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
#            [-- EXTRA LIBFUZZER FLAGS]
#   --all          every target in cmux-tui/fuzz/Cargo.toml.
#   --target       the named targets only.
#   --seconds      fuzzing time per target (default 300).
#   --parallel     targets fuzzed at once (default 1). Each run is one libFuzzer process.
#   --out          results directory (default artifacts/rust-fuzz/<UTC>).
#   --corpus       corpus root, one subdirectory per target (default <out>/corpus). Seeds from
#                  cmux-tui/fuzz/seeds.py are added to it first; what the run finds stays in it.
#   --rss-limit-mb, --malloc-limit-mb, --timeout
#                  libFuzzer limits (defaults 2048, 256 and 2 seconds).
#   --sanitizer    cargo fuzz --sanitizer (default address).
#   --build-only   build the targets and stop (the acceptance check of a new target).
#   --list         print the target names and stop.
# Results: <out>/summary.jsonl (one row per target: target, verdict, artifact, seconds, log),
# <out>/logs/<target>.log, <out>/artifacts/<target>/{crash,oom,timeout,leak}-<sha1>.
# Verdicts: clean, crash, oom, timeout, leak, error (libFuzzer stopped with no artifact).
# Exit 0 when every target is clean, 1 on any finding, 2 on a usage error, 75 when the build
# failed or a run gave no verdict.
#
# The fuzz workspace pins its own nightly in cmux-tui/fuzz/rust-toolchain.toml (installed on the
# Linux VM by scripts/cmux-next/linux/setup-tools.sh). Never run this on a person's Mac: it
# compiles cmux-tui (CLAUDE.md, "Agents never compile or test on the person's Mac").
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FUZZ_DIR="$REPO/cmux-tui/fuzz"

ALL=0 TARGETS="" SECONDS_PER_TARGET=300 PARALLEL=1 OUT="" CORPUS=""
RSS_LIMIT_MB=2048 MALLOC_LIMIT_MB=256 TIMEOUT=2 SANITIZER=address BUILD_ONLY=0 LIST=0
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
    -h|--help) usage ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "rust-fuzz.sh: unknown argument '$1'" >&2; usage ;;
  esac
done

case "$SANITIZER" in
  address|leak|none) ;;
  *) echo "rust-fuzz.sh: --sanitizer must be address, leak or none" >&2; exit 2 ;;
esac

# Every [[bin]] name in the fuzz manifest, in file order.
known_targets() {
  awk '/^\[\[bin\]\]/ { in_bin = 1; next }
       /^\[/ { in_bin = 0 }
       in_bin && $1 == "name" { gsub(/"/, "", $3); print $3 }' "$FUZZ_DIR/Cargo.toml"
}

KNOWN="$(known_targets)"
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
    grep -qxF -- "$target" <<<"$KNOWN" || { echo "rust-fuzz.sh: no fuzz target '$target' (see --list)" >&2; exit 2; }
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

python3 -I "$FUZZ_DIR/seeds.py" --repo "$REPO" --out "$CORPUS" "${SELECTED[@]}"

# One libFuzzer run of one target. Writes <out>/verdict-<target>.json.
run_target() {
  local target="$1" log="$OUT/logs/$1.log" artifacts="$OUT/artifacts/$1/" status=0 started
  local -a own=() lines=()
  local asan="${ASAN_OPTIONS:-}"
  if [[ -f "$FUZZ_DIR/fuzz_targets/$target.options" ]]; then
    mapfile -t lines < <(target_options "$target")
    own=("${lines[@]:0:${#lines[@]}-1}")
    local target_asan="${lines[-1]#ASAN_OPTIONS=}"
    asan="${asan:+$asan:}$target_asan"
  fi
  mkdir -p "$artifacts" "$CORPUS/$target"
  started="$(date +%s)"
  ASAN_OPTIONS="$asan" cargo_fuzz run "$target" "$CORPUS/$target" -- \
    -max_total_time="$SECONDS_PER_TARGET" \
    -rss_limit_mb="$RSS_LIMIT_MB" \
    -malloc_limit_mb="$MALLOC_LIMIT_MB" \
    -timeout="$TIMEOUT" \
    -artifact_prefix="$artifacts" \
    -print_final_stats=1 \
    "${own[@]}" "${EXTRA[@]}" >"$log" 2>&1 || status=$?

  # libFuzzer names an artifact by what it found; the first one decides the verdict.
  local artifact verdict
  artifact="$(find "$artifacts" -maxdepth 1 -type f \
    \( -name 'crash-*' -o -name 'oom-*' -o -name 'timeout-*' -o -name 'leak-*' \) -print -quit)"
  if [[ -n "$artifact" ]]; then
    verdict="$(basename "$artifact")"; verdict="${verdict%%-*}"
  elif [[ "$status" == 0 ]]; then
    verdict=clean
  else
    verdict=error
  fi
  python3 -I -c 'import json, sys
target, verdict, artifact, seconds, status, log, out = sys.argv[1:]
row = {"target": target, "verdict": verdict, "artifact": artifact or None,
       "seconds": int(seconds), "exit_status": int(status), "log": log}
with open(out, "w") as handle:
    json.dump(row, handle)' \
    "$target" "$verdict" "$artifact" "$(( $(date +%s) - started ))" "$status" "$log" \
    "$OUT/verdict-$target.json"
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
