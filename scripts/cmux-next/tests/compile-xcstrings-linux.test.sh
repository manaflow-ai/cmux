#!/usr/bin/env bash
# scripts/cmux-next/linux/compile-xcstrings.py, on Linux with Swift:
# a scratch package holds the real CmuxNextActions ActionCatalog.xcstrings and takes
# its compiled tables the way the Linux mode of Packages/macOS/CmuxNext/Package.swift
# does (.process("LinuxStringTables")). Its sources are the real lookup code, copied
# unchanged: familyTitle and the "Workspace: Move…" call site of
# ActionDescriptor+PaletteRank.swift, and the String(localized:defaultValue:table:bundle:)
# of CMUXMobileCore's String+LocalizationValue+Portable.swift that serves it off Darwin.
# The real call site then returns the catalog's English title, and with a different
# fallback still the table's text, under the C locale and an English one; the German
# table has the German text; and the same build without the tables gives the fallback.
# Usage: compile-xcstrings-linux.test.sh   (SWIFT: the swift binary, default `swift`)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
actions="$root/Packages/macOS/CmuxNext/Sources/CmuxNextActions"
catalog="$actions/ActionCatalog.xcstrings"
palette_rank="$actions/ActionDescriptor+PaletteRank.swift"
shim="$root/Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/String+LocalizationValue+Portable.swift"
compile="$root/scripts/cmux-next/linux/compile-xcstrings.py"
swift="${SWIFT:-swift}"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "skip: Linux only"; exit 0; }
command -v "$swift" >/dev/null 2>&1 || { echo "skip: no swift (scripts/cmux-next/linux/setup-swift.sh)"; exit 0; }
export SWIFT="$swift"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/pkg"
target="$pkg/Sources/CmuxNextActions"
mkdir -p "$target"
cp "$catalog" "$shim" "$target/"
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

key="palette.family.workspace.move"
# The familyTitle function and its call for $key, verbatim from the real source.
python3 -I - "$palette_rank" "$key" > "$target/PaletteRank.swift" <<'PY' || fail "familyTitle or its $key call is not in $palette_rank"
import re, sys
source = open(sys.argv[1], encoding="utf-8").read()
function = re.search(r"(?ms)^( *)(?:private )?nonisolated static func familyTitle\(.*?^\1\}\n", source)
call = re.search(r'familyTitle\("' + re.escape(sys.argv[2]) + r'", "[^"\\]*"\)', source)
if not function or not call:
    sys.exit(1)
print("import Foundation\n\nenum ActionDescriptor {")
print(function.group(0), end="")
print(f"    static func realCallSite() -> String {{ {call.group(0)} }}")
print(f'    static func tableOnly() -> String {{ familyTitle("{sys.argv[2]}", "<fallback>") }}')
print("}")
PY
cat > "$target/main.swift" <<'SWIFT'
import Foundation

// family: the real call site, then the same key with a fallback no table has.
// <key> <lang>: that language's table, read through Bundle directly.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["family"] {
    print(ActionDescriptor.realCallSite())
    print(ActionDescriptor.tableOnly())
} else if arguments.count == 2, let path = Bundle.module.path(forResource: arguments[1], ofType: "lproj"),
          let bundle = Bundle(path: path) {
    print(bundle.localizedString(forKey: arguments[0], value: "<missing>", table: "ActionCatalog"))
} else {
    print("<usage>")
}
SWIFT

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
[[ -L "$target/LinuxStringTables" ]] || fail "no LinuxStringTables link"

"$swift" build --package-path "$pkg" --scratch-path "$tmp/build" >"$tmp/build.log" 2>&1 \
  || { tail -n 30 "$tmp/build.log" >&2; fail "swift build"; }
bin="$tmp/build/debug/CmuxNextActions"
for lang in C.UTF-8 en_US.UTF-8; do
  got="$(env LANG="$lang" LC_ALL= LANGUAGE= "$bin" family)"
  [[ "$got" == "$english"$'\n'"$english" ]] || fail "LANG=$lang: '$got', want '$english' twice"
done
# swift-corelibs-foundation picks English whatever the locale, so the German table is read directly.
got="$("$bin" "$key" de)"
[[ "$got" == "$german" ]] || fail "de.lproj: '$got', want '$german'"

# The control: the same build without the tables shows the fallback.
rm "$target/LinuxStringTables"
mkdir "$target/LinuxStringTables"
# A fresh build folder: SwiftPM leaves resources of an earlier build in the bundle.
"$swift" build --package-path "$pkg" --scratch-path "$tmp/build-empty" >"$tmp/build.log" 2>&1 \
  || { tail -n 30 "$tmp/build.log" >&2; fail "swift build without tables"; }
got="$(env LANG=C.UTF-8 "$tmp/build-empty/debug/CmuxNextActions" family)"
[[ "$got" == "$english"$'\n'"<fallback>" ]] || fail "without tables: '$got', want '$english' then the fallback"
echo "PASS: familyTitle(\"$key\", ...) resolves to '$english' from the compiled table (de: '$german')"
