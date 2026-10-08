#!/usr/bin/env bash
# Ask main's nightly.yml (job promote-nightly-next) to move nightly-next to a
# feat-cmux-next commit, but only once that commit is buildable as a nightly:
#   1. its cmux-tui tree is published (verified the way the nightly resolves
#      it: pin-cmux-tui.sh resolve-newest-published, limited to one commit), and
#   2. its cmux-next.yml push run has a successful "cmux-next Release compile
#      (Xcode 26)" job (main's promote job checks this again).
# Both finish asynchronously, so each side asks when its half completes:
#
#   --sha <sha> --release-compile-green
#       cmux-next.yml, after the Release compile of <sha> passed. Requests <sha>
#       if its tree is published; otherwise the artifacts side asks later.
#   --tree-ready <sha>
#       cmux-tui-artifacts.yml, once the tree of <sha> is published. Requests
#       the newest feat-cmux-next commit whose Release compile passed and whose
#       tree key is the same (a later app-only commit shares it), so a commit
#       whose own artifacts run was replaced by a newer push is not lost.
#
# Why: the nightly runs the TIP's nightly.yml. A tip whose tree is unpublished
# made it fall back to an older published commit, which the tip's workflow
# may not be able to build (it skips commits whose nightly.yml differs), so
# nightly-next runs 37767816879 and 37769010617 failed. A promoted commit with
# a published tree is built at the tip, by its own workflow, with its own
# daemon. Main's promote job ignores a request that does not move forward.
#
# Usage: request-nightly-next.sh --repo <owner/repo> (--sha <sha> --release-compile-green | --tree-ready <sha>)
# Run from a checkout whose HEAD is <sha>. Needs GH_TOKEN with actions: write
# (and actions: read for --tree-ready). Exit 0 when a commit was requested or
# none is ready yet, 2 on bad usage, 1 on an API failure.
# Env: CMUX_NIGHTLY_NEXT_RUN_WINDOW (default 30) recent push runs searched.
set -euo pipefail

sha="" repo="" mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --tree-ready) sha="${2:-}"; mode=tree-ready; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --release-compile-green) mode=release-compile-green; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$mode" ]] || { echo "error: pass --sha <sha> --release-compile-green or --tree-ready <sha>" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the commit must be 40 lowercase hex characters" >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: --repo must be owner/repo" >&2; exit 2; }
window="${CMUX_NIGHTLY_NEXT_RUN_WINDOW:-30}"
[[ "$window" =~ ^[1-9][0-9]?$ ]] || { echo "error: CMUX_NIGHTLY_NEXT_RUN_WINDOW must be 1 to 99" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
head="$(git rev-parse HEAD)"
[[ "$head" == "$sha" ]] || { echo "error: the checkout is at $head, not $sha" >&2; exit 2; }

required_job="cmux-next Release compile (Xcode 26)"

# A commit whose nightly.yml lacks the NIGHTLY_NEXT_NOTARY_PAUSED gate would
# notarize even while the pause is on (cx-f58x), so it is never promoted.
has_notary_gate() { # <sha>
  git show "$1:.github/workflows/nightly.yml" 2>/dev/null | grep -q NIGHTLY_NEXT_NOTARY_PAUSED
}

request() { # <sha>
  if ! has_notary_gate "$1"; then
    echo "not promoting ${1:0:12}: its nightly.yml has no NIGHTLY_NEXT_NOTARY_PAUSED gate"
    return 1
  fi
  gh workflow run nightly.yml --repo "$repo" --ref main -f promote_nightly_next_sha="$1"
  echo "requested nightly-next promotion of $1 (published cmux-tui tree, green Release compile)"
}

# 1. The tree, exactly as the nightly will resolve it. Never dispatches a
# publisher here: cmux-tui-artifacts.yml publishes every feat-cmux-next push.
if ! resolved="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CMUX_TUI_TREE_DISPATCH=0 \
    CMUX_TUI_TREE_SEARCH_COMMITS=1 bash "$script_dir/pin-cmux-tui.sh" resolve-newest-published 2>&1)"; then
  printf '%s\n' "$resolved"
  echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet"
  exit 0
fi
key="$(sed -n 's/^key=//p' <<<"$resolved" | head -1)"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' "$resolved" >&2; echo "error: the resolver printed no tree key" >&2; exit 1; }

if [[ "$mode" == release-compile-green ]]; then
  request "$sha" || true
  exit 0
fi

# 2. --tree-ready: the newest green push run on feat-cmux-next whose commit has
# this tree key. Runs are newest first; promotion only moves forward.
runs="$(gh api --paginate --slurp \
  "repos/$repo/actions/workflows/cmux-next.yml/runs?event=push&branch=feat-cmux-next&per_page=$window")"
while read -r run_id run_sha; do
  [[ "$run_id" =~ ^[0-9]+$ && "$run_sha" =~ ^[0-9a-f]{40}$ ]] || continue
  if [[ "$run_sha" != "$sha" ]]; then
    git cat-file -e "$run_sha^{commit}" 2>/dev/null \
      || git fetch -q --no-tags --depth=1 origin "$run_sha" 2>/dev/null \
      || { echo "skipping ${run_sha:0:12}: could not fetch it" >&2; continue; }
    run_key="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$run_sha" 2>/dev/null)" || continue
    [[ "$run_key" == "$key" ]] || continue
  fi
  jobs="$(gh api --paginate --slurp "repos/$repo/actions/runs/$run_id/jobs?filter=latest&per_page=100")"
  has_notary_gate "$run_sha" || continue
  if python3 -c '
import json, sys
name = sys.argv[1]
pages = json.loads(sys.stdin.read())
ok = any(j.get("name") == name and j.get("status") == "completed" and j.get("conclusion") == "success"
         for page in pages for j in page.get("jobs", []))
sys.exit(0 if ok else 1)
' "$required_job" <<<"$jobs"; then
    request "$run_sha"
    exit 0
  fi
done < <(python3 -c '
import json, sys
seen = set()
for page in json.loads(sys.stdin.read()):
    for run in page.get("workflow_runs", []):
        sha = run.get("head_sha")
        if run.get("head_branch") == "feat-cmux-next" and run.get("event") == "push" and sha not in seen:
            seen.add(sha)
            print(run["id"], sha)
' <<<"$runs" | head -n "$window")
echo "not promoting: no recent feat-cmux-next push with tree $key has a successful \"$required_job\" yet; cmux-next.yml requests it when that job passes"
