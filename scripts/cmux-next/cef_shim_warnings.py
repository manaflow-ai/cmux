#!/usr/bin/env python3
"""Counts the CEF shim's compiler warnings (p10-stability-162, queue Q22 of plans/cmux-next/chrome-parity/p10-stability.md).

build-cef-shim.sh compiles each shim source with -Wall -Wextra -Wunsafe-buffer-usage and keeps their diagnostics in
<output>/warnings.log; this writes <output>/warnings.json from that log:

  {"schema": 1, "sanitize": "none", "total": N, "unsafe_buffer_usage": M,
   "by_flag": {"-Wunsafe-buffer-usage": M, ...}, "by_file": {"Packages/.../suggestion_rows.h": n, ...}}

A warning in a header that several sources include counts once: warnings are keyed by (file, line, column, flag), with
the file made repository-relative. `unsafe_buffer_usage` counts every -Wunsafe-buffer-usage* flag (the -in-container
and -in-libc-call groups too); p10-stability-163 takes it to 0 and then makes the flag an error.

Usage: cef_shim_warnings.py --out FILE [--root DIR] [--sanitize KINDS] LOG...
Prints one summary line. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

SCHEMA = 1
UNSAFE_BUFFERS = "-Wunsafe-buffer-usage"
# clang: `path:line:col: warning: message [-Wflag]` (or `[-Wflag,-Wgroup]`; a warning with no flag has no brackets).
WARNING = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+): warning: (?P<message>.*?)(?: \[(?P<flags>-W[^\]]*)\])?$")
NO_FLAG = "-W(none)"


def relative(path: str, root: Path | None) -> str:
    normal = os.path.normpath(path)
    if root is not None and os.path.isabs(normal):
        try:
            return Path(normal).relative_to(root).as_posix()
        except ValueError:
            return normal
    return normal


def count(lines: list[str], root: Path | None = None, sanitize: str = "none") -> dict:
    seen: set[tuple[str, int, int, str]] = set()
    for text in lines:
        match = WARNING.match(text.rstrip("\n"))
        if not match:
            continue
        flag = (match.group("flags") or NO_FLAG).split(",")[0]
        seen.add((relative(match.group("file"), root), int(match.group("line")), int(match.group("col")), flag))
    by_flag = Counter(flag for _, _, _, flag in seen)
    by_file = Counter(path for path, _, _, _ in seen)
    return {
        "schema": SCHEMA,
        "sanitize": sanitize,
        "total": len(seen),
        "unsafe_buffer_usage": sum(n for flag, n in by_flag.items() if flag.startswith(UNSAFE_BUFFERS)),
        "by_flag": dict(sorted(by_flag.items())),
        "by_file": dict(sorted(by_file.items())),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, type=Path, help="the warnings.json to write")
    parser.add_argument("--root", type=Path, help="the repository root; file names are made relative to it")
    parser.add_argument("--sanitize", default="none", help="the shim's sanitizer, recorded in the file")
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    lines: list[str] = []
    for log in args.logs:
        lines.extend(log.read_text(errors="replace").splitlines())
    root = Path(os.path.abspath(args.root)) if args.root else None
    result = count(lines, root, args.sanitize)
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"==> CEF shim warnings: {result['total']} ({result['unsafe_buffer_usage']} -Wunsafe-buffer-usage); {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
