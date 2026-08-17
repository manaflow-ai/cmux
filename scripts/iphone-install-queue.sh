#!/usr/bin/env bash
# Offline install queue for tagged cmux iOS dev builds targeting a physical iPhone.
#
# When an iOS reload finishes but the target iPhone is unreachable (unplugged,
# asleep, off the network), the signed .app is parked here instead of being
# dropped. A LaunchAgent (scripts/install-iphone-queue-agent.sh) drains the
# queue the moment the phone reappears, so the build lands on the device
# without anyone re-running the reload.
#
# Verbs:
#   enqueue --tag <tag> --app <signed .app> [--device-id <id>] [--checkout <dir>]
#           --auth-profile personal --expected-account <email>
#           --credentials-file <absolute-0600-file>
#           [--no-attach] [--no-sign-in] [--no-setup] [--no-launch]
#           [--allow-unauthenticated]
#     Copy the signed app into the persistent queue (one slot per tag; a
#     re-enqueue of the same tag replaces the older build). The sign-in/attach
#     opt-out flags produce an unauthenticated install, so they require the human-only
#     CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 (agents never set it); reload also
#     passes --allow-unauthenticated to make that intent explicit. The
#     authorization is recorded in the entry so a headless drain honors it.
#   drain [--device-id <id>] [--wait <seconds>] [--interval <seconds>]
#     Install + launch every queued build whose device is reachable. With
#     --wait, keep polling until the queue empties or the budget runs out.
#   list        Print queued, needs-auth, and failed entries.
#   retry --tag <tag>   Re-queue a needs-auth/ or failed/ entry for drain.
#   clear [--tag <tag>] [--failed]   Remove entries (all, one tag, or failed/).
#   default-device                   Print the resolved default iPhone id.
#   probe [--device-id <id>]         Exit 0 iff the (default) iPhone is reachable.
#
# Storage is persistent (NOT /tmp):
#   ${CMUX_IPHONE_QUEUE_DIR:-~/Library/Application Support/cmux-dev/iphone-install-queue}
#     pending/<slug>/cmux.app + meta.json     queued builds
#     needs-auth/<slug>/                      installed, but the iPhone auth gate
#                                             failed (app on the phone is NOT
#                                             signed in); kept for `retry`
#     failed/<slug>/                          builds whose install itself failed
#     logs/                                   drain + LaunchAgent logs
#     bin/                                    stable copy of this script for the LaunchAgent
#
# Default device id resolution (never hardcoded here):
#   1. CMUX_IPHONE_DEVICE_ID environment variable
#   2. first line of ${CMUX_CONFIG_DIR:-~/.config/cmux}/iphone-device-id
#
# Launch policy mirrors the reload scripts: the queued launch goes through the
# checkout's scripts/mobile-dev-launch.sh (auto sign-in + auto-pair via
# --ensure-mac, which also launches the same-tag Mac app and hard-fails as the
# iPhone auth gate when the app never reaches a signed-in + paired session). A
# failed signed launch never falls back to a plain launch; the entry moves to
# needs-auth/ with the error preserved, and the notification reports the TRUE
# state (installed but SIGN-IN FAILED) with the exact retry command. As a
# backstop against a launcher that lies with exit 0, the drain also requires a
# FRESH readiness receipt (the durable proof mobile-dev-launch writes only
# after the gate passes) before counting an entry as verified.
#
# This script and ios-device-process.sh are installed together as stable copies
# so the LaunchAgent remains independent of a pruned enqueuing worktree.
#
# Testing hooks: CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE=1 makes every device probe
# report unreachable (used by tests and for demonstrating the queue path while
# the phone is actually connected).
set -euo pipefail

QUEUE_DIR="${CMUX_IPHONE_QUEUE_DIR:-$HOME/Library/Application Support/cmux-dev/iphone-install-queue}"
CONFIG_DIR="${CMUX_CONFIG_DIR:-$HOME/.config/cmux}"
PENDING_DIR="$QUEUE_DIR/pending"
NEEDS_AUTH_DIR="$QUEUE_DIR/needs-auth"
FAILED_DIR="$QUEUE_DIR/failed"
LOGS_DIR="$QUEUE_DIR/logs"
LOCK_DIR="$QUEUE_DIR/.drain-lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_PROCESS_HELPER="$SCRIPT_DIR/ios-device-process.sh"
RECEIPT_DIR="${CMUX_READINESS_RECEIPT_DIR:-/tmp/cmux-ios-dogfood-readiness}"

# Mirrors cmux_attach__slug (scripts/lib/mobile-attach.sh) for RECEIPT file
# names only; tag->slug still comes from the signed app's bundle id.
slugify() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

err() { printf 'iphone-install-queue: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGS_DIR/drain.log" >&2 || true
}

usage() { sed -n '2,57p' "$0"; }

default_device_id() {
  if [[ -n "${CMUX_IPHONE_DEVICE_ID:-}" ]]; then
    printf '%s' "$CMUX_IPHONE_DEVICE_ID"
    return 0
  fi
  local f="$CONFIG_DIR/iphone-device-id"
  if [[ -f "$f" ]]; then
    head -n1 "$f" | tr -d '[:space:]'
    return 0
  fi
  printf ''
}

# Bundle id and slug come from the signed app itself so this script never
# re-implements the tag->slug transform (scripts/lib/mobile-attach.sh owns it).
app_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Info.plist" 2>/dev/null
}

# Reachability probe: the device counts as reachable when devicectl reports it
# paired + available (booted over USB, or a live localNetwork tunnel). Same
# availability rules as ios/scripts/reload.sh select_device.
device_reachable() {
  local want_id="$1"
  [[ "${CMUX_IPHONE_QUEUE_FORCE_UNREACHABLE:-0}" == "1" ]] && return 1
  [[ -n "$want_id" ]] || return 1
  WANT_ID="$want_id" /usr/bin/python3 -c '
import json, os, subprocess, tempfile

want = os.environ["WANT_ID"].strip().lower()
descriptor, output_path = tempfile.mkstemp(suffix=".json")
os.close(descriptor)
try:
    try:
        result = subprocess.run(
            [
                "xcrun", "devicectl", "list", "devices", "--timeout", "5",
                "--json-output", output_path,
            ],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(1)
    if result.returncode != 0:
        raise SystemExit(1)
    try:
        with open(output_path) as output:
            data = json.load(output)
    except (OSError, ValueError):
        raise SystemExit(1)
finally:
    try:
        os.unlink(output_path)
    except OSError:
        pass

for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if connection.get("pairingState") != "paired":
        continue
    ids = {
        str(device.get("identifier") or ""),
        str(hardware.get("udid") or ""),
        str(hardware.get("serialNumber") or ""),
        str(hardware.get("ecid") or ""),
    }
    if want not in {i.lower() for i in ids if i}:
        continue
    boot_state = str(properties.get("bootState") or "").lower()
    transport = str(connection.get("transportType") or "")
    tunnel_state = str(connection.get("tunnelState") or "")
    has_modern_status = bool(properties.get("developerModeStatus"))
    if boot_state == "booted" or (
        transport == "localNetwork"
        and tunnel_state != "unavailable"
        and has_modern_status
    ):
        raise SystemExit(0)
raise SystemExit(1)
'
}

meta_field() {
  META_PATH="$1" FIELD="$2" /usr/bin/python3 - <<'PY'
import json, os
try:
    with open(os.environ["META_PATH"]) as fh:
        meta = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(1)
value = meta.get(os.environ["FIELD"], "")
if isinstance(value, bool):
    print("1" if value else "0")
else:
    print(value)
PY
}

notify() {
  local title="$1" body="$2" cmux_bin
  cmux_bin="$(command -v cmux 2>/dev/null || true)"
  [[ -z "$cmux_bin" && -x "$HOME/.local/bin/cmux" ]] && cmux_bin="$HOME/.local/bin/cmux"
  [[ -n "$cmux_bin" ]] || { log "cmux CLI not found; skipping notification"; return 0; }
  "$cmux_bin" notify --title "$title" --body "$body" >/dev/null 2>&1 \
    || log "cmux notify failed (no running cmux?); continuing"
}

# Select the newest stable launcher when this queue script was installed into
# queue/bin. Source-checkout launchers remain a compatibility fallback for
# direct, non-installed use. Tests can inject an isolated launcher explicitly.
queue_mobile_launcher() {
  local checkout="$1" candidate
  for candidate in \
      "${CMUX_IPHONE_QUEUE_MOBILE_LAUNCHER:-}" \
      "$SCRIPT_DIR/mobile-dev-launch.sh" \
      "$checkout/scripts/mobile-dev-launch.sh" \
      "${CMUX_IPHONE_QUEUE_CHECKOUT:-}/scripts/mobile-dev-launch.sh"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Validate one immutable profile/account/file selection through the launcher's
# own credential resolver. Prints the normalized account, never the password.
queue_validate_auth_contract() {
  local launcher="$1" checkout="$2" profile="$3" expected="$4" credentials_file="$5"
  local output resolved_profile resolved_account
  output="$(
    cd "$checkout" \
      && CMUX_MOBILE_SOURCE_CHECKOUT="$checkout" "$launcher" \
        --check-auth-contract \
        --auth-profile "$profile" \
        --expected-account "$expected" \
        --credentials-file "$credentials_file"
  )" || return $?
  resolved_profile="$(printf '%s\n' "$output" | awk -F= '$1 == "CMUX_DEV_AUTH_PROFILE" { print substr($0, index($0, "=") + 1); exit }')"
  resolved_account="$(printf '%s\n' "$output" | awk -F= '$1 == "CMUX_DEV_AUTH_ACCOUNT" { print substr($0, index($0, "=") + 1); exit }')"
  [[ "$resolved_profile" == "$profile" && -n "$resolved_account" ]] || {
    err "launcher does not support the required iOS auth contract (profile/account proof missing)"
    return 2
  }
  printf '%s' "$resolved_account"
}

cmd_enqueue() {
  local tag="" app="" device_id="" checkout="" no_attach=0 no_sign_in=0 no_setup=0 launch=1
  local allow_unauthenticated_requested=0
  local auth_profile="" expected_account="" credentials_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --app) app="${2:-}"; shift 2 ;;
      --device-id) device_id="${2:-}"; shift 2 ;;
      --checkout) checkout="${2:-}"; shift 2 ;;
      --auth-profile) auth_profile="${2:-}"; shift 2 ;;
      --expected-account) expected_account="${2:-}"; shift 2 ;;
      --credentials-file) credentials_file="${2:-}"; shift 2 ;;
      --no-attach) no_attach=1; shift ;;
      --no-sign-in) no_sign_in=1; shift ;;
      --no-setup) no_setup=1; shift ;;
      --no-launch) launch=0; shift ;;
      --allow-unauthenticated) allow_unauthenticated_requested=1; shift ;;
      *) die "enqueue: unknown argument: $1" ;;
    esac
  done
  [[ -n "$tag" ]] || die "enqueue: --tag is required"
  [[ -n "$app" && -d "$app" ]] || die "enqueue: --app must point at a signed .app directory"
  # The opt-out flags yield an install the iPhone auth gate cannot verify
  # (installed-but-signed-out is a failed install). Require the human-only
  # allowance NOW and record it in the entry, because the drain runs headless
  # under a LaunchAgent where an ambient env var cannot express human intent.
  local allow_unauthenticated=0
  if [[ "$no_attach" -eq 1 || "$no_sign_in" -eq 1 || "$no_setup" -eq 1 ]]; then
    if [[ "${CMUX_ALLOW_UNAUTHENTICATED_INSTALL:-0}" != "1" ]]; then
      die "enqueue: --no-attach/--no-sign-in/--no-setup queue an unauthenticated install; humans only: rerun with CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1 (agents never set it)"
    fi
    allow_unauthenticated=1
  elif [[ "$allow_unauthenticated_requested" -eq 1 ]]; then
    die "enqueue: --allow-unauthenticated requires --no-attach, --no-sign-in, or --no-setup"
  fi
  local bundle_id
  bundle_id="$(app_bundle_id "$app")"
  [[ -n "$bundle_id" ]] || die "enqueue: could not read CFBundleIdentifier from $app"
  case "$bundle_id" in
    dev.cmux.ios.*) ;;
    *) die "enqueue: refusing non-dev bundle id '$bundle_id' (expected dev.cmux.ios.<slug>)" ;;
  esac
  local slug="${bundle_id#dev.cmux.ios.}"
  [[ -n "$device_id" ]] || device_id="$(default_device_id)"
  [[ -n "$device_id" ]] || die "enqueue: no device id (pass --device-id, set CMUX_IPHONE_DEVICE_ID, or write $CONFIG_DIR/iphone-device-id)"
  if [[ -z "$checkout" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    checkout="$(cd "$script_dir/.." && pwd)"
  fi

  if [[ "$allow_unauthenticated" -eq 0 ]]; then
    # This queue only mutates the user's physical iPhone. The shared agent
    # profile is simulator-only, so reject it before copying or queueing an
    # app that could later be installed on the phone.
    [[ "$auth_profile" == "personal" ]] \
      || die "enqueue: physical iPhone authenticated installs require --auth-profile personal (agent is simulator-only)"
    [[ -n "$expected_account" ]] \
      || die "enqueue: authenticated installs require --expected-account"
    [[ -n "$credentials_file" ]] \
      || die "enqueue: authenticated installs require --credentials-file"
    local contract_launcher
    contract_launcher="$(queue_mobile_launcher "$checkout")" \
      || die "enqueue: no contract-capable mobile-dev-launch.sh found"
    expected_account="$(queue_validate_auth_contract \
      "$contract_launcher" "$checkout" "$auth_profile" "$expected_account" "$credentials_file")" \
      || die "enqueue: auth contract validation failed before queueing"
  fi

  mkdir -p "$PENDING_DIR" "$LOGS_DIR"
  local entry="$PENDING_DIR/$slug"
  local staging="$PENDING_DIR/.staging-$slug.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  ditto "$app" "$staging/cmux.app"
  # meta.json is written LAST: drain skips entries without it, so a scan can
  # never install a half-copied app.
  TAG="$tag" SLUG="$slug" BUNDLE_ID="$bundle_id" DEVICE_ID="$device_id" \
  CHECKOUT="$checkout" NO_ATTACH="$no_attach" NO_SIGN_IN="$no_sign_in" \
  NO_SETUP="$no_setup" LAUNCH="$launch" META="$staging/meta.json" \
  ALLOW_UNAUTHENTICATED="$allow_unauthenticated" \
  AUTH_PROFILE="$auth_profile" EXPECTED_ACCOUNT="$expected_account" \
  CREDENTIALS_FILE="$credentials_file" \
  /usr/bin/python3 - <<'PY'
import json, os, time
meta = {
    "tag": os.environ["TAG"],
    "slug": os.environ["SLUG"],
    "bundle_id": os.environ["BUNDLE_ID"],
    "device_id": os.environ["DEVICE_ID"],
    "checkout": os.environ["CHECKOUT"],
    "no_attach": os.environ["NO_ATTACH"] == "1",
    "no_sign_in": os.environ["NO_SIGN_IN"] == "1",
    "no_setup": os.environ["NO_SETUP"] == "1",
    "launch": os.environ["LAUNCH"] == "1",
    "allow_unauthenticated": os.environ["ALLOW_UNAUTHENTICATED"] == "1",
    "auth_profile": os.environ["AUTH_PROFILE"],
    "expected_account": os.environ["EXPECTED_ACCOUNT"],
    "credentials_file": os.environ["CREDENTIALS_FILE"],
    "enqueued_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
}
with open(os.environ["META"], "w") as fh:
    json.dump(meta, fh, indent=2)
PY
  rm -rf "$entry"
  mv "$staging" "$entry"
  log "enqueued tag=$tag bundle=$bundle_id device=$device_id profile=${auth_profile:-none} account=${expected_account:-none}"
  cat <<EOF
==> iPhone build QUEUED (device unreachable or deferred install)
Tag:       $tag
Bundle id: $bundle_id
Device:    $device_id
Queue:     $entry
It will auto-install and launch when the iPhone reconnects (LaunchAgent
dev.cmux.iphone-install-queue). Manual drain: scripts/iphone-install-queue.sh drain
EOF
}

pending_slugs() {
  [[ -d "$PENDING_DIR" ]] || return 0
  local d
  for d in "$PENDING_DIR"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}meta.json" ]] || continue
    basename "$d"
  done
}

fail_entry() {
  local slug="$1" reason="$2"
  mkdir -p "$FAILED_DIR"
  rm -rf "${FAILED_DIR:?}/$slug"
  printf '%s\n' "$reason" > "$PENDING_DIR/$slug/error.txt" 2>/dev/null || true
  mv "$PENDING_DIR/$slug" "$FAILED_DIR/$slug"
  log "FAILED $slug: $reason"
}

# The app IS installed but the iPhone auth gate failed (not signed in/paired).
# Keep the entry (app + meta + reason) in needs-auth/ so `retry` can re-queue
# it once the blocker (credentials, web API, locked phone) is fixed; never
# silently drop an unauthenticated install.
park_needs_auth() {
  local slug="$1" reason="$2"
  mkdir -p "$NEEDS_AUTH_DIR"
  rm -rf "${NEEDS_AUTH_DIR:?}/$slug"
  printf '%s\n' "$reason" > "$PENDING_DIR/$slug/error.txt" 2>/dev/null || true
  mv "$PENDING_DIR/$slug" "$NEEDS_AUTH_DIR/$slug"
  log "NEEDS-AUTH $slug: $reason"
}

# Install + launch one entry. Authenticated staged entries (launch=0) are
# promoted to the signed launcher after install, because --no-launch only
# separates the reachable build/install step from mobile-dev-launch. Returns 0
# on verified success, 1 on hard failure
# (entry moved to failed/), 2 when the device is unreachable (entry stays
# pending), 3 when the app installed but the auth gate failed (entry moved to
# needs-auth/), 4 on an install that succeeded with auth verification opted
# out at enqueue time (human-authorized; entry removed).
#
# Re-enqueue race: a reload may replace this entry while the drain is mid-
# install. Every terminal action (remove on success, move to failed/ or
# needs-auth/) first re-reads enqueued_at; when it changed, the newer build is
# left queued for the next drain pass instead of being silently deleted.
drain_entry() {
  local slug="$1" override_device="$2"
  local entry="$PENDING_DIR/$slug"
  local meta="$entry/meta.json"
  local app="$entry/cmux.app"
  local tag device_id bundle_id checkout no_attach no_sign_in no_setup launch
  local allow_unauthenticated auth_profile expected_account credentials_file
  local stamp
  stamp="$(meta_field "$meta" enqueued_at 2>/dev/null || true)"
  entry_unchanged() {
    [[ "$(meta_field "$meta" enqueued_at 2>/dev/null || true)" == "$stamp" ]]
  }
  finish_failed() {
    if entry_unchanged; then
      fail_entry "$slug" "$1"
      return 1
    fi
    log "entry $slug was replaced mid-drain; leaving the newer build queued"
    return 2
  }
  finish_needs_auth() {
    if entry_unchanged; then
      park_needs_auth "$slug" "$1"
      return 3
    fi
    log "entry $slug was replaced mid-drain; leaving the newer build queued"
    return 2
  }
  finish_installed() {
    local rc="${1:-0}"
    if entry_unchanged; then
      rm -rf "$entry"
      return "$rc"
    fi
    log "entry $slug was replaced mid-drain; leaving the newer build queued"
    return 2
  }
  tag="$(meta_field "$meta" tag)" || { finish_failed "unreadable meta.json"; return $?; }
  bundle_id="$(meta_field "$meta" bundle_id)"
  device_id="${override_device:-$(meta_field "$meta" device_id)}"
  [[ -n "$device_id" ]] || device_id="$(default_device_id)"
  checkout="$(meta_field "$meta" checkout)"
  no_attach="$(meta_field "$meta" no_attach)"
  no_sign_in="$(meta_field "$meta" no_sign_in)"
  no_setup="$(meta_field "$meta" no_setup)"
  launch="$(meta_field "$meta" launch)"
  allow_unauthenticated="$(meta_field "$meta" allow_unauthenticated 2>/dev/null || true)"
  auth_profile="$(meta_field "$meta" auth_profile 2>/dev/null || true)"
  expected_account="$(meta_field "$meta" expected_account 2>/dev/null || true)"
  credentials_file="$(meta_field "$meta" credentials_file 2>/dev/null || true)"

  if [[ -z "$device_id" ]]; then
    finish_failed "no device id in meta and no default configured"
    return $?
  fi

  local mdl="" source_checkout="$checkout"
  if [[ "$allow_unauthenticated" != "1" ]]; then
    # Entries written before the identity metadata was introduced were
    # authenticated by the old launcher but have no immutable profile/account
    # contract. Keep them pending until a human re-enqueues the build through
    # the current personal flow; never discard an offline build or guess an
    # account during a headless drain.
    if [[ -z "$auth_profile" && -z "$expected_account" && -z "$credentials_file" ]]; then
      local legacy_note="$entry/upgrade-needed.txt"
      if [[ ! -f "$legacy_note" ]]; then
        printf '%s\n' \
          "Legacy queue entry lacks the personal auth contract." \
          "Re-enqueue this build with ios/scripts/reload.sh or the current" \
          "scripts/iphone-install-queue.sh enqueue flow after personal setup." \
          >"$legacy_note"
      fi
      log "legacy entry $slug lacks auth contract; keeping it pending for explicit personal re-enqueue"
      return 2
    fi
    # Revalidate the physical-device profile from immutable metadata before
    # any reachability probe, process termination, or install mutation. This
    # also quarantines entries written by older queue versions that accepted
    # the simulator-only agent profile.
    [[ "$auth_profile" == "personal" ]] || {
      finish_failed "queued physical iPhone install requires auth-profile personal (agent is simulator-only)"
      return $?
    }
    [[ -n "$expected_account" && -n "$credentials_file" ]] || {
      finish_failed "queued entry lacks expected-account or credentials-file identity metadata"
      return $?
    }
    if [[ ! -d "$source_checkout" ]]; then
      source_checkout="${CMUX_IPHONE_QUEUE_CHECKOUT:-}"
    fi
    [[ -d "$source_checkout" ]] || {
      finish_failed "enqueuing checkout was pruned and no fallback source checkout is configured"
      return $?
    }
    mdl="$(queue_mobile_launcher "$source_checkout")" || {
      finish_failed "no contract-capable mobile-dev-launch.sh found"
      return $?
    }
    if ! queue_validate_auth_contract \
        "$mdl" "$source_checkout" "$auth_profile" "$expected_account" "$credentials_file" \
        >/dev/null; then
      finish_failed "auth contract changed since enqueue; refusing device mutation"
      return $?
    fi
  fi
  if ! device_reachable "$device_id"; then
    log "device $device_id unreachable; keeping $slug queued"
    return 2
  fi

  if [[ ! -x "$DEVICE_PROCESS_HELPER" ]]; then
    finish_failed "missing executable process helper: $DEVICE_PROCESS_HELPER"
    return $?
  fi
  if ! "$DEVICE_PROCESS_HELPER" terminate-installed \
      --device-id "$device_id" \
      --bundle-id "$bundle_id" >>"$LOGS_DIR/drain.log" 2>&1; then
    finish_failed "existing app process did not terminate before install (see logs/drain.log)"
    return $?
  fi

  log "installing $bundle_id (tag $tag) on $device_id"
  # CMUX_SANCTIONED_IPHONE_INSTALL: see ios/scripts/reload.sh — lets the
  # local-build-guards devicectl interceptor distinguish this sanctioned flow
  # from a raw agent install. Inert without the guards.
  if ! CMUX_SANCTIONED_IPHONE_INSTALL=1 \
      xcrun devicectl device install app --device "$device_id" "$app" \
      >>"$LOGS_DIR/drain.log" 2>&1; then
    finish_failed "devicectl install failed (see logs/drain.log)"
    return $?
  fi

  if [[ "$launch" != "1" && "$allow_unauthenticated" != "1" ]]; then
    # A staged authenticated build must finish through the same launcher and
    # readiness receipt as an ordinary queue entry once the phone reconnects.
    # Treating it as install-only would leave the app signed out forever.
    log "installed $bundle_id (staged authenticated entry); continuing with signed launch"
    launch=1
  fi

  if [[ "$launch" != "1" ]]; then
    log "installed $bundle_id (launch disabled at enqueue; auth NOT verified)"
    finish_installed 4
    return $?
  fi

  if [[ "$no_setup" == "1" || "$no_sign_in" == "1" ]]; then
    if ! xcrun devicectl device process launch --terminate-existing \
        --device "$device_id" "$bundle_id" >>"$LOGS_DIR/drain.log" 2>&1; then
      finish_failed "plain launch failed (device locked?)"
      return $?
    fi
    log "installed + plain-launched $bundle_id (opt-out at enqueue; auth NOT verified)"
    finish_installed 4
    return $?
  fi

  # Signed launch through the stable installed launcher when available. The
  # source checkout is a separate input, so a stale or pruned feature worktree
  # cannot silently replace current auth policy.
  [[ -n "$mdl" ]] || mdl="$(queue_mobile_launcher "$source_checkout" || true)"
  if [[ -z "$mdl" ]]; then
    finish_needs_auth "no contract-capable mobile-dev-launch.sh found"
    return $?
  fi
  # Human-authorized unauthenticated entries predate the contract metadata and
  # may point at a pruned feature worktree. Derive the execution checkout from
  # the launcher selected by the stable fallback so `cd` and helper lookups do
  # not fail before the explicit plain launch can run.
  if [[ "$allow_unauthenticated" == "1" ]]; then
    source_checkout="$(cd "$(dirname "$mdl")/.." && pwd)"
  elif [[ ! -d "$source_checkout" ]]; then
    source_checkout="$(cd "$(dirname "$mdl")/.." && pwd)"
  fi
  [[ -d "$source_checkout" ]] || {
    finish_needs_auth "selected mobile-dev-launch.sh checkout is unavailable"
    return $?
  }
  local args=(--tag "$tag" --device --device-id "$device_id")
  # --ensure-mac launches the same-tag Mac app if its socket is down, so the
  # phone build is never left without its Mac counterpart. An entry whose
  # opt-out was human-authorized at enqueue time re-asserts that authorization
  # for the launcher (the LaunchAgent env cannot carry it).
  local mdl_env=()
  if [[ "$no_attach" == "1" ]]; then
    args+=(--no-attach)
    [[ "$allow_unauthenticated" == "1" ]] && mdl_env=(CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1)
  else
    args+=(--ensure-mac)
  fi
  if [[ "$allow_unauthenticated" != "1" ]]; then
    args+=(
      --auth-profile "$auth_profile"
      --expected-account "$expected_account"
      --credentials-file "$credentials_file"
    )
  fi
  local launch_log="$LOGS_DIR/launch-$slug.log"
  # Compute the expected readiness receipt and REMOVE any pre-existing one
  # before launching, so a leftover receipt from an earlier run can never
  # satisfy the freshness backstop (mtime comparisons have whole-second
  # resolution; existence-after-removal does not). If the stale receipt cannot
  # be cleared, fail closed: a verified claim must never rest on an old file.
  local receipt
  receipt="$RECEIPT_DIR/$(slugify "$tag")-$(slugify "$device_id").json"
  if [[ "$no_attach" != "1" && -e "$receipt" ]]; then
    rm -f "$receipt" 2>/dev/null || true
    if [[ -e "$receipt" ]]; then
      finish_failed "cannot clear stale readiness receipt $receipt; refusing a drain whose verification could not be trusted"
      return $?
    fi
  fi
  local mdl_rc=0
  ( cd "$source_checkout" && \
      env ${mdl_env[@]+"${mdl_env[@]}"} \
        CMUX_MOBILE_SOURCE_CHECKOUT="$source_checkout" \
        "$mdl" "${args[@]}" ) \
      >"$launch_log" 2>&1 || mdl_rc=$?
  cat "$launch_log" >>"$LOGS_DIR/drain.log" 2>/dev/null || true
  if [[ "$mdl_rc" -eq 75 ]]; then
    # Deferred delivery: the phone went offline or is locked. Not an auth
    # failure — keep the entry queued so the LaunchAgent's periodic drain
    # retries after unlock/reconnect.
    log "phone locked/offline during signed launch; keeping $slug queued"
    return 2
  fi
  if [[ "$mdl_rc" -ne 0 ]]; then
    # Policy: never degrade a failed signed setup to a plain launch. The app is
    # on the phone but NOT signed in; park it so retry is possible and the
    # notification can tell the truth.
    local reason
    reason="$(grep -E '^error:' "$launch_log" | head -n1 || true)"
    [[ -n "$reason" ]] || reason="signed launch (mobile-dev-launch.sh) failed; see logs/launch-$slug.log"
    finish_needs_auth "$reason"
    return $?
  fi

  if [[ "$no_attach" == "1" ]]; then
    log "installed + launched $bundle_id (no-attach opt-out; auth NOT verified)"
    finish_installed 4
    return $?
  fi

  # Backstop: the gate pass must be backed by a FRESH readiness receipt (the
  # secret-free proof mobile-dev-launch writes only after observing the
  # signed-in + paired mobile.rpc.ready event for this exact device). Any
  # pre-existing receipt was removed above, so existence means this launch.
  if [[ ! -f "$receipt" ]]; then
    finish_needs_auth "launcher exited 0 but left no fresh readiness receipt ($receipt); treat as NOT signed in"
    return $?
  fi

  log "installed + launched $bundle_id (tag $tag) on $device_id; auth gate PASS (receipt: $receipt)"
  finish_installed 0
  return $?
}

cmd_drain() {
  local override_device="" wait_seconds=0 interval=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id) override_device="${2:-}"; shift 2 ;;
      --wait) wait_seconds="${2:-0}"; shift 2 ;;
      --interval) interval="${2:-10}"; shift 2 ;;
      *) die "drain: unknown argument: $1" ;;
    esac
  done
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "drain: --wait must be a number of seconds"
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || die "drain: --interval must be a positive number of seconds"

  # Fast no-op when the queue is empty: no lock, no devicectl, near-zero cost,
  # so the LaunchAgent's periodic backstop is essentially free.
  [[ -n "$(pending_slugs)" ]] || exit 0

  mkdir -p "$QUEUE_DIR" "$LOGS_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      err "another drain is running (pid $holder); exiting"
      exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || { err "could not take drain lock"; exit 0; }
  fi
  printf '%s' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT

  local start now installed_tags="" unverified_tags="" needs_auth_slugs="" had_failure=0
  start="$(date +%s)"
  while :; do
    local slug rc remaining=0
    for slug in $(pending_slugs); do
      set +e
      drain_entry "$slug" "$override_device"
      rc=$?
      set -e
      case "$rc" in
        0) installed_tags="$installed_tags $slug" ;;
        1) had_failure=1 ;;
        2) remaining=1 ;;
        3) needs_auth_slugs="$needs_auth_slugs $slug" ;;
        4) unverified_tags="$unverified_tags $slug" ;;
      esac
    done
    [[ "$remaining" -eq 1 ]] || break
    now="$(date +%s)"
    if (( now - start >= wait_seconds )); then
      log "wait budget exhausted with builds still queued (device away); the LaunchAgent will retry"
      break
    fi
    sleep "$interval"
  done

  # The notification must report the TRUE post-install state: "installed" and
  # "signed in" are different claims, and only a fresh auth-gate pass earns the
  # second one.
  installed_tags="${installed_tags# }"
  unverified_tags="${unverified_tags# }"
  needs_auth_slugs="${needs_auth_slugs# }"
  if [[ -n "$installed_tags" ]]; then
    notify "iPhone install queue: installed $installed_tags" \
      "Auto-installed on the iPhone and VERIFIED signed in + paired (auth gate PASS): $installed_tags"
  fi
  if [[ -n "$unverified_tags" ]]; then
    notify "iPhone install queue: installed $unverified_tags (auth NOT verified)" \
      "Installed with a human-authorized auth opt-out; NOT verified signed in: $unverified_tags. Check with: scripts/verify-iphone-auth.sh --tag <tag>"
  fi
  local na_slug na_tag na_device na_reason
  for na_slug in $needs_auth_slugs; do
    na_tag="$(meta_field "$NEEDS_AUTH_DIR/$na_slug/meta.json" tag 2>/dev/null || echo "$na_slug")"
    na_device="$(meta_field "$NEEDS_AUTH_DIR/$na_slug/meta.json" device_id 2>/dev/null || true)"
    na_reason="$(head -n1 "$NEEDS_AUTH_DIR/$na_slug/error.txt" 2>/dev/null || echo 'no reason recorded')"
    notify "iPhone install queue: $na_tag installed but SIGN-IN FAILED" \
      "$na_reason — the app on the phone is NOT signed in. Entry kept in needs-auth. Retry the queued contract: scripts/iphone-install-queue.sh retry --tag $na_tag && scripts/iphone-install-queue.sh drain"
  done
  if [[ "$had_failure" -eq 1 ]]; then
    notify "iPhone install queue: install FAILED" \
      "A queued cmux iOS dev build failed to install/launch. See $FAILED_DIR and $LOGS_DIR/drain.log"
  fi
  [[ "$had_failure" -eq 0 && -z "$needs_auth_slugs" ]] || exit 1
  exit 0
}

cmd_list() {
  local found=0 d slug meta
  if [[ -d "$PENDING_DIR" ]]; then
    for d in "$PENDING_DIR"/*/; do
      [[ -d "$d" && -f "${d}meta.json" ]] || continue
      found=1
      slug="$(basename "$d")"
      meta="${d}meta.json"
      printf 'pending  %-20s tag=%s device=%s profile=%s account=%s enqueued=%s\n' \
        "$slug" "$(meta_field "$meta" tag)" "$(meta_field "$meta" device_id)" \
        "$(meta_field "$meta" auth_profile 2>/dev/null || true)" \
        "$(meta_field "$meta" expected_account 2>/dev/null || true)" \
        "$(meta_field "$meta" enqueued_at)"
    done
  fi
  if [[ -d "$NEEDS_AUTH_DIR" ]]; then
    for d in "$NEEDS_AUTH_DIR"/*/; do
      [[ -d "$d" ]] || continue
      found=1
      slug="$(basename "$d")"
      printf 'needs-auth %-18s %s\n' "$slug" "$(head -n1 "${d}error.txt" 2>/dev/null || echo '(no reason recorded)')"
    done
  fi
  if [[ -d "$FAILED_DIR" ]]; then
    for d in "$FAILED_DIR"/*/; do
      [[ -d "$d" ]] || continue
      found=1
      slug="$(basename "$d")"
      printf 'failed   %-20s %s\n' "$slug" "$(head -n1 "${d}error.txt" 2>/dev/null || echo '(no error recorded)')"
    done
  fi
  [[ "$found" -eq 1 ]] || echo "queue is empty"
}

# Move a needs-auth/ (or failed/) entry back to pending/ so the next drain
# retries it. The staged app and meta are reused as-is.
cmd_retry() {
  local tag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      *) die "retry: unknown argument: $1" ;;
    esac
  done
  [[ -n "$tag" ]] || die "retry: --tag is required"
  local d meta slug
  for d in "$NEEDS_AUTH_DIR"/*/ "$FAILED_DIR"/*/; do
    [[ -d "$d" ]] || continue
    meta="${d}meta.json"
    slug="$(basename "$d")"
    if [[ -f "$meta" && "$(meta_field "$meta" tag)" == "$tag" ]] || [[ "$slug" == "$tag" ]]; then
      mkdir -p "$PENDING_DIR"
      rm -rf "${PENDING_DIR:?}/$slug"
      rm -f "${d}error.txt"
      mv "$d" "$PENDING_DIR/$slug"
      log "re-queued $slug for drain"
      echo "re-queued $slug (drain now: scripts/iphone-install-queue.sh drain)"
      return 0
    fi
  done
  die "retry: no needs-auth or failed entry for tag $tag"
}

cmd_clear() {
  local tag="" failed_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --failed) failed_only=1; shift ;;
      *) die "clear: unknown argument: $1" ;;
    esac
  done
  if [[ -n "$tag" ]]; then
    local d meta cleared=0
    for d in "$PENDING_DIR"/*/ "$NEEDS_AUTH_DIR"/*/ "$FAILED_DIR"/*/; do
      [[ -d "$d" ]] || continue
      meta="${d}meta.json"
      if [[ -f "$meta" && "$(meta_field "$meta" tag)" == "$tag" ]] \
          || [[ "$(basename "$d")" == "$tag" ]]; then
        rm -rf "$d"
        cleared=1
        echo "cleared $(basename "$d")"
      fi
    done
    [[ "$cleared" -eq 1 ]] || echo "no entry for tag $tag"
    return 0
  fi
  if [[ "$failed_only" -eq 1 ]]; then
    rm -rf "${FAILED_DIR:?}"/* 2>/dev/null || true
    echo "cleared failed entries"
    return 0
  fi
  rm -rf "${PENDING_DIR:?}"/* "${NEEDS_AUTH_DIR:?}"/* "${FAILED_DIR:?}"/* 2>/dev/null || true
  echo "cleared all queue entries"
}

cmd_probe() {
  local device_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-id) device_id="${2:-}"; shift 2 ;;
      *) die "probe: unknown argument: $1" ;;
    esac
  done
  [[ -n "$device_id" ]] || device_id="$(default_device_id)"
  [[ -n "$device_id" ]] || die "probe: no device id (pass --device-id or configure a default)"
  device_reachable "$device_id"
}

verb="${1:-}"
[[ -n "$verb" ]] || { usage >&2; exit 2; }
shift
case "$verb" in
  enqueue) cmd_enqueue "$@" ;;
  drain) cmd_drain "$@" ;;
  list) cmd_list "$@" ;;
  retry) cmd_retry "$@" ;;
  clear) cmd_clear "$@" ;;
  default-device) default_device_id; echo ;;
  probe) cmd_probe "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown verb: $verb (expected enqueue|drain|list|retry|clear|default-device|probe)" ;;
esac
