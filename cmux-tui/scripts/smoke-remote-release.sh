#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/release/cmux-tui" >&2
  exit 2
fi

BIN_DIR="$(cd "$(dirname "$1")" && pwd)"
BIN="$BIN_DIR/$(basename "$1")"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-release-smoke.XXXXXX")"
DAEMON_PID=""

cleanup() {
  if [[ -n "$DAEMON_PID" ]]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

"$BIN" daemon \
  --session release-smoke \
  --socket "$RUN_DIR/mux.sock" \
  --remote-state-dir "$RUN_DIR/daemon-state" \
  --remote-link-socket "$RUN_DIR/link.sock" \
  --remote-admin-socket "$RUN_DIR/admin.sock" \
  >"$RUN_DIR/daemon.stdout.log" \
  2>"$RUN_DIR/daemon.stderr.log" &
DAEMON_PID=$!

for _ in $(seq 1 200); do
  [[ -S "$RUN_DIR/link.sock" ]] && break
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    cat "$RUN_DIR/daemon.stderr.log" >&2
    echo "release daemon exited before publishing its Unix link" >&2
    exit 1
  fi
  sleep 0.05
done

if [[ ! -S "$RUN_DIR/link.sock" ]]; then
  cat "$RUN_DIR/daemon.stderr.log" >&2
  echo "release daemon did not publish its Unix link" >&2
  exit 1
fi

if ! timeout --kill-after=2s 20s "$BIN" rpc \
  "unix://$RUN_DIR/link.sock" \
  --state-dir "$RUN_DIR/client-state" \
  --lanes single \
  --connect-timeout-seconds 10 \
  --request '{"type":"capabilities"}' \
  >"$RUN_DIR/rpc.json" \
  2>"$RUN_DIR/rpc.stderr.log"; then
  cat "$RUN_DIR/daemon.stderr.log" >&2
  cat "$RUN_DIR/rpc.stderr.log" >&2
  echo "release client did not complete a trusted Unix RPC" >&2
  exit 1
fi

if ! grep -q '"type":"capabilities"' "$RUN_DIR/rpc.json" \
  || ! grep -q '"capabilities":\[' "$RUN_DIR/rpc.json"; then
  cat "$RUN_DIR/rpc.json" >&2
  echo "release RPC returned an unexpected response" >&2
  exit 1
fi
