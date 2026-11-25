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
import os
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
# The film is in the judge goldens store; the runner gives its tests the store it judges (JUDGE_GOLDENS_STORE). Its bytes
# are those of pacing triage round pt-feat-5851715-b-20261103T024936Z-cmux22, bv-dt-bottom-light-dark r4. Run alone
# without the store, the test is skipped; the runner calls a skipped test NO VERDICT (review 5 of #33930, note 1).
REAL_BV = (Path(os.environ.get("JUDGE_GOLDENS_STORE", "/work/goldens/judge-films")) / "films"
           / "pt-feat-5851715-b-120x1" / "bv-dt-bottom-light-dark-r4")
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


R = 8.33  # refresh ms of the synthetic traces below


def two_pane_trace(xs, dt=None):
    """A trace whose sample k shows panes a|b with the divider at xs[k] pt; dt[k] (ms) is the interval into sample k
    (default one refresh)."""
    t, samples = 0.0, []
    for k, x in enumerate(xs):
        if k:
            t += (dt or {}).get(k, R)
        samples.append({"t": round(t, 2), "panes": [["a", 0, 0, x, 100, 1], ["b", x + 1, 0, 300 - x, 100, 1]]})
    return {"t0_s": 100.0, "refresh_ms": R, "samples": samples}


def mouse_down(t0_s, t_ms):
    return {"kind": {"mouse": {"_0": {"phase": "down"}}}, "uptimeNanos": int(round((t0_s + t_ms / 1000) * 1e9))}


@unittest.skipUnless(JUDGE_TRACE.is_file(), "this kit has no video-cases/judge_trace.py")
class DragFollowUpTests(unittest.TestCase):
    """The review of #32947 (STATUS 8188): four faults of the per-drag split, one test each."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(JUDGE_TRACE.parent))
        import judge_trace  # noqa: E402
        cls.jt = judge_trace

    def test_drop_between_close_drags_counts_once(self):
        """Drag 0 moves on samples 2..14, drag 1 starts at sample 15 and moves from 16; the interval into sample 16
        is 16.7 ms (one refresh missed) and the movie misses the same refresh. Both parts' 2-refresh margins hold
        sample 16: it is one drop in the trace and one in the movie, not one per part."""
        xs = [100.0] * 2 + [100.0 + 2 * k for k in range(1, 14)] + [126.0] + [126.0 - 2 * k for k in range(1, 11)] + [106.0] * 4
        trace = two_pane_trace(xs, {16: 2 * R})
        t = [s["t"] for s in trace["samples"]]
        frames = [[trace["t0_s"] + (v + 0.5) / 1000, "complete", True] for v in t]
        events = {"hid": [], "journal": [mouse_down(100.0, 0.5), mouse_down(100.0, t[15])]}
        report = self.jt.judge(trace, frames, 2.0, events)
        self.assertEqual(len(report["motions"]), 2, report["motions"])
        trace_drops = [d for d in report["defects"] if d["kind"] == "dropped" and d["frame"] is not None]
        movie_drops = [d for d in report["defects"] if d["kind"] == "dropped" and d["frame"] is None]
        self.assertEqual([d["frame"] for d in trace_drops], [16], trace_drops)
        self.assertEqual(len(movie_drops), 1, movie_drops)
        self.assertEqual(trace_drops[0]["drag"], 1, trace_drops)
        # Each film frame belongs to one part: the parts' frame counts add up to at most the film's.
        self.assertLessEqual(report["movie"]["complete"], len(frames), report["movie"])
        self.assertLessEqual(report["movie"]["frames_in_motion"], len(frames), report["movie"])

    def test_idle_frames_before_the_motion_are_not_a_drop(self):
        """While the screen does not change, the capture writes only idle rows; the first complete frame of the motion
        follows the last complete frame of the rest long before it. That is not a drop, with or without a split
        (review of 21ec8aa412c: feat-rv5-var2-120x2/rv-split-1pane-idle-dark got a false 241.67 ms movie drop)."""
        xs = [100.0] * 20 + [100.0 + 2 * k for k in range(1, 9)] + [116.0] * 4
        trace = two_pane_trace(xs)
        t0, t = trace["t0_s"], [s["t"] for s in trace["samples"]]
        frames = [[t0 + (v + 0.5) / 1000, "complete" if (k < 3 or k >= 21) else "idle", True] for k, v in enumerate(t)]
        for events in (None, {"hid": [], "journal": [mouse_down(t0, t[19])]}):
            report = self.jt.judge(trace, frames, 2.0, events)
            movie_drops = [d for d in report["defects"] if d["kind"] == "dropped" and d["frame"] is None]
            self.assertEqual(movie_drops, [], (events is not None, movie_drops))

    def drops(self, trace, frames, events):
        report = self.jt.judge(trace, frames, 2.0, events)
        trace_drops = sorted((d["frame"], d.get("drag")) for d in report["defects"] if d["kind"] == "dropped" and d["frame"] is not None)
        movie_drops = sorted((d["movie_frame"], d.get("drag")) for d in report["defects"] if d["kind"] == "dropped" and d["frame"] is None)
        return trace_drops, movie_drops

    @staticmethod
    def frames_of(trace, skip=()):
        return [[trace["t0_s"] + (s["t"] + 0.5) / 1000, "complete", True] for k, s in enumerate(trace["samples"]) if k not in skip]

    def test_drop_in_a_margin_cut_by_the_drag_start_is_kept(self):
        """One drag: the cut is at sample 10, the motion starts at 11, and the interval into sample 9 misses a refresh.
        That is in the motion's 2-refresh margin and in no other part's window: it is a drop of drag 0, as without a
        split (second review of #32976, case A)."""
        xs = [100.0] * 11 + [100.0 + 2 * k for k in range(1, 9)] + [116.0] * 4
        trace = two_pane_trace(xs, {9: 2 * R})
        frames = self.frames_of(trace)
        t = [s["t"] for s in trace["samples"]]
        unsplit = self.drops(trace, frames, None)
        split = self.drops(trace, frames, {"hid": [], "journal": [mouse_down(trace["t0_s"], t[10] - 0.5)]})
        self.assertEqual([f for f, _ in unsplit[0]], [9], unsplit)
        self.assertEqual(split[0], [(9, 0)], split)
        self.assertEqual(len(split[1]), len(unsplit[1]), (split, unsplit))

    def test_drop_after_a_drag_before_the_next_window_is_kept(self):
        """Drag 0 moves on samples 2..14; drag 1 is cut at sample 15 and moves from 21. The interval into sample 16
        misses a refresh: it is in drag 0's window (to 16) and not in drag 1's (from 19), so it is drag 0's drop
        (second review of #32976, case B)."""
        xs = [100.0] * 2 + [100.0 + 2 * k for k in range(1, 14)] + [126.0] * 6 + [126.0 - 2 * k for k in range(1, 9)] + [110.0] * 4
        trace = two_pane_trace(xs, {16: 2 * R})
        frames = self.frames_of(trace)
        t = [s["t"] for s in trace["samples"]]
        trace_drops, movie_drops = self.drops(trace, frames, {"hid": [], "journal": [mouse_down(trace["t0_s"], 0.5),
                                                                                       mouse_down(trace["t0_s"], t[15] - 0.5)]})
        self.assertEqual(trace_drops, [(16, 0)], trace_drops)

    def test_events_that_are_not_a_dict_do_not_fail(self):
        xs = [100.0] * 2 + [100.0 + 2 * k for k in range(1, 6)] + [110.0] * 3
        report = self.jt.judge(two_pane_trace(xs), None, 2.0, [])
        self.assertEqual(report["notes"], [])

    def test_drag_after_the_trace_ends_with_frames(self):
        """A drag that starts after the last trace sample makes an empty part at the trace's end; with film frames the
        judge must not read a sample past the end (third review of #32976: IndexError). Expected as at 21acf4ed454:
        parts [0, 1], no defects, every film frame in the motion counted once."""
        xs = [100.0] * 5 + [100.0 + 4 * k for k in range(1, 10)] + [136.0] * 5
        trace = two_pane_trace(xs)
        frames = self.frames_of(trace)
        hid = [{"kind": "drag", "t_sent": trace["t0_s"] + 0.020, "t_returned": trace["t0_s"] + 0.1, "host_offset_s": 0.0},
               {"kind": "drag", "t_sent": trace["t0_s"] + 0.163, "t_returned": trace["t0_s"] + 0.2, "host_offset_s": 0.0}]
        report = self.jt.judge(trace, frames, 2.0, {"hid": hid, "journal": []})
        self.assertEqual([m["input"]["drag"] for m in report["motions"]], [0, 1], report["motions"])
        self.assertEqual(report["defects"], [])
        self.assertEqual(report["movie"], {"frames_in_motion": 13, "complete": 13})

    def test_film_stall_across_the_cut_between_two_drags_is_kept(self):
        """Drag 0 moves the divider right on samples 1..10, drag 1 moves it back on 11..20. The film has no complete
        frame from sample 8 to 13: the stall straddles the cut, so its two frames are in different parts' windows (the
        windows overlap at the cut). It is one movie drop (frames 7 -> 14), as for the whole film, not none (fourth
        review of #32976)."""
        xs = [100.0] + [100.0 + 4 * k for k in range(1, 11)] + [140.0 - 4 * k for k in range(1, 11)] + [100.0] * 3
        trace = two_pane_trace(xs)
        t0 = trace["t0_s"]
        frames = [[t0 + (s["t"] + 1.0) / 1000, "idle" if 8 <= k <= 13 else "complete", True]
                  for k, s in enumerate(trace["samples"])]
        hid = [{"kind": "drag", "t_sent": t0, "host_offset_s": 0.0},
               {"kind": "drag", "t_sent": t0 + trace["samples"][11]["t"] / 1000, "host_offset_s": 0.0}]
        unsplit = self.drops(trace, frames, None)[1]
        split = self.drops(trace, frames, {"hid": hid, "journal": []})[1]
        self.assertEqual([f for f, _ in unsplit], [14], unsplit)
        self.assertEqual([f for f, _ in split], [14], split)

    def test_drag_labels_name_the_drag_that_starts_the_part(self):
        """Two mouse-downs before the trace starts (-2000 and -1000 ms) both cut at sample 0, then drags at 34 ms and
        at 300 ms. Each part is labelled with the last drag that starts it: drags 1, 2, 3, at -1000, 34, 300 ms."""
        xs = [100.0] * 2 + [100.0 + 2 * k for k in range(1, 4)] + [106.0] * 6 + [106.0 + 2 * k for k in range(1, 4)] \
            + [112.0] * 30 + [112.0 - 2 * k for k in range(1, 4)] + [106.0] * 4
        trace = two_pane_trace(xs)
        t = [s["t"] for s in trace["samples"]]
        downs = [-2000.0, -1000.0, t[11] - 0.5, t[44] - 0.5]
        report = self.jt.judge(trace, None, 2.0, {"hid": [], "journal": [mouse_down(100.0, v) for v in downs]})
        labels = [(m["input"]["drag"], m["input"]["t_ms"]) for m in report["motions"]]
        self.assertEqual(labels, [(1, -1000.0), (2, round(downs[2], 2)), (3, round(downs[3], 2))], report["motions"])

    def test_edge_that_moves_only_in_its_last_step_is_an_end_jump(self):
        """Three panes: the a|b divider moves 2 pt each refresh for 10 refreshes; the b|c divider stays and then jumps
        10 pt in the last step only. That snap is an end-jump (the old judge flagged it; comparing with the last
        moving step alone found no step to compare with)."""
        samples, t = [], 0.0
        for k in range(16):
            x = 100.0 + 2 * min(max(k - 2, 0), 10)
            y = 200.0 + (10.0 if k >= 12 else 0.0)
            samples.append({"t": round(t, 2), "panes": [["a", 0, 0, x, 100, 1], ["b", x + 1, 0, y - x - 1, 100, 1],
                                                        ["c", y + 1, 0, 400 - y, 100, 1]]})
            t += R
        report = self.jt.judge({"t0_s": 100.0, "refresh_ms": R, "samples": samples}, None, 2.0, None)
        jumps = [d for d in report["defects"] if d["kind"] == "end-jump"]
        self.assertTrue(any("pane c left" in d["what"] for d in jumps), report["defects"])
        self.assertTrue(any("pane b right" in d["what"] for d in jumps), report["defects"])

    def test_unsplit_film_with_drags_says_so(self):
        """Two HID drags with no host_offset_s and no journal mouse-down: nothing places them on the trace's clock,
        so the film stays one motion, and the report says why (rkd-probe-col-drag-3-heavy-dark of feat-5851715)."""
        xs = [100.0] * 2 + [100.0 + 2 * k for k in range(1, 6)] + [110.0] * 10 + [110.0 - 2 * k for k in range(1, 6)] + [100.0] * 3
        hid = [{"kind": "drag", "t_sent": 8.5, "t_returned": 9.6, "args": {}},
               {"kind": "drag", "t_sent": 10.1, "t_returned": 10.4, "args": {}}]
        report = self.jt.judge(two_pane_trace(xs), None, 2.0, {"hid": hid, "journal": []})
        self.assertIsNone(report["split"])
        notes = " ".join(report.get("notes") or [])
        self.assertIn("2 HID drag", notes, report.get("notes"))
        self.assertIn("not split", notes, report.get("notes"))


if __name__ == "__main__":
    unittest.main()
