#!/usr/bin/env python3
"""Regression coverage for manual iOS workflow revision resolution."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"


def job_block(name: str) -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    marker = f"  {name}:\n"
    start = text.index(marker)
    match = re.search(r"(?m)^  [A-Za-z0-9_-]+:\n", text[start + len(marker) :])
    if match is None:
        return text[start:]
    return text[start : start + len(marker) + match.start()]


class IOSWorkflowDispatchRefTests(unittest.TestCase):
    def test_requested_family_matrix_is_selected_on_linux(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        detect = jobs["detect-ios-changes"]
        self.assertIn("LINUX_RUNNER", detect["runs-on"])
        selector = next(step for step in detect["steps"] if step.get("id") == "families")
        self.assertEqual(selector["env"]["DEVICE_FAMILY"], "${{ inputs.device_family }}")
        self.assertEqual(
            detect["outputs"]["device_families"], "${{ steps.families.outputs.json }}"
        )
        self.assertEqual(jobs["ios-simulator"]["needs"], ["detect-ios-changes", "ios-simulator-build"])
        self.assertEqual(
            jobs["ios-simulator"]["strategy"]["matrix"]["family"],
            "${{ fromJSON(needs.detect-ios-changes.outputs.device_families) }}",
        )
        # Matrix membership is the admission decision. In particular, an empty
        # request must not select both families and then skip both test steps.
        simulator_steps = jobs["ios-simulator"]["steps"]
        run_tests = next(step for step in simulator_steps if step.get("name") == "Run iOS simulator tests")
        self.assertNotIn("if", run_tests)
        for step in simulator_steps:
            self.assertNotIn("inputs.device_family", step.get("if", ""))
            self.assertNotEqual(step.get("name"), "Skip unrequested family")
        for requested, expected in (
            (None, ["iphone", "ipad"]),
            ("", ["iphone", "ipad"]),
            ("both", ["iphone", "ipad"]),
            ("iphone", ["iphone"]),
            ("ipad", ["ipad"]),
            ("invalid", None),
            ('["iphone"]', None),
        ):
            with self.subTest(requested=requested), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                env = {key: value for key, value in os.environ.items() if key != "DEVICE_FAMILY"}
                env["GITHUB_OUTPUT"] = str(output)
                if requested is not None:
                    env["DEVICE_FAMILY"] = requested
                result = subprocess.run(
                    ["bash", "-e", "-c", selector["run"]],
                    env=env, capture_output=True, text=True,
                )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    key, value = output.read_text().strip().split("=", 1)
                    self.assertEqual(key, "json")
                    self.assertEqual(json.loads(value), expected)

    def test_run_name_identifies_the_requested_workload(self) -> None:
        run_name = yaml.safe_load(WORKFLOW.read_text())["run-name"]
        for field in ("ref", "test_filter", "swift_package", "device_family", "ios_version"):
            self.assertIn(f"inputs.{field}", run_name)
        self.assertIn("github.ref_name", run_name)

    def test_manual_ref_is_resolved_once_to_a_full_commit_sha(self) -> None:
        detect = job_block("detect-ios-changes")
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(
            "description: Branch, tag, full SHA, or short SHA to test",
            workflow,
        )
        self.assertIn("target_sha: ${{ steps.target.outputs.sha }}", detect)
        self.assertIn("ref: ${{ github.ref }}", detect)
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '0' || '1' }}", detect)
        self.assertIn("id: target", detect)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", detect)
        self.assertIn("REQUESTED_REF: ${{ inputs.ref }}", detect)
        self.assertIn("DEFAULT_SHA: ${{ github.sha }}", detect)
        self.assertIn(
            'f"https://api.github.com/repos/{repository}/commits/{encoded_ref}"',
            detect,
        )
        self.assertIn('urllib.parse.quote(requested_ref, safe="")', detect)
        self.assertIn('echo "sha=$target_sha" >> "$GITHUB_OUTPUT"', detect)
        self.assertIn(r'^[0-9a-f]{40}$', detect)

    def test_paid_and_downstream_jobs_checkout_only_the_resolved_sha(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        resolved_ref = "ref: ${{ needs.detect-ios-changes.outputs.target_sha }}"

        self.assertNotIn("ref: ${{ inputs.ref || github.ref", workflow)
        for job in ("package-conventions-lint", "mobile-core-package", "ios-simulator-build", "ios-simulator"):
            with self.subTest(job=job):
                self.assertIn(resolved_ref, job_block(job))

        # The routing job checks out the workflow revision itself; every other
        # checkout is pinned to the one resolved 40-character commit SHA.
        self.assertEqual(workflow.count(resolved_ref), 4)


def job_admitted(jobs, name, results, outputs, inputs, *, cancelled=False):
    """Execute the boolean job gates, including needs and implicit success().

    This intentionally supports only the boolean/context subset used by this
    workflow. Unknown syntax raises instead of silently approving a job.
    """
    def dependencies(job):
        needs = jobs[job].get("needs", [])
        return [needs] if isinstance(needs, str) else needs

    def ancestors(job):
        found = set(dependencies(job))
        for dependency in dependencies(job):
            found.update(ancestors(dependency))
        return found

    direct = dependencies(name)
    terminal = {"success", "failure", "cancelled", "skipped"}
    if any(results.get(dependency) not in terminal for dependency in direct):
        return False
    success = all(results.get(ancestor) == "success" for ancestor in ancestors(name))
    expression = jobs[name].get("if", "${{ success() }}").strip()
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    has_status_function = re.search(r"\b(?:success|failure|cancelled|always)\s*\(", expression)
    if not has_status_function and (cancelled or not success):
        return False

    def context(match):
        path = match.group(0)
        if path.startswith("needs."):
            _, dependency, *field = path.split(".")
            if dependency not in direct:
                return repr("")
            if field == ["result"]:
                return repr(results.get(dependency, ""))
            return repr(outputs.get(dependency, {}).get(field[1], ""))
        if path.startswith("inputs."):
            return repr(inputs.get(path.removeprefix("inputs."), ""))
        if path == "github.event_name":
            return repr(inputs.get("event_name", "workflow_dispatch"))
        raise AssertionError(f"Unmodeled context: {path}")

    expression = re.sub(
        r"needs\.[\w-]+\.(?:result|outputs\.[\w-]+)|inputs\.[\w-]+|github\.event_name",
        context, expression,
    )
    expression = expression.replace("success()", repr(success))
    expression = expression.replace("cancelled()", repr(cancelled))
    expression = expression.replace("always()", "True")
    expression = expression.replace("failure()", repr(any(
        results.get(ancestor) == "failure" for ancestor in ancestors(name))))
    expression = re.sub(r"!(?!=)", " not ", expression)
    return bool(eval("(" + expression.replace("&&", " and ").replace("||", " or ") + ")",
                     {"__builtins__": {}}))


class IOSNativeLintAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def admitted(self, job, *, lint="success", should_lint="true", should_run="true",
                 detect="success", producer="success", package="", test_filter="",
                 cancelled=False, event_name="workflow_dispatch"):
        return job_admitted(
            self.jobs, job,
            {"detect-ios-changes": detect, "package-conventions-lint": lint,
             "ios-simulator-build": producer},
            {"detect-ios-changes": {"should_lint": should_lint, "should_run": should_run}},
            {"swift_package": package, "test_filter": test_filter, "event_name": event_name},
            cancelled=cancelled,
        )

    def test_native_work_waits_for_lint_and_rejects_unsuccessful_lint(self):
        for job in ("mobile-core-package", "ios-simulator-build"):
            for lint in ("pending", "in_progress", "failure", "cancelled", "skipped"):
                with self.subTest(job=job, lint=lint):
                    self.assertFalse(self.admitted(job, lint=lint))

    def test_success_and_legitimately_unselected_lint_admit_native_work(self):
        for job in ("mobile-core-package", "ios-simulator-build", "ios-simulator"):
            with self.subTest(job=job):
                self.assertTrue(self.admitted(job))
                self.assertTrue(self.admitted(job, lint="skipped", should_lint="false"))

    def test_no_native_work_for_unselected_failed_or_cancelled_detection(self):
        for job in ("mobile-core-package", "ios-simulator-build", "ios-simulator"):
            with self.subTest(job=job):
                self.assertFalse(self.admitted(job, should_run="false"))
                self.assertFalse(self.admitted(job, cancelled=True))
                for detect in ("failure", "cancelled", "skipped"):
                    self.assertFalse(self.admitted(job, detect=detect))

    def test_focused_package_and_simulator_routing_is_preserved(self):
        for lint, should_lint in (("success", "true"), ("skipped", "false")):
            for package, test_filter, expected in (
                ("", "", (True, True)),
                ("", "cmuxFeatureTests", (False, True)),
                ("", "cmuxUITests/Focused", (False, True)),
                ("CmuxMobileShell", "Focused", (True, False)),
                ("CmuxMobileShell", "", (True, False)),
            ):
                with self.subTest(lint=lint, package=package, test_filter=test_filter):
                    actual = tuple(self.admitted(job, lint=lint, should_lint=should_lint,
                                                 package=package, test_filter=test_filter)
                                   for job in ("mobile-core-package", "ios-simulator-build"))
                    self.assertEqual(actual, expected)
        self.assertTrue(self.admitted("mobile-core-package", event_name="pull_request",
                                      test_filter="ignored-on-pr"))

    def test_consumers_require_a_completed_successful_producer(self):
        for producer in ("pending", "in_progress", "failure", "cancelled", "skipped"):
            with self.subTest(producer=producer):
                self.assertFalse(self.admitted("ios-simulator", producer=producer))


if __name__ == "__main__":
    unittest.main()
