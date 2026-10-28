#!/bin/bash
# Re-run the nightly-next tip's nightly when its newest run ended cancelled.
#
# The tick requests a promotion only for a commit that is not on nightly-next yet,
# so a tip whose run was cancelled was never built again: the owned-pool rescue
# cancelled run 40340830337 (e22f9384) at 2026-10-26 14:36Z to move a queued job,
# lost the re-run to a rate limit, and the tick then logged "already on
# nightly-next" every half hour. A nightly is never cancelled on purpose once
# started (a newer tip builds alongside it), so a cancelled tip run is one to
# finish: its failed and cancelled jobs are re-run, at most MAX_ATTEMPTS attempts
# in all.
#
# The re-run itself is scripts/ci/nightly_next_rerun.sh's: it re-runs the build picker when a
# job left without a runner (on any label) takes its runner from that pick and the re-run is
# safe, else the failed jobs.
#
#   nightly_next_cancelled_tip.sh REPO
# Needs gh (GH_TOKEN with actions: write) and git with an `origin` for REPO.
set -euo pipefail

repo="${1:?usage: nightly_next_cancelled_tip.sh OWNER/REPO}"
max_attempts="${MAX_ATTEMPTS:-3}"

line="$(git ls-remote origin refs/heads/nightly-next)"
tip="${line%%[[:space:]]*}"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "nightly-next tip: unreadable; nothing to check"; exit 0; }

# The tip's push runs of nightly.yml, newest first: id, status, conclusion, attempt.
runs="$(gh api "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&head_sha=$tip&per_page=10" \
  --jq '.workflow_runs | sort_by(.id) | reverse | .[] | "\(.id) \(.status) \(.conclusion // "-") \(.run_attempt)"')"
if [[ -z "$runs" ]]; then
  echo "nightly-next tip ${tip:0:12}: no nightly run yet"
  exit 0
fi
if grep -qv ' completed ' <<<"$runs"; then
  echo "nightly-next tip ${tip:0:12}: a nightly run is building"
  exit 0
fi
read -r id _ conclusion attempt <<<"$(head -n1 <<<"$runs")"
if [[ "$conclusion" != cancelled ]]; then
  echo "nightly-next tip ${tip:0:12}: newest run $id ended $conclusion"
  exit 0
fi
if (( attempt >= max_attempts )); then
  echo "::warning title=nightly-next tick::the tip ${tip:0:12}'s run $id was cancelled on attempt $attempt of $max_attempts; not re-run again"
  exit 0
fi

exec bash "$(dirname "$0")/nightly_next_rerun.sh" "$repo" "$id" "$attempt" "$tip" "the tip ${tip:0:12}'s run $id"
