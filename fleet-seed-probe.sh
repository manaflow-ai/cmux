#!/usr/bin/env bash
set -uo pipefail
root=$(pwd)
export CARGO_INCREMENTAL=0 GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC="" CMUX_GHOSTTY_VT_ZIG_CPU=baseline
T=$root/.build/seedprobe-target; export CARGO_TARGET_DIR=$T
echo "pwd=$root CARGO_HOME=${CARGO_HOME:-} RUSTC_WRAPPER=${RUSTC_WRAPPER:-} RUSTFLAGS=${RUSTFLAGS:-}"
cargo -V; rustc -Vv | tail -4
bash scripts/ci/init-submodule.sh ghostty-next >/dev/null 2>&1 || echo "submodule init failed"
command -v zig >/dev/null || ./scripts/install-zig-ci.sh >/dev/null 2>&1
bash scripts/ci/clippy-base-seed.sh restore "$T" 2>&1 | tail -6
cd cmux-tui
s=$SECONDS
timeout 900 env CARGO_LOG=cargo::core::compiler::fingerprint=info cargo clippy --locked --keep-going -p cmux-redact --all-targets --message-format=json -- --cap-lints warn >/dev/null 2>/tmp/fp.err
echo "rc=$? secs=$((SECONDS-s)) units=$(grep -c '^ *Compiling\|^ *Checking' /tmp/fp.err)"
grep -A4 "fingerprint dirty for" /tmp/fp.err | cut -c1-600 | head -60
grep -o "dirty: [A-Za-z]*" /tmp/fp.err | sort | uniq -c
exit 0
