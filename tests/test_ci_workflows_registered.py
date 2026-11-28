#!/usr/bin/env python3
"""A workflow that only a dispatch starts can be dispatched: GitHub knows it.

GitHub registers a workflow file once it is on the default branch (main) or once an event has started a run of it.
A file only on feat-cmux-next whose triggers are workflow_dispatch (and workflow_call) never starts a run, so
GET .../actions/workflows/NAME/runs and POST .../dispatches answer 404: cmux-next-hourly-full-tier.yml never ran
from #58074 (2026-11-26) on, every post-merge tick logged "hourly full tier kick skipped: ... Not Found (HTTP 404)"
(job 140039772251) and passed, and relay-tls, ci.yml and the other hourly workflows got no full tier at all.

Such a workflow gets a push trigger on feat-cmux-next limited to its own path (the push that adds it registers
it). REGISTERED: dispatch-only workflows GitHub already listed on 2026-11-26 (GET /actions/workflows), frozen.
UNREGISTERED: dispatch-only workflows it did not list then; each dispatch 404s until it gains that push. Both
lists only shrink: an entry whose file is gone, or an UNREGISTERED one that gained a push, fails until removed.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
DISPATCH_ONLY = {"workflow_dispatch", "workflow_call"}

REGISTERED = frozenset({
    "acpmux-sim-sweep.yml", "auto-journey.yml", "billing-e2e.yml", "billing-nightly.yml",
    "build-ghosttykit.yml", "cloud-capture-provision.yml", "cloud-chat-proof.yml",
    "cloud-composer-journey.yml", "cloud-rd-link-readback.yml", "cloud-vm-dogfood.yml", "cloud-vm-image-bake.yml",
    "cloud-vm-image-promote.yml", "cloud-vm-migrate.yml", "cmux-actions.yml",
    "cmux-api-prod-logs.yml", "cmux-next-daemon-macos-shadow.yml", "cmux-next-dev-daily.yml",
    "cmux-next-fast-gates.yml", "cmux-next-frame-pacing.yml", "cmux-next-notices.yml", "cmux-next-perf-bench.yml",
    "cmux-next-perf-budgets.yml", "cmux-next-tip-test-compile.yml", "cmux-next-web-bundles.yml",
    "cmux-next-web-pieces.yml", "cmux-next-web.yml", "cmux-platform-prod-logs.yml", "cmux-tui-release-cut.yml",
    "cmux-tui-testbox-warmup.yml", "cmux-tui.yml", "fast-checks.yml",
    "first-user-journey-ios.yml", "first-user-journey-web.yml", "fixit-handoff.yml", "fleet-compile-check.yml",
    "gallery-health.yml", "ios-app-store.yml", "ios-appstore-upload.yml",
    "ios-screenshots.yml", "ios-streamed-validate.yml", "iroh-release-gate.yml", "machine-join-e2e.yml",
    "machine-vault-e2e.yml", "macos-cross-parity.yml", "main-compile-probe.yml", "nightly-next-rollback.yml",
    "nightly-next-train.yml", "nightly-next-verdict.yml", "nightly-tag-permission-probe.yml", "pr-status.yml",
    "presence.yml", "reload-build.yml", "repair-nightly-appcast-content-types.yml",
    "resume-nightly-notarization.yml", "screen-stream-eval.yml", "sdk-publish-crates.yml", "sdk-publish-go.yml",
    "sdk-publish-java.yml", "sdk-publish-npm.yml", "sdk-publish-python.yml", "stable-next-rollback.yml",
    "swift-acpmux-protocol.yml", "test-feed-reply-providers.yml", "tui-publish-npm.yml", "tui-publish-pypi.yml",
})

UNREGISTERED = frozenset({
    "classic-migration-staging.yml", "cmux-mobile-link-stats.yml", "cmux-next-fast-tier-batch.yml",
    "cmux-next-pr-pipeline-ios-batch.yml", "cmux-next-pr-pipeline-linux-batch.yml",
    "cmux-next-pr-pipeline-mac-batch.yml", "cmux-next-tooling-tests-batch.yml",
    "cmux-web-layer-fork.yml", "device-hub-logs.yml", "internal-token-staging.yml",
    "ios-asc-subscription-records.yml", "ios-testflight.yml",
})


def triggers(path: Path) -> dict:
    workflow = yaml.safe_load(path.read_text()) or {}
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {name: None for name in on}
    return dict(on or {})


def registers_itself(path: Path, on: dict) -> bool:
    push = on.get("push") or {}
    own = f".github/workflows/{path.name}"
    return "feat-cmux-next" in (push.get("branches") or []) and own in (push.get("paths") or [own])


class WorkflowsRegisteredTests(unittest.TestCase):
    def test_a_dispatch_only_workflow_registers_itself_with_a_push_on_its_own_path(self) -> None:
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            on = triggers(path)
            if "workflow_dispatch" not in on or set(on) - DISPATCH_ONLY or path.name in REGISTERED | UNREGISTERED:
                continue  # Any other trigger (push, schedule, pull_request) starts a run, which registers it.
            with self.subTest(workflow=path.name):
                self.fail(f"{path.name}: add on.push.branches [feat-cmux-next] and paths "
                          f"[.github/workflows/{path.name}], or a dispatch of it answers 404")

    def test_the_lists_only_shrink(self) -> None:
        self.assertFalse(REGISTERED & UNREGISTERED)
        for name in sorted(REGISTERED | UNREGISTERED):
            with self.subTest(workflow=name):
                path = WORKFLOWS / name
                self.assertTrue(path.exists(), f"{name} is gone: drop it from the list")
        for name in sorted(UNREGISTERED):
            with self.subTest(workflow=name):
                on = triggers(WORKFLOWS / name)
                self.assertFalse(registers_itself(WORKFLOWS / name, on),
                                 f"{name} registers itself now: drop it from UNREGISTERED")

    def test_the_hourly_full_tier_registers_itself(self) -> None:
        path = WORKFLOWS / "cmux-next-hourly-full-tier.yml"
        on = triggers(path)
        self.assertIn("workflow_dispatch", on)
        self.assertTrue(registers_itself(path, on))
        self.assertNotIn(path.name, REGISTERED | UNREGISTERED)


if __name__ == "__main__":
    unittest.main()
