# shellcheck shell=bash
# Sourced, not run. measure_fetch_commit ROOT SHA [DEPTH]: makes SHA's commit (and DEPTH-1 parents) present in ROOT's
# checkout, for a measure script that runs a before/after pair.
#
# A fleet step's source is a shallow tree of the step's own ref with no `origin` remote (step-source-shallow-v1), so a
# plain `git fetch origin SHA` there fails with "'origin' does not appear to be a git repository" and the before arm
# never runs: scripts/measure/hang-collector-note-stall.sh died that way on an exclusive Mac after 4 h in the queue
# (cmux#58752's bench, 2026-11-26). So origin first, then the public repository (step-source-public-v1), as
# app-at-commit.sh already did. A depth flag only in a checkout that is already shallow: never turn a full clone
# shallow (tests/test_ci_no_shallow_dev_fetch.py).
measure_fetch_commit() {
  local root="$1" sha="$2" want="${3:-1}" depth=() remote
  local tip="$sha"
  (( want > 1 )) && tip="$sha~$((want - 1))"
  git -C "$root" cat-file -e "$tip^{commit}" 2>/dev/null && return 0
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth="$want")
  for remote in origin "${CMUX_MEASURE_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}"; do
    [[ "$remote" == origin ]] && ! git -C "$root" remote get-url origin >/dev/null 2>&1 && continue
    git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} "$remote" "$sha" && return 0
  done
  echo "measure_fetch_commit: cannot fetch $sha from origin or ${CMUX_MEASURE_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}" >&2
  return 1
}
