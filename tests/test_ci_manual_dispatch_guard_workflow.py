#!/usr/bin/env python3
"""Contracts for the privileged manual-dispatch cancellation watcher."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

import yaml
from test_seed_derived_data import evaluate, github_context

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci-manual-dispatch-guard.yml"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def trigger(document: dict) -> dict:
    return document.get("on", document.get(True))


def test_watcher_is_requested_ci_workflow_run() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    event = trigger(document)
    assert event["workflow_run"] == {"workflows": ["CI"], "types": ["requested"], "branches": ["main"]}
    assert document["env"]["SOURCE_WORKFLOW_PATHS"] == ".github/workflows/ci.yml"
    assert document["permissions"] == {}
    watcher_env = document["jobs"]["guard"]["steps"][-1]["env"]
    for key in ("SOURCE_EVENT_NAME", "SOURCE_REPOSITORY", "SOURCE_REF_NAME", "SOURCE_SHA", "SOURCE_RUN_ID", "SOURCE_COVERAGE_FINGERPRINT"):
        assert key in watcher_env
    assert "GITHUB_EVENT_NAME" not in watcher_env


def test_full_suite_coverage_marker_runs_inside_changes() -> None:
    document = yaml.safe_load(CI.read_text(encoding="utf-8"))
    changes = document["jobs"]["changes"]
    marker_steps = [
        step for step in changes["steps"]
        if step.get("name") == "Mark full-suite coverage"
    ]
    assert len(marker_steps) == 1
    marker = marker_steps[0]
    assert marker["if"] == "${{ steps.suite.outputs.full_suite == 'true' }}"
    assert marker["run"] == 'echo "full-suite coverage selected"'
    assert "full-suite-coverage" not in document["jobs"]
    assert "full-suite-coverage" not in document["jobs"]["macos-admission-gate"]["needs"]
    assert "coverage_fingerprint" in changes["outputs"]


def test_only_manual_dispatches_get_a_writer() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    guard = document["jobs"]["guard"]
    assert guard["if"] == (
        "github.event.workflow_run.path == '.github/workflows/ci.yml' && "
        "github.event.workflow_run.event == 'workflow_dispatch' && "
        "github.event.workflow_run.head_branch == 'main'"
    )
    assert guard["permissions"] == {
        "actions": "write",
        "contents": "read",
        "pull-requests": "read",
    }
    assert "scripts/ci/manual_dispatch_guard.py" in guard["steps"][-1]["run"]


def test_ci_changes_job_remains_read_only() -> None:
    document = yaml.safe_load(CI.read_text(encoding="utf-8"))
    changes = document["jobs"]["changes"]
    assert changes["permissions"]["actions"] == "read"
    steps = changes["steps"]
    index = next(i for i, step in enumerate(steps) if "manual_dispatch_guard.py" in step.get("run", ""))
    guard = steps[index]
    assert guard["if"] == "github.event_name == 'workflow_dispatch'"
    assert guard["run"] == "python3 scripts/ci/manual_dispatch_guard.py --check-only"
    assert index < next(i for i, step in enumerate(steps) if step.get("id") == "detect")
    assert "continue-on-error" not in guard


def test_non_main_dispatch_remote_daemon_uses_picked_owned_side_runner() -> None:
    workflow = yaml.safe_load((CI.parent / "remote-daemon.yml").read_text())
    route = workflow["jobs"]["remote-daemon-macos-tests"]["runs-on"]
    context = github_context("workflow_dispatch", ref="refs/heads/topic")
    context["github"].update(repository="manaflow-ai/cmux", run_attempt=1,
                             workflow_ref="manaflow-ai/cmux/.github/workflows/ci.yml@refs/heads/topic")
    context["inputs"].update(pr_owned_jobs=" remote-daemon ", pr_side_runner="glaeda-side-std-xcode-26.6")
    assert evaluate(route, context) == "glaeda-side-std-xcode-26.6"


def test_app_cache_canary_requires_explicit_trusted_main_dispatch() -> None:
    document = yaml.safe_load(CI.read_text())
    macos = yaml.safe_load((CI.parent / "ci-macos.yml").read_text())
    name = "app_compilation_cache_canary"
    for definition in (
        trigger(document)["workflow_dispatch"]["inputs"][name],
        trigger(macos)["workflow_call"]["inputs"][name],
    ):
        assert definition["type"] == "boolean"
        assert definition["default"] is False
    passed_input = document["jobs"]["macos"]["with"][name]
    gate = macos["env"]["CMUX_CI_ENABLE_APP_COMPILATION_CACHE"]
    for event in ("workflow_dispatch", "pull_request", "merge_group", "schedule", "push"):
        for repository in ("manaflow-ai/cmux", "someone/cmux"):
            for ref in ("refs/heads/main", "refs/heads/topic", "refs/tags/main"):
                for requested in (None, False, True):
                    context = github_context(event, ref=ref)
                    context["github"]["repository"] = repository
                    context["vars"]["CMUX_CI_ENABLE_APP_COMPILATION_CACHE"] = "1"
                    if requested is not None:
                        context["inputs"][name] = requested
                    value = evaluate(passed_input, context)
                    assert isinstance(value, bool), (event, requested, value)
                    context["inputs"][name] = value
                    expected = (event == "workflow_dispatch" and repository == "manaflow-ai/cmux"
                                and ref == "refs/heads/main" and requested is True)
                    assert evaluate(gate, context) == ("1" if expected else "0"), context


def test_app_cache_canary_has_distinct_consistent_coverage_fingerprint() -> None:
    document = yaml.safe_load(CI.read_text())
    steps = document["jobs"]["changes"]["steps"]
    guard = next(step for step in steps if "manual_dispatch_guard.py" in step.get("run", ""))
    record = next(step for step in steps if step.get("id") == "coverage-fingerprint")
    fingerprints = []
    for requested in (False, True):
        context = github_context("workflow_dispatch")
        context["github"].update(repository="manaflow-ai/cmux", sha="abc123", ref_name="main")
        context["inputs"].update(app_compilation_cache_canary=requested, release_archs="default")
        context["steps"]["suite"] = {"outputs": {"full_suite": "true"}}
        # Dispatches have no PR labels. Supply that empty projection because
        # the shared expression evaluator does not implement object filters.
        title_expression = document["run-name"].replace(
            "github.event.pull_request.labels.*.name", "fromJSON('[]')")
        title = evaluate(title_expression, context)
        assert title == evaluate(guard["env"]["SOURCE_COVERAGE_FINGERPRINT"], context)
        env = {key: str(evaluate(value, context)) for key, value in record["env"].items()}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            subprocess.run(["bash", "-c", record["run"]], check=True,
                           env={**os.environ, **env, "GITHUB_OUTPUT": str(output)})
            assert output.read_text().strip() == "fingerprint=" + title
        fingerprints.append(title)
    assert fingerprints[0] != fingerprints[1], "a normal CI run must not cover the cache canary"


if __name__ == "__main__":
    suite = unittest.TestSuite()
    for name, function in sorted(globals().items()):
        if name.startswith("test_"):
            suite.addTest(unittest.FunctionTestCase(function))
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        raise SystemExit(1)
