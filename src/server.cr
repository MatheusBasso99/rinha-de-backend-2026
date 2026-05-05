require "http/server"
require "./mcc_risk"
require "./vectorizer"
require "./references"
require "./ivf"
require "./actions/ready_action"
require "./actions/fraud_score_action"

@[Link("gc")]
lib LibGC
  fun enable_incremental = GC_enable_incremental : Void
end

module RinhaDeBackend
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9999

    @routes : Hash(Tuple(String, String), BaseAction)

    def initialize(@host : String = DEFAULT_HOST, @port : Int32 = DEFAULT_PORT)
      log_phase "loading mcc_risk"
      mcc_risk = MccRisk.new

      log_phase "mmapping references"
      refs = References.mmap
      log_phase "mmapped #{refs.count} references"

      vectorizer = Vectorizer.new(mcc_risk)
      ivf = Ivf.new(refs)
      log_phase "ivf ready: k=#{refs.k} nprobe=#{Ivf::DEFAULT_NPROBE}"

      @routes = build_routes(vectorizer, ivf)
    end

    def listen : Nil
      # Switch BDW GC into incremental mode: instead of stopping the
      # world for one long mark cycle, the collector does small slices
      # interleaved with mutator work. Trade-off: a bit more total
      # CPU for a much flatter tail. We rely on this because the hot
      # path still allocates inside HTTP::Server (per-request Request /
      # Response / header Hashes); a full GC.disable would OOM in
      # seconds. See TODO.md for the planned move off HTTP::Server.
      GC.collect
      LibGC.enable_incremental
      log_phase "GC incremental mode enabled (heap_size=#{GC.stats.heap_size})"

      log_phase "listening on #{@host}:#{@port}"
      server = HTTP::Server.new do |context|
        dispatch(context)
      end
      server.bind_tcp(@host, @port)
      server.listen
    end

    private def build_routes(vectorizer : Vectorizer, ivf : Ivf) : Hash(Tuple(String, String), BaseAction)
      actions = [
        ReadyAction.new,
        FraudScoreAction.new(vectorizer, ivf),
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
