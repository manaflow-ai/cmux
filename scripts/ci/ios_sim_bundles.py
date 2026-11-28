#!/usr/bin/env python3
"""Which CmuxMobileKit simulator test bundles each side runs (RFD 0051's per-bundle cutover).

The kit job (cmux-next-ios-kit.yml) runs the simulator tests on a Mac and on the fleet pool's Linux phones.
vars.CMUX_IOS_SIM_LINUX picks the split:

  shadow (the default)  both sides run every bundle (less the ones skipped everywhere, SKIP_EVERYWHERE)
  on                    the Mac runs only the bundles in scripts/ci/ios-sim-mac-bundles.txt and the pool
                        runs the rest; the Mac fallback, used when the pool gives no verdict, runs the pool's share
  anything else         Mac only, every bundle (the pool is not submitted)

  python3 -I scripts/ci/ios_sim_bundles.py mac       xcodebuild filter args, one per line, for the Mac
                                                     simulator step (empty output: no bundle runs there)
  python3 -I scripts/ci/ios_sim_bundles.py fallback  the same for the Mac fallback step
  python3 -I scripts/ci/ios_sim_bundles.py pool      --arg skip=TARGET pairs, one token per line, for the pool
                                                     submit (scripts/ci/ios-sim-linux-test.sh); exit 3 with
                                                     "none" on stderr: the pool has nothing to run (every
                                                     bundle stays on the Mac, or the mode is off)

Mode comes from $CMUX_IOS_SIM_LINUX (unset or empty: shadow). $CMUX_IOS_SIM_BUNDLES (a path) and
$CMUX_IOS_SIM_MAC_BUNDLES (a path) are for tests.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Skipped on both sides in every mode, as before this script: the bench runs on its own later in the job, and
# these three are covered on Linux by the package lane (scripts/ci/swift-linux-packages.txt).
SKIP_EVERYWHERE = (
    "CmuxMobileInstantPerfTests",
    "CmuxMobileDesignCoreTests",
    "CmuxMobileRealtimeTests",
    "CmuxMobileTransportTests",
)


def read_list(path: Path) -> list[str]:
    names = []
    for line in path.read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if name:
            names.append(name)
    return list(dict.fromkeys(names))


def all_bundles(package: Path) -> list[str]:
    """Every testTarget name of the kit's Apple build, in order: the manifest above its `#if os(Linux)` block,
    whose test targets (CmuxMobileLinkFFILinuxTests) exist only on the Linux package lane."""
    import re

    text = package.read_text().split("\n#if os(Linux)", 1)[0]
    return list(dict.fromkeys(re.findall(r'\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"', text)))


def split(mode: str, bundles: list[str], mac_stays: list[str]) -> tuple[list[str], list[str]]:
    """(the Mac's bundles, the pool's bundles) for MODE."""
    runnable = [b for b in bundles if b not in SKIP_EVERYWHERE]
    if mode == "shadow":
        return runnable, runnable
    if mode == "on":
        stays = set(mac_stays)
        return [b for b in runnable if b in stays], [b for b in runnable if b not in stays]
    return runnable, []


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ("mac", "fallback", "pool"):
        print(__doc__, file=sys.stderr)
        return 2
    part = argv[1]
    mode = os.environ.get("CMUX_IOS_SIM_LINUX") or "shadow"
    package = Path(os.environ.get("CMUX_IOS_SIM_BUNDLES") or ROOT / "cmux-next-ios/CmuxMobileKit/Package.swift")
    stays_file = Path(os.environ.get("CMUX_IOS_SIM_MAC_BUNDLES") or ROOT / "scripts/ci/ios-sim-mac-bundles.txt")
    stays = read_list(stays_file)
    # The kit-sim-pool jobs check out scripts/ci only: without Package.swift the pool part still works (it needs
    # only the names it skips), and the bundle checks below run where the package is (the kit job, the tests).
    bundles = all_bundles(package) if package.is_file() else []
    if package.is_file() and not bundles:
        print(f"ios_sim_bundles: no testTarget in {package}", file=sys.stderr)
        return 2
    unknown = [s for s in stays if bundles and s not in bundles]
    if unknown:
        print(f"ios_sim_bundles: {stays_file} names bundles the kit does not have: {', '.join(unknown)}", file=sys.stderr)
        return 2
    if part == "pool":
        if mode not in ("shadow", "on"):
            print("none", file=sys.stderr)
            return 3
        skips = list(SKIP_EVERYWHERE) + (stays if mode == "on" else [])
        if bundles and not split(mode, bundles, stays)[1]:
            print("none", file=sys.stderr)
            return 3
        for name in dict.fromkeys(skips):
            print("--arg")
            print(f"skip={name}")
        return 0
    if not bundles:
        print(f"ios_sim_bundles: no {package}", file=sys.stderr)
        return 2
    mac, pool = split(mode, bundles, stays)
    share = pool if part == "fallback" and mode == "on" else mac
    if share == [b for b in bundles if b not in SKIP_EVERYWHERE]:
        # Every runnable bundle: the skip form, as before, so a new test target runs without an edit here.
        for name in SKIP_EVERYWHERE:
            print(f"-skip-testing:{name}")
    else:
        for name in share:
            print(f"-only-testing:{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
