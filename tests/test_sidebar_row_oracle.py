"""Synthetic films for scripts/cmux-next/sidebar_row_oracle.py, the independent judge of sidebar row insert and
remove (cmux-ad m23, STATUS 14191).

Run: python3 -I tests/test_sidebar_row_oracle.py (standard library only; no app, no build).

Each film is what `debug.sidebar_rows {"motion": "stop"}` returns: one frame per display refresh at 120 Hz, every row's
presented [x, y, w, h, opacity] in list coordinates (points, y down). A film has STILL frames before the press, MOTION
frames of an ease-out curve and TAIL still frames after it. Frame numbers are indexes into the film's frames.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORACLE = ROOT / "scripts" / "cmux-next" / "sidebar_row_oracle.py"

FPS = 120.0
ROW_H, GAP, TOP, X, W = 28.0, 2.0, 4.0, 8.0, 220.0
STEP = ROW_H + GAP  # how far a row below moves when a row opens or closes above it
STILL, MOTION, TAIL = 18, 30, 30
FIRST = STILL + 1  # the first frame that moves
SCALE, TOL = 2.0, 1.0
oracle = None


def setUpModule():
    global oracle
    spec = importlib.util.spec_from_file_location("sidebar_row_oracle", ORACLE)
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)


def ease(i):
    """Progress at motion frame i (0 up to the press, 1 from frame MOTION on): an ease-out cubic."""
    if i <= 0:
        return 0.0
    if i >= MOTION:
        return 1.0
    return 1.0 - (1.0 - i / MOTION) ** 3


def key(r):
    return f"workspace({r})"


NEW = "workspace(new)"


def film(kind="insert", rows=12, at=2, ids=False, link=False, new_height=None, row_progress=None):
    """One insert (a new row opens at index AT) or remove (row AT closes). ROW_PROGRESS {row: f(i)} moves a row on
    another curve; NEW_HEIGHT(i) overrides the new row's height."""
    frames = []
    t0 = 1000.0
    for f in range(STILL + MOTION + TAIL):
        i = f - STILL
        p = ease(i)
        views, id_map = {}, {}
        for r in range(rows):
            q = (row_progress or {}).get(r, ease)(i)
            y = TOP + r * STEP
            if kind == "insert":
                if r >= at:
                    y += q * STEP
            else:
                if r == at:
                    if i >= MOTION:
                        continue
                    views[key(r)] = [X, y, W, (1.0 - q) * ROW_H, 1.0 - q]
                    id_map[key(r)] = str(5000 + r)
                    continue
                if r > at:
                    y -= q * STEP
            views[key(r)] = [X, y, W, ROW_H, 1.0]
            id_map[key(r)] = str(5000 + r)
        if kind == "insert" and i >= 1:
            h = new_height(i) if new_height else p * ROW_H
            views[NEW] = [X, TOP + at * STEP, W, h, min(1.0, 2 * p)]
            id_map[NEW] = "7777"
        frame = {"t": t0 + f / FPS + 0.0004, "scroll": 0.0, "lift": None, "work_ms": 0.0,
                 "revision": 2.0 if i >= 1 else 1.0, "settling": False, "views": views}
        if ids:
            frame["ids"] = id_map
        if link:
            frame.update({"link": t0 + f / FPS, "target": t0 + (f + 1) / FPS, "refresh": 1 / FPS})
        frames.append(frame)
    return frames


def judge(frames, **hints):
    return oracle.judge_film("synthetic", frames, hints, oracle.Options())


def frames_of(items):
    return [item["frame"] for item in items]


class PerfectFilms(unittest.TestCase):
    def test_perfect_insert_passes_with_zero_error(self):
        result = judge(film("insert"))
        self.assertEqual(result["verdict"], "PASS", result["fails"])
        motion, = result["motions"]
        self.assertEqual((motion["kind"], motion["inserted"], motion["start_frame"], motion["end_frame"]),
                         ("insert", [NEW], STILL, STILL + MOTION))
        self.assertEqual(motion["movers"], 10)
        self.assertLess(result["max_row_error_px"], 1e-6)
        self.assertLess(result["max_height_error_px"], 1e-6)
        self.assertLess(result["progress_spread_max"], 1e-9)
        self.assertEqual(result["missed_refreshes"], 0)
        self.assertEqual(result["rebuilt_frames"], [])
        self.assertEqual(motion["late_starts"], [])
        self.assertEqual(motion["start_frame_common"], FIRST)
        self.assertIn("not available", result["identity"])
        self.assertEqual(result["selection"], "not recorded")
        self.assertAlmostEqual(result["hz"], 120.0, places=3)

    def test_perfect_remove_passes(self):
        result = judge(film("remove"))
        self.assertEqual(result["verdict"], "PASS", result["fails"])
        motion, = result["motions"]
        self.assertEqual((motion["kind"], motion["closed"]), ("remove", [key(2)]))
        self.assertLess(result["max_row_error_px"], 1e-6)
        self.assertLess(result["max_height_error_px"], 1e-6)

    def test_perfect_insert_with_identity_and_link_times_passes(self):
        result = judge(film("insert", ids=True, link=True))
        self.assertEqual(result["verdict"], "PASS", result["fails"])
        self.assertEqual(result["identity"], "ids")
        self.assertEqual((result["clock"], result["period_source"]), ("target", "refresh"))


class FailingFilms(unittest.TestCase):
    def test_row_one_frame_late_fails_on_the_frames_it_is_off(self):
        late = 9
        result = judge(film("insert", row_progress={late: lambda i: ease(i - 1)}))
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        # The least-squares p of 10 movers, one late: the late row is 9/10 of a step off, the others 1/10.
        expected = []
        for i in range(1, MOTION + 2):
            fit = (9 * ease(i) + ease(i - 1)) / 10
            if abs(ease(i - 1) - fit) * STEP * SCALE > TOL:
                expected.append(STILL + i)
        self.assertEqual(motion["row_error_frames"], expected)
        self.assertTrue(all(e["key"] == key(late) for e in motion["row_errors"]), motion["row_errors"][:3])
        self.assertEqual(motion["start_frame_common"], FIRST)
        self.assertEqual(motion["late_starts"], [{"key": key(late), "frame": FIRST + 1}])
        self.assertGreater(result["progress_spread_max"], 0.09)

    def test_row_that_jumps_fails_on_its_frame(self):
        frames = film("insert")
        frames[STILL + 5]["views"][key(0)][1] += 10.0  # a row above the new one jumps 10 pt for one frame
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        self.assertEqual(motion["row_error_frames"], [STILL + 5])
        self.assertAlmostEqual(motion["max_row_error"]["px"], 20.0, places=6)
        self.assertEqual(motion["max_row_error"]["key"], key(0))
        self.assertIn({"frame": STILL + 5, "key": key(0), "why": "jumped off the curve"}, motion["rebuilt"])

    def test_new_row_height_not_on_the_curve_fails(self):
        result = judge(film("insert", new_height=lambda i: min(1.0, i / MOTION) * ROW_H))
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        expected = [STILL + i for i in range(1, MOTION + 1) if abs(min(1.0, i / MOTION) - ease(i)) * ROW_H * SCALE > TOL]
        self.assertTrue(expected)
        self.assertEqual(motion["height_error_frames"], expected)
        self.assertTrue(all(e["key"] == NEW for e in motion["height_errors"]))
        self.assertEqual(motion["row_error_frames"], [])

    def test_new_row_shown_at_full_height_fails(self):
        result = judge(film("insert", new_height=lambda i: ROW_H))
        motion, = result["motions"]
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(motion["height_error_frames"][0], FIRST)

    def test_closing_row_that_vanishes_early_fails(self):
        frames = film("remove")
        for f in range(STILL + 10, STILL + MOTION):
            del frames[f]["views"][key(2)]
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        expected = [STILL + i for i in range(10, MOTION) if (1 - ease(i)) * ROW_H * SCALE > TOL]
        self.assertEqual(motion["height_error_frames"], expected)

    def test_rows_that_jump_to_their_place_in_one_frame_fail(self):
        # Every row on one "curve" that is a step: the new row shows at full height and the rows below are at their
        # final place in the first frame (feat film e7bd36d8, light-50 insert #0). Nothing grows; that is not a motion.
        jump = lambda i: 0.0 if i <= 0 else 1.0
        result = judge(film("insert", new_height=lambda i: ROW_H, row_progress={r: jump for r in range(12)}))
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        self.assertEqual(frames_of(motion["progress_jumps"]), [FIRST])
        self.assertLess(result["max_row_error_px"], 1e-6)

    def test_dropped_refresh_in_motion_fails(self):
        frames = film("insert")
        del frames[STILL + 6]
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(result["missed_refreshes"], 1)
        motion, = result["motions"]
        self.assertEqual([(g["frame"], g["missed"]) for g in motion["gaps"]], [(STILL + 6, 1)])
        self.assertLess(result["max_row_error_px"], 1e-6)

    def test_dropped_refresh_while_still_is_not_a_miss(self):
        frames = film("insert")
        del frames[5]
        result = judge(frames)
        self.assertEqual(result["verdict"], "PASS", result["fails"])
        self.assertEqual(result["missed_refreshes"], 0)

    def test_key_that_leaves_and_returns_is_a_rebuilt_row_without_ids(self):
        frames = film("insert")
        for f in (STILL + 4, STILL + 5):
            del frames[f]["views"][key(7)]
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        self.assertIn({"frame": STILL + 6, "from": STILL + 4, "key": key(7), "why": "left and came back"}, motion["rebuilt"])
        self.assertEqual(result["rebuilt_frames"], [STILL + 6])
        self.assertIn("not available", result["identity"])

    def test_opacity_that_falls_to_zero_and_returns_is_a_rebuilt_row_without_ids(self):
        frames = film("insert")
        for f, opacity in ((STILL + 4, 0.0), (STILL + 5, 0.4)):
            frames[f]["views"][key(8)][4] = opacity
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        self.assertIn({"frame": STILL + 6, "from": STILL + 4, "key": key(8), "why": "opacity fell to 0 and came back"},
                      motion["rebuilt"])
        self.assertEqual(frames_of(motion["flicker"]), [STILL + 4, STILL + 5])

    def test_view_id_change_is_a_rebuilt_row(self):
        frames = film("insert", ids=True, link=True)
        for f in range(STILL + 6, len(frames)):
            frames[f]["ids"][key(7)] = "9999"
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        motion, = result["motions"]
        self.assertEqual(motion["rebuilt"], [{"frame": STILL + 6, "key": key(7), "why": "view id changed"}])
        self.assertEqual(result["identity"], "ids")

    def test_width_change_is_a_rewrap(self):
        frames = film("insert")
        for f in range(STILL + 3, len(frames)):
            frames[f]["views"][key(4)][2] = W - 15.0  # a scroller appears: the row reflows narrower
        result = judge(frames)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(frames_of(result["motions"][0]["reflow"])[0], STILL + 3)


class Selection(unittest.TestCase):
    def selected_film(self, lag):
        frames = film("insert")
        for f, frame in enumerate(frames):
            frame["selected"] = key(5)
            source = frames[max(0, f - lag)]["views"][key(5)]
            frame["selection"] = list(source[:4])
        return frames

    def test_selection_on_its_row_passes(self):
        result = judge(self.selected_film(0))
        self.assertEqual(result["verdict"], "PASS", result["fails"])
        self.assertEqual(result["selection"], "recorded")
        self.assertEqual(result["motions"][0]["selection"]["off_frames"], [])

    def test_selection_one_frame_behind_its_row_fails(self):
        result = judge(self.selected_film(1))
        self.assertEqual(result["verdict"], "FAIL")
        off = result["motions"][0]["selection"]["off_frames"]
        expected = [STILL + i for i in range(1, MOTION + 1) if (ease(i) - ease(i - 1)) * STEP * SCALE > TOL]
        self.assertEqual(off, expected)


class Inputs(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", str(ORACLE), *args], capture_output=True, text=True, timeout=60)

    def test_cli_reads_a_recorder_folder_and_writes_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, frames in (("cmd-n-x1", film("insert")), ("close-x1", film("remove"))):
                os.makedirs(os.path.join(tmp, name))
                with open(os.path.join(tmp, name, "samples.json"), "w") as handle:
                    json.dump({"pressed": [[0, 0, None]], "samples": [], "motion": {"frames": frames}}, handle)
            out = os.path.join(tmp, "oracle.json")
            done = self.run_cli(tmp, "--json", out)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            lines = done.stdout.strip().splitlines()
            self.assertEqual(len(lines), 1, done.stdout)
            self.assertTrue(lines[0].startswith("sidebar row oracle: PASS"), lines[0])
            with open(out) as handle:
                report = json.load(handle)
            self.assertEqual([f["verdict"] for f in report["films"]], ["PASS", "PASS"])

    def test_cli_exit_1_on_a_failing_film(self):
        frames = film("insert")
        del frames[STILL + 6]
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "motion.json")
            with open(path, "w") as handle:
                json.dump({"frames": frames}, handle)
            done = self.run_cli(path)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertIn("sidebar row oracle: FAIL", done.stdout.strip().splitlines()[-1])

    def test_film_harness_presses_use_the_row_lists(self):
        before = [{"key": key(r), "y": TOP + r * STEP, "h": ROW_H, "selected": r == 0} for r in range(12)]
        after = before[:2] + [{"key": NEW, "y": TOP + 2 * STEP, "h": ROW_H, "selected": True}] + [
            dict(row, y=row["y"] + STEP, selected=False) for row in before[2:]]
        removed = [row for row in before if row["key"] != key(2)]
        presses = [{"kind": "insert", "index": 0, "frames": film("insert"), "rows_before": before, "rows_after": after},
                   {"kind": "remove", "index": 1, "frames": film("remove"), "rows_before": before, "rows_after": removed}]
        films = oracle.films_from_json({"scenario": "s", "presses": presses}, "film-s.json")
        results = [oracle.judge_film(name, frames, hints, oracle.Options()) for name, frames, hints in films]
        self.assertEqual([r["verdict"] for r in results], ["PASS", "PASS"], [r["fails"] for r in results])
        self.assertEqual(results[0]["motions"][0]["inserted"], [NEW])
        self.assertEqual(results[1]["motions"][0]["closed"], [key(2)])

    def test_no_motion_is_not_a_pass(self):
        frames = film("insert")[:STILL]
        result = judge(frames)
        self.assertEqual(result["verdict"], "NO MOTION")

    def test_a_60_hz_film_is_not_judged_as_120_hz(self):
        frames = film("insert")
        for f, frame in enumerate(frames):
            frame["t"] = 1000.0 + f / 60.0
        result = judge(frames)
        self.assertEqual(result["verdict"], "INVALID")


if __name__ == "__main__":
    unittest.main()
