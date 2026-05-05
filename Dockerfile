# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Build stage: Crystal 1.20.0 on Alpine, statically linked binary for amd64.
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

RUN crystal build \
    --release \
    --no-debug \
    --static \
    -o /build/rinha_de_backend \
    src/main.cr \
 && strip /build/rinha_de_backend

# -----------------------------------------------------------------------------
# Runtime stage: minimal Alpine. The binary is fully static, but Alpine gives
# us wget for the healthcheck and a writable /tmp without extra effort.
# -----------------------------------------------------------------------------
FROM --platform=linux/amd64 alpine:3.20

WORKDIR /app

COPY resources ./resources
COPY --from=build /build/rinha_de_backend /usr/local/bin/rinha_de_backend

EXPOSE 9999

ENTRYPOINT ["/usr/local/bin/rinha_de_backend"]
