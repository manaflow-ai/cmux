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

    def test_drop_budget_keeps_bench_alive_for_recovery(self):
        self.assertEqual(netem.sample_budget(20, None), 20)
        self.assertEqual(netem.sample_budget(20, 10, 5), 80)
        self.assertEqual(netem.sample_budget(20, 60, 5), 130)

    def test_a_run_with_no_first_frame_fails(self):
        self.assertEqual(netem.run_status([]), 1)
        self.assertEqual(netem.run_status([{"ok": False}, {"ok": False}]), 1)
        self.assertEqual(netem.run_status([{"ok": False}, {"ok": True}]), 0)

    def test_a_helper_that_died_at_start_stops_the_run(self):
        dead = types.SimpleNamespace(poll=lambda: 1, returncode=1,
                                     stderr=types.SimpleNamespace(read=lambda: "cannot open display"))
        torn = []
        old = netem.teardown
        netem.teardown = lambda: torn.append(True)
        try:
            with self.assertRaises(SystemExit) as stop:
                netem.started(dead, "Xvfb :99")
        finally:
            netem.teardown = old
        self.assertIn("Xvfb :99 exited 1 at start: cannot open display", str(stop.exception))
        self.assertEqual(torn, [True])
        alive = types.SimpleNamespace(poll=lambda: None)
        self.assertIsNone(netem.started(alive, "testapp"))

    def test_recovery_requires_restoration_and_a_live_host(self):
        self.assertFalse(netem.recovered_after_drop(10, False, [50], None))
        self.assertFalse(netem.recovered_after_drop(10, True, [50], "viewer silent for 3 s"))
        self.assertTrue(netem.recovered_after_drop(10, True, [50], None))

    def test_recovery_is_the_stall_past_the_drop(self):
        self.assertEqual(netem.recovery_ms(10, [400, 11_250]), 1250.0)
        self.assertEqual(netem.recovery_ms(10, [9_000]), 0.0)
        self.assertIsNone(netem.recovery_ms(None, [50]))
        self.assertIsNone(netem.recovery_ms(10, []))

    def test_drop_gate_names_each_attempt_that_failed(self):
        records = [
            {"attempt": 1, "row": "baseline", "ok": True, "connect_ms": 5},
            {"attempt": 2, "row": "drop-10s", "drop_s": 10, "connect_ms": 5,
             "recovered_after_drop": True, "recovery_ms": 900},
            {"attempt": 3, "row": "drop-60s", "drop_s": 60, "connect_ms": 5,
             "recovered_after_drop": False, "host_ended": "viewer silent for 90 s"},
            {"attempt": 4, "row": "drop-60s", "drop_s": 60, "connect_ms": 5,
             "recovered_after_drop": True, "recovery_ms": 7_000},
            {"attempt": 5, "row": "drop-10s", "drop_s": 10, "error": "refused"},
        ]
        self.assertEqual(netem.drop_gate(records, 5_000), [
            "attempt 3 (drop-60s): did not recover: viewer silent for 90 s",
            "attempt 4 (drop-60s): recovered in 7000 ms, over 5000 ms",
            "attempt 5 (drop-10s): never connected: refused",
        ])
        self.assertEqual(netem.drop_gate(records[:2], 5_000), [])

    def test_stage_join_splits_a_key_press_on_one_clock(self):
        # Viewer ns and host µs on one CLOCK_MONOTONIC: key sent at 1000 µs.
        sample = {"sent_ns": 1_000_000, "capture_us": 3_000, "complete_ns": 9_000_000,
                  "decoded_ns": 10_000_000}
        log = [
            {"inject_us": 1_200, "recv_us": 1_100},
            {"inject_us": 1_210, "recv_us": 1_100},  # the key's release, same datagram
            {"release_us": 3_000, "damage_us": 2_500, "encoded_us": 7_000, "sent_us": 7_500,
             "encoded_bytes": 70, "idr": False},
        ]
        [row] = netem.stage_samples([sample], log)
        self.assertEqual(row["up"], 0.1)
        self.assertEqual(row["inject"], 0.1)
        self.assertEqual(row["draw_damage"], 1.3)
        self.assertEqual(row["gate"], 0.5)
        self.assertEqual(row["encode"], 4.0)
        self.assertEqual(row["send"], 0.5)
        self.assertEqual(row["down"], 1.5)
        self.assertEqual(row["decode"], 1.0)
        self.assertEqual(row["total"], 9.0)
        self.assertIn("| encode | 1 | 4.00 | 4.00 |", netem.stage_table([row]))

    def test_capture_start_splits_the_readback_out_of_the_gate(self):
        sample = {"sent_ns": 1_000_000, "capture_us": 3_000, "decoded_ns": 10_000_000}
        log = [{"release_us": 3_000, "capture_start_us": 2_700, "damage_us": 2_500,
                "encoded_us": 7_000}]
        [row] = netem.stage_samples([sample], log)
        self.assertEqual(row["gate"], 0.2)
        self.assertEqual(row["capture"], 0.3)
        self.assertEqual(row["encode"], 4.0)
        self.assertIn("| capture | 1 | 0.30 | 0.30 |", netem.stage_table([row]))

    def test_stages_read_the_capture_end_once_release_is_the_gate(self):
        # Since the stage ledger, `release_us` is the gate's release and `capture_us` the capture
        # end: the join and the capture stage use `capture_us`, the encode `encode_start_us`.
        sample = {"sent_ns": 1_000_000, "capture_us": 3_000, "decoded_ns": 10_000_000}
        log = [{"release_us": 2_600, "capture_start_us": 2_700, "capture_us": 3_000,
                "encode_start_us": 3_100, "damage_us": 2_500, "encoded_us": 7_100}]
        [row] = netem.stage_samples([sample], log)
        self.assertEqual(row["gate"], 0.2)
        self.assertEqual(row["capture"], 0.3)
        self.assertEqual(row["encode"], 4.0)

    def test_stage_join_leaves_unknown_ends_out(self):
        sample = {"sent_ns": 1_000_000, "capture_us": 5_000, "decoded_ns": 10_000_000}
        [row] = netem.stage_samples([sample], [])
        self.assertEqual(row, {"total": 9.0})


if __name__ == "__main__":
    unittest.main()
