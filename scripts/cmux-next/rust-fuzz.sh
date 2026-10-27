#!/usr/bin/env bash
# Run the coverage-guided Rust fuzz targets of cmux-tui/fuzz (cargo-fuzz, libFuzzer with
# SanitizerCoverage and ASan) with resource limits, and classify what each run found. The
# stability lab's rust-fuzz lane (plans/cmux-next/chrome-parity/p10-stability.md, section 3.A)
# and people on a Linux Testbox or VM run it. It reports; it is not a CI gate.
#
# Chromium's model (testing/libfuzzer/README.md, ClusterFuzz): every target runs with an RSS
# limit, a malloc limit and a per-input timeout, and an out-of-memory or a timeout is a finding
# like a crash, not a flake.
#
# Usage: scripts/cmux-next/rust-fuzz.sh (--all | --target NAME[,NAME...]) [--seconds N]
#            [--parallel N] [--out DIR] [--corpus DIR] [--rss-limit-mb N] [--malloc-limit-mb N]
#            [--timeout N] [--sanitizer address|leak|none] [--build-only] [--list]
#            [--store DIR | --no-store] [--store-import TAR] [--store-export TAR]
#            [--coverage [--file-quality-issues]] [-- EXTRA LIBFUZZER FLAGS]
#        scripts/cmux-next/rust-fuzz.sh --minimize-crash TARGET FILE [--out DIR]
#        scripts/cmux-next/rust-fuzz.sh --self-test [--out DIR] [--sanitizer address|leak]
#   --all          every target in cmux-tui/fuzz/Cargo.toml except the selftest_ ones.
#   --target       the named targets only.
#   --seconds      fuzzing time per target (default 300).
#   --parallel     targets fuzzed at once (default 1). Each run is one libFuzzer process.
#   --out          results directory (default artifacts/rust-fuzz/<UTC>).
#   --corpus       corpus root, one subdirectory per target (default <out>/corpus). The stored
#                  corpus and the seeds from cmux-tui/fuzz/seeds.py are added to it first; what
#                  the run finds stays in it.
#   --store        the stored corpus (scripts/cmux-next/fuzz-corpus.py; default
#                  `fuzz-corpus.py default-store --family cmux-tui`, a persistent host cache).
#                  Each target starts from its stored inputs (the log prints the count); after
#                  the run its corpus is minimized with libFuzzer -merge=1 into
#                  <out>/merged/<target> and stored back, so the next run starts there.
#   --no-store     start from the seeds only and store nothing.
#   --store-import, --store-export
#                  add a packed store (fuzz-corpus.py export) before the run; pack the store
#                  after it. A lab step on a fleet host carries the corpus this way (its
#                  --artifact), so the corpus moves with the lane, not with the host.
#   --coverage     instead of fuzzing, measure each target's stored corpus with
#                  `cargo fuzz coverage` and llvm-cov (the weekly lane), add the covered regions
#                  to the store's history and list the targets whose coverage was flat over the
#                  last 3 measurements (fuzz-corpus.py quality). --file-quality-issues files one
#                  fuzz-quality issue per flat target.
#   --minimize-crash TARGET FILE
#                  minimize a finding (libFuzzer -minimize_crash=1) and check it in as a
#                  regression input, cmux-tui/fuzz/corpus/<target>/regress-<sha1> (at most
#                  64 KiB), which every later run replays first. Commit it with the fix.
#   --rss-limit-mb, --malloc-limit-mb, --timeout
#                  libFuzzer limits (defaults 2048, 256 and 2 seconds).
#   --sanitizer    cargo fuzz --sanitizer (default address). libFuzzer enforces the malloc
#                  limit and finds leaks only through a sanitizer runtime, so with none
#                  the run warns and its summary rows say "malloc_limit_mb": null and
#                  "leak_detection": false: a clean verdict there was not under that limit.
#   --build-only   build the targets and stop (the acceptance check of a new target).
#   --list         print the target names and stop.
#   --self-test    check the finding classifier: run the selftest_findings target on a crash, an
#                  oom, a timeout, a leak and a clean input, all with the same --out, and
#                  check each verdict and exit status. Exit 0 when all five match, 1 otherwise.
# Results: <out>/summary.jsonl (one row per target: target, verdict, artifact, seconds, log,
# sanitizer, malloc_limit_mb, leak_detection, corpus_stored), <out>/logs/<target>.log,
# <out>/artifacts/<target>/<run>/{crash,oom,timeout,leak}-<sha1>. Each run writes its own
# <run> directory, so an artifact an earlier run left under the same --out never decides a
# later verdict.
# Verdicts: clean, crash, oom, timeout, leak, error (libFuzzer stopped with no artifact).
# Exit 0 when every target is clean, 1 on any finding, 2 on a usage error, 75 when the build
# failed or a run gave no verdict.
#
# The fuzz workspace pins its own nightly in cmux-tui/fuzz/rust-toolchain.toml (installed on the
# Linux VM by scripts/cmux-next/linux/setup-tools.sh). Never run this on a person's Mac: it
# compiles cmux-tui (CLAUDE.md, "Agents never compile or test on the person's Mac").
#
# libghostty-vt (Zig) is built for fuzzing by cmux-tui/crates/ghostty-vt-sys/fuzzing/build.zig:
# ReleaseSafe with SanitizerCoverage, so libFuzzer sees the VT parser's edges (as extra
# counters: they show in ft:, not cov:) and a Zig safety check failure is a crash. Its memory
# is not ASan-instrumented: an out-of-bounds access the Zig checks miss (raw pointers, C code)
# is not caught.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FUZZ_DIR="$REPO/cmux-tui/fuzz"

ALL=0 TARGETS="" SECONDS_PER_TARGET=300 PARALLEL=1 OUT="" CORPUS=""
RSS_LIMIT_MB=2048 MALLOC_LIMIT_MB=256 TIMEOUT=2 SANITIZER=address BUILD_ONLY=0 LIST=0
SELF_TEST=0 SELF_TEST_TARGET=selftest_findings
STORE="" NO_STORE=0 STORE_IMPORT="" STORE_EXPORT="" COVERAGE=0 FILE_QUALITY_ISSUES=0
MINIMIZE_TARGET="" MINIMIZE_INPUT=""
CORPUS_TOOL="$REPO/scripts/cmux-next/fuzz-corpus.py"
EXTRA=()

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { echo "rust-fuzz.sh: $1 needs a value" >&2; exit 2; }
}

need_number() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "rust-fuzz.sh: $1 needs a positive integer, got '$2'" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --target) need_value "$@"; TARGETS="$2"; shift 2 ;;
    --seconds) need_value "$@"; need_number "$1" "$2"; SECONDS_PER_TARGET="$2"; shift 2 ;;
    --parallel) need_value "$@"; need_number "$1" "$2"; PARALLEL="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --corpus) need_value "$@"; CORPUS="$2"; shift 2 ;;
    --rss-limit-mb) need_value "$@"; need_number "$1" "$2"; RSS_LIMIT_MB="$2"; shift 2 ;;
    --malloc-limit-mb) need_value "$@"; need_number "$1" "$2"; MALLOC_LIMIT_MB="$2"; shift 2 ;;
    --timeout) need_value "$@"; need_number "$1" "$2"; TIMEOUT="$2"; shift 2 ;;
    --sanitizer) need_value "$@"; SANITIZER="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --list) LIST=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --store) need_value "$@"; STORE="$2"; shift 2 ;;
    --no-store) NO_STORE=1; shift ;;
    --store-import) need_value "$@"; STORE_IMPORT="$2"; shift 2 ;;
    --store-export) need_value "$@"; STORE_EXPORT="$2"; shift 2 ;;
    --coverage) COVERAGE=1; shift ;;
    --file-quality-issues) FILE_QUALITY_ISSUES=1; shift ;;
    --minimize-crash)
      [[ $# -ge 3 && -n "$2" && -n "$3" ]] || { echo "rust-fuzz.sh: --minimize-crash needs TARGET FILE" >&2; exit 2; }
      MINIMIZE_TARGET="$2"; MINIMIZE_INPUT="$3"; shift 3 ;;
    -h|--help) usage ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "rust-fuzz.sh: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$SANITIZER" in
  address|leak|none) ;;
  *) echo "rust-fuzz.sh: --sanitizer must be address, leak or none" >&2; exit 2 ;;
esac
if [[ "$NO_STORE" == 1 && -n "$STORE$STORE_IMPORT$STORE_EXPORT" ]]; then
  echo "rust-fuzz.sh: --no-store excludes --store, --store-import and --store-export" >&2; exit 2
fi
if [[ "$NO_STORE" == 1 && "$COVERAGE" == 1 ]]; then
  echo "rust-fuzz.sh: --coverage measures the stored corpus; it cannot run with --no-store" >&2; exit 2
fi
if [[ "$FILE_QUALITY_ISSUES" == 1 && "$COVERAGE" == 0 ]]; then
  echo "rust-fuzz.sh: --file-quality-issues goes with --coverage" >&2; exit 2
fi

# Every [[bin]] name in the fuzz manifest, in file order.
manifest_targets() {
  awk '/^\[\[bin\]\]/ { in_bin = 1; next }
       /^\[/ { in_bin = 0 }
       in_bin && $1 == "name" { gsub(/"/, "", $3); print $3 }' "$FUZZ_DIR/Cargo.toml"
}

# --self-test runs this script once per case, so each case goes through the same option
# parsing, run, classification and exit status as a real run.
self_test() {
  if [[ "$SANITIZER" == none ]]; then
    echo "rust-fuzz.sh: --self-test needs a sanitizer runtime for its oom case; give --sanitizer address or leak" >&2
    exit 2
  fi
  local out="${OUT:-$REPO/artifacts/rust-fuzz/self-test-$(date -u +%Y%m%dT%H%M%SZ)}"
  local failed=0 case input want_verdict want_status status verdict
  mkdir -p "$out"
  # The clean case runs last, so the finding artifacts of the cases before it
  # are under the same --out and must not decide its verdict.
  for case in crash:c:1 oom:o:1 timeout:t:1 leak:l:1 clean:x:0; do
    IFS=: read -r want_verdict input want_status <<<"$case"
    mkdir -p "$out/inputs/$want_verdict/$SELF_TEST_TARGET"
    printf '%s' "$input" >"$out/inputs/$want_verdict/$SELF_TEST_TARGET/input"
    status=0
    # --timeout 600: only the target's .options (timeout = 1) makes the timeout case finish.
    # -runs=0: execute the corpus input once and stop, no mutations.
    "${BASH_SOURCE[0]}" --target "$SELF_TEST_TARGET" --out "$out" --corpus "$out/inputs/$want_verdict" \
      --sanitizer "$SANITIZER" --seconds 60 --timeout 600 --no-store -- -runs=0 \
      >"$out/self-test-$want_verdict.log" 2>&1 || status=$?
    verdict="$(python3 -I -c 'import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(rows[-1]["verdict"] if rows else "none")' "$out/summary.jsonl" 2>/dev/null || echo none)"
    if [[ "$verdict" == "$want_verdict" && "$status" == "$want_status" ]]; then
      echo "rust-fuzz.sh: self-test $want_verdict ok (verdict $verdict, exit $status)"
    else
      echo "rust-fuzz.sh: self-test $want_verdict FAILED: verdict $verdict exit $status, want verdict $want_verdict exit $want_status (log $out/self-test-$want_verdict.log)" >&2
      failed=1
    fi
  done
  exit "$failed"
}

ALL_BINS="$(manifest_targets)"
# selftest_ targets test this script, not cmux code: --all and --list leave them out.
KNOWN="$(grep -v '^selftest_' <<<"$ALL_BINS" || true)"
if [[ "$SELF_TEST" == 1 ]]; then
  self_test
fi
if [[ "$LIST" == 1 ]]; then
  printf '%s\n' "$KNOWN"
  exit 0
fi

if [[ -n "$MINIMIZE_TARGET" ]]; then
  [[ "$ALL" == 0 && -z "$TARGETS" ]] || { echo "rust-fuzz.sh: --minimize-crash takes its own TARGET" >&2; exit 2; }
  [[ -f "$MINIMIZE_INPUT" ]] || { echo "rust-fuzz.sh: --minimize-crash: no file '$MINIMIZE_INPUT'" >&2; exit 2; }
  TARGETS="$MINIMIZE_TARGET"
fi
if [[ "$ALL" == 1 && -n "$TARGETS" ]]; then
  echo "rust-fuzz.sh: give --all or --target, not both" >&2; exit 2
fi
if [[ "$ALL" == 1 ]]; then
  mapfile -t SELECTED <<<"$KNOWN"
elif [[ -n "$TARGETS" ]]; then
  IFS=, read -r -a SELECTED <<<"$TARGETS"
  for target in "${SELECTED[@]}"; do
    grep -qxF -- "$target" <<<"$ALL_BINS" || { echo "rust-fuzz.sh: no fuzz target '$target' (see --list)" >&2; exit 2; }
  done
else
  echo "rust-fuzz.sh: give --all or --target NAME" >&2; usage
fi

CHANNEL="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$FUZZ_DIR/rust-toolchain.toml")"
VM_NIGHTLY="$(sed -n '/^\[nightly\]/,/^\[/s/^channel *= *"\(.*\)"/\1/p' "$REPO/scripts/cmux-next/linux/tool-versions.toml")"
if [[ "$CHANNEL" != "$VM_NIGHTLY" ]]; then
  echo "rust-fuzz.sh: cmux-tui/fuzz/rust-toolchain.toml pins $CHANNEL but scripts/cmux-next/linux/tool-versions.toml installs $VM_NIGHTLY; change both" >&2
  exit 75
fi
if [[ "$SANITIZER" == none ]]; then
  echo "rust-fuzz.sh: warning: --sanitizer none: libFuzzer cannot enforce -malloc_limit_mb=$MALLOC_LIMIT_MB or find leaks without a sanitizer runtime; the summary records malloc_limit_mb null" >&2
  MALLOC_LIMIT_RECORDED=null LEAK_DETECTION=false
else
  MALLOC_LIMIT_RECORDED="$MALLOC_LIMIT_MB" LEAK_DETECTION=true
fi
if ! rustup run "$CHANNEL" rustc --version >/dev/null 2>&1; then
  echo "rust-fuzz.sh: toolchain $CHANNEL is not installed (scripts/cmux-next/linux/setup-tools.sh installs it)" >&2
  exit 75
fi
command -v cargo-fuzz >/dev/null || {
  echo "rust-fuzz.sh: cargo-fuzz is not installed (scripts/cmux-next/linux/setup-tools.sh installs it)" >&2
  exit 75
}

OUT="${OUT:-$REPO/artifacts/rust-fuzz/$(date -u +%Y%m%dT%H%M%SZ)}"
CORPUS="${CORPUS:-$OUT/corpus}"
mkdir -p "$OUT/logs" "$OUT/artifacts" "$CORPUS"
OUT="$(cd "$OUT" && pwd)"
CORPUS="$(cd "$CORPUS" && pwd)"
RUN_ID="${CMUX_FUZZ_RUN_ID:-$(basename "$OUT")}"
if [[ "$NO_STORE" == 0 ]]; then
  STORE="${STORE:-$(python3 -I "$CORPUS_TOOL" default-store --family cmux-tui)}"
  mkdir -p "$STORE"
  STORE="$(cd "$STORE" && pwd)"
  if [[ -n "$STORE_IMPORT" ]]; then
    python3 -I "$CORPUS_TOOL" import --store "$STORE" --in "$STORE_IMPORT" || exit 75
  fi
fi

# A target's own settings, Chromium's <target>.options file (testing/libfuzzer/fuzzer_test.gni,
# libfuzzer_options and asan_options): fuzz_targets/<target>.options, INI with a [libfuzzer]
# section (each key becomes -key=value after the defaults, so it overrides them) and an [asan]
# section (appended to ASAN_OPTIONS). Prints the libFuzzer flags, one per line, then a line
# "ASAN_OPTIONS=..." last.
target_options() {
  python3 -I -c 'import configparser, sys
parser = configparser.ConfigParser(interpolation=None)
parser.optionxform = str
parser.read(sys.argv[1])
for key, value in parser.items("libfuzzer") if parser.has_section("libfuzzer") else []:
    print(f"-{key}={value}")
asan = parser.items("asan") if parser.has_section("asan") else []
print("ASAN_OPTIONS=" + ":".join(f"{key}={value}" for key, value in asan))' \
    "$FUZZ_DIR/fuzz_targets/$1.options"
}

# cargo fuzz runs from the fuzz directory so rustup picks its pinned nightly.
cargo_fuzz() {
  (cd "$FUZZ_DIR" && cargo fuzz "$1" --fuzz-dir . --sanitizer "$SANITIZER" "${@:2}")
}

# The host llvm-cov of the pinned nightly (its llvm-tools component).
llvm_cov() {
  local sysroot host
  sysroot="$(rustup run "$CHANNEL" rustc --print sysroot)"
  host="$(rustup run "$CHANNEL" rustc -vV | sed -n 's/^host: //p')"
  "$sysroot/lib/rustlib/$host/bin/llvm-cov" "$@"
}

export_store() {
  if [[ -n "$STORE_EXPORT" ]]; then
    python3 -I "$CORPUS_TOOL" export --store "$STORE" --out "$STORE_EXPORT" || exit 75
  fi
}

# The weekly coverage lane: each target's stored corpus (plus seeds) through `cargo fuzz
# coverage`, its covered regions into the store's history, then the flat-coverage report.
coverage_run() {
  local target host target_dir profile binary status=0 quality=0
  host="$(rustup run "$CHANNEL" rustc -vV | sed -n 's/^host: //p')"
  # Its own target directory: cargo fuzz coverage builds with -Cinstrument-coverage, which
  # would otherwise rebuild the fuzzing binaries next to it.
  target_dir="${CARGO_TARGET_DIR:-$FUZZ_DIR/target}/coverage"
  mkdir -p "$OUT/coverage"
  python3 -I "$CORPUS_TOOL" pull --store "$STORE" --into "$CORPUS" "${SELECTED[@]}"
  python3 -I "$FUZZ_DIR/seeds.py" --repo "$REPO" --out "$CORPUS" "${SELECTED[@]}"
  for target in "${SELECTED[@]}"; do
    if ! cargo_fuzz coverage "$target" --target-dir "$target_dir" "$CORPUS/$target" \
        >"$OUT/logs/coverage-$target.log" 2>&1; then
      echo "rust-fuzz.sh: cargo fuzz coverage $target failed (log: $OUT/logs/coverage-$target.log)" >&2
      status=75
      continue
    fi
    profile="$FUZZ_DIR/coverage/$target/coverage.profdata"
    binary="$target_dir/$host/release/$target"
    if ! llvm_cov export -summary-only -instr-profile="$profile" "$binary" >"$OUT/coverage/$target.json" \
        2>>"$OUT/logs/coverage-$target.log"; then
      echo "rust-fuzz.sh: llvm-cov export $target failed (log: $OUT/logs/coverage-$target.log)" >&2
      status=75
      continue
    fi
    python3 -I "$CORPUS_TOOL" record-coverage --store "$STORE" --target "$target" --run "$RUN_ID" \
      --llvm-cov-json "$OUT/coverage/$target.json" || status=75
  done
  local -a issues=()
  [[ "$FILE_QUALITY_ISSUES" == 0 ]] || issues=(--file-issues)
  # quality exits 1 when a target is flat: a fuzzer-quality finding it reports, not a failed run.
  python3 -I "$CORPUS_TOOL" quality --store "$STORE" "${issues[@]}" || quality=$?
  (( quality <= 1 )) || status=75
  export_store
  exit "$status"
}

if [[ "$COVERAGE" == 1 ]]; then
  coverage_run
fi

echo "rust-fuzz.sh: building ${#SELECTED[@]} targets with $CHANNEL (sanitizer $SANITIZER)"
for target in "${SELECTED[@]}"; do
  if ! cargo_fuzz build "$target" >"$OUT/logs/build-$target.log" 2>&1; then
    tail -n 40 "$OUT/logs/build-$target.log" >&2
    echo "rust-fuzz.sh: $target did not build (log: $OUT/logs/build-$target.log)" >&2
    exit 75
  fi
done
if [[ "$BUILD_ONLY" == 1 ]]; then
  echo "rust-fuzz.sh: every selected target builds"
  exit 0
fi

# A finding minimized to a checked-in regression input: libFuzzer -minimize_crash=1 keeps
# shrinking while the input still fails, then fuzz-corpus.py regress refuses one over 64 KiB.
if [[ -n "$MINIMIZE_TARGET" ]]; then
  minimized="$OUT/minimized/$MINIMIZE_TARGET-$(sha1sum "$MINIMIZE_INPUT" | cut -c1-16)"
  mkdir -p "$OUT/minimized"
  cargo_fuzz run "$MINIMIZE_TARGET" "$MINIMIZE_INPUT" -- \
    -minimize_crash=1 -max_total_time="$SECONDS_PER_TARGET" \
    -rss_limit_mb="$RSS_LIMIT_MB" -malloc_limit_mb="$MALLOC_LIMIT_MB" -timeout="$TIMEOUT" \
    -exact_artifact_path="$minimized" >"$OUT/logs/minimize-$MINIMIZE_TARGET.log" 2>&1 || true
  if [[ ! -s "$minimized" ]]; then
    echo "rust-fuzz.sh: libFuzzer kept no minimized input; does $MINIMIZE_INPUT still fail? (log: $OUT/logs/minimize-$MINIMIZE_TARGET.log)" >&2
    exit 75
  fi
  python3 -I "$CORPUS_TOOL" regress --target "$MINIMIZE_TARGET" --input "$minimized" || exit 75
  exit 0
fi

PULL_RECEIPT="$OUT/corpus-pull.json"
if [[ "$NO_STORE" == 0 ]]; then
  python3 -I "$CORPUS_TOOL" pull --store "$STORE" --into "$CORPUS" --receipt "$PULL_RECEIPT" "${SELECTED[@]}"
fi
python3 -I "$FUZZ_DIR/seeds.py" --repo "$REPO" --out "$CORPUS" "${SELECTED[@]}"

# The binary `cargo fuzz build` made for a target. The merge runs it directly: a second
# `cargo fuzz run` per target only waits on the build directory lock of the other targets.
HOST_TRIPLE="$(rustup run "$CHANNEL" rustc -vV | sed -n 's/^host: //p')"
fuzz_binary() {
  printf '%s/%s/release/%s\n' "${CARGO_TARGET_DIR:-$FUZZ_DIR/target}" "$HOST_TRIPLE" "$1"
}

# The run's corpus minimized (libFuzzer -merge=1: the smallest set with every feature the
# corpus reaches, ClusterFuzz's corpus pruning) and stored back. A merge that fails stores
# nothing, so the stored corpus stays as it was. Takes the target and its own libFuzzer flags;
# ASAN_OPTIONS is the run's. Prints true when the corpus was stored, else false.
store_corpus() {
  local target="$1" merged="$OUT/merged/$1" log="$OUT/logs/merge-$1.log"
  shift
  rm -rf "$merged"
  mkdir -p "$merged"
  # cargo fuzz run appends detect_odr_violation=0 to ASAN_OPTIONS; the direct call does the same.
  if ! ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_odr_violation=0" "$(fuzz_binary "$target")" \
      -merge=1 -rss_limit_mb="$RSS_LIMIT_MB" -malloc_limit_mb="$MALLOC_LIMIT_MB" -timeout="$TIMEOUT" \
      -artifact_prefix="$OUT/merged/.$target-" "$@" "$merged" "$CORPUS/$target" >"$log" 2>&1; then
    echo "rust-fuzz.sh: $target corpus merge failed; the stored corpus is unchanged (log: $log)" >&2
    echo false
    return
  fi
  if python3 -I "$CORPUS_TOOL" push --store "$STORE" --target "$target" --from "$merged" \
      --receipt "$PULL_RECEIPT" --run "$RUN_ID" --fuzz-log "$OUT/logs/$target.log" >&2; then
    echo true
  else
    echo false
  fi
}

# One libFuzzer run of one target. Writes <out>/verdict-<target>.json.
run_target() {
  local target="$1" log="$OUT/logs/$1.log" status=0 started artifacts
  # A fresh directory per run: artifacts of earlier runs under the same --out stay where they
  # are and never decide this run's verdict.
  mkdir -p "$OUT/artifacts/$target"
  artifacts="$(mktemp -d "$OUT/artifacts/$target/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")/"
  local -a own=() lines=()
  local asan="${ASAN_OPTIONS:-}"
  if [[ -f "$FUZZ_DIR/fuzz_targets/$target.options" ]]; then
    mapfile -t lines < <(target_options "$target")
    own=("${lines[@]:0:${#lines[@]}-1}")
    local target_asan="${lines[-1]#ASAN_OPTIONS=}"
    asan="${asan:+$asan:}$target_asan"
  fi
  mkdir -p "$CORPUS/$target"
  started="$(date +%s)"
  ASAN_OPTIONS="$asan" cargo_fuzz run "$target" "$CORPUS/$target" -- \
    -max_total_time="$SECONDS_PER_TARGET" \
    -rss_limit_mb="$RSS_LIMIT_MB" \
    -malloc_limit_mb="$MALLOC_LIMIT_MB" \
    -timeout="$TIMEOUT" \
    -artifact_prefix="$artifacts" \
    -print_final_stats=1 \
    "${own[@]}" "${EXTRA[@]}" >"$log" 2>&1 || status=$?

  # libFuzzer names an artifact by what it found; the first one written decides the verdict.
  local artifact verdict
  artifact="$(find "$artifacts" -maxdepth 1 -type f \
    \( -name 'crash-*' -o -name 'oom-*' -o -name 'timeout-*' -o -name 'leak-*' \) \
    -printf '%T@ %p\n' | sort -n | head -n 1 | cut -d' ' -f2-)"
  # A run that wrote nothing leaves no empty directory behind.
  rmdir "$artifacts" 2>/dev/null || true
  if [[ -n "$artifact" ]]; then
    verdict="$(basename "$artifact")"; verdict="${verdict%%-*}"
  elif [[ "$status" == 0 ]]; then
    verdict=clean
  else
    verdict=error
  fi
  # A run that stopped without a verdict proved nothing about its corpus: keep the stored one.
  local stored=false
  if [[ "$NO_STORE" == 0 && "$verdict" != error ]]; then
    stored="$(ASAN_OPTIONS="$asan" store_corpus "$target" "${own[@]}")"
  fi
  python3 -I -c 'import json, sys
target, verdict, artifact, seconds, status, log, sanitizer, malloc_limit, leaks, stored, out = sys.argv[1:]
row = {"target": target, "verdict": verdict, "artifact": artifact or None,
       "seconds": int(seconds), "exit_status": int(status), "log": log,
       "sanitizer": sanitizer, "malloc_limit_mb": json.loads(malloc_limit),
       "leak_detection": json.loads(leaks), "corpus_stored": json.loads(stored)}
with open(out, "w") as handle:
    json.dump(row, handle)' \
    "$target" "$verdict" "$artifact" "$(( $(date +%s) - started ))" "$status" "$log" \
    "$SANITIZER" "$MALLOC_LIMIT_RECORDED" "$LEAK_DETECTION" "$stored" "$OUT/verdict-$target.json"
  echo "rust-fuzz.sh: $target $verdict${artifact:+ ($artifact)}"
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
    echo "rust-fuzz.sh: $target gave no verdict" >&2
    result=75
    continue
  fi
  cat "$verdict_file" >>"$OUT/summary.jsonl"
  echo >>"$OUT/summary.jsonl"
  rm -f "$verdict_file"
done

# Findings first: any crash, oom, timeout or leak is exit 1; an error without one is 75.
findings="$(python3 -I -c 'import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(sum(row["verdict"] in ("crash", "oom", "timeout", "leak") for row in rows),
      sum(row["verdict"] == "error" for row in rows))' "$OUT/summary.jsonl")"
read -r finding_count error_count <<<"$findings"
[[ "$NO_STORE" == 1 ]] || export_store
echo "rust-fuzz.sh: $finding_count findings, $error_count runs without a verdict; summary $OUT/summary.jsonl"
if (( finding_count > 0 )); then
  exit 1
fi
if (( error_count > 0 || result != 0 )); then
  exit 75
fi
exit 0
