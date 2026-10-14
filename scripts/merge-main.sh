#!/usr/bin/env bash
# Merge the newest main commit with green guards into this branch, resolve
# generated-file conflicts. With --guards it also runs the
# local guards and labels each failure inherited from main or introduced by
# this branch; by default it does not, since pushing runs them in CI.
# Use this instead of `git merge origin/main`. Details: scripts/ci/merge_main.py.
#
#   scripts/merge-main.sh              merge the last green main
#   scripts/merge-main.sh --guards     also run the `ci` guards locally
#   scripts/merge-main.sh --dry-run    only say which commit it would merge
#   scripts/merge-main.sh --tip        merge main's tip even when it is red
#   scripts/merge-main.sh --all-guards run every guard group after the merge
#   scripts/merge-main.sh --strict     exit 3 when this branch introduced a guard failure
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci/merge_main.py" "$@"
