#!/usr/bin/env bash
# Refresh the repository's primary main worktree and require the build checkout
# to contain that exact current base before compiling.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
common_dir="$(git rev-parse --git-common-dir)"
case "$common_dir" in /*) ;; *) common_dir="$repo_root/$common_dir" ;; esac
main_path=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) candidate="${line#worktree }" ;;
    branch\ refs/heads/main) main_path="$candidate" ;;
  esac
done < <(git worktree list --porcelain)

if [[ -n "$main_path" ]]; then
  if [[ -n "$(git -C "$main_path" status --porcelain)" ]]; then
    echo "error: primary main checkout is dirty: $main_path" >&2
    exit 2
  fi
  git -C "$main_path" fetch origin main --prune
  git -C "$main_path" checkout main >/dev/null
  git -C "$main_path" pull --ff-only origin main
else
  git fetch origin main --prune
fi

if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "error: build checkout is stale; HEAD does not contain current origin/main" >&2
  echo "error: rebase or recreate this worktree from origin/main, then retry" >&2
  exit 2
fi
printf 'Build base verified: %s contains origin/main at %s\n' "$repo_root" "$(git rev-parse origin/main)"
