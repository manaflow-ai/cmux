#!/usr/bin/env python3
"""Leo's UI removals stay removed: fail when an element on the removed-UI list is back in the tree.

Leo, 2026-11-25 (ask-9e3c3b10a7): "why are random things getting introduced..." Each element he asked to
remove is a row in scripts/cmux-next/removed-ui.json: what it was, his words, the ask, the change that removed
it, and a `pattern` (a Python regex for a marker only that element has: its component name, class, test id or
string key) with the `paths` to search. This walks the tracked files under each row's paths (tests, docs,
snapshots and string catalogs are not read: a test may name the element to assert it is gone) and names every
line where a marker is back.

Bringing one back on purpose: give its row `"restored": "Leo, YYYY-MM-DD: \"...\""` (his words asking for it
back) in the same change; that row is then skipped. Adding a row: the pattern must match nothing at the base
(`--check-row ID` prints its hits).

  python3 -I scripts/cmux-next/check-removed-ui.py [--root DIR] [--list FILE] [--json]
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
LIST = "scripts/cmux-next/removed-ui.json"
# The paths a change must touch for the step to route: the list, this script and its test; the rows' own paths
# are read from the list (ci/steps.toml names the trees they cover).
INPUTS = (LIST, "scripts/cmux-next/check-removed-ui.py", "tests/test_check_removed_ui.py")
REQUIRED = ("id", "what", "leo", "ask", "date", "removed_by", "pattern", "paths")
# A test may name a removed element to prove it is gone; docs and catalogs record history.
SKIP = re.compile(
    r"(^|/)(tests?|__tests__|__snapshots__|docs?|fixtures?)/"
    r"|\.(test|spec)\.[cm]?[jt]sx?$|Tests?\.swift$|\.md$|\.xcstrings$|\.snap$"
)
TEXT_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".css", ".html", ".swift", ".rs", ".json", ".toml", ".py")


def load(path):
    with open(path, encoding="utf-8") as f:
        rows = json.load(f)
    problems = []
    seen = set()
    for i, row in enumerate(rows):
        missing = [k for k in REQUIRED if not row.get(k)]
        if missing:
            problems.append(f"row {i} ({row.get('id', '?')}): missing {', '.join(missing)}")
            continue
        if row["id"] in seen:
            problems.append(f"row {i}: duplicate id {row['id']}")
        seen.add(row["id"])
        try:
            row["_re"] = re.compile(row["pattern"])
        except re.error as e:
            problems.append(f"{row['id']}: bad pattern: {e}")
    return rows, problems


def tracked(root, paths):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *paths], capture_output=True, check=True)
    return [p for p in out.stdout.decode().split("\0") if p and p.endswith(TEXT_EXT) and not SKIP.search(p)]


def hits(root, row):
    found = []
    for rel in tracked(root, row["paths"]):
        try:
            with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
                for n, line in enumerate(f, 1):
                    if row["_re"].search(line):
                        found.append((rel, n, line.strip()[:160]))
        except FileNotFoundError:  # sparse checkout
            continue
    return found


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--list", default=None)
    ap.add_argument("--check-row", default=None, help="print one row's hits and exit")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    rows, problems = load(a.list or os.path.join(a.root, LIST))
    for p in problems:
        print(f"::error title=removed-ui list::{p}")
    if problems:
        return 1
    back = []
    checked = 0
    for row in rows:
        if a.check_row and row["id"] != a.check_row:
            continue
        if row.get("restored"):
            print(f"skip {row['id']}: restored ({row['restored']})")
            continue
        checked += 1
        for rel, n, text in hits(a.root, row):
            back.append({"id": row["id"], "file": rel, "line": n, "text": text})
            print(
                f"::error file={rel},line={n},title=Removed UI is back: {row['id']}::"
                f"{row['what']} was removed on Leo's ask ({row['ask']}, {row['date']}: {row['leo']}) by "
                f"{row['removed_by']}. Remove it again, or add \"restored\": \"Leo, DATE: ...\" to its row in {LIST}."
            )
    if a.json:
        print(json.dumps({"checked": checked, "back": back}))
    elif not back:
        print(f"removed-ui: {checked} removed elements checked, none back")
    return 1 if back else 0


if __name__ == "__main__":
    sys.exit(main())
