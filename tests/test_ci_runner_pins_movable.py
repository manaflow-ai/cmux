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
    "billing-nightly.yml": (
        SIGNING + "; alert: tests/test_ci_billing_nightly.py requires every secret job on a literal runner",
        {"alert", "apple-api", "apple-delivery", "apple-post-release"}),
    "cmux-next-cua-helper-dev-sign.yml": (SIGNING, {"sign"}),
    "cmux-next-dev-daily.yml": (
        SIGNING + "; verify: " + VERIFY + "; tip-dmg-build: tests/test_cmux_next_dev_tip_feed.py and "
        "tests/test_ci_owned_pool_rescue.py read its exact fallback label",
        {"publish", "sign", "tip-deltas", "tip-dmg", "tip-dmg-build", "verify"}),
    "cmux-tui-testbox-warmup.yml": (
        "tests/test_ci_testbox_broker_guard.py requires its runs-on to be one label declared in .github/actionlint.yaml",
        {"cmux-tui-rust"}),
    "fast-checks.yml": (
        "admission is broker-controlled and must not trust mutable repository variables; "
        "tests/test_ci_fork_runner_routing.py pins its exact expression (FAST_CHECKS_ADMISSION_EXPRESSION)",
        {"admit", "checks"}),
    "ios-app-review-readiness.yml": (SIGNING, {"app-store-connect"}),
    "ios-app-store.yml": (SIGNING, {"upload-and-validate"}),
    "ios-appstore-upload.yml": (SIGNING, {"assign-internal", "set-testflight-notes", "upload"}),
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
        SIGNING, {"notarize-app", "notarize-dmg", "prep", "sign-codesign", "sign-rcodesign", "sparkle"}),
    "release.yml": (SIGNING, {"build-sign-notarize"}),
    "repair-v0-64-25-helper-rpaths.yml": (SIGNING, {"repair"}),
    "resume-nightly-notarization.yml": (SIGNING + "; verify-stapled: " + VERIFY, {"resume", "verify-stapled"}),
}


def unmovable(runs_on: object) -> bool:
    """Whether RUNS_ON names a vendor label and reads no repository variable."""
    text = str(runs_on)
    return bool(VENDOR_LABEL.search(text)) and not VARIABLE.search(text)


def jobs() -> list[tuple[str, str, object]]:
    found = []
    for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict) and "runs-on" in job:
                found.append((path.name, str(name), job["runs-on"]))
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
