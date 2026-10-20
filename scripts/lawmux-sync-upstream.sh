#!/usr/bin/env bash
# Merge manaflow-ai/cmux main into lawmux main, then run the static checks.
#
#   scripts/lawmux-sync-upstream.sh           merge and verify; push is left to you
#   scripts/lawmux-sync-upstream.sh --push    also push main to origin when checks pass
#   scripts/lawmux-sync-upstream.sh --dry-run only list the upstream commits not yet merged
#
# On a merge conflict the script stops with the merge in progress. Resolve it,
# `git commit`, then rerun the script to finish verification.
set -euo pipefail

UPSTREAM_URL="https://github.com/manaflow-ai/cmux.git"
BRANCH="main"
PUSH=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$UPSTREAM_URL"
fi

echo "==> Fetching upstream and origin..."
git fetch upstream "$BRANCH"
git fetch origin "$BRANCH"

pending="$(git rev-list --count "origin/$BRANCH..upstream/$BRANCH")"
echo "==> $pending upstream commit(s) not in origin/$BRANCH"
if [[ "$DRY_RUN" == 1 ]]; then
  git log --oneline --no-decorate "origin/$BRANCH..upstream/$BRANCH" | head -50
  exit 0
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: working tree has uncommitted changes; commit or stash them first." >&2
  exit 1
fi

# The pbxproj and xcstrings merge drivers come from upstream's hook installer.
if ! git config --get merge.pbxproj-v1.driver >/dev/null; then
  echo "==> Installing upstream merge drivers..."
  ./scripts/install-git-hooks.sh
fi

git switch "$BRANCH"
git merge --ff-only "origin/$BRANCH"

if [[ "$pending" != 0 ]]; then
  echo "==> Merging upstream/$BRANCH..."
  if ! git merge --no-edit "upstream/$BRANCH"; then
    echo >&2
    echo "Merge conflict. Resolve the files above, run 'git commit', then rerun this script." >&2
    exit 1
  fi
fi

echo "==> Updating submodules..."
git submodule update --init --recursive

echo "==> Running static checks..."
python3 scripts/verify-local.py

if [[ "$PUSH" == 1 ]]; then
  git push origin "$BRANCH"
else
  echo
  echo "Done. Build and try it, then push with: git push origin $BRANCH"
fi
