#!/usr/bin/env bash
# Advisory post-edit checks for Claude Code and Codex (PostToolUse): workflow YAML and actionlint,
# new-test registration and god-file growth, on the edited files only (scripts/ci/post_edit_checks.py).
# Prints one JSON object on stdout: PostToolUse additionalContext with the findings, else {}.
# Never blocks the edit: the exit status is always 0.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
out=""
if [ -n "$ROOT" ] && [ -f "$ROOT/scripts/ci/post_edit_checks.py" ] && command -v python3 >/dev/null 2>&1; then
    out="$(python3 -B "$ROOT/scripts/ci/post_edit_checks.py" --root "$ROOT")" || out=""
fi
case "$out" in
    "{"*) printf '%s\n' "$out" ;;
    *) printf '{}\n' ;;
esac
exit 0
