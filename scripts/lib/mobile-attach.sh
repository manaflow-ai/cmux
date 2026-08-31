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

# Unsigned Simulator apps have no application-identifier entitlement, so iOS
# rejects their Keychain reads. Produce a deterministic per-bundle UUID for the
# simulator-only authoritative identity store. The launcher passes it directly
# into the app process; writing the external defaults domain as well keeps the
# value inspectable from simctl. Recreated isolated simulators for the same tag
# reuse one broker device slot instead of leaking a slot on every verification.
cmux_attach_seed_simulator_device_id() {
  local simulator_id="${1:?simulator id is required}"
  local bundle_id="${2:?bundle id is required}"
  local device_id
  device_id="$(CMUX_SIMULATOR_BUNDLE_ID="$bundle_id" /usr/bin/python3 - <<'PY'
import os
import uuid

bundle_id = os.environ["CMUX_SIMULATOR_BUNDLE_ID"]
print(uuid.uuid5(uuid.NAMESPACE_URL, f"cmux-ios-simulator-device:{bundle_id}"))
PY
)"
  xcrun simctl spawn "$simulator_id" defaults write \
    "$bundle_id" cmux.deviceRegistry.iosDeviceID -string "$device_id"
  printf '%s' "$device_id"
}

# Deterministic client identity for one dogfood bundle on one concrete target.
# The launch script injects it into the DEBUG app and uses the same value to
# reject readiness events emitted by a different phone or simulator.
cmux_attach_dogfood_client_id() {
  local bundle_id="${1:?bundle id is required}"
  local target_id="${2:?target id is required}"
  CMUX_DOGFOOD_BUNDLE_ID="$bundle_id" \
  CMUX_DOGFOOD_TARGET_ID="$target_id" \
    /usr/bin/python3 - <<'PY'
import os
import uuid

bundle_id = os.environ["CMUX_DOGFOOD_BUNDLE_ID"]
target_id = os.environ["CMUX_DOGFOOD_TARGET_ID"]
print(uuid.uuid5(uuid.NAMESPACE_URL, f"cmux-ios-dogfood-client:{bundle_id}:{target_id}"))
PY
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

# Return the normalized email currently authenticated on one exact tagged Mac.
# The tagged socket and bundled CLI are selected by cmux-debug-cli.sh, so this
# can never read the stable app or another agent's tag.
cmux_attach_mac_auth_account() {
  local tag="$1" repo_root="$2" slug status
  slug="$(cmux_attach__slug "$tag")"
  status="$(CMUX_TAG="$slug" "$repo_root/scripts/cmux-debug-cli.sh" auth status --json 2>/dev/null)" \
    || return 1
  AUTH_STATUS="$status" /usr/bin/python3 - <<'PY'
import json
import os

try:
    status = json.loads(os.environ["AUTH_STATUS"])
except (KeyError, TypeError, ValueError):
    raise SystemExit(1)
user = status.get("user")
email = user.get("email") if isinstance(user, dict) else None
if status.get("signed_in") is not True or not isinstance(email, str) or not email.strip():
    raise SystemExit(1)
print(email.strip().lower(), end="")
PY
}

# Ask the tagged Mac for its authoritative post-bootstrap auth status. The
# `auth.status` RPC awaits AuthCoordinator bootstrap, which includes session
# restore and DEBUG auto-login, so this is one lifecycle-owned check rather
# than a shell polling loop.
cmux_attach_wait_for_mac_auth_account() {
  local tag="$1" repo_root="$2" expected="$3" actual=""
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  expected="${expected#"${expected%%[![:space:]]*}"}"
  expected="${expected%"${expected##*[![:space:]]}"}"
  if [[ -z "$expected" ]]; then
    echo "error: tagged Mac auth check requires a non-empty expected account" >&2
    return 1
  fi
  actual="$(cmux_attach_mac_auth_account "$tag" "$repo_root" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    echo "==> tagged Mac auth profile verified ($expected)" >&2
    return 0
  fi
  if [[ -n "$actual" ]]; then
    echo "error: tagged Mac '$tag' authenticated as '$actual', expected '$expected'" >&2
  else
    echo "error: tagged Mac '$tag' did not reach signed-in auth status for '$expected'" >&2
  fi
  return 1
}

# Opens the tagged Mac's event stream. The stream itself is the readiness
# contract, so launch tooling does not infer connection state from diagnostics.
cmux_attach_events() {
  local tag="$1" repo_root="$2" slug
  shift 2
  slug="$(cmux_attach__slug "$tag")"
  CMUX_TAG="$slug" "$repo_root/scripts/cmux-debug-cli.sh" events "$@"
}

# Captures the event sequence before launch. A subsequent wait can replay usable
# session readiness that raced between launch and event-stream subscription.
cmux_attach_readiness_cursor() {
  local tag="$1" repo_root="$2" snapshot cursor
  snapshot="$(cmux_attach_events "$tag" "$repo_root" --snapshot --no-heartbeat)" || return 1
  cursor="$(printf '%s\n' "$snapshot" | /usr/bin/python3 -c '
import json
import sys

for line in sys.stdin:
    try:
        frame = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        continue
    resume = frame.get("resume")
    latest = resume.get("latest_seq") if isinstance(resume, dict) else None
    if isinstance(latest, int) and not isinstance(latest, bool) and latest >= 0:
        print(latest)
        break
')"
  [[ -n "$cursor" ]] || {
    echo "error: tagged Mac did not return an event-stream cursor" >&2
    return 1
  }
  printf '%s' "$cursor"
}

# Waits on the host's explicit usable-RPC event after the launch baseline.
# Args: <tag> <repo_root> <baseline_event_sequence> <timeout_seconds>
#       <expected_client_id>.
cmux_attach_wait_for_usable_session() {
  local tag="$1" repo_root="$2" baseline="$3" timeout="$4"
  local expected_client_id="$5" event event_client_id event_sequence
  local started_ms deadline_ms remaining_ms remaining_seconds cursor
  started_ms="$(cmux_attach_monotonic_milliseconds)"
  deadline_ms="$((started_ms + timeout * 1000))"
  cursor="$baseline"
  while true; do
    remaining_ms="$((deadline_ms - $(cmux_attach_monotonic_milliseconds)))"
    (( remaining_ms > 0 )) || break
    remaining_seconds="$(((remaining_ms + 999) / 1000))"
    if ! event="$(cmux_attach_events \
      "$tag" \
      "$repo_root" \
      --after "$cursor" \
      --name mobile.rpc.ready \
      --limit 1 \
      --timeout "$remaining_seconds" \
      --no-ack \
      --no-heartbeat)"; then
      break
    fi
    event_client_id="$(printf '%s' "$event" | /usr/bin/python3 -c '
import json
import sys
frame = json.load(sys.stdin)
payload = frame.get("payload")
value = payload.get("client_id") if isinstance(payload, dict) else None
print(value if isinstance(value, str) else "")
')"
    if [[ "$event_client_id" == "$expected_client_id" ]]; then
      printf '%s\n' "$event"
      return 0
    fi
    event_sequence="$(printf '%s' "$event" | /usr/bin/python3 -c '
import json
import sys
value = json.load(sys.stdin).get("seq")
if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
    print(value)
')"
    [[ -n "$event_sequence" ]] || break
    cursor="$event_sequence"
  done
  echo "error: mobile app launched but did not establish a usable RPC session with tagged Mac '$tag' before the readiness deadline" >&2
  echo "error: dogfood setup is not ready; inspect phone RPC and subscription diagnostics before handoff" >&2
  return 1
}

# Writes the durable, secret-free proof consumed by dogfood automation. The
# event arrives on stdin to Python so even an unexpectedly sensitive field
# never appears in argv or the process environment; only the explicit
# readiness identity fields are copied into the receipt.
cmux_attach_write_readiness_receipt() {
  local path="$1" git_sha="$2" tag="$3" bundle_id="$4"
  local target="$5" target_id="$6" mac_tag="$7" socket_path="$8"
  local readiness_latency_ms="$9" attempt_count="${10}" event_json="${11}"
  if [[ ! "$readiness_latency_ms" =~ ^[0-9]+$ ]] \
      || [[ ! "$attempt_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: readiness receipt timing and attempt count must be integers" >&2
    return 2
  fi
  printf '%s' "$event_json" | /usr/bin/python3 -c '
import json
import os
import stat
import sys
import tempfile

(
    path,
    git_sha,
    tag,
    bundle_id,
    target,
    target_id,
    mac_tag,
    socket_path,
    readiness_latency_ms,
    attempt_count,
) = sys.argv[1:]
event = json.load(sys.stdin)
payload = event.get("payload")
if event.get("name") != "mobile.rpc.ready" or not isinstance(payload, dict):
    raise SystemExit("invalid mobile.rpc.ready event")

required_strings = ("connection_id", "client_id", "stream_id", "transport")
for key in required_strings:
    if not isinstance(payload.get(key), str) or not payload[key]:
        raise SystemExit(f"missing readiness field: {key}")
workspace_count = payload.get("workspace_count")
if isinstance(workspace_count, bool) or not isinstance(workspace_count, int) or workspace_count < 1:
    raise SystemExit("invalid readiness field: workspace_count")

receipt = {
    "schema": "cmux-ios-dogfood-readiness-v1",
    "git_sha": git_sha,
    "tag": tag,
    "bundle_id": bundle_id,
    "target": target,
    "target_id": target_id,
    "mac_tag": mac_tag,
    "socket_path": socket_path,
    "readiness_latency_ms": int(readiness_latency_ms),
    "attempt_count": int(attempt_count),
    "connection_id": payload["connection_id"],
    "client_id": payload["client_id"],
    "workspace_count": workspace_count,
    "stream_id": payload["stream_id"],
    "transport": payload["transport"],
}
auth_profile = os.environ.get("CMUX_DEV_AUTH_PROFILE", "")
auth_account = os.environ.get("CMUX_DEV_AUTH_ACCOUNT", "")
if auth_profile and auth_account:
    receipt["auth_profile"] = auth_profile
    receipt["auth_account"] = auth_account
    receipt["auth_proof"] = "stack_same_account_rpc"
parent = os.path.dirname(path) or "."
os.makedirs(parent, mode=0o700, exist_ok=True)
parent_status = os.lstat(parent)
if not stat.S_ISDIR(parent_status.st_mode) or parent_status.st_uid != os.getuid():
    raise SystemExit("readiness receipt directory is not a private owned directory")
if parent != ".":
    os.chmod(parent, 0o700)
descriptor, temporary_path = tempfile.mkstemp(prefix=".cmux-ready-", dir=parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(receipt, output, sort_keys=True)
        output.write("\n")
    os.replace(temporary_path, path)
except BaseException:
    try:
        os.close(descriptor)
    except OSError:
        pass
    try:
        os.unlink(temporary_path)
    except OSError:
        pass
    raise
' "$path" "$git_sha" "$tag" "$bundle_id" "$target" "$target_id" \
    "$mac_tag" "$socket_path" "$readiness_latency_ms" "$attempt_count"
}

cmux_attach_monotonic_milliseconds() {
  /usr/bin/python3 -c '
import time

print(time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000)
'
}

# A clean-slate staging sign-in can take longer than the transport setup that
# follows it. Keep the normal auth gate aligned with the credential-free iPhone
# verifier's 45-second cold-start budget, while retaining an explicit override
# for environments that need a different bound.
cmux_attach_resolve_readiness_timeout() {
  # Preserve an explicitly empty override so the caller's validation rejects it
  # instead of silently treating it as the default.
  printf '%s' "${CMUX_ATTACH_READY_TIMEOUT_SECONDS-45}"
}

# Terminate one exact tagged Mac bundle through LaunchServices. The helper uses
# NSRunningApplication plus NSWorkspace termination notifications, so callers
# never infer process identity from a command-line regex or a sleep loop.
# Tests can replace this function with a deterministic fake; production callers
# must provide the repository root so the helper source is unambiguous.
cmux_attach_terminate_bundle_app() {
  local bundle_id="$1" repo_root="$2" timeout="${3:-5}"
  local helper="${CMUX_ATTACH_TERMINATE_BUNDLE_HELPER:-}"
  if [[ -z "$helper" ]]; then
    [[ -n "$repo_root" ]] || {
      echo "error: tagged Mac termination requires the repository root" >&2
      return 1
    }
    helper="$repo_root/scripts/terminate-bundle-app.swift"
  fi
  [[ -f "$helper" ]] || {
    echo "error: tagged Mac termination helper is missing: $helper" >&2
    return 1
  }
  /usr/bin/swift "$helper" "$bundle_id" "$timeout"
}

# Launch one tagged bundle with its own LSEnvironment plus the selected
# non-secret auth contract. NSWorkspace.OpenConfiguration is the supported
# environment propagation path for LaunchServices; unlike `open --env`, it
# reports launch errors to the caller.
cmux_attach_launch_bundle_app() {
  local app="$1" repo_root="$2" auth_profile="${3:-}" credentials_file="${4:-}"
  local helper="${CMUX_ATTACH_LAUNCH_BUNDLE_HELPER:-}"
  if [[ -z "$helper" ]]; then
    [[ -n "$repo_root" ]] || {
      echo "error: tagged Mac launch requires the repository root" >&2
      return 1
    }
    helper="$repo_root/scripts/launch-bundle-app.swift"
  fi
  [[ -f "$helper" ]] || {
    echo "error: tagged Mac launch helper is missing: $helper" >&2
    return 1
  }
  local launch_args=("$app")
  [[ -n "$auth_profile" ]] && launch_args+=(--auth-profile "$auth_profile")
  [[ -n "$credentials_file" ]] && launch_args+=(--credentials-file "$credentials_file")
  /usr/bin/swift "$helper" "${launch_args[@]}"
}

# Ensure the tagged Mac app is running AND its iOS pairing listener
# is actually bound, so a ticket can be minted. Enables the pairing host, then:
#   - socket down  -> launch the local tagged build and wait for the socket.
#   - socket up    -> the pairing default is only read at launch, so a live
#                     socket does NOT prove the listener is bound. Probe by
#                     minting; if it already works, done. If not, relaunch only
#                     this exact tagged app so the startup-only pairing setting
#                     takes effect. Calling ensure-mac is the explicit opt-in.
# Args: <tag> [<repo_root>] [<target>] (repo_root enables the mint readiness
# probe). Returns
# 0 if the Mac is ready to mint a usable target-specific ticket, 1 otherwise.
# Never force-kills a running app by default.
cmux_attach_ensure_mac() {
  local tag="$1" repo_root="${2:-}" target="${3:?attach target is required}" force_relaunch="${4:-0}"
  local auth_profile="${5:-}" credentials_file="${6:-}" expected_account="${7:-}"
  local sock app mint_attempts _i current_account="" stopped_exact_tagged_app=0
  sock="$(cmux_attach_socket_path "$tag")"
  app="$(cmux_attach_mac_app_path "$tag")"
  cmux_attach_enable_pairing_host "$tag" || true

  stop_exact_tagged_app() {
    [[ -d "$app" ]] || return 0
    local bundle_id
    bundle_id="$(cmux_attach_mac_bundle_id "$tag")"
    echo "==> stopping exact tagged Mac app before applying the auth contract ($tag)" >&2
    # The bundle id is derived from the same sanitized tag used by the app and
    # socket. This is required even when the socket is down: `open` reuses an
    # existing process and cannot apply a new profile to it.
    cmux_attach_terminate_bundle_app "$bundle_id" "$repo_root" 5 || {
      echo "error: tagged Mac app '$tag' did not stop before applying a new auth profile" >&2
      return 1
    }
    stopped_exact_tagged_app=1
    return 0
  }

  # A caller that explicitly requests force-relaunch needs a clean process,
  # regardless of whether the old process still publishes its socket.
  if [[ "$force_relaunch" == "1" ]]; then
    stop_exact_tagged_app || return 1
  fi

  if [[ -S "$sock" ]]; then
    if [[ "$force_relaunch" != "1" ]]; then
      if [[ -n "$expected_account" ]]; then
        current_account="$(cmux_attach_mac_auth_account "$tag" "$repo_root" 2>/dev/null || true)"
      fi
      # Quick probe (2 attempts ~1s): reuse only a listener whose selected
      # account already matches this launch contract.
      if [[ -n "$repo_root" ]] \
          && { [[ -z "$expected_account" ]] || [[ "$current_account" == "$expected_account" ]]; } \
          && [[ -n "$(cmux_attach_mint_url "$tag" 60 "$repo_root" "$target" 2)" ]]; then
        return 0
      fi
    fi
    # A tagged app is running but its pairing listener is not ready (launched
    # before the startup-only default was set, prompt pending, or briefly
    # busy). `cmux_attach_ensure_mac` is itself the explicit authorization to
    # relaunch this tag. Bundle identity keeps stable cmux and every other DEV
    # tag untouched.
    if [[ ! -d "$app" ]]; then
      echo "warning: tagged Mac app for '$tag' is running but not ready, and there is no local build to relaunch; auto-pair unavailable. Re-run without --attach for an intentionally unpaired launch." >&2
      return 1
    fi
    if [[ "$stopped_exact_tagged_app" -eq 0 ]]; then
      echo "==> relaunching exact tagged Mac app to bind the pairing listener ($tag)" >&2
      stop_exact_tagged_app || return 1
    fi
  fi

  if [[ ! -d "$app" ]]; then
    echo "warning: tagged Mac app for '$tag' not found locally ($app); cannot auto-pair. Build it (scripts/reload-cloud.sh --tag $tag) then re-run, or pass --no-attach." >&2
    return 1
  fi
  echo "==> launching tagged Mac app to arm pairing ($tag)" >&2
  if [[ -n "$auth_profile" || -n "$credentials_file" || -n "$expected_account" ]]; then
    [[ -n "$auth_profile" && -n "$expected_account" ]] || {
      echo "error: selected Mac auth launch requires profile and expected account" >&2
      return 1
    }
  fi
  cmux_attach_launch_bundle_app "$app" "$repo_root" "$auth_profile" "$credentials_file" || {
    echo "error: tagged Mac app '$tag' could not be launched" >&2
    return 1
  }
  for _i in $(seq 1 60); do
    if [[ -S "$sock" ]]; then
      if [[ -z "$repo_root" ]]; then
        return 0
      fi
      if [[ -n "$expected_account" ]] \
          && ! cmux_attach_wait_for_mac_auth_account "$tag" "$repo_root" "$expected_account"; then
        return 1
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
