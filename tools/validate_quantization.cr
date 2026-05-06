require "compress/gzip"
require "json"
require "../src/references"

# TODO #2 — Quantization sanity check.
#
# Load the original Float32 (read as Float64 by JSON::PullParser) reference
# dataset from references.json.gz, and the Int16 quantized dataset from
# references.bin. For N sampled queries, compute:
#   - Float64 brute-force top-5 indices on the Float64 dataset.
#   - Int16   brute-force top-5 indices on the Int16   dataset.
# Then compare the index sets.
#
# Differences are expected only when the F64 distance ranking has ties
# (or near-ties within a few quantization steps). Report:
#   - exact match rate (top-5 sets identical)
#   - average set-recall (|intersection|/5)
#   - whether the fraud-counts-in-top-5 disagree (the only thing that
#     actually moves the score)
#
# Usage: crystal run --release tools/validate_quantization.cr -- [N] [SEED]

module RinhaDeBackend
  K       = 5
  DIMS    = References::DIMS
  N_QUERY = (ARGV[0]? || "200").to_i
  SEED    = (ARGV[1]? || "1337").to_u64

  # ---- Load Int16 quantized references (mmapped) ----
  i16_refs = References.mmap
  STDERR.puts "[quant] mmapped #{i16_refs.count} int16 vectors"

  # ---- Load Float64 reference dataset ----
  STDERR.puts "[quant] streaming references.json.gz into Float64 ..."
  capacity = i16_refs.count
  f64_vectors = Slice(Float64).new(capacity * DIMS, 0.0)
  f64_labels  = Slice(UInt8).new(capacity, 0_u8)

  f64_count = 0
  t0 = Time.instant
  File.open(References::DEFAULT_PATH, "rb") do |file|
    Compress::Gzip::Reader.open(file) do |gz|
      pull = JSON::PullParser.new(gz)
      pull.read_array do
        offset = f64_count * DIMS
        dim = 0
        label = References::LABEL_LEGIT
        pull.read_object do |key|
          case key
          when "vector"
            pull.read_array do
              v = pull.read_float
              f64_vectors[offset + dim] = v
              dim += 1
            end
          when "label"
            label = pull.read_string == "fraud" ? References::LABEL_FRAUD : References::LABEL_LEGIT
          else
            pull.read_raw
          end
        end
        f64_labels[f64_count] = label
        f64_count += 1
      end
    end
  end
  t1 = Time.instant
  STDERR.puts "[quant] loaded #{f64_count} float64 vectors in #{(t1 - t0).total_seconds.round(2)}s"

  raise "count mismatch: f64=#{f64_count} i16=#{i16_refs.count}" unless f64_count == i16_refs.count

  # ---- Brute-force top-K (Float64) ----
  def self.brute_topk_f64(query : Slice(Float64),
                          vectors : Slice(Float64),
                          count : Int32) : StaticArray(Int32, 5)
    best_dist = StaticArray(Float64, 5).new(Float64::INFINITY)
    best_idx  = StaticArray(Int32, 5).new(-1)
    worst = Float64::INFINITY

    vec_ptr   = vectors.to_unsafe
    query_ptr = query.to_unsafe

    i = 0
    while i < count
      offset = i * DIMS
      d = 0.0
      j = 0
      while j < DIMS
        diff = query_ptr[j] - vec_ptr[offset + j]
        d += diff * diff
        break if d >= worst
        j += 1
      end

      if d < worst
        slot = K - 1
        while slot > 0 && best_dist[slot &- 1] > d
          best_dist[slot] = best_dist[slot &- 1]
          best_idx[slot]  = best_idx[slot &- 1]
          slot &-= 1
        end
        best_dist[slot] = d
        best_idx[slot]  = i
        worst = best_dist[K &- 1]
      end

      i &+= 1
    end

    best_idx
  end

  # ---- Brute-force top-K (Int16) ----
  def self.brute_topk_i16(query : Slice(Int16),
                          vectors : Slice(Int16),
                          count : Int32) : StaticArray(Int32, 5)
    best_dist = StaticArray(Int64, 5).new(Int64::MAX)
    best_idx  = StaticArray(Int32, 5).new(-1)
    worst = Int64::MAX

    vec_ptr   = vectors.to_unsafe
    query_ptr = query.to_unsafe

    i = 0
    while i < count
      offset = i * DIMS
      d = 0_i64
      j = 0
      while j < DIMS
        diff = query_ptr[j].to_i32 - vec_ptr[offset + j].to_i32
        d &+= (diff &* diff).to_i64
        break if d >= worst
        j &+= 1
      end

      if d < worst
        slot = K - 1
        while slot > 0 && best_dist[slot &- 1] > d
          best_dist[slot] = best_dist[slot &- 1]
          best_idx[slot]  = best_idx[slot &- 1]
          slot &-= 1
        end
        best_dist[slot] = d
        best_idx[slot]  = i
        worst = best_dist[K &- 1]
      end

      i &+= 1
    end

    best_idx
  end

  # ---- Main ----
  # The Int16 dataset is reordered by IVF cell, so the same logical vector
  # has different indices in the two datasets. We can't compare indices
  # directly; instead we compare based on (a) fraud counts and (b) the
  # F64 distance of the I16 picks.
  #
  # For each sampled vector:
  #   - take its Float64 form as the F64 query and its quantized Int16
  #     form as the I16 query.
  #   - F64 brute-force returns indices into f64_vectors.
  #   - I16 brute-force returns indices into i16_refs.vectors (reordered).
  #   - Compare: do the fraud-counts-in-top-5 agree? That is the
  #     score-relevant invariant.
  #   - Also: take the I16 picks, look them up in F64 (impossible without
  #     a permutation map). So we approximate by computing the F64 distance
  #     of those I16 picks via their LABEL — labels are reordered the
  #     same way, so we can fetch labels[i16_picks].

  rng = Random.new(SEED)
  query_f64 = Slice(Float64).new(DIMS, 0.0)
  query_i16 = Slice(Int16).new(DIMS, 0_i16)

  fraud_count_diffs = 0
  fraud_count_diff_dist = StaticArray(Int32, 11).new(0) # bucketed |delta| 0..5 (negative folded)
  approve_flips = 0

  f64_total_ms = 0.0
  i16_total_ms = 0.0

  N_QUERY.times do |i|
    idx = rng.rand(f64_count)
    src = idx * DIMS
    j = 0
    while j < DIMS
      v = f64_vectors[src + j]
      query_f64[j] = v
      vi = (v * References::SCALE).round
      vi = Int16::MIN.to_f if vi < Int16::MIN.to_f
      vi = Int16::MAX.to_f if vi > Int16::MAX.to_f
      query_i16[j] = vi.to_i16
      j += 1
    end

    t0 = Time.instant
    f64_picks = brute_topk_f64(query_f64, f64_vectors, f64_count)
    t1 = Time.instant
    i16_picks = brute_topk_i16(query_i16, i16_refs.vectors, i16_refs.count)
    t2 = Time.instant

    f64_total_ms += (t1 - t0).total_milliseconds
    i16_total_ms += (t2 - t1).total_milliseconds

    f64_frauds = 0
    K.times { |kk| f64_frauds += 1 if f64_labels[f64_picks[kk]] == References::LABEL_FRAUD }
    i16_frauds = 0
    K.times { |kk| i16_frauds += 1 if i16_refs.labels[i16_picks[kk]] == References::LABEL_FRAUD }

    delta = (f64_frauds - i16_frauds).abs
    fraud_count_diff_dist[delta] += 1
    fraud_count_diffs += 1 if delta != 0

    f64_score = f64_frauds / 5.0
    i16_score = i16_frauds / 5.0
    f64_approved = f64_score < 0.6
    i16_approved = i16_score < 0.6
    approve_flips += 1 if f64_approved != i16_approved

    if (i + 1) % 50 == 0
      STDERR.puts "[quant] #{i + 1}/#{N_QUERY} fraud_diffs=#{fraud_count_diffs} flips=#{approve_flips}"
      STDERR.flush
    end
  end

  agree_pct = (N_QUERY - fraud_count_diffs) * 100.0 / N_QUERY
  flip_pct  = approve_flips * 100.0 / N_QUERY

  puts ""
  puts "================ RESULTS (TODO #2: quantization) ================"
  puts "samples              : #{N_QUERY}"
  puts "fraud-count agreement: #{agree_pct.round(3)}% (#{N_QUERY - fraud_count_diffs}/#{N_QUERY})"
  puts "approve-flip rate    : #{flip_pct.round(3)}% (#{approve_flips}/#{N_QUERY})"
  puts "fraud-count |Δ| dist : " + 6.times.map { |b| "Δ#{b}=#{fraud_count_diff_dist[b]}" }.join(" ")
  puts ""
  puts "timing/query (ms)    : f64=#{(f64_total_ms / N_QUERY).round(2)} " \
       "i16=#{(i16_total_ms / N_QUERY).round(2)} " \
       "speedup=#{(f64_total_ms / i16_total_ms).round(1)}x"
  puts ""
  puts "Note: top-5 *index sets* aren't directly comparable because the i16"
  puts "dataset is reordered by IVF cell. The score-relevant invariant is the"
  puts "*fraud count in top-5*, which determines the response. Approve-flip"
  puts "rate is the user-visible disagreement: 0 means quantization can never"
  puts "change the API answer for samples drawn from the dataset."
  puts ""
  puts "verdict              : " + (approve_flips == 0 ? "OK (no approve flips)" : "REVIEW (#{approve_flips} flip(s))")
end
