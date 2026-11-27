"""app-token-spread spends a quota-goblin pool token before minting the routing App (no network).

The manaflow-glaeda-route App (5067688) installation's 5,000 an hour read 0 left
every hour on 2026-11-25..27. Read-only steps whose permissions fit the
quota-goblin CI pool tokens (CI_POOL_TOKEN_1/2: contents, pull-requests and
checks read plus actions, this repository) now read on the pool, and the
glaeda-route and cmux-bot mints are skipped when a pool token has budget.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACTION = ROOT / ".github" / "actions" / "app-token-spread" / "action.yml"
WORKFLOWS = ROOT / ".github" / "workflows"
POOL = "${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}"
CURL = """#!/bin/bash
case "$*" in
  *tokA*) printf '{\\n "resources": {\\n  "core": {\\n   "limit": 5000,\\n   "remaining": 4200\\n  }\\n }\\n}' ;;
  *tokB*) printf '{"resources":{"core":{"limit":5000,"remaining":4800}}}' ;;
  *) printf '{"message":"Bad credentials"}' ;;
esac
"""


def steps() -> dict:
    return {s["id"]: s for s in yaml.safe_load(ACTION.read_text(encoding="utf-8"))["runs"]["steps"]}


class PoolStep(unittest.TestCase):
    def run_pool(self, **env: str) -> dict:
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "bin").mkdir()
            curl = Path(d) / "bin" / "curl"
            curl.write_text(CURL)
            curl.chmod(0o755)
            out = Path(d) / "out"
            out.write_text("")
            script = Path(d) / "pool.sh"
            script.write_text(steps()["pool"]["run"])
            subprocess.run(["bash", "-e", str(script)], check=True, capture_output=True, env={
                "PATH": f"{d}/bin:/usr/bin:/bin", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                "GITHUB_OUTPUT": str(out), **env})
            return dict(line.split("=", 1) for line in out.read_text().splitlines() if line)

    def test_the_fullest_live_pool_token_wins(self) -> None:
        got = self.run_pool(POOL_TOKENS="tokA tokB", P_ACTIONS="read", P_PRS="read")
        self.assertEqual(got, {"token": "tokB", "app": "quota-goblin-pool-2", "remaining": "4800"})

    def test_an_expired_token_is_skipped(self) -> None:
        got = self.run_pool(POOL_TOKENS="expired,tokA", P_CONTENTS="read")
        self.assertEqual(got["token"], "tokA")

    def test_reads_outside_the_pool_scope_keep_the_mints(self) -> None:
        for env in ({"P_ISSUES": "read"}, {"P_ADMIN": "read"}, {"P_RUNNERS": "read"},
                    {"P_ACTIONS": "write"}, {"WANT_REPOS": "cmuxterm-hq"}, {"WANT_OWNER": "other"},
                    {"POOL_FLOOR": "5000"}):
            with self.subTest(env=env):
                self.assertEqual(self.run_pool(POOL_TOKENS="tokA", **env), {})

    def test_a_pool_pick_skips_both_app_mints(self) -> None:
        s = steps()
        for step_id in ("route", "bot"):
            self.assertIn("steps.pool.outputs.token == ''", s[step_id]["if"])


class Callers(unittest.TestCase):
    def test_read_only_spread_callers_pass_the_pool(self) -> None:
        for name, job, step_id in (("ci.yml", "changes", "admitted-read-token"),
                                   ("ci-ui-tests.yml", None, "read-token"),
                                   ("ci-hosted-queue-rescue.yml", None, "glaeda-token"),
                                   ("backend-migrations.yml", None, "glaeda-token"),
                                   ("pr-media.yml", None, "read-token")):
            document = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
            found = [s for j, body in document["jobs"].items() if job in (None, j)
                     for s in body.get("steps") or [] if s.get("id") == step_id]
            with self.subTest(workflow=name, step=step_id):
                self.assertTrue(found)
                for s in found:
                    self.assertEqual(s["with"]["pool-tokens"], POOL)


if __name__ == "__main__":
    unittest.main()
