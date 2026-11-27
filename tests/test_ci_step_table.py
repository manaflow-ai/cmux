#!/usr/bin/env python3
"""The step table (ci/steps.toml) and its runner (scripts/ci/ci_steps.py).

Leo, 2026-11-13: "Few jobs on warm trees; the PR runs what base runs on the tree that lands. 267 jobs
per PR become one step table and at most 8 jobs; a landing train tests the merge result (3.81 base
reds per 100 landings today). Advisory steps run idle-class and never block."

This test holds two things:

  - the table: at most 8 jobs, and a step that does not block runs in the `advisory` job, class `idle`;
  - the runner: an advisory step's failure or timeout is a warning and the job passes; a blocking
    step's failure fails it; a label event runs only the steps that list the label; `--only` runs the
    named subset, skips a name the table lacks with a notice, and runs every routed step when empty;
  - the workflows: pr-body-checks.yml and pr-checks.yml each run their own advisory steps from the base.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))
import ci_steps  # noqa: E402
import crate_results  # noqa: E402
from test_ci_post_merge_checks import BASE, branch_matches, load_workflows, triggers  # noqa: E402


def table(steps: str, jobs: str = 'linux = "l"\nadvisory = "a"') -> ci_steps.Table:
    import tomllib

    return ci_steps.parse(tomllib.loads(f"[jobs]\n{jobs}\n{textwrap.dedent(steps)}"))



# pr-pipeline.yml's heavy linux jobs run at the land tier (Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes
# of ci time, period."): tests/test_head_tier.py land_tier_condition and the label guard of
# tests/test_ci_label_events_skip_full_ci.py, exactly as #54886 put them on every gated workflow. The router (a
# workflow_call caller) passes its pull_request event through, so the same expression reads the same head.
PIPELINE_LAND_TIER_JOBS = ("linux", "web-browser", "ios", "mac")
PIPELINE_LAND_TIER = "(github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'full-ci') || (github.event.pull_request.draft == true && (vars.CI_DRAFT_CHEAP_TIER || '1') == '0') || (github.event.pull_request.draft != true && (contains(github.event.pull_request.labels.*.name, 'ready-to-land') || github.event.pull_request.base.ref != 'feat-cmux-next' || github.event.pull_request.head.repo.full_name != github.repository || (vars.CI_LAND_TIER || '1') == '0')))"
PIPELINE_LABEL_GUARD = '!(github.event_name == \'pull_request\' && github.event.pull_request.base.ref == \'feat-cmux-next\' && (github.event.action == \'labeled\' || github.event.action == \'unlabeled\') && !contains(fromJSON(\'["full-ci","ready-to-land"]\'), github.event.label.name))'

class TableRulesTest(unittest.TestCase):
    def test_the_repository_table_loads(self) -> None:
        t = ci_steps.load()
        self.assertLessEqual(len(t.jobs), ci_steps.MAX_JOBS)
        self.assertIn("advisory", t.jobs)
        for step in t.steps.values():
            if not step.blocks:
                self.assertEqual((step.job, step.klass), ("advisory", "idle"), step.name)

    def test_at_most_eight_jobs(self) -> None:
        jobs = "\n".join(f'j{i} = "x"' for i in range(9))
        with self.assertRaisesRegex(ci_steps.TableError, "at most 8"):
            table("", jobs)

    def test_an_advisory_step_runs_idle_in_the_advisory_job(self) -> None:
        with self.assertRaisesRegex(ci_steps.TableError, "does not block"):
            table('[step.a]\njob = "linux"\nblocks = false\nclass = "idle"\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "does not block"):
            table('[step.a]\njob = "advisory"\nblocks = false\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "holds only"):
            table('[step.a]\njob = "advisory"\nrun = "true"')

    def test_unknown_job_or_key(self) -> None:
        with self.assertRaisesRegex(ci_steps.TableError, "not one of"):
            table('[step.a]\njob = "mac"\nrun = "true"')
        with self.assertRaisesRegex(ci_steps.TableError, "unknown keys"):
            table('[step.a]\njob = "linux"\nrun = "true"\nblock = false')

    def test_route_by_inputs_and_label(self) -> None:
        t = table('''
            [step.web]
            job = "linux"
            inputs = ["webviews/**"]
            run = "true"
            [step.rust]
            job = "linux"
            inputs = ["cmux-tui/**/*.rs"]
            run = "true"
            [step.perf]
            job = "advisory"
            blocks = false
            class = "idle"
            labels = ["perf"]
            run = "true"
        ''')
        self.assertEqual(ci_steps.route(t, ["webviews/src/a.tsx"]), {"linux": ["web"], "advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, ["cmux-tui/src/main.rs"])["linux"], ["rust"])
        self.assertEqual(ci_steps.route(t, ["docs/x.md"]), {"advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, None)["linux"], ["web", "rust"], "an unknown diff routes every step")
        self.assertEqual(ci_steps.route(t, None, "perf"), {"advisory": ["perf"]})
        self.assertEqual(ci_steps.route(t, None, "risk:low"), {})

    def test_ignore_drops_paths_from_inputs(self) -> None:
        t = table('''
            [step.kit]
            job = "linux"
            inputs = ["cmux-next-ios/**"]
            ignore = ["cmux-next-ios/verify/**", "**/*.md", "!cmux-next-ios/**/Resources/**"]
            run = "true"
        ''')
        self.assertEqual(t.steps["kit"].ignore, ("cmux-next-ios/verify/**", "**/*.md", "!cmux-next-ios/**/Resources/**"))
        self.assertTrue(ci_steps.routed(t.steps["kit"], ["cmux-next-ios/Kit/Resources/notes.md"]), "the last match decides")
        self.assertTrue(ci_steps.routed(t.steps["kit"], ["cmux-next-ios/Sources/A.swift"]))
        self.assertFalse(ci_steps.routed(t.steps["kit"], ["cmux-next-ios/README.md"]))
        self.assertFalse(ci_steps.routed(t.steps["kit"], ["cmux-next-ios/verify/x.swift"]))
        self.assertTrue(ci_steps.routed(t.steps["kit"], ["cmux-next-ios/README.md", "cmux-next-ios/A.swift"]))
        self.assertTrue(ci_steps.routed(t.steps["kit"], None))
        for bad in ('inputs = ["a/**"]\nignore = ["/a"]', 'inputs = ["a/**"]\nignore = ["!a"]', 'ignore = ["a"]'):
            with self.subTest(bad=bad), self.assertRaisesRegex(ci_steps.TableError, "ignore"):
                table(f'[step.a]\njob = "linux"\n{bad}\nrun = "true"')


class RunnerTest(unittest.TestCase):
    def run_job(self, t: ci_steps.Table, job: str, label: str | None = None,
                only: list[str] | None = None) -> tuple[int, str]:
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        old = os.environ
        os.environ = env  # the summary goes nowhere
        try:
            code = ci_steps.run_job(t, job, None, label, out, only=only)
        finally:
            os.environ = old
        return code, out.getvalue()

    def test_an_advisory_failure_or_timeout_never_blocks(self) -> None:
        t = table('''
            [step.fails]
            job = "advisory"
            blocks = false
            class = "idle"
            title = "Fails"
            run = "echo before; exit 3"
            [step.hangs]
            job = "advisory"
            blocks = false
            class = "idle"
            timeout = 1
            run = "sleep 30"
            [step.passes]
            job = "advisory"
            blocks = false
            class = "idle"
            run = "echo fine"
        ''')
        code, out = self.run_job(t, "advisory")
        self.assertEqual(code, 0, out)
        self.assertIn("::warning title=Fails::step fails exited 3 (advisory: never blocks)", out)
        self.assertIn("step hangs ran past its 1 s (advisory: never blocks)", out)
        self.assertIn("before", out)
        self.assertIn("fine", out)
        self.assertNotIn("::error", out)

    def test_a_timed_out_step_whose_group_cannot_be_signalled_still_times_out(self) -> None:
        # macOS answers killpg with EPERM, not ESRCH, when each process left in the step's group is a zombie
        # (tests/test_ci_killpg_tolerates_eperm.py). The step ran past its timeout all the same: no exception,
        # code None, and what the step printed is read.
        step = table('[step.slow]\njob = "linux"\ntimeout = 1\nrun = "echo before; sleep 2"').steps["slow"]
        with mock.patch.object(ci_steps.os, "killpg", side_effect=PermissionError(1, "Operation not permitted")):
            result = ci_steps.run_step(step)
        self.assertIsNone(result.code)
        self.assertIn("before", result.output)

    def test_a_blocking_failure_fails_the_job(self) -> None:
        t = table('[step.a]\njob = "linux"\nrun = "false"\n[step.b]\njob = "linux"\nrun = "true"')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1)
        self.assertIn("::error title=a::step a exited 1", out)

    def test_bash_runs_strict(self) -> None:
        t = table('[step.a]\njob = "linux"\nrun = "false | true\\necho reached"')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1, "pipefail: a failed stage fails the step")
        self.assertNotIn("reached", out)

    def test_steps_run_at_once(self) -> None:
        steps = "".join(f'[step.s{i}]\njob = "linux"\nrun = "sleep 1"\n' for i in range(4))
        t = table(steps)
        start = __import__("time").monotonic()
        code, _ = self.run_job(t, "linux")
        self.assertEqual(code, 0)
        self.assertLess(__import__("time").monotonic() - start, 3.5)

    def test_a_label_event_runs_only_its_steps(self) -> None:
        t = table('''
            [step.perf]
            job = "advisory"
            blocks = false
            class = "idle"
            labels = ["perf"]
            run = "echo perf-ran"
            [step.other]
            job = "advisory"
            blocks = false
            class = "idle"
            run = "echo other-ran"
        ''')
        _, out = self.run_job(t, "advisory", "perf")
        self.assertIn("perf-ran", out)
        self.assertNotIn("other-ran", out)
        _, out = self.run_job(t, "advisory", "media-tour")
        self.assertIn("No step of job advisory", out)

    ONLY = '''
        [step.one]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo one-ran"
        [step.two]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo two-ran"
        [step.three]
        job = "advisory"
        blocks = false
        class = "idle"
        run = "echo three-ran"
    '''

    def test_only_runs_the_named_subset(self) -> None:
        t = table(self.ONLY)
        self.assertEqual(ci_steps.parse_only("one, three"), ["one", "three"])
        self.assertEqual(ci_steps.parse_only("one three\n"), ["one", "three"])
        code, out = self.run_job(t, "advisory", only=ci_steps.parse_only("one,three"))
        self.assertEqual(code, 0, out)
        self.assertIn("one-ran", out)
        self.assertIn("three-ran", out)
        self.assertNotIn("two-ran", out)

    def test_only_skips_a_name_the_table_lacks(self) -> None:
        # The pull request that adds a step runs against a base whose table lacks it: a notice, never an error.
        t = table(self.ONLY)
        code, out = self.run_job(t, "advisory", only=["two", "added-later"])
        self.assertEqual(code, 0, out)
        self.assertIn("::notice title=Step table::no step added-later", out)
        self.assertIn("two-ran", out)
        self.assertNotIn("one-ran", out)
        code, out = self.run_job(t, "advisory", only=["added-later"])
        self.assertEqual(code, 0, out)
        self.assertIn("No step of job advisory", out)

    def test_empty_only_runs_every_routed_step(self) -> None:
        t = table(self.ONLY)
        self.assertEqual(ci_steps.parse_only(""), [])
        for only in (None, [], ci_steps.parse_only(" , ")):
            with self.subTest(only=only):
                _, out = self.run_job(t, "advisory", only=only)
                for name in ("one", "two", "three"):
                    self.assertIn(f"{name}-ran", out)

    def test_only_on_the_command_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "steps.toml")
            path.write_text('[jobs]\nadvisory = "a"\n' + textwrap.dedent(self.ONLY))
            env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
            run = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/ci_steps.py"), "--table", str(path), "run", "--job", "advisory",
                 "--only", "three gone"], env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("three-ran", run.stdout)
            self.assertNotIn("one-ran", run.stdout)
            self.assertIn("no step gone", run.stdout)


PR_CHECKS_STEPS = ("pr-size", "ui-review", "split-plan", "swift-logic", "review-link")



class FakeStore:
    """The controller's step-result store, in memory."""

    def __init__(self, write: bool = True) -> None:
        self.passes: dict[str, dict] = {}
        self.posts: list[tuple[str, str, str, bool]] = []
        self.lookups: list[tuple[str, str, bool]] = []
        self.write = write
        self.error = ""

    def lookup(self, key: str, step: str, audit: bool = False) -> dict | None:
        self.lookups.append((key, step, audit))
        return self.passes.get(key)

    def post(self, key: str, step: str, outcome: str, seconds: float, audit: bool = False) -> None:
        if not self.write:
            return
        self.posts.append((key, step, outcome, audit))
        if outcome == "pass":
            self.passes[key] = {"key": key, "step": step, "run_url": "https://example/run/1", "at": "t", "runner": "r"}
        else:
            self.passes.pop(key, None)


class StepResultsTest(unittest.TestCase):
    """Step results by input hash: a step whose inputs passed before is reused, not run again."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "a").mkdir()
        (self.root / "a" / "x.txt").write_text("one\n")
        (self.root / "b.txt").write_text("other\n")
        self.commit()
        self.marker = self.root.parent / f"{self.root.name}-ran"
        self.table = table(f'''
            [setup]
            linux = "echo setup >> {self.marker}"
            [step.a]
            job = "linux"
            inputs = ["a/**"]
            run = "echo a >> {self.marker}"
            [step.event]
            job = "linux"
            inputs = ["a/**"]
            run = "echo ${{HEAD_SHA:-event}} >> {self.marker}"
        ''')

    def tearDown(self) -> None:
        self.marker.unlink(missing_ok=True)
        self.tmp.cleanup()

    def commit(self) -> None:
        git = ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "c"], check=True)

    def run_job(self, store, paths=None, env_extra=None) -> tuple[int, str, list[str]]:
        self.marker.unlink(missing_ok=True)
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        env.update(env_extra or {})
        old = os.environ
        os.environ = env
        try:
            code = ci_steps.run_job(self.table, "linux", paths, None, out, store=store, root=self.root)
        finally:
            os.environ = old
        ran = self.marker.read_text().split() if self.marker.exists() else []
        return code, out.getvalue(), ran

    def key(self, name: str, paths=None) -> str:
        files = ci_steps.tracked_files(self.root)
        return ci_steps.step_key(self.table.steps[name], self.table, files, ci_steps.head_tree(self.root), paths, {})

    def test_reusable_excludes_event_readers_advisory_labels_and_opt_out(self) -> None:
        t = table('''
            [step.plain]
            job = "linux"
            run = "python3 tests/x.py"
            [step.reads]
            job = "linux"
            run = "echo ${PR}"
            [step.off]
            job = "linux"
            reuse = false
            run = "true"
            [step.labeled]
            job = "linux"
            labels = ["perf"]
            run = "true"
            [step.adv]
            job = "advisory"
            blocks = false
            class = "idle"
            run = "true"
        ''')
        self.assertEqual([n for n, s in t.steps.items() if ci_steps.reusable(s)], ["plain"])

    def test_the_key_follows_input_contents_only(self) -> None:
        before = self.key("a")
        (self.root / "b.txt").write_text("changed outside the inputs\n")
        self.commit()
        self.assertEqual(self.key("a"), before, "a path outside the inputs leaves the key")
        (self.root / "a" / "x.txt").write_text("two\n")
        self.commit()
        self.assertNotEqual(self.key("a"), before, "an input's content moves the key")
        self.assertNotEqual(self.key("a", ["a/x.txt"]), self.key("a", ["a/y.txt"]),
                            "the changed inputs are part of the key (a step's own router reads them)")
        self.assertEqual(self.key("a", ["a/x.txt", "b.txt"]), self.key("a", ["a/x.txt"]))

    def test_a_refusing_store_is_named_in_the_log_and_a_plain_miss_is_not(self) -> None:
        # 2026-11-25: the pool runners' calls were refused and every one read as a miss, so the store stayed empty
        # with nothing in any log saying why.
        import http.server
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            status = 401

            def do_GET(self) -> None:
                self.send_response(Handler.status)
                self.end_headers()
                self.wfile.write(b'{"miss":true}' if Handler.status == 404 else b"tagged node carries no client tag")

            do_POST = do_GET

            def log_message(self, *args) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        store = ci_steps.StepResults(f"http://127.0.0.1:{server.server_port}", True, {})
        code, out, _ran = self.run_job(store)
        self.assertEqual(code, 0, out)
        self.assertIn("lookup HTTP 401", out)
        self.assertIn("nothing reused or stored", out)
        Handler.status = 404
        store = ci_steps.StepResults(f"http://127.0.0.1:{server.server_port}", True, {})
        code, out, _ran = self.run_job(store)
        self.assertEqual(code, 0, out)
        self.assertIn("write HTTP 404", out, "a 404 lookup is a miss; the refused write still shows")
        self.assertNotIn("lookup HTTP", out)
        server.shutdown()
        server.server_close()
        store = ci_steps.StepResults(f"http://127.0.0.1:{server.server_port}", True, {})
        calls = []
        real = ci_steps.urllib.request.urlopen

        def counted(*args, **kwargs):
            calls.append(args)
            return real(*args, **kwargs)
        with mock.patch.object(ci_steps.urllib.request, "urlopen", counted):
            code, out, _ran = self.run_job(store)
        self.assertEqual(code, 0, out)
        self.assertEqual(len(calls), 1, "an unreachable store is called once, then left alone")
        self.assertIn("lookup failed", out)

    def test_a_pass_is_stored_then_reused_and_the_setup_skipped(self) -> None:
        store = FakeStore()
        code, out, ran = self.run_job(store)
        self.assertEqual(code, 0, out)
        self.assertIn("a", ran)
        self.assertIn("setup", ran)
        self.assertEqual([(s, o) for _k, s, o, _a in store.posts], [("a", "pass")], "only the reusable step posts")
        with mock.patch.object(ci_steps, "audited", return_value=False):
            code, out, ran = self.run_job(store)
        self.assertEqual(code, 0, out)
        self.assertNotIn("a", ran, "the reused step did not run")
        self.assertIn("setup", ran, "the event step still runs, so the setup does")
        self.assertIn("Reused: this step's inputs", out)
        summary = ci_steps.report([ci_steps.Result(self.table.steps["a"], 0, 0.0, "", reused="u")], "linux",
                                  io.StringIO(), logs=False)
        self.assertIn("| a | yes | pr | reused |", summary)
        self.assertIn("1 of 2 routed steps reused", out)

    def test_a_skipped_alone_step_stores_no_pass(self) -> None:
        # A skipped step never ran: storing a pass under its key would let a later run reuse a verdict nobody had.
        self.table.steps.pop("event")
        self.table.steps["red"] = ci_steps.Step(name="red", job="linux", run="exit 3", inputs=("b.txt",), reuse=False)
        self.table.steps["a"] = ci_steps.Step(name="a", job="linux", run=self.table.steps["a"].run,
                                              inputs=("a/**",), alone=True)
        store = FakeStore()
        code, out, ran = self.run_job(store)
        self.assertEqual(code, 1, out)
        self.assertNotIn("a", ran)
        self.assertIn("step a skipped: blocking step red failed", out)
        self.assertEqual(store.posts, [])

    def test_every_step_reused_skips_setup(self) -> None:
        self.table.steps.pop("event")
        store = FakeStore()
        self.run_job(store)
        with mock.patch.object(ci_steps, "audited", return_value=False):
            code, out, ran = self.run_job(store)
        self.assertEqual((code, ran), (0, []), out)

    def test_an_audit_runs_the_hit_and_a_fail_evicts(self) -> None:
        self.table.steps.pop("event")
        store = FakeStore()
        self.run_job(store)
        key = self.key("a")
        self.table.steps["a"] = ci_steps.Step(name="a", job="linux", inputs=("a/**",), run="exit 4")
        # A changed run is a new key: no hit. Store a pass under the new key to stand for a flaky pass.
        new_key = self.key("a")
        store.passes[new_key] = {"key": new_key, "run_url": "u"}
        with mock.patch.object(ci_steps, "audited", return_value=True):
            code, out, _ran = self.run_job(store)
        self.assertEqual(code, 1, out)
        self.assertIn("failed its audit", out)
        self.assertNotIn(new_key, store.passes)
        self.assertIn((new_key, "a", "fail", True), store.posts)
        self.assertIn(key, store.passes, "the other key stays")

    def test_a_failure_is_never_stored(self) -> None:
        self.table.steps["a"] = ci_steps.Step(name="a", job="linux", inputs=("a/**",), run="false")
        store = FakeStore()
        code, _out, _ran = self.run_job(store)
        self.assertEqual(code, 1)
        self.assertEqual(store.posts, [])

    def test_from_env(self) -> None:
        self.assertIsNone(ci_steps.StepResults.from_env({}), "outside Actions: off")
        on = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "9", "GITHUB_RUN_ATTEMPT": "2",
              "GITHUB_EVENT_NAME": "push"}
        s = ci_steps.StepResults.from_env(on)
        self.assertTrue(s.write)
        self.assertEqual(s.meta["run_url"], "https://github.com/o/r/actions/runs/9/attempts/2")
        self.assertIsNone(ci_steps.StepResults.from_env({**on, "CI_STEP_RESULTS": "off"}))
        self.assertIsNone(ci_steps.StepResults.from_env({**on, "RUNNER_ENVIRONMENT": "github-hosted"}))
        event = self.root / "event.json"
        event.write_text(json.dumps({"pull_request": {"head": {"repo": {"full_name": "fork/r"}}}}))
        fork = ci_steps.StepResults.from_env({**on, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": str(event)})
        self.assertFalse(fork.write, "a fork's pull request never writes")
        event.write_text(json.dumps({"pull_request": {"head": {"repo": {"full_name": "o/r"}}}}))
        same = ci_steps.StepResults.from_env({**on, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": str(event)})
        self.assertTrue(same.write)

    def test_with_an_oidc_request_url_the_store_is_the_public_route_with_a_fresh_token(self) -> None:
        # The Linux pool is off the tailnet: its jobs reach the controller's public route with an Actions OIDC token.
        import http.server
        import threading
        seen: list[tuple[str, str, str]] = []

        class Handler(http.server.BaseHTTPRequestHandler):
            minted = 0

            def answer(self, code: int, body: bytes) -> None:
                self.send_response(code)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                auth = self.headers.get("Authorization", "")
                seen.append((self.command, self.path, auth))
                if self.path.startswith("/github/") and self.headers.get("User-Agent", "").startswith("Python-urllib"):
                    # Cloudflare in front of gh-events.cmux.com: 403, error code 1010, for Python's default agent.
                    return self.answer(403, b"error code: 1010")
                if self.path.startswith("/token"):
                    Handler.minted += 1
                    ok = auth == "bearer req-secret" and "audience=cmux-ci-step-results" in self.path
                    return self.answer(200 if ok else 403, json.dumps({"value": f"tok{Handler.minted}"}).encode())
                if not self.path.startswith("/github/step-results") or not auth.startswith("Bearer tok"):
                    return self.answer(401, b"token refused")
                self.answer(404 if self.command == "GET" else 204, b"")

            do_POST = do_GET

            def log_message(self, *args) -> None:
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        env = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "o/r", "GITHUB_EVENT_NAME": "push",
               "ACTIONS_ID_TOKEN_REQUEST_URL": f"{base}/token?api-version=2.0",
               "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "req-secret", "CI_STEP_RESULTS_PUBLIC_URL": base}
        store = ci_steps.StepResults.from_env(env)
        self.assertEqual(store.url, f"{base}/github/step-results")
        self.assertEqual(ci_steps.StepResults.from_env({**env, "CI_STEP_RESULTS_PUBLIC_URL": ""}).url,
                         "https://gh-events.cmux.com/github/step-results")
        no_oidc = {k: v for k, v in env.items() if not k.startswith("ACTIONS_ID_TOKEN")}
        self.assertEqual(ci_steps.StepResults.from_env(no_oidc).url, ci_steps.CONTROLLER + "/v1/ci/step-results")
        self.assertIsNone(store.lookup("0" * 64, "a"))
        store.post("0" * 64, "a", "pass", 1.0)
        server.shutdown()
        server.server_close()
        self.assertEqual(store.error, "", seen)
        self.assertEqual([(m, a) for m, p, a in seen if p.startswith("/github")],
                         [("GET", "Bearer tok1"), ("POST", "Bearer tok2")], "one fresh token per call")
        code, out, _ran = self.run_job(store)
        self.assertNotIn("req-secret", out)
        self.assertNotIn("tok", out.replace("token", ""), "the token never reaches the log")

    def test_an_unreachable_controller_is_a_miss(self) -> None:
        s = ci_steps.StepResults("http://127.0.0.1:9", True, {}, timeout=1)
        self.assertIsNone(s.lookup("0" * 64, "a"))
        s.post("0" * 64, "a", "pass", 1.0)  # no raise

    def test_the_real_table_keys_its_reusable_steps(self) -> None:
        real = ci_steps.load()
        names = [n for n, s in real.steps.items() if ci_steps.reusable(s)]
        self.assertIn("cmux-next-daemon-tests", names)
        self.assertNotIn("ui-review", names)
        files = ci_steps.tracked_files(ROOT)
        tree = ci_steps.head_tree(ROOT)
        if files and tree:
            keys = {ci_steps.step_key(real.steps[n], real, files, tree, None, {}) for n in names}
            self.assertEqual(len(keys), len(names), "every step has its own key")


class SetupTest(unittest.TestCase):
    """A job's `[setup]` runs once before its steps, fills $CI_TOOLS, and fails the job when it fails."""

    def run_job(self, t, job, paths=None, workers=None):
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        with mock.patch.dict(os.environ, env, clear=True):
            return ci_steps.run_job(t, job, paths, out=out, workers=workers), out.getvalue()

    def test_steps_see_what_setup_made(self) -> None:
        t = table('''
            [setup]
            linux = """
            mkdir -p "$CI_TOOLS/bin"
            printf '#!/bin/sh\\necho made-by-setup\\n' > "$CI_TOOLS/bin/ci-setup-probe"
            chmod +x "$CI_TOOLS/bin/ci-setup-probe"
            """
            [step.a]
            job = "linux"
            run = "ci-setup-probe"
            [step.b]
            job = "linux"
            run = "test -x \\"$CI_TOOLS/bin/ci-setup-probe\\""
        ''')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 0, out)
        self.assertIn("made-by-setup", out)
        self.assertEqual(out.count("::group::setup (linux)"), 1)

    def test_steps_read_the_changed_paths(self) -> None:
        t = table('''
            [step.a]
            job = "linux"
            run = "test \\"$(cat \\"$CI_PATHS_FILE\\")\\" = \\"$(printf 'web/a.ts\\nweb/b c.ts')\\""
        ''')
        code, out = self.run_job(t, "linux", ["web/a.ts", "web/b c.ts"])
        self.assertEqual(code, 0, out)
        # An unknown change leaves it unset, which a step reads as "everything changed".
        t = table('''
            [step.a]
            job = "linux"
            run = "test -z \\"${CI_PATHS_FILE:-}\\""
        ''')
        with mock.patch.dict(os.environ, {"CI_PATHS_FILE": "/stale"}):
            code, out = self.run_job(t, "linux", None)
        self.assertEqual(code, 0, out)

    def test_an_unremovable_tool_dir_does_not_fail_green_steps(self) -> None:
        # A sudo zig install left root-owned files in $CI_TOOLS; cleanup raised PermissionError and a job whose
        # steps all passed exited 1 (pr pipeline / linux, run 45474768809).
        t = table('''
            [step.a]
            job = "linux"
            run = "echo step-ok"
        ''')
        real = tempfile.TemporaryDirectory._rmtree

        def rmtree(name, ignore_errors=False, repeated=False):
            if not ignore_errors:
                raise PermissionError(1, "Operation not permitted", name)
            return real(name, ignore_errors=ignore_errors, repeated=repeated)

        with mock.patch.object(tempfile.TemporaryDirectory, "_rmtree", staticmethod(rmtree)):
            code, out = self.run_job(t, "linux")
        self.assertEqual(code, 0, out)
        self.assertIn("step-ok", out)

    def test_a_failed_setup_fails_the_job_and_runs_no_step(self) -> None:
        t = table('''
            [setup]
            linux = "echo no-network; exit 3"
            [step.a]
            job = "linux"
            run = "echo step-ran"
        ''')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1)
        self.assertIn("no-network", out)
        self.assertNotIn("step-ran", out)

    def test_setup_does_not_run_when_no_step_is_routed(self) -> None:
        t = table('''
            [setup]
            linux = "echo setup-ran"
            [step.a]
            job = "linux"
            inputs = ["web/**"]
            run = "true"
        ''')
        code, out = self.run_job(t, "linux", ["docs/x.md"])
        self.assertEqual(code, 0)
        self.assertNotIn("setup-ran", out)

    def test_a_tool_is_made_only_for_a_routed_step_that_needs_it(self) -> None:
        t = table('''
            [tools]
            bun = "mkdir -p \\"$CI_TOOLS/bin\\"; echo made-bun >&2; printf '#!/bin/sh\\\\necho bun-ran\\\\n' > \\"$CI_TOOLS/bin/bun\\"; chmod +x \\"$CI_TOOLS/bin/bun\\""
            node = "echo made-node >&2"
            [step.a]
            job = "linux"
            needs = ["bun"]
            inputs = ["mux/**"]
            run = "bun"
            [step.b]
            job = "linux"
            needs = ["node"]
            inputs = ["workers/**"]
            run = "true"
        ''')
        code, out = self.run_job(t, "linux", ["mux/a.ts"])
        self.assertEqual(code, 0, out)
        self.assertIn("bun-ran", out)
        self.assertEqual(out.count("::group::tool (bun)"), 1)
        self.assertNotIn("made-node", out)
        code, out = self.run_job(t, "linux", ["docs/x.md"])
        self.assertNotIn("made-", out)

    def test_a_failed_tool_fails_the_job_and_runs_no_step(self) -> None:
        t = table('''
            [tools]
            bun = "echo no-release; exit 4"
            [step.a]
            job = "linux"
            needs = ["bun"]
            run = "echo step-ran"
        ''')
        code, out = self.run_job(t, "linux")
        self.assertEqual(code, 1)
        self.assertIn("no-release", out)
        self.assertNotIn("step-ran", out)

    def test_needs_names_a_tool_of_the_table(self) -> None:
        with self.assertRaises(ci_steps.TableError):
            table('[step.a]\njob = "linux"\nneeds = ["bun"]\nrun = "true"')

    def test_setup_names_a_job_of_the_table(self) -> None:
        with self.assertRaises(ci_steps.TableError):
            table('[setup]\nwindows = "true"\n[step.a]\njob = "linux"\nrun = "true"')

    def test_workers_bound_the_steps_at_once(self) -> None:
        body = "".join(f'[step.s{i}]\njob = "linux"\nrun = "sleep 0.5"\n' for i in range(4))
        start = time.monotonic()
        code, _ = self.run_job(table(body), "linux", workers=1)
        self.assertEqual(code, 0)
        self.assertGreaterEqual(time.monotonic() - start, 2.0)

    def test_alone_is_true_or_false(self) -> None:
        self.assertTrue(table('[step.a]\njob = "linux"\nalone = true\nrun = "true"').steps["a"].alone)
        self.assertFalse(table('[step.a]\njob = "linux"\nrun = "true"').steps["a"].alone)
        with self.assertRaisesRegex(ci_steps.TableError, "`alone` is true or false"):
            table('[step.a]\njob = "linux"\nalone = "yes"\nrun = "true"')

    def test_an_alone_step_starts_after_the_others_end(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            # Each step logs its start and end; an alone step must start only after every other one ended.
            def step(name: str, alone: bool) -> str:
                return (f'[step.{name}]\njob = "linux"\nalone = {str(alone).lower()}\n'
                        f'run = "echo start-{name} >> {tmp}/log; sleep 0.3; echo end-{name} >> {tmp}/log"\n')
            t = table(step("big", True) + step("a", False) + step("b", False) + step("last", True))
            code, out = self.run_job(t, "linux", workers=4)
            self.assertEqual(code, 0, out)
            log = Path(tmp, "log").read_text().split()
        self.assertEqual(sorted(log[:4]), ["end-a", "end-b", "start-a", "start-b"], log)
        self.assertEqual(log[4:], ["start-big", "end-big", "start-last", "end-last"])
        self.assertLess(out.index("::group::a"), out.index("::group::big"), out)
        self.assertLess(out.index("::group::big"), out.index("::group::last"), out)

    def test_an_alone_step_is_skipped_once_a_blocking_step_failed(self) -> None:
        # The job is red already and its re-run runs every step: a 15 to 65 minute alone step would only
        # spend the machine (4 of 30 long red linux jobs on 11-24, 16% of their time).
        with tempfile.TemporaryDirectory() as tmp:
            body = (f'[step.big]\njob = "linux"\nalone = true\nrun = "touch {tmp}/big"\n'
                    '[step.red]\njob = "linux"\nrun = "exit 3"\n')
            code, out = self.run_job(table(body), "linux")
            self.assertEqual(code, 1, out)
            self.assertFalse(Path(tmp, "big").exists(), out)
        self.assertIn("step big skipped: blocking step red failed", out)
        self.assertIn("::error title=red::", out)
        self.assertNotIn("step big exited", out)

    def test_a_failed_alone_step_skips_the_alone_steps_after_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            body = ('[step.first]\njob = "linux"\nalone = true\nrun = "exit 2"\n'
                    f'[step.second]\njob = "linux"\nalone = true\nrun = "touch {tmp}/second"\n'
                    '[step.ok]\njob = "linux"\nrun = "true"\n')
            code, out = self.run_job(table(body), "linux")
            self.assertEqual(code, 1, out)
            self.assertFalse(Path(tmp, "second").exists(), out)
        self.assertIn("step second skipped: blocking step first failed", out)

    def test_a_skipped_step_reads_skipped_in_the_summary(self) -> None:
        step = ci_steps.Step(name="big", job="linux", run="true", alone=True)
        red = ci_steps.Step(name="red", job="linux", run="false")
        summary = ci_steps.report([ci_steps.Result(red, 1, 1.0, ""), ci_steps.Result(step, 0, 0.0, "", skipped=True)],
                                  "linux", io.StringIO(), logs=False)
        self.assertIn("| big | yes | ", summary)
        self.assertRegex(summary, r"\| big \|.*\| skipped \|")

class PipelineTest(unittest.TestCase):
    """pr-pipeline.yml runs the table's linux job through ci/run; pr-router.yml starts it from the table."""

    def test_a_change_to_the_pipeline_routes_every_step(self) -> None:
        t = table('[step.a]\njob = "linux"\ninputs = ["web/**"]\nrun = "true"')
        for path in ci_steps.PIPELINE_PATHS:
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file(), "PIPELINE_PATHS names a file of this tree")
                self.assertEqual(ci_steps.route(t, ["docs/x.md", path]), {"linux": ["a"]})
        self.assertEqual(ci_steps.route(t, ["docs/x.md"]), {})

    def test_the_entry_is_the_runner(self) -> None:
        entry = ROOT / "ci" / "run"
        self.assertTrue(os.access(entry, os.X_OK), "ci/run is executable")
        run = subprocess.run([str(entry), "route", "--paths-file", os.devnull], cwd=ROOT, capture_output=True,
                             text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        # An empty change routes only the steps with no inputs: the advisory lints.
        self.assertEqual(set(json.loads(run.stdout)), {"advisory"})

    def test_every_linux_step_has_inputs_and_blocks(self) -> None:
        # A linux step with no inputs would start a runner on every head: say so with `inputs = ["**"]`.
        for step in ci_steps.load().steps.values():
            if step.job == "linux":
                with self.subTest(step=step.name):
                    self.assertTrue(step.inputs)
                    self.assertTrue(step.blocks)
                    self.assertTrue(step.title and step.about)

    def test_the_workflow_runs_the_linux_job_on_the_merge_commit(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        self.assertEqual(set(wf.get("on", wf.get(True))), {"workflow_call"})
        self.assertEqual(wf["permissions"], {})
        job = wf["jobs"]["linux"]
        self.assertEqual(job["permissions"], {"contents": "read", "id-token": "write", "actions": "read"},
                         "id-token mints the step-result store's OIDC token; actions reads tooling-tests' base verdict")
        checkout = job["steps"][0]
        self.assertEqual(checkout["with"]["fetch-depth"], 2)
        self.assertIs(checkout["with"]["persist-credentials"], False)
        runs = [i for i, s in enumerate(job["steps"]) if "ci/run run --job linux" in s.get("run", "")]
        self.assertEqual(len(runs), 1)
        # After it only failure-only uploads: a fixit-compile patch (the web-typecheck step's), for the cmuxterm-hq
        # reconciler, which reads a run's `fixit-compile-*` artifacts, and a failed web test shard's JUnit report.
        after = job["steps"][runs[0] + 1:]
        self.assertEqual([s["name"] for s in after], ["Upload the fixit-compile patch"] + [
            f"Upload the web test JUnit report (shard {n})" for n in range(1, 5)])
        for upload in after:
            self.assertEqual(upload["if"], "${{ failure() && !cancelled() }}")
            self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
            self.assertEqual(upload["with"]["if-no-files-found"], "ignore")
        self.assertEqual(after[0]["if"], "${{ failure() && !cancelled() }}")
        self.assertTrue(after[0]["uses"].startswith("actions/upload-artifact@"))
        self.assertTrue(after[0]["with"]["name"].startswith("fixit-compile-"))
        self.assertEqual(after[0]["with"]["path"], "${{ runner.temp }}/fixit-compile")
        self.assertEqual(after[0]["with"]["if-no-files-found"], "ignore")

    def test_the_router_starts_it_only_when_a_step_is_routed(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        # mac and ios run after merge (pr_router.json table_why, cmuxterm-hq docs/findings/2026-11-25-ci-value.md).
        self.assertEqual(callees["pr-pipeline.yml"]["table_jobs"], ["linux", "web-browser"])
        self.assertIs(callees["pr-pipeline.yml"].get("draft"), True, "a fast-track (full-tier) head still runs it")

        def started(files, **pr):
            event = {"action": "synchronize", "pull_request": pr}
            return pr_router.route(event, callees, files)

        start, why = started(["web/app/lib/indexnow.ts"])
        self.assertEqual(start, ["pr-pipeline.yml"])
        self.assertIn("indexnow", why["pr-pipeline.yml"])
        self.assertEqual(started(["docs/x.md"])[0], [])
        # A cheap head (a draft) starts none of its jobs, even when the changed files are unknown.
        start, why = started(["web/app/lib/indexnow.ts"], draft=True)
        self.assertEqual(start, [])
        self.assertIn("cheap tier", why["pr-pipeline.yml"])
        self.assertEqual(started(None, draft=True)[0], [])
        self.assertEqual(started(None)[0], ["pr-pipeline.yml"])
        # A ready head into feat-cmux-next is cheap until ready-to-land or full-ci is added; either runs it on that head.
        repo = {"full_name": "manaflow-ai/cmux"}
        web = ["web/app/lib/indexnow.ts"]

        def ready(action, labels, added=""):
            event = {"action": action, "pull_request": {
                "draft": False, "labels": [{"name": n} for n in labels],
                "base": {"ref": "feat-cmux-next", "repo": repo}, "head": {"repo": repo}}}
            if added:
                event["label"] = {"name": added}
            # The land rule on, as pr-router.yml's CI_LAND_TIER defaults it.
            return pr_router.route(event, callees, web,
                                   decided=pr_router.head_tier.tier("pull_request", event, land_switch="1"))

        start, why = ready("synchronize", [])
        self.assertEqual(start, [])
        self.assertIn("cheap tier", why["pr-pipeline.yml"])
        for label in ("ready-to-land", "full-ci"):
            with self.subTest(label=label):
                self.assertEqual(ready("labeled", [label], label)[0], ["pr-pipeline.yml"])
                self.assertEqual(ready("synchronize", [label])[0], ["pr-pipeline.yml"])
        draft_full_ci = {"action": "labeled", "label": {"name": "full-ci"},
                         "pull_request": {"draft": True, "labels": [{"name": "full-ci"}]}}
        self.assertEqual(pr_router.route(draft_full_ci, callees, web)[0], ["pr-pipeline.yml"])
        self.assertEqual(started(["ci/steps.toml"])[0], ["pr-pipeline.yml"])
        # A table the router cannot read starts the pipeline: it routes more, never less.
        self.assertIsNone(pr_router.table_steps(callees["pr-pipeline.yml"], ["docs/x.md"], ROOT / "no-such.toml"))
        with tempfile.TemporaryDirectory() as tmp:
            for body in ("not toml [", 'setup = "x"\n[jobs]\nlinux = "l"', '[jobs]\nlinux = "l"\n[step]\na = 1'):
                with self.subTest(body=body):
                    bad = Path(tmp) / "steps.toml"
                    bad.write_text(body)
                    self.assertIsNone(pr_router.table_steps(callees["pr-pipeline.yml"], ["docs/x.md"], bad))

    def test_the_router_names_the_routed_table_jobs(self) -> None:
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        routed = pr_router.table_jobs_routed
        # `security-holes` (inputs ["**"]) routes every change to linux, so linux is in every list; web-browser
        # starts only for a browser step's inputs.
        self.assertEqual(routed(callees, ["webviews/src/app.tsx"]), ["linux", "web-browser"])
        self.assertEqual(routed(callees, ["scripts/ci/notify-indexnow.py"]), ["linux"])
        self.assertEqual(routed(callees, ["web/app/page.tsx"]), ["linux", "web-browser"])
        self.assertEqual(routed(callees, ["docs/x.md"]), ["linux"])
        # Unknown changes or an unreadable table run every routed job. mac and ios are not routed on a pull
        # request since 2026-11-26: their steps run after merge (cmuxterm-hq docs/findings/2026-11-25-ci-value.md).
        self.assertEqual(routed(callees, None), ["linux", "web-browser"])
        self.assertEqual(routed(callees, ["docs/x.md"], ROOT / "no-such.toml"), ["linux", "web-browser"])
        # Every job runs only on a full-tier head: a cheap head's change routes none of them.
        swift = ["Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionRegistry.swift"]
        self.assertNotIn("mac", routed(callees, swift))
        self.assertIn("linux", routed(callees, swift))
        self.assertEqual(routed(callees, swift, full=False), [])
        self.assertEqual(routed(callees, None, full=False), [])
        self.assertEqual(pr_router.FULL_TIER_JOBS, ("linux", "web-browser", "mac", "ios"))
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}):
                pr_router.write_outputs(["pr-pipeline.yml"], {}, ["webviews/a.ts"], ["web-browser"])
            self.assertIn('table=["web-browser"]\n', out.read_text())
        router = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())
        self.assertEqual(router["jobs"]["route"]["outputs"]["table"], "${{ steps.route.outputs.table }}")
        self.assertEqual(router["jobs"]["pipeline"]["with"], {"jobs": "${{ needs.route.outputs.table || '' }}"})

    def test_browser_suites_run_on_a_pr_only_with_full_ci(self) -> None:
        """NOW's pr_verdict, 2026-11-26 08:57Z: `pr router / pr pipeline / web-browser` ended 3 of the newest 20 PR
        verdicts. A PR routes the web-browser job only with `full-ci`; base pushes run its suites (ci-web.yml)."""
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        config = callees["pr-pipeline.yml"]
        web = ["webviews/src/app.tsx"]
        self.assertEqual(pr_router.FULL_CI_ONLY_JOBS, ("web-browser",))
        with mock.patch.dict(os.environ, {"CI_PR_BROWSER_FULL_CI_ONLY": "1"}):
            self.assertEqual(pr_router.table_jobs_routed(callees, web, full_ci=False), ["linux"])
            self.assertEqual(pr_router.table_jobs_routed(callees, None, full_ci=False), ["linux"])
            self.assertEqual(pr_router.table_jobs_routed(callees, web, full_ci=True), ["linux", "web-browser"])
            browser = {s.name for s in ci_steps.load().steps.values() if s.job == "web-browser"}
            self.assertFalse(browser & set(pr_router.table_steps(config, web, full_ci=False) or []))
            self.assertTrue(browser & set(pr_router.table_steps(config, web, full_ci=True) or []))
            # The ready-to-land head (full tier) without full-ci routes no browser step either.
            event = {"action": "labeled", "label": {"name": "ready-to-land"},
                     "pull_request": {"draft": False, "labels": [{"name": "ready-to-land"}]}}
            start, why = pr_router.route(event, callees, web, decided=("full", "ready-to-land"))
            self.assertNotIn("web-browser", why.get("pr-pipeline.yml", ""))
            event = {"action": "labeled", "label": {"name": "full-ci"},
                     "pull_request": {"draft": False, "labels": [{"name": "full-ci"}]}}
            start, why = pr_router.route(event, callees, web, decided=("full", "full-ci"))
            self.assertIn("pr-pipeline.yml", start)
        # The repository variable turns it off.
        with mock.patch.dict(os.environ, {"CI_PR_BROWSER_FULL_CI_ONLY": "0"}):
            self.assertEqual(pr_router.table_jobs_routed(callees, web, full_ci=False), ["linux", "web-browser"])
        router = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())
        env = next(s for s in router["jobs"]["route"]["steps"] if s.get("id") == "route")["env"]
        self.assertEqual(env["CI_PR_BROWSER_FULL_CI_ONLY"], "${{ vars.CI_PR_BROWSER_FULL_CI_ONLY || '1' }}")

    def test_each_pipeline_job_runs_only_when_routed(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        on = wf.get("on", wf.get(True))
        self.assertEqual(on["workflow_call"]["inputs"]["jobs"]["default"], "")
        table_jobs = set(ci_steps.load().jobs) - {"advisory", "verdict"}
        # The ios job's picker (IosJobTest): it runs no step, only when the ios job runs, and places it.
        pickers = {"ios-runner": "ios"}
        # A job that runs some of a table job's steps on a machine of its own (`--only`), beside that job: the kit's
        # macOS swift test beside the ios job's simulator leg (IosJobTest).
        splits = {"ios-macos": ("ios", ["ios-kit-macos"])}
        # No gateway head start for the ios job: its request key is per runner, so it never shared a build.
        self.assertNotIn("ios-ffi-fleet", wf["jobs"])
        for name, job in wf["jobs"].items():
            if name == "mac-fallback":
                continue  # MacFallbackTest: it runs on a linux step's request, not on the router's
            if name in ("ios-fast-runner", "ios-fast"):
                continue  # tests/test_ci_ios_fast_verdict.py: the additive fast iOS verdict plans from the diff itself
            if name in pickers:
                with self.subTest(picker=name):
                    routed = f"inputs.jobs == '' || contains(fromJSON(inputs.jobs), '{pickers[name]}')"
                    # The picker runs exactly when its job does: the land tier too.
                    self.assertEqual(job["if"], f"${{{{ ({routed}) && {PIPELINE_LAND_TIER} && {PIPELINE_LABEL_GUARD} }}}}")
                    self.assertFalse([s for s in job["steps"] if "ci/run" in s.get("run", "")])
                    self.assertIn(name, wf["jobs"][pickers[name]]["needs"])
                continue
            if name in splits:
                table_job, only = splits[name]
                with self.subTest(split=name):
                    self.assertEqual(job["if"], f"${{{{ inputs.jobs == '' || contains(fromJSON(inputs.jobs), '{table_job}') }}}}")
                    runs = [s["run"] for s in job["steps"] if f"ci/run run --job {table_job} " in s.get("run", "")]
                    self.assertEqual(runs, [f'ci/run run --job {table_job} ${{PATHS_FILE:+--paths-file "$PATHS_FILE"}} '
                                            f'--only {" ".join(only)}'])
                    self.assertEqual(job["steps"][0]["with"]["fetch-depth"], 2)
                    self.assertIs(job["steps"][0]["with"]["persist-credentials"], False)
                    steps = [ci_steps.load().steps[n] for n in only]
                    self.assertTrue(all(s.job == table_job and s.alone for s in steps))
                    need = ci_steps.SETUP_TIMEOUT + ci_steps.TOOL_TIMEOUT + sum(s.timeout for s in steps)
                    self.assertGreaterEqual(job["timeout-minutes"] * 60, need)
                continue
            elsewhere = {n for split, only in splits.values() if split == name for n in only}
            with self.subTest(job=name):
                self.assertIn(name, table_jobs, "a pr-pipeline.yml job is a job of ci/steps.toml")
                routed = f"inputs.jobs == '' || contains(fromJSON(inputs.jobs), '{name}')"
                if name in PIPELINE_LAND_TIER_JOBS:
                    # The land tier (#54886's condition and label guard): runs only at the head handed to land.
                    self.assertEqual(job["if"], f"${{{{ ({routed}) && {PIPELINE_LAND_TIER} && {PIPELINE_LABEL_GUARD} }}}}")
                else:
                    self.assertEqual(job["if"], f"${{{{ {routed} }}}}")
                runs = [s for s in job["steps"] if f"ci/run run --job {name} " in s.get("run", "")]
                self.assertEqual(len(runs), 1)
                self.assertEqual(job["steps"][0]["with"]["fetch-depth"], 2)
                self.assertIs(job["steps"][0]["with"]["persist-credentials"], False)
                # The mac and ios jobs run on a Mac (MacJobTest and IosJobTest hold their labels); every other
                # job on linux's.
                if name not in ("mac", "ios"):
                    self.assertEqual(job["runs-on"], wf["jobs"]["linux"]["runs-on"])
                steps = [s for s in ci_steps.load().steps.values() if s.job == name and s.name not in elsewhere]
                shared = [s for s in steps if not s.alone]
                need = (ci_steps.SETUP_TIMEOUT + ci_steps.TOOL_TIMEOUT
                        + -(-len(shared) // 2) * max((s.timeout for s in shared), default=0)
                        + sum(s.timeout for s in steps if s.alone))
                self.assertGreaterEqual(job["timeout-minutes"] * 60, need)

    def test_the_changed_paths_are_nul_separated(self) -> None:
        # Without -z git quotes a non-ASCII path, which then matches no step's inputs: green, nothing run.
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        runs = [s.get("run", "") for s in wf["jobs"]["linux"]["steps"]]
        self.assertTrue(any("git diff --name-only --no-renames -z " in run for run in runs))
        with tempfile.TemporaryDirectory() as tmp:
            listed = Path(tmp) / "paths"
            listed.write_bytes("skills/caf\u00e9/SKILL.md\0a b.txt\0".encode())
            self.assertEqual(ci_steps.read_paths(str(listed)), ["skills/caf\u00e9/SKILL.md", "a b.txt"])
            listed.write_text("a.txt\nb.txt\n")
            self.assertEqual(ci_steps.read_paths(str(listed)), ["a.txt", "b.txt"])

    def test_a_steps_log_prints_when_it_ends(self) -> None:
        # A job cut by its own timeout still shows the steps that finished: nothing waits for the last one.
        seen: list[str] = []
        real = ci_steps.report

        def late_report(results, job, out=sys.stdout, logs=True):
            seen.append(out.getvalue())
            return real(results, job, out, logs)

        t = table('''
            [step.one]
            job = "linux"
            run = "echo said-by-one"
            blocks = true
            inputs = ["**"]
        ''')
        out = io.StringIO()
        with mock.patch.object(ci_steps, "report", late_report), mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
            self.assertEqual(ci_steps.run_job(t, "linux", None, out=out), 0)
        self.assertIn("::group::one\nsaid-by-one\n::endgroup::", seen[0])
        self.assertEqual(out.getvalue().count("::group::one"), 1)

    def test_the_router_check_names_a_runner_that_does_not_import(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import pr_router

        with mock.patch.object(pr_router, "ci_steps", None):
            problems = pr_router.check(pr_router.load_manifest(), pr_router.ENTRY.read_text(), pr_router.ENTRY.parent)
        self.assertTrue(any("does not import" in p for p in problems), problems)

    def test_the_router_checks_out_the_table(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())
        sparse = wf["jobs"]["route"]["steps"][0]["with"]["sparse-checkout"].split()
        self.assertIn("ci/steps.toml", sparse)
        self.assertIn("scripts/ci/ci_steps.py", sparse)

    def test_the_replaced_workflows_are_gone(self) -> None:
        for name in ("indexnow-tests.yml", "vendored-agent-cursor.yml", "r2-upload-tests.yml",
                     "cmux-skill-contract.yml", "ci-cache-receipts.yml"):
            self.assertFalse((ROOT / ".github/workflows" / name).exists(), f"{name}: the step table runs it")

    def test_the_moved_pull_request_triggers_are_gone(self) -> None:
        # These keep their push, dispatch or post-merge runs; a pull request runs them as steps of the table.
        moved = {"labels-sync.yml": "labels-manifest",
                 "cmux-next-shim-cpp.yml": "shim-cpp", "cmux-next-chromium-currency.yml": "chromium-currency",
                 "swift-acpmux-protocol.yml": "swift-acpmux-protocol",
                 "app-platform.yml": "app-platform", "ci-artifact-transport.yml": "ci-artifact-transport",
                 "cloud-vm-image-lock.yml": "cloud-vm-image-lock", "mux.yml": "mux",
                 "automation-bench.yml": "automation-bench",
                 "repair-nightly-appcast-content-types.yml": "repair-nightly-appcast",
                 "cmux-next-remote-daemon.yml": "remote-daemon-packaging",
                 "risk-tier-tests.yml": "risk-tier-tests", "app-store-shelf.yml": "app-store-shelf"}
        steps = ci_steps.load().steps
        for name, step in moved.items():
            with self.subTest(workflow=name):
                path = ROOT / ".github/workflows" / name
                # ci-artifact-transport.yml ran only on pushes to main, so feat-cmux-next has no copy.
                if path.exists():
                    wf = yaml.safe_load(path.read_text())
                    self.assertNotIn("pull_request", wf.get("on", wf.get(True)), "the step table runs it")
                self.assertEqual(steps[step].job, "linux")
        self.assertNotIn("validate", yaml.safe_load((ROOT / ".github/workflows/labels-sync.yml").read_text())["jobs"])
        # web-complexity.yml also ran for pull requests into main, which the table does not serve: it keeps those.
        wf = yaml.safe_load((ROOT / ".github/workflows/web-complexity.yml").read_text())
        self.assertEqual(wf.get("on", wf.get(True))["pull_request"]["branches-ignore"], ["feat-cmux-next"])
        self.assertEqual(steps["web-complexity"].job, "linux")
        # These keep their pull requests into other bases; each moved job skips only feat-cmux-next's.
        # The land tier (tests/test_head_tier.py) wraps it: the condition, then the land condition and label guard.
        for name, job, step in (("cmux-vm-clients.yml", "sdk", "cmux-vm-sdk"),
                                ("cmux-vm-clients.yml", "rust", "cmux-vm-clients-rust"),
                                ("cmux-next-crash-class.yml", "crash-class", "cmux-next-crash-class"),
                                ("cmux-cloud-cli.yml", "test", "cmux-cloud-cli"),
                                ("cmux-vm-cloud.yml", "check", "cmux-vm-cloud")):
            with self.subTest(workflow=name, job=job):
                wf = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
                self.assertIn("pull_request", wf.get("on", wf.get(True)))
                self.assertTrue(wf["jobs"][job]["if"].startswith(
                    "${{ (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') && "),
                    wf["jobs"][job]["if"])
                self.assertEqual(steps[step].job, "linux")
                on = wf.get("on", wf.get(True))
                self.assertEqual(set(steps[step].inputs) - {".github/workflows/" + name},
                                 set(on["pull_request"]["paths"]) - {".github/workflows/" + name})
        # The cargo steps run alone, so their compile does not raise the shared wave bound.
        for step in ("cmux-vm-clients-rust", "cmux-cloud-cli", "app-store-shelf"):
            with self.subTest(step=step):
                self.assertTrue(steps[step].alone)
                self.assertIn("rust", steps[step].needs)
        self.assertIn("zig", steps["app-store-shelf"].needs)
        self.assertIn("bash scripts/ci/app-store-shelf-check.sh", steps["app-store-shelf"].run)
        self.assertIn("python3 tests/test_risk_tier.py", steps["risk-tier-tests"].run)
        self.assertIn("crash-class-gate.sh", steps["cmux-next-crash-class"].run)
        # ci-guards.yml's submodule guard skips only feat-cmux-next's pull requests; every gitlink routes its step.
        wf = yaml.safe_load((ROOT / ".github/workflows/ci-guards.yml").read_text())
        self.assertEqual(wf["jobs"]["workflow-guard-submodule-forward-only"]["if"],
                         "${{ github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next' }}")
        self.assertEqual(steps["submodule-forward-only"].job, "linux")
        gitlinks = re.findall(r"^\s*path = (\S+)$", (ROOT / ".gitmodules").read_text(), re.M)
        self.assertTrue(gitlinks)
        self.assertLessEqual({".gitmodules", *gitlinks}, set(steps["submodule-forward-only"].inputs))
        # ci-web.yml's web-typecheck keeps its route and skips only feat-cmux-next's pull requests; what routed it
        # (web_subareas.py's typecheck subarea) routes the step.
        wf = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text())
        self.assertTrue(wf["jobs"]["web-typecheck"]["if"].endswith(
            "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') }}"))
        typecheck = steps["web-typecheck"]
        self.assertEqual(typecheck.job, "linux")
        self.assertIn("bun run typecheck", typecheck.run)
        self.assertIn("fixit_compile.py run --kind tsc", typecheck.run)
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import web_subareas

        for path in ("web/app/page.tsx", "web/services/x.ts", "web/next-env.d.ts", "web/scripts/a.mjs",
                     "web/package.json", "web/tsconfig.json", "web/bun.lock", "web/messages/fr.json",
                     ".github/workflows/ci-web.yml", "scripts/ci/web_subareas.py"):
            with self.subTest(path=path):
                self.assertTrue(web_subareas.classify_paths([path]).typecheck)
                self.assertTrue(ci_steps.routed(typecheck, [path]))
        # cmux-next-guards.yml's security-holes job judged every pull request (gitleaks reads any file), so its step's
        # inputs are `**` and any change routes it; the job skips feat-cmux-next's pull requests (the base matched exactly).
        wf = yaml.safe_load((ROOT / ".github/workflows/cmux-next-guards.yml").read_text())
        self.assertTrue(wf["jobs"]["security-holes"]["if"].startswith(  # then the land tier (test_head_tier.py)
                        "${{ ((github.event.action != 'ready_for_review') && (github.event_name == 'pull_request' && "
                        "(github.base_ref != 'feat-cmux-next' || github.workflow == 'docs-only fallback'))) && "),
                        wf["jobs"]["security-holes"]["if"])
        holes = steps["security-holes"]
        self.assertEqual(holes.job, "linux")
        self.assertEqual(holes.inputs, ("**",))
        self.assertTrue(holes.blocks)
        for path in ("a.txt", "web/app/page.tsx", "Sources/App.swift", ".github/workflows/x.yml"):
            with self.subTest(path=path):
                self.assertTrue(ci_steps.routed(holes, [path]))
        # A docs-only change alone does not start the pipeline for it, as the job's docs-only path filter did not.
        import pr_router
        callee = pr_router.load_manifest()["pr-pipeline.yml"]
        self.assertEqual(pr_router.table_steps(callee, ["docs/x.md"]), [])
        self.assertIn("security-holes", pr_router.table_steps(callee, ["docs/x.md", "a.txt"]))
        self.assertIn("security-holes", pr_router.table_steps(callee, ["a.txt"]))
        for command in ("ratchet.py zizmor --base HEAD^1 --head HEAD", "ratchet.py gitleaks --base HEAD^1 --head HEAD",
                        "tests/test_static_analysis_ratchet.py", "tests/test_ci_linux_single_size.py",
                        "tests/test_ci_no_single_size_pins.py", "CMUX_STATIC_ANALYSIS_BLOCKING=1"):
            self.assertIn(command, holes.run)
        # One failed command does not stop the others, as the job's `!cancelled()` steps did.
        self.assertEqual(holes.run.count("|| status=1"), 4)
        self.assertIn('exit "$status"', holes.run)
        guards = wf["jobs"]
        # tooling-tests: on a feat-cmux-next pull request (not the fallback's call) the job keeps only the tt- steps the
        # linux job cannot run; tooling-tests-1..5 carry every other tt- step's command, each behind the job's selection.
        route = next(s for s in guards["tooling-tests"]["steps"] if s.get("id") == "setup-tooling-route")
        staying = ("tt-remote-p10k", "tt-webviews-tests-per-file", "tt-web-lint-prepush", "tt-tailnet")
        self.assertIn('[ "${GITHUB_BASE_REF:-}" = feat-cmux-next ] && [ "$GITHUB_WORKFLOW" != "docs-only fallback" ]',
                      route["run"])
        self.assertIn("for id in " + " ".join(staying) + "; do", route["run"])
        shards = sorted((n for n in steps if re.fullmatch(r"tooling-tests-\d+", n)), key=lambda n: int(n.rsplit("-", 1)[1]))
        self.assertEqual(shards, [f"tooling-tests-{i}" for i in range(1, len(shards) + 1)])
        tooling = [steps[n] for n in shards]
        carried = re.findall(r"^if want (tt-[\w-]+); then", "\n".join(s.run for s in tooling), re.M)
        tt_ids = [s["id"] for s in guards["tooling-tests"]["steps"] if s.get("id", "").startswith("tt-")]
        self.assertEqual(carried, [i for i in tt_ids if i not in staying])
        for step in tooling:
            with self.subTest(step=step.name):
                self.assertEqual((step.job, step.inputs, step.alone), ("linux", ("**",), False))
                self.assertLessEqual(step.timeout, 360)
                self.assertIn("tooling_steps.py route --workflow .github/workflows/cmux-next-guards.yml --job tooling-tests",
                              step.run)
        # The job's base-red skip comes with them: while tooling-tests is red on the base, the linux job leaves
        # tooling-tests-N out of its run (not passed, so no skip is stored as a pass), and fails open.
        linux = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())["jobs"]["linux"]
        decide = next(s for s in linux["steps"] if s.get("id") == "tooling-tests-base-red")
        self.assertIn('scripts/ci/base_red_skip.py decide --workflow cmux-next-guards.yml --job "tooling-tests"',
                      decide["run"])
        self.assertIs(decide["continue-on-error"], True)
        self.assertEqual(decide["env"], {"GH_TOKEN": "${{ github.token }}"})
        for part in ("github.event_name == 'pull_request'", "format('{0}', vars.CI_SKIP_WHILE_BASE_RED) != '0'",
                     "!contains(github.event.pull_request.labels.*.name, 'full-ci')"):
            self.assertIn(part, decide["if"])
        run = next(s for s in linux["steps"] if s.get("id") == "run")
        self.assertEqual(run["env"]["TOOLING_TESTS_BASE_RED"], "${{ steps.tooling-tests-base-red.outputs.base_red }}")
        self.assertEqual(run["env"]["CI_TOOLING_TESTS_PR_SCOPE"], "${{ vars.CI_TOOLING_TESTS_PR_SCOPE || '1' }}")
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "ci").mkdir()
            fake = Path(tmp) / "ci" / "run"
            fake.write_text('#!/bin/sh\nif [ "$1" = route ]; then [ -n "$ROUTE" ] && printf %s "$ROUTE"; exit $?; fi\n'
                            'echo "ran: $*"\n')
            fake.chmod(0o755)

            def ran(red: str, route: str) -> str:
                env = dict(os.environ, TOOLING_TESTS_BASE_RED=red, ROUTE=route)
                env.pop("PATHS_FILE", None)
                return subprocess.run(["bash", "-e", "-c", run["run"]], cwd=tmp, env=env, capture_output=True,
                                      text=True, check=True).stdout

            routed = json.dumps({"linux": ["shellcheck", "tooling-tests-1", "web-tests-1", "tooling-tests-12"]})
            self.assertIn("ran: run --job linux --only shellcheck web-tests-1\n", ran("true", routed))
            self.assertEqual(ran("false", routed), "ran: run --job linux\n")
            self.assertEqual(ran("", routed), "ran: run --job linux\n")
            self.assertEqual(ran("true", ""), "ran: run --job linux\n", "an unread route runs every step")
            self.assertNotIn("ran:", ran("true", json.dumps({"linux": ["tooling-tests-1"]})))
        # ci-web.yml's diff-sidecar-check keeps its route and runs as the table step on feat-cmux-next pull requests,
        # while docs-only fallback still runs the reusable job directly.
        diff_wf = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text())
        self.assertTrue(diff_wf["jobs"]["diff-sidecar-check"]["if"].endswith(
            "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next' || github.workflow == 'docs-only fallback') }}"))
        diff_step = steps["diff-sidecar-check"]
        self.assertEqual(diff_step.job, "linux")
        self.assertEqual(diff_step.timeout, 300)
        self.assertEqual(diff_step.needs, ("bun", "rust"))
        for path in ("Native/DiffSidecar/src/server.rs", "cmux-tui/crates/cmux-git/src/lib.rs",
                     "webviews/src/diff/view.ts", "webviews/package.json", ".github/workflows/ci-web.yml",
                     "scripts/ci/web_subareas.py"):
            with self.subTest(path=path):
                self.assertTrue(ci_steps.routed(diff_step, [path]))
        self.assertFalse(ci_steps.routed(diff_step, ["web/app/page.tsx"]))
        for command in ("bun install --frozen-lockfile", "rustup toolchain install 1.98.1",
                        "run-diff-sidecar-cargo.sh fmt", "run-diff-sidecar-cargo.sh clippy",
                        "run-diff-sidecar-cargo.sh test", "generate-diff-sidecar-types.sh --check"):
            self.assertIn(command, diff_step.run)
        self.assertGreaterEqual(diff_step.run.count("|| status=1"), 3)
        self.assertIn("lint_status=1", diff_step.run)
        # ci-web.yml's web-tests matrix and web-production-build run as table steps on feat-cmux-next pull requests
        # only; the jobs still run on a push, a dispatch and a pull request into any other base.
        web_jobs = diff_wf["jobs"]
        for job in ("web-tests", "web-production-build"):
            with self.subTest(job=job):
                self.assertTrue(web_jobs[job]["if"].endswith(
                    "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') }}"))
        self.assertEqual(web_jobs["web-tests"]["strategy"]["matrix"]["shard"], ["1/4", "2/4", "3/4", "4/4"])
        pipeline = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        uploads = {s.get("with", {}).get("name"): s for s in pipeline["jobs"]["linux"]["steps"] if "uses" in s}
        for shard in range(1, 5):
            step = steps[f"web-tests-{shard}"]
            with self.subTest(step=step.name):
                self.assertEqual(step.job, "linux")
                self.assertEqual(step.timeout, 360)
                self.assertTrue(step.alone)
                self.assertEqual(step.needs, ("bun",))
                self.assertEqual(step.title, f"Web tests ({shard}/4)")
                self.assertTrue(step.run.lstrip().startswith(
                    "python3 -I scripts/ci/web_subareas.py has unit_tests || exit 0"))
                self.assertIn('flock "$CI_TOOLS/bun-install.lock" bun install --frozen-lockfile', step.run)
                self.assertIn(f"./scripts/run-tests.sh --shard {shard}/4 --reporter=junit", step.run)
                self.assertIn(f'report_dir="$RUNNER_TEMP/web-test-junit/shard{shard}"', step.run)
                self.assertIn('exit "$status"', step.run)
                upload = uploads[f"web-test-junit-shard{shard}-attempt${{{{ github.run_attempt }}}}"]
                self.assertEqual(upload["if"], "${{ failure() && !cancelled() }}")
                self.assertEqual(upload["with"]["path"], f"${{{{ runner.temp }}}}/web-test-junit/shard{shard}/junit.xml")
                for path in ("web/app/page.tsx", "web/tests/foo.test.ts", "CHANGELOG.md",
                             "config/iroh/managed-relay-catalog.json", "scripts/ci/web_subareas.py"):
                    self.assertTrue(ci_steps.routed(step, [path]), path)
                self.assertFalse(ci_steps.routed(step, ["webviews/src/main.ts"]))
        build = steps["web-production-build"]
        self.assertEqual(build.job, "linux")
        self.assertEqual(build.timeout, 360)
        # next build writes web/.next/types and web/next-env.d.ts, which the web-typecheck step reads.
        self.assertTrue(build.alone)
        self.assertEqual(build.needs, ("bun",))
        self.assertTrue(build.run.lstrip().startswith(
            "python3 -I scripts/ci/web_subareas.py has production_build || exit 0"))
        self.assertIn('flock "$CI_TOOLS/bun-install.lock" bun install --frozen-lockfile', build.run)
        self.assertIn("bun run vercel-build", build.run)
        build_env = next(s["env"] for s in web_jobs["web-production-build"]["steps"] if s.get("run") == "bun run vercel-build")
        for key, value in build_env.items():
            self.assertIn(f"export {key}={value}", build.run)
        for path in ("web/app/page.tsx", "bun.lock", "vercel.json", "package.json"):
            self.assertTrue(ci_steps.routed(build, [path]), path)
        # These workflows keep the pull_request trigger for a macOS job; the moved Linux job skips it, and
        # a pull request runs it as a step of the table with the same command.
        jobs = {("agent-brands.yml", "drift"): "agent-brands-drift",
                ("terminal-hang-diagnostics.yml", "release-gate"): "terminal-hang-release-gate"}
        for (name, job), step in jobs.items():
            with self.subTest(workflow=name, job=job):
                wf = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
                condition = str(wf["jobs"][job]["if"])  # the land tier may wrap it (tests/test_head_tier.py)
                self.assertTrue(condition == "github.event_name != 'pull_request'"
                                or condition.startswith("${{ (github.event_name != 'pull_request') && "), condition)
                runs = [s["run"] for s in wf["jobs"][job]["steps"] if "run" in s]
                self.assertEqual(runs, [steps[step].run])
                self.assertEqual(steps[step].job, "linux")
        # cmux-next-pr-autofix.yml's generated-drift job keeps its docs-only fallback runs; a pull request into
        # feat-cmux-next runs the generated-drift step, judged by the base's generated_outputs.py.
        autofix = yaml.safe_load((ROOT / ".github/workflows/cmux-next-pr-autofix.yml").read_text())["jobs"]
        self.assertIn(
            "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next' || github.workflow == 'docs-only fallback')",
            autofix["generated-drift"]["if"])
        drift = steps["generated-drift"]
        self.assertEqual((drift.job, drift.inputs), ("linux", ("**",)))
        self.assertLessEqual(drift.timeout, 360)
        self.assertIn("git show 'HEAD^1:scripts/cmux-next/generated_outputs.py'", drift.run)
        self.assertIn("generated-drift-ok", drift.run)
        self.assertIn('generated_outputs.py" drift --changed', drift.run)
        # test-ios.yml's package-conventions-lint job keeps its push, dispatch and other-base runs; a pull request
        # into feat-cmux-next runs its tests and its gate as two steps, routed by detect-ios-changes' should_lint list.
        ios = yaml.safe_load((ROOT / ".github/workflows/test-ios.yml").read_text())["jobs"]
        self.assertTrue(ios["package-conventions-lint"]["if"].endswith(
            "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') }}"))
        lint_run = next(s["run"] for s in ios["package-conventions-lint"]["steps"] if "run" in s)
        tests_step, gate = steps["package-conventions-tests"], steps["package-conventions-gate"]
        for line in tests_step.run.strip().splitlines():
            self.assertIn(line, lint_run)
        self.assertIn("scripts/ci/package-conventions-gate.sh", gate.run)
        self.assertIn("python3 scripts/ci/pr_added_namespace_types.py || exit 1", gate.run)
        self.assertIn("namespace-lint-override", gate.run)
        # --namespace-fix rewrites files: the gate runs alone, in a worktree of its own.
        self.assertTrue(gate.alone)
        self.assertIn('git worktree add --detach "$tree" HEAD', gate.run)
        self.assertEqual(tests_step.inputs, gate.inputs)
        for step in (tests_step, gate):
            self.assertEqual(step.job, "linux")
            self.assertLessEqual(step.timeout, 360)
            for path in ("Packages/iOS/CmuxKit/Sources/A.swift", "ios/App.swift", "scripts/lint_swift_namespaces.py",
                         "scripts/ci/pr_owned_findings.py", "scripts/lint-namespace-types-ratchet.txt"):
                self.assertTrue(ci_steps.routed(step, [path]), (step.name, path))
            for path in ("web/app/page.tsx", "cmux-tui/src/main.rs", "scripts/ci/pr_router.py"):
                self.assertFalse(ci_steps.routed(step, [path]), (step.name, path))

    def test_the_fleet_artifact_edge_tests_run_as_a_step_into_feat_cmux_next(self) -> None:
        # Slice 16: fleet-artifact-cdn.yml's test job keeps its other pull requests, main pushes and the dispatch
        # deploy; a pull request into feat-cmux-next runs its commands as the fleet-artifact-cdn-test step.
        wf = yaml.safe_load((ROOT / ".github/workflows/fleet-artifact-cdn.yml").read_text())
        on = wf.get("on", wf.get(True))
        self.assertEqual(on["pull_request"]["branches-ignore"], ["feat-cmux-next"])
        self.assertEqual(on["push"]["branches"], ["main"])
        self.assertIn("workflow_dispatch", on)
        self.assertEqual(wf["jobs"]["deploy"]["needs"], "test")
        job = wf["jobs"]["test"]
        step = ci_steps.load().steps["fleet-artifact-cdn-test"]
        self.assertEqual((step.job, step.needs), ("linux", ("node",)))
        self.assertFalse(step.alone)
        self.assertLessEqual(step.timeout, min(360, job["timeout-minutes"] * 60))
        self.assertEqual(set(step.inputs), set(on["pull_request"]["paths"]))
        for s in job["steps"]:
            if "run" in s:
                self.assertIn(f"cd {s['working-directory']}\n{s['run']}", step.run)
        for path in ("workers/fleet-artifacts/src/index.mjs", "workers/fleet-artifacts/test/worker.test.mjs",
                     ".github/workflows/fleet-artifact-cdn.yml"):
            self.assertTrue(ci_steps.routed(step, [path]), path)
        for path in ("workers/ci-artifacts/src/index.ts", "workers/device-hub/src/index.ts", "web/app/page.tsx"):
            self.assertFalse(ci_steps.routed(step, [path]), path)

    def test_a_step_that_runs_bun_or_node_says_so(self) -> None:
        # The tools come from [tools], only for a routed step that lists them; nothing else puts bun or node
        # on the linux job's PATH, and the runner image is not assumed to hold either.
        table = ci_steps.load()
        self.assertEqual(sorted(table.tools), ["bun", "go", "node", "rust", "valgrind", "zig", "zlib"])
        wants_bun = {"app-platform", "mux", "automation-bench", "cloud-vm-image-lock", "cmux-vm-sdk", "web-complexity",
                     "web-typecheck", "webviews-typecheck", "diff-sidecar-check", "web-tests-1", "web-tests-2", "web-tests-3",
                     "web-tests-4", "web-production-build", "cmux-vm-cloud"}
        wants_node = {"ci-artifact-worker", "fleet-artifact-cdn-test", "page-strings", "web-complexity",
                      "webviews-typecheck", "cmux-vm-cloud"}
        self.assertEqual(table.steps["remote-daemon-packaging"].needs, ("go",))
        for name, step in table.steps.items():
            if step.job != "linux":
                continue
            with self.subTest(step=name):
                self.assertEqual("bun" in step.needs, name in wants_bun)
                self.assertEqual("node" in step.needs, name in wants_node)
                words = set(re.findall(r"[A-Za-z0-9_./-]+", step.run))
                if words & {"npm", "npx", "node"}:
                    self.assertIn("node", step.needs)
                if words & {"bun"}:
                    self.assertIn("bun", step.needs)

    def test_the_artifact_transport_halves_split_on_workers_ci_artifacts(self) -> None:
        steps = ci_steps.load().steps
        self.assertEqual(steps["ci-artifact-worker"].inputs, ("workers/ci-artifacts/**",))
        self.assertIn("workers/ci-artifacts/**", steps["ci-artifact-transport"].inputs)
        self.assertEqual(steps["ci-artifact-transport"].needs, ())

    def test_the_pipeline_job_runs_on_the_persistent_pool(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        self.assertEqual(
            wf["jobs"]["linux"]["runs-on"],
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && "
            "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || "
            "vars.CI_OVERFLOW_LINUX || 'cmux-linux' }}")

    def test_the_shim_step_runs_every_cpp_script(self) -> None:
        run = ci_steps.load().steps["shim-cpp"].run
        scripts = sorted((ROOT / "scripts" / "cmux-next").glob("test-*-cpp.sh"))
        self.assertGreaterEqual(len(scripts), 10)
        for script in scripts:
            with self.subTest(script=script.name):
                self.assertIn(f"./scripts/cmux-next/{script.name}", run)

    def test_the_job_timeout_covers_setup_and_every_wave(self) -> None:
        # Setup, the tools a routed step needs, then the linux steps two at once (a 2 vCPU runner), each wave as long as the longest step.
        linux = [s for s in ci_steps.load().steps.values() if s.job == "linux"]
        # An `alone` step is a wave of its own.
        shared = [s for s in linux if not s.alone]
        need = (ci_steps.SETUP_TIMEOUT + ci_steps.TOOL_TIMEOUT + -(-len(shared) // 2) * max((s.timeout for s in shared), default=0)
                + sum(s.timeout for s in linux if s.alone))
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        self.assertGreaterEqual(wf["jobs"]["linux"]["timeout-minutes"] * 60, need)


class MacJobTest(unittest.TestCase):
    """The `mac` job: cmux-next.yml's swift-canary and fast-tier jobs on a feat-cmux-next pull request, folded into
    the table (CI v2 step 11). Leo, 2026-11-24: "how about finishing up our borg/ci v2? did we finish all 27+
    things?"
    """

    # Paths cmux_next_route.py routes to the fast tier or the canary, one or more of each kind of input it reads.
    ROUTED = (
        "Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionRegistry.swift",
        "Packages/macOS/CmuxNext/Package.swift",
        "scripts/cmux-next/fast-tier.py",
    )

    def test_it_runs_on_an_owned_mac_and_a_fork_on_blacksmith(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        self.assertEqual(
            wf["jobs"]["mac"]["runs-on"],
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && "
            "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || "
            "'cmux-mac' }}")

    def test_its_mac_setup_steps_keep_their_names(self) -> None:
        # owned_pool_rescue.py reads "Select Xcode"; the lease's holder lives as long as the workflow step.
        job = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())["jobs"]["mac"]
        names = [s.get("name") for s in job["steps"]]
        for name in ("Route the Mac tiers", "Select Xcode", "Keep Swift package builds on this owned Mac",
                     "Restore the CmuxNext build", "Upload fast-tier timing receipt"):
            with self.subTest(name=name):
                self.assertIn(name, names)
        self.assertLess(names.index("Route the Mac tiers"), names.index("Select Xcode"))
        self.assertLess(names.index("Restore the CmuxNext build"),
                        names.index("Run the routed mac steps (ci/steps.toml)"))
        upload = job["steps"][names.index("Upload fast-tier timing receipt")]
        self.assertEqual(upload["with"]["name"],
                         "cmux-next-fast-tier-receipt-${{ github.run_id }}-attempt-${{ github.run_attempt }}")

    def test_each_step_asks_the_router_first(self) -> None:
        steps = [s for s in ci_steps.load().steps.values() if s.job == "mac"]
        self.assertEqual(sorted(s.name for s in steps), ["mac-fast-tier"])
        canary = ci_steps.load().steps["swift-canary"]
        for step in steps + [canary]:
            with self.subTest(step=step.name):
                tier = {"mac-fast-tier": "fast_tier", "swift-canary": "swift_canary"}[step.name]
                first = step.run.strip().splitlines()[0]
                self.assertTrue(first.startswith(f"python3 -I scripts/ci/mac_tiers.py has {tier} "), first)
                self.assertTrue(first.endswith("|| exit 0"), first)
                self.assertTrue(step.inputs and step.blocks)
        self.assertTrue(ci_steps.load().steps["mac-fast-tier"].alone)

    def test_the_canary_compiles_on_the_build_fleet_not_a_mac(self) -> None:
        # Leo, 2026-11-25: "stop waiting on ci to get these fucking things in" (the Mac queue was 175 deep).
        canary = ci_steps.load().steps["swift-canary"]
        self.assertEqual(canary.job, "linux")
        self.assertTrue(canary.alone)
        self.assertIn("scripts/ci/fleet_compile_result.py", canary.run)
        self.assertIn("--phase app-debug", canary.run)
        self.assertNotIn("swift build", canary.run)
        self.assertIn("mac_fallback=swift-canary", canary.run)
        self.assertIn("swift-canary", ci_steps.route(ci_steps.load(), [self.ROUTED[0]]).get("linux", []))
        job = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())["jobs"]["mac"]
        self.assertNotIn("swift_canary", json.dumps(job))

    def test_no_fleet_pass_falls_back_to_a_mac(self) -> None:
        # Leo, 2026-11-25: "having our mac fleet be able to like... exist as fallbacks if we fucked up logic for
        # linux and whatnot is still fine".
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        linux, fb = wf["jobs"]["linux"], wf["jobs"]["mac-fallback"]
        self.assertEqual(linux["outputs"]["mac_fallback"], "${{ steps.run.outputs.mac_fallback }}")
        self.assertEqual(fb["needs"], "linux")
        self.assertEqual(fb["if"], "${{ !cancelled() && needs.linux.outputs.mac_fallback != '' }}")
        self.assertEqual(fb["runs-on"], wf["jobs"]["mac"]["runs-on"])
        run = fb["steps"][-1]["run"]
        self.assertIn('swift build --configuration debug --target "$target"', run)
        self.assertIn("fleet fallback", run)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            tools = Path(tmp) / "tools"
            tools.mkdir()
            env = dict(os.environ, GITHUB_OUTPUT=str(out), CI_TOOLS=str(tools))
            env.pop("GITHUB_EVENT_PATH", None)
            script = ci_steps.load().steps["swift-canary"].run.split("fallback() {", 1)[1]
            script = "word=fail\nfallback() {" + script.replace("swift_canary_targets=", "t=")
            (tools / "canary-tiers.txt").write_text("t=CmuxNextCore CmuxNextApp\n")
            subprocess.run(["bash", "-c", script.replace('"$head"', "abc").replace("$head", "abc")],
                           env=env, check=True, capture_output=True)
            self.assertEqual(out.read_text(), "mac_fallback=swift-canary\ncanary_targets=CmuxNextCore CmuxNextApp\n")

    def test_the_inputs_cover_what_the_router_routes(self) -> None:
        t = ci_steps.load()
        for path in self.ROUTED:
            with self.subTest(path=path):
                self.assertIn("mac-fast-tier", ci_steps.route(t, [path]).get("mac", []))
        self.assertEqual(ci_steps.route(t, ["docs/x.md"]).get("mac"), None)

    def test_a_draft_starts_no_mac(self) -> None:
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        event = {"action": "synchronize", "pull_request": {"draft": True}}
        swift = [self.ROUTED[0]]
        start, why = pr_router.route(event, callees, swift)
        self.assertNotIn("mac-", why["pr-pipeline.yml"])
        self.assertEqual(start, [])
        ready = {"action": "synchronize", "pull_request": {"draft": False}}
        self.assertEqual(pr_router.route(ready, callees, swift)[0], ["pr-pipeline.yml"])

    def test_cmux_next_keeps_them_only_off_the_pull_request(self) -> None:
        jobs = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())["jobs"]
        for name in ("fast-tier", "fast-tier-fleet", "fast-tier-rerun-placement"):
            with self.subTest(job=name):
                self.assertNotIn("github.event_name == 'pull_request' && github.base_ref == 'feat-cmux-next'",
                                 jobs[name]["if"])
                self.assertIn("(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')",
                              jobs[name]["if"])
        for name in ("swift-canary", "swift-canary-fleet"):
            with self.subTest(job=name):
                self.assertIn("&& github.event_name != 'pull_request'", jobs[name]["if"])
                self.assertNotIn("head.repo.full_name == github.repository", jobs[name]["if"])
        placement = jobs["macos-placement"]["steps"]
        text = json.dumps(placement)
        self.assertNotIn("'swift-canary daemon-test generated-files'", text)
        self.assertNotIn("'fast-tier daemon-test generated-files'", text)


class RepositoryAdvisoryStepsTest(unittest.TestCase):
    """The table's own advisory steps, run as the workflow runs them, against this checkout."""

    def test_they_skip_without_listed_paths_and_never_block(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = {
                **os.environ, "RUNNER_TEMP": tmp, "BODY": "x", "TITLE": "docs: a typo", "LABELS": "",
                "PATHS_LISTED": "true", "TREE_LISTED": "true", "ADDITIONS": "1", "DELETIONS": "1",
            }
            env.pop("GITHUB_STEP_SUMMARY", None)
            Path(tmp, "paths.txt").write_text("docs/x.md\n")
            Path(tmp, "status.txt").write_text("M\tdocs/x.md\n")
            Path(tmp, "tree.txt").write_text("docs/x.md\n")
            Path(tmp, "design-surfaces.json").write_text("{}")
            run = subprocess.run(
                [sys.executable, "scripts/ci/ci_steps.py", "run", "--job", "advisory",
                 "--only", "design-spec perf-section cloud-backend"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            for name in ("design-spec", "perf-section", "cloud-backend"):
                self.assertIn(f"::group::{name}", run.stdout)
            for name in PR_CHECKS_STEPS:
                self.assertNotIn(f"::group::{name}", run.stdout)
            self.assertNotIn("::error title", run.stdout)

    def test_the_workflow_runs_the_base_table(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-body-checks.yml").read_text())
        body = wf["jobs"]["body"]
        sparse = body["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("ci/steps.toml", sparse)
        self.assertIn("scripts/ci/ci_steps.py", sparse)
        step = next(s for s in body["steps"] if s.get("name") == "Run the advisory steps")
        self.assertIs(step.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --label "$LABEL" "${only[@]}"', step["run"])
        self.assertIn('only=(--only "capture design-spec perf-section cloud-backend")', step["run"])
        names = [s.get("name", "") for s in body["steps"]]
        for gone in ("Check the description cites each changed surface's spec",
                     "Check the description for a Performance table",
                     "Check where the cloud backend change belongs"):
            self.assertNotIn(gone, names, "the step table runs it")


class PrChecksAdvisoryJobTest(unittest.TestCase):
    """pr-checks.yml's advisory job (CI v2 step 6): its five checks are steps of the table, run from the base."""

    def setUp(self) -> None:
        self.table = ci_steps.load()
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-checks.yml").read_text())
        self.job = wf["jobs"]["advisory"]
        self.steps = {s.get("name"): s for s in self.job["steps"]}

    def test_its_steps_are_advisory_idle_steps_of_the_table(self) -> None:
        for name in PR_CHECKS_STEPS:
            with self.subTest(step=name):
                step = self.table.steps[name]
                self.assertEqual((step.job, step.blocks, step.klass), ("advisory", False, "idle"))
                self.assertFalse(step.labels, "a label event runs only pr-body-checks.yml's steps")
                self.assertLessEqual(step.timeout, 10 * 60, "within the run step's timeout")

    def test_split_plan_fits_its_fetches_in_its_timeout(self) -> None:
        # The window fetch, its ref fallback, the deepen and its fallback: four bounded fetches, then the checker.
        step = self.table.steps["split-plan"]
        bound = int(re.search(r"fetch\(\) \{ timeout (\d+) ", step.run).group(1))
        self.assertEqual(len(re.findall(r"^\s*(?:\|\| )?fetch ", step.run, re.M)), 4, step.run)
        self.assertGreaterEqual(step.timeout, 4 * bound + 30, "the checker gets the step's last half minute")

    def test_it_runs_the_picked_steps_from_the_base_checkout(self) -> None:
        checkout = self.steps["Check out the advisory steps from the base"]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha }}")
        sparse = checkout["with"]["sparse-checkout"].split()
        for path in ("ci/steps.toml", "scripts/ci/ci_steps.py", "scripts/cmux-next/check-pr-split.py"):
            self.assertIn(path, sparse)
        # Every script a step runs is in the sparse checkout.
        for name in PR_CHECKS_STEPS:
            for path in set(__import__("re").findall(r"scripts/[\w./-]+\.py", self.table.steps[name].run)):
                self.assertIn(path, sparse, f"{name} runs {path}")
        run = self.steps["Run the advisory steps"]
        self.assertIs(run.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --only "$PICKED"', run["run"])
        self.assertIn("::notice::The base branch has no step table", run["run"])
        self.assertEqual(run["if"], "steps.pick.outputs.steps != ''", "an empty --only would run every step")

    def test_split_plan_fetches_two_commits_not_every_branch(self) -> None:
        run = self.table.steps["split-plan"].run
        self.assertNotIn("--unshallow origin\n", run)
        self.assertIn('--shallow-since="14 days ago" origin "$BASE_SHA" "$HEAD_SHA"', run)
        self.assertIn("--no-recurse-submodules", run)
        self.assertIn("--filter=blob:none", run)
        self.assertIn('check-pr-split.py --repo "$repo" --base "$BASE_SHA" --head "$HEAD_SHA" --mode advisory', run)

    def test_split_plan_measures_a_local_pull_request(self) -> None:
        self.measure(old=False)

    def test_split_plan_deepens_when_the_merge_base_is_older_than_its_window(self) -> None:
        self.measure(old=True)

    def test_split_plan_deepens_when_the_window_cut_history_inside_the_pull_request(self) -> None:
        # The head merges a recent commit whose parent is older than the window: the merge base is found inside
        # the window, but the old commit under it is cut off, so commits= would miss it without deepening
        # (review F1 on cmux#49211).
        def git(repo: Path, *args: str, old: bool = False) -> str:
            dated = {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
            return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                                  env={**os.environ, **(dated if old else {})}).stdout.strip()

        def commit(repo: Path, name: str, old: bool = False) -> None:
            Path(repo, "webviews", f"{name}.tsx").write_text(f"{name}\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", name, old=old)

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "src")
            Path(src, "webviews").mkdir(parents=True)
            git(src, "init", "-q", "-b", "feat-cmux-next")
            for key, value in (("user.email", "t@example.com"), ("user.name", "t"),
                               ("uploadpack.allowFilter", "true"), ("uploadpack.allowAnySHA1InWant", "true")):
                git(src, "config", key, value)
            commit(src, "root", old=True)
            git(src, "checkout", "-qb", "topic")
            commit(src, "topic-old", old=True)
            commit(src, "topic-new")
            git(src, "checkout", "-q", "feat-cmux-next")
            commit(src, "base-new")
            base = git(src, "rev-parse", "HEAD")
            git(src, "checkout", "-qb", "pr")
            commit(src, "pr-new")
            git(src, "merge", "-q", "--no-edit", "topic")
            head = git(src, "rev-parse", "HEAD")
            whole = subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/check-pr-split.py"), "--repo",
                                    str(src), "--base", base, "--head", head, "--mode", "advisory"],
                                   cwd=ROOT, capture_output=True, text=True, timeout=120)
            counts = re.search(r"merge-base=\S+ head=\S+ files=\d+ commits=\d+", whole.stdout)
            self.assertIsNotNone(counts, whole.stdout + whole.stderr)
            temp = Path(tmp, "temp")
            temp.mkdir()
            env = {**os.environ, "RUNNER_TEMP": str(temp), "URL": f"file://{src}", "PR": "7",
                   "BASE_SHA": base, "HEAD_SHA": head, "BASE_REF": "feat-cmux-next"}
            run = subprocess.run(["bash", "-euo", "pipefail", "-c", self.table.steps["split-plan"].run],
                                 cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("history cut inside the pull request", run.stdout)
            self.assertIn(counts.group(0), run.stdout)

    def measure(self, old: bool) -> None:
        def git(repo: Path, *args: str) -> str:
            dated = {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"}
            return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                                  env={**os.environ, **(dated if old else {})}).stdout.strip()

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "src")
            src.mkdir()
            git(src, "init", "-q", "-b", "feat-cmux-next")
            git(src, "config", "user.email", "t@example.com")
            git(src, "config", "user.name", "t")
            git(src, "config", "uploadpack.allowFilter", "true")
            git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
            Path(src, "a.txt").write_text("a\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "base")
            base = git(src, "rev-parse", "HEAD")
            git(src, "checkout", "-qb", "pr")
            Path(src, "webviews").mkdir()
            Path(src, "webviews/b.tsx").write_text("b\n")
            git(src, "add", "-A")
            git(src, "commit", "-qm", "pr")
            head = git(src, "rev-parse", "HEAD")
            temp = Path(tmp, "temp")
            temp.mkdir()
            env = {**os.environ, "RUNNER_TEMP": str(temp), "URL": f"file://{src}", "PR": "7",
                   "BASE_SHA": base, "HEAD_SHA": head, "BASE_REF": "feat-cmux-next"}
            run = subprocess.run(["bash", "-euo", "pipefail", "-c", self.table.steps["split-plan"].run],
                                 cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(f"merge-base={base} head={head} files=1 commits=1", run.stdout)
            self.assertEqual("No merge base in the last 14 days" in run.stdout, old, run.stdout)

# scripts/ci/ensure-bun.sh: bun VERSION ends up in BIN_DIR, from the PATH, the tool cache or a checked download.
BUN_SCRIPT = ROOT / "scripts/ci/ensure-bun.sh"
BUN_VERSION = "1.4.4"
BUN_OS = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), "")
BUN_ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x64"}.get(platform.machine(), "")


def fake_bun(path: Path, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\necho {version}\n")
    path.chmod(0o755)


@unittest.skipUnless(BUN_OS and BUN_ARCH, "needs macOS or Linux on arm64 or x64")
class EnsureBun(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.cache = self.tmp / "toolcache"
        self.bin = self.tmp / "ci-bin"
        self.path_bin = self.tmp / "path-bin"
        self.path_bin.mkdir()
        self.dist = self.tmp / "dist" / f"bun-v{BUN_VERSION}"
        self.dist.mkdir(parents=True)

    def publish(self, *, corrupt: bool = False, reports: str = BUN_VERSION) -> None:
        name = f"bun-{BUN_OS}-{BUN_ARCH}"
        staged = self.tmp / "staged"
        fake_bun(staged / name / "bun", reports)
        archive = self.dist / f"{name}.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.write(staged / name / "bun", f"{name}/bun")
        digest = "0" * 64 if corrupt else hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.dist / "SHASUMS256.txt").write_text(f"{'f' * 64}  other.zip\n{digest}  {name}.zip\n")

    def run_script(self) -> subprocess.CompletedProcess[str]:
        env = {"PATH": f"{self.path_bin}:/usr/bin:/bin", "HOME": str(self.tmp), "RUNNER_TOOL_CACHE": str(self.cache),
               "ENSURE_BUN_DIST": (self.tmp / "dist").as_uri()}
        return subprocess.run(["bash", str(BUN_SCRIPT), BUN_VERSION, str(self.bin)], env=env, text=True,
                              capture_output=True, timeout=60)

    def test_the_pinned_bun_on_path_is_linked_and_nothing_is_downloaded(self) -> None:
        fake_bun(self.path_bin / "bun", BUN_VERSION)
        done = self.run_script()  # no dist published: a download would fail
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(Path(self.bin / "bun").resolve(), (self.path_bin / "bun").resolve())

    def test_any_other_bun_on_path_is_not_taken(self) -> None:
        # The workflows pinned 1.4.4 exactly: a newer bun a shared host has must not decide frozen installs.
        self.publish()
        for have in ("1.4.5", "1.10.0", "1.4.3", "1.3.14", "2.0.0", "1.4.4-rc.1", "garbage"):
            with self.subTest(have=have):
                fake_bun(self.path_bin / "bun", have)
                done = self.run_script()
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn(f"bun {BUN_VERSION} from", done.stdout)
                self.assertEqual(subprocess.run([self.bin / "bun", "--version"], text=True,
                                                capture_output=True).stdout.strip(), BUN_VERSION)

    def test_a_download_is_checked_unpacked_and_kept_in_the_tool_cache(self) -> None:
        self.publish()
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((self.cache / "bun" / BUN_VERSION / BUN_ARCH / "bun").is_file())
        (self.dist / "SHASUMS256.txt").unlink()  # the second run finds it cached: no network
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("from " + str(self.cache), done.stdout)

    def test_bunx_is_beside_bun_whichever_way_bun_came(self) -> None:
        # setup-bun gave steps `bunx` too; web's playwright webServer runs `bunx next` (#53426: "bunx: not found").
        ways = {"path": lambda: fake_bun(self.path_bin / "bun", BUN_VERSION), "download": self.publish, "cache": lambda: None}
        for way, arrange in ways.items():
            with self.subTest(way=way):
                arrange()
                done = self.run_script()
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(os.readlink(self.bin / "bunx"), "bun")
                self.assertEqual((self.bin / "bunx").resolve(), (self.bin / "bun").resolve())
                (self.bin / "bunx").unlink()
                if way == "path":
                    (self.path_bin / "bun").unlink()

    def test_a_download_that_does_not_match_its_checksum_fails(self) -> None:
        self.publish(corrupt=True)
        done = self.run_script()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("does not match SHASUMS256.txt", done.stdout + done.stderr)
        self.assertFalse((self.bin / "bun").exists())

    def test_a_download_that_reports_another_version_fails(self) -> None:
        self.publish(reports="1.4.3")
        done = self.run_script()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("not " + BUN_VERSION, done.stdout + done.stderr)




class BunInstallLockTest(unittest.TestCase):
    def test_every_bun_install_holds_the_job_lock(self) -> None:
        # Parallel steps share bun's global cache; two installs at once failed copying from it (ENOENT).
        for name, step in ci_steps.load().steps.items():
            for line in step.run.splitlines():
                if line.lstrip().startswith("#"):
                    continue
                if re.search(r"\bbun (install|i)\b", line):
                    with self.subTest(step=name, line=line.strip()):
                        self.assertIn('flock "$CI_TOOLS/bun-install.lock" bun install', line)
                # The bounded wrapper runs `bun install` too; unlocked, web-complexity's install raced
                # web-typecheck's in the same web/node_modules (#55938).
                if "bun-install.sh" in line:
                    with self.subTest(step=name, line=line.strip()):
                        self.assertIn('flock "$CI_TOOLS/bun-install.lock" bash ', line)


class WebBrowserStepsTest(unittest.TestCase):
    """The web-browser job's steps: ci-web.yml's browser jobs on a feat-cmux-next pull request, routed by their
    web subarea (web_subareas.py), which their globs cover and their first line narrows."""

    STEPS = {"web-instant-navigation": "instant", "agent-pane-real-acpmux": "agent_pane"}

    def test_their_globs_cover_the_subarea(self) -> None:
        import web_subareas

        steps = ci_steps.load().steps
        samples = {
            "instant": sorted(web_subareas.INSTANT_EXACT) + [p + "x.ts" for p in web_subareas.INSTANT_PREFIXES],
            "agent_pane": sorted(web_subareas.AGENT_PANE_EXACT) + sorted(web_subareas.REACT_EXACT)
            + [p + "x.ts" for p in web_subareas.AGENT_PANE_PREFIXES + web_subareas.REACT_PREFIXES]
            + ["schemas/settings/x.json", "release-notes/next/highlights/x.md", "web/data/model-catalog/snapshot.json"],
        }
        for name, subarea in self.STEPS.items():
            self.assertEqual(steps[name].job, "web-browser")
            for path in samples[subarea] + sorted(web_subareas.ALL_SUBAREA_INPUTS):
                if not getattr(web_subareas.classify_paths([path], ROOT), subarea):
                    continue
                with self.subTest(step=name, path=path):
                    self.assertTrue(ci_steps.routed(steps[name], [path]))
            self.assertTrue(steps[name].run.lstrip().startswith(f"python3 -I scripts/ci/web_subareas.py has {subarea} || exit 0"))

    def test_has_answers_from_the_listed_paths(self) -> None:
        script = ROOT / "scripts" / "ci" / "web_subareas.py"

        def has(subarea, paths):
            env = {k: v for k, v in os.environ.items() if k != "CI_PATHS_FILE"}
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
                f.write("".join(p + "\n" for p in paths or []))
            if paths is not None:
                env["CI_PATHS_FILE"] = f.name
            try:
                return subprocess.run([sys.executable, "-I", str(script), "has", subarea], cwd=ROOT, env=env,
                                      capture_output=True, text=True, timeout=60).returncode
            finally:
                os.unlink(f.name)

        self.assertEqual(has("instant", ["web/app/page.tsx"]), 0)
        self.assertEqual(has("instant", ["webviews/src/a.ts"]), 1)
        self.assertEqual(has("agent_pane", ["cmux-tui/crates/acpmux/src/lib.rs"]), 0)
        # A standalone webview test other than the two is not the pane's input.
        self.assertEqual(has("agent_pane", ["webviews/test/other.test.ts"]), 1)
        self.assertEqual(has("agent_pane", None), 0)
        self.assertEqual(has("agent_pane", []), 0)
        self.assertNotEqual(has("no_such", ["web/a.ts"]), 0)

    def test_the_real_daemon_lane_routes_on_acpmux_build_inputs_only(self) -> None:
        """agent-pane-real-acpmux builds acpmux: a crate outside its build skips it, and chat-flow-shift-budget (the
        stand-in daemon, no Rust build) skips every cmux-tui/ change."""
        import web_subareas

        built = web_subareas.acpmux_build_crates(str(ROOT))
        self.assertIsNotNone(built)
        self.assertLessEqual({"acpmux", "acpmux-core", "cmux-browser-host"}, built)
        crates = sorted(p.name for p in (ROOT / "cmux-tui" / "crates").iterdir() if (p / "Cargo.toml").is_file())
        outside = [name for name in crates if name not in built]
        self.assertTrue(outside, "some workspace crate is outside acpmux's build")
        for path, pane in [
            ("cmux-tui/crates/acpmux/src/lib.rs", True),
            ("cmux-tui/crates/acpmux-core/src/lib.rs", True),
            ("cmux-tui/crates/cmux-browser-host/js/guide.md", True),
            ("cmux-tui/Cargo.lock", True),
            ("cmux-tui/crates/no-such-crate-yet/src/lib.rs", True),
            (f"cmux-tui/crates/{outside[0]}/src/lib.rs", False),
        ]:
            with self.subTest(path=path):
                areas = web_subareas.classify_paths([path], ROOT)
                self.assertEqual(areas.agent_pane, pane)
                self.assertFalse(areas.chat_flow)
        areas = web_subareas.classify_paths(["webviews/src/a.ts"], ROOT)
        self.assertTrue(areas.agent_pane and areas.chat_flow)
        steps = ci_steps.load().steps
        self.assertTrue(steps["chat-flow-shift-budget"].run.lstrip().startswith(
            "python3 -I scripts/ci/web_subareas.py has chat_flow || exit 0"))
        self.assertFalse(ci_steps.routed(steps["chat-flow-shift-budget"], ["cmux-tui/crates/acpmux/src/lib.rs"]))

    def test_ci_web_skips_them_only_on_a_feat_cmux_next_pull_request(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text())
        for name in self.STEPS:
            with self.subTest(job=name):
                self.assertTrue(wf["jobs"][name]["if"].endswith(
                    "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') }}"))
        status = wf["jobs"]["web-status"]["steps"][0]["run"]
        self.assertIn('may_skip.update({"web-typecheck", "web-tests", "web-production-build", "web-instant-navigation", '
                      '"agent-pane-real-acpmux"})', status)


class RustToolCompileCacheTest(unittest.TestCase):
    """The rust tool's cargo compiles through the runner's own sccache on a persistent GHA pool runner (its
    SCCACHE_DIR outlives the job; the job-done hook wipes target/, so with no wrapper every cmux_next_ daemon test
    run compiled 626 crates cold), keeps a wrapper already set (the fleet's kache), and changes nothing elsewhere."""

    def run_tool(self, **env: str) -> tuple[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            cargo_home, tools, stub_bin, cache = base / "cargo", base / "tools", base / "stub", base / "sccache"
            for d in (cargo_home / "bin", tools, stub_bin, cache):
                d.mkdir(parents=True)
            (cargo_home / "bin" / "rustup").write_text("#!/bin/sh\nexit 0\n")
            (cargo_home / "bin" / "cargo").write_text('#!/bin/sh\necho "wrapper=${RUSTC_WRAPPER:-none} args=$*"\n')
            (stub_bin / "sccache").write_text("#!/bin/sh\nexit 0\n")
            for f in (cargo_home / "bin" / "rustup", cargo_home / "bin" / "cargo", stub_bin / "sccache"):
                f.chmod(0o755)
            full = {"PATH": f"{stub_bin}:/usr/bin:/bin", "HOME": tmp, "CARGO_HOME": str(cargo_home),
                    "CI_TOOLS": str(tools), "GITHUB_ACTIONS": "true", "SCCACHE_DIR": str(cache)}
            full.update(env)
            full = {k: v for k, v in full.items() if v != ""}
            subprocess.run(["bash", "-euo", "pipefail", "-c", ci_steps.load().tools["rust"]], env=full, check=True,
                           capture_output=True, text=True, cwd=ROOT)
            said = subprocess.run([str(tools / "bin" / "cargo"), "test", "-p", "x"], env=full, check=True,
                                  capture_output=True, text=True).stdout.strip()
            return said, str(stub_bin / "sccache")

    def test_a_pool_runner_with_sccache_compiles_through_it(self) -> None:
        said, sccache = self.run_tool()
        self.assertEqual(said, f"wrapper={sccache} args=test -p x")

    def test_a_wrapper_already_set_is_kept(self) -> None:
        said, _ = self.run_tool(RUSTC_WRAPPER="/opt/kache/kache")
        self.assertEqual(said, "wrapper=/opt/kache/kache args=test -p x")

    def test_no_sccache_dir_or_not_actions_is_as_before(self) -> None:
        for env in ({"SCCACHE_DIR": ""}, {"GITHUB_ACTIONS": ""}):
            with self.subTest(env=env):
                said, _ = self.run_tool(**env)
                self.assertEqual(said, "wrapper=none args=test -p x")


class IosJobTest(unittest.TestCase):
    """The `ios` job: cmux-next-ios-kit.yml's kit tests and ios-reliability-matrix.yml's protocol and phone legs on a
    feat-cmux-next pull request, folded into the table (CI v2 step 11). Leo, 2026-11-24: "how about finishing up
    our borg/ci v2? did we finish all 27+ things?"
    """

    def wf(self) -> dict:
        return yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())

    def test_it_runs_where_the_picker_places_it_and_a_fork_on_blacksmith(self) -> None:
        jobs = self.wf()["jobs"]
        self.assertEqual(jobs["ios-macos"]["runs-on"], jobs["mac"]["runs-on"])
        self.assertEqual(jobs["ios"]["needs"], ["ios-runner"])
        self.assertEqual(
            jobs["ios"]["runs-on"],
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && "
            "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || "
            "fromJSON(github.run_attempt > 1 && needs.ios-runner.outputs.retry_runs_on || "
            "needs.ios-runner.outputs.runs_on) }}")
        for picker in ("ios-runner", "ios-fast-runner"):
            steps = jobs[picker]["steps"]
            pick = next(s for s in steps if s.get("id") == "pool")
            self.assertIn('--lane pipeline', pick["run"])
            self.assertIn('--order "$POOL_ORDER"', pick["run"])
            self.assertEqual(pick["env"]["POOL_ORDER"], "${{ vars.CI_PR_POOL_ORDER }}")
            sparse = steps[0]["with"]["sparse-checkout"].splitlines()
            self.assertTrue("scripts/ci/xcode-pins.txt" in sparse or "scripts/ci/" in sparse, picker)
        names = [s.get("name") for s in jobs["ios"]["steps"]]
        # owned_pool_rescue.py reads "Select Xcode"; it comes before the steps that need Xcode.
        self.assertLess(names.index("Select Xcode"), names.index("Run the routed ios steps (ci/steps.toml)"))

    def test_the_pipeline_lane_is_not_sim_first(self) -> None:
        import ios_runner_pool

        self.assertIn("pipeline", ios_runner_pool.LANES)
        self.assertNotIn("pr-router.yml", getattr(ios_runner_pool, "IOS_WORKFLOWS", ()))

    def test_each_mac_step_runs_alone(self) -> None:
        steps = {s.name: s for s in ci_steps.load().steps.values() if s.job == "ios"}
        self.assertEqual(sorted(steps), ["ios-kit", "ios-kit-macos", "ios-phone-cells"])
        for step in steps.values():
            with self.subTest(step=step.name):
                self.assertTrue(step.alone)
                self.assertIn("rust", step.needs)
        self.assertTrue(ci_steps.load().steps["ios-matrix-protocol"].alone)

    def test_markdown_and_verify_paths_take_no_mac(self) -> None:
        t = ci_steps.load()
        self.assertNotIn("ios", ci_steps.route(t, ["cmux-next-ios/README.md"]))
        self.assertNotIn("ios", ci_steps.route(t, ["cmux-next-ios/verify/x.swift"]))
        self.assertEqual(ci_steps.route(t, ["cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileModel/Resources/notes.md"])
                         .get("ios"), ["ios-kit-macos", "ios-kit"])
        self.assertEqual(ci_steps.route(t, ["cmux-next-ios/CmuxKit/Sources/CmuxKit/A.swift"]).get("ios"),
                         ["ios-kit-macos", "ios-kit"])

    def test_the_macos_swift_test_runs_beside_the_simulator_leg(self) -> None:
        # Goal ios-ci-under-5min: the kit's macOS swift test ran before the simulator leg in one step on one Mac;
        # now it is ios-kit-macos, which the `ios macos` job runs beside the `ios` job, and ios is the longer leg.
        steps = ci_steps.load().steps
        kit, macos = steps["ios-kit"], steps["ios-kit-macos"]
        self.assertIn("swift test --package-path cmux-next-ios/CmuxMobileKit", macos.run)
        self.assertNotIn("swift test --package-path", kit.run)
        self.assertIn("xcodebuild test", kit.run)
        self.assertNotIn("xcodebuild", macos.run)
        for step in (kit, macos):
            with self.subTest(step=step.name):
                self.assertIn("bash scripts/ci/ios_link_ffi.sh 8", step.run)
                self.assertIn("git diff --exit-code -- cmux-next-ios/", step.run)
                # The run text names no event variable, so a pass is still reused.
                self.assertFalse([v for v in ci_steps.EVENT_VARS if v in step.run])
        # The same inputs, so the macOS leg routes exactly when the simulator leg does; ios-kit also reads the
        # macOS leg's verdict through the helper.
        self.assertEqual(set(kit.inputs) - set(macos.inputs), {"scripts/ci/ios_macos_leg.py"})
        self.assertEqual(set(macos.inputs) - set(kit.inputs), set())
        self.assertEqual(kit.ignore, macos.ignore)
        # The ordering rule both legs had in one step: a red macOS leg skips the simulator and fails ios-kit.
        self.assertEqual(kit.run.count("python3 -I scripts/ci/ios_macos_leg.py state"), 2)
        self.assertLess(kit.run.index("ios_macos_leg.py state"), kit.run.index("xcodebuild test"))
        jobs = self.wf()["jobs"]
        leg = jobs["ios-macos"]
        self.assertEqual(leg["name"], "ios macos")
        self.assertNotIn("needs", leg)
        self.assertEqual(jobs["ios"]["permissions"]["actions"], "read")
        ios_run = next(s for s in jobs["ios"]["steps"] if s.get("name") == "Run the routed ios steps (ci/steps.toml)")
        self.assertEqual(ios_run["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn('if n != "ios-kit-macos"', ios_run["run"])
        self.assertIn('--only "$only"', ios_run["run"])

    def test_the_ios_jobs_only_list_leaves_the_macos_leg_out(self) -> None:
        jobs = self.wf()["jobs"]
        run = next(s["run"] for s in jobs["ios"]["steps"] if s.get("name") == "Run the routed ios steps (ci/steps.toml)")
        pick = run.split("python3 -I -c '", 1)[1].split("')\"", 1)[0]
        for routed, want in ((["ios-kit-macos", "ios-kit", "ios-phone-cells"], "ios-kit ios-phone-cells"),
                             (["ios-phone-cells"], "ios-phone-cells"), (["ios-kit-macos"], "none"), ([], "none")):
            with self.subTest(routed=routed):
                got = subprocess.run([sys.executable, "-I", "-c", pick], input=json.dumps({"ios": routed}),
                                     capture_output=True, text=True, check=True).stdout.strip()
                self.assertEqual(got, want)

    def test_the_old_workflows_keep_every_trigger_but_the_pull_request(self) -> None:
        for name, kept in (("cmux-next-ios-kit.yml", {"push", "workflow_dispatch"}),
                           ("ios-reliability-matrix.yml", {"push", "workflow_dispatch", "schedule"})):
            with self.subTest(workflow=name):
                on = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())[True]
                self.assertNotIn("pull_request", on)
                self.assertLessEqual(kept, set(on))


class IosMacosLegTest(unittest.TestCase):
    """scripts/ci/ios_macos_leg.py: the `ios macos` job's verdict so far, which ios-kit reads before and after its
    simulator leg; an unread one runs the simulator, as a green one does."""

    ENV = {"GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "2", "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "t"}

    def state(self, jobs, env=None) -> tuple[str, list[str]]:
        import ios_macos_leg

        asked: list[str] = []

        def read(path: str) -> dict:
            asked.append(path)
            if isinstance(jobs, Exception):
                raise jobs
            return {"jobs": jobs}
        return ios_macos_leg.state(dict(self.ENV if env is None else env), read), asked

    def test_it_reads_the_leg_of_this_run_attempt(self) -> None:
        def job(status, conclusion=None, name="pr pipeline / ios macos"):
            return {"name": name, "status": status, "conclusion": conclusion}
        other = job("completed", "failure", "pr pipeline / ios")
        cases = (([other, job("completed", "failure")], "failure"), ([job("completed", "timed_out")], "failure"),
                 ([job("completed", "cancelled")], "failure"), ([job("completed", "success")], "success"),
                 ([job("completed", "skipped")], "unknown"), ([job("in_progress")], "pending"),
                 ([job("queued", name="ios macos")], "pending"), ([other], "unknown"), ([], "unknown"))
        for jobs, want in cases:
            with self.subTest(jobs=jobs):
                got, asked = self.state(jobs)
                self.assertEqual(got, want)
                self.assertEqual(asked[0], "/repos/o/r/actions/runs/7/attempts/2/jobs?per_page=100&page=1")

    def test_it_fails_open(self) -> None:
        self.assertEqual(self.state(RuntimeError("HTTP 403"))[0], "unknown")
        self.assertEqual(self.state([], {k: v for k, v in self.ENV.items() if k != "GITHUB_RUN_ID"}), ("unknown", []))
        import ios_macos_leg

        self.assertEqual(ios_macos_leg.state({k: v for k, v in self.ENV.items() if k != "GH_TOKEN"}), "unknown")

    def test_it_turns_the_pages_until_it_finds_the_leg(self) -> None:
        import ios_macos_leg

        pages = {1: [{"name": f"j{i}", "status": "completed", "conclusion": "success"} for i in range(100)],
                 2: [{"name": "pr pipeline / ios macos", "status": "completed", "conclusion": "failure"}]}
        asked: list[str] = []

        def read(path: str) -> dict:
            asked.append(path)
            return {"jobs": pages.get(int(path.rsplit("=", 1)[1]), [])}
        self.assertEqual(ios_macos_leg.state(dict(self.ENV), read), "failure")
        self.assertEqual(len(asked), 2)

    def test_the_cli_prints_one_word_and_exits_zero(self) -> None:
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        got = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/ios_macos_leg.py"), "state"], env=env,
                             capture_output=True, text=True)
        self.assertEqual((got.returncode, got.stdout), (0, "unknown\n"))


class CrateStore:
    def __init__(self, hits: dict[str, str] | None = None) -> None:
        self.hits = hits or {}  # step name -> key that passed
        self.asked: list[tuple[str, str, bool]] = []
        self.posted: list[tuple[str, str, str, bool]] = []
        self.error = ""

    def lookup(self, key: str, step: str, audit: bool = False) -> dict | None:
        self.asked.append((key, step, audit))
        return {"key": key, "run_url": "r"} if self.hits.get(step) == key else None

    def post(self, key: str, step: str, outcome: str, seconds: float, audit: bool = False) -> None:
        self.posted.append((key, step, outcome, audit))


class CrateResults(unittest.TestCase):
    """scripts/ci/crate_results.py: cmux-next-daemon-tests keyed per crate (its files, its path dependencies', what
    its sources name outside it), so a change to one crate reruns only the crates that reach it."""

    TREE = {
        "cmux-tui/Cargo.toml": '[workspace]\nmembers = ["crates/a", "crates/b", "crates/c"]\n'
                               '[workspace.dependencies]\nc = { path = "crates/c" }\n',
        "cmux-tui/Cargo.lock": "# lock\n",
        "cmux-tui/crates/a/Cargo.toml": '[package]\nname = "a"\n',
        "cmux-tui/crates/a/src/lib.rs": 'const X: &str = include_str!("../../../../shared/x.txt");\n'
                                        'fn p() { let _ = std::path::Path::new("..").join("crates"); }\n',
        "cmux-tui/crates/a/tests/ta.rs": "#[test] fn cmux_next_a() {}\n",
        "cmux-tui/crates/b/Cargo.toml": '[package]\nname = "b"\n[dev-dependencies]\nc = { workspace = true }\n',
        "cmux-tui/crates/b/src/lib.rs": "pub fn b() {}\n",
        "cmux-tui/crates/b/tests/tb.rs": "#[test] fn cmux_next_b() {}\n",
        "cmux-tui/crates/c/Cargo.toml": '[package]\nname = "c"\n',
        "cmux-tui/crates/c/src/lib.rs": "pub fn c() {}\n",
        "shared/x.txt": "x\n",
        "other/y.txt": "y\n",
    }
    ARGS = ["-p", "a", "-p", "b", "--lib", "--test", "ta", "--test", "tb"]

    def repo(self, changes: dict[str, str] | None = None) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(root)])
        for path, text in {**self.TREE, **(changes or {})}.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "t"], cwd=root, check=True)
        return root

    def keys(self, changes: dict[str, str] | None = None) -> dict[str, str]:
        root = self.repo(changes)
        ws = crate_results.Workspace(crate_results.tree_files(root), crate_results.disk_reader(root))
        return {n: crate_results.crate_key(ws, f, n, fl, ts, crate_results.step_doc({})) for n, f, fl, ts in crate_results.crates(ws, self.ARGS)}

    def test_a_crate_key_moves_with_its_files_its_path_deps_and_what_it_names_outside_it(self):
        base = self.keys()
        dep = self.keys({"cmux-tui/crates/c/src/lib.rs": "pub fn c() { 1; }\n"})
        self.assertEqual(dep["a"], base["a"], "a does not reach c")
        self.assertNotEqual(dep["b"], base["b"], "b reaches c through a workspace dev-dependency")
        named = self.keys({"shared/x.txt": "changed\n"})
        self.assertNotEqual(named["a"], base["a"], "a's include_str! names shared/x.txt")
        self.assertEqual(named["b"], base["b"])
        self.assertEqual(self.keys({"other/y.txt": "z\n"}), base, "a file no crate reads moves no key")
        self.assertNotEqual(self.keys({"cmux-tui/Cargo.lock": "# other\n"})["a"], base["a"], "the lock moves all")

    def test_crate_step_names_are_ones_the_store_takes(self):
        # build-fleet/cmd/controller/step_results.go stepResultStepRE: a name outside it is refused, every lookup misses.
        store = CrateStore()
        self.plan(store)
        self.assertTrue(store.asked)
        for _key, step, _audit in store.asked:
            self.assertRegex(step, r"^[A-Za-z0-9._-]{1,80}$")

    def test_a_climb_to_a_folder_around_the_crate_names_nothing(self):
        root = self.repo()
        ws = crate_results.Workspace(crate_results.tree_files(root), crate_results.disk_reader(root))
        self.assertNotIn("cmux-tui/crates/b/src/lib.rs", ws.inputs("cmux-tui/crates/a"))

    def plan(self, store, args=None, env=None):
        root = self.repo()
        state = root / "state.json"
        out = io.StringIO()
        runs = crate_results.plan(state, list(args or self.ARGS), env or {}, root=root, store=store, out=out)
        return runs, state, out.getvalue()

    def test_a_crate_whose_key_passed_before_does_not_run(self):
        keys = self.keys()
        runs, state, out = self.plan(CrateStore({"crate.a": keys["a"]}))
        self.assertEqual(runs, ["-p", "b", "--lib", "--test", "tb"])
        self.assertIn("a reused", out)
        store = CrateStore()
        crate_results.post(state, {}, store=store)
        self.assertEqual([(k, s) for k, s, *_ in store.posted], [(keys["b"], "crate.b")])

    def test_every_crate_reused_runs_nothing(self):
        keys = self.keys()
        runs, state, _ = self.plan(CrateStore({"crate.a": keys["a"], "crate.b": keys["b"]}))
        self.assertEqual(runs, [])
        store = CrateStore()
        crate_results.post(state, {}, store=store)
        self.assertEqual(store.posted, [])

    def test_an_audited_hit_runs_and_posts_as_an_audit(self):
        keys = self.keys()
        with mock.patch.object(crate_results.ci_steps, "audited", lambda key, env: key == keys["a"]):
            runs, state, out = self.plan(CrateStore({"crate.a": keys["a"]}))
        self.assertIn("-p", runs)
        self.assertIn("a", runs)
        store = CrateStore()
        crate_results.post(state, {}, store=store)
        self.assertIn((keys["a"], "crate.a", "pass", True), store.posted)

    def test_what_it_cannot_split_or_ask_runs_every_crate(self):
        self.assertEqual(self.plan(CrateStore(), ["--workspace"])[0], ["--workspace"])
        self.assertEqual(self.plan(CrateStore(), ["-p", "nope"])[0], ["-p", "nope"])
        self.assertEqual(self.plan(CrateStore(), ["-p", "a", "--test", "nope"])[0], ["-p", "a", "--test", "nope"])
        with mock.patch.object(crate_results.ci_steps.StepResults, "from_env", return_value=None):
            runs, _state, out = self.plan(None)
        self.assertEqual(runs, self.ARGS)
        self.assertIn("no store", out)

    def test_a_broken_plan_runs_every_crate_and_only_reused_all_skips(self):
        out = io.StringIO()
        with mock.patch.object(crate_results, "plan", side_effect=RuntimeError("boom")), \
                mock.patch("sys.stdout", out), mock.patch("sys.stderr", io.StringIO()):
            crate_results.main(["plan", "/dev/null", "--", "-p", "a"])
        self.assertEqual(out.getvalue().strip(), "-p a")
        out = io.StringIO()
        with mock.patch.object(crate_results, "plan", return_value=[]), mock.patch("sys.stdout", out):
            crate_results.main(["plan", "/dev/null", "--", "-p", "a"])
        self.assertEqual(out.getvalue().strip(), crate_results.REUSED_ALL)

    def plan_change(self, paths, store=None, root=None, gone=()):
        """plan() for a change of `paths` (CI_PATHS_FILE, as ci_steps hands a step), `gone` deleted from the tree."""
        root = root or self.repo()
        for path in gone:
            subprocess.run(["git", "rm", "-q", path], cwd=root, check=True)
        listed = root / "changed-paths.txt"
        listed.write_text("".join(f"{p}\n" for p in paths))
        out = io.StringIO()
        runs = crate_results.plan(root / "state.json", list(self.ARGS), {"CI_PATHS_FILE": str(listed)}, root=root,
                                  store=CrateStore() if store is None else store, out=out)
        return runs, out.getvalue()

    def test_a_crate_no_changed_path_reaches_does_not_run(self):
        runs, out = self.plan_change(["cmux-tui/crates/c/src/lib.rs"])
        self.assertEqual(runs, ["-p", "b", "--lib", "--test", "tb"], "only b reaches c")
        self.assertIn("a not reached", out)
        runs, _ = self.plan_change(["shared/x.txt"])
        self.assertEqual(runs, ["-p", "a", "--lib", "--test", "ta"], "a's include_str! names shared/x.txt")
        runs, out = self.plan_change(["other/y.txt", "cmux-next-ios/App.swift"])
        self.assertEqual(runs, [], "a change no crate reads runs none: the step prints REUSED_ALL")
        self.assertIn("2 of 2 crates not reached", out)

    def test_a_deleted_path_still_reaches_the_crate_that_named_it(self):
        runs, _ = self.plan_change(["shared/x.txt"], gone=["shared/x.txt"])
        self.assertEqual(runs, ["-p", "a", "--lib", "--test", "ta"])
        runs, _ = self.plan_change(["cmux-tui/crates/c/src/old.rs"])
        self.assertEqual(runs, ["-p", "b", "--lib", "--test", "tb"], "a file c no longer has is still c's")

    def test_what_it_cannot_place_reaches_every_crate(self):
        for paths in (["cmux-tui/Cargo.lock"], ["ci/steps.toml"], ["schemas/settings/x.json"],
                      ["scripts/ci/crate_results.py"], ["ghostty-next"]):
            self.assertEqual(self.plan_change(paths)[0], self.ARGS, paths)
        root = self.repo()
        runs = crate_results.plan(root / "state.json", list(self.ARGS), {}, root=root, store=CrateStore(),
                                  out=io.StringIO())
        self.assertEqual(runs, self.ARGS, "no CI_PATHS_FILE: the change is unknown, every crate runs")

    def test_a_crate_not_reached_is_one_whose_key_the_change_leaves(self):
        # The narrowing is never weaker than the key: a crate it drops is one whose stored pass would have hit.
        base = self.keys()
        for changes in ({"cmux-tui/crates/c/src/lib.rs": "pub fn c() { 2; }\n"}, {"shared/x.txt": "y\n"},
                        {"other/y.txt": "w\n"}, {"cmux-tui/crates/b/src/lib.rs": "pub fn b() { 3; }\n"}):
            root = self.repo(changes)
            ws = crate_results.Workspace(crate_results.tree_files(root), crate_results.disk_reader(root))
            planned = crate_results.crates(ws, self.ARGS)
            moved = self.keys(changes)
            skipped = crate_results.unreached(ws, planned, list(changes), io.StringIO())
            self.assertTrue(skipped, changes)
            for name in skipped:
                self.assertEqual(moved[name], base[name], (changes, name))

    def test_no_store_still_skips_what_the_change_does_not_reach(self):
        with mock.patch.object(crate_results.ci_steps.StepResults, "from_env", return_value=None):
            root = self.repo()
            listed = root / "changed-paths.txt"
            listed.write_text("cmux-tui/crates/c/src/lib.rs\n")
            out = io.StringIO()
            runs = crate_results.plan(root / "state.json", list(self.ARGS), {"CI_PATHS_FILE": str(listed)},
                                      root=root, out=out)
        self.assertEqual(runs, ["-p", "b", "--lib", "--test", "tb"])
        self.assertIn("no store", out.getvalue())

    def test_the_step_plans_by_crate_and_posts_only_after_a_pass(self):
        run = ci_steps.load().steps[crate_results.STEP].run
        self.assertIn("crate_results.py plan", run)
        self.assertIn('[ "$plan" = REUSED_ALL ]', run)
        self.assertIn('[ -n "$plan" ] || plan="$all_members"', run, "an empty plan runs every crate")
        self.assertIn('[ "$status" -ne 0 ] || python3 ../scripts/ci/crate_results.py post', run)
        self.assertLess(run.index("crate_results.py plan"), run.index("rustup toolchain install"),
                        "a step whose crates all hit installs and compiles nothing")
        self.assertIn("scripts/ci/crate_results.py", ci_steps.load().steps[crate_results.STEP].inputs)


if __name__ == "__main__":
    unittest.main()
