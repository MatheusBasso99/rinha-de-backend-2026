require "json"

module RinhaDeBackend
  struct Transaction
    include JSON::Serializable

    getter amount : Float64
    getter installments : Int32
    getter requested_at : Time
  end

  struct Customer
    include JSON::Serializable

    getter avg_amount : Float64
    getter tx_count_24h : Int32
    getter known_merchants : Array(String)
  end

  struct Merchant
    include JSON::Serializable

    getter id : String
    getter mcc : String
    getter avg_amount : Float64
  end

  struct Terminal
    include JSON::Serializable

    getter is_online : Bool
    getter card_present : Bool
    getter km_from_home : Float64
  end

  struct LastTransaction
    include JSON::Serializable

    getter timestamp : Time
    getter km_from_current : Float64
  end

  struct FraudScoreRequest
    include JSON::Serializable

    getter id : String
    getter transaction : Transaction
    getter customer : Customer
    getter merchant : Merchant
    getter terminal : Terminal
    getter last_transaction : LastTransaction?
  end
end
