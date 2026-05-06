require "../src/references"
require "../src/ivf"

# Verifies that the cell-pruning optimizations in `Ivf` (triangle-inequality
# per-cell skip + max_cell_radius outer break) preserve the exact same
# fraud-count answer as the *unpruned* IVF reference inlined below. Both
# scan the same nprobe cells over the full 3M dataset; the only difference
# is whether the per-cell triangle bound and outer break are honored.
#
# Comparing against unpruned IVF (rather than brute-force) isolates the
# effect of the new pruning from the pre-existing IVF-vs-brute-force gap
# (TODO #1 documented recall@5 = 0.9966 on jittered queries).
#
# Usage: crystal run --release tools/validate_pruning.cr -- [N] [SEED] [JITTER]

module RinhaDeBackend
  REFS    = References.mmap
  IVF     = Ivf.new(REFS)
  N_QUERY = (ARGV[0]? || "200").to_i
  SEED    = (ARGV[1]? || "1337").to_u64
  JITTER  = (ARGV[2]? || "0").to_i
  K       = 5

  BASE_NPROBE  = Ivf::DEFAULT_BASE_NPROBE
  RETRY_NPROBE = Ivf::DEFAULT_RETRY_NPROBE

  # Unpruned reference: identical phase / boundary-retry structure as
  # `Ivf#fraud_count_top_k`, but without the per-cell triangle-inequality
  # skip, without the per-cell bbox skip, and without the decision-aware
  # outer break. Comparing pruned vs unpruned with the same retry policy
  # isolates the effect of the cell-pruning skips from the retry logic.
  def self.fraud_count_unpruned(query : StaticArray(Int16, 14)) : Int32
    vectors      = REFS.vectors
    labels       = REFS.labels
    centroids    = REFS.centroids
    cell_offsets = REFS.cell_offsets
    k            = REFS.k
    base_nprobe  = BASE_NPROBE
    retry_nprobe = RETRY_NPROBE
    total_nprobe = base_nprobe + retry_nprobe
    dims         = References::DIMS

    vec_ptr   = vectors.to_unsafe
    lab_ptr   = labels.to_unsafe
    cent_ptr  = centroids.to_unsafe
    query_ptr = query.to_unsafe

    probe_dist  = StaticArray(Int64, 32).new(Int64::MAX)
    probe_cell  = StaticArray(Int32, 32).new(0)
    worst_probe = Int64::MAX

    c = 0
    while c < k
      c_off = c * dims
      d = 0_i64
      j = 0
      while j < dims
        diff = query_ptr[j].to_i32 - cent_ptr[c_off + j].to_i32
        d &+= (diff &* diff).to_i64
        j &+= 1
      end

      if d < worst_probe
        slot = total_nprobe &- 1
        while slot > 0 && probe_dist[slot &- 1] > d
          probe_dist[slot] = probe_dist[slot &- 1]
          probe_cell[slot] = probe_cell[slot &- 1]
          slot &-= 1
        end
        probe_dist[slot] = d
        probe_cell[slot] = c
        worst_probe = probe_dist[total_nprobe &- 1]
      end

      c &+= 1
    end

    best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
    best_label = StaticArray(UInt8, 5).new(0_u8)
    worst = Int64::MAX

    probe_start = 0
    probe_end   = base_nprobe
    phase = 0

    while true
      p = probe_start
      while p < probe_end
        cell  = probe_cell[p]
        start = cell_offsets[cell].to_i32
        stop  = cell_offsets[cell &+ 1].to_i32

        i = start
        while i < stop
          off = i * dims
          d = 0_i64
          j = 0
          while j < dims
            diff = query_ptr[j].to_i32 - vec_ptr[off + j].to_i32
            d &+= (diff &* diff).to_i64
            break if d >= worst
            j &+= 1
          end

          if d < worst
            slot = K &- 1
            while slot > 0 && best_dist[slot &- 1] > d
              best_dist[slot]  = best_dist[slot &- 1]
              best_label[slot] = best_label[slot &- 1]
              slot &-= 1
            end
            best_dist[slot]  = d
            best_label[slot] = lab_ptr[i]
            worst = best_dist[K &- 1]
          end

          i &+= 1
        end

        p &+= 1
      end

      break if phase == 1 || retry_nprobe == 0

      frauds_now = 0
      kk = 0
      while kk < K
        frauds_now &+= 1 if best_label[kk] == References::LABEL_FRAUD
        kk &+= 1
      end

      break unless frauds_now == 2 || frauds_now == 3
      probe_start = base_nprobe
      probe_end   = total_nprobe
      phase = 1
    end

    frauds = 0
    kk = 0
    while kk < K
      frauds &+= 1 if best_label[kk] == References::LABEL_FRAUD
      kk &+= 1
    end
    frauds
  end

  STDERR.puts "[prune] count=#{REFS.count} k=#{REFS.k} max_cell_radius=#{REFS.max_cell_radius} base=#{BASE_NPROBE} retry=#{RETRY_NPROBE} samples=#{N_QUERY} seed=#{SEED} jitter=#{JITTER}"
  STDERR.flush

  rng = Random.new(SEED)
  agree = 0
  disagree = 0
  flips = 0
  pruned_ms = 0.0
  unpruned_ms = 0.0

  N_QUERY.times do |i|
    idx = rng.rand(REFS.count)
    src = idx * References::DIMS

    query = StaticArray(Int16, 14).new(0_i16)
    j = 0
    while j < References::DIMS
      v = REFS.vectors[src + j].to_i32
      if JITTER > 0
        v += rng.rand(-JITTER..JITTER)
        v = Int16::MIN.to_i32 if v < Int16::MIN
        v = Int16::MAX.to_i32 if v > Int16::MAX
      end
      query[j] = v.to_i16
      j += 1
    end

    t0 = Time.instant
    pruned = IVF.fraud_count_top_k(query)
    t1 = Time.instant
    unpruned = fraud_count_unpruned(query)
    t2 = Time.instant

    pruned_ms   += (t1 - t0).total_milliseconds
    unpruned_ms += (t2 - t1).total_milliseconds

    if pruned == unpruned
      agree += 1
    else
      disagree += 1
      pruned_dec   = pruned   >= 3
      unpruned_dec = unpruned >= 3
      flips += 1 if pruned_dec != unpruned_dec
      STDERR.puts "[prune] mismatch idx=#{idx} pruned=#{pruned} unpruned=#{unpruned} flip=#{pruned_dec != unpruned_dec}" if disagree <= 10
    end

    if (i + 1) % 100 == 0
      STDERR.puts "[prune] #{i + 1}/#{N_QUERY} agree=#{agree} disagree=#{disagree} flips=#{flips}"
      STDERR.flush
    end
  end

  puts ""
  puts "================ RESULTS (TODO #2/3: cell pruning preserves exact IVF) ================"
  puts "samples            : #{N_QUERY}"
  puts "jitter             : #{JITTER}"
  puts "fraud-count agree  : #{agree}/#{N_QUERY} (#{(agree * 100.0 / N_QUERY).round(2)}%)"
  puts "decision flips     : #{flips}/#{N_QUERY}"
  puts ""
  puts "timing/query (ms)  : pruned=#{(pruned_ms / N_QUERY).round(3)} " \
       "unpruned=#{(unpruned_ms / N_QUERY).round(3)} " \
       "speedup=#{(unpruned_ms / pruned_ms).round(2)}x"
  puts "verdict            : " + (disagree == 0 ? "EXACT (pruning preserves answer)" : "DRIFT — investigate")
end
