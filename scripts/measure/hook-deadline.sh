#!/usr/bin/env bash
# The agent hooks cmux installs, timed against their hook timeouts at two or more commits, on one Mac, from one
# harness (scripts/measure/hook-deadline.py has the cells and the output lines). Builds each commit's release
# `cmux-tui-hook` in one scratch worktree (the second build is incremental), then runs every commit's helper in turn
# inside each cell: idle and 2 x cores spinners, a daemon that answers, is slow, stalls or is down.
#   cmux-ci run --class exclusive --measurement --script scripts/measure/hook-deadline.sh --ref HEAD_SHA \
#     --arg BASE_SHA --arg HEAD_SHA [--arg n=40] [--arg load=0,1]
# Prints "HOOK-DEADLINE-AT <sha>" per built commit, then the harness's lines (label = the sha's first 12).
set -uo pipefail
shas=()
pass=()
for arg in "$@"; do
  case "$arg" in
    *=*) pass+=("$arg") ;;
    *) shas+=("$arg") ;;
  esac
done
[[ ${#shas[@]} -ge 1 ]] || { echo "usage: hook-deadline.sh SHA [SHA...] [n=N] [load=0,1] [daemons=..] [events=..]" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d)"
tree="$scratch/tree"
cleanup() {
  git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1
  rm -rf "$scratch"
}
trap cleanup EXIT
depth=()
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
helpers=()
for sha in ${shas[@]+"${shas[@]}"}; do
  git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} origin "$sha"
  full="$(git -C "$root" rev-parse "$sha^{commit}")" || exit 1
  if [[ -d "$tree" ]]; then
    git -C "$tree" checkout -q --detach "$full" || exit 1
  else
    git -C "$root" worktree add -q --detach "$tree" "$full" || exit 1
  fi
  echo "HOOK-DEADLINE-AT $full $(git -C "$root" log -1 --format=%s "$full" | cut -c1-80)"
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$scratch/target" cargo build -q --release --locked -p cmux-tui --bin cmux-tui-hook) \
    || { echo "HOOK-DEADLINE-BUILD-FAILED $full"; exit 1; }
  cp "$scratch/target/release/cmux-tui-hook" "$scratch/hook-${full:0:12}"
  helpers+=("${full:0:12}=$scratch/hook-${full:0:12}")
done
python3 "$root/scripts/measure/hook-deadline.py" ${helpers[@]+"${helpers[@]}"} ${pass[@]+"${pass[@]}"}
