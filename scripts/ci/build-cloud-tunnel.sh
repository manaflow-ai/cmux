#!/usr/bin/env bash
# Compile the real extension separately so lifecycle verification needs no app launch.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
output="${CMUX_TUNNEL_BUILD_OUTPUT:?set a job-owned output directory}"
mkdir -p "$output"
swift test --package-path Packages/macOS/CmuxCloudTunnelCore
swift test --package-path vendor/WireGuardKit --filter TunnelFileDescriptorTests
./scripts/download-prebuilt-ghosttykit.sh
# Target-only builds use explicit product/intermediate directories instead of
# derivedDataPath, which Xcode accepts only together with a scheme.
CMUX_WIREGUARD_GO_REQUIRE=1 xcodebuild \
  -project cmux.xcodeproj -target cmuxTunnelExtension -configuration Release \
  -clonedSourcePackagesDirPath "$output/packages" \
  SYMROOT="$output/products" OBJROOT="$output/intermediates" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
extension="$output/products/Release/cmuxTunnel.systemextension"
test -x "$extension/Contents/MacOS/cmuxTunnel"
nm "$extension/Contents/MacOS/cmuxTunnel" > "$output/symbols.txt"
if grep -q cmux_wireguard_go_bridge_is_stub "$output/symbols.txt"; then
  echo 'Refusing an extension with a stub WireGuard engine' >&2
  exit 1
fi
git rev-parse HEAD > "$output/source-sha.txt"
shasum -a 256 "$extension/Contents/MacOS/cmuxTunnel" > "$output/binary-sha256.txt"
ditto -c -k --keepParent "$extension" "$output/cmuxTunnel.zip"
