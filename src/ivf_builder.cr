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
    DEFAULT_K          = 1024
    DEFAULT_ITERATIONS =    5
    DEFAULT_SEED       =   42_u64

    record Result,
      vectors : Slice(Int16),         # count * dims, reordered by cell
      labels : Slice(UInt8),          # count, reordered by cell
      centroids : Slice(Int16),       # k * dims, quantized in vector scale
      cell_offsets : Slice(UInt32)    # k+1 entries; cell c spans [off[c]..off[c+1])

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

      init_random!(centroids, vectors, count, dims, k, seed)

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

      Result.new(reordered_vectors, reordered_labels, centroids_i16, cell_offsets)
    end

    # Forgy initialization: pick k distinct random indices and copy the
    # corresponding vectors into the centroid buffer.
    private def self.init_random!(centroids : Slice(Float64),
                                  vectors : Slice(Int16),
                                  count : Int32,
                                  dims : Int32,
                                  k : Int32,
                                  seed : UInt64) : Nil
      r = Random.new(seed)
      seen = Set(Int32).new(initial_capacity: k)
      idx = Array(Int32).new(k)
      while seen.size < k
        candidate = r.rand(count)
        next if seen.includes?(candidate)
        seen << candidate
        idx << candidate
      end

      i = 0
      while i < k
        src = idx[i] * dims
        dst = i * dims
        d = 0
        while d < dims
          centroids[dst + d] = vectors[src + d].to_f64
          d += 1
        end
        i += 1
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
