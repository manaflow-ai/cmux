#!/usr/bin/env bash
# Regenerates the settings exports listed in scripts/cmux-next/settings-exports.txt (docs/mdm/*, and
# schemas/settings/settings-schema.json) on Linux, with the contract of regenerate-settings-exports.sh, the Mac
# script it stands in for: the exports that changed are copied into OUT at their repository paths, and OUT.patch
# (beside OUT, never in it) holds one `git apply` patch of them after a one-line header.
#
# No Mac and no Xcode: a scratch Swift package (in CmuxNext's .build) builds the settings model with the modules it
# reads, from links to this checkout's files:
#   CmuxNextSettings, CmuxNextDesignTokens  every file but those that import an Apple-only module (APPLE_ONLY below)
#                                           or are listed in LinuxSettingsExports/excluded.txt;
#   CmuxNextDesign, CmuxNextCompat          the files in LinuxSettingsExports/design-sources.txt and
#                                           compat-sources.txt;
#   CmuxNextActions                         the action exporter's list (LinuxActionExports/sources.txt), linked
#                                           against the pinned Rust action catalog (build-action-catalog-linux.sh);
#   CoreGraphics, and Linux stand-ins       LinuxSettingsExports/StandIns, for the few Apple names the model reads;
#   CmuxTheme                               Packages/Shared/CmuxTheme, as is;
#   CCmuxMotionFFI                          the pinned cmux-motion C ABI, built for Linux (build-motion-ffi-linux.sh);
# plus the generated half of CmuxNextSettings (gen-settings-sources.py, as the Mac's SettingsSchemaPlugin runs it).
# The `cmux-next-settings-exports` tool writes the files through the code the Mac's tests compare them with
# (ManagedPreferencesManifest.exportFiles, SettingsSchemaExport), so a new setting reaches both the same way. A
# model file that starts using AppKit breaks this build, and the Mac job regenerates the exports instead.
#
# Needs swift (6.2), python3 and cargo. Usage: scripts/cmux-next/regenerate-settings-exports-linux.sh OUT
set -euo pipefail
out="$(mkdir -p "${1:?usage: $0 OUT}" && cd "$1" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Packages/macOS/CmuxNext"
tool="$package/LinuxSettingsExports"
exports_list="$root/scripts/cmux-next/settings-exports.txt"
APPLE_ONLY='AppKit|SwiftUI|QuartzCore|ImageIO|ObjectiveC|UniformTypeIdentifiers|Darwin|AVFoundation|WebKit|CoreImage|Metal|CoreText|ScreenCaptureKit|CoreMedia|CoreVideo|CoreFoundation|SystemConfiguration|OSLog|os|CryptoKit|Security|XPC|Network|MachO|LocalAuthentication|CmuxNextWakeups|CmuxNextIcons|CmuxEgress|CmuxAgentBrands|CCmux[A-Za-z]*FFI'

started=$SECONDS
catalog="$package/.build/linux-action-catalog"
"$root/scripts/cmux-next/build-action-catalog-linux.sh" "$catalog"
motion="$package/.build/linux-motion-ffi"
"$root/scripts/cmux-next/build-motion-ffi-linux.sh" "$motion"

# The scratch package: links to the checkout's files, remade each run so a file dropped from a list is gone.
scratch="$package/.build/linux-settings-exports"
sources="$scratch/package/Sources"
rm -rf -- "$scratch/package" "$scratch/written"
mkdir -p "$sources" "$scratch/written"
link() { # SOURCE_DIR TARGET RELATIVE_FILE
  mkdir -p "$sources/$2/$(dirname "$3")"
  ln -s "$1/$3" "$sources/$2/$3"
}
link_list() { # LIST MODULE
  while IFS= read -r file; do
    case "$file" in ''|'#'*) continue ;; esac
    link "$package/Sources/$2" "$2" "$file"
  done < "$1"
}
link_portable() { # MODULE: every file that imports no Apple-only module, less excluded.txt's MODULE/ lines
  local dir="$package/Sources/$1" file
  while IFS= read -r file; do
    file="${file#./}"
    grep -qxF "$1/$file" "$tool/excluded.txt" && continue
    # The motion FFI is built for Linux (build-motion-ffi-linux.sh); any other Apple-only import leaves the file out.
    grep -E "^[[:space:]]*(@[A-Za-z_]+ +)*((public|internal|package) +)?import +($APPLE_ONLY)\b" "$dir/$file" |
      grep -qvE "import +CCmuxMotionFFI\b" && continue
    link "$dir" "$1" "$file"
  done < <(cd "$dir" && find . -name '*.swift' | LC_ALL=C sort)
}
link_list "$package/LinuxActionExports/sources.txt" CmuxNextActions
link_list "$tool/design-sources.txt" CmuxNextDesign
link_list "$tool/compat-sources.txt" CmuxNextCompat
link_portable CmuxNextDesignTokens
link_portable CmuxNextSettings
python3 -I "$root/scripts/cmux-next/gen-settings-sources.py" --swift-out "$sources/CmuxNextSettings/Generated" >/dev/null
for module in CmuxNextCompat CmuxNextDesign CmuxNextSettings CoreGraphics; do
  mkdir -p "$sources/$module"
  ln -s "$tool/StandIns/$module.swift" "$sources/$module/LinuxStandIns.swift"
done
mkdir -p "$sources/CmuxNextSettingsExports"
ln -s "$tool/main.swift" "$sources/CmuxNextSettingsExports/main.swift"
# SwiftPM takes no target path outside the package: the module map and header, linked in.
ln -s "$catalog/include" "$sources/CCmuxActionCatalogFFI"
ln -s "$motion/include" "$sources/CCmuxMotionFFI"
# Swift settings: CmuxNext's (Package.swift): uiSwiftSettings for Actions, DesignTokens and Design, and
# daemonSwiftSettings for Settings, as on the Mac.
cat > "$scratch/package/Package.swift" <<SWIFT
// swift-tools-version: 6.2
// Made by scripts/cmux-next/regenerate-settings-exports-linux.sh; never committed.
import PackageDescription

let daemon: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
let ui: [SwiftSetting] = daemon + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "CmuxNextLinuxSettingsExports",
    products: [.executable(name: "cmux-next-settings-exports", targets: ["CmuxNextSettingsExports"])],
    dependencies: [.package(path: "$root/Packages/Shared/CmuxTheme")],
    targets: [
        .systemLibrary(name: "CCmuxActionCatalogFFI"),
        .systemLibrary(name: "CCmuxMotionFFI"),
        .target(name: "CoreGraphics", swiftSettings: daemon),
        .target(name: "CmuxNextCompat", swiftSettings: daemon),
        .target(
            name: "CmuxNextActions",
            dependencies: ["CCmuxActionCatalogFFI"],
            swiftSettings: ui + [.define("CMUX_LINUX_EXPORT")],
            linkerSettings: [.unsafeFlags(["-L", "$catalog/lib"])]
        ),
        .target(
            name: "CmuxNextDesignTokens",
            dependencies: ["CCmuxMotionFFI", "CmuxNextCompat", "CoreGraphics", .product(name: "CmuxTheme", package: "CmuxTheme")],
            swiftSettings: ui,
            linkerSettings: [.unsafeFlags(["-L", "$motion/lib"])]
        ),
        .target(
            name: "CmuxNextDesign",
            dependencies: ["CCmuxMotionFFI", "CmuxNextCompat", "CmuxNextDesignTokens", "CoreGraphics", .product(name: "CmuxTheme", package: "CmuxTheme")],
            swiftSettings: ui
        ),
        .target(
            name: "CmuxNextSettings",
            dependencies: ["CmuxNextActions", "CmuxNextCompat", "CmuxNextDesign", "CoreGraphics"],
            swiftSettings: daemon
        ),
        .executableTarget(name: "CmuxNextSettingsExports", dependencies: ["CmuxNextSettings"], swiftSettings: daemon),
    ]
)
SWIFT
swift build --package-path "$scratch/package" --scratch-path "$scratch/build" --product cmux-next-settings-exports
"$scratch/build/debug/cmux-next-settings-exports" "$scratch/written" "$root"
echo "linux settings exports: built and written in $((SECONDS - started))s"

cd "$root"
exports=()
while IFS= read -r file; do
  case "$file" in ''|'#'*) continue ;; esac
  exports+=("$file")
  # OUT can sit in a kept .build: drop an earlier run's copy, so only what this run regenerated is handed over.
  rm -f -- "$out/$file"
  cmp -s "$scratch/written/$file" "$file" && continue
  mkdir -p "$out/$(dirname "$file")"
  cp "$scratch/written/$file" "$out/$file"
  echo "regenerated: $file"
done < "$exports_list"
{
  echo "regenerate-settings-exports-linux.sh at $(git rev-parse HEAD): the exports that changed (none when no diff follows)"
  for file in "${exports[@]}"; do
    [ -f "$out/$file" ] || continue
    git diff --no-index --binary -- "$file" "$out/$file" | sed -e "s#b$out/#b/#g" || true
  done
} > "$out.patch"
echo "patch: $out.patch ($(wc -l < "$out.patch" | tr -d ' ') lines)"
