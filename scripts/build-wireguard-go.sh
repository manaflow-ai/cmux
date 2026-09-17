#!/usr/bin/env bash
# Build libwg-go.a, the wireguard-go engine as a C archive, for the cmux Cloud
# tunnel system extension (TunnelExtension/, target cmuxTunnelExtension).
#
# Runs as that target's "Build wireguard-go" phase and standalone. The Swift
# side (vendor/WireGuardKit) only declares `link "wg-go"`; this script is what
# puts the archive where the linker looks (BUILT_PRODUCTS_DIR).
#
# Inputs, all Xcode build settings when run as a phase (override for standalone):
#   ARCHS / CMUX_WIREGUARD_GO_ARCHS   architectures (default: host)
#   BUILT_PRODUCTS_DIR                output directory for libwg-go.a
#   CMUX_WIREGUARD_GO_OUTPUT          explicit output path (overrides the above)
#   TARGET_TEMP_DIR                   per-arch intermediates
#   MACOSX_DEPLOYMENT_TARGET          minimum macOS (default 14.0)
#   SDKROOT                           macOS SDK (default: xcrun --show-sdk-path)
#   CONFIGURATION                     Release always requires a real toolchain
#   CMUX_WIREGUARD_GO_REQUIRE         1: fail when `go` is missing
#                                     0: build a stub archive and warn
#                                     default: 1 for Release builds, else 0
#                                     (Debug CI runners have no Go; the stub
#                                     is fine there because a Debug build can
#                                     never load the extension)
#   CMUX_WIREGUARD_GO_BINARY          explicit `go` executable (default: PATH lookup)
#
# Without Go the script emits a STUB archive: every exported wg* symbol fails,
# and the marker symbol `cmux_wireguard_go_bridge_is_stub` is defined so
# scripts/sign-cmux-bundle.sh refuses to ship it. A Debug build cannot load the
# extension anyway (no signed entitlement), so a stub keeps `reload.sh` and the
# Debug CI lanes green on machines without Go, while Release builds fail closed
# and the release workflows install Go before building.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_SRC_DIR="${ROOT}/vendor/WireGuardKit/Sources/WireGuardKitGo"
CONFIGURATION="${CONFIGURATION:-Debug}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
OUTPUT="${CMUX_WIREGUARD_GO_OUTPUT:-${BUILT_PRODUCTS_DIR:-${GO_SRC_DIR}/out}/libwg-go.a}"
WORK_DIR="${TARGET_TEMP_DIR:-${GO_SRC_DIR}/.tmp}/wireguard-go"

# Xcode build phases do not inherit a login-shell PATH.
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${HOME}/go/bin:${PATH}"

case "${CMUX_WIREGUARD_GO_REQUIRE:-}" in
  1|true|TRUE|yes|YES) REQUIRE_GO=1 ;;
  0|false|FALSE|no|NO) REQUIRE_GO=0 ;;
  "")
    if [[ "$CONFIGURATION" == "Release" ]]; then
      REQUIRE_GO=1
    else
      REQUIRE_GO=0
    fi
    ;;
  *)
    echo "error: CMUX_WIREGUARD_GO_REQUIRE must be 0 or 1, got '${CMUX_WIREGUARD_GO_REQUIRE}'" >&2
    exit 2
    ;;
esac

requested_archs="${CMUX_WIREGUARD_GO_ARCHS:-${ARCHS:-}}"
if [[ -z "$requested_archs" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) requested_archs="arm64" ;;
    x86_64) requested_archs="x86_64" ;;
    *)
      echo "error: cannot infer a macOS architecture for host $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

go_arch_for() {
  case "$1" in
    arm64|arm64e) echo "arm64" ;;
    x86_64) echo "amd64" ;;
    *)
      echo "error: unsupported macOS architecture for wireguard-go: $1" >&2
      return 1
      ;;
  esac
}

SDK="${SDKROOT:-}"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
CLANG="$(xcrun --sdk macosx --find clang)"

mkdir -p "$WORK_DIR" "$(dirname "$OUTPUT")"

GO_BIN="${CMUX_WIREGUARD_GO_BINARY:-$(command -v go || true)}"

archives=()
seen=""
if [[ -n "$GO_BIN" && -x "$GO_BIN" ]]; then
  echo "wireguard-go: building with $("$GO_BIN" version) for: ${requested_archs}"
  for arch in $requested_archs; do
    case " $seen " in *" $arch "*) continue ;; esac
    seen="$seen $arch"
    goarch="$(go_arch_for "$arch")"
    flags="-isysroot ${SDK} -arch ${arch} -mmacosx-version-min=${MIN_MACOS}"
    archive="${WORK_DIR}/libwg-go-${arch}.a"
    # GOTOOLCHAIN=local: never auto-download a different Go; the installed one
    # must satisfy go.mod. -mod=readonly: the vendored go.mod/go.sum are the
    # pinned module set; a build must fail rather than rewrite them.
    (
      cd "$GO_SRC_DIR"
      env \
        CGO_ENABLED=1 \
        GOOS=darwin \
        GOARCH="$goarch" \
        GOTOOLCHAIN=local \
        GOFLAGS=-mod=readonly \
        CC="$CLANG" \
        CGO_CFLAGS="$flags" \
        CGO_LDFLAGS="$flags" \
        "$GO_BIN" build -ldflags=-w -trimpath -buildmode=c-archive -o "$archive"
    )
    rm -f "${archive%.a}.h"
    archives+=("$archive")
  done
else
  if [[ "$REQUIRE_GO" -eq 1 ]]; then
    cat >&2 <<MSG
error: the Go toolchain is required to build the cmux Cloud tunnel extension
       (libwg-go.a) for ${CONFIGURATION} builds, and \`go\` was not found on PATH.
       Install it with \`brew install go\` (or from https://go.dev/dl/) and rebuild.
MSG
    exit 1
  fi
  echo "warning: go not found; building a STUB libwg-go.a. The tunnel extension in this build cannot carry traffic. Install Go (brew install go) for the real engine." >&2
  stub_source="${WORK_DIR}/stub.c"
  cat > "$stub_source" <<'STUB'
/* Stand-in for wireguard-go when the Go toolchain is unavailable at build time.
 * Every entry point fails; the marker symbol lets release signing reject it. */
#include <stddef.h>
#include <stdint.h>
const char cmux_wireguard_go_bridge_is_stub = 1;
void wgSetLogger(void *context, void *logger_fn) { (void)context; (void)logger_fn; }
int wgTurnOn(const char *settings, int32_t tun_fd) { (void)settings; (void)tun_fd; return -1; }
void wgTurnOff(int handle) { (void)handle; }
int64_t wgSetConfig(int handle, const char *settings) { (void)handle; (void)settings; return -1; }
char *wgGetConfig(int handle) { (void)handle; return NULL; }
void wgBumpSockets(int handle) { (void)handle; }
void wgDisableSomeRoamingForBrokenMobileSemantics(int handle) { (void)handle; }
const char *wgVersion(void) { return "stub"; }
STUB
  for arch in $requested_archs; do
    case " $seen " in *" $arch "*) continue ;; esac
    seen="$seen $arch"
    object="${WORK_DIR}/stub-${arch}.o"
    archive="${WORK_DIR}/libwg-go-${arch}.a"
    "$CLANG" -isysroot "$SDK" -arch "$arch" "-mmacosx-version-min=${MIN_MACOS}" -c "$stub_source" -o "$object"
    rm -f "$archive"
    /usr/bin/libtool -static -o "$archive" "$object"
    archives+=("$archive")
  done
fi

if [[ "${#archives[@]}" -eq 0 ]]; then
  echo "error: no architectures built for libwg-go.a" >&2
  exit 1
fi

tmp_output="${OUTPUT}.tmp"
if [[ "${#archives[@]}" -eq 1 ]]; then
  cp "${archives[0]}" "$tmp_output"
else
  lipo -create -output "$tmp_output" "${archives[@]}"
fi
mv -f "$tmp_output" "$OUTPUT"
echo "wireguard-go: wrote ${OUTPUT} ($(lipo -archs "$OUTPUT"))"
