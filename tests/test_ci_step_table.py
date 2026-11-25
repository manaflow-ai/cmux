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
from test_ci_post_merge_checks import BASE, branch_matches, load_workflows, triggers  # noqa: E402


def table(steps: str, jobs: str = 'linux = "l"\nadvisory = "a"') -> ci_steps.Table:
    import tomllib

    return ci_steps.parse(tomllib.loads(f"[jobs]\n{jobs}\n{textwrap.dedent(steps)}"))


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

    def test_the_pr_tier_leaves_push_steps_to_the_push_tier(self) -> None:
        t = table('''
            [step.fast]
            job = "linux"
            run = "true"
            [step.slow]
            job = "linux"
            tier = "push"
            run = "true"
            ''')
        self.assertEqual(ci_steps.route(t, None)["linux"], ["fast", "slow"])
        self.assertEqual(ci_steps.route(t, None, tier="full")["linux"], ["fast", "slow"])
        self.assertEqual(ci_steps.route(t, None, tier="pr")["linux"], ["fast"])
        self.assertEqual(ci_steps.route(table('[step.slow]\njob = "linux"\ntier = "push"\nrun = "true"'), None, tier="pr"), {})
        with self.assertRaisesRegex(ci_steps.TableError, "`tier` is one of"):
            table('[step.a]\njob = "linux"\ntier = "later"\nrun = "true"')

    def test_the_tables_tool_steps_are_push_tier_and_the_workflow_runs_the_pr_tier(self) -> None:
        for step in ci_steps.load().steps.values():
            if step.job == "linux" and step.needs:
                self.assertEqual(step.tier, "push", step.name)
        text = (ROOT / ".github/workflows/pr-pipeline.yml").read_text()
        self.assertIn('ci/run run --job linux --tier "$TIER"', text)
        self.assertIn("CI_PR_PIPELINE_TIER", text)
        self.assertIn("full-ci", text)

    def test_the_router_counts_only_the_pr_tier_steps(self) -> None:
        import pr_router
        callees = pr_router.load_manifest()
        files = ["cmux-tui/crates/acpmux/src/lib.rs"]
        self.assertEqual(pr_router.pipeline_tier(set()), "pr")
        self.assertEqual(pr_router.pipeline_tier({"full-ci"}), "full")
        full = pr_router.table_steps(callees["pr-pipeline.yml"], files, tier="full")
        pr = pr_router.table_steps(callees["pr-pipeline.yml"], files, tier="pr")
        self.assertIn("cmux-next-daemon-tests", full)
        self.assertNotIn("cmux-next-daemon-tests", pr)

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

    def test_the_tables_coderouter_runs_alone(self) -> None:
        # Its cargo build takes every core; broker.test.mjs's 50 ms deadline failed beside it, twice.
        self.assertTrue(ci_steps.load().steps["coderouter"].alone)


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
        self.assertEqual(job["permissions"], {"contents": "read"})
        checkout = job["steps"][0]
        self.assertEqual(checkout["with"]["fetch-depth"], 2)
        self.assertIs(checkout["with"]["persist-credentials"], False)
        runs = [i for i, s in enumerate(job["steps"]) if "ci/run run --job linux" in s.get("run", "")]
        self.assertEqual(len(runs), 1)
        # After it only the failure-only upload of a fixit-compile patch (the web-typecheck step's), for the
        # cmuxterm-hq reconciler, which reads a run's `fixit-compile-*` artifacts.
        after = job["steps"][runs[0] + 1:]
        self.assertEqual([s["name"] for s in after], ["Upload the fixit-compile patch"])
        self.assertEqual(after[0]["if"], "${{ failure() && !cancelled() }}")
        self.assertTrue(after[0]["uses"].startswith("actions/upload-artifact@"))
        self.assertTrue(after[0]["with"]["name"].startswith("fixit-compile-"))
        self.assertEqual(after[0]["with"]["path"], "${{ runner.temp }}/fixit-compile")
        self.assertEqual(after[0]["with"]["if-no-files-found"], "ignore")

    def test_the_router_starts_it_only_when_a_step_is_routed(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        self.assertEqual(callees["pr-pipeline.yml"]["table_jobs"], ["linux", "web-browser"])
        self.assertIs(callees["pr-pipeline.yml"].get("draft"), True, "the workflows it replaced ran on drafts")

        def started(files, **pr):
            event = {"action": "synchronize", "pull_request": pr}
            return pr_router.route(event, callees, files)

        start, why = started(["web/app/lib/indexnow.ts"])
        self.assertEqual(start, ["pr-pipeline.yml"])
        self.assertIn("indexnow", why["pr-pipeline.yml"])
        self.assertEqual(started(["docs/x.md"])[0], [])
        self.assertEqual(started(["web/app/lib/indexnow.ts"], draft=True)[0], ["pr-pipeline.yml"])
        self.assertEqual(started(None)[0], ["pr-pipeline.yml"])
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
        # Unknown changes or an unreadable table run every job.
        self.assertEqual(routed(callees, None), ["linux", "web-browser"])
        self.assertEqual(routed(callees, ["docs/x.md"], ROOT / "no-such.toml"), ["linux", "web-browser"])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}):
                pr_router.write_outputs(["pr-pipeline.yml"], {}, ["webviews/a.ts"], ["web-browser"])
            self.assertIn('table=["web-browser"]\n', out.read_text())
        router = yaml.safe_load((ROOT / ".github/workflows/pr-router.yml").read_text())
        self.assertEqual(router["jobs"]["route"]["outputs"]["table"], "${{ steps.route.outputs.table }}")
        self.assertEqual(router["jobs"]["pipeline"]["with"], {"jobs": "${{ needs.route.outputs.table || '' }}"})

    def test_each_pipeline_job_runs_only_when_routed(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        on = wf.get("on", wf.get(True))
        self.assertEqual(on["workflow_call"]["inputs"]["jobs"]["default"], "")
        table_jobs = set(ci_steps.load().jobs) - {"advisory", "verdict"}
        for name, job in wf["jobs"].items():
            with self.subTest(job=name):
                self.assertIn(name, table_jobs, "a pr-pipeline.yml job is a job of ci/steps.toml")
                self.assertEqual(job["if"], f"${{{{ inputs.jobs == '' || contains(fromJSON(inputs.jobs), '{name}') }}}}")
                runs = [s for s in job["steps"] if f"ci/run run --job {name} " in s.get("run", "")]
                self.assertEqual(len(runs), 1)
                self.assertEqual(job["steps"][0]["with"]["fetch-depth"], 2)
                self.assertIs(job["steps"][0]["with"]["persist-credentials"], False)
                self.assertEqual(job["runs-on"], wf["jobs"]["linux"]["runs-on"])
                steps = [s for s in ci_steps.load().steps.values() if s.job == name]
                shared = [s for s in steps if not s.alone]
                need = (ci_steps.SETUP_TIMEOUT + ci_steps.TOOL_TIMEOUT
                        + -(-len(shared) // 2) * max((s.timeout for s in shared), default=0)
                        + sum(s.timeout for s in steps if s.alone))
                self.assertGreaterEqual(job["timeout-minutes"] * 60, need)

    def test_the_changed_paths_are_nul_separated(self) -> None:
        # Without -z git quotes a non-ASCII path, which then matches no step's inputs: green, nothing run.
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-pipeline.yml").read_text())
        self.assertIn("git diff --name-only --no-renames -z ", wf["jobs"]["linux"]["steps"][1]["run"])
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
                 "cmux-next-remote-daemon.yml": "remote-daemon-packaging"}
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
        # coderouter-ci.yml also ran for pull requests into main, which the table does not serve: it keeps those.
        wf = yaml.safe_load((ROOT / ".github/workflows/coderouter-ci.yml").read_text())
        self.assertEqual(wf.get("on", wf.get(True))["pull_request"]["branches-ignore"], ["feat-cmux-next"])
        self.assertEqual(steps["coderouter"].job, "linux")
        # So did web-complexity.yml.
        wf = yaml.safe_load((ROOT / ".github/workflows/web-complexity.yml").read_text())
        self.assertEqual(wf.get("on", wf.get(True))["pull_request"]["branches-ignore"], ["feat-cmux-next"])
        self.assertEqual(steps["web-complexity"].job, "linux")
        # cmux-vm-clients.yml keeps its rust job's pull requests; its moved sdk job skips only feat-cmux-next's.
        wf = yaml.safe_load((ROOT / ".github/workflows/cmux-vm-clients.yml").read_text())
        self.assertEqual(wf["jobs"]["sdk"]["if"],
                         "${{ github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next' }}")
        self.assertNotIn("if", wf["jobs"]["rust"])
        self.assertEqual(steps["cmux-vm-sdk"].job, "linux")
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
        self.assertEqual(wf["jobs"]["security-holes"]["if"],
                         "${{ (github.event.action != 'ready_for_review') && (github.event_name == 'pull_request' && "
                         "(github.base_ref != 'feat-cmux-next' || github.workflow == 'docs-only fallback')) }}")
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
        # These workflows keep the pull_request trigger for a macOS job; the moved Linux job skips it, and
        # a pull request runs it as a step of the table with the same command.
        jobs = {("agent-brands.yml", "drift"): "agent-brands-drift",
                ("terminal-hang-diagnostics.yml", "release-gate"): "terminal-hang-release-gate"}
        for (name, job), step in jobs.items():
            with self.subTest(workflow=name, job=job):
                wf = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
                self.assertEqual(wf["jobs"][job]["if"], "github.event_name != 'pull_request'")
                runs = [s["run"] for s in wf["jobs"][job]["steps"] if "run" in s]
                self.assertEqual(runs, [steps[step].run])
                self.assertEqual(steps[step].job, "linux")

    def test_a_step_that_runs_bun_or_node_says_so(self) -> None:
        # The tools come from [tools], only for a routed step that lists them; nothing else puts bun or node
        # on the linux job's PATH, and the runner image is not assumed to hold either.
        table = ci_steps.load()
        self.assertEqual(sorted(table.tools), ["bun", "go", "node", "rust", "zig", "zlib"])
        wants_bun = {"app-platform", "mux", "automation-bench", "cloud-vm-image-lock", "cmux-vm-sdk", "web-complexity",
                     "web-typecheck", "webviews-typecheck"}
        wants_node = {"ci-artifact-worker", "coderouter", "web-complexity", "webviews-typecheck"}
        self.assertEqual(table.steps["coderouter"].needs, ("rust", "node"))
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
                if re.search(r"\bbun (install|i)\b", line) and not line.lstrip().startswith("#"):
                    with self.subTest(step=name, line=line.strip()):
                        self.assertIn('flock "$CI_TOOLS/bun-install.lock" bun install', line)


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

    def test_ci_web_skips_them_only_on_a_feat_cmux_next_pull_request(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text())
        for name in self.STEPS:
            with self.subTest(job=name):
                self.assertTrue(wf["jobs"][name]["if"].endswith(
                    "&& (github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next') }}"))
        status = wf["jobs"]["web-status"]["steps"][0]["run"]
        self.assertIn('may_skip.update({"web-typecheck", "web-instant-navigation", "agent-pane-real-acpmux"})', status)

if __name__ == "__main__":
    unittest.main()
