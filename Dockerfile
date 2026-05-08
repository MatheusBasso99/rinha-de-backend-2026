# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Build stage: Crystal 1.20.0 on Alpine, statically linked binaries for amd64.
#
# Three artifacts are produced here:
#   - rinha_de_backend : the API HTTP server (runtime).
#   - rinha_lb         : legacy Crystal LB. TCP 9999 → UDS, round-robin
#                        across the two API instances. Built with
#                        -Dpreview_mt -Dexecution_context to enable
#                        Fiber::ExecutionContext::Parallel. Kept for
#                        reference / fallback; the prod `lb` service
#                        in docker-compose.yml now runs HAProxy and
#                        does not invoke this binary.
#   - preprocess       : converts references.json.gz into the binary format
#                        consumed via mmap at runtime. Run once during the
#                        build; the resulting .bin ships with the runtime
#                        image, the original .gz does not.
# -----------------------------------------------------------------------------
FROM --platform=linux/amd64 crystallang/crystal:1.20.0-alpine AS build

WORKDIR /build

# Static variants of system libs Crystal links against.
RUN apk add --no-cache \
    yaml-static \
    libxml2-static \
    zlib-static \
    openssl-libs-static \
    pcre2-dev \
    libevent-static \
    xz-static \
    gc-dev

COPY shard.yml ./
COPY shard.lock* ./
RUN shards install --production --frozen 2>/dev/null \
    || shards install --production \
    || true

COPY src ./src
COPY resources ./resources

# HTTP parsing is now 100% Crystal (`src/http_parser.cr`); no separate
# C compilation step is needed before `crystal build`.

RUN crystal build \
    --release \
    --no-debug \
    --static \
    --mcpu=haswell \
    --mattr=+avx2,+fma,+bmi,+bmi2,+f16c,+movbe,+popcnt,+aes,+pclmul \
    -o /build/rinha_de_backend \
    src/main.cr \
 && strip /build/rinha_de_backend

# Legacy Crystal LB binary. Needs preview_mt + execution_context
# (gates Fiber::ExecutionContext::Parallel in stdlib). The API is
# deliberately built without those flags — its hot path is engineered
# for single-threaded zero-alloc, and we want to keep the GC.disable
# strategy unchanged. The prod LB is HAProxy (see compose); this
# binary is shipped for parity with older compose files that may
# still reference it as the lb entrypoint.
RUN crystal build \
    --release \
    --no-debug \
    --static \
    --mcpu=haswell \
    --mattr=+avx2,+fma,+bmi,+bmi2,+f16c,+movbe,+popcnt,+aes,+pclmul \
    -Dpreview_mt \
    -Dexecution_context \
    -o /build/rinha_lb \
    src/lb_main.cr \
 && strip /build/rinha_lb

# Build the preprocess CLI and run it — but only if the build context
# didn't already ship a `references.bin`. The k-means step takes a few
# minutes; allowing developers to commit a pre-built `.bin` (locally
# only — it stays gitignored) cuts the dev cycle dramatically.
RUN if [ ! -f resources/references.bin ]; then \
      crystal build \
        --release \
        --no-debug \
        --static \
        -o /build/preprocess \
        src/preprocess.cr \
     && strip /build/preprocess \
     && /build/preprocess resources/references.json.gz resources/references.bin \
     && rm /build/preprocess; \
    else \
      echo "[build] using cached resources/references.bin from build context"; \
    fi \
 && rm -f resources/references.json.gz

# -----------------------------------------------------------------------------
# Runtime stage: minimal Alpine. Binary is fully static; Alpine gives us
# wget for the healthcheck.
# -----------------------------------------------------------------------------
FROM --platform=linux/amd64 alpine:3.20

WORKDIR /app

COPY --from=build /build/resources/references.bin    ./resources/references.bin
COPY --from=build /build/resources/normalization.json ./resources/normalization.json
COPY --from=build /build/resources/mcc_risk.json     ./resources/mcc_risk.json
COPY --from=build /build/rinha_de_backend            /usr/local/bin/rinha_de_backend
COPY --from=build /build/rinha_lb                    /usr/local/bin/rinha_lb

EXPOSE 9999

# Default entrypoint is the API. The LB service in docker-compose
# uses the haproxy:lts-alpine image directly, not this image, so this
# entrypoint is only ever exercised by the api1/api2 containers.
ENTRYPOINT ["/usr/local/bin/rinha_de_backend"]
