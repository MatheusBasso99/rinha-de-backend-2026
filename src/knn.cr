require "./references"

module RinhaDeBackend
  # Brute-force exact KNN over the quantized reference dataset. K = 5 makes
  # an insertion-sorted StaticArray cheaper than a heap, and the inner
  # distance loop early-exits the moment the partial L2² already exceeds
  # the current 5th-best distance.
  class Knn
    K = 5

    def initialize(@refs : References)
    end

    # Returns how many of the K nearest neighbors carry the "fraud" label.
    def fraud_count_top_k(query : StaticArray(Int16, 16)) : Int32
      vectors = @refs.vectors
      labels  = @refs.labels
      count   = @refs.count
      dims    = References::DIMS

      # Top-K parallel arrays, kept sorted ascending by distance.
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

        # Asymmetric tie-break (F1.4): fraud wins over legit on a tie.
        # Mirrors `Ivf` so this brute-force reference and the IVF runtime
        # agree on every query (the round-trip spec relies on exact
        # equality between `Knn#fraud_count_top_k` and `Ivf#...`).
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
