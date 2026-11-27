"""Two probes the post-merge batch dispatches never share a concurrency group inside a suite it calls.

A confirm round runs the culprit twice and its parent twice at once (scripts/ci/post_merge_batch.py
confirm_probes): same commit, same job. GitHub keeps one running and one pending run per group and cancels
every other pending one, so a suite whose group under the batch is its ref (or its commit and job) cancels
the round; each cancelled run's judge dispatches it again, and the round ends with no verdict and no revert.
Under workflow_call, github.run_id is the calling probe run's, unique per probe."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
BATCH = WORKFLOWS / "cmux-next-post-merge.yml"

_spec = importlib.util.spec_from_file_location("ci_pr_runs_cancel_superseded_for_batch", Path(__file__).with_name("test_ci_pr_runs_cancel_superseded.py"))
cancel_superseded = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cancel_superseded)


def called_suites() -> dict[str, dict]:
    """Each local workflow the batch calls, with the `with:` it passes."""
    batch = cancel_superseded.load(BATCH)
    out = {}
    for job in batch.get("jobs", {}).values():
        uses = job.get("uses", "") if isinstance(job, dict) else ""
        if uses.startswith("./.github/workflows/"):
            out[uses.removeprefix("./")] = job.get("with") or {}
    return out


def probe_group(path: str, passed: dict, run_id: int) -> str | None:
    workflow = cancel_superseded.load(ROOT / path)
    concurrency = workflow.get("concurrency")
    if not concurrency:
        return None
    batch = cancel_superseded.load(BATCH)
    context = cancel_superseded.non_pr_context(batch, "workflow_dispatch", "refs/heads/feat-cmux-next")
    context["github"].update({"run_id": run_id, "workflow": batch.get("name") or "batch", "sha": "f" * 40})
    declared = (cancel_superseded.triggers(workflow).get("workflow_call") or {}).get("inputs") or {}
    inputs = {name: (spec or {}).get("default", "") for name, spec in declared.items()}
    plan = {"sha": "c" * 40, "only": "some-job", "suites": " all "}
    for name, value in passed.items():
        if isinstance(value, str) and "needs.plan.outputs." in value:
            inputs[name] = plan.get(value.split("needs.plan.outputs.", 1)[1].split()[0].rstrip("}"), "")
        else:
            inputs[name] = value
    context["inputs"] = inputs
    return cancel_superseded.group_of(concurrency, context)


class ConfirmProbesNeverCancelEachOther(unittest.TestCase):
    def test_every_called_suite_keys_a_probe_by_its_own_run(self):
        suites = called_suites()
        self.assertIn(".github/workflows/cmux-tui-spec.yml", suites)
        shared = []
        for path, passed in sorted(suites.items()):
            first, second = probe_group(path, passed, 4601), probe_group(path, passed, 4602)
            if first is not None and first == second:
                shared.append(f"{path}: {first!r}")
        self.assertEqual(shared, [], "two probes of one commit and job share a group (one is cancelled): "
                                     "key the batch's call by github.run_id")


if __name__ == "__main__":
    unittest.main()
