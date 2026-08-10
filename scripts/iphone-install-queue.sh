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
#           [--no-attach] [--no-sign-in] [--no-setup] [--no-launch]
#     Copy the signed app into the persistent queue (one slot per tag; a
#     re-enqueue of the same tag replaces the older build).
#   drain [--device-id <id>] [--wait <seconds>] [--interval <seconds>]
#     Install + launch every queued build whose device is reachable. With
#     --wait, keep polling until the queue empties or the budget runs out.
#   list        Print queued and failed entries.
#   clear [--tag <tag>] [--failed]   Remove entries (all, one tag, or failed/).
#   default-device                   Print the resolved default iPhone id.
#   probe [--device-id <id>]         Exit 0 iff the (default) iPhone is reachable.
#
# Storage is persistent (NOT /tmp):
#   ${CMUX_IPHONE_QUEUE_DIR:-~/Library/Application Support/cmux-dev/iphone-install-queue}
#     pending/<slug>/cmux.app + meta.json     queued builds
#     failed/<slug>/                          builds whose install/launch failed
#     logs/                                   drain + LaunchAgent logs
#     bin/                                    stable copy of this script for the LaunchAgent
#
# Default device id resolution (never hardcoded here):
#   1. CMUX_IPHONE_DEVICE_ID environment variable
#   2. first line of ${CMUX_CONFIG_DIR:-~/.config/cmux}/iphone-device-id
#
# Launch policy mirrors the reload scripts: the queued launch goes through the
# checkout's scripts/mobile-dev-launch.sh (auto sign-in + auto-pair via
# --ensure-mac, which also launches the same-tag Mac app). A failed signed
# launch never falls back to a plain launch; the entry moves to failed/ with
# the error preserved.
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
FAILED_DIR="$QUEUE_DIR/failed"
LOGS_DIR="$QUEUE_DIR/logs"
LOCK_DIR="$QUEUE_DIR/.drain-lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_PROCESS_HELPER="$SCRIPT_DIR/ios-device-process.sh"

err() { printf 'iphone-install-queue: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGS_DIR/drain.log" >&2 || true
}

usage() { sed -n '2,46p' "$0"; }

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
  local out
  out="$(WANT_ID="$want_id" /usr/bin/python3 - <<'PY'
import json, os, subprocess, sys, tempfile

want = os.environ["WANT_ID"].strip().lower()
with tempfile.NamedTemporaryFile() as output:
    result = subprocess.run(
        ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        print("no"); raise SystemExit(0)
    output.seek(0)
    try:
        data = json.load(output)
    except ValueError:
        print("no"); raise SystemExit(0)

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
        print("yes"); raise SystemExit(0)
print("no")
PY
)" || return 1
  [[ "$out" == "yes" ]]
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

cmd_enqueue() {
  local tag="" app="" device_id="" checkout="" no_attach=0 no_sign_in=0 no_setup=0 launch=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --app) app="${2:-}"; shift 2 ;;
      --device-id) device_id="${2:-}"; shift 2 ;;
      --checkout) checkout="${2:-}"; shift 2 ;;
      --no-attach) no_attach=1; shift ;;
      --no-sign-in) no_sign_in=1; shift ;;
      --no-setup) no_setup=1; shift ;;
      --no-launch) launch=0; shift ;;
      *) die "enqueue: unknown argument: $1" ;;
    esac
  done
  [[ -n "$tag" ]] || die "enqueue: --tag is required"
  [[ -n "$app" && -d "$app" ]] || die "enqueue: --app must point at a signed .app directory"
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
    "enqueued_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
}
with open(os.environ["META"], "w") as fh:
    json.dump(meta, fh, indent=2)
PY
  rm -rf "$entry"
  mv "$staging" "$entry"
  log "enqueued tag=$tag bundle=$bundle_id device=$device_id"
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

# Install + launch one entry. Returns 0 on success, 1 on hard failure (entry is
# moved to failed/), 2 when the device is unreachable (entry stays pending).
#
# Re-enqueue race: a reload may replace this entry while the drain is mid-
# install. Every terminal action (remove on success, move to failed/) first
# re-reads enqueued_at; when it changed, the newer build is left queued for the
# next drain pass instead of being silently deleted or failed.
drain_entry() {
  local slug="$1" override_device="$2"
  local entry="$PENDING_DIR/$slug"
  local meta="$entry/meta.json"
  local app="$entry/cmux.app"
  local tag device_id bundle_id checkout no_attach no_sign_in no_setup launch
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
  finish_installed() {
    if entry_unchanged; then
      rm -rf "$entry"
      return 0
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

  if [[ -z "$device_id" ]]; then
    finish_failed "no device id in meta and no default configured"
    return $?
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
  if ! xcrun devicectl device install app --device "$device_id" "$app" \
      >>"$LOGS_DIR/drain.log" 2>&1; then
    finish_failed "devicectl install failed (see logs/drain.log)"
    return $?
  fi

  if [[ "$launch" != "1" ]]; then
    log "installed $bundle_id (launch disabled at enqueue)"
    finish_installed
    return $?
  fi

  if [[ "$no_setup" == "1" || "$no_sign_in" == "1" ]]; then
    if ! xcrun devicectl device process launch --terminate-existing \
        --device "$device_id" "$bundle_id" >>"$LOGS_DIR/drain.log" 2>&1; then
      finish_failed "plain launch failed (device locked?)"
      return $?
    fi
    finish_installed
    return $?
  fi

  # Signed launch through the checkout's mobile-dev-launch.sh (auto sign-in +
  # auto-pair). Checkout fallback order: the enqueuing checkout, then the
  # LaunchAgent-baked checkout, then this script's own repo root.
  local mdl="" candidate
  for candidate in "$checkout" "${CMUX_IPHONE_QUEUE_CHECKOUT:-}" "$SCRIPT_DIR/.."; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate/scripts/mobile-dev-launch.sh" ]]; then
      mdl="$candidate/scripts/mobile-dev-launch.sh"
      checkout="$candidate"
      break
    fi
  done
  if [[ -z "$mdl" ]]; then
    finish_failed "no checkout with scripts/mobile-dev-launch.sh found (enqueuing worktree pruned? set CMUX_IPHONE_QUEUE_CHECKOUT)"
    return $?
  fi
  local args=(--tag "$tag" --device --device-id "$device_id")
  # --ensure-mac launches the same-tag Mac app if its socket is down, so the
  # phone build is never left without its Mac counterpart.
  [[ "$no_attach" == "1" ]] || args+=(--ensure-mac)
  if ! ( cd "$checkout" && "$mdl" "${args[@]}" ) >>"$LOGS_DIR/drain.log" 2>&1; then
    # Policy: never degrade a failed signed setup to a plain launch.
    finish_failed "signed launch (mobile-dev-launch.sh) failed; see logs/drain.log"
    return $?
  fi
  log "installed + launched $bundle_id (tag $tag) on $device_id"
  finish_installed
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

  local start now installed_tags="" had_failure=0
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

  installed_tags="${installed_tags# }"
  if [[ -n "$installed_tags" ]]; then
    notify "iPhone install queue: installed $installed_tags" \
      "Queued cmux iOS dev build(s) auto-installed and launched on the iPhone after it reconnected: $installed_tags"
  fi
  if [[ "$had_failure" -eq 1 ]]; then
    notify "iPhone install queue: install FAILED" \
      "A queued cmux iOS dev build failed to install/launch. See $FAILED_DIR and $LOGS_DIR/drain.log"
    exit 1
  fi
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
      printf 'pending  %-20s tag=%s device=%s enqueued=%s\n' \
        "$slug" "$(meta_field "$meta" tag)" "$(meta_field "$meta" device_id)" \
        "$(meta_field "$meta" enqueued_at)"
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
    for d in "$PENDING_DIR"/*/ "$FAILED_DIR"/*/; do
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
  rm -rf "${PENDING_DIR:?}"/* "${FAILED_DIR:?}"/* 2>/dev/null || true
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
  clear) cmd_clear "$@" ;;
  default-device) default_device_id; echo ;;
  probe) cmd_probe "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown verb: $verb (expected enqueue|drain|list|clear|default-device|probe)" ;;
esac
