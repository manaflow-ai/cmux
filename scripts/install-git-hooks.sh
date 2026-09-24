#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs the tracked pre-commit hook (pbxproj normalization and test
# registration) without hiding custom hooks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"
CURRENT_HOOKS="$(git config --get core.hooksPath || true)"
if [[ -n "$CURRENT_HOOKS" && "$CURRENT_HOOKS" != scripts/git-hooks ]]; then
    echo "Existing core.hooksPath is $CURRENT_HOOKS; left unchanged." >&2
    echo "Integrate the tracked pre-commit hook with your hook setup." >&2
    exit 1
fi
if [[ -z "$CURRENT_HOOKS" ]]; then
    DEFAULT_HOOKS="$(git rev-parse --git-path hooks)"
    for hook in "$DEFAULT_HOOKS"/*; do
        [[ -f "$hook" && -x "$hook" && "$hook" != *.sample ]] || continue
        echo "Existing executable hook $hook would be hidden; left unchanged." >&2
        echo "Integrate the tracked hooks with your existing hooks first." >&2
        exit 1
    done
fi
git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/*
echo "==> Git hooks installed (core.hooksPath = scripts/git-hooks)."

# Merge drivers named by .gitattributes have to be defined per clone; git will
# not run a driver it cannot resolve, it just falls back to the default one.
git config merge.xcstrings.name "Xcode string catalog (key-wise three-way merge)"
git config merge.xcstrings.driver "python3 scripts/merge-xcstrings.py %O %A %B %P"
echo "==> .xcstrings merge driver installed (merge.xcstrings.driver)."
