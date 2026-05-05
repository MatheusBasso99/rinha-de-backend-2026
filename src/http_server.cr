require "socket"
require "./http_parser"
require "./json_parser"
require "./parsed_request"
require "./vectorizer"
require "./ivf"
require "./references"

module RinhaDeBackend
  # Minimal HTTP/1.1 server tailored to the Rinha workload: two known
  # routes (`POST /fraud-score`, `GET /ready`), tiny POST bodies, no
  # query string, no chunked encoding, no upgrades.
  #
  # Why we replaced `HTTP::Server`:
  #   - per-request `Request`/`Response`/header `Hash` allocations,
  #   - 8 KB `IO::Buffered` read+write buffers per kept-alive connection,
  #   - keep-alive race that occasionally RSTs sockets under load.
  #
  # Design here:
  #   - One fiber per connection (same as stdlib).
  #   - Per-fiber 8 KB stack buffer (uninitialized StaticArray) — survives
  #     I/O yields, costs nothing to "allocate".
  #   - HttpParser (pure Crystal) parses the request line + headers from
  #     the same stack buffer, zero allocations on the hot path.
  #   - Six pre-rendered fraud-score responses + three static
  #     status-only responses, written with a single `socket.write`.
  #   - `read_buffering = false`, `sync = true`, `tcp_nodelay = true`:
  #     no internal IO::Buffered allocation per connection, no Nagle.
  #   - Keep-alive by default for HTTP/1.1; only `Connection: close`
  #     forces shutdown (or HTTP/1.0 unless `Connection: keep-alive`).
  class HttpServer
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9999

    # 8 KB is overkill for the Rinha schema (request bodies fit in <1 KB,
    # request lines + headers from nginx fit in ~600 B). Headroom is cheap
    # since the buffer is on the fiber stack.
    BUF_SIZE    = 8192
    MAX_HEADERS = 16

    READY_RESPONSE       = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".to_slice
    NOT_FOUND_RESPONSE   = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".to_slice
    BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_slice

    # Six possible outcomes (frauds_in_top_5 = 0..5). Threshold is 0.6, so
    # 3+ frauds → not approved. The bodies match what FraudScoreAction had
    # before; we just inline the HTTP envelope so the whole response can be
    # written in a single syscall, no streaming, no header serialization.
    FRAUD_BODIES = [
      %({"approved":true,"fraud_score":0.0}),
      %({"approved":true,"fraud_score":0.2}),
      %({"approved":true,"fraud_score":0.4}),
      %({"approved":false,"fraud_score":0.6}),
      %({"approved":false,"fraud_score":0.8}),
      %({"approved":false,"fraud_score":1.0}),
    ]

    FRAUD_RESPONSES = FRAUD_BODIES.map do |body|
      ("HTTP/1.1 200 OK\r\n" \
       "Content-Type: application/json\r\n" \
       "Content-Length: #{body.bytesize}\r\n" \
       "Connection: keep-alive\r\n" \
       "\r\n" + body).to_slice
    end

    # Lowercase reference values for case-insensitive header matching.
    CONTENT_LENGTH_NAME = "content-length"
    CONNECTION_NAME     = "connection"
    KEEP_ALIVE_VALUE    = "keep-alive"
    CLOSE_VALUE         = "close"

    GET_PATH_READY  = "/ready".to_slice
    POST_PATH_FRAUD = "/fraud-score".to_slice

    def initialize(@host : String, @port : Int32, @vectorizer : Vectorizer, @ivf : Ivf)
    end

    def listen : Nil
      tcp = TCPServer.new(@host, @port, reuse_port: false)
      tcp.reuse_address = true
      log "listening on #{@host}:#{@port}"

      loop do
        sock = tcp.accept
        spawn handle(sock)
      end
    end

    # ------------------------------------------------------------------
    # Per-connection loop. Stays alive across keep-alive requests; the
    # 8 KB stack buffer is reused for every request on the same fiber.
    # ------------------------------------------------------------------
    private def handle(sock : TCPSocket) : Nil
      sock.read_buffering = false
      sock.sync = true
      sock.tcp_nodelay = true

      buf_storage = uninitialized StaticArray(UInt8, 8192)
      buf = buf_storage.to_slice
      headers_storage = uninitialized StaticArray(HttpParser::Header, 16)
      filled = 0
      last_len = 0

      loop do
        if filled >= buf.size
          # Headers + body would not fit in the 8 KB scratch buffer.
          # Reject and close — the Rinha workload never legitimately
          # produces a request this big.
          sock.write(BAD_REQUEST_RESPONSE)
          return
        end

        n = sock.read(buf + filled)
        return if n == 0
        new_filled = filled + n

        method_ptr = Pointer(UInt8).null
        method_len = 0
        path_ptr = Pointer(UInt8).null
        path_len = 0
        minor = 0
        num_headers = MAX_HEADERS

        result = HttpParser.parse_request(
          buf.to_unsafe,
          new_filled,
          pointerof(method_ptr),
          pointerof(method_len),
          pointerof(path_ptr),
          pointerof(path_len),
          pointerof(minor),
          headers_storage.to_unsafe,
          pointerof(num_headers),
          last_len,
        )

        if result == -2
          # Partial. Keep reading. The parser uses last_len to skip
          # already-scanned bytes on the next call.
          filled = new_filled
          last_len = new_filled
          next
        end

        if result == -1
          sock.write(BAD_REQUEST_RESPONSE)
          return
        end

        header_end = result
        content_length, connection_close = HttpServer.scan_headers(
          headers_storage.to_unsafe,
          num_headers,
          minor,
        )

        total = header_end + content_length
        if total > buf.size
          sock.write(BAD_REQUEST_RESPONSE)
          return
        end

        # Make sure the body is fully buffered before we hand it off.
        while new_filled < total
          n = sock.read(buf + new_filled)
          return if n == 0
          new_filled += n
        end

        method_slice = Slice.new(method_ptr, method_len)
        path_slice = Slice.new(path_ptr, path_len)
        body_slice = buf[header_end, content_length]

        dispatch(sock, method_slice, path_slice, body_slice)

        return if connection_close

        # Carry leftover bytes (start of the next pipelined request) to
        # the front of the buffer. nginx with `proxy_http_version 1.1`
        # does not pipeline upstream, but the cost is one move of <1 KB
        # in the very rare case it happens.
        leftover = new_filled - total
        if leftover > 0
          buf.to_unsafe.move_from(buf.to_unsafe + total, leftover)
        end
        filled = leftover
        last_len = 0
      end
    rescue IO::Error
      # Connection reset, timeout, peer closed mid-write — normal under
      # load. Nothing to log; nginx will retry on the other upstream if
      # the response was lost in flight.
    ensure
      sock.close rescue nil
    end

    # ------------------------------------------------------------------
    # Routing. Inlined byte compares: the two routes we serve fit in
    # 4-char and 3-char methods + small literal paths. No hash lookup.
    # ------------------------------------------------------------------
    @[AlwaysInline]
    private def dispatch(sock : TCPSocket, method : Bytes, path : Bytes, body : Bytes) : Nil
      if method.size == 4 &&
         method.unsafe_fetch(0) == 'P'.ord.to_u8 &&
         method.unsafe_fetch(1) == 'O'.ord.to_u8 &&
         method.unsafe_fetch(2) == 'S'.ord.to_u8 &&
         method.unsafe_fetch(3) == 'T'.ord.to_u8 &&
         HttpServer.bytes_eq(path, POST_PATH_FRAUD)
        handle_fraud_score(sock, body)
      elsif method.size == 3 &&
            method.unsafe_fetch(0) == 'G'.ord.to_u8 &&
            method.unsafe_fetch(1) == 'E'.ord.to_u8 &&
            method.unsafe_fetch(2) == 'T'.ord.to_u8 &&
            HttpServer.bytes_eq(path, GET_PATH_READY)
        sock.write(READY_RESPONSE)
      else
        sock.write(NOT_FOUND_RESPONSE)
      end
    end

    @[AlwaysInline]
    private def handle_fraud_score(sock : TCPSocket, body : Bytes) : Nil
      parsed = JsonParser.parse(body)
      vec_f = @vectorizer.vectorize(body, parsed)
      query = StaticArray(Int16, 14).new(0_i16)
      14.times do |i|
        query[i] = (vec_f[i] * References::SCALE.to_f32).round.to_i16
      end
      frauds = @ivf.fraud_count_top_k(query)
      sock.write(FRAUD_RESPONSES.unsafe_fetch(frauds))
    rescue
      # Same fallback as the old FraudScoreAction: HTTP 200 with a legit
      # answer beats any 5xx in the Rinha scoring formula.
      sock.write(FRAUD_RESPONSES.unsafe_fetch(0))
    end

    # ------------------------------------------------------------------
    # Header parsing helpers. Public class methods so spec/http_server_spec
    # can exercise them with synthetic phr_header input — these are the
    # pieces that bit us last time (Content-Length came back as 0,
    # silent wrong answer downstream).
    # ------------------------------------------------------------------
    def self.scan_headers(headers : HttpParser::Header*, num : Int32, minor : Int32) : {Int32, Bool}
      content_length = 0
      # HTTP/1.0 default: close. HTTP/1.1 default: keep-alive.
      connection_close = minor == 0
      i = 0
      while i < num
        h = headers[i]
        nlen = h.name_len
        if nlen == CONTENT_LENGTH_NAME.bytesize &&
           ci_eq(h.name, CONTENT_LENGTH_NAME.to_unsafe, nlen)
          content_length = parse_content_length(h.value, h.value_len)
        elsif nlen == CONNECTION_NAME.bytesize &&
              ci_eq(h.name, CONNECTION_NAME.to_unsafe, nlen)
          vlen = h.value_len
          vstart, vend = trim_ows(h.value, vlen)
          if vend - vstart == CLOSE_VALUE.bytesize &&
             ci_eq(h.value + vstart, CLOSE_VALUE.to_unsafe, CLOSE_VALUE.bytesize)
            connection_close = true
          elsif vend - vstart == KEEP_ALIVE_VALUE.bytesize &&
                ci_eq(h.value + vstart, KEEP_ALIVE_VALUE.to_unsafe, KEEP_ALIVE_VALUE.bytesize)
            connection_close = false
          end
        end
        i += 1
      end
      {content_length, connection_close}
    end

    # Parses the request envelope from `buf` using HttpParser, then
    # returns `{method, path, body, connection_close}` with byte slices
    # pointing into `buf`. Returns nil on partial/invalid input. Used by
    # specs to exercise the full parse path without TCP.
    def self.parse_request(buf : Bytes) : {Bytes, Bytes, Bytes, Bool}?
      headers_storage = uninitialized StaticArray(HttpParser::Header, 16)
      method_ptr = Pointer(UInt8).null
      method_len = 0
      path_ptr = Pointer(UInt8).null
      path_len = 0
      minor = 0
      num_headers = MAX_HEADERS

      result = HttpParser.parse_request(
        buf.to_unsafe,
        buf.size,
        pointerof(method_ptr),
        pointerof(method_len),
        pointerof(path_ptr),
        pointerof(path_len),
        pointerof(minor),
        headers_storage.to_unsafe,
        pointerof(num_headers),
        0,
      )
      return nil if result < 0

      header_end = result
      content_length, connection_close = scan_headers(
        headers_storage.to_unsafe,
        num_headers,
        minor,
      )
      total = header_end + content_length
      return nil if total > buf.size

      method = Slice.new(method_ptr, method_len)
      path = Slice.new(path_ptr, path_len)
      body = buf[header_end, content_length]
      {method, path, body, connection_close}
    end

    @[AlwaysInline]
    def self.ci_eq(a : UInt8*, b : UInt8*, len : Int32) : Bool
      i = 0
      while i < len
        ca = a[i]
        cb = b[i]
        ca |= 0x20_u8 if ca >= 'A'.ord.to_u8 && ca <= 'Z'.ord.to_u8
        # `b` is the lowercase reference; no need to fold.
        return false if ca != cb
        i += 1
      end
      true
    end

    @[AlwaysInline]
    def self.parse_content_length(p : UInt8*, len : Int32) : Int32
      v = 0
      i = 0
      # Skip OWS (optional whitespace) before the value.
      while i < len && (p[i] == ' '.ord.to_u8 || p[i] == '\t'.ord.to_u8)
        i += 1
      end
      while i < len
        b = p[i]
        break unless b >= '0'.ord.to_u8 && b <= '9'.ord.to_u8
        v = v * 10 + (b - '0'.ord.to_u8).to_i32
        i += 1
      end
      v
    end

    # Returns [start, end) byte offsets after stripping leading and
    # trailing OWS (space / tab) from `p[0, len]`.
    @[AlwaysInline]
    def self.trim_ows(p : UInt8*, len : Int32) : {Int32, Int32}
      lo = 0
      while lo < len && (p[lo] == ' '.ord.to_u8 || p[lo] == '\t'.ord.to_u8)
        lo += 1
      end
      hi = len
      while hi > lo && (p[hi - 1] == ' '.ord.to_u8 || p[hi - 1] == '\t'.ord.to_u8)
        hi -= 1
      end
      {lo, hi}
    end

    @[AlwaysInline]
    def self.bytes_eq(a : Bytes, b : Bytes) : Bool
      return false if a.size != b.size
      i = 0
      while i < a.size
        return false if a.unsafe_fetch(i) != b.unsafe_fetch(i)
        i += 1
      end
      true
    end

    private def log(msg : String) : Nil
      STDERR.puts "[server] #{Time.utc.to_rfc3339} #{msg}"
      STDERR.flush
    end
  end
end
