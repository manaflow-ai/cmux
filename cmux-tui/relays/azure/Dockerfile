# Build from the cmux-tui directory:
#   docker build -f relays/azure/Dockerfile -t cmux-relay:dev .

FROM rust:1.95-bookworm AS build

WORKDIR /src
COPY . .
RUN cargo build --locked --release -p cmux-relay

FROM debian:bookworm-slim

RUN groupadd --system --gid 10001 cmux-relay \
    && useradd --system --uid 10001 --gid 10001 --home-dir /nonexistent \
        --shell /usr/sbin/nologin cmux-relay \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build --chown=cmux-relay:cmux-relay \
    /src/target/release/cmux-relay /usr/local/bin/cmux-relay

USER cmux-relay:cmux-relay
WORKDIR /nonexistent
ENV CMUX_RELAY_BIND=127.0.0.1:8787
ENV CMUX_RELAY_ALLOW_OPEN=false
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/cmux-relay"]
CMD ["serve"]
