#!/usr/bin/env python3
"""Exercise pair-e2e attachment selection without launching the expensive payload leg."""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
PAIR_E2E = ROOT / "scripts/ci/cmux_next_pair_e2e.py"
SPEC = importlib.util.spec_from_file_location("cmux_next_pair_e2e", PAIR_E2E)
PAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIR)


class PairE2EGuardTests(unittest.TestCase):
    def test_image_receipts_require_real_optimized_bytes_at_both_destinations(self):
        with tempfile.TemporaryDirectory() as root:
            root = str(Path(root).resolve())
            picked = Path(root, "picked", ".cmux", "attachments", "phone-1", "proof.jpg")
            sent = Path(root, "sent", ".cmux", "attachments", "phone-1", "proof.jpg")
            picked.parent.mkdir(parents=True)
            sent.parent.mkdir(parents=True)
            picked.write_bytes(b"optimized-image")
            sent.write_bytes(picked.read_bytes())
            count = picked.stat().st_size
            dimensions = subprocess.CompletedProcess([], 0, "pixelWidth: 2048\npixelHeight: 1536\n")
            with patch.object(PAIR.subprocess, "run", return_value=dimensions):
                ready = PAIR.attachment_image_ready(root, f"original=100 payload={count} confirmed={count} sent={count} path={picked}")
                self.assertEqual(ready["bytes"], count)
                self.assertEqual(ready["width"], 2048)
                event = f"readback=image-ab123 original=100 destination={root}/sent"
                self.assertEqual(PAIR.attachment_image_sent(root, event, ready), ready)
                sent.write_bytes(b"x" * count)
                with self.assertRaisesRegex(ValueError, "altered"):
                    PAIR.attachment_image_sent(root, event, ready)
                with self.assertRaisesRegex(ValueError, "expected destination"):
                    PAIR.attachment_image_ready(root, f"original=100 payload={count} confirmed={count} sent={count} path={sent}")
                with self.assertRaisesRegex(ValueError, "byte count"):
                    PAIR.attachment_image_ready(root, f"original={count} payload={count} confirmed={count} sent={count} path={picked}")
                with self.assertRaisesRegex(ValueError, "byte count"):
                    PAIR.attachment_image_ready(root, f"original=100 payload=1 confirmed=1 sent=1 path={picked}")
                with self.assertRaisesRegex(ValueError, "read-back"):
                    PAIR.attachment_image_sent(root, event.replace("/sent", "/picked"), ready)
                with self.assertRaisesRegex(ValueError, "read-back"):
                    PAIR.attachment_image_sent(root, event, None)
            dimensions.stdout = "pixelWidth: 4096\npixelHeight: 3072\n"
            with patch.object(PAIR.subprocess, "run", return_value=dimensions):
                with self.assertRaisesRegex(ValueError, "dimensions"):
                    PAIR.attachment_image_ready(root, f"original=100 payload={count} confirmed={count} sent={count} path={picked}")

    def test_connect_timeline_skips_attachment_and_normal_run_records_failure(self):
        calls = []

        def attach_leg():
            calls.append("attachment")
            return False

        self.assertTrue(
            PAIR.run_attachment_leg(True, True, True, attach_leg),
            "connect-timeline-only run must not invoke attachment",
        )
        self.assertEqual(calls, [])
        self.assertFalse(
            PAIR.run_attachment_leg(True, True, False, attach_leg),
            "ordinary run must fail when attachment leg fails",
        )
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(
            PAIR.run_attachment_leg(True, False, False, attach_leg),
            "runs without attachment capability must keep the leg neutral",
        )
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(PAIR.run_attachment_leg(False, True, False, attach_leg))
        self.assertEqual(calls, ["attachment"])
        self.assertTrue(PAIR.run_attachment_leg(True, True, False, lambda: True))


if __name__ == "__main__":
    unittest.main()
