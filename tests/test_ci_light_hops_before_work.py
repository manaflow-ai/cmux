#!/usr/bin/env python3
"""No pull request run waits for two light Blacksmith runners in a row before any real work.

A light job is checkout plus a python or bash decision: a placement bootstrap, a resolver, a path
router, a status post. It does seconds of work, but on Blacksmith it waits in the same queue as a
32 vCPU build. On 2026-11-19 every queued job of ~7,800 queued runs was on a Blacksmith label, and
each light job of cmux-next-fast-gates.yml waited 40-45 min for its runner: `portable light
placement`, then `resolve head and base` behind it, then the gates, then the post, 156 min created
to finished (median of the last 100 successes) for about two minutes of work.

The runner rules leave light jobs on Blacksmith (or owned capacity a placement bootstrap found idle):
GitHub-hosted Ubuntu is refused (Lawrence: Blacksmith for all CI; it queued them for hours on
cmux#45735), and a literal fleet label has no fallback once queued. What a workflow can still choose
is how many of those waits stand in a row before the work: one light job that starts with the run
waits once; a second light job that needs it waits again, after the first finished. This test fails
on such a chain: a light Blacksmith job that needs other jobs, all of whose ancestors are light
Blacksmith jobs too (nothing heavy has run yet, so the second wait is pure delay in front of work).
Light jobs after real work (a status post, a rollup) are not in front of anything and pass.

CHAINS lists the chains that were there when this test was added, each a placement bootstrap or a
router ahead of a light check. It only shrinks: a new chain fails, and a listed chain that is gone
fails until it is removed from the list, so it cannot come back.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# A run step that builds, installs or tests: one of these as a command (at a line start, after ;, &&, ||, |, (
# or $(, optionally behind sudo or a path), not a word in a message or a file name.
HEAVY_RUN = re.compile(
    r"(?m)(?:^|[;&|(]|\$\()\s*(?:sudo\s+)?(?:[\w./-]*/)?"
    r"(?:cargo|rustup|bun|bunx|npm|npx|pnpm|yarn|node|swift|xcodebuild|xcrun|zig|make|pytest|go|pip|pip3|uv"
    r"|apt|apt-get|apt-ensure\.sh|brew|docker|vp|playwright|tsc|cmake|ninja)(?=\s|$)")
PR_EVENTS = ("pull_request", "pull_request_target")
# A light job is bounded small: a decision has no business running longer (the default is 360).
LIGHT_TIMEOUT_MINUTES = 10
# Actions that take seconds and build nothing: a decision job may check out, mint a token and pass files on.
LIGHT_ACTIONS = {"actions/checkout", "actions/create-github-app-token", "actions/upload-artifact",
                 "actions/download-artifact", "actions/github-script"}

# (workflow, job, its needs) for each chain present on 2026-11-19. Only shrinks.
CHAINS = {
    ("ci.yml", "changes", ("portable-placement",)),
    ("cloudflare-relay.yml", "migration-approval", ("plan",)),
    ("cmux-next-hot-verify.yml", "again", ("target",)),
    ("cmux-next-hot-verify.yml", "request", ("rust", "target")),
    ("cmux-next-hot-verify.yml", "rust", ("target",)),
    ("cmux-next-hot-verify.yml", "web", ("target",)),
    ("cmux-tui-spec.yml", "inventory", ("changes",)),
    ("pr-checks.yml", "size", ("portable-placement",)),
    ("pr-checks.yml", "split", ("base-only", "portable-placement")),
    ("pr-checks.yml", "ui-review", ("base-only", "portable-placement")),
    ("repair-nightly-appcast-content-types.yml", "repair", ("test",)),
    ("signing-keychain-macos.yml", "real-import", ("real-import-plan",)),
    ("test-ios.yml", "package-conventions-lint", ("detect-ios-changes",)),
}


def triggers(document) -> list[str]:
    on = document.get(True, document.get("on"))
    if isinstance(on, str):
        return [on]
    return list(on or [])


def needs_of(job) -> tuple[str, ...]:
    needs = job.get("needs") or ()
    return (needs,) if isinstance(needs, str) else tuple(needs)


def on_blacksmith(job) -> bool:
    """Whether the job's runner can be a Blacksmith label: one named, or a RUNNER_POOLS read (Blacksmith pools)."""
    text = str(job.get("runs-on", ""))
    return "blacksmith-" in text or "RUNNER_POOLS" in text


def light(job) -> bool:
    """Checkout plus python or bash (LIGHT_ACTIONS beside them), at most LIGHT_TIMEOUT_MINUTES: no reusable
    workflow, build, install or test."""
    if "uses" in job or not job.get("steps"):
        return False
    try:
        if int(job.get("timeout-minutes", 360)) > LIGHT_TIMEOUT_MINUTES:
            return False
    except (TypeError, ValueError):  # an expression: not known to be small
        return False
    for step in job["steps"]:
        uses = step.get("uses")
        if uses is not None:
            if str(uses).split("@")[0] not in LIGHT_ACTIONS:
                return False
        elif HEAVY_RUN.search(str(step.get("run", ""))):
            return False
    return True


def chains(document) -> set[tuple[str, tuple[str, ...]]]:
    """(job, needs) for each light Blacksmith job that needs others and has only light Blacksmith ancestors."""
    jobs = workflow_jobs.jobs(document)
    waits = {key for key, job in jobs.items() if light(job) and on_blacksmith(job)}

    def ancestors(key, seen):
        for need in needs_of(jobs.get(key, {})):
            if need not in seen:
                seen.add(need)
                ancestors(need, seen)
        return seen

    found = set()
    for key in waits:
        needs = needs_of(jobs[key])
        if needs and ancestors(key, set()) <= waits:
            found.add((key, tuple(sorted(needs))))
    return found


def pr_workflow_chains(root: Path = WORKFLOWS) -> set[tuple[str, str, tuple[str, ...]]]:
    out = set()
    for path in sorted(root.glob("*.yml")):
        document = workflow_jobs.document(path)
        if not any(event in PR_EVENTS for event in triggers(document)):
            continue
        out |= {(path.name, key, needs) for key, needs in chains(document)}
    return out


class LightHopsBeforeWork(unittest.TestCase):
    def test_no_new_chain_of_light_blacksmith_waits(self):
        found = pr_workflow_chains()
        new = sorted(found - CHAINS)
        self.assertFalse(new, "light Blacksmith jobs waiting behind light Blacksmith jobs before any work (start the "
                              "second with the run, or fold its decision into one job): "
                              + "; ".join(f"{w}: {j} needs {', '.join(n)}" for w, j, n in new))
        gone = sorted(CHAINS - found)
        self.assertFalse(gone, "chains no longer present; remove them from CHAINS: "
                               + "; ".join(f"{w}: {j}" for w, j, _ in gone))

    def test_fast_gates_resolve_starts_with_the_run(self):
        """2026-11-19: placement then resolve, each 40-45 min queued, in front of the gates."""
        jobs = workflow_jobs.jobs(WORKFLOWS / "cmux-next-fast-gates.yml")
        self.assertEqual(needs_of(jobs["resolve"]), ())
        self.assertEqual(needs_of(jobs["fast-gates"]), ("resolve",))

    def test_detector_flags_a_placement_hop(self):
        document = {
            "on": {"pull_request": {}},
            "jobs": {
                "place": {"timeout-minutes": 4, "runs-on": "${{ fromJSON(vars.RUNNER_POOLS).linux_2 }}",
                          "steps": [{"uses": "actions/checkout@abc"}, {"run": "python3 scripts/ci/place.py"}]},
                "resolve": {"needs": "place", "timeout-minutes": 5, "runs-on": "blacksmith-2vcpu-ubuntu-2404",
                            "steps": [{"run": "git rev-parse HEAD^1"}]},
                "work": {"needs": "resolve", "runs-on": "${{ fromJSON(vars.RUNNER_POOLS).linux }}",
                         "steps": [{"run": "cargo test"}]},
                "post": {"needs": ["resolve", "work"], "timeout-minutes": 5, "runs-on": "blacksmith-2vcpu-ubuntu-2404",
                         "steps": [{"run": "gh api statuses"}]},
            },
        }
        self.assertEqual(chains(document), {("resolve", ("place",))})
        del document["jobs"]["resolve"]["needs"]
        self.assertEqual(chains(document), set())
        # Off Blacksmith (owned capacity) is not a Blacksmith wait.
        document["jobs"]["resolve"]["needs"] = "place"
        document["jobs"]["place"]["runs-on"] = "cmux-fleet-linux-x64"
        self.assertEqual(chains(document), set())


if __name__ == "__main__":
    unittest.main()
