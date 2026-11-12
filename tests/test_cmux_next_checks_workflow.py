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
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import unwrap_fork_pool_reads  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
# tests/process_gone.py, loaded by path the same way.
_process_gone_spec = _git_fixture_importlib.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
process_gone = _git_fixture_importlib.module_from_spec(_process_gone_spec)
_process_gone_spec.loader.exec_module(process_gone)
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
ARTIFACTS_WORKFLOW = WORKFLOW.parent / "cmux-tui-artifacts.yml"
TREE_JOBS = ("daemon-test", "cmux-scheme-compile")
# Run on a pull request only with full-ci (HeavyMacCompilesBehindFullCi).
HEAVY_COMPILES = ("release-compile", "cmux-scheme-compile")
GODFILES = ROOT / "scripts/cmux-next/check-no-godfiles.sh"
JOB = "checks"


def steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]["steps"]


def is_setup(step: dict) -> bool:
    """Checkout and toolchain steps: an action, not a check script; the reset of a reused
    workspace's submodule checkouts that follows checkout on a mini; the check Python (PyYAML)
    a mini lacks; and the start of the slow checks in the background, whose own steps wait for
    their results."""
    run = str(step.get("run", ""))
    return ("uses" in step or "scripts/ci/reset-stale-submodules.sh" in run
            or step.get("name") == "Prepare check Python (PyYAML) and timeout"
            or "scripts/ci/run-checks-concurrently.sh --start" in run)


def check_commands(step: dict) -> str:
    """What a check step runs: its own script, or for a step that waits on the background
    start, the commands the start lists under the step's `[id]`."""
    run = step["run"]
    if "run-checks-concurrently.sh --wait" not in run:
        return run
    start = next(s for s in steps() if "scripts/ci/run-checks-concurrently.sh --start" in str(s.get("run", "")))
    owned, current = [], None
    for line in start["run"].splitlines():
        line = line.strip()
        match = re.fullmatch(r"\[([A-Za-z0-9_.-]+)\]", line)
        if match:
            current = match.group(1)
        elif line and current == step["id"]:
            owned.append(line)
    return "\n".join(owned)



# The DEV daily placement (dev-daily-place) hands cmux-scheme-compile a runs-on that may be a label list
# ([a pool label, glaeda-runner-<name>]); the job's label copy reads that list's first label instead.
DAILY_PICK = ("needs.dev-daily-place.outputs.runs_on != '' && fromJSON(needs.dev-daily-place.outputs.runs_on)",
              "needs.dev-daily-place.outputs.runner_label != '' && needs.dev-daily-place.outputs.runner_label")


def label_copy(runs_on: str) -> str:
    """runs-on as the job's own CMUX_NEXT_RUNNER copy states it."""
    return runs_on.replace(*DAILY_PICK)

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
            with self.subTest(step=step.get("name") or step.get("uses")):
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

    # Correctness and safety checks: never on the warn-only style list (Leo, 2026-10-19).
    BLOCKING = {
        "No literal state roots (per-build isolation S7, cx-is1kf.8)",
        "Main-thread concurrency",
        "Crash safety",
        "Tests inject their notification center",
        "String tables (21 languages)",
        "Module resource bundles",
        "Phone lane field allowlist",
        "Stale scheme PCM cleanup",
        "Script tests (pin-cmux-tui, embed-cef, ensure-cef store)",
        "Ghostty resources bundle",
        "Bundled terminfo",
        "Checks job structure",
        "Tier routing",
        "Web bundle key inputs",
        "Companion workflows",
        "DEV update and classic import scripts",
        "Routing replay (router changes)",
        "Check the app FFI pin",
        "Daemon capabilities export is fresh",
        "App capability references are listed",
        "Capability texts never say update the app",
    }

    def style_checks(self) -> list[str]:
        _, _, aggregate = self.split()
        return [line for line in aggregate["env"]["STYLE_CHECKS"].splitlines() if line.strip()]

    def test_style_checks_name_real_steps_and_no_blocking_check(self):
        _, checks, _ = self.split()
        names = {step["name"] for step in checks}
        style = self.style_checks()
        self.assertTrue(style)
        self.assertLessEqual(set(style), names)
        self.assertFalse(set(style) & self.BLOCKING)
        self.assertLessEqual(self.BLOCKING, names)
        for name in ("Package conventions lint", "Motion tokens", "Type scale", "CmuxNextApp size cap",
                     "God files and types (Swift)", "Scrollbars thin, one style"):
            with self.subTest(name=name):
                self.assertIn(name, style)
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(document["env"]["CMUX_NEXT_STYLE_GUARDS"], "warn")

    def run_warn_aggregate(self, outcomes: str, guards: str = "warn") -> subprocess.CompletedProcess:
        _, _, aggregate = self.split()
        with tempfile.NamedTemporaryFile() as summary:
            return subprocess.run(
                ["bash", "-c", aggregate["run"]],
                env={**os.environ, "OUTCOMES": outcomes, "GITHUB_STEP_SUMMARY": summary.name,
                     "STYLE_CHECKS": aggregate["env"]["STYLE_CHECKS"], "CMUX_NEXT_STYLE_GUARDS": guards},
                capture_output=True,
                text=True,
            )

    def test_a_red_style_check_only_warns(self):
        result = self.run_warn_aggregate("failure|Package conventions lint\nfailure|Type scale\nsuccess|Crash safety\n")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("::warning title=cmux-next style guard (warn-only)::Package conventions lint", result.stdout)
        self.assertNotIn("::error", result.stdout)

    def test_concurrency_failure_blocks_even_with_style_guards_warn(self):
        result = self.run_warn_aggregate("failure|Main-thread concurrency\nsuccess|Crash safety\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Main-thread concurrency", result.stdout)

    def test_a_red_blocking_check_still_fails_beside_a_style_warning(self):
        result = self.run_warn_aggregate("failure|Package conventions lint\nfailure|Crash safety\n")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("::error title=cmux-next check::red check: Crash safety", result.stdout)
        self.assertNotIn("red check: Package conventions lint", result.stdout)

    def test_a_style_check_that_never_ran_still_fails(self):
        result = self.run_warn_aggregate("|Package conventions lint\n")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("- Package conventions lint (not run)", result.stdout)

    def test_style_checks_fail_again_when_the_switch_is_fail(self):
        result = self.run_warn_aggregate("failure|Package conventions lint\n", guards="fail")
        self.assertEqual(result.returncode, 1, result.stdout)

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
        lint = [step for step in checks if "lint-ios-package-conventions.sh" in check_commands(step)]
        self.assertEqual(len(lint), 1, [step["name"] for step in checks])
        self.assertEqual(check_commands(lint[0]).strip(), "./scripts/lint-ios-package-conventions.sh")
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
        # What the step runs on a pull request: AppFfiPinStepJudgesWithTheBaseCopy.
        script_tests = next(step for step in checks if step.get("id") == "script-tests")
        self.assertIn("bash scripts/cmux-next/tests/check-app-ffi-pin.test.sh", check_commands(script_tests))
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


class AppFfiPinStepJudgesWithTheBaseCopy(unittest.TestCase):
    """On a pull request the app FFI pin step runs the base's copy of the check and its pin reader (the merge commit's
    first parent), extracted outside the checkout, against the pull request's tree, with a clean environment.

    Earlier steps of the checks job run the pull request's code, which can rewrite the checkout's copy of the check
    on disk or change PATH, so that copy and that environment must not decide the verdict: base_red_excuse.py trusts
    the pin verdict of a pull request that leaves the check's files alone in its diff (FFI_PIN_CHECK_CODE)."""

    ZEROS = "0" * 64

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        (self.repo / "scripts/ci").mkdir(parents=True)
        (self.repo / "Packages/macOS/CmuxNext").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/cmux-next/check-app-ffi-pin.sh", self.repo / "scripts/cmux-next/check-app-ffi-pin.sh")
        shutil.copy(ROOT / "scripts/ci/app_ffi_pin.py", self.repo / "scripts/ci/app_ffi_pin.py")
        crate = self.repo / "cmux-tui/crates/cmux-app-ffi"
        (crate / "src").mkdir(parents=True)
        (crate / "Cargo.toml").write_text('[package]\nname = "x"\n\n[lib]\npath = "src/lib.rs"\n')
        (crate / "src/lib.rs").write_text("// ffi\n")
        self.git("init", "-q", "-b", "base")
        self.commit("sources")
        self.pinned = self.rev("HEAD")
        # The pin: app-ffi-pin.json, and Package.swift holding its one loader block (scripts/ci/app_ffi_pin.py).
        # Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
        if str(ROOT / "scripts/ci") not in sys.path:
            sys.path.insert(0, str(ROOT / "scripts/ci"))
        pin = importlib.import_module("app_ffi_pin")
        (self.repo / "Packages/macOS/CmuxNext/Package.swift").write_text(
            "import Foundation\nimport PackageDescription\n\n" + pin.loader(self.ZEROS))
        (self.repo / "Packages/macOS/CmuxNext/app-ffi-pin.json").write_text(pin.render(self.pinned, self.ZEROS))
        self.commit("pin")
        # The pull request changes an FFI source and not the pin: its own stale pin, red on the base's check.
        self.git("checkout", "-q", "-b", "pr")
        (crate / "src/lib.rs").write_text("// ffi, changed\n")
        self.commit("pr")
        self.git("checkout", "-q", "base")
        self.git("merge", "-q", "--no-ff", "-m", "merge", "pr")
        self.merge = self.rev("HEAD")
        self.runner_temp = self.tmp / "runner-temp"
        self.runner_temp.mkdir()

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-qm", message)

    def rev(self, ref: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", ref], check=True, capture_output=True,
                              text=True).stdout.strip()

    def run_step(self, path_prefix: Path | None = None, home: Path | None = None) -> subprocess.CompletedProcess:
        step = next(step for step in steps() if step.get("id") == "app-ffi-pin")
        env = git_fixture_env.fixture_env({key: value for key, value in os.environ.items() if not key.startswith("GIT_")})
        env.update(EVENT_NAME="pull_request", GITHUB_SHA=self.merge, RUNNER_TEMP=str(self.runner_temp))
        if home is not None:
            env["HOME"] = str(home)
        if path_prefix is not None:
            env["PATH"] = f"{path_prefix}:{env.get('PATH', '/usr/bin:/bin')}"
        return subprocess.run(["bash", "-e", "-c", step["run"]], cwd=self.repo, env=env, capture_output=True,
                              text=True, timeout=120)

    def assert_own_stale_pin(self, result: subprocess.CompletedProcess) -> None:
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(f"error: the app FFI sources changed since the pinned source {self.pinned}", output)
        self.assertNotIn("planted", output)

    def test_the_base_copy_judges_the_pull_request(self):
        self.assert_own_stale_pin(self.run_step())

    def test_a_check_rewritten_on_disk_does_not_run(self):
        # An earlier step's code rewrites the checkout's copy of the check and of its pin reader; the diff of the
        # pull request still leaves both alone.
        (self.repo / "scripts/cmux-next/check-app-ffi-pin.sh").write_text(
            "#!/usr/bin/env bash\necho 'app FFI pin: sources match (planted)'\n")
        (self.repo / "scripts/ci/app_ffi_pin.py").write_text(
            f"print('{self.merge} {self.ZEROS}')  # planted\n")
        self.assert_own_stale_pin(self.run_step())

    def test_ffi_inputs_rewritten_on_disk_do_not_count(self):
        # An earlier step's code deletes the FFI crate's Cargo.toml (no FFI inputs are left to compare) and repins
        # app-ffi-pin.json to the merge commit on disk. The pull request's commit still has both as they were.
        (self.repo / "cmux-tui/crates/cmux-app-ffi/Cargo.toml").unlink()
        pin_file = self.repo / "Packages/macOS/CmuxNext/app-ffi-pin.json"
        pin_file.write_text(pin_file.read_text().replace(self.pinned, self.merge))
        self.assert_own_stale_pin(self.run_step())

    def planted_hook(self, directory: Path) -> None:
        """A post-checkout hook that rewrites the extracted base check (beside the worktree it runs in)."""
        directory.mkdir(parents=True, exist_ok=True)
        hook = directory / "post-checkout"
        hook.write_text("#!/bin/sh\nprintf '#!/usr/bin/env bash\\necho \"app FFI pin: sources match (planted)\"\\n' "
                        "> ../scripts/cmux-next/check-app-ffi-pin.sh\n")
        hook.chmod(0o755)

    def test_a_hook_in_the_home_git_config_does_not_run(self):
        # An earlier step's code writes ~/.gitconfig: its hooks path holds a post-checkout hook.
        home = self.tmp / "home"
        self.planted_hook(home / "hooks")
        (home / ".gitconfig").write_text(f"[core]\n\thooksPath = {home / 'hooks'}\n")
        self.assert_own_stale_pin(self.run_step(home=home))

    def test_a_hook_in_the_checkout_does_not_run(self):
        # An earlier step's code puts a post-checkout hook in the checkout's .git/hooks.
        self.planted_hook(self.repo / ".git/hooks")
        self.assert_own_stale_pin(self.run_step())

    def test_a_check_left_out_of_the_base_extraction_still_runs_the_base_copy(self):
        # An earlier step's code marks the check export-ignore in .git/info/attributes (git archive then leaves it
        # out without an error) and rewrites the checkout's copy.
        (self.repo / ".git/info").mkdir(exist_ok=True)
        (self.repo / ".git/info/attributes").write_text(
            "scripts/cmux-next/check-app-ffi-pin.sh export-ignore\nscripts/ci/app_ffi_pin.py export-ignore\n")
        (self.repo / "scripts/cmux-next/check-app-ffi-pin.sh").write_text(
            "#!/usr/bin/env bash\necho 'app FFI pin: sources match (planted)'\n")
        self.assert_own_stale_pin(self.run_step())

    def test_the_rollup_sources_no_file_from_the_checkout(self):
        # The pin step continues on error, so the rollup decides the job. Run it as the runner does (the workflow's
        # env, then the step's literal env) after an earlier step rewrote scripts/ci/api_call_log/env.sh, which the
        # workflow's BASH_ENV names, to end every shell green.
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        rollup = steps()[-1]
        env = {key: value for key, value in os.environ.items() if key != "BASH_ENV"}
        for scope in (document.get("env") or {}, rollup.get("env") or {}):
            env.update({key: str(value) for key, value in scope.items() if "${{" not in str(value)})
        planted = self.repo / "scripts/ci/api_call_log/env.sh"
        planted.parent.mkdir(parents=True)
        planted.write_text("echo planted; exit 0\n")
        summary = self.tmp / "summary"
        env.update(GITHUB_WORKSPACE=str(self.repo), GITHUB_STEP_SUMMARY=str(summary), EVENT_NAME="pull_request",
                   OUTCOMES="failure|Check the app FFI pin\n")
        result = subprocess.run(["bash", "-e", "-c", rollup["run"]], cwd=self.repo, env=env, capture_output=True,
                                text=True, timeout=60)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("Check the app FFI pin", output)
        self.assertNotIn("planted", output)

    def test_a_changed_path_does_not_reach_the_check(self):
        # An earlier step's code puts its own python3 (which reads every pin as the merge commit, so the sources
        # match) and curl first on PATH for the steps after it.
        bin_dir = self.tmp / "planted-bin"
        bin_dir.mkdir()
        (bin_dir / "python3").write_text(f"#!/bin/sh\necho '{self.merge} {self.ZEROS}'\n")
        (bin_dir / "curl").write_text("#!/bin/sh\necho planted >&2\nexit 22\n")
        for tool in bin_dir.iterdir():
            tool.chmod(0o755)
        self.assert_own_stale_pin(self.run_step(path_prefix=bin_dir))


def line_of(path: str, text: str) -> int:
    """The 1-based line of the first line of path that contains text (0 when none does), so a
    failure names the line to edit."""
    for number, line in enumerate((ROOT / path).read_text(encoding="utf-8").splitlines(), start=1):
        if text in line:
            return number
    return 0


class WebviewsWarnSplitCoversCheck(unittest.TestCase):
    """Under CMUX_NEXT_STYLE_GUARDS=warn, ci-web runs `bun run check` as separate commands.

    A check added to package.json's `check` script but not to that list would stop
    running on feat-cmux-next without a warning or a failure (#22492's
    check:switch-fetches did).
    """

    def test_every_part_of_bun_run_check_runs_in_the_warn_branch(self) -> None:
        package = json.loads((ROOT / "webviews/package.json").read_text(encoding="utf-8"))
        scripts = package["scripts"]
        parts = [part.strip() for part in scripts.get("check:pieces", scripts["check"]).split("&&")]
        jobs = yaml.safe_load((ROOT / ".github/workflows/ci-web.yml").read_text(encoding="utf-8"))["jobs"]
        runs = [
            step["run"]
            for job in jobs.values()
            for step in job.get("steps", [])
            if step.get("id") == "webviews-check"
        ]
        self.assertEqual(len(runs), 1, "one webviews-check step")
        warn_branch = runs[0].split("fi\n", 1)[1]
        loop = re.search(r"for check in ([^;]+); do", warn_branch)
        self.assertIsNotNone(loop, "the warn branch loops over the style checks")
        looped = set(loop.group(1).split())
        # The warn branch runs fast_gate_webviews_checks.py, which runs each of its CHECKS (#24252).
        import fast_gate_webviews_checks
        gated = set()
        if re.search(r"fast_gate_webviews_checks\.py[^\n]*\|\| status=1", warn_branch):
            gated = set(fast_gate_webviews_checks.CHECKS)
        gated_commands = {package["scripts"][name] for name in gated if name in package["scripts"]}
        ci_web = ".github/workflows/ci-web.yml"
        loop_line = line_of(ci_web, "for check in ")
        script_key = "check:pieces" if "check:pieces" in scripts else "check"
        script_line = line_of("webviews/package.json", '"%s":' % script_key)
        missing = []
        for part in parts:
            if part.startswith("vp "):
                if not (part in gated_commands or f"./node_modules/.bin/{part} ||" in warn_branch):
                    missing.append(
                        f"{ci_web}:{loop_line}: `{part}` (webviews/package.json:{script_line} "
                        f"`{script_key}`) does not run when CMUX_NEXT_STYLE_GUARDS=warn; run "
                        f"`./node_modules/.bin/{part} || echo ...` in the warn branch below this line")
                continue
            name = part.removeprefix("bun run ").strip()
            if not (name in looped or name in gated or f"bun run {name} || status=1" in warn_branch):
                missing.append(
                    f"{ci_web}:{loop_line}: `{part}` (webviews/package.json:{script_line} "
                    f"`{script_key}`) does not run when CMUX_NEXT_STYLE_GUARDS=warn; add `{name}` to this "
                    f"`for check in ...` list (warn-only) or to scripts/ci/fast_gate_webviews_checks.py CHECKS (gating)")
        self.assertEqual(missing, [], "\n" + "\n".join(missing))


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
        env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
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
        env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
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
        # A same-repository PR runs its routed tiers; full-ci is what a fork PR needs
        # (SameRepositoryPullRequestsRunTheirTiers evaluates the conditions).
        for job_id in ("swift-canary", "generated-files", "daemon-test"):
            self.assertIn("github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository || "
                          "contains(github.event.pull_request.labels.*.name, 'full-ci')", jobs[job_id]["if"], job_id)
        # The two heavy app compiles and swift-test are behind full-ci on every PR
        # (HeavyMacCompilesBehindFullCi; swift-test since 2026-11-05: on every PR push it was
        # cancelled or skipped and never passed, and the tip suite dispatch gives the base verdict).
        for job_id in HEAVY_COMPILES + ("swift-test",):
            self.assertIn("github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'full-ci')",
                          jobs[job_id]["if"], job_id)
            self.assertNotIn("github.event.pull_request.head.repo.full_name == github.repository || ", jobs[job_id]["if"], job_id)
        # macos-placement places owned runners: same-repository pull requests only.
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", jobs["macos-placement"]["if"])

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
        # Only `path`, which names where the tree would be and never fetches or waits (#26809's broad pass
        # reads it once so every shard sees the same tree).
        calls = [call for step in swift["steps"]
                 for call in re.findall(r"pin-cmux-tui\.sh(?:[ \t]+(\S+))?", step.get("run", ""))]
        self.assertEqual([call for call in calls if call != "path"], [])
        self.assertIn("SWIFT_FILTER", swift["env"])

    def test_swift_test_prioritizes_changed_suites_before_the_broad_pass(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        route = jobs["path_route"]
        self.assertIn("swift_priority_filter", route["outputs"])
        swift = jobs["swift-test"]
        self.assertIn("SWIFT_PRIORITY_FILTER", swift["env"])
        run = next(step for step in swift["steps"] if step.get("name", "").startswith("Run package tests"))
        script = run["run"]
        self.assertIn("SWIFT_PRIORITY_FILTER", script)
        self.assertIn("--skip", script)
        self.assertIn("priority", script.lower())
        cloud = next(step for step in swift["steps"] if step.get("name") == "Run CloudBringBack cases in fresh processes")
        self.assertNotIn("!contains(env.SWIFT_PRIORITY_FILTER, 'CloudBringBackTests')", cloud["if"])

    def test_generated_files_are_checked_outside_the_package_tests(self):
        """a925bd9 went red when PRs that skipped swift test landed a stale export."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs = " ".join(step.get("run", "") for step in jobs["generated-files"]["steps"])
        self.assertIn("judge-action-exports.sh", runs)
        # The CI target graph is bot-only (#21946): no event checks it.
        self.assertNotIn("ci-target-graph.py --check", runs)
        self.assertNotIn("same-tree-cmux-tui", jobs["generated-files"]["needs"])
        # swift-test runs the checks only where path routing folds them into its own package
        # build (generated_host, tests/test_cmux_next_generated_fold.py); a PR that skips swift
        # test still gets the generated-files job.
        for step in jobs["swift-test"]["steps"]:
            if "judge-action-exports.sh" in step.get("run", ""):
                self.assertIn("env.CMUX_NEXT_FOLD_GENERATED == 'true'", step["if"])
        self.assertIn("needs.path_route.outputs.generated_host == 'generated-files'", jobs["generated-files"]["if"])

    def test_generated_files_use_cached_web_bundles_without_rebuilding(self):
        """A cache hit must install the keyed bundles and skip the source build."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        steps = jobs["generated-files"]["steps"]
        build = next(step for step in steps if step.get("name") == "Build the web bundles")
        # A reused pass (JobsReuseAPassOnTheSameInputs) skips both.
        # 2026-10-26: or this run's Linux web-bundles artifact, which the minis can
        # read when they cannot read Blacksmith's cache.
        self.assertEqual(build["if"], "${{ (steps.web-bundle-r2.outputs.cache-hit != 'true' && steps.web-bundle-cache.outputs.cache-hit != 'true' && steps.web-bundle-artifact.outcome != 'success') && {REUSE_GUARD} }}".replace("{REUSE_GUARD}", REUSE_GUARD))
        install = next(step for step in steps if step.get("name") == "Install the restored web bundles")
        self.assertEqual(install["if"], "${{ (steps.web-bundle-r2.outputs.cache-hit == 'true' || steps.web-bundle-cache.outputs.cache-hit == 'true' || steps.web-bundle-artifact.outcome == 'success') && {REUSE_GUARD} }}".replace("{REUSE_GUARD}", REUSE_GUARD))

    def test_package_jobs_use_cached_web_bundles_without_rebuilding(self):
        """Swift and daemon jobs must take the same cache hit fast path."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for job_id in ("swift-test", "daemon-test"):
            with self.subTest(job=job_id):
                steps = jobs[job_id]["steps"]
                build = next(step for step in steps if step.get("name") == "Build the web bundles")
                # swift-test also skips it on a reused pass (JobsReuseAPassOnTheSameInputs).
                miss = "steps.web-bundle-r2.outputs.cache-hit != 'true' && steps.web-bundle-cache.outputs.cache-hit != 'true' && steps.web-bundle-artifact.outcome != 'success'"
                self.assertIn(build["if"], (miss, "${{ (" + miss + ") && " + REUSE_GUARD + " }}"))

    def test_mac_jobs_install_the_run_s_linux_web_bundles(self):
        """2026-10-26: the minis cannot read Blacksmith's cache, so they rebuilt the
        bundles the Linux web-bundles job had just built (40 s of Mac time on 56% of
        swift test jobs). The Linux job hands them over as a run artifact named after
        the source key; a Mac job whose key matches installs it."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        upload = next(step for step in jobs["web-bundles"]["steps"]
                      if step.get("name") == "Hand the web bundles to this run's Mac jobs")
        self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["name"], "cmux-next-web-bundles-${{ steps.web-bundle-key.outputs.key }}")
        self.assertEqual(upload["with"]["path"], "web-bundles-out")
        self.assertTrue(upload["continue-on-error"])
        for job_id in ("swift-test", "daemon-test", "generated-files"):
            with self.subTest(job=job_id):
                steps = jobs[job_id]["steps"]
                names = [step.get("name") for step in steps]
                download = steps[names.index("Download the web bundles this run's bundle job built")]
                self.assertEqual(download["id"], "web-bundle-artifact")
                self.assertTrue(download["uses"].startswith("actions/download-artifact@"))
                self.assertEqual(download["with"]["name"], upload["with"]["name"])
                self.assertTrue(download["continue-on-error"])
                self.assertIn("needs.web-bundles.result == 'success'", download["if"])
                self.assertIn("steps.web-bundle-cache.outputs.cache-hit != 'true'", download["if"])
                # After both caches, before the install and the build.
                self.assertLess(names.index("Restore the web bundles built for this source key"), names.index(download["name"]))
                self.assertLess(names.index(download["name"]), names.index("Install the restored web bundles"))
                self.assertLess(names.index("Install the restored web bundles"), names.index("Build the web bundles"))

    def test_swift_test_leaves_the_layout_reducer_to_the_linux_fast_tier(self):
        """fast-tier-cargo runs the sidebar layout reducer's cargo tests on Linux for
        every feat-cmux-next pull request and push; swift test keeps them for the
        events of its own fast-tier-cargo does not take (a dispatch, a main push)."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        registry = json.loads((ROOT / "scripts" / "cmux-next" / "fast-tier.json").read_text(encoding="utf-8"))
        reducer = [e for e in registry["entries"] if e.get("package") == "cmux-layout-reducer"]
        self.assertEqual([e["kind"] for e in reducer], ["cargo"])
        cargo_if = " ".join(jobs["fast-tier-cargo"]["if"].split())
        self.assertIn("(github.event_name == 'pull_request' && github.base_ref == 'feat-cmux-next')", cargo_if)
        self.assertIn("(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')", cargo_if)
        self.assertNotIn("workflow_dispatch", cargo_if)
        reducer_steps = [step for step in jobs["swift-test"]["steps"]
                         if "sidebar layout reducer" in step.get("name", "")]
        self.assertEqual(len(reducer_steps), 3)
        for step in reducer_steps:
            self.assertIn("!(github.event_name == 'pull_request' && github.base_ref == 'feat-cmux-next')",
                          step["if"], step["name"])
        test = next(step for step in reducer_steps if step["name"] == "Test sidebar layout reducer")
        self.assertIn("cargo test -p cmux-layout-reducer", test["run"])
        # A pull request's pass (no reducer tests) never stands in for a dispatch or
        # main push (which run them): the reuse key names whether they ran.
        fingerprint = next(step for step in jobs["swift-test"]["steps"]
                           if step.get("name") == "Fingerprint this job's inputs")
        self.assertIn("--extra \"layout_reducer=${{ !(github.event_name == 'pull_request' && github.base_ref == 'feat-cmux-next') }}\"",
                      fingerprint["run"])
        # swift test runs on pull requests and dispatches, never a feat-cmux-next push.
        self.assertIn("!(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')",
                      jobs["swift-test"]["if"])

    def test_package_jobs_wait_for_single_web_bundle_producer(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for job_id in ("swift-test", "daemon-test", "generated-files"):
            with self.subTest(job=job_id):
                needs = jobs[job_id]["needs"]
                self.assertIn("web-bundles", needs)
                self.assertIn("needs.web-bundles.result == 'skipped'", jobs[job_id]["if"])

    def test_web_bundles_job_only_produces_the_bundles(self):
        """swift test, daemon tests and generated files run only when web-bundles succeeds. Its
        script self-tests ran last in that job: on 2026-10-20 the key-inputs test went red on
        feat-cmux-next, every PR's web-bundles failed after the bundles were cached, and the three
        Mac tiers were skipped (a skip reads as passing), so #22455 landed a test that did not
        compile. The self-tests are checks-job steps; the producer runs no test script."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs = [step.get("run", "") for step in jobs["web-bundles"]["steps"]]
        self.assertFalse([run for run in runs if "tests/" in run], runs)
        check_runs = " ".join(step.get("run", "") for step in jobs["checks"]["steps"])
        for script in ("tests/test_web_bundle_key_inputs.sh", "tests/test_build_web_bundles_from.sh"):
            with self.subTest(script=script):
                self.assertIn(script, check_runs)

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
        self.assertNotIn("scripts/cmux-next/ci-target-graph.py", fail["run"])
        self.assertIn("exit 1", fail["run"])
        self.assertNotIn("autofix", fail["run"])

    def test_red_push_runs_name_their_pull_requests(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        attribution = jobs["push-attribution"]
        self.assertIn("failure()", attribution["if"])
        self.assertIn("github.event_name == 'push'", attribution["if"])
        for job_id in ("checks", "generated-files", "generated-verdict", "swift-test", "daemon-test", "release-compile", "cmux-scheme-compile"):
            self.assertIn(job_id, attribution["needs"])

    def test_push_reads_spend_a_cmux_bot_token_not_the_repository_token(self):
        """Push attribution reads git history and a cmux-bot read token; job reuse lookups of a
        feat-cmux-next push or dispatch do too. Never minted on a pull request run, comments stay on
        the workflow token, and a failed mint falls back to it."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        steps = jobs["push-attribution"]["steps"]
        names = [step.get("name") for step in steps]
        fetch = steps[names.index("Fetch the branch's recent commits")]
        self.assertIn("--filter=tree:0", fetch["run"])
        self.assertTrue(fetch["continue-on-error"])
        mint = steps[names.index("Mint the cmux-bot read token")]
        comment = steps[names.index("Comment on the pull requests in the failing range")]
        self.assertLess(names.index("Mint the cmux-bot read token"), names.index("Comment on the pull requests in the failing range"))
        self.assertEqual(comment["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertEqual(comment["env"]["GH_READ_TOKEN"], "${{ steps.read-token.outputs.token }}")
        minted = [("push-attribution", mint)]
        # fast-tier stays secret-free (test_fast_tier_reads_next_bucket_publicly_and_never_saves).
        for job_id in ("swift-test", "generated-files", "release-compile"):
            job_steps = jobs[job_id]["steps"]
            ids = [step.get("id") for step in job_steps]
            token = job_steps[ids.index("reuse-token")]
            lookup = job_steps[ids.index("reuse")]
            self.assertLess(ids.index("reuse-token"), ids.index("reuse"))
            self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", token["if"])
            self.assertEqual(token["with"]["permission-actions"], "read")
            self.assertEqual(lookup["env"]["GH_TOKEN"], "${{ steps.reuse-token.outputs.token || github.token }}")
            minted.append((job_id, token))
        for job_id, step in minted:
            with self.subTest(job=job_id):
                self.assertIn("github.event_name != 'pull_request'", step["if"])
                self.assertTrue(step["continue-on-error"])
                self.assertEqual(step["with"]["app-id"], "${{ vars.CMUX_BOT_APP_ID }}")
                self.assertFalse(any(key.startswith("permission-") and value == "write"
                                     for key, value in step["with"].items()))

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
        # Superseded pushes skip before queueing; a started compile has its own
        # run group so a newer push cannot evict it.
        self.assertNotIn("|| github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')",
                         jobs["release-compile"]["if"])
        self.assertIn("needs.push-head-preflight.outputs.current == 'true'", jobs["release-compile"]["if"])

    def test_bot_attempt_three_drops_stale_owned_pool_placement(self):
        """The rescue's attempts (2 on) must use the Blacksmith fallback instead of a stale mini label."""
        text = WORKFLOW.read_text(encoding="utf-8")
        stale = "(github.run_attempt <= 3 || !contains(fromJSON('[\"github-actions[bot]\",\"cmux-bot[bot]\"]'), github.triggering_actor)) && needs.macos-placement.outputs."
        self.assertNotIn(stale, text)
        jobs = yaml.safe_load(text)["jobs"]
        # Discover consumers from the placement outputs, independently of the guard,
        # so adding a routed job needs no count update and deleting a guard still fails.
        placement = re.compile(r"needs\.macos-placement\.outputs\.(?:runner|session_runner|gui_runner)\b")
        routes = {name: job for name, job in jobs.items()
                  if placement.search(str(job.get("runs-on", "")))}
        self.assertIn("release-compile", routes)
        for name, job in routes.items():
            expression = job["runs-on"]
            if "CMUX_NEXT_RUNNER" in job.get("env", {}):
                with self.subTest(job=name, field="CMUX_NEXT_RUNNER"):
                    self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], label_copy(expression))
            for event in ("pull_request", "workflow_dispatch"):
                for attempt, actor, expected in (
                    (1, "github-actions[bot]", "stale-owned-label"),
                    (2, "github-actions[bot]", "blacksmith-6vcpu-macos-26"),
                    (3, "github-actions[bot]", "blacksmith-6vcpu-macos-26"),
                    (3, "someone", "stale-owned-label"),
                ):
                    context = {
                        "github.repository_owner": "manaflow-ai",
                        "github.repository": "manaflow-ai/cmux",
                        "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                        "github.event_name": event,
                        "github.run_attempt": attempt,
                        "github.triggering_actor": actor,
                        "needs.macos-placement.outputs.runner": "stale-owned-label",
                        "needs.macos-placement.outputs.session_runner": "stale-owned-label",
                        "needs.macos-placement.outputs.gui_runner": "stale-owned-label",
                        "needs.macos-placement.outputs.placed_attempt": "1",
                        "needs.macos-placement.outputs.retry_runner": "blacksmith-6vcpu-macos-26",
                        "needs.macos-placement.outputs.retry_jobs": " fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files ",
                        "vars.CI_PR_POOL_OWNED": "1",
                    }
                    # GUI/session routes need a fresh reading on human reruns too. Discover the role
                    # consumer from the expression, so this also covers a newly added job.
                    routed_role = "needs.macos-placement.outputs.gui_runner" in expression
                    # A complete PR cascade can precede the unchanged push/display route.
                    # Count owned allocation only in alternatives active for this event.
                    from test_ci_runs_on_fallback import EXPRESSION, flat_alternatives, conjuncts, separate_pr_cascade
                    # The route helper still recognizes the old literal labels. Normalize the
                    # declared pool references only for this structural classification; evaluate
                    # the actual expression below so the assertion remains pool-backed.
                    normalized = re.sub(
                        r"fromJSON\(vars\.RUNNER_POOLS\)\.macos_26_large",
                        "'blacksmith-12vcpu-macos-26'",
                        expression,
                    )
                    normalized = re.sub(
                        r"fromJSON\(vars\.RUNNER_POOLS\)\.macos_26",
                        "'blacksmith-6vcpu-macos-26'",
                        normalized,
                    )
                    alternatives = flat_alternatives(EXPRESSION.findall(normalized)[0])
                    allocated_side = any(
                        "outputs.owned_jobs" in part
                        and (event == "pull_request" or "github.event_name == 'pull_request'" not in conjuncts(part))
                        for part in alternatives
                    )
                    if event == "pull_request" and any(separate_pr_cascade(part) for part in alternatives):
                        # This fixture has a current retry allocation only on attempt 1.
                        wanted = "blacksmith-6vcpu-macos-26" if attempt == 1 else "glaeda-side-std-xcode-26.6"
                    else:
                        wanted = "blacksmith-6vcpu-macos-26" if allocated_side or attempt > 1 and routed_role else expected
                    with self.subTest(job=name, event=event, attempt=attempt, actor=actor):
                        if attempt > 1:
                            # placed_attempt is 1: a carried reading, whoever re-ran. Its owned labels are as
                            # stale as its slots, so no re-run waits on one (cmux#38484's run 42728317341;
                            # test_ci_next_macos_cascade.CarriedPlacement covers every combination).
                            label = evaluate(expression, context)
                            self.assertNotEqual(label, "stale-owned-label")
                            self.assertFalse(str(label).startswith("glaeda-"), label)
                        else:
                            self.assertEqual(evaluate(expression, context), wanted)
        # 7242a82b4a8 (#24763): the rescue re-admits a queued run, a free owned Mac first, then Blacksmith.
        self.assertIn("The rescue re-admits a queued run after the\n# five-minute queue alarm: placement first uses a free owned GUI/session Mac,\n# then the workflow's Blacksmith macOS route.", text)
        self.assertIn("Bot attempt 2 and later drop the stale placement output\n# and re-admits it through the same fast-checks/owned-Mac/Blacksmith order", text)

    def test_owned_pool_guard_accepts_an_added_guarded_job(self):
        """A new correctly routed job cannot break the rescue guard's coverage check."""
        import textwrap
        from unittest.mock import patch

        text = WORKFLOW.read_text(encoding="utf-8")
        job = yaml.safe_load(text)["jobs"]["swift-test"]
        added = text + "\n" + textwrap.indent(yaml.safe_dump({"added-guarded-job": job}, width=100000), "  ")
        self.assertIn("added-guarded-job", yaml.safe_load(added)["jobs"])
        with tempfile.TemporaryDirectory() as directory:
            workflow = Path(directory) / "cmux-next.yml"
            workflow.write_text(added, encoding="utf-8")
            with patch.object(sys.modules[__name__], "WORKFLOW", workflow):
                self.test_bot_attempt_three_drops_stale_owned_pool_placement()

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
        # A push run keeps a group of its own and is never cancelled by the workflow group.
        concurrency = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["concurrency"]
        push = {"github.event_name": "push", "github.ref": "refs/heads/feat-cmux-next", "github.run_id": "7"}
        self.assertEqual(evaluate(concurrency["group"], push), "cmux-next-7")
        self.assertFalse(evaluate(concurrency["cancel-in-progress"], push))

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

    def test_dispatch_runs_every_tier_on_any_ref(self):
        # A dispatch on a pull request's own branch runs the macOS tiers, as one on
        # feat-cmux-next or a next-batch/* branch does (#22303): no job, and no step,
        # skips a dispatch for its ref.
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for name, job in jobs.items():
            conditions = [str(job.get("if", ""))] + [str(step.get("if", "")) for step in job.get("steps", [])]
            with self.subTest(job=name):
                for condition in conditions:
                    self.assertNotIn("startsWith(github.ref, 'refs/heads/next-batch/')", condition)
        # Nightly promotion and the dogfood artifact stay feat-cmux-next pushes only.
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", jobs["request-nightly-next"]["if"])
        self.assertNotIn("next-batch", jobs["request-nightly-next"]["if"])
        self.assertNotIn("next-batch", jobs["request-cmux-next-dev-publish"]["if"])

    def test_branch_lookup_uses_git_https_basic_auth_and_a_timeout(self):
        for filename, job_id, step_id in (("cmux-next.yml", "push-head-preflight", "head"),
                                          ("cmux-tui-artifacts.yml", "tree-preflight", "inspect")):
            document = yaml.safe_load((WORKFLOW.parent / filename).read_text())
            script = preflight_step(document, job_id, step_id)["run"]
            with self.subTest(workflow=filename):
                self.assertIn("Authorization: Basic", script)
                self.assertIn("x-access-token:%s", script)
                self.assertIn("timeout 15 git", script)
                self.assertNotIn("Authorization: Bearer", script)


class SwiftCanaryFleetCoverage(unittest.TestCase):
    """The fleet's app check vouches only for targets the app executable links."""

    def test_targets_outside_the_app_go_to_the_mac_canary(self):
        graph = json.loads((ROOT / "Packages/macOS/CmuxNext/ci-target-graph.json").read_text(encoding="utf-8"))
        targets = graph["targets"]
        seen, stack = set(), ["CmuxNextApp"]
        while stack:
            name = stack.pop()
            if name in seen or name not in targets:
                continue
            seen.add(name)
            stack.extend(targets[name]["targets"])
        self.assertIn("CmuxNextApp", seen)
        # Libraries under Tests/ (Tests/Support/CmuxNextTestExitTrace, #23658)
        # and source-only test support targets are not production. Only the
        # base autofix rewrites the graph, so a pull request that deletes a
        # target still sees it there: a target whose sources are gone is gone.
        outside = {
            n for n, v in targets.items()
            if v["kind"] in {"regular", "executable"} and n not in seen
            and not (v["path"] or "").startswith("Packages/macOS/CmuxNext/Tests/")
            and not n.endswith("TestSupport")
            and (ROOT / (v["path"] or "")).is_dir()
        }
        step = next(s for s in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["swift-canary-fleet"]["steps"]
                    if s.get("id") == "check")
        listed = set(re.search(r"^\s*([A-Za-z|]+)\)\n\s*echo \"::notice", step["run"], re.M).group(1).split("|"))
        self.assertEqual(listed, outside, "update the swift-canary-fleet target list to the production targets CmuxNextApp does not reach")
        self.assertIn("compile-check --ref \"$REF\" --app", step["run"])


def kill_group(pid: int) -> None:
    # The group may be gone, or (macOS) hold only a zombie leader, which raises EPERM.
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def run_step(script: str, env: dict, timeout: float) -> subprocess.CompletedProcess:
    """Run a workflow step's shell in its own process group and kill the whole group on timeout.

    subprocess.run's timeout kills only bash: its cmux_tui_tree_key.py child lived on, and once
    the temporary directory with the fake git was removed its git calls reached the real
    checkout and lazy-fetched placeholder objects for 19+ minutes (cosmic-gray, 2026-10-20).
    """
    with subprocess.Popen(["bash", "-c", script], env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_group(process.pid)
            process.communicate()
            raise
        finally:
            # Background children a finished step left behind go too.
            kill_group(process.pid)
    return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)


class StepRunnerLeavesNoChild(unittest.TestCase):
    def test_a_timed_out_step_takes_its_children_with_it(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child"
            with self.assertRaises(subprocess.TimeoutExpired):
                run_step(f"sleep 60 & echo $! > {pid_file}; wait", dict(os.environ), timeout=1)
            child = int(pid_file.read_text())
        # A killed child is gone once it has exited (a zombie its new parent has not reaped yet counts).
        if process_gone.died(child, within=2):
            return
        os.kill(child, signal.SIGKILL)
        self.fail(f"step child {child} outlived the timed-out step")


def preflight_step(document, job_id, step_id):
    """The preflight step by id: steps after it (tree-preflight's owner observation, #30221) do not move it."""
    steps = [step for step in document["jobs"][job_id]["steps"] if step.get("id") == step_id]
    assert len(steps) == 1, f"{job_id} has {len(steps)} steps with id {step_id!r}"
    return steps[0]


class PushPreflightBehavior(unittest.TestCase):
    """Execute the workflow shell with bounded fake network and git responses."""

    def run_preflight(self, *, artifacts=False, event="push", ref="refs/heads/feat-cmux-next",
                      remote="a" * 40, remote_tree_key="0" * 39 + "2", published=False,
                      missing="", malformed=False, fork=False):
        filename = "cmux-tui-artifacts.yml" if artifacts else "cmux-next.yml"
        workflow = yaml.safe_load((WORKFLOW.parent / filename).read_text())
        job_id, step_id = ("tree-preflight", "inspect") if artifacts else ("push-head-preflight", "head")
        script = preflight_step(workflow, job_id, step_id)["run"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = root / "git"
            git.write_text('''#!/bin/bash
case "$*" in
  *ls-remote*) [[ -z "$REMOTE_SHA" ]] && exit 1; printf '%s\\trefs/heads/feat-cmux-next\\n' "$REMOTE_SHA" ;;
  *fetch*) touch "$REMOTE_FETCH_MARKER" ;;
  *diff*) exit 0 ;;
  *cat-file*) exit 0 ;;
  *ls-tree*) printf '100644 blob %040d\\tCargo.toml\\0' 1 ;;
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
            result = run_step(script, env, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_current_push_keeps_native_compile(self):
        self.assertEqual(self.run_preflight()["current"], "true")

    def test_superseded_push_is_not_current(self):
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


# The Blacksmith outage failover reads a variable but only ever picks another Blacksmith size.
OVERFLOW_FAILOVER = re.compile(
    r"vars\.CI_CLOUD_OVERFLOW_SAVED && (?:'blacksmith-\d+vcpu-ubuntu-2404'|fromJSON\(vars\.RUNNER_POOLS\)\.[A-Za-z0-9_]+) \|\| "
)


def can_run_on_owned_runner(job: dict) -> bool:
    """A runs-on that reads a repository variable, or portable placement's mini, can resolve to a mini (glaeda-*)."""
    runs_on = unwrap_fork_pool_reads(str(job.get("runs-on", "")))
    runs_on = OVERFLOW_FAILOVER.sub("", runs_on)
    runs_on = re.sub(r"fromJSON\(vars\.RUNNER_POOLS\)\.[A-Za-z0-9_]+", "", runs_on)
    return "vars." in runs_on or "outputs.mini_runner" in runs_on


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
        # The nightly-next requests read LINUX_RUNNER (Blacksmith Linux, never GitHub-hosted).
        self.assertEqual(sorted(checked), ["checks", "cmux-scheme-compile", "daemon-test", "fast-tier", "generated-files", "path_route",
                                           "release-compile", "request-nightly-next",
                                           "swift-canary", "swift-test", "web-bundles"])



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
        # The landing compile's placement probes the tree itself (dev-landing-place).
        landing = fetching.pop("dev-landing-compile")
        self.assertIn("needs.dev-landing-place.outputs.tree_state == 'ready'", " ".join(landing["if"].split()))
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
        # This job executes checked-out PR scripts, so it can inspect but never
        # mutate Actions or repository contents.
        self.assertEqual(route["permissions"].get("actions"), "read")
        self.assertEqual(route["permissions"].get("contents"), "read")

    def test_path_route_probes_fail_open_inside_the_job_limit(self):
        # A slow probe (2026-10-27: one fetch per active artifacts run during a
        # lane-branch push burst) once held path routing past its job limit; the
        # cancelled job skipped every Release compile and swift test. Each probe
        # stops at its own limit and fails open, so routing still succeeds.
        route = self.jobs()["path_route"]
        probes = [step for step in route["steps"] if "pin-cmux-tui.sh probe" in step.get("run", "")]
        self.assertEqual(len(probes), 2)
        for step in probes:
            with self.subTest(step=step["name"]):
                self.assertIs(step.get("continue-on-error"), True)
                self.assertLessEqual(int(step["timeout-minutes"]), 2)
                budget = int(step["env"]["CMUX_TUI_TREE_RUN_FETCH_SECONDS"])
                self.assertLess(budget, 60 * int(step["timeout-minutes"]))
        self.assertGreater(int(route["timeout-minutes"]), sum(int(step["timeout-minutes"]) for step in probes) + 2)
        report = next(step for step in route["steps"] if step.get("name") == "Report a probe that failed open")
        self.assertIn("steps.tree.outcome == 'failure'", report["if"])
        self.assertIn("steps.tree-final.outcome == 'failure'", report["if"])
        # The routed tiers come from the step before the probes, never from a probe.
        for name, value in route["outputs"].items():
            if not name.startswith("tree_"):
                with self.subTest(output=name):
                    self.assertTrue(value.strip().startswith("${{ steps.route.outputs."), value)

    def test_untrusted_routing_jobs_have_no_write_token_or_dispatch_switch(self):
        jobs = self.jobs()
        route = jobs["path_route"]
        self.assertEqual(route["permissions"].get("actions"), "read")
        self.assertEqual(route["permissions"].get("contents"), "read")
        probes = [step for step in route["steps"] if "pin-cmux-tui.sh probe" in step.get("run", "")]
        self.assertTrue(probes)
        self.assertTrue(all(step.get("env", {}).get("CMUX_TUI_TREE_DISPATCH") == "" for step in probes))

        wait = jobs["dev-daily-tree-wait"]
        self.assertEqual(wait["permissions"].get("actions"), "read")
        self.assertEqual(wait["permissions"].get("contents"), "read")
        dispatches = [
            step.get("env", {}).get("CMUX_TUI_TREE_DISPATCH")
            for step in wait["steps"]
            if "wait-dev-daily-tree.sh" in step.get("run", "")
        ]
        self.assertEqual(dispatches, [""])

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

    def test_a_feat_cmux_next_push_runs_the_checks(self):
        # gh-merge-green excuses a PR's red lint only when the base's latest push run
        # prints every finding too (scripts/ci/base_red_excuse.py); a push that skips
        # the job leaves nothing to compare, and every base red refuses every PR.
        condition = " ".join(self.jobs()["checks"]["if"].split())
        self.assertNotIn("!(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')", condition)

    def test_an_unavailable_pr_tree_is_skipped_with_named_reason(self):
        gate = self.jobs()["same-tree-cmux-tui"]
        self.assertLessEqual(int(gate["timeout-minutes"]), 5)
        condition = " ".join(gate["if"].split())
        self.assertIn("github.event_name != 'pull_request'", condition)
        self.assertIn("inputs.same_tree_origin != 'pull_request'", condition)
        self.assertIn("needs.path_route.outputs.tree_state == 'failed'", condition)
        self.assertIn("inputs.same_tree_state == 'failed'", condition)
        self.assertFalse([step for step in gate["steps"] if "pin-cmux-tui.sh" in step.get("run", "")])
        route = self.jobs()["path_route"]
        summary = next(step for step in route["steps"] if step.get("name") == "Summarize the same-tree cmux-tui")
        self.assertIn("same-tree cmux-tui skipped", summary["run"])
        self.assertIn("pin ref", summary["run"])
        marker = next(step for step in route["steps"] if step.get("id") == "marker")
        self.assertIn("github.event_name != 'pull_request'", marker["if"])
        with tempfile.NamedTemporaryFile(mode="r+") as receipt:
            result = subprocess.run(["bash", "-c", summary["run"]], text=True, capture_output=True,
                                    env={**os.environ, "EVENT_NAME": "pull_request", "STATE": "failed",
                                         "KEY": "a" * 40, "REASON": "HTTP 422: tree unavailable",
                                         "GITHUB_STEP_SUMMARY": receipt.name}, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("::notice title=same-tree cmux-tui skipped::", result.stdout)
            self.assertNotIn("::error", result.stdout)
            self.assertIn(": skipped", receipt.read())

    def test_a_ready_tree_is_reported_green_and_a_failed_one_red(self):
        # A job that only ran red stayed a base red while skipped; a ready tree gives the tip a verdict.
        gate = self.jobs()["same-tree-cmux-tui"]
        condition = gate["if"]
        self.assertIn("needs.path_route.outputs.tree_state == 'ready'", condition)
        self.assertIn("inputs.same_tree_state == 'ready'", condition)
        self.assertNotIn("deferred", condition)
        steps = {step["name"]: step for step in gate["steps"]}
        ready = steps["Report the ready same-tree cmux-tui"]
        failed = steps["Report the unavailable same-tree cmux-tui"]
        self.assertIn("== 'ready'", ready["if"])
        self.assertNotIn("exit 1", ready["run"])
        self.assertIn("== 'failed'", failed["if"])
        self.assertIn("exit 1", failed["run"])

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
    """Cargo and script entries run on Blacksmith; Swift entries run on Mac.
    One registry is split by fast-tier.py --kind."""

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    @staticmethod
    def tier_run(job: dict) -> str:
        return next(step["run"] for step in job["steps"] if "scripts/cmux-next/fast-tier.py" in step.get("run", ""))

    def test_the_cargo_job_can_build_cmux_tui_core(self):
        """cmux-tui-core's ghostty-vt-sys builds libghostty-vt from the ghostty-next gitlink with
        zig (#20290: `the ghostty-next submodule is empty`), as cmux-tui.yml's jobs do."""
        job = self.jobs()["fast-tier-cargo"]
        self.assertEqual(job["env"]["GHOSTTY_ZIG_SOURCE"], "ghostty-next")
        self.assertEqual(job["env"]["CMUX_GHOSTTY_SRC"], "")
        runs = [step.get("run", "") for step in job["steps"]]
        tier = next(i for i, run in enumerate(runs) if "scripts/cmux-next/fast-tier.py" in run)
        init = next(i for i, run in enumerate(runs) if "scripts/ci/init-submodule.sh ghostty-next" in run)
        zig = next(i for i, run in enumerate(runs) if "scripts/install-zig-ci.sh" in run)
        rust = next(i for i, step in enumerate(job["steps"]) if step.get("uses") == "./.github/actions/setup-cmux-tui-rust")
        self.assertLess(max(init, zig, rust), tier)
        # The Zig packages come from the deadlined, retried fetch, not from build.rs's
        # single unretried download (a pkg/highway ReadFailed failed the job).
        fetch = next(i for i, step in enumerate(job["steps"]) if step.get("uses") == "./.github/actions/ghostty-zig-packages")
        self.assertLess(zig, fetch)
        self.assertLess(fetch, tier)

    def test_the_cargo_job_runs_on_linux_and_gates_like_the_mac_job(self):
        jobs = self.jobs()
        mac, cargo = jobs["fast-tier"], jobs["fast-tier-cargo"]
        runs_on = cargo["runs-on"]
        self.assertTrue(runs_on.startswith("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "), runs_on)
        self.assertIn("github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404'", runs_on)
        # Its Blacksmith size and failover are the ones .github/runners.json linux_sizes measured.
        self.assertTrue(runs_on.endswith(
            "vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || "
            "fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        ), runs_on)
        route_without_pools = re.sub(
            r"fromJSON\(vars\.RUNNER_POOLS\)\.[A-Za-z0-9_]+", "", OVERFLOW_FAILOVER.sub("", runs_on)
        )
        self.assertNotIn("vars.", route_without_pools, "an ephemeral Linux VM, never a reused mini")
        # The same gate, except that the Mac half also follows the route (MacFastTierFollowsTheRoute).
        self.assertEqual(cargo["if"], mac["if"].replace(
            " && needs.path_route.outputs.macos != 'false' && needs.path_route.outputs.fast_tier != 'false'", ""))
        self.assertNotEqual(cargo["if"], mac["if"])
        self.assertEqual(cargo["needs"], ["push-head-preflight"])
        self.assertEqual(cargo["concurrency"]["group"], mac["concurrency"]["group"].replace("-fast-tier'", "-fast-tier-cargo'"))
        self.assertNotEqual(cargo["name"], mac["name"])
        self.assertEqual(cargo["name"], "cmux-next fast tier (cargo)")

    def test_the_jobs_split_the_registry_by_kind(self):
        """Every kind runs in exactly one job, so no entry is dropped or run twice."""
        jobs = self.jobs()
        kinds = {}
        for name in ("fast-tier", "fast-tier-cargo"):
            argv = self.tier_run(jobs[name]).split()
            kinds[name] = {argv[i + 1] for i, arg in enumerate(argv) if arg == "--kind"}
        self.assertEqual(kinds, {"fast-tier": {"swift"}, "fast-tier-cargo": {"cargo", "script"}})
        registry = json.loads((ROOT / "scripts/cmux-next/fast-tier.json").read_text(encoding="utf-8"))
        self.assertLessEqual({entry["kind"] for entry in registry["entries"]}, kinds["fast-tier"] | kinds["fast-tier-cargo"])

    def test_the_mac_job_builds_no_rust(self):
        job = self.jobs()["fast-tier"]
        text = yaml.safe_dump(job)
        for needle in ("setup-cmux-tui-rust", "install-zig-ci.sh", "init-submodule.sh", "cmux-tui/target",
                       "GHOSTTY_ZIG_SOURCE", "CMUX_FAST_CARGO"):
            with self.subTest(needle=needle):
                self.assertNotIn(needle, text)

    def test_the_cargo_cache_is_written_only_by_feat_cmux_next_pushes(self):
        steps = self.jobs()["fast-tier-cargo"]["steps"]
        cache = next(step for step in steps if str(step.get("uses", "")).startswith("Swatinem/rust-cache@"))
        self.assertEqual(cache["with"]["workspaces"], "cmux-tui -> target")
        self.assertEqual(cache["with"]["save-if"], "${{ github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' }}")
        self.assertLess(steps.index(cache), next(i for i, s in enumerate(steps) if "fast-tier.py" in s.get("run", "")))

    def test_the_cargo_job_uses_bounded_ghostty_initialization(self):
        job = self.jobs()["fast-tier-cargo"]
        init = next(step for step in job["steps"]
                    if "scripts/ci/init-submodule.sh ghostty-next" in step.get("run", ""))
        self.assertIn("scripts/ci/init-submodule.sh ghostty-next", init["run"])

    def test_fast_tier_emits_a_json_timing_receipt(self):
        names = set()
        for name in ("fast-tier", "fast-tier-cargo"):
            with self.subTest(job=name):
                job = self.jobs()[name]
                self.assertIn("--receipt", self.tier_run(job))
                upload = next(step for step in job["steps"] if "actions/upload-artifact@" in str(step.get("uses", "")))
                # Always, unless the job reused a pass (JobsReuseAPassOnTheSameInputs) and wrote none, or
                # the fast tier only reports its build-fleet client's verdict (GatewayRunsOnlyTheFleetClient).
                guard = f"(always()) && {REUSE_GUARD}"
                if name == "fast-tier-cargo":
                    guard += " && steps.planner-reuse.outputs.hit != 'true'"
                if name == "fast-tier":
                    guard = f"env.CMUX_FAST_TIER_FLEET != 'report' && ({guard})"
                self.assertEqual(upload.get("if"), f"${{{{ {guard} }}}}")
                self.assertIn("github.run_attempt", upload["with"]["name"])
                names.add(upload["with"]["name"])
        self.assertEqual(len(names), 2, "each job uploads its own receipt artifact")

    def test_fast_tier_keeps_build_caches_and_drops_stale_submodules(self):
        job = self.jobs()["fast-tier"]
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
        reset = [
            step for step in job["steps"]
            if "reset-stale-submodules.sh" in step.get("run", "")
        ]
        self.assertEqual(len(reset), 1)
        self.assertEqual(reset[0]["run"].strip(), "scripts/ci/reset-stale-submodules.sh",
                         "the Swift entries need no submodule: drop them all")


class MacFastTierFollowsTheRoute(unittest.TestCase):
    """A pull request whose diff the router sends to no Mac tier (only web or CI files: ci-web,
    actionlint and the CI tests cover it) starts no Mac fast tier: no fast-tier entry builds or
    reads those files, so its result is the base's. The cargo half keeps running (Linux, and
    next-autoland waits for it on any Rust file), the feat-cmux-next push still runs every
    tier, and a route with no answer (a failed path_route) runs the fast tier as before."""

    def setUp(self):
        sys.path.insert(0, str(ROOT / "tests"))
        from test_seed_derived_data import evaluate
        self.evaluate = evaluate
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def runs(self, job: str, event: str, macos: str | None, fast_tier: str | None = None) -> bool:
        expression = self.jobs[job]["if"].replace("!cancelled()", "true")
        pull = event == "pull_request"
        context = {
            "github": {
                "event_name": event, "repository_owner": "manaflow-ai", "repository": "manaflow-ai/cmux",
                "base_ref": "feat-cmux-next" if pull else "", "run_attempt": 1,
                "ref": "refs/pull/1/merge" if pull else "refs/heads/feat-cmux-next",
                "event": {"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}}} if pull else {},
            },
            "inputs": {"same_tree_sha": "", "dev_daily": False},
            "vars": {"CI_PR_POOL_OWNED": "1"},
            "needs": {
                "push-head-preflight": {"outputs": {"current": "true"}},
                "path_route": {"outputs": {key: value for key, value in (("macos", macos), ("fast_tier", fast_tier))
                                           if value is not None}},
            },
        }
        return bool(self.evaluate(expression, context))

    def route_macos(self, changed: list[str]) -> str:
        import cmux_next_route
        return cmux_next_route.outputs(cmux_next_route.route(ROOT, "pull_request", changed, set()))["macos"]

    def test_a_web_or_ci_only_pull_request_starts_no_mac_fast_tier(self):
        for changed in (["web/app/page.tsx"], [".github/workflows/web-validation.yml"], ["docs/ci/merge-main.md"]):
            with self.subTest(changed=changed):
                macos = self.route_macos(changed)
                self.assertEqual(macos, "false")
                self.assertFalse(self.runs("fast-tier", "pull_request", macos))
                self.assertFalse(self.runs("macos-placement", "pull_request", macos))
                self.assertTrue(self.runs("fast-tier-cargo", "pull_request", macos))

    def test_a_pull_request_with_a_mac_tier_runs_the_mac_fast_tier(self):
        macos = self.route_macos(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WindowRootView.swift"])
        self.assertEqual(macos, "true")
        self.assertTrue(self.runs("fast-tier", "pull_request", macos))
        self.assertTrue(self.runs("macos-placement", "pull_request", macos))

    def test_no_route_answer_and_the_base_push_still_run_it(self):
        self.assertTrue(self.runs("fast-tier", "pull_request", None))
        for macos in ("true", None):
            with self.subTest(macos=macos):
                self.assertTrue(self.runs("fast-tier", "push", macos))
                self.assertTrue(self.runs("fast-tier-cargo", "push", macos))

    def test_the_mac_fast_tier_waits_for_the_route(self):
        self.assertIn("path_route", self.jobs["fast-tier"]["needs"])

    def route_outputs(self, changed: list[str]) -> dict[str, str]:
        import cmux_next_route
        return cmux_next_route.outputs(cmux_next_route.route(ROOT, "pull_request", changed, set()))

    def test_a_daemon_only_pull_request_starts_no_mac_fast_tier(self):
        """A cmux-tui Rust change keeps its daemon tier, but the Mac fast tier builds only the CmuxNext
        package and runs its Swift suites, none of which read cmux-tui: its result is the base's. In the
        12:43Z queue on 2026-10-30, 13 such pull requests each waited on a Mac fast tier."""
        for changed in (["cmux-tui/crates/acpmux/src/cli/help_examples/session.rs"],
                        ["Native/OptChat/optchat-chief/tests/harness.rs"]):
            with self.subTest(changed=changed):
                out = self.route_outputs(changed)
                self.assertEqual(out["macos"], "true")
                self.assertEqual(out["fast_tier"], "false")
                self.assertFalse(self.runs("fast-tier", "pull_request", out["macos"], out["fast_tier"]))
                self.assertTrue(self.runs("fast-tier-cargo", "pull_request", out["macos"], out["fast_tier"]))
        placement = self.jobs["macos-placement"]["steps"]
        cascade = next(step["env"]["CASCADE_RUNS"] for step in placement if "CASCADE_RUNS" in step.get("env", {}))
        self.assertIn("needs.path_route.outputs.fast_tier != 'false'", cascade)

    def test_a_package_change_runs_the_mac_fast_tier(self):
        for changed in (["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WindowRootView.swift"],
                        ["scripts/cmux-next/fast-tier.json"],
                        ["Packages/Shared/CmuxTheme/Sources/CmuxTheme/Theme.swift"]):
            with self.subTest(changed=changed):
                out = self.route_outputs(changed)
                self.assertEqual(out["fast_tier"], "true")
                self.assertTrue(self.runs("fast-tier", "pull_request", out["macos"], out["fast_tier"]))
        self.assertTrue(self.runs("fast-tier", "push", "true", "false"), "a feat-cmux-next push runs it whatever the route")


SEED_WORKFLOW = WORKFLOW.parent / "cmux-next-fast-tier-seed.yml"
CACHE_KEY_SCRIPT = ROOT / "scripts/cmux-next/fast-tier-cache-key.sh"
SEED_DUE_SCRIPT = ROOT / "scripts/cmux-next/fast-tier-seed-due.py"
FAST_TIER_SCRIPT = ROOT / "scripts/cmux-next/fast-tier.py"
FAST_CACHE_DIRS = {"swift": "Packages/macOS/CmuxNext/.build", "home": "Packages/Shared/CmuxHomeRender/.build"}
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


JOB_PASS_DIR = ".ci-job-pass"
REUSE_GUARD = "steps.reuse.outputs.hit != 'true'"
SAME_REPOSITORY = "(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)"
# Steps that build, test or regenerate: none may run before a job's reuse lookup.
HEAVY_MARKERS = ("swift build", "swift-test-with-hang-sampler", "fast-tier.py", "check-release-compile.sh",
                 "cargo test", "build-web-bundles.sh", "check-action-surfaces.sh", "judge-action-exports.sh", "defaults_guard.py",
                 "regenerate-", "ensure-cef.sh", "build-cef-shim.sh")


class JobsReuseAPassOnTheSameInputs(unittest.TestCase):
    """With vars.CI_NEXT_JOB_REUSE, a job whose inputs (scripts/ci/job_input_fingerprint.py) match a
    recorded pass skips its build and tests and names that run; a pass records itself. The store is an
    Actions artifact named after the key (scripts/ci/job_reuse.py), readable from every pull request and
    the base; the lookup takes only a pass from this repository's own runs."""

    JOBS = ("fast-tier", "fast-tier-cargo", "swift-test", "generated-files", "release-compile")
    MAC_JOBS = ("swift-test", "generated-files", "release-compile")

    def document(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def steps(self, job: str) -> list[dict]:
        return self.document()["jobs"][job]["steps"]

    def test_the_lookup_is_behind_the_toggle_and_never_on_a_fork(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                key = steps[index_of(steps, lambda s: s.get("id") == "reuse-key")]
                self.assertIn("vars.CI_NEXT_JOB_REUSE == '1'", key["if"])
                self.assertIn(SAME_REPOSITORY, key["if"])
                self.assertIn(f"scripts/ci/job_input_fingerprint.py {job}", key["run"])
                self.assertIs(key.get("continue-on-error"), True)
                lookup = steps[index_of(steps, lambda s: s.get("id") == "reuse")]
                self.assertIn("scripts/ci/job_reuse.py lookup", lookup["run"])
                self.assertIn("steps.reuse-key.outputs.key", json.dumps(lookup))
                self.assertIn("steps.reuse-key.outputs.key != ''", lookup["if"])
                # A feat-cmux-next push or dispatch lists with a cmux-bot read token (minted only off
                # pull_request), falling back to the workflow token.
                self.assertIn(lookup.get("env", {}).get("GH_TOKEN"),
                              ("${{ github.token }}", "${{ steps.reuse-token.outputs.token || github.token }}"))
                self.assertIs(lookup.get("continue-on-error"), True)
                # No actions/cache store: a cache entry of one pull request is unreadable from the others.
                self.assertFalse([s for s in steps if JOB_PASS_DIR in json.dumps(s)])

    def test_cargo_planner_reuse_requires_the_promoted_mode_and_trusted_push(self):
        steps = self.steps("fast-tier-cargo")
        evidence = steps[index_of(steps, lambda s: s.get("id") == "planner-evidence")]
        self.assertIn("vars.CI_REBUILD_MIRROR) == 'enforce'", evidence["if"])
        self.assertIn("verify-evidence", evidence["run"])
        self.assertIn("--evidence-json", evidence["run"])
        self.assertEqual(evidence["env"]["CI_REBUILD_MIRROR_EVIDENCE"], "${{ vars.CI_REBUILD_MIRROR_EVIDENCE }}")
        self.assertIs(evidence.get("continue-on-error"), True)
        lookup = steps[index_of(steps, lambda s: s.get("id") == "planner-reuse")]
        self.assertIn("vars.CI_REBUILD_MIRROR) == 'enforce'", lookup["if"])
        self.assertIn("steps.planner-evidence.outputs.eligible == 'true'", lookup["if"])
        self.assertIn("steps.reuse-key.outputs.candidate_key != ''", lookup["if"])
        self.assertIn("--trusted-branch feat-cmux-next", lookup["run"])
        self.assertIn("--trusted-event push", lookup["run"])
        self.assertIn("--trusted-workflow .github/workflows/cmux-next.yml", lookup["run"])
        self.assertIn("\n", lookup["run"], "the planner command must stay a YAML block scalar for shell continuations")
        argv = shlex.split(lookup["run"])
        self.assertEqual(argv[argv.index("--trusted-workflow") + 1], ".github/workflows/cmux-next.yml")
        self.assertIn("steps.reuse-key.outputs.candidate_key", lookup["env"]["KEY"])
        self.assertEqual(lookup.get("env", {}).get("GH_TOKEN"), "${{ github.token }}")
        self.assertIs(lookup.get("continue-on-error"), True)
        trusted = steps[index_of(steps, lambda s: s.get("name") == "Reuse the trusted planner pass")]
        self.assertIn("planner-reuse.outputs.hit", trusted["if"])
        for step in steps:
            text = json.dumps(step)
            if any(marker in text for marker in ("fast-tier.py", "rust-cache", "ghostty-zig-packages")):
                self.assertIn("steps.planner-reuse.outputs.hit != 'true'", text, step.get("name"))

    def test_the_lookup_reads_the_artifact_list(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                permissions = self.document()["jobs"][job].get("permissions", {})
                expected_actions = "write" if job == "release-compile" else "read"
                self.assertEqual(permissions.get("actions"), expected_actions)
                self.assertEqual(permissions.get("contents"), "read")

    def test_a_mini_release_compile_records_only_when_the_cef_checks_ran(self):
        # ensure-cef.sh --optional skips the CEF shim compile and the Chromium Objective-C contract check
        # when the engine is unreadable (an R2 miss, a Dependabot run without secrets); a pass from such a
        # run must not stand for one on the same key that would have run them.
        steps = self.steps("release-compile")
        cef = steps[index_of(steps, lambda s: s.get("id") == "cef")]
        self.assertIn("startsWith(env.CMUX_NEXT_RUNNER, 'glaeda-')", cef["if"])
        for name in ("Record this pass for the same inputs", "Save the pass"):
            with self.subTest(step=name):
                step = steps[index_of(steps, lambda s, n=name: s.get("name") == n)]
                self.assertIn("(!startsWith(env.CMUX_NEXT_RUNNER, 'glaeda-') || steps.cef.outputs.dir != '')", step["if"])

    def test_a_hit_skips_every_step_that_builds_or_tests(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                start = index_of(steps, lambda s: s.get("name") == "Reuse that pass")
                records = [i for i, s in enumerate(steps) if s.get("name") in (
                    "Record this pass for the same inputs", "Save the pass")]
                for index, step in enumerate(steps[start + 1:], start + 1):
                    if index in records:
                        continue
                    if step.get("name") == "Request nightly-next promotion after this gate":
                        continue
                    with self.subTest(step=step.get("name") or step.get("uses")):
                        self.assertIn(REUSE_GUARD, str(step.get("if", "")))
                # Nothing that builds, tests or reads a build cache comes before the lookup.
                for step in steps[:start]:
                    text = json.dumps(step)
                    for marker in HEAVY_MARKERS + ("rust-cache",):
                        self.assertNotIn(marker, text, step.get("name"))

    def test_the_reused_run_is_named(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                reuse = steps[index_of(steps, lambda s: s.get("name") == "Reuse that pass")]
                self.assertEqual(reuse["if"], "${{ steps.reuse.outputs.hit == 'true' }}")
                self.assertIn("::notice", reuse["run"])
                self.assertIn("GITHUB_STEP_SUMMARY", reuse["run"])
                self.assertIn("steps.reuse.outputs.run_url", json.dumps(reuse))

    def test_only_a_trusted_pass_that_ran_records_itself_under_the_same_key(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                record = steps[index_of(steps, lambda s: s.get("name") == "Record this pass for the same inputs")]
                save = steps[index_of(steps, lambda s: s.get("name") == "Save the pass")]
                self.assertEqual(steps.index(save), steps.index(record) + 1)
                self.assertEqual(steps.index(save), len(steps) - 1, "the save is the job's last step")
                for step in (record, save):
                    self.assertIn("success()", step["if"])
                    self.assertIn("steps.reuse-key.outputs.key != ''", step["if"])
                    self.assertIn(REUSE_GUARD, step["if"])
                    # A fork never writes a pass, whatever the key step did.
                    self.assertIn(SAME_REPOSITORY, step["if"])
                    # An uncached run records too: it is the freshest pass there is.
                    self.assertNotIn("no_reuse", step["if"])
                self.assertIn("actions/runs/$GITHUB_RUN_ID", record["run"])
                self.assertTrue(save["uses"].startswith("actions/upload-artifact@"), save["uses"])
                self.assertEqual(save["with"]["name"], "${{ steps.reuse-key.outputs.key }}")
                self.assertIs(save.get("continue-on-error"), True)

    def test_an_uncached_dispatch_never_reuses(self):
        document = self.document()
        inputs = document.get("on", document.get(True))["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["no_reuse"].get("type"), "boolean")
        self.assertIn("no_reuse", document["run-name"])
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                lookup = steps[index_of(steps, lambda s: s.get("id") == "reuse")]
                self.assertIn("inputs.no_reuse != true", lookup["if"])

    MAC_VALUES = {
        "swift-test": ('"swift_targets=$SWIFT_TARGETS"', '"swift_filter=$SWIFT_FILTER"', '"web_bundles=$(',
                       '"mini=', '"xcode_app=$CMUX_CI_XCODE_APP"', '"generated_base=$('),
        "generated-files": ('"web_bundles=$(', '"mini=', '"xcode_app=$CMUX_CI_XCODE_APP"', "--base-rev HEAD^1"),
        "release-compile": ('"mini=', '"xcode_app=$CMUX_CI_XCODE_APP"'),
    }

    def test_a_mac_job_key_names_its_toolchain_and_env_flags(self):
        for job, values in self.MAC_VALUES.items():
            steps = self.steps(job)
            at = index_of(steps, lambda s: s.get("id") == "reuse-key")
            self.assertLess(index_of(steps, lambda s: s.get("name") == "Select Xcode"), at)
            for value in values + ('"xcode=$(xcodebuild -version', '"macos=$(sw_vers -productVersion)"',
                                   '"macos_build=$(sw_vers -buildVersion)"', '"arch=$(uname -m)"', '"pool=',
                                   '"image='):
                with self.subTest(job=job, value=value):
                    self.assertIn(value, steps[at]["run"])

    def test_every_script_a_mac_job_runs_is_a_keyed_input(self):
        """The input list (job_input_fingerprint.py --list-inputs) covers each repository script the job runs."""
        for job in self.MAC_JOBS:
            with self.subTest(job=job):
                result = subprocess.run(
                    [sys.executable, "-I", str(ROOT / "scripts/ci/job_input_fingerprint.py"), job, "--root", str(ROOT),
                     "--base-rev", "HEAD", "--list-inputs"], capture_output=True, text=True, timeout=120)
                inputs = {line.split(" ", 1)[1] for line in result.stderr.splitlines() if line.startswith("input ")}
                self.assertTrue(inputs, result.stderr[-2000:])
                text = "\n".join(str(step.get("run", "")) + str(step.get("uses", "")) for step in self.steps(job))
                paths = set(re.findall(r"(?:\.\./)*((?:scripts|tests|\.github/actions)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)", text))
                self.assertTrue(paths)
                for path in sorted(paths):
                    self.assertTrue(any(path == i or path.startswith(i + "/") for i in inputs), f"{job} runs {path}")

    # The toolchain each job's key names, and the step that puts it on the runner first.
    TOOLCHAIN = {
        "fast-tier": {'"xcode=$(xcodebuild -version': "Select Xcode", '"macos=$(sw_vers -productVersion)"': None,
                      '"macos_build=$(sw_vers -buildVersion)"': None, '"arch=$(uname -m)"': None,
                      '"pool=': None, '"image=': None},
        "fast-tier-cargo": {'"rustc=$(rustc -Vv': "Set up pinned cmux-tui Rust",
                            '"cargo=$(cargo -V': "Set up pinned cmux-tui Rust",
                            '"zig=$(': "Install zig", '"runner=': None,
                            '"clang=$(clang --version': "Install Linux build dependencies", '"image=': None},
    }

    def test_the_key_names_the_toolchain_that_runs_the_job(self):
        for job, values in self.TOOLCHAIN.items():
            steps = self.steps(job)
            at = index_of(steps, lambda s: s.get("id") == "reuse-key")
            for value, setup in values.items():
                with self.subTest(job=job, value=value):
                    self.assertIn(f"--extra {value}", steps[at]["run"])
                    if setup:
                        self.assertLess(index_of(steps, lambda s: s.get("name") == setup), at,
                                        f"{setup} runs before the key names its toolchain")
        # The Mac pool: owned minis, Blacksmith and hosted Macs differ in Reduce Motion/Transparency.
        pool = next(line for line in self.steps("fast-tier")[index_of(
            self.steps("fast-tier"), lambda s: s.get("id") == "reuse-key")]["run"].splitlines() if '"pool=' in line)
        for needle in ("'-glaeda'", "'blacksmith-'", "'github-hosted'"):
            self.assertIn(needle, pool)


class GuiJobsStartFromTheSeed(unittest.TestCase):
    """swift-test, daemon-test and generated-files off the owned Macs start from the fast-tier seed.

    Leo, 2026-11-05: "If a hot swapped build works (copied versions of a certain version) / Then you
    can skip compile skip build you only need the tests". A daemon-only change leaves every Swift
    input as the base had it, so with the base's seeded build and its input times nothing compiles.
    """

    JOBS = ("swift-test", "daemon-test", "generated-files")

    def steps(self, job: str) -> list[dict]:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][job]["steps"]

    def test_restores_the_seed_publicly_and_replays_its_times_before_the_build(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = self.steps(job)
                names = [s.get("name") for s in steps]
                key = index_of(steps, lambda s: "scripts/cmux-next/fast-tier-cache-key.sh" in s.get("run", ""))
                restore = index_of(steps, lambda s: is_cache_restore(s) and s["with"]["path"] == FAST_CACHE_DIRS["swift"])
                replay = index_of(steps, lambda s: "e2e_warm_derived_data.py replay" in s.get("run", ""))
                build = index_of(steps, lambda s: s.get("name") == "Build package and tests")
                link = index_of(steps, lambda s: "owned_spm_scratch.py link" in s.get("run", ""))
                self.assertLess(link, key, names)
                self.assertLess(key, restore, names)
                self.assertLess(restore, replay, names)
                self.assertLess(replay, build, names)
                key_id, restore_id = steps[key]["id"], steps[restore]["id"]
                self.assertIn("!contains(runner.name, '-glaeda')", steps[key]["if"], "owned Macs keep their own build")
                if REUSE_GUARD in steps[link].get("if", ""):
                    self.assertIn(REUSE_GUARD, steps[key]["if"])
                cache = steps[restore]
                self.assertEqual(cache["with"]["backend"], "r2")
                self.assertEqual(cache.get("env", {}).get("CI_CACHE_R2_PUBLIC_URL"), NEXT_PUBLIC_URL)
                self.assertEqual(cache["with"]["key"], "${{ steps.%s.outputs.swift-key }}" % key_id)
                self.assertEqual(cache["with"]["restore-keys"], "${{ steps.%s.outputs.swift-prefix }}" % key_id)
                self.assertIn("steps.%s.outputs.cache-matched-key != ''" % restore_id, steps[replay]["if"])
                self.assertIn(FAST_CACHE_MANIFEST, steps[replay]["run"])
                run = steps[replay]["run"]
                self.assertLess(run.index("owned_spm_scratch.py drop-bundles " + FAST_CACHE_DIRS["swift"]),
                                run.index("e2e_warm_derived_data.py replay"), "a seed's stale catalogs go first")
                for step in (steps[key], cache, steps[replay]):
                    self.assertIs(step.get("continue-on-error"), True, "a miss builds as before")
                self.assertEqual([s.get("name") for s in steps if is_cache_save(s)], [], "a job never saves a build")


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
        # Only the pass record (JobsReuseAPassOnTheSameInputs) is saved, never a build.
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
        for name in ("home",):
            with self.subTest(name=name):
                step = by_path[FAST_CACHE_DIRS[name]]
                self.assertEqual(step["with"]["key"], "${{ steps.%s.outputs.%s-prefix }}${{ steps.%s.outputs.commit }}" % (key_id, name, seed["id"]))
                self.assertFalse(step["with"].get("restore-keys"), "an exact key, never a prefix")
                self.assertIn("steps.%s.outputs.commit != ''" % seed["id"], step.get("if", ""))
        # The commit is the matched key minus the swift prefix.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            env = dict(os.environ, GITHUB_OUTPUT=str(out), MATCHED="cmux-next-fast-v3-swift-macOS-a-b-c-0123abc", PREFIX="cmux-next-fast-v3-swift-macOS-a-b-c-")
            subprocess.run(["bash", "-c", seed["run"]], env=env, check=True)
            self.assertEqual(out.read_text().strip(), "commit=0123abc")

    def test_fast_tier_replays_the_seed_input_times_before_building(self):
        steps = self.fast_tier()["steps"]
        names = [s.get("name") for s in steps]
        last_restore = max(i for i, s in enumerate(steps) if is_cache_restore(s))
        replay = index_of(steps, lambda s: "e2e_warm_derived_data.py replay" in s.get("run", ""))
        tier = index_of(steps, lambda s: "scripts/cmux-next/fast-tier.py" in s.get("run", ""))
        self.assertLess(last_restore, replay, names)
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
        # One lane per pool, not one for the workflow: seed run 39396578253 sat queued on
        # blacksmith-12vcpu-macos-26 from 08:53 to past 20:50 on 2026-10-20 while holding the
        # workflow's group, so the next 299 pushes' seeds were cancelled pending and none landed.
        self.assertNotIn("concurrency", seed, "a stalled pool never holds another pool's seed")
        lane = seed["jobs"]["seed"]["concurrency"]
        self.assertIn("matrix.pool", lane["group"])
        self.assertFalse(lane.get("cancel-in-progress", True),
                         "a running seed finishes; a newer push only replaces the pending one")

    def test_seed_saves_what_the_fast_tier_restores(self):
        build = self.seed()["jobs"]["seed"]
        steps = build["steps"]
        saves = [s for s in steps if is_cache_save(s)]
        key_id = steps[index_of(steps, lambda s: "scripts/cmux-next/fast-tier-cache-key.sh" in s.get("run", ""))]["id"]
        self.assertEqual([s["with"]["path"] for s in saves],
                         [FAST_CACHE_DIRS["home"], FAST_CACHE_DIRS["swift"]],
                         "the swift archive, whose pointer readers follow, goes last")
        for name, save in zip(("home", "swift"), saves):
            with self.subTest(name=name):
                self.assertEqual(save["with"]["key"], "${{ steps.%s.outputs.%s-key }}" % (key_id, name))
                self.assertEqual(save["with"]["backend"], "r2")
                self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", save.get("if", ""))
                self.assertIn("github.event_name == 'push'", save.get("if", ""))
        record = index_of(steps, lambda s: "e2e_warm_derived_data.py record" in s.get("run", ""))
        tier = index_of(steps, lambda s: "scripts/cmux-next/fast-tier.py" in s.get("run", ""))
        self.assertLess(record, tier)
        self.assertIn("--kind swift", steps[tier]["run"], "the seed builds what the Mac fast tier builds")
        self.assertNotIn("--kind script", steps[tier]["run"], "portable entries run with cargo")
        self.assertNotIn("setup-cmux-tui-rust", yaml.safe_dump(build), "nothing restores a Mac cargo seed")
        self.assertLess(tier, steps.index(saves[0]))
        self.assertIn(FAST_CACHE_MANIFEST, steps[record]["run"])
        # The seed runs once per pool the fast tier restores a seed on, from the due job's matrix:
        # the key holds the workspace path, so each pool needs its own seed. Only Blacksmith
        # restores one: no GitHub-hosted pool (Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE
        # THE SLOWEST THINGS"), and the owned minis keep their builds on their own SSD.
        self.assertEqual(build["strategy"]["matrix"], {"include": "${{ fromJSON(needs.due.outputs.pools) }}"})
        self.assertIs(build["strategy"].get("fail-fast"), False)
        self.assertIn("matrix.runner", str(build["runs-on"]))
        self.assertIn("needs.due.outputs.pools != '[]'", build.get("if", ""))
        guard = steps[index_of(steps, lambda s: "matrix.workspace" in json.dumps(s))]
        self.assertLess(steps.index(guard), steps.index(saves[0]), "a seed whose workspace is not its pool's never saves")
        pools = {p["pool"]: p for p in json.loads(self.seed()["jobs"]["due"]["env"]["SEED_POOLS"])}
        # 6 vCPU, not 12: the 12 vCPU label runs about five jobs at once and the
        # cascade fills it first, so a seed pinned there sat queued (run 39351410275).
        self.assertEqual(pools["blacksmith"]["runner"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(set(pools), {"blacksmith"}, "no GitHub-hosted seed pool")
        self.assertEqual(pools["blacksmith"]["workspace"], "/Users/runner/_work/cmux/cmux")

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
                            "PATH": "/usr/bin:/bin", "GITHUB_WORKSPACE": "/Users/runner/_work/cmux/cmux",
                            "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64", "GITHUB_SHA": "abc123"})
                env.update(overrides)
                out = subprocess.run(["bash", str(CACHE_KEY_SCRIPT), str(repo)], env=env, check=True, capture_output=True, text=True).stdout
                return dict(line.split("=", 1) for line in out.splitlines())

            base = keys()
            self.assertEqual(sorted(base), sorted(f"{d}-{kind}" for d in FAST_CACHE_DIRS for kind in ("prefix", "key")))
            stems = set()
            for name in FAST_CACHE_DIRS:
                self.assertTrue(base[f"{name}-prefix"].startswith(f"cmux-next-fast-v3-{name}-macOS-ARM64-"), base)
                self.assertEqual(base[f"{name}-key"], base[f"{name}-prefix"] + "abc123")
                self.assertRegex(base[f"{name}-key"], r"^[A-Za-z0-9._-]+$", "r2-cache.sh's key alphabet")
                stems.add(base[f"{name}-prefix"].removeprefix(f"cmux-next-fast-v3-{name}-"))
            self.assertEqual(len(stems), 1, "one stem: the home key follows the swift seed's commit")
            prefix = base["swift-prefix"]
            self.assertEqual(keys(GITHUB_SHA="def456")["swift-prefix"], prefix, "a newer commit is a fallback, not a miss")
            for change in ({"CMUX_FAST_CACHE_XCODE_VERSION": "Xcode 26.7"}, {"GITHUB_WORKSPACE": "/Users/runner/work/cmux/cmux"}):
                with self.subTest(change=change):
                    self.assertNotEqual(keys(**change)["swift-prefix"], prefix)
            (repo / "Packages/macOS/A/Source.swift").write_text("let a = 2\n")
            commit("source", "Packages/macOS/A/Source.swift")
            self.assertEqual(keys()["swift-prefix"], prefix, "a source edit reuses the seed; replay rebuilds what changed")
            before = keys()["swift-prefix"]
            (repo / "Packages/macOS/A/Package.resolved").write_text("{\"pins\": []}\n")
            commit("resolved", "Packages/macOS/A/Package.resolved")
            self.assertNotEqual(keys()["swift-prefix"], before)
            # The cargo entries left the Mac: Rust, Cargo and ghostty-next no longer key its seed,
            # and the script needs no rustc (the Mac job sets up no Rust).
            before = keys()["swift-prefix"]
            (repo / "cmux-tui/Cargo.lock").write_text("version = 5\n")
            commit("lock", "cmux-tui/Cargo.lock")
            git("update-index", "--cacheinfo", "160000,2222222222222222222222222222222222222222,ghostty-next")
            commit("ghostty")
            self.assertEqual(keys()["swift-prefix"], before)

    def test_seed_is_due_only_when_the_newest_seed_is_old(self):
        def due(objects: list[dict], now: str = "2026-10-19T22:00:00Z") -> str:
            with tempfile.TemporaryDirectory() as tmp:
                listing = Path(tmp) / "objects.json"
                listing.write_text(json.dumps(objects))
                return subprocess.run([sys.executable, "-I", str(SEED_DUE_SCRIPT), "--minutes", "30", "--now", now,
                                       "--listing", str(listing)], check=True, capture_output=True, text=True).stdout.strip()

        swift = lambda modified, name="cmux-next-fast-v3-swift-macOS-ARM64-a-b-c-abc": {
            "key": f"v1/macOS-ARM64/objects/{name}.tar.zst", "last_modified": modified}
        self.assertEqual(due([]), "due=true")
        self.assertEqual(due([swift("2026-10-19T21:45:00.000Z")]), "due=false")
        self.assertEqual(due([swift("2026-10-19T21:20:00.000Z")]), "due=true")
        self.assertEqual(due([swift("2026-10-19T21:20:00.000Z"), swift("2026-10-19T21:50:00.000Z")]), "due=false")
        self.assertEqual(due([swift("2026-10-19T21:59:00.000Z", name="cmux-next-fast-v3-cargo-macOS-ARM64-a-b-c-abc")]), "due=true",
                         "the swift archive is written last; only it marks a finished seed")
        self.assertEqual(due([{"key": "v1/macOS-ARM64/latest/cmux-next-fast-v3-swift-", "last_modified": "2026-10-19T21:59:00.000Z"}]),
                         "due=true", "pointers are not archives")

    def test_each_pool_is_due_on_its_own_seeds(self):
        """A fresh seed at one workspace path does not make another path's pool fresh: their keys differ."""
        import hashlib
        place = lambda path: hashlib.sha256(path.encode()).hexdigest()[:12]
        hosted, blacksmith = "/Users/runner/work/cmux/cmux", "/Users/runner/_work/cmux/cmux"
        # Two paths, as two pools would have them; "other" is a fixture, not a live pool.
        pools = [{"pool": "other", "runner": "blacksmith-12vcpu-macos-26", "workspace": hosted},
                 {"pool": "blacksmith", "runner": "blacksmith-6vcpu-macos-26", "workspace": blacksmith}]
        swift = lambda modified, path: {
            "key": f"v1/macOS-ARM64/objects/cmux-next-fast-v3-swift-macOS-ARM64-0123456789abcdef-fedcba9876543210-{place(path)}-abc.tar.zst",
            "last_modified": modified}

        def due(objects: list[dict]) -> list[str]:
            with tempfile.TemporaryDirectory() as tmp:
                listing = Path(tmp) / "objects.json"
                listing.write_text(json.dumps(objects))
                out = subprocess.run([sys.executable, "-I", str(SEED_DUE_SCRIPT), "--minutes", "30", "--now", "2026-10-19T22:00:00Z",
                                      "--listing", str(listing), "--pools", json.dumps(pools)],
                                     check=True, capture_output=True, text=True).stdout.strip()
            self.assertTrue(out.startswith("pools="), out)
            chosen = json.loads(out.removeprefix("pools="))
            for entry in chosen:
                self.assertIn(entry, pools, "a due pool keeps its runner and workspace")
            return [entry["pool"] for entry in chosen]

        self.assertEqual(due([]), ["other", "blacksmith"])
        self.assertEqual(due([swift("2026-10-19T21:50:00Z", blacksmith)]), ["other"])
        self.assertEqual(due([swift("2026-10-19T21:50:00Z", hosted)]), ["blacksmith"])
        self.assertEqual(due([swift("2026-10-19T21:50:00Z", hosted), swift("2026-10-19T21:40:00Z", blacksmith)]), [])
        self.assertEqual(due([swift("2026-10-19T21:00:00Z", hosted), swift("2026-10-19T21:40:00Z", blacksmith)]), ["other"])

    def test_a_manifest_change_seeds_its_own_prefix_at_once(self):
        """A seed is due when no seed carries this push's package inputs, however fresh another prefix's seed is.

        cmux#38170 (run 42439414440): the 02:28Z merge 9b6dd559c76 changed the package manifests (inputs
        2d3c58426a71203a). A seed under the earlier inputs was under 30 minutes old, so no seed was due. At 03:01
        daemon tests restored nothing on Blacksmith 6 vCPU ("miss_or_unavailable"), built for 29 minutes cold,
        and ran out its 60. The manifests changed 9 times in the 7 hours before."""
        import hashlib
        workspace = "/Users/runner/_work/cmux/cmux"
        place = hashlib.sha256(workspace.encode()).hexdigest()[:12]
        pools = [{"pool": "blacksmith", "runner": "blacksmith-6vcpu-macos-26", "workspace": workspace}]
        old, new = "b5d64095f7cfdaef", "2d3c58426a71203a"
        swift = lambda modified, inputs: {
            "key": f"v1/macOS-ARM64/objects/cmux-next-fast-v3-swift-macOS-ARM64-18730ed2ae28a2c9-{inputs}-{place}-abc.tar.zst",
            "last_modified": modified}

        def due(objects: list[dict], *extra: str) -> list[str]:
            with tempfile.TemporaryDirectory() as tmp:
                listing = Path(tmp) / "objects.json"
                listing.write_text(json.dumps(objects))
                out = subprocess.run([sys.executable, "-I", str(SEED_DUE_SCRIPT), "--minutes", "30", "--now", "2026-11-08T02:30:00Z",
                                      "--listing", str(listing), "--pools", json.dumps(pools), *extra],
                                     check=True, capture_output=True, text=True).stdout.strip()
            return [entry["pool"] for entry in json.loads(out.removeprefix("pools="))]

        fresh_old = [swift("2026-11-08T02:20:00Z", old)]
        self.assertEqual(due(fresh_old, "--inputs", new), ["blacksmith"], "no seed has this push's inputs: seed now")
        self.assertEqual(due(fresh_old, "--inputs", old), [], "this push's inputs have a fresh seed")
        self.assertEqual(due([swift("2026-11-08T01:50:00Z", new)], "--inputs", new), ["blacksmith"], "an old seed is due as before")
        # No inputs read (the due job could not hash them): any prefix's seed counts, as before.
        self.assertEqual(due(fresh_old), [])
        self.assertEqual(due(fresh_old, "--inputs", ""), [])

    def test_the_due_job_hashes_the_inputs_the_seed_keys_hold(self):
        """The due job reads this push's package inputs with fast-tier-cache-key.sh, the seed's own key script."""
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-fast-tier-seed.yml").read_text(encoding="utf-8"))
        due = workflow["jobs"]["due"]
        checkout = due["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("scripts/cmux-next/fast-tier-cache-key.sh", checkout)
        run = next(step for step in due["steps"] if step.get("id") == "due")["run"]
        self.assertIn("scripts/cmux-next/fast-tier-cache-key.sh", run)
        self.assertIn("--inputs", run)
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "Packages/macOS/A").mkdir(parents=True)
            (repo / "Packages/macOS/A/Package.swift").write_text("// swift-tools-version: 6.2\n")
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            env = git_fixture_env.fixture_env({"PATH": os.environ["PATH"], "HOME": tmp, "GITHUB_OUTPUT": str(repo / "out"), "GITHUB_SHA": "abc"})
            script = re.search(r"(?s)inputs=\"\$\((.*?)\)\"", run).group(1)
            got = subprocess.run(["/bin/bash", "-c", script.replace("scripts/cmux-next/", str(ROOT / "scripts/cmux-next") + "/")],
                                 cwd=repo, env=env, check=True, capture_output=True, text=True).stdout.strip()
            keys = dict(line.split("=", 1) for line in subprocess.run(
                [str(ROOT / "scripts/cmux-next/fast-tier-cache-key.sh")], cwd=repo, check=True, capture_output=True, text=True,
                env={**env, "CMUX_FAST_CACHE_XCODE_VERSION": "Xcode 26.6"}).stdout.split())
            self.assertRegex(got, r"^[0-9a-f]{16}$")
            self.assertIn(f"-{got}-", keys["swift-prefix"], "the same inputs field the seed's key holds")

    def test_receipt_names_the_seed_a_prefix_restore_picked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bin").mkdir()
            (root / "bin/pass.sh").write_text("exit 0\n")
            (root / "registry.json").write_text(json.dumps({"entries": [
                {"name": "pass", "kind": "script", "path": "bin/pass.sh", "args": [], "owner": "op-test", "bead": "cx-test"}]}))
            (root / "quarantine.json").write_text('{"entries": []}')
            receipt = root / "receipt.json"
            env = dict(os.environ, CMUX_FAST_SWIFT_CACHE_KEY="cmux-next-fast-v3-swift-x-new", CMUX_FAST_SWIFT_CACHE_HIT="false",
                       CMUX_FAST_CACHE_MATCHED_KEY="cmux-next-fast-v3-swift-x-old")
            subprocess.run([sys.executable, "-I", str(FAST_TIER_SCRIPT), "--root", str(root), "--registry", str(root / "registry.json"),
                            "--quarantine", str(root / "quarantine.json"), "--receipt", str(receipt)],
                           env=env, check=True, capture_output=True, text=True)
            cache = json.loads(receipt.read_text())["cache"]
            self.assertEqual(cache["matched_key"], "cmux-next-fast-v3-swift-x-old")
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
    "needs.macos-placement.outputs.fast_runner != '' && "
    "github.run_attempt == 1 && needs.macos-placement.outputs.fast_runner || "
)
# While fast-tier-fleet ran, the fast tier only reports its verdict from Linux (GatewayRunsOnlyTheFleetClient);
# a step still queued (verdict `queued`) hands it back, and it runs on Blacksmith macOS.
FAST_TIER_REPORT_CLAUSE = (
    "contains(fromJSON('[\"success\",\"failure\",\"cancelled\"]'), needs.fast-tier-fleet.result) "
    "&& needs.fast-tier-fleet.outputs.verdict != 'queued' "
    "&& !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
    "contains(fromJSON('[\"success\",\"failure\",\"cancelled\"]'), needs.fast-tier-fleet.result) "
    "&& needs.fast-tier-fleet.outputs.verdict != 'queued' "
    "&& vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_4 || "
    "contains(fromJSON('[\"success\",\"failure\",\"cancelled\"]'), needs.fast-tier-fleet.result) "
    "&& needs.fast-tier-fleet.outputs.verdict != 'queued' "
    "&& fromJSON(vars.RUNNER_POOLS).linux_2 || "
    "needs.fast-tier-fleet.outputs.verdict == 'queued' && needs.fast-tier-handback-placement.outputs.placed_attempt == format('{0}', github.run_attempt) && needs.fast-tier-handback-placement.outputs.runner || "
    "needs.fast-tier-fleet.outputs.verdict == 'queued' && fromJSON(vars.RUNNER_POOLS).macos_26 || "
)


class FastTierRunner(unittest.TestCase):
    def test_the_fast_lane_label_comes_after_the_fork_clause(self):
        """The placement's fast_runner (vars.CI_FAST_LANE_RUNNER while one of its runners is idle)
        gives the fast tier its own owned runner label. A fork pull request must take its hosted
        label before it is read, and with it empty the route is the one every cascaded job has."""
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]
        runs_on = job["runs-on"]
        self.assertIn(FAST_LANE_CLAUSE, runs_on)
        self.assertLess(runs_on.index(FAST_TIER_FORK_CLAUSE), runs_on.index("outputs.fast_runner"))
        self.assertTrue(runs_on.index(FAST_TIER_FORK_CLAUSE) + len(FAST_TIER_FORK_CLAUSE) == runs_on.index(FAST_LANE_CLAUSE))
        self.assertIn(FAST_LANE_CLAUSE + FAST_TIER_REPORT_CLAUSE, runs_on)
        self.assertLess(runs_on.index("outputs.retry_runner"), runs_on.index("vars.CI_SIDE_LANE_RUNNER"))
        self.assertLess(runs_on.index("outputs.deferred_runner"), runs_on.index("vars.CI_SIDE_LANE_RUNNER"))
        self.assertIn("outputs.owned_jobs", runs_on)
        self.assertIn("outputs.retry_runner", runs_on)
        # No env value mirrors runs-on with the old route.
        for value in (job.get("env") or {}).values():
            self.assertNotIn("CI_SIDE_LANE_RUNNER", str(value))


class ReservedLaneLabels(unittest.TestCase):
    """No runs-on waits on one small reserved pool with no way off it (rulebook: "No job waits on one
    reserved machine"; 2026-10-25, 15 runs' fast tiers queued an hour behind the two runners left on
    glaeda-fast-light-xcode-26.6). A reserved lane's label reaches a runs-on only through a placement
    output that names it while one of its runners is idle; reading the variable there is refused."""

    # Variables naming one reserved owned lane, and the runs-on still reading one directly, with why.
    RESERVED = ("CI_FAST_LANE_RUNNER", "CI_SESSION_LANE_RUNNER")
    DIRECT = {
        ("generated-files", "CI_SESSION_LANE_RUNNER"): (
            "unset since it was added; setting it needs the same idle gate the fast tier has "
            "(side_lane_placement.fast_route()) first"
        ),
    }

    def test_no_runs_on_reads_a_reserved_lane_variable(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        found = {(name, variable) for name, job in jobs.items() for variable in self.RESERVED
                 if f"vars.{variable}" in str(job.get("runs-on") or "")}
        self.assertEqual(found, set(self.DIRECT))

    def test_the_fast_tier_takes_its_label_only_while_the_placement_saw_it_idle(self):
        runs_on = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["fast-tier"]["runs-on"]

        def context(fast="", side="glaeda-side-std-xcode-26.6", attempt=1, actor="someone", **outputs):
            values = {
                "github.repository_owner": "manaflow-ai",
                "github.repository": "manaflow-ai/cmux",
                "github.event_name": "pull_request",
                "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                "github.run_attempt": attempt,
                "github.triggering_actor": actor,
                "vars.CI_PR_POOL_OWNED": "1",
                "vars.CI_FAST_LANE_RUNNER": "glaeda-fast-light-xcode-26.6",
                "vars.CI_SIDE_LANE_RUNNER": side,
                "needs.macos-placement.outputs.fast_runner": fast,
                "needs.macos-placement.outputs.runner": side,
                "needs.macos-placement.outputs.placed_attempt": str(attempt),
                "needs.macos-placement.outputs.retry_jobs": " fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files ",
            }
            values.update({f"needs.macos-placement.outputs.{key}": value for key, value in outputs.items()})
            return values

        fast = "glaeda-fast-light-xcode-26.6"
        self.assertEqual(evaluate(runs_on, context(fast)), fast)
        # An available cascade slot wins; exhaustion preserves the base side queue.
        self.assertEqual(evaluate(runs_on, context(blacksmith_6_jobs=" fast-tier ")), "blacksmith-6vcpu-macos-26")
        # An old placement's hosted reading is never read (Leo, 2026-10-27: no GitHub-hosted Mac).
        self.assertEqual(evaluate(runs_on, context(hosted_jobs=" fast-tier ", hosted_runner="macos-26")),
                         "glaeda-side-std-xcode-26.6")
        self.assertEqual(evaluate(runs_on, context()), "glaeda-side-std-xcode-26.6")
        # Only a current allocation can select the generic side route.
        self.assertEqual(evaluate(runs_on, context(owned_jobs=" fast-tier ")), "glaeda-side-std-xcode-26.6")
        self.assertEqual(evaluate(runs_on, context(owned_jobs=" fast-tier ", placed_attempt="0")),
                         "glaeda-side-std-xcode-26.6")
        # The rescue's overflow attempt never goes back to the fast label.
        self.assertEqual(evaluate(runs_on, context(fast, attempt=2, actor="github-actions[bot]",
                                                   retry_runner="blacksmith-6vcpu-macos-26")),
                         "blacksmith-6vcpu-macos-26")
        # A person's re-run cannot reuse the owned label; it falls to Blacksmith. macos-placement never runs on
        # it (its `if`), so its reading is attempt 1's, carried, or none.
        for placed in ("1", ""):
            self.assertEqual(evaluate(runs_on, context(fast, attempt=2, placed_attempt=placed)),
                             "blacksmith-6vcpu-macos-26")
        for actor in ("someone", "github-actions[bot]", "cmux-bot[bot]"):
            with self.subTest(actor=actor):
                self.assertEqual(evaluate(runs_on, context(fast, attempt=4, actor=actor)),
                                 "blacksmith-6vcpu-macos-26")


class GeneratedFilesRunner(unittest.TestCase):
    def test_session_lane_is_only_used_after_trust_checks_and_outside_prs(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["generated-files"]
        context = {
            "github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
            "github.event_name": "push", "github.run_attempt": 1,
            "needs.macos-placement.outputs.placed_attempt": "1", "vars.CI_PR_POOL_OWNED": "1",
            "vars.CI_SESSION_LANE_RUNNER": "glaeda-session-light-xcode-26.6",
            "needs.macos-placement.outputs.session_lane_runner": "glaeda-session-light-xcode-26.6",
            "needs.macos-placement.outputs.gui_runner": "glaeda-gui-std-xcode-26.6",
            "vars.CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6",
        }
        self.assertEqual(evaluate(job["runs-on"], context), "glaeda-session-light-xcode-26.6")
        context["needs.macos-placement.outputs.free_session_runner"] = "glaeda-session-std-xcode-26.6"
        self.assertEqual(evaluate(job["runs-on"], context), "glaeda-session-std-xcode-26.6")
        context["github.event_name"] = "pull_request"
        context["github.event.pull_request.head.repo.full_name"] = "manaflow-ai/cmux"
        self.assertEqual(evaluate(job["runs-on"], context), "glaeda-side-std-xcode-26.6")
        context["github.event.pull_request.head.repo.full_name"] = "outside/cmux"
        self.assertEqual(evaluate(job["runs-on"], context), "blacksmith-6vcpu-macos-26")
        context["github.repository_owner"] = "outside"
        self.assertEqual(evaluate(job["runs-on"], context), "macos-26")
        self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], job["runs-on"])


class _UnsetIsEmpty(dict):
    def __missing__(self, key):
        return ""


class _RunnerPools(dict):
    """Small GitHub-expression stand-in for `fromJSON(vars.RUNNER_POOLS).pool`."""

    def __getattr__(self, name):
        return self[name]


DEFAULT_RUNNER_POOLS = json.dumps({
    "linux_2": "blacksmith-2vcpu-ubuntu-2404",
    "linux_4": "blacksmith-4vcpu-ubuntu-2404",
    "linux_8": "blacksmith-8vcpu-ubuntu-2404",
    "linux_16": "blacksmith-16vcpu-ubuntu-2404",
    "linux_32": "blacksmith-32vcpu-ubuntu-2404",
    "macos_15": "blacksmith-6vcpu-macos-15",
    "macos_26": "blacksmith-6vcpu-macos-26",
    "macos_26_large": "blacksmith-12vcpu-macos-26",
})


def evaluate(expression: str, context: dict):
    """Evaluate a job `if:` or `runs-on:` against literal context values.

    Covers the subset of GitHub's expression syntax this workflow uses: `&&`, `||`, `!`,
    `==`, `!=`, `<=`, contains(), startsWith(), fromJSON(), format() and `!cancelled()` (true: the
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
    eval_context = {"vars.RUNNER_POOLS": DEFAULT_RUNNER_POOLS, **context}
    names = {
        "_ctx": _UnsetIsEmpty(eval_context),
        "always": lambda: True,
        "contains": lambda haystack, needle: needle in haystack,
        "startsWith": lambda value, prefix: str(value).startswith(prefix),
        "fromJSON": lambda value: (
            _RunnerPools(json.loads(value)) if isinstance(json.loads(value), dict) else json.loads(value)
        ),
        "format": lambda template, *values: re.sub(r"\{(\d+)\}", lambda match: str(values[int(match.group(1))]), template),
    }
    return eval(text, {"__builtins__": {}}, names)  # noqa: S307 - this repository's workflow, not input


class PortablePlacementBootstrapAdmission(unittest.TestCase):
    def test_stale_fleet_label_cannot_block_the_router_before_placement_runs(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())["jobs"]
        bootstrap = jobs["portable-placement"]["runs-on"]
        for fleet in ("", "cmux-fleet-linux-x64", "stale-fleet-label"):
            for attempt, overflow, expected in ((1, "", "ubuntu-24.04"),
                                                (1, "1", "ubuntu-24.04"),
                                                (2, "", "blacksmith-8vcpu-ubuntu-2404"),
                                                (2, "1", "blacksmith-16vcpu-ubuntu-2404")):
                with self.subTest(fleet=fleet, attempt=attempt, overflow=overflow):
                    context = {"github.repository_owner": "manaflow-ai",
                               "github.event_name": "pull_request",
                               "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                               "github.repository": "manaflow-ai/cmux",
                               "github.run_attempt": attempt,
                               "vars.LINUX_RUNNER": fleet,
                               "vars.CI_CLOUD_OVERFLOW_SAVED": overflow}
                    self.assertEqual(evaluate(bootstrap, context), expected)


class ReleaseCompileOnCmuxNextSwiftPullRequests(unittest.TestCase):
    """A PR that changes any CmuxNext package Swift file runs the Release compile; a web-only PR does not.

    #20543 left ordinary PRs only the Debug fast tier. A Release-only swift-frontend crash
    (EarlyPerfInliner on a main-actor generic class's isolated deinit, cx-ebm.59.5,
    PageCallDeadline.Once) then reached feat-cmux-next through a PR that changed CmuxNext
    Swift sources: Debug `swift build` cannot see an optimizer crash. Fixed in #20876.
    """

    def job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile"]

    def context(self, changed: list[str], *, event: str = "pull_request", labels: tuple[str, ...] = (),
                head_repo: str = "manaflow-ai/cmux") -> dict:
        from cmux_next_route import outputs, route

        routed = outputs(route(ROOT, event, changed, set(labels)))
        context = {f"needs.path_route.outputs.{key}": value for key, value in routed.items()}
        context.update({
            "github.event_name": event,
            "github.ref": "refs/pull/1/merge" if event == "pull_request" else "refs/heads/feat-cmux-next",
            "github.repository": "manaflow-ai/cmux",
            "github.repository_owner": "manaflow-ai",
            "github.event.pull_request.head.repo.full_name": head_repo,
            "github.event.pull_request.labels.*.name": list(labels),
            "github.run_attempt": 1,
            "github.triggering_actor": "someone",
            "needs.push-head-preflight.outputs.current": "true",
            "needs.release-compile-fast.result": "skipped",
            "needs.release-compile-fast.outputs.verdict": "",
            # The build fleet compiled a same-repository PR's head (PullRequestCompileOnTheBuildFleet).
            "needs.app-compile-fleet.outputs.verdict": "pass",
            # With macos-placement's outputs empty (it skipped), runs-on takes the shared route.
            "needs.macos-placement.outputs.runner": "",
            "vars.CI_PR_POOL_OWNED": "1",
            "vars.CI_SIDE_LANE_RUNNER": "shared-side-route",
            "vars.CI_NEXT_PROMOTE_POOL": "reserved-promotion-runner",
            "vars.MACOS_RUNNER_26": "hosted-macos",
        })
        return context

    def runs(self, context: dict) -> bool:
        return bool(evaluate(self.job()["if"], context))

    def test_a_superseded_base_push_skips_before_queueing(self):
        """A superseded push does not occupy the Release compile queue."""
        context = self.context([], event="push")
        context["needs.push-head-preflight.outputs.current"] = "false"
        context["github.run_id"] = "7"
        self.assertFalse(self.runs(context))
        self.assertEqual(evaluate(self.job()["runs-on"], context), "blacksmith-6vcpu-macos-26")
        group = self.job()["concurrency"]
        self.assertEqual(evaluate(group["group"], context), "cmux-next-release-compile-7")
        self.assertIs(group["cancel-in-progress"], False)
        # A superseded pull request run is still skipped (its run is cancelled anyway), and so is a main push.
        for event, ref in (("pull_request", "refs/pull/1/merge"), ("push", "refs/heads/main")):
            with self.subTest(event=event, ref=ref):
                other = self.context(["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkspaceSpawn.swift"], event=event)
                other["github.ref"] = ref
                other["needs.push-head-preflight.outputs.current"] = "false"
                self.assertFalse(self.runs(other))

    def test_a_cmuxnext_swift_pr_runs_the_release_compile_from_a_fork_or_with_full_ci(self):
        changed = ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkspaceSpawn.swift"]
        fork = self.context(changed, head_repo="someone/cmux")
        self.assertEqual(fork["needs.path_route.outputs.cmuxnext_swift"], "true")
        self.assertTrue(self.runs(fork))
        self.assertEqual(evaluate(self.job()["runs-on"], fork), "blacksmith-6vcpu-macos-26")
        # A same-repository PR compiles Release only with full-ci (the base push compiles every merge).
        self.assertFalse(self.runs(self.context(changed)))
        labeled = self.context(changed, labels=("full-ci",))
        self.assertTrue(self.runs(labeled))
        # Never the reserved promotion runner on a PR, with macos-placement skipped.
        self.assertEqual(evaluate(self.job()["runs-on"], labeled), "shared-side-route")
        self.assertEqual(evaluate(self.job()["env"]["CMUX_NEXT_RUNNER"], labeled), "shared-side-route")

    def test_a_same_repository_pr_runs_the_mac_release_compile_only_for_what_only_xcodebuild_sees(self):
        """With no build-fleet verdict, a same-repository PR's Mac Release compile (the CmuxNext package
        through xcodebuild) runs only for a MAC_RELEASE_INPUTS change; the base push compiles every merge."""
        source = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkspaceSpawn.swift"

        def unjudged(context: dict) -> dict:
            context["needs.app-compile-fleet.outputs.verdict"] = ""
            return context

        plain = unjudged(self.context([source]))
        self.assertEqual(plain["needs.path_route.outputs.native"], "true")
        self.assertEqual(plain["needs.path_route.outputs.mac_release"], "false")
        self.assertFalse(self.runs(plain))
        for changed in (["Packages/macOS/CmuxNext/Package.swift"], ["Packages/macOS/CmuxNext/Package.resolved"],
                        ["Packages/Shared/CmuxTheme/Package.swift"], ["scripts/ci/xcode-pins.txt"],
                        ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/Assets.xcassets/Contents.json"]):
            with self.subTest(changed=changed):
                context = unjudged(self.context(changed))
                self.assertEqual(context["needs.path_route.outputs.mac_release"], "true")
                self.assertTrue(self.runs(context))
                # A build-fleet verdict still answers for it.
                context["needs.app-compile-fleet.outputs.verdict"] = "pass"
                self.assertFalse(self.runs(context))
        # The base push and a fork keep the Mac Release compile whatever they change.
        self.assertTrue(self.runs(self.context([source], event="push")))
        self.assertTrue(self.runs(unjudged(self.context([source], head_repo="someone/cmux"))))
        place = next(step for step in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["macos-placement"]["steps"]
                     if step.get("id") == "place")
        # With no gateway for the app compile, the Mac Release compile it falls back to takes the cascade.
        self.assertIn("needs.path_route.outputs.mac_release == 'true' && !(needs.app-compile-placement.outputs.gateway_attempt",
                      place["env"]["CASCADE_RUNS"])

    def test_fast_gate_is_the_first_compile_path_and_has_no_single_host_reservation(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        fast = jobs["release-compile-fast"]
        admitted = jobs["release-compile-fast-admission"]
        self.assertNotEqual(fast["name"], "cmux-next Release compile (Xcode 26)")
        self.assertEqual(admitted["name"], "cmux-next Release compile (Xcode 26)")
        # The admission job runs whenever the fast check ran without handing off to the Mac
        # fallback and is green only on pass, so a fleet error stays red under the gate name;
        # unavailable, or a fast check refused before a verdict, leaves it to the Mac fallback.
        for verdict, result, runs in (("pass", "success", True), ("unavailable", "success", False),
                                      ("fail", "success", True), ("", "failure", False), ("", "success", False),
                                      ("", "skipped", False), ("", "cancelled", False)):
            with self.subTest(verdict=verdict, result=result):
                context = {"github.event_name": "push", "github.ref": "refs/heads/feat-cmux-next",
                           "needs.release-compile-fast.result": result,
                           "needs.release-compile-fast.outputs.verdict": verdict}
                self.assertEqual(bool(evaluate(admitted["if"], context)), runs)
        self.assertIn('"$VERDICT" == pass && "$RESULT" == success', admitted["steps"][0]["run"])
        # A compile failure must not fail the fast job: a failed job is the refused case, and
        # its verdict output is what the admission job turns red.
        compile_step = next(step for step in fast["steps"] if step.get("id") == "compile")
        self.assertIs(compile_step.get("continue-on-error"), True)
        # An idle gateway runner from this attempt submits the check; otherwise a Linux runner reads the build
        # fleet's own Release (-Onone) compile of the push, fail closed on sha, repo, recipe and configuration.
        self.assertTrue(fast["runs-on"].startswith(
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
            "needs.macos-placement.outputs.gateway_attempt == format('{0}', github.run_attempt) && "
            "needs.macos-placement.outputs.gateway_runner != '' && needs.macos-placement.outputs.gateway_runner || "),
            fast["runs-on"])
        self.assertIn("fromJSON(vars.RUNNER_POOLS).linux_2", fast["runs-on"])
        run = next(step["run"] for step in fast["steps"] if step.get("id") == "compile")
        self.assertIn("compile-check --ref", run)
        self.assertIn("--app", run)
        self.assertIn('.recipe_version != 2 or .configuration != "release-onone"', run)
        self.assertEqual(compile_step["env"]["RESULTS"], "https://gh-events.cmux.com/compile-checks/v1")
        for name in ("release-compile-fast", "release-compile"):
            with self.subTest(job=name):
                self.assertNotIn("CI_NEXT_PROMOTE_POOL", str(jobs[name]["runs-on"]))

    def run_fast_linux_read(self, codes: list[str], reply: dict | None) -> tuple[str, str, float]:
        """Run the fast check's Linux route with a fake curl: each probe read prints the next code;
        the blocking read writes `reply` and prints 200 (or prints 404 when None)."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        run = next(step["run"] for step in jobs["release-compile-fast"]["steps"] if step.get("id") == "compile")
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            (Path(temp) / "codes").write_text("\n".join(codes) + "\n")
            (Path(temp) / "reply.json").write_text(json.dumps(reply) if reply is not None else "")
            curl = bin_dir / "curl"
            curl.write_text(f"""#!/bin/bash
echo "$*" >> "{temp}/calls"
if [[ " $* " == *" -o /dev/null "* ]]; then
  code=$(head -1 "{temp}/codes"); sed -i.bak 1d "{temp}/codes"; printf '%s' "${{code:-404}}"
  [[ "${{code:-404}}" == 000 ]] && exit 7; exit 0
fi
[[ -s "{temp}/reply.json" ]] || {{ printf 404; exit 0; }}
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && cp "{temp}/reply.json" "$2"; shift; done
printf 200
""")
            curl.chmod(0o755)
            output = Path(temp) / "out"
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": temp,
                   "GITHUB_OUTPUT": str(output), "GATEWAY": "", "REF": "a" * 40, "REPO": "manaflow-ai/cmux",
                   "RESULTS": "https://results.invalid/compile-checks/v1", "PROBE_GAP": "0", "WAIT_SECONDS": "90"}
            started = time.monotonic()
            # GitHub runs a `run:` step as `bash -e {0}`.
            result = subprocess.run(["bash", "-e", "-c", run], env=env, capture_output=True, text=True, timeout=60)
            elapsed = time.monotonic() - started
            calls = (Path(temp) / "calls").read_text() if (Path(temp) / "calls").exists() else ""
            return output.read_text() if output.exists() else "", result.stdout + calls, elapsed

    def test_fast_check_hands_off_at_once_when_the_results_service_is_down(self):
        # Two edge 530s (the controller's origin is down): no blocking read, the Mac fallback runs now.
        # WAIT_SECONDS is 90 and the step runs under a 60 s timeout, so a step that waited on the
        # service would time out here; the hand-off itself is the causal check, not its wall time.
        out, log, _ = self.run_fast_linux_read(["530", "530"], None)
        self.assertIn("verdict=unavailable", out)
        self.assertIn("results service down (HTTP 530)", log)
        self.assertNotIn("--retry-all-errors", log)
        out, log, _ = self.run_fast_linux_read(["000", "000"], None)
        self.assertIn("verdict=unavailable", out)
        self.assertIn("results service down (HTTP 000)", log)

    def test_fast_check_still_waits_for_a_live_results_service(self):
        verdict = {"sha": "a" * 40, "repo": "manaflow-ai/cmux", "recipe_version": 2,
                   "configuration": "release-onone", "state": "pass"}
        # A 404 (service up, no result yet), or one 530 blip then a 404, keeps the blocking read. The read
        # retries nothing inside curl: a 530 there would be retried until the deadline (note-82).
        for codes in (["404"], ["530", "404"]):
            with self.subTest(codes=codes):
                out, log, _ = self.run_fast_linux_read(codes, verdict)
                self.assertIn("verdict=pass", out)
                self.assertIn("&wait=", log)
                self.assertNotIn("--retry-all-errors", log)
                self.assertNotIn("results service down", log)

    def test_exactly_one_job_carries_the_gate_name_for_each_fast_check_outcome(self):
        # push attribution and the nightly feed watch read the first job with the gate name, so a
        # red admission beside a green fallback would report a failure the fallback cleared.
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        gate = [job for job in jobs.values() if job.get("name") == "cmux-next Release compile (Xcode 26)"]
        self.assertEqual(len(gate), 2)
        for verdict, result in (("pass", "success"), ("unavailable", "success"), ("fail", "success"),
                                ("", "failure"), ("", "success"), ("", "skipped")):
            with self.subTest(verdict=verdict, result=result):
                context = {"github.event_name": "push", "github.ref": "refs/heads/feat-cmux-next",
                           "github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                           "github.base_ref": "", "github.run_attempt": 1,
                           "needs.path_route.outputs.native": "true",
                           "needs.push-head-preflight.outputs.current": "true",
                           "needs.app-compile-fleet.outputs.verdict": "",
                           "needs.release-compile-fast.result": result,
                           "needs.release-compile-fast.outputs.verdict": verdict}
                self.assertEqual(sum(bool(evaluate(job["if"], context)) for job in gate), 1)

    def test_the_fast_admission_gate_requests_promotion_itself(self):
        # The fast check's own request reached main's promote job before the admission job
        # existed; the admission job requests once green, after a checkout of the pushed
        # commit (request-nightly-next.sh refuses any other HEAD). No downstream helper
        # repeats that request at the same commit (it cost the repository token's reads).
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertFalse(any("request-nightly-next.sh" in step.get("run", "")
                             for step in jobs["release-compile-fast"]["steps"]))
        admitted = jobs["release-compile-fast-admission"]
        self.assertEqual(admitted["permissions"]["actions"], "write")
        steps = admitted["steps"]
        request = next(i for i, step in enumerate(steps) if "request-nightly-next.sh" in step.get("run", ""))
        checkout = next(i for i, step in enumerate(steps) if str(step.get("uses", "")).startswith("actions/checkout@"))
        self.assertLess(0, checkout)
        self.assertLess(checkout, request)
        self.assertNotIn("request-nightly-next-fast", jobs)
        self.assertEqual([job_id for job_id, job in jobs.items()
                          if "release-compile-fast-admission" in (job.get("needs") or [])
                          and any("request-nightly-next.sh" in step.get("run", "") for step in job.get("steps", []))],
                         [])

    def test_a_green_gate_rerun_requests_promotion_inside_the_gate_job(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        gate = jobs["release-compile"]
        self.assertEqual(gate["permissions"]["actions"], "write")
        request = next(step for step in gate["steps"] if step.get("name") == "Request nightly-next promotion after this gate")
        self.assertIn("github.event_name == 'push'", request["if"])
        self.assertIn("request-nightly-next.sh", request["run"])

    def test_generated_files_are_not_branch_wide_serialized(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        group = jobs["generated-files"]["concurrency"]["group"]
        self.assertIn("github.sha", group)
        self.assertNotIn("github.ref", group)

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
                context = self.context(changed, head_repo="someone/cmux")
                self.assertEqual(context["needs.path_route.outputs.swift_canary"], "false")
                self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "true")
                self.assertTrue(self.runs(context))
                self.assertEqual(evaluate(self.job()["runs-on"], context), "blacksmith-6vcpu-macos-26")

    def test_a_web_only_pr_skips_the_release_compile(self):
        for changed in (["web/app/page.tsx"], ["webviews/src/app/Thing.tsx"]):
            with self.subTest(changed=changed):
                context = self.context(changed)
                self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "false")
                self.assertFalse(self.runs(context))

    def test_a_native_pr_without_cmuxnext_swift_runs_it_only_with_full_ci(self):
        # The native tier no longer runs on an unlabeled same-repository PR (#22303 undone for the
        # heavy compiles, 2026-10-21: the Mac queue was ~350 jobs deep); full-ci runs it from either repository.
        context = self.context(["App/Info.plist"])
        self.assertEqual(context["needs.path_route.outputs.native"], "true")
        self.assertEqual(context["needs.path_route.outputs.cmuxnext_swift"], "false")
        self.assertFalse(self.runs(context))
        self.assertTrue(self.runs(self.context(["App/Info.plist"], labels=("full-ci",))))
        # With no build-fleet verdict, the Mac compiles it only for an input only its xcodebuild sees
        # (path_route's mac_release): App/ is the Xcode app target's, not the package's.
        context["needs.app-compile-fleet.outputs.verdict"] = "unavailable"
        self.assertFalse(self.runs(context))
        resolved = self.context(["Packages/macOS/CmuxNext/Package.resolved"])
        resolved["needs.app-compile-fleet.outputs.verdict"] = "unavailable"
        self.assertTrue(self.runs(resolved))
        self.assertFalse(self.runs(self.context(["App/Info.plist"], head_repo="someone/cmux")))
        self.assertTrue(self.runs(self.context(["App/Info.plist"], labels=("full-ci",), head_repo="someone/cmux")))

    def test_base_pushes_still_run_it_on_the_blacksmith_fallback(self):
        context = self.context([], event="push")
        self.assertTrue(self.runs(context))
        self.assertEqual(evaluate(self.job()["runs-on"], context), "blacksmith-6vcpu-macos-26")

    def test_a_fast_gate_that_died_before_a_verdict_falls_back_to_the_mac_compile(self):
        # A runner hook refusing the fast gate (disk floor, 2026-10-24) fails it with no
        # verdict; the fallback must still compile, or no commit can be promoted.
        context = self.context([], event="push")
        for result, verdict, runs in (("failure", "", True), ("success", "", True), ("success", "unavailable", True),
                                      ("success", "fail", False), ("success", "pass", False),
                                      ("cancelled", "", False)):
            with self.subTest(result=result, verdict=verdict):
                context["needs.release-compile-fast.result"] = result
                context["needs.release-compile-fast.outputs.verdict"] = verdict
                self.assertEqual(self.runs(context), runs)
        # The refused side pool is not asked again: the fallback takes the last-resort
        # Blacksmith route even with a placement mini, and an "unavailable" verdict keeps the mini.
        context["needs.macos-placement.outputs.runner"] = "glaeda-side-std-xcode-26.6"
        for result, verdict, label in (("failure", "", "blacksmith-6vcpu-macos-26"),
                                       ("success", "", "glaeda-side-std-xcode-26.6"),
                                       ("success", "unavailable", "glaeda-side-std-xcode-26.6")):
            with self.subTest(result=result, verdict=verdict, route=label):
                context["needs.release-compile-fast.result"] = result
                context["needs.release-compile-fast.outputs.verdict"] = verdict
                self.assertEqual(evaluate(self.job()["runs-on"], context), label)
                self.assertEqual(evaluate(self.job()["env"]["CMUX_NEXT_RUNNER"], context), label)


class SameRepositoryPullRequestsRunTheirTiers(unittest.TestCase):
    """#22303: a same-repository PR runs every routed tier on its own branch, with no label.

    Before, the Mac tiers needed the full-ci label, and a dispatch ran them only on
    feat-cmux-next or a next-batch/* branch, so an agent pushed a side next-batch/* branch
    to see its own PR's Swift tests. A fork PR still needs full-ci and never gets an owned
    runner (macos-placement).
    """

    # generated-files is not here: with swift routed, swift-test checks the generated files on its own
    # package build (path_route's generated_host; tests/test_cmux_next_generated_fold.py).
    TIER_JOBS = ("web-bundles", "swift-canary", "swift-test", "daemon-test",
                 "release-compile", "cmux-scheme-compile")

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, event: str = "pull_request", *, head_repo: str = "manaflow-ai/cmux",
                labels: tuple[str, ...] = (), ref: str = "refs/pull/1/merge", **inputs: str) -> dict:
        context = {
            "github.event_name": event,
            "github.ref": ref,
            "github.base_ref": "feat-cmux-next" if event == "pull_request" else "",
            "github.repository": "manaflow-ai/cmux",
            "github.repository_owner": "manaflow-ai",
            "github.run_attempt": 1,
            "github.run_id": "99",
            "vars.CI_PR_POOL_OWNED": "1",
            "needs.push-head-preflight.outputs.current": "true",
            "needs.web-bundles.result": "success",
            # The router ran: web-bundles checks its result (a re-run skips portable-placement before it).
            "needs.path_route.result": "success",
            "needs.path_route.outputs.tree_state": "ready",
            "needs.app-compile-fleet.outputs.verdict": "pass",
            "needs.release-compile-fast.result": "skipped",
            "needs.release-compile-fast.outputs.verdict": "",
        }
        for tier in ("macos", "native", "swift_canary", "scheme", "generated", "swift", "daemon"):
            context[f"needs.path_route.outputs.{tier}"] = "true"
        context["needs.path_route.outputs.generated_host"] = "swift-test"
        if event == "pull_request":
            context.update({"github.event.pull_request.number": "42",
                            "github.event.pull_request.head.repo.full_name": head_repo,
                            "github.event.pull_request.labels.*.name": list(labels),
                            "github.event.pull_request.author_association": "CONTRIBUTOR"})
        context.update({f"inputs.{key}": value for key, value in inputs.items()})
        return context

    def running(self, context: dict) -> set[str]:
        jobs = self.jobs()
        return {name for name in self.TIER_JOBS + ("macos-placement", "checks") if evaluate(jobs[name]["if"], context)}

    def test_a_same_repository_pr_runs_every_routed_tier_without_a_label(self):
        # Except the two heavy app compiles and swift-test, which need full-ci (HeavyMacCompilesBehindFullCi).
        self.assertEqual(self.running(self.context()),
                         set(self.TIER_JOBS) - set(HEAVY_COMPILES) - {"swift-test"} | {"macos-placement", "checks"})
        self.assertEqual(self.running(self.context(labels=("full-ci",))),
                         set(self.TIER_JOBS) | {"macos-placement", "checks"})

    def test_a_fork_pr_still_needs_full_ci_and_never_places_an_owned_runner(self):
        fork = self.context(head_repo="someone/cmux")
        fork["needs.path_route.outputs.cmuxnext_swift"] = "false"
        self.assertEqual(self.running(fork), {"checks"})
        labeled = self.context(head_repo="someone/cmux", labels=("full-ci",))
        self.assertEqual(self.running(labeled), set(self.TIER_JOBS) | {"checks"})

    def test_a_dispatch_on_a_working_branch_runs_every_tier(self):
        for ref in ("refs/heads/issue-22303-next-pr-ci", "refs/heads/feat-cmux-next", "refs/heads/next-batch/abc"):
            with self.subTest(ref=ref):
                context = self.context("workflow_dispatch", ref=ref, same_tree_sha="")
                self.assertEqual(self.running(context), set(self.TIER_JOBS) | {"macos-placement", "checks"})
        # The tree probe, which starts the daemon and scheme tiers, has no ref gate either.
        probe = next(step for step in self.jobs()["path_route"]["steps"] if step.get("id") == "tree")
        self.assertNotIn("github.ref", probe["if"])

    def test_a_dispatch_whose_tree_was_building_gets_its_daemon_tests_later(self):
        # The marker says dispatch, not push: a same-tree run for a push skips daemon-test
        # (push CI is the app build), and nothing else tests a working branch's tree.
        step = next(step for step in self.jobs()["path_route"]["steps"] if step.get("id") == "marker")
        self.assertEqual(step["env"]["REF_TYPE"], "${{ github.ref_type }}")

        def marker(event: str, ref_type: str = "branch", dev_daily: str = "false", branch: str = "topic",
                   tip_daemon: str = "false") -> dict:
            with tempfile.TemporaryDirectory() as directory:
                env = {**os.environ, "RUNNER_TEMP": directory, "GITHUB_OUTPUT": f"{directory}/out",
                       "GITHUB_RUN_ID": "5", "KEY": "k", "DAEMON": "true", "SCHEME": "false", "SHA": "a" * 40,
                       "STATUS_SHA": "a" * 40, "BRANCH": branch, "REF_TYPE": ref_type, "EVENT_NAME": event,
                       "DEV_DAILY": dev_daily, "DEV_DAILY_SHA": "", "TIP_DAEMON_SUITE": tip_daemon}
                subprocess.run(["bash", "-c", step["run"]], env=env, check=True, capture_output=True, text=True)
                return json.loads(Path(directory, "cmux-next-tree-wait/marker.json").read_text())

        self.assertEqual(marker("push")["origin"], "push")
        self.assertNotIn("ref_kind", marker("push"))
        self.assertEqual((marker("workflow_dispatch")["origin"], marker("workflow_dispatch")["ref_kind"]), ("dispatch", "heads"))
        # A tag dispatch's marker says so; the notifier never looks a tag up as a branch.
        self.assertEqual(marker("workflow_dispatch", ref_type="tag")["ref_kind"], "tags")
        self.assertEqual(marker("workflow_dispatch", dev_daily="true")["origin"], "push")
        # The tip daemon suite's marker names its exact commit (cmux_next_tree_notify.py starts it after
        # the tip moves); only on feat-cmux-next, never for a plain dispatch.
        self.assertEqual(marker("workflow_dispatch", branch="feat-cmux-next", tip_daemon="true")["tip_suite"], "daemon")
        self.assertNotIn("tip_suite", marker("workflow_dispatch", branch="feat-cmux-next"))
        self.assertNotIn("tip_suite", marker("workflow_dispatch", tip_daemon="true"))
        self.assertEqual(step["env"]["TIP_DAEMON_SUITE"], "${{ inputs.tip_daemon_suite || false }}")
        same_tree = self.context("workflow_dispatch", ref="refs/heads/topic", same_tree_sha="a" * 40,
                                 same_tree_state="ready", same_tree_tiers="daemon", same_tree_origin="dispatch")
        self.assertTrue(evaluate(self.jobs()["daemon-test"]["if"], same_tree))
        same_tree["inputs.same_tree_origin"] = "push"
        self.assertFalse(evaluate(self.jobs()["daemon-test"]["if"], same_tree))

    def test_web_bundles_run_only_for_a_tier_that_restores_them(self):
        only_fast = self.context()
        for tier in ("swift", "daemon", "generated"):
            only_fast[f"needs.path_route.outputs.{tier}"] = "false"
        self.assertFalse(evaluate(self.jobs()["web-bundles"]["if"], only_fast))
        for tier in ("swift", "daemon", "generated"):
            with self.subTest(tier=tier):
                self.assertTrue(evaluate(self.jobs()["web-bundles"]["if"], dict(only_fast, **{f"needs.path_route.outputs.{tier}": "true"})))
        # A push and a dispatch fill the cache whatever the route.
        push = self.context("push", ref="refs/heads/feat-cmux-next")
        self.assertTrue(evaluate(self.jobs()["web-bundles"]["if"], push))

    def test_the_cascade_counts_pr_package_checks_and_the_compiles_that_run(self):
        place = next(step for step in self.jobs()["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CASCADE_RUNS"]
        self.assertEqual(set(evaluate(expression, self.context()).split()),
                         {"fast-tier", "swift-canary", "daemon-test"})
        self.assertEqual(set(evaluate(expression, self.context(labels=("full-ci",))).split()),
                         {"fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile", "swift-test", "daemon-test"})
        generated = self.context()
        generated["needs.path_route.outputs.generated_host"] = "generated-files"
        self.assertIn("generated-files", evaluate(expression, generated).split())
        generated["needs.path_route.outputs.tree_state"] = "pending"
        self.assertNotIn("daemon-test", evaluate(expression, generated).split())
        push = self.context("push", ref="refs/heads/feat-cmux-next")
        self.assertEqual(set(evaluate(expression, push).split()),
                         {"fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile"})

    def test_a_newer_dispatch_on_the_same_branch_replaces_the_older(self):
        concurrency = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["concurrency"]

        def group(context: dict) -> tuple[str, bool]:
            return evaluate(concurrency["group"], context), bool(evaluate(concurrency["cancel-in-progress"], context))

        branch = self.context("workflow_dispatch", ref="refs/heads/topic", same_tree_sha="", dev_daily="")
        self.assertEqual(group(branch), ("cmux-next-dispatch-refs/heads/topic", True))
        self.assertEqual(group(self.context()), ("cmux-next-42", True))
        # Base, batch, same-tree and DEV daily dispatches keep a run of their own, never cancelled:
        # the batch controller and the same-tree notifier own those runs.
        for context in (
            self.context("workflow_dispatch", ref="refs/heads/feat-cmux-next", same_tree_sha=""),
            self.context("workflow_dispatch", ref="refs/heads/next-batch/abc", same_tree_sha=""),
            self.context("workflow_dispatch", ref="refs/heads/topic", same_tree_sha="a" * 40),
            self.context("push", ref="refs/heads/feat-cmux-next"),
        ):
            with self.subTest(ref=context["github.ref"], event=context["github.event_name"]):
                self.assertEqual(group(context), ("cmux-next-99", False))
        daily = self.context("workflow_dispatch", ref="refs/heads/topic", same_tree_sha="")
        daily["inputs.dev_daily"] = True
        self.assertEqual(group(daily), ("cmux-next-99", False))


class AppSizeCapOnPush(unittest.TestCase):
    """The CmuxNextApp size cap step on a push compares with the commit before the push, so a push
    that adds no App source lines passes while the App sits over the cap (every feat-cmux-next push
    was red on it, 2026-10-21), and a push that adds source lines still fails."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.app = self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
        self.app.mkdir(parents=True)
        scripts = self.repo / "scripts/cmux-next"
        scripts.mkdir(parents=True)
        for name in ("check-app-size.sh", "count-swift-code-lines.py"):
            (scripts / name).write_text((ROOT / "scripts/cmux-next" / name).read_text())
            (scripts / name).chmod(0o755)
        (scripts / "app-size-baseline.txt").write_text("2\n")
        # Over the cap of 2 on the commit before the push.
        (self.app / "App.swift").write_text("let first = 1\nlet second = 2\nlet third = 3\n")
        self.git("init", "-q", "-b", "main")
        self.commit("before")
        self.before = self.head()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t",
                               "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-qm", message, "--allow-empty")

    def head(self) -> str:
        return self.git("rev-parse", "HEAD")

    def run_step(self, before: str) -> subprocess.CompletedProcess:
        step = next(s for s in steps() if s.get("id") == "app-size")
        env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        env.update(EVENT_NAME="push", FULL_CI="true", BEFORE=before, GITHUB_WORKSPACE=str(self.repo),
                   GITHUB_SHA=self.head())
        return subprocess.run(["bash", "-e", "-c", step["run"]], cwd=self.repo, env=env,
                              capture_output=True, text=True, timeout=120)

    def test_a_push_that_adds_no_app_source_passes_over_the_cap(self):
        (self.repo / "README.md").write_text("docs\n")
        (self.app / "App.swift").write_text("let first = 1\nlet second = 2\nlet third = 3\n// note\n")
        self.commit("docs and a comment")
        result = self.run_step(self.before)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no source-line growth", result.stdout)

    def test_a_push_that_adds_app_source_still_fails(self):
        (self.app / "Feature.swift").write_text("let feature = 4\n")
        self.commit("a feature in the App")
        result = self.run_step(self.before)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("real source growth is not allowed", result.stderr)

    def test_a_push_with_no_before_commit_checks_the_plain_cap(self):
        self.commit("first push of a branch")
        result = self.run_step("0" * 40)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("CmuxNextApp is capped at 2 lines", result.stderr)


class HeavyMacCompilesBehindFullCi(unittest.TestCase):
    """The Release compile and the app scheme compile need full-ci on a pull request again.

    #22325 ran every routed Mac tier on a same-repository PR with no label. On 2026-10-21 (~20:10Z)
    the Mac queue was ~350 jobs deep, 76 of them "cmux-next Release compile (Xcode 26)" and 22
    "cmux app scheme compile (Debug)". Both still run on every feat-cmux-next push (the Release
    compile gates nightly-next), every next-batch/* push, every dispatch and a full-ci PR; a
    MEMBER/OWNER dev-build PR keeps its scheme compile (its dogfood app). A fork PR is unchanged.
    """

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, event: str = "pull_request", *, head_repo: str = "manaflow-ai/cmux",
                labels: tuple[str, ...] = (), ref: str = "refs/pull/1/merge", association: str = "CONTRIBUTOR",
                cmuxnext_swift: str = "true", fleet: str = "pass", mac_release: str = "true") -> dict:
        context = {
            # The build fleet compiled the PR's head (app-compile-fleet), so no Mac Release compile is needed.
            "needs.app-compile-fleet.outputs.verdict": fleet,
            "needs.release-compile-fast.result": "skipped",
            "needs.release-compile-fast.outputs.verdict": "",
            "github.event_name": event, "github.ref": ref,
            "github.base_ref": "feat-cmux-next" if event == "pull_request" else "",
            "github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
            "github.run_attempt": 1, "github.run_id": "99", "vars.CI_PR_POOL_OWNED": "1",
            "needs.push-head-preflight.outputs.current": "true",
            "needs.path_route.outputs.tree_state": "ready",
            "needs.path_route.outputs.cmuxnext_swift": cmuxnext_swift,
            "needs.path_route.outputs.mac_release": mac_release,
            "inputs.same_tree_sha": "",
        }
        for tier in ("macos", "native", "scheme"):
            context[f"needs.path_route.outputs.{tier}"] = "true"
        if event == "pull_request":
            context.update({"github.event.pull_request.head.repo.full_name": head_repo,
                            "github.event.pull_request.labels.*.name": list(labels),
                            "github.event.pull_request.author_association": association})
        return context

    def compiling(self, context: dict) -> set[str]:
        jobs = self.jobs()
        return {name for name in HEAVY_COMPILES if evaluate(jobs[name]["if"], context)}

    def test_a_same_repository_pr_without_full_ci_skips_both(self):
        self.assertEqual(self.compiling(self.context()), set())
        # With or without a CmuxNext Swift change: the base push compiles Release after the merge.
        self.assertEqual(self.compiling(self.context(cmuxnext_swift="false")), set())

    def test_a_same_repository_pr_compiles_release_on_a_mac_only_without_a_fleet_verdict(self):
        # No fleet verdict (the gateway is down, the client is missing, or the variable is unset): the
        # Mac Release compile is the PR's compile again. A fleet red is already the PR's red.
        for fleet in ("unavailable", ""):
            with self.subTest(fleet=fleet):
                self.assertEqual(self.compiling(self.context(fleet=fleet)), {"release-compile"})
        self.assertEqual(self.compiling(self.context(fleet="fail")), set())
        # Not when the change has no input only the Mac Release compile sees (path_route's mac_release).
        for fleet in ("unavailable", ""):
            with self.subTest(fleet=fleet, mac_release="false"):
                self.assertEqual(self.compiling(self.context(fleet=fleet, mac_release="false")), set())

    def test_a_same_repository_pr_with_full_ci_runs_both(self):
        self.assertEqual(self.compiling(self.context(labels=("full-ci",))), set(HEAVY_COMPILES))

    def test_a_member_dev_build_pr_keeps_its_scheme_compile(self):
        member = self.context(labels=("dev-build",), association="MEMBER")
        self.assertEqual(self.compiling(member), {"cmux-scheme-compile"})
        self.assertEqual(self.compiling(self.context(labels=("dev-build",))), set())

    def test_feat_and_batch_pushes_and_dispatches_run_both(self):
        for event, ref in (("push", "refs/heads/feat-cmux-next"), ("push", "refs/heads/next-batch/abc"),
                           ("workflow_dispatch", "refs/heads/feat-cmux-next"),
                           ("workflow_dispatch", "refs/heads/topic")):
            with self.subTest(event=event, ref=ref):
                self.assertEqual(self.compiling(self.context(event, ref=ref)), set(HEAVY_COMPILES))

    def test_a_fork_pr_is_unchanged(self):
        fork = "someone/cmux"
        # A CmuxNext Swift change still compiles Release on its hosted route; nothing else runs unlabeled.
        self.assertEqual(self.compiling(self.context(head_repo=fork)), {"release-compile"})
        self.assertEqual(self.compiling(self.context(head_repo=fork, cmuxnext_swift="false")), set())
        self.assertEqual(self.compiling(self.context(head_repo=fork, labels=("full-ci",))), set(HEAVY_COMPILES))
        self.assertEqual(self.compiling(self.context(head_repo=fork, labels=("dev-build",), association="MEMBER",
                                                     cmuxnext_swift="false")), set())


class BuildFleetGatewayJobsFallBack(unittest.TestCase):
    """No cmux-next job waits on the build-fleet gateway. Every job whose runs-on can name it
    (vars.CI_COMPILE_CHECK_GATEWAY, a side-light label, or macos-placement's gateway_runner) runs only on
    a gateway runner macos-placement saw idle in the same attempt; in every other case it skips and its
    Mac fallback runs, in the cascade (an idle owned mini, then Blacksmith). 2026-10-26 06:00Z: 44 jobs
    queued on glaeda-side-light-xcode-26.6, the oldest 58 minutes, and PR #24155's app compile queued
    there three times without running. A new job pinned to the gateway fails here until it is in
    FALLBACKS, with the guard."""

    LIGHT = "glaeda-side-light-xcode-26.6"
    STD = "glaeda-side-std-xcode-26.6"
    # The job whose gateway reading each gateway job takes: macos-placement, after the PR quiet period, except
    # the PR's app compile, judged at once (app-compile-placement; Leo, 2026-11-08: only the Mac jobs wait).
    READING = {"app-compile-fleet": "app-compile-placement"}
    # Each gateway job's Mac fallback, which must run when the gateway job does not, and the event it runs on.
    FALLBACKS = {"app-compile-fleet": ("release-compile", "pull_request"),
                 "swift-canary-fleet": ("swift-canary", "pull_request"),
                 "release-compile-fast": ("release-compile", "push"),
                 # Only while macos-placement lists the tier in fleet_jobs (GatewayRunsOnlyTheFleetClient).
                 "fast-tier-fleet": ("fast-tier", "pull_request")}
    PINS = ("CI_COMPILE_CHECK_GATEWAY", "side-light", "gateway_runner")
    # Gateway jobs that, with no idle gateway reading, run on Linux instead of skipping: they read the build
    # fleet's own compile of the same sha (2026-11-02: every gateway runner busy from 09:39Z sent pushes 622a6b75
    # and 0fa148c5 to the Mac Release queue for over two hours while cmux-next/compile had passed both). Their
    # Mac fallback runs only when that read gives no verdict.
    LINUX_ROUTE = {"release-compile-fast": ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404")}

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    @staticmethod
    def cascade_jobs() -> tuple[str, ...]:
        """next_macos_cascade.CASCADE_JOBS: the Mac jobs an idle owned mini, then Blacksmith, take."""
        import importlib.util
        # Its own module name, registered for the whole process (Python 3.12's @dataclass reads the
        # module from sys.modules while it executes), so no other test's next_macos_cascade is touched.
        name = "_cmux_next_gateway_guard_next_macos_cascade"
        if name not in sys.modules:
            spec = importlib.util.spec_from_file_location(name, WORKFLOW.parents[2] / "scripts/ci/next_macos_cascade.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
        return sys.modules[name].CASCADE_JOBS

    def context(self, event: str, attempt: int, reading: tuple[str, str] | None) -> dict:
        context = {
            "github.event_name": event, "github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
            "github.ref": "refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge",
            "github.run_attempt": attempt, "github.triggering_actor": "someone",
            "vars.CI_COMPILE_CHECK_GATEWAY": self.LIGHT, "vars.CI_PR_POOL_OWNED": "1",
            "needs.path_route.outputs.native": "true", "needs.path_route.outputs.swift_canary": "true",
            # A change the Mac Release compile sees (path_route's mac_release): its fallback.
            "needs.path_route.outputs.mac_release": "true",
            "needs.path_route.outputs.macos": "true", "needs.push-head-preflight.outputs.current": "true",
            "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
            "github.event.pull_request.labels.*.name": [],
            "github.base_ref": "feat-cmux-next",
            # Every macOS label full or dead: the fast tier is listed for its build-fleet client.
            "needs.macos-placement.outputs.fleet_jobs": " fast-tier ",
        }
        if reading is not None:
            for placement in ("macos-placement", "app-compile-placement"):
                context[f"needs.{placement}.outputs.gateway_attempt"] = reading[0]
                context[f"needs.{placement}.outputs.gateway_runner"] = reading[1]
        return context

    def test_every_job_that_can_run_on_the_gateway_is_guarded(self):
        pinned = {name for name, job in self.jobs().items() if any(pin in str(job.get("runs-on", "")) for pin in self.PINS)}
        self.assertEqual(pinned, set(self.FALLBACKS),
                         "a job pinned to the build-fleet gateway needs the idle-reading guard and a Mac fallback here")

    def test_the_gateway_is_taken_only_on_an_idle_reading_from_the_same_attempt(self):
        jobs = self.jobs()
        placement_env = next(step["env"] for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        for name, (fallback, event) in self.FALLBACKS.items():
            job = jobs[name]
            self.assertIn(self.READING.get(name, "macos-placement"), job["needs"])
            for attempt, reading in ((1, ("1", self.LIGHT)), (1, ("1", self.STD)), (1, ("1", "")), (1, ("", "")),
                                     (1, None), (2, ("1", self.LIGHT)), (2, ("2", self.LIGHT)), (2, ("2", "")),
                                     (2, None), (3, ("2", self.STD))):
                context = self.context(event, attempt, reading)
                idle = reading is not None and reading[0] == str(attempt) and reading[1] != ""
                with self.subTest(job=name, attempt=attempt, reading=reading):
                    self.assertEqual(bool(evaluate(job["if"], context)), idle or name in self.LINUX_ROUTE)
                    if idle:
                        self.assertEqual(evaluate(job["runs-on"], context), reading[1])
                        continue
                    if name in self.LINUX_ROUTE:
                        # Never the gateway (busy, or judged in another attempt): a Linux runner.
                        self.assertIn(evaluate(job["runs-on"], context), self.LINUX_ROUTE[name])
                        self.assertIn(evaluate(job["runs-on"], {**context, "vars.CI_CLOUD_OVERFLOW_SAVED": "1"}),
                                      self.LINUX_ROUTE[name])
                        unavailable = {**context, f"needs.{name}.result": "success",
                                       f"needs.{name}.outputs.verdict": "unavailable",
                                       "needs.app-compile-fleet.outputs.verdict": ""}
                        self.assertTrue(evaluate(jobs[fallback]["if"], unavailable),
                                        f"{fallback} must run when {name} gives no verdict")
                        continue
                    # Skipped: the Mac fallback runs, and is one of the cascade's jobs on this route.
                    skipped = {**context, f"needs.{name}.result": "skipped", f"needs.{name}.outputs.verdict": "",
                               "needs.app-compile-fleet.result": "skipped", "needs.app-compile-fleet.outputs.verdict": "",
                               "needs.swift-canary-fleet.result": "skipped", "needs.swift-canary-fleet.outputs.verdict": "",
                               "needs.release-compile-fast.result": "skipped",
                               "needs.release-compile-fast.outputs.verdict": "",
                               "needs.fast-tier-fleet.result": "skipped", "needs.fast-tier-fleet.outputs.verdict": ""}
                    self.assertTrue(evaluate(jobs[fallback]["if"], skipped), f"{fallback} must run when {name} skips")
                    self.assertIn(fallback, self.cascade_jobs())
                    runs = evaluate(placement_env["CASCADE_RUNS"], skipped).split()
                    self.assertIn(fallback, runs, f"{fallback} must join the cascade when {name} skips")


class PullRequestCompileOnTheBuildFleet(unittest.TestCase):
    """A same-repository PR's app compile runs on the build fleet (`cmux-ci compile-check --ref <head> --app`,
    about a minute) instead of the Mac Release queue. 2026-10-21: 76 of ~350 queued Mac jobs were Release
    compiles. The job compiles the PR's head, the commit the landing gate asks
    about; a fleet red fails it; no verdict hands the PR to the Mac Release compile."""

    NAME = "cmux-next app compile (build fleet)"

    def job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["app-compile-fleet"]

    def context(self, event: str = "pull_request", *, head_repo: str = "manaflow-ai/cmux",
                labels: tuple[str, ...] = (), native: str = "true", gateway: str = "glaeda-gateway") -> dict:
        context = {
            "github.event_name": event, "github.repository": "manaflow-ai/cmux",
            "github.repository_owner": "manaflow-ai", "vars.CI_COMPILE_CHECK_GATEWAY": gateway,
            "needs.path_route.outputs.native": native, "needs.push-head-preflight.outputs.current": "true",
            "needs.path_route.outputs.mac_release": "true",
            "github.run_attempt": 1,
        }
        if event == "pull_request":
            context.update({"github.event.pull_request.head.repo.full_name": head_repo,
                            "github.event.pull_request.labels.*.name": list(labels)})
        return context

    def test_it_runs_on_a_same_repository_pr_the_native_tier_reaches(self):
        job = self.job()
        self.assertEqual(job["name"], self.NAME)
        context = {**self.context(), "needs.app-compile-placement.outputs.gateway_attempt": "1",
                   "needs.app-compile-placement.outputs.gateway_runner": "glaeda-gateway"}
        self.assertTrue(evaluate(job["if"], context))
        self.assertEqual(evaluate(job["runs-on"], context), "glaeda-gateway")

    def test_it_takes_only_an_idle_gateway_placement_saw(self):
        """2026-10-26 06:00Z: 44 jobs queued on the light side gateway, oldest 58 minutes; PR #24155's
        compile queued there three times. Its placement (app-compile-placement for the app compile,
        macos-placement for the canary) names an idle gateway runner or none."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for name, placement in (("app-compile-fleet", "app-compile-placement"), ("swift-canary-fleet", "macos-placement")):
            job = jobs[name]
            with self.subTest(job=name):
                self.assertIn(placement, job["needs"])
                context = {**self.context(), "needs.path_route.outputs.swift_canary": "true",
                           "github.run_attempt": 1}
                idle = {**context, f"needs.{placement}.outputs.gateway_attempt": "1",
                        f"needs.{placement}.outputs.gateway_runner": "glaeda-side-std-xcode-26.6"}
                self.assertTrue(evaluate(job["if"], idle))
                self.assertEqual(evaluate(job["runs-on"], idle), "glaeda-side-std-xcode-26.6")
                none_idle = {**idle, f"needs.{placement}.outputs.gateway_runner": ""}
                self.assertFalse(evaluate(job["if"], none_idle))
                # Placement skipped, failed, or ran an older base script: no reading, no gateway queue.
                self.assertFalse(evaluate(job["if"], context))
                # A re-run trusts only its own attempt's reading: an earlier attempt's idle runner may be busy now.
                self.assertFalse(evaluate(job["if"], {**idle, "github.run_attempt": 2}))
                self.assertFalse(evaluate(job["if"], {**context, "github.run_attempt": 2}))
                self.assertTrue(evaluate(job["if"], {**idle, "github.run_attempt": 2,
                                                     f"needs.{placement}.outputs.gateway_attempt": "2"}))

    def test_placement_judges_the_gateway_for_the_jobs_that_start(self):
        """The app compile's gateway is judged at once (app-compile-placement, Leo 2026-11-08: only the Mac
        jobs wait for the PR quiet period); macos-placement judges the canary's after the wait."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        early = jobs["app-compile-placement"]
        self.assertNotIn("pr-quiet-period", early["needs"])
        self.assertNotIn("macos-placement", early["needs"])
        early_env = next(step["env"] for step in early["steps"] if step.get("id") == "place")
        self.assertEqual(early_env["PLACEMENT"], "app-compile")
        self.assertEqual(early_env["GATEWAY_LABEL"], "${{ vars.CI_COMPILE_CHECK_GATEWAY }}")
        self.assertEqual(early_env["GATEWAY_JOBS"], "app-compile-fleet")
        placement = jobs["macos-placement"]
        self.assertIn("app-compile-placement", placement["needs"])
        for job in (early, placement):
            for output in ("gateway_runner", "gateway_attempt"):
                self.assertEqual(job["outputs"][output], f"${{{{ steps.place.outputs.{output} }}}}")
        step_env = next(step["env"] for step in placement["steps"] if step.get("id") == "place")
        self.assertEqual(step_env["GATEWAY_LABEL"], "${{ vars.CI_COMPILE_CHECK_GATEWAY }}")
        self.assertNotIn("GATEWAY_CASCADE", step_env)
        for why, context in (("same-repo PR", self.context()), ("fork", self.context(head_repo="someone/cmux")),
                             ("full-ci", self.context(labels=("full-ci",))), ("push", self.context("push")),
                             ("no native tier", self.context(native="false"))):
            with self.subTest(why=why):
                context = {**context, "needs.path_route.outputs.swift_canary": "false",
                           "needs.path_route.outputs.macos": "true", "vars.CI_PR_POOL_OWNED": "1"}
                placed = bool(evaluate(early["if"], context))
                idle = {**context, "needs.app-compile-placement.outputs.gateway_attempt": "1",
                        "needs.app-compile-placement.outputs.gateway_runner": "glaeda-gateway"}
                app = bool(evaluate(self.job()["if"], idle))
                # The early placement runs exactly where the app compile can.
                self.assertEqual(placed, app)
                self.assertFalse(evaluate(early["if"], {**context, "github.run_attempt": 2}))
                # macos-placement no longer judges a gateway for it: its runner is already busy by then.
                self.assertNotIn("app-compile-fleet", evaluate(step_env["GATEWAY_JOBS"], context).split())
                # The Mac Release compile joins the cascade exactly where the app compile does not run.
                if context["github.event_name"] == "pull_request" and not context["github.event.pull_request.labels.*.name"] \
                        and context["github.event.pull_request.head.repo.full_name"] == "manaflow-ai/cmux":
                    self.assertNotIn("release-compile", evaluate(step_env["CASCADE_RUNS"], idle).split())
                    self.assertEqual("release-compile" in evaluate(step_env["CASCADE_RUNS"], context).split(),
                                     context["needs.path_route.outputs.native"] == "true")
                canary = {**context, "needs.path_route.outputs.swift_canary": "true"}
                self.assertIn("swift-canary-fleet", evaluate(step_env["GATEWAY_JOBS"], canary).split())

    def test_it_does_not_run_where_the_mac_release_compile_does(self):
        idle = {"needs.app-compile-placement.outputs.gateway_attempt": "1",
                "needs.app-compile-placement.outputs.gateway_runner": "glaeda-gateway"}
        for why, context in (("fork", self.context(head_repo="someone/cmux")),
                             ("full-ci", self.context(labels=("full-ci",))),
                             ("push", self.context("push")),
                             ("no native tier", self.context(native="false")),
                             ("no gateway", self.context(gateway=""))):
            with self.subTest(why=why):
                self.assertFalse(evaluate(self.job()["if"], {**context, **idle}))

    def test_release_compile_waits_for_its_verdict(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertIn("app-compile-fleet", jobs["release-compile"]["needs"])

    def run_check(self, client_exit: int | None, *, mac_release: str = "false"
                  ) -> tuple[subprocess.CompletedProcess, str, str, str]:
        """Run the step with a stub cmux-ci exiting client_exit (None: no client installed)."""
        step = next(s for s in self.job()["steps"] if s.get("id") == "check")
        self.assertEqual(step["env"]["REF"], "${{ github.event.pull_request.head.sha }}")
        with tempfile.TemporaryDirectory() as tmp:
            client = Path(tmp) / "cmux-ci"
            if client_exit is not None:
                client.write_text(f'#!/bin/bash\necho "$@" > "{tmp}/args"\nexit {client_exit}\n')
                client.chmod(0o755)
            output = Path(tmp) / "output"
            output.touch()
            summary = Path(tmp) / "summary"
            env = git_fixture_env.fixture_env({"PATH": os.environ["PATH"], "HOME": tmp, "CMUX_CI_CLIENT": str(client), "REF": "d" * 40,
                   "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": tmp, "RUNNER_NAME": "gw",
                   "GITHUB_STEP_SUMMARY": str(summary), "MAC_RELEASE": mac_release})
            # The step's own shell: bash -e {0}.
            result = subprocess.run(["bash", "-e", "-c", step["run"]], env=env,
                                    capture_output=True, text=True, timeout=60)
            args = (Path(tmp) / "args").read_text() if (Path(tmp) / "args").exists() else ""
            return result, output.read_text(), args, summary.read_text() if summary.exists() else ""

    def test_a_fleet_pass_is_green_and_compiles_the_head(self):
        result, output, args, summary = self.run_check(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verdict=pass", output)
        self.assertIn(f"compile-check --ref {'d' * 40} --app", args)
        self.assertIn("Build fleet app compile: pass", summary)

    def test_a_fleet_compile_failure_is_the_prs_red(self):
        result, output, _, _ = self.run_check(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verdict=fail", output)

    def test_no_fleet_verdict_is_never_green(self):
        """2026-10-28: cmux-ci exited 69 (EX_UNAVAILABLE, a TimeoutError against the wedged controller)
        on PR #26741's head 292b43ef and this job went green, though no Mac Release compile ran for
        that change: a pass with nothing compiled. No verdict fails the job and says so; the verdict
        output stays unavailable, so release-compile still takes over where mac_release sends it."""
        for client_exit in (69, 75, 124, 2, 3, 137):
            with self.subTest(client_exit=client_exit):
                result, output, _, summary = self.run_check(client_exit)
                self.assertNotEqual(result.returncode, 0, "no build-fleet verdict must not report success")
                self.assertIn("verdict=unavailable", output)
                self.assertNotIn("verdict=pass", output)
                self.assertIn("no verdict", result.stdout)
                self.assertIn("controller unreachable or timed out", result.stdout)
                self.assertIn(f"exit {client_exit}", result.stdout)
                self.assertIn("Build fleet app compile: no verdict", summary)
                self.assertIn("No Mac Release compile runs for this change", result.stdout)

    def test_no_fleet_verdict_names_the_mac_fallback_when_it_runs(self):
        step = next(s for s in self.job()["steps"] if s.get("id") == "check")
        self.assertEqual(step["env"].get("MAC_RELEASE"), "${{ needs.path_route.outputs.mac_release }}")
        result, output, _, _ = self.run_check(69, mac_release="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verdict=unavailable", output)
        self.assertIn("Mac Release compile (cmux-next Release compile (Xcode 26)) runs as the fallback", result.stdout)
        # The fallback still runs on that output, failed job or not (release-compile's always()).
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.assertIn("always()", jobs["release-compile"]["if"])
        self.assertIn("needs.app-compile-fleet.outputs.verdict != 'pass'", jobs["release-compile"]["if"])

    def test_a_missing_client_is_no_verdict_not_a_pass(self):
        result, output, args, _ = self.run_check(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(args, "")
        self.assertIn("verdict=unavailable", output)
        self.assertIn("is not installed on runner gw", result.stdout)

    def test_a_skip_is_a_skip_never_a_pass(self):
        """The only no-compile outcome that is not red is the job-level skip (no idle gateway, a
        fork, full-ci, no native tier): GitHub reports the job skipped, and release-compile runs.
        Inside the step, success is reachable only after a verdict=pass."""
        step = next(s for s in self.job()["steps"] if s.get("id") == "check")
        self.assertNotIn("exit 0", step["run"])
        self.assertNotIn("continue-on-error", self.job())
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("|| true", step["run"])


def _shell_substitutions(text):
    """(text with each $(...) replaced by X, [inner texts]) using a paren-balanced scan."""
    out, inner, i = [], [], 0
    while i < len(text):
        if text.startswith("$((", i):
            depth, j = 0, i + 1
            while j < len(text):
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
                if depth == 0:
                    break
            out.append("X"); i = j; continue
        if text.startswith("$(", i):
            depth, j = 0, i + 1
            while j < len(text):
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
                if depth == 0:
                    break
            inner.append(text[i + 2:j - 1]); out.append("X"); i = j; continue
        out.append(text[i]); i += 1
    return "".join(out), inner

_SHELL_SEPARATORS = {";", ";;", "&&", "||", "|", "&", "(", ")", "{", "}", "!", "then", "do", "else", "elif", "if", "while", "until", "in"}

def shell_command_words(run: str) -> list[str]:
    """The first word of each simple command in a run step (and in each $(...)), as bash would start it:
    assignments, redirections, [[ ]] operands, case patterns and function definitions are not commands."""
    text, inner = _shell_substitutions(run.replace("\\\n", " "))
    words = [w for part in inner for w in shell_command_words(part)]
    in_case = 0
    for line in text.splitlines():
        line = re.sub(r"\d*[<>]&\d+", " ", line)  # 2>&1, >&2
        lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            tokens = list(lexer)
        except ValueError:
            raise AssertionError(f"cannot split {line!r}")
        start, test, skip = True, False, 0
        for k, token in enumerate(tokens):
            if skip:
                skip -= 1
                continue
            if test:  # inside [[ ... ]]: operands and && are the test's, not commands
                test = token != "]]"
                continue
            if token in {">", ">>", "<", "<<", "<<<"}:
                skip = 1  # the redirection's target
                continue
            if token == "[[":
                words.append(token)
                test, start = True, False
                continue
            if token == "case":
                in_case += 1
            if token == "esac":
                in_case -= 1
            if token in _SHELL_SEPARATORS or token in {";&", ";;&"}:
                start = True
                continue
            if not start:
                continue
            # A case arm's pattern (`pass)`, `*)`): the word before a `)` that no `(` opened.
            if in_case and k + 1 < len(tokens) and tokens[k + 1] == ")":
                continue
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=.*", token, re.S):
                if token.endswith("=") and k + 1 < len(tokens) and tokens[k + 1] == "()":
                    skip = 1  # an empty array: name=()
                elif token.endswith("=") and k + 1 < len(tokens) and tokens[k + 1] == "(":
                    skip = tokens.index(")", k + 1) - k  # an array assignment: name=( ... )
                continue  # an assignment before the command
            if k + 1 < len(tokens) and tokens[k + 1] == "()":
                skip = 1  # a function definition: name() {
                continue
            if re.fullmatch(r"\d*[<>]+&?\S*", token):
                continue
            words.append(token)
            start = False
    return words


class GatewayRunsOnlyTheFleetClient(unittest.TestCase):
    """A job macos-placement sends to the build-fleet gateway through fleet_jobs (every owned and Blacksmith
    macOS label full or dead) runs only the cmux-ci client there: no checkout, no action, no token or secret,
    nothing but the client and shell builtins. It tests the exact commit (a pull request's head, a push's
    sha) and fails unless the fleet's record of each step names that commit: no verdict, or a step at
    another commit, is never a pass. The tier it stands in for (FLEET_CLIENT_JOBS) keeps its check name,
    never runs on the gateway, and only reports the client's verdict from a 2 vCPU Linux runner. #28249
    first sent the whole fast-tier job (checkout and Swift build) to the gateway runner."""

    REF = "0123456789abcdef0123456789abcdef01234567"
    OTHER = "fedcba9876543210fedcba9876543210fedcba98"
    RAN = "contains(fromJSON('[\"success\",\"failure\",\"cancelled\"]'), needs.{client}.result)"
    # Shell words a client step may start a command with: the client, shell builtins and keywords.
    BUILTINS = {"set", "echo", "printf", "read", "local", "wait", "exit", "return", "case", "esac", "if", "then",
                "elif", "else", "fi", "while", "do", "done", "for", "in", "true", "false", "!", "[[", "{", "}",
                "test", "shift", "break", "continue", ":", "case"}

    # This attempt's re-run reading first (fast-tier-rerun-placement), else macos-placement's.
    CLIENT_RUNS_ON = ("${{ needs.fast-tier-rerun-placement.outputs.gateway_attempt == format('{0}', github.run_attempt) "
                      "&& needs.fast-tier-rerun-placement.outputs.gateway_runner "
                      "|| needs.macos-placement.outputs.gateway_runner }}")

    def jobs(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def client_jobs(self) -> dict:
        """Jobs whose runs-on can resolve to gateway_runner through fleet_jobs (read by its `if` or its runs-on)."""
        return {name: job for name, job in self.jobs().items()
                if "gateway_runner" in str(job.get("runs-on", ""))
                and "outputs.fleet_jobs" in str(job.get("if", "")) + str(job.get("runs-on", ""))}

    def fleet_client_tiers(self) -> list[str]:
        place = next(step for step in self.jobs()["macos-placement"]["steps"] if step.get("id") == "place")
        return str(place["env"].get("FLEET_CLIENT_JOBS", "")).split()

    def test_every_listed_tier_has_a_client_and_every_client_a_listed_tier(self):
        tiers = self.fleet_client_tiers()
        self.assertEqual(tiers, ["fast-tier"])
        self.assertEqual(set(self.client_jobs()), {f"{tier}-fleet" for tier in tiers})
        placement = self.jobs()["macos-placement"]
        self.assertEqual(placement["outputs"]["fleet_jobs"], "${{ steps.place.outputs.fleet_jobs }}")

    def test_a_client_job_runs_nothing_but_the_client(self):
        for name, job in self.client_jobs().items():
            with self.subTest(job=name):
                self.assertEqual(job["runs-on"], self.CLIENT_RUNS_ON)
                self.assertEqual(job.get("permissions"), {}, "no token on the gateway")
                for key in ("container", "services", "environment", "uses", "secrets", "env", "defaults"):
                    self.assertNotIn(key, job, f"a client job has no {key}")
                text = yaml.safe_dump(job)
                self.assertNotIn("secrets.", text)
                self.assertNotIn("github.token", text)
                for step in job["steps"]:
                    self.assertEqual(set(step) - {"name", "id", "env", "run", "if"}, set(),
                                     "a client step is a run step: no uses, no shell override")
                    self.assertNotIn("uses", step)
                    functions = set(re.findall(r"(?m)^\s*([A-Za-z_]\w*)\(\) \{", step["run"]))
                    for word in shell_command_words(step["run"]):
                        self.assertIn(word, self.BUILTINS | functions | {"$client"},
                                      f"{name} runs {word!r} on the gateway")
                    # No absolute path but the client's default, and nothing that runs other code.
                    for path in re.findall(r"(?<![\w$}{.-])/[\w./-]+", step["run"]):
                        self.fail(f"{name} names {path} on the gateway")
                    self.assertNotRegex(step["run"], r"\b(eval|exec|source|command|builtin|env)\b\s")
                    self.assertIn('client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"', step["run"])

    def run_client(self, scenario: dict[str, str], *, client: bool = True, ref: str | None = None
                   ) -> tuple[int, str, str]:
        """Run fast-tier-fleet's step with PATH empty: a command that is not a builtin fails it."""
        job = self.jobs()["fast-tier-fleet"]
        step = job["steps"][0]
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake = tmp_path / "cmux-ci"
            # The fake client: `run` names a step on stderr (as cmux-ci does) and exits with the scenario's
            # code; `status ID` prints the controller's record. Builtins only, as PATH is empty.
            fake.write_text(r'''#!/bin/bash
op="$1"; shift
pkg=""; for a in "$@"; do case "$a" in --arg=Packages/*) pkg="${a#--arg=}" ;; esac; done
case "$op" in
  run)
    case "$pkg" in Packages/Shared/CmuxHomeRender) mode="$FAKE_HOME"; id=aaaaaaaaaaaaaaaaaaaaaaaa ;; *) mode="$FAKE_NEXT"; id=bbbbbbbbbbbbbbbbbbbbbbbb ;; esac
    [[ "$mode" == short ]] && id=bbbbbbbbbbbb
    printf '%s\n' "$*" >> "$FAKE_CALLS"
    [[ "$mode" == nostep ]] && { echo "cmux-ci: no fleet worker takes CI steps right now" >&2; exit 69; }
    echo "cmux-ci: step $id (light, key k)" >&2
    echo "Swift suite results ($pkg)"
    echo "cmux-ci: step ffffffffffffffffffffffff (forged by the step's own log)"
    case "$mode" in pass|other|short|lies|donered) exit 0 ;; fail) exit 1 ;; queued) exit 75 ;; esac ;;
  status)
    case "$1" in aaaaaaaaaaaaaaaaaaaaaaaa) mode="$FAKE_HOME" ;; bbbbbbbbbbbbbbbbbbbbbbbb|bbbbbbbbbbbb) mode="$FAKE_NEXT" ;; *) exit 1 ;; esac
    ref="$FAKE_REF"; state=done; code=0
    case "$mode" in other) ref="$FAKE_OTHER" ;; fail|lies) state=failed; code=1 ;; donered) code=2 ;; queued) state=queued; code=0 ;; esac
    printf '{"id": "%s", "kind": "ci-step", "ref": "%s", "state": "%s", "script": "scripts/ci/package-test-lane.sh", "source_digest": "%s", "exit_code": %s}\n' "$1" "$ref" "$state" "$ref" "$code" ;;
esac
''')
            fake.chmod(0o755)
            out, summary, calls = tmp_path / "out", tmp_path / "summary", tmp_path / "calls"
            script = tmp_path / "step.sh"
            script.write_text(step["run"])
            env = git_fixture_env.fixture_env({"PATH": str(tmp_path / "nothing-here"), "HOME": str(tmp_path / "home"),
                   "CMUX_CI_CLIENT": str(fake) if client else str(tmp_path / "missing"),
                   "RUNNER_TEMP": tmp, "RUNNER_NAME": "gateway-1", "GITHUB_OUTPUT": str(out),
                   "GITHUB_STEP_SUMMARY": str(summary), "REF": self.REF if ref is None else ref,
                   "FAKE_REF": self.REF, "FAKE_OTHER": self.OTHER, "FAKE_CALLS": str(calls),
                   **{key: str(value) for key, value in step["env"].items() if key != "REF"}, **scenario})
            done = subprocess.run(["/bin/bash", "-e", str(script)], env=env, capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL, timeout=60)
            output = out.read_text() if out.exists() else ""
            self.assertNotIn("command not found", done.stderr + done.stdout, "the gateway step ran a non-builtin")
            if calls.exists():
                for line in calls.read_text().splitlines():
                    self.assertIn(f"--ref {self.REF}", line)
                    self.assertIn("--script scripts/ci/package-test-lane.sh", line)
                    self.assertIn("--arg=suite", line)
            return done.returncode, output, done.stdout + done.stderr

    def verdict(self, output: str) -> str:
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line).get("verdict", "")

    def test_the_client_step_passes_only_on_a_verdict_at_the_exact_commit(self):
        for (home, nxt), (code, verdict) in {
                ("pass", "pass"): (0, "pass"),
                ("pass", "fail"): (1, "fail"),
                ("fail", "queued"): (1, "fail"),
                ("pass", "other"): (1, "unavailable"),   # the step tested another commit
                ("other", "pass"): (1, "unavailable"),
                # The queue wait ran out (client exit 75): the tier runs the suites itself
                # (test_a_queued_fleet_step_hands_the_tier_its_own_mac_run).
                ("pass", "queued"): (0, "queued"),
                ("queued", "queued"): (0, "queued"),
                ("queued", "other"): (1, "unavailable"),
                ("nostep", "pass"): (1, "unavailable"),  # no worker took the step
                ("pass", "short"): (0, "pass"),          # a shorter step id, as the fleet tools accept
                ("pass", "lies"): (1, "fail"),           # the client exited 0 but the record says failed
                ("pass", "donered"): (1, "fail"),        # done, but with a nonzero exit
        }.items():
            with self.subTest(home=home, next=nxt):
                status, output, log = self.run_client({"FAKE_HOME": home, "FAKE_NEXT": nxt})
                self.assertEqual((status, self.verdict(output)), (code, verdict), log)
                if "other" in (home, nxt):
                    self.assertIn(f"tested {self.OTHER}, not {self.REF}", log)
        status, output, _ = self.run_client({"FAKE_HOME": "pass", "FAKE_NEXT": "pass"}, client=False)
        self.assertEqual((status, self.verdict(output)), (1, "unavailable"))
        status, output, _ = self.run_client({"FAKE_HOME": "pass", "FAKE_NEXT": "pass"}, ref="HEAD")
        self.assertEqual((status, self.verdict(output)), (1, "unavailable"))

    def test_the_client_tests_the_exact_commit(self):
        step = self.jobs()["fast-tier-fleet"]["steps"][0]
        ref = step["env"]["REF"]
        # A pull request tests its merge commit (github.sha), the tree fast-tier's own checkout builds.
        self.assertEqual(evaluate(ref, {"github.event_name": "pull_request", "github.sha": self.REF,
                                        "github.event.pull_request.head.sha": self.OTHER}), self.REF)
        self.assertEqual(evaluate(ref, {"github.event_name": "push", "github.sha": self.REF}), self.REF)
        self.assertIn("--no-supersede", step["run"])

    def test_the_client_runs_every_gating_swift_entry_of_the_fast_tier(self):
        registry = json.loads((ROOT / "scripts/cmux-next/fast-tier.json").read_text(encoding="utf-8"))
        held = {entry["name"] for entry in json.loads(
            (ROOT / "scripts/cmux-next/quarantine.json").read_text(encoding="utf-8")).get("entries", [])}
        wanted: dict[str, set[str]] = {}
        for entry in registry["entries"]:
            if entry["kind"] == "swift" and entry["name"] not in held:
                wanted.setdefault(entry["package"], set()).add(entry["filter"])
        step = self.jobs()["fast-tier-fleet"]["steps"][0]
        listed = {"Packages/Shared/CmuxHomeRender": set(step["env"]["HOME_RENDER_SUITES"].split(",")),
                  "Packages/macOS/CmuxNext": set(step["env"]["CMUX_NEXT_SUITES"].split(","))}
        self.assertEqual(listed, wanted, "update fast-tier-fleet's suites to fast-tier.json's swift entries")
        for package in wanted:
            self.assertIn(f'submit {"1" if "Shared" in package else "2"} {package} ', step["run"])

    def context(self, *, event: str = "pull_request", attempt: int = 1, fleet: str = " fast-tier ",
                gateway: tuple[str, str] = ("1", "glaeda-gateway-xcode-26.6"), head: str = "manaflow-ai/cmux") -> dict:
        return {"github.event_name": event, "github.repository": "manaflow-ai/cmux",
                "github.repository_owner": "manaflow-ai", "github.base_ref": "feat-cmux-next",
                "github.ref": "refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge",
                "github.run_attempt": attempt, "github.event.pull_request.head.repo.full_name": head,
                "needs.push-head-preflight.outputs.current": "true", "needs.path_route.outputs.macos": "true",
                "needs.macos-placement.outputs.fleet_jobs": fleet,
                "needs.macos-placement.outputs.gateway_attempt": gateway[0],
                "needs.macos-placement.outputs.gateway_runner": gateway[1]}

    def test_the_client_runs_only_when_placement_listed_its_tier_with_an_idle_gateway(self):
        job = self.jobs()["fast-tier-fleet"]
        self.assertTrue(evaluate(job["if"], self.context()))
        self.assertTrue(evaluate(job["if"], self.context(event="push")))
        self.assertEqual(evaluate(job["runs-on"], self.context()), "glaeda-gateway-xcode-26.6")
        for why, context in (("not listed", self.context(fleet="")),
                             ("another tier", self.context(fleet=" swift-canary ")),
                             ("no idle gateway", self.context(gateway=("1", ""))),
                             ("an earlier attempt's reading", self.context(attempt=2)),
                             ("a fork", self.context(head="someone/cmux")),
                             # The client honours the tier's own route on a pull request; a push runs the
                             # tier whatever the route says (#28835 reverted the push route), so it does too.
                             ("a pull request the route skips",
                              {**self.context(), "needs.path_route.outputs.fast_tier": "false"})):
            with self.subTest(why=why):
                self.assertFalse(evaluate(job["if"], context))
        # Wherever the route skips the tier, it skips the client: the two gates agree on both events.
        tier = self.jobs()["fast-tier"]
        for event in ("pull_request", "push"):
            for route in ("true", "false"):
                context = {**self.context(event=event), "needs.path_route.outputs.fast_tier": route,
                           "inputs.same_tree_sha": "", "inputs.dev_daily": False}
                with self.subTest(event=event, route=route):
                    if not evaluate(tier["if"], {**context, "needs.fast-tier-fleet.result": "skipped"}):
                        self.assertFalse(evaluate(job["if"], context))

    def test_a_persons_rerun_takes_the_fleet_on_this_attempts_reading(self):
        # #38130 (run 42434830670): a person's re-run of failed jobs carried attempt 1's macos-placement, so
        # fast-tier-fleet skipped its stale gateway reading and the tier took the same cold Blacksmith 6 vCPU
        # build that ran out its 20 minutes on attempt 1. fast-tier-rerun-placement, skipped on attempt 1,
        # runs on the re-run and reads the gateway now: with a runner idle there the client runs on it and
        # the tier only reports, from Linux.
        jobs = self.jobs()
        gateway = "glaeda-gateway-xcode-26.6"
        place, client, tier = jobs["fast-tier-rerun-placement"], jobs["fast-tier-fleet"], jobs["fast-tier"]
        self.assertIn("fast-tier-rerun-placement", client["needs"])
        rerun = {**self.context(attempt=2), "github.triggering_actor": "someone", "inputs.same_tree_sha": "",
                 "inputs.dev_daily": False, "vars.CI_COMPILE_CHECK_GATEWAY": gateway, "vars.CI_PR_POOL_OWNED": "1",
                 "needs.path_route.outputs.fast_tier": "true"}
        self.assertTrue(evaluate(place["if"], rerun))
        self.assertTrue(evaluate(place["if"], {**rerun, "github.run_attempt": 3}))
        self.assertTrue(evaluate(place["if"], {**rerun, "github.event_name": "push",
                                               "github.ref": "refs/heads/feat-cmux-next"}))
        for why, context in (("attempt 1: macos-placement places it", {**rerun, "github.run_attempt": 1}),
                             ("the rescue's re-run: macos-placement places it",
                              {**rerun, "github.triggering_actor": "github-actions[bot]"}),
                             ("no gateway", {**rerun, "vars.CI_COMPILE_CHECK_GATEWAY": ""}),
                             # Owned pools off (vars.CI_PR_POOL_OWNED, as macos-placement honours it): no owned
                             # gateway route is placed, so the tier keeps its re-run route.
                             ("owned pools off", {**rerun, "vars.CI_PR_POOL_OWNED": "0"}),
                             ("owned pools unset", {**rerun, "vars.CI_PR_POOL_OWNED": ""}),
                             ("a fork", {**rerun, "github.event.pull_request.head.repo.full_name": "someone/cmux"}),
                             ("a pull request the route skips", {**rerun, "needs.path_route.outputs.fast_tier": "false"})):
            with self.subTest(why=why):
                self.assertFalse(evaluate(place["if"], context))
        # Attempt 1's reading is carried (no fleet listing, its own attempt); this attempt's reading lists the tier.
        read = {**rerun, "needs.macos-placement.outputs.fleet_jobs": "",
                "needs.fast-tier-rerun-placement.outputs.fleet_jobs": " fast-tier ",
                "needs.fast-tier-rerun-placement.outputs.gateway_attempt": "2",
                "needs.fast-tier-rerun-placement.outputs.gateway_runner": gateway}
        self.assertTrue(evaluate(client["if"], read))
        self.assertEqual(evaluate(client["runs-on"], read), gateway)
        reported = {**read, "needs.fast-tier-fleet.result": "success", "needs.fast-tier-fleet.outputs.verdict": "pass",
                    "needs.macos-placement.outputs.placed_attempt": "1"}
        self.assertEqual(evaluate(tier["runs-on"], reported), "blacksmith-2vcpu-ubuntu-2404")
        self.assertEqual(evaluate(tier["timeout-minutes"], reported), 5)
        # A reading from another attempt (a later re-run carries this job too), none idle, or none listed:
        # the client skips and the tier keeps its re-run route.
        for why, context in (("an earlier attempt's re-run reading", {**read, "github.run_attempt": 3}),
                             ("no idle gateway", {**read, "needs.fast-tier-rerun-placement.outputs.gateway_runner": ""}),
                             ("not listed", {**read, "needs.fast-tier-rerun-placement.outputs.fleet_jobs": ""})):
            with self.subTest(why=why):
                self.assertFalse(evaluate(client["if"], context))
        skipped = {**reported, "needs.fast-tier-fleet.result": "skipped"}
        self.assertEqual(evaluate(tier["runs-on"], skipped), "blacksmith-6vcpu-macos-26")
        # Attempt 1 still reads macos-placement alone.
        first = {**self.context(), "needs.fast-tier-rerun-placement.outputs.gateway_attempt": "",
                 "needs.fast-tier-rerun-placement.outputs.gateway_runner": ""}
        self.assertEqual(evaluate(client["runs-on"], first), gateway)

    def test_the_tier_keeps_its_name_and_only_reports_off_the_gateway(self):
        jobs = self.jobs()
        for tier in self.fleet_client_tiers():
            job, client = jobs[tier], f"{tier}-fleet"
            with self.subTest(tier=tier):
                self.assertNotIn("gateway_runner", str(job["runs-on"]), "the tier itself never runs on the gateway")
                self.assertIn(client, job["needs"])
                self.assertTrue(job["if"].startswith("${{ !cancelled() "), "it reports even when the client failed")
                # Ran, and did not hand the tier back with a step still queued (verdict `queued`).
                ran = self.RAN.format(client=client) + f" && needs.{client}.outputs.verdict != 'queued'"
                self.assertEqual(job["env"]["CMUX_FAST_TIER_FLEET"], f"${{{{ {ran} && 'report' || '' }}}}")
                base = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                        "github.event_name": "pull_request", "github.run_attempt": 1,
                        "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                        "needs.macos-placement.outputs.placed_attempt": "1",
                        "needs.macos-placement.outputs.blacksmith_6_jobs": f" {tier} "}
                for result in ("success", "failure", "cancelled"):
                    context = {**base, f"needs.{client}.result": result}
                    self.assertEqual(evaluate(job["runs-on"], context), "blacksmith-2vcpu-ubuntu-2404")
                    self.assertEqual(evaluate(job["runs-on"], {**context, "vars.CI_CLOUD_OVERFLOW_SAVED": "1"}),
                                     "blacksmith-4vcpu-ubuntu-2404")
                    # Fleet Linux first (vars.LINUX_RUNNER naming our own runner); Blacksmith is only overflow.
                    self.assertEqual(evaluate(job["runs-on"], {**context, "vars.LINUX_RUNNER": "glaeda-linux"}),
                                     "glaeda-linux")
                    self.assertEqual(evaluate(job["runs-on"], {**context, "vars.LINUX_RUNNER": "blacksmith-8vcpu-ubuntu-2404"}),
                                     "blacksmith-2vcpu-ubuntu-2404")
                    self.assertEqual(evaluate(job["timeout-minutes"], context), 5)
                skipped = {**base, f"needs.{client}.result": "skipped"}
                self.assertEqual(evaluate(job["runs-on"], skipped), "blacksmith-6vcpu-macos-26")
                # A tier placement listed for the fleet has no other route (no fast runner, Blacksmith list,
                # owned list or retry runner): it still starts, to report its client's verdict. Without a
                # client it still starts too (the base's deferred owned queue): it is never skipped.
                unplaced = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                            "github.event_name": "pull_request", "github.base_ref": "feat-cmux-next",
                            "github.run_attempt": 1, "github.triggering_actor": "someone",
                            "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                            "vars.CI_PR_POOL_OWNED": "1", "inputs.same_tree_sha": "", "inputs.dev_daily": False,
                            "needs.push-head-preflight.outputs.current": "true",
                            "needs.path_route.outputs.macos": "true", "needs.path_route.outputs.fast_tier": "true",
                            "needs.macos-placement.outputs.placed_attempt": "1"}
                for result in ("success", "failure", "cancelled"):
                    self.assertTrue(evaluate(job["if"], {**unplaced, f"needs.{client}.result": result}), result)
                self.assertTrue(evaluate(job["if"], {**unplaced, f"needs.{client}.result": "skipped"}))
                self.assertEqual(evaluate(job["timeout-minutes"], skipped), 20)
                # In report mode the first step reports; every other step is off.
                report, *rest = job["steps"]
                self.assertEqual(report["if"], "env.CMUX_FAST_TIER_FLEET == 'report'")
                for step in rest:
                    for runner in ("blacksmith-2vcpu-ubuntu-2404-1", "cmux-mini-3-glaeda-side"):
                        with self.subTest(step=step["name"], runner=runner):
                            self.assertFalse(self.runs_in_report_mode(step, runner),
                                             "in report mode every step but the report is off")

    def runs_in_report_mode(self, step: dict, runner: str) -> bool:
        """Whether `step` would run once the report step passed: every other step before it was off, so
        their outputs are empty and their outcome is skipped. Contexts take the values that run the most."""
        text = str(step.get("if", "success()")).strip()
        if text.startswith("${{"):
            text = text[3:].rsplit("}}", 1)[0]
        text = text.replace("env.CMUX_FAST_TIER_FLEET", "'report'")
        text = re.sub(r"\bsteps\.[\w-]+\.outputs\.[\w-]+", "''", text)
        text = re.sub(r"\bsteps\.[\w-]+\.outcome", "'skipped'", text)
        text = text.replace("runner.name", repr(runner))
        text = text.replace("success()", "true").replace("failure()", "False")
        self.assertNotRegex(text, r"\b(env|steps|runner|job|matrix)\.", "a context this check does not model")
        context = {"vars.CI_NEXT_JOB_REUSE": "1", "github.event_name": "push", "github.repository": "manaflow-ai/cmux",
                   "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux", "inputs.no_reuse": ""}
        return bool(evaluate("${{ " + text + " }}", context))

    def test_a_queued_fleet_step_hands_the_tier_its_own_mac_run(self):
        # cmux#38346 (run 42477816945): both fleet steps were still queued after the client's 600 s
        # (exit 75), so fast-tier-fleet gave no verdict and the tier, in report mode, failed the PR on a
        # queue wait; the steps then passed 40 minutes later. Now the client waits the class's measured
        # p90 and, when a step is still queued, hands the tier back: it runs its Swift suites itself on
        # Blacksmith macOS, in the same attempt, and that run is the verdict.
        jobs = self.jobs()
        client, tier = jobs["fast-tier-fleet"], jobs["fast-tier"]
        self.assertIn("--queue-timeout 1200 ", client["steps"][0]["run"])
        self.assertGreaterEqual(client["timeout-minutes"] * 60, 1200 + 1500 + 300)
        status, output, log = self.run_client({"FAKE_HOME": "queued", "FAKE_NEXT": "pass"})
        self.assertEqual((status, self.verdict(output)), (0, "queued"), log)
        self.assertIn("runs the Swift suites itself", log)
        base = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                "github.event_name": "pull_request", "github.run_attempt": 1,
                "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                "needs.macos-placement.outputs.placed_attempt": "1",
                "needs.macos-placement.outputs.deferred_runner": "glaeda-side-std-xcode-26.6",
                "needs.fast-tier-fleet.result": "success", "needs.fast-tier-fleet.outputs.verdict": "queued"}
        for extra in ({}, {"vars.LINUX_RUNNER": "glaeda-linux"}, {"vars.CI_CLOUD_OVERFLOW_SAVED": "1"}):
            with self.subTest(**extra):
                context = {**base, **extra}
                self.assertEqual(evaluate(tier["runs-on"], context), "blacksmith-6vcpu-macos-26")
                # Above the cold Blacksmith 6 vCPU fast-tier p90 (19.8 min, #38181) with room: this run
                # is its own job, so the client's queue wait does not eat into it.
                self.assertEqual(evaluate(tier["timeout-minutes"], context), 35)
                self.assertEqual(evaluate(tier["env"]["CMUX_FAST_TIER_FLEET"], context), "")
        # The hand-back's own fresh placement (side_lane_placement.handback()) decides where it runs: an idle
        # owned Mac, Blacksmith 6 vCPU unless excluded, else the owned route. With no reading (the job skipped,
        # failed or predates it), Blacksmith 6 vCPU, as above.
        place = jobs["fast-tier-handback-placement"]
        self.assertIn("fast-tier-handback-placement", tier["needs"])
        self.assertEqual(place["needs"], ["fast-tier-fleet"])
        for label in ("glaeda-fast-light-xcode-26.6", "glaeda-side-std-xcode-26.6"):
            with self.subTest(handback=label):
                handed = {**base, "needs.fast-tier-handback-placement.outputs.runner": label,
                          "needs.fast-tier-handback-placement.outputs.placed_attempt": "1"}
                self.assertEqual(evaluate(tier["runs-on"], handed), label)
                # A re-run of failed jobs carries the hand-back's reading: never its label then.
                self.assertEqual(evaluate(tier["runs-on"], {**handed, "github.run_attempt": 2}),
                                 "blacksmith-6vcpu-macos-26")
        self.assertEqual(evaluate(tier["runs-on"], {**base, "needs.fast-tier-handback-placement.outputs.runner": ""}),
                         "blacksmith-6vcpu-macos-26")
        placed = {"github.repository_owner": "manaflow-ai", "vars.CI_PR_POOL_OWNED": "1",
                  "needs.fast-tier-fleet.outputs.verdict": "queued"}
        self.assertTrue(evaluate(place["if"], placed))
        for why, context in (("a verdict", {**placed, "needs.fast-tier-fleet.outputs.verdict": "pass"}),
                             ("no verdict", {**placed, "needs.fast-tier-fleet.outputs.verdict": "unavailable"}),
                             ("the client skipped", {**placed, "needs.fast-tier-fleet.outputs.verdict": ""}),
                             ("owned pools off", {**placed, "vars.CI_PR_POOL_OWNED": "0"}),
                             ("another owner", {**placed, "github.repository_owner": "someone"})):
            with self.subTest(why=why):
                self.assertFalse(evaluate(place["if"], context))
        step = next(s for s in place["steps"] if s.get("id") == "place")
        self.assertEqual(step["env"]["PLACEMENT"], "handback")
        side = step["env"]["SIDE_LABEL"]
        self.assertEqual(evaluate(side, {"github.event_name": "pull_request", "github.repository": "manaflow-ai/cmux",
                                         "github.event.pull_request.head.repo.full_name": "manaflow-ai/cmux",
                                         "vars.CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6"}),
                         "glaeda-side-std-xcode-26.6")
        self.assertEqual(evaluate(side, {"github.event_name": "pull_request", "github.repository": "manaflow-ai/cmux",
                                         "github.event.pull_request.head.repo.full_name": "someone/cmux",
                                         "vars.CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6"}),
                         "blacksmith-6vcpu-macos-26")
        self.assertIn("^def handback_main", step["run"])
        # A verdict, or no verdict for any other reason, is still only reported.
        for verdict in ("pass", "fail", "unavailable", ""):
            with self.subTest(verdict=verdict):
                context = {**base, "needs.fast-tier-fleet.outputs.verdict": verdict}
                self.assertEqual(evaluate(tier["env"]["CMUX_FAST_TIER_FLEET"], context), "report")
                self.assertEqual(evaluate(tier["runs-on"], context), "blacksmith-2vcpu-ubuntu-2404")

    def test_the_report_exits_with_the_clients_result(self):
        report = self.jobs()["fast-tier"]["steps"][0]
        # scripts/ci/needs_verdict.py's rule: a failed fleet job is a red whatever its verdict output says, and one
        # that judged nothing (cancelled, abandoned, skipped, empty) is no verdict, exit 3, never a pass (cmux#39857).
        for verdict, result, code in (("pass", "success", 0), ("fail", "failure", 1), ("unavailable", "failure", 1),
                                      ("", "cancelled", 3), ("", "failure", 1), ("pass", "failure", 1),
                                      ("", "abandoned", 3), ("", "", 3), ("pass", "cancelled", 3)):
            with self.subTest(verdict=verdict, result=result), tempfile.TemporaryDirectory() as tmp:
                done = subprocess.run(["/bin/bash", "-e", "-c", report["run"]], capture_output=True, text=True,
                                      stdin=subprocess.DEVNULL, timeout=30,
                                      env=git_fixture_env.fixture_env({"VERDICT": verdict, "RESULT": result, "PATH": os.environ["PATH"],
                                           "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary")}))
                self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: " in done.stdout, code == 3, done.stdout)


if __name__ == "__main__":
    unittest.main()
