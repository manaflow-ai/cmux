#!/usr/bin/env bash
# The published benchmarks (RFD 0167 row 18): resume, move, fork, build and the long session under
# load, on a fleet Linux host. cmuxterm-hq docs/benchmarks/README.md publishes what this prints.
#   cmux-ci test --setup rust -- 'scripts/measure/published-benches-linux.sh [parts=resume,fork,move,build,soak] [samples=20] [soak_secs=120] [moves=5]'
# soak_secs=28800 is the 8 h run: start it on a fleet runner in the background, never a person's machine.
# Prints PUBLISHED-BENCH <json> lines (schema cmux.published-bench.v1), one per part, then all of them
# as one JSON object ({"rows": [...]}) on the last line.
set -euo pipefail
parts=resume,fork,move,build,soak
samples=20
soak_secs=120
moves=5
for arg in "$@"; do
  case "$arg" in
    parts=*) parts="${arg#parts=}" ;;
    samples=*) samples="${arg#samples=}" ;;
    soak_secs=*) soak_secs="${arg#soak_secs=}" ;;
    moves=*) moves="${arg#moves=}" ;;
    *) echo "published-benches-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
out="$(mktemp -d)"
: >"$out/rows.log"
trap 'rm -rf "$out"' EXIT
has() { [[ ",$parts," == *",$1,"* ]]; }
cd "$root/cmux-tui"

if has build; then
  # Cold: a fresh target dir, the registry already fetched (what a fleet runner's first build of a
  # head pays). Warm: one source file touched, the incremental rebuild an edit pays.
  cargo fetch --locked >/dev/null 2>&1 || true
  cold="$out/cold-target"
  start=$(date +%s.%N)
  CARGO_TARGET_DIR="$cold" cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 2
  mid=$(date +%s.%N)
  touch crates/acpmux/src/main.rs
  CARGO_TARGET_DIR="$cold" cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 2
  end=$(date +%s.%N)
  rm -rf "$cold"
  python3 - "$start" "$mid" "$end" <<'PY'
import json, os, socket, sys
start, mid, end = map(float, sys.argv[1:])
print("PUBLISHED-BENCH " + json.dumps({
    "schema": "cmux.published-bench.v1", "bench": "build",
    "what": "cargo build --locked --release -p acpmux --bin acpmux: cold (fresh target dir, registry fetched), then warm after touching src/main.rs",
    "cold_s": round(mid - start, 1), "warm_s": round(end - mid, 1),
    "host": {"name": socket.gethostname(), "cpus": os.cpu_count()}}))
PY
fi | tee -a "$out/rows.log"

if has resume || has fork || has soak; then
  tests=()
  has resume && tests+=(resume)
  has fork && tests+=(fork)
  has soak && tests+=(soak)
  PUBLISHED_BENCH_SAMPLES="$samples" PUBLISHED_BENCH_SOAK_SECS="$soak_secs" \
    cargo test --locked -p acpmux --release --test published_bench -- --ignored --nocapture \
    --test-threads 1 --exact "${tests[@]}" 2>&1 | tee "$out/bench.log" | grep -E '^(PUBLISHED-BENCH|test result)' | tee -a "$out/rows.log" || true
fi

if has move; then
  # Two real daemons on one host: `acpmux session move` of a chat with history, an image, picks, a
  # draft and a composer; the move_matrix test times the CLI call. Its three cells, $moves times.
  : >"$out/move.log"
  for _ in $(seq "$moves"); do
    cargo test --locked -p acpmux --release --test transfer_cli move_matrix -- --nocapture 2>&1 \
      | grep -E '^MATRIX .* moved ' >>"$out/move.log" || true
  done
  python3 - "$out/move.log" <<'PY'
import json, os, re, socket, sys
def secs(text):
    m = re.match(r"([0-9.]+)(ns|µs|us|ms|s)$", text)
    return float(m.group(1)) * {"ns": 1e-9, "µs": 1e-6, "us": 1e-6, "ms": 1e-3, "s": 1}[m.group(2)]
samples, red = [], 0
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.split()
    if len(parts) > 4 and parts[3] == "green:":
        samples.append(round(secs(parts[4]) * 1000, 1))
    else:
        red += 1
samples.sort()
at = lambda p: samples[round((len(samples) - 1) * p)] if samples else None
print("PUBLISHED-BENCH " + json.dumps({
    "schema": "cmux.published-bench.v1", "bench": "move",
    "what": "acpmux session move between two daemons on one host (move_matrix: claude, codex, hibernated claude)",
    "move_ms": {"n": len(samples), "p50": at(0.5), "p95": at(0.95), "max": samples[-1] if samples else None},
    "red": red, "host": {"name": socket.gethostname(), "cpus": os.cpu_count()}}))
PY
fi | tee -a "$out/rows.log"

grep -h '^PUBLISHED-BENCH ' "$out/rows.log" | python3 -c '
import json, sys
print(json.dumps({"rows": [json.loads(l.split(" ", 1)[1]) for l in sys.stdin]}))'
