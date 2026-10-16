#!/bin/bash
# App Store screenshot pipeline for cmux iOS.
#
# The default `capture` command is deterministic and uses the hosted
# SnapshotUITests fixture lane. `capture-real` drives a signed-in, paired
# simulator against live Mac workspaces and marks those files `Device Real-...`.
# Use `post --capture-source real` to make accidental fixture fallback
# impossible when producing a real-content listing refresh.
#
# Capture runs on hosted CI (ios-screenshots.yml), NEVER as a local
# `xcodebuild test` (repo policy: the cmux test host must not launch on a dev
# Mac). Everything else (post-processing, framing, verification, upload
# staging, the lock-screen shot) runs locally with simctl/ImageMagick.
#
# Usage:
#   appstore-shots.sh asc-snapshot           # download the live ASC set for reference
#   appstore-shots.sh capture [--ref REF]    # dispatch CI capture + download raws
#   appstore-shots.sh capture-real --udid UDID [--class iphone|ipad]
#                                             # capture live paired workspaces
#   appstore-shots.sh lockshot --app PATH    # lock-screen inline-reply shot (05)
#   appstore-shots.sh post [--capture-source real|fixture]
#                                             # stage final/<DISPLAY_TYPE>/ at ASC dims
#   appstore-shots.sh verify                 # check staged set against the plan
#   appstore-shots.sh upload --confirm       # upload staged set via asc CLI
#
# Work dir: ios/fastlane/appstore-shots-work/ (gitignored)
#   captures/<lang>/<Device>-<Shot>.png   raw CI captures
#   lockshot/05-LockReply.png             lock-screen shot
#   final/<DISPLAY_TYPE>/NN-<slug>.png    exact ASC-size staged set
#   asc-live/                             downloaded live listing snapshot
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(dirname "$HERE")"
WORK="$IOS_DIR/fastlane/appstore-shots-work"
PLAN="$IOS_DIR/fastlane/appstore-shots-plan.json"
REPO="${APPSTORE_SHOTS_REPO:-manaflow-ai/cmux}"
WORKFLOW="ios-screenshots.yml"
APP_ID="$(python3 -c "import json;print(json.load(open('$PLAN'))['app_id'])")"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

# Resolves the version localization whose locale matches the plan's locale
# (never data[0]: a multi-locale listing can order another locale first).
resolve_localization() {
  local version_id
  version_id="$(asc versions list --app "$APP_ID" --output json \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data'][0]['id'])")"
  asc localizations list --version "$version_id" --output json \
    | python3 -c "
import json, sys
plan = json.load(open('$PLAN'))
locale = plan.get('locale', 'en-US')
data = json.load(sys.stdin)['data']
hits = [l['id'] for l in data if l['attributes'].get('locale') == locale]
if not hits:
    sys.exit(f'no {locale} localization on the editable version '
             f'(found: {[l[\"attributes\"].get(\"locale\") for l in data]})')
print(hits[0])
"
}

cmd_asc_snapshot() {
  need asc
  mkdir -p "$WORK/asc-live"
  local loc_id
  loc_id="$(resolve_localization)"
  asc screenshots list --version-localization "$loc_id" --output json \
    > "$WORK/asc-live/manifest.json"
  asc screenshots download --version-localization "$loc_id" \
    --output-dir "$WORK/asc-live" --overwrite --format json >/dev/null
  echo "live ASC set snapshotted to $WORK/asc-live"
}

cmd_capture() {
  need gh
  local ref="HEAD" languages="en-US,de-DE,fr-FR,ar-SA,es-ES,zh-Hant,zh-Hans,ko,ja"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ref) ref="$2"; shift 2 ;;
      --languages) languages="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ "$ref" = "HEAD" ]; then
    ref="$(git -C "$IOS_DIR" rev-parse --abbrev-ref HEAD)"
  fi
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "--ref must be a branch (run resolution matches by branch name, not SHA)" >&2
    exit 1
  fi
  local request_id="cmux-shots-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  echo "dispatching $WORKFLOW on $REPO ref=$ref languages=$languages request=$request_id"
  gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$ref" \
    -f languages="$languages" -f request_id="$request_id"
  # `gh workflow run` returns before GitHub registers the run. Poll for the
  # uniquely named run instead of sleeping and taking whichever branch run is
  # newest, which can select another concurrent dispatch.
  local run_id="" waited=0
  while [ "$waited" -lt 60 ]; do
    run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$ref" \
      --event workflow_dispatch --limit 20 --json databaseId,displayTitle,createdAt \
      | REQUEST_ID="$request_id" python3 -c '
import json, os, sys
runs = [r for r in json.load(sys.stdin)
        if os.environ["REQUEST_ID"] in (r.get("displayTitle") or "")]
print(max(runs, key=lambda r: r.get("createdAt", ""))["databaseId"] if runs else "")
')"
    [ -n "$run_id" ] && break
    sleep 2
    waited=$((waited + 2))
  done
  [ -n "$run_id" ] || { echo "could not resolve dispatched run" >&2; exit 1; }
  echo "watching run $run_id (https://github.com/$REPO/actions/runs/$run_id)"
  gh run watch --repo "$REPO" "$run_id" --exit-status || {
    echo "capture run failed; logs: gh run view --repo $REPO $run_id --log-failed" >&2
    exit 1
  }
  rm -rf "$WORK/captures"
  mkdir -p "$WORK/captures"
  gh run download --repo "$REPO" "$run_id" -n ios-appstore-raw-captures -D "$WORK/captures"
  echo "raw captures in $WORK/captures:"
  find "$WORK/captures" -name '*.png' | sort
}

cmd_capture_real() {
  need xcrun; need axe; need idb
  [ -x "$HERE/appstore-shots-real.sh" ] || {
    echo "missing executable real capture driver: $HERE/appstore-shots-real.sh" >&2
    exit 1
  }
  "$HERE/appstore-shots-real.sh" "$@"
}

# Lock-screen inline-reply shot: launches the app with the reply-notification
# fixture (grants authorization, registers the reply category, schedules the
# notification with a 6s fuse), locks the simulator so the notification lands
# on the lock screen, long-presses it, opens the reply field, types the reply,
# and captures. Requires a DEBUG .app built from a revision that includes the
# "reply" mode of ScreenshotNotificationPresenter.
cmd_lockshot() {
  need xcrun; need axe; need idb
  local app="" udid="" bundle_id="dev.cmux.ios" sim_name="cmux-shots-lockreply"
  local reply_text="Looks great, merge it and start the deploy"
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --udid) udid="$2"; shift 2 ;;
      --bundle-id) bundle_id="$2"; shift 2 ;;
      --reply-text) reply_text="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl list devices --json | python3 -c "
import json, sys
data = json.load(sys.stdin)['devices']
for runtime, devices in data.items():
    for d in devices:
        if d['name'] == '$sim_name':
            print(d['udid']); sys.exit()
")"
    if [ -z "$udid" ]; then
      local devtype
      devtype="$(xcrun simctl list devicetypes | grep -oE 'iPhone [0-9]+ Pro Max \(com[^)]*\)' \
        | tail -1 | grep -oE 'com[^)]*')"
      [ -n "$devtype" ] || devtype="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
      udid="$(xcrun simctl create "$sim_name" "$devtype")"
      echo "created simulator $sim_name ($udid)"
    fi
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid"
  # ASC's current inline-reply reference uses the light SpringBoard card and
  # charging status glyph. Keep the system fixture in that appearance even
  # when the paired app's terminal screenshots are dark.
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
    --batteryState charging --batteryLevel 100
  if [ -n "$app" ]; then
    xcrun simctl install "$udid" "$app"
  fi
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true

  echo "launching $bundle_id with the reply-notification fixture"
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA=1 \
  SIMCTL_CHILD_CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1 \
  SIMCTL_CHILD_CMUX_UITEST_NOTIFICATION_BANNER=reply \
    xcrun simctl launch "$udid" "$bundle_id"
  sleep 2
  # Approve the notification-authorization alert if present (fresh installs).
  axe tap --label "Allow" --udid "$udid" 2>/dev/null || true
  # Lock before the 6s fuse fires so the notification lands on the lock screen.
  sleep 1
  idb ui button --udid "$udid" LOCK
  echo "locked; waiting for the scheduled notification"
  sleep 6

  # Long-press the lock-screen notification to expand it, then open the reply
  # field. Coordinates are resolved from the accessibility tree when possible.
  local geometry cx cy
  geometry="$(axe describe-ui --udid "$udid" 2>/dev/null | python3 -c "
import json, sys
try:
    tree = json.load(sys.stdin)
except Exception:
    sys.exit(1)
def walk(node):
    yield node
    for child in node.get('children') or []:
        yield from walk(child)
best = None
for root in tree:
    for node in walk(root):
        label = (node.get('AXLabel') or '')
        if 'finished in workspace' in label or 'cmux agent' in label:
            f = node['frame']
            best = (f['x'] + f['width'] / 2, f['y'] + f['height'] / 2)
if best:
    print(f'{best[0]} {best[1]}')
" )" || geometry=""
  if [ -n "$geometry" ]; then
    cx="${geometry%% *}"; cy="${geometry##* }"
  else
    # Fallback: lock-screen notifications stack in the lower third (points,
    # iPhone Pro Max class).
    cx=220; cy=680
  fi
  echo "long-pressing notification at $cx,$cy"
  axe touch -x "$cx" -y "$cy" --down --udid "$udid"
  sleep 1
  axe touch -x "$cx" -y "$cy" --up --udid "$udid"
  sleep 1.5
  axe tap --label "Reply" --udid "$udid" 2>/dev/null || true
  sleep 1.5
  axe type "$reply_text" --udid "$udid"
  sleep 1

  mkdir -p "$WORK/lockshot"
  xcrun simctl io "$udid" screenshot "$WORK/lockshot/05-LockReply.png"
  cp "$WORK/lockshot/05-LockReply.png" "$WORK/lockshot/05-LockReply-fixture.png"
  echo "captured $WORK/lockshot/05-LockReply.png — inspect before staging"
}

cmd_post() { python3 "$HERE/appstore_shots_post.py" stage --work "$WORK" "$@"; }

cmd_verify() { python3 "$HERE/appstore_shots_post.py" verify --work "$WORK"; }

# Uploads the staged set with the asc CLI, one display type at a time. Existing
# remote screenshots for these display types are NOT deleted automatically;
# review the plan output and delete superseded sets in ASC (or with
# `asc screenshots delete`) deliberately.
cmd_upload() {
  need asc
  local confirm=0 replace=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) confirm=1; shift ;;
      # Replaces each remote set with the staged one. Without it, uploads
      # APPEND, and ASC's 10-per-set cap will reject most of a refresh when a
      # full set is already live (the dry run shows exactly what happens).
      --replace) replace=(--replace); shift ;;
      *) usage ;;
    esac
  done
  local loc_id
  loc_id="$(resolve_localization)"
  echo "target localization: $loc_id"
  for dir in "$WORK"/final/*/; do
    local display_type device_type
    display_type="$(basename "$dir")"
    # final/ dirs are keyed by ASC API display type (APP_IPHONE_67); the asc
    # CLI's --device-type uses the same enum without the APP_ prefix.
    device_type="${display_type#APP_}"
    echo "== $display_type -> --device-type $device_type <- $dir"
    ls "$dir"
    if [ "$confirm" -eq 1 ]; then
      asc screenshots upload --version-localization "$loc_id" \
        --device-type "$device_type" --path "$dir" --max-screenshots 10 \
        "${replace[@]}" --output json
    else
      asc screenshots upload --version-localization "$loc_id" \
        --device-type "$device_type" --path "$dir" --max-screenshots 10 \
        "${replace[@]}" --dry-run --output json
      echo "(dry run; pass --confirm to upload)"
    fi
  done
}

case "${1:-}" in
  asc-snapshot) shift; cmd_asc_snapshot "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  capture-real) shift; cmd_capture_real "$@" ;;
  lockshot) shift; cmd_lockshot "$@" ;;
  post) shift; cmd_post "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  upload) shift; cmd_upload "$@" ;;
  *) usage ;;
esac
