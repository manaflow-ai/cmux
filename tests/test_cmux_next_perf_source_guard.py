#!/usr/bin/env python3
"""The perf source guard (scripts/cmux-next/check-perf-source-guard.py) and where it runs.

The perf gate's source guard ran only inside the perf gate, which needs the scheme compile; a direct
push to feat-cmux-next skips that, and two hits landed (36c5b4217488 window captures for the
screenshot actions, 715f623c97e1 a popup's CATransaction.flush). The guard now runs alone in the
`cmux-next checks` job and in the pre-push gate, and the tree it guards is clean.
"""
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-perf-source-guard.py"
SPEC = importlib.util.spec_from_file_location("perf_source_guard", SCRIPT)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

SOURCES = "Packages/macOS/CmuxNext/Sources"


class ScanFileTests(unittest.TestCase):
    def test_a_flush_is_a_hit_anywhere(self):
        hits = guard.scan_file(f"{SOURCES}/CmuxNextApp/Theme/Blend.swift", "    CATransaction.flush()\n")
        self.assertEqual(len(hits), 1)
        self.assertIn("Blend.swift:1: CATransaction.flush forces a commit", hits[0])

    def test_a_screenshot_helper_called_elsewhere_is_a_capture(self):
        hits = guard.scan_file(f"{SOURCES}/CmuxNextApp/Theme/Blend.swift", "let image = try await window.screenshotImage()\n")
        self.assertEqual(len(hits), 1)

    def test_a_capture_outside_the_capture_files_is_a_hit(self):
        hits = guard.scan_file(f"{SOURCES}/CmuxNextApp/Theme/Blend.swift", "let image = window.compositedSnapshot(in: r)\n")
        self.assertEqual(len(hits), 1)
        self.assertIn("window capture", hits[0])
        # The screenshot folder's other files are not the capture.
        self.assertEqual(len(guard.scan_file(f"{SOURCES}/CmuxNextApp/Screenshots/ScreenshotsPageService.swift",
                                             "let image = window.compositedSnapshot(in: r)\n")), 1)

    def test_the_capture_helpers_screenshot_actions_and_debug_tools_may_capture(self):
        for rel in (f"{SOURCES}/CmuxNextDesign/Windows/NSWindow+Snapshot.swift",
                    f"{SOURCES}/CmuxNextDesign/Windows/NSWindow+Screenshot.swift",
                    f"{SOURCES}/CmuxNextApp/Screenshots/AppWindowImage.swift",
                    f"{SOURCES}/CmuxNextApp/Control/DebugCapture.swift"):
            self.assertEqual(guard.scan_file(rel, "let image = window.compositedSnapshot(in: r)\n"), [], rel)

    def test_a_reason_on_the_line_or_above_it_allows_a_hit(self):
        rel = f"{SOURCES}/CmuxNextDesign/Motion/Fade.swift"
        self.assertEqual(guard.scan_file(rel, "CATransaction.flush() // perf-gate-ok: once per open\n"), [])
        self.assertEqual(guard.scan_file(rel, "// perf-gate-ok: once per open\nCATransaction.flush()\n"), [])

    def test_an_empty_reason_or_a_comment_is_not_a_hit_or_an_exception(self):
        rel = f"{SOURCES}/CmuxNextDesign/Motion/Fade.swift"
        self.assertEqual(len(guard.scan_file(rel, "CATransaction.flush() // perf-gate-ok:\n")), 1)
        self.assertEqual(guard.scan_file(rel, "// CATransaction.flush() would force a commit\n"), [])


class ScriptTests(unittest.TestCase):
    def run_on(self, files: dict[str, str]) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            for rel, text in files.items():
                path = Path(tmp, rel)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return subprocess.run([sys.executable, "-I", str(SCRIPT), tmp], capture_output=True, text=True)

    def test_it_exits_1_and_prints_each_hit_as_path_line_rule(self):
        result = self.run_on({f"{SOURCES}/A/B.swift": "x\nCATransaction.flush()\n"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(),
                         [f"{SOURCES}/A/B.swift:2: CATransaction.flush forces a commit: CATransaction.flush()"])

    def test_it_passes_a_clean_tree_and_one_without_the_package(self):
        self.assertEqual(self.run_on({f"{SOURCES}/A/B.swift": "let x = 1\n"}).returncode, 0)
        self.assertEqual(self.run_on({"README.md": "x\n"}).returncode, 0)


class WiringTests(unittest.TestCase):
    def test_the_checks_job_runs_it_and_reads_its_outcome(self):
        workflow = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        step = re.search(r"- name: (Perf source guard[^\n]*)\n\s+id: perf-source-guard\n", workflow)
        self.assertIsNotNone(step, "the checks job has no `perf-source-guard` step")
        self.assertIn("python3 -I scripts/cmux-next/check-perf-source-guard.py", workflow)
        self.assertIn(f"${{{{ steps.perf-source-guard.outcome }}}}|{step.group(1)}", workflow)

    def test_the_pre_push_gate_runs_it_on_cmux_next_sources(self):
        gate = (ROOT / "scripts/cmux-next/prepush-gate.py").read_text(encoding="utf-8")
        self.assertRegex(gate, r'\("Perf source guard[^"]*",\s*\["python3", "-I", "\{s\}/check-perf-source-guard\.py", "\{root\}"\]')

    def test_the_perf_gate_uses_the_same_rule(self):
        perf_gate = (ROOT / "scripts/cmux-next/perf-gate.py").read_text(encoding="utf-8")
        self.assertIn("check-perf-source-guard.py", perf_gate)
        self.assertRegex(perf_gate, r"def source_guard\(\):\n    hits, count = perf_source_guard\.scan\(ROOT\)")
        self.assertNotIn("CATransaction\\.flush", perf_gate)


class TreeTests(unittest.TestCase):
    def test_the_app_sources_have_no_hits(self):
        hits, count = guard.scan(str(ROOT))
        self.assertGreater(count, 1000)
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
