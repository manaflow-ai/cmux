#!/usr/bin/env bash
set -euo pipefail

binary="${1:?usage: smoke-windows-native.sh /path/to/cmux-tui.exe}"
smoke_root="${RUNNER_TEMP:?RUNNER_TEMP is required}"
socket="$smoke_root/cmux-tui-windows-$$.sock"
state="$smoke_root/cmux-tui-windows-state-$$"
log="$smoke_root/cmux-tui-windows-$$.log"

"$binary" --headless --socket "$socket" --state "$state" >"$log" 2>&1 &
server_pid=$!
cleanup() {
  taskkill.exe //PID "$server_pid" //T //F >/dev/null 2>&1 || true
}
trap cleanup EXIT

ready=false
for _ in {1..200}; do
  if "$binary" --socket "$socket" --json workspace list >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  cat "$log" >&2
  echo "Windows cmux-tui control socket did not become ready" >&2
  exit 1
fi

created="$("$binary" --socket "$socket" --json workspace create --name windows-ci)"
terminal="$(python -c 'import json,sys; print(json.load(sys.stdin)["value"]["terminal_id"])' <<<"$created")"
"$binary" --socket "$socket" terminal "$terminal" write \
  --bytes-base64 V3JpdGUtT3V0cHV0ICgnQ01VWF9XSU5ET1dTXycgKyAnQ09OUFRZX09LJykN
"$binary" --socket "$socket" terminal "$terminal" screen wait \
  --pattern CMUX_WINDOWS_CONPTY_OK --timeout-ms 10000
screen="$("$binary" --socket "$socket" terminal "$terminal" screen read)"
grep -F "CMUX_WINDOWS_CONPTY_OK" <<<"$screen"
