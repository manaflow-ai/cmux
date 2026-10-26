#!/usr/bin/env bash
# Verify the main-thread blocking detector's build configurations (plans/cmux-next/threading-model.md):
#   1. Release (what users get): the detector is compiled out. No object of the CmuxNextApp scheme's Release
#      build defines or references a detector symbol, and the inlinable check is a bare return.
#   2. The Nightly configuration (Release + -DCMUX_BLOCKING_CHECKS, what nightly.yml passes on the
#      nightly-next track and `reload.sh --config bench-checks` passes): it compiles, and the detector is in it (the flag reaches
#      the package targets).
#   3. Nightly's tests and cost: CmuxNextCompat and its blocking tests in a scratch package built
#      `-c release -DCMUX_BLOCKING_CHECKS` (no DEBUG): records, never traps, and a clean checked call
#      costs < 50 ns (BlockingCheckCostTests).
# Fleet: cmux-ci run --class exclusive --script scripts/measure/blocking-checks.sh --ref SHA
#        --artifact artifacts/blocking-checks.tar.gz
# Output: artifacts/blocking-checks/ (summary.txt, logs), and the tarball.
#
# App mode: scripts/measure/blocking-checks.sh --app PATH --expect nightly|release
#   Reads a built app's main executable with nm (and its Contents/Resources/cmux-symbols.bin, the function
#   names the release strip keeps) and needs no build. `nightly` exits 1 unless the detector is in the app
#   (a nightly-next build; RUN-9), `release` exits 1 unless it is absent (RUN-11). Exits 2 when the app has
#   no function names to read (stripped, no symbol map) or the arguments are wrong.
#   Tests: bash scripts/measure/tests/blocking-checks-app.test.sh
set -uo pipefail

DETECTOR_SYMBOL='BlockingViolationTable|BlockingPendingRing|BlockingSiteIndex|BlockingRunLoopNesting|mainThreadBlocked|mainThreadWaitedForLock'

usage() {
  echo "usage: $0 [--app PATH --expect nightly|release]" >&2
}

# The function names of the cmux NEXT symbol map ($1, scripts/write-app-symbol-map.py's format), one per line.
symbol_map_names() {
  python3 -I - "$1" <<'PY'
import struct, sys, zlib
blob = open(sys.argv[1], "rb").read()
if blob[:8] != b"CMXSYM1\0":
    sys.exit(f"blocking-checks: {sys.argv[1]} is not an app symbol map")
(count,) = struct.unpack_from("<I", blob, 8)
at = 12
for _ in range(count):
    (size,) = struct.unpack_from("<I", blob, at + 16)
    body = zlib.decompress(blob[at + 20:at + 20 + size], -15)
    at += 20 + size
    (symbols,) = struct.unpack_from("<I", body, 0)
    pos = 4
    for _ in range(symbols):  # skip the LEB128 offset deltas
        while body[pos] & 0x80:
            pos += 1
        pos += 1
    for name in body[pos:].split(b"\0"):
        if name:
            print(name.decode("utf-8", "replace"))
PY
}

# App mode: is the detector in the app at $1? $2 is what the build should be: nightly (in) or release (out).
check_app() {
  local app="$1" expect="$2"
  local nm_tool="${CMUX_NM_TOOL:-nm}" demangle_tool="${CMUX_SWIFT_DEMANGLE_TOOL:-swift}"
  local demangle_args=(demangle --compact)
  [[ -n "${CMUX_SWIFT_DEMANGLE_TOOL:-}" ]] && demangle_args=(--compact)
  [[ -d "$app/Contents" ]] || { echo "blocking-checks: no app bundle at $app" >&2; return 2; }
  local exe_name
  exe_name="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleExecutable"])' \
    "$app/Contents/Info.plist" 2>/dev/null)" || exe_name=""
  local exe="$app/Contents/MacOS/$exe_name"
  [[ -n "$exe_name" && -f "$exe" ]] || { echo "blocking-checks: no main executable in $app" >&2; return 2; }
  local raw
  raw="$(mktemp "${TMPDIR:-/tmp}/blocking-checks-app.XXXXXX")" || return 2
  # nm's error fails the check: an executable nm cannot read must never look clean.
  if ! "$nm_tool" "$exe" >"$raw"; then
    rm -f -- "$raw"
    echo "blocking-checks: nm could not read $exe" >&2
    return 2
  fi
  # Function names nm sees, not counting the header symbol a stripped executable keeps.
  local functions
  functions="$(awk '($2 == "t" || $2 == "T") && $3 != "__mh_execute_header"' "$raw" | wc -l | tr -d ' ')"
  local map="$app/Contents/Resources/cmux-symbols.bin" sources="nm ($functions function names)"
  if [[ -f "$map" ]]; then
    if ! symbol_map_names "$map" >>"$raw"; then
      rm -f -- "$raw"
      echo "blocking-checks: could not read the symbol map $map" >&2
      return 2
    fi
    sources+=", cmux-symbols.bin"
  elif [[ "$functions" -eq 0 ]]; then
    rm -f -- "$raw"
    echo "blocking-checks: $exe is stripped and $app has no Contents/Resources/cmux-symbols.bin: no function names to read" >&2
    return 2
  fi
  local demangled status=0
  if ! demangled="$("$demangle_tool" "${demangle_args[@]}" <"$raw")"; then
    rm -f -- "$raw"
    echo "blocking-checks: $demangle_tool ${demangle_args[*]} failed" >&2
    return 2
  fi
  rm -f -- "$raw"
  local hits count
  hits="$(grep -E "$DETECTOR_SYMBOL" <<<"$demangled")"
  count="$(grep -c . <<<"$hits")"
  echo "blocking-checks: $exe_name: $count detector symbols (read from $sources)"
  if [[ "$expect" == nightly && "$count" -eq 0 ]]; then
    echo "FAIL: the detector is not in $app; the nightly-next build did not pass -DCMUX_BLOCKING_CHECKS" >&2
    status=1
  elif [[ "$expect" == release && "$count" -gt 0 ]]; then
    echo "FAIL: the detector is compiled into $app, a Release build" >&2
    printf '%s\n' "$hits" | head -20 >&2
    status=1
  fi
  return "$status"
}

app="" expect=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--expect)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      if [[ "$1" == --app ]]; then app="$2"; else expect="$2"; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [[ -n "$app" || -n "$expect" ]]; then
  [[ -n "$app" && ( "$expect" == nightly || "$expect" == release ) ]] || { usage; exit 2; }
  check_app "$app" "$expect"
  exit $?
fi

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
# tests with uiSwiftSettings, as in Packages/macOS/CmuxNext/Package.swift. A `let NAME: [SwiftSetting]` statement
# runs to the next column-0 line that does not continue it (`] + stabilitySwiftSettings` continues it), and the
# settings constants it names come first, so the scratch manifest declares each one once.
compat_settings="$(grep -A3 'name: "CmuxNextCompat",' Packages/macOS/CmuxNext/Package.swift | grep -o 'swiftSettings: [A-Za-z]*' | awk '{ print $NF }' | head -1)"
tests_settings="$(grep -A3 'name: "CmuxNextCompatTests"' Packages/macOS/CmuxNext/Package.swift | grep -o 'swiftSettings: [A-Za-z]*' | awk '{ print $NF }' | head -1)"
note "nightly tests: CmuxNextCompat uses ${compat_settings:-?}, its tests ${tests_settings:-?} (from the manifest)"
settings_swift="$(python3 - Packages/macOS/CmuxNext/Package.swift "${compat_settings:-daemonSwiftSettings}" \
  "${tests_settings:-uiSwiftSettings}" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
starts = {m.group(1): i for i, line in enumerate(lines) if (m := re.match(r"let (\w+): \[SwiftSetting\] = ", line))}


def statement(name):
    first = last = starts[name]
    for index in range(first + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line[0].isspace() and line[0] not in "])}+.":
            break
        if line.strip():
            last = index
    return "\n".join(lines[first:last + 1])


emitted = []


def emit(name, chain):
    if name in emitted:
        return
    if name not in starts:
        sys.exit(f"blocking-checks: {' -> '.join(chain + [name])}: no `let {name}: [SwiftSetting]` in the manifest")
    for used in re.findall(r"\b\w+SwiftSettings\b", statement(name).split("=", 1)[1]):
        if used not in chain + [name]:
            emit(used, chain + [name])
    emitted.append(name)


for name in dict.fromkeys(sys.argv[2:]):
    emit(name, [])
print("\n".join(statement(name) for name in emitted))
PY
)" || { fail "nightly tests: could not read the package's Swift settings"; settings_swift=""; }
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
# The scratch manifest parses before the build, so a settings edit in the real manifest that this copy does not
# follow fails here by name, not as a compile failure of the tests.
swift package dump-package --package-path "$pkg" >"$OUT/nightly-tests-manifest.json" 2>"$OUT/nightly-tests-manifest.log" \
  || fail "nightly tests: the scratch Package.swift does not parse (see nightly-tests-manifest.log)"
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
