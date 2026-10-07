#!/usr/bin/env bash
# MACOS-CROSS-COMPILE-ON-LINUX shadow: build the macOS artifacts that need no
# Apple SDK on a Linux runner and compare each with the Mac-built artifact of
# the same commit (scripts/ci/macho_parity.py). The shadow replaces nothing:
# no publish step reads its output.
#
# No Apple SDK file is used. The sysroot is Zig's bundled darwin headers and
# libSystem stub (the toolchain Ghostty already uses to cross-compile), plus a
# libiconv stub this script writes from the install name alone. Compiler and
# linker are upstream clang and ld64.lld; the app FFI prelink uses Apple's
# open-source ld64 (cctools-port, APSL 2.0) because ld64.lld has no -r.
#
# usage: scripts/ci/macos-cross.sh <command> [args]
#   toolchain <sdk-version>        sysroot + clang wrappers under $XC_ROOT
#   fetch-refs <sha>               Mac-built binaries of <sha> from files.cmux.com (checksums verified)
#   ref-sdk <mac-binary>           print the SDK version recorded in a Mac binary
#   hosts <sha> <ghostty-sha>      cmux-app-host, cmux-browser-host, cmux-cloud for both macOS targets
#   vt                             ghostty-vt-sys (zig libghostty-vt.a + bindgen) for both targets
#   parity-hosts                   compare hosts with the Mac references
#   parity-vt                      compare libghostty-vt with the Mac-built cmux-tui that links it
#   cctools                        build the pinned cctools-port ld64, libtool and lipo
#   ffi [out-dir]                  CCmuxAppFFI slices + universal library, like build-app-ffi.sh
#   parity-ffi <mac-lib.a>         compare the FFI slices with the Mac-built universal library
# Environment: XC_ROOT (default $RUNNER_TEMP/macos-cross or $HOME/xc), LLVM_VERSION (default 19).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XC_ROOT="${XC_ROOT:-${RUNNER_TEMP:-$HOME}/macos-cross}"
LLVM_VERSION="${LLVM_VERSION:-19}"
LLVM_BIN="/usr/lib/llvm-$LLVM_VERSION/bin"
SYSROOT="$XC_ROOT/sysroot"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
# The rustc defaults the Mac build relies on (it sets no MACOSX_DEPLOYMENT_TARGET).
declare -A MIN_OS=([aarch64-apple-darwin]=11.0 [x86_64-apple-darwin]=10.12)
# Pinned third-party sources for the FFI prelink linker.
CCTOOLS_PORT_SHA=904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb
LIBDISPATCH_SHA=323b9b4e0ca05d6c56a0c2f2d7d8d47363e612b7
export LLVM_BIN

die() { echo "macos-cross: $*" >&2; exit 1; }
arch_of() { case "$1" in aarch64-*) echo arm64 ;; x86_64-*) echo x86_64 ;; esac; }
env_name() { echo "${1//-/_}"; }

use_target() { # <target> <min-os>: point cargo and cc-rs at the wrappers
  local t=$1 u T
  u=$(env_name "$t"); T=$(echo "$u" | tr '[:lower:]' '[:upper:]')
  export MACOSX_DEPLOYMENT_TARGET="$2"
  export "CARGO_TARGET_${T}_LINKER=$XC_ROOT/bin/cc-$t-$2" "CC_$u=$XC_ROOT/bin/cc-$t-$2" "AR_$u=$LLVM_BIN/llvm-ar"
  export "BINDGEN_EXTRA_CLANG_ARGS_$u=-isysroot $SYSROOT"
  [[ -x "$XC_ROOT/bin/cc-$t-$2" ]] || write_wrapper "$t" "$2"
}

write_wrapper() { # <target> <min-os>
  mkdir -p "$XC_ROOT/bin"
  cat > "$XC_ROOT/bin/cc-$1-$2" <<EOF
#!/usr/bin/env bash
# -fstack-clash-protection: the probes Apple clang adds by default for large frames.
exec $LLVM_BIN/clang --target=$(arch_of "$1")-apple-macos$2 -isysroot $SYSROOT -fuse-ld=lld \\
  -Xclang -fstack-clash-protection -Wno-unused-command-line-argument "\$@"
EOF
  chmod +x "$XC_ROOT/bin/cc-$1-$2"
}

cmd_toolchain() {
  local sdk=${1:?sdk version} zig_lib
  zig_lib="$(dirname "$(readlink -f "$(command -v zig)")")/lib"
  [[ -f "$zig_lib/libc/darwin/libSystem.tbd" ]] || die "zig darwin libSystem stub not found under $zig_lib"
  rm -rf "${SYSROOT:?}" "${XC_ROOT:?}/bin"; mkdir -p "$SYSROOT/usr/lib"
  cp -r "$zig_lib/libc/include/any-darwin-any" "$SYSROOT/usr/include"
  cp "$zig_lib/libc/darwin/libSystem.tbd" "$SYSROOT/usr/lib/"
  # libc, libm, libpthread and libdl are libSystem on macOS.
  for l in c m pthread dl; do ln -sf libSystem.tbd "$SYSROOT/usr/lib/lib$l.tbd"; done
  # Rust std links -liconv. No iconv symbol is imported, so the stub only names the dylib.
  cat > "$SYSROOT/usr/lib/libiconv.tbd" <<'EOF'
--- !tapi-tbd
tbd-version:     4
targets:         [ x86_64-macos, arm64-macos, arm64e-macos ]
install-name:    '/usr/lib/libiconv.2.dylib'
current-version: 7
compatibility-version: 7
...
EOF
  # The SDK version clang records in LC_BUILD_VERSION; the caller passes the Mac build's.
  cat > "$SYSROOT/SDKSettings.json" <<EOF
{"Version":"$sdk","CanonicalName":"macosx$sdk","DisplayName":"macOS $sdk","MaximumDeploymentTarget":"$sdk.99",
 "DefaultDeploymentTarget":"$sdk","SupportedTargets":{"macosx":{"Archs":["x86_64","arm64"],"LLVMTargetTripleSys":"macos",
 "LLVMTargetTripleVendor":"apple","DefaultDeploymentTarget":"$sdk","MinimumDeploymentTarget":"10.13",
 "MaximumDeploymentTarget":"$sdk.99","PlatformFamilyName":"macOS"}}}
EOF
  "$LLVM_BIN/clang" --version | head -1
  echo "sysroot: $SYSROOT (zig $(zig version), SDK version label $sdk)"
}

cmd_ref_sdk() {
  "$LLVM_BIN/llvm-objdump" --macho --private-headers "$1" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; exit}'
}

cmd_fetch_refs() {
  local sha=${1:?sha} out="$XC_ROOT/ref"; mkdir -p "$out"
  curl -fsS --retry 3 -o "$out/manifest.json" "https://files.cmux.com/cmux-tui/$sha/manifest.json"
  for t in "${TARGETS[@]}"; do
    for n in cmux-tui-app-host cmux-tui-browser-host cmux-tui-cloud-server cmux-tui; do
      curl -fsS --retry 3 -o "$out/$n-$t" "https://files.cmux.com/cmux-tui/$sha/$n-$t"
    done
  done
  python3 - "$out" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1]); binaries = json.loads((out / "manifest.json").read_text())["binaries"]
for path in sorted(out.glob("*-apple-darwin")):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if binaries.get(path.name) != digest:
        raise SystemExit(f"checksum mismatch for {path.name}")
    print(f"ref {path.name} sha256 {digest[:16]}")
PY
}

cmd_hosts() {
  local sha=${1:?sha} ghostty=${2:?ghostty sha} out="$XC_ROOT/linux"; mkdir -p "$out"
  export CARGO_TARGET_DIR="$XC_ROOT/target-hosts" CMUX_GHOSTTY_SRC=""
  for t in "${TARGETS[@]}"; do
    use_target "$t" "${MIN_OS[$t]}"
    local start; start=$(date +%s)
    # The same stamps the Mac build sets (cmux-tui-build-package.yml).
    (cd "$repo_root/cmux-tui"
      CMUX_TUI_BUILD_COMMIT=$sha CMUX_TUI_GHOSTTY_COMMIT=$ghostty CMUX_TUI_DISTRIBUTION_VERSION=0.0.0-r2.sha-$sha \
        cargo build -p cmux-app-host --bin cmux-app-host --release --locked --target "$t"
      CMUX_BUILD_SHA=$sha cargo build -p cmux-browser-host --bin cmux-browser-host --release --locked --target "$t")
    (cd "$repo_root/first-party-apps/cloud/server" && cargo build --bin cmux-cloud --release --locked --target "$t")
    echo "hosts $t: $(( $(date +%s) - start )) s"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-app-host" "$out/cmux-tui-app-host-$t"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-browser-host" "$out/cmux-tui-browser-host-$t"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-cloud" "$out/cmux-tui-cloud-server-$t"
  done
}

cmd_vt() {
  local out="$XC_ROOT/vt"; rm -rf "$out"; mkdir -p "$out"
  export CARGO_TARGET_DIR="$XC_ROOT/target-vt"
  export CMUX_GHOSTTY_SRC="${CMUX_GHOSTTY_SRC:-}"
  for t in "${TARGETS[@]}"; do
    use_target "$t" "${MIN_OS[$t]}"
    (cd "$repo_root/cmux-tui" && cargo build -p ghostty-vt-sys --release --locked --target "$t")
    local dir; dir=$(dirname "$(ls -t "$CARGO_TARGET_DIR/$t"/release/build/ghostty-vt-sys-*/out/bindings.rs | head -1)")
    cp "$dir/bindings.rs" "$out/bindings-$t.rs"
    cp "$dir/ghostty-vt/lib/libghostty-vt.a" "$out/libghostty-vt-$t.a"
  done
}

report_line() { # <report.json>
  python3 - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
fails = [k for k, v in r["checks"].items() if not v]
print(f'{"PASS" if r["pass"] else "FAIL"} {r["name"]}: bytes mac={r["mac"]["bytes"]} linux={r["linux"]["bytes"]} '
      f'(x{r["size_ratio_linux_over_mac"]}) deploy={r["linux"]["build_version"]} dylibs={len(r["linux"]["dylibs"])} '
      f'imports only_mac={r["undefined"]["only_mac"]} only_linux={r["undefined"]["only_linux"]} '
      f'exports only_mac={r["exported"]["only_mac_count"]} only_linux={r["exported"]["only_linux_count"]}'
      + (f' FAILED={fails}' if fails else ''))
PY
}

cmd_parity_hosts() {
  local status=0 reports="$XC_ROOT/reports"; mkdir -p "$reports"
  for n in cmux-tui-app-host cmux-tui-browser-host cmux-tui-cloud-server; do
    for t in "${TARGETS[@]}"; do
      python3 "$repo_root/scripts/ci/macho_parity.py" "$n-$t" "$XC_ROOT/ref/$n-$t" "$XC_ROOT/linux/$n-$t" \
        > "$reports/$n-$t.json" || status=1
      report_line "$reports/$n-$t.json"
    done
  done
  return $status
}

cmd_parity_vt() {
  local status=0 nm="$LLVM_BIN/llvm-nm"
  if ! cmp -s "$XC_ROOT/vt/bindings-aarch64-apple-darwin.rs" "$XC_ROOT/vt/bindings-x86_64-apple-darwin.rs"; then
    echo "FAIL libghostty-vt bindings differ between the two macOS targets"; status=1
  fi
  for t in "${TARGETS[@]}"; do
    local lib="$XC_ROOT/vt/libghostty-vt-$t.a" ref="$XC_ROOT/ref/cmux-tui-$t"
    [[ -s "$ref" && -s "$lib" ]] || { echo "FAIL libghostty-vt-$t: missing $ref or $lib"; status=1; continue; }
    [[ $("$nm" --just-symbol-name "$ref" | grep -cE '^_ghostty_') -gt 0 ]] \
      || { echo "FAIL libghostty-vt-$t: the Mac daemon $ref has no _ghostty_ symbols"; status=1; continue; }
    # Every libghostty-vt entry point the Mac-built daemon contains must exist in the Linux archive.
    comm -13 <("$nm" -g --defined-only --just-symbol-name "$lib" 2>/dev/null | grep -E '^_ghostty_' | sort -u) \
             <("$nm" --just-symbol-name "$ref" | grep -E '^_ghostty_' | sort -u) > "$XC_ROOT/vt/missing-$t.txt"
    local minos; minos=$("$LLVM_BIN/llvm-objdump" --macho --private-headers "$lib" 2>/dev/null \
      | awk '/cmd LC_BUILD_VERSION|cmd LC_VERSION_MIN_MACOSX/{c=1} c&&/^ *(minos|version) /{print $2; c=0}' | sort -u | tr '\n' ' ')
    # The archive's objects must carry the daemon's deployment target, not Zig's default.
    if [[ "$minos" != "${MIN_OS[$t]} " ]]; then
      echo "FAIL libghostty-vt-$t: member minimum macOS is '$minos', the daemon links at ${MIN_OS[$t]}"; status=1
    fi
    if [[ -s "$XC_ROOT/vt/missing-$t.txt" ]]; then
      echo "FAIL libghostty-vt-$t: $(wc -l < "$XC_ROOT/vt/missing-$t.txt") API symbols of the Mac daemon missing: $(head -5 "$XC_ROOT/vt/missing-$t.txt" | tr '\n' ' ')"; status=1
    else
      echo "PASS libghostty-vt-$t: all $("$nm" --just-symbol-name "$ref" | grep -cE '^_ghostty_') _ghostty_ symbols of the Mac daemon exported; members minos $minos; bytes $(stat -c %s "$lib")"
    fi
  done
  return $status
}

cmd_cctools() {
  local ct="$XC_ROOT/cctools" src="$XC_ROOT/cctools-src" dispatch="$XC_ROOT/dispatch"
  [[ -x "$ct/bin/aarch64-apple-darwin-ld" ]] && { echo "cctools: cached"; return; }
  fetch_pinned() { # <url> <sha> <dir>
    rm -rf "$3"; git init -q "$3"; git -C "$3" fetch -q --depth 1 "$1" "$2"; git -C "$3" checkout -q FETCH_HEAD
  }
  fetch_pinned https://github.com/tpoechtrager/apple-libdispatch.git "$LIBDISPATCH_SHA" "$XC_ROOT/dispatch-src"
  cmake -S "$XC_ROOT/dispatch-src" -B "$XC_ROOT/dispatch-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$LLVM_BIN/clang" -DCMAKE_CXX_COMPILER="$LLVM_BIN/clang++" -DCMAKE_INSTALL_PREFIX="$dispatch" >/dev/null
  ninja -C "$XC_ROOT/dispatch-build" install >/dev/null
  fetch_pinned https://github.com/tpoechtrager/cctools-port.git "$CCTOOLS_PORT_SHA" "$src"
  (cd "$src/cctools"
    CC="$LLVM_BIN/clang" CXX="$LLVM_BIN/clang++" CFLAGS="-I$dispatch/include" CXXFLAGS="-I$dispatch/include" \
      LDFLAGS="-L$dispatch/lib -Wl,-rpath,$dispatch/lib" ./configure --prefix="$ct" --target=aarch64-apple-darwin >/dev/null
    make -j"$(nproc)" >/dev/null && make install >/dev/null)
  "$ct/bin/aarch64-apple-darwin-ld" -v 2>&1 | head -1
}

cmd_ffi() {
  local out=${1:-$XC_ROOT/ffi} ct="$XC_ROOT/cctools/bin/aarch64-apple-darwin" crates="$repo_root/cmux-tui/crates" libs=()
  mkdir -p "$out/slices" "$out/macos" "$out/work"
  # Same settings as scripts/cmux-next/build-app-ffi.sh.
  export CARGO_TARGET_DIR="$out/cargo" CARGO_PROFILE_RELEASE_LTO=off RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C embed-bitcode=no"
  for h in "$crates/cmux-rd-ffi/include/cmux_rd_ffi.h" "$crates/cmux-layout-reducer-ffi/include/cmux_layout_reducer_ffi.h"; do
    grep -oE '\bcmux_[a-z0-9_]+\(' "$h" | tr -d '(' | sort -u | sed 's/^/_/'
  done | sort -u > "$out/work/exports.txt"
  for t in "${TARGETS[@]}"; do
    use_target "$t" 26.0
    (cd "$crates/cmux-app-ffi" && cargo build --locked --release --target "$t")
    "$LLVM_BIN/clang" --target="$(arch_of "$t")-apple-macos26.0" -isysroot "$SYSROOT" --ld-path="$ct-ld" -r -nostdlib \
      -Wl,-force_load,"$CARGO_TARGET_DIR/$t/release/libcmux_app_ffi.a" \
      -Wl,-exported_symbols_list,"$out/work/exports.txt" -o "$out/work/$t.o"
    "$ct-libtool" -static -o "$out/slices/$t.a" "$out/work/$t.o"
    libs+=("$out/slices/$t.a")
  done
  "$ct-lipo" -create "${libs[@]}" -output "$out/macos/libcmux_app_ffi.a"
  "$ct-lipo" -info "$out/macos/libcmux_app_ffi.a"
}

cmd_parity_ffi() {
  local mac=${1:?mac universal lib} status=0 out="$XC_ROOT/ffi" reports="$XC_ROOT/reports"; mkdir -p "$reports"
  # rustc's own llvm-nm reads the bitcode sections of the Rust objects in the archive.
  # Use the pinned toolchain of cmux-tui (rust-toolchain.toml), the one that built the archive.
  (cd "$repo_root/cmux-tui" && rustup component add llvm-tools >/dev/null)
  LLVM_NM="$(cd "$repo_root/cmux-tui" && rustc --print sysroot)/lib/rustlib/$(cd "$repo_root/cmux-tui" && rustc -vV | awk '/^host:/{print $2}')/bin/llvm-nm"
  export LLVM_NM
  for t in "${TARGETS[@]}"; do
    "$LLVM_BIN/llvm-lipo" -thin "$(arch_of "$t")" "$mac" -output "$out/mac-$t.a"
    python3 "$repo_root/scripts/ci/macho_parity.py" "app-ffi-$t" "$out/mac-$t.a" "$out/slices/$t.a" \
      > "$reports/app-ffi-$t.json" || status=1
    report_line "$reports/app-ffi-$t.json"
  done
  return $status
}

command=${1:-}; shift || true
case "$command" in
  toolchain) cmd_toolchain "$@" ;;
  fetch-refs) cmd_fetch_refs "$@" ;;
  ref-sdk) cmd_ref_sdk "$@" ;;
  hosts) cmd_hosts "$@" ;;
  vt) cmd_vt ;;
  parity-hosts) cmd_parity_hosts ;;
  parity-vt) cmd_parity_vt ;;
  cctools) cmd_cctools ;;
  ffi) cmd_ffi "$@" ;;
  parity-ffi) cmd_parity_ffi "$@" ;;
  *) sed -n '2,27p' "$0"; exit 2 ;;
esac
