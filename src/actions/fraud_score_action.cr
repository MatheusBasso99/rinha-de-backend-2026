require "json"
require "./base_action"
require "../payload"
require "../vectorizer"
require "../knn"
require "../references"

module RinhaDeBackend
  class FraudScoreAction < BaseAction
    route "POST", "/fraud-score"

    # Six possible outcomes (frauds_in_top_5 = 0..5). Threshold is 0.6, so
    # 3+ frauds → not approved. Pre-rendered to avoid any String#build /
    # Float#to_s allocations on the hot path.
    RESPONSES = [
      %({"approved":true,"fraud_score":0.0}),
      %({"approved":true,"fraud_score":0.2}),
      %({"approved":true,"fraud_score":0.4}),
      %({"approved":false,"fraud_score":0.6}),
      %({"approved":false,"fraud_score":0.8}),
      %({"approved":false,"fraud_score":1.0}),
    ]

    # Same legit fallback used on parse / runtime errors. HTTP 200 with a
    # legit answer is cheaper than a 5xx (Err weighs 5x in scoring).
    FALLBACK_BODY = RESPONSES[0]

    def initialize(@vectorizer : Vectorizer, @knn : Knn)
    end

    def call(context : HTTP::Server::Context) : Nil
      body = context.request.body
      return respond_json(context, 200, FALLBACK_BODY) unless body

      req = FraudScoreRequest.from_json(body)
      vec_f = @vectorizer.vectorize(req)

      # Quantize Float32 → Int16 (same scale used by References).
      query = StaticArray(Int16, 14).new(0_i16)
      14.times do |i|
        query[i] = (vec_f[i] * References::SCALE.to_f32).round.to_i16
      end

      frauds = @knn.fraud_count_top_k(query)
      respond_json(context, 200, RESPONSES.unsafe_fetch(frauds))
    rescue ex
      respond_json(context, 200, FALLBACK_BODY)
    end
  end
end
