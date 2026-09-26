#!/usr/bin/env bash
# Merge the newest main commit with green guards into this branch, resolve
# generated-file conflicts like PR catch-up, then run the local guards and
# label each failure inherited from main or introduced by this branch.
# Use this instead of `git merge origin/main`. Details: scripts/ci/merge_main.py.
#
#   scripts/merge-main.sh              merge the last green main, run the `ci` guards
#   scripts/merge-main.sh --dry-run    only say which commit it would merge
#   scripts/merge-main.sh --tip        merge main's tip even when it is red
#   scripts/merge-main.sh --all-guards run every guard group after the merge
#   scripts/merge-main.sh --strict     exit 3 when this branch introduced a guard failure
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci/merge_main.py" "$@"
