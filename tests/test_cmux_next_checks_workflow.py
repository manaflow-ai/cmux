#!/usr/bin/env python3
"""The cmux-next checks job runs every check, then fails once with the list of reds.

The job used to stop at its first failing step. The god-files step failed on
cmux-tui Rust files, so the Swift god-type, concurrency, crash-safety, module
resource and string-table checks never ran and their reds stayed hidden. Each
check step now continues on error, and a final `if: always()` step reads every
check's `outcome` (its `conclusion` is success under continue-on-error) and
fails the job naming each red step. The cmux-tui Rust ratchet is its own step,
so it can never mask the Swift god-type check.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
ARTIFACTS_WORKFLOW = WORKFLOW.parent / "cmux-tui-artifacts.yml"
TREE_JOBS = ("daemon-test", "cmux-scheme-compile")
GODFILES = ROOT / "scripts/cmux-next/check-no-godfiles.sh"
JOB = "checks"


def steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]["steps"]


def is_setup(step: dict) -> bool:
    """Checkout and toolchain steps: an action, not a check script."""
    return "uses" in step


class ChecksJobStructure(unittest.TestCase):
    def split(self) -> tuple[list[dict], list[dict], dict]:
        all_steps = steps()
        aggregate = all_steps[-1]
        body = all_steps[:-1]
        return [s for s in body if is_setup(s)], [s for s in body if not is_setup(s)], aggregate

    def test_setup_steps_stop_the_job(self):
        setup, _, _ = self.split()
        self.assertTrue(setup, "the job checks out the repository")
        for step in setup:
            with self.subTest(step=step.get("name", step["uses"])):
                self.assertNotIn("continue-on-error", step)

    def test_every_check_step_has_an_id_and_continues_on_error(self):
        _, checks, _ = self.split()
        self.assertGreaterEqual(len(checks), 6)
        ids = [step.get("id") for step in checks]
        self.assertEqual(len(ids), len(set(ids)), ids)
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertTrue(step.get("id"), "a check step needs an id for the aggregate to read")
                self.assertIs(step.get("continue-on-error"), True)
                self.assertNotIn("if", step, "a check that may skip itself hides its result")

    def test_aggregate_reads_every_check_outcome(self):
        _, checks, aggregate = self.split()
        self.assertEqual(aggregate.get("if"), "always()")
        self.assertNotIn("continue-on-error", aggregate)
        text = yaml.safe_dump(aggregate)
        self.assertNotIn(".conclusion", text, "continue-on-error makes every conclusion success")
        read = re.findall(r"steps\.([A-Za-z0-9_-]+)\.outcome", text)
        self.assertEqual(sorted(read), sorted(step["id"] for step in checks))
        # Each outcome is listed with its step's name, so the summary names the red step.
        outcomes = aggregate["env"]["OUTCOMES"]
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertIn("${{ steps.%s.outcome }}|%s\n" % (step["id"], step["name"]), outcomes)
        self.assertIn("GITHUB_STEP_SUMMARY", aggregate["run"])
        self.assertIn("exit 1", aggregate["run"])

    def run_aggregate(self, outcomes: str) -> subprocess.CompletedProcess:
        _, _, aggregate = self.split()
        with tempfile.NamedTemporaryFile() as summary:
            return subprocess.run(
                ["bash", "-c", aggregate["run"]],
                env={**os.environ, "OUTCOMES": outcomes, "GITHUB_STEP_SUMMARY": summary.name},
                capture_output=True,
                text=True,
            )

    def test_aggregate_fails_closed_on_an_empty_outcome(self):
        # An id typo renders `${{ steps.x.outcome }}` as empty; that check never ran.
        for outcomes in ("|Lint\n", "|Crash safety\nsuccess|Lint\n"):
            with self.subTest(outcomes=outcomes):
                result = self.run_aggregate(outcomes)
                self.assertEqual(result.returncode, 1, result.stdout)
                name = outcomes.split("\n")[0].split("|")[1]
                self.assertIn("- %s (not run)" % name, result.stdout)

    def test_aggregate_passes_when_every_check_succeeds(self):
        result = self.run_aggregate("success|Lint\nsuccess|Crash safety\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_package_conventions_lint_is_its_own_step(self):
        # test-ios.yml runs this lint only for pull requests, merge groups and
        # dispatches; direct pushes to feat-cmux-next skipped it, and a
        # namespace-type red (CloudLinkSocketPolicy) reached the base unseen.
        _, checks, _ = self.split()
        lint = [step for step in checks if "lint-ios-package-conventions.sh" in step["run"]]
        self.assertEqual(len(lint), 1, [step["name"] for step in checks])
        self.assertEqual(lint[0]["run"].strip(), "./scripts/lint-ios-package-conventions.sh")
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        # PyYAML reads the `on:` key as True.
        push_paths = document[True]["push"]["paths"]
        for path in ("Packages/macOS/**", "Packages/Shared/**", "Packages/iOS/**",
                     "scripts/lint-ios-package-conventions*", "scripts/lint_swift_namespaces.py",
                     "scripts/lint-namespace-types-*.txt", "scripts/swift_source_mask.py"):
            with self.subTest(path=path):
                self.assertIn(path, push_paths)

    def test_the_app_ffi_pin_is_checked_on_linux_on_every_run(self):
        # swift test (macOS) carried this check. A newer push replaces a waiting
        # swift test and a busy mini refuses its runner, so of 30 tip runs
        # (2026-10-07 00:20Z to 01:05Z) none reached the step. The checks job
        # runs on Linux for every push and pull request.
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("ubuntu", document["jobs"][JOB]["runs-on"])
        _, checks, _ = self.split()
        pin = [step for step in checks if "check-app-ffi-pin.sh" in step["run"]]
        self.assertEqual(len(pin), 1, [step["name"] for step in checks])
        self.assertEqual(pin[0]["run"].strip(), "scripts/cmux-next/check-app-ffi-pin.sh --verify-release")
        script_tests = next(step for step in checks if step.get("id") == "script-tests")
        self.assertIn("bash scripts/cmux-next/tests/check-app-ffi-pin.test.sh", script_tests["run"])
        # Only there: the macOS swift test job no longer carries a copy.
        everywhere = [(job, step.get("name")) for job, spec in document["jobs"].items()
                      for step in spec.get("steps", []) if "check-app-ffi-pin.sh" in str(step.get("run", ""))]
        self.assertEqual(everywhere, [(JOB, "Check the app FFI pin")])

    def test_rust_ratchet_is_its_own_step(self):
        _, checks, _ = self.split()
        godfile_runs = [step["run"] for step in checks if "check-no-godfiles.sh" in step["run"]]
        self.assertEqual(len(godfile_runs), 2, godfile_runs)
        self.assertEqual(sum("--only swift" in run for run in godfile_runs), 1, godfile_runs)
        self.assertEqual(sum("--only rust" in run for run in godfile_runs), 1, godfile_runs)


class ReferencedFilesExist(unittest.TestCase):
    """Every test a checks step runs, and every test or workflow a path filter names, exists.
    The bundle removal (ce0b9e76a9b) deleted tests/test_cmux_next_regenerate_bundles_workflow.py
    and its workflow, but the Companion workflows step still ran the test, so every pull
    request's checks went red (run 37646119996)."""

    def test_named_tests_and_workflows_exist(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        named = set(re.findall(r"(?:python3|bash) (tests/[A-Za-z0-9_./-]+\.(?:py|sh))", text))
        named |= set(re.findall(r"^\s+- ((?:tests|\.github/workflows)/[A-Za-z0-9_./-]+\.(?:py|sh|yml))$", text, re.M))
        missing = sorted(path for path in named if not (ROOT / path).exists())
        self.assertEqual(missing, [])


class GodfileScopes(unittest.TestCase):
    """`--only swift` and `--only rust` each check their half, at unchanged budgets."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        repo = Path(cls.tmp.name)
        package = repo / "Packages/macOS/CmuxNext"
        (package / "Sources/Fixture").mkdir(parents=True)
        (package / "Tests").mkdir()
        # A 401-line Swift file (limit 400) and a 1001-line Swift type (limit 1000).
        (package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 401)
        body = "".join(f"    let field{i} = {i}\n" for i in range(997))
        (package / "Sources/Fixture/Huge.swift").write_text("struct Huge {\n" + body + "}\n")
        (package / "Sources/Fixture/HugeMore.swift").write_text("extension Huge {\n}\n")
        rust = repo / "cmux-tui/crates/fixture/src"
        rust.mkdir(parents=True)
        # Rust budgets: 1000 lines, 60 fns; tests 1500 lines, 120 fns.
        (rust / "long.rs").write_text("// x\n" * 1001)
        (rust / "at_budget.rs").write_text("// x\n" * 1000)
        (rust / "many_fns.rs").write_text("fn f() {}\n" * 61)
        (rust / "tests.rs").write_text("fn t() {}\n" * 120 + "// x\n" * 1380)
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "fixture"], check=True)
        cls.package = package

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["bash", str(GODFILES), *args, str(self.package)],
                              capture_output=True, text=True, env=env, timeout=120)

    def test_swift_scope_reports_only_swift(self):
        result = self.run_check("--only", "swift")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift has 401 lines (limit 400)", result.stdout)
        self.assertIn("type Fixture/Huge spans 1001 lines", result.stdout)
        self.assertNotIn("cmux-tui/", result.stdout)

    def test_rust_scope_reports_only_rust_at_unchanged_budgets(self):
        result = self.run_check("--only", "rust")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn(".swift", result.stdout)
        self.assertNotIn("god type", result.stdout)
        self.assertIn("long.rs has 1001 lines, 0 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertIn("many_fns.rs has 61 lines, 61 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertNotIn("at_budget.rs", result.stdout)
        self.assertNotIn("fixture/src/tests.rs", result.stdout)
        # Baseline entries of the other half are not reported as gone.
        self.assertNotIn("swift-type", result.stdout)

    def test_unscoped_run_still_checks_both(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift", result.stdout)
        self.assertIn("long.rs", result.stdout)

    def test_file_scope_measures_only_the_named_rust_files(self):
        # safe-push passes the files a merge changed (a whole scan takes about
        # a minute on the laptop and holds the push queue).
        result = self.run_check("--only", "rust", "--file", "cmux-tui/crates/fixture/src/at_budget.rs")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("long.rs", result.stdout)
        result = self.run_check("--only", "rust", "--file", "cmux-tui/crates/fixture/src/long.rs")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("long.rs has 1001 lines, 0 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertNotIn("many_fns.rs", result.stdout)
        self.assertNotIn("is gone", result.stdout)

    def test_file_scope_sums_a_swift_type_over_its_module(self):
        # A type spans every extension in its module, so an extension file
        # alone still reports the whole type; an unnamed long file is skipped.
        result = self.run_check("--only", "swift", "--file", "Packages/macOS/CmuxNext/Sources/Fixture/HugeMore.swift")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("type Fixture/Huge spans 1001 lines", result.stdout)
        self.assertNotIn("Wide.swift", result.stdout)

    def test_file_scope_cannot_rewrite_the_baseline(self):
        result = self.run_check("--update-baseline", "--file", "cmux-tui/crates/fixture/src/long.rs")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_scope_cannot_rewrite_the_baseline(self):
        # A scoped baseline rewrite would drop the other half's entries.
        result = self.run_check("--update-baseline", "--only", "rust")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--only", result.stdout + result.stderr)

    def test_unknown_scope_is_rejected(self):
        result = self.run_check("--only", "go")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


class GodfilePullRequestScope(unittest.TestCase):
    """`--base REF` fails only on what this change grew: a god file already on the base never blocks
    an unrelated pull request (acpmux profiles.rs and requests.rs did, 2026-10-07)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.package = self.repo / "Packages/macOS/CmuxNext"
        (self.package / "Sources/Fixture").mkdir(parents=True)
        (self.package / "Tests").mkdir()
        # Over budget on the base, and in no baseline: a 401-line Swift file, a 1001-line type, a
        # 1001-line Rust file. Plus a Rust file exactly at its budget.
        (self.package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 401)
        body = "".join(f"    let field{i} = {i}\n" for i in range(997))
        (self.package / "Sources/Fixture/Huge.swift").write_text("struct Huge {\n" + body + "}\n")
        self.rust = self.repo / "cmux-tui/crates/fixture/src"
        self.rust.mkdir(parents=True)
        (self.rust / "long.rs").write_text("// x\n" * 1001)
        (self.rust / "at_budget.rs").write_text("// x\n" * 1000)
        self.git("init", "-q", "-b", "base")
        self.commit("base")
        self.git("tag", "fixture-base")

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-qm", message, "--allow-empty")

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["bash", str(GODFILES), *args, str(self.package)],
                              capture_output=True, text=True, env=env, timeout=120)

    def both(self, *args: str) -> tuple[subprocess.CompletedProcess, subprocess.CompletedProcess]:
        return self.run_check("--only", "swift", *args), self.run_check("--only", "rust", *args)

    def test_without_a_base_the_base_reds_still_fail(self):
        swift, rust = self.both()
        self.assertEqual((swift.returncode, rust.returncode), (1, 1), swift.stdout + rust.stdout)

    def test_an_unrelated_change_passes_over_base_reds(self):
        (self.rust / "small.rs").write_text("fn f() {}\n")
        (self.package / "Sources/Fixture/Small.swift").write_text("let small = 0\n")
        self.commit("unrelated")
        for result in self.both("--base", "fixture-base"):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("over budget on the base", result.stdout)

    def test_a_merge_commit_s_first_parent_is_a_base(self):
        self.git("checkout", "-q", "-b", "lane")
        (self.rust / "small.rs").write_text("fn f() {}\n")
        self.commit("lane work")
        self.git("checkout", "-q", "base")
        self.git("merge", "-q", "--no-ff", "-m", "merge", "lane")
        for result in self.both("--base", "HEAD^1"):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_growing_an_over_budget_file_fails(self):
        (self.rust / "long.rs").write_text("// x\n" * 1002)
        (self.package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 402)
        self.commit("grow")
        swift, rust = self.both("--base", "fixture-base")
        self.assertEqual(rust.returncode, 1, rust.stdout)
        self.assertIn("long.rs has 1002 lines", rust.stdout)
        self.assertEqual(swift.returncode, 1, swift.stdout)
        self.assertIn("Wide.swift has 402 lines", swift.stdout)

    def test_growing_an_over_budget_type_in_another_file_fails(self):
        (self.package / "Sources/Fixture/HugeMore.swift").write_text("extension Huge {\n    func more() {}\n}\n")
        self.commit("grow the type")
        swift, _ = self.both("--base", "fixture-base")
        self.assertEqual(swift.returncode, 1, swift.stdout)
        self.assertIn("type Fixture/Huge spans 1002 lines", swift.stdout)

    def test_pushing_a_file_past_its_budget_or_adding_one_fails(self):
        (self.rust / "at_budget.rs").write_text("// x\n" * 1001)
        (self.rust / "new.rs").write_text("fn f() {}\n" * 61)
        self.commit("past budget")
        _, rust = self.both("--base", "fixture-base")
        self.assertEqual(rust.returncode, 1, rust.stdout)
        self.assertIn("at_budget.rs has 1001 lines", rust.stdout)
        self.assertIn("new.rs has 61 lines, 61 fns", rust.stdout)
        self.assertNotIn("long.rs has", rust.stdout)

    def test_shrinking_never_fails(self):
        (self.rust / "long.rs").write_text("// x\n" * 1000)
        (self.package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 300)
        self.commit("shrink")
        for result in self.both("--base", "fixture-base"):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_unknown_base_runs_the_full_check(self):
        (self.rust / "small.rs").write_text("fn f() {}\n")
        self.commit("unrelated")
        _, rust = self.both("--base", "no-such-ref")
        self.assertEqual(rust.returncode, 1, rust.stdout)
        self.assertIn("checking every file", rust.stdout + rust.stderr)

    def test_ci_scopes_pull_requests_to_their_own_growth(self):
        job = steps()
        runs = [step["run"] for step in job if "check-no-godfiles.sh" in step.get("run", "")]
        self.assertEqual(len(runs), 2)
        for run in runs:
            self.assertIn("--base HEAD^1", run)
            self.assertIn("pull_request", run)
        checkout = next(step for step in job if step.get("uses", "").startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["fetch-depth"], 2)
        tui = yaml.safe_load((ROOT / ".github/workflows/cmux-tui.yml").read_text(encoding="utf-8"))
        lint = tui["jobs"]["lint"]["steps"]
        rust = next(step for step in lint if "check-no-godfiles.sh" in step.get("run", ""))
        # The exact commit's merge base with feat-cmux-next, from the compare API, fetched alone.
        self.assertIn("compare/feat-cmux-next...", rust["run"])
        self.assertIn("merge_base_commit.sha", rust["run"])
        self.assertIn('--base "$merge_base"', rust["run"])


class PathRoutingStructure(unittest.TestCase):
    def test_path_route_gates_each_mac_job_on_its_tier(self):
        """tests/test_cmux_next_route.py covers which paths reach which tier."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        route = jobs["path_route"]
        for output in ("native", "macos", "scheme", "generated", "swift", "daemon", "full", "release", "swift_filter",
                       "swift_targets"):
            self.assertIn(output, route["outputs"])
        route_step = next(step for step in route["steps"] if step.get("id") == "route")
        self.assertIn("scripts/ci/cmux_next_route.py", route_step["run"])
        self.assertIn("needs.path_route.outputs.macos", jobs["macos-placement"]["if"])
        self.assertIn("needs.path_route.outputs.swift == 'true'", jobs["swift-test"]["if"])
        self.assertIn("needs.path_route.outputs.daemon == 'true'", jobs["daemon-test"]["if"])
        self.assertIn("needs.path_route.outputs.generated == 'true'", jobs["generated-files"]["if"])
        self.assertIn("needs.path_route.outputs.release == 'true'", jobs["release-compile"]["if"])
        # The Release tier needs the diff's lines, for a removed DEBUG conditional.
        self.assertIn("--diff", route["steps"][-1]["run"])
        self.assertIn("needs.path_route.outputs.scheme == 'true'", jobs["cmux-scheme-compile"]["if"])

    def test_package_tests_never_wait_for_the_cmux_tui_tree(self):
        """#17470's swift test spent 13 of 29 minutes waiting for the base tree."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        swift = jobs["swift-test"]
        self.assertNotIn("same-tree-cmux-tui", swift["needs"])
        self.assertFalse([step for step in swift["steps"] if "pin-cmux-tui.sh" in step.get("run", "")])
        self.assertIn("SWIFT_FILTER", swift["env"])

    def test_generated_files_are_checked_outside_the_package_tests(self):
        """a925bd9 went red when PRs that skipped swift test landed a stale export."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs = " ".join(step.get("run", "") for step in jobs["generated-files"]["steps"])
        self.assertIn("check-action-surfaces.sh", runs)
        self.assertIn("ci-target-graph.py --check", runs)
        self.assertNotIn("same-tree-cmux-tui", jobs["generated-files"]["needs"])
        swift_runs = " ".join(step.get("run", "") for step in jobs["swift-test"]["steps"])
        self.assertNotIn("check-action-surfaces.sh", swift_runs)

    def test_stale_generated_files_fail_with_the_regenerate_hint_and_no_autofix(self):
        """The autofix job's App (glaeda route) has no contents: write, so "Mint the autofix
        token" failed on every stale PR; it is removed, not widened. A stale generated file
        fails generated-files with the commands that regenerate it."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertNotIn("generated-autofix", jobs)
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("Mint the autofix token", text)
        fail = next(step for step in jobs["generated-files"]["steps"]
                    if step.get("name") == "Fail on stale generated files")
        self.assertIn("scripts/cmux-next/regenerate-action-contracts.sh", fail["run"])
        self.assertIn("scripts/cmux-next/ci-target-graph.py", fail["run"])
        self.assertIn("exit 1", fail["run"])
        self.assertNotIn("autofix", fail["run"])

    def test_red_push_runs_name_their_pull_requests(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        attribution = jobs["push-attribution"]
        self.assertIn("failure()", attribution["if"])
        self.assertIn("github.event_name == 'push'", attribution["if"])
        for job_id in ("checks", "generated-files", "swift-test", "daemon-test", "release-compile", "cmux-scheme-compile"):
            self.assertIn(job_id, attribution["needs"])

    def test_push_head_preflight_skips_superseded_macos_jobs(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        preflight = jobs["push-head-preflight"]
        self.assertIn("github.sha", preflight["steps"][0]["env"]["SHA"])
        self.assertIn("git", preflight["steps"][0]["run"])
        self.assertIn("ls-remote", preflight["steps"][0]["run"])
        self.assertIn("current", preflight["outputs"])
        for job_id in ("macos-placement", "swift-test", "daemon-test", "generated-files", "release-compile", "cmux-scheme-compile"):
            job = jobs[job_id]
            needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
            with self.subTest(job=job_id):
                self.assertIn("push-head-preflight", needs)
                self.assertIn("needs.push-head-preflight.outputs.current == 'true'", job["if"])

    def test_current_feat_push_still_requests_nightly_next(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        nightly = jobs["request-nightly-next"]
        # Main's promote-nightly-next refuses a head whose push run has no successful
        # "cmux-next Release compile (Xcode 26)" job. Requested after the Linux checks alone, it
        # ran about 10 minutes before that job finished and refused every head from 00:12Z to
        # 15:00Z on 2026-10-07 (run 37638104609). The request waits for that job and nothing
        # else, so an unrelated red never holds the promotion.
        self.assertEqual(nightly["needs"], "release-compile")
        self.assertEqual(jobs["release-compile"]["name"], "cmux-next Release compile (Xcode 26)")
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", nightly["if"])
        self.assertIn("needs.release-compile.result == 'success'", nightly["if"])
        self.assertNotIn("needs.checks", nightly["if"])
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("group: cmux-next-${{ github.event.pull_request.number || github.run_id }}", text)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", text)

    def test_every_green_feat_push_promotes_without_a_debounce(self):
        """nightly-next rolls forward to every green head. Promotions are never dropped by a
        time window; nightly.yml's own concurrency group coalesces them: the running build
        finishes and only the newest pending one runs next."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        run = "\n".join(step.get("run", "") for step in jobs["request-nightly-next"]["steps"])
        self.assertIn("scripts/cmux-next/request-nightly-next.sh", run)
        # Behavior (requests only a green commit with a published tree) is covered by
        # scripts/cmux-next/tests/request-nightly-next.test.sh.
        script = (WORKFLOW.parents[2] / "scripts/cmux-next/request-nightly-next.sh").read_text(encoding="utf-8")
        self.assertIn("-f promote_nightly_next_sha=", script)
        self.assertNotIn("promote_nightly_next_debounce=true", script)
        nightly = yaml.safe_load((WORKFLOW.parent / "nightly.yml").read_text(encoding="utf-8"))
        group = nightly["concurrency"]["group"]
        self.assertIn("github.ref_name == 'main' && 'nightly-shared' || github.ref_name", group)
        self.assertIs(nightly["concurrency"]["cancel-in-progress"], False)

    def test_batch_dispatch_runs_every_dispatch_gated_job(self):
        # scripts/ci/next_batch.py validates a stack of pull requests by
        # dispatching this workflow on a next-batch/* branch. Every job that
        # dispatch gates to feat-cmux-next must also run there, or the batch
        # would pass with its macOS tiers skipped.
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        gated = {name: job for name, job in jobs.items()
                 if "refs/heads/feat-cmux-next" in str(job.get("if", ""))
                 and "workflow_dispatch" in str(job.get("if", ""))}
        self.assertGreaterEqual(len(gated), 6)
        for name, job in gated.items():
            with self.subTest(job=name):
                self.assertIn("startsWith(github.ref, 'refs/heads/next-batch/')", job["if"])
        # Nightly promotion and the dogfood artifact stay feat-cmux-next pushes only.
        self.assertNotIn("next-batch", jobs["request-nightly-next"]["if"])

    def test_branch_lookup_uses_git_https_basic_auth_and_a_timeout(self):
        for filename, job_id in (("cmux-next.yml", "push-head-preflight"),
                                 ("cmux-tui-artifacts.yml", "tree-preflight")):
            document = yaml.safe_load((WORKFLOW.parent / filename).read_text())
            script = document["jobs"][job_id]["steps"][-1]["run"]
            with self.subTest(workflow=filename):
                self.assertIn("Authorization: Basic", script)
                self.assertIn("x-access-token:%s", script)
                self.assertIn("timeout 15 git", script)
                self.assertNotIn("Authorization: Bearer", script)


class PushPreflightBehavior(unittest.TestCase):
    """Execute the workflow shell with bounded fake network and git responses."""

    def run_preflight(self, *, artifacts=False, event="push", ref="refs/heads/feat-cmux-next",
                      remote="a" * 40, remote_tree_key="0" * 39 + "2", published=False,
                      missing="", malformed=False, fork=False):
        filename = "cmux-tui-artifacts.yml" if artifacts else "cmux-next.yml"
        workflow = yaml.safe_load((WORKFLOW.parent / filename).read_text())
        job_id = "tree-preflight" if artifacts else "push-head-preflight"
        script = workflow["jobs"][job_id]["steps"][-1]["run"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = root / "git"
            git.write_text('''#!/bin/bash
case "$*" in
  *ls-remote*) [[ -z "$REMOTE_SHA" ]] && exit 1; printf '%s\\trefs/heads/feat-cmux-next\\n' "$REMOTE_SHA" ;;
  *fetch*) touch "$REMOTE_FETCH_MARKER" ;;
  *diff*) exit 0 ;;
  *rev-parse*) printf '%040d\\n' 1 ;;
  *mktree*) cat >/dev/null; if [[ -e "$REMOTE_FETCH_MARKER" ]]; then printf '%s\\n' "$REMOTE_TREE_KEY"; else printf '%040d\\n' 2; fi ;;
  *) exit 1 ;;
esac
''')
            git.chmod(0o755)
            curl = root / "curl"
            curl.write_text('''#!/bin/bash
[[ "$PUBLISHED" == true ]] || exit 22
for arg in "$@"; do
  [[ "$arg" == https://* ]] && url="$arg"
done
[[ -z "$MISSING" || "$url" != *"$MISSING"* ]] || exit 22

if [[ "$url" == *completion.json* ]]; then
  args=("$@")
  for ((index=0; index<${#args[@]}; index++)); do
    arg="${args[index]}"
    if [[ "$arg" == -o ]]; then
      outfile="${args[index + 1]}"
      cat > "$outfile" <<'JSON'
{"key":"0000000000000000000000000000000000000002","binaries":{"cmux-tui-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000","cmux-tui-app-host-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000","cmux-tui-cloud-server-aarch64-apple-darwin":"0000000000000000000000000000000000000000000000000000000000000000"}}
JSON
      exit 0
    fi
  done
  exit 1
fi

[[ "$MALFORMED" != true ]] || { printf 'bad checksum\\n'; exit 0; }
printf '%064d  cmux-tui-aarch64-apple-darwin\\n' 3
''')
            curl.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": str(root), "EVENT_NAME": event, "REF": ref,
                   "SHA": "a" * 40, "SOURCE_COMMIT": "a" * 40,
                   "REMOTE_SHA": remote, "PUBLISHED": str(published).lower(),
                   "REMOTE_TREE_KEY": remote_tree_key, "REMOTE_FETCH_MARKER": str(root / "remote-fetched"),
                   "MISSING": missing, "MALFORMED": str(malformed).lower(),
                   "HEAD_REPOSITORY": "outside/fork" if fork else "manaflow-ai/cmux",
                   "REPOSITORY": "manaflow-ai/cmux", "SERVER_URL": "https://github.com",
                   "GH_TOKEN": "fixture", "RUN_ID": "123"}
            result = subprocess.run(["bash", "-c", script], env=env, text=True,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_current_push_keeps_native_compile(self):
        self.assertEqual(self.run_preflight()["current"], "true")

    def test_superseded_push_skips_native_compile(self):
        self.assertEqual(self.run_preflight(remote="b" * 40)["current"], "false")

    def test_ref_lookup_failure_keeps_current_compile_enabled(self):
        self.assertEqual(self.run_preflight(remote="")["current"], "true")

    def test_pr_and_dispatch_are_never_superseded(self):
        for event in ("pull_request", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual(self.run_preflight(event=event, remote="b" * 40)["current"], "true")

    def test_published_tree_skips_mac_build_and_daemon_tests(self):
        output = self.run_preflight(artifacts=True, published=True)
        self.assertEqual(output["tree_ready"], "true")
        self.assertEqual(output["run_macos"], "false")

    def test_partial_tree_requires_companion_repair(self):
        for missing in ("app-host", "cloud-server", "app-host-aarch64-apple-darwin?", "cloud-server-aarch64-apple-darwin?"):
            with self.subTest(missing=missing):
                output = self.run_preflight(artifacts=True, published=True, missing=missing)
                self.assertEqual(output["tree_ready"], "false")
                self.assertEqual(output["run_macos"], "true")

    def test_malformed_tree_checksum_requires_repair(self):
        output = self.run_preflight(artifacts=True, published=True, malformed=True)
        self.assertEqual(output["tree_ready"], "false")
        self.assertEqual(output["run_macos"], "true")

    def test_new_tree_schedules_mac_build_and_daemon_tests(self):
        self.assertEqual(self.run_preflight(artifacts=True)["run_macos"], "true")

    def test_same_tree_superseded_push_keeps_missing_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40)
        self.assertEqual(output["run_macos"], "true")
        self.assertEqual(output["superseded"], "false")

    def test_same_tree_superseded_push_skips_complete_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40, published=True)
        self.assertEqual(output["run_macos"], "false")
        self.assertEqual(output["superseded"], "true")

    def test_distinct_tree_superseded_push_keeps_missing_tree_build(self):
        output = self.run_preflight(artifacts=True, remote="b" * 40, remote_tree_key="3" * 40)
        self.assertEqual(output["run_macos"], "true")
        self.assertEqual(output["superseded"], "false")

    def test_main_keeps_commit_and_latest_publication(self):
        self.assertEqual(self.run_preflight(artifacts=True, ref="refs/heads/main",
                                            published=True)["run_macos"], "true")

    def test_manual_republish_keeps_commit_artifacts_enabled(self):
        self.assertEqual(self.run_preflight(artifacts=True, event="workflow_dispatch",
                                            ref="refs/heads/cmux-tui-pin-repair",
                                            published=True)["run_macos"], "true")

    def test_pin_push_keeps_commit_artifacts_enabled(self):
        self.assertEqual(self.run_preflight(artifacts=True, ref="refs/heads/cmux-tui-pin-repair",
                                            published=True)["run_macos"], "true")

    def test_fork_never_schedules_trusted_build(self):
        self.assertEqual(self.run_preflight(artifacts=True, event="pull_request_target",
                                            fork=True)["run_macos"], "false")


RESET_STALE_SUBMODULES = "scripts/ci/reset-stale-submodules.sh"


def can_run_on_owned_runner(job: dict) -> bool:
    """A runs-on that reads a repository variable can resolve to a mini (glaeda-*)."""
    return "vars." in str(job.get("runs-on", ""))


class ReusedWorkspaceSubmodules(unittest.TestCase):
    """A reused mini workspace keeps the previous job's submodule checkouts.

    actions/checkout with `submodules: false` moves the superproject but leaves
    ghostty at the last branch's commit, so pin-cmux-tui.sh fetch saw ` M ghostty`
    and refused the checkout (run 37198483749). Every such checkout on a job
    that can run on a mini is followed at once by the reset step.
    """

    def test_every_submodule_free_checkout_on_an_owned_runner_resets_submodules(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        checked = []
        for job_id, job in jobs.items():
            if not can_run_on_owned_runner(job):
                continue
            job_steps = job.get("steps", [])
            for index, step in enumerate(job_steps):
                if not str(step.get("uses", "")).startswith("actions/checkout@"):
                    continue
                if str(step.get("with", {}).get("submodules", False)).lower() in ("true", "recursive"):
                    continue
                checked.append(job_id)
                with self.subTest(job=job_id):
                    following = job_steps[index + 1] if index + 1 < len(job_steps) else {}
                    self.assertIn(RESET_STALE_SUBMODULES, following.get("run", ""),
                                  "the step after checkout must drop stale submodule checkouts")
        self.assertEqual(sorted(checked), ["cmux-scheme-compile", "daemon-test", "generated-files", "release-compile",
                                           "request-nightly-next", "swift-test"])



class SupersededCommitIsNotRed(unittest.TestCase):
    """A superseded commit's cmux-next run skips the jobs that need its tree.

    Queued cmux-tui artifacts runs of an older branch head are superseded by
    design, so that commit's same-tree cmux-tui is never published. Path
    routing's probe (pin-cmux-tui.sh probe, covered by
    scripts/cmux-next/tests/pin-cmux-tui-probe.test.sh) reports
    tree_state=superseded, and every job that fetches the tree runs only on
    tree_state=ready: skipped, not failed. A tree that nothing will publish is
    red in same-tree-cmux-tui.
    """

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_every_tree_fetching_job_runs_only_on_a_ready_tree(self):
        fetching = {
            name: job for name, job in self.jobs().items()
            if any("pin-cmux-tui.sh fetch" in step.get("run", "") for step in job.get("steps", []))
        }
        self.assertEqual(sorted(fetching), sorted(TREE_JOBS))
        for name, job in fetching.items():
            with self.subTest(job=name):
                condition = " ".join(job["if"].split())
                self.assertIn("needs.path_route.outputs.tree_state == 'ready'", condition)
                self.assertIn("path_route", job["needs"])



class SameTreeIsAnEvent(unittest.TestCase):
    """No runner waits for the same-tree cmux-tui.

    The old gate job polled the CDN on a Blacksmith runner for up to 45
    minutes (10,934 job-minutes on 2026-10-06). Now path routing probes once:
    a published tree runs the tree jobs in the same run; an unpublished one
    leaves a marker artifact, and the cmux-tui artifacts run that publishes
    the key dispatches cmux-next's same-tree mode (cmux_next_tree_notify.py).
    """

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_no_step_polls_for_the_tree(self):
        for name, job in self.jobs().items():
            for step in job.get("steps", []):
                run = step.get("run", "")
                with self.subTest(job=name, step=step.get("name")):
                    self.assertNotIn("pin-cmux-tui.sh wait", run)
                    if "pin-cmux-tui.sh fetch" in run:
                        # The tree is published before a tree job starts: a download, not a wait.
                        self.assertLessEqual(int(step["env"]["CMUX_TUI_TREE_WAIT_SECONDS"]), 120)

    def test_path_route_probes_once_and_leaves_a_marker(self):
        route = self.jobs()["path_route"]
        self.assertIn("tree_state", route["outputs"])
        runs = " ".join(step.get("run", "") for step in route["steps"])
        self.assertIn("pin-cmux-tui.sh probe", runs)
        uploads = [step for step in route["steps"] if "upload-artifact" in str(step.get("uses", ""))]
        self.assertEqual(len(uploads), 1)
        self.assertTrue(uploads[0]["with"]["name"].startswith("cmux-next-tree-wait-"))
        # The probe dispatches one cmux-tui artifacts run for a same-repository
        # PR's unpublished merge tree: a pin ref (contents) and a dispatch (actions).
        self.assertEqual(route["permissions"].get("actions"), "write")
        self.assertEqual(route["permissions"].get("contents"), "write")

    def test_tree_jobs_need_a_ready_tree_and_no_waiter(self):
        jobs = self.jobs()
        for name in TREE_JOBS:
            job = jobs[name]
            condition = " ".join(job["if"].split())
            with self.subTest(job=name):
                self.assertNotIn("same-tree-cmux-tui", job["needs"])
                self.assertIn("needs.path_route.outputs.tree_state == 'ready'", condition)
                self.assertIn("inputs.same_tree_state == 'ready'", condition)
                checkout = next(step for step in job["steps"] if str(step.get("uses", "")).startswith("actions/checkout@"))
                self.assertIn("inputs.same_tree_sha", str(checkout["with"].get("ref", "")))

    def test_same_tree_mode_runs_only_the_tree_jobs(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        inputs = document.get("on", document.get(True))["workflow_dispatch"]["inputs"]
        for name in ("same_tree_sha", "same_tree_tiers", "same_tree_status_sha", "same_tree_state",
                     "same_tree_reason", "same_tree_origin", "same_tree_origin_run"):
            self.assertIn(name, inputs)
        jobs = self.jobs()
        for name in ("push-head-preflight", "path_route", "checks"):
            with self.subTest(job=name):
                self.assertIn("inputs.same_tree_sha == ''", jobs[name]["if"])

    def test_an_unavailable_tree_is_red_without_waiting(self):
        gate = self.jobs()["same-tree-cmux-tui"]
        self.assertLessEqual(int(gate["timeout-minutes"]), 5)
        self.assertIn("needs.path_route.outputs.tree_state == 'failed'", gate["if"])
        self.assertIn("inputs.same_tree_state == 'failed'", gate["if"])
        self.assertFalse([step for step in gate["steps"] if "pin-cmux-tui.sh" in step.get("run", "")])

    def test_the_artifacts_workflow_starts_the_deferred_jobs(self):
        jobs = yaml.safe_load(ARTIFACTS_WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for name, state in (("publish-tree", "ready"), ("publish-pr-tree", "ready"), ("notify-unpublished-tree", "failed")):
            job = jobs[name]
            notify = [step for step in job["steps"] if "scripts/ci/cmux_next_tree_notify.py" in step.get("run", "")]
            with self.subTest(job=name):
                self.assertEqual(len(notify), 1)
                self.assertIn(f"--state {state}", notify[0]["run"])
                self.assertEqual(job["permissions"].get("actions"), "write")
                # A notify failure must not turn a good publication red.
                self.assertTrue(notify[0].get("continue-on-error"))


if __name__ == "__main__":
    unittest.main()
