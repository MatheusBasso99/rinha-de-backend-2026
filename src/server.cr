require "./mcc_risk"
require "./vectorizer"
require "./references"
require "./ivf"
require "./http_server"

module RinhaDeBackend
  # Composition root: load mmapped references + MCC risks, build the
  # vectorizer/IVF index, then hand control to the raw HTTP/1.1 server
  # in `HttpServer`. Everything below is one-shot startup work; the hot
  # path lives in HttpServer#handle.
  class Server
    DEFAULT_HOST = HttpServer::DEFAULT_HOST
    DEFAULT_PORT = HttpServer::DEFAULT_PORT

    # Period (seconds) between GC.stats snapshots emitted on STDERR. Off
    # the hot path; gives us cheap visibility on whether the heap is
    # actually static under load. 0 disables the monitor.
    GC_STATS_PERIOD = 5

    def initialize(@host : String = DEFAULT_HOST, @port : Int32 = DEFAULT_PORT)
      log_phase "loading mcc_risk"
      mcc_risk = MccRisk.new

      log_phase "mmapping references"
      refs = References.mmap
      log_phase "mmapped #{refs.count} references"

      # Post-madvise warm-up touch. Brings every 4 KiB page into
      # residence and gives khugepaged an opportunity to fold them into
      # 2 MiB transparent huge pages, cutting TLB pressure during cold
      # cluster scans (the dominant tail cause).
      t_pf = Time.instant
      refs.prefault!
      log_phase "prefaulted references in #{(Time.instant - t_pf).total_milliseconds.round(1)}ms"

      vectorizer = Vectorizer.new(mcc_risk)
      ivf = Ivf.new(refs)
      log_phase "ivf ready: k=#{refs.k} base_nprobe=#{ivf.base_nprobe} retry_nprobe=#{ivf.retry_nprobe}"

      # When RINHA_LISTEN_UDS is set the API binds the matching Unix
      # Domain Socket and the LB (HAProxy in prod, see haproxy.cfg) is
      # the only thing talking to it. Empty/unset = TCP fallback
      # (dev + spec runs).
      uds_path = ENV["RINHA_LISTEN_UDS"]?.try { |s| s.empty? ? nil : s }
      @http = HttpServer.new(@host, @port, vectorizer, ivf, uds_path)
    end

    def listen : Nil
      # Hot path is now zero-allocation: HttpServer reuses an 8 KB stack
      # buffer per fiber, the pure-Crystal HttpParser does the parse in
      # place against that buffer, JsonParser writes into a stack struct,
      # response Bytes are pre-rendered constants, and IVF runs over
      # mmapped Int16 slices outside the GC heap. Under those invariants
      # we can drop the collector entirely and remove the last source of
      # tail-latency variance.
      #
      # Safety valve: a watchdog fiber logs GC.stats every few seconds.
      # If heap_size grows monotonically here, we know an allocation
      # leaked into the hot path and can flip back to incremental.
      GC.collect
      GC.disable
      log_phase "GC disabled (heap_size=#{GC.stats.heap_size})"

      spawn gc_stats_loop if GC_STATS_PERIOD > 0

      @http.listen
    end

    private def gc_stats_loop : Nil
      loop do
        sleep GC_STATS_PERIOD.seconds
        s = GC.stats
        log_phase "GC.stats heap_size=#{s.heap_size} free_bytes=#{s.free_bytes} bytes_since_gc=#{s.bytes_since_gc} total=#{s.total_bytes}"
      end
    end

    private def log_phase(msg : String) : Nil
      STDERR.puts "[server] #{Time.utc.to_rfc3339} #{msg}"
      STDERR.flush
    end
  end
end
