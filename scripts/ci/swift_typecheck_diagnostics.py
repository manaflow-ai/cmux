#!/usr/bin/env python3
"""Extract Swift long type-check warnings from a compiler log."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# The frontend's three diagnostics (swift include/swift/AST/DiagnosticsSema.def, release/6.2):
#   debug_long_function_body  "%kind0 took %1ms to type-check (limit: %2ms)"   -warn-long-function-bodies=N
#   debug_long_closure_body   "closure took %0ms to type-check (limit: %1ms)"  -warn-long-function-bodies=N
#   debug_long_expression     "expression took %0ms to type-check (limit: %1ms)" -warn-long-expression-type-checking=N
# %kind0 prints the declaration's kind and quoted name: "instance method 'render()'", "initializer 'init(model:)'",
# and for an accessor "getter for property 'body'" (lib/AST/DiagnosticEngine.cpp). Each fires at elapsed >= limit.
WARNING_RE = re.compile(
    r"(?P<location>[^\n:]+\.swift:\d+:\d+):\s+warning:\s+"
    r"(?:(?P<kind>expression|closure)|(?P<decl_kind>[A-Za-z_][A-Za-z_ ]*?) '(?P<function>[^']+)') took "
    r"(?P<milliseconds>\d+(?:\.\d+)?)ms to type-check"
    r"(?: \(limit: (?P<limit>\d+)ms\))?"
)


def git_output(*args: str) -> str | None:
    try:
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def parse_log(path: Path) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    text = ANSI_RE.sub("", path.read_text(encoding="utf-8", errors="replace"))
    for match in WARNING_RE.finditer(text):
        function = match.group("function")
        kind = "function" if function else match.group("kind")
        entries.append(
            {
                "location": match.group("location"),
                "kind": kind,
                "declaration": match.group("decl_kind"),
                "subject": function or kind,
                "milliseconds": float(match.group("milliseconds")),
                "limit_milliseconds": int(match.group("limit")) if match.group("limit") else None,
            }
        )
    entries.sort(key=lambda entry: (-float(entry["milliseconds"]), str(entry["location"])))
    return {
        "schema_version": 1,
        "source": {
            "revision": os.environ.get("GITHUB_SHA") or git_output("rev-parse", "HEAD"),
            "tree": git_output("rev-parse", "HEAD^{tree}"),
        },
        "log": {"path": str(path), "bytes": path.stat().st_size},
        "count": len(entries),
        "slowest": entries[:20],
    }


def write_summary(receipt: dict[str, object], stream) -> None:
    print("### Swift type-check diagnostics", file=stream)
    print(file=stream)
    slowest = list(receipt["slowest"])
    print(f"- warnings over threshold: `{receipt['count']}`", file=stream)
    if not slowest:
        print("- no long function-body, closure or expression warnings", file=stream)
        return
    print("- slowest functions, closures and expressions:", file=stream)
    for index, entry in enumerate(slowest, 1):
        data = dict(entry)
        print(
            f"  {index}. `{data['milliseconds']} ms` {data['kind']} "
            f"`{data['subject']}` at `{data['location']}`",
            file=stream,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    receipt = parse_log(args.log)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        with args.summary.open("a", encoding="utf-8") as stream:
            write_summary(receipt, stream)
    write_summary(receipt, stream=os.sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
