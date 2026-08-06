FROM rust:1.91-bookworm AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential clang cmake curl libssl-dev minisign pkg-config python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /toolchain
COPY scripts/install-zig-ci.sh scripts/ghostty-zig-version.sh ./scripts/
COPY ghostty/build.zig.zon ./ghostty/build.zig.zon
RUN ZIG_FORCE_LOCAL_INSTALL=1 ZIG_INSTALL_ROOT=/opt/zig ./scripts/install-zig-ci.sh \
    && zig_version="$(bash ./scripts/ghostty-zig-version.sh)" \
    && ln -s "/opt/zig/zig-$(uname -m)-linux-${zig_version}/zig" /usr/local/bin/zig \
    && /usr/local/bin/zig version
ENV ZIG=/usr/local/bin/zig
WORKDIR /source
