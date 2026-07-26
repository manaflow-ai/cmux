import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "measure-frames.py"
SPEC = importlib.util.spec_from_file_location("measure_frames", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
measure_frames = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure_frames)


class PointerAuthorityTests(unittest.TestCase):
    def test_frame_authority_requires_explicit_live_metadata(self) -> None:
        self.assertEqual(
            measure_frames.pointer_frame_seq_from_event(
                {"status": "live", "pointer_frame_seq": 8}
            ),
            8,
        )
        self.assertIsNone(
            measure_frames.pointer_frame_seq_from_event(
                {"status": "failed", "pointer_frame_seq": 9}
            )
        )
        self.assertIsNone(
            measure_frames.pointer_frame_seq_from_event({"pointer_frame_seq": 10})
        )
        self.assertIsNone(
            measure_frames.pointer_frame_seq_from_event(
                {"status": "live", "pointer_frame_seq": True}
            )
        )


if __name__ == "__main__":
    unittest.main()
