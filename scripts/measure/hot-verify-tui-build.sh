#!/usr/bin/env bash
# One-off measurement (not landed): can a hot-verify display worker build cmux-tui for merge(PR head, nightly commit)
# fast enough? Prints the worker's Rust toolchain and warm targets, the merge-tree conflict rate over the pairs in
# scripts/measure/hot-verify-tui-build.pairs, and timed release builds (cold, then warm across successive merges).
#   cmux-ci run --class exclusive --display --script scripts/measure/hot-verify-tui-build.sh --ref SHA --timeout 7200
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pairs="$here/hot-verify-tui-build.pairs"
work="$(mktemp -d "${TMPDIR:-/tmp}/hvtb.XXXXXX")"
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
say() { echo "HVTB $*"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }

say host "$(hostname -s)" ncpu "$(sysctl -n hw.ncpu 2>/dev/null)" mem_gb "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
say cargo "$(command -v cargo || echo none)" rustup "$(command -v rustup || echo none)"
say rustc_wrapper "${RUSTC_WRAPPER:-unset}" sccache "$(command -v sccache || echo none)" cargo_target_dir "${CARGO_TARGET_DIR:-unset}"
say ci_shared_cache "${CI_SHARED_CACHE_DIR:-unset}"
for d in "${CI_SHARED_CACHE_DIR:-/nonexistent}/rust-targets" "$HOME/Library/Caches/cmux-next-ci/cmux-tui-cargo" \
         "${CI_SHARED_CACHE_DIR:-/nonexistent}/hot-verify"; do
  [[ -d "$d" ]] && say warm_dir "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(ls "$d" | head -5 | tr '\n' ' ')" || say warm_dir "$d" none
done
say free "$(df -h "$work" | tail -1)"

export GIT_TERMINAL_PROMPT=0
repo="$work/cmux"
t0=$(now)
git clone -q --no-checkout --filter=blob:none --shallow-since=30.days.ago --branch feat-cmux-next \
  https://github.com/manaflow-ai/cmux.git "$repo" || { say error clone; exit 1; }
shas="$(cut -f1,2 "$pairs" | tr '\t' '\n' | sort -u)"
# shellcheck disable=SC2086
git -C "$repo" fetch -q --filter=blob:none origin $shas || say warn "fetch of some shas failed"
say clone_s "$(python3 -c "print(round($(now)-$t0,1))")"

# (3) conflicts: merge-tree of every (head, nightly commit) pair.
clean=0; conflict=0; missing=0
while IFS=$'\t' read -r head base nb why created; do
  [[ -n "$head" ]] || continue
  if ! git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || ! git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
    missing=$((missing+1)); say pair "${head:0:12}" "${base:0:12}" missing; continue
  fi
  if out="$(git -C "$repo" merge-tree --write-tree --name-only "$base" "$head" 2>&1)"; then
    clean=$((clean+1)); say pair "${head:0:12}" "${base:0:12}" clean "$why"
  else
    conflict=$((conflict+1)); say pair "${head:0:12}" "${base:0:12}" CONFLICT "$why" "$(echo "$out" | sed -n '2,6p' | tr '\n' ' ')"
  fi
done < "$pairs"
say conflicts clean "$clean" conflict "$conflict" missing "$missing"

# (2) builds: one source dir (cargo fingerprints hold absolute paths), one target, as a worker's warm cache would be.
src="$work/src"
export CARGO_TARGET_DIR="$work/target"
git -C "$repo" worktree add -q --detach "$src" feat-cmux-next || { say error worktree; exit 1; }
t0=$(now)
git -C "$src" submodule update -q --init --depth 1 ghostty-next || say warn "ghostty-next submodule failed"
say submodule_s "$(python3 -c "print(round($(now)-$t0,1))")"
(cd "$src/cmux-tui" && rustup show active-toolchain) 2>&1 | sed 's/^/HVTB toolchain /'

build() {  # LABEL COMMIT
  local label="$1" commit="$2" t1 t2 rc
  t1=$(now)
  git -C "$src" checkout -q --detach "$commit" && git -C "$src" submodule update -q --init --depth 1 ghostty-next
  t2=$(now)
  (cd "$src/cmux-tui" && cargo build --release -p cmux-tui --bin cmux-tui) > "$work/build.log" 2>&1
  rc=$?
  say build "$label" "${commit:0:12}" rc "$rc" checkout_s "$(python3 -c "print(round($t2-$t1,1))")" \
    build_s "$(python3 -c "print(round($(now)-$t2,1))")" compiled "$(grep -c '^ *Compiling' "$work/build.log")"
  [[ $rc -eq 0 ]] || tail -20 "$work/build.log" | sed 's/^/HVTB log /'
}

merge_commit() {  # BASE HEAD -> a commit of their merge tree, or nothing on a conflict
  local tree
  tree="$(git -C "$repo" merge-tree --write-tree "$1" "$2" 2>/dev/null | head -1)" || return 1
  git -C "$repo" -c user.name=m -c user.email=m@m commit-tree "$tree" -p "$1" -p "$2" -m merge
}

first=1
while IFS=$'\t' read -r head base nb why created; do
  [[ "$why" == "Rust the app has and the change lacks" ]] || continue
  if [[ $first == 1 ]]; then build cold-nightly "$base"; build noop-rebuild "$base"; first=0; fi
  if m="$(merge_commit "$base" "$head")"; then build "warm-merge" "$m"; else say build warm-merge skipped-conflict; fi
done < "$pairs"
say end
