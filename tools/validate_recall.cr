require "../src/references"

# Validate IVF recall vs brute-force.
#
# Samples N vectors from the mmapped references.bin, computes brute-force
# top-5 (over the full 3M Int16 dataset) and IVF top-5 (with nprobe=16),
# reports recall@5 = |intersection| / 5 averaged across the sample.
#
# Usage: crystal run --release tools/validate_recall.cr -- [N] [NPROBE] [SEED]

module RinhaDeBackend
  K       = 5
  DIMS    = References::DIMS
  REFS    = References.mmap
  NPROBE  = (ARGV[1]? || "16").to_i
  N_QUERY = (ARGV[0]? || "1000").to_i
  SEED    = (ARGV[2]? || "1337").to_u64

  raise "nprobe (#{NPROBE}) > k (#{REFS.k})" if NPROBE > REFS.k

  STDERR.puts "[recall] count=#{REFS.count} k=#{REFS.k} nprobe=#{NPROBE} samples=#{N_QUERY} seed=#{SEED} jitter=#{(ENV["JITTER"]? || "0").to_i}"

  # Brute-force top-K returning indices (sorted by distance asc).
  def self.brute_topk(query : Slice(Int16),
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

  # IVF top-K returning indices (top-K within the union of the nearest
  # `nprobe` cells). Mirrors src/ivf.cr but stores indices, not labels.
  def self.ivf_topk(query : Slice(Int16),
                    refs : References,
                    nprobe : Int32) : StaticArray(Int32, 5)
    vectors      = refs.vectors
    centroids    = refs.centroids
    cell_offsets = refs.cell_offsets
    k            = refs.k

    vec_ptr   = vectors.to_unsafe
    cent_ptr  = centroids.to_unsafe
    query_ptr = query.to_unsafe

    max_nprobe = 32
    raise "nprobe must be <= #{max_nprobe}" if nprobe > max_nprobe

    probe_dist = StaticArray(Int64, 32).new(Int64::MAX)
    probe_cell = StaticArray(Int32, 32).new(0)
    worst_probe = Int64::MAX

    c = 0
    while c < k
      c_off = c * DIMS
      d = 0_i64
      j = 0
      while j < DIMS
        diff = query_ptr[j].to_i32 - cent_ptr[c_off + j].to_i32
        d &+= (diff &* diff).to_i64
        j &+= 1
      end

      if d < worst_probe
        slot = nprobe &- 1
        while slot > 0 && probe_dist[slot &- 1] > d
          probe_dist[slot] = probe_dist[slot &- 1]
          probe_cell[slot] = probe_cell[slot &- 1]
          slot &-= 1
        end
        probe_dist[slot] = d
        probe_cell[slot] = c
        worst_probe = probe_dist[nprobe &- 1]
      end

      c &+= 1
    end

    best_dist = StaticArray(Int64, 5).new(Int64::MAX)
    best_idx  = StaticArray(Int32, 5).new(-1)
    worst = Int64::MAX

    p = 0
    while p < nprobe
      cell  = probe_cell[p]
      start = cell_offsets[cell].to_i32
      stop  = cell_offsets[cell &+ 1].to_i32

      i = start
      while i < stop
        off = i * DIMS
        d = 0_i64
        j = 0
        while j < DIMS
          diff = query_ptr[j].to_i32 - vec_ptr[off + j].to_i32
          d &+= (diff &* diff).to_i64
          break if d >= worst
          j &+= 1
        end

        if d < worst
          slot = K &- 1
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

      p &+= 1
    end

    best_idx
  end

  # ----- Main -----
  # `noise` (env JITTER, default 0) adds Int16 jitter in [-jitter..+jitter] to
  # each query dimension. 0 = exact in-set queries (baseline). Try a few
  # 100-300 values to simulate realistic /fraud-score traffic that does not
  # land on a known data point.
  jitter = (ENV["JITTER"]? || "0").to_i

  rng = Random.new(SEED)
  query_buf = Slice(Int16).new(DIMS, 0_i16)

  total_recall    = 0.0
  perfect         = 0
  partial         = 0
  worst_recall    = 1.0
  histogram       = StaticArray(Int32, 6).new(0) # bucket = #intersection (0..5)
  bf_total_ms     = 0.0
  ivf_total_ms    = 0.0

  N_QUERY.times do |i|
    idx = rng.rand(REFS.count)
    src = idx * DIMS
    j = 0
    # Logical lanes get optional jitter; pad lanes (DIMS-2..DIMS) are
    # pinned to 0 to match the on-disk row layout — jittering them
    # would model a query the vectorizer can't produce.
    while j < References::LOGICAL_DIMS
      v = REFS.vectors[src + j].to_i32
      if jitter > 0
        v += rng.rand(-jitter..jitter)
        v = Int16::MIN.to_i32 if v < Int16::MIN
        v = Int16::MAX.to_i32 if v > Int16::MAX
      end
      query_buf[j] = v.to_i16
      j += 1
    end
    while j < DIMS
      query_buf[j] = 0_i16
      j += 1
    end

    t0 = Time.instant
    bf = brute_topk(query_buf, REFS.vectors, REFS.count)
    t1 = Time.instant
    iv = ivf_topk(query_buf, REFS, NPROBE)
    t2 = Time.instant

    bf_total_ms  += (t1 - t0).total_milliseconds
    ivf_total_ms += (t2 - t1).total_milliseconds

    # |intersection| of the two top-5 index sets.
    inter = 0
    a = 0
    while a < K
      ai = bf[a]
      b = 0
      while b < K
        if iv[b] == ai
          inter &+= 1
          break
        end
        b &+= 1
      end
      a &+= 1
    end

    histogram[inter] &+= 1
    recall = inter / K.to_f
    total_recall += recall
    perfect      += 1 if inter == K
    partial      += 1 if inter > 0 && inter < K
    worst_recall = recall if recall < worst_recall

    if (i + 1) % 100 == 0
      STDERR.puts "[recall] #{i + 1}/#{N_QUERY} avg=#{(total_recall / (i + 1)).round(4)} " \
                  "perfect=#{perfect} worst=#{worst_recall.round(2)}"
      STDERR.flush
    end
  end

  avg = total_recall / N_QUERY
  puts ""
  puts "================ RESULTS (TODO #1: IVF recall) ================"
  puts "samples           : #{N_QUERY}"
  puts "nprobe            : #{NPROBE} (k=#{REFS.k})"
  puts "recall@5 (mean)   : #{avg.round(6)}"
  puts "perfect (5/5)     : #{perfect}/#{N_QUERY} (#{(perfect * 100.0 / N_QUERY).round(2)}%)"
  puts "partial (1..4/5)  : #{partial}/#{N_QUERY} (#{(partial * 100.0 / N_QUERY).round(2)}%)"
  puts "worst recall      : #{worst_recall}"
  puts "histogram (#match): " + 6.times.map { |b| "#{b}=#{histogram[b]}" }.join(" ")
  puts ""
  puts "timing/query (ms) : brute=#{(bf_total_ms / N_QUERY).round(2)} " \
       "ivf=#{(ivf_total_ms / N_QUERY).round(2)} " \
       "speedup=#{(bf_total_ms / ivf_total_ms).round(1)}x"
  puts "verdict           : " + (avg >= 0.95 ? "OK (>= 0.95)" : "BELOW TARGET (< 0.95) — tune nprobe/k")
end
