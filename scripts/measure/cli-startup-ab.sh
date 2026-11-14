#!/usr/bin/env bash
# CMUX-570: compare the shipped CLI's process startup and command latency.
#
# Fleet only. Each timed sample is a new process on one host. "cold_process"
# means the first invocation of that binary in an interleaved round; "hot"
# means the same command after a warm-up invocation, with the filesystem cache
# left untouched for both profiles. This keeps the comparison reproducible
# without requiring privileged page-cache eviction.
#
# cmux-ci run --class exclusive --measurement --label measure \
#   --script scripts/measure/cli-startup-ab.sh --ref SHA \
#   --artifact artifacts/cli-startup-ab.json
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cli-startup-ab.sh 'cargo build' 'CMUX-570 CLI startup comparison'
out="${FAST_CHECKS_OUT:-$root/artifacts/cli-startup-ab}"
mkdir -p "$out"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/cmux-tui/target/cli-startup-ab}"
cd "$root/cmux-tui"

for level in s z; do
  cargo build --locked --release -p cmux-tui --bin cmux-tui \
    --config "profile.release.package.cmux-tui.opt-level=\"$level\"" \
    >"$out/build-$level.log" 2>&1
  mkdir -p "$out/$level"
  cp "$CARGO_TARGET_DIR/release/cmux-tui" "$out/$level/cmux"
  case "$(uname -s)" in
    Darwin) strip -x "$out/$level/cmux" ;;
    Linux) strip --strip-unneeded "$out/$level/cmux" ;;
    *) echo 'cli-startup-ab: use a Linux or macOS fleet worker' >&2; exit 2 ;;
  esac
done

python3 - "$out" <<'PY'
import hashlib
import json
import math
import pathlib
import platform
import statistics
import subprocess
import sys
import time

out = pathlib.Path(sys.argv[1])
levels = ("s", "z")
samples = {level: {"cold_process_version_ms": [], "hot_help_ms": []} for level in levels}

def run(binary, args):
    started = time.perf_counter_ns()
    result = subprocess.run([str(binary), *args], capture_output=True, check=True, timeout=30)
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    return elapsed, result

# Interleave profiles and alternate which one gets the first process in each
# round, so one profile does not always inherit the host's first sample.
for round_number in range(12):
    order = levels if round_number % 2 == 0 else tuple(reversed(levels))
    for level in order:
        binary = out / level / "cmux"
        elapsed, result = run(binary, ["--version"])
        if not result.stdout.strip():
            raise SystemExit(f"{level}: --version returned no output")
        samples[level]["cold_process_version_ms"].append(elapsed)
        run(binary, ["--help"])
    for level in order:
        binary = out / level / "cmux"
        run(binary, ["--help"])  # warm-up, excluded from the sample below
        elapsed, result = run(binary, ["--help"])
        if not result.stdout.strip():
            raise SystemExit(f"{level}: --help returned no output")
        samples[level]["hot_help_ms"].append(elapsed)

def stats(values):
    ordered = sorted(values)
    return {
        "n": len(values),
        "median_ms": statistics.median(values),
        "p95_ms": ordered[max(0, math.ceil(len(values) * 0.95) - 1)],
        "samples_ms": values,
    }

report = {
    "kind": "CLI-startup-process-comparison",
    "source_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "host": platform.node(),
    "platform": platform.platform(),
    "cold_definition": "first new-process --version invocation in each interleaved round",
    "hot_definition": "new-process --help after one excluded warm-up invocation",
    "variants": {},
}
for level in levels:
    binary = out / level / "cmux"
    report["variants"][level] = {
        "bytes": binary.stat().st_size,
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "cold_process_version": stats(samples[level]["cold_process_version_ms"]),
        "hot_help": stats(samples[level]["hot_help_ms"]),
    }
(out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
PY
