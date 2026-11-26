"""scripts/measure/update_frames.py: the transition-frame verdict of one Restart to Update (ask-ad4a68e740)."""
import importlib.util
import io
import json
import struct
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("update_frames", HERE.parent / "update_frames.py")
uf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uf)

CLICK, OLD, NEW = 1_000_000, 11, 22
WIN = [0, 25, 1200, 800]


def win(pid, alpha=1.0, frame=WIN, number=1):
    return [pid, number, 0, alpha, *frame]


def round_dir(tmp, samples, frames=None, ready=None):
    d = Path(tmp)
    (d / "timeline.json").write_text(json.dumps({"v1_pid": OLD, "timeline": {"click_unix_ms": CLICK}}))
    lines = [json.dumps({"display": [1512, 982]})] + [json.dumps({"t": CLICK + t, "w": w}) for t, w in samples]
    (d / "windows.ndjson").write_text("\n".join(lines) + "\n")
    if frames is not None:
        w, h = 4, 4
        (d / "frames.json").write_text(json.dumps({"w": w, "h": h, "fps": 60}))
        (d / "frames.gray").write_bytes(b"".join(struct.pack("<d", t) + bytes([v] * (w * h)) for t, v in frames))
        (d / "rec.log").write_text(f"READY epoch_ms={ready}\n")
    return d


def judge(d):
    with redirect_stdout(io.StringIO()) as out:
        uf.main(d)
    return json.loads(out.getvalue())


class UpdateFramesTests(unittest.TestCase):
    def test_a_plain_quit_and_relaunch_in_place_has_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = judge(round_dir(tmp, [(-500, [win(OLD)]), (40, []), (3500, [win(NEW, number=7)])]))
        self.assertFalse(v["transition_frames"])
        self.assertEqual((v["windows"]["old_gone_ms"], v["windows"]["new_first_ms"], v["windows"]["blank_gap_ms"]),
                         (40, 3500, 3460))
        self.assertTrue(v["windows"]["same_frame"])

    def test_a_fade_a_jump_and_a_splash_are_transition_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = judge(round_dir(tmp, [(-500, [win(OLD)]), (20, [win(OLD, alpha=0.5)]), (60, []),
                                      (3000, [win(NEW, frame=[100, 100, 400, 300])]), (3100, [win(NEW)])]))
        self.assertTrue(v["transition_frames"])
        self.assertEqual(v["windows"]["partial_alpha_samples"], 1)
        self.assertEqual(v["windows"]["transition_states"], 2, "the faded window and the small first window")

    def test_relaunched_somewhere_else_is_not_the_same_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = judge(round_dir(tmp, [(-500, [win(OLD)]), (40, []), (3500, [win(NEW, frame=[50, 25, 1200, 800])])]))
        self.assertFalse(v["windows"]["same_frame"])
        self.assertTrue(v["transition_frames"])

    def test_content_drawing_in_steps_counts_frames(self):
        samples = [(-500, [win(OLD)]), (40, []), (3500, [win(NEW)])]
        # Recording starts 1 s before the click; the new window draws gray, then 120, then settles at 200.
        frames = [(0.0, 50), (0.5, 50), (4.5, 10), (4.6, 120), (4.7, 200), (6.0, 200)]
        with tempfile.TemporaryDirectory() as tmp:
            v = judge(round_dir(tmp, samples, frames=frames, ready=CLICK - 1000))
        self.assertEqual(v["content"]["content_transition_frames"], 2)
        self.assertEqual(v["content"]["content_settled_ms"], 3600)
        self.assertTrue(v["transition_frames"])

    def test_crop_is_the_new_windows_in_video_pixels(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = round_dir(tmp, [(-500, [win(OLD)]), (40, []), (3500, [win(NEW)])])
            self.assertEqual(uf.crop(d, 3024), [0, 50, 2400, 1600])


if __name__ == "__main__":
    unittest.main()
