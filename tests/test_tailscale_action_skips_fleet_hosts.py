#!/usr/bin/env python3
"""Every tailscale/github-action step in cmux (workflows and composite actions) leaves a fleet host's own node alone.

A self-hosted runner on a fleet host (hetzner-N-M, gcp-agent-lane-N, fs-agent-lane-N) shares the host's tailscaled. The
action's `tailscale up` re-registers the host as github-HOST under the job's tag (tag:ci) and its post step logs it out:
hetzner-2 on 2026-11-28 showed tag:ci, got 401 from the build controller, then read NeedsLogin. Each step must either
skip those runner names in its `if`, or follow a guard step (the claude-pool `fresh` check, or
scripts/e2e/require-fresh-tailnet-host.sh) that sees the runner name, the tailscaled socket and `tailscale status`, not
only `pgrep` (which a hidepid /proc or another PID namespace hides). cmuxterm-hq has the same detector for its
workflows (tests/test_tailscale_action_skips_tailnet_hosts.py, handbook ci-tailscale-action-logs-out-host.md).
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ("gcp-agent-lane-", "hetzner-", "fs-agent-lane-")
GUARD_SCRIPT = ROOT / "scripts/e2e/require-fresh-tailnet-host.sh"
POOL_ACTION = ROOT / ".github/actions/claude-pool/action.yml"


def step_lists():
    """(file, job or action, steps) for every workflow job and composite action."""
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for name, job in (doc.get("jobs") or {}).items():
            if isinstance(job, dict) and isinstance(job.get("steps"), list):
                yield path, name, job["steps"]
    for path in sorted((ROOT / ".github/actions").glob("*/action.y*ml")):
        doc = yaml.safe_load(path.read_text()) or {}
        steps = (doc.get("runs") or {}).get("steps")
        if isinstance(steps, list):
            yield path, path.parent.name, steps


def skips_fleet(cond: str) -> bool:
    return all(f"!startsWith(runner.name, '{p}')" in cond for p in PREFIXES)


def guarded_by_earlier_step(steps: list, i: int) -> bool:
    for step in steps[:i]:
        run = str(step.get("run") or "")
        if "require-fresh-tailnet-host.sh" in run:
            return True
    return False


class TailscaleStepsSkipFleetHosts(unittest.TestCase):
    def test_every_tailscale_step_is_guarded(self):
        seen, bad = 0, []
        for path, job, steps in step_lists():
            for i, step in enumerate(steps):
                if not str((step or {}).get("uses") or "").startswith("tailscale/github-action@"):
                    continue
                seen += 1
                if not (skips_fleet(str(step.get("if") or "")) or guarded_by_earlier_step(steps, i)):
                    bad.append(f"{path.relative_to(ROOT)} {job}: {step.get('name')!r}")
        self.assertGreater(seen, 0)
        self.assertEqual(bad, [], "tailscale steps that can log a fleet host off the tailnet; add "
                         + " && ".join(f"!startsWith(runner.name, '{p}')" for p in PREFIXES) + " to their if")


def stub_bin(d: Path, name: str, code: int) -> None:
    f = d / name
    f.write_text(f"#!/bin/sh\nexit {code}\n")
    f.chmod(f.stat().st_mode | stat.S_IEXEC)


class FreshChecks(unittest.TestCase):
    """The claude-pool `fresh` step and the e2e guard both refuse a fleet runner name and a live backend that pgrep
    cannot see."""

    def pool_fresh(self, env: dict) -> str:
        doc = yaml.safe_load(POOL_ACTION.read_text())
        script = next(s for s in doc["runs"]["steps"] if s.get("id") == "fresh")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            out.write_text("")
            subprocess.run(["bash", "-c", script], check=True, capture_output=True,
                           env={**env, "GITHUB_OUTPUT": str(out), "CLIENT_ID": "client"})
            return out.read_text()

    def guard(self, env: dict) -> int:
        return subprocess.run(["bash", str(GUARD_SCRIPT)], capture_output=True, env=env).returncode

    def env(self, d: Path, status_code: int, runner: str) -> dict:
        stub_bin(d, "pgrep", 1)  # the daemon is invisible to the runner user
        stub_bin(d, "tailscale", status_code)
        stub_bin(d, "hostname", 0)
        return {"PATH": f"{d}:/usr/bin:/bin", "RUNNER_NAME": runner}

    def test_fleet_runner_name_never_joins(self):
        for prefix in PREFIXES:
            with tempfile.TemporaryDirectory() as tmp:
                env = self.env(Path(tmp), 1, prefix + "2-1")
                self.assertIn("join=false", self.pool_fresh(env), prefix)
                self.assertEqual(self.guard(env), 1, prefix)

    def test_backend_pgrep_cannot_see_blocks_join(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.env(Path(tmp), 0, "cmux-gcp-secret-jit-x64-abc")
            self.assertIn("join=false", self.pool_fresh(env))
            self.assertEqual(self.guard(env), 1)

    @unittest.skipIf(os.path.exists("/var/run/tailscale/tailscaled.sock") or os.path.exists("/run/tailscale/tailscaled.sock"),
                     "this host runs tailscaled")
    def test_fresh_ephemeral_runner_still_joins(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.env(Path(tmp), 1, "cmux-gcp-secret-jit-x64-abc")
            self.assertIn("join=true", self.pool_fresh(env))
            self.assertEqual(self.guard(env), 0)


if __name__ == "__main__":
    unittest.main()
