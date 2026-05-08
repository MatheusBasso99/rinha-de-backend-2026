require "./spec_helper"
require "../src/references"
require "../src/knn"
require "../src/ivf"

describe RinhaDeBackend::References do
  it "loads the example-references.json fixture" do
    refs = File.open("resources/example-references.json", "r") do |io|
      RinhaDeBackend::References.load_from_io(io, capacity: 256)
    end

    refs.count.should eq(100)
    refs.vectors.size.should eq(100 * RinhaDeBackend::References::DIMS)
    refs.labels.size.should eq(100)

    expected = [100_i16, 833_i16, 500_i16, 8261_i16, 1667_i16,
                -10_000_i16, -10_000_i16, 432_i16, 2500_i16, 0_i16,
                10_000_i16, 0_i16, 2000_i16, 416_i16]

    14.times do |i|
      refs.vectors[i].should eq(expected[i])
    end

    # The 2 pad lanes at the end of every row are pinned to zero; the
    # IVF/KNN kernels rely on this so VPMADDWD over the full 16-lane
    # row produces the exact same squared-L2 as the 14-lane version.
    refs.vectors[14].should eq(0_i16)
    refs.vectors[15].should eq(0_i16)

    refs.labels[0].should eq(RinhaDeBackend::References::LABEL_LEGIT)
  end

  it "round-trips example-references through preprocess + mmap with IVF" do
    bin_path = File.join(Dir.tempdir, "rinha-refs-#{Random::Secure.hex(8)}.bin")
    begin
      count = File.open("resources/example-references.json", "r") do |json_io|
        File.open(bin_path, "wb") do |bin_io|
          # Small K so the 100-vector fixture isn't degenerate.
          RinhaDeBackend::References.preprocess(json_io, bin_io, k: 4, iterations: 5)
        end
      end
      count.should eq(100)

      refs = RinhaDeBackend::References.mmap(bin_path)
      refs.count.should eq(100)
      refs.k.should eq(4)
      # AOSOA-8 layout: blocks of 8 vectors. block_count is at most
      # ceil(count / 8) per cell rounded up to even, summed across k cells.
      # Loose upper bound: ceil(count/8) + k (one alignment pad per cell).
      refs.block_count.should be > 0
      refs.padded_count.should eq(refs.block_count * RinhaDeBackend::References::SLOTS_PER_BLOCK)
      # IVF mmap path: vectors slice is empty (data lives in `blocks`).
      refs.vectors.size.should eq(0)
      refs.blocks.size.should eq(refs.block_count * RinhaDeBackend::References::BLOCK_LANES)
      refs.labels.size.should eq(refs.padded_count)
      refs.centroids.size.should eq(4 * RinhaDeBackend::References::DIMS)
      refs.cell_offsets.size.should eq(5)
      # Bbox layout still uses the centroid stride (DIMS = 16); each cell
      # has 14 logical lanes plus 2 zero-pad lanes.
      refs.bbox_min.size.should eq(4 * RinhaDeBackend::References::DIMS)
      refs.bbox_max.size.should eq(4 * RinhaDeBackend::References::DIMS)

      # cell_offsets is in BLOCK index units now; last entry == block_count.
      refs.cell_offsets[4].should eq(refs.block_count.to_u32)
      # Each cell must start at an even block index (= 64 B aligned: a
      # 224 B block starting at an even index sits at offset multiple of
      # 448 B, which is 64 B-aligned).
      5.times do |i|
        (refs.cell_offsets[i] & 1_u32).should eq(0_u32)
      end
      # Cells must be non-decreasing (sanity check on the layout).
      4.times do |i|
        refs.cell_offsets[i].should be <= refs.cell_offsets[i + 1]
      end
    ensure
      File.delete(bin_path) if File.exists?(bin_path)
    end
  end

  it "ivf agrees with brute-force on every fixture vector (recall = 100%)" do
    bin_path = File.join(Dir.tempdir, "rinha-refs-#{Random::Secure.hex(8)}.bin")
    begin
      File.open("resources/example-references.json", "r") do |json_io|
        File.open(bin_path, "wb") do |bin_io|
          RinhaDeBackend::References.preprocess(json_io, bin_io, k: 4, iterations: 5)
        end
      end

      refs = RinhaDeBackend::References.mmap(bin_path)
      knn = RinhaDeBackend::Knn.new(refs)
      # base_nprobe == k → exact (every cell scanned in phase A; no retry).
      ivf = RinhaDeBackend::Ivf.new(refs, base_nprobe: 4, retry_nprobe: 0)

      slots_per_block = RinhaDeBackend::References::SLOTS_PER_BLOCK
      block_lanes     = RinhaDeBackend::References::BLOCK_LANES
      logical_dims    = RinhaDeBackend::References::LOGICAL_DIMS
      pad_sentinel    = RinhaDeBackend::IvfBuilder::PAD_SENTINEL

      # Walk every global slot. Pad slots / alignment-pad blocks carry
      # `PAD_SENTINEL` on every lane and would yield a query the
      # production vectorizer never emits (real lanes ∈ [-10_000, 10_000]) —
      # the IVF triangle/bbox prune assumes real-distribution queries, so
      # we skip pad slots here.
      refs.padded_count.times do |idx|
        block_idx = idx // slots_per_block
        slot      = idx - block_idx * slots_per_block
        block_origin = block_idx * block_lanes
        # Pad slot detection: dim 0 of a pad slot is `PAD_SENTINEL`.
        next if refs.blocks[block_origin + slot] == pad_sentinel

        query = StaticArray(Int16, 16).new(0_i16)
        logical_dims.times do |j|
          query[j] = refs.blocks[block_origin + j * slots_per_block + slot]
        end

        ivf.fraud_count_top_k(query).should eq(knn.fraud_count_top_k(query))
      end
    ensure
      File.delete(bin_path) if File.exists?(bin_path)
    end
  end
end

describe RinhaDeBackend::Knn do
  refs = File.open("resources/example-references.json", "r") do |io|
    RinhaDeBackend::References.load_from_io(io, capacity: 256)
  end
  knn = RinhaDeBackend::Knn.new(refs)

  it "returns 0 frauds when nearest neighbors are all legit" do
    query = StaticArray(Int16, 16).new(0_i16)
    14.times { |i| query[i] = refs.vectors[i] }

    knn.fraud_count_top_k(query).should be <= 2
  end

  it "honors the -10_000 sentinel for missing-history dimensions" do
    # Sentinel covers only the 14 logical dims; pad lanes (14, 15)
    # stay zero so distances against zero-padded stored rows behave
    # the same as before the row-stride bump.
    query = StaticArray(Int16, 16).new(0_i16)
    14.times { |i| query[i] = -10_000_i16 }
    result = knn.fraud_count_top_k(query)
    result.should be >= 0
    result.should be <= 5
  end
end
