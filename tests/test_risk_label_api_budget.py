#!/usr/bin/env python3
"""The risk label step spends no API request when the label is already right.

Every workflow in the repository shares GITHUB_TOKEN's REST budget of 1,000 requests an hour, and
risk-tier.yml grades every event on every open pull request (340 runs in the 70 minutes before
03:10Z on 2026-10-26). The step used to open with four `gh label create` calls on every run, about
1,160 requests an hour, all of which only reported that the label already exists. That drained the
quota the DEV publish handoff and the CLA checks spend.

These tests run the step's own script out of the workflow, with `gh` replaced by a recorder, so a
change that reintroduces a per-run request fails here. They also pin the two ways the step may not
fail: it never leaves a pull request with two tier labels, and never with none.
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
VIEW_CALL = "pr view 25172 --repo manaflow-ai/cmux --json labels --jq [.labels[].name]"
ADD = "pr edit 25172 --repo manaflow-ai/cmux --add-label "
REMOVE = "pr edit 25172 --repo manaflow-ai/cmux --remove-label "

# Records its arguments and answers each verb the way gh does, so the live-confirmation path is
# exercised rather than stubbed: `pr view --json labels --jq '[...]'` prints a JSON array, and each
# verb has its own exit code, because the step must behave differently when the read works and the
# write does not.
GH_RECORDER = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_CALLS"
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  [ "${GH_VIEW_EXIT:-0}" = 0 ] || exit "$GH_VIEW_EXIT"
  printf '%s\\n' "$GH_VIEW_JSON"
  exit 0
fi
if [ "${1:-}" = label ]; then exit "${GH_LABEL_EXIT:-0}"; fi
exit "${GH_EDIT_EXIT:-0}"
"""


def workflow_step() -> dict:
    import yaml

    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for step in workflow["jobs"]["evidence"]["steps"]:
        if step.get("name") == STEP:
            return step
    raise AssertionError(f"{WORKFLOW} has no step named {STEP!r}")


def step_script() -> str:
    """The `run:` body of the label step, read from the workflow itself."""
    return workflow_step()["run"]


class RiskLabelBudgetTest(unittest.TestCase):
    def run_step(self, label: str, current: list[str], gh_exit: int = 0,
                 live: list[str] | None = None, view_exit: int | None = None,
                 edit_exit: int | None = None, label_exit: int | None = None):
        """(gh calls, stdout) of the step for a pull request carrying `current`.

        `live` is what `gh pr view` reports, when it differs from the event payload. `gh_exit` sets
        every verb's exit code; `view_exit`, `edit_exit` and `label_exit` override one of them.
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
                "GH_VIEW_EXIT": str(gh_exit if view_exit is None else view_exit),
                "GH_EDIT_EXIT": str(gh_exit if edit_exit is None else edit_exit),
                "GH_LABEL_EXIT": str(gh_exit if label_exit is None else label_exit),
                "GH_TOKEN": "x",
                "REPO": "manaflow-ai/cmux",
                "NUMBER": "25172",
                "LABEL": label,
                "CURRENT_JSON": json.dumps(current),
                # What a live `gh pr view --jq '[.labels[].name]'` would print; the payload by default.
                "GH_VIEW_JSON": json.dumps(current if live is None else live),
            }
            done = subprocess.run(
                ["bash", "-c", step_script()], env=env, capture_output=True, text=True, timeout=60
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            recorded = [line for line in calls.read_text(encoding="utf-8").splitlines() if line]
            return recorded, done.stdout

    # --- the budget ---

    def test_the_usual_case_spends_no_request(self):
        """The graded tier is already the only risk label: the overwhelming majority of runs."""
        calls, out = self.run_step("risk:low", ["risk:low", "dev-build"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_an_unlabeled_pull_request_costs_a_read_and_an_add(self):
        calls, _ = self.run_step("risk:normal", [])
        self.assertEqual(calls, [VIEW_CALL, ADD + "risk:normal"])

    def test_a_changed_tier_costs_three_requests(self):
        """The read, the add and the remove. The PR body quotes this number."""
        calls, _ = self.run_step("risk:high", ["risk:low"])
        self.assertEqual(calls, [VIEW_CALL, ADD + "risk:high", REMOVE + "risk:low"])

    def test_a_label_is_never_created_while_adding_it_works(self):
        """The four unconditional `gh label create` calls were the whole drain."""
        calls, _ = self.run_step("risk:high", [])
        self.assertFalse([call for call in calls if call.startswith("label create")], calls)

    def test_a_missing_label_is_created_then_added(self):
        """A fresh fork has no risk labels, so the add fails once and the step creates it."""
        calls, _ = self.run_step("risk:low", [], edit_exit=1)
        self.assertEqual(
            calls,
            [
                VIEW_CALL,
                ADD + "risk:low",
                "label create risk:low --repo manaflow-ai/cmux --color 0E8A16 "
                "--description Risk tier (docs/ci/risk-tiers.md)",
                ADD + "risk:low",
            ],
        )

    def test_the_step_cannot_spend_a_request_except_through_gh(self):
        """The budget claim rests on counting `gh`, so nothing else may reach the API."""
        body = step_script()
        for tool in ("curl", "wget", "python", "node", "/usr/bin/gh", "actions/github-script"):
            self.assertNotIn(tool, body, f"{tool} could spend quota without the recorder seeing it")

    def test_the_step_is_wired_to_the_event_payload(self):
        """The tests supply the environment, so the workflow must really pass these in.

        Without this, `env:` could lose CURRENT_JSON (the step would then see an unset variable and
        exit on `set -u`) or stop using `toJSON(...)` while every test above still passed.
        """
        env = workflow_step()["env"]
        self.assertEqual(env["CURRENT_JSON"], "${{ toJSON(github.event.pull_request.labels.*.name) }}")
        self.assertEqual(env["LABEL"], "${{ steps.grade.outputs.label }}")
        self.assertEqual(env["NUMBER"], "${{ github.event.pull_request.number }}")
        self.assertEqual(env["REPO"], "${{ github.repository }}")
        self.assertEqual(env["GH_TOKEN"], "${{ github.token }}")

    # --- it never leaves the wrong labels ---

    def test_the_old_medium_name_is_still_removed(self):
        calls, _ = self.run_step("risk:normal", ["risk:medium"])
        self.assertIn(REMOVE + "risk:medium", calls)

    def test_two_tier_labels_are_reduced_to_one(self):
        calls, _ = self.run_step("risk:high", ["risk:high", "risk:low", "risk:medium"])
        self.assertEqual(calls, [VIEW_CALL, REMOVE + "risk:low", REMOVE + "risk:medium"])

    def test_human_ok_is_left_alone(self):
        """A maintainer's risk:human-ok is not a tier label; agents never touch it."""
        calls, out = self.run_step("risk:high", ["risk:high", "risk:human-ok"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_a_live_read_that_disagrees_with_the_payload_wins(self):
        """The payload is a snapshot. A racing run may already have set the tier, and a
        GITHUB_TOKEN label edit starts no run to correct a double label, so the edit path
        confirms against the live labels first."""
        calls, out = self.run_step("risk:high", ["risk:low"], live=["risk:high"])
        self.assertEqual(calls, [VIEW_CALL])
        self.assertIn("became the only risk label", out)

    def test_a_live_read_of_no_labels_is_an_answer_not_an_error(self):
        """`[]` means the pull request has no labels. Reading it as a failed read, and falling
        back to the payload, removed the payload's tier while skipping the add: no tier at all."""
        calls, _ = self.run_step("risk:high", ["risk:high", "risk:low"], live=[])
        self.assertEqual(calls, [VIEW_CALL, ADD + "risk:high"])

    def test_a_failed_live_read_falls_back_to_the_payload(self):
        """A read error must not make the step treat the pull request as unlabelled."""
        calls, out = self.run_step("risk:high", ["risk:low"], view_exit=1)
        self.assertEqual(calls, [VIEW_CALL, ADD + "risk:high", REMOVE + "risk:low"])
        self.assertIn("could not read the live labels", out)

    def test_the_old_tier_stays_when_the_new_one_cannot_be_added(self):
        """A stale tier is bad; no tier is worse, and a transient API error must not cause it."""
        calls, out = self.run_step("risk:high", ["risk:low"], edit_exit=1)
        self.assertFalse([call for call in calls if "--remove-label" in call], calls)
        self.assertIn("rather than leaving it with no tier", out)

    def test_a_remove_that_fails_is_only_a_warning(self):
        """The tier it was asked for is on the pull request; a leftover is for the next event."""
        calls, out = self.run_step("risk:high", ["risk:high", "risk:low"], edit_exit=1)
        self.assertEqual(calls, [VIEW_CALL, REMOVE + "risk:low"])
        self.assertIn("could not remove risk:low", out)

    def test_an_empty_label_leaves_the_pull_requests_labels_alone(self):
        """Unreachable today, but the risk gate must never strip the tier it set."""
        calls, out = self.run_step("", ["risk:low"])
        self.assertEqual(calls, [])
        self.assertIn("produced no label", out)

    # --- hostile label names ---

    def test_a_label_with_a_space_is_not_split(self):
        """Label names may contain spaces; matching stays exact."""
        calls, out = self.run_step("risk:low", ["good first issue", "risk:low"])
        self.assertEqual(calls, [])
        self.assertIn("no API request spent", out)

    def test_a_label_containing_a_newline_cannot_forge_a_tier(self):
        """A line-based grep over every name would read "x\\nrisk:high" as the tier risk:high and
        skip the add, leaving the pull request untagged. jq matches whole values, so it does not."""
        calls, _ = self.run_step("risk:high", ["harmless\nrisk:high"])
        self.assertEqual(calls, [VIEW_CALL, ADD + "risk:high"])

    def test_a_label_containing_a_newline_is_never_removed(self):
        """The mirror of the case above: it is not a tier, so it is not stale either."""
        calls, _ = self.run_step("risk:high", ["risk:high", "junk\nrisk:low"])
        self.assertEqual(calls, [])

    def test_a_hostile_label_name_on_the_pull_request_is_inert(self):
        """Label names come from the event payload; none of them reaches a shell or a glob."""
        marker = pathlib.Path(tempfile.gettempdir()) / "cmux-risk-label-injection-marker"
        marker.unlink(missing_ok=True)
        calls, _ = self.run_step("risk:low", [f"$(touch {marker})", "*", "risk:low"])
        self.assertEqual(calls, [])
        self.assertFalse(marker.exists(), f"{marker} was created, so a label name ran as code")

    def test_an_api_error_never_fails_the_step(self):
        """The check's verdict is the gate; a label error is a warning."""
        _, out = self.run_step("risk:high", ["risk:low"], gh_exit=1)
        self.assertIn("could not", out)


if __name__ == "__main__":
    unittest.main()
