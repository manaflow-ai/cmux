#!/bin/bash
# cmux machine devbox provision: bring a stock Blaxel sandbox up to parity with
# the chatmux devbox base image (infra/sandbox-images/Dockerfile in the chatmux
# repo): the four coding agents (claude, codex, opencode, pi), everyday
# devtools, and the half-life bash prompt with ble.sh ghost text seeded from
# history, so the shell a user lands in feels like their computer instead of a
# bare stock image.
#
# Contract with services/vms/drivers/blaxel.ts:
# - uploaded to /usr/local/bin/cmux-provision at daemon bootstrap and started
#   as a detached keepAlive process, so create/attach latency never waits on it
#   and the sandbox stays awake until provisioning finishes
# - idempotent: the stamp file short-circuits re-runs inside one sandbox
#   lifetime; a resurrected sandbox has a fresh rootfs and re-provisions
# - /root is the persistent home volume: anything under /root is written only
#   when absent, so a user's edits always win across re-provisions
# - handles both stock image families: blaxel/base-image (Alpine, node baked)
#   and blaxel/xfce-vnc (Ubuntu 22.04, no node)
#
# Deliberately absent, with reasons:
# - Docker Engine: dockerd cannot run in Blaxel microVMs today (no cgroup
#   mounts; docker.io 29.1.3 dockerd panics even with --storage-driver=vfs
#   --iptables=false --bridge=none; verified live 2026-08-26 on us-pdx-1).
# - Chrome + media capture (ffmpeg/Xvfb/cua-driver) and build-essential: the
#   sandbox rootfs is 3.1 GB total; these don't fit alongside the agents.
# - mise/bun: node comes from the image (Alpine) or NodeSource (Ubuntu);
#   python3 and uv cover the python side.
set -u

STAMP=/var/lib/cmux/.provisioned
STAMP_VERSION=v2-devbox-20260826
if [ -f "$STAMP" ] && grep -qF "$STAMP_VERSION" "$STAMP" 2>/dev/null; then
  exit 0
fi

step() { echo "cmux-provision: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

step "start $(date -u +%FT%TZ)"

# --- package layer -----------------------------------------------------------
if have apt-get; then
  export DEBIAN_FRONTEND=noninteractive
  step "apt devtools"
  apt-get update -qq || true
  apt-get install -y -qq --no-install-recommends \
    curl ca-certificates git jq ripgrep fd-find fzf sqlite3 tmux vim nano \
    less rsync file tree zip unzip xz-utils zstd gawk openssh-client procps \
    || step "WARN apt devtools install failed"
  if have fdfind && ! have fd; then
    ln -s "$(command -v fdfind)" /usr/local/bin/fd || true
  fi
  # gh from the official apt repo (not in jammy main)
  if ! have gh; then
    step "gh cli"
    if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; then
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
      apt-get update -qq || true
      apt-get install -y -qq --no-install-recommends gh || step "WARN gh install failed"
    else
      step "WARN gh keyring download failed"
    fi
  fi
  # node LTS via NodeSource; jammy's archive nodejs is far too old for the
  # coding agents.
  if ! have node; then
    step "node 22 (nodesource)"
    { curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
        && apt-get install -y -qq --no-install-recommends nodejs; } \
      || step "WARN node install failed"
  fi
elif have apk; then
  step "apk devtools"
  apk add --no-cache \
    curl ca-certificates git jq ripgrep fd fzf sqlite tmux vim nano \
    less rsync file tree zip unzip xz zstd gawk openssh-client procps \
    || step "WARN apk devtools install failed"
  have gh || apk add --no-cache github-cli || step "WARN gh install failed"
else
  step "WARN no known package manager; skipping devtools"
fi

# --- coding agents -----------------------------------------------------------
# Same npm globals as the chatmux devbox image; installed one by one so a
# platform-specific postinstall failure (e.g. a missing musl binary) cannot
# take the other agents down with it.
if have npm; then
  for pkg in @anthropic-ai/claude-code @openai/codex opencode-ai @earendil-works/pi-coding-agent; do
    step "npm -g $pkg"
    npm install -g --no-fund --no-audit "$pkg" || step "WARN $pkg install failed"
  done
else
  step "WARN npm unavailable; skipping coding agents"
fi

# --- uv (python package runner; xfce-vnc ships it, base-image does not) ------
if ! have uv; then
  step "uv"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    || step "WARN uv install failed"
fi

# --- ble.sh (ghost-text autosuggestions, same build the chatmux devbox uses) -
if [ ! -f /usr/local/share/blesh/ble.sh ]; then
  step "ble.sh"
  if curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
      -o /tmp/ble.tar.xz && tar xJf /tmp/ble.tar.xz -C /tmp; then
    mv /tmp/ble-nightly /usr/local/share/blesh
  else
    step "WARN ble.sh install failed; prompt works without ghost text"
  fi
  rm -f /tmp/ble.tar.xz
fi

# --- shell appearance --------------------------------------------------------
# The interactive bashrc matches the chatmux devbox (oh-my-zsh half-life
# palette + ble.sh ghost text + seeded history) with one deliberate change:
# the machine's own name stays in the prompt (root@noble-wren), because cmux
# machines are addressed by name everywhere.
mkdir -p /etc/cmux
printf '%s\n' \
  'claude --dangerously-skip-permissions' \
  'codex --yolo' \
  > /etc/cmux/seed-history

cat > /etc/cmux/devshell.bashrc <<'CMUX_BASHRC'
# cmux machine interactive bash setup (source: web/services/vms/images/
# blaxel-provision.sh in manaflow-ai/cmux; appearance parity with the chatmux
# devbox). Interactive shells only; exec paths (bash -lc, sh -c) return on the
# first guard.
case $- in *i*) ;; *) return ;; esac
[ -n "${_CMUX_BASHRC-}" ] && return
_CMUX_BASHRC=1

# PTY sessions may not inherit the image ENV; ble.sh warns on empty LANG, and
# prints "insane environment: $USER is empty" when exec paths leave USER unset.
export LANG="${LANG:-C.UTF-8}"
export USER="${USER:-$(id -un)}"

[ -f "$HOME/.bash_history" ] || cp /etc/cmux/seed-history "$HOME/.bash_history" 2>/dev/null

# ble.sh needs a real terminal; sourced with --noattach, attached at the end
# of this file (the documented pattern).
if [ -t 0 ] && [ -f /usr/local/share/blesh/ble.sh ]; then
  source /usr/local/share/blesh/ble.sh --noattach
  # Quiet ble.sh's status marks ([ble: EOF], [ble: exit N]): they read as
  # errors in every terminal pane.
  bleopt prompt_eol_mark= exec_errexit_mark= exec_elapsed_mark= exec_exit_mark=
fi

# half-life palette: purple 135, lime 118, orange 166, hotpink 161.
__cmux_git() {
  local b d=""
  b=$(git symbolic-ref --short HEAD 2>/dev/null) || b=$(git rev-parse --short HEAD 2>/dev/null) || return 0
  git diff --quiet --ignore-submodules HEAD 2>/dev/null || d="*"
  printf ' on \001\033[38;5;166m\002%s\001\033[38;5;161m\002%s\001\033[0m\002' "$b" "$d"
}
PS1='\[\e[38;5;135m\]\u@\h\[\e[0m\] in \[\e[38;5;118m\]\w\[\e[0m\]$(__cmux_git) λ '

HISTSIZE=50000
HISTFILESIZE=50000
shopt -s histappend

alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ll='ls -la'
alias g=git

if [ -n "${BLE_VERSION-}" ]; then ble-attach; fi
CMUX_BASHRC

SOURCE_LINE='[ -f /etc/cmux/devshell.bashrc ] && . /etc/cmux/devshell.bashrc'
# /etc/bash.bashrc only exists (and is only read) on Debian-family bash; Alpine
# bash reads ~/.bashrc alone. Blaxel's sandbox-api runs processes with
# HOME=/blaxel on some images (base-image) and /root on others (xfce-vnc), and
# the PTY shells cmuxd spawns inherit that HOME — wire whichever one this
# sandbox actually uses, plus /root (the persistent home volume) and /etc/skel.
RC_FILES="/root/.bashrc /etc/skel/.bashrc /etc/bash.bashrc"
if [ -n "${HOME-}" ] && [ "$HOME" != "/root" ]; then
  RC_FILES="$RC_FILES $HOME/.bashrc"
fi
for rc in $RC_FILES; do
  mkdir -p "$(dirname "$rc")"
  [ -f "$rc" ] || : > "$rc"
  grep -qF '/etc/cmux/devshell.bashrc' "$rc" || printf '%s\n' "$SOURCE_LINE" >> "$rc"
done

if ! grep -qs 'default-shell' /etc/tmux.conf; then
  echo 'set -g default-shell /bin/bash' >> /etc/tmux.conf
fi

# --- cache cleanup (the rootfs is only 3.1 GB total) --------------------------
if have apt-get; then
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/* || true
fi
have npm && npm cache clean --force >/dev/null 2>&1

# --- stamp -------------------------------------------------------------------
mkdir -p /var/lib/cmux
printf '%s %s\n' "$STAMP_VERSION" "$(date -u +%FT%TZ)" > "$STAMP"
step "done $(date -u +%FT%TZ)"
df -h / | tail -1
