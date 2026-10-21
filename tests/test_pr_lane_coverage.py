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
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

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


class ThisTree(unittest.TestCase):
    def test_every_test_runs_on_a_feat_cmux_next_pull_request_or_is_exempt(self):
        errors = validator.validate_pr_lanes(ROOT, BRANCH)
        self.assertEqual(errors, [], "\n".join(errors))

    def test_the_runner_test_runs_where_the_runner_changes(self):
        """A pull request that touches run-webviews-tests.sh runs its test (a2d6b35, #23430)."""
        import web_subareas  # noqa: PLC0415

        detector_spec = importlib.util.spec_from_file_location(
            "detect_ci_change_areas", ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"
        )
        detector = importlib.util.module_from_spec(detector_spec)
        detector_spec.loader.exec_module(detector)
        self.assertIn("tests/test_webviews_tests_per_file.py", validator.pr_lane_tests(ROOT, BRANCH)[0])
        for path in ("scripts/ci/run-webviews-tests.sh", "tests/test_webviews_tests_per_file.py"):
            with self.subTest(path=path):
                # ci.yml's changes job calls ci-web.yml for a web change, and react-apps-check runs for it.
                self.assertTrue(detector.is_web_change(path))
                self.assertTrue(web_subareas.classify_paths([path], ROOT).react_apps)
        workflow = (ROOT / ".github" / "workflows" / "ci-web.yml").read_text(encoding="utf-8")
        job = workflow[workflow.index("  react-apps-check-shard:"):]
        job = job[: job.index("\n  runners:")]
        self.assertIn("python3 tests/test_webviews_tests_per_file.py", job)
        self.assertIn("../scripts/ci/run-webviews-tests.sh", job)


if __name__ == "__main__":
    unittest.main()
