#!/usr/bin/env python3
"""Every nightly.yml job that runs the app license check initializes ghostty-next.

scripts/verify-app-bundle-licenses.sh runs toolchain_notices.py check-repo, and
that reads ghostty-next/build.zig.zon (the Zig minimum). The job checkouts use
submodules: false. build-sign-notarize-nightly initializes ghostty-next, but
recover-nightly-next-notarization did not. So every build that Apple accepted
after its run stopped waiting failed the check with "ghostty-next/build.zig.zon:
missing" and was skipped as "Apple did not accept" (runs 38625732642 through
38659284357 on 2026-10-14). The nightly-next feed did not move although Apple
had accepted, stapled and launch-tested each build.
"""
import re
import sys
from pathlib import Path
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
CHECKERS = ("verify-app-bundle-licenses.sh", "notarize-nightly-dmg.sh", "resume-nightly-notarization.sh")
INIT = "init-submodule.sh ghostty-next"
EXEMPT: set[str] = set()

text = nightly_text()
jobs_text = text[text.index("\njobs:\n"):]
blocks = dict(re.findall(r"^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", jobs_text, re.MULTILINE | re.DOTALL))

failures = []
checked = []
for name, body in blocks.items():
    if name in EXEMPT:
        continue
    lines = [line for line in body.splitlines() if not line.lstrip().startswith("#")]
    uses = [i for i, line in enumerate(lines) if any(c in line for c in CHECKERS)]
    if not uses:
        continue
    checked.append(name)
    inits = [i for i, line in enumerate(lines) if INIT in line]
    if not inits or inits[0] > uses[0]:
        failures.append(f"{name} runs the license check without first running `{INIT}`")

for name in ("build-sign-notarize-nightly", "recover-nightly-next-notarization"):
    if name not in checked:
        failures.append(f"{name} no longer runs the license check; update this test")

if failures:
    print("FAIL: nightly notices submodule\n  " + "\n  ".join(failures))
    sys.exit(1)
print(f"PASS: nightly notices submodule ({', '.join(checked)})")
