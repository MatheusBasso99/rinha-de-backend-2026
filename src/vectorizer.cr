require "./normalization"
require "./mcc_risk"
require "./payload"
require "./parsed_request"

module RinhaDeBackend
  # Maps a parsed FraudScoreRequest to its 14-dim feature vector following
  # docs/en/DETECTION_RULES.md. Indices 5 and 6 carry the -1 sentinel when
  # `last_transaction` is null; everything else is clamped to [0.0, 1.0].
  class Vectorizer
    DIMS = 14

    def initialize(@mcc_risk : MccRisk)
    end

    # Hot-path entrypoint. Consumes the raw request buffer plus the
    # primitives extracted by JsonParser; produces the same 14-dim vector
    # as the FraudScoreRequest path with no per-request heap allocation.
    def vectorize(buf : Bytes, parsed : ParsedRequest) : StaticArray(Float32, 14)
      vec = StaticArray(Float32, 14).new(0.0_f32)

      vec[0] = clamp(parsed.amount.to_f32 / Normalization::MAX_AMOUNT)
      vec[1] = clamp(parsed.installments.to_f32 / Normalization::MAX_INSTALLMENTS)
      vec[2] = clamp(
        (parsed.amount / parsed.cust_avg_amount).to_f32 / Normalization::AMOUNT_VS_AVG_RATIO
      )

      vec[3] = parsed.req_hour.to_f32 / 23.0_f32
      vec[4] = parsed.req_dow_index.to_f32 / 6.0_f32

      if parsed.has_last_tx
        # Mirror Time::Span#total_minutes: (req - last) / 60s, fractional
        # seconds preserved through Float64 before narrowing to Float32.
        minutes = ((parsed.req_sec_total - parsed.last_sec_total).to_f64 / 60.0).to_f32
        vec[5] = clamp(minutes / Normalization::MAX_MINUTES)
        vec[6] = clamp(parsed.last_km_from_current.to_f32 / Normalization::MAX_KM)
      else
        vec[5] = -1.0_f32
        vec[6] = -1.0_f32
      end

      vec[7]  = clamp(parsed.term_km_from_home.to_f32 / Normalization::MAX_KM)
      vec[8]  = clamp(parsed.cust_tx_count_24h.to_f32 / Normalization::MAX_TX_COUNT_24H)
      vec[9]  = parsed.term_is_online ? 1.0_f32 : 0.0_f32
      vec[10] = parsed.term_card_present ? 1.0_f32 : 0.0_f32
      vec[11] = known_merchant?(buf, parsed) ? 0.0_f32 : 1.0_f32
      vec[12] = @mcc_risk.risk_for(parsed.mcc_packed)
      vec[13] = clamp(parsed.merchant_avg_amount.to_f32 / Normalization::MAX_MERCHANT_AVG_AMOUNT)

      vec
    end

    # Walks customer.known_merchants (stored as offsets+lengths into `buf`)
    # and compares each entry to merchant.id byte-by-byte. With at most 16
    # tracked entries × ~8 bytes per id this is a few dozen byte compares —
    # cheaper than a Set lookup, and crucially allocation-free.
    @[AlwaysInline]
    private def known_merchant?(buf : Bytes, parsed : ParsedRequest) : Bool
      mid_off = parsed.merchant_id_off
      mid_len = parsed.merchant_id_len
      i = 0
      cnt = parsed.known_count
      while i < cnt
        if parsed.known_lengths[i] == mid_len
          off = parsed.known_offsets[i]
          j = 0
          eq = true
          while j < mid_len
            if buf[off + j] != buf[mid_off + j]
              eq = false
              break
            end
            j += 1
          end
          return true if eq
        end
        i += 1
      end
      false
    end

    def vectorize(req : FraudScoreRequest) : StaticArray(Float32, 14)
      vec = StaticArray(Float32, 14).new(0.0_f32)

      tx    = req.transaction
      cust  = req.customer
      merch = req.merchant
      term  = req.terminal
      last  = req.last_transaction

      vec[0] = clamp(tx.amount.to_f32 / Normalization::MAX_AMOUNT)
      vec[1] = clamp(tx.installments.to_f32 / Normalization::MAX_INSTALLMENTS)
      vec[2] = clamp(
        (tx.amount / cust.avg_amount).to_f32 / Normalization::AMOUNT_VS_AVG_RATIO
      )

      requested_at_utc = tx.requested_at.to_utc
      vec[3] = requested_at_utc.hour.to_f32 / 23.0_f32
      # Time::DayOfWeek is Mon=1..Sun=7; the spec wants Mon=0..Sun=6.
      vec[4] = (requested_at_utc.day_of_week.to_i - 1).to_f32 / 6.0_f32

      if last
        minutes = (requested_at_utc - last.timestamp.to_utc).total_minutes.to_f32
        vec[5] = clamp(minutes / Normalization::MAX_MINUTES)
        vec[6] = clamp(last.km_from_current.to_f32 / Normalization::MAX_KM)
      else
        vec[5] = -1.0_f32
        vec[6] = -1.0_f32
      end

      vec[7]  = clamp(term.km_from_home.to_f32 / Normalization::MAX_KM)
      vec[8]  = clamp(cust.tx_count_24h.to_f32 / Normalization::MAX_TX_COUNT_24H)
      vec[9]  = term.is_online ? 1.0_f32 : 0.0_f32
      vec[10] = term.card_present ? 1.0_f32 : 0.0_f32
      vec[11] = cust.known_merchants.includes?(merch.id) ? 0.0_f32 : 1.0_f32
      vec[12] = @mcc_risk.risk_for(merch.mcc)
      vec[13] = clamp(merch.avg_amount.to_f32 / Normalization::MAX_MERCHANT_AVG_AMOUNT)

      vec
    end

    @[AlwaysInline]
    private def clamp(x : Float32) : Float32
      return 0.0_f32 if x < 0.0_f32
      return 1.0_f32 if x > 1.0_f32
      x
    end
  end
end
