#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-iroh-release-gate.sh --mode <automatic|relay-only|direct-only> --tag <tag>
       [--staging-base-url <url>] [--skip-build] [--keep-simulator]
       [--report-output <path>]

Builds a tagged Mac app and an isolated iOS Simulator app, signs both into the
same staging account, pairs only over Iroh, and verifies host status, terminal
input/output, one restored workspace rename, independent events, notification
reconcile, chat sessions, artifact count, and the redacted selected path.

Credentials resolve through scripts/lib/dev-secrets.sh and are never printed.
EOF
}

MODE=""
TAG=""
STAGING_BASE_URL="${CMUX_IROH_RELEASE_GATE_BASE_URL:-https://cmux-staging.vercel.app}"
SKIP_BUILD=0
KEEP_SIMULATOR=0
REPORT_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --staging-base-url) STAGING_BASE_URL="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --report-output) REPORT_OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: --mode is required" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }

case "$MODE" in
  automatic) RAW_MODE="automatic" ;;
  relay-only) RAW_MODE="relayOnly" ;;
  direct-only) RAW_MODE="directOnly" ;;
  *) echo "error: invalid mode '$MODE'" >&2; exit 2 ;;
esac

case "$STAGING_BASE_URL" in
  https://*) ;;
  *) echo "error: --staging-base-url must use https" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"

SLUG="$(cmux_attach__slug "$TAG")"
MAC_BUNDLE_ID="$(cmux_attach_mac_bundle_id "$TAG")"
IOS_BUNDLE_ID="dev.cmux.ios.$SLUG"
MAC_APP="$(cmux_attach_mac_app_path "$TAG")"
IOS_APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-ios-$SLUG/Build/Products/Debug-iphonesimulator/cmux.app"
SIMULATOR_NAME="cmux Iroh gate $SLUG"
SIMULATOR_ID=""
REPORT_FILENAME="cmux-iroh-release-gate.json"
REPORT_READY_NOTIFICATION="dev.cmux.ios.iroh-release-gate.report-ready"
REPORT_WAITER_PID=""

cleanup() {
  if [[ -n "$REPORT_WAITER_PID" ]]; then
    kill "$REPORT_WAITER_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_SIMULATOR" -eq 1 ]]; then
    return
  fi
  defaults delete "$MAC_BUNDLE_ID" cmux.iroh.debug.transport-mode >/dev/null 2>&1 || true
  pkill -f "cmux DEV ${SLUG}.app/Contents/MacOS/cmux DEV" 2>/dev/null || true
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

SIMULATOR_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 <<'PY'
import json
import os
import subprocess

def listing(kind):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", kind, "-j"]))

def version_key(runtime):
    return tuple(int(part) if part.isdigit() else 0 for part in str(runtime.get("version", "")).split("."))

runtimes = [
    runtime for runtime in listing("runtimes").get("runtimes", [])
    if runtime.get("isAvailable", True)
    and runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS")
]
device_types = [
    device for device in listing("devicetypes").get("devicetypes", [])
    if device.get("name") in ("iPhone 17", "iPhone 16")
]
if not runtimes or not device_types:
    raise SystemExit("no available iOS runtime or supported iPhone device type")
runtime = max(runtimes, key=version_key)
device = device_types[0]
print(subprocess.check_output([
    "xcrun", "simctl", "create", os.environ["SIMULATOR_NAME"],
    device["identifier"], runtime["identifier"],
], text=True).strip())
PY
)"

xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
  CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
    ./scripts/reload.sh --tag "$TAG"
  CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
  CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
    ./ios/scripts/reload.sh \
      --tag "$TAG" \
      --simulator "$SIMULATOR_NAME" \
      --no-launch
else
  [[ -d "$IOS_APP" ]] || { echo "error: tagged iOS app is missing: $IOS_APP" >&2; exit 1; }
  xcrun simctl install "$SIMULATOR_ID" "$IOS_APP"
fi

[[ -d "$MAC_APP" ]] || { echo "error: tagged Mac app is missing: $MAC_APP" >&2; exit 1; }

# Both endpoints read the mode before constructing their Iroh endpoint. Write
# after installation so a fresh simulator app container cannot replace it.
defaults write "$MAC_BUNDLE_ID" cmux.iroh.debug.transport-mode -string "$RAW_MODE"
xcrun simctl spawn "$SIMULATOR_ID" defaults write \
  "$IOS_BUNDLE_ID" cmux.iroh.debug.transport-mode -string "$RAW_MODE"

# The driver owns this unique tag, so restart it unconditionally. A live pairing
# socket can otherwise make `cmux_attach_ensure_mac` return without relaunching,
# leaving a prior run's transport mode active.
MAC_PROCESS_PATTERN="cmux DEV ${SLUG}.app/Contents/MacOS/cmux DEV"
MAC_PROCESS_IDS="$(pgrep -f "$MAC_PROCESS_PATTERN" | tr '\n' ' ' || true)"
pkill -f "$MAC_PROCESS_PATTERN" 2>/dev/null || true
if [[ -n "$MAC_PROCESS_IDS" ]]; then
  MAC_PROCESS_IDS="$MAC_PROCESS_IDS" /usr/bin/python3 <<'PY'
import errno
import os
import select
import time

pids = {int(raw) for raw in os.environ["MAC_PROCESS_IDS"].split()}
kqueue = select.kqueue()
for pid in tuple(pids):
    try:
        kqueue.control([
            select.kevent(
                pid,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT,
            )
        ], 0, 0)
    except OSError as error:
        if error.errno == errno.ESRCH:
            pids.remove(pid)
        else:
            raise

deadline = time.monotonic() + 5
while pids:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SystemExit("Mac app did not exit before the five-second deadline")
    try:
        events = kqueue.control([], len(pids), remaining)
    except OSError as error:
        if error.errno != errno.ESRCH:
            raise
        events = []
    for event in events:
        pids.discard(event.ident)
    if not events and pids:
        raise SystemExit("Mac app did not signal process exit")
PY
fi
if pgrep -f "$MAC_PROCESS_PATTERN" >/dev/null 2>&1; then
  echo "error: tagged Mac process remained after verified exit wait" >&2
  exit 1
fi
# Unix-domain socket inodes can outlive a cleanly observed process exit. The
# tag is uniquely owned by this driver, and the exact executable is now absent,
# so remove only this validated tag's socket before relaunching.
cmux_attach_remove_stale_socket "$TAG"
CMUX_ATTACH_ALLOW_RELAUNCH=1 cmux_attach_ensure_mac \
  "$TAG" "$REPO_ROOT" simulator_injection

# Wait for the app's atomic report-write signal. Python owns the simulator
# notifyutil child so its timeout is bounded without polling the filesystem.
SIMULATOR_ID="$SIMULATOR_ID" \
REPORT_READY_NOTIFICATION="$REPORT_READY_NOTIFICATION" \
/usr/bin/python3 <<'PY' &
import os
import subprocess

try:
    subprocess.run(
        [
            "xcrun", "simctl", "spawn", os.environ["SIMULATOR_ID"],
            "notifyutil", "-1", os.environ["REPORT_READY_NOTIFICATION"],
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        timeout=180,
    )
except subprocess.TimeoutExpired:
    raise SystemExit("Iroh release gate report signal timed out")
PY
REPORT_WAITER_PID=$!

./scripts/mobile-dev-launch.sh \
  --tag "$TAG" \
  --simulator-id "$SIMULATOR_ID" \
  --ensure-mac \
  --detach \
  --iroh-release-gate "$RAW_MODE" \
  2>&1 | sed -E \
    -e 's/^(==> dev sign-in account:).*/\1 [redacted]/' \
    -e 's/(signed in as )[^,)]+/\1[redacted]/'

DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$IOS_BUNDLE_ID" data)"
REPORT_PATH="$DATA_CONTAINER/Library/Caches/$REPORT_FILENAME"
if ! wait "$REPORT_WAITER_PID"; then
  echo "error: Iroh release gate timed out before producing a report" >&2
  exit 1
fi
REPORT_WAITER_PID=""
[[ -s "$REPORT_PATH" ]] || {
  echo "error: report-ready signal arrived without an atomic report" >&2
  exit 1
}

if [[ -n "$REPORT_OUTPUT" ]]; then
  mkdir -p "$(dirname "$REPORT_OUTPUT")"
  cp "$REPORT_PATH" "$REPORT_OUTPUT"
fi

REPORT_PATH="$REPORT_PATH" EXPECTED_MODE="$RAW_MODE" /usr/bin/python3 <<'PY'
import json
import os

with open(os.environ["REPORT_PATH"], encoding="utf-8") as handle:
    report = json.load(handle)

expected_mode = os.environ["EXPECTED_MODE"]
allowed_keys = {
    "schemaVersion",
    "mode",
    "passed",
    "hostStatusVerified",
    "terminalRoundTripVerified",
    "workspaceMutationVerified",
    "independentEventsVerified",
    "notificationReconcileVerified",
    "chatSessionsVerified",
    "artifactScanCountVerified",
    "routeKind",
    "selectedPath",
    "failure",
}
allowed_paths = {
    "automatic": {"direct", "private_network", "managed_relay", "custom_relay"},
    "relayOnly": {"managed_relay", "custom_relay"},
    "directOnly": {"direct", "private_network"},
}
required_true = (
    "passed",
    "hostStatusVerified",
    "terminalRoundTripVerified",
    "workspaceMutationVerified",
    "independentEventsVerified",
    "notificationReconcileVerified",
    "chatSessionsVerified",
    "artifactScanCountVerified",
)
problems = []
unexpected_keys = set(report) - allowed_keys
if unexpected_keys:
    problems.append("report contained unexpected fields")
if report.get("schemaVersion") != 2:
    problems.append("unexpected schemaVersion")
if report.get("mode") != expected_mode:
    problems.append("mode mismatch")
if report.get("routeKind") != "iroh":
    problems.append("route was not Iroh")
if report.get("selectedPath") not in allowed_paths[expected_mode]:
    problems.append("selected path violated mode")
for key in required_true:
    if report.get(key) is not True:
        problems.append(f"{key} was not true")

redacted_report = {key: report.get(key) for key in sorted(allowed_keys) if key in report}
print(json.dumps(redacted_report, sort_keys=True))
if problems:
    raise SystemExit("Iroh release gate failed: " + "; ".join(problems))
PY

echo "==> Iroh release gate passed: $MODE"
