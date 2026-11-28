#!/usr/bin/env python3
"""CmuxMobileLiveTests compile on macOS too (the `ios macos` job runs the kit's `swift test`), so a test that names a
CmuxMobileLive type declared only under `#if os(iOS)` must sit inside an iOS-only region itself.

Base red 2026-11-28: SnapshotSaveGateTests.swift (#61498) called `LiveCoordinator.snapshotToSave` with no guard, and
`ios macos` failed with "cannot find 'LiveCoordinator' in scope".
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "cmux-next-ios" / "CmuxMobileKit"
SOURCES = KIT / "Sources" / "CmuxMobileLive"
TESTS = KIT / "Tests" / "CmuxMobileLiveTests"

IOS_ONLY = re.compile(r"^\s*#if\s+(os\(iOS\)|canImport\(UIKit\))")
IF = re.compile(r"^\s*#if\b")
ENDIF = re.compile(r"^\s*#endif\b")
# Top-level types only: a nested name (`Session`) is no global symbol.
DECL = re.compile(r"^(?:public |internal |private |fileprivate |@MainActor )*(?:final )?(?:class|struct|enum|actor)\s+(\w+)")
LOCAL_DECL = re.compile(r"^\s*(?:public |internal |private |fileprivate |@MainActor )*(?:final )?(?:class|struct|enum|actor)\s+(\w+)")


def ios_only_lines(text: str) -> list[bool]:
    """Per line: True when it sits inside an `#if os(iOS)` / `#if canImport(UIKit)` region (any depth)."""
    stack: list[bool] = []
    out = []
    for line in text.splitlines():
        if IF.match(line):
            stack.append(bool(IOS_ONLY.match(line)))
            out.append(any(stack))
            continue
        if ENDIF.match(line):
            out.append(any(stack))
            if stack:
                stack.pop()
            continue
        out.append(any(stack))
    return out


def ios_only_types() -> set[str]:
    names = set()
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        guarded = ios_only_lines(text)
        for line, inside in zip(text.splitlines(), guarded):
            m = DECL.match(line)
            if m and inside:
                names.add(m.group(1))
    # A type also declared outside any iOS region exists on macOS.
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for line, inside in zip(text.splitlines(), ios_only_lines(text)):
            m = DECL.match(line)
            if m and not inside:
                names.discard(m.group(1))
    return names


def unguarded_uses(text: str, names: set[str]) -> list[tuple[int, str]]:
    # A test that declares its own type of that name (a local fake) uses its own.
    names = names - {m.group(1) for m in map(LOCAL_DECL.match, text.splitlines()) if m}
    if not names:
        return []
    use = re.compile(r"\b(" + "|".join(sorted(map(re.escape, names))) + r")\s*[.(]")
    hits = []
    for number, (line, inside) in enumerate(zip(text.splitlines(), ios_only_lines(text)), 1):
        code = line.split("//", 1)[0]
        if inside or "`" in code:
            continue
        m = use.search(code)
        if m:
            hits.append((number, m.group(1)))
    return hits


class LiveTestsGuardIOSOnlyTypes(unittest.TestCase):
    def test_live_coordinator_is_ios_only(self):
        self.assertIn("LiveCoordinator", ios_only_types())

    def test_no_live_test_names_an_ios_only_type_outside_an_ios_region(self):
        names = ios_only_types()
        bad = []
        for path in sorted(TESTS.rglob("*.swift")):
            for number, name in unguarded_uses(path.read_text(encoding="utf-8"), names):
                bad.append(f"{path.relative_to(ROOT)}:{number}: {name}")
        self.assertEqual(bad, [], "wrap these in `#if os(iOS)` (the `ios macos` job compiles them on macOS)")

    def test_the_detector_reads_the_red_that_shipped(self):
        red = "import Testing\n@Suite struct T {\n    let i = LiveCoordinator.snapshotStampInterval\n}\n"
        self.assertEqual(unguarded_uses(red, {"LiveCoordinator"}), [(3, "LiveCoordinator")])
        fixed = "#if os(iOS)\n" + red + "#endif\n"
        self.assertEqual(unguarded_uses(fixed, {"LiveCoordinator"}), [])
        nested = "@Suite struct T {\n    #if os(iOS)\n    let i = LiveCoordinator.x\n    #endif\n}\n"
        self.assertEqual(unguarded_uses(nested, {"LiveCoordinator"}), [])


if __name__ == "__main__":
    unittest.main()
