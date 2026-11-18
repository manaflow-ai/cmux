#!/usr/bin/env bash
# Xcode "Bundle Screen Sharing helper" phase of the cmux-next target
# (plans/cmux-next/screen-sharing-helper.md): places the cmux.rd/1 host executable
# (build-screen-sharing-helper.sh) where its Screen Recording and Accessibility grants live.
#
# One permission identity for screen sharing and computer use (Lawrence: "ensure screen
# sharing + computer use uses same app for permissions"). A release, NIGHTLY or RC app carries
# the Computer Use helper, and the executable ships inside it:
#
#   Contents/Library/cmux Computer Use.app       com.cmuxterm.cua, the same for every channel
#     Contents/MacOS/cmux-cua                    the Computer Use driver (the bundle's executable)
#     Contents/MacOS/cmux-screen-sharing         this executable, signed --identifier com.cmuxterm.cua
#
# so macOS asks for, lists and keeps both grants under "cmux Computer Use" whichever way it
# attributes the process: by the outermost bundle (macOS 26) or by the code's own identifier
# (older macOS). Anyone who allowed Computer Use already has both grants. The app starts it from
# the Computer Use helper's copy outside the app with responsibility disclaimed
# (MacScreenHelper.swift), so a grant never relaunches cmux.
#
# Release packaging puts it there (--into-computer-use, after build-cmux-cua.sh --helper-app).
# The Xcode phase and --app wrap the executable in its own app, as before, which is what a DEV
# build keeps: its Computer Use helper is the pinned "cmux Computer Use (dev).app"
# (embed-cua-helper-dev.sh), signed with a certificate CI does not hold, so nothing can be added
# to it, and reload.sh drops the ad hoc com.cmuxterm.cua helper it assembles, which would
# otherwise take over the release row (scripts/cmux-cua-helper-trust.sh drop-unsigned).
# verify-computer-use-helper.sh fails a release app that still carries the separate helper.
#
#   Contents/Library/<app name> Screen Sharing.app       ("cmux DEV x Screen Sharing.app")
#     Contents/MacOS/cmux-screen-sharing
#     Contents/Info.plist   <app bundle id>.screen-sharing, LSUIElement
#
# Source: CMUX_NEXT_SCREEN_HELPER_BIN, else the cache build-screen-sharing-helper.sh fills on
# CI and fleet builds. It never runs Cargo. A build without it is still a valid build: the app
# then serves and checks permissions in its own process, as before the helper. Release builds
# carry it only when CMUX_NEXT_SCREEN_HELPER_BIN names it: the nightly bundles it right after
# the build (app-bundle-chief-and-mobile-host.sh), before the Computer Use helper exists, then
# moves it into that helper once it is assembled (app-assemble-computer-use-helper.sh,
# --into-computer-use). CMUX_NEXT_REQUIRE_SCREEN_HELPER=1 turns a missing binary into an error.
#
# Signing: with the build's identity for its own app (EXPANDED_CODE_SIGN_IDENTITY; ad hoc when
# empty, hardened runtime with a real one). Inside the Computer Use helper it is signed ad hoc
# with the helper's identifier and the helper is re-sealed ad hoc, as build-cmux-cua.sh signs
# it; Release signing then signs the executable with Developer ID and --identifier
# com.cmuxterm.cua before it seals the helper (sign-cmux-bundle.sh,
# notarize-computer-use-helper.sh, release-signer/sign-app.sh, rcodesign-sign-bundle.sh).
#
#   bundle-screen-sharing-helper.sh                          the Xcode phase (Xcode's variables)
#   bundle-screen-sharing-helper.sh --app APP                bundles into the built APP, named
#                                                            from its Info.plist: reload.sh's
#                                                            fallback when the Xcode phase did
#                                                            not run (writes no stamp)
#   bundle-screen-sharing-helper.sh --into-computer-use APP  moves APP's separate helper (or
#                                                            CMUX_NEXT_SCREEN_HELPER_BIN) into
#                                                            APP's Computer Use helper
#   bundle-screen-sharing-helper.sh --stamp APP              before Release signing: drops a
#                                                            separate helper the Computer Use
#                                                            helper replaces, else re-stamps it
#                                                            from APP's Info.plist
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
EXECUTABLE=cmux-screen-sharing
SUFFIX=" Screen Sharing"
# The Computer Use helper (scripts/build-cmux-cua.sh --helper-app) and its one TCC identity.
COMPUTER_USE="cmux Computer Use.app"
COMPUTER_USE_ID=com.cmuxterm.cua

# PlistBuddy on a Mac; plistlib elsewhere (the Linux release signer stamps before it signs). Empty for a plist that
# is not there: PlistBuddy's Print then writes "File Doesn't Exist, Will Create: PATH" to stdout, which became the
# helper's name and an mv to that path failed the build (a launch-ready A/B's head build, 2026-11-17).
plist_get() {
  [[ -f "$1" ]] || return 0
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
  else
    python3 -I -c 'import plistlib, sys; v = plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2]); print("" if v is None else v)' \
      "$1" "$2" 2>/dev/null || true
  fi
}

# The helper's Info.plist: <path> <bundle id> <name> <version> <minimum macOS>.
write_plist() {
  local path="$1" id="$2" name="$3" version="$4" minimum="$5"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
}

# Removes every helper bundle in <app>/Contents/Library except <keep> (a renamed app's old one).
remove_other_helpers() {
  local app="$1" keep="${2:-}" helper
  for helper in "$app/Contents/Library/"*"$SUFFIX.app"; do
    [[ -d "$helper" && "$helper" != "$keep" ]] || continue
    rm -rf "$helper"
  done
}

# Prints <app>'s com.cmuxterm.cua Computer Use helper, or nothing (a DEV build, or none yet).
computer_use_helper() {
  local helper="$1/Contents/Library/$COMPUTER_USE"
  [[ -d "$helper" && ! -L "$helper" && -x "$helper/Contents/MacOS/cmux-cua" ]] || return 0
  [[ "$(plist_get "$helper/Contents/Info.plist" CFBundleIdentifier)" == "$COMPUTER_USE_ID" ]] || return 0
  printf '%s\n' "$helper"
}

# into_computer_use <app> <helper> <executable>: copies <executable> into <helper>/Contents/MacOS,
# signs it ad hoc with the helper's identifier, re-seals the helper ad hoc with the stable
# requirement build-cmux-cua.sh gives it (Release signing replaces both with Developer ID), then
# removes every separate helper of <app>: one identity, never two.
into_computer_use() {
  local app="$1" helper="$2" src="$3" dest
  dest="$helper/Contents/MacOS/$EXECUTABLE"
  if [[ "$src" != "$dest" ]]; then
    cp "$src" "$dest.tmp.$$"
    chmod 755 "$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
  fi
  "$repo_root/scripts/codesign-retry.sh" --force --sign - --timestamp=none --identifier "$COMPUTER_USE_ID" "$dest"
  "$repo_root/scripts/codesign-retry.sh" --force --sign - --timestamp=none --identifier "$COMPUTER_USE_ID" \
    --requirements "=designated => identifier \"$COMPUTER_USE_ID\"" "$helper"
  remove_other_helpers "$app"
  echo "bundled $EXECUTABLE into $COMPUTER_USE ($COMPUTER_USE_ID) from $src"
}

# --into-computer-use APP: the executable moves into APP's Computer Use helper, from
# CMUX_NEXT_SCREEN_HELPER_BIN or APP's separate helper (the nightly bundles that right after the
# Release build, before it assembles the Computer Use helper).
if [[ "${1:-}" == "--into-computer-use" ]]; then
  app="${2:?usage: $0 --into-computer-use <app>}"
  app="${app%/}"
  helper="$(computer_use_helper "$app")"
  src="${CMUX_NEXT_SCREEN_HELPER_BIN:-}"
  if [[ -z "$src" ]]; then
    for found in "$app/Contents/Library/"*"$SUFFIX.app/Contents/MacOS/$EXECUTABLE"; do
      [[ -f "$found" ]] && src="$found"
    done
  fi
  if [[ -z "$src" && -n "$helper" && -f "$helper/Contents/MacOS/$EXECUTABLE" ]]; then
    src="$helper/Contents/MacOS/$EXECUTABLE"
  fi
  if [[ -z "$src" ]]; then
    echo "note: $app carries no Screen Sharing helper"
    exit 0
  fi
  [[ -n "$helper" ]] || { echo "error: $app has no $COMPUTER_USE ($COMPUTER_USE_ID) to carry $EXECUTABLE (scripts/build-cmux-cua.sh --helper-app first)" >&2; exit 1; }
  /usr/bin/file -b "$src" | grep -q 'Mach-O' || { echo "error: the Screen Sharing helper source is not a Mach-O executable: $src" >&2; exit 1; }
  # Copied aside first: the source may be inside the separate helper into_computer_use removes.
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  if [[ "$src" != "$helper/Contents/MacOS/$EXECUTABLE" ]]; then
    cp "$src" "$work/$EXECUTABLE"
    src="$work/$EXECUTABLE"
  fi
  into_computer_use "$app" "$helper" "$src"
  exit 0
fi

# --stamp APP: the final app's id and name (after a nightly or RC rename), before Release signing.
if [[ "${1:-}" == "--stamp" ]]; then
  app="${2:?usage: $0 --stamp <app>}"
  helper="$(computer_use_helper "$app")"
  if [[ -n "$helper" && -x "$helper/Contents/MacOS/$EXECUTABLE" ]]; then
    # The Computer Use helper's identity is the same for every channel: nothing to re-stamp.
    remove_other_helpers "$app"
    echo "the Screen Sharing helper is in $COMPUTER_USE ($COMPUTER_USE_ID): nothing to stamp"
    exit 0
  fi
  found=""
  for helper in "$app/Contents/Library/"*"$SUFFIX.app"; do [[ -d "$helper" ]] && found="$helper"; done
  if [[ -z "$found" ]]; then
    echo "note: $app carries no Screen Sharing helper"
    exit 0
  fi
  id="$(plist_get "$app/Contents/Info.plist" CFBundleIdentifier)"
  name="$(plist_get "$app/Contents/Info.plist" CFBundleName)"
  [[ -n "$id" && -n "$name" ]] || { echo "error: $app/Contents/Info.plist has no CFBundleIdentifier or CFBundleName" >&2; exit 1; }
  version="$(plist_get "$app/Contents/Info.plist" CFBundleVersion)"
  minimum="$(plist_get "$app/Contents/Info.plist" LSMinimumSystemVersion)"
  dest="$app/Contents/Library/$name$SUFFIX.app"
  [[ "$found" == "$dest" ]] || { rm -rf "$dest"; mv "$found" "$dest"; }
  remove_other_helpers "$app" "$dest"
  write_plist "$dest/Contents/Info.plist" "$id.screen-sharing" "$name$SUFFIX" "${version:-1}" "${minimum:-14.0}"
  echo "stamped the Screen Sharing helper: $(basename "$dest") ($id.screen-sharing)"
  exit 0
fi

# The Xcode phase, or --app APP after the build (reload.sh), which writes no stamp.
if [[ "${1:-}" == "--app" ]]; then
  app="${2:?usage: $0 --app <app>}"
  app="${app%/}"
  [[ "$app" == *.app && -d "$app/Contents" ]] || { echo "error: no app bundle at $app" >&2; exit 1; }
  stamp=""
else
  resources="${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
  app="${TARGET_BUILD_DIR:?}/${resources%/Contents/Resources}"
  [[ "$app" == *.app ]] || { echo "error: cannot find the app bundle from UNLOCALIZED_RESOURCES_FOLDER_PATH=$resources" >&2; exit 1; }
  stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-screen-sharing-helper.stamp"
fi
on_exit() {
  status=$?
  if (( status == 0 )); then
    if [[ -n "$stamp" ]]; then
      mkdir -p "$(dirname "$stamp")"
      printf 'completed\n' > "$stamp"
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
[[ -z "$stamp" ]] || rm -f "$stamp"

src="${CMUX_NEXT_SCREEN_HELPER_BIN:-}"
if [[ "${CONFIGURATION:-Debug}" == Release* && -z "$src" && "${CMUX_NEXT_REQUIRE_SCREEN_HELPER:-}" != 1 ]]; then
  echo "Screen Sharing helper: not bundled in this ${CONFIGURATION} build (CMUX_NEXT_SCREEN_HELPER_BIN is unset)"
  remove_other_helpers "$app"
  exit 0
fi
if [[ -z "$src" ]]; then
  src="$({ "$repo_root/scripts/cmux-next/build-screen-sharing-helper.sh" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  remove_other_helpers "$app"
  if [[ "${CMUX_NEXT_REQUIRE_SCREEN_HELPER:-}" == 1 ]]; then
    echo "error: no Screen Sharing helper binary for this build; run scripts/cmux-next/build-screen-sharing-helper.sh on CI or the fleet" >&2
    exit 1
  fi
  echo "warning: Screen Sharing helper not bundled (no cached build of this source); screen sharing runs in the app and its permissions are the app's" >&2
  exit 0
fi
/usr/bin/file -b "$src" | grep -q 'Mach-O' || { echo "error: the Screen Sharing helper source is not a Mach-O executable: $src" >&2; exit 1; }
if command -v lipo >/dev/null 2>&1 && [[ -n "${ARCHS:-}" ]]; then
  actual="$(lipo -archs "$src")"
  for expected in $ARCHS; do
    [[ " $actual " == *" $expected "* ]] || { echo "error: the Screen Sharing helper has '$actual', the app needs '$ARCHS'" >&2; exit 1; }
  done
fi

info="$app/Contents/Info.plist"
id="$(plist_get "$info" CFBundleIdentifier)"; id="${id:-${PRODUCT_BUNDLE_IDENTIFIER:-com.cmuxterm.app.next}}"
name="$(plist_get "$info" CFBundleName)"; name="${name:-$(basename "$app" .app)}"
version="$(plist_get "$info" CFBundleVersion)"; version="${version:-${CURRENT_PROJECT_VERSION:-1}}"
minimum="${MACOSX_DEPLOYMENT_TARGET:-$(plist_get "$info" LSMinimumSystemVersion)}"; minimum="${minimum:-14.0}"
dest="$app/Contents/Library/$name$SUFFIX.app"
remove_other_helpers "$app" "$dest"
mkdir -p "$app/Contents/Library"
tmp="$(mktemp -d "$app/Contents/Library/.screen-sharing.XXXXXX")"
trap 'status=$?; rm -rf "$tmp"; (exit "$status"); on_exit' EXIT
staged="$tmp/$name$SUFFIX.app"
mkdir -p "$staged/Contents/MacOS"
cp "$src" "$staged/Contents/MacOS/$EXECUTABLE"
chmod 755 "$staged/Contents/MacOS/$EXECUTABLE"
write_plist "$staged/Contents/Info.plist" "$id.screen-sharing" "$name$SUFFIX" "$version" "$minimum"
printf 'APPL????' > "$staged/Contents/PkgInfo"

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$identity" ]] || identity="-"
flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
  if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then flags+=(--timestamp=none); else flags+=(--timestamp); fi
fi
"$repo_root/scripts/codesign-retry.sh" "${flags[@]}" "$staged"
rm -rf "$dest"
mv "$staged" "$dest"
echo "bundled the Screen Sharing helper $(basename "$dest") ($id.screen-sharing, signed by $identity) from $src"
