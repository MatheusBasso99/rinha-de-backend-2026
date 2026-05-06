module RinhaDeBackend
  # 100% Crystal HTTP/1.x request parser. Drop-in replacement for the
  # `phr_parse_request` we used from h2o/picohttpparser — same external
  # contract (pointer/length out-params, `last_len` slowloris fast-path,
  # status codes: bytes consumed >= 0, -2 partial, -1 malformed).
  #
  # Why we replaced the C version:
  #   - kills the FFI surface and the cc step in the build,
  #   - the SSE4.2 fast paths in upstream picohttpparser amortize over
  #     long URIs and long header values; the Rinha workload sees
  #     `/fraud-score` (12 B) and ~10 short headers from the k6 client,
  #   - we trust the rinha test harness to produce syntactically-valid
  #     bytes (the prod LB is HAProxy in `mode tcp`, byte-passthrough,
  #     so the parser sees client bytes verbatim), so we skip the
  #     per-byte tchar / CTL / DEL validation upstream picohttpparser
  #     does and just locate the structural delimiters (`:`, SP, CR, LF)
  #     via libc `memchr`. Glibc/musl memchr is heavily SIMD-tuned
  #     (SSE4.2 / AVX2 on x86_64), winning on every input length we
  #     care about.
  #
  # Out of scope vs upstream (we never exercise these in this server):
  #   - response parsing (we never act as an HTTP client),
  #   - chunked transfer decoding (k6 always sends Content-Length),
  #   - obs-fold / multi-line header continuation (RFC 7230 obsoleted
  #     it and well-formed clients don't emit it).
  #
  # Trust assumptions (i.e. things this parser does NOT detect):
  #   - non-token bytes inside a header name,
  #   - control bytes (other than CR/LF/HT) inside a header value,
  #   - control bytes inside the path.
  # The Rinha test harness is well-formed; if it ever stops being so we
  # would surface the issue downstream as a malformed JSON and answer the
  # safe 200/0.0 fallback in HttpServer#handle_fraud_score.
  module HttpParser
    # Same shape as picohttpparser's `struct phr_header`: a pointer +
    # length pair pointing back into the caller's buffer. Stored in a
    # `StaticArray(Header, 16)` on the fiber stack — zero allocation per
    # request.
    struct Header
      property name : UInt8*
      property name_len : Int32
      property value : UInt8*
      property value_len : Int32

      def initialize
        @name = Pointer(UInt8).null
        @name_len = 0
        @value = Pointer(UInt8).null
        @value_len = 0
      end
    end

    SP    = 0x20_u8
    HT    = 0x09_u8
    CR    = 0x0d_u8
    LF    = 0x0a_u8
    COLON = 0x3a_u8

    # Wraps libc memchr — returns the pointer to the first occurrence of
    # `c` in `p[0, n]`, or null. Glibc and musl both ship vectorised
    # memchr (SSE4.2 / AVX2 on x86_64), which is exactly the inner loop
    # we want for "scan to next delimiter".
    @[AlwaysInline]
    private def self.memchr(p : UInt8*, c : UInt8, n : Int32) : UInt8*
      LibC.memchr(p.as(Void*), c.to_i32, n.to_u64).as(UInt8*)
    end

    # Slowloris fast-path: returns true if the headers terminator
    # (`\r\n\r\n` or any combination of CRLF/LF doubled) appears in the
    # buffer. Resumes from `last_len - 3` to avoid rescanning bytes we
    # already saw on a previous call. Mirrors picohttpparser's
    # `is_complete`.
    private def self.is_complete?(buf : UInt8*, buf_end : UInt8*, last_len : Int32) : Bool
      p = last_len < 3 ? buf : buf + (last_len - 3)
      ret_cnt = 0
      while p < buf_end
        c = p.value
        if c == CR
          p += 1
          return false if p >= buf_end
          return false if p.value != LF
          p += 1
          ret_cnt += 1
        elsif c == LF
          p += 1
          ret_cnt += 1
        else
          p += 1
          ret_cnt = 0
        end
        return true if ret_cnt == 2
      end
      false
    end

    # Top-level entry point. Drop-in for `phr_parse_request`.
    #
    # Returns:
    #   >= 0 : number of bytes consumed (request-line + headers, body
    #          starts at this offset)
    #     -2 : input is partial, caller should keep reading
    #     -1 : malformed
    #
    # Out-params populated on success:
    #   method.value, method_len.value     -> METHOD slice
    #   path.value,   path_len.value       -> request-target slice
    #   minor_version.value                -> 0 for HTTP/1.0, 1 for HTTP/1.1
    #   headers[0..num_headers.value-1]    -> name/value slices
    #   num_headers.value                  -> count of headers parsed
    def self.parse_request(buf : UInt8*, len : Int32,
                           method : Pointer(Pointer(UInt8)), method_len : Pointer(Int32),
                           path : Pointer(Pointer(UInt8)), path_len : Pointer(Int32),
                           minor_version : Pointer(Int32),
                           headers : Pointer(Header),
                           num_headers : Pointer(Int32),
                           last_len : Int32) : Int32
      max_headers = num_headers.value
      method.value = Pointer(UInt8).null
      method_len.value = 0
      path.value = Pointer(UInt8).null
      path_len.value = 0
      minor_version.value = -1
      num_headers.value = 0

      buf_start = buf
      buf_end = buf + len

      if last_len != 0 && !is_complete?(buf_start, buf_end, last_len)
        return -2
      end

      result_buf = Pointer(UInt8).null
      status = 0

      result_buf, status = parse_request_line(buf_start, buf_end,
        method, method_len, path, path_len, minor_version)
      return status if result_buf.null?

      result_buf, status = parse_headers(result_buf, buf_end, headers, num_headers, max_headers)
      return status if result_buf.null?

      (result_buf.address - buf_start.address).to_i32
    end

    # Parses METHOD SP path SP HTTP/1.<minor> CRLF, plus an optional
    # leading CRLF/LF (RFC 7230 §3.5: "a server that is expecting to
    # receive ... SHOULD ignore at least one empty line").
    private def self.parse_request_line(buf : UInt8*, buf_end : UInt8*,
                                        method : Pointer(Pointer(UInt8)), method_len : Pointer(Int32),
                                        path : Pointer(Pointer(UInt8)), path_len : Pointer(Int32),
                                        minor_version : Pointer(Int32)) : {UInt8*, Int32}
      # Tolerate a leading CRLF or bare LF before the request line.
      return {Pointer(UInt8).null, -2} if buf >= buf_end
      if buf.value == CR
        buf += 1
        return {Pointer(UInt8).null, -2} if buf >= buf_end
        return {Pointer(UInt8).null, -1} if buf.value != LF
        buf += 1
      elsif buf.value == LF
        buf += 1
      end

      # METHOD: scan to the first SP. memchr does the SIMD walk for us.
      remaining = (buf_end.address - buf.address).to_i32
      sp = memchr(buf, SP, remaining)
      return {Pointer(UInt8).null, -2} if sp.null?
      mlen = (sp.address - buf.address).to_i32
      return {Pointer(UInt8).null, -1} if mlen == 0
      method.value = buf
      method_len.value = mlen
      buf = sp + 1

      # Skip extra space(s) before the path.
      while buf < buf_end && buf.value == SP
        buf += 1
      end
      return {Pointer(UInt8).null, -2} if buf >= buf_end

      # PATH: scan to the next SP. Trusts that the harness client never
      # embeds CTLs in the request target.
      remaining = (buf_end.address - buf.address).to_i32
      sp = memchr(buf, SP, remaining)
      return {Pointer(UInt8).null, -2} if sp.null?
      plen = (sp.address - buf.address).to_i32
      return {Pointer(UInt8).null, -1} if plen == 0
      path.value = buf
      path_len.value = plen
      buf = sp + 1

      # Skip extra space(s) before the version token.
      while buf < buf_end && buf.value == SP
        buf += 1
      end

      # HTTP/1.<digit>: 8 fixed bytes + at least one byte of CR/LF.
      return {Pointer(UInt8).null, -2} if buf_end - buf < 9
      return {Pointer(UInt8).null, -1} if buf.value != 'H'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 1).value != 'T'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 2).value != 'T'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 3).value != 'P'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 4).value != '/'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 5).value != '1'.ord.to_u8
      return {Pointer(UInt8).null, -1} if (buf + 6).value != '.'.ord.to_u8
      mv = (buf + 7).value
      return {Pointer(UInt8).null, -1} if mv < '0'.ord.to_u8 || mv > '9'.ord.to_u8
      minor_version.value = (mv - '0'.ord.to_u8).to_i32
      buf += 8

      # CRLF (or bare LF) terminating the request line.
      return {Pointer(UInt8).null, -2} if buf >= buf_end
      if buf.value == CR
        buf += 1
        return {Pointer(UInt8).null, -2} if buf >= buf_end
        return {Pointer(UInt8).null, -1} if buf.value != LF
        buf += 1
      elsif buf.value == LF
        buf += 1
      else
        return {Pointer(UInt8).null, -1}
      end

      {buf, 0}
    end

    # Parses the header block: (name ":" OWS value OWS CRLF)* CRLF.
    # Trims trailing OWS from each value. Trusts the harness client's
    # syntactic output: per-byte tchar / CTL validation is omitted, we
    # only locate the structural delimiters via libc memchr (SIMD-
    # vectorised).
    private def self.parse_headers(buf : UInt8*, buf_end : UInt8*,
                                   headers : Pointer(Header),
                                   num_headers : Pointer(Int32),
                                   max_headers : Int32) : {UInt8*, Int32}
      n = 0
      loop do
        return {Pointer(UInt8).null, -2} if buf >= buf_end
        c = buf.value
        if c == CR
          buf += 1
          return {Pointer(UInt8).null, -2} if buf >= buf_end
          return {Pointer(UInt8).null, -1} if buf.value != LF
          buf += 1
          break
        elsif c == LF
          buf += 1
          break
        end

        return {Pointer(UInt8).null, -1} if n >= max_headers

        # Header name: locate the ':' delimiter via memchr.
        remaining = (buf_end.address - buf.address).to_i32
        colon = memchr(buf, COLON, remaining)
        return {Pointer(UInt8).null, -2} if colon.null?
        nlen = (colon.address - buf.address).to_i32
        return {Pointer(UInt8).null, -1} if nlen == 0
        name_start = buf
        buf = colon + 1

        # OWS before value.
        while buf < buf_end && (buf.value == SP || buf.value == HT)
          buf += 1
        end

        # Value: scan to CR (the line terminator). The harness client
        # always sends CRLF; bare LF would be detected here as
        # "no CR" → partial.
        remaining = (buf_end.address - buf.address).to_i32
        cr = memchr(buf, CR, remaining)
        return {Pointer(UInt8).null, -2} if cr.null?
        value_start = buf
        value_end = cr
        buf = cr + 1
        return {Pointer(UInt8).null, -2} if buf >= buf_end
        return {Pointer(UInt8).null, -1} if buf.value != LF
        buf += 1

        # Trim trailing OWS from the value.
        while value_end > value_start
          ce = (value_end - 1).value
          break unless ce == SP || ce == HT
          value_end -= 1
        end

        h = headers + n
        h.value.name = name_start
        h.value.name_len = nlen
        h.value.value = value_start
        h.value.value_len = (value_end.address - value_start.address).to_i32
        n += 1
      end
      num_headers.value = n
      {buf, 0}
    end
  end
end
