FROM rust:1-bookworm AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache dependencies
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo "fn main(){}" > src/main.rs && \
    cargo build --release || true
RUN rm -rf src

# Copy real sources and build
COPY src src
COPY ldpreload ldpreload
COPY tests tests
RUN make -C ldpreload
# Install the preload lib for tests/tools in later stages
RUN install -m 0755 ldpreload/libworkspace_net.so /usr/local/lib/libworkspace_net.so
# Pre-build release binary (runtime) and pre-build test deps to warm caches
RUN cargo build --release \
 && cargo test --workspace --all-features --no-run --locked

# Minimal runtime image
FROM debian:bookworm-slim AS runtime
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      bash \
      python3 \
      curl \
      unzip \
      tmux \
      postgresql \
      postgresql-client && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/cmux-proxy /usr/local/bin/cmux-proxy
COPY --from=builder /app/ldpreload/libworkspace_net.so /usr/local/lib/libworkspace_net.so
ENV LD_PRELOAD=/usr/local/lib/libworkspace_net.so
ENV CMUX_LISTEN=0.0.0.0:39379
EXPOSE 39379
USER root
ENTRYPOINT ["/usr/local/bin/cmux-proxy"]

# Test image (default)
FROM builder AS test
WORKDIR /app
ENV LD_PRELOAD=/usr/local/lib/libworkspace_net.so
RUN cargo test --workspace --all-features -- --nocapture
