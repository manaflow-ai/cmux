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
#   CMUX_DEV_BACKEND_URL            backend stack URL (informational here; the
#                                   app has it baked in from its build)
# Failure phases are named so the workflow can label infra vs product:
#   launch / socket / sign-in / wait-timeout (wait-timeout is NOT a failure).
set -euo pipefail

TAG="${CMUX_E2E_TAG:?CMUX_E2E_TAG is required}"
DONE_FILE="${CMUX_E2E_DONE_FILE:?CMUX_E2E_DONE_FILE is required}"
WAIT_BUDGET="${CMUX_E2E_WAIT_TIMEOUT_SECONDS:-1500}"
MINT_SCRIPT="${CMUX_E2E_MINT_SCRIPT:-/tmp/cmux-e2e-mint-${GITHUB_RUN_ID:-$$}.sh}"
READ_SCREEN_SCRIPT="${CMUX_E2E_READ_SCREEN_SCRIPT:-/tmp/cmux-e2e-read-screen-${GITHUB_RUN_ID:-$$}.sh}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="/tmp/cmux-debug-${TAG}.sock"
TAG_SLUG="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"

SECRETS_DIR="$HOME/.secrets"
SECRETS_FILE="$SECRETS_DIR/cmuxterm-dev.env"
SECRETS_WROTE=0
write_ci_credentials() {
  [[ -n "${CMUX_DOGFOOD_STACK_EMAIL:-}" && -n "${CMUX_DOGFOOD_STACK_PASSWORD:-}" ]] || {
    phase sign-in "CI Stack credentials are missing"; exit 1;
  }
  umask 077
  mkdir -p "$SECRETS_DIR"
  [[ ! -e "$SECRETS_FILE" ]] || { phase sign-in "refusing to overwrite an existing credentials file"; exit 1; }
  cat > "$SECRETS_FILE" <<EOF
CMUX_DOGFOOD_STACK_EMAIL=$CMUX_DOGFOOD_STACK_EMAIL
CMUX_DOGFOOD_STACK_PASSWORD=$CMUX_DOGFOOD_STACK_PASSWORD
EOF
  chmod 600 "$SECRETS_FILE"
  SECRETS_WROTE=1
}

write_remote_helpers() {
  umask 077
  cat > "$MINT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload="$(CMUX_TAG="__TAG_SLUG__" "__REPO_ROOT__/scripts/cmux-debug-cli.sh" rpc mobile.attach_ticket.create '{"ttl_seconds":600,"scope":"mac","target":"simulator_injection"}')"
PAYLOAD="$payload" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
routes = payload.get("ticket", {}).get("routes", [])
if not any(route.get("kind") == "iroh" for route in routes):
    raise SystemExit("no encrypted Iroh route was ready")
url = payload.get("attach_url")
if not isinstance(url, str) or not url:
    raise SystemExit("attach ticket response had no URL")
print(url)
PY
EOF
  sed -i '' -e "s#__TAG_SLUG__#$TAG_SLUG#g" -e "s#__REPO_ROOT__#$REPO_ROOT#g" "$MINT_SCRIPT"
  cat > "$READ_SCREEN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CMUX_TAG="__TAG_SLUG__" "__REPO_ROOT__/scripts/cmux-debug-cli.sh" "$@"
EOF
  sed -i '' -e "s#__TAG_SLUG__#$TAG_SLUG#g" -e "s#__REPO_ROOT__#$REPO_ROOT#g" "$READ_SCREEN_SCRIPT"
  chmod 700 "$MINT_SCRIPT" "$READ_SCREEN_SCRIPT"
}

phase() { echo "[mac-host:$1] $2"; }

DERIVED_DATA="${CMUX_E2E_MAC_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}}"
APP="$(ls -d "$DERIVED_DATA/Build/Products/Debug/"*.app 2>/dev/null | head -1 || true)"
[[ -n "$APP" ]] || { phase launch "tagged Mac app not found for tag ${TAG}"; exit 1; }

APP_PID=""
DIRECT_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$DIRECT_PID" ]] && kill -0 "$DIRECT_PID" 2>/dev/null; then
    kill "$DIRECT_PID" 2>/dev/null || true
  fi
  if [[ "$SECRETS_WROTE" -eq 1 ]]; then
    : > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    rm -f "$SECRETS_FILE"
  fi
  defaults delete "com.cmuxterm.app.debug.${TAG_SLUG}" mobile.iOSPairingHost.enabled >/dev/null 2>&1 || true
  rm -f "$MINT_SCRIPT" "$READ_SCREEN_SCRIPT"
}
trap cleanup EXIT

phase launch "$APP"
write_ci_credentials
defaults write "com.cmuxterm.app.debug.${TAG_SLUG}" mobile.iOSPairingHost.enabled -bool true
write_remote_helpers
CMUX_DEV_BACKEND_MODE=remote \
CMUX_GHOSTTYKIT_PREPROVISIONED=1 \
CMUX_SKIP_ZIG_BUILD=1 \
./scripts/reload.sh --tag "$TAG" --derived-data "$DERIVED_DATA" \
  --launch --no-global-cli-links --swift-frontend-workaround
# Hosted macOS runners may not keep the launchd GUI submission attached to the
# login session. LaunchServices is the fallback that presents the same tagged
# bundle in the runner's WindowServer session; the bundle already contains the
# tag-specific socket settings from reload.sh.
open -n -g "$APP"
APP_PID="$(pgrep -f "DerivedData/$(basename "$DERIVED_DATA")/.*/cmux DEV" | head -1 || true)"
if [[ ! -S "$SOCKET" ]]; then
  LAUNCH_LOG="${RUNNER_TEMP:-/tmp}/cmux-e2e-mac-direct-${TAG_SLUG}.log"
  CMUX_TAG="$TAG_SLUG" CMUX_BUNDLE_ID="com.cmuxterm.app.debug.${TAG_SLUG}" \
  CMUX_ALLOW_SOCKET_OVERRIDE=1 CMUX_SOCKET_ENABLE=1 CMUX_SOCKET_MODE=allowAll \
  CMUX_SOCKET_PATH="$SOCKET" CMUXD_UNIX_PATH="$SOCKET" \
  CMUX_API_BASE_URL="${CMUX_DEV_BACKEND_URL:-}" CMUX_VM_API_BASE_URL="${CMUX_DEV_BACKEND_URL:-}" \
  CMUX_IROH_BROKER_BASE_URL="${CMUX_DEV_BACKEND_URL:-}" \
  "$APP/Contents/MacOS/cmux DEV" >"$LAUNCH_LOG" 2>&1 &
  DIRECT_PID="$!"
fi

# Bounded readiness wait on the tagged debug socket, then capture the pid the
# socket belongs to so cleanup never kills another tag's instance.
deadline=$(( $(date +%s) + 180 ))
until CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" identify >/dev/null 2>&1; do
  if (( $(date +%s) >= deadline )); then
    phase socket "debug socket never came up: $SOCKET"
    [[ -s "${LAUNCH_LOG:-}" ]] && tail -80 "$LAUNCH_LOG" >&2 || true
    exit 1
  fi
  sleep 2
done
APP_PID="$(pgrep -f "DerivedData/cmux-${TAG}/.*/cmux DEV" | head -1 || true)"

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
