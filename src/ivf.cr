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
  #
  # Two cell-level early-exits are applied between cells (TODO #2):
  #
  #   a. **Triangle-inequality pruning.** For each probed cell `c` with
  #      centroid distance `D_c = sqrt(centroid_dist_sq[c])` and
  #      precomputed radius `R_c` (max distance from centroid to any
  #      vector in `c`), no vector in cell `c` can beat the current top-5
  #      worst distance `W` if `(D_c - R_c)² >= W` (and `D_c > R_c`).
  #      Skip the whole cell.
  #
  #   b. **Decision-aware outer break.** Probed cells are sorted ascending
  #      by `D_c`. Once the *next* probed cell satisfies `(D_{p+1} - R_max)² >= W`
  #      with `R_max = max_cell_radius`, no remaining cell can possibly
  #      displace the current top-5. The fraud count is locked — break.
  #
  # Both preserve exact answers: no recall loss, just CPU saved.
  class Ivf
    DEFAULT_NPROBE = 16
    TOPK           =  5

    def initialize(@refs : References, @nprobe : Int32 = DEFAULT_NPROBE)
      raise "ivf: references has no IVF data (k=0)" if @refs.k == 0
      raise "ivf: nprobe (#{@nprobe}) > k (#{@refs.k})" if @nprobe > @refs.k
    end

    def fraud_count_top_k(query : StaticArray(Int16, 14)) : Int32
      vectors         = @refs.vectors
      labels          = @refs.labels
      centroids       = @refs.centroids
      cell_offsets    = @refs.cell_offsets
      cell_radius     = @refs.cell_radius
      max_cell_radius = @refs.max_cell_radius.to_i64
      k               = @refs.k
      nprobe          = @nprobe
      dims            = References::DIMS

      vec_ptr     = vectors.to_unsafe
      lab_ptr     = labels.to_unsafe
      cent_ptr    = centroids.to_unsafe
      radius_ptr  = cell_radius.to_unsafe
      query_ptr   = query.to_unsafe

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
      # Precompute integer-rounded sqrt of each probe centroid distance so
      # the per-cell triangle test stays in integer math. Bounded by
      # `nprobe` (≤ 32) — negligible cost.
      probe_dist_root = StaticArray(Int64, 32).new(0_i64)
      pp = 0
      while pp < nprobe
        probe_dist_root[pp] = Math.sqrt(probe_dist[pp].to_f64).to_i64
        pp &+= 1
      end

      best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
      best_label = StaticArray(UInt8, 5).new(0_u8)
      worst = Int64::MAX

      p = 0
      while p < nprobe
        cell  = probe_cell[p]
        d_root = probe_dist_root[p]

        # (a) Per-cell triangle-inequality skip. `d_root` is floor(sqrt(D²)),
        # so it is a *lower* approximation of the true centroid distance.
        # Conservative: only skip when the floor still beats the bound.
        radius = radius_ptr[cell].to_i64
        if d_root > radius
          gap = d_root - radius
          if gap &* gap >= worst
            p &+= 1
            next
          end
        end

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

        # (b) Decision-aware outer break. Probes are sorted ascending by
        # centroid distance; once the *next* probe is far enough that even
        # a cell of `max_cell_radius` couldn't displace the current top-5,
        # neither can any remaining probe. The fraud count is locked.
        next_p = p &+ 1
        if next_p < nprobe
          next_root = probe_dist_root[next_p]
          if next_root > max_cell_radius
            gap_next = next_root - max_cell_radius
            break if gap_next &* gap_next >= worst
          end
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
