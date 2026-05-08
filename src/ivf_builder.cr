require "./references"

module RinhaDeBackend
  # Builds an IVF (Inverted File) index over the reference dataset.
  # Run once at Docker build time; the resulting reordering, centroids
  # and block-major layout are serialized into references.bin and
  # mmapped by the runtime.
  #
  # Algorithm: full-batch k-means with k-means++ init, fixed seed,
  # `ITERATIONS` full passes. Centroids are kept in Float64 during
  # iteration for precision and quantized back to Int16 (same scale as
  # the vectors) at the end so query-time distances stay in the
  # integer fast path.
  #
  # Output layout (RNH7): each cell's vectors are written in AOSOA-8
  # dim-interleaved blocks of 8 vectors. A block has
  # `LOGICAL_DIMS × SLOTS_PER_BLOCK = 14 × 8 = 112` Int16 lanes
  # (224 B). Within a block, lanes are
  # `[d0_v0..d0_v7, d1_v0..d1_v7, ..., d13_v0..d13_v7]` so the runtime
  # scan can load 8 i16 of one dim with a single VPMOVSXWD ymm and
  # produce 8 partial squared distances per dim instead of 1 per row.
  class IvfBuilder
    DEFAULT_K          = 2048
    DEFAULT_ITERATIONS =   12
    DEFAULT_SEED       =   42_u64

    # Sentinel lane value used by pad slots inserted to fill out an
    # odd-sized cell's last block (or to pad a whole alignment block
    # when a cell ends on an odd block index). Any query lane lives in
    # [-10_000, 10_000]; `(query - Int16::MAX)²` per lane × 14 logical
    # dims dominates any real worst-case L2², so a pad slot can never
    # enter the top-5 ranking and the kernel is free to scan it.
    PAD_SENTINEL = Int16::MAX

    record Result,
      blocks : Slice(Int16),          # block_count * BLOCK_LANES, dim-
                                      # interleaved (8 vectors per block)
      labels : Slice(UInt8),          # block_count * SLOTS_PER_BLOCK,
                                      # slot-major. Pad slots carry label 0
                                      # (irrelevant since they never enter
                                      # top-5).
      block_count : Int32,            # total blocks (incl. alignment pads)
      padded_count : Int32,           # = block_count * SLOTS_PER_BLOCK
      centroids : Slice(Int16),       # k * DIMS (stride 16, 14 logical +
                                      # 2 zero pad — keeps centroid scan on
                                      # VPMADDWD)
      cell_offsets : Slice(UInt32),   # k+1 entries; cell c spans block
                                      # range [off[c]..off[c+1]) with off[c]
                                      # always even (= 64 B aligned). The
                                      # range may include a single all-pad
                                      # alignment block at off[c+1]-1 when
                                      # the cell's real block count is odd.
      cell_radius : Slice(UInt32),    # k entries; max non-squared L2
                                      # distance from quantized centroid c
                                      # to any vector in cell c (ceil).
                                      # Computed over real rows only.
      max_cell_radius : UInt32,       # max(cell_radius) — global outer
                                      # break bound
      bbox_min : Slice(Int16),        # k * DIMS; per-cell axis-aligned
                                      # bounding box minimum per dim.
                                      # Computed over real rows only.
      bbox_max : Slice(Int16)         # k * DIMS; per-cell axis-aligned
                                      # bounding box maximum per dim.
                                      # Computed over real rows only.

    def self.build(vectors : Slice(Int16),
                   labels : Slice(UInt8),
                   count : Int32,
                   dims : Int32,
                   k : Int32 = DEFAULT_K,
                   iterations : Int32 = DEFAULT_ITERATIONS,
                   seed : UInt64 = DEFAULT_SEED) : Result
      raise "k must be >= 1" if k < 1
      raise "k (#{k}) > count (#{count})" if k > count
      raise "dims (#{dims}) != References::DIMS (#{References::DIMS})" unless dims == References::DIMS

      logical_dims    = References::LOGICAL_DIMS
      slots_per_block = References::SLOTS_PER_BLOCK
      block_lanes     = References::BLOCK_LANES

      centroids = Slice(Float64).new(k * dims, 0.0)
      assignments = Slice(Int32).new(count, 0)

      init_kmeans_plus_plus!(centroids, vectors, count, dims, k, seed)

      iterations.times do |iter|
        t0 = Time.instant
        assign_all!(centroids, vectors, count, dims, k, assignments)
        t1 = Time.instant
        non_empty = update_centroids!(centroids, vectors, count, dims, k, assignments)
        t2 = Time.instant
        STDERR.puts "[ivf] iter #{iter + 1}/#{iterations} " \
                    "assign=#{(t1 - t0).total_seconds.round(2)}s " \
                    "update=#{(t2 - t1).total_seconds.round(2)}s " \
                    "non_empty_cells=#{non_empty}/#{k}"
        STDERR.flush
      end

      # Final assignment after the last centroid move.
      assign_all!(centroids, vectors, count, dims, k, assignments)

      # Cell sizes from final assignment.
      cell_sizes = Slice(Int32).new(k, 0)
      i = 0
      while i < count
        cell_sizes[assignments[i]] += 1
        i += 1
      end

      # Compute per-cell block layout.
      #
      # Per cell c:
      #   real_blocks_c = ceil(cell_sizes[c] / 8)         # blocks needed for the data
      #   total_blocks_c = real_blocks_c rounded UP to even (= alignment pad)
      #
      # Even total_blocks_c keeps each cell's start at an even global
      # block index — i.e., 64 B aligned for the first byte of the
      # block (block size 224 B; even index ⇒ offset is a multiple of
      # 448 B, which is 64 B-aligned). The optional trailing alignment
      # block is filled entirely with `PAD_SENTINEL` so the runtime
      # scan can iterate the cell's full block range without bounds
      # checks.
      cell_offsets = Slice(UInt32).new(k + 1, 0_u32)
      acc = 0_u32
      c = 0
      while c < k
        cell_offsets[c] = acc
        real_blocks = (cell_sizes[c] + slots_per_block - 1) // slots_per_block
        # Round up to even so the next cell starts at an even block index.
        total_blocks = (real_blocks + 1) & ~1
        acc &+= total_blocks.to_u32
        c += 1
      end
      cell_offsets[k] = acc
      block_count  = acc.to_i32
      padded_count = block_count * slots_per_block

      # Allocate output layout. Initialize to `PAD_SENTINEL` so that any
      # slot we don't touch (last-block tail pads + alignment-pad blocks)
      # already holds the sentinel.
      blocks_buf = Slice(Int16).new(block_count * block_lanes, PAD_SENTINEL)
      labels_buf = Slice(UInt8).new(padded_count, 0_u8)

      # Cursor: how many real vectors of cell c have been placed so far.
      cursor = Slice(Int32).new(k, 0)

      # Scratch: index of the row inside the cell. We need the per-cell
      # ordering up front so we can compute (block_in_cell, slot) from a
      # per-cell counter. Walk the input vectors twice: first pass builds
      # `cell_offsets`/`cell_sizes` (already done above), second pass
      # places each vector into its cell's blocks.
      i = 0
      while i < count
        cell        = assignments[i]
        local_idx   = cursor[cell]
        cursor[cell] = local_idx + 1
        block_in_cell = local_idx // slots_per_block
        slot          = local_idx - block_in_cell * slots_per_block

        global_block  = cell_offsets[cell].to_i32 + block_in_cell
        block_origin  = global_block * block_lanes
        # Dim-interleaved write: dim d, slot s lives at
        # `block_origin + d * slots_per_block + s`.
        src = i * dims
        d = 0
        while d < logical_dims
          blocks_buf[block_origin + d * slots_per_block + slot] = vectors[src + d]
          d += 1
        end
        labels_buf[global_block * slots_per_block + slot] = labels[i]
        i += 1
      end

      # Pad-sentinel sweep is unnecessary for tail slots / alignment
      # blocks because the slice was initialized to `PAD_SENTINEL`. Real
      # writes only overwrite real-vector slots, leaving the rest at
      # sentinel.

      # Quantize centroids back to Int16 (stride 16; pad lanes 14, 15
      # remain zero from the centroids buffer initializer above — wait,
      # the Float64 buffer is zero-initialized, but we never wrote pad
      # lanes there because k-means only touched j < dims. Pad lanes
      # are at j=14, 15 and we DID touch them via `j < dims` (= 16) —
      # but the input vectors had pad lanes 0, so the Float64 sums for
      # pad lanes are 0, divided by count = 0. Quantized to 0_i16. Good.
      centroids_i16 = Slice(Int16).new(k * dims, 0_i16)
      n = k * dims
      j = 0
      while j < n
        v = centroids[j].round
        v = Int16::MIN.to_f if v < Int16::MIN.to_f
        v = Int16::MAX.to_f if v > Int16::MAX.to_f
        centroids_i16[j] = v.to_i16
        j += 1
      end

      # Per-cell radius and bbox (over real vectors only — pad sentinels
      # would torpedo every triangle / bbox prune). We iterate the
      # original vector slice + assignments to avoid having to walk the
      # block-major layout backwards.
      cell_radius = Slice(UInt32).new(k, 0_u32)
      bbox_min    = Slice(Int16).new(k * dims, 0_i16)
      bbox_max    = Slice(Int16).new(k * dims, 0_i16)
      max_cell_radius = 0_u32

      # Initialize bbox: empty cells get a sentinel-safe box that no
      # query can land inside (lo=MAX, hi=MIN per logical dim; pad lanes
      # stay 0 so a zero-padded query contributes 0). Non-empty cells
      # are seeded from the first vector encountered.
      empty_marked = Slice(UInt8).new(k, 1_u8)
      c = 0
      while c < k
        c_off = c * dims
        j = 0
        while j < References::LOGICAL_DIMS
          bbox_min[c_off + j] = Int16::MAX
          bbox_max[c_off + j] = Int16::MIN
          j += 1
        end
        # Pad lanes 14..15 stay 0 (Slice initializer).
        c += 1
      end

      # Walk all real vectors once; update bbox and max-radius² per cell.
      # Per-cell max squared distance kept in a scratch Slice(Int64).
      cell_max_sq = Slice(Int64).new(k, 0_i64)
      i = 0
      while i < count
        cell  = assignments[i]
        c_off = cell * dims
        v_off = i * dims
        empty_marked[cell] = 0_u8

        d = 0_i64
        j = 0
        while j < dims
          v = vectors[v_off + j]
          # bbox over all 16 lanes (pad lanes are 0 in input → 0 in box).
          bbox_min[c_off + j] = v if v < bbox_min[c_off + j]
          bbox_max[c_off + j] = v if v > bbox_max[c_off + j]
          diff = v.to_i32 - centroids_i16[c_off + j].to_i32
          d &+= (diff &* diff).to_i64
          j &+= 1
        end
        cell_max_sq[cell] = d if d > cell_max_sq[cell]
        i &+= 1
      end

      # Convert cell_max_sq → cell_radius (ceil(sqrt)) and zero out bbox
      # of cells that never received a vector (lo=MAX, hi=MIN per logical
      # dim already from init — keep them; they reject every query).
      c = 0
      while c < k
        if empty_marked[c] != 0_u8
          # Empty cell: bbox already at sentinel; radius irrelevant.
          c += 1
          next
        end
        r = Math.sqrt(cell_max_sq[c].to_f64).ceil.to_u32
        cell_radius[c] = r
        max_cell_radius = r if r > max_cell_radius
        c += 1
      end

      Result.new(blocks_buf, labels_buf, block_count, padded_count,
                 centroids_i16, cell_offsets, cell_radius, max_cell_radius,
                 bbox_min, bbox_max)
    end

    # k-means++ initialization (F1.2): D²-weighted seeding. Tighter
    # cluster boundaries than plain Forgy → queries land in the right
    # cell more often, recall@5 climbs without runtime cost (the extra
    # work runs once at Docker build time).
    #
    # Inner distance loop matches the runtime IVF kernel: Int16 lanes
    # widened to Int32, squared and summed in Int64, no Float64. The
    # 16-lane row stride enables the same vpmaddwd codegen path.
    # min_d2 stores the squared L² in Int64 (max per-row L² ≈ 5.6 × 10⁹,
    # cumulative sum across 3M rows ≈ 1.7 × 10¹⁶ — fits in Int64).
    private def self.init_kmeans_plus_plus!(centroids : Slice(Float64),
                                            vectors : Slice(Int16),
                                            count : Int32,
                                            dims : Int32,
                                            k : Int32,
                                            seed : UInt64) : Nil
      rng = Random.new(seed)
      min_d2 = Slice(Int64).new(count, Int64::MAX)

      first_idx = rng.rand(count)
      copy_vec_to_centroid(vectors, first_idx, centroids, 0, dims)
      update_min_d2!(min_d2, vectors, count, dims, vectors, first_idx)

      c = 1
      while c < k
        total = 0_i64
        i = 0
        while i < count
          total &+= min_d2[i]
          i &+= 1
        end

        # Degenerate guard: if every point coincides with an already-
        # picked center (only possible when k > unique_vectors), fall
        # back to a uniform draw so the loop still terminates.
        if total <= 0
          picked = rng.rand(count)
        else
          threshold = rng.rand * total.to_f64
          running = 0_i64
          picked = count - 1
          i = 0
          while i < count
            running &+= min_d2[i]
            if running.to_f64 >= threshold
              picked = i
              break
            end
            i &+= 1
          end
        end

        copy_vec_to_centroid(vectors, picked, centroids, c, dims)
        update_min_d2!(min_d2, vectors, count, dims, vectors, picked)

        if (c & 0x7F) == 0
          STDERR.puts "[ivf] kmeans++ seeded #{c}/#{k}"
          STDERR.flush
        end
        c += 1
      end
    end

    private def self.copy_vec_to_centroid(vectors : Slice(Int16),
                                          src_idx : Int32,
                                          centroids : Slice(Float64),
                                          dst_idx : Int32,
                                          dims : Int32) : Nil
      src = src_idx * dims
      dst = dst_idx * dims
      j = 0
      while j < dims
        centroids[dst + j] = vectors[src + j].to_f64
        j += 1
      end
    end

    # Update min_d2[i] := min(min_d2[i], ‖vectors[i] - ref_vectors[ref_idx]‖²).
    # Same Int16→Int32→Int64 squared-L² shape as the runtime IVF kernel
    # so LLVM lowers it to vpmaddwd ymm under --mcpu=haswell.
    private def self.update_min_d2!(min_d2 : Slice(Int64),
                                    vectors : Slice(Int16),
                                    count : Int32,
                                    dims : Int32,
                                    ref_vectors : Slice(Int16),
                                    ref_idx : Int32) : Nil
      ref_off = ref_idx * dims
      i = 0
      while i < count
        v_off = i * dims
        d = 0_i64
        j = 0
        while j < dims
          diff = vectors[v_off + j].to_i32 &- ref_vectors[ref_off + j].to_i32
          d &+= (diff &* diff).to_i64
          j &+= 1
        end
        min_d2[i] = d if d < min_d2[i]
        i &+= 1
      end
    end

    # For each vector, find the nearest centroid. Inner loop has an
    # early-exit on the partial sum exceeding the current best.
    private def self.assign_all!(centroids : Slice(Float64),
                                 vectors : Slice(Int16),
                                 count : Int32,
                                 dims : Int32,
                                 k : Int32,
                                 assignments : Slice(Int32)) : Nil
      cent_ptr = centroids.to_unsafe
      vec_ptr  = vectors.to_unsafe
      asn_ptr  = assignments.to_unsafe

      i = 0
      while i < count
        v_off = i * dims
        best_d = Float64::INFINITY
        best_c = 0

        c = 0
        while c < k
          c_off = c * dims
          d = 0.0
          j = 0
          while j < dims
            diff = vec_ptr[v_off + j].to_f64 - cent_ptr[c_off + j]
            d += diff * diff
            break if d >= best_d
            j += 1
          end
          if d < best_d
            best_d = d
            best_c = c
          end
          c += 1
        end

        asn_ptr[i] = best_c
        i += 1
      end
    end

    # Recompute each centroid as the mean of its assigned vectors.
    # Empty cells are left untouched (they keep their previous position).
    # Returns the number of non-empty cells (informational).
    private def self.update_centroids!(centroids : Slice(Float64),
                                       vectors : Slice(Int16),
                                       count : Int32,
                                       dims : Int32,
                                       k : Int32,
                                       assignments : Slice(Int32)) : Int32
      sums = Slice(Float64).new(k * dims, 0.0)
      counts = Slice(Int32).new(k, 0)

      i = 0
      while i < count
        cell = assignments[i]
        counts[cell] += 1
        v_off = i * dims
        s_off = cell * dims
        j = 0
        while j < dims
          sums[s_off + j] += vectors[v_off + j].to_f64
          j += 1
        end
        i += 1
      end

      non_empty = 0
      c = 0
      while c < k
        n = counts[c]
        if n > 0
          c_off = c * dims
          inv = 1.0 / n
          j = 0
          while j < dims
            centroids[c_off + j] = sums[c_off + j] * inv
            j += 1
          end
          non_empty += 1
        end
        c += 1
      end

      non_empty
    end
  end
end
