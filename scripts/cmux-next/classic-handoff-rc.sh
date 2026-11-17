#!/bin/bash
# Point one classic cmux install at the cmux-next handoff TEST feed, and undo it.
#
#   classic-handoff-rc.sh on  [--app PATH] [--feed URL]   classic reads the test feed from its next launch
#   classic-handoff-rc.sh off [--app PATH]                undo: classic reads the real feed again
#   classic-handoff-rc.sh back [--app PATH] [--version vX]  after the update: put classic back (default v0.65.2.2)
#   classic-handoff-rc.sh status [--app PATH]
#
# Why this edits the installed app: shipped classic (0.65.x) answers Sparkle's
# feedURLString(for:) delegate with the SUFeedURL in its own Info.plist
# (Packages/macOS/CmuxUpdater UpdateDriver+SPUUpdaterDelegate.swift on main), so
# `defaults write com.cmuxterm.app SUFeedURL ...` does nothing. `on` keeps a byte
# copy of the original Info.plist and changes only SUFeedURL; `off` puts the copy
# back, so the code signature is valid again. While the edit is in place the
# app's signature no longer matches its Info.plist: it still launches, but
# macOS may ask once for keychain access. The update to cmux-next replaces the
# whole bundle (signed, notarized), which ends the edit by itself.
#
# Nothing here reads or writes the production feed, and nothing touches classic's
# data (~/Library/Application Support/cmux, ~/.config/cmux, defaults): `back`
# replaces only the app bundle, and keeps the cmux-next bundle it removes in the
# state folder.
set -euo pipefail

TEST_FEED_DEFAULT="https://cdn.cmux.sh/cmux-next-handoff-test/appcast.xml"
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
BACKUP="$STATE/Info.plist.original"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
die() { echo "classic-handoff-rc: $*" >&2; exit 1; }

is_running() { pgrep -f "^$APP/Contents/MacOS/" >/dev/null 2>&1; }

status() {
  [ -f "$PLIST" ] || { echo "no app at $APP"; return; }
  echo "app:      $APP"
  echo "bundle:   $(pb CFBundleIdentifier) $(pb CFBundleShortVersionString) (build $(pb CFBundleVersion))"
  echo "feed:     $(pb SUFeedURL)"
  if [ -f "$BACKUP" ]; then echo "switch:   ON (original Info.plist kept in $BACKUP)"; else echo "switch:   off"; fi
  if codesign --verify --strict "$APP" >/dev/null 2>&1; then echo "signature: valid"; else echo "signature: does not match (expected while the switch is on)"; fi
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
      *github.com/manaflow-ai/cmux/releases/*|*files.cmux.com/stable/*) die "refusing the production feed: $FEED" ;;
    esac
    mkdir -p "$STATE"
    if [ ! -f "$BACKUP" ]; then
      codesign --verify --strict "$APP" >/dev/null 2>&1 || die "$APP's signature is already broken; reinstall classic first"
      cp -p "$PLIST" "$BACKUP"
    fi
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED" "$PLIST"
    echo "Switch ON: $APP reads $FEED from its next launch."
    if is_running; then echo "Quit cmux (Cmd+Q) and open it again, then use cmux > Check for Updates."; fi
    status
    ;;

  off)
    [ -f "$BACKUP" ] || { echo "Switch is already off."; status; exit 0; }
    if [ "$(pb CFBundleShortVersionString)" != "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BACKUP")" ]; then
      echo "The app is no longer the classic build the switch edited (it updated). Dropping the saved copy."
      rm -f "$BACKUP"; status; exit 0
    fi
    cp -p "$BACKUP" "$PLIST"
    rm -f "$BACKUP"
    codesign --verify --strict "$APP" >/dev/null 2>&1 || die "signature still does not verify; reinstall classic from https://github.com/manaflow-ai/cmux/releases/latest"
    echo "Switch OFF: $APP reads $REAL_FEED again (relaunch to apply)."
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
    codesign --verify --strict --deep -R "=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$src" \
      || { hdiutil detach "$mnt" >/dev/null; die "the downloaded app is not signed by team $TEAM_ID"; }
    spctl --assess --type execute "$src" || { hdiutil detach "$mnt" >/dev/null; die "Gatekeeper rejects the downloaded app"; }
    mkdir -p "$STATE/removed"
    if [ -d "$APP" ]; then
      keep="$STATE/removed/cmux-$(pb CFBundleShortVersionString)-$(date +%Y%m%d-%H%M%S).app"
      mv "$APP" "$keep"
      echo "Kept the replaced app at $keep"
    fi
    ditto "$src" "$APP"
    hdiutil detach "$mnt" >/dev/null
    rm -rf "$tmp"
    rm -f "$BACKUP"
    echo "Classic $VERSION is back at $APP. Your classic data was not touched; open cmux."
    status
    ;;

  *) die "unknown command: $cmd (on|off|back|status)" ;;
esac
