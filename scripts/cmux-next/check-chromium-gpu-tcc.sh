#!/usr/bin/env bash
# Live check for CVE-2026-106378 (pwn.ai "chrome-escape"): every Chromium GPU
# helper of a running cmux app must be responsible for itself in macOS TCC.
# A GPU helper whose responsible process is the cmux app runs with cmux's
# privacy grants (Accessibility: posting keystrokes through WindowServer),
# which the sandboxed GPU process can reach (gpu.sb allows
# com.apple.windowserver.active).
#
# usage: check-chromium-gpu-tcc.sh APP_PATH
#   APP_PATH: the running .app (e.g. "/Applications/cmux NIGHTLY.app").
# Exit 0: every GPU helper disclaims. Exit 1: one inherits the app's
# responsibility (exposed). Exit 2: no GPU helper of that app is running.
set -euo pipefail
app="${1:?usage: check-chromium-gpu-tcc.sh APP_PATH}"
app="${app%/}"
# ps prints the resolved path (/tmp is /private/tmp on macOS).
[[ -d "$app" ]] && app="$(cd "$app" && pwd -P)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/gpu-tcc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcrun clang -O1 -o "$work/responsible_pid" "$here/tcc/responsible_pid.c"

pids=()
while read -r pid command; do
  case "$command" in
    "$app/Contents/Frameworks/"*" --type=gpu-process"*) pids+=("$pid") ;;
  esac
done < <(ps -axo pid=,command=)
if [ "${#pids[@]}" -eq 0 ]; then
  echo "no GPU helper of $app is running (open a Chromium tab first)" >&2
  exit 2
fi

exposed=0
while read -r pid responsible; do
  if [ "$pid" = "$responsible" ]; then
    echo "ok: GPU helper $pid is responsible for itself"
  else
    owner="$(ps -o command= -p "$responsible" 2>/dev/null | cut -c1-120 || true)"
    echo "EXPOSED: GPU helper $pid inherits TCC responsibility of $responsible ($owner)"
    exposed=1
  fi
done < <("$work/responsible_pid" "${pids[@]}")
exit "$exposed"
