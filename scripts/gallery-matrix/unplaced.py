#!/usr/bin/env python3
"""Whether a change gallery health routes on reached no gallery entry, so every entry must render.

gallery-health.yml starts on the paths a gallery render reads (its `pull_request` paths). Most of
those outside webviews/src/ are global to every page: a theme, a font, a string catalog the build
reads, a schema the Tailwind theme is generated from, a lockfile, a config, the checker's tools.
touched.ts places a changed file on the entries that import it; a routed file it places on none
would otherwise render nothing and pass with no verdict. A webviews/src/ source file (.ts, .tsx,
.js, .mjs, .css) no entry reaches renders nothing, as before: no gallery state shows it. Any other
webviews/src/ file an entry does not place renders every entry: an asset touched.ts did not trace
(an image a page loads some other way) or a string catalog gen-strings.mjs does not list. A catalog it
lists, and a What's New highlight, touched.ts places on the entries that import the table built from it
(derivedTables: a page's generated/strings.json, the feature tips), so it renders those entries only,
or none when no entry reads that table (touched.json `derived`).

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
    """The `on.pull_request.paths` list, read without a YAML library (the runner's python3 has none), or the
    `on.push.paths` list when the workflow has no pull_request trigger (gallery health renders feat-cmux-next
    pushes only since 2026-11-21; both lists are the same when both exist)."""
    lines = workflow_text.splitlines()
    start = lines.index("  pull_request:") if "  pull_request:" in lines else lines.index("  push:")
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
        raise SystemExit("unplaced.py: no pull_request or push paths in the workflow")
    return paths


SOURCE_SUFFIXES = (".ts", ".tsx", ".js", ".mjs", ".css")


def unplaced(patterns: list[str], changed: list[str], touched: dict) -> list[str]:
    """Routed changed files no touched entry names, except webviews/src/ source files and the sources
    touched.ts routed through the tables built from them (`derived`: exact, so none is unplaced)."""
    placed = {file for files in touched.get("reasons", {}).values() for file in files} | set(touched.get("derived", []))
    return [
        path for path in changed
        if routed(path, patterns)
        and not (path.startswith("webviews/src/") and path.endswith(SOURCE_SUFFIXES))
        and path not in placed
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
