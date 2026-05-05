require "./references"

module RinhaDeBackend
  # IVF runtime query. Reads the centroids, cell offsets and reordered
  # vectors that were produced by `IvfBuilder` and serialized into the
  # mmapped binary file.
  #
  # Query algorithm:
  #
  #   1. Compute distance from `query` to each of the `k` centroids.
  #   2. Pick the `nprobe` nearest centroids.
  #   3. Linearly scan the vectors in those `nprobe` cells with the
  #      same insertion-sorted top-K + early-exit pattern used by
  #      `Knn`.
  class Ivf
    DEFAULT_NPROBE = 16
    TOPK           =  5

    def initialize(@refs : References, @nprobe : Int32 = DEFAULT_NPROBE)
      raise "ivf: references has no IVF data (k=0)" if @refs.k == 0
      raise "ivf: nprobe (#{@nprobe}) > k (#{@refs.k})" if @nprobe > @refs.k
    end

    def fraud_count_top_k(query : StaticArray(Int16, 14)) : Int32
      vectors      = @refs.vectors
      labels       = @refs.labels
      centroids    = @refs.centroids
      cell_offsets = @refs.cell_offsets
      k            = @refs.k
      nprobe       = @nprobe
      dims         = References::DIMS

      vec_ptr  = vectors.to_unsafe
      lab_ptr  = labels.to_unsafe
      cent_ptr = centroids.to_unsafe
      query_ptr = query.to_unsafe

      # ---------------- Stage 1: pick top-`nprobe` cells. ----------------
      # Insertion-sorted parallel arrays keyed by distance. Sized to the
      # max nprobe we want to support cheaply.
      max_nprobe = 32
      raise "nprobe (#{nprobe}) > max_nprobe (#{max_nprobe})" if nprobe > max_nprobe

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

      # ---------------- Stage 2: top-K within probed cells. ----------------
      best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
      best_label = StaticArray(UInt8, 5).new(0_u8)
      worst = Int64::MAX

      p = 0
      while p < nprobe
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
            slot = TOPK &- 1
            while slot > 0 && best_dist[slot &- 1] > d
              best_dist[slot]  = best_dist[slot &- 1]
              best_label[slot] = best_label[slot &- 1]
              slot &-= 1
            end
            best_dist[slot]  = d
            best_label[slot] = lab_ptr[i]
            worst = best_dist[TOPK &- 1]
          end

          i &+= 1
        end

        p &+= 1
      end

      frauds = 0
      kk = 0
      while kk < TOPK
        frauds &+= 1 if best_label[kk] == References::LABEL_FRAUD
        kk &+= 1
      end
      frauds
    end
  end
end
