#!/usr/bin/env bash
# Times scripts/cmux-next/build-optchat-chief.sh at two commits on one host, in
# one step: cold, warm, a commit that changes no Chief input, and (HEAD_SHA only)
# a commit that changes Chief source. BASE_SHA builds commit-keyed, HEAD_SHA with
# CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1 as the nightly sets it, so a Chief cache
# change shows its before and after (first used for cmux#28194).
# Usage: chief-build-cache.sh BASE_SHA HEAD_SHA
# Each side gets its own fresh Cargo target dir and cache root, so "cold" is a
# real cold build and nothing is shared with the worker's warm Rust targets.
set -euo pipefail
base="${1:?BASE_SHA}"
head="${2:?HEAD_SHA}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chief-build-cache.XXXXXX")"
results="$repo/chief-build-cache-results.tsv"
: > "$results"
cleanup() {
  git -C "$repo" worktree remove --force "$work/base" >/dev/null 2>&1 || true
  git -C "$repo" worktree remove --force "$work/head" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

export CI=1
# The base side builds commit-keyed: clear the mode switch too, or an exported
# nightly setting would make the baseline input-keyed and the comparison void.
unset CMUX_FLEET_WORKER_TRUSTED CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEY \
  CMUX_NEXT_OPTCHAT_CHIEF_ENVIRONMENT_KEY CMUX_NEXT_OPTCHAT_CHIEF_REQUIRE_IDENTITY || true
export CMUX_NEXT_OPTCHAT_CHIEF_ARCHS=arm64

for sha in "$base" "$head"; do
  # A cmux-ci step checkout may have no origin remote; fetch from the public repository then.
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$repo" fetch --quiet --no-tags origin "$sha" 2>/dev/null \
    || git -C "$repo" fetch --quiet --no-tags https://github.com/manaflow-ai/cmux.git "$sha" \
    || { echo "chief-build-cache.sh: cannot fetch $sha" >&2; exit 1; }
done
echo "host: $(uname -m) $(sw_vers -productVersion 2>/dev/null || true) cpus=$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "python3: $(python3 --version 2>&1)"
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$repo/cmux-tui/rust-toolchain.toml")"
echo "toolchain: $toolchain"

gcommit() { git -c user.name=measure -c user.email=measure@invalid -c commit.gpgsign=false -C "$1" commit -q -am "$2"; }

# run SIDE CASE DIR TARGET CACHE [ENV...]
run() {
  local side="$1" case="$2" dir="$3" target="$4" cache="$5"; shift 5
  local out="$work/$side-$case.log" result="$work/$side-$case.result" start end rc=0
  start="$(python3 -c 'import time;print(time.time())')"
  env CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$target" CMUX_NEXT_OPTCHAT_CHIEF_CACHE="$cache" \
    CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE="$result" "$@" \
    "$dir/scripts/cmux-next/build-optchat-chief.sh" --output "$work/out/$side-$case/optchat-chief" >"$out" 2>&1 || rc=$?
  end="$(python3 -c 'import time;print(time.time())')"
  local secs verdict cargo
  secs="$(python3 -c "print(f'{$end-$start:.1f}')")"
  if grep -q "already cached" "$out"; then verdict=reused; elif grep -q "optchat-chief built at" "$out"; then verdict=built; else verdict=failed; fi
  cargo="$(grep -c '^ *Compiling ' "$out" || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$side" "$case" "$secs" "$verdict" "$cargo" "$rc" "$(git -C "$dir" rev-parse HEAD)" | tee -a "$results"
  tail -n 4 "$out" | sed "s/^/  [$side-$case] /"
  [[ "$rc" -eq 0 ]] || { echo "---- $side-$case log ----"; tail -n 60 "$out"; failures=$((failures + 1)); }
  return 0
}
# A failed case is recorded and the rest still run; the step fails at the end.
failures=0

printf 'side\tcase\tseconds\tresult\tcrates_compiled\texit\tcommit\n' | tee -a "$results"

# Before: the merge-base, commit-keyed cache (what every non-glaeda build uses).
git -C "$repo" worktree add --quiet --detach "$work/base" "$base"
run before cold "$work/base" "$work/tb" "$work/cb"
run before warm-same-commit "$work/base" "$work/tb" "$work/cb"
echo "measure: touch non-Chief file" >> "$work/base/README.md"; gcommit "$work/base" "measure: non-Chief change"
run before non-chief-commit "$work/base" "$work/tb" "$work/cb"

# After: the PR head, input-keyed as the nightly sets it.
git -C "$repo" worktree add --quiet --detach "$work/head" "$head"
run after cold "$work/head" "$work/th" "$work/ch" CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1
run after warm-same-commit "$work/head" "$work/th" "$work/ch" CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1
echo "measure: touch non-Chief file" >> "$work/head/README.md"; gcommit "$work/head" "measure: non-Chief change"
run after non-chief-commit "$work/head" "$work/th" "$work/ch" CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1
src=Native/OptChat/optchat-chief/src/main.rs
[[ -f "$work/head/$src" ]] || src="$(git -C "$work/head" ls-files 'Native/OptChat/optchat-chief/src/*.rs' | head -n 1)"
printf '\n// measure: Chief source change\n' >> "$work/head/$src"; gcommit "$work/head" "measure: Chief source change"
run after chief-source-commit "$work/head" "$work/th" "$work/ch" CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1

echo "==== results ===="
cat "$results"
[[ "$failures" -eq 0 ]] || { echo "error: $failures case(s) failed; the measurement is incomplete" >&2; exit 1; }
