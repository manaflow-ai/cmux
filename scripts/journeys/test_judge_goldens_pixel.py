#!/usr/bin/env python3
"""judge_pixel in the judge goldens (REWRITE R-HARNESS stage S1b): the FRAME OWNER's pixel judge is the fifth goldens
judge, on the films it applies to, and its TRUTH facts are exact frame sets read from its summary rows.

    /work/tmp/bv-venv/bin/python -I scripts/journeys/test_judge_goldens_pixel.py

judge_pixel judges the fixture films (the layout journeys' loud-color panes: a film whose meta notes carry `pixel`).
These tests define:
- film_judges gives judge_pixel to a film with a scan, a trace and fixture notes in its meta, and to no other film;
- `snapshot` with no --source re-derives every recorded film's judge list from its pinned files and copies nothing,
  so a new judge reaches the films it applies to (a run then names each new result until it is blessed);
- a run reproduces a judge_pixel result and shows a change of it as a difference;
- a TRUTH expectation for judge_pixel selects one summary row (label, side, line, what) and holds only when the
  row's off frames are exactly the given spans (an empty list: no off frame); a missing row or another frame set is
  a TRUTH failure, a malformed fact is NO VERDICT.
"""
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import judge_goldens as jg  # noqa: E402
import test_judge_goldens as base  # noqa: E402

FIXTURE_FILM = "build-p-120x2/px-col-drag"

# A judge_pixel stand-in: one pane row whose off frames come from the film's own fixture notes (so a test controls
# them), in judge_pixel's report shape (summary rows keyed like the real judge's).
STUB_PIXEL = '''
import json
from pathlib import Path
def judge(base, all_frames=False):
    meta = json.loads(Path(f"{base}.meta.json").read_text())
    note = (meta.get("notes") or {}).get("pixel") or {}
    off = note.get("off", "")
    count = sum(int(b) - int(a) + 1 for a, _, b in (p.partition("-") for p in off.split(",") if p)
                for b in [b or a])
    row = {"what": "pane", "pane": "pane_x", "label": "p1", "kind": "page", "line": "row@10", "side": "hi",
           "off_frames": count, "off_ranges": off, "frames": 9, "max_gap_px": 0.0, "shell_in_frames": 0,
           "shell_in_ranges": ""}
    return {"case": Path(str(base)).name, "base": str(base), "frames": 9, "summary": {"p1:pane_x:row@10:hi": row},
            "findings": [], "info": [], "notes": []}
'''


def fixture_workspace(off="3-6"):
    """The runner tests' workspace plus one fixture film (meta notes carry `pixel`) and the judge_pixel stand-in."""
    w = base.Workspace()
    folder = w.gallery / "build-p-120x2"
    base.write_film(folder, "px-col-drag", frames=9)
    (folder / "px-col-drag.meta.json").write_text(json.dumps({"start": {"scale": 2}, "notes": {"pixel": {"off": off}}}))
    (w.judges / "video-cases" / "judge_pixel.py").write_text(STUB_PIXEL)
    return w


def set_pixel_off(w, off):
    """A changed judge_pixel: its row's off frames come from this text, whatever the film says."""
    (w.judges / "video-cases" / "judge_pixel.py").write_text(
        STUB_PIXEL.replace('off = note.get("off", "")', f'off = {off!r}'))


def write_pixel_fact(w, expect):
    w.manifest.mkdir(parents=True, exist_ok=True)
    (w.manifest / "truth.json").write_text(json.dumps({"v": 1, "facts": [
        {"id": "px-off", "film": FIXTURE_FILM, "why": "test", "expect": [expect]}]}))


ROW = {"label": "p1", "side": "hi", "line": "row@10", "what": "pane"}


class FilmJudgesTests(unittest.TestCase):
    def test_a_fixture_film_gets_judge_pixel_and_no_other_film_does(self):
        names = {"mov.frames.json", "trace.json", "mov.scan", "meta.json", "events.json"}
        fixture = {"start": {"scale": 2}, "notes": {"pixel": {"panes": {}}}}
        self.assertIn("judge_pixel", jg.film_judges(names, fixture))
        self.assertNotIn("judge_pixel", jg.film_judges(names, {"start": {"scale": 2}}))
        self.assertNotIn("judge_pixel", jg.film_judges(names - {"mov.scan"}, fixture))
        self.assertEqual(jg.film_judges(names, None), ["video_judge", "judge_trace", "judge_keys", "judge_scan"])


class SnapshotTests(unittest.TestCase):
    def test_snapshot_with_no_source_rederives_the_judge_lists_and_copies_nothing(self):
        w = fixture_workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            path = w.manifest / "films.json"
            doc = json.loads(path.read_text())
            self.assertIn("judge_pixel", doc["films"][FIXTURE_FILM]["judges"])
            # A films.json written before judge_pixel existed: the fixture film has the four judges only.
            doc["films"][FIXTURE_FILM]["judges"].remove("judge_pixel")
            path.write_text(json.dumps(doc))
            table = doc["files_table"]
            code, out = w.cli("snapshot")
            self.assertEqual(code, 0, out)
            again = json.loads(path.read_text())
            self.assertIn("judge_pixel", again["films"][FIXTURE_FILM]["judges"])
            self.assertNotIn("judge_pixel", again["films"]["build-a-120x2/col-drag"]["judges"])
            self.assertEqual(again["files_table"], table)
            self.assertIn("judge_pixel", out)
        finally:
            w.close()


class RunTests(unittest.TestCase):
    def test_a_judge_pixel_result_is_reproduced_and_a_change_is_a_difference(self):
        w = fixture_workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            code, out = w.run()
            self.assertEqual(code, 0, out)
            self.assertIn("reproduced 17 of 17", out)  # 3 films x 4 judges + the fixture film x 5
            set_pixel_off(w, "3-5")
            code, out = w.run()
            self.assertEqual(code, 1, out)
            self.assertIn(f"DIFF judge_pixel {FIXTURE_FILM}", out)
        finally:
            w.close()


class TruthPixelTests(unittest.TestCase):
    def blessed(self, expect, off="3-6"):
        w = fixture_workspace(off)
        write_pixel_fact(w, expect)
        self.assertEqual(w.snapshot()[0], 0)
        return w

    def test_a_row_with_exactly_the_off_frames_meets_the_fact(self):
        w = self.blessed({"judge": "judge_pixel", "pixel_row": ROW, "off_frames": [[3, 6]]})
        try:
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            code, out = w.run()
            self.assertEqual(code, 0, out)
            self.assertIn("truth: 1 of 1", out)
        finally:
            w.close()

    def test_one_frame_more_or_less_is_a_truth_failure_and_cannot_be_blessed(self):
        for off in ("3-5", "3-7", "3-6,9"):
            with self.subTest(judged=off):
                w = self.blessed({"judge": "judge_pixel", "pixel_row": ROW, "off_frames": [[3, 6]]}, off=off)
                try:
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertIn("TRUTH", out)
                finally:
                    w.close()

    def test_no_off_frame_is_a_fact_too(self):
        w = self.blessed({"judge": "judge_pixel", "pixel_row": ROW, "off_frames": []}, off="")
        try:
            self.assertEqual(w.bless()[0], 0)
            code, out = w.run()
            self.assertEqual(code, 0, out)
        finally:
            w.close()
        w = self.blessed({"judge": "judge_pixel", "pixel_row": ROW, "off_frames": []}, off="4")
        try:
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("TRUTH", out)
        finally:
            w.close()

    def test_a_row_the_judge_does_not_report_is_a_truth_failure(self):
        # Blessed with a fact that holds; then the fact names a row the judge does not report: a TRUTH failure of the
        # judge (exit 1), not a fact that cannot be checked (exit 2).
        w = self.blessed({"judge": "judge_pixel", "pixel_row": ROW, "off_frames": [[3, 6]]})
        try:
            self.assertEqual(w.bless()[0], 0)
            write_pixel_fact(w, {"judge": "judge_pixel", "pixel_row": dict(ROW, line="row@99"), "off_frames": [[3, 6]]})
            code, out = w.run()
            self.assertEqual(code, 1, out)
            self.assertIn("TRUTH FAIL px-off", out)
            self.assertIn("row@99", out)
        finally:
            w.close()

    def test_a_malformed_pixel_fact_is_no_verdict(self):
        for name, expect in (
                ("reversed span", {"judge": "judge_pixel", "pixel_row": ROW, "off_frames": [[6, 3]]}),
                ("row without a line", {"judge": "judge_pixel", "pixel_row": {"label": "p1", "side": "hi"},
                                        "off_frames": [[3, 6]]}),
                ("no frames", {"judge": "judge_pixel", "pixel_row": ROW}),
                ("frames for another judge", {"judge": "video_judge", "pixel_row": ROW, "off_frames": [[3, 6]]})):
            with self.subTest(case=name):
                w = self.blessed(expect)
                try:
                    code, out = w.cli("bless", "--judges", str(w.judges), "--reason", "t", "--jobs", "2",
                                      "--no-git-check")
                    self.assertEqual(code, 2, out)
                    self.assertIn("px-off", out)
                    self.assertIn("NO VERDICT", out)
                finally:
                    w.close()


if __name__ == "__main__":
    unittest.main()
