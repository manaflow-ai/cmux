#!/usr/bin/env python3
"""Pick the iOS simulator runtime and iPhone for scripts/ci/cmux-next-ios-sim.sh.

Reads `xcrun simctl list -j runtimes devicetypes` on stdin and prints
"RUNTIME_IDENTIFIER DEVICE_TYPE_IDENTIFIER".

CMUX_CI_IOS_SIM_RUNTIME names the runtime builds the fleet declares (simctl
buildversion, e.g. 23F77; space or comma separated). The build fleet's
controller sets it on every simulator step from its one declaration (HQ
build-fleet/mini-fleet.json defaults.ios_simulator.runtimes, which
sim-slots.json is checked against), so the step runs the same runtime on an
owned Mac and on a Blacksmith macOS overflow runner. With it set, only those
builds are candidates, and a host that has none of them fails here with the
builds it has, before anything is built. A Blacksmith image with both iOS 26.5
(23F77) and iOS 27.0 ran 27.0 before this (2026-10-29), because the newest
available runtime won. Unset (a run outside the fleet), the newest available
iOS runtime is used, as before.
"""
import json
import os
import re
import sys

ENV = "CMUX_CI_IOS_SIM_RUNTIME"
BUILD = re.compile(r"^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$")
PHONES = ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro")


def version_key(runtime):
    return [int(x) if x.isdigit() else 0 for x in str(runtime.get("version", "0")).split(".")]


def select(listing, declared):
    """(runtime identifier, device type identifier), or raise SystemExit with the reason."""
    runtimes = [r for r in listing.get("runtimes", []) if r.get("isAvailable") and r.get("platform") == "iOS"]
    if declared:
        candidates = [r for r in runtimes if r.get("buildversion") in declared]
        if not candidates:
            have = ", ".join(f"{r.get('name', r.get('identifier'))} ({r.get('buildversion')})" for r in runtimes) or "none"
            raise SystemExit(
                f"cmux-next-ios-sim.sh: the declared iOS simulator runtime {' or '.join(declared)} ({ENV}) "
                f"is not available on this host; available iOS runtimes: {have}"
            )
    else:
        candidates = runtimes
    if not candidates:
        raise SystemExit("cmux-next-ios-sim.sh: no available iOS simulator runtime on this host")
    runtime = max(candidates, key=version_key)
    names = {t["name"]: t["identifier"] for t in runtime.get("supportedDeviceTypes", []) if "name" in t and "identifier" in t}
    for want in PHONES:
        if want in names:
            return runtime["identifier"], names[want]
    phones = [v for k, v in names.items() if k.startswith("iPhone")]
    if not phones:
        raise SystemExit(f"cmux-next-ios-sim.sh: iOS runtime {runtime.get('buildversion')} supports no iPhone device type")
    return runtime["identifier"], phones[-1]


def declared_builds(value):
    builds = [b for b in re.split(r"[\s,]+", value.strip()) if b]
    for b in builds:
        if not BUILD.match(b):
            raise SystemExit(f"cmux-next-ios-sim.sh: {ENV} wants simulator runtime builds such as 23F77, got '{b}'")
    return builds


def main():
    declared = declared_builds(os.environ.get(ENV, ""))
    runtime, device = select(json.load(sys.stdin), declared)
    print(runtime, device)


if __name__ == "__main__":
    main()
