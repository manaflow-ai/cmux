#!/usr/bin/env bash
# Prints the cargo package and target arguments for the cmux_next_ daemon tests
# (cmux-tui-artifacts.yml "cargo test cmux_next_"): one `-p NAME` per workspace
# member whose Rust sources contain `cmux_next_`, then the test targets those
# sources belong to: `--lib --bins` for a file under src/, `--test NAME` for a
# file under tests/ (tests/NAME.rs, or a module of it under tests/NAME/).
# cargo's test filter matches the test path, so a test or a module named with
# cmux_next_ can only live in such a target. Building only those targets skips
# the members' other test binaries: acpmux alone has about 300, and once
# cmux-tui turned on acpmux's hub-carrier feature (#43753) every one of them
# linked the hub carrier, which filled an 8-vCPU runner's disk on every run
# from 171c1fa97a7 ("No space left on device", cmux-tui-artifacts run 43758800604).
# Falls back to the members alone (all their test targets) when a match is in
# a file it cannot place in one target, and to `--workspace` when a match is
# outside a member it can name.
# Usage (from the repository root or cmux-tui/): scripts/ci/cmux-next-daemon-test-packages.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)/cmux-tui"
cd "$root"
packages=()
targets=()
placed=1
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
  packages+=("-p" "$name")
  # A member that names its own test targets may not map tests/NAME.rs to NAME.
  if grep -qE '^autotests *= *false' "$dir/Cargo.toml"; then placed=0; continue; fi
  rel="${file#"$dir"/}"
  case "$rel" in
    src/*) targets+=("--lib" "--bins") ;;
    tests/*)
      test_name="${rel#tests/}"; test_name="${test_name%%/*}"; test_name="${test_name%.rs}"
      if [[ -f "$dir/tests/$test_name.rs" || -f "$dir/tests/$test_name/main.rs" ]]; then
        targets+=("--test" "$test_name")
      else
        placed=0
      fi
      ;;
    *) placed=0 ;;
  esac
done < <(git grep -l 'cmux_next_' -- '*.rs')
if (( ${#packages[@]} == 0 )); then echo "--workspace"; exit 0; fi
pairs() { printf '%s %s\n' "$@" | sort -u | tr '\n' ' '; }
out="$(pairs "${packages[@]}")"
if (( placed == 1 && ${#targets[@]} > 0 )); then
  # --lib and --bins are one word each; the --test pairs stay pairs.
  flags=()
  for t in "${targets[@]}"; do [[ "$t" == --lib || "$t" == --bins ]] && flags+=("$t"); done
  tests=()
  for ((i = 0; i < ${#targets[@]}; i++)); do
    [[ "${targets[$i]}" == --test ]] && tests+=("--test" "${targets[$((i + 1))]}")
  done
  out+="$(printf '%s\n' ${flags[@]+"${flags[@]}"} | sort -u | tr '\n' ' ')"
  (( ${#tests[@]} > 0 )) && out+="$(pairs "${tests[@]}")"
fi
printf '%s\n' "${out% }"
