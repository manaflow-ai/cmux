#!/usr/bin/env python3
"""scripts/ci/webviews_test_history.py keeps the base's recent webview verdicts and names the tests that flip.

A pull request fails only on webview tests its base replay passes, and that replay runs each red file
once. agent-pane-suggested-tasks failed now and then on feat-cmux-next and passed the replay by chance:
it was a new red on 9 of 40 sampled red pull request runs (2026-10-30). The history names such a test
so guards_new_reds.py --flaky keeps it a warning, while a test a push really broke stays the change's.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/webviews_test_history.py"
WORKFLOW = ROOT / ".github/workflows/ci-web.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import webviews_test_history as history  # noqa: E402

FILE = "test/agent-pane-suggested-tasks.test.ts"
TEST = f"{FILE} > sends the image"


def runs(*verdicts):
    """One run per verdict: True green, False the test red, None the file timed out, "-" not run."""
    out = []
    for i, verdict in enumerate(verdicts):
        found = {} if verdict == "-" else {FILE: False} if verdict is None else {TEST: False} if verdict is False else {FILE: True}
        out = history.record(out, f"sha{i}", 1000 + i, found) if found else out
    return out


class Flaky(unittest.TestCase):
    def test_a_lone_red_between_greens_is_flaky(self):
        self.assertEqual(history.flaky(runs(True, True, False, True, True)), [TEST])

    def test_a_lone_green_between_reds_is_flaky(self):
        self.assertEqual(history.flaky(runs(False, False, True, False), [TEST]), [TEST])

    def test_a_break_that_holds_is_not_flaky(self):
        self.assertEqual(history.flaky(runs(True, True, False, False, False)), [])

    def test_a_break_on_the_newest_push_is_not_flaky(self):
        self.assertEqual(history.flaky(runs(True, True, True, False)), [])

    def test_a_fix_that_holds_is_not_flaky(self):
        self.assertEqual(history.flaky(runs(False, False, True, True), [TEST]), [])

    def test_a_timed_out_file_says_nothing_about_its_tests(self):
        # The file never reached its tests on the timed-out run, so the red stays a lasting break.
        self.assertEqual(history.flaky(runs(True, False, None, False), [TEST]), [])
        self.assertEqual(history.verdicts(runs(True, None, True), TEST), [True, True])

    def test_a_file_that_times_out_now_and_then_is_flaky_as_a_file(self):
        found = runs(True, None, True)
        self.assertEqual(history.flaky(found, [FILE]), [FILE])
        # A run that failed with named tests did not time out: the file-level verdict is green there.
        self.assertEqual(history.verdicts(runs(False, None, False), FILE), [True, False, True])

    def test_runs_without_the_file_are_skipped(self):
        self.assertEqual(history.flaky(runs(True, "-", False, "-", True)), [TEST])

    def test_only_the_names_asked_about(self):
        self.assertEqual(history.flaky(runs(True, False, True), ["test/other.test.ts > x"]), [])


class Record(unittest.TestCase):
    def test_keeps_the_newest_runs_in_commit_order(self):
        found = []
        for i in (3, 1, 2):
            found = history.record(found, f"sha{i}", i, {FILE: True}, keep=2)
        self.assertEqual([run["sha"] for run in found], ["sha2", "sha3"])

    def test_a_rerun_of_a_push_replaces_its_run(self):
        found = history.record([], "sha", 1, {TEST: False})
        found = history.record(found, "sha", 1, {FILE: True})
        self.assertEqual(found, [{"sha": "sha", "time": 1, "files": [FILE], "red": []}])

    def test_no_results_add_no_run(self):
        self.assertEqual(history.record([], "sha", 1, {}), [])

    def test_shards_merge_and_a_red_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            one, two = Path(tmp) / "1.json", Path(tmp) / "2.json"
            one.write_text(json.dumps({FILE: True, "test/b.test.ts": True}))
            two.write_text(json.dumps({"test/b.test.ts": False}))
            self.assertEqual(history.results([str(one), str(two), str(Path(tmp) / "missing.json")]),
                             {FILE: True, "test/b.test.ts": False})

    def test_an_unreadable_history_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "history.json"
            bad.write_text("not json")
            self.assertEqual(history.load(bad), [])
            bad.write_text(json.dumps({"runs": [{"sha": 1}]}))
            self.assertEqual(history.load(bad), [])
            self.assertEqual(history.load(Path(tmp) / "missing.json"), [])


class Command(unittest.TestCase):
    def test_record_then_flaky_over_a_head_results_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            saved = tmp / "history.json"
            for i, found in enumerate(({FILE: True}, {TEST: False}, {FILE: True})):
                shard = tmp / f"shard{i}.json"
                shard.write_text(json.dumps(found))
                done = subprocess.run([sys.executable, str(SCRIPT), "record", str(saved), str(tmp / "new.json"),
                                       "--sha", f"sha{i}", "--time", str(100 + i), str(shard)],
                                      capture_output=True, text=True, check=True)
                (tmp / "new.json").replace(saved)
            self.assertIn("3 push runs", done.stdout)
            head = tmp / "head.json"
            head.write_text(json.dumps({TEST: False, "test/b.test.ts > broke": False, "test/c.test.ts": True}))
            done = subprocess.run([sys.executable, str(SCRIPT), "flaky", str(saved), "--names", str(head)],
                                  capture_output=True, text=True, check=True)
            self.assertEqual(done.stdout, f"{TEST}\n")
            done = subprocess.run([sys.executable, str(SCRIPT), "flaky", str(tmp / "missing.json"), "--names", str(head)],
                                  capture_output=True, text=True, check=True)
            self.assertEqual(done.stdout, "")


class Workflow(unittest.TestCase):
    def job(self, name):
        text = WORKFLOW.read_text(encoding="utf-8")
        start = text.index(f"\n  {name}:\n") + 1
        end = re.search(r"\n  [a-z][a-z0-9-]*:\n", text[start + 1:])
        return text[start:start + 1 + end.start()] if end else text[start:]

    def test_pushes_save_the_history_and_pull_requests_only_read_it(self):
        upkeep = self.job("webviews-test-history")
        self.assertIn("github.event_name == 'push'", upkeep)
        self.assertIn("webviews_test_history.py record", upkeep)
        self.assertIn("key: webviews-test-history-${{ github.ref_name }}-${{ github.run_id }}-${{ github.run_attempt }}", upkeep)
        self.assertIn("restore-keys: webviews-test-history-${{ github.ref_name }}-", upkeep)
        self.assertIn("timeout-minutes: 5", upkeep)
        # Optional upkeep: every step keeps going, so the job never reddens a push.
        steps = upkeep.split("\n      - name: ")[1:]
        self.assertTrue(steps)
        for step in steps:
            self.assertIn("continue-on-error: true", step, step)
        shard = self.job("react-apps-check-shard")
        upload = shard[shard.index("      - name: Upload this push's webview results"):]
        upload = upload[:upload.index("\n      - name:", 10)]
        self.assertIn("github.event_name == 'push'", upload)
        self.assertIn("continue-on-error: true", upload)
        self.assertIn("name: webviews-test-history-shard${{ matrix.shard }}", upload)
        base = self.job("react-apps-base-check")
        restore = base[base.index("      - name: Restore the base's webview test history"):]
        restore = restore[:restore.index("\n      - name:", 10)]
        self.assertIn("actions/cache/restore@", restore)
        self.assertIn("restore-keys: webviews-test-history-${{ github.base_ref }}-", restore)
        self.assertIn("continue-on-error: true", restore)
        self.assertNotIn("actions/cache/save", base)  # a pull request never writes the base's history
        self.assertNotIn("actions/cache@", restore)
        self.assertIn('webviews_test_history.py" flaky', base)

    def test_no_job_asks_for_new_permissions(self):
        for name in ("webviews-test-history", "react-apps-base-check", "react-apps-check-shard"):
            self.assertNotIn("permissions:", self.job(name), name)


if __name__ == "__main__":
    unittest.main()
