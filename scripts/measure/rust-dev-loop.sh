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
# Ghostty's zig packages download once, with retries, before any clock starts; every variant's
# cold zig cache links to them (rust-dev-loop.py --zig-packages).
zig_packages="$root/.build/rust-dev-loop-zig"
mkdir -p "$zig_packages"
ZIG_GLOBAL_CACHE_DIR="$zig_packages" "$root/scripts/ci/fetch-ghostty-zig-packages.sh" "$root/ghostty-next"
# Linux without mold: mold's release binary, checked against its published sha256.
if [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] && ! command -v mold >/dev/null; then
  mold_dir="$root/.build/rust-dev-loop-mold"
  mold_tgz="$mold_dir/mold-3.0.0-x86_64-linux.tar.gz"
  mkdir -p "$mold_dir"
  if curl -fsSL --retry 3 -o "$mold_tgz" https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-x86_64-linux.tar.gz \
    && echo "6c90d4a474c7c0409dfb575be03a5345878ac14fdba18de8b40fa58c60121189  $mold_tgz" | sha256sum -c --quiet; then
    tar -xzf "$mold_tgz" -C "$mold_dir"
    export PATH="$mold_dir/mold-3.0.0-x86_64-linux/bin:$PATH"
  else
    echo "notice: mold download failed; the mold variants are skipped"
  fi
fi
cd "$root/cmux-tui"
rustup show active-toolchain || true
out="${out:-$root/.build/rust-dev-loop}"
mkdir -p "$out"
exec python3 "$root/scripts/measure/rust-dev-loop.py" --workspace "$root/cmux-tui" --out "$out" \
  --target-root "$root/.build/rust-dev-loop-target" --zig-packages "$zig_packages/p" --variants "$variants" --n "$n" --clean-n "$clean_n" --scenarios "$scenarios" --tests "$tests"
