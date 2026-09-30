#!/usr/bin/env bash
# Mac-host side of the iOS e2e gate: launch the tagged Mac app signed into the
# CI account, prove it is answering on its tagged debug socket, then hold the
# runner until the iOS job signals completion by touching CMUX_E2E_DONE_FILE
# over Tailscale SSH. A bounded wait — never GitHub API polling (rate limits) —
# is the teardown contract; if the iOS job dies without signaling, the timeout
# bounds the hold and this job still exits cleanly.
#
# Env contract (scripts/e2e/README.md):
#   CMUX_E2E_TAG                    tag of the app build and backend stack
#   CMUX_E2E_DONE_FILE              path the iOS job touches when finished
#   CMUX_E2E_WAIT_TIMEOUT_SECONDS   hold budget after readiness (default 1500)
#   CMUX_IROH_V2_BASE_URL etc.      per-run backend origins from
#                                   scripts/e2e/backend-env.sh; they reach the
#                                   app because it is exec'd, not `open`ed
# Failure phases are named so the workflow can label infra vs product:
#   launch / socket / sign-in / wait-timeout (wait-timeout is NOT a failure).
set -euo pipefail

TAG="${CMUX_E2E_TAG:?CMUX_E2E_TAG is required}"
DONE_FILE="${CMUX_E2E_DONE_FILE:?CMUX_E2E_DONE_FILE is required}"
WAIT_BUDGET="${CMUX_E2E_WAIT_TIMEOUT_SECONDS:-1500}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="/tmp/cmux-debug-${TAG}.sock"

phase() { echo "[mac-host:$1] $2"; }

APP="$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}/Build/Products/Debug/"*.app 2>/dev/null | head -1 || true)"
[[ -n "$APP" ]] || { phase launch "tagged Mac app not found for tag ${TAG}"; exit 1; }

APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Exec the binary instead of `open`: LaunchServices would apply the baked
# LSEnvironment (staging origins from reload.sh) over this environment, and a
# direct child also gives cleanup an exact pid.
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ -n "${CMUX_IROH_V2_BASE_URL:-}" ]] || { phase launch "CMUX_IROH_V2_BASE_URL unset; run scripts/e2e/backend-env.sh env first"; exit 1; }
phase launch "$APP (iroh-v2 $CMUX_IROH_V2_BASE_URL)"
"$APP/Contents/MacOS/$EXECUTABLE" >"${RUNNER_TEMP:-/tmp}/cmux-e2e-mac-${TAG}.log" 2>&1 &
APP_PID=$!

# Bounded readiness wait on the tagged debug socket.
deadline=$(( $(date +%s) + 180 ))
until CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" identify >/dev/null 2>&1; do
  (( $(date +%s) < deadline )) || { phase socket "debug socket never came up: $SOCKET"; exit 1; }
  sleep 2
done

# The app must be signed into the CI account before the phone tries to pair.
deadline=$(( $(date +%s) + 180 ))
until CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" auth status 2>/dev/null \
    | grep -qiE 'signed[ -]?in'; do
  (( $(date +%s) < deadline )) || { phase sign-in "Mac app never reached signed-in"; exit 1; }
  sleep 3
done
phase ready "socket up, signed in; holding for done-file $DONE_FILE (budget ${WAIT_BUDGET}s)"

rm -f "$DONE_FILE"
deadline=$(( $(date +%s) + WAIT_BUDGET ))
until [[ -f "$DONE_FILE" ]]; do
  if (( $(date +%s) >= deadline )); then
    phase wait-timeout "no completion signal within ${WAIT_BUDGET}s; releasing the runner"
    exit 0
  fi
  sleep 5
done
phase done "completion signal received"
