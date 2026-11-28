#!/usr/bin/env bash
# Best-effort format-on-edit for Claude Code and Codex (PostToolUse).
#
# Formats the files an edit touched, the way the pre-commit hook will at commit
# time: Rust with rustfmt (its Cargo package's edition and the nearest
# rustfmt.toml in the checkout, rustfmt's defaults otherwise) and webviews
# files with vp fmt (packages installed with bun when missing). Never blocks
# the edit: a missing formatter or a parse error is a warning on stderr.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || exit 0

payload="$(cat 2>/dev/null || true)"
# One "rust<TAB>edition<TAB>path<TAB>config" (config last: it may be empty) or
# "web<TAB>path" line per file.
plan="$(PAYLOAD="$payload" python3 - "$ROOT" <<'PY'
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
# apply_patch-style tools carry paths only in the patch text.
for match in re.finditer(r"\*\*\* (?:Add|Update) File: ([^\n\\\"]+)", raw):
    paths.add(match.group(1).strip())

def manifest_text(directory):
    try:
        with open(os.path.join(root, directory, "Cargo.toml"), encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None

def parents(directory):
    while True:
        yield directory
        if not directory:
            return
        directory = os.path.dirname(directory)

def edition(package):
    text = manifest_text(package)
    found = re.search(r'^edition\s*=\s*"(\d{4})"', text, re.M)
    if found:
        return found.group(1)
    if re.search(r"^edition\s*(\.\s*workspace\s*=\s*true|=\s*\{\s*workspace\s*=\s*true)", text, re.M):
        for directory in list(parents(package))[1:]:
            workspace = manifest_text(directory)
            if workspace and "[workspace.package]" in workspace:
                section = workspace.split("[workspace.package]", 1)[1].split("\n[", 1)[0]
                found = re.search(r'^edition\s*=\s*"(\d{4})"', section, re.M)
                if found:
                    return found.group(1)
    return "2015"

for path in sorted(paths):
    if os.path.isabs(path):
        path = os.path.relpath(os.path.realpath(path), root)
    path = os.path.normpath(path)
    if path.startswith("..") or not os.path.isfile(os.path.join(root, path)):
        continue
    if path.endswith(".rs"):
        package = next((d for d in parents(os.path.dirname(path))
                        if (manifest_text(d) or "").count("[package]")), None)
        if package is None:
            continue
        config = next((os.path.join(root, d, name) for d in parents(package)
                       for name in ("rustfmt.toml", ".rustfmt.toml")
                       if os.path.isfile(os.path.join(root, d, name))), "")
        print(f"rust\t{edition(package)}\t{path}\t{config}")
    elif path.startswith("webviews/") and re.search(r"\.(m?[jt]sx?|c[jt]s|css|scss|html|json|mdx?)$", path):
        print(f"web\t{path}")
PY
)"
[ -n "$plan" ] || exit 0

rust_lines="$(printf '%s\n' "$plan" | grep '^rust' || true)"
if [ -n "$rust_lines" ]; then
  if ! command -v rustfmt >/dev/null 2>&1; then
    echo "warning: rustfmt is unavailable; edited Rust is unformatted (the pre-commit hook will refuse an agent commit)" >&2
  else
    # An empty config pins rustfmt's defaults, so a stray rustfmt.toml above the
    # checkout never decides the format.
    defaults="$(mktemp "${TMPDIR:-/tmp}/cmux-rustfmt-defaults.XXXXXX")"
    trap 'rm -f "$defaults"' EXIT
    printf '%s\n' "$rust_lines" | while IFS="$(printf '\t')" read -r _ edition path config; do
      rustfmt --edition "$edition" --config-path "${config:-$defaults}" "$ROOT/$path" >/dev/null 2>&1 \
        || echo "warning: rustfmt could not format $path (a syntax error?)" >&2
    done
  fi
fi

web_paths="$(printf '%s\n' "$plan" | sed -n 's/^web\twebviews\///p')"
if [ -n "$web_paths" ]; then
  vp="$ROOT/webviews/node_modules/.bin/vp"
  if [ ! -x "$vp" ] && command -v bun >/dev/null 2>&1; then
    (cd "$ROOT/webviews" && bun install --frozen-lockfile --ignore-scripts >/dev/null 2>&1) || true
  fi
  if [ ! -x "$vp" ]; then
    echo "warning: vp is unavailable; edited webviews files are unformatted (install bun)" >&2
  else
    # shellcheck disable=SC2086 # one path per word; webviews paths have no spaces
    (cd "$ROOT/webviews" && "$vp" fmt $web_paths >/dev/null 2>&1) \
      || echo "warning: vp fmt could not format ${web_paths//$'\n'/ }" >&2
  fi
fi

# A post-edit hook is advisory by design.
exit 0
