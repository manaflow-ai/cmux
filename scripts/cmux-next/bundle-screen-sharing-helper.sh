#!/usr/bin/env bash
# Xcode "Bundle Screen Sharing helper" phase of the cmux-next target
# (plans/cmux-next/screen-sharing-helper.md): wraps the cmux.rd/1 host executable
# (build-screen-sharing-helper.sh) in
#
#   Contents/Library/<app name> Screen Sharing.app       ("cmux NIGHTLY Screen Sharing.app")
#     Contents/MacOS/cmux-screen-sharing
#     Contents/Info.plist   <app bundle id>.screen-sharing, LSUIElement
#
# Its own bundle id and signature make it its own app to macOS: the app starts it with
# responsibility disclaimed (MacScreenHelper.swift), so Screen Recording and Accessibility are
# asked for, listed and restarted under the helper's name, and a grant never relaunches cmux.
#
# Source: CMUX_NEXT_SCREEN_HELPER_BIN, else the cache build-screen-sharing-helper.sh fills on
# CI and fleet builds. It never runs Cargo. A build without it is still a valid build: the app
# then serves and checks permissions in its own process, as before the helper. Release builds
# carry it only when CMUX_NEXT_SCREEN_HELPER_BIN names it (the nightly bundles it after the
# build, app-bundle-chief-and-mobile-host.sh); CMUX_NEXT_REQUIRE_SCREEN_HELPER=1 turns a
# missing binary into an error.
#
# Signing: with the build's identity (EXPANDED_CODE_SIGN_IDENTITY; ad hoc when empty, hardened
# runtime with a real one). Release signing re-signs it with Developer ID
# (sign-cmux-bundle.sh), after `--stamp <app>` renames it for the app's final bundle id and name
# (nightly and RC rename the app after the build).
#
#   bundle-screen-sharing-helper.sh             the Xcode phase (Xcode's variables)
#   bundle-screen-sharing-helper.sh --stamp APP re-stamps APP's helper from APP's Info.plist
#   bundle-screen-sharing-helper.sh --app APP   bundles into the built APP, named from its
#                                               Info.plist: reload.sh's fallback when the Xcode
#                                               phase did not run (writes no stamp)
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
EXECUTABLE=cmux-screen-sharing
SUFFIX=" Screen Sharing"

# PlistBuddy on a Mac; plistlib elsewhere (the Linux release signer stamps before it signs). Empty for a plist that
# is not there: PlistBuddy's Print then writes "File Doesn't Exist, Will Create: PATH" to stdout, which became the
# helper's name and an mv to that path failed the build (a launch-ready A/B's head build, 2026-11-17).
# CMUX_PLISTBUDDY: another PlistBuddy (tests).
PLISTBUDDY="${CMUX_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
plist_get() {
  [[ -f "$1" ]] || return 0
  if [[ -x "$PLISTBUDDY" ]]; then
    "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null || true
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

# Refuses a bundle id or app name that is not one: a value read from a tool's output can carry the tool's own
# message (the PlistBuddy line above), and the helper's path is built from the name. <id> <name>.
check_identity() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
    || { echo "error: Screen Sharing helper: bundle id '$1' is not a plain reverse-DNS name" >&2; exit 1; }
  [[ -n "$2" && "$2" != *[/:[:cntrl:]]* ]] \
    || { echo "error: Screen Sharing helper: app name '$2' is empty or holds a slash, colon or control character" >&2; exit 1; }
}

# Removes every helper bundle in <app>/Contents/Library except <keep> (a renamed app's old one).
remove_other_helpers() {
  local app="$1" keep="${2:-}" helper
  for helper in "$app/Contents/Library/"*"$SUFFIX.app"; do
    [[ -d "$helper" && "$helper" != "$keep" ]] || continue
    rm -rf "$helper"
  done
}

# --stamp APP: the final app's id and name (after a nightly or RC rename), before Release signing.
if [[ "${1:-}" == "--stamp" ]]; then
  app="${2:?usage: $0 --stamp <app>}"
  found=""
  for helper in "$app/Contents/Library/"*"$SUFFIX.app"; do [[ -d "$helper" ]] && found="$helper"; done
  if [[ -z "$found" ]]; then
    echo "note: $app carries no Screen Sharing helper"
    exit 0
  fi
  id="$(plist_get "$app/Contents/Info.plist" CFBundleIdentifier)"
  name="$(plist_get "$app/Contents/Info.plist" CFBundleName)"
  [[ -n "$id" && -n "$name" ]] || { echo "error: $app/Contents/Info.plist has no CFBundleIdentifier or CFBundleName" >&2; exit 1; }
  check_identity "$id" "$name"
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

# The Xcode phase takes the id, name and version from the build's own settings, as bundle-server-helper.sh and
# build-cmux-cua.sh do: Xcode may write the processed Info.plist after the script phases, so a rebuild in the same
# DerivedData finds none, or the previous build's (Resources/Info.plist's CFBundleName is $(PRODUCT_NAME)). --app
# reads the built app's Info.plist. Each falls back to the other, then to the bundle's file name.
info="$app/Contents/Info.plist"
if [[ -n "$stamp" ]]; then
  id="${PRODUCT_BUNDLE_IDENTIFIER:-$(plist_get "$info" CFBundleIdentifier)}"
  name="${PRODUCT_NAME:-$(plist_get "$info" CFBundleName)}"
  version="${CURRENT_PROJECT_VERSION:-$(plist_get "$info" CFBundleVersion)}"
else
  id="$(plist_get "$info" CFBundleIdentifier)"; id="${id:-${PRODUCT_BUNDLE_IDENTIFIER:-}}"
  name="$(plist_get "$info" CFBundleName)"; name="${name:-${PRODUCT_NAME:-}}"
  version="$(plist_get "$info" CFBundleVersion)"; version="${version:-${CURRENT_PROJECT_VERSION:-}}"
fi
id="${id:-com.cmuxterm.app.next}"
name="${name:-$(basename "$app" .app)}"
version="${version:-1}"
minimum="${MACOSX_DEPLOYMENT_TARGET:-$(plist_get "$info" LSMinimumSystemVersion)}"; minimum="${minimum:-14.0}"
check_identity "$id" "$name"
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
