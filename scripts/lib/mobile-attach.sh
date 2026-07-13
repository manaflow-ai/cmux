# shellcheck shell=bash
# Shared helpers for the iOS dev auto-pair flow: tag -> identity, enabling the
# tagged Mac app's iOS pairing host, and headlessly minting a short-TTL attach
# URL against the tagged debug socket. Sourced by scripts/dev-setup.sh,
# scripts/mobile-dev-launch.sh, and the reload scripts so the bundle-id / socket
# derivation and the mint RPC live in exactly ONE place (they MUST match
# reload.sh / cmux-debug-cli.sh exactly).
#
# The attach URL is a bearer credential: callers must never print it.

# Raw slug WITHOUT the empty-input fallback: lowercase, ASCII non-[a-z0-9] -> '-',
# trimmed/collapsed. Empty when the tag has no ASCII alphanumerics. The ASCII
# class is deliberate (matches reload.sh + cmux-debug-cli.sh socket/DerivedData
# naming); a locale-sensitive class would keep non-ASCII letters the slug drops.
cmux_attach__slug_raw() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# slug: raw slug, falling back to "agent" only for an otherwise-empty result.
cmux_attach__slug() {
  local cleaned
  cleaned="$(cmux_attach__slug_raw "$1")"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# True iff the tag yields a real (non-empty) slug, i.e. it is not the empty-input
# fallback. Uses the SAME ASCII transform as the slug (not locale-sensitive
# [:alnum:], which would accept non-ASCII letters like "é" that the slug drops).
# Tag identity is correctness-critical (it selects the bundle id / socket / Mac
# app), so entry points must fail closed when this is false rather than let the
# tag collapse onto the shared fallback identity and target an unrelated app.
cmux_attach_tag_has_alnum() {
  [[ -n "$(cmux_attach__slug_raw "$1")" ]]
}

# Cloud registry/presence instance tags are capped at 64 JavaScript UTF-16
# units. Slugs are ASCII, so shell character count is the same measurement.
# Reject instead of truncating because truncation could collapse two tagged
# builds onto the same instance identity.
cmux_attach_tag_within_cloud_limit() {
  local slug
  slug="$(cmux_attach__slug_raw "$1")"
  (( ${#slug} <= 64 ))
}

# Validate a dev-build tag before it selects an app bundle, socket, or cloud
# presence identity. "default" is the stable app instance sentinel, so allowing
# a dev tag to sanitize to that value would make the dev build impersonate the
# stable instance even though its bundle and socket are otherwise isolated.
cmux_attach_validate_dev_tag() {
  local tag="$1" slug
  if ! cmux_attach_tag_has_alnum "$tag"; then
    echo "error: --tag '$tag' has no letters or digits; pick a tag with at least one alphanumeric character" >&2
    return 1
  fi
  slug="$(cmux_attach__slug_raw "$tag")"
  if [[ "$slug" == "default" ]]; then
    echo "error: --tag must not sanitize to 'default'; that tag is reserved for the stable app instance" >&2
    return 1
  fi
  if ! cmux_attach_tag_within_cloud_limit "$tag"; then
    echo "error: --tag must sanitize to at most 64 characters" >&2
    return 1
  fi
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

# Best-effort: ensure the tagged Mac app is running AND its iOS pairing listener
# is actually bound, so a ticket can be minted. Enables the pairing host, then:
#   - socket down  -> launch the local tagged build and wait for the socket.
#   - socket up    -> the pairing default is only read at launch, so a live
#                     socket does NOT prove the listener is bound. Probe by
#                     minting; if it already works, done. If not, a tagged app is
#                     already running — by default DO NOT disturb it (degrade to
#                     signed-in-only with guidance to relaunch). Set
#                     CMUX_ATTACH_ALLOW_RELAUNCH=1 to opt into auto-relaunching
#                     the tagged app so it binds the listener.
# Args: <tag> [<repo_root>] [<target>] (repo_root enables the mint readiness
# probe). Returns
# 0 if the Mac is ready to mint, 1 otherwise (caller degrades to signed-in-only).
# Never fails the calling script and never force-kills a running app by default.
cmux_attach_ensure_mac() {
  local tag="$1" repo_root="${2:-}" target="${3:?attach target is required}" sock app slug _i
  sock="$(cmux_attach_socket_path "$tag")"
  app="$(cmux_attach_mac_app_path "$tag")"
  slug="$(cmux_attach__slug "$tag")"
  cmux_attach_enable_pairing_host "$tag" || true

  if [[ -S "$sock" ]]; then
    # Quick probe (2 attempts ~1s): if pairing already mints, done.
    if [[ -n "$repo_root" ]] && [[ -n "$(cmux_attach_mint_url "$tag" 60 "$repo_root" "$target" 2)" ]]; then
      return 0
    fi
    # A tagged app is running but its pairing listener is not ready (launched
    # before the default was set, prompt pending, or briefly busy). Protect the
    # running instance: do NOT force-kill it unless explicitly opted in.
    if [[ "${CMUX_ATTACH_ALLOW_RELAUNCH:-0}" != "1" ]]; then
      echo "warning: tagged Mac app for '$tag' is running but its iOS pairing listener is not bound (it was likely launched before pairing was enabled, or the macOS Local Network prompt is pending). Relaunch it to enable auto-pair, or re-run with CMUX_ATTACH_ALLOW_RELAUNCH=1; signing in only for now." >&2
      return 1
    fi
    if [[ ! -d "$app" ]]; then
      echo "warning: tagged Mac app for '$tag' is running but not ready, and there is no local build to relaunch; auto-pair unavailable (signing in only)." >&2
      return 1
    fi
    echo "==> relaunching tagged Mac app to bind the pairing listener ($tag) [CMUX_ATTACH_ALLOW_RELAUNCH=1]" >&2
    # Scoped to this tag's executable only (never the stable app or other tags).
    pkill -f "cmux DEV ${slug}.app/Contents/MacOS/cmux DEV" 2>/dev/null || true
    for _i in $(seq 1 25); do [[ -S "$sock" ]] || break; sleep 0.2; done
  fi

  if [[ ! -d "$app" ]]; then
    echo "warning: tagged Mac app for '$tag' not found locally ($app); cannot auto-pair. Build it (scripts/reload-cloud.sh --tag $tag) then re-run, or pass --no-attach." >&2
    return 1
  fi
  echo "==> launching tagged Mac app to arm pairing ($tag)" >&2
  # The tagged app derives its socket from its baked CMUXDevTag, so a plain launch
  # binds /tmp/cmux-debug-<slug>.sock without extra env.
  open -g "$app" >/dev/null 2>&1 || open "$app" >/dev/null 2>&1 || true
  for _i in $(seq 1 60); do
    [[ -S "$sock" ]] && return 0
    sleep 0.2
  done
  echo "warning: tagged Mac socket $sock did not appear after launch; auto-pair unavailable (signing in only)." >&2
  return 1
}

# Mint a short-TTL Mac-scoped attach URL against the tagged socket. Echoes the
# URL on stdout (bearer credential; do not log). Args: <tag> <ttl_seconds>
# <repo_root> <simulator_injection|physical_device>. The Mac owns route selection
# and URL encoding for the target. Polls the mint RPC until routes are bound.
cmux_attach_mint_url() {
  local tag="$1" ttl="$2" repo_root="$3" target="$4" max="${5:-20}" sock slug payload url _i
  case "$target" in
    simulator_injection|physical_device) ;;
    *) echo "error: invalid attach target '$target'" >&2; return 1 ;;
  esac
  sock="$(cmux_attach_socket_path "$tag")"
  # cmux-debug-cli.sh rejects CMUX_TAG outside [A-Za-z0-9._-] and re-sanitizes it
  # to the same slug used for the socket. Pass the slug so tags needing
  # sanitization (e.g. "Fix Foo" -> "fix-foo") are not rejected before minting.
  slug="$(cmux_attach__slug "$tag")"
  for _i in $(seq 1 "$max"); do
    if [[ ! -S "$sock" ]]; then
      sleep 0.5
      continue
    fi
    payload="$(CMUX_TAG="$slug" "$repo_root/scripts/cmux-debug-cli.sh" rpc mobile.attach_ticket.create \
      "{\"ttl_seconds\":${ttl},\"scope\":\"mac\",\"target\":\"${target}\"}" 2>/dev/null || true)"
    if [[ -n "$payload" ]]; then
      url="$(PAYLOAD="$payload" node --input-type=module <<'NODE' 2>/dev/null || true
const payload = JSON.parse(process.env.PAYLOAD);
if (typeof payload.attach_url === "string") process.stdout.write(payload.attach_url);
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
