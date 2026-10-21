#!/usr/bin/env python3
"""Defensive build-time compatibility check for the cmux app and its bundled Chromium engine.

cmux embeds the Chromium Embedded Framework (CEF), but the app's NSApp is
cmux's `CmuxApplication` and NSApp.delegate is cmux's `AppDelegate`, not
Chromium's `BrowserCrApplication` / `AppController`. When Chromium sends one
of its own application-class selectors to them without a
`respondsToSelector:` / `conformsToProtocol:` check, and cmux does not
implement it, the app ends with "unrecognized selector sent to instance"
(2026-10-20: `-[CmuxApplication cancelTerminate:]`, #22745).

This lists those selectors and compares them with the reviewed list in
scripts/cmux-next/chromium-objc-contract.json. Every entry there has a
verdict:

- `implemented`: cmux declares `@objc(<selector>)` (checked in the sources);
- `guarded`: the sender checks `respondsToSelector:` / `conformsToProtocol:` first;
- `not-reachable`: Chromium never sends it to NSApp or its delegate in cmux.

Every verdict other than `implemented` carries a reason (the reviewed call
site, when there is one).

With `--framework PATH` (macOS, Xcode tools) the selector list comes from the
engine binary itself, using standard tools:

- `xcrun dyld_info -objc` gives the methods of Chromium's application classes;
- `xcrun dyld_info -fixups` and `otool -v -s __TEXT __objc_methname` give the
  selectors the binary references.

A method of those classes that the binary references, and that AppKit's
NSApplication (or NSObject, for the delegate) does not already answer, is a
candidate. A candidate that the contract does not list fails the check, and so
does a contract entry that is no longer a candidate. Each CEF version bump
therefore reviews every new selector. `--write` merges the candidates into the
contract: new ones come in as `unreviewed`, stale ones are dropped.

Without `--framework` (Linux CI, the crash-class job) the script checks only
the contract against the sources and against scripts/cmux-next/cef-manifest.json:

- every `implemented` selector is declared;
- no entry is `unreviewed`;
- `reviewed_for` names the pinned engine version, so a CEF bump fails until
  someone runs `--framework ... --write` on a Mac and reviews the result.

Usage: scripts/cmux-next/check-cef-objc-contract.py [--framework PATH] [--write] [--root REPO]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

CONTRACT = "scripts/cmux-next/chromium-objc-contract.json"
MANIFEST = "scripts/cmux-next/cef-manifest.json"
SOURCES = "Packages/macOS/CmuxNext/Sources"
# Chromium's class for each cmux-owned receiver, and the AppKit class whose answers cmux inherits.
ROLES = {
    "BrowserCrApplication": ("NSApp", "NSApplication"),
    "CrApplication": ("NSApp", "NSApplication"),
    "AppController": ("NSApp.delegate", "NSObject"),
}
VERDICTS = {"implemented", "guarded", "not-reachable"}


def tool(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def binary(framework: Path) -> Path:
    return framework / "Chromium Embedded Framework" if framework.is_dir() else framework


def referenced_selectors(path: Path) -> set[str]:
    names = {}
    for line in tool("otool", "-v", "-s", "__TEXT", "__objc_methname", str(path)).splitlines():
        m = re.match(r"([0-9a-f]{16})\s+(\S+)$", line)
        if m:
            names[int(m.group(1), 16)] = m.group(2)
    refs = set()
    for line in tool("xcrun", "dyld_info", "-fixups", str(path)).splitlines():
        m = re.search(r"__objc_selrefs\s+0x[0-9A-Fa-f]+\s+rebase\s+0x([0-9A-Fa-f]+)", line)
        if m and int(m.group(1), 16) in names:
            refs.add(names[int(m.group(1), 16)])
    if not refs:
        raise SystemExit("check-cef-objc-contract: no selector references read (tool output changed?)")
    return refs


def role_methods(path: Path) -> dict[str, set[str]]:
    methods: dict[str, set[str]] = {cls: set() for cls in ROLES}
    for line in tool("xcrun", "dyld_info", "-objc", str(path)).splitlines():
        m = re.match(r"\s+0x[0-9A-Fa-f]+\s+-\[(\w+)(?:\([\w ]*\))? ([^\]\s]+)\]", line)
        if m and m.group(1) in methods and not m.group(2).startswith("."):
            methods[m.group(1)].add(m.group(2))
    if not methods["BrowserCrApplication"]:
        raise SystemExit("check-cef-objc-contract: BrowserCrApplication not found (tool output changed?)")
    return methods


def appkit_answers(cls: str, selector: str) -> bool:
    import ctypes

    objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
    ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
    objc.objc_getClass.restype, objc.objc_getClass.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    objc.sel_registerName.restype, objc.sel_registerName.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    objc.class_respondsToSelector.restype = ctypes.c_bool
    objc.class_respondsToSelector.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    return bool(objc.class_respondsToSelector(objc.objc_getClass(cls.encode()), objc.sel_registerName(selector.encode())))


def candidates(framework: Path) -> dict[tuple[str, str], str]:
    """(receiver, selector) -> Chromium class, for every selector cmux could be sent."""
    path = binary(framework)
    refs, methods = referenced_selectors(path), role_methods(path)
    out = {}
    for cls, (receiver, appkit) in ROLES.items():
        for selector in sorted(methods[cls] & refs):
            if not appkit_answers(appkit, selector):
                out.setdefault((receiver, selector), cls)
    return out


def declared_selectors(root: Path) -> set[str]:
    found = set()
    for path in (root / SOURCES).rglob("*.swift"):
        found.update(re.findall(r"@objc\(([\w:]+)\)", path.read_text(encoding="utf-8", errors="replace")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--framework", type=Path, help="the engine's Chromium Embedded Framework.framework (macOS)")
    parser.add_argument("--write", action="store_true", help="with --framework: merge the candidates into the contract")
    opts = parser.parse_args()
    root = opts.root.resolve()
    contract_path = root / CONTRACT
    contract = json.loads(contract_path.read_text())
    version = json.loads((root / MANIFEST).read_text())["version"]
    entries = {(e["receiver"], e["selector"]): e for e in contract["selectors"]}
    failures: list[str] = []

    if opts.framework:
        found = candidates(opts.framework)
        new = sorted(set(found) - set(entries))
        stale = sorted(set(entries) - set(found))
        if opts.write:
            for key in new:
                entries[key] = {"receiver": key[0], "selector": key[1], "chromium_class": found[key],
                                "verdict": "unreviewed", "reason": ""}
            for key in stale:
                del entries[key]
            contract["reviewed_for"] = version
            contract["selectors"] = [entries[k] for k in sorted(entries)]
            contract_path.write_text(json.dumps(contract, indent=1) + "\n")
            print(f"check-cef-objc-contract: {len(new)} new (unreviewed), {len(stale)} removed; review {CONTRACT}")
        else:
            failures += [f"Chromium can send {sel} to {recv} ({found[(recv, sel)]}), not in {CONTRACT}: "
                         f"run --framework ... --write and review it" for recv, sel in new]
            failures += [f"{CONTRACT}: {recv} {sel} is no longer a candidate in this engine: remove it" for recv, sel in stale]

    if contract.get("reviewed_for") != version:
        failures.append(f"{CONTRACT} was reviewed for {contract.get('reviewed_for')}, the pinned engine is {version}: "
                        f"run scripts/cmux-next/check-cef-objc-contract.py --framework <engine> --write on a Mac and review")
    declared = declared_selectors(root)
    for entry in entries.values():
        where = f"{CONTRACT}: {entry['receiver']} {entry['selector']}"
        if entry["verdict"] not in VERDICTS:
            failures.append(f"{where}: verdict {entry['verdict']!r} (review it: {', '.join(sorted(VERDICTS))})")
        elif entry["verdict"] == "implemented" and entry["selector"] not in declared:
            failures.append(f"{where}: verdict implemented, but no @objc({entry['selector']}) in {SOURCES}")
        elif entry["verdict"] != "implemented" and not entry.get("reason", "").strip():
            failures.append(f"{where}: verdict {entry['verdict']} needs a reason")

    for failure in failures:
        print(f"cef-objc-contract: {failure}", file=sys.stderr)
    print(f"check-cef-objc-contract: {len(entries)} selectors for {contract.get('reviewed_for')}, {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
