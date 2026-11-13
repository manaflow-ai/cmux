#!/usr/bin/env python3
"""Pure CLI-shape checks for the screen-sharing netem probe."""
import importlib.util
import pathlib
import types
import unittest


PATH = pathlib.Path(__file__).with_name("screen-share-netem.py")
SPEC = importlib.util.spec_from_file_location("screen_share_netem", PATH)
netem = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(netem)


class ScreenShareNetemCliTests(unittest.TestCase):
    def test_repeated_drop_durations_are_preserved_as_rows(self):
        args = types.SimpleNamespace(drop_seconds=[10.0, 60.0], blip_at=5.0, blip_s=2.0)
        self.assertEqual(args.drop_seconds, [10.0, 60.0])
        self.assertEqual([f"drop-{duration:g}s" for duration in args.drop_seconds], ["drop-10s", "drop-60s"])

    def test_legacy_single_blip_remains_a_single_row(self):
        args = types.SimpleNamespace(drop_seconds=None, blip_at=5.0, blip_s=2.0)
        durations = args.drop_seconds if args.drop_seconds is not None else [args.blip_s]
        self.assertEqual(durations, [2.0])


if __name__ == "__main__":
    unittest.main()
