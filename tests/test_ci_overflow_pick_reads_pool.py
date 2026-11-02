#!/usr/bin/env python3
"""No new Linux job picks one Blacksmith size where the live Linux pool would pick for it.

Leo, 2026-11-01: "ok. we clearly are not able to use them. so we should have resized a long-ass time ago."

Two runs-on shapes keep sending jobs to a Blacksmith size after it stops starting jobs:

- the hard-coded overflow pick, `vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' ||
  'blacksmith-8vcpu-ubuntu-2404'`: while the overflow record is set, every such job goes to the one size
  written there, whether or not that size starts anything;
- a bare `vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'`: one variable, one size.

On 2026-11-01 run 41299099061 (cmux-tui spec inventory, PR #30775) had five jobs queued from 10:48Z on the
stalled 4 vCPU size while the one 8 vCPU job ran. `fromJSON(vars.RUNNER_POOLS).linux` is what the runner
pool reconciler moves off a dead size, so a secretless Linux job reads it after the fork branches (#30385).

PICKS counts, per workflow, the jobs that still use one of those shapes: jobs holding secrets, an
environment or a write token, and jobs whose outputs or success such a job consumes through `needs`
(RUNNER_POOLS.linux may be the secretless fleet route; those keep the ephemeral Blacksmith mirror),
release and publish workflows and the reusable workflows they call, compile jobs with a measured size (tests/test_ci_linux_compile_runners.py),
measured 2, 8 and 16 vCPU jobs, portable-placement tails, and files other open pull requests change.
A workflow with more such jobs than its count fails: a new job reads the pool instead. A count may fall
without an edit here, so a pull request that moves a job never breaks another's base. Nightly and
notarization workflows are out of scope: they never use Blacksmith (tests/test_ci_nightly_off_blacksmith.py).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
POOL = "fromJSON(vars.RUNNER_POOLS).linux"
OUT_OF_SCOPE = re.compile(r"nightly|notarization")
PICK = re.compile(
    r"vars\.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-\d+vcpu-ubuntu-2404'"
    r"|(?<!&& )vars\.LINUX_RUNNER \|\| 'blacksmith-\d+vcpu-ubuntu-2404'"
)

# workflow file -> Linux jobs that still pick one Blacksmith size. Never raise a count.
PICKS: dict[str, int] = {
    "actions-artifact-prune.yml": 1,
    "app-ffi-release.yml": 3,
    "backend.yml": 1,
    "chief-evals.yml": 1,
    "ci-artifact-canary.yml": 1,
    "ci-compile-attribution.yml": 1,
    "ci-guard-attribution.yml": 1,
    "ci-health-report.yml": 1,
    "ci-hosted-queue-rescue.yml": 1,
    "ci-macos.yml": 2,
    "ci-queue-janitor.yml": 1,
    "ci-web.yml": 7,
    "cloud-capture-provision.yml": 1,
    "cloud-devbox-image-rebake.yml": 1,
    "cloud-image-staleness.yml": 1,
    "cloud-vm-canary.yml": 1,
    "cloud-vm-dogfood.yml": 3,
    "cloud-vm-env-audit.yml": 1,
    "cloud-vm-image-bake.yml": 3,
    "cloud-vm-image-contract.yml": 1,
    "cloud-vm-image-promote.yml": 2,
    "cloud-vm-image-reachability.yml": 1,
    "cloud-vm-migrate.yml": 3,
    "cloud-vm-runtime-promotion.yml": 1,
    "cloud-vm-smoke.yml": 1,
    "cloudflare-relay.yml": 1,
    "cmux-actions.yml": 1,
    "cmux-art-publish.yml": 1,
    "cmux-browser-host-chromium.yml": 1,
    "cmux-browser-host-release.yml": 2,
    "cmux-cloud-cli.yml": 1,
    "cmux-mobile-ffi.yml": 2,
    "cmux-next-base-autofix.yml": 7,
    "cmux-next-batch.yml": 2,
    "cmux-next-car-guards.yml": 2,
    "cmux-next-chromium-staleness.yml": 1,
    "cmux-next-dev-daily-dispatch.yml": 1,
    "cmux-next-fast-tier-seed.yml": 1,
    "cmux-next-frame-pacing.yml": 1,
    "cmux-next-generated-catch-up.yml": 2,
    "cmux-next-guards.yml": 8,
    "cmux-next-media.yml": 3,
    "cmux-next-motion-golden.yml": 1,
    "cmux-next-package-deps-heal.yml": 1,
    "cmux-next-perf-budgets.yml": 3,
    "cmux-next-pr-autofix.yml": 4,
    "cmux-next-shim-cpp.yml": 1,
    "cmux-next-skew-matrix.yml": 1,
    "cmux-next-source-archive.yml": 2,
    "cmux-next-tip-test-compile.yml": 2,
    "cmux-next-web-bundle-publish.yml": 3,
    "cmux-next-web-bundles.yml": 2,
    "cmux-next-web.yml": 1,
    "cmux-next.yml": 21,
    "cmux-terminal-client-xcframework.yml": 1,
    "cmux-tui-artifacts-retry.yml": 1,
    "cmux-tui-artifacts.yml": 18,
    "cmux-tui-build-package.yml": 2,
    "cmux-tui-headless-debug.yml": 1,
    "cmux-tui-release-cut.yml": 1,
    "cmux-tui-release-delivery.yml": 1,
    "cmux-tui-release.yml": 2,
    "cmux-tui-sdks.yml": 4,
    "cmux-tui-spec.yml": 4,
    "cmux-tui-tree-request.yml": 1,
    "cmux-tui-windows-check.yml": 1,
    "cmux-tui.yml": 6,
    "cmux-vm-clients.yml": 2,
    "cmux-vm-cloud.yml": 1,
    "cmux-vm-upstream-refresh.yml": 1,
    "cmux-vm.yml": 8,
    "coderouter-ci.yml": 1,
    "coderouter-release.yml": 3,
    "coderouter-verify-release.yml": 1,
    "docs-deploy-reusable.yml": 1,
    "dogfood-artifact-publish.yml": 1,
    "feature-flag-review-drift.yml": 1,
    "fleet-artifact-cdn.yml": 2,
    "fleet-compile-check.yml": 1,
    "fleet-test-compile.yml": 1,
    "fresh-chief-eval.yml": 1,
    "gallery-advisory.yml": 1,
    "gallery-health.yml": 1,
    "git-mirror-bundle.yml": 2,
    "herdr-upstream-drift.yml": 1,
    "ios-app-store.yml": 2,
    "ios-appstore-upload.yml": 2,
    "ios-e2e.yml": 2,
    "ios-screenshots.yml": 1,
    "ios-testflight.yml": 2,
    "iroh-relay-minter.yml": 1,
    "iroh-release-gate.yml": 1,
    "iroh-v2-production-drift.yml": 1,
    "iroh-v2.yml": 2,
    "machine-join-e2e.yml": 1,
    "macos-cross-parity.yml": 1,
    "main-submodule-pin-watch.yml": 1,
    "merge-group-policy-checks.yml": 2,
    "pr-checks.yml": 4,
    "pr-media-prune.yml": 1,
    "pr-red-checks-comment.yml": 1,
    "presence.yml": 2,
    "r2-binaries-prune.yml": 1,
    "r2-cache-prune.yml": 1,
    "r2-storage-census.yml": 3,
    "relay-publish-npm.yml": 1,
    "release-rails.yml": 2,
    "release.yml": 2,
    "remote-daemon.yml": 1,
    "repair-v0-64-25-helper-rpaths.yml": 1,
    "resolve-dispatch-ref.yml": 1,
    "rust-workspaces.yml": 3,
    "sdk-bootstrap-crates.yml": 6,
    "sdk-bootstrap-npm.yml": 3,
    "sdk-bootstrap-pypi.yml": 4,
    "sdk-publish-crates.yml": 2,
    "sdk-publish-go.yml": 4,
    "sdk-publish-java.yml": 3,
    "sdk-publish-npm.yml": 2,
    "sdk-publish-python.yml": 3,
    "sdk-release-cut.yml": 9,
    "seed-derived-data.yml": 1,
    "signing-keychain-macos.yml": 1,
    "stable-next-rollback.yml": 1,
    "stable-next.yml": 6,
    "swift-linux-packages.yml": 1,
    "swift-packages-linux.yml": 1,
    "test-ios.yml": 3,
    "tui-publish-npm.yml": 1,
    "tui-publish-pypi.yml": 2,
    "update-homebrew.yml": 2,
    "vercel-auth-health.yml": 1,
    "web-complexity.yml": 1,
    "web-validation.yml": 5,
}


# The secret-bearing route (tests/test_ci_runner_pool_reconcile.py): LINUX_RUNNER, bounded to its ephemeral
# Blacksmith sizes, picks first; a literal after it is reached only while that mirror is unset.
EPHEMERAL_MIRROR = re.compile(r"contains\(fromJSON\('[^']*'\), vars\.LINUX_RUNNER\) && vars\.LINUX_RUNNER \|\| ")


def picks_one_size(runs_on: object) -> bool:
    if not isinstance(runs_on, str) or "macos" in runs_on:
        return False
    pick = PICK.search(runs_on)
    return pick is not None and EPHEMERAL_MIRROR.search(runs_on[: pick.start()]) is None


def counts() -> dict[str, int]:
    found: dict[str, int] = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        if OUT_OF_SCOPE.search(path.name):
            continue
        for job in ((yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("jobs") or {}).values():
            if isinstance(job, dict) and picks_one_size(job.get("runs-on")):
                found[path.name] = found.get(path.name, 0) + 1
    return found


class ClassifierTests(unittest.TestCase):
    FORK = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' "
            "&& github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || ")

    def test_hard_coded_overflow_pick_and_bare_linux_runner_pick_one_size(self) -> None:
        for tail in ("vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-8vcpu-ubuntu-2404' }}",
                     "!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
                     "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}",
                     "vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"):
            with self.subTest(tail=tail):
                self.assertTrue(picks_one_size(self.FORK + tail))

    def test_the_pool_and_the_ephemeral_mirror_do_not(self) -> None:
        mirror = ("contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-8vcpu-ubuntu-2404\"]'), "
                  "vars.LINUX_RUNNER) && vars.LINUX_RUNNER || 'blacksmith-8vcpu-ubuntu-2404' }}")
        mirror_then_pick = mirror.replace("|| 'blacksmith-8vcpu-ubuntu-2404' }}",
                                          "|| vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || "
                                          "'blacksmith-8vcpu-ubuntu-2404' }}")
        for tail in (POOL + " }}", mirror, mirror_then_pick):
            with self.subTest(tail=tail):
                self.assertFalse(picks_one_size(self.FORK + tail))


class WorkflowTests(unittest.TestCase):
    def test_the_stuck_cmux_tui_spec_jobs_read_the_pool(self) -> None:
        # Run 41299099061: inventory and rustfmt waited on LINUX_RUNNER's stalled 4 vCPU size. Its other
        # waiting jobs (acpmux-tests, acpmux-protocol-ir, clippy) are measured 8 vCPU compile jobs and keep
        # their size and outage switch (tests/test_ci_linux_compile_runners.py).
        jobs = yaml.safe_load((WORKFLOWS / "cmux-tui-spec.yml").read_text(encoding="utf-8"))["jobs"]
        for name in ("inventory", "rustfmt"):
            with self.subTest(job=name):
                runs_on = jobs[name]["runs-on"]
                self.assertFalse(picks_one_size(runs_on), runs_on)
                self.assertTrue(runs_on.rstrip().endswith("|| " + POOL + " }}"), runs_on)

    def test_no_workflow_adds_a_one_size_linux_pick(self) -> None:
        grown = {name: (count, PICKS.get(name, 0)) for name, count in counts().items() if count > PICKS.get(name, 0)}
        self.assertEqual(grown, {}, "these workflows pick one Blacksmith Linux size (found, allowed); read "
                                    f"{POOL} after the fork branches instead, or the ephemeral LINUX_RUNNER "
                                    "mirror for a job that holds secrets or feeds one through needs")


if __name__ == "__main__":
    unittest.main()
