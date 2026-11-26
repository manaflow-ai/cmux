#!/usr/bin/env bash
# Build the Windows daemon (x86_64-pc-windows-gnu) on Linux, linked against the
# exact MinGW-Builds toolchain package-notices.json windows_gnu reviewed.
#
# The Windows runner's build-windows job linked with that toolchain's gcc at
# C:\mingw64. Here the same archive (sha256-checked against the review) is
# unpacked as a sysroot: clang compiles the C code and lld links, but the
# runtime that ends up in the binaries (crt2.o, libmingw32, libmingwex, the
# UCRT import libraries, libgcc and libgcc_eh) is the reviewed archive's, byte
# for byte. clang stamps no GCC ident, and check-windows-binary accepts a binary
# with none, so the reviewed notices still cover every runtime object.
#
# Usage: windows-gnu-cross-build.sh setup            # fetch + verify the sysroot, print env
#        windows-gnu-cross-build.sh build OUT_DIR    # setup, cargo build, check, stage OUT_DIR
#        windows-gnu-cross-build.sh env              # print the exports (after setup)
# Env: CMUX_WINDOWS_SYSROOT_DIR (cache dir, default $RUNNER_TEMP or ~/.cache), MINGW_ARCHIVE (an
# already downloaded copy of the archive; checked like a download).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
notices="$repo_root/cmux-tui/dist/scripts/package_notices.py"
cache_root="${CMUX_WINDOWS_SYSROOT_DIR:-${RUNNER_TEMP:-$HOME/.cache}/cmux-windows-gnu-sysroot}"

# url and sha256 come from the review record itself, so a new toolchain needs a new review.
read -r url sha < <(python3 "$notices" windows-toolchain-archive)
sysroot="$cache_root/$sha/mingw64"
bindir="$cache_root/$sha/bin"

setup() {
  if [[ ! -f "$cache_root/$sha/.ok" ]]; then
    mkdir -p "$cache_root/$sha"
    local archive="${MINGW_ARCHIVE:-$cache_root/$sha/mingw.7z}"
    if [[ ! -f "$archive" ]]; then
      curl -fsSL --retry 4 --retry-all-errors --max-time 600 -o "$archive.part" "$url"
      mv "$archive.part" "$archive"
    fi
    echo "$sha  $archive" | sha256sum -c - >&2
    rm -rf "$sysroot"
    # Only what linking and C compiling read: headers, libraries, crt objects.
    7z x -y -bd -o"$cache_root/$sha" "$archive" \
      'mingw64/x86_64-w64-mingw32/include' 'mingw64/x86_64-w64-mingw32/lib' \
      'mingw64/lib/gcc' 'mingw64/include' >/dev/null
    rm -f "$cache_root/$sha/mingw.7z"
    mkdir -p "$bindir"
    for tool in cc c++; do
      drv=clang; [[ "$tool" == c++ ]] && drv=clang++
      cat > "$bindir/x86_64-w64-mingw32-$tool" <<EOF
#!/bin/sh
exec $drv --target=x86_64-w64-mingw32 --sysroot="$sysroot" -fuse-ld=lld "\$@"
EOF
      chmod +x "$bindir/x86_64-w64-mingw32-$tool"
    done
    # rustc's raw-dylib imports (windows-sys, getrandom) call the MinGW dlltool by name.
    dlltool="$(command -v llvm-dlltool || command -v llvm-dlltool-18 || true)"
    [[ -n "$dlltool" ]] || { echo "windows-gnu-cross-build: llvm-dlltool is missing (apt: llvm)" >&2; exit 1; }
    ln -sf "$dlltool" "$bindir/x86_64-w64-mingw32-dlltool"
    touch "$cache_root/$sha/.ok"
  fi
  python3 "$notices" check-windows-sysroot "$sysroot" --cc "$bindir/x86_64-w64-mingw32-cc" >&2
}

print_env() {
  cat <<EOF
export PATH="$bindir:\$PATH"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$bindir/x86_64-w64-mingw32-cc"
export CC_x86_64_pc_windows_gnu="$bindir/x86_64-w64-mingw32-cc"
export CXX_x86_64_pc_windows_gnu="$bindir/x86_64-w64-mingw32-c++"
export AR_x86_64_pc_windows_gnu="$(command -v llvm-ar || command -v llvm-ar-18 || echo llvm-ar)"
export BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu="--target=x86_64-w64-mingw32 --sysroot=$sysroot"
EOF
}

bins=(cmux-tui cmux-tui-hook cmux-tui-host cmux-relay chatmux-relay)

build() {
  local out="${1:?OUT_DIR}"
  setup
  eval "$(print_env)"
  cd "$repo_root/cmux-tui"
  cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --bin cmux-tui-host --release --locked --target x86_64-pc-windows-gnu
  cargo build -p cmux-relay --bin cmux-relay --release --locked --target x86_64-pc-windows-gnu
  cargo build -p chatmux-relay --bin chatmux-relay --release --locked --target x86_64-pc-windows-gnu
  mkdir -p "$out"
  for b in "${bins[@]}"; do
    cp "target/x86_64-pc-windows-gnu/release/$b.exe" "$out/$b-x86_64-pc-windows-gnu.exe"
  done
  python3 "$notices" check-windows-binary "$out"/*.exe
  ls -la "$out"
}

case "${1:-}" in
  setup) setup; print_env ;;
  env) print_env ;;
  build) build "${2:-}" ;;
  *) echo "usage: $0 setup|env|build OUT_DIR" >&2; exit 2 ;;
esac
