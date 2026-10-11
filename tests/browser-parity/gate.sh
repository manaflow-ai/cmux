#!/usr/bin/env bash
# Browser REPL regression gate: every suite that proves behavior, in one
# command. Run it before each push; a round that changes behavior must keep it
# green or change goldens with a reviewed reason.
#
#   tests/browser-parity/gate.sh                 # unit, sites, cmux-dev, oracle
#   PARITY_CMUX_CLI=<tagged cli> CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock \
#     tests/browser-parity/gate.sh --app [--app-runs N]   # plus the real app
set -uo pipefail
cd "$(dirname "$0")/../.."

app=0
app_runs=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app=1 ;;
    --app-runs) app_runs="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

failed=()
step() {
  local name="$1"; shift
  echo "== $name"
  if "$@"; then echo "   ok"; else echo "   FAILED"; failed+=("$name"); fi
}

step unit node --test tests/browser-parity/unit/*.test.mjs
step sites node --test tests/browser-parity/sites/*.test.mjs
step cmux-dev node tests/browser-parity/run.mjs check --backend cmux-dev
step oracle node tests/browser-parity/run.mjs check --backend oracle
if [ "$app" = 1 ]; then
  : "${PARITY_CMUX_CLI:?set PARITY_CMUX_CLI to the tagged app cmux CLI}"
  for i in $(seq 1 "$app_runs"); do
    step "app run $i/$app_runs" node tests/browser-parity/run.mjs check --backend cmux
  done
fi

if [ ${#failed[@]} -gt 0 ]; then
  echo "gate FAILED: ${failed[*]}"
  exit 1
fi
echo "gate passed"
