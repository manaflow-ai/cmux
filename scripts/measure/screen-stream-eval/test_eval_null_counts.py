"""eval.py with a viewer that does not expose a count (gui-viewer.sh: frames are null in every row).

  python3 -m unittest scripts/measure/screen-stream-eval/test_eval_null_counts.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from eval import phase_numbers  # noqa: E402

PHASES = {name: {"start_unix_ms": start, "end_unix_ms": start + 5000}
          for name, start in (("idle", 0), ("typing", 10_000), ("scroll", 20_000))}


def rows(frames):
    return [{"unix_ms": t, "bytes": 1000, "frames": frames, "decode_ms": None, "encode_ms": None}
            for t in range(2000, 26_000, 1000)]


class NullCounts(unittest.TestCase):
    def test_null_frames_give_null_fps_and_keep_kbps(self):
        kbps, fps, _, _ = phase_numbers(rows(None), PHASES)
        self.assertEqual(fps, {"idle": None, "typing": None, "scroll": None})
        self.assertEqual(kbps, {"idle": 8.0, "typing": 8.0, "scroll": 8.0})

    def test_counted_frames_unchanged(self):
        kbps, fps, _, _ = phase_numbers(rows(30), PHASES)
        self.assertEqual(fps["typing"], 30.0)
        self.assertEqual(kbps["scroll"], 8.0)

    def test_null_bytes_give_null_kbps(self):
        series = [{**r, "bytes": None} for r in rows(30)]
        kbps, fps, _, _ = phase_numbers(series, PHASES)
        self.assertIsNone(kbps["idle"])
        self.assertEqual(fps["idle"], 30.0)


if __name__ == "__main__":
    unittest.main()
