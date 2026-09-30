#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-iroh-release-gate.sh --mode <automatic|relay-only|relay-expiry|direct-only|private-path> --tag <tag>
       [--staging-base-url <url>] [--v2-base-url <url>] [--presence-base-url <url>]
       [--skip-build] [--keep-simulator] [--simulator-id <dedicated-monitor-udid>]
       [--report-output <path>] [--print-plan] [--real-usage]
       [--soak-profile <basic|stress>]
       [--credentials-file <agent-profile-env>]
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
# The web API and legacy compatibility broker remain on their existing staging
# origin. The v2 control plane is verified separately through the canonical
# Cloudflare Worker. A caller can override either origin for an isolated test.
STAGING_BASE_URL="${CMUX_IROH_RELEASE_GATE_BASE_URL:-https://cmux-staging.vercel.app}"
V2_BASE_URL="${CMUX_IROH_RELEASE_GATE_V2_BASE_URL:-https://cmux-v2-staging.debussy.workers.dev}"
V2_ENVIRONMENT="staging"
PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}"
SKIP_BUILD=0
KEEP_SIMULATOR=0
PROVIDED_SIMULATOR_ID=""
REPORT_OUTPUT=""
PRODUCTION=0
STACK_ENV_FILE=""
BASE_URL_WAS_EXPLICIT=0
V2_BASE_URL_WAS_EXPLICIT=0
PRINT_PLAN=0
SOAK_PROFILE=""
REPORT_TIMEOUT=480
DOGFOOD_CREDENTIALS_FILE=""
REAL_USAGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --staging-base-url) STAGING_BASE_URL="${2:-}"; BASE_URL_WAS_EXPLICIT=1; shift 2 ;;
    --v2-base-url) V2_BASE_URL="${2:-}"; V2_BASE_URL_WAS_EXPLICIT=1; shift 2 ;;
    --presence-base-url) PRESENCE_BASE_URL="${2:-}"; shift 2 ;;
    --production) PRODUCTION=1; shift ;;
    --stack-env-file) STACK_ENV_FILE="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --simulator-id) PROVIDED_SIMULATOR_ID="${2:-}"; shift 2 ;;
    --report-output) REPORT_OUTPUT="${2:-}"; shift 2 ;;
    --print-plan) PRINT_PLAN=1; shift ;;
    --soak-profile) SOAK_PROFILE="${2:-}"; shift 2 ;;
    --credentials-file) DOGFOOD_CREDENTIALS_FILE="${2:-}"; shift 2 ;;
    --real-usage) REAL_USAGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: --mode is required" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; exit 2; }
if [[ "$REAL_USAGE" -eq 1 && ( "$MODE" != automatic && "$MODE" != relay-only || "$SOAK_PROFILE" != stress ) ]]; then
  echo "error: --real-usage requires automatic or relay-only stress" >&2
  exit 2
fi
if [[ "$REAL_USAGE" -eq 1 && -z "$REPORT_OUTPUT" ]]; then
  echo "error: --real-usage requires --report-output" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 1 && "$BASE_URL_WAS_EXPLICIT" -eq 1 ]]; then
  echo "error: --production cannot be combined with --staging-base-url" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 1 && "$V2_BASE_URL_WAS_EXPLICIT" -eq 1 ]]; then
  echo "error: --production cannot be combined with --v2-base-url" >&2
  exit 2
fi
if [[ "$PRODUCTION" -eq 1 && -n "$PRESENCE_BASE_URL" ]]; then
  echo "error: --production cannot be combined with --presence-base-url" >&2
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
  V2_BASE_URL="https://cmux-v2.debussy.workers.dev"
  V2_ENVIRONMENT="production"
  # Production clients resolve presence.cmux.dev from their auth channel.
  # Never inherit a development worker override from the caller's shell.
  PRESENCE_BASE_URL=""
fi

case "$MODE" in
  automatic) RAW_MODE="automatic"; GATE_SCENARIO="standard"; GATE_PLAN="app-rpc" ;;
  relay-only) RAW_MODE="relayOnly"; GATE_SCENARIO="relay_rollover"; GATE_PLAN="app-rpc" ;;
  relay-expiry) RAW_MODE="relayOnly"; GATE_SCENARIO="relay_expiry"; GATE_PLAN="app-rpc" ;;
  direct-only) RAW_MODE="directOnly"; GATE_SCENARIO="standard"; GATE_PLAN="simulator-direct-transport" ;;
  private-path) RAW_MODE=""; GATE_SCENARIO="standard"; GATE_PLAN="host-private-path-transport" ;;
  *) echo "error: invalid mode '$MODE'" >&2; exit 2 ;;
esac

if [[ -n "$SOAK_PROFILE" ]]; then
  [[ "$MODE" == automatic || "$MODE" == relay-only ]] || {
    echo "error: soak requires automatic or relay-only mode" >&2; exit 2;
  }
  case "$SOAK_PROFILE" in
    # The app deadline is the workload duration plus the rollover probe and
    # its bounded readiness/teardown allowance. The waiter starts after the
    # prewarm launch below, so this margin only covers report delivery.
    basic)
      REPORT_TIMEOUT="$([[ "$MODE" == relay-only ]] && printf 2790 || printf 1170)"
      ;;
    stress)
      # Relay-only stress adds the 1950-second rollover probe after the
      # one-hour workload. Leave enough time for that probe, teardown, and
      # report delivery.
      REPORT_TIMEOUT="$([[ "$MODE" == relay-only ]] && printf 5850 || printf 3870)"
      ;;
    *) echo "error: invalid soak profile" >&2; exit 2 ;;
  esac
  # Keep relay-only stress runs on relay_rollover. The soak workload proves
  # sustained use, then the runner performs the explicit rollover probe.
  if [[ "$MODE" == automatic ]]; then
    GATE_SCENARIO=standard
  fi
fi

if [[ -n "$PROVIDED_SIMULATOR_ID" ]]; then
  [[ "$SKIP_BUILD" -eq 1 && "$PRODUCTION" -eq 0 && -n "$SOAK_PROFILE" ]] || {
    echo "error: --simulator-id requires a prebuilt staging soak" >&2; exit 2;
  }
fi

if [[ "$PRODUCTION" -eq 1 && "$GATE_PLAN" == "host-private-path-transport" ]]; then
  echo "error: private-path proves the host transport contract and has no production environment" >&2
  exit 2
fi

if [[ "$GATE_PLAN" != "host-private-path-transport" ]]; then
  case "$STAGING_BASE_URL" in
    https://*) ;;
    *) echo "error: --staging-base-url must use https" >&2; exit 2 ;;
  esac
  case "$V2_BASE_URL" in
    https://*) ;;
    *) echo "error: --v2-base-url must use https" >&2; exit 2 ;;
  esac
  case "$PRESENCE_BASE_URL" in
    ""|https://*) ;;
    *) echo "error: --presence-base-url must use https" >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
# shellcheck source=scripts/lib/dev-secrets.sh
source "$SCRIPT_DIR/lib/dev-secrets.sh"
# shellcheck source=scripts/lib/iroh-release-gate-targets.sh
source "$SCRIPT_DIR/lib/iroh-release-gate-targets.sh"
cmux_attach_validate_dev_tag "$TAG"
if [[ -n "$DOGFOOD_CREDENTIALS_FILE" ]]; then
  [[ "$PRODUCTION" -eq 0 ]] || { echo "error: --credentials-file is for staging only" >&2; exit 2; }
  cmux_dev_secrets_validate_file "$DOGFOOD_CREDENTIALS_FILE"
fi

ACTIVE_BUILD_WRAPPER_PID=""

# Hosted logs are bounded, while a cold optimized iOS build can emit several
# megabytes before it links. Keep the full build output on the runner, expose a
# heartbeat to the job log, and print a bounded diagnostic tail only on failure.
# Python owns the child process group so cancellation is forwarded and reaped.
run_build_with_heartbeat() {
  local label="$1"
  shift
  local status build_log

  build_log="${RUNNER_TEMP:-/tmp}/cmux-iroh-${TAG}-${label}.log"

  /usr/bin/python3 - "$label" "$build_log" "$@" <<'PY' &
import os
import signal
import subprocess
import sys
import time

label, build_log, *command = sys.argv[1:]
interrupted_by = None
termination_deadline = None
process = None

def forward_signal(signum, _frame):
    global interrupted_by, termination_deadline
    if interrupted_by is None:
        interrupted_by = signum
        termination_deadline = time.monotonic() + 10
    if process is None:
        return
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass

signal.signal(signal.SIGINT, forward_signal)
signal.signal(signal.SIGTERM, forward_signal)

with open(build_log, "wb") as output:
    process = subprocess.Popen(
        command,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    if interrupted_by is not None:
        try:
            os.killpg(process.pid, interrupted_by)
        except ProcessLookupError:
            pass

    while True:
        timeout = 60
        if termination_deadline is not None:
            timeout = max(0.1, termination_deadline - time.monotonic())
        try:
            return_code = process.wait(timeout=timeout)
            break
        except subprocess.TimeoutExpired:
            if termination_deadline is None:
                print(f"==> {label} build still running", flush=True)
                continue
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            return_code = process.wait()
            break

if interrupted_by is not None:
    raise SystemExit(128 + interrupted_by)
if return_code < 0:
    raise SystemExit(128 - return_code)
raise SystemExit(return_code)
PY
  ACTIVE_BUILD_WRAPPER_PID=$!
  if wait "$ACTIVE_BUILD_WRAPPER_PID"
  then
    status=0
  else
    status=$?
  fi
  ACTIVE_BUILD_WRAPPER_PID=""
  if [[ "$status" -ne 0 ]]; then
    printf 'error: %s build failed with status %s; tail of %s follows\n' \
      "$label" "$status" "$build_log" >&2
    tail -n 240 "$build_log" >&2 || true
  else
    printf '==> %s build succeeded; full log: %s\n' "$label" "$build_log"
  fi
  return "$status"
}

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
DATA_CONTAINER=""
REPORT_FILENAME="cmux-iroh-release-gate.json"
REPORT_READY_NOTIFICATION="dev.cmux.ios.iroh-release-gate.report-ready"
REPORT_WAITER_PID=""
UI_CAPTURE_WAITER_PID=""
UI_CAPTURE_DIR=""
REAL_USAGE_DIR=""
CODEX_WORKLOAD_PID=""
STATE_DIR=""
PROD_ENV_FILE=""
PROD_CREDENTIALS_FILE=""
PROD_ACCOUNT_STATE_FILE=""
PROD_RECOVERY_FILE=""
VERCEL_DIR=""

shutdown_prior_gate_simulators() {
  local simulator_name="$1"
  local prior_simulator_id

  while IFS= read -r prior_simulator_id; do
    [[ -n "$prior_simulator_id" ]] || continue
    echo "==> shutting down retained same-tag simulator: $prior_simulator_id"
    xcrun simctl shutdown "$prior_simulator_id"
  done < <(
    SIMULATOR_NAME="$simulator_name" /usr/bin/python3 <<'PY'
import json
import os
import subprocess

listing = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"])
)
for devices in listing.get("devices", {}).values():
    for device in devices:
        if (
            device.get("isAvailable", True)
            and device.get("name") == os.environ["SIMULATOR_NAME"]
            and device.get("state") != "Shutdown"
        ):
            print(device["udid"])
PY
  )
}

# Preserve the simulator's v2 startup journal and durable debug-log generations
# alongside the release-gate report. The journal records the exact startup
# boundaries that UI latency alone cannot distinguish. Every source is
# redacted before it leaves the simulator container.
capture_ios_release_gate_diagnostics() {
  local prefix="$1"
  local label="${2:-success}"
  [[ -n "$SIMULATOR_ID" ]] || return 0
  local support_root=""
  if [[ -n "$DATA_CONTAINER" && -d "$DATA_CONTAINER/Library/Application Support" ]]; then
    support_root="$DATA_CONTAINER/Library/Application Support"
  else
    support_root="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$IOS_BUNDLE_ID" data 2>/dev/null)/Library/Application Support"
  fi
  if [[ -d "$support_root" ]]; then
    local index=0
    while IFS= read -r source; do
      [[ -f "$source" ]] || continue
      local destination
      case "$(basename "$source")" in
        iroh-v2-journal.jsonl) destination="${prefix}-ios-iroh-v2-journal-${label}-${index}.jsonl" ;;
        cmux-debug.log) destination="${prefix}-ios-debug-${label}-${index}.log" ;;
        cmux-debug.log.1) destination="${prefix}-ios-debug-rotated-${label}-${index}.log" ;;
        *) continue ;;
      esac
      sed -E \
        -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]+/<redacted-email>/g' \
        -e 's/[A-Za-z0-9_-]{24,}/<redacted-token>/g' \
        -e 's/[[:xdigit:]]{64}/<redacted-endpoint>/g' \
        "$source" > "$destination" || true
      index=$((index + 1))
    done < <(find "$support_root" -type f \( \
      -name 'iroh-v2-journal.jsonl' -o \
      -name 'cmux-debug.log' -o \
      -name 'cmux-debug.log.1' \
    \) -print 2>/dev/null)
  fi
}

cleanup() {
  local exit_code=$?
  local cleanup_code=0
  trap - EXIT INT TERM
  set +e
  if [[ -n "$REPORT_WAITER_PID" ]]; then
    kill "$REPORT_WAITER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$UI_CAPTURE_WAITER_PID" ]]; then
    kill "$UI_CAPTURE_WAITER_PID" >/dev/null 2>&1 || true
    wait "$UI_CAPTURE_WAITER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$UI_CAPTURE_DIR" ]]; then
    rm -f "$UI_CAPTURE_DIR/terminal.png"
    rmdir "$UI_CAPTURE_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$CODEX_WORKLOAD_PID" ]]; then
    kill -TERM "$CODEX_WORKLOAD_PID" >/dev/null 2>&1 || true
    wait "$CODEX_WORKLOAD_PID" >/dev/null 2>&1 || true
  fi
  # Preserve diagnostics when the app never emits a report. The normal
  # success path captures these below after the report arrives, but an early
  # readiness failure used to delete the only useful endpoint evidence during
  # cleanup. Outputs are redacted and best-effort, so this cannot change the
  # transport verdict or block teardown.
  if [[ "$exit_code" -ne 0 && -n "$REPORT_OUTPUT" ]]; then
    mkdir -p "$(dirname "$REPORT_OUTPUT")"
    failure_prefix="${REPORT_OUTPUT%.json}"
    if [[ -n "$SIMULATOR_ID" ]]; then
      xcrun simctl io "$SIMULATOR_ID" screenshot "${failure_prefix}-ios-failure.png" >/dev/null 2>&1 || true
      capture_ios_release_gate_diagnostics "$failure_prefix" "failure"
      xcrun simctl spawn "$SIMULATOR_ID" log show --style compact --last 30m \
        --predicate 'subsystem == "dev.cmux.ios"' 2>/dev/null \
        | sed -E 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]+/<redacted-email>/g; s/[A-Za-z0-9_-]{24,}/<redacted-token>/g' \
        > "${failure_prefix}-ios-failure.log" || true
    fi
    if [[ -n "$TAG" ]]; then
      if ! CMUX_TAG="$TAG" "$SCRIPT_DIR/cmux-debug-cli.sh" iroh-diag \
        > "${failure_prefix}-mac-failure.cmuxdiag" 2>/dev/null; then
        rm -f "${failure_prefix}-mac-failure.cmuxdiag"
      fi
    fi
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
  defaults delete "$MAC_BUNDLE_ID" cmux.iroh.v2.force-relay >/dev/null 2>&1 || true
  defaults delete "$MAC_BUNDLE_ID" presenceServiceURL >/dev/null 2>&1 || true
  pkill -f "cmux DEV ${SLUG}.app/Contents/MacOS/cmux DEV" 2>/dev/null || true
  if [[ "$PRODUCTION" -eq 1 ]]; then
    # Production uses a disposable account and must remove its local tokens.
    # The endpoint key and verified-policy cache live outside the ordinary
    # tagged app support directory, so clear that exact tagged identity too.
    # Staging keeps its tagged state so a failed gate remains inspectable and a
    # later --skip-build run can reuse the same authenticated build.
    rm -rf "$HOME/Library/Application Support/cmux/$MAC_BUNDLE_ID"
    rm -rf "$HOME/Library/Application Support/cmux/iroh-debug/$MAC_BUNDLE_ID"
    security delete-generic-password -s "$MAC_BUNDLE_ID.auth" -a cmux-auth-access-token >/dev/null 2>&1 || true
    security delete-generic-password -s "$MAC_BUNDLE_ID.auth" -a cmux-auth-refresh-token >/dev/null 2>&1 || true
  fi
  if [[ -n "$PROVIDED_SIMULATOR_ID" && -n "$SIMULATOR_ID" ]]; then
    xcrun simctl terminate "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    # The controller reservation owns these devices. Release their memory when
    # the service is interrupted; ordinary completed checks keep iOS warm.
    if [[ "$exit_code" -ge 128 ]]; then
      xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    fi
  elif [[ "$KEEP_SIMULATOR" -ne 1 && -n "$SIMULATOR_ID" ]]; then
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

stop_active_build() {
  local signal_name="$1"
  local wrapper_pid="$ACTIVE_BUILD_WRAPPER_PID"
  [[ -n "$wrapper_pid" ]] || return
  kill -s "$signal_name" "$wrapper_pid" >/dev/null 2>&1 || true
  wait "$wrapper_pid" >/dev/null 2>&1 || true
  ACTIVE_BUILD_WRAPPER_PID=""
}

handle_interrupt() {
  stop_active_build INT
  exit 130
}

handle_termination() {
  stop_active_build TERM
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

if [[ -n "$PROVIDED_SIMULATOR_ID" ]]; then
  # Accept only the exact dedicated monitor device, never a developer's sim.
  SIMULATOR_STATE="$(PROVIDED_SIMULATOR_ID="$PROVIDED_SIMULATOR_ID" MONITOR_TAG="$SLUG" /usr/bin/python3 <<'PY'
import json, os, subprocess
listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
match = [device for devices in listing["devices"].values() for device in devices
         if device["udid"].lower() == os.environ["PROVIDED_SIMULATOR_ID"].lower()]
if (len(match) != 1 or not match[0].get("isAvailable", False)
        or match[0]["name"] != "cmux Iroh monitor " + os.environ["MONITOR_TAG"]):
    raise SystemExit("simulator is not this tag's dedicated monitor device")
print(match[0]["state"])
PY
)"
  SIMULATOR_ID="$PROVIDED_SIMULATOR_ID"
  if [[ "$SIMULATOR_STATE" == Shutdown ]]; then xcrun simctl boot "$SIMULATOR_ID"; fi
else
shutdown_prior_gate_simulators "$SIMULATOR_NAME"

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
fi
xcrun simctl bootstatus "$SIMULATOR_ID" -b

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  iroh_release_gate_set_ios_reload_args \
    "$TAG" "$SIMULATOR_NAME" "$SIMULATOR_ID" "$PRODUCTION"
  if [[ "$PRODUCTION" -eq 1 ]]; then
    run_build_with_heartbeat Mac env \
      CMUX_PRESENCE_BASE_URL="$PRESENCE_BASE_URL" \
      CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_V2_ENVIRONMENT="$V2_ENVIRONMENT" \
      CMUX_IROH_V2_BASE_URL="$V2_BASE_URL" \
      ./scripts/reload.sh \
        --tag "$TAG" \
        --prod-auth \
        --credentials-file "$PROD_CREDENTIALS_FILE"
    run_build_with_heartbeat iOS env \
      CMUX_XCODEBUILD_JOBS="${CMUX_IROH_RELEASE_GATE_XCODEBUILD_JOBS:-2}" \
      CMUX_PRESENCE_BASE_URL="$PRESENCE_BASE_URL" \
      CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_V2_ENVIRONMENT="$V2_ENVIRONMENT" \
      CMUX_IROH_V2_BASE_URL="$V2_BASE_URL" \
      ./ios/scripts/reload.sh "${IROH_RELEASE_GATE_IOS_RELOAD_ARGS[@]}"
  else
    run_build_with_heartbeat Mac env \
      CMUX_PRESENCE_BASE_URL="$PRESENCE_BASE_URL" \
      CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_V2_ENVIRONMENT="$V2_ENVIRONMENT" \
      CMUX_IROH_V2_BASE_URL="$V2_BASE_URL" \
      ./scripts/reload.sh --tag "$TAG"
    run_build_with_heartbeat iOS env \
      CMUX_XCODEBUILD_JOBS="${CMUX_IROH_RELEASE_GATE_XCODEBUILD_JOBS:-2}" \
      CMUX_PRESENCE_BASE_URL="$PRESENCE_BASE_URL" \
      CMUX_DEV_API_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_BROKER_BASE_URL="$STAGING_BASE_URL" \
      CMUX_IROH_V2_ENVIRONMENT="$V2_ENVIRONMENT" \
      CMUX_IROH_V2_BASE_URL="$V2_BASE_URL" \
      ./ios/scripts/reload.sh "${IROH_RELEASE_GATE_IOS_RELOAD_ARGS[@]}"
  fi
else
  [[ -d "$IOS_APP" ]] || { echo "error: tagged iOS app is missing: $IOS_APP" >&2; exit 1; }
  xcrun simctl install "$SIMULATOR_ID" "$IOS_APP"
fi

# Retained simulators must never contribute a prior run's report or UI image.
DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$IOS_BUNDLE_ID" data)"
rm -f "$DATA_CONTAINER/Library/Caches/$REPORT_FILENAME" \
  "$DATA_CONTAINER/Library/Caches/cmux-iroh-ui-workspaces.png" \
  "$DATA_CONTAINER/Library/Caches/cmux-iroh-ui-terminal.png"

[[ -d "$MAC_APP" ]] || { echo "error: tagged Mac app is missing: $MAC_APP" >&2; exit 1; }
"$SCRIPT_DIR/lib/verify-iroh-release-gate-builds.sh" \
  --mac-app "$MAC_APP" \
  --ios-app "$IOS_APP" \
  --backend-base-url "$STAGING_BASE_URL" \
  --v2-base-url "$V2_BASE_URL" \
  --v2-environment "$V2_ENVIRONMENT" \
  --presence-base-url "$PRESENCE_BASE_URL"

if [[ "$PRODUCTION" -eq 1 ]]; then
  PRODUCTION_RELAY_POLICY_XCCONFIG="$REPO_ROOT/config/IrohRelayPolicyProduction.xcconfig"
  MAC_INFO_PLIST="$MAC_APP/Contents/Info.plist"
  IOS_INFO_PLIST="$IOS_APP/Info.plist"
  PRODUCTION_RELAY_POLICY_XCCONFIG="$PRODUCTION_RELAY_POLICY_XCCONFIG" \
  MAC_INFO_PLIST="$MAC_INFO_PLIST" \
  IOS_INFO_PLIST="$IOS_INFO_PLIST" \
  /usr/bin/python3 <<'PY'
import os
import plistlib

setting_names = (
    "CMUX_IROH_RELAY_POLICY_KEY_ID",
    "CMUX_IROH_RELAY_POLICY_PUBLIC_KEY_BASE64",
    "CMUX_IROH_RELAY_POLICY_NEXT_KEY_ID",
    "CMUX_IROH_RELAY_POLICY_NEXT_PUBLIC_KEY_BASE64",
)
settings = {}
with open(os.environ["PRODUCTION_RELAY_POLICY_XCCONFIG"], encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line or line.startswith("//") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        settings[key.strip()] = value.strip()

missing = [name for name in setting_names if not settings.get(name)]
if missing:
    raise SystemExit("production relay-policy build profile is incomplete")

expected_trust = [
    {
        "keyID": settings["CMUX_IROH_RELAY_POLICY_KEY_ID"],
        "publicKeyBase64": settings["CMUX_IROH_RELAY_POLICY_PUBLIC_KEY_BASE64"],
    },
    {
        "keyID": settings["CMUX_IROH_RELAY_POLICY_NEXT_KEY_ID"],
        "publicKeyBase64": settings["CMUX_IROH_RELAY_POLICY_NEXT_PUBLIC_KEY_BASE64"],
    },
]

for label, environment_name in (
    ("Mac", "MAC_INFO_PLIST"),
    ("iOS", "IOS_INFO_PLIST"),
):
    with open(os.environ[environment_name], "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CMUXIrohRelayPolicyKeyID") != expected_trust[0]["keyID"]:
        raise SystemExit(f"{label} production gate app has the wrong relay-policy key ID")
    if info.get("CMUXIrohRelayPolicyPublicKeyBase64") != expected_trust[0]["publicKeyBase64"]:
        raise SystemExit(f"{label} production gate app has the wrong relay-policy public key")
    if info.get("CMUXIrohRelayPolicyTrustKeys") != expected_trust:
        raise SystemExit(f"{label} production gate app has the wrong relay-policy trust set")

print("==> production relay-policy pins verified in Mac and iOS build artifacts")
PY
fi

# Both endpoints read the mode before constructing their Iroh endpoint. Write
# after installation so a fresh simulator app container cannot replace it.
defaults write "$MAC_BUNDLE_ID" cmux.iroh.debug.transport-mode -string "$RAW_MODE"
# Pin the Worker scope in both UserDefaults stores as well as the build
# metadata. This prevents a retained dev app from reusing a prior environment
# override when a production or staging gate is launched with a new tag.
defaults write "$MAC_BUNDLE_ID" cmux.iroh.v2.config.CMUX_IROH_V2_ENVIRONMENT -string "${V2_ENVIRONMENT:-staging}"
defaults write "$MAC_BUNDLE_ID" cmux.iroh.v2.config.CMUX_IROH_V2_BASE_URL -string "${V2_BASE_URL:-https://cmux-v2-staging.debussy.workers.dev}"
# The current Iroh implementation owns a separate endpoint configuration.
# Constrain both generations so a same-host direct route cannot satisfy a
# check advertised as exercising the relay fleet.
FORCE_RELAY=0
FORCE_RELAY_BOOLEAN=false
if [[ "$RAW_MODE" == relayOnly ]]; then
  FORCE_RELAY=1
  FORCE_RELAY_BOOLEAN=true
fi
defaults write "$MAC_BUNDLE_ID" cmux.iroh.v2.force-relay -bool "$FORCE_RELAY_BOOLEAN"
if [[ -n "$PRESENCE_BASE_URL" ]]; then
  defaults write "$MAC_BUNDLE_ID" presenceServiceURL -string "$PRESENCE_BASE_URL"
else
  defaults delete "$MAC_BUNDLE_ID" presenceServiceURL >/dev/null 2>&1 || true
fi
xcrun simctl spawn "$SIMULATOR_ID" defaults write \
  "$IOS_BUNDLE_ID" cmux.iroh.debug.transport-mode -string "$RAW_MODE"
xcrun simctl spawn "$SIMULATOR_ID" defaults write \
  "$IOS_BUNDLE_ID" cmux.iroh.v2.config.CMUX_IROH_V2_ENVIRONMENT -string "${V2_ENVIRONMENT:-staging}"
xcrun simctl spawn "$SIMULATOR_ID" defaults write \
  "$IOS_BUNDLE_ID" cmux.iroh.v2.config.CMUX_IROH_V2_BASE_URL -string "${V2_BASE_URL:-https://cmux-v2-staging.debussy.workers.dev}"
xcrun simctl spawn "$SIMULATOR_ID" defaults write \
  "$IOS_BUNDLE_ID" cmux.iroh.v2.config.CMUX_IROH_V2_FORCE_RELAY -string "$FORCE_RELAY"

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
MAC_AUTH_ARGS=()
if [[ -n "$DOGFOOD_CREDENTIALS_FILE" ]]; then
  cmux_dev_secrets_load --profile agent --credentials-file "$DOGFOOD_CREDENTIALS_FILE" >/dev/null
  MAC_AUTH_ARGS=(0 agent "$DOGFOOD_CREDENTIALS_FILE" "$CMUX_DEV_AUTH_ACCOUNT")
fi
CMUX_PRESENCE_BASE_URL="$PRESENCE_BASE_URL" \
CMUX_ATTACH_ALLOW_RELAUNCH=1 \
CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \
cmux_attach_ensure_mac "$TAG" "$REPO_ROOT" physical_device ${MAC_AUTH_ARGS[@]+"${MAC_AUTH_ARGS[@]}"}

MOBILE_LAUNCH_ARGS=(
  --tag "$TAG"
  --simulator-id "$SIMULATOR_ID"
  --auth-profile agent
  --ensure-mac
  --detach
)
if [[ "$PRODUCTION" -eq 1 ]]; then
  MOBILE_LAUNCH_ARGS+=(--credentials-file "$PROD_CREDENTIALS_FILE")
elif [[ -n "$DOGFOOD_CREDENTIALS_FILE" ]]; then
  MOBILE_LAUNCH_ARGS+=(--credentials-file "$DOGFOOD_CREDENTIALS_FILE")
fi

# Establish Stack and v2 state once before the measured launch. The first
# launch is intentionally a real enrollment; the release-gate launch below
# reuses that state and measures the cached-credential path.
if [[ -n "$SOAK_PROFILE" ]]; then
  echo "==> prewarming cached Stack and v2 state before the measured launch"
  CMUX_DEV_AUTH_REPLACE_SESSION=1 \
    ./scripts/mobile-dev-launch.sh "${MOBILE_LAUNCH_ARGS[@]}"
  # The first launch verified sign-in and pairing. The measured launch must
  # restore those saved values through the same startup path as a user launch.
  # --ensure-mac would otherwise inject a new URL and bypass that path entirely.
  MOBILE_LAUNCH_ARGS+=(--restore-pairing)
fi

# Wait for the app's atomic report-write signal. Start this after prewarm so
# its deadline measures the release-gate run itself, rather than an unrelated
# enrollment or build delay. Python owns the simulator notifyutil child so its
# timeout is bounded without polling the filesystem.
SIMULATOR_ID="$SIMULATOR_ID" \
REPORT_READY_NOTIFICATION="$REPORT_READY_NOTIFICATION" \
REPORT_TIMEOUT="$REPORT_TIMEOUT" \
/usr/bin/python3 <<'PY' &
import os
import signal
import subprocess
import time

command = [
    "xcrun", "simctl", "spawn", os.environ["SIMULATOR_ID"],
    "notifyutil", "-1", os.environ["REPORT_READY_NOTIFICATION"],
]
process = subprocess.Popen(
    command,
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
try:
    process.wait(timeout=int(os.environ["REPORT_TIMEOUT"]))
except subprocess.TimeoutExpired:
    # notifyutil is an iOS Simulator child. Own its process group so a stalled
    # notification cannot keep the release-gate job alive after its deadline.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    raise SystemExit("Iroh release gate report signal timed out")
if process.returncode != 0:
    raise SystemExit(f"Iroh release gate report waiter exited with {process.returncode}")
PY
REPORT_WAITER_PID=$!

MOBILE_LAUNCH_ARGS+=(--iroh-release-gate "$RAW_MODE")
# Capture the simulator's composited terminal pixels at the presentation
# boundary. UIKit drawHierarchy omits the renderer's IOSurface. The app waits
# for this acknowledgement before navigating back; capture time is excluded
# from the already-recorded latency.
if [[ -n "$SOAK_PROFILE" ]]; then
  UI_CAPTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-iroh-ui-${TAG}.XXXXXX")"
  UI_CAPTURE_READY_FIFO="$UI_CAPTURE_DIR/listener-ready.fifo"
  mkfifo "$UI_CAPTURE_READY_FIFO"
  # Keep a reader open before the helper can observe registration, avoiding
  # an ENXIO race when it writes the readiness handshake.
  exec 9<>"$UI_CAPTURE_READY_FIFO"
  SIMULATOR_ID="$SIMULATOR_ID" UI_CAPTURE_DIR="$UI_CAPTURE_DIR" UI_CAPTURE_READY_FIFO="$UI_CAPTURE_READY_FIFO" /usr/bin/python3 <<'PY_CAPTURE' &
import os
import select
import signal
import subprocess
import time

def interrupted(*_):
    raise SystemExit(143)

signal.signal(signal.SIGTERM, interrupted)
base = ["xcrun", "simctl", "spawn", os.environ["SIMULATOR_ID"], "notifyutil"]
target = "dev.cmux.ios.iroh-release-gate.ui-terminal-ready"
waiter = subprocess.Popen(
    base + ["-2", target],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)
try:
    # notifyutil has no registration acknowledgement. Register the real target
    # for two notifications and post the first one until it is observed. The
    # first target notification is the registration proof; the second is the
    # app's real presentation event. The FIFO therefore acknowledges the exact
    # listener that will capture the app frame.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if waiter.poll() is not None:
            raise SystemExit("terminal evidence listener exited before registration")
        subprocess.run(base + ["-p", target], check=True,
                       timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        readable, _, _ = select.select([waiter.stdout], [], [], 0.2)
        if readable:
            line = waiter.stdout.readline() if waiter.stdout is not None else ""
            if target in line:
                try:
                    fd = os.open(os.environ["UI_CAPTURE_READY_FIFO"], os.O_WRONLY | os.O_NONBLOCK)
                    os.write(fd, b"ready\n")
                    os.close(fd)
                except OSError as error:
                    raise SystemExit(f"listener readiness handshake failed: {error}")
                break
        if waiter.poll() is not None:
            raise SystemExit("terminal evidence listener exited before registration")
    else:
        raise SystemExit("terminal evidence listener registration timed out")
    if waiter.wait(timeout=240) != 0:
        raise SystemExit("terminal evidence listener failed")
    subprocess.run(["xcrun", "simctl", "io", os.environ["SIMULATOR_ID"], "screenshot",
                    os.path.join(os.environ["UI_CAPTURE_DIR"], "terminal.png")],
                   check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(base + ["-p", "dev.cmux.ios.iroh-release-gate.ui-terminal-captured"],
                   check=True, timeout=5)
finally:
    try:
        fd = os.open(os.environ["UI_CAPTURE_READY_FIFO"], os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, b"failed\n")
        os.close(fd)
    except OSError:
        pass
    if waiter.poll() is None:
        waiter.terminate()
        waiter.wait(timeout=5)
PY_CAPTURE
  UI_CAPTURE_WAITER_PID=$!
  if ! IFS= read -r -t 15 -u 9 listener_status; then
    kill "$UI_CAPTURE_WAITER_PID" 2>/dev/null || true
    wait "$UI_CAPTURE_WAITER_PID" 2>/dev/null || true
    exec 9>&-
    rm -f "$UI_CAPTURE_READY_FIFO"
    echo "error: terminal evidence listener did not become ready" >&2
    exit 1
  fi
  exec 9>&-
  rm -f "$UI_CAPTURE_READY_FIFO"
  [[ "$listener_status" == ready ]] || {
    echo "error: terminal evidence listener failed to register" >&2
    exit 1
  }
fi

# The simulator launch is detached, but the launcher also performs setup and
# attach work before it returns. Own that process group as well as notifyutil;
# otherwise a stalled launcher can keep the job alive after the report deadline.
run_release_gate_launch() {
  local log_path="$1"
  shift
/usr/bin/python3 - "$log_path" "$((REPORT_TIMEOUT + 30))" "$@" <<'PY_LAUNCH'
import os
import signal
import subprocess
import sys

log_path, timeout_seconds, *command = sys.argv[1:]
with open(log_path, "wb") as output:
    process = subprocess.Popen(
        command,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        return_code = process.wait(timeout=int(timeout_seconds))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise SystemExit("Iroh release gate launcher timed out")

if return_code < 0:
    raise SystemExit(128 - return_code)
raise SystemExit(return_code)
PY_LAUNCH
}

GATE_LAUNCH_LOG="$(mktemp "${TMPDIR:-/tmp}/cmux-iroh-launch-${TAG}.XXXXXX")"
launch_status=0
CMUX_DEV_AUTH_REPLACE_SESSION="$([[ -n "$SOAK_PROFILE" ]] && printf 0 || printf 1)" \
CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \
CMUX_ATTACH_READY_TIMEOUT_SECONDS="${CMUX_IROH_RELEASE_GATE_ATTACH_READY_TIMEOUT_SECONDS:-90}" \
CMUX_IROH_RELEASE_GATE_SCENARIO="$GATE_SCENARIO" \
CMUX_IROH_SOAK_PROFILE="$SOAK_PROFILE" \
CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH="$([[ "$GATE_SCENARIO" == "relay_expiry" ]] && printf 1 || printf 0)" \
run_release_gate_launch "$GATE_LAUNCH_LOG" ./scripts/mobile-dev-launch.sh "${MOBILE_LAUNCH_ARGS[@]}" || launch_status=$?
sed -E \
  -e 's/^(==> dev sign-in account:).*/\1 [redacted]/' \
  -e 's/(signed in as )[^,)]+/\1[redacted]/' \
  "$GATE_LAUNCH_LOG"
rm -f "$GATE_LAUNCH_LOG"
if (( launch_status )); then
  echo "error: Iroh release gate launcher failed with status $launch_status" >&2
  exit "$launch_status"
fi

if [[ "$REAL_USAGE" -eq 1 ]]; then
  REAL_USAGE_DIR="${REPORT_OUTPUT%.json}-real-usage"
  mkdir -p "$REAL_USAGE_DIR"
  echo "==> starting real Codex workload in three Mac workspaces"
  CMUX_E2E_TAG="$TAG" \
  CMUX_CODEX_EVIDENCE_DIR="$REAL_USAGE_DIR" \
  CMUX_CODEX_MODEL="${CMUX_CODEX_MODEL:-gpt-5.5-mini}" \
  CMUX_CODEX_DURATION_SECONDS="${CMUX_CODEX_DURATION_SECONDS:-900}" \
  "$SCRIPT_DIR/e2e/iroh-codex-workload.sh" \
    > "$REAL_USAGE_DIR/codex-workload.log" 2>&1 &
  CODEX_WORKLOAD_PID=$!
fi

DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$IOS_BUNDLE_ID" data)"
REPORT_PATH="$DATA_CONTAINER/Library/Caches/$REPORT_FILENAME"
if ! wait "$REPORT_WAITER_PID"; then
  echo "error: Iroh release gate timed out before producing a report" >&2
  exit 1
fi
REPORT_WAITER_PID=""
if [[ -n "$UI_CAPTURE_WAITER_PID" ]]; then
  # The capture helper has acknowledged the terminal frame by this point.
  # Reap it before cleanup so its PID can never be reused for an unrelated
  # process that a later trap might signal.
  wait "$UI_CAPTURE_WAITER_PID" >/dev/null 2>&1 || true
  UI_CAPTURE_WAITER_PID=""
fi
[[ -s "$REPORT_PATH" ]] || {
  echo "error: report-ready signal arrived without an atomic report" >&2
  exit 1
}

if [[ -n "$REPORT_OUTPUT" ]]; then
  mkdir -p "$(dirname "$REPORT_OUTPUT")"
  cp "$REPORT_PATH" "$REPORT_OUTPUT"
  for ui_step in workspaces; do
    ui_snapshot="$DATA_CONTAINER/Library/Caches/cmux-iroh-ui-$ui_step.png"
    if [[ -f "$ui_snapshot" ]]; then
      cp "$ui_snapshot" "${REPORT_OUTPUT%.json}-ui-$ui_step.png"
    fi
  done
  if [[ -n "$UI_CAPTURE_DIR" && -f "$UI_CAPTURE_DIR/terminal.png" ]]; then
    cp "$UI_CAPTURE_DIR/terminal.png" "${REPORT_OUTPUT%.json}-ui-terminal.png"
  fi
  xcrun simctl io "$SIMULATOR_ID" screenshot "${REPORT_OUTPUT%.json}-ios.png" >/dev/null 2>&1 || true
  capture_ios_release_gate_diagnostics "${REPORT_OUTPUT%.json}" "success"

  # Preserve the Mac's privacy-safe transport ring beside the iOS verdict.
  # The host owns admission and stream lifetime, so an iOS-only report cannot
  # distinguish a control-session exit from a client-side RPC failure.
  # Diagnostic capture is best-effort and must never replace the gate verdict.
  HOST_DIAGNOSTIC_OUTPUT="${REPORT_OUTPUT%.json}-mac.cmuxdiag"
  if ! CMUX_TAG="$TAG" "$SCRIPT_DIR/cmux-debug-cli.sh" iroh-diag \
    > "$HOST_DIAGNOSTIC_OUTPUT"
  then
    rm -f "$HOST_DIAGNOSTIC_OUTPUT"
    echo "warning: Mac Iroh diagnostic capture failed" >&2
  fi
fi

REPORT_PATH="$REPORT_PATH" EXPECTED_MODE="$RAW_MODE" EXPECTED_SCENARIO="$GATE_SCENARIO" EXPECTED_SOAK="$SOAK_PROFILE" /usr/bin/python3 <<'PY'
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
    "rpcMethodInventoryVerified",
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
    "uiLatencies",
    "startupPath",
    "lastDiagnosticEventCode",
    "lastDiagnosticFailureKind",
    "soak",
}
allowed_paths = {
    "automatic": {"direct", "private_network", "managed_relay", "custom_relay"},
    "relayOnly": {"managed_relay", "custom_relay"},
    "directOnly": {"direct", "private_network"},
}
required_true = (
    "passed",
    "hostStatusVerified",
    "rpcMethodInventoryVerified",
    "terminalRoundTripVerified",
    "workspaceMutationVerified",
    "independentEventsVerified",
    "notificationReconcileVerified",
    "chatSessionsVerified",
    "artifactScanCountVerified",
)
problems = []
soak_profile = os.environ["EXPECTED_SOAK"]
if soak_profile:
    allowed_paths["automatic"].add("relay")
    allowed_paths["relayOnly"].add("relay")
    soak = report.get("soak") or {}
    duration, cycles = (600, 50) if soak_profile == "basic" else (3600, 300)
    if soak.get("profile") != soak_profile or soak.get("planVersion") != 2:
        problems.append("soak profile or plan version mismatch")
    if soak.get("requestedDurationSeconds") != duration or soak.get("elapsedSeconds", 0) < duration:
        problems.append("soak did not complete its full observation window")
    if soak.get("completedCycles", 0) < cycles or soak.get("currentOperation") != "complete":
        problems.append("soak workload incomplete")
    if report.get("startupPath") != "stored_pairing":
        problems.append("soak did not use the saved-pairing startup path")
    required_operations = ["host_status", "rpc_inventory", "terminal_round_trip", "workspace_rename_restore",
                           "independent_events", "notification_reconcile", "chat_sessions", "artifact_scan"]
    if soak_profile == "stress":
        required_operations += ["workspace_navigation", "workspace_refresh", "notification_refresh",
                                "unicode_output_burst", "workspace_create", "workspace_switch", "workspace_close",
                                "terminal_after_restore", "terminal_after_refresh"]
    if soak.get("recoverableFailures") != {}:
        problems.append("soak reported terminal failures or missing recovery evidence")
    counts = soak.get("operationCounts", {})
    for operation in required_operations:
        minimum = cycles if operation in required_operations[:8] else cycles // 4
        if counts.get(operation, 0) < minimum:
            problems.append("insufficient operation coverage: " + operation)
    # The release gate must enforce the product launch budget, rather than
    # merely recording a slow measurement and still calling the run passed.
    launch_latency = (report.get("uiLatencies") or {}).get(
        "app_launch_request_to_workspace_rows_visible"
    )
    if not isinstance(launch_latency, (int, float)) or launch_latency >= 2.5:
        problems.append("workspace list exceeded the 2.5 second launch budget")
unexpected_keys = set(report) - allowed_keys
if unexpected_keys:
    problems.append("report contained unexpected fields")
if report.get("schemaVersion") != 4:
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
    if report.get("soakDurationSeconds", 0) < 1950:
        problems.append("rollover soak was shorter than 1950 seconds")
elif expected_scenario == "relay_expiry":
    if report.get("unrefreshedExpiryDisconnectVerified") is not True:
        problems.append("unrefreshedExpiryDisconnectVerified was not true")

redacted_report = {key: report.get(key) for key in sorted(allowed_keys) if key in report}
print(json.dumps(redacted_report, sort_keys=True))
if problems:
    raise SystemExit("Iroh release gate failed: " + "; ".join(problems))
PY

if [[ "$REAL_USAGE" -eq 1 ]]; then
  if ! wait "$CODEX_WORKLOAD_PID"; then
    echo "error: real Codex workload failed" >&2
    cat "$REAL_USAGE_DIR/codex-workload.log" >&2 || true
    exit 1
  fi
  CODEX_WORKLOAD_PID=""
  for cycle in 1 2 3; do
    cycle_dir="$REAL_USAGE_DIR/background-cycle-$cycle"
    mkdir -p "$cycle_dir"
    background_seconds=0
    if [[ "$cycle" -eq 2 ]]; then background_seconds=120; fi
    echo "==> running iOS foreground/background cycle $cycle (background=${background_seconds}s)"
    CMUX_E2E_TAG="$TAG" \
    CMUX_E2E_SIM_UDID="$SIMULATOR_ID" \
    CMUX_E2E_EVIDENCE_DIR="$cycle_dir" \
    CMUX_E2E_BACKGROUND_SECONDS="$background_seconds" \
    CMUX_E2E_VIDEO="$cycle_dir/ios-e2e.mp4" \
      "$SCRIPT_DIR/e2e/ios-e2e-run.sh" \
        --tag "$TAG" \
        --sim-udid "$SIMULATOR_ID" \
        --evidence-dir "$cycle_dir" \
        --bundle-id "$IOS_BUNDLE_ID" \
        --background-seconds "$background_seconds" \
        --video "$cycle_dir/ios-e2e.mp4"
  done
  REAL_USAGE_DIR="$REAL_USAGE_DIR" /usr/bin/python3 <<'PY_REAL_USAGE'
import json
import os
from pathlib import Path

root = Path(os.environ["REAL_USAGE_DIR"])
cycles = []
for index in (1, 2, 3):
    path = root / f"background-cycle-{index}" / "background.json"
    if not path.is_file():
        raise SystemExit(f"missing background evidence: {path}")
    with path.open(encoding="utf-8") as handle:
        evidence = json.load(handle)
    cycles.append(evidence)
if len(cycles) != 3 or cycles[1].get("background_seconds", 0) < 120:
    raise SystemExit("real usage did not include a 120-second background cycle")
if any(float(item.get("resume_to_mac_input_seconds", 99)) > 2.0 for item in cycles):
    raise SystemExit("real usage resume-to-input exceeded two seconds")
print(json.dumps({"cycles": cycles}, sort_keys=True))
PY_REAL_USAGE
fi

echo "==> Iroh release gate passed: $MODE"
