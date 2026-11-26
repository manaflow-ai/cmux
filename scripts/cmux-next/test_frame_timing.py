#!/usr/bin/env python3
"""frame_timing: the transition frame log reader's p50 / p95 / count (python3 scripts/cmux-next/test_frame_timing.py)."""
import io, json, os, sys, tempfile, unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import frame_timing as ft  # noqa: E402


def line(ms, transition="divider_drag", event=True):
    return json.dumps({"transition": transition, "ms": ms, "commit_ms": ms - 1, "input_ts": 1.0, "first_frame_ts": 1.0 + ms / 1000,
                       "event": event, "build": "1", "at_ms": 0})


class ReaderTests(unittest.TestCase):
    def test_p95_of_one_to_hundred_is_ninety_five(self):
        rows, skipped = ft.read_lines([line(ms) for ms in range(1, 101)])
        stats = ft.summarize(rows)["divider_drag"]
        self.assertEqual(skipped, 0)
        self.assertEqual(stats["count"], 100)
        self.assertEqual(stats["p50_ms"], 51)
        self.assertEqual(stats["p95_ms"], 95)
        self.assertEqual(stats["max_ms"], 100)

    def test_the_slowest_tenth_sets_the_p95_and_one_in_twenty_does_not(self):
        rows, _ = ft.read_lines([line(8.3)] * 18 + [line(140.0)] * 2)
        stats = ft.summarize(rows)["divider_drag"]
        self.assertEqual((stats["p50_ms"], stats["p95_ms"], stats["max_ms"]), (8.3, 140.0, 140.0))
        rows, _ = ft.read_lines([line(8.3)] * 19 + [line(140.0)])
        self.assertEqual(ft.summarize(rows)["divider_drag"]["p95_ms"], 8.3)  # nearest rank 18 of 0..19

    def test_bad_lines_are_skipped_and_counted(self):
        rows, skipped = ft.read_lines(["", "not json", "[1]", json.dumps({"transition": "divider_drag", "ms": "x"}),
                                       json.dumps({"transition": "divider_drag", "ms": True}),
                                       json.dumps({"transition": "divider_drag", "ms": -1}), line(10)])
        self.assertEqual(len(rows), 1)
        self.assertEqual(skipped, 5)

    def test_transitions_are_apart_and_filter_and_last_apply(self):
        rows, _ = ft.read_lines([line(100)] * 5 + [line(10)] * 5 + [line(50, transition="other", event=False)])
        both = ft.summarize(rows)
        self.assertEqual(sorted(both), ["divider_drag", "other"])
        self.assertEqual(both["other"]["from_event"], 0)
        self.assertEqual(list(ft.summarize(rows, transition="divider_drag")), ["divider_drag"])
        newest = ft.summarize(rows, transition="divider_drag", last=5)["divider_drag"]
        self.assertEqual((newest["count"], newest["p95_ms"]), (5, 10))

    def test_empty_is_none(self):
        self.assertIsNone(ft.pct([], 0.95))
        self.assertEqual(ft.summarize([]), {})

    def test_main_reads_both_halves_older_first(self):
        with tempfile.TemporaryDirectory() as home:
            folder = os.path.join(home, "Library", "Logs", "cmux-next", "release")
            os.makedirs(folder)
            with open(os.path.join(folder, ft.OLDER), "w") as f:
                f.write("\n".join(line(200) for _ in range(5)) + "\n")
            with open(os.path.join(folder, ft.FILE), "w") as f:
                f.write("\n".join(line(10) for _ in range(5)) + "\n")
            groups = ft.default_files(home)
            self.assertEqual(list(groups), ["release"])
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(ft.main(groups["release"] + ["--json"]), 0)
            stats = json.loads(out.getvalue())["files"]["transitions"]["divider_drag"]
            self.assertEqual((stats["count"], stats["p50_ms"], stats["p95_ms"]), (10, 10, 200))
            out = io.StringIO()
            with redirect_stdout(out):
                ft.main(groups["release"] + ["--last", "5"])
            self.assertIn("divider_drag: count 5  p50 10.0 ms  p95 10.0 ms", out.getvalue())


if __name__ == "__main__":
    unittest.main()
