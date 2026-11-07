#!/usr/bin/env python3
"""video_judge.py puts every HID time on the host clock before it builds a window (VIDEO JUDGE CLOCK, STATUS 7930).

Run: /work/tmp/resize-videos/venv/bin/python -I scripts/journeys/test_video_judge_clock.py

events.json's HID times (t_sent, t_returned) are the DRIVER's clock: time.monotonic() of the journey driver, which
the minis' python 3.9 counts from its own process start (a few s). The frames, the trace and the app's input journal
are the HOST clock (mach_absolute_time since boot, about 400000 s). Real round rk-a3-24-3-b-120x2/rk-idle: the first
Ctrl-Shift-L has t_sent 12.698 s, its key events are in the journal at 423189.667 s, and the frames run from
423187.650 s: the HID span missed its frames by 423176.96 s, so the judge never saw a key or a drag as active.

Two synthetic clocks with a known offset (host = driver + OFFSET): the drag of test_video_judge.py's "jumpback"
case (a divider moves back 4 px against the drag at frame 25) with its HID times on the driver clock. Only a judge
that moves them to the host clock sees the drag active at frame 25 and calls it a "jump back" (a defect); a judge
that does not calls it "jump back (animation)" (a note), and its HID span covers none of the drag's frames.
"""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import test_video_judge as tvj  # noqa: E402
import video_judge as vj  # noqa: E402

OFFSET = 987.654321       # host = driver + OFFSET (seconds); the driver started 12.3 s before the drag
LATENCY = 0.003           # from t_sent to the first event the app's journal stamps
T_SENT = tvj.T0 + (tvj.DRAG[0] - 1) * tvj.P
T_RETURNED = tvj.T0 + tvj.DRAG[1] * tvj.P


def journal_for_drag():
    """The app's input journal for the drag, on the host clock: down, one move per refresh, up."""
    times = [T_SENT + LATENCY] + [tvj.T0 + k * tvj.P - 0.002 for k in range(tvj.DRAG[0], tvj.DRAG[1])] + [T_RETURNED - 0.002]
    phases = ["down"] + ["dragged"] * (len(times) - 2) + ["up"]
    return [{"seq": 100 + i, "uptimeNanos": int(round(t * 1e9)),
             "kind": {"mouse": {"_0": {"button": 0, "phase": phase, "x": 101, "y": 50}}}}
            for i, (t, phase) in enumerate(zip(times, phases))]


def driver_clock_events(base, recorded_offset):
    """Rewrites BASE.events.json: the HID times on the driver clock; the journal on the host clock. With
    recorded_offset the driver also wrote its own measured offset into each HID entry (ext_video, new rounds)."""
    doc = json.loads(Path(f"{base}.events.json").read_text())
    for h in doc["hid"]:
        h["t_sent"] = round(h["t_sent"] - OFFSET, 6)
        h["t_returned"] = round(h["t_returned"] - OFFSET, 6)
        if recorded_offset:
            h["host_offset_s"] = OFFSET
    doc["journal"] = [] if recorded_offset else journal_for_drag()
    Path(f"{base}.events.json").write_text(json.dumps(doc))


class VideoJudgeClockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="video-judge-clock-")
        cls.bases = {}
        for name, recorded in (("journal", False), ("recorded", True)):
            base = tvj.build_case(cls.tmp, f"jumpback-driver-clock-{name}", "jumpback")
            driver_clock_events(base, recorded)
            cls.bases[name] = base

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def assert_on_host_clock(self, name):
        base = self.bases[name]
        case = vj.load_case(base)
        # The drag's span holds the frames it moves (frames 10..40), on the host clock.
        spans = vj.hid_spans(case)
        self.assertTrue(spans and all(any(s0 <= case.complete_t[f] <= s1 for s0, s1 in spans) for f in (10, 25, 40)),
                        f"HID spans {spans} miss the drag's frames {case.complete_t[10]:.3f}-{case.complete_t[40]:.3f}")
        report = vj.judge(base, movie=False)
        hit = tvj.find(report, "jump back")
        self.assertEqual(hit[0]["frames"], [25, 25])
        self.assertEqual(hit[0]["severity"], "defect")
        self.assertNotIn("jump back (animation)", tvj.checks(report))
        return case, report

    def test_driver_clock_hid_with_the_journal_moves_to_the_host_clock(self):
        # Rounds recorded before the driver wrote its offset: the offset comes from the journal of this run.
        case, report = self.assert_on_host_clock("journal")
        clock = report["hid_clock"]
        self.assertEqual(clock["source"], "journal")
        self.assertAlmostEqual(clock["offset_s"], OFFSET + LATENCY, delta=0.0005)
        self.assertAlmostEqual(case.hid[0]["t_sent"], T_SENT + LATENCY, delta=0.0005)
        self.assertEqual(clock["matched"], [1, 1])
        self.assertAlmostEqual(case.hid[0]["t_sent_driver"], T_SENT - OFFSET, delta=1e-6)

    def test_driver_clock_hid_with_the_recorded_offset_moves_to_the_host_clock(self):
        case, report = self.assert_on_host_clock("recorded")
        self.assertEqual(report["hid_clock"]["source"], "recorded")
        self.assertAlmostEqual(report["hid_clock"]["offset_s"], OFFSET, delta=1e-9)
        self.assertAlmostEqual(case.hid[0]["t_sent"], T_SENT, delta=1e-6)

    def test_the_offset_is_measured_per_run(self):
        # Two runs, two driver processes: each run's own journal gives its own offset (no constant).
        for offset in (5.25, 423176.962):
            hid = [{"kind": "key", "t_sent": 12.0, "t_returned": 12.06},
                   {"kind": "key", "t_sent": 14.5, "t_returned": 14.57}]
            journal = [{"uptimeNanos": int(round((t + offset) * 1e9)), "kind": {"key": {"_0": {"phase": phase}}}}
                       for t, phase in ((12.004, "flags"), (12.03, "down"), (14.502, "flags"), (14.55, "down"))]
            got = vj.hid_clock_offset(hid, journal)
            self.assertEqual(got["source"], "journal")
            self.assertAlmostEqual(got["offset_s"], offset + 0.002, delta=1e-6)

    def test_hid_already_on_the_host_clock_stays(self):
        base = tvj.build_case(self.tmp, "jumpback-host-clock", "jumpback")
        case = vj.load_case(base)
        self.assertEqual(case.hid[0]["t_sent"], T_SENT)
        report = vj.judge(base, movie=False)
        self.assertEqual(tvj.find(report, "jump back")[0]["severity"], "defect")

    @staticmethod
    def key_round(offset, keep_from, n=12):
        """n key presses about 2.1 s apart on the driver clock; the journal (host clock) keeps only the entries from
        press keep_from on, as ext_video's last-400 journal does in a long round (review of 8a4f46eebd8: sf-* rounds)."""
        sent = [3.0 + 2.1 * k + 0.013 * (k % 3) for k in range(n)]
        hid = [{"kind": "key", "t_sent": s, "t_returned": s + 0.05} for s in sent]
        journal = [{"uptimeNanos": int(round((sent[keep_from] + offset - 0.4) * 1e9)), "kind": {"focus": {}}}]
        for s in sent[keep_from:]:
            for dt, phase in ((0.004, "flags"), (0.012, "down"), (0.03, "up")):
                journal.append({"uptimeNanos": int(round((s + dt + offset) * 1e9)), "kind": {"key": {"_0": {"phase": phase}}}})
        frames = [sent[0] + offset - 0.2, sent[-1] + offset + 0.7]
        return hid, journal, frames

    def test_a_journal_without_the_first_actions_does_not_shift_the_offset(self):
        # Review BLOCK of 8a4f46eebd8 (1): seeds from the first 5 actions only, whose events the journal no longer
        # held, matched later presses to earlier sends and moved every HID by whole presses (+13 to +34 s).
        offset = 163864.585
        hid, journal, frames = self.key_round(offset, keep_from=6)
        for extra in ((), ({"t_start": 2.7, "counts": {"first_t": frames[0]}},)):  # without and with meta's prior
            got = vj.hid_clock_offset(hid, journal, frames, *extra)
            self.assertEqual(got["source"], "journal", got)
            self.assertAlmostEqual(got["offset_s"], offset + 0.004, delta=1e-6, msg=got)
            self.assertEqual(got["matched"], [6, 12])

    def test_hid_already_on_the_host_clock_stays_with_a_journal_too(self):
        # Review BLOCK of 8a4f46eebd8 (2): sw-w1-light rounds have HID on the host clock and a cut journal; the journal
        # search found a +16 to +20 s offset that matched one action more than 0 did.
        hid, journal, frames = self.key_round(0.0, keep_from=8)
        got = vj.hid_clock_offset([dict(h, t_sent=h["t_sent"] + 1027477.0, t_returned=h["t_returned"] + 1027477.0) for h in hid],
                                  [dict(e, uptimeNanos=e["uptimeNanos"] + 1027477 * 10 ** 9) for e in journal],
                                  [f + 1027477.0 for f in frames])
        self.assertEqual((got["source"], got["offset_s"]), ("host", 0.0))

    def test_an_ambiguous_journal_places_nothing(self):
        # One key press, and the journal holds two equal presses (one not from the driver): no offset, a note.
        hid = [{"kind": "key", "t_sent": 5.0, "t_returned": 5.05}]
        journal = [{"uptimeNanos": int(round((t + 1000.0) * 1e9)), "kind": {"key": {"_0": {"phase": "down"}}}}
                   for t in (5.01, 6.51)]
        got = vj.hid_clock_offset(hid, journal, [1003.0, 1010.0])
        self.assertIsNone(got["offset_s"])
        self.assertIn("equally", got["note"])

    def test_an_input_not_logged_as_hid_before_the_press_is_not_taken_for_it(self):
        # Review BLOCK of 831d17262aa (feat-bv-51b2e1d-120x1/bv-dt-right-heavy-dark-r0): the journal has two equal
        # Cmd-Opt-I clusters, the open action's own key (not logged as HID) 2.17 s before the logged press. Both match
        # 1 of 1 action; the first has more events and won, which put the film's frames 2.08 s after the driver's
        # t_stop. Meta's t_stop bounds the offset from below.
        offset = 1021257.0
        hid = [{"kind": "key", "t_sent": 9.705, "t_returned": 9.78}]
        journal = [{"uptimeNanos": int(round((t + offset) * 1e9)), "kind": {"key": {"_0": {"phase": ph}}}}
                   for base, phases in ((7.534, ("flags", "flags", "down", "up", "flags", "flags")), (9.705, ("flags", "down", "up")))
                   for t, ph in zip((base + 0.004 + 0.01 * k for k in range(6)), phases)]
        frames = [7.0 + offset, 11.2 + offset]
        meta = {"t_start": 6.9, "t_stop": 11.9, "counts": {"first_t": frames[0]}}
        got = vj.hid_clock_offset(hid, journal, frames, meta)
        self.assertEqual(got["source"], "journal", got)
        self.assertAlmostEqual(got["offset_s"], offset + 0.004, delta=1e-6, msg=got)

    def test_hid_that_nothing_places_on_the_host_clock_is_not_used(self):
        base = tvj.build_case(self.tmp, "jumpback-unplaced", "jumpback")
        driver_clock_events(base, False)
        doc = json.loads(Path(f"{base}.events.json").read_text())
        doc["journal"] = []
        Path(f"{base}.events.json").write_text(json.dumps(doc))
        case = vj.load_case(base)
        self.assertEqual(case.hid, [])
        self.assertTrue(any("HID" in n and "not used" in n for n in case.notes), case.notes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
