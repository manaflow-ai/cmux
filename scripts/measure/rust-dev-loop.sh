#!/usr/bin/env bash
# Edit-to-runnable time of cmux's Rust dev build (cmux-tui and acpmux binaries) per
# build-setting variant, as p50/p95. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/rust-dev-loop.sh --ref SHA \
#     [--arg=variants=base,lld,nodebug] [--arg=n=8] [--arg=clean_n=1] \
#     [--arg=scenarios=core,tui,acpmux,switch] [--arg=tests=acpmux] \
#     --artifact .build/rust-dev-loop/samples.json --timeout 10800
# Each variant gets its own target directory and a clean build (clean_n of them), then n
# interleaved rounds of a one-line edit in cmux-tui-core, cmux-tui and acpmux, each followed
# by `cargo build -p cmux-tui -p acpmux --bins`. scenario `switch` builds acpmux and cmux-tui
# alone after the pair (dependencies recompiled there are feature-unification churn, what a
# workspace-hack crate removes). tests=PKGS times `cargo test` against `cargo nextest run`.
# Variants (scripts/measure/rust-dev-loop.py `variants`): base, lld (macOS) or mold/split
# (Linux), nodebug, lld+nodebug, nightly, nightly+threads8, cranelift, cranelift+all.
# Output: DEVLOOP lines (variant scenario n p50 p95 min max compiled failures; with n under 20
# p95 is close to the max), DEVLOOP-SAMPLE
# per build, and .build/rust-dev-loop/samples.json. Exit 1 when a dev build failed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
variants=base n=8 clean_n=1 scenarios=core,tui,acpmux,switch tests="" out=""
for kv in "$@"; do
  case "$kv" in
    variants=*) variants="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    clean_n=*) clean_n="${kv#*=}" ;;
    scenarios=*) scenarios="${kv#*=}" ;;
    tests=*) tests="${kv#*=}" ;;
    out=*) out="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
cd "$root/cmux-tui"
rustup show active-toolchain
out="${out:-$root/.build/rust-dev-loop}"
mkdir -p "$out"
exec python3 "$root/scripts/measure/rust-dev-loop.py" --workspace "$root/cmux-tui" --out "$out" \
  --target-root "$root/.build/rust-dev-loop-target" --variants "$variants" --n "$n" --clean-n "$clean_n" --scenarios "$scenarios" --tests "$tests"
