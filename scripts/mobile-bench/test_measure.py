#!/usr/bin/env python3
"""measure.py against synthetic clips whose answers are known.

    python3 scripts/mobile-bench/test_measure.py

A striped panel slides up the screen on a SwiftUI spring at 120 fps, after a
known delay, with known dropped frames; measure.py must recover the delay, the
drops and the spring.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import measure  # noqa: E402

W, H, FPS = 120, 260, 120


def panel_frame(top: float) -> bytes:
    rows = []
    for y in range(H):
        if y >= top:
            v = 200 if (int(y - top) // 6) % 2 == 0 else 150
        else:
            v = 30 + (y % 13)
        rows.append(bytes([v]) * W)
    return b"".join(rows)


def write_clip(d: Path, *, delay_s: float, response: float, damping: float, drop: set[int],
               stim_s: float = 0.5, total_s: float = 2.0, flow: str = "keyboard-show") -> None:
    y0, y1 = 0.85 * H, 0.5 * H
    frames, last = [], None
    for i in range(int(total_s * FPS)):
        t = i / FPS
        rel = t - stim_s - delay_s
        top = y0 if rel <= 0 else y0 + (y1 - y0) * measure.spring(rel, response, damping)
        f = panel_frame(round(top))
        if i in drop and last is not None:
            f = last  # the screen did not update in this slot
        frames.append(f)
        last = f
    ff = measure.ffmpeg_bin()
    subprocess.run([ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
                    "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-qp", "0",
                    "-pix_fmt", "yuv420p", str(d / "clip.mp4")], input=b"".join(frames), check=True)
    (d / "meta.json").write_text(json.dumps({"app": "synthetic", "flow": flow, "source": "test",
                                             "stimulus_t": stim_s, "fps_nominal": FPS}))


class MeasureTests(unittest.TestCase):
    def run_case(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            write_clip(d, **kw)
            return measure.measure(d, HERE / "flows.json")

    def test_spring_delay_and_drops(self):
        stim, delay = 0.5, 0.050
        # three dropped slots inside the motion (frames 70, 71 and 80; motion starts at frame 66)
        res = self.run_case(delay_s=delay, response=0.35, damping=0.86, drop={70, 71, 80}, stim_s=stim)
        self.assertAlmostEqual(res["response_ms"], delay * 1000, delta=1000 / FPS + 0.5)
        self.assertEqual(res["dropped"], 3)
        self.assertEqual(res["bursts"], 1)
        self.assertEqual(res["jumps"], 0)
        c = res["curve"]
        self.assertEqual(c["direction"], "up")
        self.assertAlmostEqual(c["spring_response_s"], 0.35, delta=0.03)
        self.assertAlmostEqual(c["spring_damping_fraction"], 0.86, delta=0.08)

    def test_bouncy_spring_overshoots(self):
        res = self.run_case(delay_s=0.0, response=0.5, damping=0.5, drop=set())
        self.assertEqual(res["dropped"], 0)
        c = res["curve"]
        self.assertAlmostEqual(c["spring_damping_fraction"], 0.5, delta=0.08)
        self.assertGreater(c["overshoot_pct"], 10)

    def test_jump_is_flagged(self):
        # a 120 ms freeze then the panel lands in one frame: dropped frames and a jump
        drop = set(range(62, 77))
        res = self.run_case(delay_s=0.0, response=0.3, damping=1.0, drop=drop)
        self.assertGreaterEqual(res["jumps"], 1)
        self.assertGreater(res["worst_gap_ms"], 100)


def write_frames(d: Path, frames: list[bytes], flow: str, stim_s: float) -> None:
    ff = measure.ffmpeg_bin()
    subprocess.run([ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
                    "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-qp", "0",
                    "-pix_fmt", "yuv420p", str(d / "clip.mp4")], input=b"".join(frames), check=True)
    (d / "meta.json").write_text(json.dumps({"app": "synthetic", "flow": flow, "source": "test",
                                             "stimulus_t": stim_s, "fps_nominal": FPS}))


def blank() -> bytearray:
    return bytearray(bytes([40]) * (W * H))


def glyph(f: bytearray, x: int, y: int, w: int = 2, h: int = 3) -> bytearray:
    """A new glyph: a few bright pixels (one character at analysis scale)."""
    g = bytearray(f)
    for r in range(y, y + h):
        for c in range(x, x + w):
            g[r * W + c] = 230
    return g


class SmallChangeTests(unittest.TestCase):
    def test_one_glyph_is_a_response(self):
        # one 2x3 glyph 200 ms after the stimulus, in a 120x260 frame: far under the region-wide mean
        stim, n = 0.5, int(1.5 * FPS)
        base, g = blank(), None
        frames = []
        for i in range(n):
            t = i / FPS
            if t >= stim + 0.2 and g is None:
                g = glyph(base, 60, 120)
            frames.append(bytes(g or base))
        with tempfile.TemporaryDirectory() as tmp:
            write_frames(Path(tmp), frames, "new-chat", stim)
            res = measure.measure(Path(tmp), HERE / "flows.json")
        self.assertIsNotNone(res["response_ms"])
        self.assertAlmostEqual(res["response_ms"], 200, delta=1000 / FPS + 0.5)

    def test_send_feedback_is_not_the_first_token(self):
        # send feedback (a big bubble) at +30 ms for 100 ms, still for 600 ms, then one glyph at +900 ms
        stim, n = 0.5, int(2.0 * FPS)
        base = blank()
        frames, cur = [], bytes(base)
        for i in range(n):
            t = i / FPS - stim
            if 0.03 <= t < 0.13:
                rows = int(40 * (t - 0.03) / 0.1) + 1
                f = bytearray(base)
                for r in range(150, 150 + rows):
                    f[r * W + 20:r * W + 110] = bytes([200]) * 90
                cur = bytes(f)
            elif i == round((stim + 0.9) * FPS):
                cur = bytes(glyph(bytearray(cur), 30, 60))
            frames.append(cur)
        with tempfile.TemporaryDirectory() as tmp:
            write_frames(Path(tmp), frames, "send-to-first-token", stim)
            res = measure.measure(Path(tmp), HERE / "flows.json")
        self.assertAlmostEqual(res["feedback_ms"], 30, delta=1000 / FPS + 0.5)
        self.assertAlmostEqual(res["response_ms"], 900, delta=1000 / FPS + 0.5)

    def test_feedback_only_has_no_response(self):
        stim, n = 0.5, int(1.5 * FPS)
        base = blank()
        frames = []
        for i in range(n):
            t = i / FPS - stim
            frames.append(bytes(glyph(base, 20, 150, 90, 40)) if t >= 0.05 else bytes(base))
        with tempfile.TemporaryDirectory() as tmp:
            write_frames(Path(tmp), frames, "send-to-first-token", stim)
            res = measure.measure(Path(tmp), HERE / "flows.json")
        self.assertIsNone(res["response_ms"])
        self.assertIn("send feedback", res["note"])


class CutTests(unittest.TestCase):
    def test_marker_flow_cannot_name_a_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            frames = [bytes(blank())] * 30
            write_frames(root, frames, "new-chat", 0.1)
            markers = root / "markers.txt"
            markers.write_text("MOBILEBENCH flow=../escaped unsupported reason=x\n"
                               f"MOBILEBENCH flow={root}/abs unsupported reason=x\n"
                               "MOBILEBENCH flow=voice-start unsupported reason=no voice\n")
            out = root / "out"
            r = subprocess.run([sys.executable, str(HERE / "cut.py"), str(root / "clip.mp4"), str(markers),
                                str(out), "--app", "t"], capture_output=True, text=True)
            self.assertIn("skipped marker flow", r.stderr)
            self.assertFalse((root / "escaped").exists())
            self.assertFalse((root / "abs").exists())
            self.assertTrue((out / "voice-start" / "meta.json").exists())
            self.assertEqual(sorted(p.name for p in out.iterdir()), ["voice-start"])


class CompareTests(unittest.TestCase):
    def run_compare(self, *args, env=None):
        command_env = os.environ.copy()
        if env:
            command_env.update(env)
        return subprocess.run([sys.executable, str(HERE / "compare-mobile"), *args],
                              capture_output=True, text=True, env=command_env)

    def test_missing_ours_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            r = self.run_compare("keyboard-show", "--ours", str(root / "nope"), "--refs", str(root), "--out", str(root / "o"))
            self.assertNotEqual(r.returncode, 0)
            (root / "ours").mkdir()
            r = self.run_compare("keyboard-show", "--ours", str(root / "ours"), "--refs", str(root), "--out", str(root / "o"))
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("no measurement for: keyboard-show", r.stderr)
            self.assertNotIn("We are slower in", r.stdout)

    def test_changed_meta_is_measured_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = root / "ours" / "keyboard-show"
            d.mkdir(parents=True)
            write_clip(d, delay_s=0.05, response=0.35, damping=0.86, drop=set(), stim_s=0.5)
            args = ("keyboard-show", "--ours", str(root / "ours"), "--refs", str(root), "--out", str(root / "o"))
            r = self.run_compare(*args)
            self.assertEqual(r.returncode, 0, r.stderr)
            first = json.loads((d / "result.json").read_text())["response_ms"]
            meta = json.loads((d / "meta.json").read_text())
            meta["stimulus_t"] = 0.45  # corrected: the stimulus was 50 ms earlier
            (d / "meta.json").write_text(json.dumps(meta))
            r = self.run_compare(*args)
            self.assertEqual(r.returncode, 0, r.stderr)
            again = json.loads((d / "result.json").read_text())["response_ms"]
            self.assertAlmostEqual(again - first, 50, delta=1)

    def test_no_reference_clip_withholds_comparative_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            d = root / "ours" / "keyboard-show"
            d.mkdir(parents=True)
            write_clip(d, delay_s=0.05, response=0.35, damping=0.86, drop=set())
            r = self.run_compare("keyboard-show", "--ours", str(root / "ours"),
                                 "--refs", str(root / "refs"), "--out", str(root / "out"))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("No comparative verdict: no paired measurements", r.stdout)
            self.assertNotIn("We are slower in", r.stdout)
            self.assertIn("no competitor clips", r.stderr)
            table = (root / "out" / "table.md").read_text()
            self.assertIn("no measured reference clip", table)

    def test_partial_reference_coverage_is_labelled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ours = root / "ours"
            measured = ours / "keyboard-show"
            measured.mkdir(parents=True)
            write_clip(measured, delay_s=0.05, response=0.35, damping=0.86, drop=set())
            own_meta = json.loads((measured / "meta.json").read_text())
            own_meta["app"] = "cmux"
            (measured / "meta.json").write_text(json.dumps(own_meta))
            for flow in json.loads((HERE / "flows.json").read_text())["flows"]:
                fid = flow["id"]
                if fid == "keyboard-show":
                    continue
                d = ours / fid
                d.mkdir()
                (d / "meta.json").write_text(json.dumps({"app": "cmux", "flow": fid,
                                                             "unsupported": "fixture omits this flow"}))

            ref = root / "refs" / "apps" / "claude-mobile" / "bench" / "keyboard-show"
            ref.mkdir(parents=True)
            shutil.copy2(measured / "clip.mp4", ref / "clip.mp4")
            ref_meta = dict(own_meta)
            ref_meta["app"] = "Claude"
            ref_meta["source"] = "test-reference"
            (ref / "meta.json").write_text(json.dumps(ref_meta))
            r = self.run_compare("all", "--ours", str(ours), "--refs", str(root / "refs"),
                                 "--out", str(root / "out"))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("none (1/16 flows compared", r.stdout)
            table = (root / "out" / "table.md").read_text()
            self.assertIn("Comparison coverage gaps", table)
            self.assertIn("`new-chat`: our app has no measured clip", table)

    def test_failed_fleet_capture_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake = fake_bin / "cmux-ci"
            fake.write_text("#!/bin/sh\necho 0123456789abcdef01234567\nexit 7\n")
            fake.chmod(0o755)
            env = {"PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}"}
            r = self.run_compare("keyboard-show", "--ref", "0" * 40, "--refs", str(root / "refs"),
                                 "--out", str(root / "out"), env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("fleet step 0123456789abcdef01234567 failed with exit 7", r.stderr)
            self.assertIn("fleet/step.log", r.stderr)


if __name__ == "__main__":
    unittest.main()
