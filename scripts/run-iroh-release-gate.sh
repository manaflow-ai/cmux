#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-iroh-release-gate.sh --mode <automatic|relay-only|relay-expiry|direct-only|private-path> --tag <tag>
       [--staging-base-url <url>] [--skip-build] [--keep-simulator]
       [--report-output <path>] [--print-plan]
       [--production [--stack-env-file <secure-path>]]

Automatic, relay-only, and relay-expiry build a tagged Mac app plus an isolated iOS Simulator
app, sign both into the same staging account, pair only over Iroh, and verify
the app RPC surface. Direct-only runs a deterministic two-Iroh-endpoint proof
inside an isolated iOS Simulator with relays disabled. Private-path runs a
provider-neutral broker-authorized custom-route proof across a non-loopback
private host interface with relays disabled.

Credentials resolve through scripts/lib/dev-secrets.sh and are never printed.
`--production` creates a verified temporary production Stack account, runs the
same gate against https://cmux.com, then deletes the account. Production account
API cleanup failures fail the gate even when direct Stack cleanup succeeds.
EOF
}

MODE=""
TAG=""
STAGING_BASE_URL="${CMUX_IROH_RELEASE_GATE_BASE_URL:-https://cmux-staging.vercel.app}"
SKIP_BUILD=0
KEEP_SIMULATOR=0
REPORT_OUTPUT=""
PRODUCTION=0
STACK_ENV_FILE=""
BASE_URL_WAS_EXPLICIT=0
PRINT_PLAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --staging-base-url) STAGING_BASE_URL="${2:-}"; BASE_URL_WAS_EXPLICIT=1; shift 2 ;;
    --production) PRODUCTION=1; shift ;;
    --stack-env-file) STACK_ENV_FILE="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --report-output) REPORT_OUTPUT="${2:-}"; shift 2 ;;
    --print-plan) PRINT_PLAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: --mode is required" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }
if [[ "$PRODUCTION" -eq 1 && "$BASE_URL_WAS_EXPLICIT" -eq 1 ]]; then
  echo "error: --production cannot be combined with --staging-base-url" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 0 && -n "$STACK_ENV_FILE" ]]; then
  echo "error: --stack-env-file requires --production" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 1 && "$SKIP_BUILD" -eq 1 ]]; then
  echo "error: --production cannot reuse a build because each run bakes a new protected credential-file path" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 1 ]]; then
  STAGING_BASE_URL="https://cmux.com"
fi

case "$MODE" in
  automatic) RAW_MODE="automatic"; GATE_SCENARIO="standard"; GATE_PLAN="app-rpc" ;;
  relay-only) RAW_MODE="relayOnly"; GATE_SCENARIO="relay_rollover"; GATE_PLAN="app-rpc" ;;
  relay-expiry) RAW_MODE="relayOnly"; GATE_SCENARIO="relay_expiry"; GATE_PLAN="app-rpc" ;;
  direct-only) RAW_MODE="directOnly"; GATE_SCENARIO="standard"; GATE_PLAN="simulator-direct-transport" ;;
  private-path) RAW_MODE=""; GATE_SCENARIO="standard"; GATE_PLAN="host-private-path-transport" ;;
  *) echo "error: invalid mode '$MODE'" >&2; exit 2 ;;
esac

if [[ "$PRODUCTION" -eq 1 && "$GATE_PLAN" == "host-private-path-transport" ]]; then
  echo "error: private-path proves the host transport contract and has no production environment" >&2
  exit 2
fi

if [[ "$GATE_PLAN" != "host-private-path-transport" ]]; then
  case "$STAGING_BASE_URL" in
    https://*) ;;
    *) echo "error: --staging-base-url must use https" >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
cmux_attach_validate_dev_tag "$TAG"

if [[ "$PRINT_PLAN" -eq 1 ]]; then
  printf '%s\n' "$GATE_PLAN"
  exit 0
fi

if [[ "$GATE_PLAN" == "simulator-direct-transport" ]]; then
  DIRECT_GATE_ARGUMENTS=(--tag "$TAG")
  [[ "$SKIP_BUILD" -eq 1 ]] && DIRECT_GATE_ARGUMENTS+=(--skip-build)
  [[ "$KEEP_SIMULATOR" -eq 1 ]] && DIRECT_GATE_ARGUMENTS+=(--keep-simulator)
  [[ -n "$REPORT_OUTPUT" ]] && DIRECT_GATE_ARGUMENTS+=(--report-output "$REPORT_OUTPUT")
  exec "$SCRIPT_DIR/run-iroh-direct-transport-gate.sh" "${DIRECT_GATE_ARGUMENTS[@]}"
fi

if [[ "$GATE_PLAN" == "host-private-path-transport" ]]; then
  PRIVATE_GATE_ARGUMENTS=(--tag "$TAG")
  [[ "$SKIP_BUILD" -eq 1 ]] && PRIVATE_GATE_ARGUMENTS+=(--skip-build)
  [[ -n "$REPORT_OUTPUT" ]] && PRIVATE_GATE_ARGUMENTS+=(--report-output "$REPORT_OUTPUT")
  exec "$SCRIPT_DIR/run-iroh-private-path-transport-gate.sh" "${PRIVATE_GATE_ARGUMENTS[@]}"
fi

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
STATE_DIR=""
PROD_ENV_FILE=""
PROD_CREDENTIALS_FILE=""
PROD_ACCOUNT_STATE_FILE=""
PROD_RECOVERY_FILE=""
VERCEL_DIR=""

cleanup() {
  local exit_code=$?
  local cleanup_code=0
  trap - EXIT INT TERM
  set +e
  if [[ -n "$REPORT_WAITER_PID" ]]; then
    kill "$REPORT_WAITER_PID" >/dev/null 2>&1 || true
  fi
  # The helper commits protected recovery state immediately after Stack creates
  # the user. Retry cleanup whenever that state exists, including a partial
  # create whose session-token step failed.
  if [[ -n "$PROD_ACCOUNT_STATE_FILE" && -e "$PROD_ACCOUNT_STATE_FILE" ]]; then
    bun scripts/lib/temporary-stack-user.mjs cleanup \
      --environment-file "$PROD_ENV_FILE" \
      --state-file "$PROD_ACCOUNT_STATE_FILE" \
      --credentials-file "$PROD_CREDENTIALS_FILE" \
      --api-base-url "$STAGING_BASE_URL" \
      --recovery-file "$PROD_RECOVERY_FILE" >/dev/null
    cleanup_code=$?
    if [[ "$cleanup_code" -ne 0 ]]; then
      echo "error: production account cleanup gate failed; redacted report: $PROD_RECOVERY_FILE" >&2
      exit_code=1
    fi
  fi
  if [[ -n "$PROD_ENV_FILE" && "$PROD_ENV_FILE" == "$STATE_DIR/"* ]]; then
    rm -f "$PROD_ENV_FILE"
  fi
  if [[ -n "$VERCEL_DIR" ]]; then
    rm -rf "$VERCEL_DIR"
  fi
  defaults delete "$MAC_BUNDLE_ID" cmux.iroh.debug.transport-mode >/dev/null 2>&1 || true
  pkill -f "cmux DEV ${SLUG}.app/Contents/MacOS/cmux DEV" 2>/dev/null || true
  if [[ "$PRODUCTION" -eq 1 ]]; then
    # Production uses a disposable account and must remove its local tokens.
    # Staging keeps its tagged state so a failed gate remains inspectable and a
    # later --skip-build run can reuse the same authenticated build.
    rm -rf "$HOME/Library/Application Support/cmux/$MAC_BUNDLE_ID"
    security delete-generic-password -s "$MAC_BUNDLE_ID.auth" -a cmux-auth-access-token >/dev/null 2>&1 || true
    security delete-generic-password -s "$MAC_BUNDLE_ID.auth" -a cmux-auth-refresh-token >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_SIMULATOR" -ne 1 && -n "$SIMULATOR_ID" ]]; then
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STATE_DIR" ]]; then
    if [[ -e "$PROD_ACCOUNT_STATE_FILE" ]]; then
      echo "error: temporary Stack user still exists; protected recovery state retained at $PROD_ACCOUNT_STATE_FILE" >&2
      exit_code=1
    else
      rm -rf "$STATE_DIR"
    fi
  fi
  exit "$exit_code"
}

handle_interrupt() {
  exit 130
}

handle_termination() {
  exit 143
}

trap cleanup EXIT
trap handle_interrupt INT
trap handle_termination TERM

if [[ "$PRODUCTION" -eq 1 ]]; then
  # macOS normally exports TMPDIR with a trailing slash. Resolve its logical
  # spelling once so every protected path given to the account helper is
  # absolute and syntactically normalized without changing symlink identity.
  TEMPORARY_ROOT="$(cd -L "${TMPDIR:-/private/tmp}" && pwd -L)"
  TEMPORARY_PREFIX="${TEMPORARY_ROOT%/}"
  STATE_DIR="$(mktemp -d "$TEMPORARY_PREFIX/cmux-iroh-production-${SLUG}.XXXXXX")"
  chmod 700 "$STATE_DIR"
  PROD_ACCOUNT_STATE_FILE="$STATE_DIR/account.json"
  PROD_CREDENTIALS_FILE="$STATE_DIR/credentials.env"
  RECOVERY_DIR="$TEMPORARY_PREFIX/cmux-iroh-production-gate-recovery-$(id -u)"
  mkdir -p "$RECOVERY_DIR"
  chmod 700 "$RECOVERY_DIR"
  PROD_RECOVERY_FILE="$RECOVERY_DIR/${SLUG}.json"

  if [[ -n "$STACK_ENV_FILE" ]]; then
    cmux_dev_secrets_validate_file "$STACK_ENV_FILE"
    PROD_ENV_FILE="$STACK_ENV_FILE"
  else
    VERCEL_DIR="$STATE_DIR/vercel-project"
    mkdir -p "$VERCEL_DIR"
    chmod 700 "$VERCEL_DIR"
    PROD_ENV_FILE="$STATE_DIR/vercel-production.env"
    bunx vercel link --yes --project cmux --scope manaflow --cwd "$VERCEL_DIR"
    bunx vercel env pull "$PROD_ENV_FILE" \
      --environment production \
      --yes \
      --scope manaflow \
      --cwd "$VERCEL_DIR"
    chmod 600 "$PROD_ENV_FILE"
  fi

  bun scripts/lib/temporary-stack-user.mjs create \
    --environment-file "$PROD_ENV_FILE" \
    --state-file "$PROD_ACCOUNT_STATE_FILE" \
    --credentials-file "$PROD_CREDENTIALS_FILE" >/dev/null
  echo "==> temporary production Stack account ready (credentials redacted)"
fi

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
xcrun simctl bootstatus "$SIMULATOR_ID" -b

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  if [[ "$PRODUCTION" -eq 1 ]]; then
    CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
    CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      ./scripts/reload.sh \
        --tag "$TAG" \
        --prod-auth \
        --credentials-file "$PROD_CREDENTIALS_FILE"
    CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
    CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      ./ios/scripts/reload.sh \
        --tag "$TAG" \
        --simulator "$SIMULATOR_NAME" \
        --prod-auth \
        --no-launch
  else
    CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
    CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      ./scripts/reload.sh --tag "$TAG"
    CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
    CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      ./ios/scripts/reload.sh \
        --tag "$TAG" \
        --simulator "$SIMULATOR_NAME" \
        --no-launch
  fi
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
CMUX_ATTACH_ALLOW_RELAUNCH=1 \
CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \
cmux_attach_ensure_mac "$TAG" "$REPO_ROOT" physical_device

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
        timeout=480,
    )
except subprocess.TimeoutExpired:
    raise SystemExit("Iroh release gate report signal timed out")
PY
REPORT_WAITER_PID=$!

MOBILE_LAUNCH_ARGS=(
  --tag "$TAG"
  --simulator-id "$SIMULATOR_ID"
  --ensure-mac
  --detach
  --iroh-release-gate "$RAW_MODE"
)
if [[ "$PRODUCTION" -eq 1 ]]; then
  MOBILE_LAUNCH_ARGS+=(--credentials-file "$PROD_CREDENTIALS_FILE")
fi
CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \
CMUX_IROH_RELEASE_GATE_SCENARIO="$GATE_SCENARIO" \
CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH="$([[ "$GATE_SCENARIO" == "relay_expiry" ]] && printf 1 || printf 0)" \
./scripts/mobile-dev-launch.sh "${MOBILE_LAUNCH_ARGS[@]}" \
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

REPORT_PATH="$REPORT_PATH" EXPECTED_MODE="$RAW_MODE" EXPECTED_SCENARIO="$GATE_SCENARIO" /usr/bin/python3 <<'PY'
import json
import os

with open(os.environ["REPORT_PATH"], encoding="utf-8") as handle:
    report = json.load(handle)

expected_mode = os.environ["EXPECTED_MODE"]
expected_scenario = os.environ["EXPECTED_SCENARIO"]
allowed_keys = {
    "schemaVersion",
    "mode",
    "scenario",
    "passed",
    "hostStatusVerified",
    "terminalRoundTripVerified",
    "workspaceMutationVerified",
    "independentEventsVerified",
    "notificationReconcileVerified",
    "chatSessionsVerified",
    "artifactScanCountVerified",
    "relayCredentialRolloverVerified",
    "endpointContinuityVerified",
    "connectionContinuityVerified",
    "controlStreamContinuityVerified",
    "independentEventsContinuityVerified",
    "artifactLaneVerified",
    "unrefreshedExpiryDisconnectVerified",
    "soakDurationSeconds",
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
if report.get("schemaVersion") != 3:
    problems.append("unexpected schemaVersion")
if report.get("mode") != expected_mode:
    problems.append("mode mismatch")
if report.get("scenario") != expected_scenario:
    problems.append("scenario mismatch")
if report.get("routeKind") != "iroh":
    problems.append("route was not Iroh")
if report.get("selectedPath") not in allowed_paths[expected_mode]:
    problems.append("selected path violated mode")
for key in required_true:
    if report.get(key) is not True:
        problems.append(f"{key} was not true")
if expected_scenario == "relay_rollover":
    for key in (
        "relayCredentialRolloverVerified",
        "endpointContinuityVerified",
        "connectionContinuityVerified",
        "controlStreamContinuityVerified",
        "independentEventsContinuityVerified",
        "artifactLaneVerified",
    ):
        if report.get(key) is not True:
            problems.append(f"{key} was not true")
    if report.get("soakDurationSeconds", 0) < 330:
        problems.append("rollover soak was shorter than 330 seconds")
elif expected_scenario == "relay_expiry":
    if report.get("unrefreshedExpiryDisconnectVerified") is not True:
        problems.append("unrefreshedExpiryDisconnectVerified was not true")

redacted_report = {key: report.get(key) for key in sorted(allowed_keys) if key in report}
print(json.dumps(redacted_report, sort_keys=True))
if problems:
    raise SystemExit("Iroh release gate failed: " + "; ".join(problems))
PY

echo "==> Iroh release gate passed: $MODE"
