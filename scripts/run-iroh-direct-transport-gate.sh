#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-iroh-direct-transport-gate.sh --tag <tag>
       [--skip-build] [--keep-simulator] [--report-output <path>]

Runs two real relay-disabled Iroh endpoints inside a fresh iOS Simulator. The
gate requires authenticated EndpointIDs, a bidirectional stream round trip,
and an observed non-relay path. It never constructs cmux's raw TCP transport.
EOF
}

TAG=""
SKIP_BUILD=0
KEEP_SIMULATOR=0
REPORT_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
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
SIMULATOR_NAME="cmux Iroh direct gate $SLUG"
SIMULATOR_ID=""
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-iroh-direct-$SLUG"
RESULT_BUNDLE="$DERIVED_DATA/CmuxIrohDirectTransportGate.xcresult"

cleanup() {
  if [[ "$KEEP_SIMULATOR" -eq 1 || -z "$SIMULATOR_ID" ]]; then
    return
  fi
  xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

SIMULATOR_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 <<'PY'
import json
import os
import subprocess

def listing(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))

def version_key(runtime):
    return tuple(
        int(part) if part.isdigit() else 0
        for part in str(runtime.get("version", "")).split(".")
    )

runtimes = [
    runtime for runtime in listing("runtimes").get("runtimes", [])
    if runtime.get("isAvailable", False)
    and runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS")
]
if not runtimes:
    raise SystemExit("no available iOS runtime")
runtime = max(runtimes, key=version_key)
preferred_names = (
    "iPhone 17", "iPhone 17 Pro", "iPhone 16", "iPhone 16 Pro",
    "iPhone 15", "iPhone 15 Pro", "iPhone 14", "iPhone 14 Pro",
)
preference = {name: index for index, name in enumerate(preferred_names)}
supported_device_types = runtime.get("supportedDeviceTypes")
if not isinstance(supported_device_types, list):
    supported_device_types = listing("devicetypes").get("devicetypes", [])
device_types = sorted(
    (
        device for device in supported_device_types
        if str(device.get("name", "")).startswith("iPhone")
    ),
    key=lambda device: (
        preference.get(str(device.get("name", "")), len(preference)),
        str(device.get("name", "")),
    ),
)
if not device_types:
    raise SystemExit("available iOS runtime has no supported iPhone device type")
device = device_types[0]
print(subprocess.check_output([
    "xcrun", "simctl", "create", os.environ["SIMULATOR_NAME"],
    device["identifier"], runtime["identifier"],
], text=True).strip())
PY
)"

xcrun simctl boot "$SIMULATOR_ID"
python3 "$REPO_ROOT/scripts/ci/run_with_timeout.py" \
  --timeout-seconds 180 \
  -- xcrun simctl bootstatus "$SIMULATOR_ID" -b

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
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -derivedDataPath "$DERIVED_DATA" \
      -resultBundlePath "$RESULT_BUNDLE" \
      "$XCODEBUILD_ACTION" \
      -only-testing:CmuxIrohTransportTests/CmxIrohDirectTransportGateTests
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
    raise SystemExit(f"direct transport test result was {summary.get('result')}, expected Passed")
if int(summary.get("totalTestCount", 0)) <= 0:
    raise SystemExit("direct transport gate recorded zero tests")
if int(summary.get("passedTests", 0)) <= 0 or int(summary.get("failedTests", 0)) != 0:
    raise SystemExit(
        f"direct transport gate passed={summary.get('passedTests')} "
        f"failed={summary.get('failedTests')}"
    )
PY

REPORT_JSON='{"bidirectionalRoundTripVerified":true,"coverage":"simulator_direct_transport","endpointIdentityVerified":true,"passed":true,"relayMode":"disabled","routeKind":"iroh","schemaVersion":3,"selectedPathClass":"non_relay"}'
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

echo "==> Iroh direct transport gate passed"
