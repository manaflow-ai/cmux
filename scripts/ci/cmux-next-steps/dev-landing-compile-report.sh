#!/usr/bin/env bash
# cmux-next.yml dev-landing-compile: "Report the landing compile".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
report="$RUNNER_TEMP/cmux-next-dev-landing/report.txt"
mode="$(sed -n 's/^mode=//p' "$report" 2>/dev/null)"
swift_mode="$(sed -n 's/^swift_mode=//p' "$report" 2>/dev/null)"
origin="$(sed -n 's/^previous_sha=//p' "$report" 2>/dev/null)"
gap="$(python3 -I scripts/ci/dev_landing_place.py gap "$origin" "$GITHUB_SHA")"
host="$(printf '%s' "$RUNNER_NAME" | tr '[:upper:]' '[:lower:]')"; host="${host%-glaeda*}"
[[ "$POOL" == owned ]] || host="blacksmith"
counts="$(python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1])).get("compiler_cache") or {}; print(c.get("hits"), c.get("misses"), c.get("compile_wall_seconds"))' "$METRICS" 2>/dev/null || echo "? ? ?")"
read -r hits misses seconds <<<"$counts"
line="host=$host (placed ${PLACED:-any}) runner=$RUNNER_NAME overflow=$([[ "$POOL" == owned ]] && echo no || echo yes) mode=${mode:-?} swift_mode=${swift_mode:-?} restored=${origin:0:12} gap=${gap:-?} xcodebuild=${seconds}s hits=$hits misses=$misses"
echo "::notice title=DEV landing compile::$line"
echo "DEV landing compile: $line" >> "$GITHUB_STEP_SUMMARY"
scripts/cmux-next/dev-cas-holder.sh "$report" "$RUNNER_TEMP/cmux-next-dev-cas-holder" >> "$GITHUB_OUTPUT"
