module RinhaDeBackend
  # Normalization constants from resources/normalization.json. The file
  # never changes during the test, so we bake the values in.
  module Normalization
    MAX_AMOUNT              = 10_000.0_f32
    MAX_INSTALLMENTS        =     12.0_f32
    AMOUNT_VS_AVG_RATIO     =     10.0_f32
    MAX_MINUTES             =  1_440.0_f32
    MAX_KM                  =  1_000.0_f32
    MAX_TX_COUNT_24H        =     20.0_f32
    MAX_MERCHANT_AVG_AMOUNT = 10_000.0_f32

    DEFAULT_MCC_RISK = 0.5_f32
  end
end
