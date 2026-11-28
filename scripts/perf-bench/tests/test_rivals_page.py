#!/usr/bin/env python3
"""rivals_page.py (wow-20 idea 4): a rivals results.json becomes the daily head-to-head page and its history; a rerun
replaces its day, the history keeps --days entries, and a run with no measured row publishes nothing.
Run: python3 -I scripts/perf-bench/tests/test_rivals_page.py"""
import contextlib, copy, io, json, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import rivals_page  # noqa: E402

FIXTURE = os.path.join(HERE, "..", "..", "bench", "tests", "fixtures", "rivals", "results.json")


def load():
    with open(FIXTURE) as handle:
        return json.load(handle)


def run_page(result, history=None, days=90):
    out = tempfile.mkdtemp()
    today = os.path.join(out, "today.json")
    with open(today, "w") as handle:
        json.dump(result, handle)
    hist = None
    if history is not None:
        hist = os.path.join(out, "history.json")
        with open(hist, "w") as handle:
            json.dump(history, handle)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = rivals_page.page(today, hist, os.path.join(out, "page"), "a" * 40, days)
    if code:
        return code, None, None
    with open(os.path.join(out, "page", "index.json")) as handle:
        index = json.load(handle)
    with open(os.path.join(out, "page", "index.md")) as handle:
        md = handle.read()
    return code, index, md


class RivalsPage(unittest.TestCase):
    def test_headline_table_with_ratios(self):
        code, index, md = run_page(load())
        self.assertEqual(code, 0)
        self.assertEqual(len(index), 1)
        self.assertEqual(index[0]["rows"]["fresh-window"], {"cmux": 820, "claude": 2400})
        self.assertIn("| Scenario | cmux | claude |", md)
        self.assertIn("| Cold start to first window | 820 ms | 2,400 ms (2.9×) |", md)
        self.assertIn("| Warm relaunch to window | 310 ms | 925 ms (3.0×) |", md)
        self.assertIn("| Idle memory ceiling | 410 MB | 780 MB (1.9×) |", md)
        self.assertIn("## Every other row", md)
        self.assertNotIn("## Last", md)  # one day: no trend yet

    def test_rerun_replaces_its_day_and_trend_shows(self):
        first = load()
        _, index, _ = run_page(first)
        second = copy.deepcopy(first)
        second["date"] = "2026-11-24"
        _, index, md = run_page(second, index)
        self.assertEqual([e["date"] for e in index], ["2026-11-23", "2026-11-24"])
        rerun = copy.deepcopy(second)
        rerun["rows"]["fresh-window"]["cmux"]["median"] = 700
        _, index, md = run_page(rerun, index)
        self.assertEqual([e["date"] for e in index], ["2026-11-23", "2026-11-24"])
        self.assertEqual(index[-1]["rows"]["fresh-window"]["cmux"], 700)
        self.assertIn("## Last 2 days (cmux / best rival)", md)
        self.assertIn("| 2026-11-24 | aaaaaaaa | 700 ms / 2,400 ms |", md)

    def test_history_is_bounded(self):
        history = [{"date": f"2026-10-{d:02d}", "rows": {}} for d in range(1, 31)]
        _, index, _ = run_page(load(), history, days=10)
        self.assertEqual(len(index), 10)
        self.assertEqual(index[-1]["date"], "2026-11-23")

    def test_nothing_measured_publishes_nothing(self):
        result = load()
        result["rows"] = {}
        code, _, _ = run_page(result)
        self.assertEqual(code, 1)

    def test_unreadable_history_starts_over(self):
        out = tempfile.mkdtemp()
        bad = os.path.join(out, "bad.json")
        with open(bad, "w") as handle:
            handle.write("<html>404</html>")
        today = os.path.join(out, "today.json")
        with open(today, "w") as handle:
            json.dump(load(), handle)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(rivals_page.page(today, bad, os.path.join(out, "page"), None, 90), 0)


if __name__ == "__main__":
    unittest.main()
