#!/usr/bin/env bash
# Run bun, webview or browser test files at a pushed commit on Blacksmith Linux
# (.github/workflows/linux-tests.yml), instead of on a shared dev box.
#
#   ./scripts/run-linux-tests.sh [--ref SHA] [--runner 4|8|16|32] [--no-bundles]
#                                [--timeout SECONDS] [--wait] FILE...
#
# FILE is a repository path (webviews/test/foo.test.tsx, web/lib/x.test.ts) or a
# path under webviews/ (test/foo.test.tsx), in a package that tests with bun test.
# --ref defaults to HEAD, which must be the head of a branch pushed here. Prints
# the run URL; --wait waits for the run (through glaeda-gh when it is installed)
# and exits with its result.
#
# From a branch without this file:
#   gh api -H 'Accept: application/vnd.github.raw' repos/manaflow-ai/cmux/contents/scripts/run-linux-tests.sh | bash -s -- ...
set -euo pipefail

repo="${CMUX_LINUX_TESTS_REPO:-manaflow-ai/cmux}"
ref=""
runner=8
bundles=true
timeout=600
wait=false
files=()
usage() {
  cat <<'USAGE'
usage: run-linux-tests.sh [--ref SHA] [--runner 4|8|16|32] [--no-bundles] [--timeout SECONDS] [--wait] FILE...
Runs bun, webview or browser test files at a pushed branch head on Blacksmith Linux (linux-tests.yml).
USAGE
}
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a value" >&2; usage >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) need_value "$@"; ref="$2"; shift 2 ;;
    --runner) need_value "$@"; runner="$2"; shift 2 ;;
    --no-bundles) bundles=false; shift ;;
    --timeout) need_value "$@"; timeout="$2"; shift 2 ;;
    --wait) wait=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; files+=("$@"); break ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done
[ "${#files[@]}" -gt 0 ] || { echo "error: name at least one test file" >&2; usage >&2; exit 2; }
case "$runner" in 4|8|16|32) ;; *) echo "error: --runner is 4, 8, 16 or 32" >&2; exit 2 ;; esac
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "error: --timeout is whole seconds" >&2; exit 2; }

if [ -z "$ref" ]; then
  ref="$(git rev-parse HEAD)"
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "note: uncommitted changes are not tested; the run tests $ref as pushed" >&2
  fi
fi
sha="$(gh api "repos/$repo/commits/$ref" --jq .sha 2>/dev/null)" || {
  echo "error: $ref is not on $repo; push it first" >&2
  exit 2
}
# The lane runs only a branch head of this repository (the workflow refuses anything else).
if [ -z "$(gh api "repos/$repo/commits/$sha/branches-where-head" --jq '.[0].name' 2>/dev/null)" ]; then
  echo "error: $sha is not the head of a branch on $repo; push it to a branch and test that head" >&2
  exit 2
fi

dispatch_id="lt-$(date -u +%Y%m%dT%H%M%S)-$$"
gh workflow run linux-tests.yml --repo "$repo" --ref main \
  -f ref="$sha" -f files="${files[*]}" -f runner="blacksmith-${runner}vcpu-ubuntu-2404" \
  -f build_bundles="$bundles" -f file_timeout="$timeout" -f dispatch_id="$dispatch_id" >/dev/null

# The dispatch API returns no run id; the run's name carries dispatch_id. Bounded: about a minute.
run_id=""
for _ in $(seq 1 12); do
  run_id="$(gh api "repos/$repo/actions/workflows/linux-tests.yml/runs?event=workflow_dispatch&per_page=20" \
    --jq ".workflow_runs[] | select(.display_title | contains(\"$dispatch_id\")) | .id" 2>/dev/null | head -n 1)" || true
  [ -n "$run_id" ] && break
  sleep 5
done
if [ -z "$run_id" ]; then
  echo "dispatched $dispatch_id at $sha, but its run did not appear yet: https://github.com/$repo/actions/workflows/linux-tests.yml" >&2
  exit 1
fi
url="https://github.com/$repo/actions/runs/$run_id"
echo "$url"
[ "$wait" = true ] || exit 0

if command -v glaeda-gh >/dev/null 2>&1; then
  glaeda-gh wait run "$repo/$run_id" --until "done" --timeout 4200 >/dev/null || true
else
  gh run watch "$run_id" --repo "$repo" --interval 300 >/dev/null || true
fi
status="$(gh api "repos/$repo/actions/runs/$run_id" --jq .status)"
if [ "$status" != completed ]; then
  echo "still $status after the wait: $url" >&2
  exit 1
fi
conclusion="$(gh api "repos/$repo/actions/runs/$run_id" --jq .conclusion)"
echo "$conclusion: $url"
if [ "$conclusion" != success ]; then
  gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null | grep -E '::error|\(fail\)|✗|error:' | head -n 40 || true
  exit 1
fi
