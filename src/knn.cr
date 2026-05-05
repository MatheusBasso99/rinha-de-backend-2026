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
    def fraud_count_top_k(query : StaticArray(Int16, 14)) : Int32
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
          break if d >= worst
          j &+= 1
        end

        if d < worst
          # Insert into the sorted top-K via right-shift.
          slot = K - 1
          while slot > 0 && best_dist[slot &- 1] > d
            best_dist[slot]  = best_dist[slot &- 1]
            best_label[slot] = best_label[slot &- 1]
            slot &-= 1
          end
          best_dist[slot]  = d
          best_label[slot] = lab_ptr[i]
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
