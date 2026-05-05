require "json"
require "./normalization"

module RinhaDeBackend
  class MccRisk
    DEFAULT_PATH = "resources/mcc_risk.json"

    @table : Hash(String, Float32)
    # Same data, keyed by the 4 ASCII bytes of the MCC packed into a UInt32
    # ((b0<<24) | (b1<<16) | (b2<<8) | b3). Lets the hot path skip the
    # String allocation that the JSON parser would otherwise need just to
    # hash a 4-character key.
    @packed_table : Hash(UInt32, Float32)

    def initialize(path : String = DEFAULT_PATH)
      raw = File.read(path)
      parsed = Hash(String, Float64).from_json(raw)
      @table = Hash(String, Float32).new(initial_capacity: parsed.size)
      @packed_table = Hash(UInt32, Float32).new(initial_capacity: parsed.size)
      parsed.each do |mcc, risk|
        risk_f32 = risk.to_f32
        @table[mcc] = risk_f32
        if mcc.bytesize == 4
          bytes = mcc.to_slice
          packed = (bytes[0].to_u32 << 24) |
                   (bytes[1].to_u32 << 16) |
                   (bytes[2].to_u32 << 8) |
                   bytes[3].to_u32
          @packed_table[packed] = risk_f32
        end
      end
    end

    def risk_for(mcc : String) : Float32
      @table.fetch(mcc, Normalization::DEFAULT_MCC_RISK)
    end

    @[AlwaysInline]
    def risk_for(mcc_packed : UInt32) : Float32
      @packed_table.fetch(mcc_packed, Normalization::DEFAULT_MCC_RISK)
    end

    def size : Int32
      @table.size
    end
  end
end
