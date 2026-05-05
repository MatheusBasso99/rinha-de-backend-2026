require "./base_action"

module RinhaDeBackend
  class ReadyAction < BaseAction
    route "GET", "/ready"

    def call(context : HTTP::Server::Context) : Nil
      respond_empty(context, 200)
    end
  end
end
