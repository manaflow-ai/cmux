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


def film(kind="insert", rows=12, at=2, ids=False, link=False, new_height=None, row_progress=None, tail=TAIL, new_from=1):
    """One insert (a new row opens at index AT) or remove (row AT closes). ROW_PROGRESS {row: f(i)} moves a row on
    another curve; NEW_HEIGHT(i) overrides the new row's height; the new row shows from motion frame NEW_FROM on."""
    frames = []
    t0 = 1000.0
    for f in range(STILL + MOTION + tail):
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
        if kind == "insert" and i >= new_from:
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

    def test_new_row_view_at_zero_size_is_not_a_position_error(self):
        # Feat film e7bd36d8 (light-50, insert #4): the new row's view shows once as [0, 0, 0, 0] (made, not laid out)
        # before its place. It draws nothing, so its edge is not a row position error; its height is still judged.
        frames = film("insert")
        frames[FIRST]["views"][NEW] = [0.0, 0.0, 0.0, 0.0, 1.0]
        result = judge(frames)
        motion, = result["motions"]
        self.assertEqual(motion["row_error_frames"], [])
        self.assertEqual(motion["height_error_frames"], [FIRST] if ease(1) * ROW_H * SCALE > TOL else [])

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


def rows_of(frame):
    """A row list as ext_sidebar_film.py keeps it (key, y, h), from a settled frame."""
    return [{"key": k, "y": v[1], "h": v[3]} for k, v in frame["views"].items()]


def judge_press(frames, kind, rows_after=None):
    """One film-*.json press with the row lists before and after it."""
    press = {"kind": kind, "index": 0, "frames": frames, "rows_before": rows_of(frames[0]),
             "rows_after": rows_after if rows_after is not None else rows_of(frames[-1])}
    (name, raw, hints), = oracle.films_from_json({"presses": [press]}, "film-s.json")
    return oracle.judge_film(name, raw, hints, oracle.Options())


def vanish(frames, k, start):
    for frame in frames[start:]:
        frame["views"].pop(k, None)
    return frames


class NoOtherRowMoves(unittest.TestCase):
    """Review FIX at 4d32183f275: a pop-in or a vanish passed when no other row moved in its own motion window."""

    def test_new_last_row_that_pops_in_at_full_height_fails(self):
        frames = film("insert", at=12, new_height=lambda i: ROW_H)
        result = judge_press(frames, "insert")
        self.assertEqual(result["verdict"], "FAIL", result["fails"])
        self.assertEqual(frames_of(result["motions"][0]["progress_jumps"]), [FIRST])
        self.assertNotEqual(judge(frames)["verdict"], "PASS")

    def test_last_row_that_vanishes_in_one_frame_fails(self):
        frames = vanish(film("remove", at=11), key(11), FIRST)
        result = judge_press(frames, "remove")
        self.assertEqual(result["verdict"], "FAIL", result["fails"])
        self.assertEqual(frames_of(result["motions"][0]["progress_jumps"]), [FIRST])

    def test_row_that_vanishes_then_rows_below_slide_8_frames_later_fails(self):
        late = {r: (lambda i: ease(i - 9)) for r in range(3, 12)}
        frames = vanish(film("remove", row_progress=late), key(2), FIRST)
        result = judge_press(frames, "remove")
        self.assertEqual(result["verdict"], "FAIL", result["fails"])
        motion, = [m for m in result["motions"] if m["kind"] != "other"]
        self.assertEqual(motion["height_error_frames"][0], FIRST)

    def test_row_that_shrinks_then_rows_below_slide_after_it_is_gone_fails(self):
        late = {r: (lambda i: ease(i - MOTION - 8)) for r in range(3, 12)}
        frames = film("remove", row_progress=late, tail=2 * MOTION + 20)
        for result in (judge_press(frames, "remove"), judge(frames)):
            self.assertEqual(result["verdict"], "FAIL", result["fails"])
            motion, = [m for m in result["motions"] if m["kind"] != "other"]
            self.assertTrue(motion["height_error_frames"], motion["fails"])

    def test_new_row_that_pops_in_after_the_rows_opened_the_gap_fails(self):
        frames = film("insert", new_height=lambda i: ROW_H, new_from=MOTION + 7)
        result = judge_press(frames, "insert")
        self.assertEqual(result["verdict"], "FAIL", result["fails"])
        motion, = [m for m in result["motions"] if m["kind"] != "other"]
        self.assertEqual(motion["height_error_frames"][0], FIRST)

    def test_new_row_named_by_the_row_lists_that_never_shows_fails(self):
        frames = film("insert", new_from=10 ** 6)
        after = rows_of(frames[-1]) + [{"key": NEW, "y": TOP + 2 * STEP, "h": ROW_H}]
        self.assertEqual(judge_press(frames, "insert", rows_after=after)["verdict"], "FAIL")


def grow(frames, k, start, count, dh, below):
    """Row K grows by DH points over COUNT frames from frame START (linear), and the rows BELOW move down with it."""
    for f in range(start, len(frames)):
        part = min(1.0, (f - start + 1) / count)
        views = frames[f]["views"]
        if k in views:
            views[k][3] += part * dh
        for b in below:
            if b in views:
                views[b][1] += part * dh
    return frames


class OtherChangesInTheFilm(unittest.TestCase):
    """Review FIX at 1faa2b697d1: windows() joined every other change in the film to the press. A correct insert
    must PASS when another row changes before or after it."""

    def assert_pass(self, frames, kind="insert"):
        for result in (judge_press(frames, kind), judge(frames)):
            self.assertEqual(result["verdict"], "PASS", result["fails"])

    def test_new_row_that_grows_later_with_the_rows_below_still_passes(self):
        frames = grow(film("insert", tail=60), NEW, STILL + MOTION + 20, 10, 12.0, [key(r) for r in range(2, 12)])
        self.assert_pass(frames)

    def test_another_row_that_grows_after_the_insert_still_passes(self):
        frames = grow(film("insert", tail=60), key(6), STILL + MOTION + 15, 8, 10.0, [key(r) for r in range(7, 12)])
        self.assert_pass(frames)

    def test_a_row_that_resizes_before_the_press_still_passes(self):
        frames = grow(film("insert"), key(6), 2, 6, 10.0, [key(r) for r in range(7, 12)])
        self.assert_pass(frames)

    def test_a_row_that_leaves_the_view_at_the_last_frame_still_passes(self):
        frames = film("insert")
        vanish(frames, key(11), len(frames) - 1)
        self.assert_pass(frames)

    def test_a_row_that_leaves_the_view_later_on_a_hitch_still_passes(self):
        frames = film("insert")
        at = STILL + MOTION + 12
        for frame in frames[at:]:
            frame["t"] += 0.032
        vanish(frames, key(11), at)
        self.assert_pass(frames)

    def test_a_row_leaving_the_view_on_a_hitch_inside_the_window_is_not_a_missed_refresh(self):
        # Feat film e7bd36d8 light-50 #0, frame 23: the rows are at their place, only a row below the view leaves.
        jump = lambda i: 0.0 if i <= 0 else 1.0
        frames = film("insert", new_height=lambda i: ROW_H, row_progress={r: jump for r in range(12)})
        for frame in frames[FIRST + 3:]:
            frame["t"] += 0.032
        vanish(frames, key(11), FIRST + 3)
        motion, = judge(frames)["motions"]
        self.assertEqual(motion["missed_refreshes"], 0, motion["gaps"])

    def test_a_new_row_named_below_the_shown_rows_is_a_note_not_a_fail(self):
        # 12 rows show; the model's new row opens at index 12, below them: nothing on screen changes.
        frames = film("insert", at=12, new_from=10 ** 6)
        after = rows_of(frames[-1]) + [{"key": NEW, "y": TOP + 12 * STEP, "h": ROW_H}]
        result = judge_press(frames, "insert", rows_after=after)
        self.assertNotEqual(result["verdict"], "FAIL", result["fails"])
        self.assertTrue(any(NEW in n for n in result.get("notes", [])), result)


class MissedRefreshesOnlyWhileRowsMove(unittest.TestCase):
    def test_hitch_after_the_rows_settle_is_not_a_missed_refresh(self):
        # Review: a 40 ms hitch 2 frames after a perfect insert settles, then a row below the view leaves 2 frames
        # later: the still frames between were joined into the motion and the hitch counted as 5 missed refreshes.
        frames = film("insert")
        settled = STILL + MOTION
        for frame in frames[settled + 2:]:
            frame["t"] += 0.032
        vanish(frames, key(11), settled + 4)
        result = judge(frames)
        self.assertEqual(result["missed_refreshes"], 0, result["fails"])
        self.assertEqual(result["verdict"], "PASS", result["fails"])


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
        removed = [dict(row, y=row["y"] - STEP) if row["y"] > TOP + 2 * STEP else row for row in before if row["key"] != key(2)]
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
