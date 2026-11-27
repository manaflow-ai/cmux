#!/usr/bin/env python3
"""No same-repository macOS job is pinned to a paid queue: it offers an owned Mac before Blacksmith.

Leo, 2026-11-14, on run 43645667029 (cmux NEXT helper (dev) signing #11), whose
"Build the unsigned helper" job sat in "Waiting for a runner" on
blacksmith-6vcpu-macos-26: "but it's getting queued on blacksmith...". The
job's runs-on read `fromJSON(vars.RUNNER_POOLS).macos_26 || 'blacksmith-...'`,
and RUNNER_POOLS holds only Blacksmith labels (runner_pools.py), so a job its
header called "an owned Mac first" could only ever wait on Blacksmith.

The routing order is Linux, then owned Macs, then Blacksmith macOS as the last
fallback. This guard finds every job whose runs-on can resolve to a Blacksmith
macOS label (a literal, vars.MACOS_RUNNER_*, or a RUNNER_POOLS macos key) for a
run of this repository, after the fork branches are taken out (a fork or a fork
pull request may take Blacksmith or GitHub-hosted: it has no fleet), and fails
when that runs-on offers no owned pool. "Offers an owned pool" is
owned_pool_sources.py's own reading (a glaeda label, an owned-pool variable
such as CI_SIDE_LANE_RUNNER, a pool picker's output), plus a reusable
workflow's runner input that a caller passes such a value.

A job that must stay on an ephemeral Mac is listed in PAID_ONLY_JOBS with why.
A listed job that offers an owned pool now, or no longer exists, fails too, so
the list only shrinks. Each branch carries its own copy, read against its own tree (main's
from cmux#43319, this one for feat-cmux-next, cmuxterm-hq retro re46a1d4b). The handbook pattern page "job pinned to a paid queue"
(cmuxterm-hq docs/handbook) names this test as its detector.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import owned_pool_sources as sources  # noqa: E402

# A Blacksmith macOS label, a MACOS_RUNNER_* variable (runner_label_policy.py keeps
# owned labels out of them) or a RUNNER_POOLS macos key (Blacksmith only).
PAID_MACOS = re.compile(r"blacksmith-\d+vcpu-macos-[a-z0-9]+|\bvars\.MACOS_RUNNER_[A-Z0-9_]+|\.macos_[a-z0-9_]+\b")
# The fork branches: `github.repository_owner != 'manaflow-ai' && '<hosted>'` (a fork's own
# repository) and a fork pull request's `... head.repo.full_name != github.repository [&& !contains(...)]
# && '<label>'`. Only these short-circuits are taken out; anything after them still counts.
FORK_BRANCHES = (
    re.compile(r"github\.repository_owner != 'manaflow-ai' && '[^']+'"),
    re.compile(r"github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name "
               r"!= github\.repository(?: && !contains\([^)]*\)\))? && \(?(?:startsWith\([^)]*\) && "
               r"inputs\.[a-z_]+ \|\| )?'[^']+'\)?"),
)

SIGNING = ("holds a release signing, notary or App Store key; an owned Mac takes such a job only as a glaeda "
           "SIGNING_JOBS entry (exclusive claim, scripts/ci/signing-runner-claim.sh), which this job is not")
EPHEMERAL_MACHINE = ("creates a disposable machine user while holding the environment's Stack secrets; an owned "
                     "Mac would leak the user or leave the job's access on a shared runner")
SYSTEM_KEYCHAIN = ("adds a trust root to the System keychain as root; the shared owned Mac runner user cannot "
                   "perform that operation safely and the keychain state must die with the VM")
HOSTED_TIMING = ("is an explicit hosted launch-TTI timing measurement; changing it to an owned pool would make the "
                 "before/after queue and startup measurement incomparable")
# Jobs that stay on an ephemeral Mac, each with why. Keyed (workflow file name, job key).
PAID_ONLY_JOBS: dict[tuple[str, str], str] = {
    ("auto-resume-nightly-notarization.yml", "wait-and-staple"): SIGNING,
    ("auto-resume-nightly-notarization.yml", "staple-outer"): SIGNING,
    ("ios-app-store.yml", "upload-and-validate"): SIGNING,
    ("ios-appstore-upload.yml", "upload"): SIGNING,
    ("resume-nightly-notarization.yml", "resume"): SIGNING,
    ("cmux-tui-team-signed.yml", "sign"): SIGNING + " (Developer ID, environment release-next)",
    ("cmux-tui-team-signed.yml", "sign-helper"): SIGNING + " (Developer ID, environment release-next)",
    ("ios-internal-nightly.yml", "upload"): SIGNING + " (App Store Connect key and iOS distribution certificate)",
    ("ios-testflight.yml", "upload"): SIGNING + " (App Store Connect key and iOS distribution certificate)",
    ("ios-launch-tti-hosted.yml", "measure"): HOSTED_TIMING,
    ("machine-vault-e2e.yml", "e2e"): EPHEMERAL_MACHINE,
    ("relay-tls.yml", "system-keychain"): SYSTEM_KEYCHAIN,
}


def strip_fork_branches(runs_on: str) -> str:
    for pattern in FORK_BRANCHES:
        runs_on = pattern.sub("", runs_on)
    return runs_on


def owned_inputs(workflows: dict[str, sources.Workflow]) -> dict[str, set[str]]:
    """{reusable workflow path: its inputs some caller passes an owned value}."""
    found: dict[str, set[str]] = {}
    for path, workflow in workflows.items():
        for key, job in workflow.jobs.items():
            uses = sources.LOCAL_USES.match(str(job.get("uses") or ""))
            given = job.get("with") if isinstance(job.get("with"), dict) else {}
            if not uses:
                continue
            for name, value in given.items():
                if workflow.why(str(value), key, set()):
                    found.setdefault(uses.group(1), set()).add(str(name))
    return found


def read_inputs(workflow: sources.Workflow, key: str, runs_on: str) -> set[str]:
    """The inputs a runs-on reads, directly or through its matrix and the jobs whose outputs it reads."""
    texts, seen, names = [runs_on], set(), set()
    if "matrix." in runs_on:
        texts.append(str((workflow.jobs.get(key, {}).get("strategy") or {}).get("matrix")))
    while texts:
        text = texts.pop()
        names |= set(sources.INPUT_REF.findall(text))
        for producer in sources.NEEDS_OUTPUT.findall(text):
            if producer in workflow.jobs and producer not in seen:
                seen.add(producer)
                texts.append(str({k: v for k, v in workflow.jobs[producer].items() if k != "name"}))
    return names


def pinned_jobs(tree: sources.Tree) -> dict[tuple[str, str], str]:
    """{(workflow file, job): runs-on} for each same-repository macOS job that offers only a paid queue."""
    markers = sources.Markers(tree)
    workflows = {path: sources.Workflow(markers, tree, path, sources._load(tree.read(path) or ""))
                 for path in tree.workflows()}
    passed = owned_inputs(workflows)
    pinned = {}
    for path, workflow in workflows.items():
        for key, job in workflow.jobs.items():
            runs_on = str(job.get("runs-on") or "")
            if not PAID_MACOS.search(strip_fork_branches(runs_on)):
                continue
            if workflow.why(runs_on, key, set()):
                continue
            if read_inputs(workflow, key, runs_on) & passed.get(path, set()):
                continue
            pinned[(path.rsplit("/", 1)[-1], key)] = runs_on
    return pinned


class PaidQueuePin(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.pinned = pinned_jobs(sources.Tree(ROOT))

    def test_no_job_is_pinned_to_a_paid_queue(self) -> None:
        unlisted = {job: runs_on for job, runs_on in self.pinned.items() if job not in PAID_ONLY_JOBS}
        self.assertFalse(unlisted, "\n".join(
            ["these same-repository macOS jobs can only wait on a Blacksmith queue. Offer an owned Mac first "
             "(attempt 1 takes vars.CI_LIGHT_LANE_RUNNER || vars.CI_SIDE_LANE_RUNNER behind vars.CI_PR_POOL_OWNED, "
             "Blacksmith last, and list the workflow in owned_pool_rescue.SIDE_WORKFLOW_PATHS), or add the job to "
             "PAID_ONLY_JOBS with why it must stay on an ephemeral Mac:"]
            + [f"  {path}:{job}: {runs_on}" for (path, job), runs_on in sorted(unlisted.items())]))

    def test_the_paid_only_list_only_shrinks(self) -> None:
        stale = sorted(job for job in PAID_ONLY_JOBS if job not in self.pinned)
        self.assertFalse(stale, "\n".join(
            ["these PAID_ONLY_JOBS entries offer an owned pool now or no longer exist; remove them:"]
            + [f"  {path}:{job}" for path, job in stale]))

    def test_the_detector_reads_the_shapes_it_must(self) -> None:
        paid = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || fromJSON(vars.RUNNER_POOLS || '{}').macos_26 || 'blacksmith-6vcpu-macos-26' }}"
        self.assertTrue(PAID_MACOS.search(strip_fork_branches(paid)))
        fork_only = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' "
                     "&& github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' "
                     "|| vars.CI_SIDE_LANE_RUNNER }}")
        self.assertFalse(PAID_MACOS.search(strip_fork_branches(fork_only)))
        self.assertFalse(PAID_MACOS.search(strip_fork_branches(
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'ubuntu-24.04' }}")))
        self.assertTrue(PAID_MACOS.search("${{ vars.MACOS_RUNNER_15 || 'x' }}"))


if __name__ == "__main__":
    unittest.main()
