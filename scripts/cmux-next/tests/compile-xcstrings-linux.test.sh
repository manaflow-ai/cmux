#!/usr/bin/env bash
# scripts/cmux-next/linux/compile-xcstrings.py (p15-oracle-228), on Linux with Swift:
# a scratch package holds the real CmuxNextActions ActionCatalog.xcstrings and takes
# its compiled tables the way the Linux mode of Packages/macOS/CmuxNext/Package.swift
# does (.process("LinuxStringTables")). Foundation then resolves an ActionCatalog
# palette title to its English text, under the C locale and an English one, and the
# German table has the German text; without the tables it finds nothing.
# Usage: compile-xcstrings-linux.test.sh   (SWIFT: the swift binary, default `swift`)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
catalog="$root/Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionCatalog.xcstrings"
compile="$root/scripts/cmux-next/linux/compile-xcstrings.py"
swift="${SWIFT:-swift}"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "skip: Linux only"; exit 0; }
command -v "$swift" >/dev/null 2>&1 || { echo "skip: no swift (scripts/cmux-next/linux/setup-swift.sh)"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/pkg"
mkdir -p "$pkg/Sources/CmuxNextActions"
cp "$catalog" "$pkg/Sources/CmuxNextActions/"
cat > "$pkg/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompileXcstringsCheck",
    defaultLocalization: "en",
    targets: [
        .executableTarget(
            name: "CmuxNextActions",
            resources: [.process("ActionCatalog.xcstrings"), .process("LinuxStringTables")]
        ),
    ]
)
SWIFT
cat > "$pkg/Sources/CmuxNextActions/main.swift" <<'SWIFT'
import Foundation

// <key>: the lookup String(localized:) makes; <key> <lang>: that language's table.
let arguments = CommandLine.arguments.dropFirst()
var bundle = Bundle.module
if arguments.count == 2, let path = bundle.path(forResource: arguments.last, ofType: "lproj") {
    bundle = Bundle(path: path) ?? bundle
}
print(bundle.localizedString(forKey: arguments.first ?? "", value: "<missing>", table: "ActionCatalog"))
SWIFT

key="palette.family.workspace.move"
text() {
  python3 -I -c 'import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["strings"][sys.argv[2]]["localizations"][sys.argv[3]]["stringUnit"]["value"])' \
    "$catalog" "$key" "$1"
}
english="$(text en)"
german="$(text de)"
[[ -n "$english" && -n "$german" && "$english" != "$german" ]] || fail "no distinct en/de text for $key"

python3 -I "$compile" --package "$pkg" >/dev/null
python3 -I "$compile" --package "$pkg" --check >/dev/null || fail "a second run would still change files"
[[ -L "$pkg/Sources/CmuxNextActions/LinuxStringTables" ]] || fail "no LinuxStringTables link"

"$swift" build --package-path "$pkg" --scratch-path "$tmp/build" >"$tmp/build.log" 2>&1 \
  || { tail -n 30 "$tmp/build.log" >&2; fail "swift build"; }
bin="$tmp/build/debug/CmuxNextActions"
for lang in C.UTF-8 en_US.UTF-8; do
  got="$(env LANG="$lang" LC_ALL= LANGUAGE= "$bin" "$key")"
  [[ "$got" == "$english" ]] || fail "LANG=$lang: '$got', want '$english'"
done
# swift-corelibs-foundation picks English whatever the locale, so the German table is read directly.
got="$("$bin" "$key" de)"
[[ "$got" == "$german" ]] || fail "de.lproj: '$got', want '$german'"

# The control: the same build without the tables shows the fallback.
rm "$pkg/Sources/CmuxNextActions/LinuxStringTables"
mkdir "$pkg/Sources/CmuxNextActions/LinuxStringTables"
# A fresh build folder: SwiftPM leaves resources of an earlier build in the bundle.
"$swift" build --package-path "$pkg" --scratch-path "$tmp/build-empty" >"$tmp/build.log" 2>&1 \
  || { tail -n 30 "$tmp/build.log" >&2; fail "swift build without tables"; }
got="$(env LANG=C.UTF-8 "$tmp/build-empty/debug/CmuxNextActions" "$key")"
[[ "$got" == "<missing>" ]] || fail "without tables: '$got', want the fallback"
echo "PASS: $key resolves to '$english' (de: '$german') from the compiled tables"
