#!/usr/bin/env bash
# Best-effort post-edit namespace repair for Claude Code and Codex.
#
# Hooks must never block the edit that triggered them. They only inspect Swift
# paths under Packages/, run the reviewed fixer on those paths, and warn when
# the fixer or the scoped lint cannot complete.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || exit 0

payload="$(cat 2>/dev/null || true)"
files_from="$(mktemp "${TMPDIR:-/tmp}/cmux-namespace-files.XXXXXX")"
trap 'rm -f "$files_from"' EXIT

PAYLOAD="$payload" python3 - "$ROOT" > "$files_from" <<'PY'
import json
import os
import re
import sys

root = os.path.realpath(sys.argv[1])
raw = os.environ.get("PAYLOAD", "")
try:
    payload = json.loads(raw)
except (TypeError, ValueError):
    payload = {}

paths = set()
keys = {"file_path", "filePath", "path", "filename", "target_file", "targetFile"}

def visit(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in keys and isinstance(child, str):
                paths.add(child)
            else:
                visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(payload)
# apply_patch-style tools often carry paths only in the patch text.
for match in re.finditer(r"(?:^|[\s'\"`])((?:Packages/)[^\s'\"`]+\.swift)", raw):
    paths.add(match.group(1))

for path in sorted(paths):
    if os.path.isabs(path):
        try:
            path = os.path.relpath(path, root)
        except ValueError:
            continue
    path = os.path.normpath(path)
    if not path.startswith("Packages/") or not path.endswith(".swift"):
        continue
    if os.path.isfile(os.path.join(root, path)):
        print(path)
PY

[ -s "$files_from" ] || exit 0

output="$(cd "$ROOT" && bash scripts/lint-ios-package-conventions.sh \
  --namespace-fix --files-from "$files_from" 2>&1)"
status=$?

if printf '%s\n' "$output" | grep -q '^fixed namespace declarations in '; then
  printf '%s\n' "$output" | grep '^fixed namespace declarations in '
fi

if [ "$status" -ne 0 ]; then
  printf 'warning: scoped namespace autofix could not finish (exit %s); review with ./scripts/lint-ios-package-conventions.sh --namespace-fix\n' "$status" >&2
  printf '%s\n' "$output" | grep -E '^(ERROR|WARN|FAIL|error:)' >&2 || true
fi

# A post-edit hook is advisory by design.
exit 0
