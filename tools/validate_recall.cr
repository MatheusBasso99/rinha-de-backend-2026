require "../src/references"

# Validate IVF recall vs brute-force.
#
# Samples N vectors from the mmapped references.bin, computes brute-force
# top-5 (over the full 3M Int16 dataset, walking the AOSOA-8 block layout)
# and IVF top-5 (with nprobe=16), reports recall@5 = |intersection| / 5
# averaged across the sample.
#
# Indices returned by both functions are GLOBAL SLOT INDICES
# (block_idx * 8 + slot). Pad slots / alignment-pad blocks carry
# `IvfBuilder::PAD_SENTINEL` per lane, so they cannot enter top-5 against
# any production-shaped query — the comparison stays exact.
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

  SLOTS_PER_BLOCK = References::SLOTS_PER_BLOCK
  LOGICAL_DIMS    = References::LOGICAL_DIMS
  BLOCK_LANES     = References::BLOCK_LANES

  # Brute-force top-K returning global slot indices (sorted by distance asc).
  # Walks the AOSOA-8 block layout: 8 partial sums per block, dim-interleaved.
  def self.brute_topk(query : Slice(Int16),
                      blocks : Slice(Int16),
                      block_count : Int32) : StaticArray(Int32, 5)
    best_dist = StaticArray(Int64, 5).new(Int64::MAX)
    best_idx  = StaticArray(Int32, 5).new(-1)
    worst = Int64::MAX

    blk_ptr   = blocks.to_unsafe
    query_ptr = query.to_unsafe

    b = 0
    while b < block_count
      block_origin = b &* BLOCK_LANES
      partial = StaticArray(Int64, 8).new(0_i64)

      d = 0
      while d < LOGICAL_DIMS
        base = d &* SLOTS_PER_BLOCK
        qd = query_ptr[d].to_i32
        s = 0
        while s < SLOTS_PER_BLOCK
          diff = blk_ptr[block_origin &+ base &+ s].to_i32 &- qd
          partial[s] &+= (diff &* diff).to_i64
          s &+= 1
        end
        d &+= 1
      end

      slot_global_base = b &* SLOTS_PER_BLOCK
      slot = 0
      while slot < SLOTS_PER_BLOCK
        dst = partial[slot]
        if dst < worst
          ins = K - 1
          while ins > 0 && best_dist[ins &- 1] > dst
            best_dist[ins] = best_dist[ins &- 1]
            best_idx[ins]  = best_idx[ins &- 1]
            ins &-= 1
          end
          best_dist[ins] = dst
          best_idx[ins]  = slot_global_base &+ slot
          worst = best_dist[K &- 1]
        end
        slot &+= 1
      end

      b &+= 1
    end

    best_idx
  end

  # IVF top-K returning global slot indices (top-K within the union of
  # the nearest `nprobe` cells). Mirrors src/ivf.cr structure but stores
  # indices, not labels.
  def self.ivf_topk(query : Slice(Int16),
                    refs : References,
                    nprobe : Int32) : StaticArray(Int32, 5)
    blocks       = refs.blocks
    centroids    = refs.centroids
    cell_offsets = refs.cell_offsets
    k            = refs.k

    blk_ptr   = blocks.to_unsafe
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
      start_block = cell_offsets[cell].to_i32
      stop_block  = cell_offsets[cell &+ 1].to_i32

      b = start_block
      while b < stop_block
        block_origin = b &* BLOCK_LANES
        partial = StaticArray(Int64, 8).new(0_i64)

        d = 0
        while d < LOGICAL_DIMS
          base = d &* SLOTS_PER_BLOCK
          qd = query_ptr[d].to_i32
          s = 0
          while s < SLOTS_PER_BLOCK
            diff = blk_ptr[block_origin &+ base &+ s].to_i32 &- qd
            partial[s] &+= (diff &* diff).to_i64
            s &+= 1
          end
          d &+= 1
        end

        slot_global_base = b &* SLOTS_PER_BLOCK
        slot = 0
        while slot < SLOTS_PER_BLOCK
          dst = partial[slot]
          if dst < worst
            ins = K &- 1
            while ins > 0 && best_dist[ins &- 1] > dst
              best_dist[ins] = best_dist[ins &- 1]
              best_idx[ins]  = best_idx[ins &- 1]
              ins &-= 1
            end
            best_dist[ins] = dst
            best_idx[ins]  = slot_global_base &+ slot
            worst = best_dist[K &- 1]
          end
          slot &+= 1
        end

        b &+= 1
      end

      p &+= 1
    end

    best_idx
  end

  # Pull a query out of slot `idx` within the AOSOA-8 block layout.
  # `idx` is a global slot index = block_idx * 8 + slot_in_block.
  def self.read_slot(blocks : Slice(Int16), idx : Int32, out_buf : Slice(Int16)) : Nil
    block_idx = idx // SLOTS_PER_BLOCK
    slot      = idx - block_idx * SLOTS_PER_BLOCK
    block_origin = block_idx * BLOCK_LANES
    j = 0
    while j < LOGICAL_DIMS
      out_buf[j] = blocks[block_origin + j * SLOTS_PER_BLOCK + slot]
      j += 1
    end
    while j < DIMS
      out_buf[j] = 0_i16
      j += 1
    end
  end

  # Sample slot indices, biased to skip pad slots (cells with sparse
  # last block / alignment pads). We pick a random global slot, then
  # check the first lane: if it's `Int16::MAX` we redraw. Pads are at
  # most ~k * 8 / total_slots ≪ 1% so this is statistically cheap.
  def self.sample_real_slot(blocks : Slice(Int16), padded_count : Int32, rng : Random) : Int32
    loop do
      idx = rng.rand(padded_count)
      block_idx = idx // SLOTS_PER_BLOCK
      slot      = idx - block_idx * SLOTS_PER_BLOCK
      lane0 = blocks[block_idx * BLOCK_LANES + slot] # dim 0 lane for this slot
      return idx unless lane0 == Int16::MAX
    end
  end

  # ----- Main -----
  jitter = (ENV["JITTER"]? || "0").to_i

  rng = Random.new(SEED)
  query_buf = Slice(Int16).new(DIMS, 0_i16)

  total_recall    = 0.0
  perfect         = 0
  partial         = 0
  worst_recall    = 1.0
  histogram       = StaticArray(Int32, 6).new(0)
  bf_total_ms     = 0.0
  ivf_total_ms    = 0.0

  N_QUERY.times do |i|
    idx = sample_real_slot(REFS.blocks, REFS.padded_count, rng)
    read_slot(REFS.blocks, idx, query_buf)

    if jitter > 0
      j = 0
      while j < References::LOGICAL_DIMS
        v = query_buf[j].to_i32
        v += rng.rand(-jitter..jitter)
        v = Int16::MIN.to_i32 if v < Int16::MIN
        v = Int16::MAX.to_i32 if v > Int16::MAX
        query_buf[j] = v.to_i16
        j += 1
      end
    end

    t0 = Time.instant
    bf = brute_topk(query_buf, REFS.blocks, REFS.block_count)
    t1 = Time.instant
    iv = ivf_topk(query_buf, REFS, NPROBE)
    t2 = Time.instant

    bf_total_ms  += (t1 - t0).total_milliseconds
    ivf_total_ms += (t2 - t1).total_milliseconds

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
