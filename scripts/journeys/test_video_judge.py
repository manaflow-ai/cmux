#!/usr/bin/env python3
"""Tests for video_judge.py on synthetic recordings (no app, no fleet).

Run: /work/tmp/resize-videos/venv/bin/python -I scripts/journeys/test_video_judge.py

Each case is a 400x200 px window at scale 2 (200x100 pt): two terminal panes with "text" (horizontal ink rows every
16 px) and a 2 px divider between them. The divider rests at x=200, a real drag moves it 2 px per refresh to 260,
then it rests. The trace holds the model of every tick; the frame displayed at refresh k shows the model sample of
refresh k-1 (the committed one), so a clean case has lag 0. Variants damage exactly one thing.
"""
import base64
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

import numpy as np  # noqa: E402

import video_judge as vj  # noqa: E402

W, H, SCALE = 400, 200, 2.0
P = 1 / 120
T0 = 1000.0
N = 60                    # refreshes recorded
DRAG = (10, 40)           # model moves on samples 10..39 (2 px each)
ROWS, COLS = [3, 100, 195], [50, 350]
BG = (30, 30, 40)         # pane background, RGB
INK = (200, 200, 200)     # "text"
DIV = (90, 90, 90)        # divider


def model_pos(k):
    """Divider left edge (device px) in model sample k."""
    return 200 + 2 * min(max(k - DRAG[0] + 1, 0), DRAG[1] - DRAG[0])


def shown_pos(k):
    return model_pos(max(k - 1, 0))


MOVED = 6                 # vj.MOVED_HALF_PX
LIGHT = (255, 255, 254)   # the light theme of feat-steady-8a804e1-after-r1: the divider has the panes' color at rest
LIGHT_INK = (74, 74, 74)


def draw_light(pos):
    """A light-theme frame: the divider is not visible (its color is the panes' background), and every scan row
    crosses "words" (4 px ink, gaps of 10 px), laid out from each pane's left edge, so the gaps move with the drag."""
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = LIGHT
    for left, right in ((0, pos), (pos + 2, W)):
        for x in range(left + 6, right - 6, 14):
            img[:, x:x + 4] = LIGHT_INK
    return img


def draw_offgrid(variant, pos, img):
    """Review repros of c41e4124528: an edge drawn half a pixel off the grid in EVERY frame, at rest too (the model
    stays on the grid). "offgrid-divider": the 2 px divider at pos + 0.5; "offgrid-edge": a right pane of another
    color whose left edge is one mixed pixel."""
    if variant == "offgrid-divider":
        mix = (np.array(BG) + np.array(DIV)) // 2
        img[:, pos], img[:, pos + 1], img[:, pos + 2] = mix, DIV, mix
    elif variant == "offgrid-edge":
        img[:, pos + 2] = (img[0, pos + 3].astype(int) + img[0, pos + 1].astype(int)) // 2
    return img


def draw(pos, blank_right=False, right_bg=BG):
    """One frame, RGB (H, W, 3): left pane, 2 px divider at pos, right pane."""
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = BG
    img[:, pos:] = right_bg
    ink_rows = np.array([y for y in range(H) if 5 <= y % 16 <= 10])
    img[np.ix_(ink_rows, np.arange(8, pos - 8))] = INK
    if not blank_right:
        img[np.ix_(ink_rows, np.arange(pos + 2 + 8, W - 8))] = INK
    img[:, pos:pos + 2] = DIV
    return img


def build_case(root, name, variant="clean"):
    """Writes BASE.* for one synthetic recording and returns BASE."""
    base = Path(root) / "build-x" / name
    base.parent.mkdir(parents=True, exist_ok=True)
    frames, entries = [], []
    for k in range(N):
        t = T0 + k * P
        if variant == "dropped" and k == 25:
            entries.append([t, "idle", False])
            continue
        img = draw(shown_pos(k), blank_right=(variant == "blank" and k == 30),
                   right_bg=(110, 110, 120) if variant == "flash" and k == 30 else BG)
        if variant == "light":
            img = draw_light(shown_pos(k))
        if variant == "offgrid-edge":
            img = draw(shown_pos(k), right_bg=(80, 30, 30))
        img = draw_offgrid(variant, shown_pos(k), img)
        if variant == "jumpback" and k == 25:
            img = draw(shown_pos(24) - 4)
        if variant == "blend" and k in (20, 21, 22):
            x = shown_pos(k) - 1
            img[:, x] = (np.array(BG) + np.array(DIV)) // 2
        if variant == "gap" and k in (20, 21):
            x = shown_pos(k)
            img[:, x - 6:x] = 0
        in_movie = not (variant == "encoder" and k in (15, 16, 17))
        entries.append([t, "complete", in_movie])
        frames.append((t, img, in_movie))
    _write_frames_json(base, entries)
    _write_scan(base, frames)
    _write_trace(base, variant)
    _write_events(base)
    _write_meta(base)
    _write_movie(base, frames)
    return base


def _write_frames_json(base, entries):
    doc = {"frames": entries, "rows": ROWS, "columns": COLS, "width": W, "height": H}
    Path(f"{base}.mov.frames.json").write_text(json.dumps(doc))


def _bgra(img):
    alpha = np.full(img.shape[:-1] + (1,), 255, np.uint8)
    return np.concatenate((img[..., ::-1], alpha), axis=-1)


def _write_scan(base, frames):
    header = {"width": W, "height": H, "rows": ROWS, "columns": COLS, "format": "BGRA", "time": "float64-le host seconds"}
    with open(f"{base}.mov.scan", "wb") as out:
        out.write(json.dumps(header).encode() + b"\n")
        for t, img, _ in frames:
            bgra = _bgra(img)
            out.write(struct.pack("<d", t))
            for y in ROWS:
                out.write(bgra[y].tobytes())
            for x in COLS:
                out.write(bgra[:, x].tobytes())


def _write_trace(base, variant):
    samples = []
    for k in range(N):
        x = model_pos(k) / SCALE
        left = [1, 0, 0, x, 100, 1, 0, 0, 0, x, 100, x, 100, 0, 0, 0, x, 100]
        rx, rw = x + 1, 200 - (x + 1)
        # "stale": the right pane's content stays laid out 3 pt wider for 6 samples after the drag ends.
        cw = rw + 3 if variant == "stale" and DRAG[1] <= k < DRAG[1] + 6 else rw
        right = [2, rx, 0, rw, 100, 1, 0, rx, 0, rw, 100, cw, 100, 0, rx, 0, rw, 100]
        samples.append({"t": k * P * 1000, "window": [200, 100], "panes": [left, right],
                        "dividers": [[10, x, 0, 1, 100, 1, 0]], "zoom": []})
    # Sample k is taken on the tick 1 ms before refresh k is displayed: host time T0 - 1 ms + k * P.
    trace = {"t0_s": T0 - 0.001, "refresh_ms": P * 1000, "samples": samples, "looping": []}
    Path(f"{base}.trace.json").write_text(json.dumps(trace))


def _write_events(base):
    drag = {"kind": "drag", "args": {"window_from": [101, 50], "window_to": [131, 50], "duration_ms": 250},
            "t_sent": T0 + (DRAG[0] - 1) * P, "t_returned": T0 + DRAG[1] * P}
    Path(f"{base}.events.json").write_text(json.dumps({"hid": [drag], "journal": []}))


def _write_meta(base):
    meta = {"start": {"width": W, "height": H, "scale": SCALE, "window": 0, "rows": ROWS, "columns": COLS},
            "counts": {}, "window": {"frame": [0, 0, 200, 100], "screen": [0, 0, 200, 100]}, "notes": {}}
    Path(f"{base}.meta.json").write_text(json.dumps(meta))


def _encoder():
    out = subprocess.run([vj.ffmpeg_exe(), "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    return ["-c:v", "libx265", "-crf", "8", "-x265-params", "log-level=error"] if "libx265" in out else \
        ["-c:v", "mpeg4", "-q:v", "2"]


def _write_movie(base, frames):
    """A VFR movie, one frame per in-movie complete frame, PTS = t - first t.

    Every refresh from the first complete frame on goes in as raw video at 120 fps (a refresh without a complete
    frame repeats the previous image); the select filter then keeps only the in-movie frames with their PTS."""
    by_refresh = {round((t - frames[0][0]) / P): (img, keep) for t, img, keep in frames}
    raw, keep_n, img = bytearray(), [], None
    for k in range(max(by_refresh) + 1):
        if k in by_refresh:
            img, keep = by_refresh[k]
            if keep:
                keep_n.append(k)
        raw += img.tobytes()
    select = "+".join(f"eq(n\\,{k})" for k in keep_n)
    cmd = [vj.ffmpeg_exe(), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
           "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "120", "-i", "pipe:0", "-vf", f"select={select}",
           "-fps_mode", "passthrough", *_encoder(), "-pix_fmt", "yuv420p", "-video_track_timescale", "120000",
           f"{base}.mov"]
    subprocess.run(cmd, input=bytes(raw), check=True)


def checks(report, severity=None):
    return [f["check"] for f in report["findings"] if severity is None or f["severity"] == severity]


def find(report, check):
    hits = [f for f in report["findings"] if f["check"] == check]
    assert hits, f"no {check!r} in {json.dumps(report['findings'], indent=1)}"
    return hits


class VideoJudgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="video-judge-")
        names = ["clean", "blend", "jumpback", "gap", "dropped", "blank", "encoder", "flash", "stale", "light", "offgrid-divider",
                 "offgrid-edge"]
        cls.reports = {}
        from concurrent.futures import ThreadPoolExecutor

        def one(name):
            return name, vj.judge(build_case(cls.tmp, name, name))

        with ThreadPoolExecutor(max_workers=len(names)) as pool:
            cls.reports = dict(pool.map(one, names))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_clean_drag_has_no_findings(self):
        r = self.reports["clean"]
        self.assertEqual(r["findings"], [], json.dumps(r["findings"], indent=1))
        self.assertEqual(r["dropped"], 0)
        self.assertEqual(len(r["motion"]), 1)
        self.assertEqual(r["motion_frames"], [[11, 40]])
        self.assertEqual(r["intervals_ms"]["hist"], {"1": 29})
        self.assertEqual(r["model_lag"], {"0": 30})
        self.assertGreater(r["tracked_dividers"], 0)
        self.assertEqual(r["build"], "build-x")

    def test_an_invisible_divider_is_not_tracked_on_the_gaps_between_words(self):
        # STATUS 5795 (feat-steady-8a804e1-after-r1, col-drag-fast): in the light theme the divider has the panes' color,
        # and the judge took a 15 px gap between words for it: "shown 538 px, model 459 px", a "-81 px jump" and
        # "half-pixel blends" that were text, while the app's drag hairline was at the model every frame.
        r = self.reports["light"]
        self.assertEqual(checks(r, "defect"), [], json.dumps(r["findings"], indent=1))
        self.assertEqual(r["tracked_dividers"], 0)
        self.assertTrue(any("not visible at rest" in n for n in r["notes"]), r["notes"])

    def test_the_real_light_frame_has_no_visible_divider_at_the_model(self):
        # The exact BGRA of rows 240, 481 and 722 of frame 156 (at rest) of that film: the model divider is at
        # x 455-463; the run there is the panes' white, between words.
        doc = json.loads((HERE / "fixture-video-judge-light-divider-8a804e1-r1.json").read_text())
        frame = doc["frames"]["156"]
        x0, (_, x, _, w, _) = doc["x0"], frame["model_divider"]
        for y, b64 in frame["rows"].items():
            row = np.frombuffer(base64.b64decode(b64), np.uint8).reshape(-1, 4).astype(np.int16)
            center = int(x + w / 2) - x0
            r0, r1 = vj._run_around(row, center, vj.COLOR_TOL)
            self.assertFalse(vj.divider_visible(row, r0, r1), f"row {y}: run {x0 + r0}-{x0 + r1}")

    def test_text_moved_by_whole_pixels_is_not_a_blend_and_a_new_mix_still_is(self):
        # Row 481 of frames 156 (rest) and 161 (drag) of the real film: the right pane's glyphs moved +10 px with
        # their exact antialiasing, which the old judge called a "half-pixel blend" at x 1619.
        doc = json.loads((HERE / "fixture-video-judge-light-divider-8a804e1-r1.json").read_text())
        rows = lambda f: np.frombuffer(base64.b64decode(doc["frames"][f]["rows"]["481"]), np.uint8).reshape(-1, 4)
        rest, drag = rows("156"), rows("161")
        new = [x for x in np.flatnonzero(vj.blend_mask(drag[None])[0] & ~vj.blend_mask(rest[None])[0])
               if MOVED <= x < len(drag) - MOVED]
        self.assertTrue(new, "the drag frame has blends at new places")
        no_edges = [np.zeros(len(rest), bool)]
        moved = [x for x in new if vj._moved_whole_pixels(drag, x, [rest.tobytes()], no_edges)]
        self.assertTrue(moved, [doc["x0"] + int(x) for x in new])
        # A pixel mixed half way between two colors (an edge off the grid) inside that same text: no rest frame has
        # that neighbourhood, so it is still a blend.
        edge = drag.copy()
        x = moved[0]
        edge[x, :3] = (edge[x - 1, :3].astype(int) + edge[x + 1, :3].astype(int) + 1) // 2 + 1
        self.assertFalse(vj._moved_whole_pixels(edge, x, [rest.tobytes()], no_edges))

    def test_an_edge_off_the_grid_at_rest_too_is_still_a_blend(self):
        # Review BLOCK of c41e4124528: the whole-pixel rule found the same 13 px at rest (the same off-grid edge) and
        # dropped every blend. A rest match centered on a model edge does not count.
        for name in ("offgrid-divider", "offgrid-edge"):
            hit = find(self.reports[name], "half-pixel blend")
            self.assertGreaterEqual(sum(h["frames"][1] - h["frames"][0] + 1 for h in hit), 20, (name, hit))

    def test_with_no_trace_an_edge_off_the_grid_at_rest_too_is_still_a_blend(self):
        # Review B2 of b94c3947324: with no model sample the rest match was always accepted and every blend dropped.
        base = build_case(self.tmp, "offgrid-divider-notrace", "offgrid-divider")
        Path(f"{base}.trace.json").unlink()
        hit = find(vj.judge(base, movie=False), "half-pixel blend")
        self.assertGreaterEqual(sum(h["frames"][1] - h["frames"][0] + 1 for h in hit), 20, hit)

    def test_a_dark_divider_between_panes_is_visible(self):
        row = _bgra(draw(200))[100].astype(np.int16)
        r0, r1 = vj._run_around(row, 200, vj.COLOR_TOL)
        self.assertEqual((r0, r1), (200, 202))
        self.assertTrue(vj.divider_visible(row, r0, r1))

    def test_half_pixel_blend_found(self):
        r = self.reports["blend"]
        hit = find(r, "half-pixel blend")
        self.assertEqual([h["frames"] for h in hit], [[20, 22]])
        self.assertEqual(checks(r, "defect"), ["half-pixel blend"])

    def test_jump_back_found(self):
        r = self.reports["jumpback"]
        hit = find(r, "jump back")
        self.assertEqual(hit[0]["frames"], [25, 25])
        self.assertIn("-4.0 px", hit[0]["detail"])

    def test_black_gap_found(self):
        r = self.reports["gap"]
        hit = find(r, "gap or overlap")
        self.assertEqual([h["frames"] for h in hit], [[20, 21]])
        self.assertIn("6 px", hit[0]["detail"])

    def test_dropped_refresh_counted(self):
        r = self.reports["dropped"]
        self.assertEqual(r["dropped"], 1)
        hit = find(r, "dropped frames")
        self.assertEqual(len(hit), 1)
        self.assertTrue(hit[0]["detail"].startswith("1 refresh without a new frame"), hit[0]["detail"])
        self.assertIn("1 idle", hit[0]["detail"])
        self.assertEqual(r["intervals_ms"]["hist"].get("2"), 1)
        self.assertNotIn("idle refresh in motion", checks(r))

    def test_blank_pane_found(self):
        r = self.reports["blank"]
        hit = find(r, "blank pane")
        self.assertEqual([h["frames"] for h in hit], [[30, 30]])
        self.assertIn("pane 2", hit[0]["detail"])
        self.assertEqual(checks(r, "defect"), ["blank pane"])

    def test_encoder_drops_are_recorder_faults(self):
        r = self.reports["encoder"]
        hit = find(r, "encoder dropped frames")
        self.assertEqual(hit[0]["severity"], "recorder")
        self.assertEqual(hit[0]["frames"], [15, 17])
        self.assertEqual(r["recorder"]["in_movie_false"], 3)
        self.assertEqual(checks(r, "defect"), [])
        self.assertEqual(r["dropped"], 0)

    def test_flash_found(self):
        r = self.reports["flash"]
        hit = find(r, "flash")
        self.assertEqual([h["frames"] for h in hit], [[30, 30]])
        self.assertNotIn("blank pane", checks(r))

    def test_content_not_at_final_size_after_motion(self):
        r = self.reports["stale"]
        hit = find(r, "content not at final size after motion")
        self.assertEqual(hit[0]["frames"], [41, 46])
        self.assertIn("pane 2", hit[0]["detail"])
        self.assertEqual(checks(r, "defect"), ["content not at final size after motion"])

    def test_decode_maps_movie_frames_to_complete_frames(self):
        case = vj.load_case(Path(self.tmp) / "build-x" / "encoder")
        self.assertEqual([i for i, _ in vj.decode_frames(case, 12, 22)], [12, 13, 14, 18, 19, 20, 21, 22])
        self.assertEqual([i for i, _ in vj.decode_frames(case, 18, 20)], [18, 19, 20])
        # Frame 20 shows the divider at shown_pos(20) (2 px wide, decoded at half size).
        _, rgb = next(vj.decode_frames(case, 20, 20))
        x = shown_pos(20) // 2
        self.assertGreater(int(rgb[50, x, 0]), 70)
        self.assertLess(int(rgb[50, x - 3, 0]), 50)

    def test_markdown_rows(self):
        md = vj.findings_markdown([self.reports["blank"], self.reports["clean"]])
        lines = md.strip().splitlines()
        self.assertEqual(lines[0], "| case | build | video t | frames | check | what is wrong |")
        self.assertTrue(any(line.startswith("| blank | build-x | 0.250 s | 30 | blank pane |") for line in lines), md)

    def test_scan_reader(self):
        header, records, trailing = vj.read_scan(f"{Path(self.tmp) / 'build-x' / 'clean'}.mov.scan")
        self.assertEqual(len(records), N)
        self.assertEqual(trailing, 0)
        self.assertEqual(records["rows"].shape, (N, len(ROWS), W, 4))
        self.assertEqual(records["rows"][0, 1, 201].tolist(), [DIV[2], DIV[1], DIV[0], 255])

    def test_cli_writes_json_and_pngs(self):
        base = Path(self.tmp) / "build-x" / "blank"
        out, frames_dir = Path(self.tmp) / "blank.json", Path(self.tmp) / "pngs"
        done = subprocess.run([sys.executable, "-I", str(HERE / "video_judge.py"), str(base), "--json", str(out),
                               "--frames-dir", str(frames_dir)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("blank pane", done.stdout)
        report = json.loads(out.read_text())
        self.assertEqual(report["case"], "blank")
        pngs = sorted(p.name for p in frames_dir.glob("*.png"))
        self.assertTrue(any("blank-pane-first-f30" in p for p in pngs), pngs)


if __name__ == "__main__":
    unittest.main(verbosity=2)
