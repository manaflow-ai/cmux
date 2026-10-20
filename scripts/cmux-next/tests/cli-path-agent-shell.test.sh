#!/usr/bin/env bash
# An agent's own shells must run this app's bundled `cmux`. Codex and Claude
# Code run each command in a fresh `zsh -lc` (or `zsh -c`), which reads the
# user's .zshenv, .zprofile and .zlogin again; those often prepend
# ~/.local/bin, where an old PyPI `cmux` lives. acpmux starts every agent
# with ZDOTDIR=Resources/cmux-cli-path/zsh-agent (and the user's ZDOTDIR in
# CMUX_CLI_AGENT_ZDOTDIR); that layer runs the user's files from the user's
# ZDOTDIR and moves the bundled bin dir back to the front after each one.
#
# Cases: login and non-login, non-interactive and interactive, with and
# without a user ZDOTDIR, and a user .zshenv that sets its own ZDOTDIR. Each
# checks that `command -v cmux` is the bundled CLI, that the user's files ran,
# and that an interactive shell keeps the user's ZDOTDIR and HISTFILE.
# Needs only zsh (no app build, no Ghostty).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
layer="$ROOT/Resources/cmux-cli-path/zsh-agent"
[[ -r "$layer/.zshenv" ]] || { echo "FAIL: $layer/.zshenv is missing" >&2; exit 1; }
command -v zsh >/dev/null || { echo "SKIP: no zsh"; exit 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

resources="$TMP/cmux DEV t.app/Contents/Resources"
mkdir -p "$resources/bin" "$TMP/home/.local/bin" "$TMP/zdot" "$TMP/xdg/zsh"
ln -s "$ROOT/Resources/cmux-cli-path" "$resources/cmux-cli-path"
printf '#!/bin/sh\necho bundled\n' >"$resources/bin/cmux"
printf '#!/bin/sh\necho old\n' >"$TMP/home/.local/bin/cmux"
chmod +x "$resources/bin/cmux" "$TMP/home/.local/bin/cmux"
bundled="$resources/bin/cmux"
home="$TMP/home"

# Every startup file prepends the old cmux and records that it ran.
for dir in "$home" "$TMP/zdot" "$TMP/xdg/zsh"; do
  for file in .zshenv .zprofile .zshrc .zlogin; do
    printf 'export PATH="$HOME/.local/bin:$PATH"; export RAN_%s=1\n' "${file#.}" >"$dir/$file"
  done
done
# A user whose ~/.zshenv moves zsh to an XDG ZDOTDIR.
mkdir -p "$TMP/xdghome/.local/bin"
cp "$TMP/home/.local/bin/cmux" "$TMP/xdghome/.local/bin/cmux"
printf 'export ZDOTDIR="%s"\n' "$TMP/xdg/zsh" >"$TMP/xdghome/.zshenv"

probe='printf "cmux=%s env=%s profile=%s rc=%s login=%s zdotdir=%s histfile=%s\n" "$(command -v cmux)" "${RAN_zshenv-}" "${RAN_zprofile-}" "${RAN_zshrc-}" "${RAN_zlogin-}" "${ZDOTDIR-unset}" "${HISTFILE-}"'

fail=0
run() {
  local name="$1" user_home="$2" user_zdotdir="$3" want="$4"; shift 4
  local -a env=(HOME="$user_home" PATH="$resources/bin:/usr/bin:/bin" SHELL=/bin/zsh
    TERM=dumb CMUX_BUNDLED_CLI_PATH="$bundled" ZDOTDIR="$layer")
  [[ -n "$user_zdotdir" ]] && env+=(CMUX_CLI_AGENT_ZDOTDIR="$user_zdotdir")
  local out
  out=$(cd "$TMP" && env -i "${env[@]}" /bin/zsh "$@" "$probe" </dev/null 2>&1 || true)
  local line; line=$(grep -aoE 'cmux=.*' <<<"$out" | tail -1 || true)
  if [[ "$line" != "cmux=$bundled "* ]]; then
    echo "FAIL: $name: $line" >&2; printf '%s\n' "$out" | tail -10 >&2; fail=1; return
  fi
  if [[ "$line" != *"$want"* ]]; then
    echo "FAIL: $name: want '$want' in: $line" >&2; fail=1; return
  fi
  if [[ "$line" == *"zdotdir=$layer"* || "$line" == *"histfile=$layer"* ]]; then
    echo "FAIL: $name: the layer leaked into ZDOTDIR/HISTFILE: $line" >&2; fail=1; return
  fi
  echo "PASS: $name"
}

run "zsh -lc, user ZDOTDIR" "$home" "$TMP/zdot" "env=1 profile=1 rc= login=1 zdotdir=$TMP/zdot " -lc
run "zsh -lc, no ZDOTDIR" "$home" "" "env=1 profile=1 rc= login=1 zdotdir=unset " -lc
run "zsh -c, user ZDOTDIR" "$home" "$TMP/zdot" "env=1 profile= rc= login= zdotdir=$TMP/zdot " -c
run "zsh -lc, .zshenv sets an XDG ZDOTDIR" "$TMP/xdghome" "" "profile=1 rc= login=1 zdotdir=$TMP/xdg/zsh " -lc
run "zsh -ilc, user ZDOTDIR" "$home" "$TMP/zdot" "env=1 profile=1 rc=1 login=1 zdotdir=$TMP/zdot histfile=$TMP/zdot/.zsh_history" -ilc
run "zsh -ic, no ZDOTDIR" "$home" "" "env=1 profile= rc=1 login= zdotdir=unset histfile=$home/.zsh_history" -ic

# Without the bundled CLI the layer changes nothing but still runs the
# user's files.
out=$(cd "$TMP" && env -i HOME="$home" PATH=/usr/bin:/bin ZDOTDIR="$layer" CMUX_CLI_AGENT_ZDOTDIR="$TMP/zdot" \
  /bin/zsh -lc "$probe" </dev/null 2>&1 || true)
if [[ "$out" == *"cmux=$home/.local/bin/cmux env=1 profile=1 rc= login=1 zdotdir=$TMP/zdot "* ]]; then
  echo "PASS: no bundled CLI"
else
  echo "FAIL: no bundled CLI: $out" >&2; fail=1
fi

exit "$fail"
