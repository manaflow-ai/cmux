#!/usr/bin/env bash
# Does a Package.swift's Context.environment see the xcodebuild caller's environment, per installed Xcode?
# (The live code variant's appLinksStatically reads CMUX_LIVE_CODE_BUILD that way.) Prints one row per
# Xcode: the linkage the manifest chose with the variable set, cold and then with the DerivedData kept
# from a build without it.
set -uo pipefail
[[ "$(uname)" == Darwin ]] || { echo "manifest-env-probe: macOS only" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/manifest-env-probe.XXXXXX")"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/pkg/Sources/Lib" "$work/pkg/Sources/exe"
cat > "$work/pkg/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let live = Context.environment["PROBE_LIVE"] == "1"
let package = Package(name: "probe", platforms: [.macOS(.v13)],
  products: [.library(name: "Lib", type: live ? nil : .dynamic, targets: ["Lib"]),
             .executable(name: "exe", targets: ["exe"])],
  targets: [.target(name: "Lib"), .executableTarget(name: "exe", dependencies: ["Lib"])])
SWIFT
echo 'public func probeHello() -> Int { 42 }' > "$work/pkg/Sources/Lib/Lib.swift"
printf 'import Lib\nprint(probeHello())\n' > "$work/pkg/Sources/exe/main.swift"
linkage() { # DD
  local exe; exe="$(find "$1/Build/Products" -name exe -type f -perm -u+x | head -1)"
  if [[ -z "$exe" ]]; then echo none; elif otool -L "$exe" | grep -q 'Lib\.framework\|libLib'; then echo dynamic; else echo static; fi
}
build() { # DD [ENV...]
  local dd="$1"; shift
  (cd "$work/pkg" && env "$@" xcodebuild -scheme exe -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build >"$dd.log" 2>&1) || echo "build failed: $(grep -m3 error: "$dd.log")" >&2
}
for app in /Applications/Xcode*.app; do
  dev="$app/Contents/Developer"; [[ -x "$dev/usr/bin/xcodebuild" ]] || continue
  export DEVELOPER_DIR="$dev"
  ver="$(xcodebuild -version 2>/dev/null | paste -sd ' ' -)"
  colddd="$work/cold"; rm -rf "$colddd"
  build "$colddd" PROBE_LIVE=1; cold="$(linkage "$colddd")"
  kept="$work/kept"; rm -rf "$kept"
  build "$kept"; before="$(linkage "$kept")"
  build "$kept" PROBE_LIVE=1; after="$(linkage "$kept")"
  echo "manifest-env-probe: $ver: live cold=$cold (want static); unset=$before (want dynamic), then live on kept DerivedData=$after (want static)"
done
