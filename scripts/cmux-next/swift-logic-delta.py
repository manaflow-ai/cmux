#!/usr/bin/env python3
"""How much a change moves the Swift logic count: swift-logic-lines.py at a base and a head revision, and the
difference.

  python3 -I scripts/cmux-next/swift-logic-delta.py --base BASE --head HEAD          the report, as Markdown
  python3 -I scripts/cmux-next/swift-logic-delta.py --base BASE --head HEAD --json   one JSON object (below)
  ... --repo ROOT   --top N (the declarations listed, 15 by default)

For a pull request, BASE is the merge base (`git merge-base origin/feat-cmux-next HEAD`), so the report is the
pull request's own share and not what landed on the base branch since it forked. It is a report: it exits 0 whatever
the delta (a growth is no failure), and nonzero only when it cannot count.

  ... --gate --body-file FILE   the ratchet (.github/workflows/swift-logic-ratchet.yml): exits 1 when the head's
                                swift_logic_lines + mirror_lines is above the base's and FILE (the pull request's
                                description) has no line `Swift-growth: <reason>`; 0 otherwise, and 0 with a notice
                                when it cannot count (a count that cannot be made never blocks)

Goal swift-share-falls: the report alone did not stop the count rising (493,843 on 2026-11-13, about 512,000 on
2026-11-25), so growth now needs a stated reason, as `size:` does for the bundle budget.

Both counts are swift-logic-lines.count() (its scope, table and rules), with its facts cache: the second count reads
only the Swift files whose blobs differ, so a delta costs about one count. Each counted declaration contributes to a
row (swift_logic_lines, mirror_lines) what that script's `--sites ROW` lists for it; a declaration is keyed by (row,
file, kind, name, ordinal in the file), so a moved or renamed one shows as one removed and one added, as the count
itself treats it.

JSON (--json): {"base": sha, "head": sha, "rows": {row: {"base": n, "head": n, "delta": n}}, "packages": {module:
{row: delta}} (deltas that are not 0), "added": [{"row", "path", "line", "declaration", "lines"}] (the declarations
whose count rose, largest first, at most --top), "removed_lines": {row: the lines of declarations whose count fell}}.

Tests: scripts/cmux-next/tests/test_swift_logic_lines.py (SwiftLogicDeltaTests).
"""

from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_logic():
    """swift-logic-lines.py next to this file."""
    name = "cmux_next_swift_logic_lines"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "swift-logic-lines.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


LOGIC = load_logic()
# A site's text is `kind name #ordinal: N of SPAN lines (...)` (swift-logic-lines count_units); a name may hold a `:`
# (`extension [String:Int]`), so the label runs to the last `: N of`.
_SITE = re.compile(r"^(?P<label>.*): (?P<n>\d+) of \d+ lines \(")


def contributions(found) -> dict[tuple[str, str, str], tuple[int, int]]:
    """{(row, path, label): (line, lines)} of a swift-logic-lines Count: what each declaration adds to each row."""
    out: dict[tuple[str, str, str], tuple[int, int]] = {}
    for row in LOGIC.ROWS:
        for path, line, text in found.sites[row]:
            m = _SITE.match(text)
            if m is None:
                raise ValueError(f"unexpected site text from swift-logic-lines: {text!r}")
            out[(row, path, m.group("label"))] = (line, int(m.group("n")))
    return out


def delta(base, head, top: int = 15) -> dict:
    """The report (docstring, JSON) of two swift-logic-lines Counts."""
    b, h = base.json(), head.json()
    rows = {row: {"base": b["rows"][row], "head": h["rows"][row], "delta": h["rows"][row] - b["rows"][row]}
            for row in LOGIC.ROWS}
    packages: dict[str, dict[str, int]] = {}
    for module in sorted(set(b["packages"]) | set(h["packages"])):
        moved = {row: h["packages"].get(module, {}).get(row, 0) - b["packages"].get(module, {}).get(row, 0)
                 for row in LOGIC.ROWS}
        moved = {row: n for row, n in moved.items() if n}
        if moved:
            packages[module] = moved
    was, now = contributions(base), contributions(head)
    added = []
    removed = collections.Counter()
    for key in set(was) | set(now):
        row, path, label = key
        before = was.get(key, (0, 0))[1]
        line, after = now.get(key, (was.get(key, (0, 0))[0], 0))
        if after > before:
            added.append({"row": row, "path": path, "line": line, "declaration": label, "lines": after - before})
        elif before > after:
            removed[row] += before - after
    added.sort(key=lambda a: (-a["lines"], a["row"], a["path"], a["line"]))
    return {"base": base.sha, "head": head.sha, "rows": rows,
            "packages": dict(sorted(packages.items(), key=lambda kv: (-sum(kv[1].values()), kv[0]))),
            "added": added[:top], "removed_lines": {row: removed[row] for row in LOGIC.ROWS}}


def markdown(report: dict) -> str:
    """The report as Markdown (a job summary or a PR comment)."""
    out = [f"### Swift logic delta, {report['base'][:11]}..{report['head'][:11]}", "",
           "| row | base | head | delta |", "| --- | ---: | ---: | ---: |"]
    for row, r in report["rows"].items():
        out.append(f"| {row} | {r['base']} | {r['head']} | {r['delta']:+d} |")
    if report["packages"]:
        out += ["", "| module | " + " | ".join(LOGIC.ROWS) + " |", "| --- |" + " ---: |" * len(LOGIC.ROWS)]
        for module, moved in report["packages"].items():
            out.append(f"| {module} | " + " | ".join(f"{moved.get(row, 0):+d}" for row in LOGIC.ROWS) + " |")
    if report["added"]:
        out += ["", "Declarations whose count rose:", ""]
        for a in report["added"]:
            out.append(f"- `{a['path']}:{a['line']}` {a['declaration']}: +{a['lines']} {a['row']}")
    return "\n".join(out) + "\n"


SHORT = {"swift_logic_lines": "swift_logic", "mirror_lines": "mirror"}
STATUS_LARGEST = 3


def _declaration(a: dict) -> str:
    """`File.swift:LINE` Decl (+n): an added entry for the status line (the ordinal only when it is not #0)."""
    label = a["declaration"].removesuffix(" #0")
    return f"`{a['path'].rsplit('/', 1)[-1]}:{a['line']}` {label} (+{a['lines']})"


def status(report: dict) -> str:
    """The pull request status comment's `swift-logic` section (scripts/ci/pr_status.py): one line, then the
    per-module deltas and every declaration that grew in a collapsed <details>."""
    rows = report["rows"]
    total = sum(r["delta"] for r in rows.values())
    parts = ", ".join(f"{SHORT.get(row, row)} {r['delta']:+,d}" for row, r in rows.items())
    line = (f"Swift logic + mirror: **{total:+,d} lines** ({parts}) against the merge base "
            f"`{report['base'][:7]}`")
    largest = [a for a in report["added"] if a["row"] == "swift_logic_lines"] or report["added"]
    if largest:
        line += "; largest: " + ", ".join(_declaration(a) for a in largest[:STATUS_LARGEST])
    body = markdown(report).split("\n", 2)[2]  # without the `###` heading and its blank line
    return (f"{line}\n<details><summary>Swift logic + mirror by module and declaration (the ratchet: a rise needs a `Swift-growth:` line; "
            f"scripts/cmux-next/swift-logic-delta.py)</summary>\n\n{body.rstrip()}\n</details>\n")


def not_counted(reason: str) -> str:
    """The `swift-logic` section when the count could not be made: the line says so, nothing fails."""
    reason = " ".join(reason.split())[:300]
    return f"Swift logic + mirror: not counted ({reason})\n"


# `Swift-growth: <reason>` on a line of its own in the description (case-insensitive, any leading space or `-`).
GROWTH_LINE = re.compile(r"^[ \t>*-]*swift-growth:[ \t]*(?P<why>\S.*?)[ \t]*$", re.IGNORECASE | re.MULTILINE)


def growth_reason(body: str) -> str:
    """The description's `Swift-growth:` reason, or "" when it has none."""
    m = GROWTH_LINE.search(body or "")
    return m.group("why") if m else ""


def gate(report: dict, body: str) -> tuple[int, str]:
    """(exit code, message) of the ratchet on REPORT: 1 when swift_logic_lines + mirror_lines rose and BODY names no
    `Swift-growth:` reason."""
    total = sum(r["delta"] for r in report["rows"].values())
    if total <= 0:
        return 0, f"Swift logic + mirror: {total:+,d} lines against {report['base'][:7]}; the ratchet holds."
    why = growth_reason(body)
    if why:
        return 0, (f"Swift logic + mirror: {total:+,d} lines against {report['base'][:7]}, with the reason "
                   f"\"Swift-growth: {why}\".")
    largest = ", ".join(_declaration(a) for a in report["added"][:STATUS_LARGEST])
    return 1, (f"Swift logic + mirror grows by {total:+,d} lines against {report['base'][:7]}"
               + (f" (largest: {largest})" if largest else "")
               + ". Move the logic to Rust, or add a line `Swift-growth: <reason>` to the description (editing it "
               "re-runs this check). Goal swift-share-falls; scripts/cmux-next/swift-logic-delta.py --gate.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--base", required=True, help="the merge base of the change")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--top", type=int, default=15, help="declarations listed (default 15)")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--status", action="store_true",
                        help="the PR status comment's section; exits 0 and says 'not counted' when it cannot count")
    parser.add_argument("--gate", action="store_true",
                        help="the ratchet: exit 1 on growth without a `Swift-growth:` line in --body-file")
    parser.add_argument("--body-file", type=Path, default=None, help="the pull request's description (--gate)")
    parser.add_argument("--no-cache", action="store_true")
    args = parser.parse_args(argv)
    top = ["git", "rev-parse", "--show-toplevel"]
    try:
        repo = Path(args.repo).resolve() if args.repo else Path(
            subprocess.run(top, capture_output=True, text=True, check=True).stdout.strip())
        base = LOGIC.count(repo, args.base, cache=not args.no_cache)
        head = LOGIC.count(repo, args.head, cache=not args.no_cache)
        report = delta(base, head, args.top)
    except Exception as error:  # noqa: BLE001 - a status line reports any failure to count, it never fails a job
        if args.gate:
            print(f"::notice title=Swift logic ratchet::not counted, so not judged: {type(error).__name__}: "
                  f"{' '.join(str(error).split())[:300]}")
            return 0
        if not args.status:
            raise
        print(not_counted(f"{type(error).__name__}: {error}"), end="")
        return 0
    if args.gate:
        body = args.body_file.read_text(errors="replace") if args.body_file and args.body_file.exists() else ""
        code, message = gate(report, body)
        print(markdown(report), end="")
        print(("::error title=Swift logic ratchet::" if code else "") + message)
        return code
    if args.status:
        print(status(report), end="")
    else:
        print(json.dumps(report, sort_keys=True) if args.json else markdown(report), end="\n" if args.json else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
