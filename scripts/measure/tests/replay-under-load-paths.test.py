#!/usr/bin/env python3
"""replay-under-load.sh cds into webviews/ before it writes: every path flag is resolved from the caller's directory
first, or a relative --out/--log/--trace points under webviews/ (run 46146790475 wrote no artifacts/vfp95/run.json)."""
import pathlib, re, sys

src = (pathlib.Path(__file__).resolve().parents[1] / "replay-under-load.sh").read_text()
bad = []
for flag in ("--out", "--log", "--trace"):
    arm = re.search(rf"^\s*(?:[-\w|]*\|)?{re.escape(flag)}(?:\|[-\w|]*)?\)(.*)$", src, re.M)
    if not arm or "realpath" not in arm.group(1):
        bad.append(flag)
if bad:
    sys.exit(f"replay-under-load.sh: {', '.join(bad)} not resolved with realpath before the cd into webviews/")
print("ok")
