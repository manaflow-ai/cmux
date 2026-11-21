#!/usr/bin/env bash
# The hover rules' main-thread cost per pointer move at one commit: Lawrence's HoverCardSweepBench
# (Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/HoverCardSweepBench.swift) in a release build, RUNS test
# processes, alone on an exclusive worker. The rules are whatever that commit has: the Swift reducers before
# B8 step B, the Rust hover rules through the app FFI after.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/hover-sweep.sh \
#     --ref <feat-cmux-next tip> --arg=sha=<commit> [--arg=ffi=source] [--arg=runs=5]
#
# Runs at the tip ref (the controller takes an unlisted scripts/measure script only at a commit on
# feat-cmux-next or main), so every commit is measured with today's harness: sha= is checked out whole into a
# scratch worktree (fetched when the step's checkout lacks it), and this checkout's HoverCardSweepBench.swift is
# copied in when the commit has none, so a base before the bench existed runs the same sweep. Without sha= it
# measures the checkout itself.
#
# ffi=pinned (default) links the CCmuxAppFFI release the commit's app-ffi-pin.json names. ffi=source builds
# the FFI from the commit's cmux-tui sources (scripts/cmux-next/build-app-ffi.sh: arm64, its release
# settings) and points the package's appFFI binary target at it, for a commit whose Swift needs FFI changes no
# release carries yet (an unlanded step B).
#
# The build and the test processes are the commit's own scripts/ci/package-test-lane.sh suite (Xcode, GhosttyKit,
# watchdog), with CMUX_SWIFT_SUITE_CONFIGURATION=release and CMUX_HOVER_SWEEP_BENCH=1.
# Prints `HS host NAME chip="..." macOS V`, `HS sha SHA ffi MODE runs N`, then the suite's output with one
#   hover-card sweep bench: macOS ..., N pointer moves over 60 rows: p50 X ns, p95 Y ns, p99 Z ns, max W ns ...
# line per process (scripts/bench/benches/hover_sweep.py reads them).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bench_rel="Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/HoverCardSweepBench.swift"
sha="" ffi=pinned runs=5
for a in "$@"; do
  case "$a" in
    sha=*) sha="${a#sha=}" ;;
    ffi=pinned|ffi=source) ffi="${a#ffi=}" ;;
    runs=*) runs="${a#runs=}" ;;
    *) echo "error: unknown argument $a (sha=COMMIT, ffi=pinned|source, runs=N)" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]?$ ]] || { echo "error: runs must be 1 to 99" >&2; exit 2; }
[[ -z "$sha" || "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: sha must be a full 40-character commit id" >&2; exit 2; }

echo "HS host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null)\" macOS $(sw_vers -productVersion 2>/dev/null)"

tree="$root"
scratch=""
cleanup() {
  if [[ -n "$scratch" ]]; then
    git -C "$root" worktree remove --force "$scratch/tree" >/dev/null 2>&1 || true
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT
if [[ -n "$sha" && "$sha" != "$(git -C "$root" rev-parse HEAD)" ]]; then
  if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
    depth=()
    [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
    git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} origin "$sha"
  fi
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/hover-sweep.XXXXXX")"
  git -C "$root" worktree add -q --detach "$scratch/tree" "$sha"
  tree="$scratch/tree"
fi
echo "HS sha $(git -C "$tree" rev-parse HEAD) ffi $ffi runs $runs"
if [[ ! -f "$tree/$bench_rel" ]]; then
  cp "$root/$bench_rel" "$tree/$bench_rel"
  echo "HS bench copied in from $(git -C "$root" rev-parse --short=11 HEAD)"
fi

pkg="$tree/Packages/macOS/CmuxNext"
if [[ "$ffi" == source ]]; then
  # shellcheck source=scripts/lib/rust-targets.sh
  source "$tree/scripts/lib/rust-targets.sh"
  (cd "$tree/cmux-tui/crates/cmux-app-ffi" && ensure_rust_targets aarch64-apple-darwin >/dev/null)
  start=$SECONDS
  CMUX_APP_FFI_ARCHS=arm64 CMUX_APP_FFI_OUT="$pkg/.bench-ffi" bash "$tree/scripts/cmux-next/build-app-ffi.sh" >&2
  echo "HS ffi built from source in $((SECONDS - start)) s"
  # In the scratch tree only (or restored on exit when measuring the checkout itself).
  [[ "$tree" != "$root" ]] || { cp "$pkg/Package.swift" "$pkg/.Package.swift.orig"; trap 'mv -f "$pkg/.Package.swift.orig" "$pkg/Package.swift"; rm -rf "$pkg/.bench-ffi"; cleanup' EXIT; }
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

suites=()
for _ in $(seq 1 "$runs"); do suites+=(HoverCardSweepBench); done
cd "$tree"
CMUX_SWIFT_SUITE_CONFIGURATION=release CMUX_HOVER_SWEEP_BENCH=1 \
  bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext "${suites[@]}"
