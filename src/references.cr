require "compress/gzip"
require "json"
require "./ivf_builder"

module RinhaDeBackend
  # Reference dataset for KNN/IVF. Stored densely in a single binary
  # file produced once at Docker build time and mmapped read-only at
  # runtime.
  #
  #   - `vectors`     : Slice(Int16), length = count * DIMS, row-major,
  #                     reordered so that vectors of the same IVF cell
  #                     are contiguous.
  #   - `labels`      : Slice(UInt8), length = count, 1 = fraud, 0 = legit,
  #                     reordered the same way as `vectors`.
  #   - `centroids`   : Slice(Int16), length = k * DIMS, the IVF cell
  #                     centers (quantized to the same scale as vectors).
  #   - `cell_offsets`: Slice(UInt32), length = k + 1; cell `c` spans
  #                     `vectors[cell_offsets[c]..cell_offsets[c+1])`.
  #   - `cell_radius` : Slice(UInt32), length = k; max non-squared L2
  #                     distance from quantized centroid `c` to any vector
  #                     in cell `c` (ceil). Used at query time for the
  #                     triangle-inequality cell-pruning check.
  #   - `max_cell_radius`: max over `cell_radius`. Cached in the header so
  #                       the runtime can use it for a global outer-break
  #                       check without scanning the per-cell array.
  #   - `bbox_min`    : Slice(Int16), length = k * DIMS. Per-cell axis-
  #                     aligned bounding box minimum per dimension.
  #   - `bbox_max`    : Slice(Int16), length = k * DIMS. Per-cell axis-
  #                     aligned bounding box maximum per dimension.
  #                     Used at query time for an exact cell-pruning
  #                     check tighter than triangle-inequality (TODO #4).
  #
  # Floats are quantized as `(v * 10_000).round.to_i16`. The `-1`
  # sentinel for indices 5/6 (no last_transaction) maps to `-10_000`,
  # naturally outside the [0, 10_000] band.
  #
  # Binary file format (little-endian, x86_64):
  #
  #   bytes  0..3   : magic "RNH4"
  #   bytes  4..7   : count u32
  #   bytes  8..11  : dims  u32 (= 14)
  #   bytes 12..15  : k     u32 (number of IVF cells)
  #   bytes 16..19  : max_cell_radius u32
  #   bytes 20..63  : reserved (zeroed)
  #   bytes 64..    : vectors (count * dims * Int16, reordered by cell)
  #   then          : labels  (count * UInt8, reordered by cell)
  #   then          : centroids (k * dims * Int16)
  #   then          : cell_offsets ((k + 1) * UInt32)
  #   then          : cell_radius (k * UInt32)
  #   then          : bbox_min (k * dims * Int16)
  #   then          : bbox_max (k * dims * Int16)
  class References
    DEFAULT_PATH     = "resources/references.json.gz"
    DEFAULT_BIN_PATH = "resources/references.bin"

    DIMS  = 14
    SCALE = 10_000.0_f64

    LABEL_LEGIT = 0_u8
    LABEL_FRAUD = 1_u8

    DEFAULT_CAPACITY = 3_000_000

    HEADER_SIZE  =     64
    HEADER_MAGIC = "RNH4"

    getter count : Int32
    getter vectors : Slice(Int16)
    getter labels : Slice(UInt8)
    getter k : Int32
    getter centroids : Slice(Int16)
    getter cell_offsets : Slice(UInt32)
    getter cell_radius : Slice(UInt32)
    getter max_cell_radius : UInt32
    getter bbox_min : Slice(Int16)
    getter bbox_max : Slice(Int16)

    # Base + size of the mmapped region (set only on the mmap path; nil for
    # non-mmap loaders). Used by `prefault!` to walk the region and force
    # pages into the page cache, optionally promoted to 2 MiB transparent
    # huge pages where the kernel allows. (TODO #5)
    @mmap_base : UInt8* = Pointer(UInt8).null
    @mmap_size : Int64  = 0_i64

    # Sink for `prefault!`'s page-touch loop. Stored so the optimizer
    # cannot elide the reads.
    @prefault_sink : UInt8 = 0_u8

    private def initialize(@count : Int32,
                           @vectors : Slice(Int16),
                           @labels : Slice(UInt8),
                           @k : Int32 = 0,
                           @centroids : Slice(Int16) = Slice(Int16).new(0, 0_i16),
                           @cell_offsets : Slice(UInt32) = Slice(UInt32).new(0, 0_u32),
                           @cell_radius : Slice(UInt32) = Slice(UInt32).new(0, 0_u32),
                           @max_cell_radius : UInt32 = 0_u32,
                           @bbox_min : Slice(Int16) = Slice(Int16).new(0, 0_i16),
                           @bbox_max : Slice(Int16) = Slice(Int16).new(0, 0_i16),
                           @mmap_base : UInt8* = Pointer(UInt8).null,
                           @mmap_size : Int64 = 0_i64)
    end

    # Mmap a pre-built binary file produced by `preprocess`.
    def self.mmap(path : String = DEFAULT_BIN_PATH) : References
      size_i64 = File.size(path)
      raise "references.bin too small (#{size_i64} bytes)" if size_i64 < HEADER_SIZE

      fd = LibC.open(path, LibC::O_RDONLY)
      raise "open(#{path}) failed: errno=#{Errno.value}" if fd < 0

      ptr = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(size_i64),
        LibC::PROT_READ,
        LibC::MAP_SHARED | LibC::MAP_POPULATE,
        fd,
        0_i64
      )
      LibC.close(fd)
      raise "mmap(#{path}) failed: errno=#{Errno.value}" if ptr == LibC::MAP_FAILED

      # TODO #5: hint the kernel to back the region with 2 MiB transparent
      # huge pages. Best-effort — the kernel may decline (depends on THP
      # policy and filesystem support for file-backed THP). The actual
      # touch loop lives in `prefault!`, called during warm-up.
      LibC.madvise(ptr, LibC::SizeT.new(size_i64), LibC::MADV_HUGEPAGE)

      base = ptr.as(UInt8*)
      magic = String.new(base, 4)
      raise "bad magic in #{path}: #{magic.inspect}" unless magic == HEADER_MAGIC

      count = (base + 4).as(UInt32*).value.to_i32
      dims  = (base + 8).as(UInt32*).value.to_i32
      k     = (base + 12).as(UInt32*).value.to_i32
      max_cell_radius = (base + 16).as(UInt32*).value
      raise "dims mismatch in #{path}: #{dims} != #{DIMS}" unless dims == DIMS

      vectors_off      = HEADER_SIZE
      labels_off       = vectors_off + count * DIMS * sizeof(Int16)
      centroids_off    = labels_off + count * sizeof(UInt8)
      cell_offsets_off = centroids_off + k * DIMS * sizeof(Int16)
      cell_radius_off  = cell_offsets_off + (k + 1) * sizeof(UInt32)
      bbox_min_off     = cell_radius_off + k * sizeof(UInt32)
      bbox_max_off     = bbox_min_off + k * DIMS * sizeof(Int16)
      end_off          = bbox_max_off + k * DIMS * sizeof(Int16)
      raise "size mismatch in #{path}: #{size_i64} != #{end_off}" unless size_i64 == end_off

      vectors_ptr      = (base + vectors_off).as(Int16*)
      labels_ptr       = (base + labels_off).as(UInt8*)
      centroids_ptr    = (base + centroids_off).as(Int16*)
      cell_offsets_ptr = (base + cell_offsets_off).as(UInt32*)
      cell_radius_ptr  = (base + cell_radius_off).as(UInt32*)
      bbox_min_ptr     = (base + bbox_min_off).as(Int16*)
      bbox_max_ptr     = (base + bbox_max_off).as(Int16*)

      vectors      = Slice(Int16).new(vectors_ptr, count * DIMS, read_only: true)
      labels       = Slice(UInt8).new(labels_ptr, count, read_only: true)
      centroids    = Slice(Int16).new(centroids_ptr, k * DIMS, read_only: true)
      cell_offsets = Slice(UInt32).new(cell_offsets_ptr, k + 1, read_only: true)
      cell_radius  = Slice(UInt32).new(cell_radius_ptr, k, read_only: true)
      bbox_min     = Slice(Int16).new(bbox_min_ptr, k * DIMS, read_only: true)
      bbox_max     = Slice(Int16).new(bbox_max_ptr, k * DIMS, read_only: true)

      new(count, vectors, labels, k, centroids, cell_offsets, cell_radius,
          max_cell_radius, bbox_min, bbox_max, base, size_i64.to_i64)
    end

    # Walk the mmapped region, reading one byte every 4 KiB to force the
    # kernel to populate any pages that haven't been brought in yet (and
    # give MADV_HUGEPAGE an opportunity to fold them into 2 MiB pages).
    # MAP_POPULATE already prefaults at mmap time, but a manual touch
    # post-madvise is the canonical way to nudge khugepaged into action
    # on file-backed mappings. (TODO #5)
    #
    # No-op on non-mmap loads (`load`, `load_from_io`).
    def prefault! : Nil
      return if @mmap_size <= 0 || @mmap_base.null?
      page = 4096_i64
      sum  = 0_u8
      p = 0_i64
      while p < @mmap_size
        sum &+= @mmap_base[p]
        p &+= page
      end
      sum &+= @mmap_base[@mmap_size &- 1]
      @prefault_sink = sum
    end

    # Builds the binary file by parsing JSON, running k-means and
    # writing all sections in order. `output_io` must be seekable.
    # Returns the number of records written.
    def self.preprocess(json_io : IO,
                        output_io : IO,
                        k : Int32 = IvfBuilder::DEFAULT_K,
                        iterations : Int32 = IvfBuilder::DEFAULT_ITERATIONS) : Int32
      # Load all vectors into memory.
      raw = load_from_io(json_io, capacity: DEFAULT_CAPACITY)

      # Build IVF.
      result = IvfBuilder.build(raw.vectors, raw.labels, raw.count, DIMS, k, iterations)

      raise "output_io must be seekable" unless output_io.responds_to?(:seek)

      # Header placeholder.
      output_io.write(Bytes.new(HEADER_SIZE, 0_u8))

      # Sections.
      output_io.write(result.vectors.to_unsafe_bytes)
      output_io.write(result.labels.to_unsafe_bytes)
      output_io.write(result.centroids.to_unsafe_bytes)
      output_io.write(result.cell_offsets.to_unsafe_bytes)
      output_io.write(result.cell_radius.to_unsafe_bytes)
      output_io.write(result.bbox_min.to_unsafe_bytes)
      output_io.write(result.bbox_max.to_unsafe_bytes)

      # Backfill header.
      output_io.seek(0)
      output_io.write(HEADER_MAGIC.to_slice)
      output_io.write_bytes(raw.count.to_u32, IO::ByteFormat::LittleEndian)
      output_io.write_bytes(DIMS.to_u32, IO::ByteFormat::LittleEndian)
      output_io.write_bytes(k.to_u32, IO::ByteFormat::LittleEndian)
      output_io.write_bytes(result.max_cell_radius, IO::ByteFormat::LittleEndian)

      raw.count
    end

    # Legacy gzip+JSON loader. Used by `preprocess` and by tests
    # against `example-references.json`.
    def self.load(path : String = DEFAULT_PATH) : References
      File.open(path, "rb") do |file|
        Compress::Gzip::Reader.open(file) do |gz|
          load_from_io(gz)
        end
      end
    end

    # Stream-parse the JSON array from `io` into pre-allocated slices.
    def self.load_from_io(io : IO, capacity : Int32 = DEFAULT_CAPACITY) : References
      pull = JSON::PullParser.new(io)

      vectors = Slice(Int16).new(capacity * DIMS, 0_i16)
      labels  = Slice(UInt8).new(capacity, 0_u8)
      i = 0

      pull.read_array do
        if i >= capacity
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
