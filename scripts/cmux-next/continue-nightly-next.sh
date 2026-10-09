#!/usr/bin/env bash
# Ask nightly-next to publish an earlier build that Apple accepted after its
# run stopped waiting (cx-f58x). A nightly-next run that waited 40 minutes
# leaves a recovery artifact. Until now only the next promoted push run
# continued it, so publication waited for an unrelated promotion. GitHub runs
# `schedule` triggers only from main's workflow, so cmux-next.yml calls this
# after each green Release compile of feat-cmux-next instead.
#
# This dispatches nightly.yml on nightly-next with nightly_next_continue_only.
# That run builds nothing and makes no Apple submission. It continues the
# newest pending build only when Apple has accepted it, and it publishes
# through the normal guarded path. The dispatch happens only when all of these
# hold:
#   - a completed nightly-next run younger than MAX_AGE_HOURS (default 6)
#     still holds a cmux-nightly-notarization-recovery-* artifact. Apple
#     finishes even slow reviews in about 2 hours, so an older one is final;
#   - no nightly-next workflow_dispatch run started in the last MIN_MINUTES
#     (default 30). This keeps the macOS recovery runner use bounded.
#
# Usage: continue-nightly-next.sh --repo <owner/repo>
# Needs GH_TOKEN with actions: write. Exit 0 when a run was requested or none
# is needed. A failed query or dispatch only warns, because this runs after a
# green compile and must never fail it.
# Env: CMUX_NIGHTLY_NEXT_CONTINUE_MIN_MINUTES, CMUX_NIGHTLY_NEXT_CONTINUE_MAX_AGE_HOURS,
#      CMUX_NOW_EPOCH (tests only).
set -euo pipefail

repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: --repo must be owner/repo" >&2; exit 2; }
min_minutes="${CMUX_NIGHTLY_NEXT_CONTINUE_MIN_MINUTES:-30}"
max_age_hours="${CMUX_NIGHTLY_NEXT_CONTINUE_MAX_AGE_HOURS:-6}"
[[ "$min_minutes" =~ ^[0-9]+$ && "$max_age_hours" =~ ^[0-9]+$ ]] || { echo "error: the limits must be whole numbers" >&2; exit 2; }
now="${CMUX_NOW_EPOCH:-$(date +%s)}"

if ! runs="$(gh api "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=30")"; then
  echo "warning: could not list nightly-next runs; not requesting a continuation" >&2
  exit 0
fi

# Prints "recent-dispatch" or the candidate run ids (completed, young enough).
plan="$(python3 -c '
import json, sys
from datetime import datetime
now, min_minutes, max_age_hours = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
def age(run):
    created = datetime.strptime(run["created_at"], "%Y-%m-%dT%H:%M:%SZ")
    return now - int((created - datetime(1970, 1, 1)).total_seconds())
runs = [r for r in json.loads(sys.stdin.read()).get("workflow_runs", []) if r.get("head_branch") == "nightly-next"]
if any(r.get("event") == "workflow_dispatch" and age(r) < min_minutes * 60 for r in runs):
    print("recent-dispatch")
    sys.exit(0)
for r in runs:
    if r.get("status") == "completed" and age(r) < max_age_hours * 3600:
        print(r["id"])
' "$now" "$min_minutes" "$max_age_hours" <<<"$runs")" || {
  echo "warning: could not read the nightly-next runs; not requesting a continuation" >&2
  exit 0
}

if [[ "$plan" == recent-dispatch ]]; then
  echo "not requesting: a nightly-next dispatch started in the last ${min_minutes} minutes"
  exit 0
fi

pending=""
while read -r run_id; do
  [[ "$run_id" =~ ^[0-9]+$ ]] || continue
  if ! artifacts="$(gh api "repos/$repo/actions/runs/$run_id/artifacts?per_page=100")"; then
    echo "warning: could not list the artifacts of run $run_id" >&2
    continue
  fi
  if python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
sys.exit(0 if any(a["name"].startswith("cmux-nightly-notarization-recovery-") and not a.get("expired")
                  for a in data.get("artifacts", [])) else 1)
' <<<"$artifacts"; then
    pending="$run_id"
    break
  fi
done <<<"$plan"

if [[ -z "$pending" ]]; then
  echo "not requesting: no nightly-next run younger than ${max_age_hours}h holds a pending notarization"
  exit 0
fi
if gh workflow run nightly.yml --repo "$repo" --ref nightly-next -f nightly_next_continue_only=true; then
  echo "requested a nightly-next continuation run (run $pending holds a pending notarization)"
else
  echo "warning: the continuation dispatch failed (nightly-next may predate nightly_next_continue_only)" >&2
fi
exit 0
