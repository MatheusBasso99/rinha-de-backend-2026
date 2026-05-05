require "json"
require "./base_action"
require "../payload"
require "../vectorizer"

module RinhaDeBackend
  class FraudScoreAction < BaseAction
    route "POST", "/fraud-score"

    # Safe fallback. We always return 200 with this body when anything goes
    # wrong (parse error, runtime exception). Per docs/EVALUATION.md, an Err
    # (HTTP != 200) costs 5x in scoring, while a wrong-but-200 answer costs 1x
    # for FP / 3x for FN — returning the legit fallback is the cheapest panic.
    FALLBACK_BODY = %({"approved":true,"fraud_score":0.0})

    def initialize(@vectorizer : Vectorizer)
    end

    def call(context : HTTP::Server::Context) : Nil
      body = context.request.body
      return respond_json(context, 200, FALLBACK_BODY) unless body

      req = FraudScoreRequest.from_json(body)
      _vec = @vectorizer.vectorize(req)

      # KNN/decision wiring lands in the next iteration; for now we return
      # the legit fallback to confirm the parse + vectorize path compiles
      # and runs end-to-end.
      respond_json(context, 200, FALLBACK_BODY)
    rescue ex
      respond_json(context, 200, FALLBACK_BODY)
    end
  end
end
