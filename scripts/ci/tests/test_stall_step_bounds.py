#!/usr/bin/env python3
"""The checkout, setup and cache steps that stalled on the Linux pools carry a step bound (note-stall-step-bounds).

docs/ci/cmux-next-workflow-notes.md#note-stall-step-bounds: a stalled actions/checkout, toolchain setup or cache restore held its
job's runner for the job's whole limit (15 to 55 min) before going red. Each step below has a `timeout-minutes` a few
times its healthy duration, and every cache step continues past its bound (a cache miss), so a bound never fails a
job that would have passed. Run: python3 scripts/ci/tests/test_stall_step_bounds.py (about 1 s, no build).
"""
from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github/workflows"

# Healthy durations measured on 2026-11-23 (note-stall-step-bounds), in seconds: the bound must stay well above them.
HEALTHY_MAX_SECONDS = {"checkout": 193, "rust": 120, "setup": 60, "cache": 46}
# Longest passing checkout per job, 2026-11-25/26 step samples (note-stall-step-bounds): these jobs fetch on Macs or full trees.
HEALTHY_MAX_SECONDS.update({"checkout-mac": 693, "checkout-swift-test": 485, "checkout-daemon": 395, "checkout-clippy": 246})
RETRY = "Retry checkout after transient network failure"
# (workflow, job, how the step is found: its name or its `uses` prefix, kind, bound in minutes)
BOUNDS = (
    ("cmux-next.yml", "web-bundles", "actions/checkout@", "checkout", 6),
    ("cmux-next.yml", "web-bundles", "Look up the cached web bundles", "cache", 5),
    ("cmux-next.yml", "web-bundles", "Cache the webviews Bun package cache", "cache", 3),
    ("cmux-next.yml", "fast-tier-cargo", "actions/checkout@", "checkout", 6),
    ("ci-web.yml", "agent-pane-real-acpmux", "Checkout", "checkout", 6),
    ("ci-web.yml", "agent-pane-real-acpmux", "Cache Bun package cache", "cache", 3),
    ("ci-web.yml", "agent-pane-real-acpmux", "Cache Bun package cache (restore only off feat-cmux-next)", "cache", 3),
    ("ci-web.yml", "agent-pane-real-acpmux", "Set up pinned Rust", "rust", 8),
    ("cmux-next-web-lint.yml", "web-lint", "Cache Bun package cache", "cache", 3),
    ("cmux-next-web-lint.yml", "web-lint", "Cache Bun package cache (restore only off base branches)", "cache", 3),
    ("ci-guards.yml", "workflow-guard-history", "Checkout", "checkout", 6),
    ("ci-guards.yml", "workflow-guard-history", "Set up Python 3.9", "setup", 5),
    ("backend.yml", "test", "actions/setup-node@", "setup", 5),
    ("cmux-next.yml", "checks", "Checkout", "checkout", 6),
    ("cmux-next.yml", "checks", RETRY, "checkout", 6),
    ("cmux-next.yml", "swift-test", "Checkout", "checkout-swift-test", 15),
    ("cmux-next.yml", "swift-test", RETRY, "checkout-swift-test", 15),
    ("cmux-next.yml", "daemon-test", "Checkout", "checkout-daemon", 12),
    ("cmux-next.yml", "daemon-test", RETRY, "checkout-daemon", 12),
    ("pr-pipeline.yml", "mac", "Checkout the merge commit and the base tip", "checkout-mac", 21),
    ("pr-pipeline.yml", "mac", RETRY, "checkout-mac", 21),
    ("cmux-tui-spec.yml", "clippy", "Checkout", "checkout-clippy", 8),
    ("cmux-tui-spec.yml", "clippy", RETRY, "checkout-clippy", 8),
)


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text())


def find_steps(workflow: dict, job: str | None, needle: str) -> list[dict]:
    jobs = workflow["jobs"]
    selected = [jobs[job]] if job else list(jobs.values())
    found = []
    for spec in selected:
        for step in spec.get("steps") or []:
            if step.get("name") == needle or (needle.endswith("@") and not step.get("name")
                                               and str(step.get("uses", "")).startswith(needle)):
                found.append(step)
    return found


class StallStepBoundsTests(unittest.TestCase):
    def test_each_stalled_step_is_bounded(self):
        cache: dict[str, dict] = {}
        for name, job, needle, kind, minutes in BOUNDS:
            with self.subTest(workflow=name, job=job, step=needle):
                workflow = cache.setdefault(name, load(name))
                steps = find_steps(workflow, job, needle)
                self.assertTrue(steps, f"{name} {job}: no step {needle!r}; update BOUNDS and note-stall-step-bounds with the move")
                for step in steps:
                    self.assertEqual(step.get("timeout-minutes"), minutes,
                                     f"{name} {job} {needle!r}: bound {step.get('timeout-minutes')!r}, want {minutes}")

    def test_cache_steps_fail_open(self):
        for name, job, needle, kind, _ in BOUNDS:
            if kind != "cache":
                continue
            with self.subTest(workflow=name, job=job, step=needle):
                for step in find_steps(load(name), job, needle):
                    self.assertIs(step.get("continue-on-error"), True,
                                  f"{name} {job} {needle!r}: a cache step past its bound must continue as a miss")

    def test_bounds_keep_room_above_healthy(self):
        for name, job, needle, kind, minutes in BOUNDS:
            with self.subTest(workflow=name, job=job, step=needle):
                self.assertGreaterEqual(minutes * 60, 1.8 * HEALTHY_MAX_SECONDS[kind])

    def test_a_bounded_first_checkout_has_its_retry(self):
        for name, job, needle, kind, _ in BOUNDS:
            if not kind.startswith("checkout") or needle == RETRY or (name, job, RETRY, kind) not in {b[:4] for b in BOUNDS}:
                continue
            with self.subTest(workflow=name, job=job):
                first = find_steps(load(name), job, needle)
                self.assertTrue(all(s.get("continue-on-error") is True and s.get("id") == "checkout" for s in first),
                                f"{name} {job}: the first checkout continues to its retry (id: checkout, continue-on-error)")
                retry = find_steps(load(name), job, RETRY)
                self.assertTrue(retry and all(s.get("if") == "steps.checkout.outcome == 'failure'" for s in retry))

    def test_no_job_limit_is_shortened_below_its_bound(self):
        for name, job, needle, kind, minutes in BOUNDS:
            if job is None:
                continue
            limit = load(name)["jobs"][job].get("timeout-minutes")
            if isinstance(limit, int):
                with self.subTest(workflow=name, job=job):
                    self.assertGreater(limit, minutes)


if __name__ == "__main__":
    unittest.main()
