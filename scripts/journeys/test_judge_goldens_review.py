#!/usr/bin/env python3
"""The judge goldens runner gives the right CLASS of answer (review of #33930 at 83af04ed384, comment 6608121020).

    /work/tmp/bv-venv/bin/python -I scripts/journeys/test_judge_goldens_review.py

`run` exits 0 only when every result was reproduced, 1 only when a judge's result changed, and 2 (NO VERDICT) when the
run itself cannot say: a judge that does not finish, a judge_scan that times out or is killed, an out-of-memory or
an operating-system error, a store file the table does not pin (a judge reads only the pinned files: a sealed view),
a blessed result file that is gone or changed, or no film selected. A bless pins the runner it ran with, and refuses
an uncommitted runner as it refuses uncommitted judges.
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import judge_goldens as jg  # noqa: E402
import test_judge_goldens as base  # noqa: E402


def run_cli(w, judges, *extra, timeout=120):
    """The runner as its own process (a hang must end by itself)."""
    done = subprocess.run([sys.executable, "-I", str(HERE / "judge_goldens.py"), "run", "--store", str(w.store),
                           "--manifest", str(w.manifest), "--judges", str(judges), "--jobs", "2", *extra],
                          capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout + done.stderr


class Blessed(unittest.TestCase):
    def setUp(self):
        self.w = base.Workspace()
        self.assertEqual(self.w.snapshot()[0], 0)
        code, out = self.w.bless()
        self.assertEqual(code, 0, out)

    def tearDown(self):
        self.w.close()

    def judges(self, name, **parts):
        return base.write_judges(self.w.root / name, **parts)


class NoVerdictTests(Blessed):
    def test_a_judge_that_loops_is_no_verdict_within_the_film_budget(self):
        # The stand-in ends by itself after 60 s (review 5 of #33930, note 3): if the budget kill regresses, a film
        # process left behind does not spin for ever. The test still proves the 2 s budget.
        looping = self.judges("judges-loop", keys="import time\ndef judge(base):\n    end = time.monotonic() + 60\n"
                                                  "    while time.monotonic() < end:\n        pass\n")
        started = time.monotonic()
        code, out = run_cli(self.w, looping, "--film-seconds", "2")
        self.assertEqual(code, 2, out)
        self.assertIn("did not finish", out)
        self.assertLess(time.monotonic() - started, 60, out)

    def test_a_judge_that_catches_every_exception_still_ends_at_the_budget(self):
        stubborn = self.judges("judges-stubborn", keys=textwrap.dedent('''
            import time
            def judge(base):
                end = time.monotonic() + 60  # bounded (review 5 of #33930, note 3)
                while time.monotonic() < end:
                    try:
                        while time.monotonic() < end:
                            pass
                    except Exception:
                        pass
            '''))
        code, out = run_cli(self.w, stubborn, "--film-seconds", "2")
        self.assertEqual(code, 2, out)
        self.assertIn("did not finish", out)

    def test_a_judge_scan_timeout_is_no_verdict_not_a_result(self):
        slow = self.judges("judges-scan-slow", scan="import time\ntime.sleep(60)\n")
        code, out = run_cli(self.w, slow, "--film-seconds", "2")
        self.assertEqual(code, 2, out)
        self.assertIn("judge_scan", out)

    def test_a_judge_scan_killed_by_a_signal_is_no_verdict(self):
        killed = self.judges("judges-scan-killed", scan="import os, signal\nos.kill(os.getpid(), signal.SIGKILL)\n")
        code, out = run_cli(self.w, killed)
        self.assertEqual(code, 2, out)
        self.assertIn("signal", out)

    def test_out_of_memory_and_os_errors_are_no_verdict(self):
        for name, error in (("oom", "MemoryError()"), ("os", "OSError(24, 'Too many open files')")):
            judges = self.judges(f"judges-{name}", keys=f"def judge(base):\n    raise {error}\n")
            code, out = run_cli(self.w, judges)
            self.assertEqual(code, 2, (name, out))

    def test_an_empty_selection_is_no_verdict(self):
        code, out = self.w.run(None, "--only", "no-such-folder/*")
        self.assertEqual(code, 2, out)
        self.assertIn("no film", out)

    def test_a_file_the_table_does_not_pin_changes_no_result(self):
        # One store serves every manifest (review 6 of #33930, finding A): a file this table does not pin is another
        # manifest's, and no judge sees it (sealed views: display.json, an input of every film in its folder, too).
        folder = self.w.store / "films" / "build-a-120x2"
        os.chmod(folder, 0o755)
        (folder / "display.json").write_text(json.dumps({"asked": {"scale": 3}}))
        code, out = self.w.run()
        self.assertEqual(code, 0, out)
        self.assertIn("reproduced 12 of 12", out)
        self.assertIn("1 file", out)

    def test_a_file_beside_the_film_folders_changes_no_result(self):
        films = self.w.store / "films"
        os.chmod(films, 0o755)
        (films / "diag-tiers.json").write_text("{}")
        code, out = self.w.run()
        self.assertEqual(code, 0, out)
        self.assertIn("reproduced 12 of 12", out)

    def test_a_blessed_result_that_is_gone_is_no_verdict(self):
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        sha = expected["films"]["build-a-120x2/col-drag"]["video_judge"]["sha256"]
        os.remove(self.w.store / "expected" / f"{sha}.json")
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn(sha[:12], out)

    def test_a_hand_edited_expected_hash_is_no_verdict(self):
        path = self.w.manifest / "expected.json"
        text = path.read_text()
        expected = json.loads(text)
        sha = expected["films"]["build-a-120x2/col-drag"]["video_judge"]["sha256"]
        path.write_text(text.replace(sha, "0" * 64))
        code, out = self.w.run()
        self.assertEqual(code, 2, out)


class SealedViewTests(Blessed):
    def test_a_judge_sees_only_the_pinned_files_of_its_film(self):
        # A judge that lists its folder and its parent: the result must not depend on what else the store holds.
        lister = self.judges("judges-lister", keys=textwrap.dedent('''
            import os
            def judge(base):
                folder = os.path.dirname(base)
                return {"folder": sorted(os.listdir(folder)), "parent": sorted(os.listdir(os.path.dirname(folder)))}
            '''))
        _, _ = self.w.cli("bless", "--judges", str(lister), "--reason", "lister", "--jobs", "2", "--no-git-check")
        expected = json.loads((self.w.manifest / "expected.json").read_text())
        sha = expected["films"]["build-a-120x2/col-drag"]["judge_keys"]["sha256"]
        seen = jg.load_expected(self.w.store, sha)
        table = jg.files_table(self.w.store, json.loads((self.w.manifest / "films.json").read_text()))
        self.assertEqual(seen["folder"], sorted(table["build-a-120x2"]))
        self.assertEqual(seen["parent"], ["build-a-120x2"])


class SnapshotTests(unittest.TestCase):
    def test_a_refused_folder_leaves_no_new_file_in_the_store(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            src = w.gallery / "build-a-120x2"
            (src / "col-drag.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            (src / "display.json").write_text("{}")
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertFalse((w.store / "films" / "build-a-120x2" / "display.json").exists())
        finally:
            w.close()

    def test_a_new_input_of_a_recorded_film_is_refused(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            (w.gallery / "build-a-120x2" / "col-drag.result.json").write_text("{}")
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("col-drag.result.json", out)
            (w.gallery / "build-a-120x2" / "col-drag.result.json").unlink()
            (w.gallery / "build-a-120x2" / "display.json").write_text("{}")
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("display.json", out)
        finally:
            w.close()


class NormalizeTests(unittest.TestCase):
    def test_a_set_has_one_order(self):
        self.assertEqual(jg.normalize({"s": {3, 1, 2}}, roots=[]), {"s": [1, 2, 3]})

    def test_an_unknown_type_is_an_error_not_a_repr(self):
        with self.assertRaises(TypeError):
            jg.normalize({"x": object()}, roots=[])


class ContentTests(unittest.TestCase):
    def test_a_changed_content_file_is_never_kept_as_its_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            sha = jg.put_content(tmp, {"a": 1})
            path = Path(tmp) / f"{sha}.json"
            os.chmod(path, 0o644)
            path.write_text('{"a":2}')
            with self.assertRaises(ValueError):
                jg.put_content(tmp, {"a": 1})

    def test_a_summary_of_an_unexpected_shape_is_named_not_a_crash(self):
        got = jg.summary("video_judge", {"findings": ["a string, not a finding"]})
        self.assertIn("summary_error", got)


class RunnerPinTests(unittest.TestCase):
    """A bless names the runner's own blob, and refuses an uncommitted runner (the runner makes the judges' inputs
    and normalizes their results: it is part of what a golden pins)."""

    def test_a_bless_refuses_an_uncommitted_runner_and_records_the_runner(self):
        w = base.Workspace()
        repo = Path(tempfile.mkdtemp(prefix="judge-goldens-runner-"))
        try:
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                       GIT_COMMITTER_EMAIL="t@t")
            shutil.copy(HERE / "judge_goldens.py", repo / "judge_goldens.py")
            for item in w.judges.iterdir():
                (shutil.copytree if item.is_dir() else shutil.copy)(item, repo / item.name)
            subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
            subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "runner and judges"], check=True, env=env)
            self.assertEqual(w.snapshot()[0], 0)

            def bless():
                done = subprocess.run([sys.executable, "-I", str(repo / "judge_goldens.py"), "bless", "--store", str(w.store),
                                       "--manifest", str(w.manifest), "--judges", str(repo), "--reason", "pin",
                                       "--jobs", "2"], capture_output=True, text=True, timeout=120)
                return done.returncode, done.stdout + done.stderr
            code, out = bless()
            self.assertEqual(code, 0, out)
            history = json.loads((w.manifest / "expected.json").read_text())["history"][-1]
            self.assertIn("runner", history)
            self.assertEqual(len(history["runner"]["blob"]), 40)
            text = (repo / "judge_goldens.py").read_text()
            (repo / "judge_goldens.py").write_text(text.replace("return scale or 2.0", "return 3.0"))
            code, out = bless()
            self.assertEqual(code, 2, out)
            self.assertIn("uncommitted", out)
        finally:
            shutil.rmtree(repo, ignore_errors=True)
            w.close()



class SecondReviewTests(Blessed):
    """Review of #33930 at c366f1481d0 (FIX, comment 6612669328): findings A (stale bytecode), B (three faults that
    were not NO VERDICT within the budget) and C (a TRUTH fact that passes with no check)."""

    def test_a_same_size_same_second_judge_edit_is_a_difference_not_reproduced(self):
        # Finding A: every film process read one bytecode cache under $TMPDIR, keyed by the source's size and mtime.
        judges = self.judges("judges-stale", keys="def judge(base):\n    return {'presses': 0}\n")
        code, out = self.w.cli("bless", "--judges", str(judges), "--reason", "stale", "--jobs", "2", "--no-git-check")
        self.assertEqual(code, 0, out)
        path = judges / "video-cases" / "judge_keys.py"
        stat = path.stat()
        self.assertEqual(run_cli(self.w, judges)[0], 0)  # the cache now holds the old bytecode
        path.write_text(path.read_text().replace("'presses': 0", "'presses': 7"))
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))  # the same size and the same mtime
        code, out = run_cli(self.w, judges)
        self.assertEqual(code, 1, out)
        self.assertIn(".presses: 0 -> 7", out)

    def test_a_film_that_closes_its_output_and_hangs_ends_at_the_budget(self):
        # Finding B1: at the pipe's end the runner waited for the process with no limit.
        # The stand-in hangs 40 s, then ends by itself: a runner without the fix ends late, never leaves it behind.
        hang = self.judges("judges-quiet", keys=textwrap.dedent('''
            import os, time
            def judge(base):
                os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
                time.sleep(40)
                return {"presses": 0}
            '''))
        started = time.monotonic()
        code, out = run_cli(self.w, hang, "--film-seconds", "2", timeout=180)
        self.assertEqual(code, 2, out)
        self.assertIn("did not finish", out)
        self.assertLess(time.monotonic() - started, 20, out)

    def test_a_host_error_inside_judge_scan_is_no_verdict(self):
        # Finding B2: judge_scan runs as its own process, so its MemoryError or EMFILE became its result text.
        for name, error in (("oom", "MemoryError()"), ("emfile", "OSError(24, 'Too many open files')")):
            scan = self.judges(f"judges-scan-{name}", scan=f"raise {error}\n")
            code, out = run_cli(self.w, scan)
            self.assertEqual(code, 2, (name, out))
            self.assertIn("judge_scan", out)

    def test_a_unit_test_process_ended_by_a_signal_is_no_verdict(self):
        # Finding B3: a killed test file was a TRUTH failure (exit 1) with the count "-1 of 0".
        killed = self.judges("judges-unit-killed")
        (killed / "test_video_judge.py").write_text("import os, signal\nos.kill(os.getpid(), signal.SIGKILL)\n")
        code, out = run_cli(self.w, killed)
        self.assertEqual(code, 2, out)
        self.assertIn("unit test", out)
        self.assertNotIn("-1 of", out)

    def test_judge_scan_leaves_no_folder_behind(self):
        # Note H: a film ended during judge_scan left its judge-scan-* folder in $TMPDIR.
        tmp = Path(tempfile.mkdtemp(prefix="goldens-tmp-"))
        try:
            slow = self.judges("judges-scan-slow2", scan="import time\ntime.sleep(60)\n")
            done = subprocess.run([sys.executable, "-I", str(HERE / "judge_goldens.py"), "run", "--store", str(self.w.store),
                                   "--manifest", str(self.w.manifest), "--judges", str(slow), "--jobs", "2",
                                   "--film-seconds", "2"], capture_output=True, text=True, timeout=120,
                                  env=dict(os.environ, TMPDIR=str(tmp)))
            self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
            self.assertEqual(sorted(p.name for p in tmp.iterdir() if p.name.startswith("judge-scan-")), [])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TruthFactTests(unittest.TestCase):
    """Finding C: a fact of a film that is not in films.json passed `run` unchecked (bless refused it), and some
    expectation shapes are met by any result. Both are NO VERDICT now, in run and in bless."""

    def workspace(self, fact):
        """A blessed workspace with one good fact; then FACT is added to its truth.json."""
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        w.write_truth()
        self.assertEqual(w.snapshot()[0], 0)
        code, out = w.bless()
        self.assertEqual(code, 0, out)
        doc = json.loads((w.manifest / "truth.json").read_text())
        doc["facts"].append(fact)
        (w.manifest / "truth.json").write_text(json.dumps(doc))
        return w

    def assert_no_verdict(self, fact, needle):
        w = self.workspace(fact)
        try:
            code, out = w.cli("bless", "--judges", str(w.judges), "--reason", "t", "--jobs", "2", "--no-git-check")
            self.assertEqual(code, 2, out)
            self.assertIn(needle, out)
            code, out = w.run()
            self.assertEqual(code, 2, out)
            self.assertIn(needle, out)
        finally:
            w.close()

    def test_a_fact_of_a_film_not_in_films_json_is_no_verdict(self):
        # (dropped frames, not jump: an absence of jump is refused for its own reason, which would hide this rule)
        self.assert_no_verdict({"id": "typo", "film": "px-build-120x2/px-keys-typo", "why": "t",
                                "expect": [{"judge": "video_judge", "absent_check": "dropped frames"}]}, "is not in films.json")

    def test_a_fact_with_no_check_is_no_verdict(self):
        self.assert_no_verdict({"id": "empty", "film": "px-build-120x2/px-keys", "why": "t"}, "empty")

    def test_an_empty_or_reversed_span_is_no_verdict(self):
        for name, spans in (("no-spans", []), ("reversed", [[190, 164]])):
            with self.subTest(case=name):
                self.assert_no_verdict({"id": name, "film": "px-build-120x2/px-keys", "why": "t",
                                        "expect": [{"judge": "video_judge", "defect_frames": spans}]}, name)

    def test_an_unknown_expectation_key_is_no_verdict(self):
        self.assert_no_verdict({"id": "odd", "film": "px-build-120x2/px-keys", "why": "t",
                                "expect": [{"judge": "video_judge", "check": "gap or overlap", "frame": [3, 6]}]}, "odd")

    def test_only_skips_the_facts_of_films_it_does_not_select(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            code, out = w.run(None, "--only", "px-build-120x2/*")
            self.assertEqual(code, 0, out)
            self.assertIn("truth: 2 of 2", out)
        finally:
            w.close()


class RulerFrameIdentityTests(unittest.TestCase):
    """Note D: the ruler counts scan records, the judge counts the complete frames of frames.json. A film whose
    records do not match its complete frames one to one, by time, is NO VERDICT for a ruler fact."""

    def test_a_scan_with_one_record_more_than_the_complete_frames_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            film = w.gallery / "px-build-120x2" / "px-keys"
            truth.write_scan(Path(f"{film}.mov.scan"), 10)  # 10 records; frames.json has 9 complete frames
            fact = {"line": "row", "at": 10, "class": "#FF00FF", "x": [18, 22], "frames": [3, 6], "min_run_px": 8}
            with self.assertRaises(ValueError) as caught:
                jg.ruler_check(str(film), fact)
            self.assertIn("complete frames", str(caught.exception))
        finally:
            w.close()



class ThirdReviewTests(unittest.TestCase):
    """Review 3 of #33930 at 46438a1154d (FIX, comment 6615568910): an expectation is checked only against the result
    shape of its own judge; a fact with an unknown key, no why, or a judge that does not judge its film is NO VERDICT;
    an absence on a judge that saw no frame is NO VERDICT; a missing truth.json is NO VERDICT; a judge file that
    changes during a run is NO VERDICT; the judge's own exit 97 is a result."""

    def workspace(self, fact, video=None):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace(video=video)
        w.write_truth()
        self.assertEqual(w.snapshot()[0], 0)
        code, out = w.bless()
        self.assertEqual(code, 0, out)
        doc = json.loads((w.manifest / "truth.json").read_text())
        doc["facts"].append(fact)
        (w.manifest / "truth.json").write_text(json.dumps(doc))
        return w

    def assert_no_verdict(self, fact, needle, video=None):
        w = self.workspace(fact, video)
        try:
            code, out = w.cli("bless", "--judges", str(w.judges), "--reason", "t", "--jobs", "2", "--no-git-check")
            self.assertEqual(code, 2, out)
            self.assertIn(needle, out)
            code, out = w.run()
            self.assertEqual(code, 2, out)
            self.assertIn(needle, out)
        finally:
            w.close()

    FILM = "px-build-120x2/px-keys"

    def test_a_kind_of_another_judge_is_no_verdict(self):
        # absent_kind reads judge_trace's defects; on video_judge it checked nothing and always held.
        for name, expect in (("absent_kind on video_judge", {"judge": "video_judge", "absent_kind": "reverse"}),
                             ("kind on video_judge", {"judge": "video_judge", "kind": "gap or overlap"}),
                             ("absent_check on judge_trace", {"judge": "judge_trace", "absent_check": "jump"}),
                             ("absent_check on judge_keys", {"judge": "judge_keys", "absent_check": "jump"})):
            with self.subTest(case=name):
                self.assert_no_verdict({"id": "wrong-kind", "film": self.FILM, "why": "t", "expect": [expect]},
                                       "wrong-kind")

    def test_a_judge_that_does_not_judge_the_film_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            base.write_film(w.gallery / "frames-only-120x2", "only", frames=4)
            for kind in ("trace.json", "events.json", "mov.scan", "meta.json"):
                (w.gallery / "frames-only-120x2" / f"only.{kind}").unlink()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            doc = json.loads((w.manifest / "truth.json").read_text())
            doc["facts"].append({"id": "not-its-judge", "film": "frames-only-120x2/only", "why": "t",
                                 "expect": [{"judge": "judge_trace", "absent_kind": "reverse"}]})
            (w.manifest / "truth.json").write_text(json.dumps(doc))
            code, out = w.run()
            self.assertEqual(code, 2, out)
            self.assertIn("not-its-judge", out)
        finally:
            w.close()

    def test_an_unknown_key_of_a_fact_or_no_why_is_no_verdict(self):
        self.assert_no_verdict({"id": "typo-key", "film": self.FILM, "why": "t",
                                "expects": [{"judge": "video_judge", "absent_check": "dropped frames"}]}, "unknown keys")
        self.assert_no_verdict({"id": "no-why", "film": self.FILM,
                                "expect": [{"judge": "video_judge", "absent_check": "dropped frames"}]}, "no-why: no why")

    def test_an_absence_on_a_judge_that_saw_no_frame_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        empty = truth.STUB_VIDEO_BAND.replace('"frames": 9', '"frames": 0').replace("__FRAMES__", "[]") \
            .replace("__EXTRA__", "[]")
        w = truth.TruthWorkspace(video=empty)
        try:
            w.write_truth(expect=[{"judge": "video_judge", "absent_check": "dropped frames"}])
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.cli("bless", "--judges", str(w.judges), "--reason", "t", "--jobs", "2", "--no-git-check")
            self.assertEqual(code, 2, out)
            self.assertIn("no frame", out)
        finally:
            w.close()

    def test_a_missing_truth_file_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            (w.manifest / "truth.json").unlink()
            code, out = w.run()
            self.assertEqual(code, 2, out)
            self.assertIn("truth.json", out)
        finally:
            w.close()

    def test_a_judge_file_that_changes_during_the_run_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            keys = w.judges / "video-cases" / "judge_keys.py"
            original = keys.read_text()
            # The first film's judge_keys rewrites itself: a later film loads the changed file.
            keys.write_text(original.replace("def judge(base):", "import pathlib\n_ME = pathlib.Path(__file__)\n"
                                             "def judge(base):\n    _ME.write_text(_ME.read_text().replace("
                                             "'presses', 'presses2'))", 1))
            code, out = w.cli("run", "--judges", str(w.judges), "--jobs", "1")
            self.assertEqual(code, 2, out)
            self.assertIn("changed during the run", out)
        finally:
            w.close()

    def test_judge_scans_own_exit_97_is_a_result(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            (w.judges / "video-cases" / "judge_scan.py").write_text("import sys\nprint('done')\nsys.exit(97)\n")
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 0, out)
        finally:
            w.close()



class FourthReviewTests(unittest.TestCase):
    """Review 4 of #33930 at 7d08a9afddc (FIX, comment 6619442751), finding A: an absence holds only where its judge
    looked (a judged motion) and only for a name the judge reports; a result without the list a kind reads is NO
    VERDICT."""

    FILM = "px-build-120x2/px-keys"

    def workspace(self, expect, video=None, trace=None):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace(video=video)
        if trace is not None:
            (w.judges / "video-cases" / "judge_trace.py").write_text(textwrap.dedent(trace))
        w.write_truth(expect=expect)
        self.assertEqual(w.snapshot()[0], 0)
        return w

    def bless(self, w):
        return w.cli("bless", "--judges", str(w.judges), "--reason", "t", "--jobs", "2", "--no-git-check")

    NO_MOTION_TRACE = """
        import json
        def load_trace(path):
            return json.loads(open(path).read())
        def judge(trace, frames=None, scale=2.0, events=None):
            return {"motion": None, "motions": [], "defects": [], "counts": {}}
        """
    MOTION_TRACE = """
        import json
        def load_trace(path):
            return json.loads(open(path).read())
        def judge(trace, frames=None, scale=2.0, events=None):
            return {"motion": {"first": 0, "last": 2},
                    "motions": [{"first": 0, "last": 2, "motion": {"frames": 3}, "travel": {"a": {"right": 40.0}}}],
                    "defects": [], "counts": {}}
        """

    def test_an_absence_on_a_trace_with_no_motion_is_no_verdict(self):
        w = self.workspace([{"judge": "judge_trace", "absent_kind": "reverse"}], trace=self.NO_MOTION_TRACE)
        try:
            code, out = self.bless(w)
            self.assertEqual(code, 2, out)
            self.assertIn("no motion", out)
        finally:
            w.close()

    def test_an_absence_on_a_trace_with_a_motion_holds(self):
        w = self.workspace([{"judge": "judge_trace", "absent_kind": "reverse"}], trace=self.MOTION_TRACE)
        try:
            code, out = self.bless(w)
            self.assertEqual(code, 0, out)
            self.assertIn("truth: 2 of 2", out)
        finally:
            w.close()

    def test_an_absence_on_a_video_judge_with_no_motion_window_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        still = truth.video_stub().replace('"motion": [{"a": 0, "b": 8}]', '"motion": []')
        w = self.workspace([{"judge": "video_judge", "absent_check": "dropped frames"}], video=still)
        try:
            code, out = self.bless(w)
            self.assertEqual(code, 2, out)
            self.assertIn("no motion", out)
        finally:
            w.close()

    def test_the_model_grid_check_needs_no_motion_window(self):
        # 'model edge off the device-pixel grid' judges the trace alone (every sample), not a motion window.
        import test_judge_goldens_truth as truth
        still = truth.video_stub().replace('"motion": [{"a": 0, "b": 8}]', '"motion": []')
        w = self.workspace([{"judge": "video_judge", "absent_check": "model edge off the device-pixel grid"}], video=still)
        try:
            code, out = self.bless(w)
            self.assertEqual(code, 0, out)
        finally:
            w.close()

    def test_an_absent_name_its_judge_does_not_report_is_no_verdict(self):
        for name, expect in (("reversed", {"judge": "judge_trace", "absent_kind": "reversed"}),
                             ("jump-back", {"judge": "video_judge", "absent_check": "jump-back"})):
            with self.subTest(name=name):
                w = self.workspace([expect], trace=self.MOTION_TRACE)
                try:
                    code, out = self.bless(w)
                    self.assertEqual(code, 2, out)
                    self.assertIn(name, out)
                finally:
                    w.close()

    def test_a_result_without_its_list_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        bare = truth.video_stub().replace('"findings": findings}', '"findings_v2": findings}')
        w = self.workspace([{"judge": "video_judge", "absent_check": "gap or overlap"}], video=bare)
        try:
            code, out = self.bless(w)
            self.assertEqual(code, 2, out)
            self.assertIn("no findings list", out)
        finally:
            w.close()

    def test_the_runners_name_sets_are_the_judges_own(self):
        import re
        video = (HERE / "video_judge.py").read_text()
        names = set(re.findall(r'(?<![a-z_])finding\(\s*case\s*,\s*"([^"]+)"', video, re.S))
        names |= set(re.findall(r'grouped_findings\(\s*case\s*,\s*"([^"]+)"', video, re.S))
        names |= set(re.findall(r'"check":\s*"([^"]+)"', video))
        trace = (HERE / "video-cases" / "judge_trace.py").read_text()
        kinds = set(re.findall(r'(?<![a-z_])add\(\s*"([^"]+)"', trace)) | set(re.findall(r'"kind":\s*"([^"]+)"', trace))
        kinds |= {"overlap"}  # add("overlap-fading" if fading else "overlap", ...): the second name of one call
        self.assertEqual(jg.JUDGE_NAMES["video_judge"], frozenset(names))
        self.assertEqual(jg.JUDGE_NAMES["judge_trace"], frozenset(kinds))


class FifthReviewTests(unittest.TestCase):
    """Review 5 of #33930 at f7872ae3a71 (FIX, comment 6621529858), finding A: a name is checked at the severity its
    judge writes it with (9 video_judge names are never defects), and an absence needs the input of its own check, as
    the result shows it (a motion window, trace samples, tracked dividers, a divider compared with the trace, the
    film's movie, panes at rest), not only a motion window. A positive check needs nothing: a judge that did not look,
    and so missed it, fails. Also its notes: a name that is not text, truth.json read once, the NO VERDICT heading, a
    skipped unit test."""

    JUDGED = {"frames": 10, "motion": [[0.0, 0.5]], "pacing": {"trace": True}, "tracked_dividers": 2,
              "model_lag": {"0": 5}, "hid_clock": {"offset_s": 0.0}, "findings": []}

    def result(self, findings=(), **fields):
        r = dict(self.JUDGED, findings=list(findings))
        r.update(fields)
        return r

    @staticmethod
    def found(check, severity, frames=(3, 4)):
        return {"check": check, "severity": severity, "frames": list(frames), "t": [0, 0], "detail": "x"}

    @staticmethod
    def verdict(result, expect, **inputs):
        """'holds', 'fails: <why>' or 'NO VERDICT: <why>'."""
        expect = dict(expect)
        expect.setdefault("judge", "video_judge")
        try:
            why = jg._expectation(result, expect, **inputs)
        except jg.Unchecked as error:
            return f"NO VERDICT: {error}"
        return "holds" if why is None else f"fails: {why}"

    def test_a_note_or_recorder_name_is_checked_at_its_own_severity(self):
        for name, severity in (("content wait", "note"), ("content size during motion", "note"),
                               ("capture stall", "recorder"), ("encoder dropped frames", "recorder")):
            with self.subTest(name=name):
                reported = self.result([self.found(name, severity)])
                self.assertEqual(self.verdict(reported, {"check": name}), "holds")
                self.assertEqual(self.verdict(reported, {"check": name, "frames": [3, 4]}), "holds")
                self.assertTrue(self.verdict(reported, {"absent_check": name}).startswith("fails: must not report"))
                self.assertEqual(self.verdict(self.result(), {"absent_check": name}), "holds")
        # A defect name is not met by a finding of another severity.
        self.assertTrue(self.verdict(self.result([self.found("jump", "note")]), {"check": "jump"}).startswith("fails"))

    def test_the_severities_are_the_ones_the_judge_writes(self):
        import ast
        tree = ast.parse((HERE / "video_judge.py").read_text())
        written = {}

        def text(node):
            return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None

        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("finding", "grouped_findings"):
                if len(node.args) < 2 or text(node.args[1]) is None:
                    continue
                at = 5 if node.func.id == "finding" else 4
                severity = text(node.args[at]) if len(node.args) > at else "defect"
                for kw in node.keywords:
                    if kw.arg == "severity":
                        severity = text(kw.value)
                written.setdefault(text(node.args[1]), set()).add(severity)
            elif isinstance(node, ast.Dict):  # a finding written as a dict (the model grid); not finding()'s own
                keys = [text(k) for k in node.keys]
                if "check" in keys and "severity" in keys and text(node.values[keys.index("check")]) is not None:
                    written.setdefault(text(node.values[keys.index("check")]), set()).add(
                        text(node.values[keys.index("severity")]))
        self.assertTrue(all(len(v) == 1 for v in written.values()), written)
        self.assertEqual({name: severity for name, (severity, _) in jg.NAMES["video_judge"].items()},
                         {name: v.pop() for name, v in written.items()})
        self.assertEqual(jg.JUDGE_NAMES, {judge: frozenset(names) for judge, names in jg.NAMES.items()})

    def test_an_absence_of_a_divider_check_needs_a_tracked_divider(self):
        untracked = self.result(tracked_dividers=0, model_lag={})
        # (jump, jump back and jump back (animation) also need a divider that moved, which no result shows: review 7)
        for name in ("gap or overlap", "divider not shown",
                     "shown geometry not in the model"):
            with self.subTest(name=name):
                self.assertIn("tracked no divider", self.verdict(untracked, {"absent_check": name}))
                # (jump back also needs a drag the judge placed: review 6, finding B.3)
                self.assertEqual(self.verdict(self.result(), {"absent_check": name}, hid_drag=True), "holds")

    def test_an_absence_of_a_model_check_needs_the_trace(self):
        untraced = self.result(pacing={"trace": False}, model_lag={})
        for name in ("content not at final size after motion", "content size during motion", "content wait",
                     "model edge off the device-pixel grid", "shown geometry not in the model"):
            with self.subTest(name=name):
                self.assertIn("no trace samples", self.verdict(untraced, {"absent_check": name}))
        compared_none = self.result(model_lag={})
        self.assertIn("compared no tracked divider", self.verdict(compared_none,
                                                                  {"absent_check": "shown geometry not in the model"}))

    def test_an_absence_of_a_movie_check_needs_the_films_movie(self):
        for name in ("blank pane", "flash", "content stretched", "reflow"):
            with self.subTest(name=name):
                self.assertIn("no movie", self.verdict(self.result(), {"absent_check": name}))
                self.assertEqual(self.verdict(self.result(), {"absent_check": name}, movie=True), "holds")

    def test_the_movie_is_the_films_movie_in_the_store(self):
        # The runner reads the movie from the films table (the film's pinned files), not from the result.
        import test_judge_goldens_truth as truth
        for with_movie, code_wanted in ((False, 2), (True, 0)):
            with self.subTest(with_movie=with_movie):
                w = truth.TruthWorkspace()
                try:
                    if with_movie:
                        (w.gallery / "px-build-120x2" / "px-keys.mov").write_bytes(b"a movie the stand-in judge does not read")
                    w.write_truth(expect=[{"judge": "video_judge", "absent_check": "flash"}])
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, code_wanted, out)
                    if not with_movie:
                        self.assertIn("no movie", out)
                finally:
                    w.close()

    def test_an_absence_of_a_check_that_starts_from_an_input_is_no_verdict(self):
        # video_judge writes no count of the inputs these checks start from: the result cannot show that they looked.
        for name in ("main thread missed refreshes before the first frame", "frame gap during slow input"):
            with self.subTest(name=name):
                got = self.verdict(self.result(), {"absent_check": name})
                self.assertTrue(got.startswith("NO VERDICT") and "input" in got, got)

    def test_an_absence_of_gap_or_overlap_on_the_trace_needs_two_panes_at_rest(self):
        def trace(panes):
            motion = {"first_frame": 1, "last_frame": 9, "frames": 9, "panes_at_rest": panes}
            return {"motion": motion, "motions": [{"motion": motion, "travel": {"a": {"right": 40.0}}}], "defects": []}

        for name in ("gap", "overlap", "overlap-fading"):
            with self.subTest(name=name):
                self.assertIn("2 or more panes at rest", self.verdict(trace(["a"]),
                                                                       {"judge": "judge_trace", "absent_kind": name}))
                self.assertEqual(self.verdict(trace(["a", "b"]), {"judge": "judge_trace", "absent_kind": name}), "holds")
        self.assertEqual(self.verdict(trace(["a"]), {"judge": "judge_trace", "absent_kind": "reverse"}), "holds")

    def test_a_reported_name_fails_its_absence_even_where_its_input_is_not_shown(self):
        reported = self.result([self.found("jump", "defect")], tracked_dividers=0)
        self.assertTrue(self.verdict(reported, {"absent_check": "jump"}).startswith("fails: must not report"))

    def test_a_name_that_is_not_text_is_no_verdict_that_names_the_fact(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth(expect=[{"judge": "video_judge", "absent_check": ["jump"]}])
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("px-keys-shell-band", out)
            self.assertNotIn("the runner failed", out)
        finally:
            w.close()

    def test_a_run_reads_truth_json_once(self):
        # Read twice, an edit between the reads checks facts other than the ones that were validated.
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        reads, real = [], jg.load_truth
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)

            def counting(manifest):
                reads.append(manifest)
                return real(manifest)

            jg.load_truth = counting
            code, out = w.run()
            self.assertEqual(code, 0, out)
            self.assertEqual(len(reads), 1, out)
            reads.clear()
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            self.assertEqual(len(reads), 1, out)
        finally:
            jg.load_truth = real
            w.close()

    def test_a_no_verdict_of_an_expectation_is_not_called_a_ruler_fact(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            (w.judges / "video-cases" / "judge_trace.py").write_text(textwrap.dedent(FourthReviewTests.NO_MOTION_TRACE))
            w.write_truth(expect=[{"judge": "judge_trace", "absent_kind": "reverse"}])
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("no motion", out)
            self.assertNotIn("ruler fact does not hold", out)
        finally:
            w.close()

    def test_a_skipped_judge_unit_test_is_no_verdict(self):
        import test_judge_goldens_truth as truth
        skipping = truth.PASSING_UNIT_TESTS.replace("def test_b(self): self.assertTrue(True)",
                                                    "@unittest.skip('its film is not on this machine')\n"
                                                    "    def test_b(self): self.assertTrue(True)")
        w = truth.TruthWorkspace(unit=skipping)
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("skipped", out)
            (w.judges / "test_video_judge.py").write_text(textwrap.dedent(truth.PASSING_UNIT_TESTS))
            self.assertEqual(w.bless()[0], 0)
            (w.judges / "test_video_judge.py").write_text(textwrap.dedent(skipping))
            code, out = w.run()
            self.assertEqual(code, 2, out)
            self.assertIn("skipped", out)
        finally:
            w.close()

    def test_the_judges_unit_tests_get_the_store(self):
        # test_video_judge_classes.py reads its real film from the store the run judges (JUDGE_GOLDENS_STORE).
        with tempfile.TemporaryDirectory() as tmp:
            judges = Path(tmp) / "judges"
            judges.mkdir()
            (judges / "test_video_judge.py").write_text(textwrap.dedent(f'''
                import os, unittest
                class T(unittest.TestCase):
                    def test_store(self):
                        self.assertEqual(os.environ.get("JUDGE_GOLDENS_STORE"), {str(Path(tmp) / "store")!r})
                if __name__ == "__main__":
                    unittest.main()
                '''))
            ran, failed, skipped, _ = jg.unit_tests(judges, store=Path(tmp) / "store")
            self.assertEqual((ran, failed, skipped), (1, 0, 0))
        real = (HERE / "test_video_judge_classes.py").read_text()
        self.assertIn("JUDGE_GOLDENS_STORE", real)
        # r4, the round the test always read (the store's copy has the same bytes as the scratch folder it read).
        self.assertIn('"pt-feat-5851715-b-120x1" / "bv-dt-bottom-light-dark-r4"', real)


class SixthReviewTests(unittest.TestCase):
    """Review 6 of #33930 at f971818773c (FIX, comment 6624684656). A: one store serves every manifest: a run does not
    refuse another manifest's folders, and a snapshot never replaces a stored file. B: an absence holds only where its
    own check looked, for 5 more names (judge_trace reverse, lurch and end-jump on an edge that travelled; video_judge
    divider not shown with trace samples; jump back against a drag). Notes: tests for needs that no test held, a fact
    of an absence that can never be checked is refused before judging, and other fields that are not text."""

    verdict = staticmethod(FifthReviewTests.verdict)
    JUDGED = FifthReviewTests.JUDGED

    def result(self, findings=(), **fields):
        r = dict(self.JUDGED, findings=list(findings))
        r.update(fields)
        return r

    # -- A: two manifests on one store --
    @staticmethod
    def cli(w, manifest, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = jg.guarded_main([args[0], "--store", str(w.store), "--manifest", str(manifest), *args[1:]])
        return code, out.getvalue() + err.getvalue()

    def test_another_manifests_folder_does_not_stop_a_run(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            other_gallery, other = w.root / "gallery-b", w.root / "manifest-b"
            base.write_film(other_gallery / "build-b-120x2", "row-drag", frames=6)
            code, out = self.cli(w, other, "snapshot", "--source", str(other_gallery), "--settled-minutes", "0")
            self.assertEqual(code, 0, out)
            code, out = w.run()
            self.assertEqual(code, 0, out)
            self.assertIn("reproduced 12 of 12", out)
            self.assertIn("1 folder", out)
        finally:
            w.close()

    def test_a_snapshot_never_replaces_a_stored_file(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            self.assertEqual(w.bless()[0], 0)
            stored = w.store / "films" / "build-a-120x2" / "col-drag.meta.json"
            before = jg.sha256_file(stored)
            (w.gallery / "build-a-120x2" / "col-drag.meta.json").write_text(json.dumps({"start": {"scale": 3}}))
            code, out = self.cli(w, w.root / "manifest-b", "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("col-drag.meta.json", out)
            self.assertEqual(jg.sha256_file(stored), before)
            code, out = w.run()
            self.assertEqual(code, 0, out)
        finally:
            w.close()

    def test_a_snapshot_records_a_stored_identical_file_without_a_copy(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            stored = w.store / "films" / "build-a-120x2" / "col-drag.meta.json"
            inode = os.stat(stored).st_ino
            other = w.root / "manifest-b"
            code, out = self.cli(w, other, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 0, out)
            self.assertEqual(os.stat(stored).st_ino, inode)
            films_b = json.loads((other / "films.json").read_text())
            self.assertIn("col-drag.meta.json", jg.files_table(w.store, films_b)["build-a-120x2"])
        finally:
            w.close()

    # -- B: 5 more names --
    @staticmethod
    def trace(travel):
        motion = {"first_frame": 1, "last_frame": 9, "frames": 9, "panes_at_rest": ["a", "b"]}
        return {"motion": motion, "motions": [{"motion": motion, "travel": travel}], "defects": []}

    def test_reverse_lurch_and_end_jump_need_an_edge_that_travelled(self):
        for name in ("reverse", "lurch", "end-jump"):
            with self.subTest(name=name):
                self.assertIn("travelled", self.verdict(self.trace({}), {"judge": "judge_trace", "absent_kind": name}))
                self.assertEqual(self.verdict(self.trace({"a": {"right": 40.0}}), {"judge": "judge_trace", "absent_kind": name}),
                                 "holds")
        # dropped and off-grid look at every motion, travelled or not
        self.assertEqual(self.verdict(self.trace({}), {"judge": "judge_trace", "absent_kind": "dropped"}), "holds")

    def test_divider_not_shown_needs_the_trace(self):
        got = self.verdict(self.result(pacing={"trace": False}), {"absent_check": "divider not shown"})
        self.assertIn("no trace samples", got)

    def test_jump_back_needs_a_drag_the_judge_placed(self):
        # jump back's needs include "drag" (a HID drag in the pinned events.json that video_judge placed). Its absence
        # is refused before judging today (it also needs "moved", review 7); the drag need itself:
        self.assertIn("drag", jg.NAMES["video_judge"]["jump back"][1])
        shows = jg.NEEDS["drag"][1]
        placed = {"offset_s": 0.0}
        self.assertFalse(shows(self.result(hid_clock=placed), {"movie": False, "hid_drag": False}))
        self.assertFalse(shows(self.result(hid_clock={"offset_s": None}), {"movie": False, "hid_drag": True}))
        self.assertTrue(shows(self.result(hid_clock=placed), {"movie": False, "hid_drag": True}))

    def test_the_drag_is_read_from_the_films_pinned_events(self):
        import test_judge_goldens_truth as truth
        for drag, wanted in ((None, False), ("key", False), ("drag", True)):
            with self.subTest(drag=drag):
                w = truth.TruthWorkspace()
                try:
                    hid = [{"kind": drag, "t_sent": 100.0, "t_returned": 100.05, "args": {}}] if drag else []
                    (w.gallery / "px-build-120x2" / "px-keys.events.json").write_text(json.dumps({"hid": hid, "journal": []}))
                    self.assertEqual(w.snapshot()[0], 0)
                    films = json.loads((w.manifest / "films.json").read_text())
                    self.assertEqual(jg._film_hid_drag(w.store, films, "px-build-120x2/px-keys"), wanted)
                finally:
                    w.close()

    # -- notes --
    def test_movie_checks_need_the_trace_too(self):
        for name in ("blank pane", "flash", "content stretched", "reflow"):
            with self.subTest(name=name):
                got = self.verdict(self.result(pacing={"trace": False}), {"absent_check": name}, movie=True)
                self.assertIn("no trace samples", got)

    def test_pacing_blend_and_capture_checks_need_a_motion_window(self):
        for name in ("dropped frames", "idle refresh in motion", "half-pixel blend", "capture stall"):
            with self.subTest(name=name):
                self.assertIn("no motion window", self.verdict(self.result(motion=[]), {"absent_check": name}))

    def test_a_positive_check_needs_no_coverage(self):
        # A judge that did not look, and so missed it, fails a must-report fact; it is never NO VERDICT.
        reported = self.result([{"check": "jump", "severity": "defect", "frames": [3, 4], "t": [0, 0], "detail": "x"}],
                               tracked_dividers=0, motion=[])
        self.assertEqual(self.verdict(reported, {"check": "jump"}), "holds")
        self.assertTrue(self.verdict(self.result(pacing={"trace": False}, motion=[]),
                                     {"check": "divider not shown"}).startswith("fails"))
        self.assertTrue(self.verdict(self.trace({}), {"judge": "judge_trace", "kind": "lurch"}).startswith("fails"))

    def test_an_absence_that_can_never_be_checked_is_refused_before_judging(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth(expect=[{"judge": "video_judge", "absent_check": "frame gap during slow input"}])
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("truth.json has facts that cannot be checked", out)
            self.assertIn("px-keys-shell-band", out)
        finally:
            w.close()

    def test_a_film_id_or_ruler_value_that_is_not_text_or_a_number_is_no_verdict_that_names_the_fact(self):
        import test_judge_goldens_truth as truth
        for field, value in (("film", ["px-build-120x2/px-keys"]), ("id", ["x"]), ("min_run_px", [8])):
            with self.subTest(field=field):
                w = truth.TruthWorkspace()
                try:
                    w.write_truth()
                    path = w.manifest / "truth.json"
                    doc = json.loads(path.read_text())
                    fact = doc["facts"][0]
                    if field == "min_run_px":
                        fact["ruler"]["min_run_px"] = value
                    else:
                        fact[field] = value
                    path.write_text(json.dumps(doc))
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertNotIn("the runner failed", out)
                    self.assertIn("truth.json has facts that cannot be checked", out)  # refused before judging
                finally:
                    w.close()


class SeventhReviewTests(unittest.TestCase):
    """Review 7 of #33930 at 029604eea31 (FIX, comment 6625895023). A: an absence of jump, jump back or jump back
    (animation) needs a tracked divider that moved, which no result shows: refused before judging. B: no unpinned file
    decides a result: snapshot plans each folder against what the store holds (whatever its manifest records), the
    TRUTH ruler reads only pinned files, a judge in its sealed view never sees an unpinned file, and the drag need reads
    only a pinned events.json. Notes: tests for the ruler's at and class types and the TypeError catch; a drag entry
    with no times; judge_trace motions of one frame; a ruler that is no object; two snapshots at the same time."""

    verdict = staticmethod(FifthReviewTests.verdict)
    cli = staticmethod(SixthReviewTests.cli)

    def truth_workspace(self, expect=None, **kw):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace(**kw)
        if expect is not None:
            w.write_truth(expect=expect)
        return w

    # -- A --
    def test_an_absence_of_a_step_check_is_refused_before_judging(self):
        for name in ("jump", "jump back", "jump back (animation)"):
            with self.subTest(name=name):
                w = self.truth_workspace([{"judge": "video_judge", "absent_check": name}])
                try:
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertIn("truth.json has facts that cannot be checked", out)
                    self.assertIn("moved", out)
                finally:
                    w.close()

    def test_a_positive_step_check_still_holds(self):
        reported = FifthReviewTests.result(FifthReviewTests(), [{"check": "jump", "severity": "defect", "frames": [3, 4],
                                                                 "t": [0, 0], "detail": "x"}])
        self.assertEqual(self.verdict(reported, {"check": "jump"}), "holds")

    # -- B --
    def test_snapshot_refuses_a_new_input_of_a_film_another_manifest_stores(self):
        w = self.truth_workspace()
        try:
            scan = w.gallery / "px-build-120x2" / "px-keys.mov.scan"
            data = scan.read_bytes()
            scan.unlink()  # manifest A stores px-keys without its scan
            self.assertEqual(w.snapshot()[0], 0)
            scan.write_bytes(data)  # the gallery gets the scan later
            code, out = self.cli(w, w.root / "manifest-b", "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("px-keys.mov.scan", out)
            self.assertFalse((w.store / "films" / "px-build-120x2" / "px-keys.mov.scan").exists())
        finally:
            w.close()

    def test_the_ruler_reads_only_pinned_files(self):
        w = self.truth_workspace()
        try:
            w.write_truth()
            scan = w.gallery / "px-build-120x2" / "px-keys.mov.scan"
            data = scan.read_bytes()
            scan.unlink()
            self.assertEqual(w.snapshot()[0], 0)
            folder = w.store / "films" / "px-build-120x2"
            os.chmod(folder, 0o755)
            (folder / "px-keys.mov.scan").write_bytes(data)  # in the store, not pinned
            os.chmod(folder, 0o555)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("pinned", out)
        finally:
            w.close()

    def test_a_judge_never_sees_an_unpinned_file_of_its_folder(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            folder = w.store / "films" / "build-a-120x2"
            os.chmod(folder, 0o755)
            (folder / "col-drag.extra.json").write_text("{}")  # a file of a pinned film that the table does not pin
            os.chmod(folder, 0o555)
            lister = base.write_judges(w.root / "judges-lister", keys=textwrap.dedent('''
                import os
                def judge(base):
                    return {"folder": sorted(os.listdir(os.path.dirname(base)))}
                '''))
            self.assertEqual(w.cli("bless", "--judges", str(lister), "--reason", "t", "--jobs", "2", "--no-git-check")[0], 0)
            expected = json.loads((w.manifest / "expected.json").read_text())
            seen = jg.load_expected(w.store, expected["films"]["build-a-120x2/col-drag"]["judge_keys"]["sha256"])
            self.assertNotIn("col-drag.extra.json", seen["folder"])
        finally:
            w.close()

    def test_the_drag_need_reads_only_a_pinned_events_json(self):
        import test_judge_goldens_truth as truth
        stub = truth.video_stub().replace('"motion": [{"a": 0, "b": 8}],', '"motion": [{"a": 0, "b": 8}], '
                                          '"hid_clock": {"offset_s": 0.0},')
        w = self.truth_workspace([{"judge": "video_judge", "absent_check": "divider not shown"}], video=stub)
        try:
            events = w.gallery / "px-build-120x2" / "px-keys.events.json"
            events.unlink()  # not pinned
            self.assertEqual(w.snapshot()[0], 0)
            folder = w.store / "films" / "px-build-120x2"
            os.chmod(folder, 0o755)
            (folder / "px-keys.events.json").write_text(json.dumps({"hid": [{"kind": "drag", "t_sent": 100.0,
                                                                              "t_returned": 100.05}], "journal": []}))
            os.chmod(folder, 0o555)
            self.assertFalse(jg._film_hid_drag(w.store, json.loads((w.manifest / "films.json").read_text()),
                                               "px-build-120x2/px-keys"))
        finally:
            w.close()

    # -- notes --
    def test_a_ruler_at_class_or_shape_of_the_wrong_type_is_refused(self):
        for field, value in (("at", 10.5), ("class", 16711935), ("ruler", ["row", 10])):
            with self.subTest(field=field):
                w = self.truth_workspace()
                try:
                    w.write_truth()
                    path = w.manifest / "truth.json"
                    doc = json.loads(path.read_text())
                    if field == "ruler":
                        doc["facts"][0]["ruler"] = value
                    else:
                        doc["facts"][0]["ruler"][field] = value
                    path.write_text(json.dumps(doc))
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertNotIn("the runner failed", out)
                    self.assertIn("truth.json has facts that cannot be checked", out)
                finally:
                    w.close()

    def test_a_ruler_that_raises_a_type_error_is_no_verdict_naming_the_fact(self):
        w = self.truth_workspace()
        real = jg.ruler_check
        try:
            w.write_truth()
            self.assertEqual(w.snapshot()[0], 0)

            def broken(base, fact):
                raise TypeError("a value of another type")

            jg.ruler_check = broken
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertNotIn("the runner failed", out)
            self.assertIn("px-keys-shell-band", out)
        finally:
            jg.ruler_check = real
            w.close()

    def test_a_drag_entry_with_no_times_is_no_drag(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "e.json"
            path.write_text(json.dumps({"hid": [{"kind": "drag", "args": {}}], "journal": []}))
            self.assertFalse(jg._has_hid_drag(path))
            path.write_text(json.dumps({"hid": [{"kind": "drag", "t_sent": 1.0, "t_returned": 1.1}], "journal": []}))
            self.assertTrue(jg._has_hid_drag(path))

    def test_a_judge_trace_motion_of_one_frame_has_not_travelled(self):
        def trace(frames):
            motion = {"first_frame": 1, "last_frame": frames, "frames": frames, "panes_at_rest": ["a", "b"]}
            return {"motion": motion, "motions": [{"motion": motion, "travel": {"a": {"right": 40.0}}}], "defects": []}

        self.assertIn("travelled", self.verdict(trace(1), {"judge": "judge_trace", "absent_kind": "lurch"}))
        self.assertEqual(self.verdict(trace(2), {"judge": "judge_trace", "absent_kind": "lurch"}), "holds")

    def test_a_stored_file_that_appears_while_copying_is_not_replaced(self):
        # Two snapshots at the same time: the second's file must not replace the first's.
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            src = w.root / "gallery-c" / "build-c-120x2"
            base.write_film(src.parent / "build-c-120x2", "row-drag", frames=6)
            films = w.store / "films"
            folder = films / "build-c-120x2"
            take = {n: [p.stat().st_size, jg.sha256_file(p)] for n, p in ((p.name, p) for p in src.iterdir())
                    if n.endswith(jg.KEEP_SUFFIXES)}
            os.chmod(films, 0o755)
            folder.mkdir()
            (folder / "row-drag.meta.json").write_text("{\"other\": 1}")  # the other snapshot's, other bytes
            problems = jg.copy_folder(src.parent, w.store, "build-c-120x2", take)
            self.assertTrue(problems)
            self.assertEqual((folder / "row-drag.meta.json").read_text(), "{\"other\": 1}")
            self.assertFalse([p.name for p in folder.iterdir() if p.name.startswith(".")])  # no part file left
        finally:
            w.close()

    def test_bless_counts_the_other_files_and_a_nested_folder_is_no_extra(self):
        w = base.Workspace()
        try:
            base.write_film(w.gallery / "build-n" / "nested-120x2", "deep", frames=5)
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            self.assertNotIn("the store also holds", out)
            films = w.store / "films"
            os.chmod(films, 0o755)
            (films / "diag-tiers.json").write_text("{}")
            os.chmod(films, 0o555)
            code, out = w.bless()
            self.assertEqual(code, 0, out)
            self.assertIn("0 folder(s) and 1 file(s)", out)
        finally:
            w.close()


class NinthReviewTests(unittest.TestCase):
    """Review 9 of #33930 at d9c319fc23f (FIX, comment 6630483631). A: no test held that a snapshot keeps the store's
    lock while it works. Notes: a killed snapshot left a folder no later snapshot could complete (1); an empty or null
    `expect` (2); a new film name with a dot, or named as a folder file (3); a KeyboardInterrupt in the link loop (5)."""

    cli = staticmethod(SixthReviewTests.cli)

    def test_the_snapshot_holds_the_lock_while_it_copies(self):
        import fcntl
        import threading
        w = base.Workspace()
        copying, go, result = threading.Event(), threading.Event(), {}
        real = jg.copy_reflink

        def slow_copy(src, dst):
            copying.set()
            go.wait(30)
            return real(src, dst)

        def snapshot():
            result["code"], result["out"] = w.snapshot()

        try:
            jg.copy_reflink = slow_copy
            t = threading.Thread(target=snapshot)
            t.start()
            self.assertTrue(copying.wait(30), "the snapshot never started copying")
            with open(w.store / jg.STORE_LOCK, "a") as other:
                try:
                    fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)  # even a shared lock: the snapshot's is exclusive
                    held = False
                    fcntl.flock(other, fcntl.LOCK_UN)
                except BlockingIOError:
                    held = True
            go.set()
            t.join(60)
            self.assertTrue(held, "another holder took the store's lock while the snapshot copied")
            self.assertEqual(result.get("code"), 0, result.get("out"))
        finally:
            go.set()
            jg.copy_reflink = real
            w.close()

    def test_a_killed_snapshot_leaves_a_store_the_next_snapshot_completes(self):
        # SIGTERM (what timeout, a sandbox stop or a tool timeout sends) at the 2nd link: no finally runs; the next
        # snapshot completes and pins every file of the folder
        import signal
        for name in ("SIGTERM", "SIGKILL"):
            with self.subTest(signal=name):
                w = base.Workspace()
                try:
                    child = w.root / "child.py"
                    child.write_text(textwrap.dedent(f"""
                        import os, signal, sys
                        sys.path.insert(0, {str(HERE)!r})
                        import judge_goldens as jg
                        real, calls = os.link, []
                        def link(src, dst, *a, **k):
                            calls.append(dst)
                            if len(calls) == 2:
                                os.kill(os.getpid(), signal.{name})
                            return real(src, dst, *a, **k)
                        jg.os.link = link
                        sys.exit(jg.guarded_main(["snapshot", "--store", {str(w.store)!r}, "--manifest",
                                                  {str(w.manifest)!r}, "--source", {str(w.gallery)!r},
                                                  "--settled-minutes", "0"]))
                        """))
                    done = subprocess.run([sys.executable, "-I", str(child)], capture_output=True, text=True, timeout=120)
                    self.assertEqual(done.returncode, -getattr(signal, name), done.stdout + done.stderr)
                    code, out = w.snapshot()
                    self.assertEqual(code, 0, out)
                    doc = json.loads((w.manifest / "films.json").read_text())
                    table = jg.files_table(w.store, doc)
                    for folder in ("build-a-120x2", "build-b-120x1"):
                        on_disk = sorted(p.name for p in (w.gallery / folder).iterdir() if p.name.endswith(jg.KEEP_SUFFIXES))
                        self.assertEqual(sorted(table.get(folder, {})), on_disk, out)
                finally:
                    for d, _, _ in os.walk(w.root):
                        os.chmod(d, 0o755)
                    w.close()

    def test_an_empty_or_null_expect_is_refused(self):
        import test_judge_goldens_truth as truth
        for value in (None, {}, [], "", 0, False):
            with self.subTest(expect=value):
                w = truth.TruthWorkspace()
                try:
                    w.write_truth()
                    path = w.manifest / "truth.json"
                    doc = json.loads(path.read_text())
                    doc["facts"][0]["expect"] = value
                    path.write_text(json.dumps(doc))
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertIn("truth.json has facts that cannot be checked", out)
                finally:
                    w.close()

    def test_a_new_film_name_with_a_dot_is_refused(self):
        # a film name is the part of its files' names before the first dot: row.v2 would make row.v2.* files of row
        w = base.Workspace()
        try:
            (w.gallery / "build-a-120x2" / "row.v2.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/row.v2: a film name with a dot", out)
            self.assertFalse((w.store / "films" / "build-a-120x2" / "row.v2.trace.json").exists())
        finally:
            w.close()

    def test_a_new_film_named_as_a_folder_file_is_refused(self):
        # display.json and diag-tiers.json are inputs of every film of the folder: no film may bring one in
        for name in ("display", "diag-tiers"):
            with self.subTest(film=name):
                w = base.Workspace()
                try:
                    folder = w.gallery / "build-b-120x1"
                    (folder / f"{name}.json").unlink(missing_ok=True)
                    self.assertEqual(w.snapshot()[0], 0)
                    (folder / f"{name}.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
                    (folder / f"{name}.json").write_text(json.dumps({"asked": {"scale": 1}}))
                    code, out = w.snapshot()
                    self.assertEqual(code, 2, out)
                    self.assertIn(f"build-b-120x1/{name}: a film named as a file of the folder", out)
                    self.assertFalse((w.store / "films" / "build-b-120x1" / f"{name}.json").exists())
                finally:
                    w.close()

    def test_an_interrupt_inside_the_link_loop_leaves_no_partly_stored_film(self):
        w = base.Workspace()
        real = os.link
        calls = []
        try:
            def interrupted(src, dst, *a, **k):
                calls.append(dst)
                if len(calls) == 3:
                    raise KeyboardInterrupt
                return real(src, dst, *a, **k)

            os.link = interrupted
            try:
                code, out = w.snapshot()
                self.assertNotEqual(code, 0, out)  # guarded_main turns the interrupt into an exit status
            except KeyboardInterrupt:
                pass
            os.link = real
            self.assertEqual([p.name for p in (w.store / "films").rglob("*") if p.is_file() and not p.name.startswith(".")], [])
            code, out = w.snapshot()
            self.assertEqual(code, 0, out)
        finally:
            os.link = real
            w.close()


class TenthReviewTests(unittest.TestCase):
    """Review 10 of #33930 at 8b543fbed01 (SHIP, comment 6631822421), notes for the follow-up: a part file that a killed
    write left blocks every later write of the same result (1); no test held the lock while films.json is written (2);
    store_pins had no test of a table that does not hash to its name, or of a file another manifest's table pins (3); a
    stored file changed by hand went into a new manifest with its new bytes, two tables could pin one file with other
    bytes, and a film of an older runner's dotted name refused a new film with a wrong message (4); a film name with
    two dots (7)."""

    def test_a_part_file_a_killed_write_left_does_not_block_the_next_write(self):
        # put_content wrote <sha>.part, made it read-only, then renamed it; a kill between the two left a read-only part
        # file under the one name every later write of the same result used: PermissionError for ever after
        tmp = Path(tempfile.mkdtemp(prefix="judge-goldens-part-"))
        try:
            value = {"result": [1, 2, 3]}
            sha = hashlib.sha256(jg.canonical(value).encode()).hexdigest()
            left = tmp / f".{sha}.part"
            left.write_text("a write that was killed")
            os.chmod(left, 0o444)
            self.assertEqual(jg.put_content(tmp, value), sha)
            self.assertEqual(jg.get_content(tmp, sha), value)
        finally:
            for path in tmp.iterdir():
                os.chmod(path, 0o644)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_two_writes_of_one_result_at_once_both_succeed(self):
        # two blesses that write the same new result: the second's part file is not the first's
        import threading
        tmp = Path(tempfile.mkdtemp(prefix="judge-goldens-part-"))
        real_chmod, errors, entered, go = os.chmod, [], threading.Event(), threading.Event()
        value = {"result": "the same"}

        def chmod(path, mode, *a, **k):
            real_chmod(path, mode, *a, **k)
            if str(path).endswith(".part") and threading.current_thread().name == "first":
                entered.set()  # the first write holds a read-only part file until the second has written
                go.wait(30)

        def write(name):
            try:
                jg.put_content(tmp, value)
            except Exception as error:  # noqa: BLE001 (the test reports every failure of a write)
                errors.append((name, repr(error)))

        try:
            jg.os.chmod = chmod
            first = threading.Thread(target=write, args=("first",), name="first")
            first.start()
            self.assertTrue(entered.wait(30))
            write("second")
            go.set()
            first.join(30)
            self.assertEqual(errors, [])
            sha = hashlib.sha256(jg.canonical(value).encode()).hexdigest()
            self.assertEqual(jg.get_content(tmp, sha), value)
        finally:
            go.set()
            jg.os.chmod = real_chmod
            for path in tmp.iterdir():
                os.chmod(path, 0o644)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_the_snapshot_holds_the_lock_while_it_writes_the_manifest(self):
        # review 9 A held the lock only while the snapshot copied; a lock released before films.json is written lost a
        # film in the reviewer's probe (two snapshots of one manifest)
        import fcntl
        import threading
        w = base.Workspace()
        writing, go, result = threading.Event(), threading.Event(), {}
        real = jg.write_json

        def slow_write(path, value):
            if Path(path).name == "films.json":
                writing.set()
                go.wait(30)
            return real(path, value)

        def snapshot():
            result["code"], result["out"] = w.snapshot()

        try:
            jg.write_json = slow_write
            t = threading.Thread(target=snapshot)
            t.start()
            self.assertTrue(writing.wait(30), "the snapshot never wrote films.json")
            with open(w.store / jg.STORE_LOCK, "a") as other:
                try:
                    fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    held = False
                    fcntl.flock(other, fcntl.LOCK_UN)
                except BlockingIOError:
                    held = True
            go.set()
            t.join(60)
            self.assertTrue(held, "another holder took the store's lock while the snapshot wrote films.json")
            self.assertEqual(result.get("code"), 0, result.get("out"))
        finally:
            go.set()
            jg.write_json = real
            w.close()

    def test_a_table_that_does_not_hash_to_its_name_refuses_the_snapshot_and_writes_nothing(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            doc_before = (w.manifest / "films.json").read_text()
            table = next((w.store / "tables").glob("*.json"))
            os.chmod(table, 0o644)
            table.write_text(json.dumps({"folders": {}}))  # other bytes under the table's name
            base.write_film(w.gallery / "build-c-120x2", "new-film", frames=3)
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("does not hash to its name", out)
            self.assertEqual((w.manifest / "films.json").read_text(), doc_before)
            self.assertFalse((w.store / "films" / "build-c-120x2").exists())
        finally:
            w.close()

    def test_a_file_another_manifests_table_pins_decides_the_plan(self):
        # one store, two manifests: the second manifest's snapshot of a folder the first stored keeps the stored bytes
        # (no copy) and refuses other bytes under a stored name
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            second = w.root / "manifest-2"
            code, out = w.cli("snapshot", "--source", str(w.gallery), "--settled-minutes", "0")  # first manifest again
            self.assertEqual(code, 0, out)
            run = lambda: SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            code, out = run()
            self.assertEqual(code, 0, out)
            table2 = jg.files_table(w.store, json.loads((second / "films.json").read_text()))
            table1 = jg.files_table(w.store, json.loads((w.manifest / "films.json").read_text()))
            self.assertEqual(table2, table1)
            trace = w.gallery / "build-a-120x2" / "col-drag.trace.json"
            trace.write_text(trace.read_text().replace("[", "[ ", 1))  # other bytes under a name the first table pins
            code, out = run()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.trace.json: differs from the stored copy", out)
        finally:
            w.close()

    def test_a_stored_file_changed_by_hand_never_enters_a_new_manifest(self):
        # the second manifest recorded the stored file's bytes as they are on disk now, not as the table pinned them
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            stored = w.store / "films" / "build-a-120x2" / "col-drag.trace.json"
            src = w.gallery / "build-a-120x2" / "col-drag.trace.json"
            changed = stored.read_text().replace("[", "[ ", 1)
            os.chmod(stored.parent, 0o755)
            os.chmod(stored, 0o644)
            stored.write_text(changed)
            src.write_text(changed)  # the gallery has the same changed bytes: nothing but the table tells them apart
            second = w.root / "manifest-2"
            code, out = SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.trace.json: a table pins it, and the store's copy is changed or gone", out)
            doc = json.loads((second / "films.json").read_text()) if (second / "films.json").exists() else {}
            table = jg.files_table(w.store, doc) if doc.get("files_table") else {}
            self.assertNotIn("col-drag.trace.json", table.get("build-a-120x2", {}))
        finally:
            w.close()

    def test_two_tables_that_pin_one_file_with_other_bytes_refuse_the_snapshot(self):
        # only a hand edit makes two tables disagree (a stored file is never replaced): the store is not trusted then
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            jg.put_content(w.store / "tables", {"folders": {"build-a-120x2": {"col-drag.trace.json": [1, "0" * 64]}}})
            second = w.root / "manifest-2"
            code, out = SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("two files tables pin build-a-120x2/col-drag.trace.json with other bytes", out)
            self.assertFalse((second / "films.json").exists())
        finally:
            w.close()

    def test_a_pinned_film_deleted_by_hand_refuses_the_snapshot_and_no_table_pins_other_bytes(self):
        # review of #36011, finding 1: the disk check looked only at pinned files still on disk; a film deleted by hand let
        # another manifest store other bytes under the pinned name, and from then on every snapshot of every manifest
        # stopped on the two tables' conflict
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            folder = w.store / "films" / "build-a-120x2"
            os.chmod(folder, 0o755)
            for path in sorted(folder.glob("col-drag.*")):
                path.unlink()
            os.chmod(folder, 0o555)
            trace = w.gallery / "build-a-120x2" / "col-drag.trace.json"
            trace.write_text(trace.read_text().replace("[", "[ ", 1))
            second = w.root / "manifest-2"
            code, out = SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.trace.json: a table pins it, and the store's copy is changed or gone", out)
            self.assertEqual(w.snapshot()[0], 2)  # the first manifest's snapshot refuses the same folder, never a crash
            pins = jg.store_pins(w.store)  # no two tables pin one name with other bytes
            self.assertNotEqual(pins["build-a-120x2"]["col-drag.trace.json"][1], jg.sha256_file(trace))
        finally:
            w.close()

    def test_another_manifests_pin_decides_the_plan_of_a_first_snapshot(self):
        # finding 2: the gallery changes before the second manifest's FIRST snapshot, so only the first manifest's table
        # can refuse it in the plan (a store_pins that returned nothing let the changed bytes through)
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            trace = w.gallery / "build-a-120x2" / "col-drag.trace.json"
            trace.write_text(trace.read_text().replace("[", "[ ", 1))
            second = w.root / "manifest-2"
            code, out = SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.trace.json: differs from the stored copy", out)
        finally:
            w.close()

    def test_another_manifests_table_that_does_not_hash_to_its_name_refuses(self):
        # finding 2: store_pins' own hash check (the changed table is the first manifest's; the snapshot is the second's)
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            sha = json.loads((w.manifest / "films.json").read_text())["files_table"]
            path = w.store / "tables" / f"{sha}.json"
            doc = json.loads(path.read_text())
            doc["folders"]["build-a-120x2"]["col-drag.trace.json"][0] += 1
            os.chmod(path, 0o644)
            path.write_text(jg.canonical(doc))
            second = w.root / "manifest-2"
            code, out = SixthReviewTests.cli(w, second, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 2, out)
            self.assertIn("does not hash to its name", out)
            self.assertFalse((second / "films.json").exists())
        finally:
            w.close()

    def test_a_retry_after_a_failed_write_in_the_same_thread_succeeds(self):
        # finding 4: a write that failed between chmod and the rename leaves its read-only part file; the same thread's
        # next write of the same result needs a part name of its own (the clock in the name)
        tmp = Path(tempfile.mkdtemp(prefix="judge-goldens-part-"))
        real_replace, calls = os.replace, []
        value = {"result": "retry"}

        def replace(src, dst, *a, **k):
            calls.append(src)
            if len(calls) == 1:
                raise OSError(28, "No space left on device")
            return real_replace(src, dst, *a, **k)

        try:
            jg.os.replace = replace
            with self.assertRaises(OSError):
                jg.put_content(tmp, value)
            sha = jg.put_content(tmp, value)
            self.assertEqual(jg.get_content(tmp, sha), value)
            self.assertNotEqual(str(calls[0]), str(calls[1]))
        finally:
            jg.os.replace = real_replace
            for path in tmp.iterdir():
                os.chmod(path, 0o644)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_a_dotted_film_of_an_older_runner_names_itself_when_it_refuses_a_new_film(self):
        # an older runner stored row.v2.* (a dotted film name, refused since review 9): by the first-dot rule its files
        # are film row's, so a new film row is refused as a new input of row; the message names the stored files
        w = base.Workspace()
        try:
            folder = w.gallery / "build-a-120x2"
            (folder / "row.v2.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            real = jg.plan_folder

            def older_runner(source, folder_name, recorded, names):  # no dotted-name refusal
                take, keep, problems = real(source, folder_name, recorded, [n for n in names if "." not in n])
                for n in names:
                    if "." in n:
                        for path in sorted((Path(source) / folder_name).glob(n + ".*")):
                            take[path.name] = [path.stat().st_size, jg.sha256_file(path)]
                return take, keep, problems

            jg.plan_folder = older_runner
            try:
                self.assertEqual(w.snapshot()[0], 0)
            finally:
                jg.plan_folder = real
            (folder / "row.v2.trace.json").unlink()
            (folder / "row.trace.json").write_text(json.dumps({"t0_s": 2.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/row.trace.json: a new input of the stored film row (stored as row.v2.trace.json", out)
        finally:
            w.close()

    def test_a_new_film_name_with_two_dots_is_refused(self):
        w = base.Workspace()
        try:
            (w.gallery / "build-a-120x2" / "row.v2.x.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/row.v2.x: a film name with a dot", out)
        finally:
            w.close()


class EighthReviewTests(unittest.TestCase):
    """Review 8 of #33930 at a116b2ab95d (FIX, comment 6627130937). A: two guards that the jump rule hid (fixed in the
    tests above: their own words). Notes: a failure inside the link loop leaves no partly stored film; one snapshot at a
    time (a lock on the store); a dotted film name brings in no stored film's input; an empty ruler is a ruler of no
    form; the ruler needs the pinned frames.json too; the copy removes every file it linked when it fails."""

    cli = staticmethod(SixthReviewTests.cli)

    def test_a_failure_inside_the_link_loop_leaves_no_partly_stored_film(self):
        w = base.Workspace()
        real = os.link
        calls = []
        try:
            def failing(src, dst, *a, **k):
                calls.append(dst)
                if len(calls) == 3:  # two files of the folder are linked by then: both must go
                    raise PermissionError(13, "Permission denied", str(dst))
                return real(src, dst, *a, **k)

            os.link = failing
            code, out = w.snapshot()
            os.link = real
            self.assertNotEqual(code, 0, out)
            self.assertEqual([p.name for p in (w.store / "films").rglob("*") if p.is_file()], [], out)
            code, out = w.snapshot()  # no fault now: it completes
            self.assertEqual(code, 0, out)
        finally:
            os.link = real
            w.close()

    def test_one_snapshot_at_a_time(self):
        import fcntl
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            lock = w.store / jg.STORE_LOCK
            with open(lock, "a") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                code, out = self.cli(w, w.root / "manifest-b", "snapshot", "--source", str(w.gallery),
                                     "--settled-minutes", "0", "--lock-seconds", "1")
                self.assertEqual(code, 2, out)
                self.assertIn("another snapshot", out)
            code, out = self.cli(w, w.root / "manifest-b", "snapshot", "--source", str(w.gallery), "--settled-minutes", "0")
            self.assertEqual(code, 0, out)
        finally:
            w.close()

    def test_a_dotted_film_name_brings_in_no_stored_films_input(self):
        w = base.Workspace()
        try:
            events = w.gallery / "build-a-120x2" / "col-drag.events.json"
            data = events.read_bytes()
            events.unlink()
            self.assertEqual(w.snapshot()[0], 0)
            events.write_bytes(data)
            # a new film "col-drag.events" whose trace makes col-drag.events.json look like its own file
            (w.gallery / "build-a-120x2" / "col-drag.events.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.events: a film name with a dot", out)
            self.assertFalse((w.store / "films" / "build-a-120x2" / "col-drag.events.json").exists())
        finally:
            w.close()

    def test_an_empty_ruler_is_a_ruler_of_no_form(self):
        import test_judge_goldens_truth as truth
        for value in ({}, [], "", 0, False):
            with self.subTest(ruler=value):
                w = truth.TruthWorkspace()
                try:
                    w.write_truth()
                    path = w.manifest / "truth.json"
                    doc = json.loads(path.read_text())
                    doc["facts"][0]["ruler"] = value
                    path.write_text(json.dumps(doc))
                    self.assertEqual(w.snapshot()[0], 0)
                    code, out = w.bless()
                    self.assertEqual(code, 2, out)
                    self.assertIn("truth.json has facts that cannot be checked", out)
                finally:
                    w.close()

    def test_a_null_ruler_is_refused_too(self):
        # "ruler": null is no ruler of any form either; before, a fact with expectations and a null ruler was
        # judged as if it had none (the null hid the mistake of a ruler left out)
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth()
            path = w.manifest / "truth.json"
            doc = json.loads(path.read_text())
            doc["facts"][0]["ruler"] = None
            path.write_text(json.dumps(doc))
            self.assertEqual(w.snapshot()[0], 0)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("truth.json has facts that cannot be checked", out)
        finally:
            w.close()

    def test_two_new_films_of_one_snapshot_clash_too(self):
        # nothing stored yet: "col-drag" and "col-drag.events" are both new in the first snapshot
        w = base.Workspace()
        try:
            (w.gallery / "build-a-120x2" / "col-drag.events.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.events: a film name with a dot", out)
        finally:
            w.close()

    def test_a_stored_film_gone_from_the_gallery_still_clashes(self):
        # col-drag is stored without col-drag.events.json; then its film files leave the gallery (the gallery no longer
        # names col-drag) and col-drag.events.json comes back with a new film col-drag.events. Only the stored name
        # col-drag tells that col-drag.events.json is col-drag's input: the new film must not take it
        w = base.Workspace()
        try:
            folder = w.gallery / "build-a-120x2"
            events = folder / "col-drag.events.json"
            data = events.read_bytes()
            events.unlink()
            self.assertEqual(w.snapshot()[0], 0)
            for suffix in jg.FILM_SUFFIXES:
                if (folder / f"col-drag{suffix}").exists():
                    (folder / f"col-drag{suffix}").unlink()
            self.assertNotIn("col-drag", jg.find_films(w.gallery)["build-a-120x2"])
            events.write_bytes(data)
            (folder / "col-drag.events.trace.json").write_text(json.dumps({"t0_s": 1.0, "samples": []}))
            code, out = w.snapshot()
            self.assertEqual(code, 2, out)
            self.assertIn("build-a-120x2/col-drag.events: a film name with a dot", out)
            self.assertFalse((w.store / "films" / "build-a-120x2" / "col-drag.events.json").exists())
        finally:
            w.close()

    def test_a_snapshot_waits_for_the_lock(self):
        # another snapshot holds the lock for 0.6 s: this one waits for it, then completes
        import fcntl
        import threading
        import time
        w = base.Workspace()
        try:
            w.store.mkdir(parents=True, exist_ok=True)
            held = open(w.store / jg.STORE_LOCK, "a")
            fcntl.flock(held, fcntl.LOCK_EX)
            release = threading.Timer(0.6, lambda: (fcntl.flock(held, fcntl.LOCK_UN), held.close()))
            release.start()
            started = time.monotonic()
            code, out = self.cli(w, w.manifest, "snapshot", "--source", str(w.gallery), "--settled-minutes", "0",
                                 "--lock-seconds", "30")
            release.join()
            self.assertEqual(code, 0, out)
            self.assertGreaterEqual(time.monotonic() - started, 0.5)
        finally:
            w.close()

    def test_a_part_file_of_a_snapshot_is_no_extra(self):
        # a dot file (a snapshot's part file in progress) is not counted as another manifest's file; a plain extra is
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            doc = json.loads((w.manifest / "films.json").read_text())
            folder = w.store / "films" / "build-a-120x2"
            os.chmod(folder, 0o755)
            (folder / ".col-drag.trace.json.part").write_text("{}")
            self.assertEqual(jg.store_extras(w.store, doc), (0, 0))
            (folder / "other.trace.json").write_text("{}")
            self.assertEqual(jg.store_extras(w.store, doc), (0, 1))
        finally:
            w.close()

    def test_the_ruler_needs_the_pinned_frames_too(self):
        import test_judge_goldens_truth as truth
        w = truth.TruthWorkspace()
        try:
            w.write_truth(expect=[{"judge": "judge_trace", "absent_kind": "dropped"}])  # no video_judge: no frames.json
            frames = w.gallery / "px-build-120x2" / "px-keys.mov.frames.json"
            data = frames.read_bytes()
            frames.unlink()
            self.assertEqual(w.snapshot()[0], 0)
            folder = w.store / "films" / "px-build-120x2"
            os.chmod(folder, 0o755)
            (folder / "px-keys.mov.frames.json").write_bytes(data)
            os.chmod(folder, 0o555)
            code, out = w.bless()
            self.assertEqual(code, 2, out)
            self.assertIn("px-keys.mov.frames.json is not pinned", out)
        finally:
            w.close()

    def test_a_failed_copy_keeps_no_file_it_linked(self):
        w = base.Workspace()
        try:
            self.assertEqual(w.snapshot()[0], 0)
            src = w.root / "gallery-c" / "build-c-120x2"
            base.write_film(src.parent / "build-c-120x2", "row-drag", frames=6)
            films = w.store / "films"
            folder = films / "build-c-120x2"
            take = {p.name: [p.stat().st_size, jg.sha256_file(p)] for p in src.iterdir() if p.name.endswith(jg.KEEP_SUFFIXES)}
            os.chmod(films, 0o755)
            folder.mkdir()
            (folder / "row-drag.trace.json").write_text("{\"other\": 1}")  # another snapshot's, other bytes
            problems = jg.copy_folder(src.parent, w.store, "build-c-120x2", take)
            self.assertTrue(problems)
            self.assertEqual(sorted(p.name for p in folder.iterdir()), ["row-drag.trace.json"])
        finally:
            w.close()


if __name__ == "__main__":
    unittest.main()
