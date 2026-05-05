require "./spec_helper"

private def round4(value : Float32) : Float32
  ((value * 10_000.0_f32).round / 10_000.0_f32).to_f32
end

# Both fixtures and expected vectors are taken verbatim from
# docs/en/DETECTION_RULES.md.
describe RinhaDeBackend::Vectorizer do
  mcc_risk   = RinhaDeBackend::MccRisk.new
  vectorizer = RinhaDeBackend::Vectorizer.new(mcc_risk)

  it "matches the legit example from DETECTION_RULES.md" do
    payload = <<-JSON
    {
      "id": "tx-1329056812",
      "transaction":      { "amount": 41.12, "installments": 2, "requested_at": "2026-03-11T18:45:53Z" },
      "customer":         { "avg_amount": 82.24, "tx_count_24h": 3, "known_merchants": ["MERC-003", "MERC-016"] },
      "merchant":         { "id": "MERC-016", "mcc": "5411", "avg_amount": 60.25 },
      "terminal":         { "is_online": false, "card_present": true, "km_from_home": 29.23 },
      "last_transaction": null
    }
    JSON

    req = RinhaDeBackend::FraudScoreRequest.from_json(payload)
    vec = vectorizer.vectorize(req)

    expected = [0.0041_f32, 0.1667_f32, 0.05_f32, 0.7826_f32, 0.3333_f32,
                -1.0_f32, -1.0_f32, 0.0292_f32, 0.15_f32, 0.0_f32,
                1.0_f32, 0.0_f32, 0.15_f32, 0.006_f32]

    14.times do |i|
      round4(vec[i]).should be_close(expected[i], 0.0002_f32)
    end
  end

  it "matches the fraud example from DETECTION_RULES.md" do
    payload = <<-JSON
    {
      "id": "tx-3330991687",
      "transaction":      { "amount": 9505.97, "installments": 10, "requested_at": "2026-03-14T05:15:12Z" },
      "customer":         { "avg_amount": 81.28, "tx_count_24h": 20, "known_merchants": ["MERC-008", "MERC-007", "MERC-005"] },
      "merchant":         { "id": "MERC-068", "mcc": "7802", "avg_amount": 54.86 },
      "terminal":         { "is_online": false, "card_present": true, "km_from_home": 952.27 },
      "last_transaction": null
    }
    JSON

    req = RinhaDeBackend::FraudScoreRequest.from_json(payload)
    vec = vectorizer.vectorize(req)

    expected = [0.9506_f32, 0.8333_f32, 1.0_f32, 0.2174_f32, 0.8333_f32,
                -1.0_f32, -1.0_f32, 0.9523_f32, 1.0_f32, 0.0_f32,
                1.0_f32, 1.0_f32, 0.75_f32, 0.0055_f32]

    14.times do |i|
      round4(vec[i]).should be_close(expected[i], 0.0002_f32)
    end
  end

  it "computes minutes_since_last_tx and km_from_last_tx when last_transaction is present" do
    payload = <<-JSON
    {
      "id": "tx-1",
      "transaction":      { "amount": 100.0, "installments": 1, "requested_at": "2026-03-11T20:00:00Z" },
      "customer":         { "avg_amount": 100.0, "tx_count_24h": 1, "known_merchants": ["MERC-001"] },
      "merchant":         { "id": "MERC-001", "mcc": "5411", "avg_amount": 100.0 },
      "terminal":         { "is_online": false, "card_present": true, "km_from_home": 10.0 },
      "last_transaction": { "timestamp": "2026-03-11T18:00:00Z", "km_from_current": 250.0 }
    }
    JSON

    req = RinhaDeBackend::FraudScoreRequest.from_json(payload)
    vec = vectorizer.vectorize(req)

    # 2 hours = 120 min, 120/1440 = 0.0833...
    vec[5].should be_close(120.0_f32 / 1440.0_f32, 1e-5_f32)
    # 250 km / 1000 km = 0.25
    vec[6].should be_close(0.25_f32, 1e-5_f32)
  end

  it "uses 0.5 default for unknown MCCs" do
    payload = <<-JSON
    {
      "id": "tx-2",
      "transaction":      { "amount": 100.0, "installments": 1, "requested_at": "2026-03-11T20:00:00Z" },
      "customer":         { "avg_amount": 100.0, "tx_count_24h": 1, "known_merchants": [] },
      "merchant":         { "id": "MERC-X", "mcc": "0000", "avg_amount": 100.0 },
      "terminal":         { "is_online": true, "card_present": false, "km_from_home": 10.0 },
      "last_transaction": null
    }
    JSON

    req = RinhaDeBackend::FraudScoreRequest.from_json(payload)
    vec = vectorizer.vectorize(req)
    vec[12].should eq(0.5_f32)
  end
end
