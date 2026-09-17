FROM rust:1.98-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build --release --locked -p cmux-v3-relay-server

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin cmux-relay
COPY --from=build /src/target/release/cmux-v3-relay-server /usr/local/bin/cmux-v3-relay-server
USER cmux-relay
EXPOSE 4001/tcp 4001/udp 4002/tcp 8080/tcp
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/cmux-v3-relay-server"]
