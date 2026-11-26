#!/usr/bin/env python3
"""No job's runs-on names a vendor runner label with no repository variable in front of it.

Leo, 2026-10-28 (ask-973a915bea), told that nightly.yml named `blacksmith-4vcpu-ubuntu-2404` literally, so a
re-run could not move it off a label that had stopped starting jobs: "Where the f*** are the generalized solution
to all these f***ing problems that these incessant f***ing pins?"

A runs-on that names a Blacksmith, Depot or WarpBuild label must also read a `vars.` expression, so changing a
repository variable (RUNNER_POOLS, which scripts/ci/runner_pools.py keeps on a live member of each pool in
.github/runners.json) moves the job without a commit. The literal stays as the fallback, so an unset variable
changes nothing. The usual form is a bounded pool read:

    contains(fromJSON('["<literal>","<next member>"]'), fromJSON(vars.RUNNER_POOLS || '{}').<pool>)
        && fromJSON(vars.RUNNER_POOLS || '{}').<pool> || '<literal>'

A value that feeds a runs-on counts as that runs-on: each matrix entry a `${{ matrix.KEY }}` runs-on reads, and
each `*runner` input a reusable-workflow call passes. tests/test_ci_runner_set.py takes any matrix read as live, so a
literal written into the matrix (relay-publish-npm.yml's smoke legs) was a pin neither test saw.

PINNED lists the jobs another rule requires to name a literal label, each with that rule. It only shrinks: a job
not in it fails, and an entry whose job now reads a variable (or is gone) fails too, so it is removed.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
VENDOR_LABEL = re.compile(r"\b(?:blacksmith|depot|warp)-[A-Za-z0-9.-]+")
VARIABLE = re.compile(r"\bvars\.[A-Za-z0-9_]+")

SIGNING = ("holds a signing secret: rule 7 of tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py "
           "requires a literal ephemeral label that no repository variable can move")
VERIFY = ("verifies a signed release artifact: tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py "
          "requires its exact literal runs-on")

# workflow file -> (the rule that keeps its label literal, the jobs it covers)
PINNED: dict[str, tuple[str, set[str]]] = {
    "auto-resume-nightly-notarization.yml": (
        SIGNING + "; verify-stapled: " + VERIFY,
        {"generate-deltas", "staple-outer", "staple-stapled", "verify-stapled", "wait-and-staple"}),
    "cmux-next-cua-helper-dev-sign.yml": (SIGNING, {"sign"}),
    "cmux-next-dev-daily.yml": (
        SIGNING + "; verify: " + VERIFY + "; tip-dmg-build: tests/test_cmux_next_dev_tip_feed.py and "
        "tests/test_ci_owned_pool_rescue.py read its exact fallback label",
        {"tip-deltas", "tip-dmg-build", "verify"}),
    "coderouter-release.yml": (
        "its matrix legs hold the release environment and a Developer ID keychain (tests/"
        "test_ci_signing_keychain_is_deleted_before_bundle_code.py INLINE_DEVELOPER_ID_KEYCHAINS): rule 7 keeps a "
        "signing job on a literal label, and macos-latest, Linux arm64 and Windows each have one image",
        {"build"}),
    "cmux-tui-testbox-warmup.yml": (
        "tests/test_ci_testbox_broker_guard.py requires its runs-on to be one label declared in .github/actionlint.yaml",
        {"cmux-tui-rust"}),
    "fast-checks.yml": (
        "admission is broker-controlled and must not trust mutable repository variables; "
        "tests/test_ci_fork_runner_routing.py pins its exact expression (FAST_CHECKS_ADMISSION_EXPRESSION)",
        {"admit", "checks"}),
    "ios-app-review-readiness.yml": (SIGNING, {"app-store-connect", "store-declarations"}),
    "ios-app-store.yml": (SIGNING, {"upload-and-validate"}),
    "ios-appstore-upload.yml": (SIGNING, {"upload"}),
    "ios-asc-ops.yml": (SIGNING, {"op"}),
    "ios-screenshots.yml": (SIGNING, {"app-store-upload"}),
    "ios-streamed-validate.yml": (
        "tests/test_ci_pr_runner_pool.py requires streamed validation to stay on its exact Blacksmith label", {"validate"}),
    "iroh-release-gate.yml": (
        "tests/test_ci_pr_runner_pool.py requires simulator-e2e to stay on its exact Blacksmith label", {"simulator-e2e"}),
    "nightly-sign.yml": (
        "a shadow signing job: tests/test_nightly_sign_shadow_workflow.py forbids vars.RUNNER_POOLS in its runs-on",
        {"admit"}),
    "nightly.yml": (
        SIGNING + "; verify-signed-nightly: " + VERIFY,
        {"build-sign-notarize-nightly", "promote-nightly-next", "promote-nightly-next-acked", "publish-nightly",
         "verify-signed-nightly"}),
    "rcodesign-parity-proof.yml": (
        SIGNING, {"sign-codesign", "sparkle"}),
    "release.yml": (SIGNING, {"build-sign-notarize"}),
    "repair-v0-64-25-helper-rpaths.yml": (SIGNING, {"repair"}),
    "resume-nightly-notarization.yml": (SIGNING + "; verify-stapled: " + VERIFY, {"resume", "verify-stapled"}),
}


def unmovable(runs_on: object) -> bool:
    """Whether RUNS_ON names a vendor label and reads no repository variable."""
    text = str(runs_on)
    return bool(VENDOR_LABEL.search(text)) and not VARIABLE.search(text)


MATRIX_READ = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")


def feeding(job: dict) -> list[object]:
    """What JOB runs on: its runs-on, or the matrix values or reusable-workflow runner inputs that choose it."""
    values: list[object] = []
    if "runs-on" in job:
        runs_on = job["runs-on"]
        read = MATRIX_READ.match(str(runs_on).strip())
        matrix = (job.get("strategy") or {}).get("matrix")
        if read and isinstance(matrix, dict):
            key = read.group(1)
            column = matrix.get(key)
            values.extend(column if isinstance(column, list) else [column] if column is not None else [])
            values.extend(entry[key] for entry in matrix.get("include") or []
                          if isinstance(entry, dict) and key in entry)
        else:
            values.append(runs_on)
    if "uses" in job:
        values.extend(value for key, value in (job.get("with") or {}).items() if str(key).endswith("runner"))
    return values


def jobs() -> list[tuple[str, str, object]]:
    found = []
    for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                found.extend((path.name, str(name), value) for value in feeding(job))
    return found


class RuleTests(unittest.TestCase):
    def test_a_literal_vendor_label_is_unmovable(self) -> None:
        fork = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
        for runs_on in (
            "blacksmith-4vcpu-ubuntu-2404",
            "${{ " + fork + "'blacksmith-4vcpu-ubuntu-2404' }}",
            "${{ " + fork + "github.run_attempt == 1 && 'cmux-gcp-nightly-jit-x64' || 'blacksmith-2vcpu-ubuntu-2404' }}",
            "${{ " + fork + "needs.pick.outputs.runner || 'blacksmith-6vcpu-macos-26' }}",
            ["self-hosted", "warp-ubuntu-latest-x64-4x"],
            "depot-ubuntu-24.04",
        ):
            with self.subTest(runs_on=runs_on):
                self.assertTrue(unmovable(runs_on))

    def test_a_variable_in_front_of_the_literal_is_movable(self) -> None:
        fork = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
        pool = "fromJSON(vars.RUNNER_POOLS || '{}').linux_4"
        for runs_on in (
            "${{ " + fork + "contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-16vcpu-ubuntu-2404\"]'), "
            + pool + ") && " + pool + " || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "${{ " + fork + "vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
            # No vendor label at all: nothing to move.
            "${{ " + fork + "'cmux-linux' }}",
            "ubuntu-24.04",
        ):
            with self.subTest(runs_on=runs_on):
                self.assertFalse(unmovable(runs_on))


class FeedingTests(unittest.TestCase):
    def test_matrix_values_and_runner_inputs_are_what_the_job_runs_on(self) -> None:
        job = {"runs-on": "${{ matrix.os }}",
               "strategy": {"matrix": {"os": ["ubuntu-24.04"], "include": [{"os": "blacksmith-6vcpu-macos-15"}]}}}
        self.assertEqual(feeding(job), ["ubuntu-24.04", "blacksmith-6vcpu-macos-15"])
        self.assertTrue(any(unmovable(value) for value in feeding(job)))
        call = {"uses": "./.github/workflows/x.yml", "with": {"macos_retry_runner": "blacksmith-6vcpu-macos-15",
                                                              "checkout_ref": "blacksmith-is-not-a-runner"}}
        self.assertEqual(feeding(call), ["blacksmith-6vcpu-macos-15"])
        # A runs-on that is more than one matrix read is judged as written.
        self.assertEqual(feeding({"runs-on": "${{ matrix.os || 'x' }}"}), ["${{ matrix.os || 'x' }}"])


class WorkflowTests(unittest.TestCase):
    def test_no_job_names_a_vendor_label_no_variable_can_move(self) -> None:
        pinned = {(path, job) for path, (_, names) in PINNED.items() for job in names}
        failing = {(path, name) for path, name, runs_on in jobs() if unmovable(runs_on)}
        new = sorted(failing - pinned)
        self.assertEqual(new, [], "these jobs name a vendor runner label that only a commit can move; put a "
                                  "repository variable in front of it (fromJSON(vars.RUNNER_POOLS || '{}').<pool>, "
                                  "bounded to the pool's labels), keeping the literal as the fallback")
        stale = sorted(pinned - failing)
        self.assertEqual(stale, [], "these PINNED jobs now read a variable or are gone; remove them")

    def test_every_pinned_entry_names_its_rule(self) -> None:
        for path, (why, names) in PINNED.items():
            with self.subTest(workflow=path):
                self.assertTrue(why.strip() and names)


if __name__ == "__main__":
    unittest.main()
