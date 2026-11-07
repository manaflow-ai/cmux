#!/usr/bin/env bash
# Experiment (goal cloud-fix-to-machine): how long a warm incremental release build of the Cloud machine's
# binaries takes after a one-file edit, against the cold build. Not for merge.
set -euo pipefail
cd cmux-tui
out="${FAST_CHECKS_OUT:-/tmp}/incr.txt"
nproc | sed 's/^/nproc /' | tee -a "$out"
t() { local s; s=$(date +%s); "$@" >/dev/null 2>&1 || { echo "FAILED: $*" | tee -a "$out"; return 1; }; echo $(( $(date +%s) - s )); }
b() { cargo build --release --locked -p cmux-tui --bin cmux-tui --bin cmux-tui-hook; }
echo "cold $(t b)s" | tee -a "$out"
echo "noop $(t b)s" | tee -a "$out"
echo '// incr-experiment' >> crates/cmux-tui/src/main.rs
echo "edit-cmux-tui-main $(t b)s" | tee -a "$out"
echo '// incr-experiment' >> crates/cmux-tui-core/src/lib.rs
echo "edit-cmux-tui-core $(t b)s" | tee -a "$out"
du -sh target | tee -a "$out"
