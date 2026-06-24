#!/usr/bin/env bash
# Turnkey dev-build entrypoint: build + launch the macOS dev app auto-signed-in,
# and (optionally) the iOS dev build auto-paired to it, with no QR scan and no
# manual sign-in. Wraps the P1 macOS auto-sign-in path and the P2 iOS auto-pair.
#
# Everything here is DEBUG-only and targets the TAGGED app/socket/bundle id, so
# it never touches the user's stable cmux instance.
#
# Flow (--surface both):
#   1. Load dev sign-in creds (dogfood account wins; --agent forces agent).
#   2. Enable the iOS pairing host on the tagged build (opt-in, default OFF):
#        defaults write com.cmuxterm.app.debug.<tag-id> mobile.iOSPairingHost.enabled -bool true
#      Written BEFORE the macOS launch so a single build binds the NWListener on
#      first launch. NOTE: the first bind per bundle id triggers a one-time macOS
#      "Local Network" permission prompt; click Allow.
#   3. Build + launch the macOS dev app via reload.sh --tag <t> --launch. It
#      auto-signs-in from ~/.secrets/cmuxterm-dev.env (DebugDogfoodCredentialResolver).
#   4. Headlessly mint a short-TTL attach URL against the tagged socket via the
#      local automation path (no Stack auth needed for the mint).
#   5. Build + launch the iOS dev build, passing the URL as CMUX_DOGFOOD_ATTACH_URL
#      so the phone auto-attaches.
#
# Usage:
#   scripts/dev-setup.sh --tag grid                 # macOS + iOS, auto-pair
#   scripts/dev-setup.sh --tag grid --surface mac   # macOS only
#   scripts/dev-setup.sh --tag grid --surface ios   # iOS only (needs Mac listener up)
#   scripts/dev-setup.sh --tag grid --no-pair       # build both, skip auto-pair
#   scripts/dev-setup.sh --tag grid --agent         # sign in as the agent account
#
# Flags:
#   --tag <t>           required; tags the macOS + iOS dev builds.
#   --surface <s>       mac | ios | both   (default both)
#   --profile <name>    apply an environment preset after the app is up. Replays
#                       scripts/dev-profiles/<name>.json against the tagged debug
#                       socket (composer, notif, browser, groups, multi-mac, ...).
#                       Accepts a comma-list to compose (e.g. composer,browser).
#                       Run `scripts/dev-profiles/replay-cli.mjs --list` for names.
#   --no-pair           skip enabling the host + minting + auto-pair.
#   --simulator <name>  iOS simulator name (default "iPhone 17").
#   --device            target a connected iPhone instead of the simulator.
#   --agent             use the shared agent account for the iOS sign-in. NOTE:
#                       this does NOT change the macOS account: the Mac app picks
#                       its account from disk via DebugDogfoodCredentialResolver
#                       (dogfood-first), which has no agent-force selector and
#                       which we cannot override without env-leaking the password.
#                       For a pure agent-account run, use --surface ios --agent.

set -euo pipefail

TAG=""
SURFACE="both"            # mac | ios | both
PROFILE=""
NO_PAIR=0
AGENT=0
SIMULATOR_NAME="iPhone 17"
IOS_TARGET="simulator"   # simulator | device
TTL_SECONDS="600"

usage() { sed -n '2,40p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --surface) SURFACE="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --no-pair) NO_PAIR=1; shift ;;
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

if [[ "$AGENT" -eq 1 && ( "$SURFACE" == "mac" || "$SURFACE" == "both" ) ]]; then
  echo "warning: --agent only changes the iOS sign-in account. The macOS app picks its" >&2
  echo "         account from ~/.secrets via DebugDogfoodCredentialResolver (dogfood-first)," >&2
  echo "         which has no agent-force selector. For a pure agent run use --surface ios --agent." >&2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_REPLAY="$SCRIPT_DIR/dev-profiles/replay-cli.mjs"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"

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
DEV_SECRETS_ARGS=()
[[ "$AGENT" -eq 1 ]] && DEV_SECRETS_ARGS+=(--agent)
# shellcheck source=scripts/lib/dev-secrets.sh
if ! ( source "$SCRIPT_DIR/lib/dev-secrets.sh"; cmux_dev_secrets_load "${DEV_SECRETS_ARGS[@]}" ); then
  exit 2
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

# --- enable the iOS pairing host (must precede the macOS launch) -------------
enable_pairing_host() {
  echo "==> enabling iOS pairing host on $BUNDLE_ID (opt-in, default OFF)"
  echo "    (first bind per bundle id triggers a one-time macOS Local Network prompt; click Allow)"
  # The host listener is opt-in. createAttachTicket returns empty routes unless
  # the NWListener is bound. MobileHostService.start() reads this default at app
  # launch (applicationDidFinishLaunching), so it must be written BEFORE the
  # macOS launch below. The tagged bundle id is targeted, never the stable app.
  cmux_attach_enable_pairing_host "$TAG"
}

# --- macOS build + launch (P1 auto-sign-in) ---------------------------------
# Writing the pairing default first means a single reload.sh build binds the
# listener on its first launch (no double build).
build_and_launch_mac() {
  echo "==> building + launching macOS dev app (tag: $TAG)"
  # reload.sh --launch builds the tagged Debug app and opens it. The macOS app
  # auto-signs-in from ~/.secrets/cmuxterm-dev.env via DebugDogfoodCredentialResolver.
  "$REPO_ROOT/scripts/reload.sh" --tag "$TAG" --launch
}

# --- mint a short-TTL attach URL headlessly ---------------------------------
# Echoes the URL on stdout. The URL is a bearer credential: callers must NOT
# print it. Polls the mint RPC (real readiness signal) until routes are ready,
# bounded so a never-binding listener fails instead of hanging.
mint_attach_url() { cmux_attach_mint_url "$TAG" "$TTL_SECONDS" "$REPO_ROOT"; }

# --- iOS build + launch (auto-pair via CMUX_DOGFOOD_ATTACH_URL) -------------
build_and_launch_ios() {
  local attach_url="${1:-}"
  echo "==> building iOS dev app (tag: $TAG)"
  # --no-launch: build + install only. mobile-dev-launch.sh below does the launch
  # with the sign-in + auto-pair env, so a plain reload launch would be redundant
  # (and would launch signed-out).
  local ios_args=(--tag "$TAG" --no-launch)
  if [[ "$IOS_TARGET" == "device" ]]; then
    # --device-only skips the simulator build/boot entirely (--device would also
    # reload the default simulator first and can fail before reaching the iPhone).
    ios_args+=(--device-only)
  else
    # Build + install onto the SAME simulator mobile-dev-launch.sh launches on,
    # so the requested sim has the freshly built app (reload defaults to iPhone 17).
    ios_args+=(--simulator "$SIMULATOR_NAME")
  fi
  "$REPO_ROOT/ios/scripts/reload.sh" "${ios_args[@]}"

  echo "==> launching iOS dev app${attach_url:+ (auto-pairing)}"
  local launch_args=(--tag "$TAG")
  # Express attach intent so mobile-dev-launch.sh honors the pre-minted URL we
  # pass via CMUX_DOGFOOD_ATTACH_URL (it ignores an ambient URL without --attach).
  if [[ -n "$attach_url" ]]; then
    launch_args+=(--attach)
  fi
  if [[ "$AGENT" -eq 1 ]]; then
    launch_args+=(--agent)
  fi
  if [[ "$IOS_TARGET" == "device" ]]; then
    launch_args+=(--device)
  else
    launch_args+=(--simulator "$SIMULATOR_NAME")
  fi
  # Pass the URL via env (CMUX_DOGFOOD_ATTACH_URL), never on the command line, so
  # it is not visible in `ps`. mobile-dev-launch.sh injects it into the app env.
  CMUX_DOGFOOD_ATTACH_URL="$attach_url" "$REPO_ROOT/scripts/mobile-dev-launch.sh" "${launch_args[@]}"
}

# --- apply environment profile(s) (P3) --------------------------------------
# Profiles provision a realistic test environment against the TAGGED Mac socket
# via scripts/cmux-debug-cli.sh. The replay engine spawns the debug CLI, which
# refuses without CMUX_TAG and never touches the stable app.
#
# This must run BEFORE build_and_launch_ios: the simulator launch path
# (mobile-dev-launch.sh -> `simctl launch --console-pty`) attaches to the app
# console and blocks until the app exits, so anything after it would never run.
# Profiles only need the Mac socket anyway, and seeding before the phone attaches
# means the phone sees the seeded workspaces/groups immediately. For --surface
# ios the tagged Mac app must already be running.
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
ATTACH_URL=""

# Enable the pairing host BEFORE the macOS launch so a single build binds the
# listener on first launch (the default is read in applicationDidFinishLaunching).
if [[ "$NO_PAIR" -eq 0 && ( "$SURFACE" == "mac" || "$SURFACE" == "both" ) ]]; then
  enable_pairing_host
fi

if [[ "$SURFACE" == "mac" || "$SURFACE" == "both" ]]; then
  build_and_launch_mac
fi

# Mint the attach URL when iOS is in play and pairing is on. For --surface ios
# the Mac dev app must already be running with the pairing host enabled.
if [[ "$NO_PAIR" -eq 0 && ( "$SURFACE" == "ios" || "$SURFACE" == "both" ) ]]; then
  echo "==> minting attach URL against $SOCKET_PATH"
  if ATTACH_URL="$(mint_attach_url)"; then
    echo "==> attach URL minted (TTL ${TTL_SECONDS}s); auto-pair armed"
  else
    ATTACH_URL=""
    echo "warning: could not mint an attach URL (is the Mac dev app running with the pairing host enabled, and the Local Network prompt allowed?). iOS will launch signed-in only." >&2
  fi
fi

# Apply environment profile(s) BEFORE the (blocking) iOS launch. Profiles target
# the Mac socket, so they only need the Mac app up; seeding here means the phone
# sees the seeded state the moment it attaches.
if [[ -n "$PROFILE" ]]; then
  apply_profile
fi

if [[ "$SURFACE" == "ios" || "$SURFACE" == "both" ]]; then
  build_and_launch_ios "$ATTACH_URL"
fi

echo "==> dev-setup complete (tag: $TAG, surface: $SURFACE)"
