#!/usr/bin/env bash
# CMUX-570: what a Rust toolchain change does to the Rust executables the Mac
# app ships, measured as shipped (stripped the way scripts/strip-release-bundle.sh
# strips them), base against this checkout, built the same way on one Mac:
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/rust-toolchain-size.sh \
#     --ref <head sha> --arg <base sha> --artifact artifacts/rust-toolchain-size.json
#
# Each tree builds with its own rust-toolchain.toml pins: bin/cmux (cmux-tui),
# cmux-tui-host and cmux-holder (cmux-tui release profile, as
# scripts/cmux-next/build-cmux-tui-client.sh builds them), optchat-chief (as
# scripts/cmux-next/build-optchat-chief.sh, on cmux-tui's toolchain) and
# cmux-diff-sidecar (Native/DiffSidecar's own pin). bin/cmux and the helpers keep
# their global symbols (strip -S -x); cmux-diff-sidecar is stripped in full.
# Prints one `rust-toolchain-size NAME base=N head=N delta=N` line per binary
# (stripped bytes) and writes artifacts/rust-toolchain-size.json.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
base_sha="${1:?usage: rust-toolchain-size.sh BASE_SHA}"
[[ "$(uname -s)" == Darwin ]] || { echo "rust-toolchain-size.sh measures macOS binaries; run it on a macOS fleet worker" >&2; exit 2; }
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
work="$(mktemp -d "${TMPDIR:-/tmp}/rust-toolchain-size.XXXXXX")"
base_tree="$work/base"
cleanup() { git -C "$root" worktree remove --force "$base_tree" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
git -C "$root" cat-file -e "$base_sha^{commit}" 2>/dev/null || git -C "$root" fetch -q --no-tags origin "$base_sha"
git -C "$root" worktree add -q --detach "$base_tree" "$base_sha"
git -C "$base_tree" submodule update -q --init ghostty-next
cache="${CI_SHARED_CACHE_DIR:-$work}/rust-toolchain-size-target"
mkdir -p "$root/artifacts"

build_tree() { # TREE LABEL
  local tree="$1" label="$2" out="$work/$2" commit toolchain target
  mkdir -p "$out"
  commit="$(git -C "$tree" rev-parse HEAD)"
  toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$tree/cmux-tui/rust-toolchain.toml")"
  target="$cache/$label"
  echo "==> $label $commit: cmux-tui (rust $toolchain)" >&2
  (cd "$tree/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CARGO_TARGET_DIR="$target/tui" \
    cargo build --locked --release -p cmux-tui --bin cmux-tui --bin cmux-tui-host >&2)
  (cd "$tree/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CARGO_TARGET_DIR="$target/tui" \
    cargo build --locked --release -p cmux-holder --bin cmux-holder >&2)
  cp "$target/tui/release/cmux-tui" "$out/cmux"
  cp "$target/tui/release/cmux-tui-host" "$out/cmux-tui-host"
  cp "$target/tui/release/cmux-holder" "$out/cmux-holder"
  echo "==> $label: optchat-chief (rust $toolchain)" >&2
  (cd "$tree/Native/OptChat/optchat-chief" && OPTCHAT_BUILD_COMMIT="${commit:0:11}" CARGO_TARGET_DIR="$target/chief" \
    cargo "+$toolchain" build --locked --release --bin optchat-chief >&2)
  cp "$target/chief/release/optchat-chief" "$out/optchat-chief"
  echo "==> $label: cmux-diff-sidecar ($(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$tree/Native/DiffSidecar/rust-toolchain.toml"))" >&2
  (cd "$tree/Native/DiffSidecar" && CARGO_TARGET_DIR="$target/sidecar" cargo build --locked --release >&2)
  cp "$target/sidecar/release/cmux-diff-sidecar" "$out/cmux-diff-sidecar"
  for name in cmux cmux-tui-host cmux-holder optchat-chief; do
    cp "$out/$name" "$out/$name.unstripped"; strip -S -x "$out/$name"
  done
  cp "$out/cmux-diff-sidecar" "$out/cmux-diff-sidecar.unstripped"; strip "$out/cmux-diff-sidecar"
  printf '%s\n' "$toolchain" >"$out/toolchain"
}

build_tree "$base_tree" base
build_tree "$root" head

size() { stat -f %z "$1"; }
json="{\"base\":\"$(git -C "$base_tree" rev-parse HEAD)\",\"head\":\"$(git -C "$root" rev-parse HEAD)\""
json+=",\"base_rust\":\"$(cat "$work/base/toolchain")\",\"head_rust\":\"$(cat "$work/head/toolchain")\",\"binaries\":{"
sep="" total_b=0 total_h=0
for name in cmux cmux-tui-host cmux-holder optchat-chief cmux-diff-sidecar; do
  b="$(size "$work/base/$name")"; h="$(size "$work/head/$name")"
  bu="$(size "$work/base/$name.unstripped")"; hu="$(size "$work/head/$name.unstripped")"
  total_b=$((total_b + b)); total_h=$((total_h + h))
  echo "rust-toolchain-size $name base=$b head=$h delta=$((h - b)) unstripped_base=$bu unstripped_head=$hu"
  json+="$sep\"$name\":{\"base\":$b,\"head\":$h,\"unstripped_base\":$bu,\"unstripped_head\":$hu}"; sep=","
done
echo "rust-toolchain-size total base=$total_b head=$total_h delta=$((total_h - total_b))"
json+="},\"total\":{\"base\":$total_b,\"head\":$total_h}}"
printf '%s\n' "$json" >"$root/artifacts/rust-toolchain-size.json"
