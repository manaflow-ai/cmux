"""The classifier of scripts/ci/affected_set_replay.py: which checks a diff could have made fail."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import affected_set_replay as a  # noqa: E402


class CouldFail(unittest.TestCase):
    def test_docs_only_diff_skips_file_bound_checks(self):
        files = ["docs/ci/notes.md"]
        self.assertFalse(a.could_fail("ios-tests", files))
        self.assertFalse(a.could_fail("clippy (changed cmux-tui packages)", files))
        self.assertFalse(a.could_fail("tooling-tests", files))

    def test_input_touch_runs_the_check(self):
        self.assertTrue(a.could_fail("clippy (changed cmux-tui packages)", ["cmux-tui/crates/acpmux/src/lib.rs"]))
        self.assertTrue(a.could_fail("ios-tests", ["Packages/iOS/Foo/Bar.swift"]))

    def test_ci_plumbing_is_an_input_of_every_check(self):
        self.assertTrue(a.could_fail("ios-tests", [".github/workflows/cmux-next.yml"]))
        self.assertTrue(a.could_fail("rustfmt", ["scripts/ci/affected_jobs.py"]))

    def test_pr_dependent_and_unknown_checks_always_run(self):
        self.assertTrue(a.could_fail("risk evidence", ["docs/x.md"]))
        self.assertTrue(a.could_fail("some new check", ["docs/x.md"]))

    def test_counted_drops_skipped_cancelled_advisory_and_post_merge(self):
        base = {"name": "x", "conclusion": "SUCCESS", "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T00:01:00Z"}
        merged = "2026-01-02T00:00:00Z"
        self.assertTrue(a.counted(base, merged))
        self.assertFalse(a.counted({**base, "conclusion": "SKIPPED"}, merged))
        self.assertFalse(a.counted({**base, "conclusion": "CANCELLED"}, merged))
        self.assertFalse(a.counted({**base, "name": "chat-open (report only)"}, merged))
        self.assertFalse(a.counted({**base, "start": "2026-01-03T00:00:00Z"}, merged))

    def test_replay_sums_minutes(self):
        pr = {"number": 1, "merged_at": "2026-01-02T00:00:00Z", "files": ["docs/a.md"], "checks": [
            {"name": "ios-tests", "conclusion": "SUCCESS", "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T00:04:00Z"},
            {"name": "fast gates", "conclusion": "SUCCESS", "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T00:02:00Z"}]}
        row = a.replay([pr])["rows"][0]
        self.assertEqual((row["verdict_wall"], row["aff_wall"], row["no_machine"]), (4.0, 2.0, 4.0))


if __name__ == "__main__":
    unittest.main()
