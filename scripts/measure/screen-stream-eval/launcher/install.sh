#!/usr/bin/env bash
# Installs CmuxScreenEvalLauncher.app (launcher.swift) in the user's real ~/Applications once (from
# the directory service: a fleet step's $HOME is a scratch folder of that step, removed after it). It never replaces an
# installed copy that can run: macOS keys the console grants to this exact signed binary, so a rebuild
# would lose them. A copy built for a newer macOS than this one (swiftc's default target is the SDK's,
# which can be ahead of the OS; LaunchServices then refuses it with -10825) never ran and so holds no
# grant: that one is replaced. A new launcher version gets a new bundle name. Prints the app's path.
#   install.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name=CmuxScreenEvalLauncher
home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
[[ -n "$home" && -d "$home" ]] || { echo "install.sh: no home directory for $(id -un)" >&2; exit 1; }
app="$home/Applications/$name.app"
target=14.0 # LSMinimumSystemVersion below
# The macOS version a binary needs (LC_BUILD_VERSION minos).
minos() { otool -l "$1" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { print $2; exit }'; }
runs_here() {
  python3 -I -c 'import sys
need, have = ([int(x) for x in v.split(".")] for v in sys.argv[1:3])
sys.exit(0 if need <= have else 1)' "${1:-99}" "$(sw_vers -productVersion)"
}
if [[ -x "$app/Contents/MacOS/$name" ]]; then
  if runs_here "$(minos "$app/Contents/MacOS/$name")"; then
    echo "$app"
    exit 0
  fi
  echo "install.sh: replacing $app, built for macOS $(minos "$app/Contents/MacOS/$name") (it never ran here, so it holds no grant)" >&2
  rm -rf "$app"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$name.app/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos$target" -o "$work/$name.app/Contents/MacOS/$name" "$here/launcher.swift"
cat >"$work/$name.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.manaflow.cmux-screen-eval-launcher</string>
  <key>CFBundleName</key><string>CmuxScreenEvalLauncher</string>
  <key>CFBundleExecutable</key><string>CmuxScreenEvalLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - --identifier ai.manaflow.cmux-screen-eval-launcher "$work/$name.app"
mkdir -p "$home/Applications"
mv "$work/$name.app" "$app"
# LaunchServices may still hold the record of a refused copy at this path: register this one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true
echo "$app"
