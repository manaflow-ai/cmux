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

    def test_it_reads_the_title_after_the_rebuilt_page_loads_the_url(self):
        code = bench.agent_script("tab_1", "http://site0.test:1/0")
        wait = code.index("driven.waitForURL(\"http://site0.test:1/0\", { waitUntil: 'load' })")
        self.assertLess(wait, code.index("driven.title()"))


class HostCliEnvTests(unittest.TestCase):
    def test_the_cli_sees_a_daemon_owned_socket(self):
        # cmux-browser-host.rs daemon_owns: both variables, or a failed connect starts a second host on the socket.
        env = bench.host_cli_env("/tmp/bh/browser-host.sock", "/tmp/app/daemon.sock")
        self.assertEqual(env["CMUX_BROWSER_HOST_SOCKET"], "/tmp/bh/browser-host.sock")
        self.assertEqual(env["CMUX_TUI_SOCKET"], "/tmp/app/daemon.sock")


class SiteSharingTests(unittest.TestCase):
    SITES = {"a0": 0, "a1": 0, "a2": 0, "b0": 1, "b1": 1, "agent": 0}

    def test_two_same_site_frames_per_renderer_pass(self):
        owners = {1: ["agent"], 2: ["a0", "a1"], 3: ["a2"], 4: ["b0", "b1"], 5: []}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10, renderers=5, require_sharing=True)
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["max_same_site_main_frames"], 2)
        self.assertEqual(result["shared_renderers"], 2)
        self.assertEqual(result["agent_renderer_tabs"], 1)
        self.assertEqual(result["tab_renderers"], 4)
        self.assertEqual(result["unshared_sites"], [])
        self.assertTrue(result["below_limit"])

    def test_three_same_site_frames_below_the_limit_fail(self):
        owners = {1: ["agent"], 2: ["a0", "a1", "a2"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10, renderers=2)
        self.assertEqual(result["max_same_site_main_frames"], 3)
        self.assertEqual(len(result["violations"]), 1)

    def test_above_the_limit_same_site_reuse_is_allowed(self):
        owners = {1: ["agent", "a2"], 2: ["a0", "a1"], 3: ["b0", "b1"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=3, renderers=3)
        self.assertFalse(result["below_limit"])
        self.assertEqual(result["violations"], [])

    def test_renderers_without_a_bench_tab_count_toward_the_limit(self):
        # Chrome counts every renderer (uBlock, internal pages): 2 tab renderers plus 2 others are at a limit of 4,
        # so a third same-site main frame in one renderer is Chrome's above-limit reuse, not a violation.
        owners = {1: ["agent"], 2: ["a0", "a1", "a2"], 3: [], 4: []}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=4, renderers=4)
        self.assertFalse(result["below_limit"])
        self.assertEqual(result["violations"], [])

    def test_two_sites_in_one_renderer_always_fail(self):
        owners = {1: ["a0", "b0"], 2: ["a1"], 3: ["b1"]}
        result = bench.site_sharing(owners, self.SITES, None, limit=2, renderers=3)
        self.assertEqual(result["mixed_site_renderers"], 1)
        self.assertEqual(len(result["violations"]), 1)
        self.assertIsNone(result["agent_renderer_tabs"])

    def test_the_agents_renderer_takes_no_other_tab_below_the_limit(self):
        owners = {1: ["agent", "a0"], 2: ["a1"]}
        result = bench.site_sharing(owners, self.SITES, "agent", limit=10, renderers=2)
        self.assertEqual(result["agent_renderer_tabs"], 2)
        self.assertIn("the agent's renderer holds 2 tabs", result["violations"])

    def test_tabs_the_bench_did_not_open_do_not_count(self):
        owners = {1: ["a0", "a1", "home"], 2: ["other"]}
        result = bench.site_sharing(owners, self.SITES, None, limit=10, renderers=2)
        self.assertEqual(result["tab_renderers"], 1)
        self.assertEqual(result["violations"], [])


class NoSharingTests(unittest.TestCase):
    """The bug 046 fixes: an agent's DevTools session turns sharing off for the whole browser
    (WasEverAttachedToAnyFrame), so every tab gets its own renderer. That must fail, not pass."""

    def test_every_tab_in_its_own_renderer_with_an_agent_fails(self):
        sites = SiteSharingTests.SITES
        owners = {1: ["agent"], 2: ["a0"], 3: ["a1"], 4: ["a2"], 5: ["b0"], 6: ["b1"], 7: []}
        result = bench.site_sharing(owners, sites, "agent", limit=82, renderers=7, require_sharing=True)
        self.assertEqual(result["max_same_site_main_frames"], 1)
        self.assertEqual(result["shared_renderers"], 0)
        self.assertEqual(result["unshared_sites"], [0, 1])
        self.assertEqual(len(result["violations"]), 1)
        self.assertIn("2 of 2 sites with 2 or more tabs share no renderer", result["violations"][0])

    def test_the_full_bench_unshared_is_over_the_limit_yet_fails(self):
        # 100 tabs over 20 sites, one renderer each, plus 3 others: 103 renderers, over Chrome's 82, so the
        # over-sharing rules are off; shared, the layout needs 3 + 1 (agent) + 2 + 19 * 3 = 63, below 82.
        site_of = {f"t{i}": i % 20 for i in range(100)}
        owners = {i: [f"t{i}"] for i in range(100)}
        owners.update({100: [], 101: [], 102: []})
        result = bench.site_sharing(owners, site_of, "t0", limit=82, renderers=103, require_sharing=True)
        self.assertFalse(result["below_limit"])
        self.assertEqual(result["shared_layout_renderers"], 63)
        self.assertEqual(len(result["unshared_sites"]), 20)
        self.assertEqual(len(result["violations"]), 1)

    def test_chromes_pairs_pass_the_full_bench(self):
        # Shared as Chrome does: the agent's tab alone, then each site's tabs in pairs.
        site_of = {f"t{i}": i % 20 for i in range(100)}
        owners, pid = {0: ["t0"]}, 1
        for site in range(20):
            tabs = [f"t{i}" for i in range(100) if i % 20 == site and i != 0]
            for start in range(0, len(tabs), 2):
                owners[pid] = tabs[start:start + 2]
                pid += 1
        result = bench.site_sharing(owners, site_of, "t0", limit=82, renderers=len(owners) + 3, require_sharing=True)
        self.assertTrue(result["below_limit"])
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["max_same_site_main_frames"], 2)

    def test_sharing_in_the_agents_renderer_does_not_count(self):
        sites = SiteSharingTests.SITES
        owners = {1: ["agent", "a0"], 2: ["a1"], 3: ["b0", "b1"]}
        result = bench.site_sharing(owners, sites, "agent", limit=82, renderers=3, require_sharing=True)
        self.assertEqual(result["unshared_sites"], [0])

    def test_no_layout_below_the_limit_asks_for_no_sharing(self):
        sites = SiteSharingTests.SITES
        owners = {1: ["agent"], 2: ["a0"], 3: ["a1"], 4: ["b0"], 5: ["b1"]}
        result = bench.site_sharing(owners, sites, "agent", limit=3, renderers=5, require_sharing=True)
        self.assertEqual(result["shared_layout_renderers"], 3)
        self.assertEqual(result["violations"], [])

    def test_without_an_agent_unshared_tabs_are_only_reported(self):
        sites = SiteSharingTests.SITES
        owners = {2: ["a0"], 3: ["a1"], 5: ["b0"], 6: ["b1"]}
        result = bench.site_sharing(owners, sites, None, limit=82, renderers=4)
        self.assertEqual(result["unshared_sites"], [0, 1])
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

    def test_a_passed_renderer_process_limit_switch_is_the_limit(self):
        report = FakeReport({"budget": {"chromium_renderer_limit": 64}})
        self.assertEqual(bench.renderer_limit(report, 82, None, ["renderer-process-limit=12"]), 12)
        self.assertEqual(bench.renderer_limit(report, 82, None, ["--renderer-process-limit=7", "x=1"]), 7)
        self.assertEqual(bench.renderer_limit(report, 82, 6, ["renderer-process-limit=12"]), 6)
        self.assertEqual(bench.renderer_limit(report, 82, None, ["renderer-process-limit=0", "renderer-process-limit"]), 64)

    def test_the_reuse_switch_from_debug_cef(self):
        self.assertTrue(bench.reuse_switch({"windows": {"process_reuse_per_renderer_devtools": True}}))
        self.assertFalse(bench.reuse_switch({"windows": {"process_reuse_per_renderer_devtools": False}}))
        # An older build does not report it: unknown, never derived from the fork API.
        self.assertIsNone(bench.reuse_switch({"windows": {"fork_api": 29}}))
        self.assertIsNone(bench.reuse_switch(None))

    def test_fork_api_from_debug_cef(self):
        self.assertEqual(bench.fork_api({"windows": {"fork_api": 29.0}}), 29)
        self.assertIsNone(bench.fork_api({"windows": {}}))
        self.assertIsNone(bench.fork_api(None))


if __name__ == "__main__":
    unittest.main()
