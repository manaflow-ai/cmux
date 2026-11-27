#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/run-iroh-release-gate.sh --mode <direct-only|private-path> --tag <tag>
       [--skip-build] [--keep-simulator] [--report-output <path>] [--print-plan]

Direct-only runs a deterministic two-Iroh-endpoint proof inside an isolated iOS
Simulator with relays disabled (scripts/run-iroh-direct-transport-gate.sh).
Private-path runs a provider-neutral broker-authorized custom-route proof
across a non-loopback private host interface with relays disabled
(scripts/run-iroh-private-path-transport-gate.sh). Both test the
CmuxIrohTransport package and need no Mac app.

The app-rpc modes (automatic, relay-only, relay-expiry) and their flags
(--production, --soak-profile, --real-usage, --simulator-id, --credentials-file,
--staging-base-url, --v2-base-url, --presence-base-url, --stack-env-file) are
refused with exit 2: they paired the iOS app with the tagged Mac app's iroh
phone listener (mobile.attach_ticket.create / mobile.rpc.ready), which the
cmux-next Mac app no longer runs.
EOF_USAGE
}

NO_MAC_RPC="the cmux-next Mac app no longer runs the iroh phone listener (mobile.attach_ticket.create / mobile.rpc.ready)"

MODE=""
TAG=""
SKIP_BUILD=0
KEEP_SIMULATOR=0
REPORT_OUTPUT=""
PRINT_PLAN=0
REFUSED_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --report-output) REPORT_OUTPUT="${2:-}"; shift 2 ;;
    --print-plan) PRINT_PLAN=1; shift ;;
    # Flags of the removed app-rpc modes: one value each, except the switches.
    --production|--real-usage) REFUSED_FLAG="${REFUSED_FLAG:-$1}"; shift ;;
    --staging-base-url|--v2-base-url|--presence-base-url|--stack-env-file|--simulator-id|--soak-profile|--credentials-file)
      REFUSED_FLAG="${REFUSED_FLAG:-$1}"; shift; [[ $# -eq 0 ]] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: --mode is required" >&2; exit 2; }
case "$MODE" in
  direct-only) GATE_PLAN="simulator-direct-transport" ;;
  private-path) GATE_PLAN="host-private-path-transport" ;;
  automatic|relay-only|relay-expiry)
    echo "error: --mode $MODE has no target: it paired the iOS app with the tagged Mac app, and $NO_MAC_RPC; use --mode direct-only or --mode private-path" >&2
    exit 2
    ;;
  *) echo "error: invalid mode '$MODE'" >&2; exit 2 ;;
esac
if [[ -n "$REFUSED_FLAG" ]]; then
  echo "error: $REFUSED_FLAG belonged to the removed app-rpc modes ($NO_MAC_RPC); --mode $MODE does not take it" >&2
  exit 2
fi
[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"

if [[ "$PRINT_PLAN" -eq 1 ]]; then
  printf '%s\n' "$GATE_PLAN"
  exit 0
fi

# Hosted runners can reuse RUNNER_TEMP between jobs. Never let a build or
# launch failure upload a verdict from an earlier run at the same output path.
if [[ -n "$REPORT_OUTPUT" ]]; then
  rm -f "$REPORT_OUTPUT"
fi

if [[ "$GATE_PLAN" == "simulator-direct-transport" ]]; then
  DIRECT_GATE_ARGUMENTS=(--tag "$TAG")
  [[ "$SKIP_BUILD" -eq 1 ]] && DIRECT_GATE_ARGUMENTS+=(--skip-build)
  [[ "$KEEP_SIMULATOR" -eq 1 ]] && DIRECT_GATE_ARGUMENTS+=(--keep-simulator)
  [[ -n "$REPORT_OUTPUT" ]] && DIRECT_GATE_ARGUMENTS+=(--report-output "$REPORT_OUTPUT")
  exec "$SCRIPT_DIR/run-iroh-direct-transport-gate.sh" "${DIRECT_GATE_ARGUMENTS[@]}"
fi

PRIVATE_GATE_ARGUMENTS=(--tag "$TAG")
[[ "$SKIP_BUILD" -eq 1 ]] && PRIVATE_GATE_ARGUMENTS+=(--skip-build)
[[ -n "$REPORT_OUTPUT" ]] && PRIVATE_GATE_ARGUMENTS+=(--report-output "$REPORT_OUTPUT")
exec "$SCRIPT_DIR/run-iroh-private-path-transport-gate.sh" "${PRIVATE_GATE_ARGUMENTS[@]}"
