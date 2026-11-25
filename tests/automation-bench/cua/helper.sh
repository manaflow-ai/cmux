#!/usr/bin/env bash
# Start or stop a private cmux Computer Use helper for the bench, on a fleet
# GUI Mac (cmux-lawrence-2), never on a person's laptop. The helper runs with
# its own TCC identity (com.cmuxterm.cua, the Developer ID build inside an
# installed cmux NIGHTLY), its own socket and state directory. Stop kills only
# the PID this script recorded.
#
#   helper.sh start NAME [--glide-ms N]   prints the socket path
#   helper.sh stop NAME
set -euo pipefail
cmd="${1:-}"; name="${2:-}"
[[ "$cmd" =~ ^(start|stop)$ && "$name" =~ ^[a-z0-9-]+$ ]] || { echo "usage: $0 start|stop NAME [--glide-ms N]" >&2; exit 2; }
base="$HOME/nx-bench/$name"
helper="${CMUX_BENCH_HELPER:-/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app}"
sock="$base/cua.sock"
case "$cmd" in
  start)
    mkdir -p "$base/state"; chmod 700 "$base"; rm -f "$sock"
    # Only the Developer ID helper may run: an ad-hoc com.cmuxterm.cua copy
    # fails the Screen Recording row, and granting it replaces that row.
    "$(dirname "$0")/../../../scripts/cmux-cua-helper-trust.sh" check "$helper" \
      || { echo "refusing $helper: not the Developer ID signed cmux Computer Use helper" >&2; exit 1; }
    extra=()
    if [[ "${3:-}" == "--glide-ms" ]]; then extra=(--glide-ms "$4" --dwell-ms 0); fi
    open -n -g -a "$helper" \
      --env CMUX_CUA_STATE_DIR="$base/state" --env CMUX_CUA_TELEMETRY_ENABLED=false \
      --env CMUX_CUA_UPDATE_CHECK=false --env CMUX_CUA_PERMISSIONS_GATE=0 \
      --env CMUX_CUA_EXTERNAL_PERMISSION_FLOW=1 --env CMUX_CUA_RESPONSIBILITY_DISCLAIMED=1 \
      --env CMUX_CUA_CURSOR_LABEL="bench-$name" \
      --args serve --socket "$sock" --no-permissions-gate --cursor-shape cmux --idle-hide-ms 0 ${extra[@]+"${extra[@]}"}
    for _ in $(seq 1 40); do [[ -S "$sock" ]] && break; sleep 0.25; done
    [[ -S "$sock" ]] || { echo "helper did not bind $sock" >&2; exit 1; }
    lsof -t "$sock" | head -1 > "$base/helper.pid"
    echo "$sock"
    ;;
  stop)
    pid="$(cat "$base/helper.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] || exit 0
    command="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$command" == *"MacOS/cmux-cua serve --socket $sock"* ]]; then kill "$pid"; fi
    rm -f "$base/helper.pid"
    ;;
esac
