require "http/server"
require "./mcc_risk"
require "./vectorizer"
require "./references"
require "./knn"
require "./actions/ready_action"
require "./actions/fraud_score_action"

module RinhaDeBackend
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9999

    @routes : Hash(Tuple(String, String), BaseAction)

    def initialize(@host : String = DEFAULT_HOST, @port : Int32 = DEFAULT_PORT)
      log_phase "loading mcc_risk"
      mcc_risk = MccRisk.new

      log_phase "loading references"
      refs = References.load
      log_phase "loaded #{refs.count} references"

      vectorizer = Vectorizer.new(mcc_risk)
      knn = Knn.new(refs)

      @routes = build_routes(vectorizer, knn)
    end

    def listen : Nil
      log_phase "listening on #{@host}:#{@port}"
      server = HTTP::Server.new do |context|
        dispatch(context)
      end
      server.bind_tcp(@host, @port)
      server.listen
    end

    private def build_routes(vectorizer : Vectorizer, knn : Knn) : Hash(Tuple(String, String), BaseAction)
      actions = [
        ReadyAction.new,
        FraudScoreAction.new(vectorizer, knn),
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

    private def log_phase(msg : String) : Nil
      STDERR.puts "[server] #{Time.utc.to_rfc3339} #{msg}"
      STDERR.flush
    end
  end
end
