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
# A member with `autotests = false` names its test targets as `[[test]]`
# entries: a file under tests/ goes to the entry whose path is that file, or the
# tests/DIR.rs or tests/DIR/main.rs entry of its folder, else to the member's one
# tests/DIR/main.rs entry that gathers the undeclared files (cmux-tui's `it`,
# #56677). Before that mapping, cmux-tui's `autotests = false` (#56928,
# 2026-11-25 21:42Z) sent the job back to every test target of every member,
# acpmux's ~300 included, and each window's run died "No space left on device"
# on the pool: the feat-cmux-next channel stayed at 2b2b65097 (22:57Z).
# Falls back to the members alone (all their test targets) when a match is in
# a file it cannot place in one target, and to `--workspace` when a match is
# outside a member it can name.
# Usage (from the repository root or cmux-tui/): scripts/ci/cmux-next-daemon-test-packages.sh [MEMBER_DIR]
# MEMBER_DIR (a member's directory under cmux-tui/, e.g. crates/acpmux) prints that one member's package and
# targets only: the per-member pull request steps of ci/steps.toml (cmux-next-acpmux and the rest) run those.
set -euo pipefail
root="$(git rev-parse --show-toplevel)/cmux-tui"
cd "$root"
member="${1:-}"
if [[ -n "$member" && ! -f "$member/Cargo.toml" ]]; then
  echo "$0: $member is not a member directory under cmux-tui/" >&2
  exit 2
fi
# The [[test]] target of an `autotests = false` member that builds tests/... file REL, or nothing.
declared_test() {
  local manifest="$1" rel="$2" top entries name path gather="" gathers=0
  top="${rel#tests/}"; top="${top%%/*}"; top="${top%.rs}"
  # One "name<TAB>path" line per [[test]] entry; a missing path is cargo's tests/NAME.rs.
  entries="$(awk '
    function emit() { if (inside && name != "") print name "\t" (path != "" ? path : "tests/" name ".rs") }
    /^\[\[test\]\]/ { emit(); inside = 1; name = ""; path = ""; next }
    /^\[/ { emit(); inside = 0; next }
    inside && /^name *=/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); name = v }
    inside && /^path *=/ { v = $0; sub(/^[^"]*"/, "", v); sub(/".*$/, "", v); sub(/^\.\//, "", v); path = v }
    END { emit() }' "$manifest")"
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    if [[ "$path" == "$rel" || "$path" == "tests/$top.rs" || "$path" == "tests/$top/main.rs" ]]; then
      printf '%s\n' "$name"; return 0
    fi
    if [[ "$path" == tests/*/main.rs ]]; then gather="$name"; gathers=$((gathers + 1)); fi
  done <<<"$entries"
  (( gathers == 1 )) && printf '%s\n' "$gather"
  return 0
}
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
  rel="${file#"$dir"/}"
  # A member that names its own test targets: place the file through its [[test]] entries.
  if grep -qE '^autotests *= *false' "$dir/Cargo.toml"; then
    case "$rel" in
      src/*) targets+=("--lib" "--bins"); continue ;;
      tests/*) ;;
      *) placed=0; continue ;;
    esac
    test_name="$(declared_test "$dir/Cargo.toml" "$rel")"
    if [[ -n "$test_name" ]]; then targets+=("--test" "$test_name"); else placed=0; fi
    continue
  fi
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
done < <(git grep -l 'cmux_next_' -- "${member:+$member/}*.rs")
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
