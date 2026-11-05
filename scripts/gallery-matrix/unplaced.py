#!/usr/bin/env python3
"""Whether a change gallery health routes on reached no gallery entry, so every entry must render.

gallery-health.yml starts on the paths a gallery render reads (its `pull_request` paths). Most of
those outside webviews/src/ are global to every page: a theme, a font, a string catalog the build
reads, a schema the Tailwind theme is generated from, a lockfile, a config, the checker's tools.
touched.ts places a changed file on the entries that import it; a routed file it places on none
would otherwise render nothing and pass with no verdict. A webviews/src/ file no entry reaches
renders nothing, as before: no gallery state shows it.

    python3 scripts/gallery-matrix/unplaced.py WORKFLOW CHANGED_TXT TOUCHED_JSON   # prints true or false
"""

from __future__ import annotations

import json
import re
import sys


def glob_regex(pattern: str) -> re.Pattern[str]:
    """A GitHub paths pattern (`**`, `*`) as a regular expression over one repo path."""
    out, index = "", 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out, index = out + "(?:.*/)?", index + 3
        elif pattern.startswith("**", index):
            out, index = out + ".*", index + 2
        elif pattern[index] == "*":
            out, index = out + "[^/]*", index + 1
        else:
            out, index = out + re.escape(pattern[index]), index + 1
    return re.compile(out + r"\Z")


def routed(path: str, patterns: list[str]) -> bool:
    """GitHub's rule: the last pattern that matches decides, a `!` pattern excluding."""
    hit = False
    for pattern in patterns:
        if glob_regex(pattern.lstrip("!")).match(path):
            hit = not pattern.startswith("!")
    return hit


def pull_request_paths(workflow_text: str) -> list[str]:
    """The `on.pull_request.paths` list, read without a YAML library (the runner's python3 has none)."""
    lines = workflow_text.splitlines()
    start = lines.index("  pull_request:")
    paths: list[str] = []
    inside = False
    for line in lines[start + 1:]:
        if re.match(r"^  \S", line) or re.match(r"^\S", line):
            break
        if line.strip() == "paths:":
            inside = True
            continue
        if inside:
            if line.strip().startswith("#") or not line.strip():
                continue
            item = re.match(r'^\s+- "([^"]+)"\s*$', line)
            if not item:
                break
            paths.append(item.group(1))
    if not paths:
        raise SystemExit("unplaced.py: no pull_request paths in the workflow")
    return paths


def unplaced(patterns: list[str], changed: list[str], touched: dict) -> list[str]:
    """Routed changed files outside webviews/src/ that no touched entry names."""
    placed = {file for files in touched.get("reasons", {}).values() for file in files}
    return [
        path for path in changed
        if routed(path, patterns) and not path.startswith("webviews/src/") and path not in placed
    ]


def main(argv: list[str]) -> int:
    workflow, changed_txt, touched_json = argv[1:4]
    with open(workflow, encoding="utf-8") as handle:
        patterns = pull_request_paths(handle.read())
    with open(changed_txt, encoding="utf-8") as handle:
        changed = [line.strip() for line in handle if line.strip()]
    with open(touched_json, encoding="utf-8") as handle:
        touched = json.load(handle)
    found = unplaced(patterns, changed, touched)
    for path in found[:10]:
        print(f"gallery: {path} reaches no entry; rendering every entry", file=sys.stderr)
    print("true" if found else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
