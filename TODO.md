# TODO — performance & correctness backlog

Tracked record of follow-up work and audit results. Lives on the
default branch (not on `submission`) so the decision history stays
visible without polluting what the Rinha test rig actually runs. When
an item here becomes a binding constraint, fold the relevant context
into CLAUDE.md or a dedicated doc under `docs/`.

## 1. Validate IVF recall vs brute-force

Cheap to do, easy to forget. Sample 1k–10k vectors from the reference
set, run brute-force top-5 vs IVF top-5 with `nprobe = 16`, report
recall@5. If recall < ~0.95, the detection score is leaving points on
the table; tune `nprobe` or `k` before chasing more p99 wins.

## 2. Quantization sanity check

We quantize Float32 → Int16 with `References::SCALE`. Worth confirming
on a small sample that the resulting Int16 query and the Int16 reference
vectors give the same top-5 ordering as Float32 brute-force (within
ties). Cheap, prevents a silent recall regression from hiding behind
fast IVF numbers.

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
