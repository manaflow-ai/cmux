#!/usr/bin/env python3
"""browser-fuzz.sh builds with the bun webviews/package.json pins, not the account's (no build, no app).

Job 910574114793e0a390089c19 (cmux18-perf, 2026-10-31) failed before any fuzz op: the script put the account's
~/.bun/bin (bun 1.3.14) first on PATH, and the web bundle build needs 1.4.4 (devEngines). crash-gate.sh,
tab-switch.sh and the other app-building measure scripts provision the pin with scripts/cmux-next/private-bun.sh
first on PATH before reload.sh. This checks browser-fuzz.sh does the same, in that order.

  python3 scripts/measure/tests/browser-fuzz-bun.test.py
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
lines = (ROOT / "scripts/measure/browser-fuzz.sh").read_text().splitlines()
code = [line.split("#", 1)[0] if not line.lstrip().startswith("#") else "" for line in lines]


def first(pattern):
    return next((i for i, line in enumerate(code) if re.search(pattern, line)), None)


provision = first(r"scripts/cmux-next/private-bun\.sh")
on_path = first(r'PATH="\$\(tail -n 1 "\$out/bun-path"\):\$PATH"')
build = first(r"scripts/reload\.sh")
failures = []
if build is None:
    failures.append("browser-fuzz.sh runs no scripts/reload.sh")
if provision is None:
    failures.append("browser-fuzz.sh does not provision the pinned bun (scripts/cmux-next/private-bun.sh)")
elif build is not None and provision > build:
    failures.append("browser-fuzz.sh provisions the pinned bun after the build")
if on_path is None:
    failures.append("browser-fuzz.sh does not put the pinned bun first on PATH ($out/bun-path)")
elif build is not None and on_path > build:
    failures.append("browser-fuzz.sh puts the pinned bun on PATH after the build")
for failure in failures:
    print(f"FAIL {failure}")
if failures:
    sys.exit(1)
print("ok browser-fuzz.sh builds with the pinned bun")
