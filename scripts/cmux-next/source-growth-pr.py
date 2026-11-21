#!/usr/bin/env python3
"""The advisory source budget of one change: how many bytes of NEXT app source it adds, net, against its base.

    source-growth-pr.py check --base REF [--head REF] [--body-file FILE] [--json OUT] [--repo DIR] [--budget JSON]

It gates nothing (cmuxterm-hq goals/next-code-shrinks.md, 2026-11-16: "growth rate, and an advisory per-PR
budget"). It reads both trees with `git ls-tree -r -l` (no checkout), counts each path NOW's code-shape rule
counts (language() below), and prints a Markdown table: net bytes by language, the top areas, and whether the
change is over `allowance_bytes` of scripts/cmux-next/source-growth-budget.json. Over it, the table names the
offset the change would need and the levers that give it. A line `source: <reason>` in the pull request body
is shown as the stated reason.

Exit 0 always, whatever the growth; 2 when the check itself cannot run (a bad ref, an unreadable budget).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUDGET = Path(__file__).resolve().parent / "source-growth-budget.json"
REASON_LINE = re.compile(r"^[ \t]*source[ \t]*:[ \t]*(\S.*)$", re.IGNORECASE | re.MULTILINE)
LANGUAGES = ("swift", "rust", "web")
TOP_AREAS = 5

# Copied exactly from cmuxterm-hq tools/fleet-reconcilers/now_code_shape.py (TEST, VENDOR, language()), so this
# budget and NOW's code_shape count the same files. Change them there first, then here.
TEST = re.compile(r"(^|/)(Tests?|tests?|UITests|fixtures|benches|bench|gallery)(/|$)|(^|/)tests?\.rs$|_tests?\.rs$"
                  r"|\.(test|spec|gallery)\.(ts|tsx)$|\.d\.ts$")
VENDOR = re.compile(r"(^|/)(vendor|Vendor|third_party|generated|Generated)(/|$)|\+Generated\.swift$|\.generated\.")


def language(path: str) -> str | None:
    """`swift`, `rust` or `web` for a NEXT app source file; None for everything else."""
    if TEST.search(path) or VENDOR.search(path):
        return None
    if path.endswith(".swift") and path.startswith(("Packages/macOS/", "Packages/Shared/")) and "/Sources/" in path:
        return "swift"
    if path.endswith(".rs") and path.startswith("cmux-tui/"):
        return "rust"
    if path.endswith((".ts", ".tsx")) and path.startswith(("webviews/", "cmux-tui/frontends/web/")):
        return "web"
    return None


class Broken(Exception):
    pass


def source_files(repo: Path, ref: str) -> dict[str, int]:
    """{path: bytes} of every counted source file at ref."""
    r = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", "-l", "-z", "--full-tree", ref],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise Broken(f"git ls-tree {ref} failed: {r.stderr.strip()}")
    out = {}
    for entry in r.stdout.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        parts = meta.split()
        if len(parts) < 4 or parts[1] != "blob" or not parts[3].isdigit():
            continue
        if language(path):
            out[path] = int(parts[3])
    return out


def area(path: str) -> str:
    return "/".join(path.split("/")[:3])


def measure(base: dict[str, int], head: dict[str, int]) -> dict:
    by_lang = {lang: {"base": 0, "head": 0} for lang in LANGUAGES}
    areas: dict[str, int] = {}
    changed = 0
    for path in base.keys() | head.keys():
        b, h = base.get(path, 0), head.get(path, 0)
        lang = language(path)
        by_lang[lang]["base"] += b
        by_lang[lang]["head"] += h
        if b != h:
            changed += 1
            areas[area(path)] = areas.get(area(path), 0) + h - b
    for v in by_lang.values():
        v["net"] = v["head"] - v["base"]
    top = sorted(areas.items(), key=lambda kv: (-abs(kv[1]), kv[0]))[:TOP_AREAS]
    return {"net_bytes": sum(v["net"] for v in by_lang.values()), "languages": by_lang,
            "areas": [{"area": a, "net": n} for a, n in top], "changed_files": changed}


def signed(n: int) -> str:
    return f"{n:+,}"


def report(m: dict, allowance: int, reasons: list[str]) -> str:
    net = m["net_bytes"]
    over = net > allowance
    if over:
        head = (f"**Source growth: {signed(net)} bytes net, over the {allowance:,}-byte allowance** "
                "(advisory: gates nothing)")
    else:
        head = f"**Source growth: {signed(net)} bytes net, within the {allowance:,}-byte allowance** (advisory)"
    lines = [head, "", "| Language | Base | Head | Net |", "| --- | ---: | ---: | ---: |"]
    for lang in LANGUAGES:
        v = m["languages"][lang]
        lines.append(f"| {lang} | {v['base']:,} | {v['head']:,} | {signed(v['net'])} |")
    lines.append(f"| **total** | | | **{signed(net)}** |")
    if m["areas"]:
        lines += ["", "| Area | Net |", "| --- | ---: |"]
        lines += [f"| `{a['area']}` | {signed(a['net'])} |" for a in m["areas"]]
    lines += ["", f"{m['changed_files']} source files changed. Counted: Swift under Packages/macOS or Packages/Shared "
              "with /Sources/, Rust under cmux-tui/, TS/TSX under webviews/ or cmux-tui/frontends/web/; tests, "
              "fixtures, galleries, vendor and generated code left out (NOW's code-shape rule)."]
    if over:
        lines += ["", f"To stay within the allowance this change would need an offset of {net - allowance:,} bytes. "
                  "Levers: a port that deletes the Swift it replaces; a step-B delete of the code a landed port made "
                  "dead; moving inline `#[cfg(test)]` blocks out of Rust sources with "
                  "`scripts/cmux-next/move-inline-tests.py`."]
    if reasons:
        lines += ["", "Stated reason: " + "; ".join(reasons)]
    elif over:
        lines += ["", "No stated reason: a line `source: <reason>` in the pull request description is shown here."]
    return "\n".join(lines) + "\n"


def check(args: argparse.Namespace) -> int:
    try:
        allowance = int(json.loads(args.budget.read_text())["allowance_bytes"])
        body = args.body_file.read_text() if args.body_file else ""
        m = measure(source_files(args.repo, args.base), source_files(args.repo, args.head))
    except (Broken, OSError, ValueError, KeyError, TypeError) as e:
        print(f"source-growth-pr: {e}", file=sys.stderr)
        return 2
    reasons = [r.strip() for r in REASON_LINE.findall(body)]
    sys.stdout.write(report(m, allowance, reasons))
    if args.json:
        m.update(allowance_bytes=allowance, over=m["net_bytes"] > allowance,
                 offset_needed=max(0, m["net_bytes"] - allowance), reasons=reasons)
        args.json.write_text(json.dumps(m, indent=2) + "\n")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--base", required=True)
    c.add_argument("--head", default="HEAD")
    c.add_argument("--body-file", type=Path)
    c.add_argument("--json", type=Path)
    c.add_argument("--repo", type=Path, default=ROOT)
    c.add_argument("--budget", type=Path, default=BUDGET)
    args = ap.parse_args(argv)
    return check(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
