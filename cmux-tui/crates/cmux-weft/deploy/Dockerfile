# Weft services image: weft-coord, weft-relay and the weft client.
# Build context: the cmux-tui workspace root, e.g.
#   fly deploy cmux-tui -c cmux-tui/crates/cmux-weft/deploy/relay.staging.fly.toml \
#     --dockerfile cmux-tui/crates/cmux-weft/deploy/Dockerfile --remote-only
FROM rust:1.95-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release --locked -p cmux-weft --bins \
 && mkdir -p /out \
 && cp target/release/weft target/release/weft-coord target/release/weft-relay /out/

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home /data weft \
 && mkdir -p /data && chown weft /data
COPY --from=build /out/ /usr/local/bin/
USER weft
EXPOSE 8080
