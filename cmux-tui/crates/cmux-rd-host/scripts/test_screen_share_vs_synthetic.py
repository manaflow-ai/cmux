"""screen-share-vs.py --source synthetic: the host command and marker of a rig-less run.

    python3 -m unittest cmux-tui/crates/cmux-rd-host/scripts/test_screen_share_vs_synthetic.py
"""
import contextlib
import importlib.util
import io
import os
import shlex
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("screen_share_vs", os.path.join(HERE, "screen-share-vs.py"))
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)


def orchestrator(**kw):
    args = dict(source="synthetic", synthetic_size=None, link_bind=None, host="h", viewer="v",
                via="ssh", root="/home/u/cmux rd", python="/usr/bin/python3", out=None)
    args.update(kw)
    return vs.Orchestrator(types.SimpleNamespace(**args))


class SyntheticSource(unittest.TestCase):
    def test_key_trials_serve_a_still_picture_with_the_timing_log(self):
        cmd = orchestrator(synthetic_size="1280x720", link_bind="10.0.0.2").synthetic_serve("key")
        timing = shlex.quote("/home/u/cmux rd/state/timing.jsonl")
        self.assertTrue(cmd.startswith(f": > {timing} && CMUX_RD_TIMING_LOG={timing} "), cmd)
        argv = shlex.split(cmd.split(f"CMUX_RD_TIMING_LOG={timing} ", 1)[1])
        self.assertEqual(argv[:6], ["/home/u/cmux rd/bin/cmux-rd", "serve", "--profile", "high",
                                    "--source", "synthetic-still"])
        self.assertIn("--synthetic-size", argv)
        self.assertEqual(argv[argv.index("--link-bind") + 1], "10.0.0.2:0")
        self.assertEqual(argv[-2:], ["2>", "/home/u/cmux rd/state/serve.err"])

    def test_fps_trials_move_and_tick_without_a_timing_log(self):
        cmd = orchestrator().synthetic_serve("fps")
        self.assertNotIn("CMUX_RD_TIMING_LOG", cmd)
        self.assertIn("--source synthetic-tick", cmd)
        self.assertNotIn("--synthetic-size", cmd)

    def test_link_bind_must_be_an_ipv4_literal(self):
        with self.assertRaises(ValueError):
            orchestrator(link_bind="1.2.3.4; rm -rf ~").synthetic_serve("key")

    def test_the_marker_is_at_the_origin_without_a_rig(self):
        o = orchestrator()

        def no_rig(*_a, **_k):
            raise AssertionError("a synthetic run never calls the rig")

        o.rig = no_rig
        self.assertEqual(o.marker([]), [0, 0])
        self.assertEqual(o.marker(["--tick", "--motion"]), [0, 0])

    def test_motion_quality_is_null_with_a_reason_and_no_marker_log_read(self):
        o = orchestrator()

        def no_host(*_a, **_k):
            raise AssertionError("a synthetic run reads no marker log")

        o.host.run = no_host
        self.assertIsNone(o.motion_geometry())
        self.assertIn("--source synthetic", o.quality_null)

    def test_the_presented_leg_is_skipped_without_the_rig(self):
        o = orchestrator(presented_pid=1, presented_window=2, presented_origin="0,0",
                         presented_at="300,16")

        def no_rig(*_a, **_k):
            raise AssertionError("a synthetic run never calls the rig")

        o.rig = no_rig
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(o.run_presented())

    def test_a_synthetic_run_emits_the_budget_table_and_compares(self):
        row = {"up": 1.0, "inject": 0.5, "draw": None, "sck": None, "gate": None, "encode": 5.0,
               "send": 3.0, "first_packet": 1.0, "down": 4.0, "decode": 2.0, "total": 20.0}
        why = "--source synthetic streams no display (cmux leg only)"
        before = vs.build_budget({"rows": [row], "quality_null": "synthetic"}, {"skipped": why},
                                 label="before", source="synthetic")
        after = vs.build_budget({"rows": [dict(row, total=15.0)], "quality_null": "synthetic"},
                                {"skipped": why}, label="after", source="synthetic")
        self.assertEqual(after["source"], "synthetic")
        total = next(r for r in after["rows"] if r["row"] == "Total")
        self.assertEqual(total["cmux"]["p50"], 15.0)
        self.assertEqual(total["apple"], {"null": why})
        present = next(r for r in after["rows"] if r["row"] == "Present")
        self.assertIn("--source synthetic", present["cmux"]["null"])
        text = "\n".join(vs.format_budget(after))
        self.assertIn("(--source synthetic)", text)
        self.assertIn(why, text)
        cmp = "\n".join(vs.format_compare(before, after))
        self.assertIn("before (synthetic) -> after (synthetic)", cmp)
        self.assertIn("-5", cmp)


if __name__ == "__main__":
    unittest.main()
