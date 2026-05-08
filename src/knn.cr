require "./references"

module RinhaDeBackend
  # Brute-force exact KNN over the quantized reference dataset. K = 5 makes
  # an insertion-sorted StaticArray cheaper than a heap, and the inner
  # distance loop early-exits the moment the partial L2² already exceeds
  # the current 5th-best distance.
  #
  # Two layout paths share this class:
  #
  #   - Block path (`block_count > 0`): walks the AOSOA-8 dim-interleaved
  #     blocks the IVF builder writes. Used by the runtime mmap loader
  #     (`References.mmap`) and any spec/tool that compares brute-force
  #     to IVF.
  #
  #   - Row path (`block_count == 0`): walks the legacy row-major
  #     `vectors` slice produced by `References.load_from_io`. Only used
  #     by spec fixtures that load `example-references.json` directly.
  class Knn
    K = 5

    SLOTS_PER_BLOCK = References::SLOTS_PER_BLOCK
    LOGICAL_DIMS    = References::LOGICAL_DIMS
    BLOCK_LANES     = References::BLOCK_LANES

    def initialize(@refs : References)
    end

    # Returns how many of the K nearest neighbors carry the "fraud" label.
    def fraud_count_top_k(query : StaticArray(Int16, 16)) : Int32
      if @refs.block_count > 0
        fraud_count_top_k_blocks(query)
      else
        fraud_count_top_k_rows(query)
      end
    end

    # Block-major brute-force scan. Same per-block AOSOA-8 inner kernel
    # the IVF runtime uses, minus the cell-pruning skips. Pad slots /
    # alignment-pad blocks carry `IvfBuilder::PAD_SENTINEL` per lane,
    # which guarantees their squared distance dominates any real
    # candidate — they cannot enter the top-5.
    private def fraud_count_top_k_blocks(query : StaticArray(Int16, 16)) : Int32
      blocks      = @refs.blocks
      labels      = @refs.labels
      block_count = @refs.block_count

      blk_ptr   = blocks.to_unsafe
      lab_ptr   = labels.to_unsafe
      query_ptr = query.to_unsafe

      best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
      best_label = StaticArray(UInt8, 5).new(0_u8)
      worst = Int64::MAX

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
          new_label = lab_ptr[slot_global_base &+ slot]
          new_is_fraud = new_label == References::LABEL_FRAUD
          # F1.4 asymmetric tie-break — mirrors `Ivf` so the round-trip
          # spec (`base_nprobe == k`) holds bit-identical equality.
          tie_admit = new_is_fraud && dst == worst && best_label[K &- 1] == References::LABEL_LEGIT
          if dst < worst || tie_admit
            ins = K &- 1
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
            worst = best_dist[K &- 1]
          end
          slot &+= 1
        end

        b &+= 1
      end

      frauds = 0
      k = 0
      while k < K
        frauds &+= 1 if best_label[k] == References::LABEL_FRAUD
        k &+= 1
      end
      frauds
    end

    # Row-major brute-force scan over the legacy `vectors` slice (stride
    # DIMS = 16, 14 logical + 2 zero pad).
    private def fraud_count_top_k_rows(query : StaticArray(Int16, 16)) : Int32
      vectors = @refs.vectors
      labels  = @refs.labels
      count   = @refs.padded_count
      dims    = References::DIMS

      best_dist  = StaticArray(Int64, 5).new(Int64::MAX)
      best_label = StaticArray(UInt8, 5).new(0_u8)
      worst = Int64::MAX

      vec_ptr = vectors.to_unsafe
      lab_ptr = labels.to_unsafe
      query_ptr = query.to_unsafe

      i = 0
      while i < count
        offset = i * dims

        d = 0_i64
        j = 0
        while j < dims
          diff = query_ptr[j].to_i32 - vec_ptr[offset + j].to_i32
          d &+= (diff * diff).to_i64
          j &+= 1
        end

        new_label = lab_ptr[i]
        new_is_fraud = new_label == References::LABEL_FRAUD
        tie_admit = new_is_fraud && d == worst && best_label[K &- 1] == References::LABEL_LEGIT
        if d < worst || tie_admit
          slot = K - 1
          while slot > 0
            bd = best_dist[slot &- 1]
            bl = best_label[slot &- 1]
            shift = bd > d || (new_is_fraud && bd == d && bl == References::LABEL_LEGIT)
            break unless shift
            best_dist[slot]  = bd
            best_label[slot] = bl
            slot &-= 1
          end
          best_dist[slot]  = d
          best_label[slot] = new_label
          worst = best_dist[K &- 1]
        end

        i &+= 1
      end

      frauds = 0
      k = 0
      while k < K
        frauds &+= 1 if best_label[k] == References::LABEL_FRAUD
        k &+= 1
      end
      frauds
    end
  end
end
