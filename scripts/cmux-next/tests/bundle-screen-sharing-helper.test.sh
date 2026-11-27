#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# bundle-screen-sharing-helper.sh run more than once over the same built app, as a second build in one
# DerivedData does (a launch-ready A/B builds its base and head arms there). A stub PlistBuddy prints, as
# the real one does, "File Doesn't Exist, Will Create: PATH" on stdout for a plist that is not there; a
# stub codesign prints "replacing existing signature" on stderr. Covers: the Xcode phase with no
# processed Info.plist yet, the same phase again over the bundled helper, a previous build's Info.plist
# (another name and id) left in the app, --app with no Info.plist, and --stamp refusing a name that is
# not one, and an app built before the rename (a legacy "<name> Screen Sharing.app") migrating on a rebuild and
# on --stamp while another app's " Helper.app" stays. Each run must leave exactly one helper, named from this build, and no staging directory.
# The helper also carries the app's icon (CFBundleIconFile and its .icns in Contents/Resources) after the Xcode
# phase, --app and --stamp: without one, the Computer Use onboarding's drag row, System Settings' privacy lists and
# the permission prompt show the blank generic app icon (Austin, 2026-11-27: "We need to show the icon instead of
# the blank white icon").
# Runs on Linux and macOS (python3 and file(1)).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/bundle-screen-sharing-helper.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

cat > "$TMP/PlistBuddy" <<'STUB'
#!/usr/bin/env bash
# PlistBuddy -c "Print :KEY" FILE
key="${2#Print :}"; file="$3"
if [[ ! -f "$file" ]]; then
  echo "File Doesn't Exist, Will Create: $file"
  echo "Print: Entry, \":$key\", Does Not Exist" >&2
  exit 1
fi
exec python3 -I -c 'import plistlib, sys
v = plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2])
if v is None:
    sys.stderr.write("Print: Entry does not exist\n"); sys.exit(1)
print(v)' "$file" "$key"
STUB
cat > "$TMP/codesign" <<'STUB'
#!/usr/bin/env bash
echo "${!#}: replacing existing signature" >&2
STUB
chmod 755 "$TMP/PlistBuddy" "$TMP/codesign"
# A Mach-O 64-bit arm64 executable header, enough for file(1).
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00' > "$TMP/cmux-screen-sharing"
head -c 4080 /dev/zero >> "$TMP/cmux-screen-sharing"

NAME="cmux NEXT DEV"
ID=com.cmuxterm.app.next.dev
build="$TMP/build"
app="$build/$NAME.app"
library="$app/Contents/Library"
mkdir -p "$app/Contents/Resources" "$build/tmp"

write_info() { # <name> <id>
  python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleName": sys.argv[2], "CFBundleIdentifier": sys.argv[3], "CFBundleVersion": "7"}, open(sys.argv[1], "wb"))' \
    "$app/Contents/Info.plist" "$1" "$2"
}
plist_value() { python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2], ""))' "$1" "$2"; }
run() { # [args...] -> out, rc; the Xcode phase's settings unless --app/--stamp
  local settings=(TARGET_BUILD_DIR="$build" TARGET_TEMP_DIR="$build/tmp"
    UNLOCALIZED_RESOURCES_FOLDER_PATH="$NAME.app/Contents/Resources"
    PRODUCT_NAME="$NAME" PRODUCT_BUNDLE_IDENTIFIER="$ID" CURRENT_PROJECT_VERSION=7
    ${ASSETCATALOG_COMPILER_APPICON_NAME:+ASSETCATALOG_COMPILER_APPICON_NAME="$ASSETCATALOG_COMPILER_APPICON_NAME"})
  [[ $# == 0 ]] || settings=()
  set +e
  out=$(env -i PATH=/usr/bin:/bin HOME="$TMP" TMPDIR="$TMP" CONFIGURATION=Debug SRCROOT="$ROOT" \
    CMUX_PLISTBUDDY="$TMP/PlistBuddy" CMUX_CODESIGN_TOOL="$TMP/codesign" \
    CMUX_NEXT_SCREEN_HELPER_BIN="$TMP/cmux-screen-sharing" ${settings[@]+"${settings[@]}"} \
    /bin/bash "$SCRIPT" "$@" 2>&1)
  rc=$?
  set -e
}
expect_one_helper() { # <case> <expected helper name> <expected id>
  local entries helper="$library/$2 Helper.app"
  entries=$(ls -A "$library")
  [[ $rc == 0 ]] || fail "$1: exit $rc" "$out"
  [[ "$entries" == "$2 Helper.app" ]] || fail "$1: Contents/Library holds [$entries], not one helper named '$2 Helper.app'" "$out"
  [[ -x "$helper/Contents/MacOS/cmux-screen-sharing" ]] || fail "$1: no helper executable" "$out"
  [[ "$(plist_value "$helper/Contents/Info.plist" CFBundleIdentifier)" == "$3" ]] \
    || fail "$1: the helper's id is '$(plist_value "$helper/Contents/Info.plist" CFBundleIdentifier)', not $3" "$out"
}

# 1. The Xcode phase before Xcode writes the processed Info.plist.
run
expect_one_helper "first build, no Info.plist" "$NAME" "$ID.screen-sharing"

# 2. The phase again over the bundled helper (the second build in the same DerivedData).
rm -f "$build/tmp/bundle-screen-sharing-helper.stamp"
run
expect_one_helper "second build over the helper" "$NAME" "$ID.screen-sharing"

# 3. A previous build's Info.plist, with another name and id, is still in the app.
write_info "cmux NEXT DEV old-tag" "$ID.oldtag"
run
expect_one_helper "a previous build's Info.plist" "$NAME" "$ID.screen-sharing"

# 4. --app (reload.sh's fallback) on an app with no Info.plist: named from the bundle.
rm -f "$app/Contents/Info.plist"
run --app "$app"
expect_one_helper "--app, no Info.plist" "$NAME" "com.cmuxterm.app.next.screen-sharing"

# 5. --stamp refuses a name that would make a path, and leaves the helper alone.
write_info "cmux/NEXT" "$ID"
run --stamp "$app"
[[ $rc != 0 ]] || fail "--stamp took the name 'cmux/NEXT'" "$out"
[[ "$(ls -A "$library")" == "$NAME Helper.app" ]] || fail "--stamp moved the helper on a refused name" "$out"

# 6. An app built before the rename: the Xcode phase replaces its "<name> Screen Sharing.app".
legacy() { # <name> -> a legacy-named helper in the app, the only helper
  rm -rf "$library"/*
  mkdir -p "$library/$1 Screen Sharing.app/Contents/MacOS"
  cp "$TMP/cmux-screen-sharing" "$library/$1 Screen Sharing.app/Contents/MacOS/cmux-screen-sharing"
  chmod 755 "$library/$1 Screen Sharing.app/Contents/MacOS/cmux-screen-sharing"
}
rm -f "$app/Contents/Info.plist" "$build/tmp/bundle-screen-sharing-helper.stamp"
legacy "$NAME"
run
expect_one_helper "rebuild over a legacy helper" "$NAME" "$ID.screen-sharing"

# 7. --stamp on an app built before the rename: renamed to "<name> Helper.app", named "<name> Helper".
legacy "cmux NEXT"
write_info "$NAME" "$ID"
run --stamp "$app"
expect_one_helper "--stamp of a legacy helper" "$NAME" "$ID.screen-sharing"
for key in CFBundleName CFBundleDisplayName; do
  [[ "$(plist_value "$library/$NAME Helper.app/Contents/Info.plist" $key)" == "$NAME Helper" ]] \
    || fail "--stamp: $key is not '$NAME Helper'" "$out"
done

# 8. Another bundle ending in " Helper.app" (no cmux-screen-sharing inside) is neither taken nor removed.
mkdir -p "$library/Other Helper.app/Contents/MacOS"
touch "$library/Other Helper.app/Contents/MacOS/other"
run --stamp "$app"
[[ $rc == 0 && -d "$library/Other Helper.app" && -x "$library/$NAME Helper.app/Contents/MacOS/cmux-screen-sharing" ]] \
  || fail "--stamp took or removed another app's Helper.app" "$out"
rm -rf "$library/$NAME Helper.app"
run --stamp "$app"
[[ $rc == 0 && "$out" == *"carries no Screen Sharing helper"* && -d "$library/Other Helper.app" ]] \
  || fail "--stamp treated another app's Helper.app as the helper" "$out"

# 9. Every DEV build, whatever its tag, carries the one DEV helper id: one System Settings row, one copy.
rm -rf "$library"/* "$build/tmp/bundle-screen-sharing-helper.stamp"
for dev_id in com.cmuxterm.app.debug.my-tag com.cmuxterm.app.debug.other.tag com.cmuxterm.app.debug; do
  write_info "$NAME" "$dev_id"
  ID="$dev_id" run
  expect_one_helper "Xcode phase of $dev_id" "$NAME" com.cmuxterm.app.debug.screen-sharing
  run --stamp "$app"
  expect_one_helper "--stamp of $dev_id" "$NAME" com.cmuxterm.app.debug.screen-sharing
done

# 10. The helper carries the app's own icon: CFBundleIconFile names an .icns in its Contents/Resources with the
# app icon's bytes. Each channel names its icon differently (AppIcon, AppIcon-Debug), so the helper follows the app.
write_icon_info() { # <icon name>: an app Info.plist naming its icon, and that icon in Resources
  python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleName": sys.argv[2], "CFBundleIdentifier": sys.argv[3], "CFBundleVersion": "7", "CFBundleIconFile": sys.argv[4]}, open(sys.argv[1], "wb"))' \
    "$app/Contents/Info.plist" "$NAME" "$ID" "$1"
  rm -f "$app/Contents/Resources/"*.icns
  printf 'icns-%s' "$1" > "$app/Contents/Resources/$1.icns"
}
expect_icon() { # <case> <app icon name>
  local helper="$library/$NAME Helper.app" file
  file=$(plist_value "$helper/Contents/Info.plist" CFBundleIconFile)
  [[ -n "$file" ]] || fail "$1: the helper's Info.plist has no CFBundleIconFile (the blank app icon)" "$out"
  [[ "$file" == *.icns ]] || file="$file.icns"
  [[ -s "$helper/Contents/Resources/$file" ]] \
    || fail "$1: the helper's CFBundleIconFile names Contents/Resources/$file, which is not there" "$out"
  cmp -s "$helper/Contents/Resources/$file" "$app/Contents/Resources/$2.icns" \
    || fail "$1: the helper's icon is not the app's $2.icns" "$out"
}
rm -rf "$library"/* "$build/tmp/bundle-screen-sharing-helper.stamp"
for icon in AppIcon AppIcon-Debug; do
  write_icon_info "$icon"
  rm -f "$build/tmp/bundle-screen-sharing-helper.stamp"
  ASSETCATALOG_COMPILER_APPICON_NAME="$icon" run
  expect_one_helper "Xcode phase, icon $icon" "$NAME" "$ID.screen-sharing"
  expect_icon "Xcode phase, icon $icon" "$icon"
  run --app "$app"
  expect_one_helper "--app, icon $icon" "$NAME" "$ID.screen-sharing"
  expect_icon "--app, icon $icon" "$icon"
  run --stamp "$app"
  expect_one_helper "--stamp, icon $icon" "$NAME" "$ID.screen-sharing"
  expect_icon "--stamp, icon $icon" "$icon"
done
# --stamp of a helper bundled before the icon (no Contents/Resources): the release signer's path gives it one.
legacy "$NAME"
write_icon_info AppIcon
run --stamp "$app"
expect_one_helper "--stamp of a helper with no icon" "$NAME" "$ID.screen-sharing"
expect_icon "--stamp of a helper with no icon" AppIcon

echo "PASS: bundle-screen-sharing-helper.sh reruns over the same app"
