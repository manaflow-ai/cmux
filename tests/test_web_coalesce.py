#!/usr/bin/env python3
"""cmux-next-web.yml's coalesced push runs (scripts/ci/web_coalesce.py) and their bisect.

The decision (claude-sr2-coord, 2026-11-03): coalesce the push runs to the newest tip when (1) a run still starts
at least every 15 minutes of landings, (2) a red coalesced run bisects only its failing named tests over the commits
it skipped, so test_reds.py still names the first red commit and its pull request, and (3) the PR-time webview
verdict (react-apps-base-check) is unchanged.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/ci" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coalesce = load("web_coalesce", "web_coalesce.py")
test_reds = load("test_reds_for_coalesce", "test_reds.py")
WEB = ROOT / ".github/workflows/cmux-next-web.yml"
LINT = ROOT / ".github/workflows/cmux-next-web-lint.yml"
CI_WEB = ROOT / ".github/workflows/ci-web.yml"
A, B, C = "a" * 40, "b" * 40, "c" * 40


class WaitTests(unittest.TestCase):
    def test_a_push_with_no_last_covered_one_runs_at_once_from_its_own_base(self):
        self.assertEqual(coalesce.plan_wait(None, A, B, 1000.0, 900), (0.0, B))
        self.assertEqual(coalesce.plan_wait(None, A, "0" * 40, 1000.0, 900), (0.0, ""))

    def test_a_push_inside_the_window_waits_for_it_and_routes_from_the_last_covered_commit(self):
        last = {"sha": B, "started": 1000.0}
        self.assertEqual(coalesce.plan_wait(last, A, C, 1000.0 + 300, 900), (600.0, B))
        # Past the window: no wait, and still everything since the last covered commit.
        self.assertEqual(coalesce.plan_wait(last, A, C, 1000.0 + 1200, 900), (0.0, B))

    def test_a_rerun_of_the_covered_push_does_not_wait(self):
        self.assertEqual(coalesce.plan_wait({"sha": A, "started": 1000.0}, A, B, 1001.0, 900), (0.0, B))

    def test_wait_sleeps_records_the_push_and_outputs_its_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            last, out, output = Path(tmp, "last.json"), Path(tmp, "new/last.json"), Path(tmp, "output")
            last.write_text(json.dumps({"sha": B, "started": 1000.0}))
            slept = []
            clock = iter([1100.0, 1900.0])
            args = SimpleNamespace(off=False, hold_minutes=15, last=str(last), sha=A, before=C, out=str(out))
            os.environ["GITHUB_OUTPUT"] = str(output)
            try:
                with redirect_stdout(io.StringIO()):
                    coalesce.wait(args, sleep=slept.append, clock=lambda: next(clock))
            finally:
                del os.environ["GITHUB_OUTPUT"]
            self.assertEqual(slept, [800.0])
            self.assertEqual(json.loads(out.read_text()), {"sha": A, "started": 1900.0})
            self.assertEqual(output.read_text(), f"base={B}\n")

    def test_the_off_switch_never_waits(self):
        with tempfile.TemporaryDirectory() as tmp:
            last = Path(tmp, "last.json")
            last.write_text(json.dumps({"sha": B, "started": 1000.0}))
            slept = []
            args = SimpleNamespace(off=True, hold_minutes=15, last=str(last), sha=A, before=C,
                                   out=str(Path(tmp, "o.json")))
            with redirect_stdout(io.StringIO()):
                coalesce.wait(args, sleep=slept.append, clock=lambda: 1001.0)
            self.assertEqual(slept, [])

    def test_an_unreadable_marker_is_no_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp, "last.json")
            for text in ("", "{}", json.dumps({"sha": "x", "started": 1}), json.dumps({"sha": A, "started": True})):
                bad.write_text(text)
                self.assertIsNone(coalesce.read_last(str(bad)))


class SearchTests(unittest.TestCase):
    def probe_for(self, first_red: dict[str, int], calls: list):
        def probe(position, files):
            calls.append((position, tuple(files)))
            return {f: position >= first_red[f] for f in files}
        return probe

    def test_binary_search_finds_each_files_first_red_change(self):
        points = [2, 5, 6, 9, 11, 14]  # commits whose webview inputs changed; 14 is the head's
        calls = []
        found = coalesce.search(["x.test.ts", "y.test.ts"], points, True,
                                self.probe_for({"x.test.ts": 6, "y.test.ts": 11}, calls))
        self.assertEqual(found["x.test.ts"], ("first", 6, 5))
        self.assertEqual(found["y.test.ts"], ("first", 11, 10))
        self.assertLessEqual(len(calls), 5)  # 3 each, the first shared
        self.assertNotIn(0, [p for p, _ in calls])  # BASE's verdict is recorded: never probed

    def test_one_changing_commit_needs_no_probe(self):
        calls = []
        found = coalesce.search(["x.test.ts"], [4], True, self.probe_for({"x.test.ts": 4}, calls))
        self.assertEqual(found["x.test.ts"], ("first", 4, 3))
        self.assertEqual(calls, [])

    def test_a_red_with_no_recorded_base_verdict_probes_the_base(self):
        calls = []
        found = coalesce.search(["x.test.ts"], [3], False, self.probe_for({"x.test.ts": 0}, calls))
        self.assertEqual(found["x.test.ts"], ("base", 0, 0))
        self.assertEqual(calls, [(0, ("x.test.ts",))])
        found = coalesce.search(["x.test.ts"], [3], False, self.probe_for({"x.test.ts": 3}, []))
        self.assertEqual(found["x.test.ts"], ("first", 3, 2))

    def test_out_of_probes_or_no_verdict_names_the_narrowest_range(self):
        points = list(range(1, 65))
        found = coalesce.search(["x.test.ts"], points, True, self.probe_for({"x.test.ts": 40}, []), max_probes=2)
        kind, lo, hi = found["x.test.ts"]
        self.assertEqual(kind, "unresolved")
        self.assertLess(lo, 40)
        self.assertGreaterEqual(hi, 40)
        found = coalesce.search(["x.test.ts"], [2, 5, 9], True, lambda p, f: {x: None for x in f})
        self.assertEqual(found["x.test.ts"], ("unresolved", 0, 9))


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class BisectTests(unittest.TestCase):
    """The whole bisect on a scratch repo: a probe stub stands in for the webview runner."""

    def commit(self, repo: Path, path: str, text: str, subject: str) -> str:
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(text)
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", subject)
        return git(repo, "rev-parse", "HEAD")

    def run_bisect(self, *, base_red=(), flaky_history=False, old_red_in_file=False):
        tmp = Path(self.tmp.name)
        repo = tmp / "repo"
        repo.mkdir()
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        base = self.commit(repo, "webviews/src/a.ts", "1\n", "base")
        self.commit(repo, "README.md", "docs\n", "docs only (#101)")
        self.commit(repo, "webviews/src/b.ts", "1\n", "unrelated web (#102)")
        culprit = self.commit(repo, "webviews/src/a.ts", "2\n", "break a (#103)")
        self.commit(repo, "Sources/x.swift", "x\n", "swift only (#104)")
        head = self.commit(repo, "webviews/src/c.ts", "1\n", "another web (#105)")
        # The probe stub: a.test.ts fails wherever a.ts says 2.
        probe = tmp / "probe.sh"
        probe.write_text("#!/usr/bin/env bash\nset -e\nsha=$1 out=$3\necho \"$sha\" >> \"$PROBED\"\n"
                         "if [ \"$(git show \"$sha:webviews/src/a.ts\")\" = 2 ]; then ok=false; else ok=true; fi\n"
                         "printf '{\"src/a.test.ts\": %s, \"src/a.test.ts > renders\": %s%s}\\n' \"$ok\" \"$ok\" "
                         "\"$OLD_RED\" > \"$out\"\n")
        results = tmp / "shard1.json"
        results.write_text(json.dumps({"src/a.test.ts": False, "src/a.test.ts > renders": False,
                                       "src/old.test.ts": False, "src/old.test.ts > stays red": False,
                                       "src/ok.test.ts": True,
                                       **({"src/a.test.ts > was red": False} if old_red_in_file else {})}))
        runs = [{"sha": base, "attempt": 1, "time": 1, "inputs": "k1",
                 "files": ["src/a.test.ts", "src/old.test.ts"], "red": ["src/old.test.ts > stays red", *base_red,
                         *(["src/a.test.ts > was red"] if old_red_in_file else [])]}]
        if flaky_history:
            runs += [{"sha": "d" * 40, "attempt": 1, "time": 0, "inputs": "k0", "files": ["src/a.test.ts"],
                      "red": ["src/a.test.ts > renders"]},
                     {"sha": "e" * 40, "attempt": 1, "time": 0.5, "inputs": "k0", "files": ["src/a.test.ts"],
                      "red": []}]
        history = tmp / "history.json"
        history.write_text(json.dumps({"runs": runs}))
        report = tmp / "out/report.json"
        probed = tmp / "probed"
        probed.touch()
        args = SimpleNamespace(base=base, head=head, results=[str(results)], history=str(history), probe=str(probe),
                               report=str(report), max_probes=coalesce.MAX_PROBES)
        here = os.getcwd()
        os.chdir(repo)
        os.environ["PROBED"] = str(probed)
        # Every probe also reports a test of the same file that was already red at BASE.
        os.environ["OLD_RED"] = ', "src/a.test.ts > was red": false' if old_red_in_file else ""
        try:
            with redirect_stdout(io.StringIO()) as printed:
                self.assertEqual(coalesce.bisect(args), 0)
        finally:
            os.chdir(here)
            del os.environ["PROBED"]
            del os.environ["OLD_RED"]
        return base, culprit, printed.getvalue(), probed.read_text().split(), json.loads(report.read_text())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_new_red_is_pinned_to_its_first_red_commit_and_pull_request(self):
        base, culprit, printed, probed, report = self.run_bisect()
        found = test_reds.bisect_report(printed)
        self.assertEqual(found["src/a.test.ts"]["kind"], "first")
        self.assertEqual(found["src/a.test.ts"]["first_red"], culprit)
        self.assertEqual(found["src/a.test.ts"]["pr"], 103)
        # Already red at the run before: not this range's, and never probed.
        self.assertEqual(found["src/old.test.ts"]["kind"], "base")
        # Only commits that changed webview inputs were candidates (3 of 5), and only the middle one was probed.
        self.assertLessEqual(len(probed), 2)
        self.assertNotIn(base, probed)
        self.assertEqual(report["lines"], [line for line in printed.splitlines() if line.startswith("web bisect: ")
                                           and "probing" not in line and "nothing" not in line])

    def test_a_test_already_red_at_the_base_in_the_same_file_does_not_move_the_first_red(self):
        _, culprit, printed, probed, _ = self.run_bisect(old_red_in_file=True)
        found = test_reds.bisect_report(printed)["src/a.test.ts"]
        self.assertEqual((found["kind"], found["first_red"], found["pr"]), ("first", culprit, 103))
        self.assertTrue(probed)

    def test_a_commit_routing_the_suite_through_the_bundle_inputs_is_a_candidate(self):
        bundle = lambda path: path == "Resources/settings-schema.json"  # noqa: E731
        self.assertTrue(coalesce.routes_webview_tests(["Resources/settings-schema.json"], bundle))
        self.assertFalse(coalesce.routes_webview_tests(["Resources/settings-schema.json"], None))
        self.assertFalse(coalesce.routes_webview_tests(["README.md", "Sources/x.swift"], bundle))
        self.assertTrue(coalesce.routes_webview_tests(["webviews/src/a.ts"], None))

    def test_a_test_that_flips_on_the_base_by_itself_is_not_bisected(self):
        _, _, printed, probed, _ = self.run_bisect(flaky_history=True)
        self.assertEqual(test_reds.bisect_report(printed)["src/a.test.ts"]["kind"], "flaky")
        self.assertEqual(probed, [])

    def test_a_red_already_red_at_the_base_is_not_bisected(self):
        _, _, printed, probed, _ = self.run_bisect(base_red=["src/a.test.ts > renders"])
        self.assertEqual(test_reds.bisect_report(printed)["src/a.test.ts"]["kind"], "base")
        self.assertEqual(probed, [])

    def test_no_base_means_nothing_to_bisect(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(base="", head=A, results=[], history=None, probe="x",
                                   report=str(Path(tmp, "r.json")), max_probes=1)
            with redirect_stdout(io.StringIO()) as printed:
                self.assertEqual(coalesce.bisect(args), 0)
            self.assertIn("nothing to bisect", printed.getvalue())
            self.assertEqual(test_reds.bisect_report(printed.getvalue()), {})


class ReportTests(unittest.TestCase):
    def test_every_line_kind_reads_back(self):
        log = "\n".join([
            f"2026-11-03T10:00:00.0000000Z web bisect: first red at {A} (#123) after {B}: src/x.test.ts (x > y)",
            f"2026-11-03T10:00:00.0000000Z web bisect: first red at {C} (a direct push) after {B}: src/d.test.ts",
            f"web bisect: red before the range at {B}: src/old.test.ts",
            "web bisect: flaky on the base: src/flaky.test.ts",
            f"web bisect: unresolved between {B} and {A}: src/wide.test.ts",
        ])
        found = test_reds.bisect_report(log)
        self.assertEqual(found["src/x.test.ts"], {"kind": "first", "first_red": A, "green": B, "pr": 123})
        self.assertEqual(found["src/d.test.ts"]["pr"], None)
        self.assertEqual(found["src/old.test.ts"]["kind"], "base")
        self.assertEqual(found["src/flaky.test.ts"]["kind"], "flaky")
        self.assertEqual(found["src/wide.test.ts"], {"kind": "unresolved", "first_red": A, "green": B, "pr": None})

    def test_the_runners_echo_of_the_step_is_never_read(self):
        echo = ("##[group]Run echo \"web bisect: flaky on the base: src/x.test.ts\"\n"
                "echo \"web bisect: flaky on the base: src/x.test.ts\"\nshell: /usr/bin/bash -e {0}\n##[endgroup]\n")
        self.assertEqual(test_reds.bisect_report(echo), {})


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.web = yaml.safe_load(WEB.read_text())
        self.lint = yaml.safe_load(LINT.read_text())

    def test_the_coalesce_job_waits_one_at_a_time_and_never_cancels_a_started_one(self):
        job = self.web["jobs"]["coalesce"]
        self.assertIs(job["concurrency"]["cancel-in-progress"], False)
        self.assertIn("'cmux-next-web-coalesce'", job["concurrency"]["group"])
        # A dispatch, another branch and the off switch get a group of their own.
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'",
                      job["concurrency"]["group"])
        self.assertIn("vars.CMUX_NEXT_WEB_COALESCE", job["concurrency"]["group"])
        self.assertIn("--hold-minutes 15", next(s for s in job["steps"] if s.get("id") == "wait")["run"])
        self.assertLessEqual(job["timeout-minutes"], 20)
        self.assertIs(self.web["concurrency"]["cancel-in-progress"], False)
        self.assertNotIn("cancel-in-progress: true", WEB.read_text())

    def test_the_marker_is_restored_from_and_saved_to_one_path(self):
        # Actions keys a cache's version by its path, so a save at another path is never restored, even by prefix.
        steps = self.web["jobs"]["coalesce"]["steps"]
        restore = next(s for s in steps if str(s.get("uses", "")).startswith("actions/cache/restore@"))
        save = next(s for s in steps if str(s.get("uses", "")).startswith("actions/cache/save@"))
        wait = next(s for s in steps if s.get("id") == "wait")["run"]
        self.assertEqual(restore["with"]["path"], save["with"]["path"])
        self.assertTrue(save["with"]["key"].startswith(restore["with"]["restore-keys"]))
        marker = restore["with"]["path"].replace("${{ runner.temp }}", "$RUNNER_TEMP")
        self.assertIn(f'--last "{marker}"', wait)
        self.assertIn(f'--out "{marker}"', wait)

    def test_the_web_checks_route_from_the_last_covered_commit(self):
        web = self.web["jobs"]["web"]
        self.assertEqual(web["needs"], "coalesce")
        self.assertEqual(web["with"]["push_base"], "${{ github.event_name == 'push' && needs.coalesce.outputs.base || '' }}")

    def test_the_bisect_runs_on_a_red_push_and_never_fails(self):
        job = self.web["jobs"]["web-bisect"]
        self.assertIn("needs.web.result == 'failure'", job["if"])
        self.assertIn("github.event_name == 'push'", job["if"])
        bisect = next(s for s in job["steps"] if s["name"] == "Bisect the new webview reds")
        self.assertIs(bisect["continue-on-error"], True)
        self.assertIn("web_coalesce.py\" bisect", bisect["run"])

    def test_web_lint_still_runs_on_every_push_in_its_own_workflow(self):
        on = self.lint.get("on", self.lint.get(True))
        self.assertEqual(on["push"]["branches"], ["feat-cmux-next"])
        self.assertIn("web-lint", self.lint["jobs"])
        self.assertEqual(self.lint["concurrency"]["group"], "cmux-next-web-lint-${{ github.sha }}")
        self.assertNotIn("web-lint", self.web["jobs"])
        self.assertNotIn("needs", self.lint["jobs"]["web-lint"])

    def test_the_pull_request_webview_verdict_is_untouched(self):
        # Condition 3: react-apps-base-check runs on pull requests only, from the head shards' own results.
        ci_web = yaml.safe_load(CI_WEB.read_text())
        base = ci_web["jobs"]["react-apps-base-check"]
        self.assertEqual(base["needs"], ["web-subarea-scope", "react-apps-check-shard"])
        self.assertTrue(base["if"].startswith("${{ github.event_name == 'pull_request'"))


if __name__ == "__main__":
    unittest.main()
