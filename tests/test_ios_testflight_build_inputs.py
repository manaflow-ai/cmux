#!/usr/bin/env python3
"""The TestFlight upload job must fetch only what it actually consumes.

Two inputs of that job were bought up front and mostly wasted. On run
35794306343, a 22-minute job:

    9.6 min  Checkout                             (8m42s of it the main fetch)
    5.7 min  Install zig
    6.4 min  Archive, export, and upload

`fetch-depth: 0` cloned 2.1 GB of history because one script walks
`LAST_UPLOADED_SHA..HEAD` -- a range that is a handful of commits at the
20-minute upload cadence. `Install zig` downloaded and verified a toolchain
that ensure-ghosttykit.sh only invokes when the pinned prebuilt xcframework
misses, which it did not: Provision GhosttyKit took 0.1 min.

Neither is a correctness bug, so nothing would ever go red over it coming
back. These two checks are what makes it stay fixed.
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-testflight.yml"
ENSURE_GHOSTTYKIT = ROOT / "scripts/ensure-ghosttykit.sh"
NOTES_GENERATOR = "generate-testflight-notes.sh"


def zig_is_installed_lazily() -> str | None:
    """ensure-ghosttykit.sh must obtain zig on the path that needs it."""
    text = ENSURE_GHOSTTYKIT.read_text(encoding="utf-8")
    if "install-zig-ci.sh" not in text:
        return (
            f"{ENSURE_GHOSTTYKIT.relative_to(ROOT)} does not install zig, so "
            "every caller has to install it up front whether or not the "
            "from-source build runs"
        )
    build = text.find("zig build")
    if build == -1:
        build = text.find('"$ZIG_BIN" build')
    install = text.find("install-zig-ci.sh")
    if build != -1 and install > build:
        return (
            f"{ENSURE_GHOSTTYKIT.relative_to(ROOT)} installs zig after it "
            "builds with it"
        )
    return None


def notes_history_is_fetched() -> str | None:
    """Shallow is fine only if the notes range is deepened for."""
    text = WORKFLOW.read_text(encoding="utf-8")
    if NOTES_GENERATOR not in text:
        return None
    if "fetch-depth: 0" in text:
        return None
    if "last_uploaded_sha" not in text or "--depth=" not in text:
        return (
            f"{WORKFLOW.relative_to(ROOT)} checks out shallow but never "
            f"deepens to last_uploaded_sha, so {NOTES_GENERATOR} silently "
            "falls back to its generic line on every build"
        )
    return None


def main() -> int:
    failures = [
        message
        for message in (zig_is_installed_lazily(), notes_history_is_fetched())
        if message
    ]
    if failures:
        print("the TestFlight upload job fetches more than it uses:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("TestFlight upload job fetches zig and history on demand")
    return 0


if __name__ == "__main__":
    sys.exit(main())
