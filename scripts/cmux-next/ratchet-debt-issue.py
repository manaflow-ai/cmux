#!/usr/bin/env python3
"""Keeps one open issue (label ratchet-debt) of the style ratchets' warnings.

The cmux-next checks job writes each warning-tier check's output to
DIR/<check>.log; the `::warning title=ratchet debt::` lines in them are the
debt. On a feat-cmux-next push this rewrites the open issue's body with the
debt at that commit, opens the issue when there is debt and none is open, and
closes it with a comment once the debt is paid.

Usage: ratchet-debt-issue.py --repo OWNER/NAME --sha SHA --run-url URL [--dry-run] DIR
--dry-run prints what it would write and never calls gh.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

LABEL = "ratchet-debt"
TITLE = "Ratchet debt on feat-cmux-next"
PREFIX = "::warning title=ratchet debt::"
NAMES = {
    "godfiles-swift": "God files and types (Swift)",
    "godfiles-rust": "God files (cmux-tui Rust)",
    "l10n": "String tables: style",
    "scrollbars": "Scrollbars follow macOS",
}
LIMIT = 100  # lines per check in the body


def debt(directory: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for log in sorted(directory.glob("*.log")) if directory.is_dir() else []:
        lines = [line[len(PREFIX):].strip() for line in log.read_text(errors="replace").splitlines() if line.startswith(PREFIX)]
        if lines:
            found[log.stem] = lines
    return found


def body(found: dict[str, list[str]], sha: str, run_url: str) -> str:
    total = sum(len(v) for v in found.values())
    out = [
        f"{total} style ratchet warnings on feat-cmux-next at {sha[:12]} ([run]({run_url})).",
        "",
        "Each is under its hard ceiling, so it does not fail CI; past the ceiling it does.",
        "This body is rewritten on every feat-cmux-next push and the issue closes when the debt is paid.",
    ]
    for check, lines in found.items():
        out += ["", f"### {NAMES.get(check, check)} ({len(lines)})", ""]
        out += [f"- `{line}`" for line in lines[:LIMIT]]
        if len(lines) > LIMIT:
            out.append(f"- ... {len(lines) - LIMIT} more in the run's annotations")
    return "\n".join(out) + "\n"


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--run-url", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("dir", type=Path)
    a = ap.parse_args()
    found = debt(a.dir)
    text = body(found, a.sha, a.run_url)
    if a.dry_run:
        print("open or rewrite" if found else "close if open")
        print(text if found else "")
        return 0
    issues = json.loads(gh("issue", "list", "--repo", a.repo, "--label", LABEL, "--state", "open", "--json", "number", "--limit", "5"))
    number = str(issues[0]["number"]) if issues else ""
    if found and number:
        gh("issue", "edit", number, "--repo", a.repo, "--body", text)
    elif found:
        gh("label", "create", LABEL, "--repo", a.repo, "--force", "--color", "fbca04", "--description", "Style ratchet warnings on feat-cmux-next")
        gh("issue", "create", "--repo", a.repo, "--title", TITLE, "--label", LABEL, "--body", text)
    elif number:
        gh("issue", "close", number, "--repo", a.repo, "--comment", f"Paid off at {a.sha[:12]} ({a.run_url}).")
    print(f"ratchet debt: {sum(len(v) for v in found.values())} warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
