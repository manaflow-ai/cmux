#!/usr/bin/env bash
# Turnkey dev-build entrypoint: build + launch the macOS dev app auto-signed-in,
# and (optionally) the iOS dev build signed in, with no manual sign-in.
#
# Everything here is DEBUG-only and targets the TAGGED app/socket/bundle id, so
# it never touches the user's stable cmux instance.
#
# Flow (--surface both):
#   1. Select exactly one auth profile for both surfaces.
#   2. Build + launch the macOS dev app via reload.sh --tag <t> --launch. It
#      auto-signs-in from ~/.secrets/cmuxterm-dev.env (DebugDogfoodCredentialResolver).
#   3. Build the iOS dev app, then let mobile-dev-launch.sh launch it signed in.
#      The gate is the app's own signed-in receipt (--readiness app-receipt).
#      The iOS app does not pair with the Mac: the cmux-next Mac app no longer
#      runs the iroh phone listener, so there is no pairing host to enable and
#      no attach ticket to mint. Simulator and device policies stay distinct.
#
# Usage:
#   scripts/dev-setup.sh --tag grid                 # macOS + iOS
#   scripts/dev-setup.sh --tag grid --surface mac   # macOS only
#   scripts/dev-setup.sh --tag grid --surface ios   # iOS only
#   scripts/dev-setup.sh --tag grid --agent         # sign in as the agent account
#   scripts/dev-setup.sh --tag grid --device        # physical iPhone, hosted DEV backend
#
# Flags:
#   --tag <t>           required; tags the macOS + iOS dev builds.
#   --surface <s>       mac | ios | both   (default both)
#   --profile <name>    apply an environment preset after the app is up. Replays
#                       scripts/dev-profiles/<name>.json against the tagged debug
#                       socket (composer, notif, browser, groups, multi-mac, ...).
#                       Accepts a comma-list to compose (e.g. composer,browser).
#                       Run `scripts/dev-profiles/replay-cli.mjs --list` for names.
#   --no-pair           accepted for older callers and ignored: there is no
#                       Mac pairing.
#   --simulator <name>  iOS simulator name (default "iPhone 17").
#   --device            target a connected iPhone instead of the simulator.
#   --agent             use the shared agent account for both Mac and Simulator.
#                       Physical iPhone dogfood always uses the personal profile.

set -euo pipefail

TAG=""
SURFACE="both"            # mac | ios | both
PROFILE=""
AGENT=0
SIMULATOR_NAME="iPhone 17"
IOS_TARGET="simulator"   # simulator | device

usage() { sed -n '2,38p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --surface) SURFACE="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --no-pair) shift ;;  # accepted and ignored: there is no Mac pairing
    --simulator) SIMULATOR_NAME="${2:-}"; shift 2 ;;
    --device) IOS_TARGET="device"; shift ;;
    --agent) AGENT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }
case "$SURFACE" in
  mac|ios|both) ;;
  *) echo "error: --surface must be mac|ios|both (got '$SURFACE')" >&2; exit 2 ;;
esac

if [[ "$AGENT" -eq 1 && "$IOS_TARGET" == "device" ]]; then
  echo "error: --agent is simulator-only; physical iPhone dogfood always uses the personal profile" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_REPLAY="$SCRIPT_DIR/dev-profiles/replay-cli.mjs"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"

# Validate before loading credentials or starting either build. The shared validator also rejects the stable instance sentinel.
if ! cmux_attach_validate_dev_tag "$TAG"; then
  exit 2
fi

# --- profiles: validate up front (P3) ---------------------------------------
# Fail fast on an unknown profile name BEFORE any heavy build/launch work, so a
# typo doesn't cost a full build. --dry-run validates parse + resolution without
# touching a socket; it lists the available profiles on an unknown name.
if [[ -n "$PROFILE" ]]; then
  if ! node "$PROFILE_REPLAY" --dry-run --profile "$PROFILE" >/dev/null; then
    echo "error: invalid --profile '$PROFILE'." >&2
    echo "available profiles:" >&2
    node "$PROFILE_REPLAY" --list | sed 's/^/  /' >&2
    exit 2
  fi
fi

# --- credentials: validate only, do NOT export into this process -------------
# The macOS app reads dogfood creds from disk (DebugDogfoodCredentialResolver),
# and mobile-dev-launch.sh loads its own creds for the iOS launch. So this script
# must NOT export CMUX_UITEST_STACK_PASSWORD: reload.sh launches the long-lived
# GUI process inheriting this environment (it only scrubs a denylist, and the
# Stack vars are not on it), which would leak the password to every child
# terminal/CLI the app spawns. Validate in a subshell to surface a clear early
# error, but keep the password out of dev-setup.sh's environment.
AUTH_PROFILE="personal"
AUTH_CREDENTIALS_FILE="$HOME/.secrets/cmuxterm-dev.env"
if [[ "$AGENT" -eq 1 ]]; then
  AUTH_PROFILE="agent"
  # Let the agent profile search both the current and legacy secret files.
  # Passing cmuxterm-dev.env explicitly would make an older ~/.secrets/cmux.env
  # pair undiscoverable because explicit files are intentionally exclusive.
  AUTH_CREDENTIALS_FILE=""
fi
DEV_SECRETS_ARGS=(--profile "$AUTH_PROFILE")
[[ -n "$AUTH_CREDENTIALS_FILE" ]] && DEV_SECRETS_ARGS+=(--credentials-file "$AUTH_CREDENTIALS_FILE")
# shellcheck source=scripts/lib/dev-secrets.sh
AUTH_ACCOUNT="$(
  source "$SCRIPT_DIR/lib/dev-secrets.sh"
  cmux_dev_secrets_load "${DEV_SECRETS_ARGS[@]}" >/dev/null
  printf '%s' "$CMUX_DEV_AUTH_ACCOUNT"
)" || exit 2
if [[ -z "$AUTH_ACCOUNT" ]]; then
  echo "error: selected auth profile did not resolve an account" >&2
  exit 2
fi
echo "==> dev auth contract: $AUTH_PROFILE ($AUTH_ACCOUNT)"

# A physical phone cannot reach the Mac's localhost API. Select the hosted DEV
# backend for both tagged apps before either build starts, so a new teammate's
# first device run does not depend on remembering two origin overrides. Keep
# explicit caller values intact for controlled local or staging experiments.
if [[ "$IOS_TARGET" == "device" && ( "$SURFACE" == "ios" || "$SURFACE" == "both" ) ]]; then
  if [[ -z "${CMUX_DEV_API_BASE_URL:-}" ]]; then
    export CMUX_DEV_API_BASE_URL="https://cmux-staging.vercel.app"
  fi
  if [[ -z "${CMUX_IROH_BROKER_BASE_URL:-}" ]]; then
    export CMUX_IROH_BROKER_BASE_URL="https://cmux-staging.vercel.app"
  fi
  echo "==> physical-device dev backend: $CMUX_DEV_API_BASE_URL"
fi

# --- tag identity (delegated to scripts/lib/mobile-attach.sh) ----------------
# slug -> socket path + DerivedData; tag-id -> bundle id. The shared lib owns the
# exact derivation so it stays in sync with reload.sh / cmux-debug-cli.sh.
dev_setup__sanitize_path() { cmux_attach__slug "$1"; }
dev_setup__sanitize_bundle() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

TAG_SLUG="$(dev_setup__sanitize_path "$TAG")"
TAG_ID="$(dev_setup__sanitize_bundle "$TAG")"
BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"

# --- macOS build + launch (P1 auto-sign-in) ---------------------------------
build_and_launch_mac() {
  echo "==> building + launching macOS dev app (tag: $TAG)"
  local reload_args=(
    --tag "$TAG" \
    --launch \
    --auth-profile "$AUTH_PROFILE" \
    --expected-account "$AUTH_ACCOUNT"
  )
  [[ -n "$AUTH_CREDENTIALS_FILE" ]] \
    && reload_args+=(--credentials-file "$AUTH_CREDENTIALS_FILE")
  "$REPO_ROOT/scripts/reload.sh" "${reload_args[@]}"
}

# --- iOS build + target-aware launch ----------------------------------------
build_and_launch_ios() {
  echo "==> building iOS dev app (tag: $TAG)"
  # --no-launch: build + install only. mobile-dev-launch.sh below does the launch
  # with the sign-in env, so a plain reload launch would be redundant (and
  # would launch signed-out).
  # The iOS reload interface owns build/install flags only. Auth identity is
  # deliberately passed to the separate mobile-dev-launch invocation below,
  # which is the one that injects credentials.
  local ios_reload_args=(--tag "$TAG" --no-launch)
  if [[ "$IOS_TARGET" == "device" ]]; then
    # --device-only skips the simulator build/boot entirely (--device would also
    # reload the default simulator first and can fail before reaching the iPhone).
    ios_reload_args+=(--device-only)
  else
    # Build + install onto the SAME simulator mobile-dev-launch.sh launches on,
    # so the requested sim has the freshly built app (reload defaults to iPhone 17).
    ios_reload_args+=(--simulator "$SIMULATOR_NAME")
  fi
  "$REPO_ROOT/ios/scripts/reload.sh" "${ios_reload_args[@]}"

  echo "==> launching iOS dev app signed in"
  # The iOS app declares CMUXDogfoodReadiness = app-receipt-v1. Name the gate
  # explicitly: a physical device does not expose the installed Info.plist, so
  # `auto` would find nothing to read there.
  local mobile_launch_args=(--tag "$TAG" --readiness app-receipt)
  mobile_launch_args+=(
    --auth-profile "$AUTH_PROFILE"
    --expected-account "$AUTH_ACCOUNT"
  )
  [[ -n "$AUTH_CREDENTIALS_FILE" ]] \
    && mobile_launch_args+=(--credentials-file "$AUTH_CREDENTIALS_FILE")
  if [[ "$IOS_TARGET" == "device" ]]; then
    mobile_launch_args+=(--device)
  else
    mobile_launch_args+=(--simulator "$SIMULATOR_NAME")
  fi
  "$REPO_ROOT/scripts/mobile-dev-launch.sh" "${mobile_launch_args[@]}"
}

# --- apply environment profile(s) (P3) --------------------------------------
# Profiles provision a realistic test environment against the TAGGED Mac socket
# via scripts/cmux-debug-cli.sh. The replay engine spawns the debug CLI, which
# refuses without CMUX_TAG and never touches the stable app.
#
# This must run BEFORE build_and_launch_ios: the simulator launch path
# (mobile-dev-launch.sh -> `simctl launch --console-pty`) attaches to the app
# console and blocks until the app exits, so anything after it would never run.
# Profiles only need the Mac socket anyway. For --surface ios the tagged Mac app
# must already be running.
apply_profile() {
  echo "==> applying profile(s) '$PROFILE' against $SOCKET_PATH"
  # The Mac app needs its socket bound before the debug CLI can connect. Poll
  # the socket file (the real readiness signal), bounded so a never-launching
  # app fails clearly instead of hanging.
  local _attempt
  for _attempt in $(seq 1 40); do
    [[ -S "$SOCKET_PATH" ]] && break
    sleep 0.25
  done
  if [[ ! -S "$SOCKET_PATH" ]]; then
    echo "error: tagged socket $SOCKET_PATH never appeared; is the Mac dev app for tag '$TAG' running?" >&2
    exit 1
  fi
  node "$PROFILE_REPLAY" --tag "$TAG" --profile "$PROFILE" --cwd "$REPO_ROOT"
}

# --- orchestrate ------------------------------------------------------------
if [[ "$SURFACE" == "mac" || "$SURFACE" == "both" ]]; then
  build_and_launch_mac
fi

# Apply environment profile(s) BEFORE the (blocking) iOS launch. Profiles target
# the Mac socket, so they only need the Mac app up.
if [[ -n "$PROFILE" ]]; then
  apply_profile
fi

if [[ "$SURFACE" == "ios" || "$SURFACE" == "both" ]]; then
  build_and_launch_ios
fi

echo "==> dev-setup complete (tag: $TAG, surface: $SURFACE)"
