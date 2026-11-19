#!/usr/bin/env python3
"""Every Linux job of cmux-tui-artifacts.yml takes the one Linux label, cmux-linux.

On 2026-10-30 from about 05:20Z every cmux-tui artifacts run on feat-cmux-next
sat queued on blacksmith-4vcpu-ubuntu-2404: run 41007923202's tree preflight
waited 4 minutes for a runner, and mark-tree-commits and point-feat-channel,
about 10 seconds of work each, were still queued 15 minutes later. nightly-next
promotion waits on the tree marker those jobs publish, so the NEXT nightly feed
stalled behind them.

The jobs then read a declared set (LINUX_RUNNER, the RUNNER_POOLS size and
failover, the overflow switch, owned GCP labels on the nightly path). A label is
fixed when a job queues, so none of that moved a job already waiting. Since
cmuxterm-hq#14156 ("capacity comes to the job") every own-branch Linux job here
says the literal cmux-linux and the provider brings a runner to it; no
repository variable, pool, overflow record or picker output changes that.

This evaluates every Linux runs-on of the workflow for each variable state and
checks the answer is cmux-linux. A fork keeps GitHub-hosted Ubuntu.
"""

from __future__ import annotations

import itertools
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from runs_on_labels import resolve_labels  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
LABEL = "cmux-linux"
BIG = "blacksmith-32vcpu-ubuntu-2404"
SMALL = "blacksmith-16vcpu-ubuntu-2404"


def resolved(runs_on: str, owner: str, linux_runner: str, overflow: str, trusted: str,
             darwin_cross: str = "") -> set[str]:
    """Resolve the route for these variable values, keeping picker contexts silent."""
    return resolve_labels(
        runs_on,
        owner=owner,
        variables={
            "LINUX_RUNNER": [linux_runner],
            "CI_CLOUD_OVERFLOW_SAVED": [overflow],
            "CI_TRUSTED_RUNNER": [trusted],
            "LINUX_RUNNER_DARWIN_CROSS": [darwin_cross],
        },
        silent=("needs",),
    )
# A non-Blacksmith Linux pool LINUX_RUNNER may name (the GCP pool, say).
POOL = "gcp-linux-pool"
# The overflow switch writes GitHub-hosted Ubuntu into LINUX_RUNNER when it fails over.
HOSTED = "ubuntu-24.04"
# The job that had its own override: the Darwin cross-compile shadow.
DARWIN_CROSS_JOB = "macos-cross-shadow"
DARWIN_CROSS = "darwin-cross-pool"
# The owned GCP runners the nightly path's attempt 1 used to take first.
OWNED = "cmux-gcp-lane-build-x64"
NIGHTLY = "cmux-gcp-nightly-x64"
# The jobs a NEXT nightly waits for.
NIGHTLY_TREE_JOBS = ("tree-preflight", "tree-owner-wait", "publish", "publish-tree", "mark-tree-commits")
OVERFLOW_RECORD = '{"probe":"blacksmith-4vcpu-ubuntu-2404"}'
# The short jobs that sat queued on 2026-10-30; each must stay a Linux job.
SHORT_JOBS = (
    "reject-untrusted-pin-ref",
    "tree-preflight",
    "tree-owner-wait",
    "darwin-fallback-plan",
    "publish-ref-notice",
    "sentry-dsyms",
    "publish-tree-tested",
    "point-feat-channel",
    "point-machine-channel",
    "mark-tree-commits",
    "request-nightly-next",
    "notify-unpublished-tree",
)
LINUX_RUNNER_VALUES = (
    "",
    "blacksmith-2vcpu-ubuntu-2404",
    "blacksmith-4vcpu-ubuntu-2404",
    SMALL,
    BIG,
    POOL,
    HOSTED,
)
TRUSTED_RUNNER_VALUES = ("", "ubuntu-24.04", "blacksmith-4vcpu-ubuntu-2404")
# What a Linux job's runs-on no longer reads (cmuxterm-hq#14156).
RETIRED_READS = ("vars.LINUX_RUNNER", "RUNNER_POOLS", "CI_CLOUD_OVERFLOW_SAVED", "CI_TRUSTED_RUNNER", "needs.",
                 OWNED, NIGHTLY)


def linux_routes() -> list[tuple[str, str]]:
    """(job, route) for every Linux route: each matrix cell of a runs-on (`${{ matrix.runner }}` read as its
    values) is a route of its own. A runs-on with a matrix value nothing resolves fails, never drops out."""
    routes = []
    for name, job in yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"].items():
        cells = workflow_jobs.runs_on_cells(job)
        if cells is None:
            raise AssertionError(f"{WORKFLOW.name}#{name}: runs-on has a matrix value nothing resolves")
        routes.extend((name, runs_on) for runs_on in cells if "ubuntu" in runs_on or LABEL in runs_on)
    return routes


class CmuxTuiArtifactsLinuxRunnerSetTest(unittest.TestCase):
    def test_the_short_jobs_are_linux_jobs_of_this_workflow(self) -> None:
        names = {name for name, _ in linux_routes()}
        for name in SHORT_JOBS:
            with self.subTest(job=name):
                self.assertIn(name, names)

    def test_every_linux_job_reads_no_variable_pool_or_picker(self) -> None:
        for name, runs_on in linux_routes():
            for read in RETIRED_READS:
                with self.subTest(job=name, read=read):
                    self.assertNotIn(read, runs_on)

    def test_every_linux_job_takes_cmux_linux_whatever_the_variables_say(self) -> None:
        # The overflow switch, LINUX_RUNNER (a Blacksmith size, a pool, hosted Ubuntu) and the trusted-runner
        # variable no longer move a job; overflow is more runners on the same label.
        routes = linux_routes()
        for (name, runs_on), linux_runner, overflow, trusted in itertools.product(
            routes, LINUX_RUNNER_VALUES, ("", OVERFLOW_RECORD), TRUSTED_RUNNER_VALUES
        ):
            labels = resolved(runs_on, "manaflow-ai", linux_runner, overflow, trusted)
            with self.subTest(job=name, linux_runner=linux_runner, overflow=bool(overflow), trusted=trusted):
                self.assertEqual(labels, {LABEL})

    def test_no_job_reads_the_darwin_cross_override(self) -> None:
        # macos-cross-shadow read LINUX_RUNNER_DARWIN_CROSS; it now takes cmux-linux like the rest.
        names = {name for name, _ in linux_routes()}
        self.assertIn(DARWIN_CROSS_JOB, names)
        for name, runs_on in linux_routes():
            for linux_runner in ("", POOL):
                with self.subTest(job=name, linux_runner=linux_runner):
                    labels = resolved(runs_on, "manaflow-ai", linux_runner, "", "", DARWIN_CROSS)
                    self.assertNotIn(DARWIN_CROSS, labels)

    def test_the_nightly_path_takes_cmux_linux_on_every_attempt(self) -> None:
        # 2026-11-18: tree preflights waited 11-56+ min on blacksmith-2vcpu and -4vcpu behind PR CI under the
        # Blacksmith vCPU cap, and the nightly path moved to owned GCP labels on attempt 1. Since
        # cmuxterm-hq#14156 every Linux job of the tree path (this workflow's, the build package's, the tree
        # request) takes cmux-linux on every attempt and ref, so a nightly-next tree never waits on a lane label.
        routes = [(WORKFLOW.name, name, runs_on) for name, runs_on in linux_routes() if name in NIGHTLY_TREE_JOBS]
        self.assertEqual({name for _, name, _ in routes}, set(NIGHTLY_TREE_JOBS))
        for workflow in ("cmux-tui-build-package.yml", "cmux-tui-tree-request.yml"):
            jobs = yaml.load((WORKFLOW.parent / workflow).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
            routes.extend((workflow, name, job["runs-on"]) for name, job in jobs.items()
                          if f"'{LABEL}'" in str(job.get("runs-on", "")))
        self.assertGreaterEqual(len(routes), len(NIGHTLY_TREE_JOBS) + 3)
        nightly = {"event": "'push'", "ref": "'refs/heads/feat-cmux-next'", "attempt": "1"}
        cases = (
            ("feat-cmux-next push", nightly),
            ("nightly-next push", {**nightly, "ref": "'refs/heads/nightly-next'"}),
            ("dispatch", {**nightly, "event": "'workflow_dispatch'", "ref": "'refs/heads/feat-cmux-next'"}),
            ("re-run", {**nightly, "attempt": "2"}),
            ("lane push", {**nightly, "ref": "'refs/heads/lane/x'"}),
        )
        for workflow, name, runs_on in routes:
            for case, values in cases:
                text = runs_on.replace("github.run_attempt", values["attempt"])
                text = text.replace("github.event_name", values["event"])
                text = re.sub(r"\bgithub\.ref\b", values["ref"], text)
                text = text.replace("github.workflow_ref",
                                    "'manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/x'")
                for linux_runner in LINUX_RUNNER_VALUES:
                    labels = resolve_labels(text, owner="manaflow-ai", silent=("needs", "inputs"), variables={
                        "LINUX_RUNNER": [linux_runner], "CI_CLOUD_OVERFLOW_SAVED": [""]})
                    with self.subTest(workflow=workflow, job=name, case=case, linux_runner=linux_runner):
                        self.assertEqual(labels, {LABEL})

    def test_a_fork_keeps_github_hosted_ubuntu(self) -> None:
        for name, runs_on in linux_routes():
            with self.subTest(job=name):
                self.assertEqual(resolved(runs_on, "someone-else", "", "", ""), {"ubuntu-24.04"})


# The routes that can name an owned self-hosted Linux label whose runner user has no sudo:
# cmux-gcp-lane-build-x64, the build-lane runners on the GCP agent lanes (cmuxterm-hq
# build-fleet/swift-linux-builder/lane-build-runners). LINUX_BUILD_RUNNER and LINUX_RUNNER_DARWIN_CROSS name it,
# the placement steps hand it on as a needs output or a reusable workflow's runner input, and a matrix runner
# carries it in the workflows that read those variables. The nightly path names the label itself (6763b318).
OWNED_ROUTE = re.compile(
    r"vars\.(?:LINUX_BUILD_RUNNER|LINUX_RUNNER_DARWIN_CROSS|CMUX_TUI_GATE_RUNNER)\b"
    r"|inputs\.linux(?:_build)?_runner\b"
    r"|needs\.[\w-]+\.outputs\.[\w-]*runner\b"
    r"|'cmux-gcp-lane-build[\w-]*'"
)
SUDO = re.compile(r"(?<![\w-])sudo(?![\w-])")
APT_INSTALL = re.compile(r"\bapt(?:-get)?\s+(?:[^|;&\n]*\s)?install\b")


def owned_routable_jobs() -> list[tuple[str, str, dict]]:
    """(workflow, job, body) for every job whose runs-on can resolve to an owned label."""
    found = []
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        if not OWNED_ROUTE.search(text):
            continue
        for name, job in workflow_jobs.jobs(path).items():
            runs_on = workflow_jobs.runs_on(job)
            if OWNED_ROUTE.search(runs_on) or "matrix." in runs_on:
                found.append((path.name, name, job))
    return found


class OwnedRunnerNeedsNoPasswordTest(unittest.TestCase):
    """A job that can land on an owned runner never asks sudo for a password.

    On 2026-11-18 LINUX_BUILD_RUNNER named cmux-gcp-lane-build-x64 and every musl leg of run 44363923089
    died in its first step, `sudo apt-get install ... musl-tools`, with "sudo: a password is required": that
    label's runner user has no sudo. Such a job installs packages through scripts/ci/apt-ensure.sh (nothing
    to do when the image has them; `sudo -n` otherwise, failing at once with the packages to provision), and
    any other sudo it runs is `sudo -n`. A step only GitHub-hosted runners take is exempt.
    """

    def test_the_musl_legs_are_found(self) -> None:
        names = {(workflow, job) for workflow, job, _ in owned_routable_jobs()}
        self.assertIn(("cmux-tui-build-package.yml", "build"), names)

    def test_no_password_prompt_on_an_owned_route(self) -> None:
        for workflow, name, job in owned_routable_jobs():
            for step in job.get("steps") or []:
                run = step.get("run")
                if not isinstance(run, str) or "github-hosted" in str(step.get("if", "")):
                    continue
                for line in run.splitlines():
                    with self.subTest(workflow=workflow, job=name, step=step.get("name"), line=line.strip()):
                        self.assertIsNone(
                            APT_INSTALL.search(line),
                            "install packages with scripts/ci/apt-ensure.sh PACKAGE..., not apt-get install",
                        )
                        for match in SUDO.finditer(line):
                            self.assertTrue(line[match.end():].lstrip().startswith("-n"), "use sudo -n")

    def test_the_detector_flags_the_failing_step(self) -> None:
        self.assertTrue(APT_INSTALL.search("sudo apt-get install -y binutils clang musl-tools"))
        self.assertTrue(APT_INSTALL.search("sudo apt-get -o DPkg::Lock::Timeout=300 install -y zsh"))
        self.assertIsNone(APT_INSTALL.search("bash scripts/ci/apt-ensure.sh musl-tools"))
        self.assertTrue(OWNED_ROUTE.search("${{ needs.tree-preflight.outputs.linux_build_runner || '' }}"))
        self.assertTrue(OWNED_ROUTE.search("github.run_attempt == 1 && 'cmux-gcp-lane-build-x64' || vars.LINUX_RUNNER"))


if __name__ == "__main__":
    unittest.main()


class NightlyTreeLegsTakeTheNightlyRunners(unittest.TestCase):
    """2026-11-19: tree run 44431930226 (03103fd) never started on cmux-gcp-lane-build-x64, whose runners
    newer PR legs kept busy. Since cmuxterm-hq#14156 a tree's macOS leg (LINUX_DARWIN_RUNNER) takes the one
    Linux label, cmux-linux, like every other leg, on a nightly-next push, a dispatch and a feat-cmux-next push."""

    def test_the_macos_leg_of_a_nightly_next_tree_takes_cmux_linux(self) -> None:
        package = yaml.load((WORKFLOW.parent / "cmux-tui-build-package.yml").read_text(encoding="utf-8"),
                            Loader=yaml.BaseLoader)["jobs"]["plan-build"]
        expr = next(step for step in package["steps"] if step.get("id") == "targets")["env"]["LINUX_DARWIN_RUNNER"]
        artifacts = "'manaflow-ai/cmux/.github/workflows/cmux-tui-artifacts.yml@refs/heads/x'"
        for ref, event in (("'refs/heads/nightly-next'", "'push'"),
                           ("'refs/heads/feat-cmux-next'", "'workflow_dispatch'"),
                           ("'refs/heads/feat-cmux-next'", "'push'")):
            text = (expr.replace("github.run_attempt", "1").replace("github.event_name", event)
                    .replace("github.workflow_ref", artifacts))
            text = re.sub(r"\bgithub\.ref\b", ref, text)
            labels = resolve_labels(text, owner="manaflow-ai", silent=("needs", "inputs"), variables={
                "LINUX_RUNNER_DARWIN_CROSS": [OWNED], "LINUX_RUNNER": ["blacksmith-2vcpu-ubuntu-2404"],
                "CI_CLOUD_OVERFLOW_SAVED": [""]})
            with self.subTest(ref=ref, event=event):
                self.assertEqual(labels, {LABEL})

    def test_the_shared_lane_placement_skips_nightly_next(self) -> None:
        preflight = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]["tree-preflight"]
        step = next(step for step in preflight["steps"] if step.get("id") == "gcp-placement")
        self.assertIn("refs/heads/feat-cmux-next", step["if"])
        self.assertNotIn("nightly-next", step["if"])
