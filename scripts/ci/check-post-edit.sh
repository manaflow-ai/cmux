#!/usr/bin/env bash
# Advisory post-edit checks for Claude Code and Codex (PostToolUse): workflow YAML and actionlint,
# new-test registration and god-file growth, on the edited files only (scripts/ci/post_edit_checks.py).
# Never blocks the edit: warnings go to stderr and the exit status is always 0.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || exit 0
[ -f "$ROOT/scripts/ci/post_edit_checks.py" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 -B "$ROOT/scripts/ci/post_edit_checks.py" --root "$ROOT" || true
exit 0
