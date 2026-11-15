#!/usr/bin/env python3
"""A job that recovers from a needed job's failure recovers from its timeout too.

GitHub ends a job that passes its `timeout-minutes` as `cancelled`, not `failure`, and the run ends
`failure`. A recovery written as "when X failed" (`needs.X.result == 'failure'`) is skipped then, and a
timeout is the failure a busy fleet produces most. On 2026-11-13 cmux-tui tree a8ff9bd1 was never
published for it: the macOS leg of artifacts run 43346255778 was cancelled by its 60 min timeout,
darwin-fallback-plan read only `failure`, and the nightly that waited for the tree gave up after 45 min
(run 43347371069).

This reads every job-level `if:` under .github/workflows. A job whose condition reads a needed job's
`failure` must also read that job's `cancelled` (`needs.X.result == 'cancelled'`, or
`contains(needs.*.result, 'cancelled')`), or be listed below:

- FAILURE_ONLY: a stopped job is no reason to run this one, with the reason.
- OPEN: the condition misses a timeout and is not fixed yet, with the issue that tracks it. Fix it,
  then remove the row; never add one.

A person's cancel is kept out with `!cancelled()` on the run, not by leaving `cancelled` out of the
condition.
"""

from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
READS_FAILURE = re.compile(r"needs\.([\w-]+)\.result\s*==\s*'failure'")
ANY_NEED_CANCELLED = re.compile(r"contains\(\s*needs\.\*\.result\s*,\s*'cancelled'\s*\)")

# (workflow, job, needed job): why a timeout of the needed job is no reason to run the job.
FAILURE_ONLY = {
    ("auto-resume-nightly-notarization.yml", "poll-outer", "wait-and-staple"):
        "wait-and-staple's one long step has its own timeout-minutes below the job's, so a slow wait ends failure",
    ("auto-resume-nightly-notarization.yml", "poll-stapled", "staple-outer"):
        "staple-outer's one long step has its own timeout-minutes below the job's, so a slow wait ends failure",
    ("cmux-next-web.yml", "web-bisect", "web"):
        "a bisect needs the red files a finished run names; a stopped run named none",
    ("cmux-next.yml", "release-compile-revert", "release-compile"):
        "a revert needs a compile that judged the merge; a stopped compile judged nothing",
    ("cmux-next.yml", "release-compile-revert", "release-compile-fast-admission"):
        "a revert needs a compile that judged the merge; a stopped admission judged nothing",
}

# (workflow, job, needed job): the issue that tracks a condition that misses a timeout.
OPEN = {
    ("cmux-next.yml", "release-compile", "release-compile-fast"): "manaflow-ai/cmuxterm-hq#10291 item 2",
    ("nightly.yml", "prepare-nightly-variant", "prepare-nightly-variant-primary"): "manaflow-ai/cmuxterm-hq#10291 item 1",
}


def failure_only_sites(workflows: Path) -> list[tuple[str, str, str]]:
    """Every (workflow, job, needed job) whose job `if:` reads the needed job's failure and not its cancel."""
    found = []
    for path in sorted(workflows.glob("*.yml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            condition = str(job.get("if", "")) if isinstance(job, dict) else ""
            if ANY_NEED_CANCELLED.search(condition):
                continue
            for needed in sorted(set(READS_FAILURE.findall(condition))):
                if not re.search(rf"needs\.{re.escape(needed)}\.result\s*==\s*'cancelled'", condition):
                    found.append((path.name, name, needed))
    return found


class RecoveryRunsAfterATimeout(unittest.TestCase):
    def test_every_failure_only_condition_is_listed_with_its_reason(self) -> None:
        unlisted = [site for site in failure_only_sites(WORKFLOWS) if site not in FAILURE_ONLY and site not in OPEN]
        self.assertEqual(unlisted, [], "\n".join(
            f"{workflow} job {job}: its `if:` reads needs.{needed}.result == 'failure' and not 'cancelled', so a "
            f"{needed} that its timeout cancels skips {job}. Add `|| needs.{needed}.result == 'cancelled'` (and "
            "`!cancelled()` so a person's cancel starts nothing), or list it in FAILURE_ONLY with the reason "
            f"({Path(__file__).name})." for workflow, job, needed in unlisted))

    def test_no_row_outlives_its_condition(self) -> None:
        sites = set(failure_only_sites(WORKFLOWS))
        self.assertEqual(sorted(set(FAILURE_ONLY) - sites), [], "FAILURE_ONLY rows with no such condition: remove them")
        self.assertEqual(sorted(set(OPEN) - sites), [], "OPEN rows whose condition is fixed or gone: remove them")
        self.assertEqual(sorted(set(FAILURE_ONLY) & set(OPEN)), [])

    def test_the_tree_builds_fallback_runs_after_a_timeout_and_not_after_a_cancelled_run(self) -> None:
        document = yaml.safe_load((WORKFLOWS / "cmux-tui-artifacts.yml").read_text(encoding="utf-8"))
        condition = document["jobs"]["darwin-fallback-plan"]["if"]
        self.assertIn("needs.build.result == 'failure' || needs.build.result == 'cancelled'", condition)
        self.assertIn("!cancelled()", condition)

    def test_the_reader_finds_each_shape(self) -> None:
        workflow = """
on: push
jobs:
  build: {runs-on: x, steps: [{run: "true"}]}
  only-failure:
    needs: build
    if: ${{ always() && needs.build.result == 'failure' }}
    runs-on: x
    steps: [{run: "true"}]
  folded:
    needs: build
    if: >-
      always() &&
      needs.build.result  ==  'failure'
    runs-on: x
    steps: [{run: "true"}]
  both:
    needs: build
    if: ${{ !cancelled() && (needs.build.result == 'failure' || needs.build.result == 'cancelled') }}
    runs-on: x
    steps: [{run: "true"}]
  any-need:
    needs: build
    if: always() && (contains(needs.*.result, 'cancelled') || needs.build.result == 'failure')
    runs-on: x
    steps: [{run: "true"}]
  another-jobs-cancel:
    needs: [build, both]
    if: ${{ always() && needs.build.result == 'failure' && needs.both.result == 'cancelled' }}
    runs-on: x
    steps: [{run: "true"}]
  no-condition:
    needs: build
    runs-on: x
    steps: [{run: "true"}]
"""
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / "sample.yml").write_text(workflow, encoding="utf-8")
            self.assertEqual(failure_only_sites(Path(temp)), [
                ("sample.yml", "only-failure", "build"),
                ("sample.yml", "folded", "build"),
                ("sample.yml", "another-jobs-cancel", "build"),
            ])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
