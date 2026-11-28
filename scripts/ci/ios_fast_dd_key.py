#!/usr/bin/env python3
"""R2 key of the ios fast verdict's warm DerivedData (ios-fast-verdict-seed.yml saves it, pr-pipeline.yml's
`ios-fast` job restores it on a hosted Mac).

A hosted Mac (the picker's overflow when every owned simulator Mac is busy) built the kit and the app from empty
DerivedData: 144 s and 215 s of cmux#61812's verdict (2026-11-27, blacksmith-6vcpu-macos-26). The seed is one
build of exactly what that job builds, with the input times scripts/ci/e2e_warm_derived_data.py replays, so a
pull request rebuilds only the files that differ from the seed.

    ios-fast-verdict-<xcode>-<inputs>-<place>-<UTC minute>

- xcode: the selected Xcode (`xcodebuild -version`), 12 hex digits; `none` off a Mac.
- inputs: the package graph a restore must match, 12 hex digits of the git blobs of the kit's Package.resolved
  and the app's project.yml: the job runs with -skipPackageUpdates once the resolved checkouts exist, so another
  graph's checkouts must never be restored.
- place: the workspace path, 12 hex digits: DerivedData records absolute paths.
- the minute the seed started, so the due check reads its age from the newest key alone.

    python3 scripts/ci/ios_fast_dd_key.py [--workspace W] [--now]   # key=, prefix= (GITHUB_OUTPUT lines)
    python3 scripts/ci/ios_fast_dd_key.py due --newest KEY --minutes 240   # due=true|false
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from datetime import datetime, timezone

NAME = "ios-fast-verdict"
INPUTS = ("cmux-next-ios/CmuxMobileKit/Package.resolved", "cmux-next-ios/project.yml")
STAMP = "%Y%m%d%H%M"


def short(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def inputs(ref: str = "HEAD") -> str:
    blobs = subprocess.run(["git", "rev-parse", *(f"{ref}:{p}" for p in INPUTS)], check=True,
                           capture_output=True, text=True).stdout.split()
    return short(" ".join(blobs))


def xcode() -> str:
    try:
        out = subprocess.run(["xcodebuild", "-version"], check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return "none"
    return short(out)


def prefix(xcode_id: str, inputs_id: str, workspace: str) -> str:
    return f"{NAME}-{xcode_id}-{inputs_id}-{short(workspace)}-"


def fields(key: str) -> dict[str, str] | None:
    parts = key.strip().split("-")
    head = NAME.split("-")
    if len(parts) != len(head) + 4 or parts[: len(head)] != head:
        return None
    xcode_id, inputs_id, place, stamp = parts[len(head):]
    return {"xcode": xcode_id, "inputs": inputs_id, "place": place, "stamp": stamp}


def due(newest: str, now: datetime, minutes: int, inputs_id: str = "") -> bool:
    """A seed is due when no seed exists, the newest is older than `minutes`, or its package graph differs."""
    seen = fields(newest) if newest else None
    if seen is None:
        return True
    if inputs_id and seen["inputs"] != inputs_id:
        return True
    try:
        at = datetime.strptime(seen["stamp"], STAMP).replace(tzinfo=timezone.utc)
    except ValueError:
        return True
    return (now - at).total_seconds() >= minutes * 60


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", default="key", choices=("key", "due"))
    parser.add_argument("--workspace", default="")
    parser.add_argument("--newest", default="")
    parser.add_argument("--minutes", type=int, default=240)
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    if args.mode == "due":
        print(f"due={'true' if due(args.newest, now, args.minutes, inputs()) else 'false'}")
        return 0
    p = prefix(xcode(), inputs(), args.workspace)
    print(f"prefix={p}")
    print(f"key={p}{now.strftime(STAMP)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
