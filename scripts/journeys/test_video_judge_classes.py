#!/usr/bin/env python3
"""Two judge faults that made film numbers wrong (VIDEO JUDGE, lead STATUS 8130), on real recordings.

Run: /work/tmp/resize-videos/venv/bin/python -I scripts/journeys/test_video_judge_classes.py

1. Content wait is not a dropped refresh (PACING TRIAGE, STATUS 8048). In bv-dt-bottom-light-dark-r4 of round
   pt-feat-5851715-b, the DevTools open shows its first changed frame, then no new frame for 141.7 ms while the
   DevTools frontend (a CEF process) draws. The app's own frame trace (debug.motion, sampled on the MAIN thread at
   each display frame) has a sample at nearly every vsync of that gap: the app waits for content, it did not drop
   those refreshes. Before the first changed frame, the main thread misses vsyncs in the key turn (trace gaps of
   53 ms after the key-down): those are the real drops, and the old judge counted them only as first-frame delay.
   The old judge says dropped 22. With the trace, each no-change refresh is "main missed" (no trace sample for its
   vsync) or "content wait" (the trace runs), main misses before the first changed frame count as drops too, and a
   recording without a trace keeps the old count, marked "unclassified".
   Fixture: fixture-video-judge-content-wait-bv-dt-5851715-b-r4.json (the real film's frame times, which frames
   changed, the trace's sample times, the journal and HID; its "source" says how it was cut).

2. Each drag is judged on its own (RESIZE KEYS, STATUS 8124). rkd-col-drag-clamp-heavy-dark drags a divider left
   past its clamp, then right past it. judge_trace.py judged the whole film as one motion whose net direction is
   right, so every step of the first (left) drag was a "reverse": 28 false findings. The app's input journal
   (mouse down/up, host clock = the trace's clock) splits the film into one motion per drag.
   Fixture: fixture-judge-trace-clamp-two-drags-5851715.json (the real trace's sample times and pane rows, the
   mouse journal and the HID entries).
"""
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import video_judge as vj  # noqa: E402

PACING_FIXTURE = HERE / "fixture-video-judge-content-wait-bv-dt-5851715-b-r4.json"
DRAG_FIXTURE = HERE / "fixture-judge-trace-clamp-two-drags-5851715.json"
JUDGE_TRACE = HERE / "video-cases" / "judge_trace.py"
REAL_BV = Path("/work/tmp/pacing-triage/runs/pt-feat-5851715-b-20261103T024936Z-cmux22/bv-dt-bottom-light-dark/video/"
               "bv-dt-bottom-light-dark-r4")
OLD_DROPPED = 22  # the old judge's count for this film (pacing triage films.jsonl, round b r4)


def write_pacing_case(root, with_trace=True):
    """BASE.* of the real film from the fixture: frames.json as recorded; a 4 px scan row whose color changes exactly
    on the frames whose real scanlines changed (the judge reads only that for its motion windows here); the trace's
    sample times (no geometry); the journal, HID and meta clock fields as recorded."""
    doc = json.loads(PACING_FIXTURE.read_text())
    base = Path(root) / "pt-feat-5851715-b-120x1" / "bv-dt-bottom-light-dark-r4"
    base.parent.mkdir(parents=True, exist_ok=True)
    t_base = float(doc["base_s"])
    entries = [[t_base + float(t), status, in_movie] for t, status, in_movie in doc["frames"]]
    Path(f"{base}.mov.frames.json").write_text(json.dumps({"frames": entries, "width": 4, "height": 4}))
    complete = [e[0] for e in entries if e[1] == "complete"]
    scanned, changed = set(doc["scanned"]), set(doc["changed"])
    header = {"width": 4, "height": 4, "rows": [0], "columns": [], "format": "BGRA", "time": "float64-le host seconds"}
    level = 0
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for i, t in enumerate(complete):
            if i in changed:
                level += 1
            if i not in scanned:
                continue
            out.write(struct.pack("<d", t))
            out.write(bytes([level % 256, level // 256 % 256, 0, 255]) * 4)
    trace = doc["trace"]
    samples = [{"t": t, "panes": [], "dividers": []} for t in trace["t_ms"]] if with_trace else []
    Path(f"{base}.trace.json").write_text(json.dumps({"t0_s": trace["t0_s"], "refresh_ms": trace["refresh_ms"],
                                                      "samples": samples}))
    Path(f"{base}.events.json").write_text(json.dumps({"hid": doc["hid"], "journal": doc["journal"]}))
    Path(f"{base}.meta.json").write_text(json.dumps(doc["meta"]))
    return base


def pacing_findings(report, check):
    return [f for f in report["findings"] if f["check"] == check]


class ContentWaitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="video-judge-classes-")
        cls.report = vj.judge(write_pacing_case(Path(cls.tmp) / "traced"), movie=False)
        cls.untraced = vj.judge(write_pacing_case(Path(cls.tmp) / "untraced", with_trace=False), movie=False)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def check_classes(self, report):
        pacing = report.get("pacing")
        self.assertIsInstance(pacing, dict, "the report has no pacing classes (main missed / content wait)")
        self.assertTrue(pacing["trace"])
        # Every no-change refresh in the motion windows is classified once: the old judge's 22 split in three.
        self.assertEqual(pacing["main_missed"] + pacing["not_shown"] + pacing["content_wait"] + pacing["unclassified"],
                         OLD_DROPPED, pacing)
        # The 141.7 ms gap after the first changed frame: the main thread ticks at nearly every vsync.
        self.assertGreaterEqual(pacing["content_wait"], 14, pacing)
        # The key turn's main-thread stall before the first changed frame counts as drops now.
        self.assertGreaterEqual(pacing["main_missed_before_first_frame"], 1, pacing)
        self.assertEqual(report["dropped"], pacing["main_missed"] + pacing["main_missed_before_first_frame"]
                         + pacing["not_shown"] + pacing["unclassified"], pacing)
        self.assertLess(report["dropped"], OLD_DROPPED // 2, pacing)
        waits = pacing_findings(report, "content wait")
        self.assertTrue(waits and all(f["severity"] == "note" for f in waits), report["findings"])
        self.assertTrue(any("141.7 ms" in f["detail"] for f in waits), [f["detail"] for f in waits])
        before = pacing_findings(report, "main thread missed refreshes before the first frame")
        self.assertTrue(before and all(f["severity"] == "defect" for f in before), report["findings"])

    def test_content_wait_is_not_a_drop(self):
        self.check_classes(self.report)

    def test_without_trace_old_count_unclassified(self):
        pacing = self.untraced.get("pacing")
        self.assertIsInstance(pacing, dict)
        self.assertFalse(pacing["trace"])
        self.assertEqual(self.untraced["dropped"], OLD_DROPPED)
        self.assertEqual(pacing["unclassified"], OLD_DROPPED)
        self.assertEqual(pacing["main_missed"] + pacing["not_shown"] + pacing["content_wait"]
                         + pacing["main_missed_before_first_frame"], 0)
        self.assertIn("unclassified", vj.summary(self.untraced))

    @unittest.skipUnless(Path(f"{REAL_BV}.mov.scan").is_file(), "the real film is not on this machine")
    def test_real_film(self):
        self.check_classes(vj.judge(REAL_BV, movie=False))


@unittest.skipUnless(JUDGE_TRACE.is_file(), "this kit has no video-cases/judge_trace.py")
class PerDragTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="judge-trace-drags-")
        doc = json.loads(DRAG_FIXTURE.read_text())
        base = Path(cls.tmp) / "rkd-col-drag-clamp-heavy-dark"
        Path(f"{base}.trace.json").write_text(json.dumps(doc["trace"]))
        Path(f"{base}.events.json").write_text(json.dumps({"hid": doc["hid"], "journal": doc["journal"]}))
        cls.base = base

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_judge(self, *extra):
        out = Path(self.tmp) / f"report{len(extra)}.json"
        subprocess.run([sys.executable, "-I", str(JUDGE_TRACE), f"{self.base}.trace.json", "--json", str(out), *extra],
                       check=False, stdout=subprocess.DEVNULL)
        return json.loads(out.read_text())

    def check_two_drags(self, report):
        self.assertNotIn("reverse", report.get("counts") or {}, [d["what"] for d in report["defects"]][:5])
        motions = report.get("motions") or []
        self.assertEqual(len(motions), 2, motions)
        self.assertTrue(all(m.get("motion") for m in motions), motions)
        # The two drags move the same divider in opposite directions.
        pane = "pane_bba06c4387ae453fa738e8371e5eeb19"
        first, second = (m["travel"][pane]["left"] for m in motions)
        self.assertLess(first, 0, motions[0])
        self.assertGreater(second, 0, motions[1])

    def test_each_drag_judged_on_its_own(self):
        self.check_two_drags(self.run_judge("--events", f"{self.base}.events.json"))

    def test_events_beside_the_trace_are_used(self):
        self.check_two_drags(self.run_judge())

    def test_sparse_drag_end_is_not_an_end_jump(self):
        """Once each drag is judged, a fast drag back with input under the refresh rate has 0 steps between its
        steps (rkd-col-drag-2: 12.5, 0, 12.5 pt): the last step is compared with the last step that moved."""
        xs = [100.0] * 5 + [112.5, 112.5, 125.0, 137.5, 137.5, 150.0] + [150.0] * 5
        samples = [{"t": round(k * 8.33, 2), "panes": [["a", 0, 0, x, 100, 1], ["b", x + 1, 0, 300 - x, 100, 1]]}
                   for k, x in enumerate(xs)]
        trace = {"t0_s": 100.0, "refresh_ms": 8.33, "samples": samples}
        down = {"kind": {"mouse": {"_0": {"phase": "down"}}}, "uptimeNanos": int((100.0 + 0.030) * 1e9)}
        sys.path.insert(0, str(JUDGE_TRACE.parent))
        import judge_trace  # noqa: E402
        report = judge_trace.judge(trace, None, 2.0, {"hid": [], "journal": [down]})
        self.assertNotIn("end-jump", report["counts"], report["defects"])
        self.assertEqual(report["split"], "journal")


if __name__ == "__main__":
    unittest.main()
