#!/usr/bin/env bash
# MACOS-CROSS-COMPILE-ON-LINUX: build the macOS artifacts on a Linux runner and
# compare each with the Mac-built artifact of the same commit
# (scripts/ci/macho_parity.py). The shadow job replaces nothing; the package
# build runs `toolchain`, `hosts` and `bins` when its darwin builder switch says
# linux (cmux-tui-build-package.yml), with XC_CARGO_TARGET_DIR at its target dir.
#
# No Apple SDK file is used. The sysroot is Zig's bundled darwin headers and
# libSystem stub (the toolchain Ghostty already uses to cross-compile), a
# libiconv stub this script writes from the install name alone, and the
# framework stubs in scripts/ci/macos-stubs (symbol names our own Mac-built
# binaries import, written by scripts/ci/macos_stubs.py). Compiler and linker
# are upstream clang and ld64.lld; the app FFI prelink uses Apple's
# open-source ld64 (cctools-port, APSL 2.0) because ld64.lld has no -r.
#
# usage: scripts/ci/macos-cross.sh <command> [args]
#   toolchain <sdk-version>        sysroot + clang wrappers under $XC_ROOT
#   fetch-refs <sha>               Mac-built binaries of <sha> from files.cmux.com (checksums verified)
#   ref-sdk <mac-binary>           print the SDK version recorded in a Mac binary
#   hosts <sha> <ghostty-sha> [version]  cmux-app-host, cmux-browser-host, cmux-cloud for both macOS targets
#   bins <sha> <ghostty-sha> <version>  cmux-tui, cmux-tui-hook, acpmux, cmux-relay, chatmux-relay
#                                  (framework stubs) for both macOS targets
#   parity-bins                    compare the daemon family with the Mac references
#   stubs-check                    the committed framework stubs cover every Mac reference import
#   weaken-compiler-rt <lib.a> <rust-target>  ld64's symbol result for the archive's compiler_rt.o (zig wrapper)
#   vt                             ghostty-vt-sys (zig libghostty-vt.a + bindgen) for both targets
#   parity-hosts                   compare hosts with the Mac references
#   parity-vt                      compare libghostty-vt with the Mac-built cmux-tui that links it
#   cctools                        build the pinned cctools-port ld64, libtool and lipo
#   ffi [out-dir]                  CCmuxAppFFI slices + universal library, like build-app-ffi.sh
#   parity-ffi <mac-lib.a>         compare the FFI slices with the Mac-built universal library
# Environment: XC_ROOT (default $RUNNER_TEMP/macos-cross or $HOME/xc), LLVM_VERSION (default 19),
#   XC_TARGETS (default: both macOS targets; one target for a per-target package job),
#   XC_CARGO_TARGET_DIR (default: one directory per command under XC_ROOT).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XC_ROOT="${XC_ROOT:-${RUNNER_TEMP:-$HOME}/macos-cross}"
LLVM_VERSION="${LLVM_VERSION:-19}"
LLVM_BIN="/usr/lib/llvm-$LLVM_VERSION/bin"
SYSROOT="$XC_ROOT/sysroot"
read -r -a TARGETS <<< "${XC_TARGETS:-aarch64-apple-darwin x86_64-apple-darwin}"
STUBS_DIR="$repo_root/scripts/ci/macos-stubs"
# The rustc defaults the Mac build relies on (it sets no MACOSX_DEPLOYMENT_TARGET).
declare -A MIN_OS=([aarch64-apple-darwin]=11.0 [x86_64-apple-darwin]=10.12)
# Mac-built references under cmux-tui/<sha>/ (the relays have their own prefixes).
REF_NAMES=(cmux-tui-app-host cmux-tui-browser-host cmux-tui-cloud-server cmux-tui cmux-tui-hook cmux-tui-acpmux)
# The daemon family: the binaries that link Apple frameworks through the stubs.
BIN_NAMES=(cmux-tui cmux-tui-hook cmux-tui-acpmux cmux-relay chatmux-relay)
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
  # rustc asks xcrun for the SDK unless SDKROOT names one; the sysroot is ours.
  export SDKROOT="$SYSROOT"
  export "CARGO_TARGET_${T}_LINKER=$XC_ROOT/bin/cc-$t-$2" "CC_$u=$XC_ROOT/bin/cc-$t-$2" "AR_$u=$LLVM_BIN/llvm-ar"
  export "BINDGEN_EXTRA_CLANG_ARGS_$u=-isysroot $SYSROOT"
  [[ -x "$XC_ROOT/bin/cc-$t-$2" ]] || write_wrapper "$t" "$2"
  # ghostty-vt-sys runs $ZIG; the wrapper post-processes its macOS archive.
  [[ -x "$XC_ROOT/bin/zig" ]] || write_zig_wrapper
  export ZIG="$XC_ROOT/bin/zig"
}

write_wrapper() { # <target> <min-os>
  mkdir -p "$XC_ROOT/bin"
  cat > "$XC_ROOT/bin/cc-$1-$2" <<EOF
#!/usr/bin/env bash
# -fstack-clash-protection: the probes Apple clang adds by default for large frames.
# Rust's compiler_builtins defines its routines weak. Apple ld64 links them from
# the archive; ld64.lld binds a lazy weak archive definition to a dylib that
# exports the same name (libSystem's __umodti3, ...). force_load keeps the ld64
# result; -dead_strip (rustc passes it) drops what nothing uses.
extra=()
for arg in "\$@"; do
  case "\$arg" in */libcompiler_builtins-*.rlib) extra+=("-Wl,-force_load,\$arg") ;; esac
done
exec $LLVM_BIN/clang --target=$(arch_of "$1")-apple-macos$2 -isysroot $SYSROOT -fuse-ld=lld \\
  -Xclang -fstack-clash-protection -Wno-unused-command-line-argument "\${extra[@]}" "\$@"
EOF
  chmod +x "$XC_ROOT/bin/cc-$1-$2"
}

write_zig_wrapper() {
  mkdir -p "$XC_ROOT/bin"
  cat > "$XC_ROOT/bin/zig" <<EOF
#!/usr/bin/env bash
# Runs zig; after a macOS \`zig build --prefix <dir>\` it applies
# macos-cross.sh weaken-compiler-rt to each static library the build installed.
set -euo pipefail
"$(command -v zig)" "\$@"
[[ "\${1:-}" == build ]] || exit 0
prefix="" target=""
while ((\$#)); do
  case "\$1" in
    --prefix) prefix="\${2:-}" ;;
    -Dtarget=aarch64-macos*) target=aarch64-apple-darwin ;;
    -Dtarget=x86_64-macos*) target=x86_64-apple-darwin ;;
  esac
  shift
done
[[ -n "\$prefix" && -n "\$target" ]] || exit 0
for archive in "\$prefix"/lib/*.a; do
  [[ -f "\$archive" ]] && XC_ROOT="$XC_ROOT" "$repo_root/scripts/ci/macos-cross.sh" weaken-compiler-rt "\$archive" "\$target"
done
exit 0
EOF
  chmod +x "$XC_ROOT/bin/zig"
}

# A Linux-hosted zig build bundles a compiler_rt.o whose routines are strong
# definitions; Zig declares them weak. libghostty-vt then has two strong memsets
# (compiler_rt and ghostty-next src/quirks_memset.zig) and ld64.lld stops with
# "duplicate symbol". The Mac-built daemon has quirks_memset's memset, imports
# the libc routines (memcpy, strlen, fmod, __memcpy_chk, ...) from libSystem and
# keeps the integer and float helpers (__udivti3, ...) and the stack protector
# internal. To give
# ld64.lld that result: mark compiler_rt.o's definitions weak
# (scripts/ci/macho_weaken.py) and rename its copies of the routines that
# libSystem exports and Rust's compiler_builtins does not define, so the
# daemon binds them to libSystem.
cmd_weaken_compiler_rt() {
  local archive=${1:?archive} target=${2:?rust target} work builtins renames=() s
  work=$(mktemp -d)
  if (cd "$work" && "$LLVM_BIN/llvm-ar" x "$archive" compiler_rt.o 2>/dev/null); then
    builtins="$(cd "$repo_root/cmux-tui" && rustc --print sysroot)/lib/rustlib/$target/lib"
    builtins="$(ls "$builtins"/libcompiler_builtins-*.rlib 2>/dev/null | head -1)"
    [[ -n "$builtins" ]] || die "no compiler_builtins rlib for $target (rustup target add $target)"
    "$LLVM_BIN/llvm-nm" -g --defined-only --just-symbol-name "$work/compiler_rt.o" | sort -u > "$work/crt"
    grep -oE "'?_[A-Za-z0-9_\$]+'?" "$SYSROOT/usr/lib/libSystem.tbd" | tr -d "'" | sort -u > "$work/system"
    # llvm-nm exits 1 on the rlib's lib.rmeta member; the object members still print.
    { "$LLVM_BIN/llvm-nm" -g --defined-only --just-symbol-name "$builtins" 2>/dev/null || true; } \
      | grep -v ':$' | sort -u > "$work/builtins"
    # The Mac daemon keeps compiler_rt's stack protector (__stack_chk_guard and
    # __stack_chk_fail) internal; those stay.
    while IFS= read -r s; do renames+=(--redefine-sym "$s=$s.cmux_xc_libsystem"); done \
      < <(comm -12 "$work/crt" "$work/system" | comm -23 - "$work/builtins" | grep -v -x -E '___stack_chk_(guard|fail)')
    ((${#renames[@]})) && "$LLVM_BIN/llvm-objcopy" "${renames[@]}" "$work/compiler_rt.o"
    python3 "$repo_root/scripts/ci/macho_weaken.py" "$work/compiler_rt.o" >&2
    echo "weaken-compiler-rt $(basename "$archive"): $(( ${#renames[@]} / 2 )) libSystem routines left to libSystem" >&2
    (cd "$work" && "$LLVM_BIN/llvm-ar" r "$archive" compiler_rt.o)
  fi
  rm -rf "$work"
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
  # Apple framework stubs (CoreFoundation, Security, CoreServices) from our own binaries' imports.
  python3 "$repo_root/scripts/ci/macos_stubs.py" install "$STUBS_DIR" "$SYSROOT"
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
    for n in "${REF_NAMES[@]}"; do
      curl -fsS --retry 3 -o "$out/$n-$t" "https://files.cmux.com/cmux-tui/$sha/$n-$t"
    done
    # The relays are published under their own prefixes with their own manifests.
    for n in cmux-relay chatmux-relay; do
      curl -fsS --retry 3 -o "$out/$n-manifest.json" "https://files.cmux.com/$n/$sha/manifest.json"
      curl -fsS --retry 3 -o "$out/$n-$t" "https://files.cmux.com/$n/$sha/$n-$t"
    done
  done
  python3 - "$out" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
expected = dict(json.loads((out / "manifest.json").read_text())["binaries"])
expected.update(json.loads((out / "cmux-relay-manifest.json").read_text())["binaries"])
for target, files in json.loads((out / "chatmux-relay-manifest.json").read_text())["artifacts"].items():
    expected[files["chatmux-relay"]["name"]] = files["chatmux-relay"]["sha256"]
for path in sorted(out.glob("*-apple-darwin")):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if expected.get(path.name) != digest:
        raise SystemExit(f"checksum mismatch for {path.name}")
    print(f"ref {path.name} sha256 {digest[:16]}")
PY
}

cmd_hosts() {
  local sha=${1:?sha} ghostty=${2:?ghostty sha} version=${3:-0.0.0-r2.sha-$1} out="$XC_ROOT/linux"; mkdir -p "$out"
  export CARGO_TARGET_DIR="${XC_CARGO_TARGET_DIR:-$XC_ROOT/target-hosts}" CMUX_GHOSTTY_SRC=""
  for t in "${TARGETS[@]}"; do
    use_target "$t" "${MIN_OS[$t]}"
    local start; start=$(date +%s)
    # The same stamps the Mac build sets (cmux-tui-build-package.yml).
    (cd "$repo_root/cmux-tui"
      CMUX_TUI_BUILD_COMMIT=$sha CMUX_TUI_GHOSTTY_COMMIT=$ghostty CMUX_TUI_DISTRIBUTION_VERSION=$version \
        cargo build -p cmux-app-host --bin cmux-app-host --release --locked --target "$t"
      CMUX_BUILD_SHA=$sha cargo build -p cmux-browser-host --bin cmux-browser-host --release --locked --target "$t")
    (cd "$repo_root/first-party-apps/cloud/server" && cargo build --bin cmux-cloud --release --locked --target "$t")
    echo "hosts $t: $(( $(date +%s) - start )) s"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-app-host" "$out/cmux-tui-app-host-$t"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-browser-host" "$out/cmux-tui-browser-host-$t"
    cp "$CARGO_TARGET_DIR/$t/release/cmux-cloud" "$out/cmux-tui-cloud-server-$t"
  done
}

cmd_bins() {
  local sha=${1:?sha} ghostty=${2:?ghostty sha} version=${3:?distribution version} out="$XC_ROOT/linux"; mkdir -p "$out"
  [[ -f "$SYSROOT/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd" ]] \
    || die "no framework stubs in $SYSROOT; run the toolchain command first"
  export CARGO_TARGET_DIR="${XC_CARGO_TARGET_DIR:-$XC_ROOT/target-bins}"
  # Package artifacts build and stamp the checked-out submodule (cmux-tui-build-package.yml).
  unset CMUX_GHOSTTY_SRC
  for t in "${TARGETS[@]}"; do
    use_target "$t" "${MIN_OS[$t]}"
    local start; start=$(date +%s)
    (cd "$repo_root/cmux-tui"
      export CMUX_TUI_BUILD_COMMIT=$sha CMUX_TUI_GHOSTTY_COMMIT=$ghostty CMUX_TUI_DISTRIBUTION_VERSION=$version
      cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --release --locked --target "$t"
      cargo build -p cmux-relay --bin cmux-relay --release --locked --target "$t"
      cargo build -p chatmux-relay --bin chatmux-relay --release --locked --target "$t"
      cargo build -p acpmux --bin acpmux --release --locked --target "$t")
    echo "bins $t: $(( $(date +%s) - start )) s"
    local r="$CARGO_TARGET_DIR/$t/release"
    cp "$r/cmux-tui" "$out/cmux-tui-$t"
    cp "$r/cmux-tui-hook" "$out/cmux-tui-hook-$t"
    cp "$r/acpmux" "$out/cmux-tui-acpmux-$t"
    cp "$r/cmux-relay" "$out/cmux-relay-$t"
    cp "$r/chatmux-relay" "$out/chatmux-relay-$t"
  done
}

cmd_parity_bins() {
  local status=0 reports="$XC_ROOT/reports"; mkdir -p "$reports"
  for n in "${BIN_NAMES[@]}"; do
    for t in "${TARGETS[@]}"; do
      python3 "$repo_root/scripts/ci/macho_parity.py" "$n-$t" "$XC_ROOT/ref/$n-$t" "$XC_ROOT/linux/$n-$t" \
        > "$reports/$n-$t.json" || status=1
      report_line "$reports/$n-$t.json"
    done
  done
  return $status
}

cmd_stubs_check() {
  local refs=()
  for n in "${BIN_NAMES[@]}"; do for t in "${TARGETS[@]}"; do refs+=("$XC_ROOT/ref/$n-$t"); done; done
  python3 "$repo_root/scripts/ci/macos_stubs.py" check "$STUBS_DIR" "${refs[@]}"
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
  bins) cmd_bins "$@" ;;
  weaken-compiler-rt) cmd_weaken_compiler_rt "$@" ;;
  parity-bins) cmd_parity_bins ;;
  stubs-check) cmd_stubs_check ;;
  vt) cmd_vt ;;
  parity-hosts) cmd_parity_hosts ;;
  parity-vt) cmd_parity_vt ;;
  cctools) cmd_cctools ;;
  ffi) cmd_ffi "$@" ;;
  parity-ffi) cmd_parity_ffi "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2 ;;
esac
