# Submission — Rinha de Backend 2026

Step-by-step for submitting this repository to an official Rinha de Backend 2026 test (preview or final).

Upstream reference: [`docs/en/SUBMISSION.md`](https://github.com/zanfranceschi/rinha-de-backend-2026/blob/main/docs/en/SUBMISSION.md).

## Current state

- **Participant**: already registered at [`participants/MatheusBasso99.json`](https://github.com/zanfranceschi/rinha-de-backend-2026/blob/main/participants/MatheusBasso99.json):
  ```json
  [{ "id": "matheus-crystal",
     "repo": "https://github.com/MatheusBasso99/rinha-de-backend-2026" }]
  ```
- **Required branches**: `main` (source code) and `submission` (only `docker-compose.yml`, `haproxy.cfg`, `info.json`). Both already exist.
- **API image**: `ghcr.io/matheusbasso99/rinha-de-backend-2026:<tag>` on the GitHub Container Registry, public, with `references.bin` baked in.
- **License**: MIT (see `LICENSE`) — required by Rinha.
- **`info.json`**: present on both branches.

In other words: registration is done. Each new submission only requires **publishing a new image, updating the `submission` branch, and opening a test issue**.

## Prerequisites (one-time)

- `docker buildx` configured for `linux/amd64` (Rinha runs on a Mac Mini Late 2014, Ubuntu 24.04 amd64).
- Logged into `ghcr.io` with a PAT scoped `write:packages`:
  ```sh
  echo "$GHCR_TOKEN" | docker login ghcr.io -u MatheusBasso99 --password-stdin
  ```
- `gh` CLI authenticated (`gh auth status`) — used to open the preview issue.
- `references.json.gz` present in `resources/` (gitignored, ~48 MiB) — needed at `docker build` time because the k-means preprocessing runs inside the image.

## Submission flow

### 1. Make sure `main` is ready

Before anything else, validate locally:

```sh
# Unit tests
make spec

# Recall (must not regress before touching IVF parameters)
crystal run --release tools/validate_recall.cr

# Local smoke with docker-compose (optional but recommended)
docker compose up --build
curl -s localhost:9999/ready
curl -s -X POST localhost:9999/fraud-score \
  -H 'content-type: application/json' \
  -d @test/test-data.json | head
docker compose down
```

Commit everything to `main` and push.

### 2. Build and push the API image

Tag scheme observed in history: `vN-<git_short_sha>` (e.g. `v2-33cba619`, `v3-a0ba5918`, `v4-77c93c65`). The `N` is just an iteration counter the maintainer bumps at their discretion; the sha is the source commit. The only hard rule is **don't reuse a tag** — each push must be a fresh, immutable identifier.

```sh
SHA=$(git rev-parse --short=8 HEAD)
TAG="v4-${SHA}"   # bump v4 → v5 if you want a clean iteration marker

docker buildx build \
  --platform linux/amd64 \
  --tag ghcr.io/matheusbasso99/rinha-de-backend-2026:${TAG} \
  --push \
  .
```

> The `Dockerfile` does everything: compiles the Crystal binary (`--mcpu=haswell`), runs `preprocess` to generate `references.bin`, and copies the binary + `.bin` into the final image. Expect several minutes because of the k-means pass (5 iterations over 3M vectors).

After the push, confirm the image is public at https://github.com/MatheusBasso99/rinha-de-backend-2026/pkgs/container/rinha-de-backend-2026 (Package settings → Change visibility → Public, if not already).

### 3. Update the `submission` branch

The `submission` branch must contain **only** runtime artifacts — no source code. Today:

```
docker-compose.yml
haproxy.cfg
info.json
```

Bump the image tag in `docker-compose.yml`:

```sh
git checkout submission
# Edit docker-compose.yml: bump the line
#   image: ghcr.io/matheusbasso99/rinha-de-backend-2026:v4-<sha>
git add docker-compose.yml
git commit -m "chore: bump image to ${TAG}"
git push origin submission
git checkout main
```

> **Important**: `submission` must *never* contain `src/`, `spec/`, `Dockerfile`, etc. — only the files needed to bring the stack up.

### 4. Validate the stack pre-submission

Confirm that the `docker-compose.yml` from the `submission` branch boots correctly while pulling the image from GHCR:

```sh
git worktree add /tmp/rinha-sub submission
cd /tmp/rinha-sub
docker compose pull
docker compose up -d
sleep 5
curl -fsS localhost:9999/ready && echo OK
docker compose down
cd -
git worktree remove /tmp/rinha-sub
```

If `/ready` answers 2xx, the stack is ready for the Rinha engine.

### 5. Open the test issue

#### Preview test (as many as you want)

```sh
gh issue create \
  --repo zanfranceschi/rinha-de-backend-2026 \
  --title "preview test - matheus-crystal" \
  --body  "rinha/test matheus-crystal"
```

The Rinha engine scans open issues, finds `rinha/test matheus-crystal` in the body, runs the preview, comments the result (score or error), and closes the issue automatically. Sample reference: [issue #49](https://github.com/zanfranceschi/rinha-de-backend-2026/issues/49).

#### Final test

Runs **once**, at the end of the event — the organizer triggers it, not you. No issue needed. The image pinned in `submission` at cutoff time is what gets benchmarked.

### 6. Read the result

The bot comments on the issue with:

- `score_p99` — `1000 · log₁₀(1000ms / max(p99, 1ms))`, clamp `[-3000, +3000]`. Hard floor `-3000` if `p99 > 2000ms`.
- `score_det` — `1000 · log₁₀(1/ε) − 300 · log₁₀(1+E)`, where `E = 1·FP + 3·FN + 5·Err`. Hard floor `-3000` if `(FP+FN+Err)/N > 15%`.
- `final_score = score_p99 + score_det`, total range `[-6000, +6000]`.

Record the run in `RESULTS.md` (iter, image tag, p99, FP/FN/Err, score) to track regressions.

## Quick checklist

Before opening a preview issue:

- [ ] `make spec` green
- [ ] `tools/validate_recall.cr` no regression
- [ ] `main` committed and pushed
- [ ] `linux/amd64` image built with `--mcpu=haswell` and pushed to GHCR
- [ ] Image is public on GHCR
- [ ] `docker-compose.yml` on the `submission` branch points at the new tag
- [ ] `submission` pushed
- [ ] `docker compose pull && up -d` from `submission` answers 200 on `/ready`
- [ ] Total CPU/memory limits ≤ 1.0 / 350 MB (LB 0.10/16, api1 0.45/167, api2 0.45/167)
- [ ] No `network_mode: host`, no `privileged: true`
- [ ] LB does plain TCP round-robin only (HAProxy `mode tcp`) — no business logic

## Operational notes

- **Use immutable tags**, not `:latest`. Background: issue [#1920](https://github.com/zanfranceschi/rinha-de-backend-2026/issues/1920) failed with `stat /usr/local/bin/rinha_lb: no such file or directory` while the published `:latest` digest contained the binary. Root cause was never confirmed (one hypothesis: the runner had a stale `:latest` in its local docker cache and `up -d` did not refresh it). Pinning a unique tag (`v2-33cba619`) on the next run worked, so since then the project pins immutable tags as a precaution.
- **Do not bake `references.json.gz` into the published image**: only the preprocessed `references.bin` ships in the final image (see Dockerfile).
- **Do not use `test/test-data.json` as a dataset/lookup**: explicitly forbidden by Rinha rules.
- **`open_to_work` in `info.json`**: currently `false`. Flip to `true` if you want organizers to reach out.
- **Multiple submissions**: the array in `participants/MatheusBasso99.json` accepts N entries. To submit a second variant (e.g. an HNSW experiment), open a PR on the Rinha repo adding another entry like `{ "id": "matheus-experimental", "repo": "..." }`.
