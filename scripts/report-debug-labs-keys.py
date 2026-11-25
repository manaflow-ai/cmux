#!/usr/bin/env python3
"""List cmux NEXT's Debug Settings and Labs keys older than a week, with who added them and the case for each.

A Debug key is a toggle or choice tunable (`Tunable<T>.toggle(` / `.choice(` under
Packages/macOS/CmuxNext/Sources): a design or feature switch shown in Debug Settings. A Labs key is a
row of schemas/settings/source/labs.json. Numbers and colors are design tokens, not switches, and are
left out. Each key's age is the day its literal first appeared on this branch, from one pass over
the history (the checkout needs full history). The case for a key (flip it on, delete its code, or
keep it with a reason) lives in scripts/debug-labs-keys.json; a key with no case is listed as such.

The daily debug-labs-keys-report workflow turns the JSON into one issue. Flipping a default needs
Leo's word on that flag; the report only lists.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
SOURCES = "Packages/macOS/CmuxNext/Sources"
LABS = "schemas/settings/source/labs.json"
CASES = "scripts/debug-labs-keys.json"
CASE_KINDS = ("flip", "delete", "keep")
MIN_AGE_DAYS = 7

TUNABLE_RE = re.compile(r'Tunable<([^>]+)>\.(toggle|choice)\(\s*"([^"]+)"')
DEFAULT_RE = re.compile(r"\bdefault:\s*([^,)\n]+)")
PR_RE = re.compile(r"\(#(\d+)\)\s*$")


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, check=True).stdout


def debug_keys() -> list[dict[str, Any]]:
    """Every toggle or choice tunable: key, value type, default and where it is declared."""
    keys = []
    files = git("grep", "-l", "-E", r"Tunable<[^>]+>\.(toggle|choice)\(", "--", f"{SOURCES}/*.swift").split()
    for source in sorted(files):
        text = (REPO / source).read_text()
        for match in TUNABLE_RE.finditer(text):
            # The default is the declaration's own `default:`, before the next declaration starts.
            rest = text[match.end():]
            following = TUNABLE_RE.search(rest)
            default = DEFAULT_RE.search(rest[: following.start() if following else len(rest)])
            keys.append({
                "key": match.group(3),
                "kind": "debug",
                "type": match.group(1),
                "default": default.group(1).strip() if default else "",
                "source": f"{source}:{text.count(chr(10), 0, match.start()) + 1}",
            })
    return keys


def labs_keys() -> list[dict[str, Any]]:
    keys = []
    for section in json.loads((REPO / LABS).read_text()).get("lists", []):
        for row in section.get("rows", []):
            keys.append({
                "key": row["key"],
                "kind": "labs",
                "type": row.get("kind", ""),
                "default": json.dumps(row.get("default")),
                "source": LABS,
            })
    return keys


def first_added(keys: list[str], ref: str = "HEAD") -> dict[str, dict[str, str]]:
    """The oldest commit whose added lines carry each key's quoted literal: one pass, oldest first."""
    wanted = {f'"{key}"': key for key in keys}
    found: dict[str, dict[str, str]] = {}
    shallow = set(_shallow_commits())
    log = subprocess.Popen(
        ["git", "log", "--reverse", "-p", "-U0", "--no-renames", "--no-color",
         "--format=@@@%H %ad %an\t%s", "--date=short", ref, "--", f"{SOURCES}/*.swift", LABS],
        cwd=REPO, stdout=subprocess.PIPE, text=True, errors="replace",
    )
    commit: dict[str, str] = {}
    assert log.stdout is not None
    for line in log.stdout:
        if line.startswith("@@@"):
            head, _, subject = line[3:].rstrip("\n").partition("\t")
            sha, date, author = head.split(" ", 2)
            pr = PR_RE.search(subject)
            commit = {"commit": sha, "added": date, "author": author, "subject": subject,
                      "pr": int(pr.group(1)) if pr else None, "beforeHistory": sha in shallow}
            continue
        if not line.startswith("+") or line.startswith("+++") or '"' not in line:
            continue
        for literal in re.findall(r'"[^"]+"', line):
            key = wanted.get(literal)
            if key and key not in found:
                found[key] = commit
    log.wait()
    if log.returncode:
        raise RuntimeError(f"git log exited {log.returncode}")
    return found


def _shallow_commits() -> list[str]:
    path = Path(git("rev-parse", "--git-path", "shallow").strip())
    path = path if path.is_absolute() else REPO / path
    return path.read_text().split() if path.exists() else []


def load_cases() -> dict[str, dict[str, str]]:
    cases = json.loads((REPO / CASES).read_text())
    for key, case in cases.items():
        if case.get("case") not in CASE_KINDS or not case.get("why"):
            raise ValueError(f"{CASES}: {key} needs a case ({', '.join(CASE_KINDS)}) and a why")
    return cases


def build_report(keys, added, cases, today: datetime.date, min_age: int = MIN_AGE_DAYS) -> dict[str, Any]:
    rows = []
    for item in keys:
        origin = added.get(item["key"])
        if origin is None:
            continue
        age = (today - datetime.date.fromisoformat(origin["added"])).days
        if age <= min_age:
            continue
        case = cases.get(item["key"], {})
        rows.append({**item, **origin, "ageDays": age,
                     "case": case.get("case", ""), "why": case.get("why", "")})
    order = {"flip": 0, "delete": 1, "": 2, "keep": 3}
    rows.sort(key=lambda row: (order[row["case"]], row["kind"] != "labs", -row["ageDays"], row["key"]))
    present = {item["key"] for item in keys}
    return {
        "minAgeDays": min_age,
        "today": today.isoformat(),
        "keys": rows,
        # A case whose key is gone from the code: the case should go too.
        "staleCases": sorted(key for key in cases if key not in present),
    }


def render_text(report: dict[str, Any]) -> str:
    lines = [f"{len(report['keys'])} Debug and Labs keys older than {report['minAgeDays']} days"]
    for row in report["keys"]:
        lines.append(f"{row['case'] or 'no case':6}  {row['key']}  default {row['default']}  "
                     f"{row['ageDays']}d  #{row['pr'] or '?'}  {row['why']}")
    for key in report["staleCases"]:
        lines.append(f"stale case (key gone): {key}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--min-age", type=int, default=MIN_AGE_DAYS, help="days a key must be older than")
    parser.add_argument("--ref", default="HEAD")
    args = parser.parse_args(argv)
    try:
        keys = debug_keys() + labs_keys()
        report = build_report(keys, first_added([item["key"] for item in keys], args.ref),
                              load_cases(), datetime.date.today(), args.min_age)
    except Exception as error:  # The workflow says so on the issue instead of an empty all-clear.
        if args.json:
            print(json.dumps({"error": f"Debug and Labs key report failed: {error}"}))
        else:
            print(f"Debug and Labs key report failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2) if args.json else render_text(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
