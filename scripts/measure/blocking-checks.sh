#!/usr/bin/env bash
# Verify the main-thread blocking detector's build configurations (plans/cmux-next/threading-model.md):
#   1. Release (what users get): the detector is compiled out. No object of the CmuxNextApp scheme's Release
#      build defines or references a detector symbol, and the inlinable check is a bare return.
#   2. The Nightly configuration (Release + -DCMUX_BLOCKING_CHECKS, what nightly.yml will pass once its line
#      lands; bench builds pass it today): it compiles, and the detector is in it (the flag reaches the
#      package targets).
#   3. Nightly's tests and cost: CmuxNextCompat and its blocking tests in a scratch package built
#      `-c release -DCMUX_BLOCKING_CHECKS` (no DEBUG): records, never traps, and a clean checked call
#      costs < 50 ns (BlockingCheckCostTests).
# Fleet: cmux-ci run --class exclusive --script scripts/measure/blocking-checks.sh --ref SHA
#        --artifact artifacts/blocking-checks.tar.gz
# Output: artifacts/blocking-checks/ (summary.txt, logs), and the tarball.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# The detector lands in slice (a) of plans/cmux-next/threading-model.md; before it, there is nothing to verify.
if [[ ! -f Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/BlockingCheck.swift ]]; then
  echo "blocking-checks: this commit has no main-thread blocking detector (CmuxNextCompat/Threading/BlockingCheck.swift);" \
    "it lands with slice (a) of plans/cmux-next/threading-model.md. Run this at a commit that has it." >&2
  exit 2
fi
OUT="$ROOT/artifacts/blocking-checks"
rm -rf "$OUT"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
status=0
note() { echo "$*" | tee -a "$SUMMARY"; }
fail() { note "FAIL: $*"; status=1; }

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  pinned="$(awk '$1 == "26" { print $2 }' scripts/ci/xcode-pins.txt)"
  if [[ -d "/Applications/Xcode_${pinned}.app" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode_${pinned}.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"  # a host without the nightly's pin (nx-remote hosts); the summary names it
  fi
fi
note "xcode: $(xcodebuild -version | tr '\n' ' ')"
note "commit: $(git rev-parse HEAD)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/blocking-checks.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

DETECTOR_SYMBOL='BlockingViolationTable|BlockingPendingRing|BlockingSiteIndex|BlockingRunLoopNesting|mainThreadBlocked|mainThreadWaitedForLock'

release_build() {  # $1: name, $2...: extra build settings
  local name="$1"; shift
  ( cd Packages/macOS/CmuxNext && "$ROOT/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
      xcodebuild -scheme CmuxNextApp -configuration Release -destination 'generic/platform=macOS' \
      -derivedDataPath "$scratch/$name" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
      CODE_SIGNING_ALLOWED=NO "$@" build ) >"$OUT/$name.log" 2>&1
}

# 1. Release: no object of the whole Release build defines or references a detector symbol, and the public
# inlinable check that every seam calls is a bare return. Any missing piece is a failure, never a skip.
if release_build release; then
  objects=()
  while IFS= read -r -d '' object; do objects+=("$object"); done < <(find "$scratch/release/Build" -name '*.o' -print0)
  compat=0
  for object in "${objects[@]}"; do [[ "$object" == *CmuxNextCompat* ]] && compat=$((compat + 1)); done
  note "release: compiled; objects: ${#objects[@]} (CmuxNextCompat: $compat)"
  [[ ${#objects[@]} -gt 0 && $compat -gt 0 ]] || fail "release: found no objects to inspect"
  if [[ ${#objects[@]} -gt 0 ]]; then
    # nm's errors go to the log and fail the check: an unread object must never look clean.
    if ! printf '%s\0' "${objects[@]}" | xargs -0 nm -m 2>"$OUT/release-nm-errors.log" >"$scratch/release-symbols-raw.txt"; then
      fail "release: nm could not read every object (see release-nm-errors.log)"
    fi
    swift demangle --compact <"$scratch/release-symbols-raw.txt" >"$scratch/release-symbols.txt"
    count="$(grep -Ec "$DETECTOR_SYMBOL" "$scratch/release-symbols.txt")"
    note "release: detector symbols defined or referenced in any object: $count"
    [[ "$count" -eq 0 ]] || { fail "release: the detector is compiled in"; grep -E "$DETECTOR_SYMBOL" "$scratch/release-symbols.txt" | head -20 >>"$SUMMARY"; }
  fi
  # The object that defines the check (per-file or one per module, as the Release build's WMO emits).
  object=""
  while IFS= read -r -d '' candidate; do
    if nm -U "$candidate" 2>>"$OUT/release-nm-errors.log" | grep -q 'assertBlockingAllowed'; then object="$candidate"; break; fi
  done < <(find "$scratch/release/Build" -name '*.o' -path '*CmuxNextCompat*' -print0)
  [[ -n "$object" ]] || fail "release: no CmuxNextCompat object defines assertBlockingAllowed"
  if [[ -n "$object" ]]; then
    symbol="$(nm -U "$object" | awk '/assertBlockingAllowed/ && ($2 == "T" || $2 == "t") { print $3; exit }')"
    [[ -n "$symbol" ]] || fail "release: no assertBlockingAllowed code symbol in $(basename "$object")"
    if [[ -n "$symbol" ]]; then
      otool -tV -p "$symbol" "$object" | sed -n '1,8p' >"$OUT/release-assertBlockingAllowed.txt"
      first="$(grep -Em1 '^[0-9a-f]+[[:space:]]' "$OUT/release-assertBlockingAllowed.txt" | awk '{ $1=""; print }')"
      note "release: assertBlockingAllowed's first instruction: $first"
      echo "$first" | grep -q 'ret' || fail "release: assertBlockingAllowed does more than return"
    fi
    # pthread_main_np is the check's only call: no CmuxNextCompat object of a Release build may need it.
    while IFS= read -r -d '' candidate; do
      if nm -u "$candidate" 2>>"$OUT/release-nm-errors.log" | grep -q '_pthread_main_np'; then
        fail "release: $(basename "$candidate") references pthread_main_np"
      fi
    done < <(find "$scratch/release/Build" -name '*.o' -path '*CmuxNextCompat*' -print0)
  fi
else
  fail "release: did not compile (see release.log)"
fi

# 2. Nightly configuration
if release_build nightly 'OTHER_SWIFT_FLAGS=$(inherited) -DCMUX_BLOCKING_CHECKS'; then
  count="$(find "$scratch/nightly/Build" -name '*.o' -path '*CmuxNextCompat*' -print0 | xargs -0 nm -U 2>>"$OUT/nightly-nm-errors.log" \
    | swift demangle --compact | grep -Ec "$DETECTOR_SYMBOL")"
  note "nightly (-DCMUX_BLOCKING_CHECKS): compiled; detector symbols in CmuxNextCompat: $count"
  [[ "$count" -gt 0 ]] || fail "nightly: the flag did not reach CmuxNextCompat"
else
  fail "nightly: did not compile (see nightly.log)"
fi

# 3. Nightly tests and cost, in a scratch package holding CmuxNextCompat and its blocking tests.
pkg="$scratch/pkg"
mkdir -p "$pkg/Sources" "$pkg/Tests/CmuxNextCompatTests"
cp -R Packages/macOS/CmuxNext/Sources/CmuxNextCompat "$pkg/Sources/"
cp Packages/macOS/CmuxNext/Tests/CmuxNextCompatTests/BlockingCheck*.swift "$pkg/Tests/CmuxNextCompatTests/"
revision="$(python3 -c "import json,sys;print(next(p['state']['revision'] for p in json.load(open(sys.argv[1]))['pins'] if p['identity']=='swift-atomics'))" Packages/macOS/CmuxNext/Package.resolved)"
# The real package's settings, read from its manifest: CmuxNextCompat builds with daemonSwiftSettings and its
# tests with uiSwiftSettings, as in Packages/macOS/CmuxNext/Package.swift.
settings_swift="$(python3 - Packages/macOS/CmuxNext/Package.swift <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for name in ("uiSwiftSettings", "daemonSwiftSettings"):
    block = re.search(r"^let " + name + r": \[SwiftSetting\] = \[.*?^\]$", text, re.S | re.M)
    if not block:
        sys.exit(f"blocking-checks: no `let {name}` in the manifest")
    print(block.group(0))
PY
)" || { fail "nightly tests: could not read the package's Swift settings"; settings_swift=""; }
compat_settings="$(grep -A3 'name: "CmuxNextCompat",' Packages/macOS/CmuxNext/Package.swift | grep -o 'swiftSettings: [A-Za-z]*' | awk '{ print $NF }' | head -1)"
tests_settings="$(grep -A3 'name: "CmuxNextCompatTests"' Packages/macOS/CmuxNext/Package.swift | grep -o 'swiftSettings: [A-Za-z]*' | awk '{ print $NF }' | head -1)"
note "nightly tests: CmuxNextCompat uses ${compat_settings:-?}, its tests ${tests_settings:-?} (from the manifest)"
cat >"$pkg/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
$settings_swift
let package = Package(
    name: "BlockingChecks",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/apple/swift-atomics.git", revision: "$revision")],
    targets: [
        .target(name: "CmuxNextCompat", dependencies: [.product(name: "Atomics", package: "swift-atomics")],
                swiftSettings: ${compat_settings:-daemonSwiftSettings}),
        .testTarget(name: "CmuxNextCompatTests", dependencies: ["CmuxNextCompat"],
                    swiftSettings: ${tests_settings:-uiSwiftSettings}),
    ]
)
SWIFT
flags=(-c release -Xswiftc -enable-testing -Xswiftc -DCMUX_BLOCKING_CHECKS)
# The tests use the probe-free table seams (@testable); a Nightly-configuration test run proves the record-only
# path, the clean-path cost (< 50 ns per checked call) and that a Nightly never traps.
if swift build --build-tests "${flags[@]}" --package-path "$pkg" >"$OUT/nightly-tests-build.log" 2>&1; then
  swift test --skip-build "${flags[@]}" --package-path "$pkg" >"$OUT/nightly-tests.log" 2>&1
  test_status=$?
  grep -E 'blocking-check cost:' "$OUT/nightly-tests.log" | sed 's/^.*blocking-check/nightly: blocking-check/' | tee -a "$SUMMARY"
  passed="$(grep -Ec '✔ Test .* passed' "$OUT/nightly-tests.log")"
  failed="$(grep -Ec '✘ Test .* (failed|recorded an issue)' "$OUT/nightly-tests.log")"
  note "nightly tests: $passed passed, $failed failed (exit $test_status)"
  [[ "$test_status" -eq 0 && "$passed" -gt 0 ]] || fail "nightly tests"
else
  fail "nightly tests: did not compile (see nightly-tests-build.log)"
fi

tar -czf "$ROOT/artifacts/blocking-checks.tar.gz" -C "$ROOT/artifacts" blocking-checks
note "result: $([[ $status -eq 0 ]] && echo ok || echo FAILED)"
exit "$status"
