#!/usr/bin/env python3
"""No new job takes its Linux runner from LINUX_RUNNER alone (one Blacksmith size).

Leo, 2026-10-28: "I hate pins. Like, just pin the set of the shit that isn't hilariously slow."
The rulebook: no job names one runner size or label directly, and a CI test fails on a literal
single-size runs-on.

`vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'` looks live, but it is one size.
LINUX_RUNNER holds a single label (blacksmith-4vcpu-ubuntu-2404 since 2026-10-29), and the
overflow switch (cloud_overflow_switch.py) moves it only when every probed Blacksmith size stops
starting jobs. A stall of that one size moves nothing. On 2026-10-31 `GhosttyKit release check`
(ci.yml, run 41158893861, PR #28749) sat 41 minutes on blacksmith-4vcpu-ubuntu-2404 while the
16 and 32 vCPU sizes started jobs. It now reads the Linux pool,
`fromJSON(vars.RUNNER_POOLS).linux`, which runner_pools.py keeps on a live member.

main's tests/test_ci_runner_set.py accepts LINUX_RUNNER as a live source and is not on this
branch, so nothing caught it. SINGLE_SIZE counts, per workflow, the jobs that still read
LINUX_RUNNER this way. It only shrinks: a workflow with more such jobs than its count fails (a
new pin), and one with fewer fails until its count is lowered, so a moved job can't come back.

FIXED_PAIR counts the other single-size shape, `!startsWith(vars.LINUX_RUNNER, 'blacksmith-') &&
vars.LINUX_RUNNER || vars.CI_CLOUD_OVERFLOW_SAVED && '<size>' || '<size>'`. While LINUX_RUNNER names a
Blacksmith label (always, since runner_pools.py mirrors the pool into it) it reads neither the variable
nor the pool: the job waits on its one literal size, and the overflow record (set only once every probed
size stalls) swaps it for the other literal. On 2026-10-31 gallery health sat 46 min queued on
blacksmith-16vcpu-ubuntu-2404 and web validation 44 min, with nothing started. Leo, 2026-10-31: "stop
falling only to a [...] Blacksmith that isn't available". Same ratchet: it only shrinks.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# The whole expression, or its last `||` alternative after the fork branches, is LINUX_RUNNER then
# one Blacksmith Linux literal.
SINGLE_SIZE_TAIL = re.compile(r"(?:^|\|\|)\s*vars\.LINUX_RUNNER\s*\|\|\s*'blacksmith-\d+vcpu-ubuntu-2404'\s*$")

FIXED_PAIR_TAIL = re.compile(
    r"(?:^|\|\|)\s*!startsWith\(vars\.LINUX_RUNNER,\s*'blacksmith-'\)\s*&&\s*vars\.LINUX_RUNNER\s*\|\|"
    r"\s*vars\.CI_CLOUD_OVERFLOW_SAVED\s*&&\s*'blacksmith-\d+vcpu-ubuntu-2404'\s*\|\|\s*'blacksmith-\d+vcpu-ubuntu-2404'\s*$"
)

LIVE_SOURCE = re.compile(r"\b(?:needs|matrix|inputs|steps|env)\.|vars\.(?!LINUX_RUNNER\b)[A-Z0-9_]+")

# workflow file -> jobs that still read LINUX_RUNNER as their one size. Lower a count when a job
# moves to fromJSON(vars.RUNNER_POOLS).<pool> or a picker; never raise one.
SINGLE_SIZE: dict[str, int] = {
    "actions-artifact-prune.yml": 1,
    "agent-brands.yml": 0,
    "app-ffi-release.yml": 3,
    "auto-resume-nightly-notarization.yml": 6,
    "automation-bench.yml": 0,
    "backend.yml": 0,
    "ci-artifact-canary.yml": 1,
    "ci-artifact-transport.yml": 0,
    "ci-cache-receipts.yml": 0,
    "ci-compile-attribution.yml": 1,
    "ci-fast-guards.yml": 0,
    "ci-guard-attribution.yml": 1,
    "ci-guards.yml": 0,
    "ci-health-report.yml": 1,
    "ci-hosted-queue-rescue.yml": 1,
    "ci-queue-janitor.yml": 1,
    "ci-repo-variables.yml": 0,
    "ci-web.yml": 0,
    "ci.yml": 0,
    "cloud-capture-provision.yml": 1,
    "cloud-devbox-image-rebake.yml": 1,
    "cloud-image-staleness.yml": 1,
    "cloud-vm-canary.yml": 1,
    "cloud-vm-env-audit.yml": 1,
    "cloud-vm-guest-install.yml": 0,
    "cloud-vm-image-bake.yml": 3,
    "cloud-vm-image-contract.yml": 1,
    "cloud-vm-image-lock.yml": 0,
    "cloud-vm-image-promote.yml": 2,
    "cloud-vm-image-reachability.yml": 1,
    "cloud-vm-migrate.yml": 3,
    "cloud-vm-runtime-promotion.yml": 1,
    "cloud-vm-smoke.yml": 1,
    "cmux-art-publish.yml": 1,
    "cmux-browser-host-release.yml": 2,
    "cmux-next-chromium-staleness.yml": 1,
    "cmux-next-batch.yml": 2,
    "cmux-next-crash-class.yml": 0,
    "cmux-next-dev-daily-dispatch.yml": 1,
    "cmux-next-docs-shortcuts.yml": 0,
    "cmux-next-fast-gates.yml": 0,
    "cmux-next-frame-pacing.yml": 1,
    "cmux-next-guards.yml": 4,
    "cmux-next-media.yml": 3,
    "cmux-next-motion-golden.yml": 1,
    "cmux-next-notices.yml": 0,
    "cmux-next-perf-budgets.yml": 3,
    "cmux-next-pr-merge-tree.yml": 0,
    "cmux-next-remote-daemon.yml": 0,
    "cmux-next-shell-integration.yml": 0,
    "cmux-next-tip-test-compile.yml": 2,
    "cmux-next-web-bundle-publish.yml": 2,
    "cmux-next-web-bundles.yml": 0,
    "cmux-next-web.yml": 1,
    "cmux-next.yml": 3,
    "cmux-skill-contract.yml": 0,
    "cmux-terminal-client-xcframework.yml": 1,
    "cmux-tui-artifacts-retry.yml": 1,
    "cmux-tui-nightly.yml": 1,
    "cmux-tui-release-cut.yml": 1,
    "cmux-tui-release-delivery.yml": 1,
    "cmux-tui-release.yml": 2,
    "cmux-tui-sdks.yml": 0,
    "cmux-tui-spec.yml": 0,
    "cmux-tui-tree-request.yml": 1,
    "cmux-tui.yml": 1,
    "cmux-vm.yml": 7,
    "coderouter-release.yml": 3,
    "coderouter-verify-release.yml": 1,
    "docs-deploy-reusable.yml": 1,
    "dogfood-artifact-publish.yml": 1,
    "feature-flag-review-drift.yml": 1,
    "fleet-artifact-cdn.yml": 2,
    "fleet-test-compile.yml": 0,
    "git-mirror-bundle.yml": 1,
    "indexnow-tests.yml": 0,
    "indexnow.yml": 0,
    "ios-app-store.yml": 2,
    "ios-appstore-upload.yml": 2,
    "ios-e2e.yml": 2,
    "ios-internal-nightly.yml": 3,
    "ios-screenshots.yml": 1,
    "ios-testflight.yml": 2,
    "iroh-release-gate.yml": 1,
    "iroh-v2-production-drift.yml": 1,
    "iroh-v2.yml": 1,
    "labels-sync.yml": 0,
    "main-submodule-pin-watch.yml": 1,
    "merge-group-policy-checks.yml": 2,
    "mux.yml": 0,
    "nightly-next-canary.yml": 2,
    "nightly-next-feed-watch.yml": 1,
    "nightly-next-rollback.yml": 3,
    "nightly-next-train.yml": 2,
    "nightly-next-verdict.yml": 1,
    "nightly-tag-permission-probe.yml": 1,
    "pr-capture-check.yml": 0,
    "pr-design-spec-check.yml": 0,
    "pr-media-prune.yml": 1,
    "pr-perf-section-check.yml": 0,
    "pr-red-checks-comment.yml": 1,
    "presence.yml": 1,
    "r2-binaries-prune.yml": 1,
    "r2-cache-prune.yml": 1,
    "r2-storage-census.yml": 3,
    "r2-upload-tests.yml": 0,
    "relay-publish-npm.yml": 1,
    "release-rails.yml": 2,
    "release.yml": 1,
    "remote-daemon.yml": 0,
    "repair-nightly-appcast-content-types.yml": 2,
    "required-checks-drift.yml": 0,
    "resolve-dispatch-ref.yml": 1,
    "risk-tier-tests.yml": 0,
    "sdk-bootstrap-crates.yml": 5,
    "sdk-bootstrap-npm.yml": 3,
    "sdk-bootstrap-pypi.yml": 4,
    "sdk-publish-crates.yml": 1,
    "sdk-publish-go.yml": 1,
    "sdk-publish-java.yml": 2,
    "sdk-publish-npm.yml": 1,
    "sdk-publish-python.yml": 2,
    "sdk-release-cut.yml": 9,
    "seed-derived-data.yml": 1,
    "signing-keychain-macos.yml": 0,
    "stable-next.yml": 4,
    "terminal-hang-diagnostics.yml": 0,
    "test-ios.yml": 3,
    "testbox-broker-guard.yml": 0,
    "tui-publish-npm.yml": 1,
    "tui-publish-pypi.yml": 2,
    "update-homebrew.yml": 2,
    "vendored-agent-cursor.yml": 0,
    "vercel-auth-health.yml": 1,
}


# workflow file -> jobs whose runs-on ends in FIXED_PAIR_TAIL. Lower a count when a job moves to
# fromJSON(vars.RUNNER_POOLS).<pool> or a picker; never raise one.
FIXED_PAIR: dict[str, int] = {
    "backend.yml": 1,
    "ci-web.yml": 5,
    "cloudflare-relay.yml": 1,
    "cmux-actions.yml": 1,
    "cmux-browser-host-chromium.yml": 1,
    "cmux-cloud-cli.yml": 1,
    "cmux-mobile-ffi.yml": 2,
    "cmux-next-car-guards.yml": 1,
    "cmux-next-fast-gates.yml": 1,
    "cmux-next-guards.yml": 1,
    "cmux-next-shim-cpp.yml": 1,
    "cmux-next-source-archive.yml": 1,
    "cmux-next-web-bundle-publish.yml": 1,
    "cmux-next-web-bundles.yml": 2,
    "cmux-next.yml": 2,
    "cmux-tui-artifacts.yml": 16,
    "cmux-tui-headless-debug.yml": 1,
    "cmux-tui-sdks.yml": 4,
    "cmux-tui-spec.yml": 3,
    "cmux-tui-windows-check.yml": 1,
    "cmux-tui.yml": 3,
    "cmux-vm-clients.yml": 2,
    "cmux-vm-cloud.yml": 1,
    "cmux-vm.yml": 1,
    "coderouter-ci.yml": 1,
    "iroh-relay-minter.yml": 1,
    "iroh-v2.yml": 1,
    "nightly-next-launch-smoke.yml": 3,
    "presence.yml": 1,
    "remote-daemon.yml": 1,
    "rust-workspaces.yml": 1,
    "sdk-bootstrap-crates.yml": 1,
    "sdk-publish-crates.yml": 1,
    "sdk-publish-go.yml": 3,
    "sdk-publish-java.yml": 1,
    "sdk-publish-npm.yml": 1,
    "sdk-publish-python.yml": 1,
    "swift-packages-linux.yml": 1,
}


def single_size(runs_on: object) -> bool:
    if not isinstance(runs_on, str):
        return False
    text = runs_on.strip()
    if not (text.startswith("${{") and text.endswith("}}")):
        return False
    expression = text[3:-2].strip()
    tail = SINGLE_SIZE_TAIL.search(expression)
    # A picker's output, a matrix leg, an input or a pool read ahead of it chooses first.
    return tail is not None and LIVE_SOURCE.search(expression[:tail.start()]) is None


def fixed_pair(runs_on: object) -> bool:
    if not isinstance(runs_on, str):
        return False
    text = runs_on.strip()
    if not (text.startswith("${{") and text.endswith("}}")):
        return False
    expression = text[3:-2].strip()
    tail = FIXED_PAIR_TAIL.search(expression)
    return tail is not None and LIVE_SOURCE.search(expression[:tail.start()]) is None


def counts(rule=single_size) -> dict[str, int]:
    found: dict[str, int] = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (document.get("jobs") or {}).values():
            if isinstance(job, dict) and rule(job.get("runs-on")):
                found[path.name] = found.get(path.name, 0) + 1
    return found


class SingleSizeRuleTests(unittest.TestCase):
    def test_linux_runner_with_one_literal_is_one_size(self) -> None:
        fork = ("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' "
                "&& github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || ")
        # The GhosttyKit release check's runs-on before the fix.
        self.assertTrue(single_size("${{ " + fork + "vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(single_size("${{ vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}"))

    def test_a_pool_or_picker_is_not(self) -> None:
        fork = ("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' "
                "&& github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || ")
        for expression in (fork + "fromJSON(vars.RUNNER_POOLS).linux",
                           "fromJSON(needs.runners.outputs.map).linux_16",
                           "needs.pick.outputs.label || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'"):
            with self.subTest(expression=expression):
                self.assertFalse(single_size("${{ " + expression + " }}"))


class FixedPairRuleTests(unittest.TestCase):
    PAIR = ("!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
            "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-32vcpu-ubuntu-2404' || 'blacksmith-16vcpu-ubuntu-2404'")

    def test_the_overflow_pair_is_one_size(self) -> None:
        fork = ("github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' "
                "&& github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || ")
        # gallery health's runs-on before the move.
        self.assertTrue(fixed_pair("${{ " + fork + self.PAIR + " }}"))
        self.assertTrue(fixed_pair("${{ " + self.PAIR + " }}"))

    def test_a_pool_or_picker_ahead_is_not(self) -> None:
        for expression in ("needs.place.outputs.linux_runner || " + self.PAIR,
                           "fromJSON(vars.RUNNER_POOLS).linux"):
            with self.subTest(expression=expression):
                self.assertFalse(fixed_pair("${{ " + expression + " }}"))


class WorkflowTests(unittest.TestCase):
    def test_the_ghosttykit_release_check_reads_the_linux_pool(self) -> None:
        document = yaml.safe_load((WORKFLOWS / "ci.yml").read_text(encoding="utf-8"))
        runs_on = document["jobs"]["ghosttykit-release-check"]["runs-on"]
        self.assertFalse(single_size(runs_on))
        self.assertTrue(runs_on.rstrip().endswith("fromJSON(vars.RUNNER_POOLS).linux }}"), runs_on)

    def test_web_subarea_scope_reads_the_linux_pool(self) -> None:
        # Run 41275619982 (2026-11-01): job 124762739841 waited 50 minutes unassigned on LINUX_RUNNER's
        # stalled 32 vCPU size while every webview shard waited behind it.
        document = yaml.safe_load((WORKFLOWS / "ci-web.yml").read_text(encoding="utf-8"))
        runs_on = document["jobs"]["web-subarea-scope"]["runs-on"]
        self.assertFalse(single_size(runs_on))
        self.assertNotIn("LINUX_RUNNER", runs_on)
        self.assertTrue(runs_on.rstrip().endswith("|| fromJSON(vars.RUNNER_POOLS).linux }}"), runs_on)

    def test_no_workflow_adds_a_single_size_linux_job(self) -> None:
        found = counts()
        grown = {name: (count, SINGLE_SIZE.get(name, 0)) for name, count in found.items()
                 if count > SINGLE_SIZE.get(name, 0)}
        self.assertEqual(grown, {}, "these workflows read LINUX_RUNNER as their one Linux size (found, allowed); "
                                    "read fromJSON(vars.RUNNER_POOLS).linux after the fork branches instead")
        shrunk = {name: (found.get(name, 0), count) for name, count in SINGLE_SIZE.items()
                  if found.get(name, 0) < count}
        self.assertEqual(shrunk, {}, "these workflows have fewer single-size Linux jobs (found, allowed); "
                                     "lower SINGLE_SIZE so they stay moved")

    def test_no_workflow_adds_a_fixed_pair_linux_job(self) -> None:
        found = counts(fixed_pair)
        grown = {name: (count, FIXED_PAIR.get(name, 0)) for name, count in found.items()
                 if count > FIXED_PAIR.get(name, 0)}
        self.assertEqual(grown, {}, "these workflows wait on one fixed Blacksmith Linux size (found, allowed); "
                                    "read fromJSON(vars.RUNNER_POOLS).linux after the fork branches instead")
        shrunk = {name: (found.get(name, 0), count) for name, count in FIXED_PAIR.items()
                  if found.get(name, 0) < count}
        self.assertEqual(shrunk, {}, "these workflows have fewer fixed-pair Linux jobs (found, allowed); "
                                     "lower FIXED_PAIR so they stay moved")


if __name__ == "__main__":
    unittest.main()
