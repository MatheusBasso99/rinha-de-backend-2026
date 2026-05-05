require "http/server"
require "./actions/ready_action"
require "./actions/fraud_score_action"

module RinhaDeBackend
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9999

    @routes : Hash(Tuple(String, String), BaseAction)

    def initialize(@host : String = DEFAULT_HOST, @port : Int32 = DEFAULT_PORT)
      @routes = build_routes
    end

    def listen : Nil
      server = HTTP::Server.new do |context|
        dispatch(context)
      end
      server.bind_tcp(@host, @port)
      server.listen
    end

    private def build_routes : Hash(Tuple(String, String), BaseAction)
      actions = [
        ReadyAction.new,
        FraudScoreAction.new,
      ] of BaseAction

      actions.each_with_object({} of Tuple(String, String) => BaseAction) do |action, table|
        table[{action.http_method, action.path}] = action
      end
    end

    private def dispatch(context : HTTP::Server::Context) : Nil
      key = {context.request.method, context.request.path}
      if action = @routes[key]?
        action.call(context)
      else
        context.response.status_code = 404
      end
    end
  end
end
