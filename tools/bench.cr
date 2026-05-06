require "http/client"
require "json"
require "time"

# Lightweight latency bench against POST /fraud-score on the running stack.
# Keep-alive `HTTP::Client` per fiber, p50/p95/p99/p99.9/max + rps.
#
# Usage: crystal run --release tools/bench.cr -- N C [HOST] [PORT]
#   N     total requests
#   C     concurrency (fibers, each with its own HTTP::Client + keep-alive)
#   HOST  default localhost
#   PORT  default 9999
#
# Workload: every request `g` (0..total-1) maps to
# `payloads[g % 50]` over `resources/example-payloads.json`. Two
# runs of the bench send the exact same payload sequence in the
# same order — fair A/B. Single-payload benches understated the
# per-query work (in-set queries land on top of their centroid and
# `break` fires inside 2-3 dims), so this rotation is the canonical
# bench from iter 7 onward.
#
# Bench is zero-persist; the result line goes to STDOUT in the same
# shape `/tmp/bench` used.

n = (ARGV[0]? || "10000").to_i
c = (ARGV[1]? || "1").to_i
host = ARGV[2]? || "localhost"
port = (ARGV[3]? || "9999").to_i

raise "n must be > 0" if n <= 0
raise "c must be > 0" if c <= 0

raw_payloads = JSON.parse(File.read("resources/example-payloads.json")).as_a
bodies       = raw_payloads.map(&.to_json)
size         = bodies.size

per_fiber = n // c
extra     = n % c
total     = (per_fiber * c) + extra

latencies = Slice(Float64).new(total, 0.0)
errors    = Atomic(Int32).new(0)
done      = Channel(Nil).new(c)

start_t = Time.instant

c.times do |fi|
  spawn do
    client = HTTP::Client.new(host, port)
    client.read_timeout = 30.seconds
    headers = HTTP::Headers{"Content-Type" => "application/json"}

    count = per_fiber + (fi < extra ? 1 : 0)
    base  = fi * per_fiber + Math.min(fi, extra)

    count.times do |k|
      g = base + k
      body = bodies[g % size]
      t0 = Time.instant
      begin
        resp = client.post("/fraud-score", headers: headers, body: body)
        if resp.status_code != 200
          errors.add(1)
        end
      rescue
        errors.add(1)
      end
      dt = (Time.instant - t0).total_milliseconds
      latencies[g] = dt
    end

    client.close rescue nil
    done.send(nil)
  end
end

c.times { done.receive }

elapsed = (Time.instant - start_t).total_seconds
sorted  = latencies.to_a.sort!
pick    = ->(p : Float64) { sorted[((sorted.size - 1) * p).to_i] }
p50     = pick.call(0.50)
p95     = pick.call(0.95)
p99     = pick.call(0.99)
p999    = pick.call(0.999)
mx      = sorted[-1]
rps     = total / elapsed

printf "n=%d c=%d payloads=%d elapsed=%.2fs rps=%.1f errors=%d p50=%.2fms p95=%.2fms p99=%.2fms p99.9=%.2fms max=%.2fms\n",
  total, c, size, elapsed, rps, errors.get, p50, p95, p99, p999, mx
