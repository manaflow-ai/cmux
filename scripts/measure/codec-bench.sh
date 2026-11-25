#!/usr/bin/env bash
# Screen-share codec bench (cmux-tui/crates/cmux-codecs, `codec-bench`) on an Apple-silicon
# worker: the same scenes and simulated link as the Linux rows, so its encode and decode ms per
# frame are what a Mac host pays (libvpx and OpenH264 built from source with their NEON code).
# Run alone on an idle mini:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/codec-bench.sh \
#     --ref SHA --artifact artifacts/codec-bench/rows.jsonl --key KEY --timeout 5400 [--arg=ARG]...
# Args go to codec-bench as they are (default: --codecs h264,vp9 --loss 0,2 --match-h264 0,1),
# except `vp9-drop=N`, which sets libvpx's frame-drop threshold (CMUX_VP9_DROPFRAME_THRESH; 0 is off).
# Prints CODEC-BENCH-MACHINE, the Markdown table, and writes artifacts/codec-bench/{rows.jsonl,table.md}.
set -euo pipefail
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "codec-bench.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
out="$root/artifacts/codec-bench"
mkdir -p "$out"
cd "$root/cmux-tui/crates/cmux-codecs"
export CARGO_TARGET_DIR="$root/.build/codec-bench-target"
toolchain_cargo="$(rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
args=()
for arg in "$@"; do
  case "$arg" in
    vp9-drop=*) export CMUX_VP9_DROPFRAME_THRESH="${arg#vp9-drop=}" ;;
    *) args+=("$arg") ;;
  esac
done
[[ ${#args[@]} -gt 0 ]] || args=(--codecs h264,vp9 --loss 0,2 --match-h264 0,1)
echo "CODEC-BENCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)\" cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc) sha=$(git rev-parse --short=11 HEAD)"
echo "CODEC-BENCH-LOAD before $(uptime | sed 's/.*load averages*: //')"
# rav1d's crates.io package lacks src/arm/asm-offsets.h, so its arm64 assembly does not
# build; AV1 runs as portable code on Apple silicon (H.264 and VP9 keep their NEON code).
features=vp9,av1
[[ "$(uname -m)" == x86_64 ]] && features+=,asm
cargo build --locked --release --no-default-features --features "$features" --bin codec-bench 2>&1 | grep -v '^ *\(Compiling\|Downloaded\|Downloading\)' | tail -20
"$CARGO_TARGET_DIR/release/codec-bench" "${args[@]}" --json "$out/rows.jsonl" | tee "$out/table.md"
echo "CODEC-BENCH-LOAD after $(uptime | sed 's/.*load averages*: //')"
