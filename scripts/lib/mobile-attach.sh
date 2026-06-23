# shellcheck shell=bash
# Shared helpers for the iOS dev auto-pair flow: tag -> identity, enabling the
# tagged Mac app's iOS pairing host, and headlessly minting a short-TTL attach
# URL against the tagged debug socket. Sourced by scripts/dev-setup.sh,
# scripts/mobile-dev-launch.sh, and the reload scripts so the bundle-id / socket
# derivation and the mint RPC live in exactly ONE place (they MUST match
# reload.sh / cmux-debug-cli.sh exactly).
#
# The attach URL is a bearer credential: callers must never print it.

# slug: lowercase, non-alnum -> '-', trimmed/collapsed. Matches reload.sh +
# cmux-debug-cli.sh socket/DerivedData naming.
cmux_attach__slug() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# bundle id segment: lowercase, non-alnum -> '.', trimmed/collapsed.
cmux_attach__bundle_seg() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# The tagged macOS Debug app's bundle id (the iOS pairing host lives on the Mac).
cmux_attach_mac_bundle_id() {
  printf 'com.cmuxterm.app.debug.%s' "$(cmux_attach__bundle_seg "$1")"
}

# The tagged Mac app's debug socket path.
cmux_attach_socket_path() {
  printf '/tmp/cmux-debug-%s.sock' "$(cmux_attach__slug "$1")"
}

# The locally-built tagged macOS Debug .app bundle path (cloud/local reloads both
# download/install here). Both the DerivedData dir AND the .app basename use the
# sanitized slug, matching reload.sh (`APP_NAME="cmux DEV ${TAG_SLUG}"`); the raw
# tag would miss for any tag whose slug differs (e.g. "Fix Foo" -> "fix-foo").
cmux_attach_mac_app_path() {
  local slug
  slug="$(cmux_attach__slug "$1")"
  printf '%s/Library/Developer/Xcode/DerivedData/cmux-%s/Build/Products/Debug/cmux DEV %s.app' \
    "$HOME" "$slug" "$slug"
}

# Enable the opt-in iOS pairing host on the tagged Mac bundle. Must be written
# BEFORE the Mac app launches (read in applicationDidFinishLaunching). The first
# bind per bundle id triggers a one-time macOS "Local Network" prompt.
cmux_attach_enable_pairing_host() {
  local tag="$1" bundle_id
  bundle_id="$(cmux_attach_mac_bundle_id "$tag")"
  defaults write "$bundle_id" mobile.iOSPairingHost.enabled -bool true
}

# True if the tagged Mac app's debug socket is bound (app running + listening).
cmux_attach_mac_socket_ready() {
  local sock
  sock="$(cmux_attach_socket_path "$1")"
  [[ -S "$sock" ]]
}

# Best-effort: ensure the tagged Mac app is running so a ticket can be minted.
# Enables the pairing host, then (if the socket is down and a local tagged build
# exists) launches it and waits up to ~12s for the socket. Returns 0 if the
# socket is ready, 1 otherwise (caller should degrade to signed-in-only). Never
# fails the calling script.
cmux_attach_ensure_mac() {
  local tag="$1" sock app
  sock="$(cmux_attach_socket_path "$tag")"
  cmux_attach_enable_pairing_host "$tag" || true
  if [[ -S "$sock" ]]; then
    return 0
  fi
  app="$(cmux_attach_mac_app_path "$tag")"
  if [[ ! -d "$app" ]]; then
    echo "warning: tagged Mac app for '$tag' not found locally ($app); cannot auto-pair. Build it (scripts/reload-cloud.sh --tag $tag) then re-run, or pass --no-attach." >&2
    return 1
  fi
  echo "==> launching tagged Mac app to arm pairing ($tag)" >&2
  # The tagged app derives its socket from its baked CMUXDevTag, so a plain launch
  # binds /tmp/cmux-debug-<slug>.sock without extra env.
  open -g "$app" >/dev/null 2>&1 || open "$app" >/dev/null 2>&1 || true
  local _i
  for _i in $(seq 1 60); do
    [[ -S "$sock" ]] && return 0
    sleep 0.2
  done
  echo "warning: tagged Mac socket $sock did not appear after launch; auto-pair unavailable (signing in only)." >&2
  return 1
}

# Mint a short-TTL Mac-scoped attach URL against the tagged socket. Echoes the
# URL on stdout (bearer credential; do not log). Args: <tag> <ttl_seconds>
# <repo_root>. Polls the mint RPC (the real readiness signal) until routes are
# bound, bounded so a never-binding listener fails instead of hanging.
cmux_attach_mint_url() {
  local tag="$1" ttl="$2" repo_root="$3" sock payload url _i
  sock="$(cmux_attach_socket_path "$tag")"
  for _i in $(seq 1 20); do
    if [[ ! -S "$sock" ]]; then
      sleep 0.5
      continue
    fi
    payload="$(CMUX_TAG="$tag" "$repo_root/scripts/cmux-debug-cli.sh" rpc mobile.attach_ticket.create \
      "{\"ttl_seconds\":${ttl},\"scope\":\"mac\"}" 2>/dev/null || true)"
    if [[ -n "$payload" ]]; then
      url="$(REPO_ROOT="$repo_root" PAYLOAD="$payload" node --input-type=module <<'NODE' 2>/dev/null || true
import path from "node:path";
import { pathToFileURL } from "node:url";
const { buildAttachURL } = await import(
  pathToFileURL(path.join(process.env.REPO_ROOT, "scripts", "lib", "attach-url.mjs")).href
);
const { attachURL } = buildAttachURL(JSON.parse(process.env.PAYLOAD));
process.stdout.write(attachURL);
NODE
)"
      if [[ -n "$url" ]]; then
        printf '%s' "$url"
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}
