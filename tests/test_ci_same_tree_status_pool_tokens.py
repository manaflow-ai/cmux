#!/usr/bin/env python3
"""A same-tree status post waits on its runner only once every token it holds is spent.

POOL_TOKEN_CHAIN (ci-min-per-pr-1500). Run 45898765362's `same-tree status (scheme)` job (2026-11-26 21:35Z) held
a Linux runner 15.6 min: github.token and the cmux-bot App token were both spent, so the post slept to the reset
(RATE_LIMIT_BUDGET_S, up to 3,540 s inside a 64-minute job). CI_POOL_TOKEN_1/_2 have their own hourly budgets
and already post the required `cmux/ios-fast` status in pr-router.yml. This fails if the reporters lose them or
the client stops moving through them before it sleeps.
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_same_tree_status as status  # noqa: E402

HEAD = "a" * 40
SPENT = (403, b'{"message":"API rate limit exceeded for installation."}',
         {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "9999999999"})


class PoolTokens(unittest.TestCase):
    def test_both_reporters_pass_the_pool_tokens(self):
        jobs = yaml.safe_load((ROOT / ".github" / "workflows" / "cmux-next.yml").read_text())["jobs"]
        for tier in status.TESTED:
            with self.subTest(tier=tier):
                steps = jobs[f"same-tree-status-{tier}"]["steps"]
                post = next(s for s in steps if s.get("name") == "Post the same-tree status")
                self.assertEqual(post["env"]["GH_TOKEN_POOL"],
                                 "${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}")

    def test_the_script_chains_app_then_pool_tokens(self):
        seen = {}

        class Client:
            def __init__(self, token, api_url="", spare=""):
                seen.update(token=token, spare=spare)

        argv = ["--tier", "daemon", "--repo", "o/r", "--status-sha", HEAD, "--state", "ready", "--needs", "{}"]
        original, env = status.notify.GitHub, dict(os.environ)
        status.notify.GitHub = Client
        os.environ.update(GH_TOKEN="workflow", GH_TOKEN_SPARE="app", GH_TOKEN_POOL="pool1 pool2")
        try:
            status.main(argv, sleep=lambda _s: None)
        except Exception:  # noqa: BLE001 - the stub has no get/post; only the construction is under test
            pass
        finally:
            status.notify.GitHub = original
            os.environ.clear()
            os.environ.update(env)
        self.assertEqual(seen, {"token": "workflow", "spare": "app pool1 pool2"})

    def test_spent_workflow_and_app_tokens_post_on_a_pool_token_with_no_sleep(self):
        client = status.notify.GitHub("workflow", "http://api.invalid", "app pool1 pool2")
        sent = []

        def send(method, url, body=None):
            sent.append(client.token)
            return SPENT if client.token in ("workflow", "app") else (201, b"{}", {})

        client._send = send
        slept = []
        args = status.parse(["--tier", "daemon", "--repo", "o/r", "--status-sha", HEAD, "--state", "ready",
                             "--needs", "{}"])
        ok = status.post(client, args, "success", "passed", "", sleep=slept.append, log=lambda _l: None)
        self.assertTrue(ok)
        self.assertEqual(sent, ["workflow", "app", "pool1"])
        self.assertEqual(slept, [], "a post with an unspent token left must not hold the runner")

    def test_empty_and_repeated_tokens_are_skipped(self):
        client = status.notify.GitHub("workflow", "http://api.invalid", " app  workflow app ")
        self.assertEqual(client.spares, ["app"])
        self.assertEqual(status.notify.GitHub("t", "http://api.invalid", "").spares, [])


if __name__ == "__main__":
    unittest.main()
