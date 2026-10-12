#!/usr/bin/env bash
# End-to-end check of the native host bridge against a real cmux-tui daemon.
#
# Starts a headless daemon for session $SESSION, builds cmux-native-host and
# runs `cmux-native-host e2e` over each transport in $TRANSPORTS:
#   loopback  plain TCP link (no WebRTC)
#   local     WebRTC data channels, in-memory signaling (no network)
#   worker    WebRTC data channels, real Worker signaling + Cloudflare TURN
#             (needs CMUX_NATIVE_DEV_SECRET; skipped without it)
#   relay     like worker, but ICE restricted to TURN relay candidates
# Each run proves identify, list-workspaces, attach-surface vt-state, send
# (output observed on the attach stream and via read-screen), allowlist
# refusals and the svc host services through the link.
#
# Needs a Mac with Xcode (swift). Env:
#   CMUX_TUI_BIN   cmux-tui binary (default: newest cmux*nxn*.app bundle in
#                  DerivedData, then ~/cmux-native/work/bin/cmux-tui, then PATH)
#   SESSION        daemon session name (default nxtest)
#   TRANSPORTS     default "loopback local worker relay"
#   KEEP_DAEMON=1  leave the daemon running afterwards
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
session="${SESSION:-nxtest}"
transports="${TRANSPORTS:-loopback local worker relay}"

find_tui() {
  if [[ -n "${CMUX_TUI_BIN:-}" ]]; then echo "$CMUX_TUI_BIN"; return; fi
  local newest
  newest="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/cmux*nxn*.app/Contents/Resources/bin/cmux-tui 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" ]]; then echo "$newest"; return; fi
  if [[ -x "$HOME/cmux-native/work/bin/cmux-tui" ]]; then echo "$HOME/cmux-native/work/bin/cmux-tui"; return; fi
  command -v cmux-tui || true
}

tui="$(find_tui)"
if [[ -z "$tui" || ! -x "$tui" ]]; then
  echo "no cmux-tui binary; set CMUX_TUI_BIN" >&2
  exit 2
fi
echo "cmux-tui: $tui ($("$tui" --version 2>/dev/null | head -1))"

"$tui" daemon ensure --session "$session" >/dev/null
socket="$("$tui" daemon status --session "$session" | awk '$1 == "socket" {print $2}')"
if [[ ! -S "$socket" ]]; then
  echo "daemon socket missing: $socket" >&2
  exit 2
fi
echo "daemon: session $session socket $socket"

work="$(mktemp -d /tmp/nxn-e2e.XXXXXX)"
cleanup() {
  rm -rf "$work"
  if [[ "${KEEP_DAEMON:-0}" != 1 ]]; then "$tui" daemon stop --session "$session" --end-terminals >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# A small repository with a modified file and an untracked file.
repo="$work/repo"
mkdir -p "$repo/src"
git -C "$repo" init -q -b main
printf 'one\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=e2e -c user.email=e2e@test.cmux.dev commit -q -m init
printf 'one\ntwo\n' > "$repo/README.md"
printf 'print("hi")\n' > "$repo/src/main.swift"

(cd "$pkg" && swift build --product cmux-native-host 2>&1 | tail -1)
bin="$(cd "$pkg" && swift build --show-bin-path)/cmux-native-host"

status=0
for transport in $transports; do
  echo
  echo "=== transport: $transport"
  args=(e2e --socket "$socket" --git-repo "$repo")
  case "$transport" in
    worker|relay)
      if [[ -z "${CMUX_NATIVE_DEV_SECRET:-}" ]]; then
        echo "SKIP $transport: CMUX_NATIVE_DEV_SECRET is not set"
        continue
      fi
      args+=(--transport worker)
      [[ "$transport" == relay ]] && args+=(--relay-only)
      ;;
    *) args+=(--transport "$transport") ;;
  esac
  if ! "$bin" "${args[@]}" 2>"$work/$transport.log"; then
    status=1
    echo "--- host log ($transport)"
    tail -40 "$work/$transport.log"
  fi
done
exit "$status"
