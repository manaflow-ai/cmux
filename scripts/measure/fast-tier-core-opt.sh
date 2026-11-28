#!/usr/bin/env bash
# fast-tier-core-opt.sh: wall time of the fast tier's cmux-tui-core test-library build (cargo test --no-run -p
# cmux-tui-core --lib, CARGO_INCREMENTAL=0, as cmux-next.yml's fast-tier-cargo runs it) after a rebuild of
# cmux-tui-core and acpmux, at dev opt-level 1 (the workspace) and 0 (fast-tier.py), twice each, then the
# matrix entry's run time at each level. Run from the repo root: cmux-ci test -- bash scripts/measure/fast-tier-core-opt.sh
set -u
# The fast-tier-cargo job's env and setup steps (cmux-next.yml), so the build matches it.
export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC= CMUX_GHOSTTY_VT_ZIG_CPU=baseline
bash scripts/ci/init-submodule.sh ghostty-next >/dev/null || exit 1
if [ -z "${ZIG:-}${CMUX_ZIG:-}" ] && ! command -v zig >/dev/null; then
  ZIG_FORCE_LOCAL_INSTALL=1 ZIG_INSTALL_ROOT="$HOME/.local/zig-ci" ./scripts/install-zig-ci.sh >/dev/null || exit 1
fi
fail=0
cd cmux-tui
export CARGO_INCREMENTAL=0
nproc
t(){ s=$(date +%s); "$@" > /tmp/b.log 2>&1; rc=$?; echo "$L rc=$rc $(( $(date +%s)-s ))s"; [ $rc = 0 ] || { fail=1; grep -E "error|panicked|unable|fetch" /tmp/b.log | head -15; }; }
L=warm t cargo test --locked --no-run -p cmux-tui-core --lib
for lvl in 1 0 1 0; do touch crates/cmux-tui-core/src/lib.rs crates/acpmux/src/lib.rs crates/cmux-layout-reducer/src/lib.rs; L=opt$lvl t cargo test --locked --no-run -p cmux-tui-core --lib --config "profile.dev.package.cmux-tui-core.opt-level=$lvl"; done
s=$(date +%s); cargo test --locked -p cmux-tui-core --lib --config profile.dev.package.cmux-tui-core.opt-level=0 -- mux::tests::matrix 2>&1 | grep -E 'test result'; echo "run0 $(( $(date +%s)-s ))s"
cargo test --locked --no-run -p cmux-tui-core --lib >/dev/null 2>&1; s=$(date +%s); cargo test --locked -p cmux-tui-core --lib -- mux::tests::matrix 2>&1 | grep -E 'test result'; echo "run1 $(( $(date +%s)-s ))s"
exit $fail
