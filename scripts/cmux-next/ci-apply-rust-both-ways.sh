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
# Every test that fails is run once more on its own side (`-- --exact NAME`); one that passes then is
# flaky, and the settled outcome counts it as ok. Writes $FAST_CHECKS_OUT/results.tsv (one line per
# pair: base, head, selection, the lane's incremental build seconds, the clean build seconds, lane
# exit, full exit, tests, tests whose first outcome differs, tests whose settled outcome differs,
# flaky tests on the lane and full side) and per pair the outcome lists and diffs. Only one target
# dir is on disk at a time (two of them filled a runner's disk). Never run cargo on a laptop: this
# is a fleet step (cmux-ci test).
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
out="${FAST_CHECKS_OUT:-$(mktemp -d)}"
mkdir -p "$out"
work="$(mktemp -d -p "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")"
# The scratch worktrees have no submodules: ghostty-vt-sys builds libghostty-vt from the checkout's
# ghostty-next (both sides use the same one; a PR that moves the gitlink is a full-build change).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next >&2 || true
fi
export CMUX_GHOSTTY_SRC="$root/ghostty-next"
trap 'git -C "$root" worktree prune; rm -rf "$work"' EXIT
printf 'base\thead\tselection\tlane_build_s\tfull_build_s\tlane_exit\tfull_exit\ttests\tdiffering\tdiffering_settled\tlane_flaky\tfull_flaky\tbinaries_with_other_counts\n' > "$out/results.tsv"

# The binary is its file name without cargo's hash, so the two target dirs' lists compare.
BIN='/Running (unittests )?[^ ]+/ { bin = $NF; gsub(/[()]/, "", bin); sub(/.*\//, "", bin); sub(/-[0-9a-f]{16}$/, "", bin) }'
outcomes() { # LOG: "binary::test outcome" lines, sorted. A test's line is matched anywhere: tests
  # that start daemons have their children's output land on the same line.
  awk "$BIN"' match($0, /test [^ ]+ \.\.\. (ok|FAILED|ignored)/) {
         split(substr($0, RSTART, RLENGTH), f, " "); print bin "::" f[2] " " f[4] }' "$1" | sort
}
totals() { # LOG: "binary tests" per binary, from libtest's own "test result:" line
  awk "$BIN"' /test result:/ { n = 0; for (i = 2; i <= NF; i++) if ($i ~ /^(passed|failed|ignored);/) n += $(i - 1); print bin, n }' "$1" | sort
}

side() { # SIDE: test the selection in $work/SIDE, retry its failures once, write SIDE.outcomes
  # (first run), SIDE.settled (a failure that passed on retry is ok) and SIDE.flaky; prints the exit
  local s="$1" code names
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/$s" cargo test --locked --no-fail-fast "${sel[@]}") > "$out/$tag.$s.log" 2>&1
  code=$?
  outcomes "$out/$tag.$s.log" > "$out/$tag.$s.outcomes"
  mapfile -t names < <(awk '$2 == "FAILED" { sub(/^[^:]*::/, "", $1); print $1 }' "$out/$tag.$s.outcomes" | sort -u)
  : > "$out/$tag.$s.retry.outcomes"
  if [[ ${#names[@]} -gt 0 ]]; then
    (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/$s" cargo test --locked --no-fail-fast "${sel[@]}" -- --exact "${names[@]}") \
      > "$out/$tag.$s.retry.log" 2>&1
    outcomes "$out/$tag.$s.retry.log" > "$out/$tag.$s.retry.outcomes"
  fi
  awk 'NR == FNR { if ($2 == "ok") passed[$1] = 1; next }
       $2 == "FAILED" && ($1 in passed) { print $1 > "/dev/stderr"; $2 = "ok" } { print }' \
    "$out/$tag.$s.retry.outcomes" "$out/$tag.$s.outcomes" > "$out/$tag.$s.settled" 2> "$out/$tag.$s.flaky"
  echo "$code"
}

n=0
failed=0
for pair in "$@"; do
  n=$((n + 1))
  base="${pair%%:*}" head="${pair##*:}" tag="$n-${head:0:12}"
  depth=()  # --depth only in a checkout that is already shallow, so a full clone stays full
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=200)
  if ! git -C "$root" fetch -q --no-tags ${depth[@]+"${depth[@]}"} origin "$base" "$head"; then
    printf '%s\t%s\tfetch-failed\n' "$base" "$head" >> "$out/results.tsv"; failed=1; continue
  fi
  wt="$work/wt-$n"
  git -C "$root" worktree add -q --detach "$wt" "$head"
  # include_str! reads ghostty-next by relative path too: point the worktree's empty submodule at it.
  rmdir "$wt/ghostty-next" 2>/dev/null && ln -s "$root/ghostty-next" "$wt/ghostty-next"
  mapfile -t changed < <(git -C "$wt" diff --name-only "$base" "$head")
  if ! selection="$(python3 "$wt/scripts/ci/cargo_affected.py" --root "$wt" --changed "${changed[@]}" --format args 2>"$out/$tag.affected.err")"; then
    # A selector that fails is not an empty selection: report it, and fail the run at the end.
    printf '%s\t%s\tselection-failed\n' "$base" "$head" >> "$out/results.tsv"; failed=1
    git -C "$root" worktree remove --force "$wt"; continue
  fi
  read -r -a sel <<< "$selection"
  if [[ ${#sel[@]} -eq 0 ]]; then
    printf '%s\t%s\tnone\n' "$base" "$head" >> "$out/results.tsv"; git -C "$root" worktree remove --force "$wt"; continue
  fi
  echo "== $tag: ${sel[*]}"
  # lane: warm base tree, then the PR applied over it.
  git -C "$wt" checkout -q --detach "$base"
  if ! (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/lane" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.base.log" 2>&1; then
    # No warm baseline, so no comparison: say so instead of reporting zero differing tests.
    printf '%s\t%s\t%s\tbase-build-failed\n' "$base" "$head" "${sel[*]}" >> "$out/results.tsv"; failed=1
    rm -rf "$work/lane"; git -C "$root" worktree remove --force "$wt"; continue
  fi
  git -C "$wt" checkout -q --detach "$head"
  t0=$SECONDS
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/lane" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.lane-build.log" 2>&1
  lane_build=$((SECONDS - t0))
  lane_exit="$(side lane)"
  rm -rf "$work/lane"
  # full: a clean target dir at the same head.
  t0=$SECONDS
  (cd "$wt/cmux-tui" && CARGO_TARGET_DIR="$work/full" cargo test --locked --no-run "${sel[@]}") > "$out/$tag.full-build.log" 2>&1
  full_build=$((SECONDS - t0))
  full_exit="$(side full)"
  diff "$out/$tag.lane.outcomes" "$out/$tag.full.outcomes" > "$out/$tag.diff"
  diff "$out/$tag.lane.settled" "$out/$tag.full.settled" > "$out/$tag.settled.diff"
  ndiff() { grep '^[<>]' "$1" | cut -c3- | cut -d' ' -f1 | sort -u | wc -l | tr -d ' '; } # tests, not lines
  differing="$(ndiff "$out/$tag.diff")"
  settled="$(ndiff "$out/$tag.settled.diff")"
  # A stale incremental build would run another set of tests: compare each binary's own count.
  diff <(totals "$out/$tag.lane.log") <(totals "$out/$tag.full.log") > "$out/$tag.totals.diff"
  counts="$(grep -c '^<' "$out/$tag.totals.diff")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$head" "${sel[*]}" "$lane_build" "$full_build" \
    "$lane_exit" "$full_exit" "$(wc -l < "$out/$tag.full.outcomes" | tr -d ' ')" "$differing" "$settled" \
    "$(wc -l < "$out/$tag.lane.flaky" | tr -d ' ')" "$(wc -l < "$out/$tag.full.flaky" | tr -d ' ')" "$counts" >> "$out/results.tsv"
  rm -rf "$work/full"
  git -C "$root" worktree remove --force "$wt"
done
rm -rf "$work/lane"
cat "$out/results.tsv"
exit "$failed"
