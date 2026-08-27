# cmux Cloud devbox image, shared by the E2B template and the Daytona
# snapshot (web/scripts/build-devbox-e2b.ts and build-devbox-daytona.ts;
# build-devbox-freestyle.ts replays the same steps over Freestyle exec).
# Parity target is the chatmux devbox (chatmux repo,
# infra/sandbox-images/Dockerfile) and the Blaxel cmux-devbox template
# (../blaxel/Dockerfile): same devtools, mise toolchains, pinned coding
# agents, ble.sh ghost text, half-life prompt, seeded history, and the
# coderouter agent-config generator.
#
# Session daemon: cmux-tui, the machine's only session daemon
# (docs/cloud-cmux-tui-daemon.md), exactly as on Blaxel. The binary is NOT
# baked: each driver installs the pinned files.cmux.com build
# (sha256-verified) onto the machine at create time and heals it on attach
# (web/services/vms/drivers/cmuxTuiDaemon.ts). The image ships only
# /usr/local/bin/cmux-devbox-boot, the supervisor that waits for the binary
# and restarts the daemon: Daytona registers it as the snapshot entrypoint
# (stop kills processes, start re-runs it), the Freestyle beta bake runs it
# from a systemd unit, and E2B leaves it inert (pause/resume preserves
# processes; the driver starts the daemon directly).
#
# E2B translates this Dockerfile to template steps with a restricted parser:
# no backslash escape sequences inside RUN strings (printf '\n' corrupts; use
# one echo per line), ARG behaves like ENV, ENTRYPOINT would override the
# template start command (so there is none; provider boot commands come from
# the build scripts), and PATH must be a literal value.

FROM debian:bookworm-slim

# Cache-buster: bump the date to force remote builders past stale layer
# caches (Daytona's cache served stale layers for chatmux on 2026-08-21 and
# 2026-08-25; E2B skips cache by default).
ENV CMUX_IMAGE_EPOCH=2026-08-27-r2

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Devtools (chatmux devbox apt list) plus vim (Blaxel parity), sudo for
# non-root provider exec users (E2B), and procps for the drivers' daemon
# process discovery (pgrep).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ripgrep \
    build-essential \
    curl \
    ca-certificates \
    unzip \
    zip \
    xz-utils \
    zstd \
    procps \
    openssh-client \
    pkg-config \
    jq \
    fd-find \
    fzf \
    sqlite3 \
    tmux \
    less \
    rsync \
    file \
    tree \
    nano \
    vim \
    sudo \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
  && echo 'LANG=C.UTF-8' > /etc/default/locale \
  && fd --version && jq --version && fzf --version && sqlite3 --version && tmux -V

# GitHub CLI from the official apt repo (not in bookworm main).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && gh --version

# mise system-wide: data in /opt/mise, global config in /etc/mise, shims first
# on a HARDCODED PATH (no $PATH expansion; E2B's Dockerfile-to-template
# translation must see a literal value). /etc/profile.d covers login shells.
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    PATH=/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mkdir -p /etc/mise /etc/profile.d \
  && echo 'export MISE_DATA_DIR=/opt/mise' > /etc/profile.d/mise.sh \
  && echo 'export MISE_CACHE_DIR=/opt/mise/cache' >> /etc/profile.d/mise.sh \
  && echo 'export MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml' >> /etc/profile.d/mise.sh \
  && echo 'export PATH="/opt/mise/shims:$PATH"' >> /etc/profile.d/mise.sh \
  && mise --version

# Toolchain: node LTS + python 3.12 + bun via mise, uv standalone.
RUN mise use -g node@lts python@3.12 bun@latest \
  && mise reshim \
  && node --version && npm --version && npx --version \
  && python --version && python3 --version \
  && bun --version
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
  && uv --version

# Media layer for agent-browser and display capture: ffmpeg for x11grab,
# Xvfb + xdpyinfo for a headless display, xdotool, fonts for Chrome.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    xvfb \
    xauth \
    x11-utils \
    xdotool \
    fonts-dejavu-core \
    fonts-liberation \
  && rm -rf /var/lib/apt/lists/* \
  && command -v Xvfb && command -v xdpyinfo && command -v xdotool

# Google Chrome stable from the official .deb (amd64 only; every provider
# here runs amd64 sandboxes) with the managed policy (DuckDuckGo default
# search, no first-run ceremony). agent-browser drives it via
# AGENT_BROWSER_EXECUTABLE_PATH; the profile.d export covers exec shells on
# providers that do not inherit image ENV (Freestyle).
RUN curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  && apt-get update && apt-get install -y --no-install-recommends /tmp/chrome.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/chrome.deb \
  && google-chrome-stable --version
COPY chrome-managed-policy.json /etc/opt/chrome/policies/managed/cmux.json
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable
RUN jq -e '.DefaultSearchProviderSearchURL | test("duckduckgo")' /etc/opt/chrome/policies/managed/cmux.json \
  && echo 'export AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable' > /etc/profile.d/cmux-media.sh

# cua computer-use driver, pinned (dormant until an X display exists).
ENV CUA_DRIVER_RS_HOME=/opt/cua-driver
RUN curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh \
  && CUA_DRIVER_RS_VERSION=0.19.3 CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh \
  && rm -f /tmp/cua-install.sh \
  && chmod -R a+rX /opt/cua-driver \
  && cua-driver --version

# Coding agents, pinned at bake time (bump with the image epoch; keep in
# lockstep with ../blaxel/Dockerfile). Installed on the mise node so they
# ride the same toolchain users get.
ARG CMUX_IMAGE_CLAUDE_CODE_VERSION=2.1.246
ARG CMUX_IMAGE_CODEX_VERSION=0.150.0
ARG CMUX_IMAGE_OPENCODE_VERSION=1.18.23
ARG CMUX_IMAGE_PI_VERSION=0.84.3
ARG CMUX_IMAGE_AGENT_BROWSER_VERSION=0.35.1
RUN npm install -g --foreground-scripts \
    "@anthropic-ai/claude-code@${CMUX_IMAGE_CLAUDE_CODE_VERSION}" \
    "@openai/codex@${CMUX_IMAGE_CODEX_VERSION}" \
    "opencode-ai@${CMUX_IMAGE_OPENCODE_VERSION}" \
    "@earendil-works/pi-coding-agent@${CMUX_IMAGE_PI_VERSION}" \
    "agent-browser@${CMUX_IMAGE_AGENT_BROWSER_VERSION}" \
  && mise reshim \
  && claude --version && codex --version && opencode --version && pi --version && agent-browser --version

# Keep Claude Code session transcripts effectively forever (chatmux parity).
RUN mkdir -p /etc/claude-code \
  && echo '{ "cleanupPeriodDays": 99999 }' > /etc/claude-code/managed-settings.json \
  && node -e 'JSON.parse(require("fs").readFileSync("/etc/claude-code/managed-settings.json","utf8"))'

# E2B creates a `user` account for its default exec user; give it sudo so a
# person shelling in through the provider's own surfaces can still administer
# the machine (cmux sessions run as root via the cmux-tui daemon).
RUN if id -u user >/dev/null 2>&1; then echo 'user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/91-user-nopasswd && chmod 0440 /etc/sudoers.d/91-user-nopasswd; fi

# Interactive shell polish: bash IS the shell (Blaxel/chatmux parity); it
# borrows the oh-my-zsh half-life theme colors and ble.sh supplies
# zsh-autosuggestions-style ghost text from history, seeded with the
# claude/codex launch commands. The build-time `bash -ic` check runs without
# a tty, so it exercises the history seeding but skips ble.sh; the verify
# script proves ghost text end-to-end under a tmux PTY.
RUN curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o /tmp/ble.tar.xz \
  && tar xJf /tmp/ble.tar.xz -C /tmp \
  && mv /tmp/ble-nightly /usr/local/share/blesh \
  && rm -f /tmp/ble.tar.xz \
  && test -f /usr/local/share/blesh/ble.sh
COPY cmux-bashrc /etc/cmux/bashrc
COPY seed-history /etc/cmux/seed-history
RUN bash -n /etc/cmux/bashrc \
  && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/bash.bashrc \
  && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/skel/.bashrc \
  && echo '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /root/.bashrc \
  && echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf \
  && bash -ic 'head -2 /root/.bash_history'

# Agent harness config: every shell materializes per-harness model-proxy
# configs from the machine boot env (the coderouter model-plane vars minted
# at VM create) and persists that env 0600 for shells that boot without it.
# The build check generates configs under a throwaway HOME with fake env,
# proves the persisted-env re-source path, then proves the image itself
# ships no generated config.
COPY agent-config.sh /etc/cmux/agent-config.sh
RUN bash -n /etc/cmux/agent-config.sh \
  && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh \
  && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/bash.bashrc \
  && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/skel/.bashrc \
  && echo '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /root/.bashrc \
  && mkdir -p /tmp/agent-config-check \
  && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' \
  && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'base_url = "https://example.invalid/v1"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'persistence = "save-all"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q "export OPENAI_API_KEY='crt_check'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] \
  && rm -rf /tmp/agent-config-check \
  && mkdir -p /tmp/agent-config-resurrect/.config/cmux \
  && echo "export OPENAI_BASE_URL='https://resurrect.invalid/v1'" > /tmp/agent-config-resurrect/.config/cmux/model-plane.env \
  && echo "export OPENAI_API_KEY='crt_persisted'" >> /tmp/agent-config-resurrect/.config/cmux/model-plane.env \
  && env HOME=/tmp/agent-config-resurrect bash -lc 'grep -q "https://resurrect.invalid/v1" "$HOME/.codex/config.toml"' \
  && rm -rf /tmp/agent-config-resurrect \
  && bash -lc 'true' \
  && test ! -e /root/.codex/config.toml \
  && test ! -e /root/.config/cmux/model-plane.env

# The cmux-tui daemon supervisor (see the header; the binary itself is
# installed by the driver at create time, never baked).
COPY cmux-devbox-boot /usr/local/bin/cmux-devbox-boot
RUN chmod 0755 /usr/local/bin/cmux-devbox-boot \
  && sh -n /usr/local/bin/cmux-devbox-boot
