#!/usr/bin/env python3
"""Pick the iOS simulator runtime and iPhone for scripts/ci/cmux-next-ios-sim.sh and the iOS workflows.

Reads `xcrun simctl list -j runtimes devicetypes` on stdin and prints
"RUNTIME_IDENTIFIER DEVICE_TYPE_IDENTIFIER", or only the runtime identifier
with --runtime-only (for callers that rank their own devices).

CMUX_CI_IOS_SIM_RUNTIME names the runtime builds the fleet declares (simctl
buildversion, e.g. 23F77; space or comma separated). The build fleet's
controller sets it on every simulator step from its one declaration (HQ
build-fleet/mini-fleet.json defaults.ios_simulator.runtimes, which
sim-slots.json is checked against), so the step runs the same runtime on an
owned Mac and on a Blacksmith macOS overflow runner. With it set, only those
builds are candidates, and a host that has none of them fails here with the
builds it has, before anything is built. A Blacksmith image with both iOS 26.5
(23F77) and iOS 27.0 ran 27.0 before this (2026-10-29), because the newest
available runtime won. A step that asks for iOS 27 by label (HQ sim-slots.json
opt_in_runtimes, `--label ios27`) gets that build here instead.

--prefer-pin (the iOS workflows, 2026-11-17): with CMUX_CI_IOS_SIM_RUNTIME
unset, prefer the builds in CMUX_CI_IOS_SIM_RUNTIME_PREFER, else in
scripts/ci/ios-sim-runtime-pin.txt, and take the newest available runtime only
when none of them is installed (a GitHub-hosted or Blacksmith image without the
pin keeps working). Owned minis now carry iOS 27.0 (24A434) beside the pin, and
Xcode 26.6 runs it, so "the newest" there moved a run to iOS 27.

Neither set: the newest available iOS runtime, as before.
"""
import json
import os
import pathlib
import re
import sys

ENV = "CMUX_CI_IOS_SIM_RUNTIME"
PREFER_ENV = "CMUX_CI_IOS_SIM_RUNTIME_PREFER"
PIN_FILE = pathlib.Path(__file__).resolve().parent / "ios-sim-runtime-pin.txt"
BUILD = re.compile(r"^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$")
PHONES = ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro")


def version_key(runtime):
    return [int(x) if x.isdigit() else 0 for x in str(runtime.get("version", "0")).split(".")]


def pick_runtime(listing, declared, prefer=()):
    """The runtime dict, or raise SystemExit with the reason."""
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
        candidates = [r for r in runtimes if r.get("buildversion") in prefer] or runtimes
    if not candidates:
        raise SystemExit("cmux-next-ios-sim.sh: no available iOS simulator runtime on this host")
    return max(candidates, key=version_key)


def select(listing, declared, prefer=()):
    """(runtime identifier, device type identifier), or raise SystemExit with the reason."""
    runtime = pick_runtime(listing, declared, prefer)
    names = {t["name"]: t["identifier"] for t in runtime.get("supportedDeviceTypes", []) if "name" in t and "identifier" in t}
    for want in PHONES:
        if want in names:
            return runtime["identifier"], names[want]
    phones = [v for k, v in names.items() if k.startswith("iPhone")]
    if not phones:
        raise SystemExit(f"cmux-next-ios-sim.sh: iOS runtime {runtime.get('buildversion')} supports no iPhone device type")
    return runtime["identifier"], phones[-1]


def declared_builds(value, name=ENV):
    builds = [b for b in re.split(r"[\s,]+", value.strip()) if b]
    for b in builds:
        if not BUILD.match(b):
            raise SystemExit(f"cmux-next-ios-sim.sh: {name} wants simulator runtime builds such as 23F77, got '{b}'")
    return builds


def pinned_builds():
    """The prefer list: CMUX_CI_IOS_SIM_RUNTIME_PREFER, else the repo's pin file."""
    if os.environ.get(PREFER_ENV, "").strip():
        return declared_builds(os.environ[PREFER_ENV], PREFER_ENV)
    lines = [line.split("#", 1)[0] for line in PIN_FILE.read_text().splitlines()]
    return declared_builds(" ".join(lines), str(PIN_FILE.name))


def main(argv):
    flags = set(argv)
    unknown = flags - {"--prefer-pin", "--runtime-only"}
    if unknown:
        raise SystemExit(f"ios_sim_runtime.py: unknown option {sorted(unknown)[0]}")
    declared = declared_builds(os.environ.get(ENV, ""))
    prefer = pinned_builds() if "--prefer-pin" in flags else ()
    listing = json.load(sys.stdin)
    if "--runtime-only" in flags:
        print(pick_runtime(listing, declared, prefer)["identifier"])
        return
    runtime, device = select(listing, declared, prefer)
    print(runtime, device)


if __name__ == "__main__":
    main(sys.argv[1:])
