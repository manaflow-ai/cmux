#!/usr/bin/env python3
"""Rewrite an .xctestrun so agent-sim runs its logic-test targets.

`xcodebuild build-for-testing` on a Swift package (CmuxMobileKit-Package) writes every test target as a logic
test: no app hosts it, so xcodebuild runs it under Xcode's `xctest` agent, and the .xctestrun says so with
TestHostPath = __PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest. agent-sim reads any
TestHostPath as "app-hosted" and refuses the target ("app-hosted unit bundles are not supported yet"), so every kit
run on a pool phone ended with 0 tests and one error per target (17 for CmuxMobileKit).

A host that is not an .app is the xctest tool itself, which agent-sim already runs the bundle under (the runtime's
own Developer/usr/bin/xctest). Dropping that TestHostPath (and its bundle id) makes agent-sim run the bundle as the
logic test it is. Targets hosted by a real .app (app-hosted unit tests, UI tests' runners) are left as they are.

Usage: ios_sim_logic_xctestrun.py IN.xctestrun OUT.xctestrun
Prints one line per rewritten target. OUT must sit beside IN: __TESTROOT__ is the file's own directory.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path
from typing import Any

HOST_KEYS = ("TestHostPath", "TestHostBundleIdentifier")


def _targets(plist: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    out: list[tuple[str, dict[str, Any]]] = []
    configs = plist.get("TestConfigurations")
    if isinstance(configs, list):
        for config in configs:
            if not isinstance(config, dict):
                continue
            for target in config.get("TestTargets") or []:
                if isinstance(target, dict):
                    out.append((str(target.get("BlueprintName", config.get("Name", ""))), target))
        return out
    for name, value in plist.items():
        if name != "__xctestrun_metadata__" and isinstance(value, dict) and "TestBundlePath" in value:
            out.append((name, value))
    return out


def is_tool_hosted(target: dict[str, Any]) -> bool:
    """A logic test: its host is a tool (Xcode's xctest agent), not an app."""
    host = target.get("TestHostPath")
    if not isinstance(host, str) or not host:
        return False
    if target.get("IsUITestBundle") is True:
        return False
    return not host.rstrip("/").endswith(".app")


def rewrite(plist: dict[str, Any]) -> list[str]:
    """Drops the tool host from every logic-test target in place; returns the names it changed."""
    changed: list[str] = []
    for name, target in _targets(plist):
        if not is_tool_hosted(target):
            continue
        host = target["TestHostPath"]
        bundle = target.get("TestBundlePath")
        # A bundle path relative to the host would lose its anchor; such a target is not a plain logic test.
        if isinstance(bundle, str) and "__TESTHOST__" in bundle:
            continue
        for key in HOST_KEYS:
            target.pop(key, None)
        changed.append(f"{name}: dropped tool host {host}")
    return changed


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    src, dst = Path(argv[1]), Path(argv[2])
    with src.open("rb") as f:
        plist = plistlib.load(f)
    changed = rewrite(plist)
    with dst.open("wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_XML)
    for line in changed:
        print(f"ios_sim_logic_xctestrun: {line}")
    print(f"ios_sim_logic_xctestrun: {len(changed)} logic-test target(s) run without a host")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
