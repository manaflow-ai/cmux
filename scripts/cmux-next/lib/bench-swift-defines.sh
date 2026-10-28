# shellcheck shell=bash
# The Swift -D flags of the bench configuration (reload.sh --config bench, check-release-compile.sh
# --bench-hooks): one place, so the compile check builds what a bench runs (bench-config-parity.py).
#   CMUX_BENCH_HOOKS: the debug.* control surface and its counters, never shipped (check-no-bench-hooks.sh).
#   CMUX_BLOCKING_CHECKS: the main-thread blocking detector records (never traps), as a Nightly does
#   (plans/cmux-next/threading-model.md).
# shellcheck disable=SC2034 # read by the scripts that source this file
CMUX_BENCH_SWIFT_DEFINES="-DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS"
