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

The iPhone is the first of PHONES the runtime supports, unless the step names one:
`--device NAME` (the step's device= argument) picks that iPhone type and nothing else. The one
other family it takes is the iPad mini: its window (744 x 1133 pt) stands in for an unfolded
foldable iPhone's nearly square screen, which the app's Debug build lays out for (cmuxterm-hq
docs/design/ios-foldable.md); no other iPad. NAME
is the device type's name ("iPhone 16e"), the same with commas for spaces ("iPhone,16e",
since fleet step arguments hold no spaces), or its identifier's last part
("iPhone-SE-3rd-generation", for names with parentheses). A name the runtime does not
support fails with the iPhone types it has; there is no fallback to another device.
`--with-name` adds the chosen device type's name as a third field (it may hold spaces, so
it comes last).
`--phone-class appstore-6.9` picks the 6.9" iPhone App Store Connect requires
screenshots of (iPhone 17 Pro Max, else 16 Pro Max) and never another phone,
since a screenshot of any other size is refused there.
"""
import json
import os
import re
import sys

ENV = "CMUX_CI_IOS_SIM_RUNTIME"
BUILD = re.compile(r"^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$")
PHONES = ("iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro")
# App Store Connect's 6.9" iPhone display: 1320x2868 (17 Pro Max) or 1290x2796 (16 Pro Max).
APPSTORE_69 = ("iPhone 17 Pro Max", "iPhone 16 Pro Max")


def version_key(runtime):
    return [int(x) if x.isdigit() else 0 for x in str(runtime.get("version", "0")).split(".")]


# Device families a step may name: every iPhone, and the iPad mini (an unfolded foldable's stand-in).
FAMILIES = ("iPhone", "iPad mini")


def find_device(types, want):
    """The device type identifier and name for want among types ({name: identifier}), or raise SystemExit."""
    spaced = want.replace(",", " ").strip()
    types = {k: v for k, v in types.items() if k.startswith(FAMILIES)}
    for name, ident in types.items():
        if want in (name, ident, ident.rsplit(".", 1)[-1]) or spaced == name:
            return ident, name
    phones = sorted(types)
    raise SystemExit(
        f"cmux-next-ios-sim.sh: device={want}: this runtime has no such iPhone or iPad mini device type; "
        f"available iPhone types: {', '.join(phones) or 'none'}"
    )


def select(listing, declared, device=None, phones=PHONES, exact=False):
    """(runtime identifier, device type identifier, device type name), or raise SystemExit with the reason.

    exact: only a phone in `phones`, no fallback to another iPhone."""
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
    if device:
        ident, name = find_device(names, device)
        return runtime["identifier"], ident, name
    for want in phones:
        if want in names:
            return runtime["identifier"], names[want], want
    if exact:
        raise SystemExit(
            f"cmux-next-ios-sim.sh: iOS runtime {runtime.get('buildversion')} supports none of {', '.join(phones)}"
        )
    phones = [k for k in names if k.startswith("iPhone")]
    if not phones:
        raise SystemExit(f"cmux-next-ios-sim.sh: iOS runtime {runtime.get('buildversion')} supports no iPhone device type")
    return runtime["identifier"], names[phones[-1]], phones[-1]


def declared_builds(value):
    builds = [b for b in re.split(r"[\s,]+", value.strip()) if b]
    for b in builds:
        if not BUILD.match(b):
            raise SystemExit(f"cmux-next-ios-sim.sh: {ENV} wants simulator runtime builds such as 23F77, got '{b}'")
    return builds


def main(argv):
    device, with_name, appstore = None, False, False
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--device" and args and args[0].strip():
            device = args.pop(0).strip()
        elif arg == "--with-name":
            with_name = True
        elif arg == "--phone-class" and args and args[0] == "appstore-6.9":
            args.pop(0)
            appstore = True
        else:
            raise SystemExit(
                f"ios_sim_runtime.py: takes --device NAME, --with-name and --phone-class appstore-6.9, got '{arg}'"
            )
    if appstore and device:
        raise SystemExit("ios_sim_runtime.py: --phone-class appstore-6.9 picks the device; drop --device")
    declared = declared_builds(os.environ.get(ENV, ""))
    if appstore:
        runtime, ident, name = select(json.load(sys.stdin), declared, phones=APPSTORE_69, exact=True)
    else:
        runtime, ident, name = select(json.load(sys.stdin), declared, device)
    fields = [runtime, ident] + ([name] if with_name else [])
    print(*fields)


if __name__ == "__main__":
    main(sys.argv[1:])
