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
  ~16 MB gzipped / ~284 MB uncompressed.
- `mcc_risk.json` — risk per MCC (default `0.5`).
- `normalization.json` — constants.

**The files do not change between test runs.** Pre-processing at build/startup
is allowed and recommended (binary format, ANN index, mmap, etc.) to move cost
out of the hot path.

## Decision

1. Vectorize payload (14 dims).
2. Find 5 nearest neighbors (exact KNN, ANN — HNSW/IVF/VP-Tree —, or any
   technique that keeps both precision and p99 acceptable).
3. `fraud_score = frauds_in_top5 / 5`.
4. `approved = fraud_score < 0.6`.

## Infrastructure constraints

- ≥ 1 load balancer + ≥ 2 API instances, **simple round-robin** (the LB must
  not run business logic — no payload inspection, no responding, no deciding).
- Submission = `docker-compose.yml` on the `submission` branch, public images,
  compatible with `linux/amd64`.
- Sum of all service limits: **≤ 1 CPU and ≤ 350 MB RAM**.
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

Mac Mini Late 2014, 2.6 GHz, 8 GB RAM, Ubuntu 24.04 (`linux/amd64`).

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

Recommended pattern:

```crystal
# Startup: load and pre-process the dataset, warm caches, allocate everything
# we expect to keep around (Slice(Float32) buffers, ANN index, etc.).
load_references!
warm_up!

# After warm-up, before serving traffic, call:
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
  Mitigation: keep the hot path **zero-allocation** (reuse `IO::Memory`
  buffers, reuse `Slice(Float32)` query vectors, parse JSON in place into
  pre-allocated structs, avoid `String#split`, avoid implicit `to_s`).
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
  pressure (and prefer disabling the GC, see above), pre-compute everything
  possible at startup (decompress and parse the dataset into a dense binary
  representation like `Slice(Float32)` or similar).
- **Concurrency**: use Crystal `Fiber`/`Channel`; HTTP keep-alive; consider
  raw `HTTP::Server` vs frameworks.
- **Tight memory (350 MB total)**: 3M × 14 × 4 bytes ≈ 168 MB just for the
  vectors. Watch object overhead; prefer contiguous `Slice(Float32)` over
  `Array(Array(Float64))`.
- **Algorithm choices**: brute-force `O(N · D)` likely will not fit the p99
  target; consider VP-Tree, HNSW, IVF, or quantization. Measure before
  complicating.
- **Before using stdlib**, open
  https://crystal-lang.org/api/1.20.1/ for the matching class/module.
- **No mocks on the critical path** that would hide real cost (JSON parsing,
  allocation, Float conversion).
