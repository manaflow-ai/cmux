#!/bin/bash
# Point one classic cmux install at the cmux-next handoff TEST feed, and undo it.
#
#   classic-handoff-rc.sh on  [--app PATH] [--feed URL]     classic reads the test feed from its next launch
#   classic-handoff-rc.sh off [--app PATH]                  undo before updating: the original app comes back
#   classic-handoff-rc.sh back [--app PATH] [--version vX]  after the update: put classic back (default v0.65.2.2)
#   classic-handoff-rc.sh status [--app PATH]
#
# Why this changes the installed app: shipped classic (0.65.x) answers Sparkle's
# feedURLString(for:) delegate with the SUFeedURL in its own Info.plist
# (Packages/macOS/CmuxUpdater UpdateDriver+SPUUpdaterDelegate.swift on main), so
# `defaults write com.cmuxterm.app SUFeedURL ...` does nothing.
#
# Why it re-signs: an edited Info.plist breaks the Developer ID signature, and
# Sparkle's installer (Autoupdate, Developer ID) then refuses the app's XPC
# connection: "An error occurred while starting the installer" (SUSparkleErrorDomain
# 4005, seen in the first end-to-end run). `on` therefore keeps a full byte copy of
# the original app, edits SUFeedURL, and signs the whole bundle ad hoc, so the app
# and its Sparkle helpers match again. The update itself is still checked against
# the stable Sparkle EdDSA key, and it installs the Developer ID signed,
# notarized cmux-next app. While the switch is on, macOS may ask once for
# keychain access or a permission, because the ad-hoc app is not the signed one.
#
# Nothing here reads or writes the production feed, and nothing touches classic's
# data (~/Library/Application Support/cmux, ~/.config/cmux, defaults): `off` and
# `back` replace only the app bundle, and keep the bundle they remove in the
# state folder.
set -euo pipefail

TEST_FEED_DEFAULT="https://github.com/manaflow-ai/cmux-next-handoff-test/releases/latest/download/appcast.xml"
REAL_FEED="https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"
BUNDLE_ID="com.cmuxterm.app"
TEAM_ID="7WLXT3NR37"
STATE="$HOME/Library/Application Support/cmux-handoff-test"

cmd="${1:-status}"; shift || true
APP="/Applications/cmux.app"
FEED="$TEST_FEED_DEFAULT"
VERSION="v0.65.2.2"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --feed) FEED="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

PLIST="$APP/Contents/Info.plist"
ORIGINAL="$STATE/cmux-classic-original.app"
pbf() { [[ -f "$1" ]] || return 0; /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
pb() { pbf "$PLIST" "$1"; }
die() { echo "classic-handoff-rc: $*" >&2; exit 1; }
is_running() { pgrep -f "^$APP/Contents/MacOS/" >/dev/null 2>&1; }
team_signed() {
  codesign --verify --strict --deep -R "=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$1" >/dev/null 2>&1
}
set_aside() { # move the app at $APP into the state folder
  mkdir -p "$STATE/removed"
  local keep
  keep="$STATE/removed/cmux-$(pb CFBundleShortVersionString)-$(date +%Y%m%d-%H%M%S).app"
  mv "$APP" "$keep"
  echo "Kept the replaced app at $keep"
}

status() {
  [ -f "$PLIST" ] || { echo "no app at $APP"; return; }
  echo "app:       $APP"
  echo "bundle:    $(pb CFBundleIdentifier) $(pb CFBundleShortVersionString) (build $(pb CFBundleVersion))"
  echo "feed:      $(pb SUFeedURL)"
  if [ -d "$ORIGINAL" ]; then echo "switch:    ON (original app kept at $ORIGINAL)"; else echo "switch:    off"; fi
  if team_signed "$APP"; then echo "signature: Developer ID, team $TEAM_ID"
  elif codesign --verify --strict --deep "$APP" >/dev/null 2>&1; then echo "signature: ad hoc (expected while the switch is on)"
  else echo "signature: does not verify"; fi
}

case "$cmd" in
  status) status ;;

  on)
    [ -f "$PLIST" ] || die "no app at $APP"
    [ "$(pb CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "$APP is $(pb CFBundleIdentifier), not $BUNDLE_ID (classic stable)"
    case "$(pb CFBundleShortVersionString)" in
      0.*) ;;
      *) die "$APP is version $(pb CFBundleShortVersionString): already cmux-next, nothing to switch" ;;
    esac
    case "$FEED" in https://*) ;; *) die "the feed must be https: $FEED" ;; esac
    case "$FEED" in
      *github.com/manaflow-ai/cmux/releases/*|*files.cmux.com/*) die "refusing a production feed: $FEED" ;;
    esac
    is_running && die "quit cmux first (Cmd+Q), then run this from Terminal.app"
    mkdir -p "$STATE"
    if [ ! -d "$ORIGINAL" ]; then
      team_signed "$APP" || die "$APP is not the Developer ID signed classic; reinstall it from https://github.com/manaflow-ai/cmux/releases/latest first"
      ditto "$APP" "$ORIGINAL"
    fi
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED" "$PLIST"
    # A downloaded app keeps its quarantine flag; Gatekeeper blocks an ad-hoc app that has one.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    restore() { rm -rf "$APP"; ditto "$ORIGINAL" "$APP"; rm -rf "$ORIGINAL"; die "$1; the original app is back"; }
    codesign --force --deep --sign - --preserve-metadata=entitlements "$APP" >/dev/null 2>&1 || restore "ad-hoc signing failed"
    # AMFI kills an ad-hoc app that claims profile-bound entitlements (application-identifier,
    # team-identifier, network extension, system extension install, passkeys, keychain
    # groups): sign the outer app again without them. The test copy then cannot start
    # classic's cmux Cloud tunnel or browser passkeys; the update does not need either.
    ent="$(mktemp "${TMPDIR:-/tmp}/cmux-handoff-ent.XXXXXX")"
    codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$ent" || restore "cannot read the app's entitlements"
    for key in $(plutil -convert json -o - "$ent" | python3 -c 'import json,sys; print("\n".join(k for k in json.load(sys.stdin) if k == "com.apple.application-identifier" or k.startswith("com.apple.developer.") or k == "keychain-access-groups"))'); do
      /usr/libexec/PlistBuddy -c "Delete :$key" "$ent" >/dev/null
    done
    rm -f "$APP/Contents/embedded.provisionprofile"
    codesign --force --sign - --entitlements "$ent" "$APP" >/dev/null 2>&1 || { rm -f "$ent"; restore "ad-hoc signing of the app failed"; }
    rm -f "$ent"
    codesign --verify --strict --deep "$APP" >/dev/null 2>&1 || die "the re-signed app does not verify; run: $0 off"
    echo "Switch ON: $APP reads $FEED. Open cmux, then cmux > Check for Updates…"
    status
    ;;

  off)
    [ -d "$ORIGINAL" ] || { echo "Switch is already off."; status; exit 0; }
    if [ "$(pb CFBundleShortVersionString)" != "$(pbf "$ORIGINAL/Contents/Info.plist" CFBundleShortVersionString)" ]; then
      echo "The app updated to $(pb CFBundleShortVersionString) already; use '$0 back' to return to classic."
      status; exit 0
    fi
    is_running && die "quit cmux first (Cmd+Q)"
    [ -d "$APP" ] && set_aside
    mv "$ORIGINAL" "$APP"
    team_signed "$APP" || die "the restored app does not verify; reinstall classic from https://github.com/manaflow-ai/cmux/releases/latest"
    echo "Switch OFF: the original classic app is back and reads $REAL_FEED."
    status
    ;;

  back)
    is_running && die "quit cmux first (Cmd+Q), then run this from Terminal.app"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-classic-back.XXXXXX")"
    dmg="$tmp/cmux-macos.dmg"
    echo "Downloading classic $VERSION ..."
    curl -fsSL -o "$dmg" "https://github.com/manaflow-ai/cmux/releases/download/$VERSION/cmux-macos.dmg"
    mnt="$tmp/mnt"; mkdir -p "$mnt"
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
    src="$mnt/cmux.app"
    [ -d "$src" ] || { hdiutil detach "$mnt" >/dev/null; die "no cmux.app in the $VERSION DMG"; }
    team_signed "$src" || { hdiutil detach "$mnt" >/dev/null; die "the downloaded app is not signed by team $TEAM_ID"; }
    spctl --assess --type execute "$src" || { hdiutil detach "$mnt" >/dev/null; die "Gatekeeper rejects the downloaded app"; }
    [ -d "$APP" ] && set_aside
    ditto "$src" "$APP"
    hdiutil detach "$mnt" >/dev/null
    rm -rf "$tmp"
    [ -d "$ORIGINAL" ] && { mkdir -p "$STATE/removed"; mv "$ORIGINAL" "$STATE/removed/cmux-classic-original-$(date +%Y%m%d-%H%M%S).app"; }
    echo "Classic $VERSION is back at $APP. Your classic data was not touched; open cmux."
    status
    ;;

  *) die "unknown command: $cmd (on|off|back|status)" ;;
esac
