#!/usr/bin/env bash
# Stream the structured iROH journal emitted by a physical iOS build.
#
# IrxJournal writes every event to OSLog at NOTICE level as well as to its
# durable JSONL file. idevicesyslog subscribes to that OSLog stream in place,
# so this does not copy the growing journal file or change the app state.
set -euo pipefail

readonly DEFAULT_DEVICE_ID="4A52829D-6427-599F-A166-4058881D2DF4"
readonly DEFAULT_BUNDLE_ID="dev.cmux.app.internal"

device_id="${CMUX_IPHONE_DEVICE_ID:-$DEFAULT_DEVICE_ID}"
bundle_id="${CMUX_IOS_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
match="irx"
tail_lines=0
no_colors=1
all_logs=0
wait_seconds=15

usage() {
  cat <<'EOF'
Usage: scripts/stream-ios-logs.sh [options]

Stream the live iROH journal from the attached cmux iOS app. The default
device and bundle are Aziz's iPhone and cmux INTERNAL.

Options:
  --device-id <id>       iOS device identifier
  --bundle-id <id>       iOS bundle used for --tail-lines (default: dev.cmux.app.internal)
  --tail-lines <count>   Print this many existing journal lines before streaming
  --match <text>         Local OSLog substring filter (default: irx)
  --all                  Stream all cmux process logs instead of only iROH events
  --wait-seconds <count> Wait for INTERNAL to start when it is not running (default: 15)
  --no-colors            Disable idevicesyslog color output (default)
  -h, --help             Show this help

The live stream comes from OSLog. Press Ctrl-C to stop it. A tail snapshot is
optional and is copied once from Documents/irx-journal.jsonl before streaming.
Install the stream dependency with: brew install libimobiledevice
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-id)
      [[ $# -ge 2 ]] || die "--device-id requires a value"
      device_id="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || die "--bundle-id requires a value"
      bundle_id="$2"
      shift 2
      ;;
    --tail-lines)
      [[ $# -ge 2 ]] || die "--tail-lines requires a value"
      tail_lines="$2"
      shift 2
      ;;
    --match)
      [[ $# -ge 2 ]] || die "--match requires a value"
      match="$2"
      shift 2
      ;;
    --all)
      match=""
      all_logs=1
      shift
      ;;
    --wait-seconds)
      [[ $# -ge 2 ]] || die "--wait-seconds requires a value"
      wait_seconds="$2"
      shift 2
      ;;
    --no-colors)
      no_colors=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

[[ "$tail_lines" =~ ^[0-9]+$ ]] || die "--tail-lines must be a non-negative integer"
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a non-negative integer"
[[ -n "$device_id" ]] || die "device id cannot be empty"
[[ -n "$bundle_id" ]] || die "bundle id cannot be empty"

idevicesyslog_path="$(command -v idevicesyslog || true)"
if [[ -z "$idevicesyslog_path" ]]; then
  die "idevicesyslog is required; install it with 'brew install libimobiledevice'"
fi

idevice_id_path="$(command -v idevice_id || true)"
if [[ -z "$idevice_id_path" ]]; then
  die "idevice_id is required with idevicesyslog; install it with 'brew install libimobiledevice'"
fi

# Keep temporary device snapshots private and clean them up on every exit.
tail_file=""
details_file=""
apps_file=""
processes_file=""
# shellcheck disable=SC2329 # Invoked indirectly by trap.
cleanup() {
  rm -f "${tail_file:-}" "${details_file:-}" "${apps_file:-}" "${processes_file:-}"
}
trap cleanup EXIT INT TERM

# devicectl uses a CoreDevice identifier (the default above), while
# libimobiledevice uses the device's USB UDID. Resolve the latter through
# devicectl so the command works with the identifier used by the iOS tooling.
syslog_device_id="$device_id"
if ! "$idevice_id_path" -l 2>/dev/null | grep -Fqx "$syslog_device_id"; then
  details_file="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-device-details.XXXXXX")"
  if ! xcrun devicectl device info details \
    --device "$device_id" \
    --json-output "$details_file" >/dev/null; then
    die "could not resolve a USB UDID for device $device_id"
  fi
  syslog_device_id="$(DETAILS_JSON="$details_file" /usr/bin/python3 - <<'PY'
import json
import os
import sys

try:
    with open(os.environ["DETAILS_JSON"]) as stream:
        payload = json.load(stream)
    udid = payload["result"]["hardwareProperties"]["udid"]
except (KeyError, OSError, TypeError, ValueError):
    sys.exit(1)
if not isinstance(udid, str) or not udid:
    sys.exit(1)
print(udid)
PY
  )" || die "devicectl did not report a USB UDID for device $device_id"
fi

if ! "$idevice_id_path" -l 2>/dev/null | grep -Fqx "$syslog_device_id"; then
  die "device $device_id is not available to libimobiledevice (resolved USB UDID: $syslog_device_id)"
fi

if (( tail_lines > 0 )); then
  tail_file="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-irx-journal.XXXXXX")"
  if ! xcrun devicectl device copy from \
    --device "$device_id" \
    --source Documents/irx-journal.jsonl \
    --destination "$tail_file" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --timeout 30 >/dev/null; then
    die "could not read Documents/irx-journal.jsonl from $bundle_id on device $device_id"
  fi
  echo "==> last $tail_lines iROH journal lines from $bundle_id"
  tail -n "$tail_lines" "$tail_file"
  echo "==> live iROH journal follows (Ctrl-C to stop)"
fi

if (( all_logs == 1 )); then
  echo "==> streaming all cmux process logs on iOS device $device_id"
else
  echo "==> streaming iROH journal from $bundle_id on iOS device $device_id"
fi
echo "==> source: OSLog NOTICE events, no repeated journal-file transfer"

# Some idevicesyslog/iOS combinations emit the initial backlog but stop
# forwarding live rows when --process or --match is active. Subscribe to the
# raw feed and scope it locally so live logging remains reliable.
stream_args=("$idevicesyslog_path" --udid "$syslog_device_id")
(( no_colors == 1 )) && stream_args+=(--no-colors)

if (( all_logs == 0 )); then
  apps_file="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-apps.XXXXXX")"
  processes_file="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-processes.XXXXXX")"
  resolve_target_pids() {
    xcrun devicectl device info apps \
      --device "$device_id" \
      --json-output "$apps_file" >/dev/null || return 1
    xcrun devicectl device info processes \
      --device "$device_id" \
      --json-output "$processes_file" >/dev/null || return 1
    APPS_JSON="$apps_file" PROCESSES_JSON="$processes_file" BUNDLE_ID="$bundle_id" \
      /usr/bin/python3 - <<'PY'
import json
import os
from urllib.parse import unquote, urlparse


def file_url_path(value):
    if not isinstance(value, str):
        return None
    parsed = urlparse(value)
    if parsed.scheme != "file":
        return None
    return unquote(parsed.path).rstrip("/")


with open(os.environ["APPS_JSON"]) as stream:
    apps = json.load(stream).get("result", {}).get("apps", [])
with open(os.environ["PROCESSES_JSON"]) as stream:
    processes = json.load(stream).get("result", {}).get("runningProcesses", [])

bundle_id = os.environ["BUNDLE_ID"]
app_paths = {
    path
    for app in apps
    if app.get("bundleIdentifier") == bundle_id
    if (path := file_url_path(app.get("url")))
}
pids = set()
for process in processes:
    executable = file_url_path(process.get("executable"))
    pid = process.get("processIdentifier")
    if not executable or not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        continue
    if any(executable.startswith(path + "/") for path in app_paths):
        pids.add(pid)
print(",".join(str(pid) for pid in sorted(pids)))
PY
  }
  target_pids=""
  for (( waited = 0; waited <= wait_seconds; waited++ )); do
    target_pids="$(resolve_target_pids || true)"
    [[ -n "$target_pids" ]] && break
    (( waited == wait_seconds )) || sleep 1
  done
  [[ -n "$target_pids" ]] || die "$bundle_id is not running on device $device_id; launch cmux INTERNAL, then retry (or use --all)"
  echo "==> target process id(s): $target_pids"

  # Every installed cmux build uses the same executable. Keep the stream
  # scoped to INTERNAL by matching the PID(s) belonging to its bundle path.
  set +e
  "${stream_args[@]}" | /usr/bin/awk \
    -v wanted_pids="$target_pids" \
    -v wanted_match="$match" '
    BEGIN {
      count = split(wanted_pids, values, ",")
      for (i = 1; i <= count; i++) {
        wanted[values[i]] = 1
      }
    }
    {
      if (wanted_match != "" && index($0, wanted_match) == 0) {
        next
      }
      if (match($0, /cmux\[[0-9]+\]/)) {
        marker = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", marker)
        if (wanted[marker]) {
          print
          fflush()
        }
      }
    }
  '
  stream_status=${PIPESTATUS[0]}
  set -e
  exit "$stream_status"
fi

set +e
"${stream_args[@]}" | /usr/bin/awk '
  /cmux\[[0-9]+\]/ {
    print
    fflush()
  }
'
stream_status=${PIPESTATUS[0]}
set -e
exit "$stream_status"
