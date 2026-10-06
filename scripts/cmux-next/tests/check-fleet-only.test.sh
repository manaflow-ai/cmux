#!/usr/bin/env bash
# The check scripts that build Swift (swift test or xcodebuild) run only as a
# fleet CI step (`cmux-ci run`, which sets CMUX_CI_STEP_KEY) or on a GitHub
# runner, never on a developer Mac (agents ran them on the laptop on
# 2026-10-04 and 2026-10-06). Stub `swift` and `xcodebuild` record whether a
# build was reached.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/pkg"
for tool in swift xcodebuild; do
  printf '#!/bin/sh\necho ran >"%s/ran"\n' "$TMP" > "$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done

check() {
  local script=$1 ci_job=$2
  run() { env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" "$@" /bin/bash "$ROOT/scripts/cmux-next/$script" "$TMP/pkg" 2>&1; }
  rm -f "$TMP/ran"
  local out status=0
  out=$(run) || status=$?
  [[ $status -eq 2 ]] || { printf 'FAIL: %s exited %s on a non-fleet host (want 2):\n%s\n' "$script" "$status" "$out"; exit 1; }
  [[ ! -e "$TMP/ran" ]] || { echo "FAIL: $script started a build on a non-fleet host"; exit 1; }
  grep -q "$script runs only on the build fleet" <<<"$out" || { printf 'FAIL: %s message does not say fleet only:\n%s\n' "$script" "$out"; exit 1; }
  grep -qF "$ci_job" <<<"$out" || { printf 'FAIL: %s message does not name its CI job %s:\n%s\n' "$script" "$ci_job" "$out"; exit 1; }
  # On the fleet or a GitHub runner the guard lets the script continue; it
  # may fail later on the stubs, but never with the guard's exit 2 message.
  for env_var in CMUX_CI_STEP_KEY=k1 GITHUB_ACTIONS=true; do
    out=$(run "$env_var") || true
    if grep -q "runs only on the build fleet" <<<"$out"; then
      printf 'FAIL: %s refused with %s:\n%s\n' "$script" "$env_var" "$out"; exit 1
    fi
  done
}

check check-action-surfaces.sh 'cmux-next generated files'
check check-release-compile.sh 'cmux-next Release compile (Xcode 26)'
check check-cmux-scheme-compile.sh 'cmux app scheme compile (Debug)'
printf 'check fleet-only tests: ok\n'
