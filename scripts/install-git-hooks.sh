#!/usr/bin/env bash
# Point this clone's git at scripts/git-hooks/ for tracked, reviewed hooks.
# Idempotent: re-running just rewrites the same config line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"
git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/*
echo "==> Git hooks installed (core.hooksPath = scripts/git-hooks)."

# Merge drivers named by .gitattributes have to be defined per clone; git will
# not run a driver it cannot resolve, it just falls back to the default one.
git config merge.xcstrings.name "Xcode string catalog (key-wise three-way merge)"
git config merge.xcstrings.driver "python3 scripts/merge-xcstrings.py %O %A %B %P"
echo "==> .xcstrings merge driver installed (merge.xcstrings.driver)."
