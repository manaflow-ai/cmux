#!/usr/bin/env python3
"""build-nightly-app builds the cmux-next web bundles before any Rust build.

The bundles are build output since cx-vn5, and optchat-chief compiles the
inspector page in (include_str! of inspector/index.html). Nightly-next run
37654121454 built the Chief before "Build the web bundles (cmux-next)" on a
commit without a committed inspector page and failed with exit 101. Every
step of build-nightly-app that runs cargo or a Rust build script must come
after the bundle build and its Bun and Node setup.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"

BUNDLE_STEPS = (
    "Set up Bun (cmux-next web bundles)",
    "Setup Node (cmux-next web bundles)",
    "Build the web bundles (cmux-next)",
)
RUST_BUILD = re.compile(r"cargo build|build-optchat-chief\.sh|build-acpmux\.sh")


def job_steps(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.MULTILINE | re.DOTALL)
    assert match, f"nightly.yml has no {job} job"
    steps = []
    for chunk in re.split(r"^      - ", match.group(1), flags=re.MULTILINE)[1:]:
        name = re.match(r"name: (.+)", chunk)
        steps.append((name.group(1).strip() if name else "", chunk))
    return steps


failures = []
steps = job_steps(WORKFLOW.read_text(), "build-nightly-app")
names = [name for name, _ in steps]
for step in BUNDLE_STEPS:
    if step not in names:
        failures.append(f"build-nightly-app has no step {step!r}")
if not failures:
    last_bundle = max(names.index(step) for step in BUNDLE_STEPS)
    for index, (name, body) in enumerate(steps):
        if RUST_BUILD.search(body) and index < last_bundle:
            failures.append(f"{name!r} builds Rust before the web bundles are built")
    if not any(RUST_BUILD.search(body) for _, body in steps):
        failures.append("build-nightly-app has no Rust build step; update this test")

if failures:
    print("FAIL: nightly web bundles order\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly web bundles order")
