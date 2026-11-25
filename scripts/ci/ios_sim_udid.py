#!/usr/bin/env python3
"""The newest available iOS 26 iPhone simulator on this Mac: its UDID on stdout.

The ios steps of ci/steps.toml (the CmuxMobileKit tests and the reliability matrix's phone cells) test on one.
Exits 1 with a GitHub error line when the runner has none.

    udid="$(python3 -I scripts/ci/ios_sim_udid.py)"
"""

from __future__ import annotations

import json
import subprocess
import sys


def pick(devices: dict[str, list[dict]]) -> str:
    """The UDID of the iPhone on the newest iOS 26 runtime of `xcrun simctl list devices available -j`, or ""."""
    found = sorted(
        (runtime, device["udid"])
        for runtime, items in devices.items()
        if ".SimRuntime.iOS-26" in runtime
        for device in items
        if device.get("name", "").startswith("iPhone")
    )
    return found[-1][1] if found else ""


def main() -> int:
    listed = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], check=True,
                            capture_output=True, text=True, timeout=120)
    udid = pick(json.loads(listed.stdout)["devices"])
    if not udid:
        print("::error::no available iOS 26 iPhone simulator on this runner", file=sys.stderr)
        return 1
    print(f"simulator {udid}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
