#!/usr/bin/env bash
# Fail a pull request only on a red its own change adds: new_red_only.sh NAME -- CMD [ARG...]
#
# Runs CMD in the merge commit's tree (the working directory). When it fails, runs the same CMD again in a
# worktree of the merge commit's first parent (the base), with the base's own copy of every script it calls. Red
# on the base too: the red is the base's, already fixed forward there (the base tier runs these checks on every
# feat-cmux-next tip), so this warns and passes. Green on the base: the change made it red, and this fails.
# A base that cannot be checked out (no HEAD^1, a shallow clone without it) fails as the change's red.
#
# Why: the cmux-next.yml `checks` job runs these guards only on feat-cmux-next tips, so a pull request that broke
# one merged green and the tip went red (base tier run 46080642938, 2026-11-27: 9 red checks, each from a change
# whose own run never ran the guard). ci/steps.toml runs them on the pull request through this wrapper.
set -uo pipefail
name="${1:?usage: new_red_only.sh NAME -- CMD [ARG...]}"
shift
[[ "${1:-}" == "--" ]] && shift
(( $# > 0 )) || { echo "usage: new_red_only.sh NAME -- CMD [ARG...]" >&2; exit 2; }

"$@"
rc=$?
(( rc == 0 )) && exit 0

base="$(git rev-parse -q --verify 'HEAD^1^{commit}' 2>/dev/null || true)"
if [[ -z "$base" ]]; then
  echo "::error title=$name::red (exit $rc), and no base commit (HEAD^1) to tell whether the base is red too"
  exit "$rc"
fi
tree="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/new-red-only.XXXXXX")"
cleanup() { git worktree remove --force "$tree" >/dev/null 2>&1 || true; }
trap cleanup EXIT
if ! git worktree add --detach "$tree" "$base" >/dev/null 2>&1; then
  echo "::error title=$name::red (exit $rc); the base $base could not be checked out to compare"
  exit "$rc"
fi
echo "--- $name is red here (exit $rc); the same check on the base ${base:0:12}:"
( cd "$tree" && "$@" )
base_rc=$?
if (( base_rc != 0 )); then
  echo "::warning title=$name (red on the base too)::the base ${base:0:12} is red on this check already (exit $base_rc); its fix lands on feat-cmux-next, not in this pull request. Compare the two outputs above for a red this change adds."
  exit 0
fi
echo "::error title=$name::this change turns the check red: the base ${base:0:12} passes it, the merge fails (exit $rc); see the first output above"
exit "$rc"
