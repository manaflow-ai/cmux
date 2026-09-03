# cmux Cloud devbox image (web/scripts/build-devbox-freestyle.ts replays
# these steps over Freestyle exec on the freestyle/ubuntu base; its build API
# has no COPY). Ubuntu 24.04, the distro every cmux Cloud machine runs, so
# package names, the Ghostty .deb and the desktop stack below are exactly what
# the Freestyle bake installs.
# Parity target for the shell layer is the chatmux devbox (chatmux repo,
# infra/sandbox-images/Dockerfile): same devtools, mise toolchains, pinned
# coding agents, ble.sh ghost text, half-life prompt, seeded history, and the
# coderouter agent-config generator. The desktop layer is the retired Blaxel
# cmux-devbox desktop (openbox/TigerVNC, tint2 dock, Ghostty, Chrome, Thunar,
# noVNC on 6901), the same stack on every provider.
#
# Session daemon: cmux-tui, the machine's only session daemon
# (docs/cloud-cmux-tui-daemon.md). This container image bakes NO binary: a
# driver installs the pinned files.cmux.com build (sha256-verified) at create
# time and heals it on attach (web/services/vms/drivers/cmuxTuiDaemon.ts). The
# image ships only /usr/local/bin/cmux-devbox-boot, the supervisor that waits
# for the binary and restarts the daemon, and (without systemd) runs the
# desktop supervisor as the work user. The Freestyle public-platform bake
# (build-devbox-freestyle.ts) runs the same supervisor from a systemd unit but
# bakes the binary, binds the daemon identity to the instance id, and runs the
# desktop from its own cmux-desktop unit.
#
# Portability rules the Freestyle replay depends on (originally imposed by a
# remote builder's restricted Dockerfile parser): no backslash escape
# sequences inside RUN strings (printf '\n' corrupts; use one echo per line),
# ARG behaves like ENV, no ENTRYPOINT (boot commands come from the build
# script), and PATH must be a literal value.

FROM ubuntu:24.04

# Cache-buster: bump the date to force remote builders past stale layer
# caches (a remote builder served stale layers for chatmux on 2026-08-21 and
# 2026-08-25). Also the image version /etc/cmux/image-stamp carries.
ENV CMUX_IMAGE_EPOCH=2026-09-02-r4

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Devtools (chatmux devbox apt list) plus vim, sudo for non-root provider
# exec users, procps for the driver's daemon process discovery (pgrep), and
# iproute2 for the desktop's port probes (ss).
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
    sudo \
    util-linux \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
  && echo 'LANG=C.UTF-8' > /etc/default/locale \
  && fd --version && jq --version && fzf --version && sqlite3 --version && tmux -V && ss -V

# GitHub CLI from the official apt repo (not in the Ubuntu archive).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && gh --version

# mise system-wide: data in /opt/mise, global config in /etc/mise, shims first
# on a HARDCODED PATH (no $PATH expansion; the replay must see a literal
# value). /etc/profile.d covers login shells.
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
# Xvfb + xdpyinfo/xprop for a headless display, xdotool, fonts for Chrome.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    xvfb \
    xauth \
    x11-utils \
    xdotool \
    fonts-dejavu-core \
    fonts-liberation \
  && rm -rf /var/lib/apt/lists/* \
  && command -v Xvfb && command -v xdpyinfo && command -v xprop && command -v xdotool

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

# cua computer-use driver, pinned. It acts on whatever X display a shell
# points it at: the VNC desktop below, once /etc/cmux/desktop-env.sh has
# exported DISPLAY and the accessibility bus (`cua-driver doctor` proves it).
ENV CUA_DRIVER_RS_HOME=/opt/cua-driver
RUN curl -fsSL https://cua.ai/driver/install.sh -o /tmp/cua-install.sh \
  && CUA_DRIVER_RS_VERSION=0.23.2 CUA_DRIVER_BIN_DIR=/usr/local/bin CUA_DRIVER_NO_MODIFY_PATH=1 bash /tmp/cua-install.sh \
  && rm -f /tmp/cua-install.sh \
  && chmod -R a+rX /opt/cua-driver \
  && cua-driver --version

# Desktop layer: TigerVNC serving an openbox session with the tint2 dock
# (Chrome, Files, Ghostty), Thunar, the CC0 wallpaper, the accessibility bus
# for computer-use (at-spi2-core; gdbus is what cua-driver's doctor probes
# it with), TigerVNC's clipboard helper, and noVNC + websockify on
# 6901 (the port the app's Displays row opens; RFB 5901 stays loopback-only).
# Contract: web/services/vms/images/desktop.ts and desktop/start-vnc.sh.
# The package list and the Ghostty .deb are ARGs because
# build-devbox-freestyle.ts reads them from this file (devbox-image-common.ts),
# never a second copy. GL/Vulkan/xkb libraries are what Ghostty and Chrome
# render with under Xvnc. Ghostty ships no upstream .deb; the community build
# for Ubuntu 24.04 is pinned by release tag and by the SHA-256 of its bytes.
ARG CMUX_IMAGE_DESKTOP_PACKAGES="tigervnc-standalone-server tigervnc-tools openbox tint2 thunar feh novnc websockify at-spi2-core dbus-x11 libglib2.0-bin x11-xserver-utils xdg-utils adwaita-icon-theme libgl1-mesa-dri mesa-vulkan-drivers libvulkan1 libxkbcommon0 libxkbcommon-x11-0 netcat-openbsd"
ARG CMUX_IMAGE_GHOSTTY_DEB_URL=https://github.com/mkasberg/ghostty-ubuntu/releases/download/1.3.1-0-ppa2/ghostty_1.3.1-0.ppa2_amd64_24.04.deb
ARG CMUX_IMAGE_GHOSTTY_DEB_SHA256=478d440153ef544426418efc7d6d8901715359f452c46be29071901a94b8cd47
RUN apt-get update && apt-get install -y --no-install-recommends $CMUX_IMAGE_DESKTOP_PACKAGES \
  && rm -rf /var/lib/apt/lists/* \
  && { [ -e /usr/share/novnc/index.html ] || ln -s vnc.html /usr/share/novnc/index.html; } \
  && command -v Xtigervnc && command -v vncconfig && command -v websockify && command -v openbox && command -v tint2 \
  && command -v dbus-launch && command -v dbus-send && command -v gdbus && command -v feh && command -v thunar \
  && { test -x /usr/libexec/at-spi-bus-launcher || test -x /usr/lib/at-spi2-core/at-spi-bus-launcher; }
RUN curl -fsSL -o /tmp/ghostty.deb "$CMUX_IMAGE_GHOSTTY_DEB_URL" \
  && echo "$CMUX_IMAGE_GHOSTTY_DEB_SHA256  /tmp/ghostty.deb" | sha256sum -c - \
  && apt-get update && apt-get install -y --no-install-recommends /tmp/ghostty.deb \
  && rm -rf /var/lib/apt/lists/* /tmp/ghostty.deb \
  && ghostty +version | head -1

# Dock launchers, icons and the dock config live under /etc/cmux so the dock
# never depends on a distro's /usr/share/applications or icon-theme layout.
# The systemd unit is shipped for VM images; a container runs the desktop
# supervisor from cmux-devbox-boot instead.
COPY desktop/google-chrome-cmux.desktop /etc/cmux/apps/google-chrome-cmux.desktop
COPY desktop/thunar-cmux.desktop /etc/cmux/apps/thunar-cmux.desktop
COPY desktop/ghostty-cmux.desktop /etc/cmux/apps/ghostty-cmux.desktop
COPY desktop/tint2rc /etc/cmux/tint2rc
COPY desktop/wallpaper.jpg /usr/share/backgrounds/cmux/wallpaper.jpg
COPY desktop/start-vnc.sh /usr/local/bin/start-vnc.sh
COPY desktop/cmux-desktop-boot /usr/local/bin/cmux-desktop-boot
COPY desktop/cmux-desktop.service /etc/systemd/system/cmux-desktop.service
COPY desktop/desktop-env.sh /etc/cmux/desktop-env.sh
RUN chmod 0755 /usr/local/bin/start-vnc.sh /usr/local/bin/cmux-desktop-boot \
  && bash -n /usr/local/bin/start-vnc.sh && sh -n /usr/local/bin/cmux-desktop-boot && sh -n /etc/cmux/desktop-env.sh \
  && mkdir -p /etc/cmux/icons \
  && cp /opt/google/chrome/product_logo_128.png /etc/cmux/icons/google-chrome.png \
  && cp "$(find /usr/share/icons -name 'org.xfce.thunar.png' -path '*128*' | head -1)" /etc/cmux/icons/thunar.png \
  && cp "$(find /usr/share/icons -name 'com.mitchellh.ghostty.png' -path '*128*' | head -1)" /etc/cmux/icons/ghostty.png \
  && test -s /etc/cmux/icons/thunar.png && test -s /etc/cmux/icons/ghostty.png && test -s /etc/cmux/icons/google-chrome.png \
  && echo '[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh' > /etc/profile.d/cmux-desktop.sh \
  && echo '[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh' >> /etc/bash.bashrc \
  && echo '[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh' >> /etc/skel/.bashrc \
  && echo '[ -f /etc/cmux/desktop-env.sh ] && . /etc/cmux/desktop-env.sh' >> /root/.bashrc

# Coding agents, pinned at bake time (bump with the image epoch; keep in
# lockstep with the chatmux devbox). Installed on the mise node so they
# ride the same toolchain users get.
ARG CMUX_IMAGE_CLAUDE_CODE_VERSION=2.1.252
ARG CMUX_IMAGE_CODEX_VERSION=0.151.0
ARG CMUX_IMAGE_OPENCODE_VERSION=1.18.25
ARG CMUX_IMAGE_PI_VERSION=0.84.4
ARG CMUX_IMAGE_AGENT_BROWSER_VERSION=0.35.2
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

# The work user is the uid-1000 account (`ubuntu` on the Ubuntu base, as on
# Freestyle): the desktop session runs as it, and it gets passwordless sudo
# so a person shelling in through the provider's own surfaces can still
# administer the machine and coding agents' root-refusing modes work
# (cmux sessions run as root via the cmux-tui daemon).
RUN work_user="$(getent passwd 1000 | cut -d: -f1)" && test -n "$work_user" \
  && echo "$work_user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/91-work-user-nopasswd && chmod 0440 /etc/sudoers.d/91-work-user-nopasswd \
  && sudo -n -u "$work_user" sudo -n true

# Interactive shell polish: bash IS the shell (chatmux parity); it
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

# Seed ble.sh tput caches for the TERMs cmux uses, exactly as the chatmux
# template does (its Dockerfile carries the full rationale): without them the
# FIRST shell on a machine prints "ble/term.sh: updating tput cache ... done"
# into the pane before its first prompt. Both cache homes are seeded: the
# XDG seed copied by cmux-bashrc from /etc/cmux/blesh-cache-seed, and
# <blesh>/cache.d for uid 0 plus the uid-1000 work user (numeric chown: the
# provider's name for that user is not guaranteed).
RUN mkdir -p /etc/cmux/blesh-cache-seed \
  && for term in xterm-256color screen-256color tmux-256color linux xterm-ghostty; do \
       echo exit | TERM="$term" HOME=/tmp/blesh-seed-home XDG_CACHE_HOME=/etc/cmux/blesh-cache-seed \
         script -qec 'bash -i' /dev/null >/dev/null 2>&1 || true; \
     done \
  && rm -rf /tmp/blesh-seed-home \
  && chmod -R a+rX /etc/cmux/blesh-cache-seed \
  && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-256color \
  && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.screen-256color \
  && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.tmux-256color \
  && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.linux \
  && test -s /etc/cmux/blesh-cache-seed/blesh/*/term.xterm-ghostty \
  && mkdir -p /usr/local/share/blesh/cache.d/0 /usr/local/share/blesh/cache.d/1000 \
  && chmod a+rwxt /usr/local/share/blesh/cache.d \
  && cp /etc/cmux/blesh-cache-seed/blesh/*/term.* /usr/local/share/blesh/cache.d/0/ \
  && cp /etc/cmux/blesh-cache-seed/blesh/*/term.* /usr/local/share/blesh/cache.d/1000/ \
  && chmod 700 /usr/local/share/blesh/cache.d/0 /usr/local/share/blesh/cache.d/1000 \
  && chown -R 1000:1000 /usr/local/share/blesh/cache.d/1000

# Agent harness config: every shell materializes per-harness model-proxy
# configs from the machine boot env (the coderouter model-plane vars set at
# VM create: base URLs, placeholder keys, the VM id; the route token itself
# is injected by the provider's TLS edge and never reaches the guest) and
# persists that env 0600 for shells that boot without it.
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
  && env HOME=/tmp/agent-config-check OPENAI_BASE_URL=https://example.invalid/v1 OPENAI_API_KEY=cmux-vm-edge-placeholder CMUX_CODEROUTER_URL=https://example.invalid ANTHROPIC_BASE_URL=https://example.invalid ANTHROPIC_API_KEY=cmux-vm-edge-placeholder CMUX_VM_ID=vm-check bash -lc 'true' \
  && grep -q 'model_provider = "cmux"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'base_url = "https://example.invalid/v1"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'wire_api = "responses"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'supports_websockets = false' /tmp/agent-config-check/.codex/config.toml \
  && grep -q 'persistence = "save-all"' /tmp/agent-config-check/.codex/config.toml \
  && grep -q "export OPENAI_API_KEY='cmux-vm-edge-placeholder'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && grep -q "export ANTHROPIC_BASE_URL='https://example.invalid'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && grep -q "export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && grep -q "export CMUX_VM_ID='vm-check'" /tmp/agent-config-check/.config/cmux/model-plane.env \
  && [ "$(stat -c %a /tmp/agent-config-check/.config/cmux/model-plane.env)" = "600" ] \
  && grep -q '"baseUrl": "https://example.invalid/v1"' /tmp/agent-config-check/.pi/agent/models.json \
  && grep -qF '"apiKey": "e30.' /tmp/agent-config-check/.pi/agent/models.json \
  && ! grep -q 'x-coderouter-route-token' /tmp/agent-config-check/.pi/agent/models.json \
  && ! grep -q 'crt_' /tmp/agent-config-check/.pi/agent/models.json \
  && test ! -e /tmp/agent-config-check/.config/opencode/opencode.json \
  && rm -rf /tmp/agent-config-check \
  && mkdir -p /tmp/agent-config-resurrect/.config/cmux \
  && echo "export OPENAI_BASE_URL='https://resurrect.invalid/v1'" > /tmp/agent-config-resurrect/.config/cmux/model-plane.env \
  && echo "export OPENAI_API_KEY='cmux-vm-edge-placeholder'" >> /tmp/agent-config-resurrect/.config/cmux/model-plane.env \
  && env HOME=/tmp/agent-config-resurrect bash -lc 'grep -q "https://resurrect.invalid/v1" "$HOME/.codex/config.toml"' \
  && rm -rf /tmp/agent-config-resurrect \
  && bash -lc 'true' \
  && test ! -e /root/.codex/config.toml \
  && test ! -e /root/.pi/agent/models.json \
  && test ! -e /root/.config/opencode/opencode.json \
  && test ! -e /root/.config/cmux/model-plane.env

# The boot supervisor (see the header; the daemon binary itself is installed
# by the driver at create time, never baked). Without systemd it also runs the
# desktop supervisor as the work user.
COPY cmux-devbox-boot /usr/local/bin/cmux-devbox-boot
RUN chmod 0755 /usr/local/bin/cmux-devbox-boot \
  && sh -n /usr/local/bin/cmux-devbox-boot

# Desktop self-check, the way a container boots it: the supervisor starts the
# session as the work user, both contract ports answer, noVNC serves its
# client, the window manager, dock, clipboard helper and accessibility bus are
# up, the wallpaper is on the root window, root can reach the display too
# (cmux sessions run as root), a login shell inherits DISPLAY from the
# published env, then everything is stopped and the session's state removed
# so the image ships no live desktop.
RUN work_user="$(getent passwd 1000 | cut -d: -f1)" && work_home="$(getent passwd 1000 | cut -d: -f6)" \
  && mkdir -p "$work_home/.config/google-chrome" && touch "$work_home/.config/google-chrome/First Run" && chown -R 1000:1000 "$work_home" \
  && { cmux-devbox-boot >/tmp/cmux-devbox-boot.log 2>&1 & } && boot_pid=$! \
  && for i in $(seq 1 90); do ss -tln | grep -q ':6901 ' && ss -tln | grep -q ':5901 ' && test -s /run/cmux-desktop/env && break; sleep 1; done \
  && ss -tln | grep -q ':5901 ' && ss -tln | grep -q ':6901 ' \
  && ss -tln | grep ':5901 ' | grep -q '127.0.0.1:5901' \
  && curl -fsS http://127.0.0.1:6901/ | grep -qi novnc \
  && pgrep -u "$work_user" -x 'Xvnc|Xtigervnc' && pgrep -u "$work_user" -x openbox && pgrep -u "$work_user" -x tint2 \
  && pgrep -u "$work_user" -x vncconfig && pgrep -u "$work_user" -f at-spi-bus-launcher \
  && pgrep -u "$work_user" -f cmux-desktop-boot \
  && runuser -u "$work_user" -- env DISPLAY=:1 xdpyinfo | grep dimensions \
  && env DISPLAY=:1 xdpyinfo >/dev/null \
  && env DISPLAY=:1 xprop -root _XROOTPMAP_ID | grep -q 0x \
  && grep -q "^export DISPLAY=':1'$" /run/cmux-desktop/env \
  && grep -q '^export AT_SPI_BUS_ADDRESS=' /run/cmux-desktop/env && grep -q '^export AT_SPI_BUS=' /run/cmux-desktop/env \
  && [ "$(env -i HOME=/root PATH="$PATH" bash -lc 'echo "$DISPLAY"')" = ":1" ] \
  && [ "$(runuser -u "$work_user" -- env -i HOME="$work_home" PATH="$PATH" bash -lc 'echo "$DISPLAY"')" = ":1" ] \
  && runuser -u "$work_user" -- env -i HOME="$work_home" PATH="$PATH" bash -lc 'test -n "$DBUS_SESSION_BUS_ADDRESS" && test -n "$AT_SPI_BUS_ADDRESS"' \
  && [ -z "$(env -i HOME=/root PATH="$PATH" bash -lc 'echo "$DBUS_SESSION_BUS_ADDRESS"')" ] \
  && echo desktop-self-check-ok; rc=$?; \
  cat /tmp/cmux-devbox-boot.log /var/log/cmux-desktop.log 2>/dev/null | tail -20; \
  kill "$boot_pid" 2>/dev/null; pkill -u "$work_user"; sleep 2; pkill -9 -u "$work_user"; \
  rm -rf /run/cmux-desktop /tmp/.X1-lock /tmp/.X11-unix/X1 /var/log/cmux-desktop.log /tmp/cmux-devbox-boot.log "$work_home/.cmux"; \
  test ! -e /tmp/.X11-unix/X1 && test $rc -eq 0

# Login banner (pam_motd on providers that run sshd; inert elsewhere). It
# reads the versions the bake pinned from /etc/cmux/tool-versions so login
# never runs a tool to ask.
COPY cmux-motd /etc/update-motd.d/00-cmux
RUN chmod 0755 /etc/update-motd.d/00-cmux \
  && sh -n /etc/update-motd.d/00-cmux \
  && mkdir -p /etc/cmux \
  && echo "claude ${CMUX_IMAGE_CLAUDE_CODE_VERSION} · codex ${CMUX_IMAGE_CODEX_VERSION} · opencode ${CMUX_IMAGE_OPENCODE_VERSION} · pi ${CMUX_IMAGE_PI_VERSION}" > /etc/cmux/tool-versions \
  && echo "node $(node --version) · python $(python3 --version | awk '{print $2}') · bun $(bun --version) · uv $(uv --version | awk '{print $2}') · gh $(gh --version | head -1 | awk '{print $3}')" >> /etc/cmux/tool-versions \
  && cat /etc/cmux/tool-versions

# Image stamp, last: its presence says every layer above baked, and which
# layers the image carries (verify-devbox-image.ts keys the desktop checks on
# the word "desktop").
RUN echo "cmux-devbox ${CMUX_IMAGE_EPOCH} desktop" > /etc/cmux/image-stamp && cat /etc/cmux/image-stamp
