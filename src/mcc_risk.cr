require "json"
require "./normalization"

module RinhaDeBackend
  class MccRisk
    DEFAULT_PATH = "resources/mcc_risk.json"

    @table : Hash(String, Float32)

    def initialize(path : String = DEFAULT_PATH)
      raw = File.read(path)
      parsed = Hash(String, Float64).from_json(raw)
      @table = Hash(String, Float32).new(initial_capacity: parsed.size)
      parsed.each { |mcc, risk| @table[mcc] = risk.to_f32 }
    end

    def risk_for(mcc : String) : Float32
      @table.fetch(mcc, Normalization::DEFAULT_MCC_RISK)
    end

    def size : Int32
      @table.size
    end
  end
end
