require "./base_action"
require "../json_parser"
require "../parsed_request"
require "../vectorizer"
require "../ivf"
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

    # Body buffer size. The Rinha schema fits comfortably under 1 KB; 4 KB
    # gives headroom for whitespace-heavy payloads. The buffer lives on the
    # fiber stack (uninitialized StaticArray), so it costs nothing per
    # request and survives I/O yields.
    BODY_BUF_SIZE = 4096

    def initialize(@vectorizer : Vectorizer, @ivf : Ivf)
    end

    def call(context : HTTP::Server::Context) : Nil
      body = context.request.body
      return respond_json(context, 200, FALLBACK_BODY) unless body

      buf_storage = uninitialized StaticArray(UInt8, 4096)
      slice = buf_storage.to_slice
      total = 0
      while total < slice.size
        n = body.read(slice + total)
        break if n == 0
        total += n
      end
      buf = slice[0, total]

      parsed = JsonParser.parse(buf)
      vec_f = @vectorizer.vectorize(buf, parsed)

      # Quantize Float32 → Int16 (same scale used by References).
      query = StaticArray(Int16, 14).new(0_i16)
      14.times do |i|
        query[i] = (vec_f[i] * References::SCALE.to_f32).round.to_i16
      end

      frauds = @ivf.fraud_count_top_k(query)
      respond_json(context, 200, RESPONSES.unsafe_fetch(frauds))
    rescue ex
      respond_json(context, 200, FALLBACK_BODY)
    end
  end
end
