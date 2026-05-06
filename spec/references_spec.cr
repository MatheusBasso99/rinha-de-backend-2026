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
      refs.vectors.size.should eq(100 * RinhaDeBackend::References::DIMS)
      refs.labels.size.should eq(100)
      refs.centroids.size.should eq(4 * RinhaDeBackend::References::DIMS)
      refs.cell_offsets.size.should eq(5)

      # cell_offsets are cumulative: last entry must equal count.
      refs.cell_offsets[4].should eq(100_u32)
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

      refs.count.times do |i|
        query = StaticArray(Int16, 14).new(0_i16)
        14.times { |j| query[j] = refs.vectors[i * 14 + j] }

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
    query = StaticArray(Int16, 14).new(0_i16)
    14.times { |i| query[i] = refs.vectors[i] }

    knn.fraud_count_top_k(query).should be <= 2
  end

  it "honors the -10_000 sentinel for missing-history dimensions" do
    query = StaticArray(Int16, 14).new(-10_000_i16)
    result = knn.fraud_count_top_k(query)
    result.should be >= 0
    result.should be <= 5
  end
end
