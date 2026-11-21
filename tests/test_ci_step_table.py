#!/usr/bin/env python3
"""The step table (ci/steps.toml) and its runner (scripts/ci/ci_steps.py).

Leo, 2026-11-13: "Few jobs on warm trees; the PR runs what base runs on the tree that lands. 267 jobs
per PR become one step table and at most 8 jobs; a landing train tests the merge result (3.81 base
reds per 100 landings today). Advisory steps run idle-class and never block."

This test holds two things:

  - the table: at most 8 jobs, and a step that does not block runs in the `advisory` job, class `idle`;
  - the runner: an advisory step's failure or timeout is a warning and the job passes; a blocking
    step's failure fails it; a label event runs only the steps that list the label;
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
    def run_job(self, t: ci_steps.Table, job: str, label: str | None = None) -> tuple[int, str]:
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_STEP_SUMMARY"}
        old = os.environ
        os.environ = env  # the summary goes nowhere
        try:
            code = ci_steps.run_job(t, job, None, label, out)
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
        self.assertIn("ci/run run --job linux", job["steps"][-1]["run"])

    def test_the_router_starts_it_only_when_a_step_is_routed(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import pr_router

        callees = {"pr-pipeline.yml": pr_router.load_manifest()["pr-pipeline.yml"]}
        self.assertEqual(callees["pr-pipeline.yml"]["table_jobs"], ["linux"])
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
                 "repair-nightly-appcast-content-types.yml": "repair-nightly-appcast"}
        steps = ci_steps.load().steps
        for name, step in moved.items():
            with self.subTest(workflow=name):
                wf = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
                self.assertNotIn("pull_request", wf.get("on", wf.get(True)), "the step table runs it")
                self.assertEqual(steps[step].job, "linux")
        self.assertNotIn("validate", yaml.safe_load((ROOT / ".github/workflows/labels-sync.yml").read_text())["jobs"])
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
        self.assertEqual(sorted(table.tools), ["bun", "node"])
        wants_bun = {"app-platform", "mux", "automation-bench", "cloud-vm-image-lock"}
        wants_node = {"ci-artifact-worker"}
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
            "github.event.pull_request.head.repo.full_name != github.repository && 'ubuntu-24.04' || "
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
        need = ci_steps.SETUP_TIMEOUT + ci_steps.TOOL_TIMEOUT + -(-len(linux) // 2) * max(s.timeout for s in linux)
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
                [sys.executable, "scripts/ci/ci_steps.py", "run", "--job", "advisory"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            for name in ("design-spec", "perf-section", "cloud-backend"):
                self.assertIn(f"::group::{name}", run.stdout)
            self.assertNotIn("::error title", run.stdout)

    def test_the_workflow_runs_the_base_table(self) -> None:
        wf = yaml.safe_load((ROOT / ".github/workflows/pr-body-checks.yml").read_text())
        body = wf["jobs"]["body"]
        sparse = body["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("ci/steps.toml", sparse)
        self.assertIn("scripts/ci/ci_steps.py", sparse)
        step = next(s for s in body["steps"] if s.get("name") == "Run the advisory steps")
        self.assertIs(step.get("continue-on-error"), True)
        self.assertIn('ci_steps.py run --job advisory --label "$LABEL"', step["run"])
        names = [s.get("name", "") for s in body["steps"]]
        for gone in ("Check the description cites each changed surface's spec",
                     "Check the description for a Performance table",
                     "Check where the cloud backend change belongs"):
            self.assertNotIn(gone, names, "the step table runs it")



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

    def test_bun_of_the_major_on_path_is_linked_and_nothing_is_downloaded(self) -> None:
        for have in ("1.4.4", "1.4.5", "1.10.0"):
            with self.subTest(have=have):
                fake_bun(self.path_bin / "bun", have)
                done = self.run_script()  # no dist published: a download would fail
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(subprocess.run([self.bin / "bun", "--version"], text=True,
                                                capture_output=True).stdout.strip(), have)

    def test_an_older_or_other_bun_is_not_taken(self) -> None:
        self.publish()
        for have in ("1.4.3", "1.3.14", "2.0.0", "1.4.4-rc.1", "garbage"):
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


if __name__ == "__main__":
    unittest.main()
