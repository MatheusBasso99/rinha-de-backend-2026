require "compress/gzip"
require "json"

module RinhaDeBackend
  # Reference dataset for KNN. Stored densely:
  #
  #   - `vectors`: Slice(Int16), length = count * DIMS, row-major.
  #   - `labels` : Slice(UInt8), length = count, 1 = fraud, 0 = legit.
  #
  # Floats are quantized as `(v * 10_000).round.to_i16`. This is uniform: the
  # `-1` sentinel for indices 5/6 (no last_transaction) maps to `-10_000`,
  # which is naturally outside the [0, 10_000] band — so "no history"
  # vectors keep clustering with each other in L2 space without any branch
  # in the distance loop.
  class References
    DEFAULT_PATH = "resources/references.json.gz"

    DIMS  = 14
    SCALE = 10_000.0_f64

    LABEL_LEGIT = 0_u8
    LABEL_FRAUD = 1_u8

    # Upper bound from docs/en/DATASET.md (3,000,000 labeled vectors).
    # Used as the initial allocation size; we trim to actual count.
    DEFAULT_CAPACITY = 3_000_000

    getter count : Int32
    getter vectors : Slice(Int16)
    getter labels : Slice(UInt8)

    private def initialize(@count : Int32, @vectors : Slice(Int16), @labels : Slice(UInt8))
    end

    def self.load(path : String = DEFAULT_PATH) : References
      File.open(path, "rb") do |file|
        Compress::Gzip::Reader.open(file) do |gz|
          load_from_io(gz)
        end
      end
    end

    # Stream-parse the JSON array from `io`, filling pre-allocated
    # contiguous slices.
    def self.load_from_io(io : IO, capacity : Int32 = DEFAULT_CAPACITY) : References
      pull = JSON::PullParser.new(io)

      vectors = Slice(Int16).new(capacity * DIMS, 0_i16)
      labels  = Slice(UInt8).new(capacity, 0_u8)
      i = 0

      pull.read_array do
        if i >= capacity
          # Unlikely; double the buffers and copy.
          new_capacity = capacity * 2
          new_vectors = Slice(Int16).new(new_capacity * DIMS, 0_i16)
          new_labels  = Slice(UInt8).new(new_capacity, 0_u8)
          vectors.copy_to(new_vectors)
          labels.copy_to(new_labels)
          vectors = new_vectors
          labels = new_labels
          capacity = new_capacity
        end

        offset = i * DIMS
        dim = 0
        label = LABEL_LEGIT

        pull.read_object do |key|
          case key
          when "vector"
            pull.read_array do
              v = pull.read_float
              vectors[offset + dim] = (v * SCALE).round.to_i16
              dim += 1
            end
          when "label"
            label = pull.read_string == "fraud" ? LABEL_FRAUD : LABEL_LEGIT
          else
            pull.read_raw
          end
        end

        labels[i] = label
        i += 1
      end

      # Trim to actual count.
      if i < capacity
        trimmed_vectors = Slice(Int16).new(i * DIMS, 0_i16)
        trimmed_labels  = Slice(UInt8).new(i, 0_u8)
        vectors[0, i * DIMS].copy_to(trimmed_vectors)
        labels[0, i].copy_to(trimmed_labels)
        vectors = trimmed_vectors
        labels  = trimmed_labels
      end

      new(i, vectors, labels)
    end
  end
end
