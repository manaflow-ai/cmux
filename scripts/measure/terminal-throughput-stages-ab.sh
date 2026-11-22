#!/usr/bin/env bash
# Terminal throughput by stage on Linux (CMUX-571 goal terminal-throughput), before and after: the stage harness
# (cmux-tui/crates/cmux-tui/tests/terminal_throughput_stages.rs) at this checkout and at each BEFORE commit, in one
# job on one worker, so both arms come from one harness and one machine. Each BEFORE commit is checked out whole into
# a scratch worktree and given this checkout's harness file; arms alternate (after, before, after, ...) once per
# round so a noisy neighbour hits both. Prints "STAGES-AT <label> <sha> round N" before each arm's table, then the
# tables of every arm; with FAST_CHECKS_OUT set it copies each arm's terminal-throughput-stages.json there.
#   cmux-ci test --setup rust -- bash -c 'set -o pipefail; scripts/measure/terminal-throughput-stages-ab.sh BEFORE_SHA [mb=200] [runs=3] [rounds=1] [stages=daemon-hosted+viewer,...]'
# A Linux-only harness; on macOS use scripts/measure/terminal-throughput.sh (the app against Ghostty).
set -uo pipefail
before="${1:?usage: terminal-throughput-stages-ab.sh BEFORE_SHA [mb=200] [runs=3] [rounds=1] [stages=LIST]}"
shift
mb=200 runs=3 rounds=1 stages="daemon-hosted,daemon-hosted+viewer,daemon-hosted+viewer-snapshot,daemon-hosted+viewer-frames"
for arg in "$@"; do
  case "$arg" in
    mb=*) mb="${arg#mb=}" ;; runs=*) runs="${arg#runs=}" ;; rounds=*) rounds="${arg#rounds=}" ;;
    stages=*) stages="${arg#stages=}" ;; *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
harness=cmux-tui/crates/cmux-tui/tests/terminal_throughput_stages.rs
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
depth=()
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git -C "$root" cat-file -e "$before^{commit}" 2>/dev/null \
  || git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} origin "$before"
before="$(git -C "$root" rev-parse "$before^{commit}")"
after="$(git -C "$root" rev-parse HEAD)"
tree="$scratch/${before:0:12}"
git -C "$root" worktree add -q --detach "$tree" "$before" && trees+=("$tree") || exit 1
# The before tree borrows this checkout's submodules (ghostty) and harness: only the Rust it builds differs.
for sub in $(git -C "$root" config --file .gitmodules --get-regexp path | awk '{print $2}'); do
  [[ -e "$root/$sub/.git" || -d "$root/$sub" ]] && rm -rf "${tree:?}/$sub" && ln -s "$root/$sub" "$tree/$sub"
done
cp "$root/$harness" "$tree/$harness"
export CMUX_THROUGHPUT_MB="$mb" CMUX_THROUGHPUT_RUNS="$runs" CMUX_THROUGHPUT_STAGES="$stages"
out="${FAST_CHECKS_OUT:-}"
# Each arm builds into its own target dir: the harness starts the daemon at its compiled-in CARGO_BIN_EXE path, so
# a shared one would run the last build's daemon in both arms.
target_for() { [[ "$1" == "$root" ]] && echo "${CARGO_TARGET_DIR:-$root/cmux-tui/target}" || echo "$scratch/target-before"; }
build() { (cd "$1/cmux-tui" && CARGO_TARGET_DIR="$(target_for "$1")" cargo test --release -p cmux-tui --test terminal_throughput_stages --no-run 2>&1 | tail -1); }
build "$root" || exit 1
build "$tree" || exit 1
status=0
summary=()
for round in $(seq 1 "$rounds"); do
  for arm in after before; do
    dir="$root" sha="$after"
    [[ "$arm" == before ]] && dir="$tree" sha="$before"
    echo "STAGES-AT $arm $sha round $round"
    arm_out="$scratch/out-$arm-$round"
    mkdir -p "$arm_out"
    (cd "$dir/cmux-tui" && CARGO_TARGET_DIR="$(target_for "$dir")" FAST_CHECKS_OUT="$arm_out" cargo test --release -p cmux-tui --test terminal_throughput_stages \
      -- --ignored --nocapture 2>&1 | grep -vE '^\s*(Compiling|Finished|Running)') || status=1
    [[ -n "$out" && -f "$arm_out/terminal-throughput-stages.json" ]] \
      && cp "$arm_out/terminal-throughput-stages.json" "$out/stages-$arm-$round.json"
    [[ -f "$arm_out/terminal-throughput-stages.md" ]] && summary+=("== $arm ${sha:0:12} round $round" "$(cat "$arm_out/terminal-throughput-stages.md")")
  done
done
printf '%s\n' "${summary[@]}"
exit "$status"
