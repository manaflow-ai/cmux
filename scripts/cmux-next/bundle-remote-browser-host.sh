#!/usr/bin/env bash
# Wraps a built cmux-remote-browser-host binary (scripts/ci/cmux-remote-browser-host-build.sh
# artifact) into an app bundle with the CEF fork framework and its helper apps, the layout
# CEF needs on macOS. No compiler: runs on the GUI host (cmux-lawrence-2).
#   scripts/cmux-next/bundle-remote-browser-host.sh BINARY CEF_PATH OUT.app
# Then: OUT.app/Contents/MacOS/cmux-remote-browser-host --smoke OUT_DIR
set -euo pipefail
bin="${1:?usage: bundle-remote-browser-host.sh BINARY CEF_PATH OUT.app}"
cef="${2:?CEF_PATH}"
app="${3:?OUT.app}"
fw="Chromium Embedded Framework.framework"
[[ -f "$bin" && -d "$cef/$fw" ]] || { echo "error: need the binary and $cef/$fw" >&2; exit 2; }
name=cmux-remote-browser-host
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
plist() { # <path> <executable> <bundle id>
  cat >"$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>RbShimApplication</string>
</dict></plist>
PLIST
}
cp "$bin" "$app/Contents/MacOS/$name"
chmod 755 "$app/Contents/MacOS/$name"
plist "$app/Contents/Info.plist" "$name" com.manaflow.cmux-remote-browser-host
# Release assets are stripped, which leaves their signatures invalid: re-sign ad hoc.
cp -R "$cef/$fw" "$app/Contents/Frameworks/"
find "$app/Contents/Frameworks/$fw" -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$app/Contents/Frameworks/$fw" 2>/dev/null
# CEF looks for "<exe> Helper.app" and its (GPU), (Renderer), (Plugin), (Alerts) variants;
# the host binary is its own helper (rb_shim_run runs CefExecuteProcess for --type=).
for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  helper_name="$name Helper$suffix"
  helper="$app/Contents/Frameworks/$helper_name.app"
  mkdir -p "$helper/Contents/MacOS"
  cp "$bin" "$helper/Contents/MacOS/$helper_name"
  chmod 755 "$helper/Contents/MacOS/$helper_name"
  id_suffix="$(printf %s "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
  plist "$helper/Contents/Info.plist" "$helper_name" "com.manaflow.cmux-remote-browser-host.helper${id_suffix:+.$id_suffix}"
  codesign --force --sign - "$helper" 2>/dev/null
done
codesign --force --sign - "$app" 2>/dev/null
echo "$app"
