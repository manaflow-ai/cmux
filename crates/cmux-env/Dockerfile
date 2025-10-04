# Simple multi-stage Dockerfile to run tests without touching host FS
FROM rust:1-bookworm AS test
WORKDIR /app

# Pre-fetch dependencies for better caching
COPY Cargo.toml ./
RUN mkdir -p src && echo "fn main(){}" > src/main.rs && cargo fetch && cargo build || true

# Copy full source
COPY . .

# Lint and test
RUN rustup component add clippy && \
    cargo clippy --all-targets --all-features -- -D warnings && \
    cargo test --all --locked -- --nocapture
