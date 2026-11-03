#!/usr/bin/env python3
"""The judge goldens runner gives the right CLASS of answer (review of #33930 at 83af04ed384, comment 6608121020).

    /work/tmp/bv-venv/bin/python -I scripts/journeys/test_judge_goldens_review.py

`run` exits 0 only when every result was reproduced, 1 only when a judge's result changed, and 2 (NO VERDICT) when the
run itself cannot say: a judge that does not finish, a judge_scan that times out or is killed, an out-of-memory or
an operating-system error, a store file the table does not pin (a judge reads only the pinned files: a sealed view),
a blessed result file that is gone or changed, or no film selected. A bless pins the runner it ran with, and refuses
an uncommitted runner as it refuses uncommitted judges.
"""
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
        looping = self.judges("judges-loop", keys="def judge(base):\n    while True:\n        pass\n")
        started = time.monotonic()
        code, out = run_cli(self.w, looping, "--film-seconds", "2")
        self.assertEqual(code, 2, out)
        self.assertIn("did not finish", out)
        self.assertLess(time.monotonic() - started, 60, out)

    def test_a_judge_that_catches_every_exception_still_ends_at_the_budget(self):
        stubborn = self.judges("judges-stubborn", keys=textwrap.dedent('''
            def judge(base):
                while True:
                    try:
                        while True:
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

    def test_a_file_the_table_does_not_pin_is_no_verdict(self):
        folder = self.w.store / "films" / "build-a-120x2"
        os.chmod(folder, 0o755)
        (folder / "display.json").write_text(json.dumps({"asked": {"scale": 3}}))
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("display.json", out)

    def test_a_file_beside_the_film_folders_is_no_verdict(self):
        films = self.w.store / "films"
        os.chmod(films, 0o755)
        (films / "diag-tiers.json").write_text("{}")
        code, out = self.w.run()
        self.assertEqual(code, 2, out)
        self.assertIn("diag-tiers.json", out)

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
        self.assert_no_verdict({"id": "typo", "film": "px-build-120x2/px-keys-typo", "why": "t",
                                "expect": [{"judge": "video_judge", "absent_check": "jump"}]}, "typo")

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


if __name__ == "__main__":
    unittest.main()
