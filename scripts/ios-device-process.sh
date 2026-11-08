#!/usr/bin/env bash
# Process lifecycle helpers for physical iOS dev installs.
#
# Replacing a running app can leave its old executable alive at the previous
# installation URL. Once the new bundle is registered, devicectl can no longer
# resolve that orphan through --terminate-existing. Terminate the registered
# process before install while the bundle-to-executable mapping is authoritative.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/ios-device-process.sh terminate-installed --device-id <id> --bundle-id <id>
EOF
}

device_id=""
bundle_id=""
verb="${1:-}"
[[ -n "$verb" ]] && shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-id) device_id="${2:-}"; shift 2 ;;
    --bundle-id) bundle_id="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$verb" == "terminate-installed" ]] || { usage >&2; exit 2; }
[[ -n "$device_id" ]] || { echo "error: --device-id is required" >&2; exit 2; }
[[ -n "$bundle_id" ]] || { echo "error: --bundle-id is required" >&2; exit 2; }

apps_json="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-apps.XXXXXX")"
processes_json="$(mktemp "${TMPDIR:-/tmp}/cmux-ios-processes.XXXXXX")"
cleanup() {
  rm -f "$apps_json" "$processes_json"
}
trap cleanup EXIT

query_processes() {
  xcrun devicectl device info processes \
    --device "$device_id" \
    --json-output "$processes_json" >/dev/null
}

xcrun devicectl device info apps \
  --device "$device_id" \
  --json-output "$apps_json" >/dev/null
query_processes

running_pids="$(APPS_JSON="$apps_json" PROCESSES_JSON="$processes_json" BUNDLE_ID="$bundle_id" \
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


with open(os.environ["APPS_JSON"]) as handle:
    apps = json.load(handle).get("result", {}).get("apps", [])
with open(os.environ["PROCESSES_JSON"]) as handle:
    processes = json.load(handle).get("result", {}).get("runningProcesses", [])

bundle_id = os.environ["BUNDLE_ID"]
app_paths = {
    path
    for app in apps
    if app.get("bundleIdentifier") == bundle_id
    if (path := file_url_path(app.get("url")))
}
for process in processes:
    executable = file_url_path(process.get("executable"))
    pid = process.get("processIdentifier")
    if not executable or not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        continue
    if any(executable.startswith(app_path + "/") for app_path in app_paths):
        print(pid)
PY
)"

[[ -n "$running_pids" ]] || exit 0

target_pids=""
while IFS= read -r pid; do
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
  echo "==> Terminating existing $bundle_id process (pid $pid) before install"
  xcrun devicectl device process terminate \
    --device "$device_id" \
    --pid "$pid" >/dev/null
  target_pids="${target_pids:+$target_pids,}$pid"
done <<< "$running_pids"

[[ -n "$target_pids" ]] || exit 0

for _ in 1 2 3 4 5 6 7 8 9 10; do
  query_processes
  remaining="$(PROCESSES_JSON="$processes_json" TARGET_PIDS="$target_pids" \
    /usr/bin/python3 - <<'PY'
import json
import os

targets = {int(value) for value in os.environ["TARGET_PIDS"].split(",") if value}
with open(os.environ["PROCESSES_JSON"]) as handle:
    processes = json.load(handle).get("result", {}).get("runningProcesses", [])
running = {
    process.get("processIdentifier")
    for process in processes
    if isinstance(process.get("processIdentifier"), int)
    and not isinstance(process.get("processIdentifier"), bool)
}
print(",".join(str(pid) for pid in sorted(targets & running)))
PY
)"
  [[ -z "$remaining" ]] && exit 0
  sleep 0.2
done

echo "error: $bundle_id process did not exit before its bundle replacement (pid $remaining)" >&2
exit 1
