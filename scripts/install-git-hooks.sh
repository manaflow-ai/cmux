#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Installs the normalizer and committed-source pre-push checks without a build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"
CURRENT_HOOKS="$(git config --get core.hooksPath || true)"
if [[ -n "$CURRENT_HOOKS" && "$CURRENT_HOOKS" != scripts/git-hooks ]]; then
    echo "Existing core.hooksPath is $CURRENT_HOOKS; left unchanged." >&2
    echo "Chain scripts/git-hooks/pre-push from your hook, preserving its stdin." >&2
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
echo "==> Git hooks installed: pre-commit normalization and pre-push static checks."
