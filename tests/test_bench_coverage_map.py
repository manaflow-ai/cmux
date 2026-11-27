#!/usr/bin/env python3
"""docs/benches/coverage-map.md lists every bench and every risky path; this keeps it whole.

Leo, 2026-11-27: "did we map out all the benches of everything else too?" The map is the answer, and
it only stays one if a new bench, or a new risky area, cannot land without a row. The test fails when:

  - a bench registered in scripts/bench/benches/ is missing from the cmux-bench table (or the table
    names one that is not registered);
  - a Swift bench suite in a Tests/ or UITests/ folder is missing from the Swift table (or a listed
    one has gone);
  - a Rust bench in a crate's benches/ folder, or a webviews/bench/ bench file, has no row;
  - a risky path this file requires is missing from the risky paths table, or any listed path or
    glob matches nothing in the tree.
"""
from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAP = ROOT / "docs/benches/coverage-map.md"

# The areas where one change can freeze the main thread at scale. cmux#59531 (2-6 s hangs at 1,100
# workspaces) went through the first three. Adding a risky area means adding it here and in the map.
REQUIRED_RISKY = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeRules.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextChiefPetWiring/WelcomeRule.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextChiefPetWiring/ChiefMascotPicks.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar",
    "Packages/macOS/CmuxNext/Sources/CmuxNextBridge/SidebarMapping+Face.swift",
    "cmux-tui/crates/cmux-home-rules",
    "cmux-tui/crates/cmux-app-ffi",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp",
    "cmux-tui/crates/acpmux",
    "cmux-tui/crates/acpmux-core",
    "cmux-tui/crates/cmux-chat-index",
    "webviews/src/agent-session",
    "webviews/src/sidebar",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive",
    "cmux-tui/crates/cmux-relay",
)

# A bench suite, not a helper: `…Bench`, `…BenchTests`, `…Benchmark`, `…BenchmarkTests`, `…BenchParse`,
# `…Bench…UITests`, `…PerformanceTests`. `BenchError`, `BenchHost` and `WorkspaceBenchmarkDaemon` are not.
SUITE_NAME = re.compile(r"^\w+Bench(?:mark)?(?:Tests|UITests|Parse)?$|^\w+Bench\w+UITests$|^\w+PerformanceTests$")
SWIFT_ROOTS = ("Packages", "cmux-next-ios")


def sections(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for part in re.split(r"^## ", text, flags=re.M)[1:]:
        head, _, body = part.partition("\n")
        out[head.strip()] = body
    return out


def first_cells(body: str, column: int = 0) -> list[str]:
    """The backticked value of one column in each table row."""
    values = []
    for line in body.splitlines():
        if not line.startswith("|") or set(line) <= set("|-: "):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if column < len(cells):
            values += re.findall(r"`([^`]+)`", cells[column])
    return values


def registered_benches() -> set[str]:
    sys.path.insert(0, str(ROOT / "scripts/bench"))
    from benchlib.registry import load_all
    return set(load_all())


def tracked(*specs: str) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z", "--", *specs], cwd=ROOT, check=True, capture_output=True).stdout
    return sorted(filter(None, out.decode().split("\0")))


def swift_suites() -> dict[str, str]:
    """Bench suite types declared under a `…Tests` folder (git grep: one pass, no file reads in Python)."""
    out = subprocess.run(["git", "grep", "-o", "-E", r"(struct|class|enum|actor) +[A-Za-z0-9_]*(Bench|PerformanceTests)[A-Za-z0-9_]*",
                          "--", *(f"{root}/*Tests/*.swift" for root in SWIFT_ROOTS)],
                         cwd=ROOT, capture_output=True, text=True)
    if out.returncode not in (0, 1):
        raise RuntimeError(out.stderr)
    found: dict[str, str] = {}
    for line in sorted(out.stdout.splitlines()):
        rel, _, decl = line.partition(":")
        name = decl.split()[-1]
        if SUITE_NAME.match(name) and any(folder.endswith("Tests") for folder in rel.split("/")[:-1]):
            found.setdefault(name, rel)
    return found


def tree_has(pattern: str) -> bool:
    if any(ch in pattern for ch in "*?["):
        return any(fnmatch.fnmatch(rel, pattern) for rel in tracked(pattern.split("*")[0].rsplit("/", 1)[0]))
    return (ROOT / pattern).exists()


class BenchCoverageMapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parts = sections(MAP.read_text(encoding="utf-8"))

    def section(self, name: str) -> str:
        self.assertIn(name, self.parts, f"{MAP.relative_to(ROOT)} has no '## {name}' section")
        return self.parts[name]

    def test_every_registered_bench_has_a_row(self):
        listed = set(first_cells(self.section("cmux-bench registry")))
        registered = registered_benches()
        self.assertFalse(sorted(registered - listed), "registered benches missing from the map's cmux-bench table")
        self.assertFalse(sorted(listed - registered), "the map's cmux-bench table lists benches that are not registered")

    def test_every_swift_bench_suite_has_a_row(self):
        body = self.section("Swift bench suites")
        listed = set(first_cells(body, 0))
        found = swift_suites()
        missing = {name: path for name, path in found.items() if name not in listed}
        self.assertFalse(missing, "Swift bench suites missing from the map's Swift table")
        pending = {n for line in body.splitlines() if "| pending lane/" in line for n in re.findall(r"^\|\s*`([^`]+)`", line)}
        gone = sorted(listed - set(found) - pending)
        self.assertFalse(gone, "the map's Swift table lists suites that no Tests/ folder defines")
        for path in first_cells(body, 1):
            self.assertTrue((ROOT / path).is_file(), f"the Swift table names {path}, which does not exist")

    def test_every_rust_bench_has_a_row(self):
        listed = set(first_cells(self.section("Rust benches")))
        found = {f for f in tracked("cmux-tui/crates") if re.fullmatch(r"cmux-tui/crates/[^/]+/benches/[^/]+\.rs", f)}
        self.assertFalse(sorted(found - listed), "Rust benches missing from the map's Rust table")
        self.assertFalse(sorted(listed - found), "the map's Rust table lists benches that do not exist")

    def test_every_web_bench_matches_a_glob(self):
        globs = first_cells(self.section("Web benches"))
        files = [f for f in tracked("webviews/bench") if fnmatch.fnmatch(f, "*.bench.ts*")]
        self.assertTrue(files, "no webviews/bench/*.bench.ts files found")
        unmatched = [f for f in files if not any(fnmatch.fnmatch(f, g) for g in globs)]
        self.assertFalse(unmatched, "web benches no glob in the map's web table matches")
        for glob in globs:
            self.assertTrue(any(fnmatch.fnmatch(f, glob) for f in files), f"the web table's {glob} matches no bench")

    def test_every_risky_path_is_mapped_and_exists(self):
        listed = first_cells(self.section("Risky paths"), 2)
        missing = [p for p in REQUIRED_RISKY if p not in listed]
        self.assertFalse(missing, "risky paths missing from the map's risky paths table")
        for path in listed:
            self.assertTrue(tree_has(path), f"the risky paths table names {path}, which matches nothing")


if __name__ == "__main__":
    unittest.main()
