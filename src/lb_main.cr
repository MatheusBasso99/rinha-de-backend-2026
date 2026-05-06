require "./lb"

# Entry point for the legacy Crystal LB binary. The production LB is
# now HAProxy (see haproxy.cfg / docker-compose.yml); this entrypoint
# is kept for reference / local experimentation. Reads the runtime
# config from env vars so the same image can run any of (api1, api2,
# rinha_lb).
#
#   RINHA_LB_HOST         — bind address      (default 0.0.0.0)
#   RINHA_LB_PORT         — bind port         (default 9999)
#   RINHA_UPSTREAMS       — comma-separated UDS paths (required)
#   RINHA_LB_PARALLELISM  — schedulers        (default 2)
#
# Build with:
#   crystal build --release --no-debug --static --mcpu=haswell \
#                 -Dpreview_mt -Dexecution_context \
#                 -o rinha_lb src/lb_main.cr
#
# Both `-Dpreview_mt` and `-Dexecution_context` are required by the
# stdlib — `Fiber::ExecutionContext::Parallel` is gated behind those
# flags in Crystal 1.20.

host = ENV["RINHA_LB_HOST"]? || RinhaDeBackend::Lb::DEFAULT_HOST
port = (ENV["RINHA_LB_PORT"]? || RinhaDeBackend::Lb::DEFAULT_PORT.to_s).to_i

raw = ENV["RINHA_UPSTREAMS"]? || ""
upstreams = raw.split(',').map(&.strip).reject(&.empty?)
if upstreams.empty?
  STDERR.puts "[lb] fatal: RINHA_UPSTREAMS env var is empty (expected comma-separated UDS paths)"
  exit 2
end

parallelism = (ENV["RINHA_LB_PARALLELISM"]? || RinhaDeBackend::Lb::DEFAULT_PARALLELISM.to_s).to_i

RinhaDeBackend::Lb.new(host, port, upstreams, parallelism).listen
