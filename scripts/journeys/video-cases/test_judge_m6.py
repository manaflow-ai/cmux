#!/usr/bin/env python3
"""judge_m6.py, the m6 (d) film check (cmux-ad m6; frame-owner-s4): one verdict line per film, from judge_pixel's m6
report (its kinds.terminal row), with a fake judge (no film, no numpy).

    python3 scripts/journeys/video-cases/test_judge_m6.py
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import judge_m6 as M  # noqa: E402


def terminal_row(fail=0, frames=100, late=3, not_judged=0, ranges=""):
    return {"frames": frames, "pass": frames - fail - late - not_judged, "late": late, "page_late_1": 0, "fail": fail,
            "not_judged": not_judged, "fail_ranges": ranges, "late_ranges": "", "page_late_1_ranges": "",
            "not_judged_ranges": "", "fail_by_rule": {"E2": fail, "E3": 0, "E4": 0, "E5": 0, "page early 1": 0}}


def report(kinds, findings=()):
    return {"base": "/x/px-keys-rk-3t-s1r-s1", "m6": {"kinds": kinds, "late_as_a_whole": 0}, "findings": list(findings)}


class VerdictTests(unittest.TestCase):
    def test_no_failing_terminal_frame_passes(self):
        v = M.verdict(report({"terminal": terminal_row()}), judge_exit=0)
        self.assertEqual(v["status"], "pass", v)
        self.assertEqual((v["fail"], v["frames"], v["late"]), (0, 100, 3))

    def test_a_failing_terminal_frame_fails_with_its_frames_and_rules(self):
        v = M.verdict(report({"terminal": terminal_row(fail=2, ranges="41-42")}), judge_exit=1)
        self.assertEqual(v["status"], "fail", v)
        self.assertEqual(v["fail"], 2)
        self.assertIn("41-42", v["line"])
        self.assertIn("E2 2", v["line"])

    def test_other_findings_of_the_judge_do_not_decide_it(self):
        """A page's frames, a divider rect or a clock finding are the judge's other items: m6 (d) is the terminals'."""
        v = M.verdict(report({"terminal": terminal_row(), "page": terminal_row(fail=9)},
                             findings=[{"check": "m6 contract", "where": "page content"}]), judge_exit=1)
        self.assertEqual(v["status"], "pass", v)

    def test_no_terminal_frame_judged_is_not_judged_never_a_pass(self):
        for kinds in ({}, {"terminal": terminal_row(frames=40, late=0, not_judged=40)}, {"page": terminal_row()}):
            v = M.verdict(report(kinds), judge_exit=0)
            self.assertEqual(v["status"], "not judged", (kinds, v))

    def test_a_judge_that_could_not_read_the_film_is_not_judged(self):
        v = M.verdict(None, judge_exit=2, stderr="no scan")
        self.assertEqual(v["status"], "not judged", v)
        self.assertIn("no scan", v["line"])


class RunTests(unittest.TestCase):
    """main(): the judge runs once per film (its JSON read back), the exit is 0 when every film passes, 1 when one fails,
    2 when one is not judged (and none fails)."""

    def fake_judge(self, folder, reports, code):
        path = Path(folder) / "video-cases" / "judge_pixel.py"
        path.parent.mkdir(parents=True)
        path.write_text(textwrap.dedent(f"""\
            import json, sys
            reports = {json.dumps(reports)!r}
            args = sys.argv[1:]
            out = args[args.index("--json") + 1]
            base = args[0]
            rep = json.loads(reports).get(base.rsplit("/", 1)[-1])
            if rep is None:
                sys.stderr.write("no scan for " + base)
                sys.exit(2)
            open(out, "w").write(json.dumps(rep))
            sys.exit({code})
            """))
        return path

    def run_main(self, reports, code, bases):
        with tempfile.TemporaryDirectory() as folder:
            judge = self.fake_judge(folder, reports, code)
            out = Path(folder) / "m6.json"
            argv = [*bases, "--judge", str(judge), "--json", str(out)]
            exit_code = M.main(argv)
            return exit_code, json.loads(out.read_text())

    def test_every_film_passes(self):
        reports = {"a-s1": report({"terminal": terminal_row()}), "a-reduce": report({"terminal": terminal_row(late=0)})}
        code, out = self.run_main(reports, 0, ["/r/a-s1", "/r/a-reduce.mov.scan"])
        self.assertEqual(code, 0)
        self.assertEqual([f["status"] for f in out["films"]], ["pass", "pass"])
        self.assertEqual(out["status"], "pass")

    def test_one_failing_film_fails_the_check(self):
        reports = {"a-s1": report({"terminal": terminal_row(fail=1, ranges="7")}), "a-reduce": report({"terminal": terminal_row()})}
        code, out = self.run_main(reports, 1, ["/r/a-s1", "/r/a-reduce"])
        self.assertEqual(code, 1)
        self.assertEqual(out["status"], "fail")

    def test_a_film_with_no_scan_is_not_judged(self):
        reports = {"a-s1": report({"terminal": terminal_row()})}
        code, out = self.run_main(reports, 0, ["/r/a-s1", "/r/a-reduce"])
        self.assertEqual(code, 2)
        self.assertEqual([f["status"] for f in out["films"]], ["pass", "not judged"])
        self.assertEqual(out["status"], "not judged")

    def test_the_base_of_any_recording_file(self):
        for name in ("/r/a-s1", "/r/a-s1.mov", "/r/a-s1.mov.scan", "/r/a-s1.trace.json", "/r/a-s1.meta.json"):
            self.assertEqual(M.base_of(name), "/r/a-s1", name)


class PinnedJudgeTests(unittest.TestCase):
    """Without --judge, the judge is R-HARNESS's judge_pixel.py at JUDGE_REF (3e.1), taken from git into a folder of its
    own with the video_judge.py it imports; never the kit's own older judge_pixel.py (no m6 rows)."""

    def test_the_pin(self):
        self.assertRegex(M.JUDGE_REF, r"^[0-9a-f]{11,40}$")
        self.assertEqual(M.JUDGE_FILES, ("scripts/journeys/video-cases/judge_pixel.py", "scripts/journeys/video_judge.py"))

    def test_extract_lays_out_the_judge_and_its_import(self):
        calls = []

        def show(ref, path):
            calls.append((ref, path))
            return f"# {path} at {ref}\\n"

        with tempfile.TemporaryDirectory() as folder:
            judge = M.extract_judge(folder, show=show)
            self.assertEqual(judge, Path(folder) / "video-cases" / "judge_pixel.py")
            self.assertTrue((Path(folder) / "video_judge.py").is_file())
            self.assertEqual(calls, [(M.JUDGE_REF, f) for f in M.JUDGE_FILES])


if __name__ == "__main__":
    unittest.main(verbosity=2)
