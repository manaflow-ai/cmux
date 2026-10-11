#!/usr/bin/env bash
# Prints the cargo package arguments for the cmux_next_ daemon tests
# (cmux-tui-artifacts.yml "cargo test cmux_next_"): one `-p NAME` per workspace
# member whose Rust sources contain `cmux_next_`. cargo's test filter matches the
# test path, so a test or a module named with cmux_next_ can only live in such a
# member. Building only those test targets skips the other members' test
# binaries (acpmux alone has about 45), which was most of the job's 11.5 min
# compile on 2026-10-09.
# Falls back to `--workspace` when a match is outside a member it can name.
# Usage (from the repository root or cmux-tui/): scripts/ci/cmux-next-daemon-test-packages.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)/cmux-tui"
cd "$root"
args=()
while IFS= read -r file; do
  dir="$file"
  while [[ "$dir" == */* ]]; do
    dir="${dir%/*}"
    [[ -f "$dir/Cargo.toml" ]] && grep -q '^\[package\]' "$dir/Cargo.toml" && break
  done
  if [[ "$dir" != */* && ! -f "$dir/Cargo.toml" ]] || ! grep -q '^\[package\]' "$dir/Cargo.toml" 2>/dev/null; then
    echo "--workspace"; exit 0
  fi
  name="$(sed -n 's/^name *= *"\([^"]*\)".*/\1/p' "$dir/Cargo.toml" | head -n 1)"
  [[ -n "$name" ]] || { echo "--workspace"; exit 0; }
  args+=("-p" "$name")
done < <(git grep -l 'cmux_next_' -- '*.rs')
if (( ${#args[@]} == 0 )); then echo "--workspace"; exit 0; fi
printf '%s %s\n' "${args[@]}" | sort -u | tr '\n' ' ' | sed 's/ $/\n/'
