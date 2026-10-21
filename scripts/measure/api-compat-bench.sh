#!/usr/bin/env bash
# Rex parity bench for cmux-api-compat (msg 2785): 10,000-revision chains of
# pathological change rules applied to a ~20 KB message, upgrade and
# downgrade, plus broadcast to 1,000 peers. Rex reports ~35 us per upgrade.
# Run alone on an idle mini:
#   cmux-ci run --class exclusive --measurement \
#     --script scripts/measure/api-compat-bench.sh --ref SHA [--target-worker NAME]
# Prints APICOMPAT-MACHINE and one `scenario=` line per case.
set -euo pipefail
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "api-compat-bench.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
cd "$root/cmux-tui"
export CARGO_TARGET_DIR="$root/.build/api-compat-bench-target"
toolchain_cargo="$(rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "APICOMPAT-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)\" cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc) sha=$(git rev-parse --short=11 HEAD)"
echo "APICOMPAT-LOAD before $(uptime | sed 's/.*load averages*: //')"
cargo bench --locked -p cmux-api-compat --bench rex_parity 2>&1 | grep -v '^ *\(Compiling\|Finished\|Running\)'
echo "APICOMPAT-LOAD after $(uptime | sed 's/.*load averages*: //')"
