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
scripts/cmux-next/chromium-objc-contract.json. Each entry has a verdict and a
reason:

- `implemented`: the entry's `owner` (CmuxApplication, an NSApplication
  extension, or AppDelegate) declares `@objc(<selector>)` (checked in the
  sources);
- `appkit`: AppKit's NSApplication / NSObject answers it on every macOS the
  app supports (reviewed by hand, not decided by the CI Mac's macOS);
- `guarded`: the sender checks `respondsToSelector:` / `conformsToProtocol:` first;
- `not-reachable`: Chromium never sends it to NSApp or its delegate in cmux.

The contract also lists every NSApplication subclass in the engine with its
role (`NSApp`, or `ignored: <reason>`), so a new application class fails the
check until someone reviews it.

With `--framework PATH` (macOS, Xcode tools), standard tools read the engine binary:

- `xcrun dyld_info -objc` gives the classes and their instance methods;
- `xcrun dyld_info -fixups` plus `otool -v -s __TEXT __objc_methname` give the
  selectors the binary references. Today every implemented method is
  referenced, so this filter keeps them all; it only drops a method the
  binary cannot send.

Candidates are the methods of the NSApp-role classes (receiver NSApp) and of
`AppController` (receiver NSApp.delegate). A candidate that the contract does
not list fails the check, and so does a contract entry that is no longer a
candidate. Each CEF bump therefore reviews every new selector. `--write`
merges the candidates into the contract: new ones come in as `unreviewed`
(the reason says whether this Mac's AppKit answers them), stale ones are
dropped, and `reviewed_for` / `reviewed_sha256` are set from
scripts/cmux-next/cef-manifest.json.

Without `--framework` (Linux CI, the crash-class job) the script checks only
the contract, against the sources and the manifest:

- every `implemented` selector is declared on its owner;
- no entry is `unreviewed`, and each one has a reason;
- `reviewed_for` and `reviewed_sha256` match the pinned engine, so a CEF bump
  fails until the new engine is reviewed.

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
DELEGATE_CLASS = "AppController"
VERDICTS = {"implemented", "appkit", "guarded", "not-reachable"}
# The Swift types that may implement a selector for each receiver.
OWNERS = {"NSApp": {"CmuxApplication", "NSApplication"}, "NSApp.delegate": {"AppDelegate"}}


def tool(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def binary(framework: Path) -> Path:
    return framework / "Chromium Embedded Framework" if framework.is_dir() else framework


def referenced_selectors(path: Path) -> set[str]:
    names = {}
    for line in tool("otool", "-arch", "arm64", "-v", "-s", "__TEXT", "__objc_methname", str(path)).splitlines():
        m = re.match(r"([0-9a-f]{16})\s+(\S+)$", line)
        if m:
            names[int(m.group(1), 16)] = m.group(2)
    refs = set()
    for line in tool("xcrun", "dyld_info", "-arch", "arm64", "-fixups", str(path)).splitlines():
        m = re.search(r"__objc_selrefs\s+0x[0-9A-Fa-f]+\s+rebase\s+0x([0-9A-Fa-f]+)", line)
        if m and int(m.group(1), 16) in names:
            refs.add(names[int(m.group(1), 16)])
    if len(refs) < 100:
        raise SystemExit(f"check-cef-objc-contract: read {len(refs)} selector references (tool output changed?)")
    return refs


def classes(path: Path) -> tuple[dict[str, str], dict[str, set[str]]]:
    """(class -> superclass, class -> instance methods) from `dyld_info -objc`."""
    supers: dict[str, str] = {}
    methods: dict[str, set[str]] = {}
    for line in tool("xcrun", "dyld_info", "-arch", "arm64", "-objc", str(path)).splitlines():
        m = re.match(r"\s+@interface (\w+)(?:\([\w ]*\))?\s*(?::\s*(\w+))?", line)
        if m and m.group(2):
            supers.setdefault(m.group(1), m.group(2))
            continue
        m = re.match(r"\s+0x[0-9A-Fa-f]+\s+-\[(\w+)(?:\([\w ]*\))? ([^\]\s]+)\]", line)
        if m and not m.group(2).startswith("."):
            methods.setdefault(m.group(1), set()).add(m.group(2))
    return supers, methods


def application_subclasses(supers: dict[str, str]) -> set[str]:
    def is_app(cls: str, seen: frozenset = frozenset()) -> bool:
        parent = supers.get(cls)
        return parent == "NSApplication" or (parent is not None and parent not in seen and is_app(parent, seen | {cls}))
    return {cls for cls in supers if is_app(cls)}


def appkit_answers(cls: str, selector: str) -> bool | None:
    if sys.platform != "darwin":
        return None
    import ctypes

    objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
    ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
    objc.objc_getClass.restype, objc.objc_getClass.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    objc.sel_registerName.restype, objc.sel_registerName.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    objc.class_respondsToSelector.restype = ctypes.c_bool
    objc.class_respondsToSelector.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    return bool(objc.class_respondsToSelector(objc.objc_getClass(cls.encode()), objc.sel_registerName(selector.encode())))


def read_engine(framework: Path, roles: dict[str, str]) -> tuple[dict[tuple[str, str], str], set[str]]:
    """(receiver, selector) -> Chromium class for every candidate, and the engine's NSApplication subclasses."""
    path = binary(framework)
    refs = referenced_selectors(path)
    supers, methods = classes(path)
    app_classes = application_subclasses(supers)
    if "BrowserCrApplication" not in app_classes or DELEGATE_CLASS not in methods:
        raise SystemExit("check-cef-objc-contract: Chromium's application classes not found (tool output changed?)")
    out: dict[tuple[str, str], str] = {}
    for cls in sorted(app_classes):
        if roles.get(cls) == "NSApp":
            for selector in sorted(methods.get(cls, set()) & refs):
                out.setdefault(("NSApp", selector), cls)
    for selector in sorted(methods[DELEGATE_CLASS] & refs):
        out.setdefault(("NSApp.delegate", selector), DELEGATE_CLASS)
    return out, app_classes


def type_bodies(root: Path) -> dict[str, str]:
    """Swift type name -> the code of its class and extension bodies (comments and strings blanked)."""
    bodies: dict[str, list[str]] = {}
    decl = re.compile(r"\b(class|extension)\s+(\w+)\b[^{;]*\{")
    for path in (root / SOURCES).rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="replace")
        text = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"', lambda m: " " * len(m.group(0)), text, flags=re.S)
        for m in decl.finditer(text):
            depth, i = 1, m.end()
            while i < len(text) and depth:
                depth += {"{": 1, "}": -1}.get(text[i], 0)
                i += 1
            bodies.setdefault(m.group(2), []).append(text[m.end():i])
    return {name: "\n".join(parts) for name, parts in bodies.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--framework", type=Path, help="the engine's Chromium Embedded Framework.framework (macOS)")
    parser.add_argument("--write", action="store_true", help="with --framework: merge the candidates into the contract")
    opts = parser.parse_args()
    root = opts.root.resolve()
    contract_path = root / CONTRACT
    contract = json.loads(contract_path.read_text())
    manifest = json.loads((root / MANIFEST).read_text())
    roles: dict[str, str] = contract.setdefault("application_classes", {})
    entries = {(e["receiver"], e["selector"]): e for e in contract["selectors"]}
    failures: list[str] = []

    if opts.framework:
        found, app_classes = read_engine(opts.framework, roles)
        new = sorted(set(found) - set(entries))
        stale = sorted(set(entries) - set(found))
        new_classes = sorted(app_classes - set(roles))
        if opts.write:
            for cls in new_classes:
                roles[cls] = "unreviewed"
            for key in new:
                answers = appkit_answers("NSApplication" if key[0] == "NSApp" else "NSObject", key[1])
                hint = {True: "AppKit answers it on this Mac; check every supported macOS",
                        False: "AppKit does not answer it", None: ""}[answers]
                entries[key] = {"receiver": key[0], "selector": key[1], "chromium_class": found[key],
                                "verdict": "unreviewed", "reason": hint}
            for key in stale:
                del entries[key]
            contract["reviewed_for"], contract["reviewed_sha256"] = manifest["version"], manifest["sha256"]
            contract["application_classes"] = dict(sorted(roles.items()))
            contract["selectors"] = [entries[k] for k in sorted(entries)]
            contract_path.write_text(json.dumps(contract, indent=1) + "\n")
            print(f"check-cef-objc-contract: {len(new)} new selectors and {len(new_classes)} new classes "
                  f"(unreviewed), {len(stale)} removed; review {CONTRACT}")
        else:
            failures += [f"Chromium can send {sel} to {recv} ({found[(recv, sel)]}), not in {CONTRACT}: "
                         f"run --framework ... --write and review it" for recv, sel in new]
            failures += [f"{CONTRACT}: {recv} {sel} is no longer a candidate in this engine: remove it" for recv, sel in stale]
            failures += [f"the engine has a new NSApplication subclass {cls}: add it to application_classes "
                         f"in {CONTRACT} (NSApp, or ignored: <reason>)" for cls in new_classes]

    for key, want in (("reviewed_for", "version"), ("reviewed_sha256", "sha256")):
        if contract.get(key) != manifest[want]:
            failures.append(f"{CONTRACT} {key} is {contract.get(key)}, the pinned engine's {want} is {manifest[want]}: run "
                            f"scripts/cmux-next/check-cef-objc-contract.py --framework <engine> --write on a Mac and review")
    for cls, role in roles.items():
        if role != "NSApp" and not role.startswith("ignored: "):
            failures.append(f"{CONTRACT}: application class {cls}: role {role!r} (NSApp, or ignored: <reason>)")
    bodies = type_bodies(root)
    for entry in entries.values():
        where = f"{CONTRACT}: {entry['receiver']} {entry['selector']}"
        if entry["verdict"] not in VERDICTS:
            failures.append(f"{where}: verdict {entry['verdict']!r} (review it: {', '.join(sorted(VERDICTS))})")
        elif not entry.get("reason", "").strip():
            failures.append(f"{where}: verdict {entry['verdict']} needs a reason")
        elif entry["verdict"] == "implemented":
            owner = entry.get("owner")
            if owner not in OWNERS.get(entry["receiver"], set()):
                failures.append(f"{where}: owner {owner!r} cannot answer for {entry['receiver']} "
                                f"({' or '.join(sorted(OWNERS.get(entry['receiver'], set())))})")
            elif f"@objc({entry['selector']})" not in bodies.get(owner, ""):
                failures.append(f"{where}: verdict implemented, but {owner} declares no @objc({entry['selector']}) in {SOURCES}")

    for failure in failures:
        print(f"cef-objc-contract: {failure}", file=sys.stderr)
    print(f"check-cef-objc-contract: {len(entries)} selectors for {contract.get('reviewed_for')}, {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
