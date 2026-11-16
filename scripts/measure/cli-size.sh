#!/usr/bin/env bash
# CMUX-570: compare CLI compiler optimization on one source tree and toolchain.
# Fleet only. Results are binary payloads until a complete app is packaged.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cli-size.sh 'cargo build' 'CMUX-570 CLI optimization comparison'
out="${FAST_CHECKS_OUT:-$root/artifacts/cli-size}"
mkdir -p "$out"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/cmux-tui/target/cli-size}"
cd "$root/cmux-tui"
for level in 3 s z; do
  # Override only the CLI crate. Dependencies and the rendering/daemon core
  # retain their shipping optimization, LTO and codegen-unit settings.
  setting="$level"
  [[ "$level" == 3 ]] || setting="\"$level\""
  cargo build --locked --release -p cmux-tui --bin cmux-tui \
    --config "profile.release.package.cmux-tui.opt-level=$setting" \
    2>&1 | tee "$out/build-$level.log"
  mkdir -p "$out/$level"
  cp "$CARGO_TARGET_DIR/release/cmux-tui" "$out/$level/cmux"
  case "$(uname -s)" in
    Darwin) strip -x "$out/$level/cmux" ;;
    Linux) strip --strip-unneeded "$out/$level/cmux" ;;
    *) echo 'CLI size comparison requires a Linux or macOS fleet worker' >&2; exit 2 ;;
  esac
done
# Interleave samples so the comparison does not assign a cold filesystem to
# one compiler mode. Each invocation has a deadline and must succeed.
python3 - "$out" <<'PY'
import hashlib, json, pathlib, statistics, subprocess, sys, time
out = pathlib.Path(sys.argv[1])
levels = ('3', 's', 'z')
samples = {level: {'help': [], 'version': []} for level in levels}
expected = {}
for round in range(21):
    for level in levels[round % 3:] + levels[:round % 3]:
        for command in ('help', 'version'):
            start = time.perf_counter()
            result = subprocess.run([str(out / level / 'cmux'), '--' + command],
                                    capture_output=True, check=True, timeout=30)
            elapsed = (time.perf_counter() - start) * 1000
            # These flags must retain exactly the same grammar and version.
            answer = (result.stdout, result.stderr)
            expected.setdefault(command, answer)
            if answer != expected[command]:
                raise SystemExit(f'{level}: --{command} output changed')
            if round:
                samples[level][command].append(elapsed)
report = {'kind': 'CLI-payload-only', 'source_sha': subprocess.check_output(
    ['git', 'rev-parse', 'HEAD'], text=True).strip(), 'variants': {}}
for level in levels:
    binary = out / level / 'cmux'
    report['variants'][level] = {'bytes': binary.stat().st_size,
        'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'commands': {key: {'median_ms': statistics.median(values),
                          'p95_ms': sorted(values)[18], 'samples_ms': values}
                     for key, values in samples[level].items()}}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
