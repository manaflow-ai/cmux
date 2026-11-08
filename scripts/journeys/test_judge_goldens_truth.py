#!/usr/bin/env python3
"""Tests of the judge goldens TRUTH tier and of the run's limits (judge_goldens.py; REWRITE R-HARNESS stage S1c).

    /work/tmp/bv-venv/bin/python -I scripts/journeys/test_judge_goldens_truth.py

BASELINE goldens pin what the judges said on the gallery films; a bless with a reason may change them. TRUTH goldens
are answers known without the judges: a pixel fact a judge-free ruler reads from a film's exact scan lines (a run of
one fixture color on one scan line, in exactly these frames), and what a judge must (or must not) report on that film.
A judge that misses a TRUTH answer fails the run and cannot be blessed; a ruler fact the film does not show means the
store or the fact is wrong: NO VERDICT. The judges' own unit tests (synthetic films with injected faults) are the
second part of the TRUTH tier and run in the same command.
"""
import json
import os
import struct
import subprocess
import sys
import textwrap
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import judge_goldens as jg  # noqa: E402
import test_judge_goldens as base  # noqa: E402

MAGENTA = (255, 0, 255)   # the fixture's shell color (RGB)
CYAN = (0, 255, 255)
WIDTH, ROWS = 64, [10]
BAND = (20, 35)           # x range of the magenta band
BAND_FRAMES = (3, 6)      # complete frames that show it


def write_scan(path, frames, band_frames=BAND_FRAMES, band=BAND):
    """A real scan file (the recorder's layout): one 64 px row per complete frame; cyan, with a magenta band at x
    band[0]..band[1] in frames band_frames[0]..band_frames[1]."""
    header = {"width": WIDTH, "height": 4, "rows": ROWS, "columns": [], "format": "BGRA", "time": "float64-le host seconds"}
    with open(path, "wb") as f:
        f.write(json.dumps(header).encode() + b"\n")
        for i in range(frames):
            f.write(struct.pack("<d", 100.0 + i / 120))
            for x in range(WIDTH):
                r, g, b = MAGENTA if band_frames[0] <= i <= band_frames[1] and band[0] <= x <= band[1] else CYAN
                f.write(bytes((b, g, r, 255)))


# A video judge stand-in that reports the band it is told to (or none), so a test can make it right or wrong.
STUB_VIDEO_BAND = '''
import json
from pathlib import Path
FRAMES = __FRAMES__
EXTRA = __EXTRA__
def judge(base, movie=True):
    findings = []
    if FRAMES:
        findings.append({"check": "gap or overlap", "severity": "defect", "frames": FRAMES, "t": [0, 0], "detail": "band"})
    for check in EXTRA:
        findings.append({"check": check, "severity": "defect", "frames": [0, 0], "t": [0, 0], "detail": "x"})
    # One motion window over the film, with trace samples and a tracked divider compared with the trace: a judged
    # film (an absence needs the judge to have looked: the input of its own check).
    return {"case": Path(str(base)).name, "base": str(base), "frames": 9, "dropped": 0,
            "motion": [{"a": 0, "b": 8}], "pacing": {"trace": True}, "tracked_dividers": 1, "model_lag": {"0": 9},
            "findings": findings}
'''


def video_stub(frames=list(BAND_FRAMES), extra=()):
    return STUB_VIDEO_BAND.replace("__FRAMES__", json.dumps(frames)).replace("__EXTRA__", json.dumps(list(extra)))


PASSING_UNIT_TESTS = '''
import unittest
class T(unittest.TestCase):
    def test_a(self): self.assertTrue(True)
    def test_b(self): self.assertTrue(True)
if __name__ == "__main__":
    unittest.main()
'''
FAILING_UNIT_TESTS = PASSING_UNIT_TESTS.replace("def test_b(self): self.assertTrue(True)",
                                                "def test_b(self): self.assertEqual(1, 2)")


class TruthWorkspace(base.Workspace):
    """The runner tests' workspace, one film with a real scan, its truth file, and judges with unit tests."""

    def __init__(self, video=None, unit=PASSING_UNIT_TESTS):
        super().__init__()
        folder = self.gallery / "px-build-120x2"
        base.write_film(folder, "px-keys", frames=9)
        write_scan(folder / "px-keys.mov.scan", 9)
        self.judges = base.write_judges(self.root / "judges", video=video or video_stub())
        (self.judges / "test_video_judge.py").write_text(textwrap.dedent(unit))
        self.film = "px-build-120x2/px-keys"

    def write_truth(self, ruler_frames=BAND_FRAMES, expect=None):
        fact = {"id": "px-keys-shell-band", "film": self.film, "why": "test",
                "ruler": {"line": "row", "at": ROWS[0], "class": "#FF00FF", "x": [BAND[0] - 2, BAND[0] + 2],
                          "frames": list(ruler_frames), "min_run_px": 8},
                "expect": expect if expect is not None else
                [{"judge": "video_judge", "check": "gap or overlap", "frames": list(BAND_FRAMES)}]}
        self.manifest.mkdir(parents=True, exist_ok=True)
        (self.manifest / "truth.json").write_text(json.dumps({"v": 1, "facts": [fact]}))


class NormalizeKeepsEveryKey(unittest.TestCase):
    def test_no_key_is_dropped_and_paths_are_written_from_the_store_root(self):
        got = jg.normalize({"base": "/store/films/a/b", "nested": {"base": "/elsewhere/x", "v": 1.5}}, roots=["/store"])
        self.assertEqual(got["base"], "<root>/films/a/b")
        self.assertEqual(got["nested"], {"base": "/elsewhere/x", "v": 1.5})


class RulerTests(unittest.TestCase):
    def setUp(self):
        self.w = TruthWorkspace()

    def tearDown(self):
        self.w.close()

    def test_the_ruler_reads_the_band_in_exactly_its_frames(self):
        film = self.w.gallery / "px-build-120x2" / "px-keys"
        fact = {"line": "row", "at": 10, "class": "#FF00FF", "x": [18, 22], "frames": [3, 6], "min_run_px": 8}
        self.assertTrue(jg.ruler_check(str(film), fact)["holds"])
        early = dict(fact, frames=[2, 6])
        self.assertEqual(jg.ruler_check(str(film), early)["missing_in"], [2])
        short = dict(fact, frames=[3, 5])
        self.assertEqual(jg.ruler_check(str(film), short)["present_outside"], [6])


class TruthRunTests(unittest.TestCase):
    def test_a_met_truth_passes_with_the_baseline(self):
        w = TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            code, out = w.run()
            self.assertEqual(code, 0, out)
            self.assertIn("truth: 2 of 2", out)
            self.assertIn("unit tests: 2 of 2", out)
        finally:
            w.close()

    def test_a_judge_that_misses_a_truth_defect_fails_and_cannot_be_blessed(self):
        w = TruthWorkspace(video=video_stub(frames=[]))
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("TRUTH", out)
            self.assertFalse((w.manifest / "expected.json").exists())
        finally:
            w.close()

    def test_a_judge_that_misses_a_truth_defect_fails_the_run(self):
        w = TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            blind = base.write_judges(w.root / "judges-blind", video=video_stub(frames=[]))
            (blind / "test_video_judge.py").write_text(textwrap.dedent(PASSING_UNIT_TESTS))
            code, out = w.run(blind)
            self.assertEqual(code, 1, out)
            self.assertIn("TRUTH FAIL px-keys-shell-band", out)
        finally:
            w.close()

    def test_a_finding_the_truth_forbids_fails_the_run(self):
        w = TruthWorkspace(video=video_stub(extra=["dropped frames"]))
        try:
            w.write_truth(expect=[{"judge": "video_judge", "check": "gap or overlap", "frames": list(BAND_FRAMES)},
                                  {"judge": "video_judge", "absent_check": "dropped frames"}])
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("must not report", out)
        finally:
            w.close()

    def test_every_band_frame_must_be_in_a_defect_finding(self):
        partial = TruthWorkspace(video=video_stub(frames=[BAND_FRAMES[0], BAND_FRAMES[1] - 1]))
        try:
            partial.write_truth(expect=[{"judge": "video_judge", "defect_frames": [list(BAND_FRAMES)]}])
            self.assertEqual(partial.snapshot()[0], 0)
            code, out = partial.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("1 frames of", out)
        finally:
            partial.close()
        full = TruthWorkspace()
        try:
            full.write_truth(expect=[{"judge": "video_judge", "defect_frames": [list(BAND_FRAMES)]}])
            self.assertEqual(full.snapshot()[0], 0)
            code, out = full.bless()
            self.assertEqual(code, 0, out)
        finally:
            full.close()

    def test_a_ruler_fact_the_film_does_not_show_is_no_verdict(self):
        w = TruthWorkspace()
        try:
            w.write_truth(ruler_frames=(2, 6))
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("NO VERDICT", out)
            self.assertIn("ruler", out)
        finally:
            w.close()

    def test_a_failing_unit_test_of_the_judges_fails_the_run(self):
        w = TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            broken = base.write_judges(w.root / "judges-unit-red", video=video_stub())
            (broken / "test_video_judge.py").write_text(textwrap.dedent(FAILING_UNIT_TESTS))
            code, out = w.run(broken)
            self.assertEqual(code, 1, out)
            self.assertIn("TRUTH FAIL unit tests", out)
        finally:
            w.close()

    def test_a_bless_with_failing_unit_tests_is_refused(self):
        w = TruthWorkspace(unit=FAILING_UNIT_TESTS)
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("unit tests: 1 of 2 failed", out)
        finally:
            w.close()

    def test_no_unit_tests_is_said_out_loud(self):
        w = TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            code, out = w.run(None, "--no-unit-tests")
            self.assertEqual(code, 0, out)
            self.assertIn("unit tests: NOT RUN (--no-unit-tests)", out)
        finally:
            w.close()


class DeadlineTests(unittest.TestCase):
    def test_a_judge_that_hangs_is_no_verdict_at_the_deadline(self):
        w = TruthWorkspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            slow = base.write_judges(w.root / "judges-hang", video=video_stub(),
                                     keys="import time\ndef judge(base):\n    time.sleep(300)\n")
            (slow / "test_video_judge.py").write_text(textwrap.dedent(PASSING_UNIT_TESTS))
            started = time.monotonic()
            done = subprocess.run([sys.executable, "-I", str(HERE / "judge_goldens.py"), "run", "--store", str(w.store),
                                   "--manifest", str(w.manifest), "--judges", str(slow), "--jobs", "2",
                                   "--deadline-minutes", "0.05"], capture_output=True, text=True, timeout=120)
            out = done.stdout + done.stderr
            self.assertEqual(done.returncode, 2, out)
            self.assertIn("not judged within", out)
            self.assertLess(time.monotonic() - started, 60)
        finally:
            w.close()


if __name__ == "__main__":
    unittest.main()
