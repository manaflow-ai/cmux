#!/usr/bin/env bash
# The hover rules' main-thread cost per pointer move: Lawrence's HoverCardSweepBench
# (Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/HoverCardSweepBench.swift) in a release
# build, RUNS times, at the checkout's commit. The rules are whatever that commit has: the Swift
# reducers before B8 step B, the Rust hover rules through the app FFI after.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/hover-sweep.sh \
#     --ref <sha> [--arg=ffi=source] [--arg=runs=5]
#
# ffi=pinned (default) links the CCmuxAppFFI release app-ffi-pin.json names. ffi=source builds the
# FFI from this commit's cmux-tui sources (scripts/cmux-next/build-app-ffi.sh: arm64, its release
# settings) and points the package's appFFI binary target at it for this run only, for a commit
# whose Swift needs FFI changes no release carries yet. Package.swift is restored on exit.
#
# Prints `HS host NAME chip="..." macOS V`, `HS ref SHA ffi MODE runs N`, and one line per run:
#   HS-RUN hover-card sweep bench: macOS ..., N pointer moves over 60 rows: p50 X ns, p95 Y ns, p99 Z ns, max W ns ...
# (scripts/bench/benches/hover_sweep.py reads them).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pkg="$root/Packages/macOS/CmuxNext"
ffi=pinned runs=5
for a in "$@"; do
  case "$a" in
    ffi=pinned|ffi=source) ffi="${a#ffi=}" ;;
    runs=*) runs="${a#runs=}" ;;
    *) echo "error: unknown argument $a (ffi=pinned|source, runs=N)" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]?$ ]] || { echo "error: runs must be 1 to 99" >&2; exit 2; }

echo "HS host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null)\" macOS $(sw_vers -productVersion 2>/dev/null)"
echo "HS ref $(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown) ffi $ffi runs $runs"

if [[ "$ffi" == source ]]; then
  out="$pkg/.bench-ffi"
  cp "$pkg/Package.swift" "$pkg/.Package.swift.bench-orig"
  trap 'mv -f "$pkg/.Package.swift.bench-orig" "$pkg/Package.swift"; rm -rf "$out"' EXIT
  # shellcheck source=scripts/lib/rust-targets.sh
  source "$root/scripts/lib/rust-targets.sh"
  (cd "$root/cmux-tui/crates/cmux-app-ffi" && ensure_rust_targets aarch64-apple-darwin >/dev/null)
  start=$SECONDS
  CMUX_APP_FFI_ARCHS=arm64 CMUX_APP_FFI_OUT="$out" bash "$root/scripts/cmux-next/build-app-ffi.sh" >&2
  echo "HS ffi built from source in $((SECONDS - start)) s"
  python3 -c '
import re, sys
p = sys.argv[1]
s = open(p).read()
s, n = re.subn(r"let appFFI: Target = \.binaryTarget\(\s*name: \"CCmuxAppFFI\",\s*url: appFFIPin\.url,\s*checksum: appFFIPin\.checksum\s*\)",
               "let appFFI: Target = .binaryTarget(name: \"CCmuxAppFFI\", path: \".bench-ffi/CCmuxAppFFI.xcframework\")", s)
if n != 1:
    sys.exit("error: Package.swift: no appFFI binaryTarget(url:checksum:) block to point at the source build")
open(p, "w").write(s)
' "$pkg/Package.swift"
fi

cd "$pkg"
swift build -c release --build-tests >&2
for i in $(seq 1 "$runs"); do
  line="$(CMUX_HOVER_SWEEP_BENCH=1 swift test -c release --skip-build --filter HoverCardSweepBench 2>&1 \
    | grep 'hover-card sweep bench:' | head -1 || true)"
  [[ -n "$line" ]] || { echo "error: run $i printed no 'hover-card sweep bench:' line" >&2; exit 1; }
  echo "HS-RUN hover-card sweep bench:${line#*hover-card sweep bench:}"
done
