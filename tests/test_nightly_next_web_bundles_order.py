#!/usr/bin/env python3
"""build-nightly-app installs the cmux-next web bundles before the Release build.

The bundles are build output since cx-vn5, and the Release build's first phase
refuses an app without them, so the bundle steps and their Bun and Node setup
must come before "Build nightly app (Release)".

They may come after the Rust helper builds. optchat-chief compiles the memory
inspector page in (include_str! of inspector/index.html), and nightly-next run
37654121454 failed (exit 101) building the Chief before the bundles on a commit
without that page. The page is committed now and an in-tree bundle build only
checks it, never writes it, so no Rust build reads anything the bundle steps
write. This test keeps both halves of that true.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
BUNDLE_SCRIPT = ROOT / "scripts" / "cmux-next" / "build-web-bundles.sh"
INSPECTOR = "Native/OptChat/optchat-chief/inspector/index.html"

BUNDLE_STEPS = (
    "Set up Bun (cmux-next web bundles)",
    "Setup Node (cmux-next web bundles)",
    "Build the web bundles (cmux-next)",
)
RELEASE_BUILD = "Build nightly app (Release)"


def job_steps(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.MULTILINE | re.DOTALL)
    assert match, f"nightly.yml has no {job} job"
    steps = []
    for chunk in re.split(r"^      - ", match.group(1), flags=re.MULTILINE)[1:]:
        name = re.match(r"name: (.+)", chunk)
        steps.append((name.group(1).strip() if name else "", chunk))
    return steps


failures = []
names = [name for name, _ in job_steps(WORKFLOW.read_text(), "build-nightly-app")]
for step in (*BUNDLE_STEPS, RELEASE_BUILD):
    if step not in names:
        failures.append(f"build-nightly-app has no step {step!r}")
if not failures:
    last_bundle = max(names.index(step) for step in BUNDLE_STEPS)
    if last_bundle > names.index(RELEASE_BUILD):
        failures.append(f"the web bundle steps must come before {RELEASE_BUILD!r}")

tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", INSPECTOR],
                         capture_output=True, text=True)
if tracked.returncode != 0:
    failures.append(f"{INSPECTOR} is not committed: the Chief build would need the web bundles first")
script = BUNDLE_SCRIPT.read_text()
# The only write of the inspector page is the --out-root build's own copy.
writes = [line.strip() for line in script.splitlines()
          if '"$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh"' in line and "--check" not in line]
if writes != ['"$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$(out "$INSPECTOR")"'] \
        or 'if [ -n "$OUT_ROOT" ]; then\n  "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out' not in script:
    failures.append("build-web-bundles.sh may write the committed inspector page in-tree; the Chief would then read it")

if failures:
    print("FAIL: nightly web bundles order\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly web bundles order")
