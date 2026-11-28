#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/run-iroh-release-gate.sh --mode <direct-only|private-path> --tag <tag>
       [--skip-build] [--keep-simulator] [--report-output <path>] [--print-plan]

Every mode is refused with exit 2. Direct-only and private-path ran
CmuxIrohTransport's transport proofs (scripts/run-iroh-direct-transport-gate.sh,
scripts/run-iroh-private-path-transport-gate.sh); that Swift package had no
consumer and was deleted with both scripts.

The app-rpc modes (automatic, relay-only, relay-expiry) and their flags
(--production, --soak-profile, --real-usage, --simulator-id, --credentials-file,
--staging-base-url, --v2-base-url, --presence-base-url, --stack-env-file) are
refused with exit 2: they paired the iOS app with the tagged Mac app's iroh
phone listener (mobile.attach_ticket.create / mobile.rpc.ready), which the
cmux-next Mac app no longer runs.
EOF_USAGE
}

NO_MAC_RPC="the cmux-next Mac app no longer runs the iroh phone listener (mobile.attach_ticket.create / mobile.rpc.ready)"
NO_SWIFT_TRANSPORT="CmuxIrohTransport, the Swift package its transport proofs tested, had no consumer and was deleted"

MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    # Every other flag is accepted and ignored: every mode is refused below.
    --skip-build|--keep-simulator|--print-plan|--production|--real-usage) shift ;;
    --tag|--report-output|--staging-base-url|--v2-base-url|--presence-base-url|--stack-env-file|--simulator-id|--soak-profile|--credentials-file)
      shift; [[ $# -eq 0 ]] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: --mode is required" >&2; exit 2; }
case "$MODE" in
  direct-only|private-path)
    echo "error: --mode $MODE has no target: $NO_SWIFT_TRANSPORT" >&2
    exit 2
    ;;
  automatic|relay-only|relay-expiry)
    echo "error: --mode $MODE has no target: it paired the iOS app with the tagged Mac app, and $NO_MAC_RPC" >&2
    exit 2
    ;;
  *) echo "error: invalid mode '$MODE'" >&2; exit 2 ;;
esac
