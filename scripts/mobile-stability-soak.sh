#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/mobile-stability-soak.sh [--tag swmob] [--profile crash-finder|steady] [--seconds N]

Environment:
  IPHONE_SIM_ID   Required if no booted iPhone simulator can be auto-detected.
  IPAD_SIM_ID     Required if no booted iPad simulator can be auto-detected.
  SOAK_ROOT       Output directory. Defaults to /tmp/cmux-mobile-soak-<tag>-<profile>.
  CMUX_MOBILE_DEV_STACK_AUTH_TOKEN
                 DEBUG-only token used by simulator apps and the tagged Mac host.

Profiles:
  crash-finder    Aggressive attach, viewport, input, color, surface, and resource churn.
  steady          Longer lower-noise soak profile.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
helper_dir="$script_dir/mobile-stability-soak"

tag="swmob"
profile="crash-finder"
seconds=""
iphone_sim_id="${IPHONE_SIM_ID:-}"
ipad_sim_id="${IPAD_SIM_ID:-}"
dev_stack_auth_token="${CMUX_MOBILE_DEV_STACK_AUTH_TOKEN:-cmux-dev-mobile-stack-token}"

while (( $# > 0 )); do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --seconds)
      seconds="${2:-}"
      shift 2
      ;;
    --iphone-sim)
      iphone_sim_id="${2:-}"
      shift 2
      ;;
    --ipad-sim)
      ipad_sim_id="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$profile" in
  crash-finder)
    seconds="${seconds:-1800}"
    ;;
  steady)
    seconds="${seconds:-43200}"
    ;;
  *)
    echo "invalid profile: $profile" >&2
    exit 2
    ;;
esac

if [[ ! "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid tag: $tag" >&2
  exit 2
fi

detect_booted_sim() {
  local family="$1"
  local devices_json
  devices_json="$(xcrun simctl list devices booted -j)"
  /usr/bin/python3 - "$family" "$devices_json" <<'PY'
import json
import sys

family = sys.argv[1].lower()
data = json.loads(sys.argv[2])
for runtimes in data.get("devices", {}).values():
    for device in runtimes:
        name = device.get("name", "").lower()
        if device.get("state") == "Booted" and family in name:
            print(device.get("udid", ""))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

if [[ -z "$iphone_sim_id" ]]; then
  iphone_sim_id="$(detect_booted_sim iphone || true)"
fi
if [[ -z "$ipad_sim_id" ]]; then
  ipad_sim_id="$(detect_booted_sim ipad || true)"
fi

if [[ -z "$iphone_sim_id" || -z "$ipad_sim_id" ]]; then
  cat >&2 <<EOF
Missing booted simulator.
  IPHONE_SIM_ID=${iphone_sim_id:-missing}
  IPAD_SIM_ID=${ipad_sim_id:-missing}
EOF
  exit 1
fi

root="${SOAK_ROOT:-/tmp/cmux-mobile-soak-${tag}-${profile}}"
mkdir -p "$root"

session_prefix="cmux-${tag}-${profile}"

for session in \
  "${session_prefix}-mac" \
  "${session_prefix}-iphone" \
  "${session_prefix}-ipad" \
  "${session_prefix}-macos" \
  "${session_prefix}-resources" \
  "${session_prefix}-audit"
do
  screen -S "$session" -X quit >/dev/null 2>&1 || true
done

cleanup_tagged_soak_processes() {
  local pid command
  while IFS= read -r line; do
    pid="${line%% *}"
    command="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [[ "$command" == *"mobile-stability-soak"* && "$command" == *"CMUX_TAG='$tag'"* ]]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done < <(ps -axo pid=,command=)

  for sim_id in "$iphone_sim_id" "$ipad_sim_id"; do
    [[ -n "$sim_id" ]] || continue
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < <(ps -axo pid=,command= | awk -v sim="$sim_id" 'index($0, "cmux.app/cmux") && index($0, "/Devices/" sim "/") { print $1 }')

    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done < <(ps -axo pid=,command= | awk -v sim="$sim_id" '/xcodebuildmcp/ && /ui-automation snapshot-ui/ && index($0, sim) { print $1 }')
  done
}

cleanup_tagged_soak_processes
sleep 1
cleanup_tagged_soak_processes

app="$HOME/Library/Developer/Xcode/DerivedData/cmux-${tag}/Build/Products/Debug/cmux DEV ${tag}.app"
if [[ ! -x "$app/Contents/MacOS/cmux DEV" ]]; then
  cat >&2 <<EOF
Tagged macOS app is missing:
  $app

Build it first:
  ./scripts/reload.sh --tag $tag
EOF
  exit 1
fi

for pid in $(pgrep -f "cmux-${tag}/Build/Products/Debug/cmux DEV ${tag}.app/Contents/MacOS/cmux DEV" || true); do
  kill "$pid" >/dev/null 2>&1 || true
done

rm -f "/tmp/cmux-debug-${tag}.sock" "/tmp/cmux-debug-${tag}.log"
rm -f \
  "$root/mobile-iphone.log" "$root/mobile-iphone.status" "$root/mobile-iphone.console.log" \
  "$root/mobile-ipad.log" "$root/mobile-ipad.status" "$root/mobile-ipad.console.log" \
  "$root/macos.log" "$root/macos.status" "$root/macos.console.log" \
  "$root/resources.jsonl" "$root/resources.status" "$root/resources.console.log" \
  "$root/audit.json" "$root/audit.console.log"
rm -f "$root"/*.png

CMUX_TAG="$tag" CMUX_REPO="$repo_root" SOAK_ROOT="$root" \
  screen -dmS "${session_prefix}-mac" "$helper_dir/launch-tagged-mac.sh"

for _ in $(seq 1 60); do
  if [[ -S "/tmp/cmux-debug-${tag}.sock" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -S "/tmp/cmux-debug-${tag}.sock" ]]; then
  echo "tagged socket did not appear: /tmp/cmux-debug-${tag}.sock" >&2
  exit 1
fi

(
  cd "$repo_root"
  CMUX_TAG="$tag" scripts/cmux-debug-cli.sh ping >/dev/null
  if [[ -n "$dev_stack_auth_token" ]]; then
    CMUX_TAG="$tag" scripts/cmux-debug-cli.sh rpc mobile.dev_stack_auth.configure \
      "$(jq -n --arg token "$dev_stack_auth_token" '{token:$token}')" >/dev/null
  fi
)

if [[ "$profile" == "crash-finder" ]]; then
  mobile_loop_sleep=0.75
  color_interval=5
  mobile_input_interval=5
  mobile_input_burst=4
  reattach_seconds="${MOBILE_REATTACH_INTERVAL_SECONDS:-45}"
  ticket_ttl=90
  socket_timeout=12
  color_fatal=1
  color_settle=3.25
  mac_loop_sleep=0.75
  mac_surface_churn=3
  mac_notification=9
  resource_interval="${RESOURCE_SAMPLE_INTERVAL:-5}"
  resource_growth_kb=262144
  mobile_reattach_mode="${MOBILE_REATTACH_MODE:-relaunch}"
else
  mobile_loop_sleep=5
  color_interval=120
  mobile_input_interval=20
  mobile_input_burst=1
  reattach_seconds="${MOBILE_REATTACH_INTERVAL_SECONDS:-2700}"
  ticket_ttl=3600
  socket_timeout=30
  color_fatal=1
  color_settle=2
  mac_loop_sleep=5
  mac_surface_churn=20
  mac_notification=60
  resource_interval="${RESOURCE_SAMPLE_INTERVAL:-60}"
  resource_growth_kb=524288
  mobile_reattach_mode="${MOBILE_REATTACH_MODE:-openurl}"
fi

resource_pid_change_allowed_labels=""
if [[ "$mobile_reattach_mode" == "relaunch" ]]; then
  resource_pid_change_allowed_labels="iphone,ipad"
fi

screen -dmS "${session_prefix}-iphone" bash -lc "
  export CMUX_TAG='$tag' CMUX_REPO='$repo_root' SIMULATOR_ID='$iphone_sim_id' CLIENT_ID='${profile}-iphone'
  export SOAK_ROOT='$root' SOAK_PROFILE='$profile' SOAK_SECONDS='$seconds'
  export SOAK_LOG='$root/mobile-iphone.log' SOAK_STATUS='$root/mobile-iphone.status'
  export CMUX_MOBILE_DEV_STACK_AUTH_TOKEN='$dev_stack_auth_token'
  export COLOR_PROBE_INTERVAL='$color_interval' MOBILE_TICKET_TTL_SECONDS='$ticket_ttl' MOBILE_REATTACH_INTERVAL_SECONDS='$reattach_seconds'
  export COLOR_FAILURE_IS_FATAL='$color_fatal' COLOR_MIN_PIXELS=2000
  export MOBILE_INPUT_INTERVAL='$mobile_input_interval' MOBILE_INPUT_BURST_COMMANDS='$mobile_input_burst' MOBILE_SCREENSHOT_INTERVAL=30
  export MOBILE_REATTACH_MODE='$mobile_reattach_mode'
  export MOBILE_FAILURE_LIMIT=1 SOAK_DIAGNOSTICS_DIR='$root/diagnostics' CMUX_DEBUG_LOG='/tmp/cmux-debug-${tag}.log'
  export MOBILE_MAX_SCROLLBACK_ROWS=220 SOCKET_TIMEOUT_SECONDS='$socket_timeout' ATTACH_SETTLE_SECONDS=1.5 COLOR_SETTLE_SECONDS='$color_settle'
  export TERMINAL_OUTPUT_ATTEMPTS=20 TERMINAL_OUTPUT_RETRY_SECONDS=1
  export LOOP_SLEEP_SECONDS='$mobile_loop_sleep' FAILURE_SLEEP_SECONDS='$mobile_loop_sleep'
  exec '$helper_dir/mobile-soak.py' >'$root/mobile-iphone.console.log' 2>&1
"

screen -dmS "${session_prefix}-ipad" bash -lc "
  export CMUX_TAG='$tag' CMUX_REPO='$repo_root' SIMULATOR_ID='$ipad_sim_id' CLIENT_ID='${profile}-ipad'
  export SOAK_ROOT='$root' SOAK_PROFILE='$profile' SOAK_SECONDS='$seconds'
  export SOAK_LOG='$root/mobile-ipad.log' SOAK_STATUS='$root/mobile-ipad.status'
  export CMUX_MOBILE_DEV_STACK_AUTH_TOKEN='$dev_stack_auth_token'
  export COLOR_PROBE_INTERVAL='$color_interval' MOBILE_TICKET_TTL_SECONDS='$ticket_ttl' MOBILE_REATTACH_INTERVAL_SECONDS='$reattach_seconds'
  export COLOR_FAILURE_IS_FATAL='$color_fatal' COLOR_MIN_PIXELS=2000
  export MOBILE_INPUT_INTERVAL='$mobile_input_interval' MOBILE_INPUT_BURST_COMMANDS='$mobile_input_burst' MOBILE_SCREENSHOT_INTERVAL=30
  export MOBILE_REATTACH_MODE='$mobile_reattach_mode'
  export MOBILE_FAILURE_LIMIT=1 SOAK_DIAGNOSTICS_DIR='$root/diagnostics' CMUX_DEBUG_LOG='/tmp/cmux-debug-${tag}.log'
  export MOBILE_MAX_SCROLLBACK_ROWS=220 SOCKET_TIMEOUT_SECONDS='$socket_timeout' ATTACH_SETTLE_SECONDS=1.5 COLOR_SETTLE_SECONDS='$color_settle'
  export TERMINAL_OUTPUT_ATTEMPTS=20 TERMINAL_OUTPUT_RETRY_SECONDS=1
  export LOOP_SLEEP_SECONDS='$mobile_loop_sleep' FAILURE_SLEEP_SECONDS='$mobile_loop_sleep'
  exec '$helper_dir/mobile-soak.py' >'$root/mobile-ipad.console.log' 2>&1
"

screen -dmS "${session_prefix}-macos" bash -lc "
  export CMUX_TAG='$tag' CMUX_REPO='$repo_root' SOAK_ROOT='$root' SOAK_SECONDS='$seconds'
  export SOAK_LOG='$root/macos.log' SOAK_STATUS='$root/macos.status'
  export LOOP_SLEEP_SECONDS='$mac_loop_sleep' MAC_SURFACE_CHURN_INTERVAL='$mac_surface_churn' MAC_NOTIFICATION_INTERVAL='$mac_notification' MAC_READ_SCREEN_RETRIES=3
  export CMUX_CLI_TIMEOUT_SECONDS='$socket_timeout'
  exec '$helper_dir/macos-soak.py' >'$root/macos.console.log' 2>&1
"

screen -dmS "${session_prefix}-resources" bash -lc "
  export CMUX_TAG='$tag' SOAK_SECONDS='$seconds' IPHONE_SIM_ID='$iphone_sim_id' IPAD_SIM_ID='$ipad_sim_id'
  export RESOURCE_LOG='$root/resources.jsonl' RESOURCE_STATUS='$root/resources.status'
  export RESOURCE_SAMPLE_INTERVAL='$resource_interval' RESOURCE_WARMUP_SAMPLES=2 RESOURCE_MAX_GROWTH_KB='$resource_growth_kb'
  export RESOURCE_FAIL_ON_PID_CHANGE=1
  export RESOURCE_PID_CHANGE_ALLOWED_LABELS='$resource_pid_change_allowed_labels'
  export RESOURCE_STARTUP_GRACE_SECONDS=120
  export RESOURCE_MAX_RSS_KB=1258291 RESOURCE_MAX_CPU_PERCENT=220 RESOURCE_CPU_STREAK_LIMIT=6
  exec '$helper_dir/resource-monitor.py' >'$root/resources.console.log' 2>&1
"

screen -dmS "${session_prefix}-audit" bash -lc "
  export SOAK_SECONDS='$seconds' SOAK_AUDIT_STATUS='$root/audit.json' SOAK_AUDIT_INTERVAL_SECONDS=15
  export IPHONE_STATUS='$root/mobile-iphone.status' IPAD_STATUS='$root/mobile-ipad.status'
  export MAC_STATUS='$root/macos.status' RESOURCE_STATUS='$root/resources.status'
  exec '$helper_dir/soak-audit.py' >'$root/audit.console.log' 2>&1
"

cat <<EOF
started mobile stability soak
  tag: $tag
  profile: $profile
  seconds: $seconds
  root: $root
  iPhone: $iphone_sim_id
  iPad: $ipad_sim_id
  audit: $root/audit.json
EOF
