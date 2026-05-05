require "./spec_helper"
require "../src/json_parser"
require "json"

# Cross-validates the hand-rolled JsonParser against Crystal's
# JSON::Serializable + Time path. For every fixture in example-payloads.json
# we parse both ways, run them through Vectorizer, and assert the resulting
# 14-dim vectors agree element-by-element. Any drift here means the parser
# diverges from the canonical implementation.
describe RinhaDeBackend::JsonParser do
  mcc_risk   = RinhaDeBackend::MccRisk.new
  vectorizer = RinhaDeBackend::Vectorizer.new(mcc_risk)

  fixtures = JSON.parse(File.read("resources/example-payloads.json")).as_a

  fixtures.each_with_index do |fixture, idx|
    payload = fixture.to_json
    id      = fixture["id"].as_s

    it "parses fixture ##{idx} (#{id}) identically to JSON::Serializable" do
      buf = payload.to_slice

      req       = RinhaDeBackend::FraudScoreRequest.from_json(payload)
      vec_canon = vectorizer.vectorize(req)

      parsed   = RinhaDeBackend::JsonParser.parse(buf)
      vec_fast = vectorizer.vectorize(buf, parsed)

      14.times do |i|
        vec_fast[i].should be_close(vec_canon[i], 1e-5_f32)
      end
    end
  end
end
