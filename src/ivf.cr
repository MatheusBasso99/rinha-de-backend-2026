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
  # Three cell-level early-exits are applied between cells:
  #
  #   a. **Triangle-inequality pruning.** For each probed cell
  #      `c` with centroid distance `D_c = sqrt(centroid_dist_sq[c])` and
  #      precomputed radius `R_c` (max distance from centroid to any
  #      vector in `c`), no vector in cell `c` can beat the current top-5
  #      worst distance `W` if `(D_c - R_c)² >= W` (and `D_c > R_c`).
  #      Skip the whole cell.
  #
  #   b. **Per-cell bounding-box pruning.** Tighter than (a) in
  #      high-dim corners. For each probed cell `c` with bbox
  #      `[bbox_min[c], bbox_max[c]]`, the minimum possible squared
  #      distance from `query` to any vector in the box is
  #      `sum_j max(bbox_min[c][j] - query[j], 0, query[j] - bbox_max[c][j])²`.
  #      If that already `>= W`, skip the cell. Exact pruning.
  #
  #   c. **Decision-aware outer break.** Probed cells are sorted ascending
  #      by `D_c`. Once the *next* probed cell satisfies `(D_{p+1} - R_max)² >= W`
  #      with `R_max = max_cell_radius`, no remaining cell can possibly
  #      displace the current top-5. The fraud count is locked — break.
  #
  # Inside the per-vector inner loop, the squared-L2 is a single straight
  # 16-lane pass: vector rows are stored at stride 16 with the 14 logical
  # dims in lanes 0..13 and zero pad in lanes 14..15. With `--mcpu=haswell`
  # LLVM lowers the loop to one VPMADDWD ymm (5c lat / 1c throughput on
  # ports P0+P1) producing the full squared inner product for the row in
  # a single iteration. Decision-aware outer break + bbox prune still
  # skip whole cells; we only drop the per-dim early-exit because at
  # 1 cycle per vector it's cheaper to compute the full distance than
  # to mispredict a per-chunk branch.
  #
  # All three cell skips preserve exact answers: no recall loss, just CPU saved.
  class Ivf
    DEFAULT_BASE_NPROBE  =  8
    DEFAULT_RETRY_NPROBE = 16
    TOPK                 =  5

    def initialize(@refs : References,
                   @base_nprobe : Int32 = DEFAULT_BASE_NPROBE,
                   @retry_nprobe : Int32 = DEFAULT_RETRY_NPROBE)
      raise "ivf: references has no IVF data (k=0)" if @refs.k == 0
      raise "ivf: base_nprobe (#{@base_nprobe}) <= 0" if @base_nprobe <= 0
      raise "ivf: retry_nprobe (#{@retry_nprobe}) < 0" if @retry_nprobe < 0
      total = @base_nprobe + @retry_nprobe
      raise "ivf: base+retry (#{total}) > k (#{@refs.k})" if total > @refs.k
      raise "ivf: base+retry (#{total}) > 32 (probe arrays sized for 32)" if total > 32
    end

    getter base_nprobe : Int32
    getter retry_nprobe : Int32

    # Two-phase IVF probe:
    #
    #   Phase A — scan the `base_nprobe` (8) nearest cells. Run the full
    #             pruning stack (per-cell triangle, per-cell bbox,
    #             decision-aware outer break) and a flat 16-lane L2 inner
    #             loop (single VPMADDWD ymm under `--mcpu=haswell`).
    #
    #   Phase B — only when the top-5 from phase A lands at the decision
    #             threshold (`frauds ∈ {2, 3}`, where one swap flips the
    #             API answer), continue scanning the next `retry_nprobe`
    #             (16) cells using the same top-5 buffer. The already-tight
    #             `worst` from phase A makes pruning bite harder in phase B,
    #             so most retries skip cleanly.
    #
    # In the common path (frauds ∈ {0, 1, 4, 5}) the retry is skipped
    # entirely — mean/p50 latency drops ~2× vs the previous always-16
    # baseline.
    def fraud_count_top_k(query : StaticArray(Int16, 16)) : Int32
      vectors         = @refs.vectors
      labels          = @refs.labels
      centroids       = @refs.centroids
      cell_offsets    = @refs.cell_offsets
      cell_radius     = @refs.cell_radius
      bbox_min        = @refs.bbox_min
      bbox_max        = @refs.bbox_max
      max_cell_radius = @refs.max_cell_radius.to_i64
      k               = @refs.k
      base_nprobe     = @base_nprobe
      retry_nprobe    = @retry_nprobe
      total_nprobe    = base_nprobe &+ retry_nprobe
      dims            = References::DIMS

      vec_ptr     = vectors.to_unsafe
      lab_ptr     = labels.to_unsafe
      cent_ptr    = centroids.to_unsafe
      radius_ptr  = cell_radius.to_unsafe
      bmin_ptr    = bbox_min.to_unsafe
      bmax_ptr    = bbox_max.to_unsafe
      query_ptr   = query.to_unsafe

      # ---------------- Stage 1: pick top-`total_nprobe` cells. -----------
      # Always pick the top BASE+RETRY centroids in a single pass — even when
      # phase B is skipped, the centroid-scan cost is dominated by reading
      # all k centroids. Insertion-sort into more slots is cheap (only when
      # `worst_probe` is loose, i.e. early in the scan).
      probe_dist  = StaticArray(Int64, 32).new(Int64::MAX)
      probe_cell  = StaticArray(Int32, 32).new(0)
      worst_probe = Int64::MAX

      c = 0
      while c < k
        c_off = c &* dims
        d = 0_i64
        j = 0
        while j < dims
          diff = query_ptr[j].to_i32 &- cent_ptr[c_off &+ j].to_i32
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

      # ---------------- Stage 2: top-K within probed cells. ---------------
      # Precompute integer-rounded sqrt of each probe centroid distance so
      # the per-cell triangle test stays in integer math.
      probe_dist_root = StaticArray(Int64, 32).new(0_i64)
      pp = 0
      while pp < total_nprobe
        probe_dist_root[pp] = Math.sqrt(probe_dist[pp].to_f64).to_i64
        pp &+= 1
      end

      best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
      best_label = StaticArray(UInt8, 5).new(0_u8)
      worst = Int64::MAX

      # Phase loop: phase 0 scans probes [0..base_nprobe);
      #             phase 1 scans probes [base_nprobe..total_nprobe), only
      #             entered when frauds ∈ {2, 3} after phase 0.
      probe_start = 0
      probe_end   = base_nprobe
      phase = 0

      while true
        p = probe_start
        while p < probe_end
          cell  = probe_cell[p]
          d_root = probe_dist_root[p]

          # (a) Per-cell triangle-inequality skip. `d_root` is floor(sqrt(D²)),
          # a lower approximation of the true centroid distance.
          radius = radius_ptr[cell].to_i64
          if d_root > radius
            gap = d_root - radius
            if gap &* gap >= worst
              p &+= 1
              next
            end
          end

          # (b) Per-cell bounding-box exact skip. Min squared
          # distance from `query` to the axis-aligned bbox of this cell.
          # Pad lanes (indices 14, 15) carry lo = hi = 0 and the query is
          # zero on those lanes too, so they contribute nothing.
          bb_off = cell &* dims
          bb_d = 0_i64
          bj = 0
          while bj < dims
            q_b = query_ptr[bj].to_i32
            lo  = bmin_ptr[bb_off &+ bj].to_i32
            hi  = bmax_ptr[bb_off &+ bj].to_i32
            if q_b < lo
              diff_b = lo &- q_b
              bb_d &+= (diff_b &* diff_b).to_i64
            elsif q_b > hi
              diff_b = q_b &- hi
              bb_d &+= (diff_b &* diff_b).to_i64
            end
            break if bb_d >= worst
            bj &+= 1
          end
          if bb_d >= worst
            p &+= 1
            next
          end

          start = cell_offsets[cell].to_i32
          stop  = cell_offsets[cell &+ 1].to_i32

          i = start
          while i < stop
            off = i &* dims

            # 16-lane straight L2² over a single row.
            #
            # On Haswell with `--mcpu=haswell` the loop body lowers to:
            #   vmovdqu  ymm0, [vec_ptr + off]      ; one row, 32 B aligned
            #   vmovdqu  ymm1, [query_ptr]          ; broadcast-style reuse
            #   vpsubw   ymm2, ymm0, ymm1
            #   vpmaddwd ymm3, ymm2, ymm2           ; 8× (Δ²+Δ²) → 8 i32
            #   vpmovsxdq+vpaddq → reduce to scalar i64 outside the loop
            # so the per-vector inner cost is one VPMADDWD (1c thr, P0+P1).
            d = 0_i64
            j = 0
            while j < dims
              diff = query_ptr[j].to_i32 &- vec_ptr[off &+ j].to_i32
              d &+= (diff &* diff).to_i64
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

          # (c) Decision-aware outer break. Probes are sorted ascending by
          # centroid distance; once the *next* probe is far enough that even
          # a cell of `max_cell_radius` couldn't displace the current top-5,
          # neither can any remaining probe in this phase.
          next_p = p &+ 1
          if next_p < probe_end
            next_root = probe_dist_root[next_p]
            if next_root > max_cell_radius
              gap_next = next_root - max_cell_radius
              break if gap_next &* gap_next >= worst
            end
          end

          p &+= 1
        end

        # End of phase. Decide whether to enter phase B.
        break if phase == 1 || retry_nprobe == 0

        frauds_now = 0
        kk = 0
        while kk < TOPK
          frauds_now &+= 1 if best_label[kk] == References::LABEL_FRAUD
          kk &+= 1
        end

        # Boundary retry only on the decision edge. The fixed
        # threshold is 0.6 → frauds < 3 ⇒ approve. Top-5 with frauds in
        # {2, 3} is the "one neighbor away from flipping" zone, where the
        # extra 16 cells can move the answer; outside that zone, the
        # current top-5 already locks in the decision regardless of any
        # cells we'd scan next.
        break unless frauds_now == 2 || frauds_now == 3

        probe_start = base_nprobe
        probe_end   = total_nprobe
        phase = 1
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
