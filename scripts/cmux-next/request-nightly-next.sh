#!/usr/bin/env bash
# Ask main's nightly.yml (job promote-nightly-next) to move nightly-next to a
# feat-cmux-next commit, but only once that commit is buildable as a nightly:
#   1. its cmux-tui tree is published (verified the way the nightly resolves
#      it, pin-cmux-tui.sh resolve-newest-published limited to this commit), and
#   2. its cmux-next.yml push run has a successful "cmux-next Release compile
#      (Xcode 26)" job (main's promote job checks this again).
# Both finish asynchronously, so both workflows call this script when their
# half completes: cmux-next.yml after the Release compile (pass
# --release-compile-green), cmux-tui-artifacts.yml once the tree is published.
# Whichever finishes last sees the other done and asks.
#
# Why: the nightly runs the TIP's nightly.yml. A tip whose tree is unpublished
# made it fall back to an older published commit, which the tip's workflow
# may not be able to build (it skips commits whose nightly.yml differs), so
# nightly-next runs 37767816879 and 37769010617 failed. A promoted commit with
# a published tree is built at the tip, by its own workflow, with its own
# daemon.
#
# Usage: request-nightly-next.sh --sha <40 hex> --repo <owner/repo> [--release-compile-green]
# Run from a checkout whose HEAD is <sha>. Needs GH_TOKEN with actions: write
# (and actions: read without --release-compile-green). Exit 0 when the commit
# was requested or is not ready yet, 2 on bad usage, 1 on an API failure.
set -euo pipefail

sha="" repo="" release_green=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --release-compile-green) release_green=true; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: --sha must be 40 lowercase hex characters" >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: --repo must be owner/repo" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
head="$(git rev-parse HEAD)"
[[ "$head" == "$sha" ]] || { echo "error: the checkout is at $head, not $sha" >&2; exit 2; }

required_job="cmux-next Release compile (Xcode 26)"

# 1. The tree, exactly as the nightly will resolve it. Never dispatches a
# publisher here: cmux-tui-artifacts.yml publishes every feat-cmux-next push.
if ! resolved="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CMUX_TUI_TREE_DISPATCH=0 \
    CMUX_TUI_TREE_SEARCH_COMMITS=1 bash "$script_dir/pin-cmux-tui.sh" resolve-newest-published 2>&1)"; then
  printf '%s\n' "$resolved"
  echo "not promoting ${sha:0:12}: its cmux-tui tree is not published yet; cmux-tui-artifacts.yml requests it after publishing"
  exit 0
fi

# 2. The Release compile of this exact push.
if [[ "$release_green" != true ]]; then
  runs="$(gh api --paginate --slurp \
    "repos/$repo/actions/workflows/cmux-next.yml/runs?event=push&branch=feat-cmux-next&head_sha=$sha&per_page=100")"
  green=false
  while read -r run_id; do
    [[ "$run_id" =~ ^[0-9]+$ ]] || continue
    jobs="$(gh api --paginate --slurp "repos/$repo/actions/runs/$run_id/jobs?filter=latest&per_page=100")"
    if python3 -c '
import json, sys
name = sys.argv[1]
pages = json.loads(sys.stdin.read())
ok = any(j.get("name") == name and j.get("status") == "completed" and j.get("conclusion") == "success"
         for page in pages for j in page.get("jobs", []))
sys.exit(0 if ok else 1)
' "$required_job" <<<"$jobs"; then
      green=true
      break
    fi
  done < <(python3 -c '
import json, sys
sha = sys.argv[1]
for page in json.loads(sys.stdin.read()):
    for run in page.get("workflow_runs", []):
        if run.get("head_sha") == sha and run.get("head_branch") == "feat-cmux-next" and run.get("event") == "push":
            print(run["id"])
' "$sha" <<<"$runs")
  if [[ "$green" != true ]]; then
    echo "not promoting ${sha:0:12}: no successful \"$required_job\" yet; cmux-next.yml requests it when that job passes"
    exit 0
  fi
fi

gh workflow run nightly.yml --repo "$repo" --ref main -f promote_nightly_next_sha="$sha"
echo "requested nightly-next promotion of $sha (published cmux-tui tree, green Release compile)"
