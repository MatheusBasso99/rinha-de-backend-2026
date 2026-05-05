require "./normalization"
require "./mcc_risk"
require "./payload"

module RinhaDeBackend
  # Maps a parsed FraudScoreRequest to its 14-dim feature vector following
  # docs/en/DETECTION_RULES.md. Indices 5 and 6 carry the -1 sentinel when
  # `last_transaction` is null; everything else is clamped to [0.0, 1.0].
  class Vectorizer
    DIMS = 14

    def initialize(@mcc_risk : MccRisk)
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
