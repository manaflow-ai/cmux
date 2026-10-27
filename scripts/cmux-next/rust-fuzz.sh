#!/usr/bin/env bash
# Run the coverage-guided Rust fuzz targets (cargo-fuzz, libFuzzer with SanitizerCoverage
# and ASan) with resource limits, and classify what each run found. The targets live in one
# fuzz workspace per Cargo workspace (FUZZ_DIRS below: cmux-tui/fuzz, and the fuzz dirs of
# the separate workspaces cmux-next-ios/rust and Native/OptChat, each with its own lock and
# nightly pin); target names are unique across them. The
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
#            [-- EXTRA LIBFUZZER FLAGS]
#        scripts/cmux-next/rust-fuzz.sh --self-test [--out DIR] [--sanitizer address|leak]
#   --all          every target of every fuzz workspace except the selftest_ ones.
#   --target       the named targets only.
#   --seconds      fuzzing time per target (default 300).
#   --parallel     targets fuzzed at once (default 1). Each run is one libFuzzer process.
#   --out          results directory (default artifacts/rust-fuzz/<UTC>).
#   --corpus       corpus root, one subdirectory per target (default <out>/corpus). Seeds from
#                  cmux-tui/fuzz/seeds.py and each workspace's corpus/<target>/ are added to it
#                  first; what the run finds stays in it.
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
# sanitizer, malloc_limit_mb, leak_detection), <out>/logs/<target>.log,
# <out>/artifacts/<target>/<run>/{crash,oom,timeout,leak}-<sha1>. Each run writes its own
# <run> directory, so an artifact an earlier run left under the same --out never decides a
# later verdict.
# Verdicts: clean, crash, oom, timeout, leak, error (libFuzzer stopped with no artifact).
# Exit 0 when every target is clean, 1 on any finding, 2 on a usage error, 75 when the build
# failed or a run gave no verdict.
#
# Each fuzz workspace pins its own nightly in its rust-toolchain.toml, all the same one
# (installed on the Linux VM by scripts/cmux-next/linux/setup-tools.sh). Never run this on a
# person's Mac: it compiles cmux-tui (CLAUDE.md, "Agents never compile or test on the person's
# Mac").
#
# libghostty-vt (Zig) is built for fuzzing by cmux-tui/crates/ghostty-vt-sys/fuzzing/build.zig:
# ReleaseSafe with SanitizerCoverage, so libFuzzer sees the VT parser's edges (as extra
# counters: they show in ft:, not cov:) and a Zig safety check failure is a crash. Its memory
# is not ASan-instrumented: an out-of-bounds access the Zig checks miss (raw pointers, C code)
# is not caught.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FUZZ_DIR="$REPO/cmux-tui/fuzz"
# Every fuzz workspace, the cmux-tui one first. A separate Cargo workspace gets its own fuzz
# dir and lock (p10-stability.md task 181), never a path into another workspace's lock.
FUZZ_DIRS=("$FUZZ_DIR" "$REPO/cmux-next-ios/rust/fuzz" "$REPO/Native/OptChat/fuzz")

ALL=0 TARGETS="" SECONDS_PER_TARGET=300 PARALLEL=1 OUT="" CORPUS=""
RSS_LIMIT_MB=2048 MALLOC_LIMIT_MB=256 TIMEOUT=2 SANITIZER=address BUILD_ONLY=0 LIST=0
SELF_TEST=0 SELF_TEST_TARGET=selftest_findings
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
    -h|--help) usage ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "rust-fuzz.sh: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$SANITIZER" in
  address|leak|none) ;;
  *) echo "rust-fuzz.sh: --sanitizer must be address, leak or none" >&2; exit 2 ;;
esac

# Every [[bin]] name of one fuzz manifest, in file order.
manifest_targets_of() {
  awk '/^\[\[bin\]\]/ { in_bin = 1; next }
       /^\[/ { in_bin = 0 }
       in_bin && $1 == "name" { gsub(/"/, "", $3); print $3 }' "$1/Cargo.toml"
}

# Every target of every fuzz workspace, workspace by workspace.
manifest_targets() {
  local dir
  for dir in "${FUZZ_DIRS[@]}"; do
    if [[ -f "$dir/Cargo.toml" ]]; then
      manifest_targets_of "$dir"
    fi
  done
}

# The fuzz workspace that holds TARGET.
dir_of() {
  local dir
  for dir in "${FUZZ_DIRS[@]}"; do
    if [[ -f "$dir/Cargo.toml" ]] && manifest_targets_of "$dir" | grep -qxF -- "$1"; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
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
      --sanitizer "$SANITIZER" --seconds 60 --timeout 600 -- -runs=0 \
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
DUPLICATES="$(sort <<<"$ALL_BINS" | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
  echo "rust-fuzz.sh: fuzz targets named in two workspaces: $DUPLICATES" >&2
  exit 2
fi
# selftest_ targets test this script, not cmux code: --all and --list leave them out.
KNOWN="$(grep -v '^selftest_' <<<"$ALL_BINS" || true)"
if [[ "$SELF_TEST" == 1 ]]; then
  self_test
fi
if [[ "$LIST" == 1 ]]; then
  printf '%s\n' "$KNOWN"
  exit 0
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

VM_NIGHTLY="$(sed -n '/^\[nightly\]/,/^\[/s/^channel *= *"\(.*\)"/\1/p' "$REPO/scripts/cmux-next/linux/tool-versions.toml")"
CHANNEL="$VM_NIGHTLY"
for dir in "${FUZZ_DIRS[@]}"; do
  [[ -f "$dir/Cargo.toml" ]] || continue
  pinned="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$dir/rust-toolchain.toml")"
  if [[ "$pinned" != "$VM_NIGHTLY" ]]; then
    echo "rust-fuzz.sh: ${dir#"$REPO"/}/rust-toolchain.toml pins $pinned but scripts/cmux-next/linux/tool-versions.toml installs $VM_NIGHTLY; change both" >&2
    exit 75
  fi
done
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

# A target's own settings, Chromium's <target>.options file (testing/libfuzzer/fuzzer_test.gni,
# libfuzzer_options and asan_options): fuzz_targets/<target>.options, INI with a [libfuzzer]
# section (each key becomes -key=value after the defaults, so it overrides them) and an [asan]
# section (appended to ASAN_OPTIONS). Prints the libFuzzer flags, one per line, then a line
# "ASAN_OPTIONS=..." last.
target_options() {
  local dir
  dir="$(dir_of "$1")"
  python3 -I -c 'import configparser, sys
parser = configparser.ConfigParser(interpolation=None)
parser.optionxform = str
parser.read(sys.argv[1])
for key, value in parser.items("libfuzzer") if parser.has_section("libfuzzer") else []:
    print(f"-{key}={value}")
asan = parser.items("asan") if parser.has_section("asan") else []
print("ASAN_OPTIONS=" + ":".join(f"{key}={value}" for key, value in asan))' \
    "$dir/fuzz_targets/$1.options"
}

# cargo fuzz COMMAND TARGET ARGS... runs from the target's fuzz directory, so rustup picks
# that workspace's pinned nightly and cargo its own lock.
cargo_fuzz() {
  local dir
  dir="$(dir_of "$2")"
  (cd "$dir" && cargo fuzz "$1" --fuzz-dir . --sanitizer "$SANITIZER" "${@:2}")
}

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

corpus_dirs=()
for dir in "${FUZZ_DIRS[@]}"; do
  corpus_dirs+=(--corpus-dir "$dir/corpus")
done
python3 -I "$FUZZ_DIR/seeds.py" --repo "$REPO" --out "$CORPUS" "${corpus_dirs[@]}" "${SELECTED[@]}"

# One libFuzzer run of one target. Writes <out>/verdict-<target>.json.
run_target() {
  local target="$1" log="$OUT/logs/$1.log" status=0 started artifacts
  # A fresh directory per run: artifacts of earlier runs under the same --out stay where they
  # are and never decide this run's verdict.
  mkdir -p "$OUT/artifacts/$target"
  artifacts="$(mktemp -d "$OUT/artifacts/$target/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")/"
  local -a own=() lines=()
  local asan="${ASAN_OPTIONS:-}"
  if [[ -f "$(dir_of "$target")/fuzz_targets/$target.options" ]]; then
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
  python3 -I -c 'import json, sys
target, verdict, artifact, seconds, status, log, sanitizer, malloc_limit, leaks, out = sys.argv[1:]
row = {"target": target, "verdict": verdict, "artifact": artifact or None,
       "seconds": int(seconds), "exit_status": int(status), "log": log,
       "sanitizer": sanitizer, "malloc_limit_mb": json.loads(malloc_limit),
       "leak_detection": json.loads(leaks)}
with open(out, "w") as handle:
    json.dump(row, handle)' \
    "$target" "$verdict" "$artifact" "$(( $(date +%s) - started ))" "$status" "$log" \
    "$SANITIZER" "$MALLOC_LIMIT_RECORDED" "$LEAK_DETECTION" "$OUT/verdict-$target.json"
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
echo "rust-fuzz.sh: $finding_count findings, $error_count runs without a verdict; summary $OUT/summary.jsonl"
if (( finding_count > 0 )); then
  exit 1
fi
if (( error_count > 0 || result != 0 )); then
  exit 75
fi
exit 0
