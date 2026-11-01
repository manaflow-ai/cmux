#!/usr/bin/env bash
# stable-next.yml smoke-27 / smoke-26: the UI tests of the cmux NEXT Stable DMG.
#
# scripts/ci/stable_next_ui_journey.py: the nightly's fresh-home launch smoke (the app from an empty
# home renders Home, no crash report), then a new user's first session on the same launch (terminal
# and echo, split, Chromium and WebKit pages, palette, Settings, sidebar, close, Home, quit), each
# step checked in the app's own state, with a screenshot per step and a screen recording. A publish
# gate: two attempts, and only a pass ships. A signed DMG (SIGNED=true) must also pass Gatekeeper and
# carry its stapled ticket. Writes tested=<sha256> to GITHUB_OUTPUT on a pass.
#
# Environment: DMG, EXPECT_SHA256, SIGNED (true|false), RUNNER_TEMP, GITHUB_OUTPUT.
set -euo pipefail
: "${DMG:?}" "${EXPECT_SHA256:?}" "${SIGNED:?}" "${RUNNER_TEMP:?}"

actual="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$actual" = "$EXPECT_SHA256" ] || { echo "the DMG is $actual, the sign job made $EXPECT_SHA256" >&2; exit 1; }

if [ "$SIGNED" = true ]; then
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
fi

source scripts/ci/lib/signing-runtime-guard.sh
cmux_signing_runtime_guard
dir="$RUNNER_TEMP/launch-smoke"
mkdir -p "$dir"
for attempt in 1 2; do
  out="$dir/attempt-$attempt"
  mkdir -p "$out" && chmod 0777 "$out"
  status=0
  scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/ci/stable_next_ui_journey.py" \
    --dmg "$DMG" --out "$out" || status=$?
  echo "$status" > "$dir/status-$attempt"
  echo "attempt $attempt: exit $status"
  [ "$status" = 0 ] && break
done
verdict="$(python3 scripts/ci/nightly_next_launch_smoke.py verdict --dir "$dir")"
echo "### cmux NEXT Stable launch smoke on macOS $(sw_vers -productVersion): $verdict" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
# A pass on either attempt passes; anything else (a crash, or no GUI session to judge it in) blocks.
passed=false
for attempt in 1 2; do
  [ "$(cat "$dir/status-$attempt" 2>/dev/null)" = 0 ] && passed=true
done
if [ "$passed" != true ]; then
  echo "::error title=cmux NEXT Stable::launch smoke $verdict on macOS $(sw_vers -productVersion)"
  exit 1
fi
echo "tested=$actual" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "launch smoke passed: $actual"
