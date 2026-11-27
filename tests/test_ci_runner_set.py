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
# The persistent Linux pool's label (cmux-linux): a runner group, not one size, so naming it
# literally is reading the pool. Only this exact label; any other literal still fails.
POOL_LABELS = frozenset({"'cmux-linux'"})
POOL_READ = re.compile(r"fromJSON\(\s*vars\.RUNNER_POOLS\s*\)\.([A-Za-z0-9_]+)")

# workflow file -> (why it is not on a pool yet, its jobs that still name only literals)
PINNED: dict[str, tuple[str, set[str]]] = {
    'fast-checks.yml': ('the admission picker is a light read-only job on Blacksmith 2 vCPU; checks use its live fleet output',
     {'admit'}),
    'web-complexity-trusted.yml': ('reads untrusted pull request source: only the one-job cmux-gcp-pr-control-jit-x64, never a pool a variable can move',
     {'complexity'}),
    'auto-resume-nightly-notarization.yml': ('nightly signing and notarization: an ephemeral label the signing rule checks literally',
     {'poll', 'wait-and-staple', 'poll-outer', 'staple-outer', 'poll-stapled', 'staple-stapled', 'verify-stapled', 'publish', 'generate-deltas', 'republish-deltas'}),
    'cmux-next-pr-autofix-push.yml': ('holds the PR autofix App key (contents write): the fork-routing App-key rule forbids a variable-movable runner',
     {'push'}),
    'feature-flag-review-drift.yml': ('report holds App keys (spare issue tokens, cmux#55872): the fork-routing secret rule forbids a variable-movable runner',
     {'report'}),
    'billing-nightly.yml': ('holds the App Store In-App Purchase key and health token: the fork-routing secret rule forbids a variable-movable runner',
     {'alert', 'apple-api', 'apple-delivery', 'apple-post-release'}),
    'ci-queue-janitor.yml': ('the queue repair job must not depend on the pools it repairs: the one-job cmux-gcp-repair-jit-x64, '
                             'or cmux-fleet-linux-x64 when CI_QUEUE_JANITOR_ON_FLEET=1 (check_queue_janitor_runs_off_the_pools_it_judges)',
     {'sweep'}),
    'ci-queue-janitor-watchdog.yml': ("watches the sweep's label from off it: cmux-fleet-linux-x64 while the sweep is on "
                                      'cmux-gcp-repair-jit-x64, cmux-gcp-repair-jit-x64 when CI_QUEUE_JANITOR_ON_FLEET=1 (test_ci_janitor_watchdog_route)',
     {'watch'}),
    'cmux-next-cua-helper-dev-sign.yml': ('DEV Computer Use helper signing: an ephemeral label the signing rule checks literally',
     {'sign'}),
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
    'ios-app-review-readiness.yml': ('app-store-connect and store-declarations hold the App Store Connect API key (release environment), as ios-asc-ops.yml op does, and review-gate mints the bot App token: the fork-routing secret rule forbids a variable-movable runner',
     {'app-store-connect', 'store-declarations', 'review-gate'}),
    'ios-asc-subscription-records.yml': ('holds the App Store Connect API key (release environment), as ios-asc-ops.yml op does: the fork-routing secret rule forbids a variable-movable runner',
     {'records'}),
    'ios-asc-ops.yml': ('holds the App Store Connect API key (release environment): the fork-routing secret rule forbids a variable-movable runner',
     {'op'}),
    'ios-screenshots.yml': ('App Store upload with signing keys',
     {'app-store-upload'}),
    'stable-next-rollback.yml': ('holds the stable feed R2 token: an ephemeral label the secret-runner rule (test_ci_fork_runner_routing) checks literally',
     {'rollback'}),
    'nightly-next-rollback.yml': ('not yet on a pool; moves in its own PR',
     {'rollback'}),
    'nightly-next-rollback-drill.yml': ('publish and receipt hold the feed\'s R2 token: an ephemeral label the secret rule checks literally',
     {'publish', 'receipt'}),
    'nightly-next-train.yml': ('not yet on a pool; moves in its own PR',
     {'drive'}),
    'nightly-next-verdict.yml': ('not yet on a pool; moves in its own PR',
     {'write'}),
    'web-complexity-trusted.yml': ('reads untrusted pull_request_target source: hosted ubuntu-24.04 is the one ephemeral Linux label outside the persistent pool',
     {'complexity'}),
    'nightly.yml': ('NEXT nightly: never moved mid-train here; its runner change is its own PR',
     {'promote-nightly-next', 'publish-nightly', 'promote-nightly-next-acked'}),
    'rcodesign-parity-proof.yml': ('signing parity proof: an ephemeral label the signing rule checks literally',
     {'notarize-dmg', 'notarize-app', 'sparkle', 'prep', 'sign-rcodesign', 'sign-codesign'}),
    'relay-publish-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'release.yml': ('release signing: an ephemeral label the signing rule checks literally',
     {'build-sign-notarize'}),
    'repair-nightly-appcast-content-types.yml': ('not yet on a pool; moves in its own PR',
     {'repair'}),
    'repair-v0-64-25-helper-rpaths.yml': ('release repair that re-signs: an ephemeral label the signing rule checks literally',
     {'repair'}),
    'resume-nightly-notarization.yml': ('nightly signing and notarization: an ephemeral label the signing rule checks literally',
     {'resume', 'verify-stapled'}),
    'sdk-bootstrap-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'sdk-bootstrap-pypi.yml': ('GitHub OIDC trusted publishing: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'sdk-release-cut.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish-npm', 'verify-stable-provenance', 'publish-crate-sdk', 'publish-crate-sidebar', 'publish-python-wheel', 'publish-python-sdist'}),
    'tui-publish-pypi.yml': ('GitHub OIDC trusted publishing: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'tui-publish-npm.yml': ('GitHub OIDC provenance: moves to fromJSON(vars.RUNNER_POOLS).provenance',
     {'publish'}),
    'ios-streamed-validate.yml': ('not yet on a pool; moves in its own PR',
     {'validate'}),
    'iroh-release-gate.yml': ('not yet on a pool; moves in its own PR',
     {'simulator-e2e'}),
    'nightly-sign.yml': ('nightly signing admission: an ephemeral label the signing rule checks literally',
     {'admit'}),
}


# Jobs whose picker was written out as the label it resolved to (2026-11-24, Leo: "one label (`runs-on: cmux-linux`)
# for every own-branch Linux job, with the pickers (...) deleted now, not after a soak"). Each is a credentialed
# job (a write token, an App key, a secret), a reserved one-job JIT label's or a nightly pin, so it names that
# ephemeral label literally, not cmux-linux or a variable (cmux#49325's convention). Merged into PINNED below.
WRITTEN_OUT_WHY = ("its picker was written out as the ephemeral label it resolved to on 2026-11-24: a credentialed, "
                   "reserved or nightly job (cmux#49325's convention)")
WRITTEN_OUT: dict[str, set[str]] = {
    'auto-triage.yml': {'backfill', 'triage'},
    'backend-migrations.yml': {'apply-production', 'apply-staging', 'gate', 'plan'},
    'ci-artifact-canary.yml': {'canary'},
    'ci-cla-quota-rerun.yml': {'cla-quota-rerun'},
    'ci-cloud-overflow-probe.yml': {'watch'},
    'ci-compile-attribution.yml': {'analyze', 'fix', 'report'},
    'ci-failure-attribution.yml': {'attribute'},
    'ci-guard-attribution.yml': {'analyze', 'report'},
    'ci-health-report.yml': {'report'},
    'ci-hosted-backlog-rescue.yml': {'backlog'},
    'ci-hosted-light-rescue.yml': {'rescue'},
    'ci-hosted-queue-rescue.yml': {'rescue'},
    'ci-macos.yml': {'admission-placement', 'late-placement'},
    'ci-main-full-suite.yml': {'report'},
    'ci-manual-dispatch-guard.yml': {'guard'},
    'ci-owned-pool-rescue.yml': {'rescue'},
    'ci-shed-superseded-runs.yml': {'shed'},
    'ci-stale-run-janitor.yml': {'janitor'},
    'ci-token-budget-sampler.yml': {'sample'},
    'ci-ui-tests.yml': {'dispatch'},
    'ci.yml': {'changes'},
    'classic-api-guard.yml': {'classic-api'},
    'classic-deploy-guard.yml': {'guard'},
    'claude.yml': {'claude'},
    'cloud-capture-provision.yml': {'provision'},
    'cloud-chat-proof-nightly-dispatch.yml': {'proof'},
    'cloud-claude-matrix.yml': {'matrix'},
    'cloud-composer-journey.yml': {'dispatch'},
    'cloud-journey-prod.yml': {'journey', 'preclaim'},
    'cloud-vm-env-audit.yml': {'audit'},
    'cloud-vm-image-contract.yml': {'promote'},
    'cloud-vm-image-full-bake.yml': {'dispatch'},
    'cloud-vm-image-reachability.yml': {'reachable'},
    'cloud-vm-migrate.yml': {'migrate-production', 'migrate-staging'},
    'cloud-vm-smoke-sweep.yml': {'sweep'},
    'cmux-browser.yml': {'host-tests'},
    'cmux-next-cef-publish.yml': {'publish', 'resolve'},
    'cmux-next-cua-driver-sdk-publish.yml': {'publish'},
    'cmux-next-cua-helper-dev-sign.yml': {'pin-pr', 'publish', 'sdk'},
    'cmux-next-cua-helper-publish.yml': {'publish'},
    'cmux-next-dev-daily-dispatch.yml': {'dispatch'},
    'cmux-next-dev-daily.yml': {'runner', 'tip'},
    'cmux-next-perf-cron-dispatch.yml': {'dispatch'},
    'cmux-next-remote-browser-host-publish.yml': {'cef', 'publish'},
    'cmux-next-resource-budget-dispatch.yml': {'dispatch'},
    'cmux-next-web-pieces.yml': {'switch'},
    'cmux-tui-artifacts.yml': {'publish'},
    'cmux-tui-release-delivery.yml': {'delivery'},
    'coderouter-team-claude-account.yml': {'add'},
    'contributor-welcome.yml': {'welcome'},
    'cu-driver-eval-dispatch.yml': {'dispatch'},
    'debug-labs-keys-dispatch.yml': {'dispatch'},
    'docs-deploy-reusable.yml': {'deploy'},
    'dogfood-artifact-publish.yml': {'capture-inputs', 'capture-report', 'publish'},
    'executor-journey-nightly-dispatch.yml': {'journey'},
    'feature-flag-review-drift.yml': {'report'},
    'first-user-journey-web-dispatch.yml': {'dispatch'},
    'fleet-artifact-cdn.yml': {'deploy'},
    'intent-familiar-review.yml': {'warn'},
    'ios-asc-subscription-records.yml': {'records'},
    'ios-e2e.yml': {'backend'},
    'iroh-release-gate.yml': {'runner'},
    'iroh-v2.yml': {'deploy-development'},
    'labels-sync.yml': {'apply'},
    'language-boundaries.yml': {'language-boundaries'},
    'merge-freeze.yml': {'check', 'expire'},
    'merge-group-fail-fast.yml': {'watch'},
    'merge-receipt.yml': {'receipt'},
    'namespace-autofix.yml': {'autofix'},
    'nightly-next-feed-watch.yml': {'watch'},
    'nightly-next-tick.yml': {'request', 'unstick'},
    'nightly-next-train.yml': {'pick-train-runner'},
    'nightly-tag-permission-probe.yml': {'probe'},
    'nightly.yml': {'await-release-surface-ack', 'pick-classic-prepare-runner', 'pick-nightly-app-runner'},
    'pr-media.yml': {'plan', 'publish', 'tour'},
    'pr-status.yml': {'line'},
    'presence.yml': {'deploy'},
    'published-in.yml': {'published-in'},
    'storage-maintenance.yml': {'r2-binaries', 'r2-cache', 'r2-census-binaries', 'r2-census-cef', 'r2-census-ci-cache'},
    'required-checks-drift.yml': {'reconcile'},
    'resolve-runners.yml': {'resolve'},
    'risk-tier.yml': {'evidence'},
    'screen-stream-eval-dispatch.yml': {'dispatch'},
    'sdk-bootstrap-crates.yml': {'publish-sdk', 'publish-sidebar'},
    'sdk-release-cut.yml': {'cut-tags'},
    'stale-agent-prs.yml': {'stale-agent-prs'},
    'test-e2e.yml': {'runner'},
    'test-ios.yml': {'ios-simulator-cache-seed', 'runner'},
    'thunderdome-label.yml': {'backfill', 'label'},
    'triage-radar.yml': {'refresh'},
    'update-homebrew.yml': {'update-cask'},
    'vercel-auth-health.yml': {'check'},
    'vercel-staging-env-apply.yml': {'apply'},
}
for _path, _names in WRITTEN_OUT.items():
    PINNED.setdefault(_path, (WRITTEN_OUT_WHY, set()))[1].update(_names)


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
        if LIVE.match(value) or value in POOL_LABELS:
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
        # Only the exact pool label: a look-alike literal is still one label written down.
        self.assertFalse(runs_on_is_live("${{ 'cmux-linux-x64' }}"))
        self.assertFalse(runs_on_is_live("${{ github.repository_owner != 'manaflow-ai' && 'cmux-linux' || 'x' }}"))
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
            # The persistent pool's label, after the fork branches.
            fork + "'cmux-linux'",
            fork + "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != "
                   "github.repository && 'blacksmith-4vcpu-ubuntu-2404' || 'cmux-linux'",
        ):
            with self.subTest(expression=expression):
                self.assertTrue(runs_on_is_live("${{ " + expression + " }}"))
        self.assertTrue(runs_on_is_live({"group": "linux"}))


class WorkflowTests(unittest.TestCase):
    def test_fast_checks_reads_the_linux_pool(self) -> None:
        runs_on = {(path, name): value for path, name, value in jobs()}[("fast-checks.yml", "checks")]
        self.assertIn("needs.admit.outputs.runner", runs_on)
        self.assertNotIn("RUNNER_POOLS", runs_on)
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", runs_on)

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
