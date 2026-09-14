#!/usr/bin/env bash
# Real wireguard-go archive for both iPhone and Simulator. Never emit a stub.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="$root/vendor/WireGuardKit/Sources/WireGuardKitGo"
output="${BUILT_PRODUCTS_DIR:?}/libwg-go.a"
work="${TARGET_TEMP_DIR:?}/wireguard-go"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$PATH"
command -v go >/dev/null || { echo "error: Go is required for the Cloud VPN provider" >&2; exit 1; }
mkdir -p "$work"
case "${PLATFORM_NAME:?}" in
  iphoneos) sdk=iphoneos; suffix="" ;;
  iphonesimulator) sdk=iphonesimulator; suffix="-simulator" ;;
  *) echo "error: Unsupported VPN platform" >&2; exit 1 ;;
esac
sdk_path="${SDKROOT:-$(xcrun --sdk "$sdk" --show-sdk-path)}"
clang="$(xcrun --sdk "$sdk" --find clang)"
archives=()
for arch in ${ARCHS:-arm64}; do
    case "$arch" in arm64) goarch=arm64 ;; x86_64) goarch=amd64 ;; *) exit 1 ;; esac
    archive="$work/libwg-go-$arch.a"
    flags="-isysroot $sdk_path -target $arch-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-18.0}$suffix"
    (cd "$source_dir" && CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" GOTOOLCHAIN=local GOFLAGS=-mod=readonly \
        CC="$clang" CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
        go build -ldflags=-w -trimpath -buildmode=c-archive -o "$archive")
    archives+=("$archive")
done
if [[ "${#archives[@]}" == 1 ]]; then
    cp "${archives[0]}" "$output"
else
    lipo -create -output "$output" "${archives[@]}"
fi
