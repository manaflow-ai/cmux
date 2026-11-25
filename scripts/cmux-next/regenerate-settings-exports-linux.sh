#!/usr/bin/env bash
# Regenerates the settings exports listed in scripts/cmux-next/settings-exports.txt (docs/mdm/*, and
# schemas/settings/settings-schema.json) on Linux, with the contract of regenerate-settings-exports.sh, the Mac
# script it stands in for: the exports that changed are copied into OUT at their repository paths.
#
# No Mac and no Xcode: a scratch Swift package (in CmuxNext's .build) builds the settings schema and managed
# preferences model (Packages/macOS/CmuxNext/LinuxSettingsExports/sources.txt, plus the files
# gen-settings-sources.py generates), CmuxNextActions' model files (the action exporter's list) and the
# `cmux-next-settings-exports` tool. The tool writes the files through the code the Mac's tests compare them with
# (ManagedPreferencesManifest.exportFiles, SettingsSchemaExport), so a new setting reaches both the same way.
#
# Needs swift (6.2), python3 and cargo (the Actions model links the pinned Rust action catalog).
# Usage: scripts/cmux-next/regenerate-settings-exports-linux.sh OUT
set -euo pipefail
out="$(mkdir -p "${1:?usage: $0 OUT}" && cd "$1" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Packages/macOS/CmuxNext"
tool="$package/LinuxSettingsExports"
actions="$package/LinuxActionExports"

started=$SECONDS
catalog="$package/.build/linux-action-catalog"
"$root/scripts/cmux-next/build-action-catalog-linux.sh" "$catalog"

scratch="$package/.build/linux-settings-exports"
rm -rf -- "$scratch/package" "$scratch/written"
mkdir -p "$scratch/package/Sources/CmuxNextActions" "$scratch/package/Sources/CmuxNextSettings" \
  "$scratch/package/Sources/CmuxNextSettingsExports" "$scratch/written"
link_files() { # LIST SOURCE_DIR TARGET_DIR
  while IFS= read -r file; do
    case "$file" in ''|'#'*) continue ;; esac
    mkdir -p "$3/$(dirname "$file")"
    ln -s "$2/$file" "$3/$file"
  done < "$1"
}
link_files "$actions/sources.txt" "$package/Sources/CmuxNextActions" "$scratch/package/Sources/CmuxNextActions"
link_files "$tool/sources.txt" "$package/Sources/CmuxNextSettings" "$scratch/package/Sources/CmuxNextSettings"
# The generated half of CmuxNextSettings, from the same script the SettingsSchemaPlugin runs on the Mac.
python3 -I "$root/scripts/cmux-next/gen-settings-sources.py" --swift-out "$scratch/package/Sources/CmuxNextSettings/Generated"
ln -s "$tool/LinuxShims.swift" "$scratch/package/Sources/CmuxNextSettings/LinuxShims.swift"
ln -s "$tool/main.swift" "$scratch/package/Sources/CmuxNextSettingsExports/main.swift"
ln -s "$catalog/include" "$scratch/package/Sources/CCmuxActionCatalogFFI"
# Modules the Mac's files import and use nothing of here (their AppKit and UI users are not in the lists).
for stub in CmuxNextDesign CmuxNextCompat CoreGraphics; do
  mkdir -p "$scratch/package/Sources/$stub"
  echo "// Empty on Linux: the settings model imports $stub for UI types this build leaves out." > "$scratch/package/Sources/$stub/Stub.swift"
done
cat > "$scratch/package/Package.swift" <<SWIFT
// swift-tools-version: 6.2
// Made by scripts/cmux-next/regenerate-settings-exports-linux.sh; never committed.
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxNextLinuxSettingsExports",
    products: [.executable(name: "cmux-next-settings-exports", targets: ["CmuxNextSettingsExports"])],
    targets: [
        .systemLibrary(name: "CCmuxActionCatalogFFI"),
        .target(name: "CmuxNextDesign"),
        .target(name: "CmuxNextCompat"),
        .target(name: "CoreGraphics"),
        .target(
            name: "CmuxNextActions",
            dependencies: ["CCmuxActionCatalogFFI"],
            swiftSettings: settings + [.define("CMUX_LINUX_EXPORT")],
            linkerSettings: [.unsafeFlags(["-L", "$catalog/lib"])]
        ),
        .target(
            name: "CmuxNextSettings",
            dependencies: ["CmuxNextActions", "CmuxNextDesign", "CmuxNextCompat", "CoreGraphics"],
            swiftSettings: settings
        ),
        .executableTarget(name: "CmuxNextSettingsExports", dependencies: ["CmuxNextSettings"], swiftSettings: settings),
    ]
)
SWIFT
swift build --package-path "$scratch/package" --scratch-path "$scratch/build" --product cmux-next-settings-exports
"$scratch/build/debug/cmux-next-settings-exports" "$scratch/written" "$root"
echo "linux settings exports: built and written in $((SECONDS - started))s"

while IFS= read -r file; do
  case "$file" in ''|'#'*) continue ;; esac
  rm -f -- "$out/$file"
  cmp -s "$scratch/written/$file" "$root/$file" && continue
  mkdir -p "$out/$(dirname "$file")"
  cp "$scratch/written/$file" "$out/$file"
  echo "regenerated: $file"
done < "$root/scripts/cmux-next/settings-exports.txt"
