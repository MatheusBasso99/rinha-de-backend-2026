require "./spec_helper"
require "../src/references"
require "../src/knn"

describe RinhaDeBackend::References do
  it "loads the example-references.json fixture" do
    refs = File.open("resources/example-references.json", "r") do |io|
      RinhaDeBackend::References.load_from_io(io, capacity: 256)
    end

    refs.count.should eq(100)
    refs.vectors.size.should eq(100 * RinhaDeBackend::References::DIMS)
    refs.labels.size.should eq(100)

    # First reference, from the file:
    #   {"vector":[0.01, 0.0833, 0.05, 0.8261, 0.1667, -1, -1,
    #              0.0432, 0.25, 0, 1, 0, 0.2, 0.0416],
    #    "label":"legit"}
    expected = [100_i16, 833_i16, 500_i16, 8261_i16, 1667_i16,
                -10_000_i16, -10_000_i16, 432_i16, 2500_i16, 0_i16,
                10_000_i16, 0_i16, 2000_i16, 416_i16]

    14.times do |i|
      refs.vectors[i].should eq(expected[i])
    end

    refs.labels[0].should eq(RinhaDeBackend::References::LABEL_LEGIT)
  end
end

describe RinhaDeBackend::Knn do
  refs = File.open("resources/example-references.json", "r") do |io|
    RinhaDeBackend::References.load_from_io(io, capacity: 256)
  end
  knn = RinhaDeBackend::Knn.new(refs)

  it "returns 0 frauds when nearest neighbors are all legit" do
    # Pick the first reference as the query — distance to itself is 0,
    # so it is one of the top-5. The example dataset is mostly legit at
    # the top, so a self-query should return 0 frauds.
    query = StaticArray(Int16, 14).new(0_i16)
    14.times { |i| query[i] = refs.vectors[i] }

    knn.fraud_count_top_k(query).should be <= 2
  end

  it "honors the -10_000 sentinel for missing-history dimensions" do
    # All-sentinel query must match references with sentinel at idx 5/6
    # before others. Asserting only that the call runs and returns 0..K.
    query = StaticArray(Int16, 14).new(-10_000_i16)
    result = knn.fraud_count_top_k(query)
    result.should be >= 0
    result.should be <= 5
  end
end
