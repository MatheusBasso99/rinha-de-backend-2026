require "./references"

module RinhaDeBackend
  # Builds an IVF (Inverted File) index over the reference dataset.
  # Run once at Docker build time; the resulting reordering, centroids
  # and cell offsets are serialized into references.bin and mmapped by
  # the runtime.
  #
  # Algorithm: full-batch k-means with random (Forgy) init, fixed seed,
  # `ITERATIONS` full passes. Centroids are kept in Float64 during
  # iteration for precision and quantized back to Int16 (same scale as
  # the vectors) at the end so query-time distances stay in the
  # integer fast path.
  class IvfBuilder
    DEFAULT_K          = 2048
    DEFAULT_ITERATIONS =   12
    DEFAULT_SEED       =   42_u64

    record Result,
      vectors : Slice(Int16),         # count * dims, reordered by cell
      labels : Slice(UInt8),          # count, reordered by cell
      centroids : Slice(Int16),       # k * dims, quantized in vector scale
      cell_offsets : Slice(UInt32),   # k+1 entries; cell c spans [off[c]..off[c+1])
      cell_radius : Slice(UInt32),    # k entries; max non-squared L2 distance
                                      # from quantized centroid c to any vector
                                      # in cell c (ceil). Used at query time for
                                      # triangle-inequality pruning.
      max_cell_radius : UInt32,       # max(cell_radius) — global outer-break bound
      bbox_min : Slice(Int16),        # k * dims; per-cell axis-aligned bounding
                                      # box minimum per dimension.
      bbox_max : Slice(Int16)         # k * dims; per-cell axis-aligned bounding
                                      # box maximum per dimension.

    def self.build(vectors : Slice(Int16),
                   labels : Slice(UInt8),
                   count : Int32,
                   dims : Int32,
                   k : Int32 = DEFAULT_K,
                   iterations : Int32 = DEFAULT_ITERATIONS,
                   seed : UInt64 = DEFAULT_SEED) : Result
      raise "k must be >= 1" if k < 1
      raise "k (#{k}) > count (#{count})" if k > count

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

      # Cell sizes → cumulative offsets.
      cell_sizes = Slice(Int32).new(k, 0)
      i = 0
      while i < count
        cell_sizes[assignments[i]] += 1
        i += 1
      end

      cell_offsets = Slice(UInt32).new(k + 1, 0_u32)
      acc = 0_u32
      c = 0
      while c < k
        cell_offsets[c] = acc
        acc += cell_sizes[c].to_u32
        c += 1
      end
      cell_offsets[k] = acc

      # Reorder vectors and labels by cell.
      reordered_vectors = Slice(Int16).new(count * dims, 0_i16)
      reordered_labels  = Slice(UInt8).new(count, 0_u8)
      cursor = Slice(UInt32).new(k, 0_u32)

      i = 0
      while i < count
        cell = assignments[i]
        pos = (cell_offsets[cell] + cursor[cell]).to_i32
        cursor[cell] += 1_u32

        target = pos * dims
        source = i * dims
        d = 0
        while d < dims
          reordered_vectors[target + d] = vectors[source + d]
          d += 1
        end
        reordered_labels[pos] = labels[i]
        i += 1
      end

      # Quantize centroids back to Int16.
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

      # Compute per-cell radius using the quantized centroids and reordered
      # vectors — the exact same Int16 → Int32 → Int64 math the runtime uses.
      # Radius is stored *non-squared* (ceil of the integer sqrt) so the
      # query-time check needs only one sqrt per probed cell, not one per
      # vector in the cell.
      #
      # Same loop also computes the per-cell axis-aligned bounding box:
      # bbox_min[c][j] / bbox_max[c][j] = min/max of vec[i][j] over all
      # vectors `i` in cell `c`. Used at query time to skip a cell when
      # the squared distance from query to its bbox already exceeds the
      # current top-5 worst (exact pruning).
      cell_radius = Slice(UInt32).new(k, 0_u32)
      bbox_min    = Slice(Int16).new(k * dims, 0_i16)
      bbox_max    = Slice(Int16).new(k * dims, 0_i16)
      max_cell_radius = 0_u32
      c = 0
      while c < k
        c_off = c * dims
        start = cell_offsets[c].to_i32
        stop  = cell_offsets[c + 1].to_i32
        max_sq = 0_i64

        # Initialize the bbox to the first vector (or sentinel-safe values
        # if the cell is empty so the box never matches any query). For
        # the empty case we pin the pad lanes (indices LOGICAL_DIMS..dims)
        # to 0 so a zero-padded query also lands inside [lo, hi] = [0, 0]
        # and contributes 0 — keeping the bbox check exact across pad.
        if start < stop
          v_off = start * dims
          j = 0
          while j < dims
            v = reordered_vectors[v_off + j]
            bbox_min[c_off + j] = v
            bbox_max[c_off + j] = v
            j += 1
          end
        else
          j = 0
          while j < References::LOGICAL_DIMS
            bbox_min[c_off + j] = Int16::MAX
            bbox_max[c_off + j] = Int16::MIN
            j += 1
          end
          while j < dims
            bbox_min[c_off + j] = 0_i16
            bbox_max[c_off + j] = 0_i16
            j += 1
          end
        end

        i = start
        while i < stop
          v_off = i * dims
          d = 0_i64
          j = 0
          while j < dims
            v = reordered_vectors[v_off + j]
            diff = v.to_i32 - centroids_i16[c_off + j].to_i32
            d &+= (diff &* diff).to_i64
            bbox_min[c_off + j] = v if v < bbox_min[c_off + j]
            bbox_max[c_off + j] = v if v > bbox_max[c_off + j]
            j &+= 1
          end
          max_sq = d if d > max_sq
          i &+= 1
        end
        # ceil(sqrt(max_sq)) — keep the bound conservative so we never skip
        # a cell that could legitimately contain a top-K candidate.
        r = Math.sqrt(max_sq.to_f64).ceil.to_u32
        cell_radius[c] = r
        max_cell_radius = r if r > max_cell_radius
        c += 1
      end

      Result.new(reordered_vectors, reordered_labels, centroids_i16,
                 cell_offsets, cell_radius, max_cell_radius,
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
