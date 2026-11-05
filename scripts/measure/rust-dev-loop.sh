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
# (Linux), nodebug, lld+nodebug, nightly, nightly+threads8, cranelift, cranelift+all, and blaze
# (github.com/indexable-inc/blaze, its pinned release; one clean build, then edits; rss_mb per build).
# Output: DEVLOOP lines (variant scenario n p50 p95 min max compiled failures; with n under 20
# p95 is close to the max), DEVLOOP-SAMPLE
# per build, and .build/rust-dev-loop/samples.json. Exit 1 when a dev build failed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
variants=base n=8 clean_n=1 scenarios=core,tui,acpmux,switch tests="" out="" timings=0
for kv in "$@"; do
  case "$kv" in
    variants=*) variants="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    clean_n=*) clean_n="${kv#*=}" ;;
    scenarios=*) scenarios="${kv#*=}" ;;
    tests=*) tests="${kv#*=}" ;;
    out=*) out="${kv#*=}" ;;
    timings=*) timings="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
# Scratch (variant targets, zig packages, blaze) lives outside the checkout: blaze's daemon watches
# the checkout, .gitignore'd build output included.
# On disk, not /tmp: Linux /tmp is often tmpfs (RAM), and the variant targets are tens of GB.
scratch="${CMUX_DEVLOOP_SCRATCH:-$HOME/.cache/cmux-rust-dev-loop}/run-$$"
mkdir -p "$scratch"
df -h "$scratch" | tail -1
# This run's own scratch and blaze home only (named by this shell's pid).
trap 'rm -rf "$scratch" "${TMPDIR:-/tmp}/cmux-rust-dev-loop-blaze-home-$$"' EXIT
# Ghostty's zig packages download once, with retries, before any clock starts; every variant's
# cold zig cache links to them (rust-dev-loop.py --zig-packages).
zig_packages="$scratch/zig"
mkdir -p "$zig_packages"
ZIG_GLOBAL_CACHE_DIR="$zig_packages" "$root/scripts/ci/fetch-ghostty-zig-packages.sh" "$root/ghostty-next"
# Linux without mold: mold's release binary, checked against its published sha256.
if [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] && ! command -v mold >/dev/null; then
  mold_dir="$scratch/mold"
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
# blaze, when asked for: its pinned release, checked against the sha256 GitHub publishes, with its
# home (daemon state, build directory) outside the checkout; the toolchain download
# happens here, before any clock starts.
if [[ ",$variants," == *,blaze,* ]]; then
  blaze_version=0.20261105.1
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) blaze_target=x86_64-unknown-linux-gnu blaze_sha=aaf09e38f7cd9e873c84d4fa6afe8c26f713cb558e2e9dfc1a599af31b15ad8b ;;
    Linux-aarch64) blaze_target=aarch64-unknown-linux-gnu blaze_sha=b50716873fe4f1fd9c0c3604e8df49d5f8225c0ded995016c86b9f5a2f7e4ebc ;;
    Darwin-arm64) blaze_target=aarch64-apple-darwin blaze_sha=2c6fb64b14668cb73c1a4531bd4f8b77665d2abe0e365d5ad76aaa77a3001f3e ;;
    *) blaze_target="" ;;
  esac
  blaze_dir="$scratch/blaze"
  # Outside the checkout: blaze's daemon watches the checkout and reads every file in it, its own
  # socket included ("v2.sock changed and can't be read", 0.20261105.1).
  export BLAZE_HOME="${TMPDIR:-/tmp}/cmux-rust-dev-loop-blaze-home-$$"
  mkdir -p "$blaze_dir/bin" "$BLAZE_HOME"
  blaze_tgz="$blaze_dir/blaze-v$blaze_version-$blaze_target.tar.gz"
  if [[ -n "$blaze_target" ]] \
    && curl -fsSL --retry 3 -o "$blaze_tgz" "https://github.com/indexable-inc/blaze/releases/download/v$blaze_version/blaze-v$blaze_version-$blaze_target.tar.gz" \
    && python3 -c 'import hashlib,sys; sys.exit(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()!=sys.argv[2])' "$blaze_tgz" "$blaze_sha"; then
    tar -xzf "$blaze_tgz" -C "$blaze_dir/bin"
    blaze_bin="$(dirname "$(find "$blaze_dir/bin" -type f -name blaze -perm -u+x | head -1)")"
    export PATH="$blaze_bin:$PATH"
    blaze --version || true
    blaze toolchain || echo "notice: blaze toolchain failed; its first build fetches the toolchain"
  else
    echo "notice: no blaze release for this host or the download failed; the blaze variant is skipped"
  fi
fi
cd "$root/cmux-tui"
rustup show active-toolchain || true
out="${out:-$root/.build/rust-dev-loop}"
mkdir -p "$out"
python3 "$root/scripts/measure/rust-dev-loop.py" --workspace "$root/cmux-tui" --out "$out" \
  --target-root "$scratch/target" --zig-packages "$zig_packages/p" --variants "$variants" --n "$n" --clean-n "$clean_n" --scenarios "$scenarios" --tests "$tests" $([[ "$timings" == 1 ]] && echo --timings)
