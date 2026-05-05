require "./base_action"

module RinhaDeBackend
  class FraudScoreAction < BaseAction
    route "POST", "/fraud-score"

    STUB_BODY = %({"approved":true,"fraud_score":0.0})

    def call(context : HTTP::Server::Context) : Nil
      respond_json(context, 200, STUB_BODY)
    end
  end
end
