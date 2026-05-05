module RinhaDeBackend
  # Stack-allocated, zero-heap projection of FraudScoreRequest. The parser
  # writes primitives (Float64/Int32/Int64/Bool) directly into instances of
  # this struct; merchant_id and customer.known_merchants are kept as
  # (offset, length) byte ranges into the original request buffer so we can
  # match them later without allocating String copies.
  #
  # Sized to fit comfortably on a fiber stack: roughly 200 bytes.
  struct ParsedRequest
    # Maximum number of known_merchants we track. The Rinha fixtures top out
    # at 5; we leave headroom and silently drop extras (the matcher just
    # returns "unknown" if merchant.id was past this cap, which is fine
    # because falling back to "unknown" never fails harder than getting it
    # right would have).
    MAX_KNOWN_MERCHANTS = 16

    property amount : Float64
    property installments : Int32

    # requested_at, broken into the pieces the vectorizer needs:
    #   - hour for vec[3]
    #   - day-of-week (Mon=0..Sun=6) for vec[4]
    #   - total seconds since epoch for the minutes_since_last_tx delta
    property req_hour : Int32
    property req_dow_index : Int32
    property req_sec_total : Int64

    property cust_avg_amount : Float64
    property cust_tx_count_24h : Int32

    # Byte range of merchant.id within the input buffer.
    property merchant_id_off : Int32
    property merchant_id_len : Int32

    # Byte ranges of customer.known_merchants entries.
    property known_count : Int32
    property known_offsets : StaticArray(Int32, 16)
    property known_lengths : StaticArray(Int32, 16)

    # MCC packed as 4 ASCII bytes (b0<<24 | b1<<16 | b2<<8 | b3). Lets MccRisk
    # do a Hash(UInt32, Float32) lookup with no String allocation.
    property mcc_packed : UInt32
    property merchant_avg_amount : Float64

    property term_is_online : Bool
    property term_card_present : Bool
    property term_km_from_home : Float64

    property has_last_tx : Bool
    property last_sec_total : Int64
    property last_km_from_current : Float64

    def initialize
      @amount = 0.0
      @installments = 0
      @req_hour = 0
      @req_dow_index = 0
      @req_sec_total = 0_i64
      @cust_avg_amount = 0.0
      @cust_tx_count_24h = 0
      @merchant_id_off = 0
      @merchant_id_len = 0
      @known_count = 0
      @known_offsets = StaticArray(Int32, 16).new(0)
      @known_lengths = StaticArray(Int32, 16).new(0)
      @mcc_packed = 0_u32
      @merchant_avg_amount = 0.0
      @term_is_online = false
      @term_card_present = false
      @term_km_from_home = 0.0
      @has_last_tx = false
      @last_sec_total = 0_i64
      @last_km_from_current = 0.0
    end
  end
end
