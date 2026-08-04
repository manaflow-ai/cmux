FROM rust:1.91-bookworm AS builder

ARG CMUX_TUI_BUILD_COMMIT=iroh-stage1-sol
ENV CMUX_TUI_BUILD_COMMIT=${CMUX_TUI_BUILD_COMMIT}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential clang cmake curl libssl-dev minisign pkg-config python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /source
COPY . .
RUN ZIG_FORCE_LOCAL_INSTALL=1 ZIG_INSTALL_ROOT=/opt/zig ./scripts/install-zig-ci.sh \
    && zig_version="$(./scripts/ghostty-zig-version.sh)" \
    && ln -s "/opt/zig/zig-$(uname -m)-linux-${zig_version}/zig" /usr/local/bin/zig \
    && /usr/local/bin/zig version
ENV ZIG=/usr/local/bin/zig
RUN cargo build \
    --manifest-path cmux-tui/Cargo.toml \
    --locked \
    --release \
    -p cmux-tui \
    -p cmux-tui-iroh \
    && mkdir -p /output/bin /output/lib \
    && cp cmux-tui/target/release/cmux-tui /output/bin/ \
    && cp cmux-tui/target/release/cmux-tui-iroh /output/bin/ \
    && find cmux-tui/target/release/build -path '*/out/ghostty-vt/lib/libghostty-vt.so*' \
        -exec cp {} /output/lib/ \;

FROM debian:bookworm-slim

LABEL dev.cmux.purpose="iroh-tui-stage1-sol"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates socat \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/sh cmux \
    && mkdir -p /state /run/cmux \
    && chown -R cmux:cmux /state /run/cmux

COPY --from=builder /output/bin/ /usr/local/bin/
COPY --from=builder /output/lib/ /usr/local/lib/
COPY scripts/iroh-tui-stage1/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
RUN chmod 0755 /usr/local/bin/container-entrypoint.sh \
    && ldconfig

USER cmux
VOLUME ["/state"]
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
