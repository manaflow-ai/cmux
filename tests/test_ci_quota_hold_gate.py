#!/usr/bin/env python3
"""The CI_QUOTA_HOLD repository variable pauses API-heavy optional workflows.

Every workflow run spends the same installation GITHUB_TOKEN budget (5000
calls an hour). On 2026-10-26 pull request traffic emptied it within about 30
minutes of each reset, and the nightly's attest step then failed with "API
rate limit exceeded for installation". Setting the repository variable
CI_QUOTA_HOLD to 1 for the first hour after a reset pauses the optional,
API-heavy workflows listed here, so the nightly gets the budget first.

The gate is a job condition, `vars.CI_QUOTA_HOLD != '1'`, so an unset or any
other value runs everything as before. This test keeps it in place:

  - every workflow in HOLD_GATED gates each job that does not wait on another
    job of the same workflow (a job that `needs` a gated job is skipped with it);
  - no workflow that produces a required check reads the variable, so the hold
    can never make a pull request unmergeable or let one merge unchecked;
  - no nightly, dev or promote delivery workflow reads it.

A workflow that reads CI_QUOTA_HOLD must be listed in HOLD_GATED, so a partial
gate (one job held, its siblings still spending) cannot slip in unnoticed.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_required_checks_are_bounded import context_of, load  # noqa: E402
from test_ci_required_checks_have_no_path_filters import REQUIRED_CHECKS  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
VARIABLE = "CI_QUOTA_HOLD"
GATE = "vars.CI_QUOTA_HOLD != '1'"

# Optional workflows that spend GITHUB_TOKEN calls on every pull request
# completion and that the nightly must not compete with during the hold.
HOLD_GATED = (
    "ci-failure-attribution.yml",
    "dogfood-artifact-publish.yml",
    "pr-media.yml",
)

DELIVERY = re.compile(r"^(nightly.*|cmux-next-dev-daily.*|.*promote.*|release)\.ya?ml$")


def workflow_files() -> list[Path]:
    return sorted(WORKFLOWS.glob("*.y*ml"))


def required_owners(workflows: dict[Path, dict]) -> set[Path]:
    owners: set[Path] = set()
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            try:
                context = context_of(job_id, job, path, workflow)
            except ValueError:
                # A malformed CLA route is the timeout guard's to report; a
                # job here that cannot be matched still owns nothing.
                owners.add(path)
                continue
            if context in REQUIRED_CHECKS:
                owners.add(path)
    return owners


def ungated_jobs(workflow: dict) -> list[str]:
    missing = []
    for job_id, job in (workflow.get("jobs") or {}).items():
        if not isinstance(job, dict) or job.get("needs"):
            continue
        condition = str(job.get("if", ""))
        if GATE not in condition:
            missing.append(job_id)
    return missing


def violations(paths: list[Path] | None = None, gated: tuple[str, ...] = HOLD_GATED) -> list[str]:
    paths = workflow_files() if paths is None else paths
    texts = {path: path.read_text(encoding="utf-8") for path in paths}
    workflows = {path: load(path) for path in paths}
    by_name = {path.name: path for path in paths}
    failures: list[str] = []

    for name in gated:
        path = by_name.get(name)
        if path is None:
            failures.append(f"{name} is listed in HOLD_GATED but does not exist")
            continue
        for job_id in ungated_jobs(workflows[path]):
            failures.append(f"{name} job {job_id!r} does not gate on `{GATE}`")

    owners = required_owners(workflows)
    for path, text in texts.items():
        if VARIABLE not in text:
            continue
        if path in owners:
            failures.append(f"{path.name} produces a required check and must not read {VARIABLE}")
        if DELIVERY.match(path.name):
            failures.append(f"{path.name} is a delivery workflow and must not read {VARIABLE}")
        if path.name not in gated:
            failures.append(f"{path.name} reads {VARIABLE} but is not listed in HOLD_GATED")
    return failures


class QuotaHoldGateTests(unittest.TestCase):
    def test_current_tree_passes(self) -> None:
        self.assertEqual(violations(), [])

    def test_the_gated_workflows_produce_no_required_check(self) -> None:
        owners = {path.name for path in required_owners({p: load(p) for p in workflow_files()})}
        self.assertTrue(owners, "no workflow owns a required check; the mirror is unreadable")
        self.assertFalse(owners & set(HOLD_GATED))

    def test_dogfood_publish_skips_mismatched_bases_without_a_call(self) -> None:
        # The job condition pairs each source workflow with the base the script
        # accepts for it, so it skips only runs the script would skip anyway.
        document = load(WORKFLOWS / "dogfood-artifact-publish.yml")
        condition = document["jobs"]["publish"]["if"]
        run = next(step["run"] for step in document["jobs"]["publish"]["steps"]
                   if step.get("name") == "Find the trusted org-member dogfood artifact")
        event = "github.event.workflow_run"
        ci = f"{event}.name == 'CI' && {event}.pull_requests[0].base.ref != 'feat-cmux-next'"
        next_ = f"{event}.name == 'cmux-next' && {event}.pull_requests[0].base.ref == 'feat-cmux-next'"
        self.assertIn(f"({ci} || {next_})", condition)
        self.assertIn('(workflow_name == "CI" and pr.get("base", {}).get("ref") != "feat-cmux-next")', run)
        self.assertIn('(workflow_name == "cmux-next" and pr.get("base", {}).get("ref") == "feat-cmux-next")', run)
        # Swapped pairs would skip every run that should publish.
        self.assertNotIn(f"{event}.name == 'CI' && {event}.pull_requests[0].base.ref == 'feat-cmux-next'", condition)
        self.assertNotIn(f"{event}.name == 'cmux-next' && {event}.pull_requests[0].base.ref != 'feat-cmux-next'", condition)

    def test_dogfood_publish_has_no_cancelling_group(self) -> None:
        # A later CI completion on the same branch (a label event) can carry no
        # artifact; a cancelling group would drop the earlier head's publish.
        self.assertNotIn("cancel-in-progress: true",
                         (WORKFLOWS / "dogfood-artifact-publish.yml").read_text(encoding="utf-8"))

    def write(self, directory: Path, name: str, text: str) -> Path:
        path = directory / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_a_dropped_gate_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = (WORKFLOWS / "dogfood-artifact-publish.yml").read_text(encoding="utf-8")
            dropped = self.write(directory, "dogfood-artifact-publish.yml", original.replace(f"{GATE} && ", ""))
            others = [p for p in workflow_files() if p.name != dropped.name]
            failures = violations(others + [dropped])
        self.assertTrue(any("'publish' does not gate" in f for f in failures), failures)

    def test_a_required_workflow_reading_the_variable_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = (WORKFLOWS / "backend-migrations.yml").read_text(encoding="utf-8")
            held = self.write(directory, "backend-migrations.yml", original + f"\n# {VARIABLE}\n")
            others = [p for p in workflow_files() if p.name != held.name]
            failures = violations(others + [held])
        self.assertTrue(any("produces a required check" in f for f in failures), failures)

    def test_an_unlisted_reader_is_reported(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stray = self.write(directory, "stray.yml", "on: push\njobs:\n  a:\n"
                               f"    if: {GATE}\n    runs-on: ubuntu-24.04\n    steps: [{{run: x}}]\n")
            failures = violations(workflow_files() + [stray])
        self.assertTrue(any("stray.yml reads" in f for f in failures), failures)

    def test_merge_freeze_skips_drafts_but_is_never_held(self) -> None:
        # Mergers read the freezes again at merge time, so a skipped draft run
        # passes nothing; a held run on a ready pull request could, so the
        # freeze check never reads CI_QUOTA_HOLD.
        text = (WORKFLOWS / "merge-freeze.yml").read_text(encoding="utf-8")
        self.assertNotIn(VARIABLE, text)
        document = load(WORKFLOWS / "merge-freeze.yml")
        self.assertIn("!github.event.pull_request.draft", document["jobs"]["check"]["if"])
        on = document.get("on", document.get(True))
        self.assertIn("ready_for_review", on["pull_request_target"]["types"])

    def test_delivery_names_are_recognised(self) -> None:
        for name in ("nightly.yml", "nightly-next-tick.yml", "cmux-next-dev-daily.yml", "release.yml"):
            self.assertTrue(DELIVERY.match(name), name)
        self.assertFalse(DELIVERY.match("dogfood-artifact-publish.yml"))


if __name__ == "__main__":
    unittest.main()
