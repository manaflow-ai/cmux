#!/usr/bin/env bash
# bundle-share-extension.sh: the Share extension the app carries (Contents/PlugIns/CmuxShare.appex).
#
# Anywhere (Linux too): `--stamp <app>` writes the extension's Info.plist from the app's: a
# com.apple.share-services extension for images only, titled "<app name> Chat", with the app's
# bundle id as its prefix and the app's version; an app with no extension is left alone.
#
# On a Mac (a fleet Mac: scripts/measure/share-extension.sh), under Xcode's /bin/bash 3.2: the Xcode
# phase builds it into a stand-in app (both slices, signed with the App Sandbox), `pluginkit -a`
# registers it, NSSharingService lists it for a PNG's file URL under its title, and performing that
# service from a script, with no sheet and no click, hands the PNG to the app that carries it, which
# writes down the files it was opened with. The phase's second run reuses the compiled executable.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/bundle-share-extension.sh"
TMP=$(mktemp -d)
registered=()
cleanup() {
  local path
  for path in ${registered[@]+"${registered[@]}"}; do /usr/bin/pluginkit -r "$path" >/dev/null 2>&1 || true; done
  if [[ -n "${host_app:-}" && -x "${LSREGISTER:-}" ]]; then "$LSREGISTER" -u "$host_app" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

plist_value() { # <plist> <dotted key path>
  python3 -I -c '
import plistlib, sys
value = plistlib.load(open(sys.argv[1], "rb"))
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)' "$1" "$2"
}

# The host claims images the way the app does (Resources/Info.plist's "Image" document type): a sandboxed
# extension may open files only with an app that claims their type, else Launch Services refuses with
# kLSAppDoesNotClaimTypeErr (-10820, "sandboxed callers only") and the host never launches.
write_app_plist() { # <app> <id> <name> <executable>
  mkdir -p "$1/Contents"
  python3 -I -c '
import plistlib, sys
images = {"CFBundleTypeName": "Image", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
          "LSItemContentTypes": ["public.png", "public.jpeg", "public.image"]}
plistlib.dump({"CFBundleIdentifier": sys.argv[2], "CFBundleName": sys.argv[3], "CFBundleExecutable": sys.argv[4],
               "CFBundlePackageType": "APPL", "CFBundleVersion": "4242", "CFBundleShortVersionString": "0.99.1",
               "LSMinimumSystemVersion": "14.0", "LSUIElement": True, "CFBundleDocumentTypes": [images]},
              open(sys.argv[1], "wb"))' \
    "$1/Contents/Info.plist" "$2" "$3" "$4"
}

check_plist() { # <appex Info.plist> <app id> <app name>
  local info="$1"
  [[ "$(plist_value "$info" NSExtension.NSExtensionPointIdentifier)" == com.apple.share-services ]] ||
    fail "not a Share extension" "$(cat "$info")"
  [[ "$(plist_value "$info" NSExtension.NSExtensionAttributes.NSExtensionActivationRule.NSExtensionActivationSupportsImageWithMaxCount)" -ge 1 ]] ||
    fail "the activation rule takes no images" "$(cat "$info")"
  [[ "$(plist_value "$info" NSExtension.NSExtensionAttributes.NSExtensionActivationRule.NSExtensionActivationSupportsFileWithMaxCount)" == "" ]] ||
    fail "the activation rule takes any file, not only images" "$(cat "$info")"
  [[ "$(plist_value "$info" NSExtension.NSExtensionPrincipalClass)" == CmuxShareViewController ]] ||
    fail "principal class" "$(cat "$info")"
  [[ "$(plist_value "$info" CFBundleIdentifier)" == "$2.share" ]] || fail "bundle id is not the app's plus .share" "$(cat "$info")"
  [[ "$(plist_value "$info" CFBundleDisplayName)" == "$3 Chat" ]] || fail "title" "$(cat "$info")"
  [[ "$(plist_value "$info" CFBundlePackageType)" == "XPC!" ]] || fail "package type" "$(cat "$info")"
  [[ "$(plist_value "$info" CFBundleVersion)" == 4242 && "$(plist_value "$info" CFBundleShortVersionString)" == 0.99.1 ]] ||
    fail "the extension's version is not the app's" "$(cat "$info")"
}

# 1. --stamp: a renamed app (as nightly renames it after the build) re-stamps its extension.
app="$TMP/stamp/cmux NEXT Nightly.app"
write_app_plist "$app" com.cmuxterm.app.nightly-next "cmux NEXT Nightly" cmux
mkdir -p "$app/Contents/PlugIns/CmuxShare.appex/Contents"
printf '<plist><dict/></plist>\n' > "$app/Contents/PlugIns/CmuxShare.appex/Contents/Info.plist"
out=$(bash "$SCRIPT" --stamp "$app" 2>&1) || fail "--stamp failed" "$out"
check_plist "$app/Contents/PlugIns/CmuxShare.appex/Contents/Info.plist" com.cmuxterm.app.nightly-next "cmux NEXT Nightly"
bare="$TMP/bare/cmux.app"
write_app_plist "$bare" com.cmuxterm.app.next cmux cmux
out=$(bash "$SCRIPT" --stamp "$bare" 2>&1) || fail "--stamp of an app with no extension failed" "$out"
[[ ! -e "$bare/Contents/PlugIns" ]] || fail "--stamp made a PlugIns folder in an app with no extension"
# The release signers sign it with the App Sandbox; macOS loads no unsandboxed extension.
python3 -I -c 'import plistlib, sys; sys.exit(plistlib.load(open(sys.argv[1], "rb")) != {"com.apple.security.app-sandbox": True})' \
  "$ROOT/scripts/cmux-next/share-extension.entitlements" || fail "share-extension.entitlements is not the App Sandbox alone"
echo "PASS bundle-share-extension --stamp"

[[ "$(uname -s)" == Darwin ]] || { echo "SKIP the build, registration and perform (macOS only)"; exit 0; }

# 2. The Xcode phase into a stand-in host app that writes down the files it is opened with.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
suffix="$(date +%s)-$$"
host_name="Share Test $suffix"
host_app="$TMP/build/$host_name.app"
write_app_plist "$host_app" "com.cmuxterm.test.share-host.$suffix" "$host_name" ShareHost
mkdir -p "$host_app/Contents/MacOS"
cat > "$TMP/host.swift" <<'SWIFT'
import AppKit
final class Host: NSObject, NSApplicationDelegate {
    // Written at launch, so a missing opened.txt says whether the host never started or started without the files.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let out = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("launched.txt")
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: out, atomically: true, encoding: .utf8)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let out = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("opened.txt")
        try? (urls.map(\.path).joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        application.terminate(nil)
    }
}
let host = Host()
NSApplication.shared.delegate = host
NSApplication.shared.run()
SWIFT
xcrun swiftc -O "$TMP/host.swift" -o "$host_app/Contents/MacOS/ShareHost" || fail "the stand-in host did not compile"
codesign --force --sign - "$host_app" >/dev/null 2>&1 || true
run_phase() {
  env SRCROOT="$ROOT" TARGET_BUILD_DIR="$TMP/build" UNLOCALIZED_RESOURCES_FOLDER_PATH="$host_name.app/Contents/Resources" \
    TARGET_TEMP_DIR="$TMP/temp" ARCHS="arm64 x86_64" MACOSX_DEPLOYMENT_TARGET=14.0 EXPANDED_CODE_SIGN_IDENTITY= \
    /bin/bash "$SCRIPT"
}
out=$(run_phase 2>&1) || fail "the phase failed" "$out"
appex="$host_app/Contents/PlugIns/CmuxShare.appex"
check_plist "$appex/Contents/Info.plist" "com.cmuxterm.test.share-host.$suffix" "$host_name"
archs=$(lipo -archs "$appex/Contents/MacOS/CmuxShare")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "slices: $archs"
codesign --verify --strict "$appex" || fail "the extension's signature does not verify"
codesign -d --entitlements :- "$appex" 2>/dev/null | grep -q com.apple.security.app-sandbox ||
  fail "the extension is not signed with the App Sandbox"
[[ -f "$TMP/temp/bundle-share-extension.stamp" ]] || fail "no phase stamp"
again=$(run_phase 2>&1) || fail "the second run failed" "$again"
[[ "$(ls "$TMP/temp/share-extension" | grep -c '^CmuxShare-')" == 1 ]] || fail "the second run compiled again" "$again"
codesign --force --sign - "$host_app" >/dev/null 2>&1 || fail "the host did not sign around its extension"
echo "PASS the phase builds a signed, sandboxed, universal extension"

# 3. Registered, listed for a PNG under its title, and performed from a script: the host gets the PNG.
"$LSREGISTER" -f "$host_app" || fail "lsregister refused the host"
/usr/bin/pluginkit -a "$appex" || fail "pluginkit -a refused the extension"
registered+=("$appex")
listing=$(/usr/bin/pluginkit -m -v -p com.apple.share-services 2>&1 || true)
[[ "$listing" == *"$appex"* ]] || fail "pluginkit does not list the extension" "$listing"
python3 -I -c 'import base64, sys; open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))' "$TMP/shot.png"
cat > "$TMP/perform.swift" <<'SWIFT'
import AppKit
final class Watch: NSObject, NSSharingServiceDelegate {
    var shared: Bool?
    var error = ""
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { shared = true }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        shared = false
        self.error = error.localizedDescription
    }
}
let arguments = CommandLine.arguments
let title = arguments[1], url = URL(fileURLWithPath: arguments[2]), opened = arguments[3]
_ = NSApplication.shared.setActivationPolicy(.accessory)
let services = NSSharingService.sharingServices(forItems: [url])
guard let service = services.first(where: { $0.title == title }) else {
    let image = NSImage(contentsOf: url).map { NSSharingService.sharingServices(forItems: [$0]).map(\.title) } ?? []
    print("no Share service titled \(title); offered for the file: \(services.map(\.title)); for the image: \(image)")
    exit(2)
}
let watch = Watch()
service.delegate = watch
guard service.canPerform(withItems: [url]) else { print("canPerform said no"); exit(3) }
service.perform(withItems: [url])
let end = Date().addingTimeInterval(15)
while !FileManager.default.fileExists(atPath: opened) && watch.shared != false && Date() < end {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
print("shared: \(watch.shared.map(String.init(describing:)) ?? "no answer") \(watch.error)")
exit(FileManager.default.fileExists(atPath: opened) ? 0 : 4)
SWIFT
xcrun swiftc "$TMP/perform.swift" -o "$TMP/perform" || fail "the performer did not compile"
ext_id="com.cmuxterm.test.share-host.$suffix.share"
# Shared but no PNG at the host: whether the host launched, and what the extension, the sandbox and
# LaunchServices logged while it ran.
handoff_trace() {
  local launched="never launched"
  [[ -f "$TMP/build/launched.txt" ]] && launched="launched, pid $(cat "$TMP/build/launched.txt")"
  printf 'host: %s\nlog:\n' "$launched"
  /usr/bin/log show --last 2m --style compact --predicate \
    'process == "CmuxShare" OR process == "ShareHost" OR eventMessage CONTAINS "CmuxShare" OR eventMessage CONTAINS "share-host"' \
    2>&1 | grep -v '^Timestamp\|^Filtering' | tail -60 || true
  # ShareViewController's own steps (loadView, beginRequest, each loadItem, the open and its answer): none at all
  # means the extension's principal class never loaded.
  printf 'extension steps (%s):\n' "$ext_id"
  /usr/bin/log show --last 2m --style compact --info --predicate "subsystem == \"$ext_id\"" \
    2>&1 | grep -v '^Timestamp\|^Filtering' | tail -30 || true
}
said=$("$TMP/perform" "$host_name Chat" "$TMP/shot.png" "$TMP/build/opened.txt" 2>&1) || {
  status=$?
  # Not offered: say whether macOS registered it switched off (pluginkit's "-" or no mark), then switch it on
  # (pluginkit -e use, what System Settings' Extensions pane does) and ask again.
  [[ $status == 2 ]] ||
    fail "performing the Share service did not hand the PNG to the host within 15 s" "$said"$'\n'"$(handoff_trace)"
  election=$(/usr/bin/pluginkit -m -v -i "$ext_id" 2>&1 || true)
  /usr/bin/pluginkit -e use -i "$ext_id" || fail "pluginkit -e use refused the extension" "$said"$'\n'"$election"
  said=$("$TMP/perform" "$host_name Chat" "$TMP/shot.png" "$TMP/build/opened.txt" 2>&1) ||
    fail "not offered as registered, nor after pluginkit -e use" \
      "registered as: $election"$'\n'"$said"$'\n'"$(handoff_trace)"
  echo "NOTE: offered only after pluginkit -e use; registered as: $election"
}
grep -qx "$(cd "$TMP" && pwd -P)/shot.png\|$TMP/shot.png" "$TMP/build/opened.txt" ||
  fail "the host was opened with something else" "$(cat "$TMP/build/opened.txt")"
echo "PASS performing \"$host_name Chat\" opens the PNG with the app that carries the extension ($said)"
