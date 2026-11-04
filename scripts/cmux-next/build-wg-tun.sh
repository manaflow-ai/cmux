#!/usr/bin/env bash
# Builds libcmux_wg_tun.a, the Cloud Tunnel system extension's WireGuard engine
# (cmux-tui/crates/cmux-wg-tun), for the extension target's link.
#
# A build host (CI, a fleet build, an nx job) runs cargo for every architecture
# in ARCHS and lipos the slices. A developer Mac never runs cargo: it uses the
# last library a fleet or CI build left in cmux-tui/target/wg-tun-app, and a
# Debug build with none gets a stub whose start fails with "engine not built",
# so the app still builds and the tunnel reports why it cannot start. A Release
# build that ships the tunnel (CMUX_CLOUD_TUNNEL=YES) refuses the stub; any
# other Release build gets the stub too, since embed-cloud-tunnel.sh never embeds
# the extension from it, so it never spends a cargo build on boringtun.
#
# Usage: build-wg-tun.sh OUTPUT_DIR
# Environment: ARCHS (Xcode; default: host), CONFIGURATION (Xcode)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${1:?usage: build-wg-tun.sh OUTPUT_DIR}"
lib="libcmux_wg_tun.a"
header="$repo_root/cmux-tui/crates/cmux-wg-tun/include/cmux_wg_tun.h"
cache="$repo_root/cmux-tui/target/wg-tun-app"
mkdir -p "$out_dir" "$cache"

build_allowed() { [[ -n "${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]]; }
shipped() { [[ "${CONFIGURATION:-Debug}" != "Release" || "${CMUX_CLOUD_TUNNEL:-NO}" == "YES" ]]; }

archs="${ARCHS:-$(uname -m)}"
archs="${archs//,/ }"
key="$(git -C "$repo_root" rev-parse HEAD:cmux-tui/crates/cmux-wg-tun 2>/dev/null || echo unknown)-$(git -C "$repo_root" rev-parse HEAD:cmux-tui/crates/cmux-wg 2>/dev/null || echo unknown)-$(git -C "$repo_root" rev-parse HEAD:cmux-tui/Cargo.lock 2>/dev/null || echo unknown)-${archs// /+}"

if shipped && build_allowed; then
  slices=()
  for arch in $archs; do
    case "$arch" in
      arm64|aarch64) target=aarch64-apple-darwin ;;
      x86_64) target=x86_64-apple-darwin ;;
      *) echo "error: unsupported architecture $arch" >&2; exit 2 ;;
    esac
    echo "==> cargo build cmux-wg-tun ($target)"
    (cd "$repo_root/cmux-tui" && \
      MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_PROFILE_RELEASE_LTO=off \
      RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C embed-bitcode=no" \
      CARGO_TARGET_DIR="$cache/cargo" \
      cargo build --locked --release --package cmux-wg-tun --lib --target "$target")
    slices+=("$cache/cargo/$target/release/$lib")
  done
  if ((${#slices[@]} == 1)); then
    cp -f "${slices[0]}" "$cache/$lib.tmp"
  else
    lipo -create "${slices[@]}" -output "$cache/$lib.tmp"
  fi
  mv -f "$cache/$lib.tmp" "$cache/$lib"
  printf '%s\n' "$key" > "$cache/$lib.key"
  cp -f "$cache/$lib" "$out_dir/$lib"
  exit 0
fi

if [[ -f "$cache/$lib" && "$(cat "$cache/$lib.key" 2>/dev/null)" == "$key" ]]; then
  cp -f "$cache/$lib" "$out_dir/$lib"
  exit 0
fi

if [[ "${CONFIGURATION:-Debug}" == "Release" && "${CMUX_CLOUD_TUNNEL:-NO}" == "YES" ]]; then
  echo "error: no cmux-wg-tun library for $key; a Release build needs a build host (CI or the fleet)" >&2
  exit 1
fi

echo "note: building the Cloud Tunnel engine stub (cargo runs only on build hosts, for a build that ships the tunnel)"
stub="$(mktemp -d "${TMPDIR:-/tmp}/cmux-wg-tun-stub.XXXXXX")"
trap 'rm -rf "$stub"' EXIT
cat > "$stub/stub.c" <<'C'
#include <string.h>
#include "cmux_wg_tun.h"
int32_t cmux_wg_tun_find_utun_fd(void) { return -1; }
CmuxWgTun *cmux_wg_tun_start(const char *config, int32_t tun_fd, char *error, size_t error_len) {
  (void)config; (void)tun_fd;
  if (error && error_len) { strncpy(error, "engine not built: this is a developer build", error_len - 1); error[error_len - 1] = 0; }
  return 0;
}
void cmux_wg_tun_network_changed(CmuxWgTun *tun) { (void)tun; }
void cmux_wg_tun_stats(const CmuxWgTun *tun, CmuxWgTunStats *out) { (void)tun; if (out) memset(out, 0, sizeof *out); }
void cmux_wg_tun_stop(CmuxWgTun *tun) { (void)tun; }
C
objects=()
for arch in $archs; do
  clang -arch "$arch" -mmacosx-version-min=14.0 -I"$(dirname "$header")" -c "$stub/stub.c" -o "$stub/stub-$arch.o"
  objects+=("$stub/stub-$arch.o")
done
libtool -static -o "$out_dir/$lib" "${objects[@]}" 2>/dev/null
