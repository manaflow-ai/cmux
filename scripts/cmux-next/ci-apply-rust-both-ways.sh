#!/usr/bin/env bash
# The correctness check for ci_apply.py's daemon lane: run one PR head's affected cargo tests both
# ways, on one host, and compare every test's outcome.
#
#   cmux-ci test --setup rust --timeout 10800 -- bash scripts/cmux-next/ci-apply-rust-both-ways.sh BASE:HEAD [BASE:HEAD...]
#
#   lane   the base tree built first (the warm tree a prebuilt base gives), then the PR's sources
#          checked out over it and `cargo test` run incrementally in the same target dir
#   full   a fresh target dir at HEAD: `cargo test` from clean, as full CI builds it
#
# The crates are scripts/ci/cargo_affected.py's selection for the change (its dependents included).
# Writes $FAST_CHECKS_OUT/results.tsv (one line per pair: base, head, selection, the lane's
# incremental build seconds, the clean build seconds, lane exit, full exit, tests, differing tests)
# and per pair the two sorted outcome lists and a diff. Never run cargo on a laptop: this is a
# fleet step (cmux-ci test).
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"
mkdir -p "$out"
work="$(mktemp -d)"
# The scratch worktrees have no submodules: ghostty-vt-sys builds libghostty-vt from the checkout's
# ghostty-next (both sides use the same one; a PR that moves the gitlink is a full-build change).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next >&2 || true
fi
export CMUX_GHOSTTY_SRC="$root/ghostty-next"
trap 'git -C "$root" worktree prune; rm -rf "$work"' EXIT
printf 'base\thead\tselection\tlane_build_s\tfull_build_s\tlane_exit\tfull_exit\ttests\tdiffering\n' > "$out/results.tsv"

outcomes() { # LOG: "binary::test outcome" lines, sorted
  awk '/Running (unittests )?[^ ]+/ { bin = $NF } /^test .* \.\.\. (ok|FAILED|ignored)/ {
         name = $2; outcome = $NF; print bin "::" name " " outcome }' "$1" | sort
}

n=0
for pair in "$@"; do
  n=$((n + 1))
  base="${pair%%:*}" head="${pair##*:}" tag="$n-${head:0:12}"
  if ! git -C "$root" fetch -q --no-tags --depth=200 origin "$base" "$head"; then
    printf '%s\t%s\tfetch-failed\n' "$base" "$head" >> "$out/results.tsv"; continue
  fi
  wt="$work/wt-$n"
  git -C "$root" worktree add -q --detach "$wt" "$head"
  # include_str! reads ghostty-next by relative path too: point the worktree's empty submodule at it.
  rmdir "$wt/ghostty-next" 2>/dev/null && ln -s "$root/ghostty-next" "$wt/ghostty-next"
  mapfile -t changed < <(git -C "$wt" diff --name-only "$base" "$head")
  read -r -a sel < <(python3 "$wt/scripts/ci/cargo_affected.py" --root "$wt" --changed "${changed[@]}" --format args 2>"$out/$tag.affected.err")
  if [[ ${#sel[@]} -eq 0 ]]; then
    printf '%s\t%s\tnone\n' "$base" "$head" >> "$out/results.tsv"; git -C "$root" worktree remove --force "$wt"; continue
  fi
  echo "== $tag: ${sel[*]}"
  # lane: warm base tree, then the PR applied over it.
  git -C "$wt" checkout -q --detach "$base"
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/lane" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.base.log" 2>&1
  git -C "$wt" checkout -q --detach "$head"
  t0=$SECONDS
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/lane" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.lane-build.log" 2>&1
  lane_build=$((SECONDS - t0))
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/lane" cargo test --locked --no-fail-fast "${sel[@]}") > "$out/$tag.lane.log" 2>&1
  lane_exit=$?
  # full: a clean target dir at the same head.
  t0=$SECONDS
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/full" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.full-build.log" 2>&1
  full_build=$((SECONDS - t0))
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/full" cargo test --locked --no-fail-fast "${sel[@]}") > "$out/$tag.full.log" 2>&1
  full_exit=$?
  outcomes "$out/$tag.lane.log" > "$out/$tag.lane.outcomes"
  outcomes "$out/$tag.full.log" > "$out/$tag.full.outcomes"
  diff "$out/$tag.lane.outcomes" "$out/$tag.full.outcomes" > "$out/$tag.diff"
  differing="$(grep -c '^[<>]' "$out/$tag.diff")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$head" "${sel[*]}" "$lane_build" "$full_build" \
    "$lane_exit" "$full_exit" "$(wc -l < "$out/$tag.full.outcomes" | tr -d ' ')" "$differing" >> "$out/results.tsv"
  rm -rf "$work/full"
  git -C "$root" worktree remove --force "$wt"
done
rm -rf "$work/lane"
cat "$out/results.tsv"
