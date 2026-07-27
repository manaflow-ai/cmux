# shellcheck shell=bash
# Shared helpers for the iOS dev auto-pair flow: tag -> identity, enabling the
# tagged Mac app's iOS pairing host, and headlessly minting a short-TTL attach
# URL against the tagged debug socket. Sourced by scripts/dev-setup.sh,
# scripts/mobile-dev-launch.sh, and the reload scripts so the bundle-id / socket
# derivation and the mint RPC live in exactly ONE place (they MUST match
# reload.sh / cmux-debug-cli.sh exactly).
#
# The attach URL is a bearer credential: callers must never print it.

# Resolve the backend shared by a tagged Mac and its mobile build. Localhost
# remains the default for ordinary simulator work. Physical-device dogfood can
# select a trusted shared backend without giving every developer the relay
# fleet's private JWT signing key.
cmux_attach_resolve_dev_api_base_url() {
  local fallback="$1"
  if [[ -n "${CMUX_DEV_API_BASE_URL:-}" ]]; then
    printf '%s' "$CMUX_DEV_API_BASE_URL"
  else
    printf '%s' "$fallback"
  fi
}

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

# Remove a stale socket only for one validated tagged-build identity. Callers
# must first prove the exact tagged app process has exited. Refuse regular files
# and symlinks so this cleanup cannot delete an unrelated path substituted at
# the tag's predictable socket location.
cmux_attach_remove_stale_socket() {
  local tag="$1" sock
  cmux_attach_validate_dev_tag "$tag" || return 1
  sock="$(cmux_attach_socket_path "$tag")"
  if [[ -L "$sock" ]]; then
    echo "error: refusing to remove symlink at tagged socket path: $sock" >&2
    return 1
  fi
  if [[ -e "$sock" ]] && [[ ! -S "$sock" ]]; then
    echo "error: refusing to remove non-socket at tagged socket path: $sock" >&2
    return 1
  fi
  [[ -S "$sock" ]] || return 0
  rm -f -- "$sock"
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

# Ensure the tagged Mac app is running AND its iOS pairing listener
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
# 0 if the Mac is ready to mint a usable target-specific ticket, 1 otherwise.
# Never force-kills a running app by default.
cmux_attach_ensure_mac() {
  local tag="$1" repo_root="${2:-}" target="${3:?attach target is required}" sock app slug mint_attempts _i
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
      if [[ "$target" == "physical_device" ]]; then
        echo "warning: tagged Mac app for '$tag' cannot mint a trusted physical-device ticket (an encrypted Iroh route may still be starting). Relaunch it to retry, or re-run with CMUX_ATTACH_ALLOW_RELAUNCH=1." >&2
      else
        echo "warning: tagged Mac app for '$tag' is running but its iOS pairing listener is not ready (it was likely launched before pairing was enabled, or the macOS Local Network prompt is pending). Relaunch it to enable auto-pair, or re-run with CMUX_ATTACH_ALLOW_RELAUNCH=1." >&2
      fi
      return 1
    fi
    if [[ ! -d "$app" ]]; then
      echo "warning: tagged Mac app for '$tag' is running but not ready, and there is no local build to relaunch; auto-pair unavailable (signing in only). Re-run without --attach for an intentionally unpaired launch." >&2
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
    if [[ -S "$sock" ]]; then
      if [[ -z "$repo_root" ]]; then
        return 0
      fi
      mint_attempts="${CMUX_ATTACH_MINT_MAX_ATTEMPTS:-20}"
      if [[ -n "$(cmux_attach_mint_url "$tag" 60 "$repo_root" "$target" "$mint_attempts")" ]]; then
        return 0
      fi
      if [[ "$target" == "physical_device" ]]; then
        echo "warning: tagged Mac app for '$tag' launched, but no trusted Iroh ticket became ready." >&2
      else
        echo "warning: tagged Mac app for '$tag' launched, but its iOS pairing ticket did not become ready." >&2
      fi
      return 1
    fi
    sleep 0.2
  done
  echo "warning: tagged Mac socket $sock did not appear after launch; auto-pair unavailable (signing in only)." >&2
  return 1
}

# Mint a short-TTL Mac-scoped attach URL against the tagged socket. Echoes the
# URL on stdout (bearer credential; do not log). Args: <tag> <ttl_seconds>
# <repo_root> <simulator_injection|physical_device>. The Mac owns route selection
# and URL encoding for the target. Polls the mint RPC until routes are bound.
# A physical-device ticket is usable only with an encrypted Iroh route. Plain
# Tailscale TCP cannot carry the phone's Stack credential, so fail closed here
# instead of launching an app that must reject the ticket as untrusted.
cmux_attach_mint_url() {
  local tag="$1" ttl="$2" repo_root="$3" target="$4" max="${5:-20}"
  local sock slug payload cli_output url node_status cli_status _i
  local last_reason="route_not_ready" saw_no_iroh=0
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
      last_reason="control_socket_unavailable"
      sleep 0.5
      continue
    fi
    cli_status=0
    cli_output="$(CMUX_TAG="$slug" "$repo_root/scripts/cmux-debug-cli.sh" rpc mobile.attach_ticket.create \
      "{\"ttl_seconds\":${ttl},\"scope\":\"mac\",\"target\":\"${target}\"}" 2>&1)" || cli_status=$?
    if [[ "$cli_status" -ne 0 ]]; then
      case "$cli_output" in
        *"Mobile host routes are not available yet"*) last_reason="host_routes_unavailable" ;;
        *"Requested mobile host route is not available"*) last_reason="requested_route_unavailable" ;;
        *"Selected mobile host routes cannot be represented"*) last_reason="route_representation_unavailable" ;;
        *) last_reason="attach_rpc_unavailable" ;;
      esac
    elif [[ -n "$cli_output" ]]; then
      payload="$cli_output"
      node_status=0
      url="$(
        PAYLOAD="$payload" ATTACH_TARGET="$target" node --input-type=module <<'NODE' 2>/dev/null
const payload = JSON.parse(process.env.PAYLOAD);
const routes = payload?.ticket?.routes;
if (
  process.env.ATTACH_TARGET === "physical_device" &&
  (!Array.isArray(routes) || !routes.some((route) => route?.kind === "iroh"))
) {
  process.exit(2);
}
if (typeof payload.attach_url === "string") process.stdout.write(payload.attach_url);
NODE
      )" || node_status=$?
      if [[ "$node_status" -eq 2 ]]; then
        # The legacy listener can publish Tailscale before asynchronous Iroh
        # broker registration finishes. Remember that the Mac is reachable,
        # but keep polling for the encrypted route until the readiness window
        # closes.
        saw_no_iroh=1
        last_reason="iroh_route_unavailable"
      elif [[ "$node_status" -ne 0 ]]; then
        last_reason="malformed_response"
      elif [[ -z "$url" ]]; then
        last_reason="ticket_url_missing"
      fi
      if [[ -n "$url" ]]; then
        printf '%s' "$url"
        return 0
      fi
    else
      last_reason="empty_response"
    fi
    # Empty output, malformed output, and a valid ticket that has not gained an
    # Iroh route yet are all transient during startup. Poll to the deadline.
    sleep 0.5
  done
  printf 'warning: attach readiness exhausted: %s\n' "$last_reason" >&2
  if [[ "$saw_no_iroh" -eq 1 ]]; then
    return 2
  fi
  return 1
}
