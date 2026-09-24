#!/usr/bin/env python3
"""Tests for .github/actions/glaeda-route and its wiring in ci.yml and nightly.yml (no network).

The route rule itself lives in teamleaderleo/glaeda (scripts/glaeda-route, tested there). What
cmux owns, and what these tests pin, is the gate in front of it: a fork run, a retry, the switch
being off, or a missing pool state or credential answers with the caller's default before any
call, and the workflows fall back to their existing expressions whenever Glaeda does not answer
with an owned pool.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github" / "actions" / "glaeda-route" / "action.yml"
WORKFLOWS = ROOT / ".github" / "workflows"


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def step(steps: list[dict], step_id: str) -> dict:
    return next(s for s in steps if s.get("id") == step_id)


ACTION_DOC = load(ACTION)
STEPS = ACTION_DOC["runs"]["steps"]


def run_gate(**env: str) -> tuple[dict[str, str], str]:
    base = {"ENABLED": "1", "EVENT_NAME": "pull_request", "HEAD_REPO": "manaflow-ai/cmux",
            "REPOSITORY": "manaflow-ai/cmux", "RUN_ATTEMPT": "1", "HAS_STATE": "true", "HAS_KEY": "true"}
    base.update(env)
    with tempfile.TemporaryDirectory() as tmp:
        out, summary = Path(tmp) / "out", Path(tmp) / "summary"
        out.touch()
        summary.touch()
        subprocess.run(["bash", "-c", step(STEPS, "gate")["run"]], check=True,
                       env={**base, "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary),
                            "PATH": "/usr/bin:/bin"})
        outputs = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return outputs, summary.read_text()


class GateTests(unittest.TestCase):
    def test_trusted_same_repo_attempt_one_asks(self):
        outputs, summary = run_gate()
        self.assertEqual(outputs["ask"], "true")
        self.assertEqual(summary, "")
        for event in ("push", "merge_group", "schedule", "workflow_dispatch"):
            self.assertEqual(run_gate(EVENT_NAME=event, HEAD_REPO="")[0]["ask"], "true", event)

    def test_everything_else_answers_with_the_default_without_asking(self):
        cases = {
            "off": {"ENABLED": ""},
            "fork": {"HEAD_REPO": "someone/cmux"},
            "deleted fork": {"HEAD_REPO": ""},
            "pull_request_target": {"EVENT_NAME": "pull_request_target", "HEAD_REPO": ""},
            "retry": {"RUN_ATTEMPT": "2"},
            "no state": {"HAS_STATE": "false"},
            "no key": {"HAS_KEY": "false"},
        }
        for name, env in cases.items():
            outputs, summary = run_gate(**env)
            self.assertEqual(outputs["ask"], "false", name)
            self.assertTrue(outputs["reason"], name)
            self.assertIn("caller default", summary, name)


class ActionShapeTests(unittest.TestCase):
    def test_every_later_step_runs_only_when_the_gate_asks(self):
        for s in STEPS[1:]:
            self.assertIn("steps.gate.outputs.ask == 'true'", s.get("if", ""), s.get("name"))
            self.assertTrue(s.get("continue-on-error"), s.get("name"))

    def test_token_reaches_only_the_ledger_repository(self):
        token = step(STEPS, "token")
        self.assertRegex(token["uses"], r"^actions/create-github-app-token@[0-9a-f]{40}$")
        self.assertEqual(token["with"]["repositories"], "glaeda-route-state")
        self.assertEqual(token["with"]["owner"], "manaflow-ai")
        permissions = {k: v for k, v in token["with"].items() if k.startswith("permission-")}
        self.assertEqual(permissions, {"permission-contents": "write"})

    def test_route_script_is_pinned_by_commit_and_digest(self):
        route = step(STEPS, "route")
        self.assertRegex(route["env"]["GLAEDA_COMMIT"], r"^[0-9a-f]{40}$")
        self.assertRegex(route["env"]["GLAEDA_ROUTE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertIn("raw.githubusercontent.com/teamleaderleo/glaeda/$GLAEDA_COMMIT/scripts/glaeda-route",
                      route["run"])
        self.assertIn("hashlib.sha256", route["run"])
        self.assertLess(route["run"].index("hashlib.sha256"), route["run"].index('python3 "$script" route'))

    def test_no_expression_is_interpolated_into_a_script(self):
        for s in STEPS:
            self.assertNotIn("${{", s.get("run", ""), s.get("name"))

    def test_outputs_fall_back_to_the_default(self):
        outputs = ACTION_DOC["outputs"]
        self.assertEqual(outputs["runs-on"]["value"],
                         "${{ steps.route.outputs.owned == 'true' && steps.route.outputs.runs_on || inputs.default }}")
        self.assertEqual(outputs["owned"]["value"],
                         "${{ steps.route.outputs.owned == 'true' && 'true' || 'false' }}")


class WiringTests(unittest.TestCase):
    def test_ci_changes_asks_glaeda_before_the_picker(self):
        job = load(WORKFLOWS / "ci.yml")["jobs"]["changes"]
        ids = [s.get("id") for s in job["steps"]]
        self.assertLess(ids.index("glaeda-route"), ids.index("macos-pool"))
        ask = step(job["steps"], "glaeda-route")
        self.assertEqual(ask["uses"], "./.github/actions/glaeda-route")
        self.assertEqual(ask["if"], "github.event_name == 'pull_request' && vars.GLAEDA_ROUTE == '1'")
        self.assertTrue(ask["continue-on-error"])
        self.assertEqual(ask["with"]["priority"], "pr")
        self.assertEqual(ask["with"]["xcode"], "${{ vars.CMUX_CI_XCODE_APP_PR }}")
        self.assertEqual(step(job["steps"], "macos-pool")["if"], "steps.glaeda-route.outputs.owned != 'true'")
        self.assertEqual(job["outputs"]["macos_pr_runner"],
                         "${{ steps.glaeda-route.outputs.owned == 'true' && steps.glaeda-route.outputs.runs-on "
                         "|| steps.macos-pool.outputs.runner }}")
        # An owned pool pins the lane's own Xcode, which is what its label names.
        self.assertEqual(job["outputs"]["macos_pr_xcode_app"],
                         "${{ steps.glaeda-route.outputs.owned != 'true' && steps.macos-pool.outputs.xcode_app || '' }}")

    def test_nightly_warm_jobs_ask_as_low_priority_and_keep_their_fallbacks(self):
        doc = load(WORKFLOWS / "nightly.yml")
        decide = doc["jobs"]["decide"]
        for step_id, job_name, output in (("glaeda-warm-cache", "refresh-compilation-cache", "warm_cache_runner"),
                                          ("glaeda-warm-test-cache", "refresh-test-compilation-cache",
                                           "warm_test_cache_runner")):
            ask = step(decide["steps"], step_id)
            self.assertEqual(ask["with"]["priority"], "warm")
            self.assertTrue(ask["if"].startswith("vars.GLAEDA_ROUTE == '1' && "))
            self.assertIn(f"steps.{step_id}.outputs.owned == 'true'", decide["outputs"][output])
            runs_on = doc["jobs"][job_name]["runs-on"]
            # The owner branch still comes first, and the old expression follows the Glaeda answer.
            self.assertTrue(runs_on.startswith("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                                               f"needs.decide.outputs.{output} || "), runs_on)
        kinds = [step(decide["steps"], i)["with"]["kind"] for i in ("glaeda-warm-cache", "glaeda-warm-test-cache")]
        self.assertEqual(len(set(kinds)), 2, "each ask in a run needs its own kind (reservation id)")

    def test_no_workflow_names_an_owned_label_literally(self):
        owned = re.compile(r"glaeda-(?:std|light|xl)-xcode-")
        for path in [*WORKFLOWS.glob("*.yml"), ACTION]:
            self.assertIsNone(owned.search(path.read_text(encoding="utf-8")), path.name)


if __name__ == "__main__":
    unittest.main()
