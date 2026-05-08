# Rinha de Backend 2026 — Fraud Detection with Vector Search

This project is the submission for **Rinha de Backend 2026** using **Crystal lang 1.20.0**.

## Canonical documentation (always consult)

- **Official repo**: https://github.com/zanfranceschi/rinha-de-backend-2026
- **Challenge docs (English)**: https://github.com/zanfranceschi/rinha-de-backend-2026/tree/main/docs/en
  - `README.md`, `API.md`, `ARCHITECTURE.md`, `EVALUATION.md`,
    `VECTOR_SEARCH.md`, `DATASET.md`, `DETECTION_RULES.md`,
    `SUBMISSION.md`, `FAQ.md`
- **Crystal lang API 1.20.1** (always cross-check before writing stdlib code):
  https://crystal-lang.org/api/1.20.1/
  - For any doubt about stdlib (`HTTP::Server`, `JSON`, `Channel`, `Fiber`,
    `Slice`, `Math`, `Compress::Gzip`, etc.), open the page for that exact
    version. Do not invent APIs — read the corresponding page on
    `crystal-lang.org/api/1.20.1/`.
- **Crystal GC module**: https://crystal-lang.org/api/1.20.1/GC.html
  (used by the GC strategy below).

## Project working notes (read these before iterating)

Living documents at the repo root — consult the relevant one before
proposing changes in its area, and update it after landing the change.

- **`SUBMISSION.md`** *(checked in)* — end-to-end submission flow:
  pre-submission validation gates, `docker buildx` for `linux/amd64`,
  publishing to `ghcr.io/matheusbasso99/rinha-de-backend-2026`, syncing
  the `submission` branch (compose-only artifacts), and opening the
  `rinha/test` issue. The single source of truth for "how do I ship
  this iteration".
- **`OFICIAL_RESULTS.md`** *(gitignored, local-only)* — **ground truth**.
  Each entry pins the **commit + image tag** that ran on the official
  Mac Mini Late 2014, the bot's raw JSON result, and the **delta vs the
  matching `RESULTS.md` entry** (= the Apple-Silicon-Rosetta vs
  Haswell-U gap). Read this before deciding which optimisation is worth
  the next official run.
- **`RESULTS.md`** *(gitignored, local-only)* — local k6 benchmark log
  on M-series + Docker `linux/amd64` (Rosetta). Each iteration records
  configuration, measurement, and delta vs the previous iteration.
  Subjective under emulation — useful for relative comparisons between
  iterations, **not** for predicting the official score (use
  `OFICIAL_RESULTS.md` for that).
- **`FP_FN_TODO.md`** *(gitignored, local-only)* — backlog for reducing
  False Positives / False Negatives (`score_det`). Tiers ordered by
  expected `E = 1·FP + 3·FN + 5·Err` reduction per unit latency cost.
  Status header tracks whether detection is currently saturated at the
  +3000 ceiling on the official rig (if so, items here score zero until
  a regression brings `E` back above zero).
- **`PERFORMANCE_TODO.md`** *(gitignored, local-only)* — backlog for
  reducing p99 (`score_p99`) on the official Haswell-U target. Tiers
  ordered by expected p99 win per hour of effort, with explicit Haswell
  vs modern-OOO caveats. Read this before any micro-optimisation
  proposal.

## Challenge theme

Build the **`fraud-score`** module: for each transaction, transform the payload
into a **14-dimension vector**, find the **5 nearest neighbors** in the
reference dataset (3 million labeled vectors) and answer with `approved` and
`fraud_score = number_of_frauds / 5`. Fixed threshold: `0.6`.

## Endpoints (port 9999)

- `GET /ready` → `2xx` once the API is ready.
- `POST /fraud-score` → receives the transaction, returns
  `{ "approved": bool, "fraud_score": number }`.

Full field contract: `docs/en/API.md`.

## Vectorization (14 dimensions)

Fixed order, normalization via `clamp(x, 0.0, 1.0)` except indices 5 and 6
(which can be `-1` when `last_transaction == null`):

| idx | dimension | formula |
|-----|-----------|---------|
| 0 | `amount` | `amount / max_amount` |
| 1 | `installments` | `installments / max_installments` |
| 2 | `amount_vs_avg` | `(amount / customer.avg_amount) / amount_vs_avg_ratio` |
| 3 | `hour_of_day` | `hour(requested_at) / 23` (UTC) |
| 4 | `day_of_week` | `dow(requested_at) / 6` (Mon=0, Sun=6) |
| 5 | `minutes_since_last_tx` | `min / max_minutes` or `-1` |
| 6 | `km_from_last_tx` | `km / max_km` or `-1` |
| 7 | `km_from_home` | `km_from_home / max_km` |
| 8 | `tx_count_24h` | `tx_count_24h / max_tx_count_24h` |
| 9 | `is_online` | `1` or `0` |
| 10 | `card_present` | `1` or `0` |
| 11 | `unknown_merchant` | `1` if `merchant.id ∉ known_merchants` |
| 12 | `mcc_risk` | `mcc_risk[mcc]` (default `0.5`) |
| 13 | `merchant_avg_amount` | `merchant.avg_amount / max_merchant_avg_amount` |

Constants in `resources/normalization.json`. MCC risks in
`resources/mcc_risk.json`.

## Reference dataset

- `references.json.gz` — 3,000,000 labeled vectors (`fraud` / `legit`),
  ~48 MB gzipped / ~284 MB uncompressed. Re-downloadable from the official
  repo; gitignored, baked into the Docker image at build time.
- `mcc_risk.json` — risk per MCC (default `0.5`).
- `normalization.json` — constants.

**The files do not change between test runs.** Pre-processing happens at
Docker build time (multi-minute k-means pass) and ships as a binary blob
in the runtime image; startup is just `open + mmap`.

## Current architecture (what the code actually does)

This section reflects the **shipped implementation**, not options on the
table. Update it when behavior changes — `CLAUDE.md` is the contract.

### Search

- **IVF index** (`src/ivf.cr`, `src/ivf_builder.cr`): `k = 2048` cells,
  two-phase probe with `base_nprobe = 8` and `retry_nprobe = 16`
  (phase B only fires when the top-5 lands at the decision edge,
  `frauds ∈ {2, 3}`), top-K = 5. Forgy init, 5 k-means iterations,
  fixed seed.
- **Int16 quantization**: vectors and centroids stored as `Int16` with a
  `× 10_000` scale (`src/references.cr`). Distance math is integer-domain.
- **Cell-level pruning** (`src/ivf.cr`):
  - **Triangle-inequality** using the cell's `cell_radius` and the
    global `max_cell_radius` (decision-aware outer break).
  - **Per-cell axis-aligned bounding box** (`bbox_min` / `bbox_max`):
    tighter than triangle in high-dim corners, exact.
  - **Decision-aware early exit**: once ≥3 frauds or ≥3 legits lock into
    the top-5, the answer cannot flip — short-circuit the whole probe.
- **Inner-loop chunked early exit**: per-vector L2 evaluated in 4-dim
  chunks (4/4/4/2), partial-sum compared against the current `worst`
  between chunks; auto-vectorisable straight-line code per chunk.
- **No HNSW, no VP-Tree, no exact brute-force.** Recall measured offline
  via `tools/validate_recall.cr`.

### `references.bin` layout (mmap, `MAP_POPULATE`)

64-byte header, then six contiguous sections — all little-endian:

| section | type | size |
|---|---|---|
| header | `"RNH6"` magic + `count u32` + `dims u32` + `k u32` + `max_cell_radius u32` + `padded_count u32` + 40 B padding | 64 B |
| vectors | `padded_count × dims × Int16`, reordered by cell, each cell starts at an even row index (= 64 B aligned) | ~84 MiB |
| labels | `padded_count × UInt8` (0=legit, 1=fraud) | ~3 MiB |
| centroids | `k × dims × Int16` | ~57.3 KiB |
| cell offsets | `(k + 1) × UInt32`, every entry even | ~8.2 KiB |
| cell radii | `k × UInt32` | ~8 KiB |
| bbox min | `k × dims × Int16` | ~57.3 KiB |
| bbox max | `k × dims × Int16` | ~57.3 KiB |

`padded_count` is `count` plus up to one tail pad row per odd-sized cell
(≤ k extra rows ≈ 64 KiB at k=2048). Pad rows carry
`IvfBuilder::PAD_SENTINEL = Int16::MAX` on every lane so they cannot
enter the top-5 ranking for any production query — real lanes live in
[-10000, 10000], so the per-lane diff² ≥ 22767² × 14 dominates any real
worst case. The sentinel keeps brute-force loaders that walk the slice
linearly correct without needing to skip pads. `cell_radius` and the
bbox are computed over real rows only (pad rows would torpedo every
triangle / bbox prune); the runtime kernel iterates the full padded
range per cell, but the prune logic stays sound.

Total: **~84 MiB**, mmaped at boot with `MAP_POPULATE` so the first
request doesn't pay page-fault cost. `prefault!` walks one byte every
4 KiB after `MADV_HUGEPAGE` to give khugepaged a chance to fold pages
into 2 MiB transparent huge pages.

### HTTP

- **`TCPServer` raw** (or **`UNIXServer`** when `RINHA_LISTEN_UDS` is
  set — the LB→API hop runs over UDS), no `HTTP::Server`, no framework
  (`src/http_server.cr`). One fiber per connection (`spawn handle`).
- **HTTP parser 100% Crystal** (`src/http_parser.cr`) — `picohttpparser`
  was removed; there is no C dependency anymore.
- **Keep-alive** by default (HTTP/1.1); only `Connection: close` triggers
  shutdown. On TCP: `TCP_NODELAY=true`, `sync=true`, `read_buffering=false`.
  On UDS: `sync=true`, `read_buffering=false` (no Nagle).
- **Stack-allocated 8 KiB read buffer** per fiber, reused across
  requests on the same connection.
- **Pre-rendered responses**: the 6 possible `{approved, fraud_score}`
  bodies (`0.0/0.2/0.4/0.6/0.8/1.0`) are precomputed slices.

### Load balancer

- **HAProxy `lts-alpine`** (`haproxy.cfg`) is the production LB. Image
  `haproxy:lts-alpine` (3.2.x). Runs in `mode tcp` with
  `balance roundrobin` over UDS backends — pure byte-passthrough, no
  HTTP parsing in the LB, matching the rinha rule of "no business logic
  in the LB".
- Frontend: `bind *:9999` (TCP). Backend: `server api1 /sockets/api1.sock`
  + `server api2 /sockets/api2.sock`. LB→API hop is `AF_UNIX`, skipping
  the TCP/IP stack on the loopback (no port allocation, no Nagle, no port
  reuse pressure under k6 storms).
- Tuning: `nbthread 1` (the 0.10 CPU cap throttles aggregate throughput
  regardless of thread count), `maxconn 512`, `tune.bufsize 8192` —
  buffer pool sized to fit inside the 16 MB cgroup envelope.
- Runs as `user: "0:0"` in compose. The API binds its UDS with default
  mode `0755 root:root`; the haproxy image's worker uid 99 would
  otherwise hit `EACCES` on `connect()`. Stays inside the container.
- The legacy Crystal LB (`src/lb.cr` + `src/lb_main.cr`, built into the
  image as `/usr/local/bin/rinha_lb` via `-Dpreview_mt -Dexecution_context`)
  is kept in the tree for reference but is no longer the entrypoint of the
  `lb` service. The HAProxy migration was the LB swap iteration.

### JSON

- **Custom zero-alloc parser** (`src/json_parser.cr`). The hot path stores
  offsets + lengths into the original buffer — no `String` allocations.
- `ParsedRequest` (`src/parsed_request.cr`) is a stack struct holding
  those offsets.
- `JSON` from stdlib is used **only at preprocess time**, never on the
  hot path.

### Vectorizer

- 14 dims (table above), produces a `StaticArray(Float32, 14)` reused
  per request (stack-allocated). Two overloads: zero-alloc (offsets)
  and object-based (used in specs only).

### Decision

1. Vectorize payload (14 dims).
2. IVF search (`nprobe = 16`) for top-5 nearest, with triangle-inequality
   pruning and decision-aware early exit.
3. `fraud_score = frauds_in_top5 / 5`.
4. `approved = fraud_score < 0.6`.

## Infrastructure constraints

- ≥ 1 load balancer + ≥ 2 API instances, **simple round-robin** (the LB must
  not run business logic — no payload inspection, no responding, no deciding).
- Submission = `docker-compose.yml` on the `submission` branch, public images,
  compatible with `linux/amd64`.
- Sum of all service limits: **≤ 1 CPU and ≤ 350 MB RAM**.
  Current split: `lb = 0.10 / 16 MB` (HAProxy), `api1 = api2 = 0.45 / 167 MB`,
  total `1.00 / 350 MB`. HAProxy peak working set under sustained k6 load
  sits around 12 MiB — the buffer pool dominates and is the reason
  `maxconn`/`bufsize` are tuned down (see `haproxy.cfg`).
- Network mode `bridge`. `host` and `privileged` are forbidden.
- App responds on `localhost:9999`.

## Scoring (practical summary)

`final_score = score_p99 + score_det`, each clamped to `[-3000, +3000]` →
total in `[-6000, +6000]`.

- **Latency (`score_p99`)**: `1000 · log₁₀(1000ms / max(p99, 1ms))`.
  Ceiling +3000 when `p99 ≤ 1ms`. **Floor −3000 when `p99 > 2000ms`.**
- **Detection (`score_det`)**: `1000 · log₁₀(1/ε) − 300 · log₁₀(1 + E)`,
  where `E = 1·FP + 3·FN + 5·Err` and `ε = E / N`.
  **Hard −3000 floor when `(FP+FN+Err) / N > 15%`.**

Implications:
- Each **10× faster** is worth +1000 points on `score_p99`. Optimizing below
  1ms is wasted (saturates).
- `Err` (HTTP ≠ 200) has weight 5 and also counts as raw failure — when
  panicking, returning `200` with `{ approved: true, fraud_score: 0.0 }` beats
  a 5xx.
- The 15% failure cut is hard: cross it and `score_det = −3000`, nullifying
  any p99 gain.
- Do **not** use the test payloads (`test/test-data.json`) as a
  dataset/lookup — explicitly forbidden.

## Submission

- PR adding `participants/<github-user>.json` listing the repos.
- Repo must be public; with branches `main` (source) and `submission` (only
  compose-time artifacts).
- For the official run: open an issue on the challenge repo with
  `rinha/test [id]` in the description. The Rinha engine runs it, comments
  the result, and closes the issue.

## Official test environment

- **Hardware**: Mac Mini Late 2014, 2.6 GHz model. The 2.6 GHz Mac Mini
  Late 2014 ships with the **Intel Core i5-4278U** (Haswell-U,
  4th-gen Core, 2 cores / 4 threads, 2.6 GHz base / 3.1 GHz turbo,
  TDP 28 W).
- **Caches**: L1 32 KiB I + 32 KiB D per core, L2 256 KiB per core,
  **L3 only 3 MiB shared** — `references.bin` (~83 MiB) thrashes
  L3 on every per-cell scan, so the workload is memory-bound on
  this CPU even when it isn't on a modern desktop.
- **ISA**: SSE 4.2, AVX, **AVX2, FMA3, BMI1/BMI2**, AES, CLMUL.
  `--mcpu=haswell` is the exact codegen target — pass it to
  `crystal build --release` so LLVM enables AVX2/FMA and schedules
  for Haswell's port layout.
- **Memory**: 8 GB DDR3L-1600.
- **OS**: Ubuntu 24.04, `linux/amd64`.

Implications for benchmarking on a modern dev box (e.g. Raptor Lake
i5/i7): bench numbers don't transfer 1:1. Modern OOO machines hide
extra loads (e.g. a `DIM_ORDER` indirection) and have stronger branch
predictors, so micro-optimisations that look neutral or negative
locally can land positively on Haswell-U — and vice versa. The only
definitive measurement is `rinha/test`. See `RESULTS.md` iter 7 for
a worked example of this gap.

## Garbage Collector strategy

This is **not production code** — we optimize aggressively for benchmark
behavior. Crystal exposes the GC via the `GC` module
(https://crystal-lang.org/api/1.20.1/GC.html):

- `GC.disable` — turns the collector off (no pauses).
- `GC.enable` — turns it back on.
- `GC.collect` — forces a collection cycle.
- `GC.malloc` / `GC.malloc_atomic` / `GC.realloc` / `GC.free` — manual
  allocation primitives.
- `GC.add_finalizer`, `GC.add_root`, `GC.stats`, etc.

**Default policy for this project: disable the GC whenever possible.**

Currently implemented in `src/server.cr`: after `load_references!` /
`warm_up!`, the boot path calls `GC.collect` once (final compaction) and
then `GC.disable`. A background fiber (`gc_stats_loop`) samples
`GC.stats` every 5 s and logs `heap_size`/`bytes_since_gc` — purely
observational, off the hot path. There is no incremental enable/collect/
disable flip; the hot path is engineered to be zero-alloc, so pauses
never need to come back.

Reference pattern:

```crystal
# Startup: load and pre-process the dataset, warm caches, allocate everything
# we expect to keep around (Slice(Int16) buffers, IVF index, etc.).
load_references!
warm_up!

# After warm-up, before serving traffic:
GC.collect    # one final compaction to start clean
GC.disable    # no GC pauses during the benchmark hot path
```

Why this is acceptable here:
- The benchmark is bounded in duration; we are not designed to survive for
  days.
- The 350 MB / 1 CPU envelope is fully consumed by the dataset + working
  buffers we already need; transient per-request allocations should be small
  and short-lived if the hot path is written carefully.
- Removing GC pauses helps `score_p99` directly — pauses on the tail are
  exactly what blow up p99.

Why this is risky (and how to mitigate):
- With `GC.disable`, transient allocations are never reclaimed → memory grows
  monotonically until OOM.
  Mitigation: keep the hot path **zero-allocation** (reuse stack
  buffers, reuse `StaticArray(Float32, 14)` query vectors, parse JSON
  in place into pre-allocated structs via offsets, avoid `String#split`,
  avoid implicit `to_s`).
- If memory does climb, the safety valve is to flip back: `GC.enable;
  GC.collect; GC.disable` between bursts (off the hot path), or just leave
  the GC enabled for that instance.
- Always measure: `GC.stats` gives `heap_size`, `free_bytes`,
  `unmapped_bytes`, `bytes_since_gc`, `total_bytes` — log them periodically
  (off the hot path) to confirm the assumption holds.

If, while writing code, you cannot guarantee zero-allocation in the hot path
for a given feature, **say so explicitly** before disabling the GC — the
trade-off must be conscious.

## Collaboration guidelines for this project

- **Language**: PT-BR with the user; CLAUDE.md and source comments in English.
- **Performance is everything**: zero-allocation in the hot path, avoid GC
  pressure (the GC is currently disabled in production — see above),
  pre-compute everything possible at startup (the dataset is parsed at
  Docker build time into `references.bin` and mmaped at boot).
- **Concurrency**: `TCPServer` raw + one fiber per connection. No
  `HTTP::Server`, no framework, no Channels (no inter-fiber comms needed).
- **Tight memory (350 MB total)**: with Int16 quantization, the vectors
  cost `3M × 14 × 2 ≈ 84 MiB`; the full mmaped `references.bin` is
  ~84 MiB (vectors + labels + centroids + cell offsets/radii + bbox).
  The remaining envelope absorbs Crystal runtime, HAProxy, and per-fiber
  stack buffers. Stay in `Slice(Int16)`/`StaticArray` —
  `Array(Array(Float64))` would explode the budget.
- **Algorithm**: IVF (`k=2048`, `base_nprobe=8`, `retry_nprobe=16`) with
  Int16 quantization, triangle-inequality + bbox cell pruning, and a
  decision-aware two-phase probe is the chosen approach; brute-force is
  too slow, HNSW/VP-Tree were not needed once IVF + pruning hit the
  recall target. Re-validate recall via `tools/validate_recall.cr`
  before changing index parameters.
- **HTTP/JSON**: custom Crystal parsers (`src/http_parser.cr`,
  `src/json_parser.cr`). Do not reintroduce stdlib `HTTP::Server` or
  `JSON::PullParser` on the hot path — both allocate per-request.
- **Before using stdlib**, open
  https://crystal-lang.org/api/1.20.1/ for the matching class/module.
- **No mocks on the critical path** that would hide real cost (JSON parsing,
  allocation, Float conversion).
