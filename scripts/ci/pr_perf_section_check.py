#!/usr/bin/env python3
"""Fail a performance pull request whose description has no before/after table.

    pr_perf_section_check.py --body-file BODY --paths-file PATHS [--title T] [--labels a,b]

A pull request is a performance change when it carries the `perf` label, or when its title or
description uses one of TRIGGER_WORDS (perf, performance, latency, faster, speed, speedup) as a
word. Near-misses do not count: "perform", "performed", "perfect", "speedometer". Text inside HTML
comments, fenced code blocks and inline code is ignored, so the template's own hint and a quoted
path such as `perf_harness.py` never trigger it.

Such a pull request records its deltas in a `## Performance` section holding a Markdown table with
the columns metric | before | after | delta | harness or run link, and at least one row with every
cell filled in (placeholders such as `<before>`, `TBD`, `-` or `?` are empty). When there are no
numbers to record (the change is not about speed), a line `No perf numbers: <why>` inside the
Performance section says so instead.

A docs-only change (every path under docs/ or a Markdown file) is exempt. Prints GitHub annotations
and, on a failure, the template. Exits 1 on a missing or incomplete section, 0 otherwise (2 on bad
input).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PERF_LABELS = {"perf", "performance"}
# The one list of trigger words. Each entry is a regex matched as a whole word, case-insensitively.
TRIGGER_WORDS = (
    r"perf",
    r"performance",
    r"latency",
    r"latencies",
    r"faster",
    r"speed",
    r"speeds",
    r"speed[- ]?ups?",
)
TRIGGER = re.compile(r"(?<!\w)(?:" + "|".join(TRIGGER_WORDS) + r")(?![\w])", re.IGNORECASE)
# A fenced block, or an unclosed fence to the end of the body.
FENCE = re.compile(r"^\s{0,3}(```|~~~).*?(?:^\s{0,3}\1|\Z)", re.DOTALL | re.MULTILINE)
COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
INLINE_CODE = re.compile(r"`[^`\n]+`")
URL = re.compile(r"https?://\S+")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
SECTION_TITLE = re.compile(r"^(?:\W*\s*)?performance\b", re.IGNORECASE)
NO_NUMBERS = re.compile(r"^\s*(?:>\s*)*(?:[-*]\s+)?(?:\*\*)?No perf numbers(?:\*\*)?[ \t]*:[ \t]*(?:\*\*)?[ \t]*(?P<why>.*)$",
                        re.IGNORECASE | re.MULTILINE)
# An empty or template cell (a URL autolink such as <https://...> is a real value, not a placeholder).
PLACEHOLDER = re.compile(r"^(?:|[-–—?.…]+|n/?a|tbd|todo|xx+|<(?!https?://)[^>]*>|\.\.\.)$", re.IGNORECASE)


def has_reason(text: str) -> bool:
    """A `No perf numbers: <why>` line with a real reason: not empty, short, or a placeholder."""
    for match in NO_NUMBERS.finditer(text):
        why = re.sub(r"<[^>]*>|[*_`]", "", match.group("why")).strip()
        if len(why) >= 4 and not PLACEHOLDER.match(why):
            return True
    return False
COLUMNS = ("metric", "before", "after", "delta", "harness")

TEMPLATE = """## Performance

| metric | before | after | delta | harness or run link |
| --- | --- | --- | --- | --- |
| <what you measured, e.g. sidebar open p50> | <number> | <number> | <change, e.g. -38%> | <harness name or run URL> |"""


def is_docs_only(paths: list[str]) -> bool:
    """Every changed path is documentation; an empty list is not docs-only."""
    return bool(paths) and all(p.startswith("docs/") or p.lower().endswith((".md", ".mdx")) for p in paths)


def prose(text: str) -> str:
    """The text a reader sees as prose: no comments, code blocks, inline code or URLs."""
    text = COMMENT.sub(" ", text or "")
    text = FENCE.sub(" ", text)
    text = INLINE_CODE.sub(" ", text)
    return URL.sub(" ", text)


def trigger(title: str, body: str, labels: set[str]) -> str:
    """Why this is a performance change, or "" when it is not."""
    hit = PERF_LABELS & {l.lower() for l in labels}
    if hit:
        return f"label `{sorted(hit)[0]}`"
    for where, text in (("title", title), ("description", body)):
        match = TRIGGER.search(prose(text))
        if match:
            return f"the word \"{match.group(0)}\" in the {where}"
    return ""


def section(body: str) -> str | None:
    """The text of the Performance section (to the next heading at its level or above), or None."""
    lines = FENCE.sub("", COMMENT.sub("", body or "")).splitlines()
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if not m or not SECTION_TITLE.match(m.group(2)):
            continue
        level = len(m.group(1))
        end = len(lines)
        for j in range(i + 1, len(lines)):
            n = HEADING.match(lines[j])
            if n and len(n.group(1)) <= level:
                end = j
                break
        return "\n".join(lines[i + 1:end])
    return None


def cells(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", line)]


def column_index(header: list[str]) -> dict[str, int] | None:
    """Map each required column to its position, or None when one is missing."""
    names = [re.sub(r"[*_`]", "", h).strip().lower() for h in header]
    found: dict[str, int] = {}
    for key in COLUMNS:
        for i, name in enumerate(names):
            if i in found.values():
                continue
            if key == "harness" and ("harness" in name or re.search(r"\brun\b", name)):
                found[key] = i
                break
            if key != "harness" and re.match(rf"^{key}\b", name):
                found[key] = i
                break
    return found if len(found) == len(COLUMNS) else None


SEPARATOR = re.compile(r"^\s*:?-{3,}:?\s*$")


def tables(lines: list[str]):
    """Each Markdown table in the lines: (header cells, data rows). The separator row must have
    as many cells as the header."""
    for i in range(len(lines) - 1):
        if "|" not in lines[i] or "|" not in lines[i + 1]:
            continue
        header, separator = cells(lines[i]), cells(lines[i + 1])
        if len(separator) != len(header) or not all(SEPARATOR.match(c) for c in separator):
            continue
        rows = []
        for line in lines[i + 2:]:
            if "|" not in line:
                break
            rows.append(cells(line))
        yield header, rows


def table_problems(header: list[str], rows: list[list[str]]) -> list[str]:
    index = column_index(header)
    if index is None:
        return ["the table needs the columns metric | before | after | delta | harness or run link"]
    if not rows:
        return ["the table has no rows"]
    issues = []
    for n, row in enumerate(rows, 1):
        empty = [k for k, at in index.items() if at >= len(row) or PLACEHOLDER.match(row[at].strip())]
        if empty:
            issues.append(f"row {n} has no {', '.join(empty)}")
    return issues


def problems(text: str) -> list[str]:
    """What the Performance section is missing; empty when one of its tables is complete. When none
    is, the problems of the first table that has the required columns (else the first table)."""
    found = [table_problems(header, rows) for header, rows in tables(text.splitlines())]
    if not found:
        return ["the section has no before/after table"]
    if any(not issues for issues in found):
        return []
    columned = [issues for issues in found if "needs the columns" not in issues[0]]
    return (columned or found)[0]


def check(title: str, body: str, labels: set[str], paths: list[str]) -> tuple[int, str]:
    if is_docs_only(paths):
        return 0, "Docs-only change: no Performance table needed."
    why = trigger(title, body, labels)
    if not why:
        return 0, "Not a performance change: no Performance table needed."
    text = section(body)
    if text is None:
        return 1, f"Performance change ({why}) and the description has no `## Performance` section."
    if has_reason(text):
        return 0, f"Performance change ({why}); its Performance section says why it has no numbers."
    issues = problems(text)
    if issues:
        return 1, f"Performance change ({why}); the Performance section is incomplete: {'; '.join(issues)}."
    return 0, f"Performance change ({why}); the Performance table is complete."


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--body-file", type=Path, required=True)
    ap.add_argument("--paths-file", type=Path, required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--labels", default="")
    a = ap.parse_args(argv)
    try:
        body = a.body_file.read_text(encoding="utf-8")
        paths = [p.strip() for p in a.paths_file.read_text(encoding="utf-8").splitlines() if p.strip()]
    except OSError as error:
        print(f"::error::pr perf section check: {error}")
        return 2
    labels = {l.strip() for l in a.labels.split(",") if l.strip()}
    code, message = check(a.title, body, labels, paths)
    if code == 0:
        print(message)
        return 0
    print(f"::error title=No Performance table::{message} Record the before/after numbers from the same "
          "harness, or write `No perf numbers: <why>` under the heading.")
    print("Add this to the description (editing it re-runs the check):\n\n" + TEMPLATE)
    return 1


if __name__ == "__main__":
    sys.exit(main())
