#!/usr/bin/env bash
# Regenerates the action exports (plans/cmux-next/action-surfaces.json, action-catalog.json, actions.md and
# links.json) on Linux, with the contract of regenerate-action-exports.sh, the Mac script it stands in for: the
# exports that changed are copied into OUT at their repository paths, and OUT.patch (beside OUT, never in it)
# holds one `git apply` patch of them after a one-line header.
#
# No Mac and no Xcode: a scratch Swift package (in CmuxNext's .build) builds CmuxNextActions' model files
# (Packages/macOS/CmuxNext/LinuxActionExports/sources.txt) and the `cmux-next-action-exports` tool, linked against
# cmux-action-catalog built at the app's CCmuxAppFFI pin (build-action-catalog-linux.sh), so the exports read the
# Rust catalog the Mac app links. The tool writes the files through the code the Mac's parity tests use
# (ActionExports), so the Mac's CMUX_CHECK_GENERATED_EXPORTS tests check these bytes.
#
# Needs swift (6.2) and cargo. Usage: scripts/cmux-next/regenerate-action-exports-linux.sh OUT
set -euo pipefail
out="$(mkdir -p "${1:?usage: $0 OUT}" && cd "$1" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Packages/macOS/CmuxNext"
tool="$package/LinuxActionExports"
exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/action-catalog.json plans/cmux-next/actions.md plans/cmux-next/links.json)

started=$SECONDS
catalog="$package/.build/linux-action-catalog"
"$root/scripts/cmux-next/build-action-catalog-linux.sh" "$catalog"

# The scratch package: links to the checkout's files, remade each run so a file dropped from sources.txt is gone.
scratch="$package/.build/linux-action-exports"
rm -rf -- "$scratch/package"
mkdir -p "$scratch/package/Sources/CmuxNextActions" "$scratch/package/Sources/CmuxNextActionExports"
while IFS= read -r file; do
  case "$file" in ''|'#'*) continue ;; esac
  mkdir -p "$scratch/package/Sources/CmuxNextActions/$(dirname "$file")"
  ln -s "$package/Sources/CmuxNextActions/$file" "$scratch/package/Sources/CmuxNextActions/$file"
done < "$tool/sources.txt"
ln -s "$tool/main.swift" "$scratch/package/Sources/CmuxNextActionExports/main.swift"
# SwiftPM takes no target path outside the package: the module map and header, linked in.
ln -s "$catalog/include" "$scratch/package/Sources/CCmuxActionCatalogFFI"
# Swift settings: CmuxNext's uiSwiftSettings (Package.swift), which CmuxNextActions builds with on the Mac.
cat > "$scratch/package/Package.swift" <<SWIFT
// swift-tools-version: 6.2
// Made by scripts/cmux-next/regenerate-action-exports-linux.sh; never committed.
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
    name: "CmuxNextLinuxActionExports",
    products: [.executable(name: "cmux-next-action-exports", targets: ["CmuxNextActionExports"])],
    targets: [
        .systemLibrary(name: "CCmuxActionCatalogFFI"),
        .target(
            name: "CmuxNextActions",
            dependencies: ["CCmuxActionCatalogFFI"],
            swiftSettings: settings + [.define("CMUX_LINUX_EXPORT")],
            linkerSettings: [.unsafeFlags(["-L", "$catalog/lib"])]
        ),
        .executableTarget(name: "CmuxNextActionExports", dependencies: ["CmuxNextActions"], swiftSettings: settings),
    ]
)
SWIFT
swift build --package-path "$scratch/package" --scratch-path "$scratch/build" --product cmux-next-action-exports
"$scratch/build/debug/cmux-next-action-exports" "$root"
# The tool writes only the files whose bytes changed (an export already current keeps its mtime); a run that
# succeeded wrote every export, as the Mac's tests do, so stamp them all (base-autofix-exports-pack.sh checks it).
(cd "$root" && touch -- "${exports[@]}")
echo "linux action exports: built and written in $((SECONDS - started))s"

cd "$root"
for file in "${exports[@]}"; do
  # OUT can sit in a kept .build: drop an earlier run's copy, so only what this run regenerated is handed over.
  rm -f -- "$out/$file"
  git diff --quiet -- "$file" && continue
  mkdir -p "$out/$(dirname "$file")"
  cp "$file" "$out/$file"
  echo "regenerated: $file"
done
{
  echo "regenerate-action-exports-linux.sh at $(git rev-parse HEAD): the exports that changed (none when no diff follows)"
  git diff --binary -- "${exports[@]}"
} > "$out.patch"
echo "patch: $out.patch ($(wc -l < "$out.patch" | tr -d ' ') lines)"
