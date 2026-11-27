#!/usr/bin/env bash
# Chief behavior A/B: which good Chief behavior a change lost (or gained).
# It builds the Chief eval runner (Native/OptChat/optchat-chief examples/
# chief_eval.rs: the real native engine and production prompt) at two refs,
# runs the same model cases (evals/cases/*.json from THIS checkout, so both
# sides answer the same questions) on both on one worker, and diffs them with
# the harness's `chief_eval diff`: pass rate per group before and after, and the cases
# that regressed, improved, are new or are missing. A regressed case is a good
# behavior the after ref lost.
#
# Why a measurement and not only the chief-evals workflow: that workflow's
# model cases need a tailnet join from a GitHub runner, which has been refused
# (token exchange 403) on every run since at least 2026-10-30, so it scored
# deterministic cases only and its baseline diff never ran. Fleet workers reach
# the model route directly.
#
# Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --os linux --label measure \
#     --script scripts/measure/chief-evals.sh --ref HARNESS_SHA \
#     --arg=base_url=http://100.120.48.119:4016 --arg=before=BASE_SHA --arg=after=HEAD_SHA \
#     [--arg=repeat=3] [--arg=only=links-] --timeout 5400
# before= and after= are full commit SHAs; after= left out scores one ref (a
# baseline); after= equal to before= is an A/A run: the noise floor.
# base_url= is a Claude route that needs no credential (SR2 signs requests
# itself). repeat=N runs each model case N times (pass fraction per case).
# Output: CHIEF-EVALS-MACHINE, CHIEF-EVALS-BUILD per ref, the per-group table
# per ref, then CHIEF-EVALS-DIFF (diff.json, one line) and diff.md. Files under
# .build/chief-evals: before/, after/ (each chief_eval's summary.json) and
# after/diff.md, after/diff.json.
set -euo pipefail
base_url=""
before=""
after=""
repeat=1
only=""
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    before=*) before="${arg#before=}" ;;
    after=*) after="${arg#after=}" ;;
    repeat=*) repeat="${arg#repeat=}" ;;
    only=*) only="${arg#only=}" ;;
    *) echo "chief-evals.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "chief-evals.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "chief-evals.sh: before=SHA (40 hex) is required" >&2; exit 2; }
[[ -z "$after" || "$after" =~ ^[0-9a-f]{40}$ ]] || { echo "chief-evals.sh: after=SHA (40 hex)" >&2; exit 2; }
[[ "$repeat" =~ ^[1-9]$ ]] || { echo "chief-evals.sh: repeat=1..9" >&2; exit 2; }
[[ "$only" =~ ^[a-z0-9-]*$ ]] || { echo "chief-evals.sh: only=ID_PREFIX" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chief-evals"
cases="$root/Native/OptChat/optchat-chief/evals/cases"
remove_trees() {
  for side in before after; do
    [[ -d "$work/src-$side" ]] && git worktree remove --force "$work/src-$side" 2>/dev/null || true
  done
  git worktree prune 2>/dev/null || true
}
trap remove_trees EXIT
remove_trees
rm -rf "$work"
mkdir -p "$work"
ulimit -n 8192 2>/dev/null || ulimit -n "$(ulimit -Hn)"
echo "CHIEF-EVALS-MACHINE host=$(hostname) cores=$(getconf _NPROCESSORS_ONLN) os=$(uname -sr) harness_rev=$(git rev-parse HEAD) before=$before after=${after:-none} repeat=$repeat only=${only:-all}"
export OPTCHAT_ANTHROPIC_BASE_URL="$base_url"

# One cargo target dir for both refs, so the second builds incrementally.
export CARGO_TARGET_DIR="$root/.build/chief-evals-target"
build_side() {
  local side="$1" sha="$2" src="$work/src-$1"
  local depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet ${depth[@]+"${depth[@]}"} origin "$sha"
  git worktree add --quiet --detach "$src" "$sha"
  (cd "$src/Native/OptChat/optchat-chief" && cargo build --release --locked --example chief_eval)
  cp "$CARGO_TARGET_DIR/release/examples/chief_eval" "$work/chief_eval-$side"
  echo "CHIEF-EVALS-BUILD $side $sha"
}
# The harness's own runner scores both sides (`chief_eval diff`): a refusal
# by the model route (HTTP 429/5xx) is infra, not a lost behavior, even at
# refs whose runner predates that rule.
(cd "$root/Native/OptChat/optchat-chief" && cargo build --release --locked --example chief_eval)
cp "$CARGO_TARGET_DIR/release/examples/chief_eval" "$work/chief_eval-harness"
echo "CHIEF-EVALS-BUILD harness $(git rev-parse HEAD)"
build_side before "$before"
"$work/chief_eval-before" preflight || { echo "CHIEF-EVALS the route $base_url does not answer Claude requests" >&2; exit 1; }
if [[ -n "$after" && "$after" != "$before" ]]; then
  build_side after "$after"
elif [[ -n "$after" ]]; then
  cp "$work/chief_eval-before" "$work/chief_eval-after"
  echo "CHIEF-EVALS-BUILD after $after (same as before: A/A)"
fi

run_side() {
  local side="$1"; shift
  local flags=(--cases "$cases" --repeat "$repeat" --jobs 24 --out "$work/$side")
  [[ -n "$only" ]] && flags+=(--only "$only")
  echo "== $side"
  # Cases come from this checkout; each side's default person.md is its own
  # ref's evals/person.md (its worktree stays until this script exits).
  "$work/chief_eval-$side" "${flags[@]}" "$@" || true
}
run_side before
if [[ -n "$after" ]]; then
  run_side after
  if [[ -f "$work/after/rows.jsonl" ]] && "$work/chief_eval-harness" diff "$work/before" "$work/after" >/dev/null; then
    echo "CHIEF-EVALS-DIFF $(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' "$work/after/diff.json")"
    cat "$work/after/diff.md"
  else
    echo "CHIEF-EVALS no diff.json: the after run did not finish" >&2
    exit 1
  fi
fi
