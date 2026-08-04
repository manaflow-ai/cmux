# cmux-tui iroh stage-1 acceptance image: a headless cmux-tui session server
# plus the cmux-tui-iroh listener, reachable only outbound (zero published
# ports). Build context is the cmux repo root:
#
#   docker build -f cmux-tui/scripts/iroh-docker-demo/Dockerfile -t cmux-tui-iroh-demo .

FROM rust:slim-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils pkg-config clang libclang-dev make git \
    && rm -rf /var/lib/apt/lists/*

# Zig for libghostty-vt (version pinned to the ghostty tree's minimum).
ARG ZIG_VERSION=0.16.0
RUN arch="$(uname -m)" \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

WORKDIR /src
COPY ghostty ghostty
COPY cmux-tui cmux-tui

WORKDIR /src/cmux-tui
# Docker's generated resolv.conf trips zig's resolver (ResolvConfParseFailed)
# during ghostty dependency fetch, and the file is read-only in build
# containers here, so bind-mount a plain one over it for this step.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/cmux-tui/target \
    --mount=type=bind,source=cmux-tui/scripts/iroh-docker-demo/build-resolv.conf,target=/etc/resolv.conf \
    cargo build -p cmux-tui -p cmux-tui-iroh \
    && install -m 0755 target/debug/cmux-tui /usr/local/bin/cmux-tui \
    && install -m 0755 target/debug/cmux-tui-iroh /usr/local/bin/cmux-tui-iroh

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash cmux
COPY --from=builder /usr/local/bin/cmux-tui /usr/local/bin/cmux-tui
COPY --from=builder /usr/local/bin/cmux-tui-iroh /usr/local/bin/cmux-tui-iroh
COPY cmux-tui/scripts/iroh-docker-demo/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER cmux
ENV CMUX_TUI_STATE_DIR=/home/cmux/state
# Identity persists across container restarts through this volume.
VOLUME ["/home/cmux/state"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
