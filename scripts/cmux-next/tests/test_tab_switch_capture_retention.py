"""A successful capture remains reviewable only when retention is requested."""
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tab_switch_capture as capture


class RetentionTests(unittest.TestCase):
    def complete_block(self, root, retain):
        block = Path(root) / "block-01"
        block.mkdir()
        video = block / "recording.mp4"
        video.write_bytes(b"video fixture")
        frames_file = block / "frames.bin"
        frames_file.write_bytes(b"frame fixture")
        recorder = capture.Capture.__new__(capture.Capture)
        recorder.block_dir = str(block)
        recorder.blocks = 1
        recorder.names = ["activate:mark"]
        recorder.retain = retain
        recorder.retained = []
        recorder.session = types.SimpleNamespace(stop=lambda _: str(video))
        recorder.decode = lambda *_: {"w": 1, "h": 1, "fps": 60,
                                     "frames": 2, "marker": [[0, 0], [.1, 255]]}
        frames = [(0, b"\x00"), (.1, b"\xff")]
        with patch.object(capture.time, "sleep"), patch.object(capture.judge, "read_segment", return_value=frames):
            self.assertEqual(recorder.end(), (frames, {"activate:mark": .1}))
        return recorder, block, video, frames_file

    def test_passing_capture_retains_video_frames_and_action_mapping(self):
        with tempfile.TemporaryDirectory() as root:
            recorder, block, video, frames_file = self.complete_block(root, retain=True)
            self.assertTrue(video.is_file())
            self.assertTrue(frames_file.is_file())
            receipt = json.loads((block / "capture.json").read_text())
            self.assertEqual(receipt["flips"], {"activate:mark": .1})
            self.assertEqual(receipt["video"], str(video))
            self.assertEqual(recorder.retained, [receipt])

    def test_existing_default_removes_temporary_capture_block(self):
        with tempfile.TemporaryDirectory() as root:
            recorder, block, _, _ = self.complete_block(root, retain=False)
            self.assertFalse(block.exists())
            self.assertEqual(recorder.retained, [])


if __name__ == "__main__":
    unittest.main()
