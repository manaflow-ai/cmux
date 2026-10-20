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

import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
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

    def test_ratchet_ceilings_are_set_only_on_their_own_steps(self):
        # Job-wide, the warning ceilings reach the script tests in this job, which
        # expect every hit to fail (#18894's first run: check-scrollbars.test.sh and
        # the god-file scope tests went green on a warning).
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]
        ceilings = {"GODFILES_WARN_SLACK", "L10N_STYLE_WARN_MAX", "SCROLLBARS_WARN_MAX"}
        self.assertFalse(ceilings & set(job.get("env") or {}), "set the ceilings on their steps")
        owners = {"godfiles-swift": "GODFILES_WARN_SLACK", "godfiles-rust": "GODFILES_WARN_SLACK",
                  "l10n": "L10N_STYLE_WARN_MAX", "scrollbars": "SCROLLBARS_WARN_MAX"}
        for step in job["steps"]:
            env = set(step.get("env") or {}) & ceilings
            if step.get("id") in owners:
                self.assertEqual(env, {owners[step["id"]]}, step.get("name"))
            else:
                self.assertFalse(env, step.get("name"))

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
        self.assertIn("scripts/cmux-next/check-app-ffi-pin.sh --verify-release", pin[0]["run"])
        self.assertIn("base=(--base HEAD^1)", pin[0]["run"])
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
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
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
                        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args], check=True, capture_output=True)

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

    def test_base_as_self_excuses_inherited_debt(self):
        swift, rust = self.both("--base", "HEAD")
        for result in (swift, rust):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("over budget on the base", result.stdout)

    def test_base_as_self_without_optional_rust_tree_excuses_inherited_debt(self):
        # A Swift-only checkout must not let the optional cmux-tui archive path
        # erase the base tree and turn inherited debt into a new failure.
        self.git("rm", "-q", "-r", "cmux-tui")
        self.commit("swift-only base")
        result = self.run_check("--only", "swift", "--base", "HEAD")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("over budget on the base", result.stdout)

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
        for output in ("native", "macos", "scheme", "generated", "swift", "daemon", "full", "swift_filter", "swift_targets"):
            self.assertIn(output, route["outputs"])
        route_step = next(step for step in route["steps"] if step.get("id") == "route")
        self.assertIn("scripts/ci/cmux_next_route.py", route_step["run"])
        self.assertIn("needs.path_route.outputs.macos", jobs["macos-placement"]["if"])
        self.assertIn("needs.path_route.outputs.swift == 'true'", jobs["swift-test"]["if"])
        self.assertIn("needs.path_route.outputs.daemon == 'true'", jobs["daemon-test"]["if"])
        self.assertIn("needs.path_route.outputs.generated == 'true'", jobs["generated-files"]["if"])
        self.assertIn("needs.path_route.outputs.native", jobs["release-compile"]["if"])
        self.assertIn("needs.path_route.outputs.scheme == 'true'", jobs["cmux-scheme-compile"]["if"])
        for job_id in ("macos-placement", "swift-canary", "swift-test", "generated-files", "daemon-test", "release-compile", "cmux-scheme-compile"):
            self.assertIn("contains(github.event.pull_request.labels.*.name, 'full-ci')", jobs[job_id]["if"], job_id)

    def test_trusted_dev_build_prs_keep_the_scheme_producer(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        scheme_if = jobs["cmux-scheme-compile"]["if"]
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'full-ci')", scheme_if)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", scheme_if)
        self.assertIn("github.event.pull_request.author_association == 'MEMBER'", scheme_if)
        self.assertIn("github.event.pull_request.author_association == 'OWNER'", scheme_if)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'dev-build')", scheme_if)
        outer_guard = scheme_if.split(" && !(", 1)[0]
        self.assertIn(
            "github.base_ref == 'feat-cmux-next' && "
            "github.event.pull_request.head.repo.full_name == github.repository",
            outer_guard,
        )
        self.assertIn(
            "contains(github.event.pull_request.labels.*.name, 'dev-build')",
            outer_guard,
        )

    def test_web_bundle_cache_restore_downloads_the_output(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        restore = next(
            step for step in jobs["web-bundles"]["steps"]
            if step.get("id") == "web-bundle-cache"
        )
        self.assertNotIn("lookup-only", restore.get("with", {}))
        self.assertEqual(restore["with"]["path"], "web-bundles-out")

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

    def test_generated_files_use_cached_web_bundles_without_rebuilding(self):
        """A cache hit must install the keyed bundles and skip the source build."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        steps = jobs["generated-files"]["steps"]
        build = next(step for step in steps if step.get("name") == "Build the web bundles")
        self.assertEqual(build["if"], "steps.web-bundle-cache.outputs.cache-hit != 'true'")
        install = next(step for step in steps if step.get("name") == "Install the restored web bundles")
        self.assertEqual(install["if"], "steps.web-bundle-cache.outputs.cache-hit == 'true'")

    def test_package_jobs_use_cached_web_bundles_without_rebuilding(self):
        """Swift and daemon jobs must take the same cache hit fast path."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for job_id in ("swift-test", "daemon-test"):
            with self.subTest(job=job_id):
                steps = jobs[job_id]["steps"]
                build = next(step for step in steps if step.get("name") == "Build the web bundles")
                self.assertEqual(build["if"], "steps.web-bundle-cache.outputs.cache-hit != 'true'")

    def test_package_jobs_wait_for_single_web_bundle_producer(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for job_id in ("swift-test", "daemon-test", "generated-files"):
            with self.subTest(job=job_id):
                needs = jobs[job_id]["needs"]
                self.assertIn("web-bundles", needs)
                self.assertIn("needs.web-bundles.result == 'skipped'", jobs[job_id]["if"])

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

    def test_bot_attempt_three_drops_stale_owned_pool_placement(self):
        """Rescue attempt 3 must use the Blacksmith fallback instead of a stale mini label."""
        text = WORKFLOW.read_text(encoding="utf-8")
        stale = "(github.run_attempt <= 3 || github.triggering_actor != 'github-actions[bot]') && needs.macos-placement.outputs."
        self.assertNotIn(stale, text)
        guard = "(github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') && "
        # The session-only jobs read `(session_runner || gui_runner)`, the rest one output.
        self.assertEqual(text.count(guard + "needs.macos-placement.outputs."), 9)
        self.assertEqual(text.count(guard + "(needs.macos-placement.outputs.session_runner || "
                                    "needs.macos-placement.outputs.gui_runner)"), 4)
        self.assertIn("bot attempt 3 is the measured Blacksmith overflow", text)
        self.assertIn("bot attempt 3\n# drops the stale placement output and takes the Blacksmith fallback", text)

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
                   "GH_TOKEN": "fixture", "RUN_ID": "123", "API_URL": "https://api.github.com"}
            # The tree-claim authority needs a job OIDC token; without one it exits 3 and the
            # preflight falls back to the run-list election (fake curl answers it).
            env.pop("ACTIONS_ID_TOKEN_REQUEST_URL", None)
            env.pop("ACTIONS_ID_TOKEN_REQUEST_TOKEN", None)
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
        # A pin push of a published tree whose commit's binaries are missing
        # still builds them (only a true duplicate is skipped, cx-urd.26).
        self.assertEqual(self.run_preflight(artifacts=True, ref="refs/heads/cmux-tui-pin-repair",
                                            published=True, missing="/manifest.json")["run_macos"], "true")


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

    CHECKOUT_FAILED = "steps.checkout.outcome == 'failure'"

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
                # A failed checkout's retry pair (tests/test_cmux_next_checkout_retry.py)
                # sits between the checkout and the reset, which follows either way.
                if step.get("if") == self.CHECKOUT_FAILED:
                    continue
                checked.append(job_id)
                with self.subTest(job=job_id):
                    after = index + 1
                    while after < len(job_steps) and job_steps[after].get("if") == self.CHECKOUT_FAILED:
                        after += 1
                    following = job_steps[after] if after < len(job_steps) else {}
                    self.assertIn(RESET_STALE_SUBMODULES, following.get("run", ""),
                                  "the step after checkout must drop stale submodule checkouts")
        self.assertEqual(sorted(checked), ["cmux-scheme-compile", "daemon-test", "fast-tier", "generated-files",
                                           "release-compile", "request-nightly-next", "swift-canary", "swift-test"])



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
        for name, state in (("publish-tree", "ready"), ("notify-unpublished-tree", "failed")):
            job = jobs[name]
            notify = [step for step in job["steps"] if "scripts/ci/cmux_next_tree_notify.py" in step.get("run", "")]
            with self.subTest(job=name):
                self.assertEqual(len(notify), 1)
                self.assertIn(f"--state {state}", notify[0]["run"])
                self.assertEqual(job["permissions"].get("actions"), "write")
                # A notify failure must not turn a good publication red.
                self.assertTrue(notify[0].get("continue-on-error"))



class FastTierBuildsLibghosttyVt(unittest.TestCase):
    def test_the_fast_tier_job_can_build_cmux_tui_core(self):
        """cmux-tui-core's ghostty-vt-sys builds libghostty-vt from the ghostty-next gitlink with
        zig (#20290: `the ghostty-next submodule is empty`), as cmux-tui.yml's jobs do."""
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        self.assertEqual(job["env"]["GHOSTTY_ZIG_SOURCE"], "ghostty-next")
        self.assertEqual(job["env"]["CMUX_GHOSTTY_SRC"], "")
        runs = [step.get("run", "") for step in job["steps"]]
        tier = next(i for i, run in enumerate(runs) if "scripts/cmux-next/fast-tier.py" in run)
        init = next(i for i, run in enumerate(runs)
                    if "scripts/ci/init-submodule.sh ghostty-next" in run
                    or ("git submodule update --init" in run and "ghostty-next" in run))
        zig = next(i for i, run in enumerate(runs) if "scripts/install-zig-ci.sh" in run)
        self.assertLess(max(init, zig), tier)

    def test_fast_tier_uses_bounded_ghostty_initialization(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        init = next(step for step in job["steps"]
                    if "scripts/ci/init-submodule.sh ghostty-next" in step.get("run", ""))
        self.assertIn("scripts/ci/init-submodule.sh ghostty-next", init["run"])

    def test_fast_tier_emits_a_json_timing_receipt(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        run = next(step for step in job["steps"] if "scripts/cmux-next/fast-tier.py" in step.get("run", ""))
        self.assertIn("--receipt", run["run"])
        upload = next(step for step in job["steps"] if "actions/upload-artifact@" in str(step.get("uses", "")))
        self.assertEqual(upload.get("if"), "always()")
        self.assertIn("github.run_attempt", upload["with"]["name"])

    def test_fast_tier_reuses_ghostty_next_instead_of_deinitializing_every_submodule(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        checkouts = [step for step in job["steps"] if str(step.get("uses", "")).startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        for checkout in checkouts:
            with self.subTest(checkout=checkout):
                self.assertIs(checkout["with"]["clean"], False)
        cleanup = [
            step for step in job["steps"]
            if "git clean -ffd" in step.get("run", "")
        ]
        self.assertEqual(len(cleanup), 1)
        reuse = [
            step for step in job["steps"]
            if "reset-stale-submodules.sh" in step.get("run", "")
        ]
        self.assertEqual(len(reuse), 1)
        self.assertIn("--reuse ghostty-next", reuse[0]["run"])
        self.assertNotIn("--all", reuse[0]["run"])


SEED_WORKFLOW = WORKFLOW.parent / "cmux-next-fast-tier-seed.yml"
CACHE_KEY_SCRIPT = ROOT / "scripts/cmux-next/fast-tier-cache-key.sh"
SEED_DUE_SCRIPT = ROOT / "scripts/cmux-next/fast-tier-seed-due.py"
FAST_TIER_SCRIPT = ROOT / "scripts/cmux-next/fast-tier.py"
FAST_CACHE_DIRS = {"swift": "Packages/macOS/CmuxNext/.build", "home": "Packages/Shared/CmuxHomeRender/.build",
                   "cargo": "cmux-tui/target"}
FAST_CACHE_MANIFEST = "Packages/macOS/CmuxNext/.build/cmux-fast-tier-input-mtimes.json"
NEXT_BUCKET = "cmux-ci-cache-next"
NEXT_PUBLIC_URL = "https://ci-cache-next.cmux.com"
NEXT_WRITER = "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}"


def is_cache_restore(step: dict) -> bool:
    uses = str(step.get("uses", ""))
    return "cache-restore" in uses or uses.startswith("actions/cache/restore@")


def is_cache_save(step: dict) -> bool:
    uses = str(step.get("uses", ""))
    return "cache-save" in uses or uses.startswith("actions/cache/save@") or uses.startswith("actions/cache@")


def index_of(steps: list[dict], predicate) -> int:
    return next(i for i, step in enumerate(steps) if predicate(step))


class FastTierStartsWarm(unittest.TestCase):
    """The fast tier restores the build a feat-cmux-next push seeded into NEXT's own R2 bucket.

    The old R2 saves needed main's ci-cache-writer environment, so nothing was ever saved
    and every Blacksmith fast tier built cold (~6.5 of 7 min). NEXT now writes
    cmux-ci-cache-next through next-cache-writer (feat-cmux-next only), and pull requests
    read its public URL with no credential.
    """

    def fast_tier(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]

    def seed(self) -> dict:
        self.assertTrue(SEED_WORKFLOW.is_file(), "the seed workflow exists")
        return yaml.safe_load(SEED_WORKFLOW.read_text(encoding="utf-8"))

    def test_fast_tier_reads_next_bucket_publicly_and_never_saves(self):
        job = self.fast_tier()
        steps = job["steps"]
        restores = [s for s in steps if is_cache_restore(s)]
        self.assertEqual(sorted(cache["with"]["path"] for cache in restores), sorted(FAST_CACHE_DIRS.values()))
        key_step = steps[index_of(steps, lambda s: "scripts/cmux-next/fast-tier-cache-key.sh" in s.get("run", ""))]
        for restore in restores:
            with self.subTest(restore=restore["name"]):
                self.assertEqual(restore["with"]["backend"], "r2")
                self.assertEqual(restore.get("env", {}).get("CI_CACHE_R2_PUBLIC_URL"), NEXT_PUBLIC_URL)
                self.assertIs(restore.get("continue-on-error"), True)
        self.assertIn("!contains(runner.name, '-glaeda')", key_step.get("if", ""))
        self.assertEqual([s.get("name") for s in steps if is_cache_save(s)], [])
        self.assertNotIn("secrets.", yaml.safe_dump(job))
        self.assertNotIn("ci-cache-writer", str(job.get("environment", "")).replace("github.ref == 'refs/heads/main' && 'ci-cache-writer'", ""))

    def test_fast_tier_takes_every_directory_from_one_seed(self):
        """Only the swift build is restored by prefix. The others take that seed's exact
        commit, so a directory from another seed never meets this seed's manifest."""
        steps = self.fast_tier()["steps"]
        key_id = steps[index_of(steps, lambda s: "scripts/cmux-next/fast-tier-cache-key.sh" in s.get("run", ""))]["id"]
        by_path = {s["with"]["path"]: s for s in steps if is_cache_restore(s)}
        swift = by_path[FAST_CACHE_DIRS["swift"]]
        self.assertEqual(swift["with"]["key"], "${{ steps.%s.outputs.swift-key }}" % key_id)
        self.assertEqual(swift["with"]["restore-keys"], "${{ steps.%s.outputs.swift-prefix }}" % key_id)
        seed = steps[index_of(steps, lambda s: "cache-matched-key" in json.dumps(s.get("env", {})) and "commit=" in s.get("run", ""))]
        for name in ("home", "cargo"):
            with self.subTest(name=name):
                step = by_path[FAST_CACHE_DIRS[name]]
                self.assertEqual(step["with"]["key"], "${{ steps.%s.outputs.%s-prefix }}${{ steps.%s.outputs.commit }}" % (key_id, name, seed["id"]))
                self.assertFalse(step["with"].get("restore-keys"), "an exact key, never a prefix")
                self.assertIn("steps.%s.outputs.commit != ''" % seed["id"], step.get("if", ""))
        # The commit is the matched key minus the swift prefix.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            env = dict(os.environ, GITHUB_OUTPUT=str(out), MATCHED="cmux-next-fast-v2-swift-macOS-a-b-c-0123abc", PREFIX="cmux-next-fast-v2-swift-macOS-a-b-c-")
            subprocess.run(["bash", "-c", seed["run"]], env=env, check=True)
            self.assertEqual(out.read_text().strip(), "commit=0123abc")

    def test_fast_tier_replays_the_seed_input_times_before_building(self):
        steps = self.fast_tier()["steps"]
        names = [s.get("name") for s in steps]
        last_restore = max(i for i, s in enumerate(steps) if is_cache_restore(s))
        replay = index_of(steps, lambda s: "e2e_warm_derived_data.py replay" in s.get("run", ""))
        tier = index_of(steps, lambda s: "scripts/cmux-next/fast-tier.py" in s.get("run", ""))
        ghostty = index_of(steps, lambda s: "init-submodule.sh ghostty-next" in s.get("run", ""))
        self.assertLess(last_restore, replay, names)
        self.assertLess(ghostty, replay, "replay sees the same submodule files the seed recorded")
        self.assertLess(replay, tier, names)
        self.assertIn(FAST_CACHE_MANIFEST, steps[replay]["run"])
        self.assertIn(".outputs.commit != ''", steps[replay].get("if", ""))
        self.assertIs(steps[replay].get("continue-on-error"), True)
        self.assertIn("CMUX_FAST_CACHE_MATCHED_KEY", steps[tier].get("env", {}))

    def test_seed_writes_only_next_bucket_from_feat_cmux_next_pushes(self):
        seed = self.seed()
        triggers = seed.get("on", seed.get(True))
        self.assertEqual(set(triggers), {"push"}, "no pull_request, pull_request_target or dispatch")
        self.assertEqual(triggers["push"]["branches"], ["feat-cmux-next"])
        self.assertEqual(seed["env"]["CI_CACHE_R2_BUCKET"], NEXT_BUCKET)
        self.assertEqual(seed["env"]["CI_CACHE_R2_PUBLIC_URL"], NEXT_PUBLIC_URL)
        text = SEED_WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("vars.CI_CACHE_R2_BUCKET", text)
        self.assertNotIn("ci-cache-writer", text.replace("next-cache-writer", ""))
        for name, job in seed["jobs"].items():
            with self.subTest(job=name):
                self.assertIn("github.repository == 'manaflow-ai/cmux'", job.get("if", ""))
                self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", job.get("if", ""))
                self.assertEqual(job.get("environment"), NEXT_WRITER)
        self.assertFalse(seed.get("concurrency", {}).get("cancel-in-progress", True),
                         "a running seed finishes; a newer push only replaces the pending one")

    def test_seed_saves_what_the_fast_tier_restores(self):
        build = self.seed()["jobs"]["seed"]
        steps = build["steps"]
        saves = [s for s in steps if is_cache_save(s)]
        key_id = steps[index_of(steps, lambda s: "scripts/cmux-next/fast-tier-cache-key.sh" in s.get("run", ""))]["id"]
        self.assertEqual([s["with"]["path"] for s in saves],
                         [FAST_CACHE_DIRS["home"], FAST_CACHE_DIRS["cargo"], FAST_CACHE_DIRS["swift"]],
                         "the swift archive, whose pointer readers follow, goes last")
        for name, save in zip(("home", "cargo", "swift"), saves):
            with self.subTest(name=name):
                self.assertEqual(save["with"]["key"], "${{ steps.%s.outputs.%s-key }}" % (key_id, name))
                self.assertEqual(save["with"]["backend"], "r2")
                self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", save.get("if", ""))
                self.assertIn("github.event_name == 'push'", save.get("if", ""))
        record = index_of(steps, lambda s: "e2e_warm_derived_data.py record" in s.get("run", ""))
        tier = index_of(steps, lambda s: "scripts/cmux-next/fast-tier.py" in s.get("run", ""))
        ghostty = index_of(steps, lambda s: "init-submodule.sh ghostty-next" in s.get("run", ""))
        self.assertLess(ghostty, record)
        self.assertLess(record, tier)
        self.assertLess(tier, steps.index(saves[0]))
        self.assertIn(FAST_CACHE_MANIFEST, steps[record]["run"])
        self.assertIn("'blacksmith-12vcpu-macos-26'", str(build["runs-on"]))
        self.assertIn("needs.due.outputs.due == 'true'", build.get("if", ""))

    def test_seed_key_matches_the_fast_tier_key_for_one_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            (repo / "Packages/macOS/A").mkdir(parents=True)
            (repo / "cmux-tui").mkdir()
            (repo / "scripts/ci").mkdir(parents=True)
            (repo / "Packages/macOS/A/Package.swift").write_text("// swift-tools-version:6.0\n")
            (repo / "Packages/macOS/A/Package.resolved").write_text("{}\n")
            (repo / "Packages/macOS/A/Source.swift").write_text("let a = 1\n")
            (repo / "cmux-tui/Cargo.lock").write_text("version = 4\n")
            (repo / "scripts/ci/swiftpm-cache-layout").write_text("2\n")
            git = lambda *args: subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()
            commit = lambda message, *paths: (paths and git("add", *paths), git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message))
            git("init", "-q")
            git("add", ".")
            git("update-index", "--add", "--cacheinfo", "160000,1111111111111111111111111111111111111111,ghostty-next")
            commit("base")

            def keys(**overrides) -> dict[str, str]:
                env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "RUNNER_", "CMUX_FAST_CACHE_"))}
                env.update({"CMUX_FAST_CACHE_XCODE_VERSION": "Xcode 26.6\nBuild version 17F1",
                            "CMUX_FAST_CACHE_RUST_VERSION": "rustc 1.95.0", "GITHUB_WORKSPACE": "/Users/runner/_work/cmux/cmux",
                            "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64", "GITHUB_SHA": "abc123"})
                env.update(overrides)
                out = subprocess.run(["bash", str(CACHE_KEY_SCRIPT), str(repo)], env=env, check=True, capture_output=True, text=True).stdout
                return dict(line.split("=", 1) for line in out.splitlines())

            base = keys()
            self.assertEqual(sorted(base), sorted(f"{d}-{kind}" for d in FAST_CACHE_DIRS for kind in ("prefix", "key")))
            stems = set()
            for name in FAST_CACHE_DIRS:
                self.assertTrue(base[f"{name}-prefix"].startswith(f"cmux-next-fast-v2-{name}-macOS-ARM64-"), base)
                self.assertEqual(base[f"{name}-key"], base[f"{name}-prefix"] + "abc123")
                self.assertRegex(base[f"{name}-key"], r"^[A-Za-z0-9._-]+$", "r2-cache.sh's key alphabet")
                stems.add(base[f"{name}-prefix"].removeprefix(f"cmux-next-fast-v2-{name}-"))
            self.assertEqual(len(stems), 1, "one stem: home and cargo keys follow the swift seed's commit")
            prefix = base["swift-prefix"]
            self.assertEqual(keys(GITHUB_SHA="def456")["swift-prefix"], prefix, "a newer commit is a fallback, not a miss")
            for change in ({"CMUX_FAST_CACHE_XCODE_VERSION": "Xcode 26.7"}, {"CMUX_FAST_CACHE_RUST_VERSION": "rustc 1.96.0"},
                           {"GITHUB_WORKSPACE": "/Users/runner/work/cmux/cmux"}):
                with self.subTest(change=change):
                    self.assertNotEqual(keys(**change)["swift-prefix"], prefix)
            (repo / "Packages/macOS/A/Source.swift").write_text("let a = 2\n")
            commit("source", "Packages/macOS/A/Source.swift")
            self.assertEqual(keys()["swift-prefix"], prefix, "a source edit reuses the seed; replay rebuilds what changed")
            for path, text in (("Packages/macOS/A/Package.resolved", "{\"pins\": []}\n"), ("cmux-tui/Cargo.lock", "version = 5\n")):
                with self.subTest(path=path):
                    before = keys()["swift-prefix"]
                    (repo / path).write_text(text)
                    commit(path, path)
                    self.assertNotEqual(keys()["swift-prefix"], before)
            before = keys()["swift-prefix"]
            git("update-index", "--cacheinfo", "160000,2222222222222222222222222222222222222222,ghostty-next")
            commit("ghostty")
            self.assertNotEqual(keys()["swift-prefix"], before)

    def test_seed_is_due_only_when_the_newest_seed_is_old(self):
        def due(objects: list[dict], now: str = "2026-10-19T22:00:00Z") -> str:
            with tempfile.TemporaryDirectory() as tmp:
                listing = Path(tmp) / "objects.json"
                listing.write_text(json.dumps(objects))
                return subprocess.run([sys.executable, "-I", str(SEED_DUE_SCRIPT), "--minutes", "30", "--now", now,
                                       "--listing", str(listing)], check=True, capture_output=True, text=True).stdout.strip()

        swift = lambda modified, name="cmux-next-fast-v2-swift-macOS-ARM64-a-b-c-abc": {
            "key": f"v1/macOS-ARM64/objects/{name}.tar.zst", "last_modified": modified}
        self.assertEqual(due([]), "due=true")
        self.assertEqual(due([swift("2026-10-19T21:45:00.000Z")]), "due=false")
        self.assertEqual(due([swift("2026-10-19T21:20:00.000Z")]), "due=true")
        self.assertEqual(due([swift("2026-10-19T21:20:00.000Z"), swift("2026-10-19T21:50:00.000Z")]), "due=false")
        self.assertEqual(due([swift("2026-10-19T21:59:00.000Z", name="cmux-next-fast-v2-cargo-macOS-ARM64-a-b-c-abc")]), "due=true",
                         "the swift archive is written last; only it marks a finished seed")
        self.assertEqual(due([{"key": "v1/macOS-ARM64/latest/cmux-next-fast-v2-swift-", "last_modified": "2026-10-19T21:59:00.000Z"}]),
                         "due=true", "pointers are not archives")

    def test_receipt_names_the_seed_a_prefix_restore_picked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bin").mkdir()
            (root / "bin/pass.sh").write_text("exit 0\n")
            (root / "registry.json").write_text(json.dumps({"entries": [
                {"name": "pass", "kind": "script", "path": "bin/pass.sh", "args": [], "owner": "op-test", "bead": "cx-test"}]}))
            (root / "quarantine.json").write_text('{"entries": []}')
            receipt = root / "receipt.json"
            env = dict(os.environ, CMUX_FAST_SWIFT_CACHE_KEY="cmux-next-fast-v2-swift-x-new", CMUX_FAST_SWIFT_CACHE_HIT="false",
                       CMUX_FAST_CACHE_MATCHED_KEY="cmux-next-fast-v2-swift-x-old")
            subprocess.run([sys.executable, "-I", str(FAST_TIER_SCRIPT), "--root", str(root), "--registry", str(root / "registry.json"),
                            "--quarantine", str(root / "quarantine.json"), "--receipt", str(receipt)],
                           env=env, check=True, capture_output=True, text=True)
            cache = json.loads(receipt.read_text())["cache"]
            self.assertEqual(cache["matched_key"], "cmux-next-fast-v2-swift-x-old")
            self.assertFalse(cache["swift"]["exact_hit"])


class FastTierTriggers(unittest.TestCase):
    def test_a_fast_tier_registry_change_runs_the_workflow(self):
        """A PR that only adds a fast-tier entry (#20232) must run the tier it changes."""
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        triggers = document.get("on", document.get(True))
        for event in ("pull_request", "push"):
            paths = triggers[event]["paths"]
            for path in ("scripts/cmux-next/fast-tier.py", "scripts/cmux-next/fast-tier.json",
                         "scripts/cmux-next/quarantine.json", "scripts/cmux-next/tests/fast-tier.test.sh"):
                self.assertTrue(any(fnmatch.fnmatch(path, pattern) for pattern in paths), f"{event}: {path}")


class NightlyControlPushAdmission(unittest.TestCase):
    def release_compile_requested(self, changed_path):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        triggers = document.get("on", document.get(True))
        if not any(fnmatch.fnmatchcase(changed_path, pattern) for pattern in triggers["push"]["paths"]):
            return False
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/ci/cmux_next_route.py"), "--event", "push"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        )
        return "native=true" in result.stdout.splitlines()

    def test_a_merged_nightly_repair_can_get_its_exact_release_compile(self):
        # #21144 repaired publication but changed only nightly.yml and its tests.
        # No push workflow ran, so the exact-SHA promotion guard could never admit it.
        for changed_path in (
            ".github/workflows/nightly.yml",
            "scripts/ci/nightly_version.py",
            "scripts/ci/find-nightly-next-recovery.py",
            "scripts/ci/notarize-nightly-dmg.sh",
            "scripts/ci/publish-release-assets.py",
            "scripts/ci/finalize-release.py",
            "scripts/ci/upload-r2-object.py",
            "scripts/ci/update-release-tag.py",
            "scripts/ci/signing-keychain.sh",
            "scripts/ci/download-run-artifact.py",
            "scripts/import-apple-developer-id-intermediates.sh",
            "scripts/apple-developer-id-certs/DeveloperIDG2CA.cer",
            "scripts/prune_nightly_release_assets.py",
        ):
            with self.subTest(changed_path=changed_path):
                self.assertTrue(self.release_compile_requested(changed_path), changed_path)

    def test_unrelated_ci_changes_do_not_request_a_release_compile(self):
        self.assertFalse(self.release_compile_requested("scripts/ci/ci-health-report.py"))


FAST_TIER_FORK_CLAUSE = (
    "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository "
    "&& 'blacksmith-6vcpu-macos-26' || "
)
FAST_LANE_CLAUSE = (
    "vars.CI_FAST_LANE_RUNNER != '' && vars.CI_PR_POOL_OWNED == '1' && "
    "(github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') && vars.CI_FAST_LANE_RUNNER || "
)
# The fast tier's runs-on before CI_FAST_LANE_RUNNER: with the variable unset it must route exactly so.
FAST_TIER_RUNNER_WITHOUT_FAST_LANE = (
    "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || " + FAST_TIER_FORK_CLAUSE
    # next_macos_cascade.py: a free Blacksmith slot (12 vCPU, then 6) the placement found.
    + "(github.run_attempt == 1 || github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]') "
    "&& contains(needs.macos-placement.outputs.blacksmith_12_jobs, ' fast-tier ') "
    "&& 'blacksmith-12vcpu-macos-26' || "
    "(github.run_attempt == 1 || github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]') "
    "&& contains(needs.macos-placement.outputs.blacksmith_6_jobs, ' fast-tier ') "
    "&& 'blacksmith-6vcpu-macos-26' || "
    "(github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') && needs.macos-placement.outputs.runner || "
    "github.repository_owner != 'manaflow-ai' && 'macos-26' || (" + FAST_TIER_FORK_CLAUSE
    + "vars.CI_PR_POOL_OWNED == '1' && contains(fromJSON('[\"pull_request\",\"push\",\"workflow_dispatch\"]'), github.event_name) "
    "&& (github.run_attempt <= 2 || github.triggering_actor != 'github-actions[bot]') && vars.CI_SIDE_LANE_RUNNER || "
    "needs.macos-placement.outputs.retry_runner || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26') }}"
)


class FastTierRunner(unittest.TestCase):
    def test_the_fast_lane_label_comes_after_the_fork_clause(self):
        """vars.CI_FAST_LANE_RUNNER gives the fast tier its own owned runner label. A fork pull
        request must take its hosted label before that variable is read, and with the variable
        unset the route is the one the job had before it."""
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        runs_on = job["runs-on"]
        self.assertIn(FAST_LANE_CLAUSE, runs_on)
        self.assertLess(runs_on.index(FAST_TIER_FORK_CLAUSE), runs_on.index("vars.CI_FAST_LANE_RUNNER"))
        self.assertTrue(runs_on.index(FAST_TIER_FORK_CLAUSE) + len(FAST_TIER_FORK_CLAUSE) == runs_on.index(FAST_LANE_CLAUSE))
        self.assertEqual(runs_on.replace(FAST_LANE_CLAUSE, "", 1), FAST_TIER_RUNNER_WITHOUT_FAST_LANE)
        # No env value mirrors runs-on with the old route.
        for value in (job.get("env") or {}).values():
            self.assertNotIn("CI_SIDE_LANE_RUNNER", str(value))


class _UnsetIsEmpty(dict):
    def __missing__(self, key):
        return ""


def evaluate(expression: str, context: dict):
    """Evaluate a job `if:` or `runs-on:` against literal context values.

    Covers the subset of GitHub's expression syntax this workflow uses: `&&`, `||`, `!`,
    `==`, `!=`, `<=`, contains(), startsWith(), fromJSON() and `!cancelled()` (true: the
    run was not cancelled). A context name the test does not set reads as '' (unset).
    """
    text = expression.strip()
    if text.startswith("${{"):
        text = text[3:].rsplit("}}", 1)[0]
    text = text.replace("!cancelled()", "True")
    text = re.sub(r"\b(?:github|needs|inputs|vars)\.[A-Za-z0-9_.*-]+",
                  lambda match: f"_ctx[{match.group(0)!r}]", text)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    text = re.sub(r"(?<!')\btrue\b(?!')", "True", text)
    names = {
        "_ctx": _UnsetIsEmpty(context),
        "contains": lambda haystack, needle: needle in haystack,
        "startsWith": lambda value, prefix: str(value).startswith(prefix),
        "fromJSON": json.loads,
    }
    return eval(text, {"__builtins__": {}}, names)  # noqa: S307 - this repository's workflow, not input


class ReleaseCompileOnCmuxNextSwiftPullRequests(unittest.TestCase):
    """A PR that changes any CmuxNext package Swift file runs the Release compile; a web-only PR does not.

    #20543 left ordinary PRs only the Debug fast tier. A Release-only swift-frontend crash
    (EarlyPerfInliner on a main-actor generic class's isolated deinit, cx-ebm.59.5,
    PageCallDeadline.Once) then reached feat-cmux-next through a PR that changed CmuxNext
    Swift sources: Debug `swift build` cannot see an optimizer crash. Fixed in #20876.
    """

    def job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile"]

    def context(self, changed: list[str], *, event: str = "pull_request", labels: tuple[str, ...] = ()) -> dict:
        from cmux_next_route import outputs, route

        routed = outputs(route(ROOT, event, changed, set(labels)))
        context = {f"needs.path_route.outputs.{key}": value for key, value in routed.items()}
        context.update({
            "github.event_name": event,
            "github.ref": "refs/pull/1/merge" if event == "pull_request" else "refs/heads/feat-cmux-next",
            "github.repository": "manaflow-ai/cmux",
            "github.repository_owner": "manaflow-ai",
            "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
            "github.event.pull_request.labels.*.name": list(labels),
            "github.run_attempt": 1,
            "github.triggering_actor": "someone",
            "needs.push-head-preflight.outputs.current": "true",
            # An ordinary PR skips macos-placement (full-ci gated), so its outputs are empty.
            "needs.macos-placement.outputs.runner": "",
            "vars.CI_PR_POOL_OWNED": "1",
            "vars.CI_SIDE_LANE_RUNNER": "shared-side-route",
            "vars.CI_NEXT_PROMOTE_POOL": "reserved-promotion-runner",
            "vars.MACOS_RUNNER_26": "hosted-macos",
        })
        return context

    def runs(self, context: dict) -> bool:
        return bool(evaluate(self.job()["if"], context))

    def test_a_cmuxnext_swift_pr_runs_the_release_compile_on_the_shared_route(self):
        context = self.context(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkspaceSpawn.swift"])
        self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "true")
        self.assertTrue(self.runs(context))
        # Never the reserved promotion runner on a PR, with macos-placement skipped.
        self.assertEqual(evaluate(self.job()["runs-on"], context), "shared-side-route")
        self.assertEqual(evaluate(self.job()["env"]["CMUX_NEXT_RUNNER"], context), "shared-side-route")

    def test_the_cx_ebm_59_5_file_mix_runs_the_release_compile(self):
        # 67ab9281307a: two CmuxNext Sources files and a proof script. The script made
        # swift_canary false, so a swift_canary gate would not have run this job.
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertEqual(jobs["path_route"]["outputs"].get("cmuxnext_swift"),
                         "${{ steps.route.outputs.cmuxnext_swift }}")
        for changed in (
            ["Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/ChiefProfilePageRelay.swift",
             "Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/PageCallDeadline.swift",
             "scripts/cmux-next/chief-create-click-proof.py"],
            ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkspaceSpawn.swift",
             "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/WorkspaceSpawnFirstTabTests.swift"],
        ):
            with self.subTest(changed=changed):
                context = self.context(changed)
                self.assertEqual(context["needs.path_route.outputs.swift_canary"], "false")
                self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "true")
                self.assertTrue(self.runs(context))
                self.assertEqual(evaluate(self.job()["runs-on"], context), "shared-side-route")

    def test_a_web_only_pr_skips_the_release_compile(self):
        for changed in (["web/app/page.tsx"], ["webviews/src/app/Thing.tsx"]):
            with self.subTest(changed=changed):
                context = self.context(changed)
                self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "false")
                self.assertFalse(self.runs(context))

    def test_a_native_pr_without_cmuxnext_swift_keeps_the_full_ci_cadence(self):
        context = self.context(["App/Info.plist"])
        self.assertEqual(context["needs.path_route.outputs.native"], "true")
        self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "false")
        self.assertFalse(self.runs(context))
        self.assertTrue(self.runs(self.context(["App/Info.plist"], labels=("full-ci",))))

    def test_base_pushes_still_run_it_on_the_promotion_runner(self):
        context = self.context([], event="push")
        self.assertTrue(self.runs(context))
        self.assertEqual(evaluate(self.job()["runs-on"], context), "reserved-promotion-runner")

if __name__ == "__main__":
    unittest.main()
