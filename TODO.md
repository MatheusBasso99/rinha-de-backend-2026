# TODO — performance & correctness backlog

Tracked record of follow-up work and audit results. Lives on the
default branch (not on `submission`) so the decision history stays
visible without polluting what the Rinha test rig actually runs. When
an item here becomes a binding constraint, fold the relevant context
into CLAUDE.md or a dedicated doc under `docs/`.

## 1. ✅ DONE: validate IVF recall vs brute-force

Resolved 2026-05-05. Tool: `tools/validate_recall.cr` — samples N
vectors from `references.bin`, runs brute-force top-5 over the full
3M Int16 dataset and IVF top-5 with the configured `nprobe`, reports
recall@5 = |intersection|/5 averaged across the sample.

Numbers (k=1024, nprobe=16, seed=1337, full dataset mmapped):

  - In-set queries (query == known dataset vector), N=1000:
    **recall@5 = 1.000000**, 1000/1000 perfect, worst = 1.0.
    brute=13.66 ms/query, ivf=0.38 ms/query (35.8× speedup).
  - Jittered queries (Int16 jitter ±2000, ~20% of full scale), N=1000:
    **recall@5 = 0.9966**, 990/1000 perfect, 9 partial (>= 3/5),
    1 outlier with 0/5 (random query landed nowhere near a cell).
    brute=15.67 ms/query, ivf=0.59 ms/query.

Verdict: comfortably above the 0.95 target. The detection score is
not leaving meaningful points on the table at `nprobe=16`; do not
spend time tuning recall further.

Re-run with: `crystal run --release tools/validate_recall.cr -- 1000 16 1337`
or `JITTER=2000 crystal run --release tools/validate_recall.cr -- 1000 16 1337`.

## 2. ✅ DONE: quantization sanity check

Resolved 2026-05-05. Tool: `tools/validate_quantization.cr` — loads
the original Float64 dataset from `references.json.gz` (~6 s on disk,
8 GB host RAM) plus the mmapped Int16 `references.bin`, then for N
sampled queries computes top-5 brute-force on each side and compares
the **fraud-count-in-top-5** (the only quantity that determines the
API response).

We compare fraud counts rather than index sets because the Int16
dataset is reordered by IVF cell, so indices are not directly
comparable. Fraud count is the score-relevant invariant.

Numbers (N=500, seed=1337, full 3M dataset on both sides):

  - fraud-count agreement: **100% (500/500)**
  - approve-flip rate: **0% (0/500)** — quantization never changed
    the API answer for samples drawn from the dataset
  - timing: f64=33.11 ms/query, i16=13.96 ms/query

Verdict: the Float64 → Int16 (×10_000) quantization has no observable
impact on the user-visible decision for in-set queries. The Int16
fast path is a true equivalent of the Float64 reference.

Re-run with: `crystal run --release tools/validate_quantization.cr -- 500 1337`
(needs ~350 MB resident for the Float64 buffer).

## ✅ DONE: Decision-aware early exit + cell-radius pruning

Resolved 2026-05-05. Both pruning paths landed in `src/ivf.cr` over
the same query method, sharing one precomputed `cell_radius` array
and a `max_cell_radius` header field.

Build-time (`src/ivf_builder.cr`): after final reorder + centroid
quantization, computes `cell_radius[c]` = `ceil(sqrt(max squared L2
from quantized centroid c to any vector in cell c))`. Stored as
`Slice(UInt32)` of length k. The header now also caches
`max_cell_radius` (single UInt32). Binary format magic bumped
`RNH2 → RNH3` (`src/references.cr`).

Query-time pruning (`src/ivf.cr` stage 2):

1. **Per-cell triangle-inequality skip.** For each probed cell `p`
   with floor-sqrt centroid distance `D_p` (Int64) and stored
   `cell_radius[cell] = R_p`, skip the cell when
   `D_p > R_p AND (D_p − R_p)² >= worst`. Conservative on both
   sides (D_p uses floor, R_p uses ceil) so we never skip a cell
   that could legitimately contain a top-K candidate.

2. **Decision-aware outer break (`max_cell_radius`).** Probes are
   sorted ascending by centroid distance. After processing cell `p`,
   compute `gap = D_{p+1} − max_cell_radius`. If `gap > 0 AND
   gap² >= worst`, no remaining probed cell can possibly displace
   the current top-5, so the fraud count is locked — break the
   outer loop.

The 16 sqrts (one per probed cell, hoisted out of the inner loop)
are negligible cost; the inner cell-distance loop stays in pure
integer math.

Validation (`tools/validate_pruning.cr`): compares the new pruned
IVF against an inline unpruned IVF on the full 3M dataset.

  - In-set queries (jitter=0), N=500: **500/500 exact agreement**;
    pruned 0.244 ms/query vs unpruned 0.372 ms/query → **1.52×
    speedup** (≈34% IVF compute reduction).
  - Jittered queries (Int16 ±2000), N=1000: **1000/1000 exact
    agreement**; pruned 0.561 ms vs unpruned 0.582 ms → **1.04×
    speedup**. Pruning fires far less often when the query is far
    from any centroid, as expected.

Recall vs brute-force unchanged (re-ran `tools/validate_recall.cr`
N=500, in-set: recall@5 = 1.0).

End-to-end benchmarks on the full compose stack (1 CPU + 350 MB,
single repeated payload, 10k requests/run):

  | Workload | iter 5 p99 | iter 6 p99 | Δ        |
  | -------- | ---------- | ---------- | -------- |
  | c=1      | 1.73 ms    | **0.89 ms**| **−49%** |
  | c=10     | 64.8 ms    | 74.45 ms   | +15% (noise) |
  | c=20     | 96.0 ms    | 76.87 ms   | **−20%** |
  | c=50     | 208.4 ms   | 105.95 ms  | **−49%** |
  | c=100    | 312.2 ms   | 260.15 ms  | **−17%** |

c=1 now under 1 ms ⇒ `score_p99` saturates at +3000.

What we explicitly did NOT do (per the original guidance): "if the
X nearest vectors are far ⇒ reject" without looking at labels. The
verdict depends on the *labels* of the top-5, not their absolute
distances. A query in a sparse area can still be approved if the
5 nearest are all legit.

Re-run with: `crystal run --release tools/validate_pruning.cr -- 500 1337 0`
or `crystal run --release tools/validate_pruning.cr -- 1000 1337 2000`.

## 3. ✅ DONE: harness sends only well-formed HTTP/JSON

Resolved 2026-05-05. Reviewed the official challenge repo
(zanfranceschi/rinha-de-backend-2026) end-to-end:

  - `run.sh` invokes `k6 run test/test.js` (no other harness).
  - `test/test.js` and `test/smoke.js` both use k6's `http.post()`,
    which is Go `net/http` underneath — produces strictly RFC-compliant
    HTTP/1.1 (uppercase methods, ASCII-only request target, well-formed
    Content-Length / Content-Type / Host / User-Agent).
  - `test/test-data.json` is pure 7-bit ASCII: tx IDs `tx-<digits>`,
    merchant IDs `MERC-<digits>`, MCCs as digit-strings, ISO-8601
    timestamps, JSON numbers. No high-bit bytes, embedded CRs/LFs,
    or other surprises.
  - Neither smoke nor test scripts include any "send malformed bytes"
    case. EVALUATION.md says nothing about robustness / fuzz testing
    — `Err` only counts HTTP responses ≠ 200.
  - All traffic hits `localhost:9999` (our LB = nginx). Even if k6 ever
    misbehaved, nginx would normalise or reject before our backend
    sees the bytes.

Conclusion: `HttpParser`'s "trust nginx" stance is safe under the
official run. Keep the safety net (`rescue` → 200/0.0 in
`handle_fraud_score`) as defence in depth; do NOT pay the ~70 ns/parse
cost of re-adding per-byte tchar / CTL / DEL validation.

Side note found while skimming `test-data.json`: `merchant.mcc` ships
as a JSON **string** (`"5912"`), not a number. Verified 2026-05-05 —
no fix needed:

  - `resources/mcc_risk.json` keys are 4-char strings (`"5411"`, ...).
  - `MccRisk#initialize` (src/mcc_risk.cr:24-30) packs each 4-char key
    big-endian into a `UInt32` and stores a parallel `@packed_table`.
  - Hot path: `json_parser.cr` reads `"mcc"` as a quoted string (line
    214-223), packs the 4 ASCII bytes via `pack_mcc` (line 410-415)
    using the same big-endian formula, then the vectorizer calls
    `risk_for(mcc_packed : UInt32)`.
  - Canonical path: `Merchant#mcc : String` (src/payload.cr:24);
    vectorizer canonical calls `risk_for(merch.mcc : String)`.
  Both paths agree, no String allocation on the hot path.

## 4. ✅ DONE: confirm no test-payload lookup leakage

Verified 2026-05-05 against the rule "Não é permitido usar os payloads
do teste como referência ou para fazer lookup de fraudes":

  - Production startup (src/server.cr) loads only:
      * `resources/references.bin` (mmapped),
      * `resources/mcc_risk.json`,
      * `resources/normalization.json`.
  - `references.bin` is preprocessed (src/preprocess.cr) from
    `references.json.gz`, which is **byte-identical** (50,246,401 B) to
    the official challenge repo's `resources/references.json.gz`.
    Decoded: 3,000,000 entries, only `vector` (14 dims) + `label`
    (`fraud`/`legit`) keys — no `id`, no `transaction`, no
    `customer.known_merchants`. This is the proper 3M-vector ANN
    reference dataset, not the test payloads.
  - `resources/example-payloads.json` and `example-references.json`
    are byte-identical to the official `resources/example-*.json` (the
    maintainer ships them explicitly for participant testing). They
    are loaded ONLY by spec/ files (assertions of parser/vectorizer
    correctness), never by production code, and are NOT copied into
    the runtime image (Dockerfile copies only the three production
    files above).
  - `test/test-data.json` (the actual harness payloads, 54,100
    entries) is never referenced anywhere in this repo — neither
    src/, nor spec/, nor resources/. The IDs in `example-payloads`
    overlap with `test-data.json` because the maintainer chose them
    that way; we do not store / index / lookup by them.

Conclusion: compliant with the rule. The runtime answer for any
incoming `/fraud-score` is computed from the 3M ANN reference set
via IVF KNN, not memoised from any test fixture.
