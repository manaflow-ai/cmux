#!/usr/bin/env bash
# Build and run the coverage-guided Swift fuzz targets of Packages/Shared/CmuxFuzzSupport/LinuxFuzz
# (libFuzzer with SanitizerCoverage and ASan, swiftc -sanitize=fuzzer,address) with resource
# limits, and classify what each run found. The Swift counterpart of rust-fuzz.sh: the stability
# lab's swift-fuzz lane (plans/cmux-next/chrome-parity/p10-stability.md, task 182) and people on a
# Linux Testbox or VM run it. It reports; it is not a CI gate.
#
# Chromium's model (testing/libfuzzer/README.md, ClusterFuzz): every target runs with an RSS limit,
# a malloc limit and a per-input timeout, and an out-of-memory or a timeout is a finding like a
# crash, not a flake.
#
# Usage: scripts/cmux-next/swift-libfuzzer.sh (--all | --target NAME[,NAME...]) [--seconds N]
#            [--parallel N] [--out DIR] [--corpus DIR] [--scratch DIR] [--rss-limit-mb N]
#            [--malloc-limit-mb N] [--timeout N] [--sanitizer address|none] [--random-baseline N]
#            [--build-only] [--list] [-- EXTRA LIBFUZZER FLAGS]
#        scripts/cmux-next/swift-libfuzzer.sh --self-test [--out DIR]
#   --all          every target (Sources/*Fuzzer) except SelfTestFuzzer.
#   --target       the named targets only.
#   --seconds      fuzzing time per target (default 300).
#   --parallel     targets fuzzed at once (default 1). Each run is one libFuzzer process.
#   --out          results directory (default artifacts/swift-libfuzzer/<UTC>).
#   --corpus       corpus root (default <out>/corpus). A target's corpus is <root>/<name>, where
#                  <name> is its property suite's run name (MobileProtocol.oneInput, ...), the
#                  layout CmuxFuzzSupport reads: `CMUX_FUZZ_CORPUS=<root> swift test` replays
#                  what the fuzzer found through the same suite. The target's seeds are added
#                  first; what the run finds stays in it.
#   --scratch      SwiftPM scratch directory (default .build/swift-libfuzzer in the checkout).
#   --rss-limit-mb, --malloc-limit-mb, --timeout
#                  libFuzzer limits (defaults 2048, 256 and 2 seconds).
#   --sanitizer    address (default): -sanitize=fuzzer,address, with leak detection; none:
#                  -sanitize=fuzzer only. Without ASan libFuzzer cannot enforce the malloc limit
#                  or find leaks: the run warns and its rows say "malloc_limit_mb": null.
#   --random-baseline N
#                  also run each target once over N random inputs (up to 256 bytes each, the
#                  size CmuxFuzzSupport's random inputs have) and record the edges they reach as
#                  "random_edges" and "random_features", next to the fuzzing run's "edges" and
#                  "features" (the acceptance comparison).
#   --build-only   build the targets and stop.
#   --list         print the target names and stop.
#   --self-test    check the finding classifier: run SelfTestFuzzer on a trap, a failed property,
#                  an oom, a timeout, a leak and a clean input (which fills a static that
#                  LeakSanitizer must not report), all with the same --out, and check each
#                  verdict and exit status. Exit 0 when all six match, 1 otherwise.
# Results: <out>/summary.jsonl (one row per target: target, corpus, verdict, artifact, seconds,
# exit_status, log, sanitizer, malloc_limit_mb, leak_detection, edges, features, corpus_inputs,
# random_edges, random_features), <out>/logs/<target>.log, <out>/artifacts/<target>/<run>/{crash,oom,timeout,leak}-<sha1>.
# Verdicts: clean, crash, oom, timeout, leak, error (libFuzzer stopped with no artifact).
# Exit 0 when every target is clean, 1 on any finding, 2 on a usage error, 75 when the build
# failed, the toolchain has no libFuzzer runtime or a run gave no verdict.
#
# Toolchain: swift.org's Linux toolchain ships the runtime (scripts/cmux-next/linux/setup-swift.sh
# installs it on the Linux VM); Xcode's does not. On macOS the script runs only as a fleet step
# (cmux-ci run), never on a person's Mac (CLAUDE.md, "Agents never compile or test on the person's
# Mac"), and only with a toolchain that has libclang_rt.fuzzer_osx.a.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE="$REPO/Packages/Shared/CmuxFuzzSupport/LinuxFuzz"
SUPPRESSIONS="$PACKAGE/lsan-suppressions.txt"
SELF_TEST_TARGET=SelfTestFuzzer

ALL=0 TARGETS="" SECONDS_PER_TARGET=300 PARALLEL=1 OUT="" CORPUS="" SCRATCH=""
RSS_LIMIT_MB=2048 MALLOC_LIMIT_MB=256 TIMEOUT=2 SANITIZER=address RANDOM_BASELINE=0
BUILD_ONLY=0 LIST=0 SELF_TEST=0
EXTRA=()

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { echo "swift-libfuzzer.sh: $1 needs a value" >&2; exit 2; }
}

need_number() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "swift-libfuzzer.sh: $1 needs a positive integer, got '$2'" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --target) need_value "$@"; TARGETS="$2"; shift 2 ;;
    --seconds) need_value "$@"; need_number "$1" "$2"; SECONDS_PER_TARGET="$2"; shift 2 ;;
    --parallel) need_value "$@"; need_number "$1" "$2"; PARALLEL="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --corpus) need_value "$@"; CORPUS="$2"; shift 2 ;;
    --scratch) need_value "$@"; SCRATCH="$2"; shift 2 ;;
    --rss-limit-mb) need_value "$@"; need_number "$1" "$2"; RSS_LIMIT_MB="$2"; shift 2 ;;
    --malloc-limit-mb) need_value "$@"; need_number "$1" "$2"; MALLOC_LIMIT_MB="$2"; shift 2 ;;
    --timeout) need_value "$@"; need_number "$1" "$2"; TIMEOUT="$2"; shift 2 ;;
    --sanitizer) need_value "$@"; SANITIZER="$2"; shift 2 ;;
    --random-baseline) need_value "$@"; need_number "$1" "$2"; RANDOM_BASELINE="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --list) LIST=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "swift-libfuzzer.sh: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$SANITIZER" in
  address|none) ;;
  *) echo "swift-libfuzzer.sh: --sanitizer must be address or none" >&2; exit 2 ;;
esac

# Every target: a Sources/<name>Fuzzer directory with a main.swift that the manifest lists.
package_targets() {
  local dir name
  for dir in "$PACKAGE"/Sources/*Fuzzer; do
    name="$(basename "$dir")"
    [[ -f "$dir/main.swift" ]] || continue
    grep -qF "(\"$name\"" "$PACKAGE/Package.swift" || {
      echo "swift-libfuzzer.sh: $name has a main.swift but Package.swift does not list it" >&2; exit 75; }
    echo "$name"
  done
}

ALL_TARGETS="$(package_targets)"
KNOWN="$(grep -vxF "$SELF_TEST_TARGET" <<<"$ALL_TARGETS" || true)"
if [[ "$LIST" == 1 ]]; then
  printf '%s\n' "$KNOWN"
  exit 0
fi

# --- Host and toolchain ---------------------------------------------------------------------------
if [[ "$(uname -s)" == Darwin ]]; then
  # shellcheck source=scripts/cmux-next/lib/fleet-only.sh disable=SC1091
  . "$REPO/scripts/cmux-next/lib/fleet-only.sh"
  cmux_next_require_fleet swift-libfuzzer.sh "swift build of the fuzz targets" "none (a stability lab lane)" \
    "cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-libfuzzer.sh -- --all --seconds 600"
fi
if ! command -v swift >/dev/null && [[ -x "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin/swift" ]]; then
  PATH="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/bin:$PATH"
fi
command -v swift >/dev/null || {
  echo "swift-libfuzzer.sh: no swift on PATH (scripts/cmux-next/linux/setup-swift.sh installs it)" >&2; exit 75; }
# The toolchain's usr/ (runtimeResourcePath is usr/lib/swift, also behind swiftly's proxy) holds
# the libFuzzer runtime under lib/ and llvm-symbolizer under bin/; LeakSanitizer's suppressions
# match function names only on a symbolized stack.
TOOLCHAIN_USR="$( (cd / && swiftc -print-target-info 2>/dev/null) | python3 -I -c 'import json, os, sys
print(os.path.dirname(os.path.dirname(json.load(sys.stdin)["paths"]["runtimeResourcePath"])))' 2>/dev/null)" || TOOLCHAIN_USR=""
RUNTIME=""
if [[ -n "$TOOLCHAIN_USR" ]]; then
  RUNTIME="$(find "$TOOLCHAIN_USR/lib" \( -name 'libclang_rt.fuzzer-*.a' -o -name 'libclang_rt.fuzzer_osx.a' \) \
    -print -quit 2>/dev/null || true)"
fi
if [[ -z "$RUNTIME" ]]; then
  echo "swift-libfuzzer.sh: the toolchain at ${TOOLCHAIN_USR:-?} ships no libFuzzer runtime (Xcode's does not);" \
    "use a swift.org toolchain or a Linux Testbox" >&2
  exit 75
fi
SYMBOLIZER="$TOOLCHAIN_USR/bin/llvm-symbolizer"
[[ -x "$SYMBOLIZER" ]] || SYMBOLIZER="$(command -v llvm-symbolizer || true)"

SCRATCH="${SCRATCH:-$REPO/.build/swift-libfuzzer}"
SANITIZE_FLAG="-sanitize=fuzzer,address"
[[ "$SANITIZER" == none ]] && SANITIZE_FLAG="-sanitize=fuzzer"
# Release, as Chromium builds its fuzzers optimized; -enable-testing for the linked suites'
# `@testable import`; a scratch per sanitizer, so switching never relinks the other's objects.
SCRATCH="$SCRATCH/$SANITIZER"
swift_build() {
  (cd / && swift build -c release --package-path "$PACKAGE" --scratch-path "$SCRATCH" \
    -Xswiftc "$SANITIZE_FLAG" -Xswiftc -enable-testing "$@")
}

build_targets() {
  local log="$1"
  mkdir -p "$(dirname "$log")"
  if ! swift_build >"$log" 2>&1; then
    grep -E 'error:' "$log" | sort -u | head -n 40 >&2 || true
    echo "swift-libfuzzer.sh: the fuzz targets did not build (log: $log)" >&2
    exit 75
  fi
  BIN_DIR="$(swift_build --show-bin-path)"
}

# --- Self-test ------------------------------------------------------------------------------------
# Runs this script once per case, so each case goes through the same option parsing, run,
# classification and exit status as a real run.
self_test() {
  if [[ "$SANITIZER" == none ]]; then
    echo "swift-libfuzzer.sh: --self-test needs ASan for its oom and leak cases" >&2
    exit 2
  fi
  local out="${OUT:-$REPO/artifacts/swift-libfuzzer/self-test-$(date -u +%Y%m%dT%H%M%SZ)}"
  local failed=0 case name input want_verdict want_status status verdict
  mkdir -p "$out"
  # The clean case runs last, so the artifacts of the cases before it are under the same --out
  # and must not decide its verdict.
  for case in crash:c:1 property:p:1 oom:o:1 timeout:t:1 leak:l:1 clean:x:0; do
    IFS=: read -r name input want_status <<<"$case"
    want_verdict="$name"
    [[ "$name" == property ]] && want_verdict=crash
    mkdir -p "$out/inputs/$name/SelfTest"
    printf '%s' "$input" >"$out/inputs/$name/SelfTest/input"
    status=0
    # -runs=0: execute the corpus input once and stop, no mutations.
    "${BASH_SOURCE[0]}" --target "$SELF_TEST_TARGET" --out "$out" --corpus "$out/inputs/$name" \
      --scratch "${SCRATCH%/*}" --seconds 60 --timeout 1 -- -runs=0 \
      >"$out/self-test-$name.log" 2>&1 || status=$?
    verdict="$(python3 -I -c 'import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(rows[-1]["verdict"] if rows else "none")' "$out/summary.jsonl" 2>/dev/null || echo none)"
    if [[ "$verdict" == "$want_verdict" && "$status" == "$want_status" ]]; then
      echo "swift-libfuzzer.sh: self-test $name ok (verdict $verdict, exit $status)"
    else
      echo "swift-libfuzzer.sh: self-test $name FAILED: verdict $verdict exit $status," \
        "want verdict $want_verdict exit $want_status (log $out/self-test-$name.log)" >&2
      failed=1
    fi
  done
  exit "$failed"
}

if [[ "$SELF_TEST" == 1 ]]; then
  self_test
fi

if [[ "$ALL" == 1 && -n "$TARGETS" ]]; then
  echo "swift-libfuzzer.sh: give --all or --target, not both" >&2; exit 2
fi
if [[ "$ALL" == 1 ]]; then
  mapfile -t SELECTED <<<"$KNOWN"
elif [[ -n "$TARGETS" ]]; then
  IFS=, read -r -a SELECTED <<<"$TARGETS"
  for target in "${SELECTED[@]}"; do
    grep -qxF -- "$target" <<<"$ALL_TARGETS" || { echo "swift-libfuzzer.sh: no fuzz target '$target' (see --list)" >&2; exit 2; }
  done
else
  echo "swift-libfuzzer.sh: give --all or --target NAME" >&2; usage
fi

if [[ "$SANITIZER" == none ]]; then
  echo "swift-libfuzzer.sh: warning: --sanitizer none: libFuzzer cannot enforce -malloc_limit_mb=$MALLOC_LIMIT_MB or find leaks without ASan; the summary records malloc_limit_mb null" >&2
  MALLOC_LIMIT_RECORDED=null LEAK_DETECTION=false
else
  MALLOC_LIMIT_RECORDED="$MALLOC_LIMIT_MB" LEAK_DETECTION=true
fi

OUT="${OUT:-$REPO/artifacts/swift-libfuzzer/$(date -u +%Y%m%dT%H%M%SZ)}"
CORPUS="${CORPUS:-$OUT/corpus}"
mkdir -p "$OUT/logs" "$OUT/artifacts" "$CORPUS"
OUT="$(cd "$OUT" && pwd)"
CORPUS="$(cd "$CORPUS" && pwd)"

echo "swift-libfuzzer.sh: building ${#SELECTED[@]} targets ($SANITIZE_FLAG, $(swift --version 2>/dev/null | head -n 1))"
build_targets "$OUT/logs/build.log"
if [[ "$BUILD_ONLY" == 1 ]]; then
  echo "swift-libfuzzer.sh: every target builds ($BIN_DIR)"
  exit 0
fi

ASAN_BASE="${ASAN_OPTIONS:-}"
LSAN_BASE="suppressions=$SUPPRESSIONS:print_suppressions=0${LSAN_OPTIONS:+:$LSAN_OPTIONS}"

# A target binary under the run's sanitizer options (its own commands exit through ASan too).
sanitized() {
  ASAN_OPTIONS="$ASAN_BASE" LSAN_OPTIONS="$LSAN_BASE" ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" "$@"
}

# The last coverage line of a libFuzzer log: "<edges> <features> <corpus inputs>", or "null null null".
coverage_of() {
  python3 -I -c 'import re, sys
found = None
for line in open(sys.argv[1], errors="replace"):
    match = re.search(r"\bcov: (\d+) ft: (\d+) corp: (\d+)/", line)
    if match:
        found = match.groups()
print(*(found or ("null",) * 3))' "$1"
}

# "<edges> <features>" N random inputs reach: one pass (-runs=0) over them, nothing mutated or kept.
random_coverage() {
  local target="$1" bin="$BIN_DIR/$1" dir log
  dir="$(mktemp -d "$OUT/random-$target-XXXXXX")"
  log="$OUT/logs/$target.random.log"
  python3 -I -c 'import os, random, sys
directory, count = sys.argv[1], int(sys.argv[2])
for index in range(count):
    with open(os.path.join(directory, f"r{index}"), "wb") as handle:
        handle.write(os.urandom(random.randint(0, 256)))' "$dir" "$RANDOM_BASELINE"
  sanitized "$bin" "$dir" -runs=0 -timeout="$TIMEOUT" -rss_limit_mb="$RSS_LIMIT_MB" >"$log" 2>&1 || true
  rm -rf "$dir"
  local edges features
  read -r edges features _ <<<"$(coverage_of "$log")"
  echo "$edges $features"
}

# One libFuzzer run of one target. Writes <out>/verdict-<target>.json.
run_target() {
  local target="$1" bin="$BIN_DIR/$1" log="$OUT/logs/$1.log" status=0 started artifacts name
  if ! name="$(sanitized "$bin" --cmux-corpus-name 2>"$log")" || [[ -z "$name" ]]; then
    echo "swift-libfuzzer.sh: $target did not name its corpus (log: $log)" >&2
    return
  fi
  mkdir -p "$CORPUS/$name" "$OUT/artifacts/$target"
  if ! sanitized "$bin" --cmux-write-seeds "$CORPUS/$name" 2>"$log"; then
    echo "swift-libfuzzer.sh: $target did not write its seeds (log: $log)" >&2
    return
  fi
  # A fresh directory per run: artifacts of earlier runs under the same --out never decide
  # this run's verdict.
  artifacts="$(mktemp -d "$OUT/artifacts/$target/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")/"
  local -a limits=(-max_total_time="$SECONDS_PER_TARGET" -rss_limit_mb="$RSS_LIMIT_MB" -timeout="$TIMEOUT")
  [[ "$SANITIZER" == address ]] && limits+=(-malloc_limit_mb="$MALLOC_LIMIT_MB")
  started="$(date +%s)"
  sanitized "$bin" "$CORPUS/$name" "${limits[@]}" -artifact_prefix="$artifacts" -print_final_stats=1 \
    "${EXTRA[@]}" >"$log" 2>&1 || status=$?

  # libFuzzer names an artifact by what it found; the first one written decides the verdict.
  local artifact verdict edges features inputs random_edges=null random_features=null
  artifact="$(find "$artifacts" -maxdepth 1 -type f \
    \( -name 'crash-*' -o -name 'oom-*' -o -name 'timeout-*' -o -name 'leak-*' \) \
    -printf '%T@ %p\n' | sort -n | head -n 1 | cut -d' ' -f2-)"
  rmdir "$artifacts" 2>/dev/null || true
  if [[ -n "$artifact" ]]; then
    verdict="$(basename "$artifact")"; verdict="${verdict%%-*}"
  elif [[ "$status" == 0 ]]; then
    verdict=clean
  else
    verdict=error
  fi
  read -r edges features inputs <<<"$(coverage_of "$log")"
  if (( RANDOM_BASELINE > 0 )); then
    read -r random_edges random_features <<<"$(random_coverage "$target")"
  fi
  python3 -I -c 'import json, sys
(target, corpus, verdict, artifact, seconds, status, log, sanitizer, malloc_limit, leaks,
 edges, features, inputs, random_edges, random_features, out) = sys.argv[1:]
row = {"target": target, "corpus": corpus, "verdict": verdict, "artifact": artifact or None,
       "seconds": int(seconds), "exit_status": int(status), "log": log, "sanitizer": sanitizer,
       "malloc_limit_mb": json.loads(malloc_limit), "leak_detection": json.loads(leaks),
       "edges": json.loads(edges), "features": json.loads(features),
       "corpus_inputs": json.loads(inputs), "random_edges": json.loads(random_edges),
       "random_features": json.loads(random_features)}
with open(out, "w") as handle:
    json.dump(row, handle)' \
    "$target" "$CORPUS/$name" "$verdict" "$artifact" "$(( $(date +%s) - started ))" "$status" "$log" \
    "$SANITIZER" "$MALLOC_LIMIT_RECORDED" "$LEAK_DETECTION" "$edges" "$features" "$inputs" "$random_edges" "$random_features" \
    "$OUT/verdict-$target.json"
  local random_note=""
  (( RANDOM_BASELINE > 0 )) && random_note="; random: edges $random_edges, features $random_features"
  echo "swift-libfuzzer.sh: $target $verdict (edges $edges, features $features$random_note)${artifact:+ ($artifact)}"
}

running=0
for target in "${SELECTED[@]}"; do
  if (( running >= PARALLEL )); then
    wait -n || true
    running=$(( running - 1 ))
  fi
  run_target "$target" &
  running=$(( running + 1 ))
done
wait || true

: >"$OUT/summary.jsonl"
result=0
for target in "${SELECTED[@]}"; do
  verdict_file="$OUT/verdict-$target.json"
  if [[ ! -f "$verdict_file" ]]; then
    echo "swift-libfuzzer.sh: $target gave no verdict" >&2
    result=75
    continue
  fi
  cat "$verdict_file" >>"$OUT/summary.jsonl"
  echo >>"$OUT/summary.jsonl"
  rm -f "$verdict_file"
done

findings="$(python3 -I -c 'import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(sum(row["verdict"] in ("crash", "oom", "timeout", "leak") for row in rows),
      sum(row["verdict"] == "error" for row in rows))' "$OUT/summary.jsonl")"
read -r finding_count error_count <<<"$findings"
echo "swift-libfuzzer.sh: $finding_count findings, $error_count runs without a verdict; summary $OUT/summary.jsonl"
if (( finding_count > 0 )); then
  exit 1
fi
if (( error_count > 0 || result != 0 )); then
  exit 75
fi
exit 0
