#!/usr/bin/env python3
"""The type errors that stop a web bundle, from `vp check --no-fmt --no-lint` in webviews/.

    web_bundle_typecheck.py [--log FILE]

The full typecheck is not green on feat-cmux-next (test harness types, implicit any), so failing on all of it
would turn every push red (a missing module is caught where a bundle reaches it, by the builds beside this).
A bundle breaks on a name declared twice in shipped code (TS2300, TS2395, TS2440, TS2451, TS2528). Those are printed in the checker's own form
(`x typescript(TSnnnn): message` and `,-[file:line:col]`, which web-bundle-matrix.sh reads FILE:LINE from), and
fail with exit 1. Everything else is counted and left to `bun run typecheck`.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

BREAKS = {"TS2300", "TS2395", "TS2440", "TS2451", "TS2528"}
TEST_PATH = re.compile(r"(^|/)(test|tests|__tests__|e2e|bench)/|\.(test|spec|harness)\.[cm]?[jt]sx?$|\.stories\.[jt]sx?$")
HEAD = re.compile(r"^\s*x typescript\((TS\d+)\):")
LOC = re.compile(r"^\s*,-\[([^\]:]+):(\d+):\d+\]")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, help="read this checker output instead of running it")
    args = parser.parse_args(argv)
    if args.log:
        text = args.log.read_text(encoding="utf-8", errors="replace")
    else:
        done = subprocess.run(["vp", "check", "--no-fmt", "--no-lint"], capture_output=True, text=True)
        text = done.stdout + done.stderr
        if done.returncode == 127:
            print("error: vp not found", file=sys.stderr)
            return 2
    blocks, current = [], None
    for line in text.splitlines():
        if HEAD.match(line):
            current = [line]
            blocks.append(current)
        elif current is not None and line.strip() == "":
            current = None
        elif current is not None:
            current.append(line)
    hits, other = [], 0
    for block in blocks:
        code = HEAD.match(block[0]).group(1)
        where = next((LOC.match(l) for l in block[1:] if LOC.match(l)), None)
        if code in BREAKS and where and not TEST_PATH.search(where.group(1)):
            hits.append(block)
        else:
            other += 1
    for block in hits:
        print("\n".join(block) + "\n")
    print(f"web bundle typecheck: {len(hits)} bundle-breaking, {other} other type errors left to `bun run typecheck`")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
