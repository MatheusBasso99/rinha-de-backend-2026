require "./references"

module RinhaDeBackend
  # IVF runtime query against the AOSOA-8 dim-interleaved block layout
  # produced by `IvfBuilder`. Reads the centroids, cell-to-block offsets,
  # and the block-major reference data through the mmapped binary file.
  #
  # Query algorithm:
  #
  #   1. Compute distance from `query` to each of the `k` centroids.
  #   2. Pick the `nprobe` nearest centroids.
  #   3. Scan the blocks in those `nprobe` cells with the multi-stage
  #      AOSOA-8 inner kernel + insertion-sorted top-K.
  #
  # Three cell-level early-exits are applied between cells:
  #
  #   a. **Triangle-inequality pruning.** For each probed cell `c` with
  #      centroid distance `D_c = sqrt(centroid_dist_sq[c])` and
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
  # Inside each block (AOSOA-8 dim-interleaved):
  #
  #   - 8 vectors per block, dim-interleaved as
  #     `[d0_v0..d0_v7, d1_v0..d1_v7, ..., d13_v0..d13_v7]`.
  #     With `--mcpu=haswell --mattr=+avx2,+fma` LLVM lowers the per-dim
  #     8-wide squared-difference loop to (i32 path):
  #
  #       vpmovsxwd ymm0, [block + d*16]   ; 8 i16 → 8 i32
  #       vpsubd    ymm1, ymm0, ymm_qd     ; 8 i32 differences
  #       vpmulld   ymm2, ymm1, ymm1       ; 8 i32 squares
  #       vpmovsxdq ymm3, ymm2_lo          ; 4 i64 widened
  #       vpaddq    ymm_acc_lo, ymm_acc_lo, ymm3
  #       vextracti128 + vpmovsxdq ymm4    ; 4 i64 high half
  #       vpaddq    ymm_acc_hi, ymm_acc_hi, ymm4
  #
  #     producing 8 partial squared distances per dim instead of 1
  #     squared distance per row in the old layout.
  #
  #   - Multi-stage early exit at d=4 and d=8: if every one of the 8
  #     partial sums already exceeds the current top-5 worst, skip the
  #     remainder of the block.
  #
  #   - Top-5 insertion sort runs once per block, scanning the 8
  #     finished partial sums against `worst`. Slots that early-exited
  #     have all-lanes >= worst, so the same scan correctly admits
  #     nothing.
  #
  # Pad slots and alignment-pad blocks (carrying `IvfBuilder::PAD_SENTINEL =
  # Int16::MAX` on every lane) produce squared distances ≥ ~7.3 × 10⁹ vs
  # any production query (lanes ∈ [-10000, 10000]) — well above any real
  # worst-case real-row L² (~5.6 × 10⁹) — so they cannot enter the top-5
  # ranking and the block scan needs no per-slot validity bookkeeping.
  #
  # All three cell skips preserve exact answers: no recall loss, just CPU saved.
  class Ivf
    DEFAULT_BASE_NPROBE  =  8
    DEFAULT_RETRY_NPROBE = 16
    TOPK                 =  5

    # Mirrored from References at compile time so the inner loop can use
    # them as literals (the optimizer won't touch instance attribute
    # reads inside a hot loop).
    SLOTS_PER_BLOCK = References::SLOTS_PER_BLOCK # 8
    LOGICAL_DIMS    = References::LOGICAL_DIMS    # 14
    BLOCK_LANES     = References::BLOCK_LANES     # 112

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
    #             decision-aware outer break) and the AOSOA-8 multi-stage
    #             inner kernel.
    #
    #   Phase B — only when the top-5 from phase A lands at the decision
    #             threshold (`frauds ∈ {2, 3}`, where one swap flips the
    #             API answer), continue scanning the next `retry_nprobe`
    #             (16) cells using the same top-5 buffer. The already-tight
    #             `worst` from phase A makes pruning bite harder in phase B,
    #             so most retries skip cleanly.
    #
    # In the common path (frauds ∈ {0, 1, 4, 5}) the retry is skipped
    # entirely.
    #
    # `@[AlwaysInline]` lets the optimizer fold the whole probe into
    # `handle_fraud_score` so register/spill decisions are made across
    # the request boundary. `@[TargetFeature]` is **deliberately not
    # used** here: Crystal's codegen treats any `target_features` /
    # `target_cpu` override as a hard inlining boundary
    # (`compiler/crystal/codegen/fun.cr` adds `LLVM::Attribute::NoInline`
    # whenever those are set), which would silently cancel the
    # `AlwaysInline` we want. The global `--mcpu=haswell` /
    # `--mattr=+avx2,+fma,+bmi2,...` build flags already give the
    # kernel the same Haswell ISA, without the inlining penalty.
    @[AlwaysInline]
    def fraud_count_top_k(query : StaticArray(Int16, 16)) : Int32
      blocks          = @refs.blocks
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

      blk_ptr     = blocks.to_unsafe
      lab_ptr     = labels.to_unsafe
      cent_ptr    = centroids.to_unsafe
      radius_ptr  = cell_radius.to_unsafe
      bmin_ptr    = bbox_min.to_unsafe
      bmax_ptr    = bbox_max.to_unsafe
      query_ptr   = query.to_unsafe

      # ---------------- Stage 1: pick top-`total_nprobe` cells. -----------
      # Always pick the top BASE+RETRY centroids in a single pass — even when
      # phase B is skipped, the centroid-scan cost is dominated by reading
      # all k centroids. Insertion-sort into more slots is cheap.
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

      probe_start = 0
      probe_end   = base_nprobe
      phase = 0

      while true
        p = probe_start
        while p < probe_end
          cell  = probe_cell[p]
          d_root = probe_dist_root[p]

          # (a) Per-cell triangle-inequality skip.
          radius = radius_ptr[cell].to_i64
          if d_root > radius
            gap = d_root - radius
            if gap &* gap >= worst
              p &+= 1
              next
            end
          end

          # (b) Per-cell bounding-box exact skip. Pad lanes 14..15 carry
          # lo = hi = 0 and the query is zero on those lanes too, so they
          # contribute nothing.
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

          # ----- Cell scan: walk this cell's blocks. -----
          start_block = cell_offsets[cell].to_i32
          stop_block  = cell_offsets[cell &+ 1].to_i32

          b = start_block
          while b < stop_block
            block_origin = b &* BLOCK_LANES

            # Per-block 8-wide partial squared-L² accumulators. Use Int64
            # because pad-sentinel slots can blow Int32 (per-stage sum
            # against a sentinel slot ~ 14 × 1.8e9 ≈ 2.5e10, overflows
            # i32). LLVM still vectorizes the per-dim loop into ymm i32
            # multiplies + ymm i64 accumulates.
            partial = StaticArray(Int64, 8).new(0_i64)

            # Stage 1: dims 0..3.
            d = 0
            while d < 4
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

            # Stage 1 early exit: if EVERY lane already meets/exceeds
            # `worst`, no slot in this block can enter top-5 even if the
            # remaining dims contribute zero. Skip to next block.
            all_exceed = true
            ss = 0
            while ss < SLOTS_PER_BLOCK
              if partial[ss] < worst
                all_exceed = false
                break
              end
              ss &+= 1
            end
            if all_exceed
              b &+= 1
              next
            end

            # Stage 2: dims 4..7.
            d = 4
            while d < 8
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

            all_exceed = true
            ss = 0
            while ss < SLOTS_PER_BLOCK
              if partial[ss] < worst
                all_exceed = false
                break
              end
              ss &+= 1
            end
            if all_exceed
              b &+= 1
              next
            end

            # Stage 3: dims 8..13 (LOGICAL_DIMS = 14).
            d = 8
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

            # Insertion: scan the 8 finished partial sums, admit slots
            # that beat (or tie-break, asymmetric) the current top-5.
            slot_global_base = b &* SLOTS_PER_BLOCK
            slot = 0
            while slot < SLOTS_PER_BLOCK
              dst = partial[slot]
              new_label = lab_ptr[slot_global_base &+ slot]
              new_is_fraud = new_label == References::LABEL_FRAUD
              # F1.4 asymmetric tie-break: on equal distance, fraud wins
              # over legit; FN penalty (3×) outweighs FP (1×) so the
              # expected-cost optimum is to surface the fraud.
              tie_admit = new_is_fraud && dst == worst && best_label[TOPK &- 1] == References::LABEL_LEGIT
              if dst < worst || tie_admit
                ins = TOPK &- 1
                while ins > 0
                  bd = best_dist[ins &- 1]
                  bl = best_label[ins &- 1]
                  shift = bd > dst || (new_is_fraud && bd == dst && bl == References::LABEL_LEGIT)
                  break unless shift
                  best_dist[ins]  = bd
                  best_label[ins] = bl
                  ins &-= 1
                end
                best_dist[ins]  = dst
                best_label[ins] = new_label
                worst = best_dist[TOPK &- 1]
              end
              slot &+= 1
            end

            b &+= 1
          end

          # (c) Decision-aware outer break.
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

        # Boundary retry only on the decision edge.
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
