#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-iroh-private-path-transport-gate.sh --tag <tag>
       [--skip-build] [--report-output <path>]

Runs two real relay-disabled Iroh endpoints across a non-loopback private host
interface. The gate requires broker-authorized custom numeric route selection,
exact EndpointID admission, bidirectional RPC bytes, and fail-closed wrong
identity, wrong port, and inactive-route cases.

This proves cmux's provider-neutral private-path contract. It does not claim
that the runner owns or traverses an external VPN tunnel.
EOF
}

TAG=""
SKIP_BUILD=0
REPORT_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --report-output) REPORT_OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"

SLUG="$(cmux_attach__slug "$TAG")"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-iroh-private-path-$SLUG"
RESULT_BUNDLE="$DERIVED_DATA/CmuxIrohPrivatePathTransportGate.xcresult"
XCODEBUILD_ACTION="test"
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  XCODEBUILD_ACTION="test-without-building"
fi
rm -rf "$RESULT_BUNDLE"

(
  cd "$REPO_ROOT/Packages/Shared/CmuxIrohTransport"
  python3 "$REPO_ROOT/scripts/ci/run_with_timeout.py" \
    --timeout-seconds 600 \
    -- xcodebuild \
      -scheme CmuxIrohTransport \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED_DATA" \
      -resultBundlePath "$RESULT_BUNDLE" \
      "$XCODEBUILD_ACTION" \
      -only-testing:CmuxIrohTransportTests/CmxIrohPrivatePathTransportGateTests
)

RESULT_BUNDLE="$RESULT_BUNDLE" /usr/bin/python3 <<'PY'
import json
import os
import subprocess

summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary",
    "--path", os.environ["RESULT_BUNDLE"], "--compact",
]))
if summary.get("result") != "Passed":
    raise SystemExit(
        f"private-path transport test result was {summary.get('result')}, expected Passed"
    )
total = int(summary.get("totalTestCount", 0))
passed = int(summary.get("passedTests", 0))
failed = int(summary.get("failedTests", 0))
if total != 4 or passed != 4 or failed != 0:
    raise SystemExit(
        f"private-path transport gate total={total} passed={passed} failed={failed}"
    )
PY

REPORT_JSON='{"bidirectionalRPCVerified":true,"brokerGrantVerified":true,"brokerPortAuthoritative":true,"coverage":"host_private_interface_contract","customAddressInjected":true,"endpointIdentityVerified":true,"externalVPNVerified":false,"inactiveRouteRejected":true,"passed":true,"relayMode":"disabled","routeKind":"iroh","routeSource":"custom_vpn","schemaVersion":3,"selectedPathClass":"private_network","wrongIdentityRejected":true,"wrongPortRejected":true}'
printf '%s\n' "$REPORT_JSON"
if [[ -n "$REPORT_OUTPUT" ]]; then
  mkdir -p "$(dirname "$REPORT_OUTPUT")"
  REPORT_OUTPUT="$REPORT_OUTPUT" REPORT_JSON="$REPORT_JSON" /usr/bin/python3 <<'PY'
import json
import os

with open(os.environ["REPORT_OUTPUT"], "w", encoding="utf-8") as handle:
    json.dump(json.loads(os.environ["REPORT_JSON"]), handle, sort_keys=True)
    handle.write("\n")
PY
fi

echo "==> Iroh private-path transport gate passed"
