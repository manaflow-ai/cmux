# cmux Cloud baked Blaxel machine image ("base snapshot"): sandbox/cmux-devbox.
#
# Parity target is the chatmux devbox (chatmux repo, infra/sandbox-images/Dockerfile)
# plus its desktop image (Dockerfile.desktop): same devtools, mise toolchains, coding
# agents, ble.sh ghost text, half-life prompt, seeded history, and an openbox/TigerVNC
# desktop with Ghostty, Chrome, and Thunar on a tint2 dock.
#
# Driver contract this image must keep (web/services/vms/drivers/blaxel.ts):
#   - /usr/local/bin/start-vnc.sh exists, is idempotent, and is runnable as user `cua`
#     with HOME=/home/cua DISPLAY=:1 (DESKTOP_VNC_HEAL_COMMAND runs exactly that).
#   - The VNC RFB port is 5901 (the heal probe greps for a :5901 listener).
#   - The noVNC web client answers on 6901 (CLI cloudVMDesktopPort) at `/` with the
#     standard noVNC URL params (autoconnect/resize/reconnect).
#   - /root is shadowed at runtime by the persistent home volume, so nothing user-facing
#     may be baked into /root; per-HOME setup materializes at shell start from /etc/cmux.
#   - /etc/cmux/image-stamp marks the image as baked; the driver skips its create-time
#     provisioning fallback when it is present.
#
# Bake with web/scripts/build-blaxel-image.sh (remote build on Blaxel, no local docker).

# Trixie, not bookworm: the pinned Ghostty community .deb needs GTK4 >= 4.14.
FROM debian:trixie-slim

# Cache-buster: bump to force a full rebuild on Blaxel's builder.
ENV CMUX_IMAGE_EPOCH=2026-08-28-r10

# Blaxel's sandbox API binary is mandatory in every custom image: it is the control
# plane (port 8080) the driver uses for filesystem and process operations.
COPY --from=ghcr.io/blaxel-ai/sandbox:latest /sandbox-api /usr/local/bin/sandbox-api

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Devtools (chatmux devbox apt list, plus vim, plus iproute2 which the driver's VNC
# heal probe needs for `ss`).
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
    iproute2 \
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
  && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# GitHub CLI from its own apt repo.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# mise as the system-wide toolchain manager (node/python/bun), shims on PATH for
# every process, not just login shells.
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    PATH=/opt/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mkdir -p /etc/mise /etc/profile.d \
  && printf '%s\n' \
    'export MISE_DATA_DIR=/opt/mise' \
    'export MISE_CACHE_DIR=/opt/mise/cache' \
    'export MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml' \
    'export PATH="/opt/mise/shims:$PATH"' > /etc/profile.d/mise.sh

RUN mise use -g node@lts python@3.12 bun@latest \
  && mise reshim \
  && node --version && python3 --version && bun --version

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
  && uv --version

# Desktop + media stack (chatmux Dockerfile.desktop apt list, plus novnc so the
# desktop wrapper's iframe finds a web client at /, plus the capture/input tools).
RUN apt-get update && apt-get install -y --no-install-recommends \
    tigervnc-standalone-server \
    tigervnc-tools \
    openbox \
    tint2 \
    thunar \
    feh \
    novnc \
    websockify \
    at-spi2-core \
    dbus-x11 \
    x11-xserver-utils \
    xdg-utils \
    adwaita-icon-theme \
    libgl1-mesa-dri \
    mesa-vulkan-drivers \
    libvulkan1 \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    fonts-dejavu-core \
    fonts-liberation \
    xdotool \
    ffmpeg \
    xvfb \
    xauth \
    x11-utils \
    netcat-openbsd \
  && rm -rf /var/lib/apt/lists/* \
  && [ -e /usr/share/novnc/index.html ] || ln -s vnc.html /usr/share/novnc/index.html

# Google Chrome stable + managed policy (DuckDuckGo default search).
RUN curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  && apt-get update && apt-get install -y --no-install-recommends /tmp/chrome.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/chrome.deb
COPY chrome-managed-policy.json /etc/opt/chrome/policies/managed/cmux.json
# The dock launches Chrome through this entry: first run is pre-accepted so no
# ToS dialog ever shows on a machine (or in anything resumed from its snapshot).
COPY google-chrome-cmux.desktop /etc/cmux/apps/google-chrome-cmux.desktop
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable
# Blaxel's deploy-time rootfs slimming strips /usr/share/applications and the
# raster icon themes, so the dock's launcher entries and icons are kept under
# /etc/cmux, which survives. Icons are copied out of the installed packages
# here, before slimming can eat them.
COPY thunar-cmux.desktop /etc/cmux/apps/thunar-cmux.desktop
RUN mkdir -p /etc/cmux/icons \
  && cp /opt/google/chrome/product_logo_128.png /etc/cmux/icons/google-chrome.png \
  && cp "$(find /usr/share/icons -name 'org.xfce.thunar.png' -path '*128*' | head -1)" /etc/cmux/icons/thunar.png \
  && test -s /etc/cmux/icons/thunar.png

# Ghostty, pinned community .deb for trixie (github.com/mkasberg/ghostty-ubuntu;
# no official upstream .deb exists). libgl1-mesa-dri above is the software GL its
# renderer uses under Xvnc.
RUN curl -fsSL -o /tmp/ghostty.deb https://github.com/mkasberg/ghostty-ubuntu/releases/download/1.3.1-0-ppa2/ghostty_1.3.1-0.ppa2_amd64_trixie.deb \
  && apt-get update && apt-get install -y --no-install-recommends /tmp/ghostty.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/ghostty.deb \
  && ghostty +version
COPY ghostty-cmux.desktop /etc/cmux/apps/ghostty-cmux.desktop
RUN mkdir -p /etc/cmux/icons \
  && cp "$(find /usr/share/icons -name 'com.mitchellh.ghostty.png' -path '*128*' | head -1)" /etc/cmux/icons/ghostty.png \
  && test -s /etc/cmux/icons/ghostty.png

# cua computer-use driver, pinned.
ENV CUA_DRIVER_RS_HOME=/opt/cua-driver
RUN curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh \
  && CUA_DRIVER_RS_VERSION=0.19.3 CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh \
  && rm -f /tmp/cua-install.sh \
  && ls /usr/local/bin | grep -qi cua

# Coding agents, pinned at bake time (bump with the image epoch). Installed on the
# mise node so they ride the same toolchain users get.
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
  && claude --version && codex --version && opencode --version && pi --version

# Keep Claude Code session transcripts effectively forever (chatmux parity).
RUN mkdir -p /etc/claude-code \
  && echo '{ "cleanupPeriodDays": 99999 }' > /etc/claude-code/managed-settings.json

# Desktop user. The driver heals the desktop as `cua` with HOME=/home/cua; the
# stock blaxel/xfce-vnc image set that contract and we keep it.
RUN useradd -m -u 1000 -s /bin/bash cua

# Interactive shell setup: ble.sh ghost text, half-life prompt, seeded history.
# Everything global lives under /etc/cmux because /root is shadowed by the
# persistent home volume at runtime; cmux-bashrc materializes per-HOME state.
RUN curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o /tmp/ble.tar.xz \
  && tar xJf /tmp/ble.tar.xz -C /tmp \
  && mv /tmp/ble-nightly /usr/local/share/blesh \
  && rm -f /tmp/ble.tar.xz
COPY cmux-bashrc /etc/cmux/bashrc
COPY seed-history /etc/cmux/seed-history
COPY tint2rc /etc/cmux/tint2rc
# CC0 mountain-lake wallpaper; provenance and license in WALLPAPER.md.
COPY wallpaper.jpg /usr/share/backgrounds/cmux/wallpaper.jpg
RUN printf '%s\n' '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/bash.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /etc/skel/.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /root/.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> /home/cua/.bashrc \
  && echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf

# Agent harness config: every shell materializes per-harness model-proxy
# configs from the machine boot env (the coderouter model-plane vars minted at
# VM create), and persists that env on the durable home volume because Blaxel
# create-time envs are not replayed on resurrect. The build check generates
# configs under a throwaway HOME with fake env, then proves the image itself
# ships no generated config.
COPY agent-config.sh /etc/cmux/agent-config.sh
RUN bash -n /etc/cmux/agent-config.sh \
  && printf '%s\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' > /etc/profile.d/cmux-agents.sh \
  && printf '%s\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/bash.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /etc/skel/.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /root/.bashrc \
  && printf '%s\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> /home/cua/.bashrc \
  && mkdir -p /tmp/agent-config-check \
  && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=crt_check CMUX_CODEROUTER_URL=https://example.invalid bash -lc 'true' \
  && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'base_url = "https://example.invalid/v1"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'persistence = "save-all"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q "export OPENAI_API_KEY='crt_check'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] \
  && grep -q '"baseUrl": "https://example.invalid/v1"' /tmp/agent-config-check/.pi/agent/models.json \
  && grep -qF '"x-coderouter-route-token": "$OPENAI_API_KEY"' /tmp/agent-config-check/.pi/agent/models.json \
  && ! grep -q 'crt_check' /tmp/agent-config-check/.pi/agent/models.json \
  && test ! -e /tmp/agent-config-check/.config/opencode/opencode.json \
  && rm -rf /tmp/agent-config-check \
  && mkdir -p /tmp/agent-config-resurrect/.config/cmux \
  && printf '%s\n' "export OPENAI_BASE_URL='https://resurrect.invalid/v1'" "export OPENAI_API_KEY='crt_persisted'" > /tmp/agent-config-resurrect/.config/cmux/model-plane.env \
  && env HOME=/tmp/agent-config-resurrect bash -lc 'grep -q "https://resurrect.invalid/v1" "$HOME/.codex/config.toml"' \
  && rm -rf /tmp/agent-config-resurrect \
  && bash -lc 'true' \
  && test ! -e /root/.codex/config.toml \
  && test ! -e /root/.pi/agent/models.json \
  && test ! -e /root/.config/opencode/opencode.json \
  && test ! -e /root/.config/cmux/model-plane.env

# /entrypoint.sh is the path every official Blaxel template uses; the microVM
# boot command comes from this ENTRYPOINT.
COPY start-vnc.sh /usr/local/bin/start-vnc.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/start-vnc.sh /entrypoint.sh /usr/local/bin/sandbox-api \
  && bash -n /usr/local/bin/start-vnc.sh && bash -n /entrypoint.sh

# Stamp last: its presence tells the driver every layer above baked successfully.
RUN mkdir -p /etc/cmux && echo "cmux-devbox ${CMUX_IMAGE_EPOCH}" > /etc/cmux/image-stamp

EXPOSE 5901 6901 8080
ENTRYPOINT ["/entrypoint.sh"]
