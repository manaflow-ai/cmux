#!/usr/bin/env bash
# Release smoke for a cmux-browser-host binary (plans/cmux-next/browser-host.md 6d).
# No Chromium needed.
#
# Usage: scripts/cmux-next/smoke-browser-host.sh BINARY EXPECTED_SHA
#
#   1. `BINARY version` exits 0 and prints one line
#      `cmux-browser-host <version> (<EXPECTED_SHA>)`.
#   2. `BINARY guide` exits 0 with non-empty output.
#   3. `BINARY serve --socket T/h.sock` starts; `BINARY list --socket T/h.sock`
#      exits 0 with JSON that has a "sessions" array; the server is stopped.
# Any failure exits 1 and names the check.
set -euo pipefail

bin="${1:?usage: smoke-browser-host.sh BINARY EXPECTED_SHA}"
sha="${2:?usage: smoke-browser-host.sh BINARY EXPECTED_SHA}"
fail() { echo "smoke-browser-host: FAIL: $*" >&2; exit 1; }

[ -x "$bin" ] || fail "$bin is not executable"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "expected sha must be 40 lowercase hex characters (got '$sha')"

version="$("$bin" version)" || fail "version exited $?"
[ "$(printf '%s\n' "$version" | wc -l | tr -d ' ')" = 1 ] || fail "version printed more than one line: $version"
[[ "$version" =~ ^cmux-browser-host\ [0-9]+\.[0-9]+\.[0-9]+[^\ ]*\ \(${sha}\)$ ]] \
  || fail "version line does not name commit $sha: $version"
echo "ok: $version"

guide="$("$bin" guide)" || fail "guide exited $?"
[ -n "${guide//[[:space:]]/}" ] || fail "guide printed nothing"
echo "ok: guide (${#guide} bytes)"

tmp="$(mktemp -d)"
server=""
cleanup() {
  if [ -n "$server" ] && kill -0 "$server" 2>/dev/null; then
    kill "$server" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
sock="$tmp/h.sock"
"$bin" serve --socket "$sock" >"$tmp/serve.log" 2>&1 &
server=$!
for _ in $(seq 1 100); do
  [ -S "$sock" ] && break
  kill -0 "$server" 2>/dev/null || { cat "$tmp/serve.log" >&2; fail "serve exited before its socket appeared"; }
  sleep 0.1
done
[ -S "$sock" ] || { cat "$tmp/serve.log" >&2; fail "serve made no socket at $sock in 10 s"; }
list="$(timeout 30 "$bin" list --socket "$sock")" || fail "list exited $? (124: no reply in 30 s)"
printf '%s' "$list" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) or (isinstance(d, dict) and isinstance(d.get("sessions"), list)), d' \
  || fail "list did not print a JSON session list: $list"
echo "ok: serve + list ($list)"
echo "smoke-browser-host: all checks passed"
