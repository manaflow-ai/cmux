# syntax=docker/dockerfile:1.7-labs

ARG RUST_VERSION=1.91.0
ARG DOCKER_VERSION=27.4.0
ARG DOCKER_COMPOSE_VERSION=2.29.7
ARG BUILDX_VERSION=0.30.1
ARG BUILDKIT_VERSION=0.15.2
ARG NODE_VERSION=22.11.0

FROM rust:${RUST_VERSION}-bookworm AS rust-base

ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
  CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  pkg-config \
  libssl-dev \
  clang \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

FROM rust-base AS chef
RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  cargo install --locked cargo-chef
COPY packages/sandbox/Cargo.toml packages/sandbox/Cargo.lock ./
COPY packages/sandbox/benches ./benches
RUN cargo chef prepare --recipe-path recipe.json

FROM rust-base AS acp-builder
WORKDIR /workspace
ENV CARGO_TERM_COLOR=never \
  CARGO_PROFILE_RELEASE_STRIP=symbols \
  CARGO_TARGET_DIR=/workspace/target

RUN git clone https://github.com/agentclientprotocol/agent-client-protocol .tmp_acp_repos/agent-client-protocol && \
    git clone https://github.com/zed-industries/codex-acp .tmp_acp_repos/codex-acp && \
    cd .tmp_acp_repos/codex-acp && \
    cargo build --release

FROM chef AS builder
ENV CARGO_TERM_COLOR=never \
  CARGO_PROFILE_RELEASE_STRIP=symbols \
  CARGO_TARGET_DIR=/workspace/target

COPY packages/sandbox/Cargo.toml packages/sandbox/Cargo.lock ./
COPY packages/sandbox/benches ./benches
COPY --from=chef /workspace/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  cargo chef cook --release --recipe-path recipe.json

COPY packages/sandbox/src ./src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  cargo build --locked --release --bin cmux --bin cmux-sandboxd --bin cmux-bridge

FROM ubuntu:24.04 AS dind-installer

ARG DOCKER_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG BUILDX_VERSION
ARG BUILDKIT_VERSION

SHELL ["/bin/bash", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  jq \
  iptables \
  iproute2 \
  && rm -rf /var/lib/apt/lists/*

RUN <<'EOF'
set -euo pipefail
arch="$(uname -m)"
case "$arch" in
  x86_64) docker_arch="x86_64"; buildkit_arch="linux-amd64" ;;
  aarch64) docker_arch="aarch64"; buildkit_arch="linux-arm64" ;;
  *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
esac

wget -O /tmp/docker.tgz "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"
tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1

mkdir -p /usr/local/lib/docker/cli-plugins
wget -O /usr/local/lib/docker/cli-plugins/docker-compose \
  "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${docker_arch}"
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

wget -O /usr/local/lib/docker/cli-plugins/docker-buildx \
  "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.${buildkit_arch}"
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

wget -O /tmp/buildkit.tgz "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${buildkit_arch}.tar.gz"
tar -xzf /tmp/buildkit.tgz -C /tmp
install -m 0755 /tmp/bin/buildkitd /usr/local/bin/buildkitd
install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl
rm -rf /tmp/buildkit.tgz /tmp/bin
EOF

FROM ubuntu:24.04

ARG NODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  bubblewrap \
  iproute2 \
  iptables \
  iputils-ping \
  uidmap \
  fuse-overlayfs \
  util-linux \
  less \
  systemd \
  systemd-sysv \
  dbus \
  ca-certificates \
  curl \
  bash \
  zsh \
  zsh-autosuggestions \
  zsh-syntax-highlighting \
  vim \
  tini \
  python3 \
  python3-venv \
  python3-websockets \
  socat \
  tmux \
  lsof \
  htop \
  btop \
  unzip \
  sudo \
  git \
  ripgrep \
  wget \
  gnupg \
  make \
  build-essential \
  openssh-client \
  jq \
  findutils \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

RUN arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) node_arch="linux-x64" ;; \
    aarch64) node_arch="linux-arm64" ;; \
    *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${node_arch}.tar.gz" | tar -xz -C /usr/local --strip-components=1 && \
  rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | bash && \
  install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun && \
  install -m 0755 /root/.bun/bin/bunx /usr/local/bin/bunx && \
  rm -rf /root/.bun /root/.cache/bun

ENV BUN_INSTALL_GLOBAL_DIR=/usr/local/lib/bun
ENV BUN_INSTALL_BIN=/usr/local/bin

RUN bun add -g \
    @openai/codex \
    @anthropic-ai/claude-code \
    @zed-industries/claude-code-acp \
    @google/gemini-cli \
    opencode-ai \
    @sourcegraph/amp

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
  mv /root/.local/bin/uv /usr/local/bin/uv && \
  rm -rf /root/.local

ARG RUST_VERSION
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal && \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true
RUN mkdir -p /var/lib/cmux/sandboxes

# Install libssl1.1 for compatibility (required by some agent binaries)
RUN arch="$(uname -m)"; \
    if [ "$arch" = "x86_64" ]; then \
      echo "deb http://security.ubuntu.com/ubuntu focal-security main" >> /etc/apt/sources.list; \
    else \
      echo "deb http://ports.ubuntu.com/ubuntu-ports focal-security main" >> /etc/apt/sources.list; \
    fi && \
    apt-get update && \
    apt-get install -y libssl1.1 && \
    sed -i '$d' /etc/apt/sources.list && \
    rm -rf /var/lib/apt/lists/*

COPY --from=dind-installer /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dind-installer --link /usr/local/bin/dockerd /usr/local/bin/dockerd
COPY --from=dind-installer --link /usr/local/bin/docker-init /usr/local/bin/docker-init
COPY --from=dind-installer --link /usr/local/bin/docker-proxy /usr/local/bin/docker-proxy
COPY --from=dind-installer --link /usr/local/bin/containerd /usr/local/bin/containerd
COPY --from=dind-installer --link /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
COPY --from=dind-installer --link /usr/local/bin/runc /usr/local/bin/runc
COPY --from=dind-installer --link /usr/local/bin/ctr /usr/local/bin/ctr
COPY --from=dind-installer --link /usr/local/bin/buildctl /usr/local/bin/buildctl
COPY --from=dind-installer --link /usr/local/bin/buildkitd /usr/local/bin/buildkitd
COPY --from=dind-installer --link /usr/local/lib/docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/

COPY --from=builder --link /workspace/target/release/cmux-sandboxd /usr/local/bin/cmux-sandboxd
COPY --from=builder --link /workspace/target/release/cmux /usr/local/bin/cmux
COPY --from=builder --link /workspace/target/release/cmux-bridge /usr/local/bin/cmux-bridge
COPY --from=acp-builder --link /workspace/target/release/codex-acp /usr/local/bin/codex-acp

COPY --link packages/sandbox/scripts/bootstrap-dind.sh /usr/local/bin/bootstrap-dind.sh
COPY --link packages/sandbox/scripts/docker-mode.sh /usr/local/bin/docker-mode.sh
RUN chmod +x /usr/local/bin/bootstrap-dind.sh /usr/local/bin/docker-mode.sh && \
    ln -sf /usr/local/bin/cmux-bridge /usr/local/bin/open-url && \
    ln -sf /usr/local/bin/cmux-bridge /usr/local/bin/xdg-open && \
    # Replace gh CLI with symlinks to cmux-bridge so git credential helpers work
    # This proxies gh commands to the host where the user is authenticated
    rm -f /usr/bin/gh && \
    ln -sf /usr/local/bin/cmux-bridge /usr/bin/gh && \
    # Common gh installation paths (macOS Homebrew, Linux Homebrew, snap, etc.)
    mkdir -p /opt/homebrew/bin && \
    ln -sf /usr/local/bin/cmux-bridge /opt/homebrew/bin/gh && \
    mkdir -p /home/linuxbrew/.linuxbrew/bin && \
    ln -sf /usr/local/bin/cmux-bridge /home/linuxbrew/.linuxbrew/bin/gh && \
    mkdir -p /snap/bin && \
    ln -sf /usr/local/bin/cmux-bridge /snap/bin/gh && \
    ln -sf /usr/local/bin/cmux-bridge /usr/local/bin/gh

# Agent notification hook configurations
# These files configure Claude Code, Codex, and OpenCode to send notifications via cmux-bridge
# Stored in /usr/share/cmux/agent-config/ and copied into sandbox's /root during bubblewrap setup
COPY --link packages/sandbox/agent-config /usr/share/cmux/agent-config

# systemd service units
COPY --link packages/sandbox/systemd/dockerd.service /etc/systemd/system/dockerd.service
COPY --link packages/sandbox/systemd/buildkitd.service /etc/systemd/system/buildkitd.service
COPY --link packages/sandbox/systemd/cmux-sandboxd.service /etc/systemd/system/cmux-sandboxd.service
RUN echo "CMUX_SANDBOX_PORT=46831" > /etc/default/cmux-sandboxd && \
  { echo "CMUX_DOCKER_MODE=dind"; echo "CMUX_DOCKER_SOCKET=/var/run/docker.sock"; } > /etc/default/cmux-docker
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
  ln -s /etc/systemd/system/dockerd.service /etc/systemd/system/multi-user.target.wants/dockerd.service && \
  ln -s /etc/systemd/system/buildkitd.service /etc/systemd/system/multi-user.target.wants/buildkitd.service && \
  ln -s /etc/systemd/system/cmux-sandboxd.service /etc/systemd/system/multi-user.target.wants/cmux-sandboxd.service

ENV CMUX_SANDBOX_PORT=46831 \
  CMUX_DOCKER_MODE=dind \
  CMUX_DOCKER_SOCKET=/var/run/docker.sock \
  DOCKER_HOST=unix:///var/run/docker.sock \
  BROWSER=/usr/local/bin/open-url

EXPOSE 46831
VOLUME ["/var/lib/docker", "/var/lib/cmux/sandboxes"]

ENV container=docker
STOPSIGNAL SIGRTMIN+3
VOLUME ["/sys/fs/cgroup"]
ENTRYPOINT ["/sbin/init"]
