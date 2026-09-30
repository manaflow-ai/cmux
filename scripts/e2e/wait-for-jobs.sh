#!/usr/bin/env bash
# Wait until the named jobs of this workflow run finish, and fail unless every
# one succeeded. Lets a job start (and sit out its runner queue, and do its
# setup) in parallel with the jobs it depends on, instead of `needs:`-ing
# them. Checks every 30 s: a dozen-minute build costs about 30 API calls.
#
# Usage: wait-for-jobs.sh <budget-seconds> <job-name>...
# Env: GH_TOKEN (actions: read), GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT.
set -euo pipefail
budget="${1:?budget seconds}"
shift
(( $# > 0 )) || { echo "usage: $0 <budget-seconds> <job-name>..." >&2; exit 2; }
deadline=$(( $(date +%s) + budget ))
url="${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100"

while :; do
  verdict="$(curl -fsS -H "Authorization: Bearer ${GH_TOKEN:?GH_TOKEN is required}" \
      -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null \
    | python3 -c '
import json, sys
wanted = sys.argv[1:]
jobs = {j["name"]: j for j in json.load(sys.stdin)["jobs"]}
states = []
for name in wanted:
    job = jobs.get(name)
    if job is None or job["status"] != "completed":
        print("wait"); sys.exit()
    states.append((name, job["conclusion"]))
bad = [f"{n}={c}" for n, c in states if c != "success"]
print("fail " + " ".join(bad) if bad else "ok")
' "$@" 2>/dev/null || echo wait)"
  case "$verdict" in
    ok) echo "[wait-for-jobs] $* succeeded"; exit 0 ;;
    fail*) echo "::error::${verdict#fail } (this job needs them)"; exit 1 ;;
  esac
  if (( $(date +%s) >= deadline )); then
    echo "::error::[infra-preflight] $* did not finish within ${budget}s"
    exit 1
  fi
  sleep 30
done
