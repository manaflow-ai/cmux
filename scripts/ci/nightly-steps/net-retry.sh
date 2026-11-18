#!/usr/bin/env bash
# Run one network fetch with bounded retries and backoff, so a slow or dropped link costs a retry,
# never the nightly.
#
#   scripts/ci/nightly-steps/net-retry.sh [--tries N] [--timeout S] -- CMD [ARGS...]
#
# It lives in nightly-steps/ so an older build tree gets it with the other new step scripts
# ("Add the workflow commit's new step scripts to an older build tree"); callers name it by
# their own directory. A git command goes through scripts/ci/git_fetch_retry.py (when the tree
# has it; else the plain loop below): each try gets git's low-speed abort, a time limit
# (S seconds, default 600) and a cleanup of the partial packs and locks a killed fetch leaves behind.
# Any other command (npm install, curl without its own --retry, ...) is re-run after 10 s, then 30 s,
# then 60 s. Exits with the last try's status.
#
# Why: on 2026-11-18 NEXT nightly run 44232805509 died in "Assemble the Computer Use helper" when one
# `git clone` of cmux-cua stalled for 9 minutes on the signer's link (curl 56, exit 128) with no retry;
# the feed then lagged the newest landing by 684 minutes. tests/test_ci_nightly_network_fetch_retry.py
# fails when a nightly step fetches over the network without this helper or another named retry.
set -euo pipefail

tries=3
timeout=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tries) tries="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "usage: net-retry.sh [--tries N] [--timeout S] -- CMD [ARGS...]" >&2; exit 2 ;;
  esac
done
[[ $# -gt 0 ]] || { echo "usage: net-retry.sh [--tries N] [--timeout S] -- CMD [ARGS...]" >&2; exit 2; }
[[ "$tries" =~ ^[1-9][0-9]*$ && "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "net-retry: --tries and --timeout take positive integers" >&2; exit 2; }

git_retry="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/git_fetch_retry.py"
if [[ "$(basename "$1")" == git && -f "$git_retry" ]] && command -v python3 >/dev/null 2>&1; then
  # The repository whose partial packs a failed try may leave: `git -C DIR ...`'s DIR, else here.
  repo_arg=.
  [[ "${2:-}" == -C && -n "${3:-}" ]] && repo_arg="$3"
  repo="$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null || (cd "$repo_arg" && pwd))"
  exec python3 "$git_retry" \
    --tries "$tries" --timeout "$timeout" --repo "$repo" -- "$@"
fi

backoff=(10 30 60)
status=0
for ((attempt = 1; attempt <= tries; attempt++)); do
  status=0
  "$@" && exit 0 || status=$?
  if ((attempt < tries)); then
    delay="${backoff[$((attempt - 1))]:-60}"
    echo "net-retry: '$1' failed with $status (try $attempt of $tries); retrying in ${delay}s" >&2
    sleep "$delay"
  fi
done
echo "net-retry: '$1' failed $tries times; last status $status" >&2
exit "$status"
