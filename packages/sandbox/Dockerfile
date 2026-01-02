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

# Build cmux-pty (PTY terminal server)
FROM rust-base AS pty-builder
WORKDIR /workspace
ENV CARGO_TERM_COLOR=never \
  CARGO_PROFILE_RELEASE_STRIP=symbols \
  CARGO_TARGET_DIR=/workspace/target

COPY crates/cmux-terminal ./crates/cmux-terminal
COPY crates/cmux-pty ./crates/cmux-pty

RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  cargo build --locked --release --manifest-path crates/cmux-pty/Cargo.toml

# Build VS Code extension
FROM node:22-bookworm AS ext-builder
RUN npm install -g bun @vscode/vsce
WORKDIR /workspace/packages/shared
# Copy and install shared dependencies first
COPY packages/shared/package.json ./
# Remove workspace refs (convex is not needed for extension build) and install
RUN sed -i '/"@cmux\/convex"/d' package.json && \
    npm install --legacy-peer-deps --ignore-scripts
COPY packages/shared/src ./src
# Now build the extension
WORKDIR /workspace/packages/vscode-extension
COPY packages/vscode-extension/package.json ./
# Replace workspace:* with file:../shared for npm compatibility, then install
RUN sed -i 's/"workspace:\*"/"file:..\/shared"/g' package.json && \
    npm install --legacy-peer-deps
# Copy extension source and build
COPY packages/vscode-extension/src ./src
COPY packages/vscode-extension/tsconfig.json ./
RUN bun run compile && vsce package --allow-missing-repository --no-dependencies --allow-star-activation

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
  dbus-x11 \
  ca-certificates \
  curl \
  bash \
  zsh \
  zsh-autosuggestions \
  zsh-syntax-highlighting \
  vim \
  neovim \
  emacs-nox \
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
  openssh-server \
  jq \
  findutils \
  tigervnc-standalone-server \
  openbox \
  xterm \
  novnc \
  x11-xserver-utils \
  libx11-6 \
  libxcomposite1 \
  libxdamage1 \
  libxext6 \
  libxfixes3 \
  libxrandr2 \
  libxrender1 \
  libxtst6 \
  libnss3 \
  libatk1.0-0 \
  libatk-bridge2.0-0 \
  libcups2 \
  libdrm2 \
  libgbm1 \
  libasound2t64 \
  libpango-1.0-0 \
  libcairo2 \
  fonts-liberation \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Install Google Chrome (optional, may not be available on ARM64)
RUN arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) chrome_url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" ;; \
    aarch64) echo "Chrome not officially available for ARM64, skipping"; exit 0 ;; \
    *) echo "Unsupported architecture: ${arch}" >&2; exit 0 ;; \
  esac; \
  if curl -fsSL -o /tmp/chrome.deb "$chrome_url"; then \
    apt-get update && \
    apt-get install -y --no-install-recommends /tmp/chrome.deb || true; \
    rm -f /tmp/chrome.deb; \
    rm -rf /var/lib/apt/lists/*; \
  else \
    echo "Failed to download Chrome, skipping"; \
  fi

# Install cmux-code (our VSCode fork with OpenVSIX marketplace)
# This provides a web-based VS Code IDE inside each sandbox
RUN arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) ARCH="x64" ;; \
    aarch64) ARCH="arm64" ;; \
    *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
  esac; \
  CMUX_CODE_RELEASE=$(curl -sX GET "https://api.github.com/repos/manaflow-ai/vscode-1/releases/latest" \
    | jq -r '.tag_name' \
    | sed 's|^v||'); \
  echo "Installing cmux-code v${CMUX_CODE_RELEASE}"; \
  mkdir -p /app/cmux-code; \
  curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 \
    -o /tmp/cmux-code.tar.gz \
    "https://github.com/manaflow-ai/vscode-1/releases/download/v${CMUX_CODE_RELEASE}/vscode-server-linux-${ARCH}-web.tar.gz"; \
  tar xf /tmp/cmux-code.tar.gz -C /app/cmux-code/ --strip-components=1; \
  rm -rf /tmp/cmux-code.tar.gz; \
  # Create VS Code settings directory with default config (trust disabled, no agent prompts)
  mkdir -p /root/.vscode-server-oss/data/User /root/.vscode-server-oss/extensions; \
  echo '{"workbench.startupEditor":"none","security.workspace.trust.enabled":false,"security.workspace.trust.untrustedFiles":"open","security.workspace.trust.startupPrompt":"never","security.workspace.trust.emptyWindow":true,"security.workspace.trust.banner":"never","chat.agent.enabled":false,"github.copilot.chat.agent.runTasks":false,"extensions.verifySignature":false,"telemetry.telemetryLevel":"off"}' \
    > /root/.vscode-server-oss/data/User/settings.json

# Set up VS Code settings for all common server directories (code-server, openvscode-server, vscode-server)
RUN SETTINGS='{"security.workspace.trust.enabled":false,"security.workspace.trust.untrustedFiles":"open","security.workspace.trust.startupPrompt":"never","security.workspace.trust.emptyWindow":true,"security.workspace.trust.banner":"never","chat.agent.enabled":false,"github.copilot.chat.agent.runTasks":false}' && \
    for dir in \
      /root/.code-server/User /root/.code-server/Machine \
      /root/.openvscode-server/data/User /root/.openvscode-server/data/Machine \
      /root/.vscode-server/data/User /root/.vscode-server/data/Machine; do \
      mkdir -p "$dir" && echo "$SETTINGS" > "$dir/settings.json"; \
    done

# Set up zsh completions directory and compinit
RUN mkdir -p /root/.zsh/completions && \
    echo 'fpath=(~/.zsh/completions $fpath)' >> /root/.zshrc && \
    echo 'autoload -Uz compinit && compinit -C' >> /root/.zshrc && \
    # Generate claude completions
    claude completions zsh > /root/.zsh/completions/_claude 2>/dev/null || true

# Configure sshd for sandbox access
RUN mkdir -p /run/sshd && \
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config && \
    ssh-keygen -A && \
    # Generate container SSH key for container-to-sandbox SSH access
    mkdir -p /root/.ssh /usr/share/cmux && \
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "cmux-container" && \
    chmod 600 /root/.ssh/id_ed25519 && \
    chmod 644 /root/.ssh/id_ed25519.pub && \
    # Copy public key to shared location accessible by sandboxes
    cp /root/.ssh/id_ed25519.pub /usr/share/cmux/container-ssh.pub

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
    @sourcegraph/amp && \
  find /usr/local/lib/bun/node_modules -name '*.map' -type f -delete && \
  find /usr/local/lib/bun/node_modules -name '*.ts' ! -name '*.d.ts' -type f -delete && \
  find /usr/local/lib/bun/node_modules -type d -name '__tests__' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'test' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '*.md' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'docs' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'doc' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'example' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -type d -name 'examples' -exec rm -rf {} + 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '*.d.ts' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '*.d.ts.map' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name 'CHANGELOG*' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name 'HISTORY*' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '.npmignore' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '.eslint*' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name '.prettier*' -type f -delete 2>/dev/null || true && \
  find /usr/local/lib/bun/node_modules -name 'tsconfig*.json' -type f -delete 2>/dev/null || true && \
  arch="$(uname -m)"; \
  if [ "$arch" = "x86_64" ]; then \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-arm64*' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-darwin*' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-win32*' -exec rm -rf {} + 2>/dev/null || true; \
  elif [ "$arch" = "aarch64" ]; then \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-x64*' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-darwin*' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*-win32*' -exec rm -rf {} + 2>/dev/null || true; \
    find /usr/local/lib/bun/node_modules -maxdepth 1 -type d -name '*linux*musl*' -exec rm -rf {} + 2>/dev/null || true; \
  fi && \
  rm -rf /root/.bun/install/cache

# Install git-delta for better git diffs
RUN arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) delta_arch="x86_64-unknown-linux-gnu" ;; \
    aarch64) delta_arch="aarch64-unknown-linux-gnu" ;; \
    *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
  esac; \
  DELTA_VERSION="0.18.2"; \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-${delta_arch}.tar.gz" | tar -xz -C /tmp && \
  mv /tmp/delta-${DELTA_VERSION}-${delta_arch}/delta /usr/local/bin/delta && \
  rm -rf /tmp/delta-* && \
  chmod +x /usr/local/bin/delta

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
  mv /root/.local/bin/uv /usr/local/bin/uv && \
  rm -rf /root/.local

ARG RUST_VERSION
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal && \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME && \
    rm -rf $RUSTUP_HOME/toolchains/*/share/doc && \
    rm -rf $RUSTUP_HOME/toolchains/*/share/man

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true && \
    mkdir -p /var/lib/cmux/sandboxes

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
COPY --from=dind-installer --link /usr/local/bin/buildkitd /usr/local/bin/buildkitd
COPY --from=dind-installer --link /usr/local/lib/docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/

COPY --from=builder --link /workspace/target/release/cmux-sandboxd /usr/local/bin/cmux-sandboxd
COPY --from=builder --link /workspace/target/release/cmux /usr/local/bin/cmux
COPY --from=builder --link /workspace/target/release/cmux-bridge /usr/local/bin/cmux-bridge
COPY --from=acp-builder --link /workspace/target/release/codex-acp /usr/local/bin/codex-acp
COPY --from=pty-builder --link /workspace/target/release/cmux-pty /usr/local/bin/cmux-pty

# Install cmux VS Code extension
COPY --from=ext-builder /workspace/packages/vscode-extension/*.vsix /tmp/
RUN mkdir -p /root/.vscode-server-oss/extensions && \
    /app/cmux-code/bin/code-server-oss \
      --install-extension /tmp/cmux-vscode-extension-*.vsix \
      --extensions-dir /root/.vscode-server-oss/extensions \
      --user-data-dir /root/.vscode-server-oss/data && \
    rm -f /tmp/*.vsix

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
  { echo "CMUX_DOCKER_MODE=dind"; echo "CMUX_DOCKER_SOCKET=/var/run/docker.sock"; } > /etc/default/cmux-docker && \
  mkdir -p /etc/systemd/system/multi-user.target.wants && \
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
