#!/usr/bin/env bash
# A cmux-next terminal's `cmux` must be this app's bundled CLI, even when the
# user's startup files prepend another directory that holds a `cmux` (for
# example ~/.local/bin). The app puts its bin dir first on PATH at spawn
# (BundledCLIEnvironment); Resources/cmux-cli-path moves it back to the front
# after the startup files, before the first prompt, for zsh, bash and fish.
#
# Each case starts a real interactive shell the way the app starts it (the
# env BundledCLIEnvironment and GhosttyShellIntegration write), with startup
# files that prepend a fake ~/.local/bin/cmux, and reads `command -v cmux` at
# the first prompt. It also checks that the user's files ran, that zsh ends
# with the user's ZDOTDIR and HISTFILE, and that no cmux-cli-path variable
# leaks into the shell's children.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
integration="$ROOT/ghostty-next/src/shell-integration"
[[ -d "$integration" ]] || { echo "FAIL: $integration is missing (git submodule update --init ghostty-next)" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

resources="$TMP/cmux DEV t.app/Contents/Resources"
mkdir -p "$resources/bin" "$resources/ghostty" "$TMP/home/.local/bin" "$TMP/zdot"
ln -s "$integration" "$resources/ghostty/shell-integration"
ln -s "$ROOT/Resources/cmux-cli-path" "$resources/cmux-cli-path"
printf '#!/bin/sh\necho bundled\n' >"$resources/bin/cmux"
printf '#!/bin/sh\necho old\n' >"$TMP/home/.local/bin/cmux"
chmod +x "$resources/bin/cmux" "$TMP/home/.local/bin/cmux"
bundled="$resources/bin/cmux"
cli_dir="$resources/cmux-cli-path"
home="$TMP/home"

prepend='export PATH="$HOME/.local/bin:$PATH"; export CMUX_TEST_RC_RAN=1'
printf '%s\n' "$prepend" >"$TMP/zdot/.zshrc"
printf '%s\n' "$prepend" >"$TMP/zdot/.zprofile"
printf '%s\n' "$prepend" >"$home/.bashrc"
printf '%s\n' "$prepend" >"$home/.bash_profile"
mkdir -p "$home/.config/fish"
printf '%s\n' 'set -gx PATH $HOME/.local/bin $PATH; set -gx CMUX_TEST_RC_RAN 1' >"$home/.config/fish/config.fish"

fail=0
probe='printf "cmux=%s rc=%s zdotdir=%s histfile=%s leak=%s\n" "$(command -v cmux)" "${CMUX_TEST_RC_RAN-}" "${ZDOTDIR-unset}" "${HISTFILE-}" "$(env | grep -c "^CMUX_CLI_" || true)"'

check() {
  local name="$1" out="$2" want_zdotdir="${3-}"
  local line; line=$(grep -aoE 'cmux=/.* leak=[0-9]+' <<<"$out" | tail -1 || true)
  if [[ "$line" != "cmux=$bundled rc=1 "* ]]; then
    echo "FAIL: $name: $line" >&2; printf "%s\n" "$out" | tail -20 | cat -v >&2; fail=1; return
  fi
  if [[ "$line" != *" leak=0" ]]; then echo "FAIL: $name: cmux-cli-path variable leaked: $line" >&2; fail=1; return; fi
  if [[ -n "$want_zdotdir" && "$line" != *" zdotdir=$want_zdotdir histfile=$want_zdotdir/.zsh_history "* && "$line" != *" zdotdir=$want_zdotdir histfile= "* ]]; then
    echo "FAIL: $name: ZDOTDIR/HISTFILE not the user's: $line" >&2; fail=1; return
  fi
  echo "PASS: $name"
}

base=(env -i HOME="$home" USER="${USER:-u}" TERM=xterm-256color PATH="$resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      CMUX_BUNDLED_CLI_PATH="$bundled" GHOSTTY_RESOURCES_DIR="$resources/ghostty")

if command -v zsh >/dev/null; then
  zsh_env=("${base[@]}" SHELL="$(command -v zsh)" ZDOTDIR="$cli_dir/zsh"
           CMUX_CLI_ZSH_ZDOTDIR="$resources/ghostty/shell-integration/zsh" GHOSTTY_ZSH_ZDOTDIR="$TMP/zdot")
  for flags in -i -il; do
    out=$(printf '%s\nexit\n' "$probe" | "${zsh_env[@]}" zsh "$flags" 2>&1 || true)
    check "zsh $flags" "$out" "$TMP/zdot"
  done
  # Ghostty's integration off: the layer chains straight to the user's ZDOTDIR.
  out=$(printf '%s\nexit\n' "$probe" | "${base[@]}" SHELL="$(command -v zsh)" ZDOTDIR="$cli_dir/zsh" \
        CMUX_CLI_ZSH_ZDOTDIR="$TMP/zdot" zsh -i 2>&1 || true)
  check "zsh -i without Ghostty integration" "$out" "$TMP/zdot"
else
  echo "SKIP: zsh not installed"
fi

bash_bin=$(command -v bash)
if [[ "$bash_bin" != /bin/bash ]] || [[ -n "${CMUX_TEST_BASH:-}" ]]; then
  bash_bin=${CMUX_TEST_BASH:-$bash_bin}
  for login in "" --login; do
    out=$(printf '%s\nexit\n' "$probe" | "${base[@]}" SHELL="$bash_bin" ENV="$cli_dir/bash/cmux-cli-path.bash" \
          CMUX_CLI_BASH_ENV="$integration/bash/ghostty.bash" GHOSTTY_BASH_INJECT=1 "$bash_bin" $login --posix -i 2>&1 || true)
    check "bash -i $login" "$out"
  done
else
  echo "SKIP: only Apple /bin/bash (Ghostty does not integrate it); set CMUX_TEST_BASH to a newer bash"
fi

if fish_bin=$(command -v fish); then
  fish_probe='printf "cmux=%s rc=%s zdotdir=unset histfile= leak=%s\n" (command -v cmux) "$CMUX_TEST_RC_RAN" (env | grep -c "^CMUX_CLI_"; or true)'
  # fish runs its prompt events only with a terminal on stdin: drive it on a
  # pty, send the probe once the first prompt is drawn, read until the answer.
  out=$("${base[@]}" SHELL="$fish_bin" XDG_CONFIG_HOME="$home/.config" \
        XDG_DATA_DIRS="$cli_dir:/usr/local/share:/usr/share" CMUX_CLI_FISH_XDG_DIR="$cli_dir" \
        /usr/bin/python3 -I -c '
import os, pty, re, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "-i"])
buf, sent, end = b"", False, time.time() + 30
while time.time() < end and not re.search(rb"cmux=/[^\r\n]* leak=[0-9]", buf):
    if select.select([fd], [], [], 0.2)[0]:
        try: buf += os.read(fd, 65536)
        except OSError: break
    elif not sent and buf:
        os.write(fd, sys.argv[2].encode() + b"\n"); sent = True
os.write(fd, b"exit\n")
sys.stdout.write(buf.decode("utf-8", "replace"))
' "$fish_bin" "$fish_probe" 2>&1 || true)
  check "fish -i" "$out"
else
  echo "SKIP: fish not installed"
fi

[[ $fail -eq 0 ]] || exit 1
echo "PASS: plain cmux is the bundled CLI after user startup files"
