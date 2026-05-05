require "./parsed_request"

module RinhaDeBackend
  # Hand-rolled JSON parser tailored to the FraudScoreRequest schema. Reads
  # the request body as a Bytes slice and writes primitives directly into a
  # ParsedRequest, with zero String allocations on the happy path.
  #
  # Field key dispatch: at every nested object level the first letter of the
  # key uniquely identifies the field, except at the top level where 't'
  # collides between "transaction" (len 11) and "terminal" (len 8). We
  # disambiguate by length there, no second-char check needed.
  #
  # The parser is permissive about whitespace, strict about overall shape:
  # malformed input raises ParseError, which the caller turns into the
  # legit fallback (HTTP 200 with fraud_score=0.0).
  module JsonParser
    extend self

    class ParseError < Exception
    end

    # Single ASCII-byte constants kept as private consts to keep the parser
    # readable. Crystal compiles these to UInt8 literals at the call site.
    private QUOTE         = '"'.ord.to_u8
    private LBRACE        = '{'.ord.to_u8
    private RBRACE        = '}'.ord.to_u8
    private LBRACK        = '['.ord.to_u8
    private RBRACK        = ']'.ord.to_u8
    private COMMA         = ','.ord.to_u8
    private COLON         = ':'.ord.to_u8
    private MINUS         = '-'.ord.to_u8
    private DOT           = '.'.ord.to_u8
    private DIGIT_0       = '0'.ord.to_u8
    private DIGIT_9       = '9'.ord.to_u8
    private SPACE         = ' '.ord.to_u8
    private TAB           = '\t'.ord.to_u8
    private LF            = '\n'.ord.to_u8
    private CR            = '\r'.ord.to_u8
    private CHAR_T        = 't'.ord.to_u8
    private CHAR_F        = 'f'.ord.to_u8
    private CHAR_N        = 'n'.ord.to_u8

    def parse(buf : Bytes) : ParsedRequest
      parsed = ParsedRequest.new
      pos = skip_ws(buf, 0)
      pos = expect(buf, pos, LBRACE)
      parse_top_object(buf, pos, pointerof(parsed))
      parsed
    end

    # ------------------------------------------------------------------
    # Object parsers
    # ------------------------------------------------------------------

    private def parse_top_object(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        key_off = pos
        pos = skip_to_quote(buf, pos)
        key_len = pos - key_off
        pos += 1 # past closing quote
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 'i'.ord.to_u8 # "id"
          pos = skip_value(buf, pos)
        when 't'.ord.to_u8
          if key_len == 11 # "transaction"
            pos = parse_transaction(buf, pos, p)
          else # "terminal"
            pos = parse_terminal(buf, pos, p)
          end
        when 'c'.ord.to_u8 # "customer"
          pos = parse_customer(buf, pos, p)
        when 'm'.ord.to_u8 # "merchant"
          pos = parse_merchant(buf, pos, p)
        when 'l'.ord.to_u8 # "last_transaction"
          pos = parse_last_transaction(buf, pos, p)
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    private def parse_transaction(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      pos = expect(buf, pos, LBRACE)
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        pos = skip_to_quote(buf, pos)
        pos += 1
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 'a'.ord.to_u8 # amount
          v, pos = parse_number(buf, pos)
          p.value.amount = v
        when 'i'.ord.to_u8 # installments
          v, pos = parse_int(buf, pos)
          p.value.installments = v.to_i32
        when 'r'.ord.to_u8 # requested_at
          pos = expect(buf, pos, QUOTE)
          sec_total, hour, dow = parse_timestamp(buf, pos)
          p.value.req_sec_total = sec_total
          p.value.req_hour = hour
          p.value.req_dow_index = dow
          pos += 20 # "YYYY-MM-DDTHH:MM:SSZ" is exactly 20 chars
          pos = expect(buf, pos, QUOTE)
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    private def parse_customer(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      pos = expect(buf, pos, LBRACE)
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        pos = skip_to_quote(buf, pos)
        pos += 1
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 'a'.ord.to_u8 # avg_amount
          v, pos = parse_number(buf, pos)
          p.value.cust_avg_amount = v
        when 't'.ord.to_u8 # tx_count_24h
          v, pos = parse_int(buf, pos)
          p.value.cust_tx_count_24h = v.to_i32
        when 'k'.ord.to_u8 # known_merchants
          pos = parse_known_merchants(buf, pos, p)
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    private def parse_known_merchants(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      pos = expect(buf, pos, LBRACK)
      count = 0
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACK
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        off = pos
        pos = skip_to_quote(buf, pos)
        len = pos - off
        if count < ParsedRequest::MAX_KNOWN_MERCHANTS
          p.value.known_offsets[count] = off
          p.value.known_lengths[count] = len
          count += 1
        end
        pos += 1 # past closing quote
      end
    ensure
      p.value.known_count = count if count
    end

    private def parse_merchant(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      pos = expect(buf, pos, LBRACE)
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        pos = skip_to_quote(buf, pos)
        pos += 1
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 'i'.ord.to_u8 # id
          pos = expect(buf, pos, QUOTE)
          off = pos
          pos = skip_to_quote(buf, pos)
          p.value.merchant_id_off = off
          p.value.merchant_id_len = pos - off
          pos += 1
        when 'm'.ord.to_u8 # mcc — packed UInt32 of 4 ASCII digits
          pos = expect(buf, pos, QUOTE)
          off = pos
          pos = skip_to_quote(buf, pos)
          if pos - off == 4
            p.value.mcc_packed = pack_mcc(buf, off)
          else
            p.value.mcc_packed = 0_u32
          end
          pos += 1
        when 'a'.ord.to_u8 # avg_amount
          v, pos = parse_number(buf, pos)
          p.value.merchant_avg_amount = v
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    private def parse_terminal(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      pos = expect(buf, pos, LBRACE)
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        pos = skip_to_quote(buf, pos)
        pos += 1
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 'i'.ord.to_u8 # is_online
          v, pos = parse_bool(buf, pos)
          p.value.term_is_online = v
        when 'c'.ord.to_u8 # card_present
          v, pos = parse_bool(buf, pos)
          p.value.term_card_present = v
        when 'k'.ord.to_u8 # km_from_home
          v, pos = parse_number(buf, pos)
          p.value.term_km_from_home = v
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    private def parse_last_transaction(buf : Bytes, pos : Int32, p : ParsedRequest*) : Int32
      # Either an object with timestamp + km_from_current, or null.
      if buf[pos] == CHAR_N
        # "null"
        return pos + 4
      end

      pos = expect(buf, pos, LBRACE)
      p.value.has_last_tx = true
      loop do
        pos = skip_ws(buf, pos)
        return pos + 1 if buf[pos] == RBRACE
        if buf[pos] == COMMA
          pos += 1
          next
        end
        pos = expect(buf, pos, QUOTE)
        key_first = buf[pos]
        pos = skip_to_quote(buf, pos)
        pos += 1
        pos = skip_ws(buf, pos)
        pos = expect(buf, pos, COLON)
        pos = skip_ws(buf, pos)

        case key_first
        when 't'.ord.to_u8 # timestamp
          pos = expect(buf, pos, QUOTE)
          sec_total, _hour, _dow = parse_timestamp(buf, pos)
          p.value.last_sec_total = sec_total
          pos += 20
          pos = expect(buf, pos, QUOTE)
        when 'k'.ord.to_u8 # km_from_current
          v, pos = parse_number(buf, pos)
          p.value.last_km_from_current = v
        else
          pos = skip_value(buf, pos)
        end
      end
    end

    # ------------------------------------------------------------------
    # Primitive parsers
    # ------------------------------------------------------------------

    private def parse_number(buf : Bytes, pos : Int32) : {Float64, Int32}
      neg = false
      if buf[pos] == MINUS
        neg = true
        pos += 1
      end
      int_part = 0_i64
      while pos < buf.size
        b = buf[pos]
        break unless b >= DIGIT_0 && b <= DIGIT_9
        int_part = int_part * 10 + (b - DIGIT_0)
        pos += 1
      end
      v = int_part.to_f64
      if pos < buf.size && buf[pos] == DOT
        pos += 1
        frac_int = 0_i64
        frac_div = 1.0
        while pos < buf.size
          b = buf[pos]
          break unless b >= DIGIT_0 && b <= DIGIT_9
          frac_int = frac_int * 10 + (b - DIGIT_0)
          frac_div *= 10.0
          pos += 1
        end
        v += frac_int.to_f64 / frac_div
      end
      v = -v if neg
      {v, pos}
    end

    private def parse_int(buf : Bytes, pos : Int32) : {Int64, Int32}
      neg = false
      if buf[pos] == MINUS
        neg = true
        pos += 1
      end
      v = 0_i64
      while pos < buf.size
        b = buf[pos]
        break unless b >= DIGIT_0 && b <= DIGIT_9
        v = v * 10 + (b - DIGIT_0)
        pos += 1
      end
      v = -v if neg
      {v, pos}
    end

    private def parse_bool(buf : Bytes, pos : Int32) : {Bool, Int32}
      if buf[pos] == CHAR_T
        {true, pos + 4} # "true"
      else
        {false, pos + 5} # "false"
      end
    end

    # Parses "YYYY-MM-DDTHH:MM:SSZ" starting at `off` into total seconds
    # since the Unix epoch, plus the hour-of-day and Mon=0..Sun=6 day index.
    # Caller is responsible for advancing past the 20 chars + closing quote.
    private def parse_timestamp(buf : Bytes, off : Int32) : {Int64, Int32, Int32}
      y = digits4(buf, off)
      m = digits2(buf, off + 5)
      d = digits2(buf, off + 8)
      hh = digits2(buf, off + 11)
      mm = digits2(buf, off + 14)
      ss = digits2(buf, off + 17)
      days = days_from_civil(y, m, d)
      sec = days * 86400_i64 + hh.to_i64 * 3600 + mm.to_i64 * 60 + ss.to_i64
      # 1970-01-01 was Thursday → days=0 should map to dow_index=3 (Mon=0)
      raw = (days + 3) % 7
      raw += 7 if raw < 0
      {sec, hh, raw.to_i32}
    end

    @[AlwaysInline]
    private def digits2(buf : Bytes, off : Int32) : Int32
      ((buf[off] - DIGIT_0).to_i32) * 10 + (buf[off + 1] - DIGIT_0).to_i32
    end

    @[AlwaysInline]
    private def digits4(buf : Bytes, off : Int32) : Int32
      ((buf[off] - DIGIT_0).to_i32) * 1000 +
        (buf[off + 1] - DIGIT_0).to_i32 * 100 +
        (buf[off + 2] - DIGIT_0).to_i32 * 10 +
        (buf[off + 3] - DIGIT_0).to_i32
    end

    # Howard Hinnant's days_from_civil: number of days from 1970-01-01 to
    # the given proleptic Gregorian date. Algorithm reference:
    # https://howardhinnant.github.io/date_algorithms.html
    private def days_from_civil(y : Int32, m : Int32, d : Int32) : Int64
      yy = m <= 2 ? y - 1 : y
      era = (yy >= 0 ? yy : yy - 399) // 400
      yoe = yy - era * 400
      doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) // 5 + d - 1
      doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
      era.to_i64 * 146097_i64 + doe.to_i64 - 719468_i64
    end

    @[AlwaysInline]
    private def pack_mcc(buf : Bytes, off : Int32) : UInt32
      (buf[off].to_u32 << 24) |
        (buf[off + 1].to_u32 << 16) |
        (buf[off + 2].to_u32 << 8) |
        buf[off + 3].to_u32
    end

    # ------------------------------------------------------------------
    # Whitespace / structural helpers
    # ------------------------------------------------------------------

    @[AlwaysInline]
    private def skip_ws(buf : Bytes, pos : Int32) : Int32
      while pos < buf.size
        b = buf[pos]
        break unless b == SPACE || b == LF || b == CR || b == TAB
        pos += 1
      end
      pos
    end

    @[AlwaysInline]
    private def expect(buf : Bytes, pos : Int32, byte : UInt8) : Int32
      raise ParseError.new("expected #{byte.chr.inspect} at #{pos}") if buf[pos] != byte
      pos + 1
    end

    # Returns the position of the closing `"`. Assumes opening `"` was
    # already consumed by the caller and the contents have no escapes
    # (true for all FraudScoreRequest fields).
    @[AlwaysInline]
    private def skip_to_quote(buf : Bytes, pos : Int32) : Int32
      while pos < buf.size && buf[pos] != QUOTE
        pos += 1
      end
      pos
    end

    # Skips one JSON value, returning the position right after it.
    private def skip_value(buf : Bytes, pos : Int32) : Int32
      c = buf[pos]
      case c
      when QUOTE
        pos += 1
        pos = skip_to_quote(buf, pos)
        pos + 1
      when LBRACE
        skip_object(buf, pos)
      when LBRACK
        skip_array(buf, pos)
      when CHAR_T
        pos + 4
      when CHAR_F
        pos + 5
      when CHAR_N
        pos + 4
      else
        # number
        while pos < buf.size
          b = buf[pos]
          break if b == COMMA || b == RBRACE || b == RBRACK || b == SPACE || b == LF || b == CR || b == TAB
          pos += 1
        end
        pos
      end
    end

    private def skip_object(buf : Bytes, pos : Int32) : Int32
      depth = 0
      loop do
        c = buf[pos]
        if c == LBRACE
          depth += 1
          pos += 1
        elsif c == RBRACE
          depth -= 1
          pos += 1
          return pos if depth == 0
        elsif c == QUOTE
          pos += 1
          pos = skip_to_quote(buf, pos)
          pos += 1
        else
          pos += 1
        end
      end
    end

    private def skip_array(buf : Bytes, pos : Int32) : Int32
      depth = 0
      loop do
        c = buf[pos]
        if c == LBRACK
          depth += 1
          pos += 1
        elsif c == RBRACK
          depth -= 1
          pos += 1
          return pos if depth == 0
        elsif c == QUOTE
          pos += 1
          pos = skip_to_quote(buf, pos)
          pos += 1
        else
          pos += 1
        end
      end
    end
  end
end
