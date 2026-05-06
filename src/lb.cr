require "socket"

module RinhaDeBackend
  # Legacy round-robin TCP→UDS load balancer.
  #
  # The production LB is now HAProxy (see `haproxy.cfg` and the `lb`
  # service in `docker-compose.yml`). This Crystal LB is kept in the
  # tree for reference / fallback and is still built into the runtime
  # image as `/usr/local/bin/rinha_lb`, but no compose service invokes
  # it by default.
  #
  # Behaviour (preserved as documented for the historical iteration):
  # the challenge rules forbid the LB from inspecting payload or
  # running business logic, so this is a strict bidirectional byte
  # copy between the client (TCP) and the picked upstream (UDS), with
  # round-robin upstream selection at connection-accept time.
  #
  # Original design rationale (vs. the older nginx LB):
  #
  #   1. UDS skips the TCP/IP stack on the LB→API hop entirely (no port
  #      allocation, no Nagle, no port reuse pressure under k6 storms).
  #   2. The previous nginx allowance was paying for an HTTP-aware proxy
  #      with logging/templates/configuration parsing. The static Crystal
  #      binary is ~3 MB and runs on tens of KB of working set per
  #      connection. HAProxy (in `mode tcp`) keeps both wins.
  #
  # Concurrency model
  # -----------------
  # Built on `Fiber::ExecutionContext::Parallel` (Crystal 1.20 stdlib,
  # https://crystal-lang.org/api/1.20.0/Fiber/ExecutionContext/Parallel.html).
  # All fibers — accept loop, c2s and s2c forwarders — live in the same
  # parallel context, so they can be resumed by any of N scheduler
  # threads. Even at the 0.10 CPU cgroup ceiling assigned to the LB,
  # the parallel context lets a sibling fiber make progress while a
  # peer is parked inside an `epoll_wait` — which is essentially the
  # whole LB workload.
  #
  # Round-robin selection uses an `Atomic(UInt32)` counter; with N
  # parallel schedulers we'd race a plain integer. Atomic increment is
  # one `lock xadd` on x86-64.
  #
  # Lifecycle of one downstream connection
  # --------------------------------------
  #   1. accept_loop fiber accepts a TCP socket.
  #   2. It picks the next upstream UDS path (`@rr.add(1) % N`) and
  #      opens a new UNIXSocket — one upstream connection per
  #      downstream connection.
  #   3. Spawns a c2s fiber (downstream→upstream copy). The current
  #      fiber drives the s2c copy itself; when either side closes,
  #      both sockets are closed and both copy fibers unwind.
  class Lb
    DEFAULT_HOST        = "0.0.0.0"
    DEFAULT_PORT        = 9999
    DEFAULT_PARALLELISM = 2

    # 16 KiB per direction, stack-allocated. The Rinha hot path
    # request/response pair is well under 1 KiB, so most copy() calls
    # do a single read+write. The headroom matters for the body of
    # a slow client where the kernel may hand us partial reads — we
    # still complete each loop iteration in a single syscall pair.
    BUF_SIZE = 16384

    def initialize(@host : String,
                   @port : Int32,
                   @upstreams : Array(String),
                   @parallelism : Int32 = DEFAULT_PARALLELISM)
      raise "lb: at least one upstream required" if @upstreams.empty?
      raise "lb: parallelism must be >= 1" if @parallelism < 1
      @rr = Atomic(UInt32).new(0_u32)
    end

    def listen : Nil
      ctx = Fiber::ExecutionContext::Parallel.new("lb", @parallelism)
      log "starting (parallelism=#{@parallelism}) → #{@upstreams.join(", ")}"

      # Run the accept loop inside the parallel context so every fiber
      # spawned from it inherits the same context and can migrate
      # across scheduler threads. The main fiber blocks on `done` until
      # the accept loop exits (either a fatal error or process signal).
      done = Channel(Nil).new
      ctx.spawn(name: "lb-accept") do
        accept_loop(ctx)
      rescue ex
        log "accept loop terminated: #{ex.message}"
      ensure
        done.send(nil)
      end
      done.receive
    end

    private def accept_loop(ctx : Fiber::ExecutionContext::Parallel) : Nil
      tcp = TCPServer.new(@host, @port, reuse_port: false)
      tcp.reuse_address = true
      log "listening on #{@host}:#{@port}"

      loop do
        client = tcp.accept
        ctx.spawn(name: "lb-conn") do
          handle(client, ctx)
        end
      end
    end

    # Picks the next upstream, opens the UDS, and pairs the two
    # sockets via two byte-copy fibers. The s2c direction runs on the
    # current fiber so we don't need a join channel: when this method
    # returns, the caller's outer rescue/ensure shuts down both sides
    # and the c2s fiber unwinds on its next read against a closed
    # socket.
    private def handle(client : TCPSocket, ctx : Fiber::ExecutionContext::Parallel) : Nil
      client.read_buffering = false
      client.sync = true
      client.tcp_nodelay = true

      # Atomic round-robin: lock xadd on x86-64. With N parallel
      # schedulers a plain `@i += 1` would race; with Parallel(1) it
      # would still work but the atomic costs the same once it lands
      # in cache.
      idx = (@rr.add(1_u32) % @upstreams.size.to_u32).to_i32
      path = @upstreams.unsafe_fetch(idx)

      upstream = UNIXSocket.new(path)
      upstream.read_buffering = false
      upstream.sync = true

      # c2s direction: spawn a fiber. When it returns, ensure tears
      # down both sockets so the s2c read on this fiber unblocks too.
      ctx.spawn(name: "lb-c2s") do
        copy(client, upstream)
      ensure
        upstream.close rescue nil
        client.close rescue nil
      end

      # s2c direction: drive on the current fiber.
      copy(upstream, client)
    rescue ex : IO::Error | Socket::Error
      # Peer reset, upstream unavailable mid-handshake, etc. Drop
      # the connection — there's nothing useful to log per request
      # at the LB layer.
    ensure
      client.close rescue nil
    end

    @[AlwaysInline]
    private def copy(src : IO, dst : IO) : Nil
      buf_storage = uninitialized StaticArray(UInt8, BUF_SIZE)
      buf = buf_storage.to_slice
      loop do
        n = src.read(buf)
        break if n == 0
        dst.write(buf[0, n])
      end
    rescue IO::Error
      # Treat closed-mid-copy as a clean end of stream.
    end

    private def log(msg : String) : Nil
      STDERR.puts "[lb] #{Time.utc.to_rfc3339} #{msg}"
      STDERR.flush
    end
  end
end
