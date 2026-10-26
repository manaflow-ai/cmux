#!/usr/bin/env python3
"""bench_renderer_sharing.py without an app (no macOS): the browser host socket it reads from the
host's command line, the agent session's REPL code, the per-site sharing checks (Chrome's 2 same-site
main frames per renderer below the limit, never two sites, the agent's renderer alone) and the limit
they are checked below. Run from the repo root: python3 -I tests/test_bench_renderer_sharing.py."""
import importlib.util
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "bench_renderer_sharing.py")
sys.path.insert(0, os.path.dirname(SCRIPT))
if sys.platform != "darwin":
    # bench_power loads libproc at import (macOS only); these tests call none of its functions.
    sys.modules["bench_power"] = types.SimpleNamespace(rpc=None, wipe_state=None)
spec = importlib.util.spec_from_file_location("bench_renderer_sharing", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

BUNDLE = "/tmp/cmux DEV rsharing.app"


class FakeReport:
    def __init__(self, raw):
        self.raw = raw


class HostSocketTests(unittest.TestCase):
    def test_the_socket_is_the_rest_of_the_serve_line(self):
        rows = [
            (10, 1, "/usr/bin/other serve --socket /tmp/x.sock"),
            (11, 1, f"{BUNDLE}/Contents/Resources/bin/cmux-browser-host serve --supervised --idle-exit-ms 300000 "
                    "--socket /tmp/scratch dir/bh-0123456789ab/browser-host.sock"),
        ]
        self.assertEqual(bench.host_socket(rows, BUNDLE), "/tmp/scratch dir/bh-0123456789ab/browser-host.sock")

    def test_the_private_spelling_of_the_bundle_counts(self):
        rows = [(11, 1, f"{BUNDLE}/Contents/Resources/bin/cmux-browser-host serve --socket /tmp/a.sock")]
        self.assertEqual(bench.host_socket(rows, "/private" + BUNDLE), "/tmp/a.sock")

    def test_another_bundles_host_and_the_eval_cli_do_not_count(self):
        rows = [
            (12, 1, "/Applications/cmux.app/Contents/Resources/bin/cmux-browser-host serve --socket /tmp/b.sock"),
            (13, 1, f"{BUNDLE}/Contents/Resources/bin/cmux-browser-host eval --session s --socket /tmp/c.sock"),
        ]
        self.assertIsNone(bench.host_socket(rows, BUNDLE))


class AgentScriptTests(unittest.TestCase):
    def test_it_claims_the_tab_and_reads_its_title(self):
        code = bench.agent_script("tab_1", 'http://site0.test:1/0"')
        self.assertIn('t.id === "tab_1"', code)
        self.assertIn('t.url === "http://site0.test:1/0\\""', code)
        self.assertIn("tabs.use(hit.id)", code)
        self.assertIn("driven.title()", code)


class SiteSharingTests(unittest.TestCase):
    SITES = {"a0": 0, "a1": 0, "a2": 0, "b0": 1, "b1": 1, "agent": 0}

    def test_two_same_site_frames_per_renderer_pass(self):
        owners = {1: ["agent"], 2: ["a0", "a1"], 3: ["a2"], 4: ["b0", "b1"], 5: []}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10)
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["max_same_site_main_frames"], 2)
        self.assertEqual(result["shared_renderers"], 2)
        self.assertEqual(result["agent_renderer_tabs"], 1)
        self.assertEqual(result["tab_renderers"], 4)
        self.assertTrue(result["below_limit"])

    def test_three_same_site_frames_below_the_limit_fail(self):
        owners = {1: ["agent"], 2: ["a0", "a1", "a2"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10)
        self.assertEqual(result["max_same_site_main_frames"], 3)
        self.assertEqual(len(result["violations"]), 1)

    def test_above_the_limit_same_site_reuse_is_allowed(self):
        owners = {1: ["agent", "a2"], 2: ["a0", "a1"], 3: ["b0", "b1"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=3)
        self.assertFalse(result["below_limit"])
        self.assertEqual(result["violations"], [])

    def test_two_sites_in_one_renderer_always_fail(self):
        owners = {1: ["a0", "b0"], 2: ["a1"], 3: ["b1"]}
        result = bench.site_sharing(owners, self.SITES, None, limit=2)
        self.assertEqual(result["mixed_site_renderers"], 1)
        self.assertEqual(len(result["violations"]), 1)
        self.assertIsNone(result["agent_renderer_tabs"])

    def test_the_agents_renderer_takes_no_other_tab_below_the_limit(self):
        owners = {1: ["agent", "a0"], 2: ["a1"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10)
        self.assertEqual(result["agent_renderer_tabs"], 2)
        self.assertIn("the agent's renderer holds 2 tabs", result["violations"])

    def test_tabs_the_bench_did_not_open_do_not_count(self):
        owners = {1: ["a0", "a1", "home"], 2: ["other"]}
        result = bench.site_sharing(owners, self.SITES, None, limit=10)
        self.assertEqual(result["tab_renderers"], 1)
        self.assertEqual(result["violations"], [])


class LimitTests(unittest.TestCase):
    def test_forced_limit_wins(self):
        self.assertEqual(bench.renderer_limit(FakeReport({"budget": {"chromium_renderer_limit": 64}}), 82, 6), 6)

    def test_the_lower_of_chrome_and_the_budget(self):
        self.assertEqual(bench.renderer_limit(FakeReport({"budget": {"chromium_renderer_limit": 64}}), 82, None), 64)
        self.assertEqual(bench.renderer_limit(FakeReport({"budget": {"chromium_renderer_limit": 90}}), 82, None), 82)

    def test_no_report_or_budget_gives_chromes(self):
        self.assertEqual(bench.renderer_limit(None, 82, None), 82)
        self.assertEqual(bench.renderer_limit(FakeReport({}), 82, None), 82)
        self.assertEqual(bench.renderer_limit(FakeReport({"budget": {"chromium_renderer_limit": True}}), 82, None), 82)

    def test_fork_api_from_debug_cef(self):
        self.assertEqual(bench.fork_api({"windows": {"fork_api": 29.0}}), 29)
        self.assertIsNone(bench.fork_api({"windows": {}}))
        self.assertIsNone(bench.fork_api(None))


if __name__ == "__main__":
    unittest.main()
