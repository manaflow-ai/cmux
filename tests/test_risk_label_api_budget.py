#!/usr/bin/env python3
"""The risk label step spends no API request when the label is already right.

Every workflow in the repository shares GITHUB_TOKEN's REST budget of 1,000 requests an hour, and
risk-tier.yml grades every event on every open pull request (340 runs in the 70 minutes before
03:10Z on 2026-10-26). The step used to open with four `gh label create` calls on every run, about
1,160 requests an hour, all of which only reported that the label already exists. That drained the
quota the DEV publish handoff and the CLA checks spend.

These tests run the step's own script out of the workflow, with `gh` replaced by a recorder, so a
change that reintroduces a per-run request fails here.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
STEP = "Set the risk label"
VIEW_CALL = "pr view 25172 --repo manaflow-ai/cmux --json labels --jq .labels[].name"

# Records its arguments, and answers `pr view --json labels` the way gh does: one label per line,
# from GH_VIEW_LABELS. That way the live-confirmation path is exercised, not stubbed out.
GH_RECORDER = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_CALLS"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  [ -z "${GH_VIEW_LABELS:-}" ] || printf '%s\\n' "$GH_VIEW_LABELS"
fi
exit "${GH_EXIT:-0}"
"""


def step_script() -> str:
    """The `run:` body of the label step, read from the workflow itself."""
    import yaml

    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    steps = workflow["jobs"]["evidence"]["steps"]
    for step in steps:
        if step.get("name") == STEP:
            return step["run"]
    raise AssertionError(f"{WORKFLOW} has no step named {STEP!r}")


class RiskLabelBudgetTest(unittest.TestCase):
    def run_step(self, label: str, current: list[str], gh_exit: int = 0,
                 live: list[str] | None = None):
        """(gh calls, stdout) of the step for a pull request carrying `current`.

        `live` is what a `gh pr view` reports, when it differs from the event payload.
        """
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = pathlib.Path(tmp) / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            gh.write_text(GH_RECORDER, encoding="utf-8")
            gh.chmod(0o755)
            calls = pathlib.Path(tmp) / "calls"
            calls.write_text("", encoding="utf-8")
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "GH_CALLS": str(calls),
                "GH_EXIT": str(gh_exit),
                "GH_TOKEN": "x",
                "REPO": "manaflow-ai/cmux",
                "NUMBER": "25172",
                "LABEL": label,
                "CURRENT_JSON": json.dumps(current),
                # What a live `gh pr view` would report; defaults to the payload.
                "GH_VIEW_LABELS": "\n".join(live if live is not None else current),
            }
            done = subprocess.run(
                ["bash", "-c", step_script()], env=env, capture_output=True, text=True, timeout=60
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            recorded = [line for line in calls.read_text(encoding="utf-8").splitlines() if line]
            return recorded, done.stdout

    def test_the_usual_case_spends_no_request(self):
        """The graded tier is already the only risk label: the overwhelming majority of runs."""
        calls, out = self.run_step("risk:low", ["risk:low", "dev-build"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_an_unlabeled_pull_request_costs_one_add(self):
        calls, _ = self.run_step("risk:normal", [])
        self.assertEqual(calls, ["pr view 25172 --repo manaflow-ai/cmux --json labels --jq .labels[].name",
                                 "pr edit 25172 --repo manaflow-ai/cmux --add-label risk:normal"])

    def test_a_label_is_never_created_while_adding_it_works(self):
        """The four unconditional `gh label create` calls were the whole drain."""
        calls, _ = self.run_step("risk:high", [])
        self.assertFalse([call for call in calls if call.startswith("label create")], calls)

    def test_a_changed_tier_replaces_the_old_label(self):
        calls, _ = self.run_step("risk:high", ["risk:low"])
        self.assertEqual(
            calls,
            [
                "pr view 25172 --repo manaflow-ai/cmux --json labels --jq .labels[].name",
                "pr edit 25172 --repo manaflow-ai/cmux --add-label risk:high",
                "pr edit 25172 --repo manaflow-ai/cmux --remove-label risk:low",
            ],
        )

    def test_the_old_medium_name_is_still_removed(self):
        calls, _ = self.run_step("risk:normal", ["risk:medium"])
        self.assertIn("pr edit 25172 --repo manaflow-ai/cmux --remove-label risk:medium", calls)

    def test_human_ok_is_left_alone(self):
        """A maintainer's risk:human-ok is not a tier label; agents never touch it."""
        calls, out = self.run_step("risk:high", ["risk:high", "risk:human-ok"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_a_missing_label_is_created_then_added(self):
        """A fresh fork has no risk labels, so the add fails once and the step creates it."""
        calls, _ = self.run_step("risk:low", [], gh_exit=1)
        self.assertEqual(
            calls,
            [
                "pr view 25172 --repo manaflow-ai/cmux --json labels --jq .labels[].name",
                "pr edit 25172 --repo manaflow-ai/cmux --add-label risk:low",
                "label create risk:low --repo manaflow-ai/cmux --color 0E8A16 "
                "--description Risk tier (docs/ci/risk-tiers.md)",
                "pr edit 25172 --repo manaflow-ai/cmux --add-label risk:low",
            ],
        )

    def test_a_label_with_a_space_is_not_split(self):
        """Label names may contain spaces; matching stays exact."""
        calls, out = self.run_step("risk:low", ["good first issue", "risk:low"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_an_empty_label_leaves_the_pull_requests_labels_alone(self):
        """Unreachable today, but the risk gate must never strip the tier it set.

        `grep -vxF ""` keeps every non-empty line, so without the guard an empty LABEL reads the
        existing risk label as stale and asks for `--add-label ` with no name.
        """
        calls, out = self.run_step("", ["risk:low"])
        self.assertEqual(calls, [])
        self.assertIn("produced no label", out)

    def test_a_hostile_label_name_on_the_pull_request_is_inert(self):
        """Label names come from the event payload; none of them reaches a shell or a glob."""
        marker = pathlib.Path(tempfile.gettempdir()) / "cmux-risk-label-injection-marker"
        marker.unlink(missing_ok=True)
        calls, _ = self.run_step("risk:low", [f"$(touch {marker})", "*", "risk:low"])
        self.assertEqual(calls, [])
        self.assertFalse(marker.exists(), f"{marker} was created, so a label name ran as code")

    def test_a_live_read_that_disagrees_with_the_payload_wins(self):
        """The payload is a snapshot. A racing run may already have set the tier, and a
        GITHUB_TOKEN label edit starts no run to correct a double label, so the edit path
        confirms against the live labels first."""
        calls, out = self.run_step("risk:high", ["risk:low"], live=["risk:high"])
        self.assertEqual(calls, [VIEW_CALL])
        self.assertIn("became the only risk label", out)

    def test_a_failed_live_read_falls_back_to_the_payload(self):
        """A read error must not make the step treat the pull request as unlabelled."""
        calls, _ = self.run_step("risk:high", ["risk:low"], gh_exit=1)
        self.assertIn("pr edit 25172 --repo manaflow-ai/cmux --remove-label risk:low", calls)

    def test_the_step_cannot_spend_a_request_except_through_gh(self):
        """The budget claim rests on counting `gh`, so nothing else may reach the API."""
        body = step_script()
        for tool in ("curl", "wget", "python", "node", "/usr/bin/gh", "actions/github-script"):
            self.assertNotIn(tool, body, f"{tool} could spend quota without the recorder seeing it")

    def test_an_api_error_never_fails_the_step(self):
        """The check's verdict is the gate; a label error is a warning."""
        _, out = self.run_step("risk:high", ["risk:low"], gh_exit=1)
        self.assertIn("could not", out + "")


if __name__ == "__main__":
    unittest.main()
