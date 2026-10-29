#!/usr/bin/env bash
# cmux shell defaults for a cloud VM (Chief VMs, dev VMs). Bake-time and
# retrofit, never boot-time: run once as root, idempotent, keeps all data.
#
#   shell-defaults.sh SRC_DIR
#
# SRC_DIR holds cmux-shell.sh and nvm-lazy.sh (this directory) and, from
# web/services/vms/images/devbox: cmux-terminfo.src, cmux-terminfo.sh,
# cmux-bashrc, cmux-prompt.bash, cmux-motd. Nothing new is invented here:
# the devbox image's terminfo overlay, prompt, bashrc and banner are reused.
#
# It does:
#   - terminfo: compile the cmux overlay (xterm-ghostty, ghostty and a
#     Ghostty-capable xterm-256color) into /etc/terminfo;
#   - identity: hostname `cmux` (static, live, 127.0.1.1 alias); the
#     provider's TLS-egress block in /etc/hosts is kept byte for byte;
#   - prompt: `user@cmux in ~/dir λ` (builtins only, no git scan), history
#     50k with histappend, ls/grep colors;
#   - env: LANG=C.UTF-8, COLORTERM=truecolor, TERM fallback to
#     xterm-256color for unknown TERMs;
#   - banner: the cmux motd; the stock Ubuntu scripts and the provider's
#     static /etc/motd are switched off;
#   - tools: htop, tmux, git, less, vim when missing (apt, bake time only);
#   - startup: the provider's eager /etc/profile.d/nvm.sh (about 300 ms per
#     login shell) becomes nvm-lazy.sh; node stays on PATH.
# SSH host keys are not regenerated, so clients' known_hosts stay valid.
#
# CMUX_SHELL_ROOT=/dir writes every file under /dir and skips the live
# hostname and apt (tests). CMUX_VM_NAME overrides the name (default cmux).
set -euo pipefail
src="${1:?usage: shell-defaults.sh SRC_DIR}"
root="${CMUX_SHELL_ROOT:-}"
name="${CMUX_VM_NAME:-cmux}"
etc="$root/etc"
for f in cmux-shell.sh nvm-lazy.sh cmux-terminfo.src cmux-terminfo.sh cmux-bashrc cmux-prompt.bash cmux-motd; do
  [ -s "$src/$f" ] || { echo "missing $src/$f" >&2; exit 1; }
done
mkdir -p "$etc/cmux" "$etc/profile.d" "$etc/update-motd.d" "$etc/terminfo"

# Tools, only what is missing (the Chief images already carry most).
if [ -z "$root" ]; then
  missing=""
  for p in htop tmux git less vim; do command -v "$p" >/dev/null 2>&1 || missing="$missing $p"; done
  command -v tic >/dev/null 2>&1 || missing="$missing ncurses-bin"
  if [ -n "$missing" ]; then
    apt-get update -q >/tmp/cmux-shell-apt.log 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $missing >>/tmp/cmux-shell-apt.log 2>&1 \
      || { tail -20 /tmp/cmux-shell-apt.log >&2; exit 1; }
  fi
fi

# Terminfo overlay.
install -m 0644 "$src/cmux-terminfo.src" "$etc/cmux/terminfo.src"
tic -x -o "$etc/terminfo" "$etc/cmux/terminfo.src"
chmod -R a+rX "$etc/terminfo"
install -m 0644 "$src/cmux-terminfo.sh" "$etc/profile.d/cmux-terminfo.sh"
install -m 0644 "$src/cmux-shell.sh" "$etc/profile.d/cmux-shell.sh"

# Identity.
printf '%s\n' "$name" > "$etc/hostname"
[ -f "$etc/hosts" ] || printf '127.0.0.1\tlocalhost\n' > "$etc/hosts"
awk -v h="$name" 'BEGIN { done = 0 } $1 == "127.0.1.1" { if (!done) { print "127.0.1.1\t" h; done = 1 }; next } { print } END { if (!done) print "127.0.1.1\t" h }' \
  "$etc/hosts" > "$etc/hosts.cmux-identity"
cat "$etc/hosts.cmux-identity" > "$etc/hosts"
rm -f "$etc/hosts.cmux-identity"
if [ -z "$root" ]; then
  hostnamectl set-hostname "$name" 2>/dev/null || hostname "$name"
fi
printf '%s\n' "$name" > "$etc/cmux/vm-name"

# Prompt, history, aliases (the devbox bashrc; ble.sh is not installed, so it
# is skipped there).
install -m 0644 "$src/cmux-bashrc" "$etc/cmux/bashrc"
install -m 0644 "$src/cmux-prompt.bash" "$etc/cmux/prompt.bash"
profile_line='[ -f /etc/profile.d/cmux-shell.sh ] && . /etc/profile.d/cmux-shell.sh'
bashrc_line='[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc'
add_line() { # add_line FILE LINE: append once
  [ -f "$1" ] || return 0
  grep -qxF "$2" "$1" || printf '%s\n' "$2" >> "$1"
}
touch "$etc/bash.bashrc"
add_line "$etc/bash.bashrc" "$profile_line"
add_line "$etc/bash.bashrc" "$bashrc_line"
# Ubuntu's per-user .bashrc resets PS1 after /etc/bash.bashrc; source the
# cmux bashrc again at its end (it only re-applies the prompt the 2nd time).
for rc in "$etc/skel/.bashrc" "$root/root/.bashrc" "$root"/home/*/.bashrc; do add_line "$rc" "$bashrc_line"; done

# tmux: truecolor through to the outer terminal.
tmux_line="set -as terminal-features ',xterm-ghostty:RGB,xterm-256color:RGB'"
touch "$etc/tmux.conf"
add_line "$etc/tmux.conf" "$tmux_line"

# Lazy nvm: only when the provider's eager loader is there (kept as .orig).
nvm_profile="$etc/profile.d/nvm.sh"
if [ -f "$nvm_profile" ] && grep -q 'nvm\.sh"' "$nvm_profile" && ! grep -q 'loaded on first use' "$nvm_profile"; then
  cp "$nvm_profile" "$etc/cmux/nvm.sh.orig"
  install -m 0644 "$src/nvm-lazy.sh" "$nvm_profile"
fi

# Banner.
install -m 0755 "$src/cmux-motd" "$etc/update-motd.d/00-cmux"
for f in "$etc"/update-motd.d/*; do [ "$f" = "$etc/update-motd.d/00-cmux" ] || chmod -x "$f"; done
: > "$etc/motd"
echo "cmux-shell-defaults-ok name=$name"
