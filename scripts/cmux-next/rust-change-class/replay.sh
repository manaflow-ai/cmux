#!/usr/bin/env bash
# Sorts merged PRs' Rust changes into rust-change-class buckets (a fleet step):
#   cmux-ci test --setup rust -- bash scripts/cmux-next/rust-change-class/replay.sh PR:MERGE...
# Writes $FAST_CHECKS_OUT/buckets.jsonl (one line per PR: {"pr", "merge", ...classifier output})
# and Cargo.lock, so a first run can hand its lockfile back.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"; mkdir -p "$out"
export CARGO_TARGET_DIR="$here/target"
(cd "$here" && cargo build --release --locked 2>&1 | tail -5 && cargo test --release --locked 2>&1 | tail -15) | tee "$out/build.log"
cp "$here/Cargo.lock" "$out/Cargo.lock" 2>/dev/null || true
bin="$here/target/release/rust-change-class"
merges=(); for pair in "$@"; do merges+=("${pair#*:}"); done
depth=()  # --depth only in a checkout that is already shallow, so a full clone stays full
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=2)
git -C "$root" fetch -q --no-tags ${depth[@]+"${depth[@]}"} origin "${merges[@]}" || echo "fetch failed" >&2
: > "$out/buckets.jsonl"
for pair in "$@"; do
  pr="${pair%%:*}" merge="${pair#*:}"
  result="$("$bin" --repo "$root" "$merge^1" "$merge" 2>>"$out/errors.log")" || result='{"bucket":"error"}'
  printf '{"pr":%s,"merge":"%s","result":%s}\n' "$pr" "$merge" "$result" >> "$out/buckets.jsonl"
done
wc -l "$out/buckets.jsonl"
