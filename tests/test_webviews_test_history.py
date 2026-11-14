#!/usr/bin/env python3
"""scripts/ci/webviews_test_history.py keeps the base's recent webview verdicts and names the tests that flip.

A pull request fails only on webview tests its base replay passes, and that replay runs each red file
once. agent-pane-suggested-tasks failed now and then on feat-cmux-next and passed the replay by chance:
it was a new red on 9 of 40 sampled red pull request runs (2026-10-30). The history names such a test
so guards_new_reds.py --flaky keeps it a warning, while a test a push really broke stays the change's.
"""
import io
import itertools
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/webviews_test_history.py"
WORKFLOW = ROOT / ".github/workflows/ci-web.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import webviews_test_history as history  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

FILE = "test/agent-pane-suggested-tasks.test.ts"
TEST = f"{FILE} > sends the image"


def runs(*verdicts, keys=None):
    """One run per verdict: True green, False the test red, None the file timed out, "-" not run. `keys` gives each
    run's inputs key (default: all the same inputs)."""
    out = []
    for i, verdict in enumerate(verdicts):
        found = {} if verdict == "-" else {FILE: False} if verdict is None else {TEST: False} if verdict is False else {FILE: True}
        out = history.record(out, f"sha{i}", 1000 + i, found, keys[i] if keys else "same") if found else out
    return out


class Flaky(unittest.TestCase):
    def test_a_test_that_passes_and_fails_on_the_same_inputs_is_flaky(self):
        # agent-pane-suggested-tasks: base runs 41075124126 red and 41075808917 green on the same webview tree.
        self.assertEqual(history.flaky(runs(True, True, False, True, True)), [TEST])
        self.assertEqual(history.flaky(runs(False, False, True, False), [TEST]), [TEST])
        self.assertEqual(history.flaky(runs(True, False, keys=["a", "a"])), [TEST])

    def test_a_break_and_its_revert_are_not_flaky(self):
        # A working commit, a broken one and its revert: green, red, green, each on its own inputs (review, 10-30).
        self.assertEqual(history.flaky(runs(True, False, True, keys=["w", "x", "w"])), [])
        self.assertEqual(history.flaky(runs(True, False, True, keys=["w", "x", "r"])), [])
        # Pushes that change no webview input in between still follow the code.
        self.assertEqual(history.flaky(runs(True, True, False, False, True, True, keys="wwxxrr")), [])

    def test_a_red_that_comes_back_after_a_green_is_flaky_on_any_inputs(self):
        # send-stream-motion, 2026-11-08: nearly every feat-cmux-next push changed a webview input, so its reds and
        # greens never shared an inputs key, and its replay charged it to unrelated pull requests (#37286, #36911).
        self.assertEqual(history.flaky(runs(True, False, True, False, True, keys="abcde")), [TEST])
        self.assertEqual(history.flaky(runs(False, True, False, keys="abc"), [TEST]), [TEST])
        # A run the file missed, or a timeout that names no test, does not split one red stretch in two.
        self.assertEqual(history.flaky(runs(True, False, "-", None, False, True, keys="abcdef")), [])

    def test_a_test_whose_file_flakes_through_its_siblings_is_flaky_once_it_failed_on_the_base(self):
        # send-stream-motion, 2026-11-08: send, steer and tools share one assertion and fail now and then, one on one
        # run and another on the next. send failed on one base push only; #37286's replay passed it and failed steer.
        stream = "test/send-stream-motion.test.ts"
        send, steer, tools = (f"{stream} > {s}: the default follow motion" for s in ("send", "steer", "tools"))
        found = []
        for i, red in enumerate([[], [steer], [], [send], [], [tools], []]):
            found = history.record(found, f"sha{i}", 1000 + i, {stream: True, **{n: False for n in red}}, f"k{i}")
        self.assertEqual(history.flaky(found, [send, steer, tools]), [send, steer, tools])
        # A test of that file that never failed on the base stays the change's.
        self.assertEqual(history.flaky(found, [f"{stream} > with motion off"]), [])
        # One sibling broken once and fixed is one red stretch: not a flaky file.
        once = history.record(history.record(history.record([], "a", 1, {stream: True}, "a"), "b", 2,
                                             {stream: True, send: False}, "b"), "c", 3, {stream: True}, "c")
        self.assertEqual(history.flaky(once, [send]), [])

    def test_a_break_that_holds_is_not_flaky(self):
        self.assertEqual(history.flaky(runs(True, True, False, False, keys="wwxx")), [])

    def test_a_timed_out_file_says_nothing_about_its_tests(self):
        # The timed-out run shares the red run's inputs but names no test: no green to set against the red.
        self.assertEqual(history.flaky(runs(True, None, False, keys="abb"), [TEST]), [])
        self.assertEqual(history.verdicts(runs(True, None, True), TEST), [("same", True), ("same", True)])

    def test_a_file_that_times_out_now_and_then_is_flaky_as_a_file(self):
        self.assertEqual(history.flaky(runs(True, None, True), [FILE]), [FILE])
        # A run that failed with named tests did not time out: the file-level verdict is green there.
        self.assertEqual([ok for _, ok in history.verdicts(runs(False, None, False), FILE)], [True, False, True])

    def test_runs_without_the_file_are_skipped(self):
        self.assertEqual(history.flaky(runs(True, "-", False)), [TEST])

    def test_only_the_names_asked_about(self):
        self.assertEqual(history.flaky(runs(True, False, True), ["test/other.test.ts > x"]), [])


class Known(unittest.TestCase):
    """react-apps-base-check reads a head red's base verdict from a push with the merge parent's inputs."""

    def test_a_red_green_on_every_push_with_the_same_inputs_is_the_changes(self):
        base, replay = history.known(runs(True, True), "same", {TEST: False, f"{FILE} > other": True})
        self.assertEqual((base, replay), ({TEST: True}, []))

    def test_the_newest_such_push_decides(self):
        self.assertEqual(history.known(runs(True, False), "same", {TEST: False}), ({TEST: False}, []))
        # One old red at the key (a flake) does not excuse a change once a newer push ran it green.
        self.assertEqual(history.known(runs(False, True), "same", {TEST: False}), ({TEST: True}, []))

    def test_other_inputs_or_a_timed_out_file_say_nothing_and_the_file_replays(self):
        self.assertEqual(history.known(runs(True, keys=["older"]), "same", {TEST: False}), ({}, [FILE]))
        self.assertEqual(history.known(runs(None), "same", {TEST: False}), ({}, [FILE]))
        self.assertEqual(history.known([], "same", {TEST: False}), ({}, [FILE]))

    def test_a_file_red_without_names_reads_the_files_own_verdict(self):
        self.assertEqual(history.known(runs(True, True), "same", {FILE: False}), ({FILE: True}, []))
        self.assertEqual(history.known(runs(None), "same", {FILE: False}), ({FILE: False}, []))

    def test_one_green_push_is_one_sample_and_the_file_replays(self):
        # cmux#41254 (run 43006460063): one green base sample of a test that flaps called its red the change's. A green
        # takes two pushes at the key; a red is answered by one (it only excuses, and flaky() still names a flip).
        self.assertEqual(history.known(runs(True), "same", {TEST: False}), ({}, [FILE]))
        self.assertEqual(history.known(runs(True), "same", {FILE: False}), ({}, [FILE]))
        self.assertEqual(history.known(runs(True, keys=["older"]) + runs(True), "same", {TEST: False}), ({}, [FILE]))
        self.assertEqual(history.known(runs(False), "same", {TEST: False}), ({TEST: False}, []))

    def test_a_file_no_such_push_ran_replays_and_a_file_one_ran_answers_every_name(self):
        other = "test/other.test.ts"
        pushes = history.record([], "sha0", 1000, {FILE: True, other: True}, "same")
        pushes = history.record(pushes, "sha1", 1001, {FILE: True, other: True}, "same")
        head = {TEST: False, f"{other} > x": False, f"{FILE} > new test": False}
        base, replay = history.known(pushes, "same", head)
        # FILE's "new test" is answered too (its file ran green); a red name the push never ran keeps the file
        # whole only when its file did not run.
        self.assertEqual(replay, [])
        self.assertEqual(base, {TEST: True, f"{other} > x": True, f"{FILE} > new test": True})
        pushes = history.record([], "sha0", 1000, {FILE: True}, "same")
        pushes = history.record(pushes, "sha1", 1001, {FILE: True}, "same")
        base, replay = history.known(pushes, "same", head)
        self.assertEqual((base, replay), ({TEST: True, f"{FILE} > new test": True}, [other]))


class KnownReds(unittest.TestCase):
    """A head shard skips the alone retry of a file whose every first-run red its base's newest recorded push has red
    (run-webviews-tests.sh, CMUX_WEB_TEST_BASE_REDS)."""

    def test_a_name_red_on_the_newest_push_at_its_inputs_is_a_known_red(self):
        self.assertEqual(history.known_reds(runs(True, False), "same"), [TEST])
        # A newer green at the same inputs answers green, as known() would.
        self.assertEqual(history.known_reds(runs(False, True), "same"), [])
        # A timed-out file names itself, and says nothing about its tests.
        self.assertEqual(history.known_reds(runs(False, None), "same"), [FILE, TEST])
        self.assertEqual(history.known_reds(runs(False, True, keys=["same", "other"]), "same"), [TEST])

    def test_only_pushes_no_newer_than_the_base_count(self):
        pushes = runs(False, True, keys=["k", "k"])  # times 1000 and 1001
        self.assertEqual(history.known_reds(pushes, "k", before=1000), [TEST])
        self.assertEqual(history.known_reds(pushes, "k", before=1001), [])
        self.assertEqual(history.base_run(pushes, 1000.5)["sha"], "sha0")
        self.assertEqual(history.base_run(pushes, 5000)["sha"], "sha1")
        self.assertIsNone(history.base_run(pushes, 999))

    def test_a_file_skips_only_when_every_red_it_names_is_red_on_the_base(self):
        other = "test/other.test.ts"
        head = {TEST: False, f"{FILE} > green": True, f"{other} > a": False, f"{other} > b": False, "test/gone.test.ts": False}
        self.assertEqual(history.base_red_files({TEST, f"{other} > a", "test/gone.test.ts"}, head),
                         [FILE, "test/gone.test.ts"])
        self.assertEqual(history.base_red_files(set(), head), [])
        self.assertEqual(history.base_red_files({TEST}, {FILE: True}), [])

    def test_the_commands_write_and_read_the_base_reds_and_fail_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            saved = tmp / "history.json"
            saved.write_text(json.dumps({"runs": runs(True, False, keys=["k", "k"])}))
            out = tmp / "base-reds.json"
            done = subprocess.run([sys.executable, str(SCRIPT), "known-reds", str(saved), "--before", "1001", "--out", str(out)],
                                  capture_output=True, text=True, check=True)
            self.assertIn("1 names red on the base's push sha1", done.stdout)
            self.assertEqual(json.loads(out.read_text()), {"sha": "sha1", "inputs": "k", "red": [TEST]})
            head = tmp / "head.json"
            head.write_text(json.dumps({TEST: False, "test/new.test.ts > x": False}))
            done = subprocess.run([sys.executable, str(SCRIPT), "base-red-files", str(out), "--names", str(head)],
                                  capture_output=True, text=True, check=True)
            self.assertEqual(done.stdout, f"{FILE}\n")
            # No push at or before the base: no file at all.
            none = tmp / "none.json"
            subprocess.run([sys.executable, str(SCRIPT), "known-reds", str(saved), "--before", "1", "--out", str(none)],
                           capture_output=True, text=True, check=True)
            self.assertFalse(none.exists())
            for bad in ["{not json", json.dumps({"red": [TEST]}), json.dumps({"inputs": "k", "red": "x"}), ""]:
                (tmp / "bad.json").write_text(bad)
                done = subprocess.run([sys.executable, str(SCRIPT), "base-red-files", str(tmp / "bad.json"), "--names",
                                       str(head)], capture_output=True, text=True, check=True)
                self.assertEqual(done.stdout, "", bad)


class EarlyBase(unittest.TestCase):
    """react-apps-base-early runs the base's recorded red files on the merge parent while the head shards run, so
    react-apps-base-check need not replay them after: run 43384458711's base check replayed up to 10 such files a
    shard (12.8 min, one a 600 s timeout) after the head shards' 17.9 min, for a 30.8 min verdict."""

    SHA = "b" * 40

    def test_the_base_reds_split_longest_first_and_keep_to_the_affected_files_the_base_has(self):
        reds = ["test/hang.test.ts", "test/a.test.ts > x", "test/a.test.ts > y", "test/b.test.ts > x",
                "test/c.test.ts > x", "test/gone.test.ts > x"]
        durations = {"test/hang.test.ts": 600, "test/a.test.ts": 90, "test/b.test.ts": 80}
        split = [history.early_files(reds, i, 2, durations) for i in (1, 2)]
        # The 600 s file alone; the rest (c unknown: 60 s) on the other shard; every file once.
        self.assertEqual(split, [["test/hang.test.ts"], ["test/a.test.ts", "test/b.test.ts", "test/c.test.ts",
                                                          "test/gone.test.ts"]])
        self.assertEqual(sorted(sum((history.early_files(reds, i, 5, durations) for i in range(1, 6)), [])),
                         ["test/a.test.ts", "test/b.test.ts", "test/c.test.ts", "test/gone.test.ts", "test/hang.test.ts"])
        only = {"test/a.test.ts", "test/gone.test.ts", "test/hang.test.ts"}
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("test/a.test.ts", "test/hang.test.ts", "test/b.test.ts"):
                Path(tmp, name).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, name).write_text("", encoding="utf-8")
            self.assertEqual(history.early_files(reds, 1, 1, durations, only, Path(tmp)), ["test/a.test.ts", "test/hang.test.ts"])

    def early(self, files, results, sha=SHA):
        return {"sha": sha, "files": files, "results": results}

    def test_a_file_the_early_run_ran_on_this_base_takes_its_verdicts_red_or_green(self):
        other, hang = "test/other.test.ts", "test/hang.test.ts"
        early = [self.early([FILE, other], {TEST: False, f"{FILE} > green": True, f"{other} > x": True}),
                 self.early([hang], {hang: False})]
        known, left = history.early_known(early, self.SHA, [FILE, other, hang, "test/not-early.test.ts"], {"k": True})
        self.assertEqual(left, ["test/not-early.test.ts"])
        # The base's red stays red (it excuses only that name), and a base green charges the head's red to the change.
        self.assertEqual(known, {"k": True, TEST: False, f"{FILE} > green": True, f"{other} > x": True, hang: False})

    def test_anything_the_early_run_cannot_vouch_for_replays(self):
        replay = [FILE]
        for early in ([], [self.early([FILE], {TEST: False}, sha="c" * 40)],  # another merge parent
                      [self.early([FILE], {TEST: False}, sha="")],
                      [self.early([], {TEST: False})],  # a result for a file it was not given
                      [self.early([FILE], {})],  # given, never reached
                      [self.early([FILE], {"test/x.test.ts > y": False})],
                      [{"sha": self.SHA, "files": "x", "results": {TEST: False}}], ["junk"]):
            self.assertEqual(history.early_known(early, self.SHA, replay, {}), ({}, [FILE]), early)
        self.assertEqual(history.early_known([self.early([FILE], {TEST: False})], "short", replay, {}), ({}, [FILE]))

    def test_the_commands_pick_a_shard_and_fold_its_results_in_and_fail_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            reds = tmp / "base-reds.json"
            reds.write_text(json.dumps({"sha": "s", "inputs": "k", "red": [TEST, "test/hang.test.ts"]}))
            manifest = tmp / "manifest.json"
            manifest.write_text(json.dumps({"test/hang.test.ts": 600, FILE: 30, "bad": "x"}))

            def pick(shard, *extra, path=reds):
                return subprocess.run([sys.executable, str(SCRIPT), "early-files", str(path), "--shard", str(shard),
                                       "--shard-count", "2", "--durations", str(manifest), *extra],
                                      capture_output=True, text=True, check=True).stdout

            self.assertEqual((pick(1), pick(2)), ("test/hang.test.ts\n", f"{FILE}\n"))
            (tmp / "affected").write_text(f"{FILE}\n")
            self.assertEqual(pick(1, "--only", str(tmp / "affected")), f"{FILE}\n")
            for bad in ["{not json", json.dumps({"red": [TEST]}), ""]:
                (tmp / "bad.json").write_text(bad)
                self.assertEqual(pick(1, path=tmp / "bad.json"), "", bad)
            self.assertEqual(pick(1, path=tmp / "missing.json"), "")
            early = tmp / "early"
            early.mkdir()
            (early / "early-1.json").write_text(json.dumps(self.early([FILE], {TEST: False})))
            (early / "early-2.json").write_text("{not json")
            replay, known = tmp / "replay", tmp / "known.json"
            replay.write_text(f"{FILE}\ntest/other.test.ts\n")
            known.write_text("{}")

            def fold(directory, sha=self.SHA):
                return subprocess.run([sys.executable, str(SCRIPT), "early-known", str(directory), "--sha", sha,
                                       "--replay", str(replay), "--known", str(known)], capture_output=True, text=True)

            done = fold(tmp / "missing")
            self.assertEqual((done.returncode, replay.read_text(), known.read_text()), (0, f"{FILE}\ntest/other.test.ts\n", "{}\n"))
            done = fold(early)
            self.assertIn("answers for 1 of 2 files", done.stdout)
            self.assertEqual((replay.read_text(), json.loads(known.read_text())), ("test/other.test.ts\n", {TEST: False}))


class FlakyOnly(unittest.TestCase):
    """A file whose head reds are all flaky on the base only warns, whatever its base replay says, so
    react-apps-base-check does not replay it: run 43442029204 replayed 4 such files for 5.1 min after its head shards."""

    def test_a_file_replays_unless_every_red_it_names_is_flaky(self):
        other, hang = "test/other.test.ts", "test/hang.test.ts"
        head = {TEST: False, f"{FILE} > green": True, f"{other} > x": False, f"{other} > y": False, hang: False,
                "test/green.test.ts > z": True}
        flaky = {TEST, f"{other} > x", hang}
        # other's y is not flaky and hang's whole-file red is; green has no red the head names, so it replays.
        self.assertEqual(history.flaky_only([FILE, other, hang, "test/green.test.ts"], flaky, head),
                         ([other, "test/green.test.ts"], [FILE, hang]))
        self.assertEqual(history.flaky_only([FILE], set(), head), ([FILE], []))
        self.assertEqual(history.flaky_only([FILE], {TEST}, {}), ([FILE], []))  # unread head results: it replays

    def test_the_command_drops_only_flaky_files_and_leaves_the_list_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            head, flaky, replay = tmp / "head.json", tmp / "flaky", tmp / "replay"
            head.write_text(json.dumps({TEST: False, "test/other.test.ts > x": False}))
            replay.write_text(f"{FILE}\ntest/other.test.ts\n")

            def run(path=flaky):
                return subprocess.run([sys.executable, str(SCRIPT), "flaky-only", str(path), "--replay", str(replay),
                                       "--names", str(head)], capture_output=True, text=True)

            done = run(tmp / "missing")
            self.assertNotEqual(done.returncode, 0)
            self.assertEqual(replay.read_text(), f"{FILE}\ntest/other.test.ts\n")
            flaky.write_text(f"{TEST}\n\n")
            done = run()
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("1 of 2 files to replay", done.stdout)
            self.assertEqual(replay.read_text(), "test/other.test.ts\n")


class OneBaseCheck(unittest.TestCase):
    """react-apps-base-check is one job for all head shards (it was one a head shard: in run 43409592440 11 of those 12
    took 0.3-0.9 min with the early base results). It joins the shards' artifacts and keeps each shard's re-run cap."""

    def shard(self, root, i, results, logs=None, runner=True):
        here = root / history.HEAD_ARTIFACT.format(i)
        here.mkdir(parents=True)
        (here / history.HEAD_RESULTS).write_text(results if isinstance(results, str) else json.dumps(results))
        if runner:
            (here / "runner").mkdir()
            (here / "runner/run-webviews-tests.sh").write_text(f"# shard {i}\n")
        if logs:
            (here / "raw-logs").mkdir()
            for name, text in logs.items():
                (here / "raw-logs" / name).write_text(text)

    def test_the_shards_join_into_one_results_map_runner_and_raw_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            self.shard(tmp / "in", 1, {TEST: False, "test/a.test.ts": True},
                       {"summary": "FAIL x /r/test_agent.log\n", "test_agent.log": "one"})
            self.shard(tmp / "in", 2, {"test/b.test.ts > y": False}, {"summary": "FAIL y /r/test_b.log\n", "test_b.log": "two"})
            self.assertIsNone(history.join_heads(tmp / "in", 2, tmp / "out"))
            self.assertEqual(json.loads((tmp / "out" / history.HEAD_RESULTS).read_text()),
                             {TEST: False, "test/a.test.ts": True, "test/b.test.ts > y": False})
            self.assertEqual(json.loads((tmp / "out/shards.json").read_text()),
                             {FILE: 1, "test/a.test.ts": 1, "test/b.test.ts": 2})
            self.assertEqual((tmp / "out/raw-logs/summary").read_text(), "FAIL x /r/test_agent.log\nFAIL y /r/test_b.log\n")
            self.assertEqual(((tmp / "out/raw-logs/test_agent.log").read_text(), (tmp / "out/raw-logs/test_b.log").read_text()),
                             ("one", "two"))
            self.assertEqual((tmp / "out/runner/run-webviews-tests.sh").read_text(), "# shard 1\n")

    def test_a_missing_shard_fails_and_an_unreadable_one_leaves_the_results_unreadable(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            self.shard(tmp / "in", 1, {TEST: False})
            self.assertIn("shard2", history.join_heads(tmp / "in", 2, tmp / "out"))
            done = subprocess.run([sys.executable, str(SCRIPT), "heads", str(tmp / "in"), "--count", "2", "--out",
                                   str(tmp / "out2")], capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)
            self.assertIn("::error", done.stdout)
            self.shard(tmp / "in", 2, "{not json")
            self.assertIsNone(history.join_heads(tmp / "in", 2, tmp / "out"))
            done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_test_results.py"), "--failed-files",
                                   str(tmp / "out" / history.HEAD_RESULTS)], capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0)  # read as one shard's unreadable results were: every red replays

    def test_the_rerun_cap_holds_per_head_shard(self):
        where = {f"test/s1-{i}.test.ts": 1 for i in range(25)} | {f"test/s2-{i}.test.ts": 2 for i in range(26)}
        one = [f"test/s1-{i}.test.ts" for i in range(25)]
        self.assertTrue(history.rerun_fits(one, where, 25))
        self.assertTrue(history.rerun_fits(one + [f"test/s2-{i}.test.ts" for i in range(25)], where, 25))
        self.assertFalse(history.rerun_fits([f"test/s2-{i}.test.ts" for i in range(26)], where, 25))
        self.assertFalse(history.rerun_fits([], where, 25))
        # No map: every file counts as one shard's.
        self.assertFalse(history.rerun_fits(one + ["test/x.test.ts"], {}, 25))
        with tempfile.TemporaryDirectory() as tmp:
            files = Path(tmp, "files")
            files.write_text("".join(f"{f}\n" for f in one))
            def fits(*shards):
                return subprocess.run([sys.executable, str(SCRIPT), "rerun-fits", str(files), "--shards",
                                       *shards, "--cap", "25"]).returncode
            Path(tmp, "shards.json").write_text(json.dumps(where))
            self.assertEqual(fits(str(Path(tmp, "shards.json"))), 0)
            self.assertEqual(fits(str(Path(tmp, "missing.json"))), 0)
            files.write_text("")
            self.assertEqual(fits(str(Path(tmp, "shards.json"))), 1)

    def test_the_one_job_joins_every_head_shard_before_it_reads_them(self):
        import yaml
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        check = jobs["react-apps-base-check"]
        self.assertNotIn("strategy", check)
        self.assertEqual(check["name"], "react-apps-base-check")
        steps = {s["name"]: s for s in check["steps"]}
        names = [s["name"] for s in check["steps"]]
        download = steps["Download head webview results"]["with"]
        self.assertEqual(download["pattern"], "react-apps-head-results-shard*")
        self.assertNotIn("merge-multiple", download)
        join = steps["Join the head shards' results"]
        self.assertEqual(int(join["env"]["HEAD_SHARDS"]), len(jobs["react-apps-check-shard"]["strategy"]["matrix"]["include"]))
        self.assertIn('--out "$RUNNER_TEMP/head-results"', join["run"])
        self.assertNotIn("continue-on-error", join)
        self.assertLess(names.index("Join the head shards' results"), names.index("Use the merge parent as the base"))
        compare = steps["Run base reds and compare"]["run"]
        self.assertIn("rerun-fits", compare)
        self.assertIn("--cap 25", compare)


class Inputs(unittest.TestCase):
    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              check=True, capture_output=True, text=True).stdout

    def test_the_key_follows_the_routers_webview_inputs_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.git(repo, "init", "-q")
            (repo / "webviews/test").mkdir(parents=True)
            (repo / "webviews/test/a.test.ts").write_text("1\n")
            (repo / "Sources").mkdir()
            (repo / "Sources/App.swift").write_text("1\n")
            self.git(repo, "add", "-A")
            self.git(repo, "commit", "-qm", "one")
            first = history.inputs(repo)
            (repo / "Sources/App.swift").write_text("2\n")  # a Swift-only push
            self.git(repo, "commit", "-qam", "swift")
            self.assertEqual(history.inputs(repo), first)
            (repo / "webviews/test/a.test.ts").write_text("2\n")
            self.git(repo, "commit", "-qam", "webviews")
            changed = history.inputs(repo)
            self.assertNotEqual(changed, first)
            (repo / "webviews/test/a.test.ts").write_text("1\n")  # the revert: its inputs are the first's again
            self.git(repo, "commit", "-qam", "revert")
            self.assertEqual(history.inputs(repo), first)
            (repo / "scripts/ci").mkdir(parents=True)
            (repo / "scripts/ci/run-webviews-tests.sh").write_text("runner\n")  # REACT_EXACT
            self.git(repo, "add", "-A")
            self.git(repo, "commit", "-qm", "runner")
            self.assertNotEqual(history.inputs(repo), first)

    def test_the_key_follows_the_web_bundles_routed_inputs_and_the_font_pin(self):
        # Webview tests import the settings schema; a base break through it must not read as green at an older
        # push's key (react-apps-base-check's known verdicts, #40223 review).
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.git(repo, "init", "-q")
            for path, text in (("webviews/test/a.test.ts", "1\n"), ("schemas/settings/settings-schema.json", "{}\n"),
                               ("scripts/ci/pin-browser-test-font.sh", "pin\n")):
                (repo / path).parent.mkdir(parents=True, exist_ok=True)
                (repo / path).write_text(text)
            self.git(repo, "add", "-A")
            self.git(repo, "commit", "-qm", "one")
            first = history.inputs(repo)
            (repo / "schemas/settings/settings-schema.json").write_text('{"a": 1}\n')
            self.git(repo, "commit", "-qam", "schema")
            second = history.inputs(repo)
            self.assertNotEqual(second, first)
            (repo / "scripts/ci/pin-browser-test-font.sh").write_text("pin 2\n")
            self.git(repo, "commit", "-qam", "font")
            self.assertNotEqual(history.inputs(repo), second)
            # From a subfolder (the push shards run from webviews/), the key is the top's.
            self.assertEqual(history.inputs(repo / "webviews"), history.inputs(repo))

    def test_a_tree_with_no_webview_inputs_has_no_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            self.git(repo, "init", "-q")
            (repo / "README").write_text("x\n")
            self.git(repo, "add", "-A")
            self.git(repo, "commit", "-qm", "one")
            with self.assertRaises(SystemExit):
                history.inputs(repo)


class Record(unittest.TestCase):
    def test_keeps_the_newest_runs_in_commit_order(self):
        found = []
        for i in (3, 1, 2):
            found = history.record(found, f"sha{i}", i, {FILE: True}, "k", keep=2)
        self.assertEqual([run["sha"] for run in found], ["sha2", "sha3"])

    def test_a_rerun_of_a_push_is_more_evidence_and_the_same_attempt_replaces_itself(self):
        found = history.record([], "sha", 1, {TEST: False}, "k")
        found = history.record(found, "sha", 1, {FILE: True}, "k", attempt=2)
        self.assertEqual(history.flaky(found), [TEST])
        found = history.record(found, "sha", 1, {FILE: True}, "k", attempt=2)
        self.assertEqual(len(found), 2)
        found = history.record([], "sha", 1, {TEST: False}, "k")
        found = history.record(found, "sha", 1, {FILE: True}, "k")
        self.assertEqual(found, [{"sha": "sha", "attempt": 1, "time": 1, "inputs": "k", "files": [FILE], "red": []}])

    def test_no_results_add_no_run(self):
        self.assertEqual(history.record([], "sha", 1, {}, "k"), [])

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
            # A run with no inputs key proves nothing.
            bad.write_text(json.dumps({"runs": [{"sha": "s", "time": 1, "files": [], "red": []}]}))
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
                                       "--sha", f"sha{i}", "--time", str(100 + i), "--inputs", "k", str(shard)],
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


def file_runs(*verdicts, file=FILE):
    """One push a verdict, oldest first, at an hour apart: True green, False a test red, None the file failed whole,
    "-" the file did not run (another file did)."""
    out = []
    for i, verdict in enumerate(verdicts):
        found = ({"test/other.test.ts": True} if verdict == "-" else {file: False} if verdict is None
                 else {f"{file} > sends the image": False, f"{file} > ok": True} if verdict is False else {file: True})
        out = history.record(out, f"{i:040x}", 1_800_000_000 + 3600 * i, found, "k")
    return out


class Stuck(unittest.TestCase):
    """cmuxterm-hq#10383: react-apps-check was red on every completed feat-cmux-next push run for about 40 hours
    (78 runs from 2026-11-11 16:59 UTC) and model-picker-scaling on 62 recorded pushes in a row, each excused on
    every pull request as a base red, until someone read a whole run's failures."""

    def test_a_file_red_on_the_last_n_pushes_is_named_with_its_first_red_and_last_green(self):
        found = history.stuck(file_runs(True, True, False, False, None, "-", False), streak=4)
        self.assertEqual([(f["file"], f["reds"]) for f in found], [(FILE, 4)])
        self.assertEqual(found[0]["first"]["sha"], f"{2:040x}")
        self.assertEqual(found[0]["green"]["sha"], f"{1:040x}")
        self.assertEqual(found[0]["tests"], [f"{FILE} > sends the image"])

    def test_a_red_shorter_than_n_or_one_that_went_green_is_not_stuck(self):
        self.assertEqual(history.stuck(file_runs(True, False, False, False), streak=4), [])
        self.assertEqual(history.stuck(file_runs(False, False, False, False, True), streak=4), [])
        # A flake: one green in the stretch ends it.
        self.assertEqual(history.stuck(file_runs(False, False, True, False, False), streak=4), [])
        self.assertEqual(history.stuck([], streak=1), [])

    def test_a_red_older_than_the_history_has_no_last_green(self):
        runs = file_runs(False, False, False)
        found = history.stuck(runs, streak=3)
        self.assertIsNone(found[0]["green"])
        notes, summary = history.stuck_report(found, runs, 3, "o/r")
        self.assertIn("no green in the 3 pushes recorded", notes[0])
        self.assertIn("none recorded", summary)

    def test_report_gives_one_error_a_range_with_its_commits_and_a_summary_row_a_file(self):
        a = file_runs(True, False, False, False)
        other = "test/b.test.ts"
        runs = []
        for i, run in enumerate(a):
            found = {name: name not in run["red"] for name in (f"{FILE} > sends the image", f"{FILE} > ok")}
            found[f"{other} > lays out"] = i == 0
            runs = history.record(runs, run["sha"], run["time"], found, "k")
        found = history.stuck(runs, streak=3)
        self.assertEqual([f["file"] for f in found], [FILE, other])
        notes, summary = history.stuck_report(found, runs, 3, "o/r")
        self.assertEqual(len(notes), 1)
        self.assertTrue(notes[0].startswith("::error title=Webview base red for 3 pushes::2 webview test file(s)"))
        self.assertIn(f"https://github.com/o/r/compare/{0:040x}...{1:040x}", notes[0])
        self.assertIn(f"Files: {FILE}, {other}", notes[0])
        self.assertEqual(summary.count("\n| `"), 2)
        self.assertIn("lays out", summary)

    def test_annotations_stop_at_the_step_limit(self):
        runs = []
        names = [f"test/f{i}.test.ts" for i in range(12)]
        for push in range(14):
            # File i goes red on push i and stays red: twelve first-red ranges.
            runs = history.record(runs, f"{push:040x}", 1_800_000_000 + push,
                                  {f"{n} > t": push < i for i, n in enumerate(names)}, "k")
        found = history.stuck(runs, streak=2)
        self.assertEqual(len(found), 12)
        notes, summary = history.stuck_report(found, runs, 2, "o/r")
        self.assertEqual(len(notes), history.STUCK_NOTES + 1)
        self.assertIn("3 more range(s)", notes[-1])
        self.assertEqual(summary.count("\n| `"), 12)

    def test_the_command_fails_writes_the_summary_and_passes_when_nothing_is_stuck(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved, summary = Path(tmp, "history.json"), Path(tmp, "summary.md")
            saved.write_text(json.dumps({"runs": file_runs(True, False, False)}))
            run = lambda *extra: subprocess.run([sys.executable, str(SCRIPT), "stuck", str(saved), "--runs", "2",
                                                 "--repo", "o/r", "--summary", str(summary), *extra],
                                                capture_output=True, text=True)
            done = run("--fail")
            self.assertEqual(done.returncode, 1, done.stderr)
            self.assertIn("::error title=Webview base red for 2 pushes::", done.stdout)
            self.assertIn(f"`{FILE}`", summary.read_text())
            self.assertEqual(run().returncode, 0)
            saved.write_text(json.dumps({"runs": file_runs(False, False, True)}))
            done = run("--fail")
            self.assertEqual(done.returncode, 0, done.stdout)
            self.assertNotIn("::error", done.stdout)
            missing = subprocess.run([sys.executable, str(SCRIPT), "stuck", str(Path(tmp, "none.json")), "--fail"],
                                     capture_output=True, text=True)
            self.assertEqual(missing.returncode, 0)


def artifact_zip(runs) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        archive.writestr(history.ARTIFACT_FILE, json.dumps({"runs": runs}))
    return out.getvalue()


def listed(*items):
    return json.dumps({"artifacts": list(items)}).encode()


def item(id, created, branch="feat-cmux-next", repo=1, head_repo=1, expired=False, name=history.ARTIFACT):
    return {"id": id, "name": name, "expired": expired, "created_at": created,
            "archive_download_url": f"https://api.example/artifacts/{id}/zip",
            "workflow_run": {"id": 100 + id, "head_branch": branch, "repository_id": repo,
                             "head_repository_id": head_repo, "head_sha": "abc" * 13}}


class Fetch(unittest.TestCase):
    def serve(self, listing, zips, redirect=True):
        calls = []

        def get(url, token):
            calls.append((url, token))
            if "/actions/artifacts?" in url:
                return 200, {}, listing
            for id, body in zips.items():
                if url == f"https://api.example/artifacts/{id}/zip":
                    return (302, {"Location": f"https://blob.example/{id}"}, b"") if redirect else (200, {}, body)
                if url == f"https://blob.example/{id}":
                    return 200, {}, body
            return 404, {}, b""
        return get, calls

    def test_the_newest_push_history_is_read_and_names_the_flakes(self):
        # 2026-11-08: the cache never held more than one run; the artifact carries the whole history to the replay.
        flaky_runs = runs(True, False, True, False)
        get, calls = self.serve(listed(item(1, "2026-11-08T10:00:00Z", ), item(2, "2026-11-08T11:00:00Z")),
                                {1: artifact_zip([]), 2: artifact_zip(flaky_runs)})
        found, said, read = history.fetch("manaflow-ai/cmux", "feat-cmux-next", "tok", get=get)
        self.assertEqual(found, flaky_runs)
        self.assertTrue(read)
        self.assertIn("from run 102", said)
        self.assertEqual(history.flaky(found, [TEST]), [TEST])
        # Two requests and the storage redirect, the token never sent to the storage host.
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][1], "tok")
        self.assertEqual(calls[2], ("https://blob.example/2", None))

    def test_other_branches_forks_and_expired_uploads_are_never_read(self):
        bad = [item(1, "2026-11-08T12:00:00Z", branch="other"), item(2, "2026-11-08T12:00:00Z", head_repo=9),
               item(3, "2026-11-08T12:00:00Z", expired=True), item(4, "2026-11-08T12:00:00Z", name="x")]
        get, calls = self.serve(listed(*bad), {})
        self.assertEqual(history.fetch("o/r", "feat-cmux-next", None, get=get)[::2], ([], True))  # none yet: read
        self.assertEqual(len(calls), 1)
        self.assertEqual(history.newest(json.loads(listed(*bad, item(5, "2026-11-01T00:00:00Z"))), "feat-cmux-next")["id"], 5)

    def test_any_failure_is_an_empty_history_that_says_why(self):
        def refused(url, token):
            return 403, {}, b""
        self.assertEqual(history.fetch("o/r", "feat-cmux-next", None, get=refused),
                         ([], "listing the webviews-test-history artifacts answered 403", False))
        get, _ = self.serve(listed(item(1, "2026-11-08T10:00:00Z")), {1: b"not a zip"})
        self.assertEqual(history.fetch("o/r", "feat-cmux-next", None, get=get)[::2], ([], False))
        get, _ = self.serve(listed(item(1, "2026-11-08T10:00:00Z")), {1: artifact_zip("nope")})
        self.assertEqual(history.fetch("o/r", "feat-cmux-next", None, get=get)[::2], ([], False))

    def test_the_command_always_writes_a_history_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "h" / "history.json"
            done = subprocess.run([sys.executable, str(SCRIPT), "fetch", str(out), "--repo", "o/r", "--branch", "b"],
                                  capture_output=True, text=True, env=git_fixture_env.fixture_env({"PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin",
                                                                      "GITHUB_API_URL": "http://127.0.0.1:9"}))
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(out.read_text()), {"runs": []})
            self.assertIn("0 push runs", done.stdout)

    def test_a_push_that_cannot_read_the_history_never_saves_one_over_it(self):
        # A push saves what it read plus its own run: one failed read would replace the whole history with one run.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "history.json"
            done = subprocess.run([sys.executable, str(SCRIPT), "fetch", str(out), "--repo", "o/r", "--branch", "b",
                                   "--need-read"], capture_output=True, text=True,
                                  env=git_fixture_env.fixture_env({"PATH": "/usr/bin:/bin", "GITHUB_API_URL": "http://127.0.0.1:9"}))
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        upkeep = Workflow().job("webviews-test-history")
        restore = upkeep[upkeep.index("      - name: Restore the history"):]
        restore = restore[:restore.index("\n      - name:", 10)]
        self.assertIn("id: history-restore", restore)
        self.assertIn("--need-read", restore)
        record = upkeep[upkeep.index("      - name: Add this push to the history"):]
        self.assertIn("steps.history-restore.outcome == 'success'", record[:record.index("run: |")])


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
        self.assertIn('webviews_test_history.py fetch "$RUNNER_TEMP/webviews-test-history/history.json"', upkeep)
        self.assertIn('--branch "$BRANCH"', upkeep)
        self.assertIn("name: webviews-test-history\n", upkeep)
        self.assertIn("timeout-minutes: 5", upkeep)
        # The cache the history used to live in was never restored by the next push (2026-11-08).
        self.assertNotIn("actions/cache", upkeep)
        # Optional upkeep: every step keeps going, so a stalled download or save never reddens a push. Only the last
        # step, which names reds stuck on the base, may turn the job red, and it runs after the history is saved.
        steps = upkeep.split("\n      - name: ")[1:]
        self.assertTrue(steps)
        self.assertTrue(steps[-1].startswith("Name webview reds stuck on the base"), steps[-1])
        for step in steps[:-1]:
            self.assertIn("continue-on-error: true", step, step)
        self.assertNotIn("continue-on-error", steps[-1])
        self.assertIn("if: ${{ steps.history-record.outcome == 'success' }}", steps[-1])
        self.assertIn('webviews_test_history.py stuck "$RUNNER_TEMP/webviews-test-history/history.json"', steps[-1])
        self.assertIn('--summary "$GITHUB_STEP_SUMMARY" --fail', steps[-1])
        shard = self.job("react-apps-check-shard")
        upload = shard[shard.index("      - name: Upload this push's webview results"):]
        upload = upload[:upload.index("\n      - name:", 10)]
        self.assertIn("github.event_name == 'push'", upload)
        self.assertIn("continue-on-error: true", upload)
        self.assertIn("name: webviews-test-history-shard${{ matrix.shard }}", upload)
        gate = shard[shard.index("      - name: Fail on the gate checks"):]
        self.assertIn("HISTORY_UPLOAD: ${{ steps.history-upload.outcome }}", gate)
        self.assertNotIn('"HISTORY_UPLOAD|', gate)  # read as a warning, never one of the failing gates
        base = self.job("react-apps-base-check")
        restore = base[base.index("      - name: Restore the base's webview test history"):]
        restore = restore[:restore.index("\n      - name:", 10)]
        self.assertIn('webviews_test_history.py" fetch', restore)
        self.assertIn('--branch "$BASE_REF"', restore)
        self.assertIn("continue-on-error: true", restore)
        self.assertNotIn("upload-artifact", base.split("Restore the base's webview test history")[1].split("Fail on the change")[0])
        self.assertNotIn("actions/cache/save", base)  # a pull request never writes the base's history
        self.assertIn('webviews_test_history.py" flaky', base)

    def test_the_web_bisect_reads_the_history_artifact(self):
        # The cache it restored is no longer saved (#38716): it read nothing, and known flakes stayed bisectable.
        text = (ROOT / ".github/workflows/cmux-next-web.yml").read_text(encoding="utf-8")
        start = text.index("\n  web-bisect:\n") + 1
        end = re.search(r"\n  [a-z][a-z0-9-]*:\n", text[start + 1:])
        job = text[start:start + 1 + end.start()] if end else text[start:]
        restore = job[job.index("      - name: Restore the base's webview test history"):]
        restore = restore[:restore.index("\n      - name:", 10)]
        self.assertIn('webviews_test_history.py fetch "$RUNNER_TEMP/webviews-test-history/history.json"', restore)
        self.assertIn('--branch "$BRANCH"', restore)
        self.assertIn("continue-on-error: true", restore)
        self.assertNotIn("webviews-test-history-${{", job)
        block = job[job.index("    permissions:\n"):].split("\n    ", 3)
        self.assertEqual(block[1:3], ["  contents: read", "  actions: read"])

    def test_only_the_history_jobs_ask_for_actions_read(self):
        # The history is an artifact: listing and downloading it takes actions: read, nothing more.
        for name in ("webviews-test-history", "react-apps-base-check"):
            job = self.job(name)
            block = job[job.index("    permissions:\n"):].split("\n    ", 3)
            self.assertEqual(block[1:3], ["  contents: read", "  actions: read"], name)
        self.assertNotIn("permissions:", self.job("react-apps-check-shard"))

    def test_the_replay_fetches_the_history_unless_the_head_results_say_no_reds(self):
        # Head results it cannot read are unknown, not "no reds": skipping the fetch then left the flaky list empty.
        base = self.job("react-apps-base-check")
        step = base[base.index("      - name: Restore the base's webview test history"):]
        step = step[:step.index("\n      - name:", 10)]
        body = step[step.index("        run: |\n") + len("        run: |\n"):].splitlines()
        script = "\n".join(line[10:] for line in itertools.takewhile(lambda line: line.startswith(" " * 10), body))

        def fetched(results):
            with tempfile.TemporaryDirectory() as temp:
                runner = Path(temp, "head-results/runner")
                runner.mkdir(parents=True)
                (runner / "webviews_test_results.py").write_text(
                    (ROOT / "scripts/ci/webviews_test_results.py").read_text(encoding="utf-8"), encoding="utf-8")
                (runner / "webviews_test_history.py").write_text(
                    "import pathlib, sys\npathlib.Path(sys.argv[0]).with_name('fetched').touch()\n", encoding="utf-8")
                head = Path(temp, "head-results/webviews-head-results.json")
                if results is not None:
                    head.write_text(results, encoding="utf-8")
                subprocess.run(["bash", "-c", script], check=True, capture_output=True, env=git_fixture_env.fixture_env({
                    "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "RUNNER_TEMP": temp, "HEAD_RESULTS": str(head),
                    "GITHUB_REPOSITORY": "manaflow-ai/cmux", "BASE_REF": "feat-cmux-next"}))
                return (runner / "fetched").exists()

        self.assertFalse(fetched(json.dumps({f"{FILE} > a": True})))
        self.assertTrue(fetched(json.dumps({f"{FILE} > a": False})))
        self.assertTrue(fetched(None))  # missing
        self.assertTrue(fetched("{not json"))  # unreadable

    def test_the_replay_takes_the_bases_verdicts_from_a_push_with_its_inputs(self):
        base = self.job("react-apps-base-check")
        step = base[base.index("      - name: Restore the base's webview test history"):]
        step = step[:step.index("\n      - name:", 10)]
        body = step[step.index("        run: |\n") + len("        run: |\n"):].splitlines()
        script = "\n".join(line[10:] for line in itertools.takewhile(lambda line: line.startswith(" " * 10), body))
        other = "test/other.test.ts"
        with tempfile.TemporaryDirectory() as temp:
            runner = Path(temp, "head-results/runner")
            runner.mkdir(parents=True)
            (runner / "webviews_test_results.py").write_text(
                (ROOT / "scripts/ci/webviews_test_results.py").read_text(encoding="utf-8"), encoding="utf-8")
            (runner / "real_history.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
            pushes = history.record([], "sha0", 1000, {FILE: True}, "same")
            pushes = history.record(pushes, "sha1", 1001, {FILE: True}, "same")  # a green takes two samples
            # fetch writes this history; every other command is the real script's.
            (runner / "webviews_test_history.py").write_text(
                "import json, pathlib, runpy, sys\n"
                "if sys.argv[1] == 'fetch':\n"
                f"    pathlib.Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)\n"
                f"    pathlib.Path(sys.argv[2]).write_text(json.dumps({{'runs': {json.dumps(pushes)}}}))\n"
                "    sys.exit(0)\n"
                "sys.argv[0] = str(pathlib.Path(__file__).with_name('real_history.py'))\n"
                "runpy.run_path(sys.argv[0], run_name='__main__')\n", encoding="utf-8")
            # The merge parent's own copy prints its inputs key.
            Path(temp, "scripts/ci").mkdir(parents=True)
            Path(temp, "scripts/ci/webviews_test_history.py").write_text("print('same')\n", encoding="utf-8")
            head = Path(temp, "head-results/webviews-head-results.json")
            head.write_text(json.dumps({TEST: False, f"{other} > x": False}), encoding="utf-8")
            output = Path(temp, "output")
            subprocess.run(["bash", "-e", "-c", script], check=True, capture_output=True, cwd=temp, env=git_fixture_env.fixture_env({
                "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "RUNNER_TEMP": temp, "HEAD_RESULTS": str(head),
                "GITHUB_REPOSITORY": "manaflow-ai/cmux", "BASE_REF": "feat-cmux-next", "GITHUB_OUTPUT": str(output)}))
            self.assertEqual(output.read_text(encoding="utf-8"), "replay=1\n")
            self.assertEqual(Path(temp, "base-replay-files").read_text(encoding="utf-8"), f"{other}\n")
            self.assertEqual(json.loads(Path(temp, "base-known.json").read_text(encoding="utf-8")), {TEST: True})

    def test_the_replay_takes_the_early_base_runs_verdicts_and_replays_only_the_rest(self):
        """Run 43384458711: the base check replayed after the head shards what the base's push already had red, at
        its 17.9 min, to 30.8. With react-apps-base-early's results for this merge parent, those files need no
        replay; a red the early run did not reach still replays."""
        base = self.job("react-apps-base-check")
        step = base[base.index("      - name: Restore the base's webview test history"):]
        step = step[:step.index("\n      - name:", 10)]
        body = step[step.index("        run: |\n") + len("        run: |\n"):].splitlines()
        script = "\n".join(line[10:] for line in itertools.takewhile(lambda line: line.startswith(" " * 10), body))
        other, late = "test/other.test.ts", "test/late.test.ts"
        with tempfile.TemporaryDirectory() as temp:
            runner = Path(temp, "head-results/runner")
            runner.mkdir(parents=True)
            (runner / "webviews_test_results.py").write_text(
                (ROOT / "scripts/ci/webviews_test_results.py").read_text(encoding="utf-8"), encoding="utf-8")
            (runner / "real_history.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
            # The history holds no push at the merge parent's inputs: alone, it answers for nothing.
            (runner / "webviews_test_history.py").write_text(
                "import json, pathlib, runpy, sys\n"
                "if sys.argv[1] == 'fetch':\n"
                "    pathlib.Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)\n"
                "    pathlib.Path(sys.argv[2]).write_text(json.dumps({'runs': []}))\n"
                "    sys.exit(0)\n"
                "sys.argv[0] = str(pathlib.Path(__file__).with_name('real_history.py'))\n"
                "runpy.run_path(sys.argv[0], run_name='__main__')\n", encoding="utf-8")
            Path(temp, "scripts/ci").mkdir(parents=True)
            Path(temp, "scripts/ci/webviews_test_history.py").write_text("print('new-key')\n", encoding="utf-8")
            env = git_fixture_env.fixture_env({"PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin"})
            subprocess.run(["git", "init", "-q"], cwd=temp, check=True, env=env)
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"],
                           cwd=temp, check=True, env=env)
            sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=temp, check=True, capture_output=True, text=True,
                                 env=env).stdout.strip()
            Path(temp, "base-early").mkdir()
            Path(temp, "base-early/early-3.json").write_text(json.dumps({
                "sha": sha, "files": [FILE, other], "results": {TEST: False, f"{other} > x": True}}), encoding="utf-8")
            head = Path(temp, "head-results/webviews-head-results.json")
            head.write_text(json.dumps({TEST: False, f"{other} > x": False, f"{late} > y": False}), encoding="utf-8")
            output = Path(temp, "output")
            subprocess.run(["bash", "-e", "-c", script], check=True, capture_output=True, cwd=temp, env={**env,
                "RUNNER_TEMP": temp, "HEAD_RESULTS": str(head), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                "BASE_REF": "feat-cmux-next", "GITHUB_OUTPUT": str(output)})
            self.assertEqual(output.read_text(encoding="utf-8"), "replay=1\n")
            self.assertEqual(Path(temp, "base-replay-files").read_text(encoding="utf-8"), f"{late}\n")
            # The base's red excuses its name; the base's green leaves other's red the change's.
            self.assertEqual(json.loads(Path(temp, "base-known.json").read_text(encoding="utf-8")),
                             {TEST: False, f"{other} > x": True})
            # Early results from another merge parent answer for nothing.
            Path(temp, "base-early/early-3.json").write_text(json.dumps({
                "sha": "c" * 40, "files": [FILE, other], "results": {TEST: False, f"{other} > x": True}}), encoding="utf-8")
            subprocess.run(["bash", "-e", "-c", script], check=True, capture_output=True, cwd=temp, env={**env,
                "RUNNER_TEMP": temp, "HEAD_RESULTS": str(head), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                "BASE_REF": "feat-cmux-next", "GITHUB_OUTPUT": str(output)})
            self.assertEqual(output.read_text(encoding="utf-8"), "replay=1\nreplay=3\n")
            self.assertEqual(json.loads(Path(temp, "base-known.json").read_text(encoding="utf-8")), {})

    def test_the_early_base_job_runs_the_replay_its_way_and_never_blocks_the_check(self):
        import yaml
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        early, check = jobs["react-apps-base-early"], jobs["react-apps-base-check"]
        self.assertEqual(early["needs"], "web-subarea-scope")  # alongside the head shards, not after them
        self.assertIn("react-apps-base-early", check["needs"])
        self.assertIn("react-apps-check-shard", check["needs"])
        self.assertIs(early["continue-on-error"], True)
        self.assertEqual(early["if"], check["if"])
        sys.path.insert(0, str(ROOT / "tests"))
        import workflow_jobs  # noqa: PLC0415
        self.assertEqual(workflow_jobs.runs_on(early), workflow_jobs.runs_on(check))
        self.assertLess(early["timeout-minutes"], jobs["react-apps-check-shard"]["timeout-minutes"])
        # 2 shards (run 43409592440's 12 ran 54 files one at a time; shard 1's 600 s timeout alone ended at 15.0 min),
        # each running its files at the head shards' widths, so the slowest file still ends before the head shards.
        include = early["strategy"]["matrix"]["include"]
        self.assertEqual(include, [{"shard": 1, "shard_count": 2}, {"shard": 2, "shard_count": 2}])
        steps = {s["name"]: s for s in early["steps"]}
        replay = next(s for s in check["steps"] if s["name"] == "Run base reds and compare")
        head = next(s for s in jobs["react-apps-check-shard"]["steps"] if s["name"] == "Test webviews")
        run = steps["Run the base reds"]
        for key in ("CMUX_NEXT_STYLE_GUARDS", "CMUX_WEB_TEST_RETRIES"):
            self.assertEqual(run["env"][key], replay["env"][key], key)
        for key in ("CMUX_WEB_TEST_JOBS", "CMUX_WEB_TEST_DEV_JOBS"):
            self.assertEqual(run["env"][key], head["env"][key], key)
        self.assertEqual(steps["Pick this shard's base reds"]["env"]["SHARD_COUNT"], "${{ matrix.shard_count }}")
        self.assertIn('--shard-count "$SHARD_COUNT"', steps["Pick this shard's base reds"]["run"])
        self.assertIn('env -u CMUX_WEB_TEST_SHARD -u CMUX_WEB_TEST_SHARD_COUNT -u CMUX_PR_CHANGED_FILES', run["run"])
        self.assertIn('bash "$early/runner/run-webviews-tests.sh"', run["run"])
        pick = steps["Pick this shard's base reds"]["run"]
        # The head's runner, then the merge parent, as the base check does.
        self.assertLess(pick.index("cp scripts/ci/run-webviews-tests.sh"), pick.index("git checkout -q --detach HEAD^1"))
        self.assertLess(pick.index("webviews_affected.py --base HEAD^1 --head HEAD"), pick.index("git checkout -q --detach HEAD^1"))
        self.assertIn("early-files", pick)
        self.assertEqual(steps["Upload the early base results"]["with"]["name"], "react-apps-base-early-shard${{ matrix.shard }}")
        download = next(s for s in check["steps"] if s["name"] == "Download the early base results")
        self.assertEqual(download["with"]["pattern"], "react-apps-base-early-shard*")
        self.assertIs(download["continue-on-error"], True)
        names = [s["name"] for s in check["steps"]]
        self.assertLess(names.index("Download the early base results"), names.index("Restore the base's webview test history"))
        # Every early shard waits on the install only when it has files to run.
        for name in ("Setup Bun", "Install webview dependencies", "Build base web bundles", "Install headless engines",
                     "Run the base reds", "Upload the early base results"):
            self.assertEqual(steps[name]["if"], "${{ steps.pick.outputs.files != '0' }}", name)

    def step_script(self, name):
        base = self.job("react-apps-base-check")
        step = base[base.index(f"      - name: {name}\n"):]
        step = step[:step.index("\n      - name:", 10)] if "\n      - name:" in step[10:] else step
        body = step[step.index("        run: |\n") + len("        run: |\n"):].splitlines()
        return "\n".join(line[10:] for line in itertools.takewhile(
            lambda line: line.startswith(" " * 10) or not line.strip(), body))

    def compare_env(self):
        import yaml
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["react-apps-base-check"]["steps"]
        return {k: str(v) for k, v in next(s for s in steps if s["name"] == "Run base reds and compare")["env"].items()}

    def replay(self, head, results, rerun=None, elapsed=0, source="test\n"):
        """Run the compare step (and the head re-run step when it asks for one) with a stub test runner whose Nth call
        writes RESULTS[N-1] ({} past the end), ELAPSED seconds into the job. Returns (compare exit, compare output,
        rerun output, calls' files)."""
        red = "test/agent-pane-stream-row-overlap.test.ts"
        budget = {k: v for k, v in self.compare_env().items() if k in ("JOB_TIMEOUT_MINUTES", "REPLAY_RESERVE")}
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp, "repo")
            git_fixture_env.init_repo(repo)
            Path(repo, "webviews/test").mkdir(parents=True)
            Path(repo, f"webviews/{red}").write_text(source, encoding="utf-8")
            env = git_fixture_env.fixture_env({
                "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "RUNNER_TEMP": temp,
                "HEAD_RESULTS": str(Path(temp, "head.json")), "BASE_RESULTS": str(Path(temp, "base-results.json")),
                "HEAD_RERUN": str(Path(temp, "head-rerun.json")), "KNOWN_REPLAY": "1",
                "GITHUB_OUTPUT": str(Path(temp, "output")), **budget})
            Path(temp, "job-started").write_text(f"{int(time.time()) - elapsed}\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
                           check=True, env=env)
            Path(temp, "head.json").write_text(json.dumps(head), encoding="utf-8")
            Path(temp, "base-replay-files").write_text(f"{red}\n", encoding="utf-8")
            Path(temp, "base-known.json").write_text("{}\n", encoding="utf-8")
            runner = Path(temp, "head-results/runner")
            runner.mkdir(parents=True)
            (runner / "guards_new_reds.py").write_text(
                (ROOT / "scripts/ci/guards_new_reds.py").read_text(encoding="utf-8"), encoding="utf-8")
            (runner / "webviews_test_history.py").write_text("", encoding="utf-8")  # no flakes on record
            (runner / "test_reds.py").write_text("", encoding="utf-8")
            for i, found in enumerate(results, 1):
                (runner / f"result-{i}.json").write_text(json.dumps(found), encoding="utf-8")
            (runner / "run-webviews-tests.sh").write_text(
                'here="$(dirname "$0")"; n=$(( $(cat "$here/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$here/calls"\n'
                'printf "%s\\n" "$CMUX_WEB_TEST_FILES" > "$here/files-$n"\n'
                'cp "$here/result-$n.json" "$CMUX_WEB_TEST_RESULTS" 2>/dev/null || echo "{}" > "$CMUX_WEB_TEST_RESULTS"\n',
                encoding="utf-8")
            compare = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", self.step_script("Run base reds and compare")],
                                     cwd=repo / "webviews", capture_output=True, text=True, env=env)
            again = ""
            if Path(temp, "output").exists() and "rerun=true" in Path(temp, "output").read_text(encoding="utf-8"):
                again = subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", self.step_script("Re-run the change's reds alone on the head")],
                    cwd=repo / "webviews", capture_output=True, text=True, env=env).stdout
            calls = int((runner / "calls").read_text()) if (runner / "calls").exists() else 0
            files = [(runner / f"files-{n}").read_text(encoding="utf-8").split() for n in range(1, calls + 1)]
            return compare.returncode, compare.stdout + compare.stderr, again, files

    def test_a_red_the_base_passes_once_replays_there_again_before_it_is_the_changes(self):
        # cmux#41254 (run 43006460063): attempt 2's one base replay passed the webkit overlap test the head failed
        # twice, and the verdict called it the change's; attempt 3's base replay failed it. A second replay on the
        # base settles it as flaky there.
        red = "test/agent-pane-stream-row-overlap.test.ts > webkit: followed, no lag"
        file = red.split(" > ")[0]
        status, out, _, files = self.replay({red: False}, [{red: True}, {red: False}])
        self.assertEqual(status, 0, out)
        self.assertIn(f"webview test red step (flaky): {red}", out)
        self.assertEqual(files, [[file], [file]])  # stops once the base failed it
        # A real break: the base passes every bounded replay (three in all) and the head fails it again alone.
        status, out, again, files = self.replay({red: False}, [{red: True}, {red: True}, {red: True}, {red: False}])
        self.assertEqual(status, 1, out)
        self.assertIn(f"::error title=Webview test red on this change::{red}", out)
        self.assertEqual(files, [[file], [file], [file], [file]])  # three base replays, then the head re-run
        self.assertIn(f"::error title=Webview test red on this change::{red}", again)
        # A red the first replay already fails on the base replays no more.
        status, out, _, files = self.replay({red: False}, [{red: False}])
        self.assertEqual((status, files), (0, [[file]]), out)

    def test_a_new_test_file_red_on_the_head_reaches_the_verdict_and_never_replays_on_the_base(self):
        # #41414 review BLOCK: a red in a file the base does not have (a new test file) has no base result, so it is a
        # new red and the replay loop listed its file; reading that missing file's declared limit failed under
        # -e -o pipefail and ended the step with no verdict and no head re-run. It stays the change's, unreplayed,
        # and the other file's reds still replay.
        red = "test/agent-pane-stream-row-overlap.test.ts > webkit: followed, no lag"
        file = red.split(" > ")[0]
        new = "test/only-on-the-head.test.ts > draws"
        status, out, _, files = self.replay({red: False, new: False}, [{red: True}, {red: False}])
        self.assertEqual(status, 1, out)
        self.assertIn(f"not on the base, the change's own, not replayed: {new.split(' > ')[0]}", out)
        self.assertIn(f"::error title=Webview test red on this change::{new}", out)
        self.assertIn(f"webview test red step (flaky): {red}", out)
        self.assertEqual(files[:2], [[file], [file]])  # the first replay and one more, neither with the new file

    def test_the_base_replays_fit_the_job_timeout(self):
        # #41414 review F1: three base replays of a 900 s file plus the head re-run is 60 minutes, past the job's 55,
        # and a job cut at its timeout gives the required check no verdict. The replays after the first share one
        # budget, what is left of timeout-minutes less REPLAY_RESERVE for the head re-run and the verdict; this sums
        # that worst case against timeout-minutes, as cmuxterm-hq#9496's test_skills_workflow_budget does.
        import yaml
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["react-apps-base-check"]
        env = self.compare_env()
        timeout = int(job["timeout-minutes"]) * 60
        self.assertEqual(int(env["JOB_TIMEOUT_MINUTES"]) * 60, timeout, "the budget must read this job's timeout-minutes")
        runner = (ROOT / "scripts/ci/run-webviews-tests.sh").read_text(encoding="utf-8")
        ceiling = int(re.search(r'maximum="\$\{CMUX_WEB_TEST_MAX_FILE_TIMEOUT:-(\d+)\}"', runner).group(1))
        # The head re-run: its checkout, bun, install, bundles and browsers (3 to 11 min a shard), one file at the
        # runner's ceiling, the verdict, and the checkout before the job's clock starts.
        head_rerun = 11 * 60 + ceiling + 60 + 60
        self.assertGreaterEqual(int(env["REPLAY_RESERVE"]), head_rerun)
        # Before the replays: the base's setup (11 min) and the first replay of one file at the ceiling. The replays
        # after it get only what is left, so the sum stays inside timeout-minutes; the first replay itself must fit.
        before = 11 * 60 + ceiling
        self.assertLess(before + int(env["REPLAY_RESERVE"]), timeout)
        compare = self.step_script("Run base reds and compare")
        self.assertIn('"$RUNNER_TEMP/job-started"', compare)
        self.assertIn("JOB_TIMEOUT_MINUTES * 60", compare)
        self.assertIn("REPLAY_RESERVE", compare)
        self.assertIn('date +%s > "$RUNNER_TEMP/job-started"', self.step_script("Use the merge parent as the base"))

    def test_a_replay_the_budget_cannot_fit_is_not_run_and_its_reds_stay_the_changes(self):
        red = "test/agent-pane-stream-row-overlap.test.ts > webkit: followed, no lag"
        file = red.split(" > ")[0]
        timeout = int(self.compare_env()["JOB_TIMEOUT_MINUTES"]) * 60
        reserve = int(self.compare_env()["REPLAY_RESERVE"])
        # No time left after the first replay: no second one, and the red is the change's, not replayed (never excused).
        status, out, _, files = self.replay({red: False}, [{red: True}, {red: False}], elapsed=timeout - reserve)
        self.assertEqual(status, 1, out)
        self.assertEqual(files[0], [file])
        self.assertNotIn("replaying on the base again", out)
        self.assertIn("not replayed", out)
        self.assertIn(f"::error title=Webview test red on this change::{red}", out)
        # 600 s left fits a file at the default 120 s limit, not one that declares 900 s.
        status, out, _, files = self.replay({red: False}, [{red: True}, {red: False}], elapsed=timeout - reserve - 600)
        self.assertEqual((status, files), (0, [[file], [file]]), out)
        status, out, _, files = self.replay({red: False}, [{red: True}, {red: False}], elapsed=timeout - reserve - 600,
                                            source="// cmux-web-test-timeout: 900\ntest\n")
        self.assertEqual(status, 1, out)
        self.assertIn("not replayed", out)
        # A job long past its budget replays nothing more.
        status, out, _, files = self.replay({red: False}, [{red: True}, {red: False}], elapsed=10**6)
        self.assertEqual(status, 1, out)
        self.assertNotIn("replaying on the base again", out)

    def test_the_head_rerun_keeps_a_base_replay_flake_flaky(self):
        # The re-run's verdict line is the replay's final one (base_red_excuse reads it): a name another base replay
        # failed stays flaky there while a different red is the change's.
        flake = "test/agent-pane-stream-row-overlap.test.ts > webkit: followed, no lag"
        broken = "test/agent-pane-stream-row-overlap.test.ts > chromium: followed"
        status, out, again, _ = self.replay({flake: False, broken: False},
                                            [{flake: True, broken: True}, {flake: False, broken: True},
                                             {flake: True, broken: True}, {flake: False, broken: False}])
        self.assertEqual(status, 1, out)
        self.assertIn(f"webview test red step (flaky): {flake}", again)
        self.assertIn(f"webview test red step (new): {broken}", again)

    def test_only_the_install_build_and_browsers_wait_on_the_replay(self):
        import yaml
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["react-apps-base-check"]["steps"]
        gated = {s["name"] for s in steps if "steps.history.outputs.replay != '0'" in str(s.get("if", ""))}
        # The caches restore either way: a head re-run after an all-answered replay installs from them.
        self.assertEqual(gated, {"Use the base's bun", "Install webview dependencies", "Build base web bundles",
                                 "Install headless engines"})
        names = [s["name"] for s in steps]
        self.assertLess(names.index("Restore the base's webview test history"), names.index("Use the base's bun"))
        compare = next(s for s in steps if s["name"] == "Run base reds and compare")
        self.assertEqual(compare["env"]["KNOWN_REPLAY"], "${{ steps.history.outputs.replay }}")
        self.assertIn('base-replay-files', compare["run"])
        self.assertIn('base-known.json', compare["run"])

    def test_the_history_job_records_the_key_the_shards_computed_and_never_an_empty_one(self):
        # The history job's checkout is sparse; inputs() reads routed files it does not have (#40223 review).
        shard = self.job("react-apps-check-shard")
        self.assertIn('webviews_test_history.py inputs > "$RUNNER_TEMP/webviews-head-results/webviews-inputs-key"', shard)
        upload = shard[shard.index("      - name: Upload this push's webview results"):]
        upload = upload[:upload.index("\n      - name:", 10)]
        self.assertIn("webviews-head-results/webviews-inputs-key", upload)
        upkeep = self.job("webviews-test-history")
        self.assertNotIn("webviews_test_history.py inputs", upkeep)
        record = upkeep[upkeep.index("      - name: Add this push to the history"):]
        record = record[:record.index("\n      - name:", 10)]
        body = record[record.index("        run: |\n") + len("        run: |\n"):].splitlines()
        script = "\n".join(line[10:] for line in itertools.takewhile(lambda line: line.startswith(" " * 10), body))
        with tempfile.TemporaryDirectory() as temp:
            Path(temp, "scripts/ci").mkdir(parents=True)
            Path(temp, "scripts/ci/webviews_test_history.py").write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
            Path(temp, "scripts/ci/web_subareas.py").write_text(
                (ROOT / "scripts/ci/web_subareas.py").read_text(encoding="utf-8"), encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=temp, check=True)
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"],
                           cwd=temp, check=True)
            Path(temp, "webviews-test-history").mkdir()

            def record(*keys):
                for i, key in enumerate(keys, 1):
                    shard = Path(temp, f"history-results/webviews-test-history-shard{i}")
                    shard.mkdir(parents=True, exist_ok=True)
                    (shard / "webviews-head-results.json").write_text(json.dumps({FILE: True}), encoding="utf-8")
                    if key is not None:
                        (shard / "webviews-inputs-key").write_text(key + "\n", encoding="utf-8")
                done = subprocess.run(["bash", "-e", "-c", script], cwd=temp, capture_output=True, text=True, env=git_fixture_env.fixture_env({
                    "PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "RUNNER_TEMP": temp,
                    "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ATTEMPT": "1"}))
                saved = Path(temp, "webviews-test-history/history.json")
                runs_ = json.loads(saved.read_text())["runs"] if saved.exists() else []
                subprocess.run(["rm", "-rf", str(Path(temp, "history-results")), str(saved)], check=True)
                return done.returncode, [r["inputs"] for r in runs_]

            self.assertEqual(record("k1", "k1"), (0, ["k1"]))
            self.assertNotEqual(record(None, None)[0], 0)
            self.assertNotEqual(record("k1", "k2")[0], 0)
        self.assertNotEqual(subprocess.run([sys.executable, str(SCRIPT), "record", "/nonexistent", "/tmp/x", "--sha", "a",
                                            "--time", "1", "--inputs", "", "/nonexistent"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
