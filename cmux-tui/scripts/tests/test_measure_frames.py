import importlib.util
import json
import socket
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "measure-frames.py"
SPEC = importlib.util.spec_from_file_location("measure_frames", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
measure_frames = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure_frames)


class PointerAuthorityTests(unittest.TestCase):
    def test_attach_handshake_advertises_guarded_pointer_input(self) -> None:
        sender, receiver = socket.socketpair()
        try:
            measure_frames.send_browser_attach_handshake(sender, 17)
            stream = receiver.makefile("r", encoding="utf-8")
            self.assertEqual(
                json.loads(stream.readline()),
                {
                    "id": 0,
                    "cmd": "set-client-info",
                    "kind": "measure-frames",
                    "capabilities": ["browser-pointer-frame-guard-v1"],
                },
            )
            self.assertEqual(
                json.loads(stream.readline()),
                {"id": 1, "cmd": "attach-surface", "surface": 17},
            )
        finally:
            sender.close()
            receiver.close()

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

    def test_recovery_poke_activates_before_guarded_pointer_authority_exists(self) -> None:
        self.assertEqual(
            measure_frames.recovery_poke(7, None),
            {"cmd": "browser-activate", "surface": 7},
        )
        self.assertEqual(
            measure_frames.recovery_poke(7, 11),
            {
                "cmd": "browser-wheel-guarded",
                "surface": 7,
                "x_px": 10,
                "y_px": 10,
                "delta_y_px": 120,
                "frame_seq": 11,
            },
        )


if __name__ == "__main__":
    unittest.main()
