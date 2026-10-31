#!/usr/bin/env python3
"""No job's runner comes only from labels written in its workflow (.github/runners.json pools).

Leo, 2026-10-28: "I hate pins. Like, just pin the set of the shit that isn't hilariously slow."
The rule: no job names one runner size or label directly; every job resolves its runner from the
declared set, so a stalled size is left for a live one. `.github/runners.json` declares that set
(`pools`) and scripts/ci/runner_pools.py keeps the RUNNER_POOLS variable on each pool's live member.

A job's `runs-on` passes when, once the fork branches (`github.repository_owner != 'manaflow-ai'`,
a fork pull request) are set aside, some alternative takes its label from a live source: a
variable (`vars.X`, `fromJSON(vars.RUNNER_POOLS).<pool>`), a picker job's output (`needs.*`) or a
matrix value. A label picked by a condition (`vars.CI_CLOUD_OVERFLOW_SAVED && 'a' || 'b'`) or
passed in as a dispatch input is still a label written down: on 2026-10-30 Fast checks named
`blacksmith-32vcpu-ubuntu-2404` that way and only a re-dispatch could move it.

PINNED lists the jobs that still fail the rule on main, each with why it moves in its own PR (most
are signing jobs, which must name an ephemeral label literally). It only shrinks: a job not in it
fails, and an entry whose job no longer fails (or no longer exists) fails too, so it is removed.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
RUNNERS = ROOT / ".github" / "runners.json"

FORK = re.compile(r"github\.repository_owner != 'manaflow-ai'|head\.repo\.full_name != github\.repository")
LIVE = re.compile(r"^(?:vars|needs|matrix)\.|^fromJSON\(.*\b(?:vars|needs|matrix)\.")
# A workflow_call or dispatch input is the caller's choice only when nothing follows it; with a
# literal after it (Fast checks' `runner`), an empty input means the literal.
INPUT = re.compile(r"^inputs\.[A-Za-z0-9_-]+$")
POOL_READ = re.compile(r"fromJSON\(\s*vars\.RUNNER_POOLS\s*\)\.([A-Za-z0-9_]+)")

# workflow file -> (why it is not on a pool yet, its jobs that still name only literals)
PINNED: dict[str, tuple[str, set[str]]] = {
    'auto-resume-nightly-notarization.yml': ('nightly signing and notarization: an ephemeral label the signing rule checks literally',
     {'preflight', 'poll', 'wait-and-staple', 'poll-outer', 'staple-outer', 'poll-stapled', 'staple-stapled', 'verify-stapled', 'publish', 'generate-deltas', 'republish-deltas'}),
    'build-ghosttykit.yml': ('not yet on a pool; moves in its own PR',
     {'build-ghosttykit'}),
    'ci-cloud-overflow-probe.yml': ('holds the App key that writes the runner variables, so a variable must never move it (it would write its own runner)',
     {'watch'}),
    'cmux-next-dev-daily.yml': ('DEV signing and publish: an ephemeral label the signing rule checks literally',
     {'sign', 'publish', 'tip-dmg'}),
    'cmux-tui-build-package.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'attest-npm-packages'}),
    'cmux-tui-testbox-warmup.yml': ("Blacksmith Testbox broker bound to its environment's approver App",
     {'cmux-tui-rust'}),
    'coderouter-publish-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'coderouter-publish-pypi.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'ios-appstore-upload.yml': ('App Store upload with signing keys',
     {'upload', 'set-testflight-notes', 'assign-internal'}),
    'ios-e2e.yml': ('not yet on a pool; moves in its own PR',
     {'mac-ios-e2e'}),
    'ios-screenshots.yml': ('App Store upload with signing keys',
     {'app-store-upload'}),
    'ios-streamed-validate.yml': ('not yet on a pool; moves in its own PR',
     {'validate'}),
    'ios-testflight.yml': ('TestFlight upload with signing keys',
     {'upload', 'set-testflight-notes', 'assign-internal-group'}),
    'iroh-release-gate.yml': ('not yet on a pool; moves in its own PR',
     {'simulator-e2e'}),
    'nightly-next-canary.yml': ('not yet on a pool; moves in its own PR',
     {'pick', 'pick-canary-runner', 'verdict', 'failed'}),
    'nightly-next-launch-smoke.yml': ('not yet on a pool; moves in its own PR',
     {'pick'}),
    'stable-next-rollback.yml': ('holds the stable feed R2 token: an ephemeral label the secret-runner rule (test_ci_fork_runner_routing) checks literally',
     {'rollback'}),
    'nightly-next-rollback.yml': ('not yet on a pool; moves in its own PR',
     {'rollback'}),
    'nightly-next-train.yml': ('not yet on a pool; moves in its own PR',
     {'drive'}),
    'nightly-next-verdict.yml': ('not yet on a pool; moves in its own PR',
     {'write'}),
    'nightly-sign.yml': ('nightly signing admission: an ephemeral label the signing rule checks literally',
     {'admit'}),
    'nightly-tag-permission-probe.yml': ('not yet on a pool; moves in its own PR',
     {'probe'}),
    'nightly.yml': ('NEXT nightly: never moved mid-train here; its runner change is its own PR',
     {'decide', 'promote-nightly-next', 'await-release-surface-ack', 'promote-nightly-next-acked', 'refresh-compilation-cache', 'build-nightly-ghostty-cli-helper', 'pick-nightly-app-runner', 'resolve-nightly-cmux-tui-client', 'pick-classic-sign-runner', 'pick-classic-prepare-runner', 'publish-nightly', 'republish-nightly-deltas', 'report-nightly-failure', 'close-nightly-failure-issue'}),
    'pr-media-privacy.yml': ('not yet on a pool; moves in its own PR',
     {'scan'}),
    'rcodesign-parity-proof.yml': ('signing parity proof: an ephemeral label the signing rule checks literally',
     {'prep', 'sign-codesign', 'sign-rcodesign', 'notarize-app', 'dmg', 'notarize-dmg', 'gatekeeper', 'gatekeeper-reference', 'sparkle'}),
    'relay-publish-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'release.yml': ('release signing: an ephemeral label the signing rule checks literally',
     {'build-sign-notarize'}),
    'repair-nightly-appcast-content-types.yml': ('not yet on a pool; moves in its own PR',
     {'test', 'repair'}),
    'repair-v0-64-25-helper-rpaths.yml': ('release repair that re-signs: an ephemeral label the signing rule checks literally',
     {'verify-shipped', 'repair'}),
    'resume-nightly-notarization.yml': ('nightly signing and notarization: an ephemeral label the signing rule checks literally',
     {'resume', 'verify-stapled'}),
    'sdk-bootstrap-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'sdk-release-cut.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish-npm', 'verify-stable-provenance'}),
    'seed-swiftpm-manifests.yml': ('not yet on a pool; moves in its own PR',
     {'seed'}),
    'signing-keychain-macos.yml': ('signing keychain import: an ephemeral label the signing rule checks literally',
     {'real-import'}),
    'test-feed-reply-providers.yml': ('not yet on a pool; moves in its own PR',
     {'full-text', 'verify'}),
    'tui-publish-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
}


def split_top(expression: str, operator: str) -> list[str]:
    """Split on `operator` outside quotes and brackets."""
    parts, depth, quoted, current, i = [], 0, False, "", 0
    while i < len(expression):
        char = expression[i]
        if char == "'":
            quoted = not quoted
        elif not quoted:
            if char in "([":
                depth += 1
            elif char in ")]":
                depth -= 1
            elif depth == 0 and expression.startswith(operator, i):
                parts.append(current.strip())
                current, i = "", i + len(operator)
                continue
        current += char
        i += 1
    parts.append(current.strip())
    return parts


def has_live_source(expression: str) -> bool:
    alternatives = split_top(expression, "||")
    for index, alternative in enumerate(alternatives):
        terms = split_top(alternative, "&&")
        if any(FORK.search(term) for term in terms[:-1]):
            continue
        value = terms[-1]
        if value.startswith("(") and value.endswith(")") and has_live_source(value[1:-1]):
            return True
        if LIVE.match(value):
            return True
        if INPUT.match(value) and len(terms) == 1 and index == len(alternatives) - 1:
            return True
    return False


def runs_on_is_live(runs_on: object) -> bool:
    if isinstance(runs_on, dict):
        return "group" in runs_on
    if isinstance(runs_on, list):
        return any(runs_on_is_live(item) for item in runs_on)
    text = str(runs_on).strip()
    if text.startswith("${{") and text.endswith("}}"):
        return has_live_source(text[3:-2].strip())
    return False


def jobs() -> list[tuple[str, str, object]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict) and "runs-on" in job:
                found.append((path.name, str(name), job["runs-on"]))
    return found


class RuleTests(unittest.TestCase):
    def test_labels_written_down_fail(self) -> None:
        fork = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
        for expression in (
            "'blacksmith-32vcpu-ubuntu-2404'",
            fork + "'blacksmith-4vcpu-ubuntu-2404'",
            # Fast checks on 2026-10-30: an input and an overflow condition, but every label written down.
            fork + "contains(fromJSON('[\"blacksmith-16vcpu-ubuntu-2404\"]'), inputs.runner) && inputs.runner || "
                   "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404'",
            fork + "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                   "github.repository && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404'",
        ):
            with self.subTest(expression=expression):
                self.assertFalse(runs_on_is_live("${{ " + expression + " }}"))
        self.assertFalse(runs_on_is_live("${{ inputs.runner || 'blacksmith-32vcpu-ubuntu-2404' }}"))
        self.assertFalse(runs_on_is_live("${{ fromJSON('[\"blacksmith-32vcpu-ubuntu-2404\"]') }}"))
        self.assertFalse(runs_on_is_live("blacksmith-32vcpu-ubuntu-2404"))
        self.assertFalse(runs_on_is_live(["self-hosted", "blacksmith-32vcpu-ubuntu-2404"]))

    def test_a_pool_variable_or_picker_passes(self) -> None:
        fork = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
        for expression in (
            fork + "fromJSON(vars.RUNNER_POOLS).linux",
            fork + "contains(fromJSON('[\"a\"]'), inputs.runner) && inputs.runner || fromJSON(vars.RUNNER_POOLS).linux",
            fork + "vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'",
            fork + "needs.pick.outputs.label || 'blacksmith-6vcpu-macos-26'",
            fork + "(inputs.linux_runner != '' && inputs.linux_runner || vars.LINUX_RUNNER || 'x')",
            "matrix.label",
            # A reusable workflow whose caller picks the runner.
            fork + "inputs.runner",
            fork + "fromJSON(github.run_attempt > 1 && needs.runner.outputs.retry_runs_on || needs.runner.outputs.runs_on)",
        ):
            with self.subTest(expression=expression):
                self.assertTrue(runs_on_is_live("${{ " + expression + " }}"))
        self.assertTrue(runs_on_is_live({"group": "linux"}))


class WorkflowTests(unittest.TestCase):
    def test_fast_checks_reads_the_linux_pool(self) -> None:
        runs_on = {(path, name): value for path, name, value in jobs()}[("fast-checks.yml", "checks")]
        self.assertIn("fromJSON(vars.RUNNER_POOLS).linux }}", runs_on)
        self.assertNotRegex(runs_on.split("inputs.runner ||")[-1], r"'blacksmith-")

    def test_no_job_names_only_literal_labels(self) -> None:
        pinned = {(path, job) for path, (_, names) in PINNED.items() for job in names}
        failing = {(path, name) for path, name, value in jobs() if not runs_on_is_live(value)}
        new = sorted(failing - pinned)
        self.assertEqual(new, [], "these jobs name their runner only as literal labels; read a pool "
                                  "(fromJSON(vars.RUNNER_POOLS).<pool>, .github/runners.json) or a picker's output")
        stale = sorted(pinned - failing)
        self.assertEqual(stale, [], "these PINNED jobs now resolve from a live source or are gone; remove them")

    def test_every_pool_read_names_a_declared_pool(self) -> None:
        pools = set(json.loads(RUNNERS.read_text(encoding="utf-8"))["pools"]) - {"$comment"}
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for pool in POOL_READ.findall(path.read_text(encoding="utf-8")):
                with self.subTest(workflow=path.name, pool=pool):
                    self.assertIn(pool, pools)

    def test_every_pinned_entry_says_why(self) -> None:
        for path, (why, names) in PINNED.items():
            self.assertTrue(why.strip() and names, path)


if __name__ == "__main__":
    unittest.main()
