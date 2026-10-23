#!/usr/bin/env python3
"""Every tests/test_*.py runs on a pull request lane, or is a reviewed exemption.

The registry validator accepted a linux-guard test that any workflow named.
tests/test_webviews_tests_per_file.py was named only by web-validation.yml's
main-push job and the nightly car guards, so a2d6b35 broke it on feat-cmux-next
and every pull request stayed green until #23430. `--pr-lanes BRANCH` reads the
workflows as a pull request into BRANCH runs them (scripts/ci/pr_test_lanes.py)
and fails on a test none of its jobs executes, unless tests/pr-lane-exemptions.json
lists it with a reason.

    python3 tests/test_pr_lane_coverage.py

Needs PyYAML (the Linux runners and the guard venv have it).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
spec = importlib.util.spec_from_file_location(
    "validate_test_execution_registry", ROOT / "scripts" / "ci" / "validate_test_execution_registry.py"
)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)

BRANCH = "feat-cmux-next"
FEAT_PULL_REQUEST = "on:\n  pull_request:\n    branches: [feat-cmux-next]\n"


def job(run: str, condition: str = "", needs: str = "") -> str:
    lines = ["  check:\n", "    runs-on: ubuntu-24.04\n"]
    if needs:
        lines.append(f"    needs: [{needs}]\n")
    if condition:
        lines.append(f"    if: {condition}\n")
    lines.append(f"    steps:\n      - run: {run}\n")
    return "".join(lines)


class Tree:
    """A throwaway repository: workflows, tests, the registry and the exemption list."""

    def __init__(self, tests: list[str], workflows: dict[str, str], exemptions: list[dict] | None = None,
                 lanes: dict[str, str] | None = None):
        self.temporary = tempfile.TemporaryDirectory(prefix="pr-lanes-")
        self.root = Path(self.temporary.name)
        (self.root / ".github" / "workflows").mkdir(parents=True)
        (self.root / "tests").mkdir()
        for name, text in workflows.items():
            (self.root / ".github" / "workflows" / name).write_text(text, encoding="utf-8")
        registry = ["version = 1\n"]
        for test in tests:
            (self.root / test).write_text("", encoding="utf-8")
            lane = (lanes or {}).get(test, "linux-guard")
            registry.append(f'\n[[test]]\npath = "{test}"\nlane = "{lane}"\n')
            if lane == "manual":
                registry.append('reason = "needs a GUI session"\n')
        (self.root / "tests" / "test-execution.toml").write_text("".join(registry), encoding="utf-8")
        if exemptions is not None:
            (self.root / "tests" / "pr-lane-exemptions.json").write_text(
                json.dumps({"exemptions": exemptions}), encoding="utf-8"
            )

    def errors(self) -> list[str]:
        return validator.validate_pr_lanes(self.root, BRANCH)

    def close(self) -> None:
        self.temporary.cleanup()


class PullRequestLanes(unittest.TestCase):
    def check(self, workflows: dict[str, str], unrun: list[str], **kwargs) -> list[str]:
        tests = kwargs.pop("tests", ["tests/test_a.py"])
        tree = Tree(tests, workflows, **kwargs)
        self.addCleanup(tree.close)
        errors = tree.errors()
        flagged = sorted({error.split(":", 1)[0] for error in errors if error.startswith("tests/test_")})
        self.assertEqual(flagged, sorted(unrun), "\n".join(errors))
        return errors

    def test_a_job_a_feat_pull_request_runs_counts(self):
        self.check({"next.yml": FEAT_PULL_REQUEST + "jobs:\n" + job("python3 tests/test_a.py")}, [])

    def test_a_main_push_job_does_not_count(self):
        # web-validation.yml: a pull_request trigger, but its jobs skip pull requests.
        workflow = (
            "on:\n  pull_request:\n  push:\n    branches: [main]\njobs:\n"
            + job("python3 tests/test_a.py", "${{ github.event_name != 'pull_request' && github.event_name != 'merge_group' }}")
        )
        self.check({"web-validation.yml": workflow}, ["tests/test_a.py"])

    def test_a_job_that_skips_feat_pull_requests_does_not_count(self):
        workflow = "on:\n  pull_request:\njobs:\n" + job(
            "python3 tests/test_a.py",
            "${{ github.event_name != 'pull_request' || github.event.pull_request.base.ref != 'feat-cmux-next' }}",
        )
        self.check({"ci.yml": workflow}, ["tests/test_a.py"])

    def test_a_job_after_a_skipped_job_does_not_count(self):
        workflow = (
            "on:\n  pull_request:\njobs:\n"
            "  gate:\n    if: github.event_name == 'push'\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n"
            + job("python3 tests/test_a.py", needs="gate")
        )
        self.check({"ci.yml": workflow}, ["tests/test_a.py"])

    def test_a_label_only_job_does_not_count(self):
        workflow = FEAT_PULL_REQUEST + "jobs:\n" + job(
            "python3 tests/test_a.py", "contains(github.event.pull_request.labels.*.name, 'motion-golden')"
        )
        self.check({"golden.yml": workflow}, ["tests/test_a.py"])

    def test_an_unknown_condition_counts(self):
        workflow = FEAT_PULL_REQUEST + "jobs:\n" + job(
            "python3 tests/test_a.py", "${{ needs.changes.outputs.web == 'true' && vars.LANE == '1' }}"
        )
        self.check({"web.yml": workflow}, [])

    def test_other_branches_schedules_and_path_filters_do_not_count(self):
        workflows = {
            "main.yml": "on:\n  pull_request:\n    branches: [main]\njobs:\n" + job("python3 tests/test_a.py"),
            "ignored.yml": "on:\n  pull_request:\n    branches-ignore: [feat-cmux-next]\njobs:\n" + job("python3 tests/test_a.py"),
            "nightly.yml": "on:\n  schedule:\n    - cron: '7 * * * *'\njobs:\n" + job("python3 tests/test_a.py"),
            # r2-upload-tests.yml named tests/test_r2_upload_requests.py only in its paths filter.
            "paths.yml": "on:\n  pull_request:\n    paths:\n      - tests/test_a.py\njobs:\n" + job("true"),
        }
        self.check(workflows, ["tests/test_a.py"])

    def test_a_reusable_workflow_runs_only_the_groups_its_caller_passes(self):
        caller = FEAT_PULL_REQUEST + textwrap.dedent("""\
            jobs:
              guards:
                uses: ./.github/workflows/guards.yml
                with:
                  groups: '["release-notary"]'
                  history: ${{ 'false' }}
            """)
        callee = textwrap.dedent("""\
            on:
              workflow_call:
                inputs:
                  groups: {type: string, required: true}
                  history: {type: string, required: true}
            jobs:
              tests:
                strategy:
                  matrix:
                    group: ${{ fromJSON(inputs.groups) }}
                runs-on: ubuntu-24.04
                steps:
                  - if: ${{ !cancelled() && matrix.group == 'release-notary' }}
                    run: python3 tests/test_a.py
                  - if: ${{ !cancelled() && matrix.group == 'preflight' }}
                    run: python3 tests/test_b.py
              history:
                if: ${{ inputs.history == 'true' }}
                runs-on: ubuntu-24.04
                steps:
                  - run: python3 tests/test_c.py
            """)
        self.check({"next-guards.yml": caller, "guards.yml": callee}, ["tests/test_b.py", "tests/test_c.py"],
                   tests=["tests/test_a.py", "tests/test_b.py", "tests/test_c.py"])

    def test_a_runner_lane_counts_where_a_pull_request_job_invokes_it(self):
        workflow = FEAT_PULL_REQUEST + "jobs:\n" + job("python3 scripts/ci/run_python_test_lane.py --lane macos-shell")
        self.check({"mac.yml": workflow}, ["tests/test_b.py"], tests=["tests/test_a.py", "tests/test_b.py"],
                   lanes={"tests/test_a.py": "macos-shell", "tests/test_b.py": "macos-cli-no-socket"})

    def test_manual_tests_and_reviewed_exemptions_pass(self):
        exemptions = [{"reason": "the classic app's Mac lanes", "tests": ["tests/test_b.py"]}]
        self.check({}, [], tests=["tests/test_a.py", "tests/test_b.py"], exemptions=exemptions,
                   lanes={"tests/test_a.py": "manual"})

    def test_an_exemption_needs_a_reason_and_goes_once_the_test_runs(self):
        workflows = {"next.yml": FEAT_PULL_REQUEST + "jobs:\n" + job("python3 tests/test_a.py")}
        exemptions = [
            {"reason": "was unrouted", "tests": ["tests/test_a.py"]},
            {"reason": "", "tests": ["tests/test_b.py"]},
            {"reason": "deleted", "tests": ["tests/test_gone.py"]},
        ]
        errors = self.check(workflows, ["tests/test_a.py", "tests/test_b.py"],
                            tests=["tests/test_a.py", "tests/test_b.py"], exemptions=exemptions)
        self.assertTrue(any("exemption 2 needs a reason" in error for error in errors), errors)
        self.assertTrue(any("tests/test_gone.py does not exist" in error for error in errors), errors)
        self.assertTrue(any(error.startswith("tests/test_a.py: a pull request into") for error in errors), errors)

    def test_the_feat_routed_guard_groups_count_and_the_main_only_ones_do_not(self):
        """cmux-next-guards.yml runs ci-guards.yml's groups routed by the change's paths
        (`guards-local.sh --feat-routes FILE`, detect_linux_guard_changes.classify_feat). Any routed group
        may run, so its tests count; release-ios, which guards main's iOS release path, never does."""
        caller = FEAT_PULL_REQUEST + "jobs:\n" + job(
            'scripts/ci/guards-local.sh --no-stamp --keep-going --feat-routes "$RUNNER_TEMP/changed.txt"'
        )
        guards = textwrap.dedent("""\
            on:
              workflow_call:
                inputs:
                  linux_guard_test_groups: {type: string, required: true}
                  linux_guard_history: {type: string, required: true}
            jobs:
              workflow-guard-tests:
                strategy:
                  matrix:
                    group: ${{ fromJSON(inputs.linux_guard_test_groups) }}
                runs-on: ubuntu-24.04
                steps:
                  - name: ci guard
                    if: ${{ !cancelled() && matrix.group == 'ci' }}
                    run: python3 tests/test_a.py
                  - name: preflight guard
                    if: ${{ !cancelled() && matrix.group == 'preflight' }}
                    run: python3 tests/test_b.py
                  - name: watchdog guard
                    if: ${{ !cancelled() && matrix.group == 'app-host-watchdog' }}
                    run: python3 tests/test_c.py
                  - name: release-ios guard
                    if: ${{ !cancelled() && matrix.group == 'release-ios' }}
                    run: python3 tests/test_d.py
              workflow-guard-history:
                if: ${{ inputs.linux_guard_history == 'true' }}
                runs-on: ubuntu-24.04
                steps:
                  - name: Validate SwiftPM lockfile policy
                    run: python3 tests/test_e.py
            """)
        self.check({"next-guards.yml": caller, "ci-guards.yml": guards}, ["tests/test_d.py"],
                   tests=["tests/test_a.py", "tests/test_b.py", "tests/test_c.py", "tests/test_d.py",
                          "tests/test_e.py"])


class OnlyWhatThePullRequestAdds(unittest.TestCase):
    """feat-cmux-next takes direct-pushed main syncs (18, 10 and 2 new tests in the last three) that skip pull
    request checks. A test the base already leaves unrun is a warning; only one this change leaves unrun fails."""

    def git(self, root: Path, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args],
            cwd=root, check=True, text=True, capture_output=True,
        ).stdout.strip()

    def test_a_base_gap_warns_and_a_new_one_fails(self):
        tree = Tree(["tests/test_old.py"], {"next.yml": FEAT_PULL_REQUEST + "jobs:\n" + job("true")})
        self.addCleanup(tree.close)
        root = tree.root
        self.git(root, "init", "--quiet", "-b", "feat-cmux-next")
        self.git(root, "add", "-A")
        self.git(root, "commit", "--quiet", "-m", "base")
        base = self.git(root, "rev-parse", "HEAD")
        (root / "tests" / "test_new.py").write_text("", encoding="utf-8")
        with (root / "tests" / "test-execution.toml").open("a", encoding="utf-8") as registry:
            registry.write('\n[[test]]\npath = "tests/test_new.py"\nlane = "linux-guard"\n')
        self.git(root, "add", "-A")
        self.git(root, "commit", "--quiet", "-m", "head")

        errors, warnings = validator.pr_lane_findings(root, BRANCH, base)
        self.assertEqual([error.split(":", 1)[0] for error in errors], ["tests/test_new.py"], errors)
        self.assertTrue(any(warning.startswith("tests/test_old.py:") for warning in warnings), warnings)
        self.assertFalse(any(warning.startswith("tests/test_new.py:") for warning in warnings), warnings)

    def test_without_a_base_every_gap_fails(self):
        tree = Tree(["tests/test_old.py"], {})
        self.addCleanup(tree.close)
        errors, warnings = validator.pr_lane_findings(tree.root, BRANCH, "")
        self.assertEqual([error.split(":", 1)[0] for error in errors], ["tests/test_old.py"], errors)
        self.assertEqual(warnings, [])


class ThisTree(unittest.TestCase):
    # The whole tree is judged by the tooling-tests step that runs the validator with
    # --base-sha HEAD^1: a test a direct-pushed main sync left unrun warns there instead of
    # turning every later pull request red, which an assertion here would do.

    def test_the_runner_test_runs_on_every_feat_pull_request(self):
        """a2d6b35 broke tests/test_webviews_tests_per_file.py with every pull request green (#23430)."""
        import yaml  # noqa: PLC0415

        text = validator.pr_lane_tests(ROOT, BRANCH)[0]
        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        runs = "\n".join(str(step.get("run", "")) for step in workflow["jobs"]["tooling-tests"]["steps"])
        for test in ("tests/test_webviews_tests_per_file.py", "tests/test_web_lint_prepush.py"):
            with self.subTest(test=test):
                self.assertIn(test, text)
                self.assertIn(f"python3 {test}", runs)

    def test_tests_of_feat_files_run_on_feat_pull_requests(self):
        """Tests whose code feat-cmux-next pull requests edit ran only on main, a push, a schedule, or nowhere.

        Fourteen had no registry entry; eleven more ran only from push, schedule or main-only jobs.
        Each listed here now runs from a job a feat-cmux-next pull request starts (routed by paths
        for an area job); the stdlib tests of feat CI tooling run in cmux-next guards / tooling-tests.
        """
        import yaml  # noqa: PLC0415

        text = validator.pr_lane_tests(ROOT, BRANCH)[0]
        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        tooling = "\n".join(str(step.get("run", "")) for step in workflow["jobs"]["tooling-tests"]["steps"])
        in_tooling_tests = (
            "tests/test_app_crate_licenses.py",
            "tests/test_browser_host_release_package.py",
            "tests/test_ci_macho_parity.py",
            "tests/test_ci_macos_stubs.py",
            "tests/test_ci_package_lane_prebuild.py",
            "tests/test_ci_tip_test_compile.py",
            "tests/test_cmux_next_dev_daily_notify_cli.py",
            "tests/test_cmux_next_media_publish_windows.py",
            "tests/test_compile_string_catalogs.py",
            "tests/test_install_zig_ci_reviewed_version.py",
            "tests/test_list_macho_candidates.py",
            "tests/test_normalize_pbxproj.py",
            "tests/test_publish_cmux_tui_tree.py",
            "tests/test_swiftpm_test_product.py",
            "tests/test_web_validation.py",
        )
        in_area_jobs = (
            "tests/test_cmux_bug_triage.py",
            "tests/test_cmux_code_mode_mcp.py",
            "tests/test_cmux_cua_dev_helper_identity.py",
            "tests/test_remote_daemon_notices.py",
            "tests/test_remote_daemon_release_assets.py",
            "tests/test_remote_daemon_release_verification.py",
            "tests/test_shell_claude_rereports_pwd.py",
            "tests/test_socket_control_schema.py",
            "tests/test_zsh_git_head_watch_no_fork.py",
        )
        for test in in_tooling_tests + in_area_jobs:
            with self.subTest(test=test):
                self.assertIn(f"python3 {test}", text)
        for test in in_tooling_tests:
            with self.subTest(tooling_tests=test):
                self.assertIn(f"python3 {test}", tooling)

    def test_the_guard_group_job_runs_the_feat_routed_groups_on_the_head_and_the_base(self):
        import yaml  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next-guards.yml").read_text(encoding="utf-8"))
        steps = workflow["jobs"]["ci-guard-group"]["steps"]
        runs = [str(step.get("run", "")) for step in steps]
        calls = [line for run in runs for line in run.splitlines() if "scripts/ci/guards-local.sh" in line]
        self.assertEqual(len(calls), 2, calls)
        for call in calls:
            with self.subTest(call=call):
                self.assertIn("--feat-routes", call)
        self.assertIn("--root .guard-base", calls[1])


if __name__ == "__main__":
    unittest.main()
