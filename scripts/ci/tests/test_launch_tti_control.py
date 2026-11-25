"""launch_tti_control: the launch bench's positive control passes only when the injected delay shows in its numbers.

Run: python3 -I scripts/ci/tests/test_launch_tti_control.py"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import launch_tti_control as C  # noqa: E402


def run(shift=0.0, chat_input=None):
    """A tti.json of four rounds, every time `shift` later."""
    rounds = []
    for kind, front, frame, paint, inp in (("cold_install", "chat", 900, 1200, chat_input),
                                           ("cold_install", "terminal", 1000, None, 1500),
                                           ("warm", "chat", 400, 600, chat_input),
                                           ("warm", "terminal", 420, None, 700)):
        row = {"kind": kind, "front": front, "first_frame_ms": frame + shift, "input_ms": None if inp is None else inp + shift,
               "stages": {} if paint is None else {"first_chat_paint": paint + shift}}
        rounds.append(row)
    return {"rounds": rounds}


class JudgeTests(unittest.TestCase):
    def test_within_thirty_percent_passes(self):
        self.assertTrue(C.judge(500, 500))
        self.assertTrue(C.judge(350, 500))
        self.assertTrue(C.judge(650, 500))

    def test_outside_thirty_percent_fails(self):
        self.assertFalse(C.judge(349, 500))
        self.assertFalse(C.judge(651, 500))
        self.assertFalse(C.judge(0, 500))  # the bench did not see the delay at all
        self.assertFalse(C.judge(-500, 500))


class MetricsTests(unittest.TestCase):
    def test_reads_first_frame_per_kind_chat_paint_and_interaction(self):
        got = C.metrics(run())
        self.assertEqual(got, {"first_frame.cold_install": 950.0, "first_frame.warm": 410.0, "first_chat_paint": 900.0,
                               "launch_to_interaction.terminal": 1100.0})

    def test_no_rounds_reads_nothing(self):
        self.assertEqual(C.metrics({}), {})
        self.assertEqual(C.metrics({"rounds": [{"kind": "warm", "first_frame_ms": True}]}), {})


class CompareTests(unittest.TestCase):
    def test_a_delay_that_shows_passes(self):
        rows = C.compare(C.metrics(run()), C.metrics(run(shift=480)), 500)
        self.assertEqual(len(rows), 4)
        self.assertTrue(all(r["delta_ms"] == 480 for r in rows))
        self.assertTrue(C.passed(rows))

    def test_a_delay_the_bench_missed_fails(self):
        base, delayed = run(), run(shift=500)
        delayed["rounds"][1]["input_ms"] = base["rounds"][1]["input_ms"]
        delayed["rounds"][3]["input_ms"] = base["rounds"][3]["input_ms"]
        rows = C.compare(C.metrics(base), C.metrics(delayed), 500)
        failed = [r["metric"] for r in rows if r["verdict"] == "fail"]
        self.assertEqual(failed, ["launch_to_interaction.terminal"])
        self.assertFalse(C.passed(rows))

    def test_a_metric_only_one_run_read_fails(self):
        rows = C.compare(C.metrics(run()), C.metrics(run(shift=500, chat_input=100)), 500)
        row = next(r for r in rows if r["metric"] == "launch_to_interaction.chat")
        self.assertEqual((row["verdict"], row["delta_ms"]), ("fail", None))

    def test_nothing_compared_fails(self):
        self.assertFalse(C.passed(C.compare({}, {}, 500)))

    def test_line_format(self):
        row = C.compare({"first_chat_paint": 900.0}, {"first_chat_paint": 1410.0}, 500.0)[0]
        self.assertEqual(C.line(row), "CONTROL metric=first_chat_paint base_ms=900.0 delayed_ms=1410.0 delta_ms=510.0 "
                                      "expected=500 pass")


class MainTests(unittest.TestCase):
    def files(self, base, delayed):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        (folder / "b.json").write_text(json.dumps(base))
        (folder / "d.json").write_text(json.dumps(delayed))
        return ["--base", str(folder / "b.json"), "--delayed", str(folder / "d.json"), "--expected", "500"]

    def test_exit_codes(self):
        self.assertEqual(C.main(self.files(run(), run(shift=520))), 0)
        self.assertEqual(C.main(self.files(run(), run(shift=40))), 1)
        self.assertEqual(C.main(self.files({}, {})), 1)


if __name__ == "__main__":
    unittest.main()
