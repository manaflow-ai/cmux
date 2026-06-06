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
