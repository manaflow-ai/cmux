#!/usr/bin/env bash
# Runs the Windows cmux-rd host on Linux: cross-builds cmux-rd.exe for x86_64-pc-windows-gnu
# (mingw) and runs it under wine on a virtual X display. A Linux lane iterates on the Windows
# `serve`, its secure link (WSAPoll driver), GDI capture and OpenH264 without a Windows runner.
#
#   scripts/cmux-next/rd-windows-wine.sh                 # build, then the serve selftest (view, control)
#   scripts/cmux-next/rd-windows-wine.sh test [FILTER]   # the Windows cargo tests the CI job runs
#   scripts/cmux-next/rd-windows-wine.sh run ARGS...     # cmux-rd.exe ARGS under wine
#
# Needs: wine (wine64), mingw-w64, xvfb (xvfb-run), and the pinned toolchain's
# x86_64-pc-windows-gnu target; `--install` adds them (apt and rustup).
# Wine is not Windows: a pass here does not prove the real runner (cmux-rd-windows.yml) passes.
# A new prefix's first serve can end in "BitBlt failed (Invalid handle)" while wine sets up its
# desktop; the next run captures.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
crate="$root/cmux-tui/crates/cmux-rd-host"
target=x86_64-pc-windows-gnu
toolchain="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/cmux-tui/rust-toolchain.toml")"
features=(--no-default-features --features bench,link)

if [[ "${1:-}" == --install ]]; then
  shift
  sudo apt-get install -y wine64 mingw-w64 xvfb xauth
  # shellcheck source=scripts/lib/rust-targets.sh
  source "$root/scripts/lib/rust-targets.sh"
  ensure_rust_targets --toolchain "$toolchain" "$target"
fi
for tool in wine xvfb-run x86_64-w64-mingw32-gcc; do
  command -v "$tool" >/dev/null || { echo "rd-windows-wine: $tool is missing; rerun with --install" >&2; exit 2; }
done

# mingw's C++ runtime (OpenH264 built from source links it) and winpthread, found by wine.
gcc_dir="$(dirname "$(x86_64-w64-mingw32-g++ -print-file-name=libstdc++-6.dll)")"
pthread_dir="$(dirname "$(x86_64-w64-mingw32-gcc -print-file-name=libwinpthread-1.dll)")"
export WINEPREFIX="${WINEPREFIX:-$HOME/.cache/cmux-rd-wine-prefix}"
export WINEDEBUG="${WINEDEBUG:--all}"
# A new prefix is set up once, to its end, with no X display and nothing on WINEPATH.
if [[ ! -f "$WINEPREFIX/.cmux-rd-ready" ]]; then
  DISPLAY= wineboot -u >/dev/null 2>&1 || true
  wineserver -w
  wine cmd /c ver >/dev/null 2>&1 || {
    echo "rd-windows-wine: the wine prefix $WINEPREFIX does not start; set WINEPREFIX to a new path" >&2
    exit 2
  }
  touch "$WINEPREFIX/.cmux-rd-ready"
fi
# Set after the prefix is: wineboot with these on WINEPATH leaves a prefix with no kernel32.dll.
export WINEPATH="Z:${gcc_dir//\//\\};Z:${pthread_dir//\//\\}"
runner="$(mktemp -d)/wine-run"
trap 'rm -rf "$(dirname "$runner")"' EXIT
cat >"$runner" <<'EOF'
#!/bin/sh
exec xvfb-run -a -s "-screen 0 1280x720x24" wine "$@"
EOF
chmod +x "$runner"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUNNER="$runner"

cd "$crate"
exe="target/$target/release/cmux-rd.exe"
build() { cargo build --release --locked --target "$target" "${features[@]}"; }

case "${1:-selftest}" in
  selftest)
    build
    for scope in view control; do
      "$runner" "$exe" windows-serve-selftest --scope "$scope" --duration-s 3
    done
    ;;
  test)
    filter=("${@:2}")
    if [[ ${#filter[@]} -eq 0 ]]; then filter=(windows_serve windows_host screen_host); fi
    cargo test --release --locked --target "$target" "${features[@]}" -- "${filter[@]}"
    cargo test --release --locked --target "$target" --features net --manifest-path ../cmux-rd-link/Cargo.toml
    ;;
  run)
    build
    "$runner" "$exe" "${@:2}"
    ;;
  *)
    echo "usage: $0 [--install] [selftest | test [FILTER...] | run ARGS...]" >&2
    exit 2
    ;;
esac
