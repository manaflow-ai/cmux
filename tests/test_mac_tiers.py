#!/usr/bin/env python3
"""scripts/ci/mac_tiers.py: the Mac tiers the step table's `mac` steps ask for (ci/steps.toml)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "mac_tiers.py"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import mac_tiers  # noqa: E402

SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionRegistry.swift"


class MacTiersTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def env(self, paths: list[str] | None, raw: bytes | None = None, **pr) -> dict[str, str]:
        tmp = Path(self.tmp.name)
        env = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
               "CI_IDLE_BASE_MERGE_SKIP": "0"}
        if raw is not None or paths is not None:
            listed = tmp / "paths"
            listed.write_bytes(raw if raw is not None else "".join(f"{p}\n" for p in paths).encode())
            env["CI_PATHS_FILE"] = str(listed)
        event = {"action": "synchronize",
                 "pull_request": {"draft": False, "labels": [], "head": {"repo": {"full_name": "manaflow-ai/cmux"}},
                                  **pr}}
        (tmp / "event.json").write_text(json.dumps(event))
        env["GITHUB_EVENT_PATH"] = str(tmp / "event.json")
        return env

    def tiers(self, env: dict[str, str]) -> dict[str, str]:
        return mac_tiers.tiers(ROOT, env)[0]

    def test_a_swift_source_routes_both_tiers(self) -> None:
        values = self.tiers(self.env([SWIFT]))
        self.assertEqual(values["fast_tier"], "true")
        self.assertEqual(values["swift_canary"], "true")
        self.assertIn("CmuxNextActions", values["swift_canary_targets"].split())

    def test_a_change_no_tier_reads_routes_none(self) -> None:
        for path in ("docs/x.md", "ci/steps.toml", "scripts/ci/mac_tiers.py", ".github/workflows/pr-pipeline.yml"):
            with self.subTest(path=path):
                values = self.tiers(self.env([path]))
                self.assertEqual((values["fast_tier"], values["swift_canary"]), ("false", "false"))

    def test_an_unknown_change_routes_every_tier(self) -> None:
        values = self.tiers(self.env(None))
        self.assertEqual((values["fast_tier"], values["swift_canary"]), ("true", "false"))
        self.assertEqual(values["full"], "true")

    def test_the_paths_may_be_nul_separated(self) -> None:
        self.assertEqual(self.tiers(self.env(None, raw=f"{SWIFT}\0".encode()))["swift_canary"], "true")
        # Not one path: a Swift path and a doc read as one file would route nothing.
        self.assertEqual(self.tiers(self.env(None, raw=f"{SWIFT}\0docs/x.md\0".encode()))["fast_tier"], "true")

    def test_a_draft_routes_no_mac_tier(self) -> None:
        values = self.tiers(self.env([SWIFT], draft=True))
        self.assertEqual((values["fast_tier"], values["swift_canary"], values["macos"]), ("false", "false", "false"))
        # full-ci runs the Mac tiers on a draft (every tier: the full tier, not the small-diff canary).
        values = self.tiers(self.env([SWIFT], draft=True, labels=[{"name": "full-ci"}]))
        self.assertEqual((values["fast_tier"], values["full"]), ("true", "true"))

    def test_a_fork_runs_the_canary_only_with_full_ci(self) -> None:
        fork = {"head": {"repo": {"full_name": "someone/cmux"}}}
        values = self.tiers(self.env([SWIFT], **fork))
        self.assertEqual((values["fast_tier"], values["swift_canary"]), ("true", "false"))
        # With full-ci a fork's change runs the full tier, as a same-repository one does (the router's own rule).
        values = self.tiers(self.env([SWIFT], labels=[{"name": "full-ci"}], **fork))
        self.assertEqual((values["fast_tier"], values["full"]), ("true", "true"))

    def test_has_exits_by_the_tier(self) -> None:
        def has(tier: str, paths: list[str]) -> subprocess.CompletedProcess:
            env = {**os.environ, **self.env(paths)}
            return subprocess.run([sys.executable, "-I", str(SCRIPT), "has", tier], env=env, capture_output=True,
                                  text=True, timeout=300)

        done = has("swift_canary", [SWIFT])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("swift_canary=true", done.stdout.splitlines())
        self.assertEqual(has("fast_tier", ["docs/x.md"]).returncode, 1)
        bad = subprocess.run([sys.executable, "-I", str(SCRIPT), "has", "nope"], capture_output=True, text=True,
                             timeout=60)
        self.assertNotEqual(bad.returncode, 0)

    def test_route_appends_to_the_github_output(self) -> None:
        out = Path(self.tmp.name) / "out"
        env = {**os.environ, **self.env([SWIFT])}
        done = subprocess.run([sys.executable, "-I", str(SCRIPT), "route", "--github-output", str(out)], env=env,
                              capture_output=True, text=True, timeout=300)
        self.assertEqual(done.returncode, 0, done.stderr)
        lines = out.read_text().splitlines()
        self.assertIn("fast_tier=true", lines)
        self.assertIn("swift_canary=true", lines)

    def test_anything_unread_routes_every_tier(self) -> None:
        env = {**os.environ, **self.env([SWIFT])}
        env["GITHUB_EVENT_PATH"] = str(Path(self.tmp.name) / "missing.json")
        # A missing event is read as no labels and no head facts: the paths still route.
        self.assertEqual(self.tiers(env)["swift_canary"], "true")


if __name__ == "__main__":
    unittest.main()
