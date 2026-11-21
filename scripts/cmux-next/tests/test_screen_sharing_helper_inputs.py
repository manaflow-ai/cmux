#!/usr/bin/env python3
"""The Screen Sharing helper's inputs are cmux-rd-host's path-dependency crates, no more, no less.

#44069 keyed the helper on all of cmux-tui/crates and named that folder in the Xcode phase
"Bundle Screen Sharing helper". The router reads the phase's inputs, so every daemon-only
Rust change (acpmux, cmux-app-host) routed to the app scheme compile and tests/test_cmux_next_route.py
went red on feat-cmux-next. The narrow list has the opposite risk: a new path dependency missing
from it leaves a stale cached helper. This test derives the closure from Cargo.toml and checks the
build script's cache key and the Xcode phase against it.

    python3 scripts/cmux-next/tests/test_screen_sharing_helper_inputs.py
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HOST = "cmux-tui/crates/cmux-rd-host"
SCRIPT = ROOT / "scripts/cmux-next/build-screen-sharing-helper.sh"
PROJECT = ROOT / "cmux.xcodeproj/project.pbxproj"
PHASE = "Bundle Screen Sharing helper"
CARGO_PATH = re.compile(r'\bpath\s*=\s*"([^"]+)"')


def crate_closure(root: Path, start: str) -> set[str]:
    """`start` and every crate it reaches through a Cargo path dependency (optional ones too)."""
    seen: set[str] = set()
    pending = [start]
    while pending:
        crate = pending.pop()
        manifest = root / crate / "Cargo.toml"
        if crate in seen or not manifest.is_file():
            continue
        seen.add(crate)
        for dep in CARGO_PATH.findall(manifest.read_text(encoding="utf-8")):
            resolved = (root / crate / dep).resolve()
            if (resolved / "Cargo.toml").is_file():
                pending.append(resolved.relative_to(root.resolve()).as_posix())
    return seen


# A `[target.'cfg(...)'.dependencies]` table the macOS helper never builds (Linux or Windows only).
NOT_MACOS_TABLE = re.compile(r"^\[target\.'cfg\((?:target_os\s*=\s*\"(?:linux|windows)\"|windows|unix,\s*not\(target_os\s*=\s*\"macos\"\))\)'\.[a-z-]*dependencies\]")


def macos_crate_closure(root: Path, start: str) -> set[str]:
    """The crates the macOS helper build compiles: `crate_closure` without the path dependencies of a
    Linux- or Windows-only target table or of a dev-dependencies table."""
    seen: set[str] = set()
    pending = [start]
    while pending:
        crate = pending.pop()
        manifest = root / crate / "Cargo.toml"
        if crate in seen or not manifest.is_file():
            continue
        seen.add(crate)
        built = True
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if line.startswith("["):
                built = not NOT_MACOS_TABLE.match(line) and "dev-dependencies" not in line
            elif built:
                for dep in CARGO_PATH.findall(line):
                    resolved = (root / crate / dep).resolve()
                    if (resolved / "Cargo.toml").is_file():
                        pending.append(resolved.relative_to(root.resolve()).as_posix())
    return seen


def script_inputs(text: str) -> set[str]:
    match = re.search(r"^inputs=\(([^)]*)\)", text, re.M)
    assert match, "build-screen-sharing-helper.sh has no inputs=( ... ) line"
    return set(match.group(1).split())


def phase_inputs(text: str) -> set[str]:
    match = re.search(r"/\* " + re.escape(PHASE) + r" \*/ = \{.*?\binputPaths = \((.*?)\n\t*\);", text, re.S)
    assert match, f"no {PHASE!r} phase in the Xcode project"
    return set(re.findall(r'"\$\(SRCROOT\)/(cmux-tui/[^"]+)"', match.group(1)))


class ScreenSharingHelperInputs(unittest.TestCase):
    def setUp(self):
        self.closure = crate_closure(ROOT, HOST)
        self.script = {p for p in script_inputs(SCRIPT.read_text(encoding="utf-8")) if p.startswith("cmux-tui/crates")}
        self.phase = {p for p in phase_inputs(PROJECT.read_text(encoding="utf-8")) if p.startswith("cmux-tui/crates")}

    def test_the_closure_is_read(self):
        self.assertIn(HOST, self.closure)
        self.assertIn("cmux-tui/crates/cmux-rd-proto", self.closure)

    def test_the_cache_key_names_exactly_the_closure(self):
        self.assertEqual(self.script, self.closure)

    def test_the_xcode_phase_names_every_crate_the_macos_build_compiles_and_none_outside_the_closure(self):
        # The cache key above decides when a cached helper is stale. The phase only tells Xcode (and the router)
        # when the app's helper can change: a crate only a Linux or Windows table names (cmux-file-lock, through
        # cmux-rd-host's Linux and Windows host) never changes the macOS helper.
        self.assertEqual(macos_crate_closure(ROOT, HOST) - self.phase, set(),
                         "a crate the macOS helper compiles is missing from the Xcode phase")
        self.assertEqual(self.phase - self.closure, set(), "the Xcode phase names a crate the helper never reaches")

    def test_the_macos_closure_drops_only_other_platform_crates(self):
        macos = macos_crate_closure(ROOT, HOST)
        self.assertIn("cmux-tui/crates/cmux-rd-proto", macos)
        self.assertNotIn("cmux-tui/crates/cmux-file-lock", macos)
        self.assertLessEqual(macos, self.closure)

    def test_neither_names_the_whole_crates_folder(self):
        for found in (self.script, self.phase):
            self.assertNotIn("cmux-tui/crates", found)
            self.assertNotIn("cmux-tui/crates/acpmux", found)


if __name__ == "__main__":
    sys.exit(unittest.main())
