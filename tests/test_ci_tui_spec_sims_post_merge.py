#!/usr/bin/env python3
"""cmux-tui-spec's seeded simulations skip every pull request into feat-cmux-next, full-ci included.

acpmux-sim (pull_request_skip Tier A) and carrier-sim (after merge since CI 10x) ran on full-ci heads, and land puts
full-ci on nearly every landing head: 2026-11-26 14-17Z they ran 162 and 137 times on pull request heads (511 and 173
runner-min/h). The post-merge batch and feat-cmux-next pushes run both; a pull request into another base keeps them;
the repository variable SIMS_ON_PULL_REQUESTS=on puts them back on pull requests.

Run: python3 tests/test_ci_tui_spec_sims_post_merge.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-spec.yml"
SKIP = ("(github.event_name != 'pull_request' || !startsWith(github.event.pull_request.base.ref, 'feat-cmux-next')"
        " || vars.SIMS_ON_PULL_REQUESTS == 'on')")
JOBS = ("acpmux-sim", "carrier-sim")


def job_if(job: str) -> str:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][job]["if"]


def top_level_conjuncts(expr: str) -> list[str]:
    """EXPR's `&&` operands at paren depth 0 (outside quotes), with the ${{ }} stripped."""
    body = expr.strip()
    if body.startswith("${{") and body.endswith("}}"):
        body = body[3:-2].strip()
    parts, depth, quote, start, i = [], 0, False, 0, 0
    while i < len(body):
        c = body[i]
        if c == "'":
            quote = not quote
        elif not quote and c == "(":
            depth += 1
        elif not quote and c == ")":
            depth -= 1
        elif not quote and depth == 0 and body.startswith("&&", i):
            parts.append(body[start:i].strip())
            start = i + 2
            i += 1
        i += 1
    parts.append(body[start:].strip())
    return parts


class SimsPostMerge(unittest.TestCase):
    def test_each_sim_carries_the_skip_as_a_top_level_conjunct(self):
        for job in JOBS:
            with self.subTest(job=job):
                self.assertIn(SKIP, top_level_conjuncts(job_if(job)), job_if(job))

    def test_the_skip_is_not_lifted_by_full_ci(self):
        self.assertNotIn("full-ci", SKIP)

    def test_acpmux_sim_keeps_the_pull_request_skip_clause(self):
        # scripts/ci/affected_jobs.py check holds every pull_request_skip job to PR_SKIP_IF verbatim.
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import affected_jobs  # noqa: E402

        self.assertIn(affected_jobs.PR_SKIP_IF, job_if("acpmux-sim"))

    def test_a_push_never_reads_the_skip(self):
        self.assertTrue(SKIP.startswith("(github.event_name != 'pull_request' ||"))
        self.assertTrue(re.search(r"!startsWith\(github\.event\.pull_request\.base\.ref, 'feat-cmux-next'\)", SKIP))


if __name__ == "__main__":
    sys.exit(unittest.main())
