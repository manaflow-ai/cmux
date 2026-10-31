#!/usr/bin/env python3
"""Tests of the browser fuzz's pure part (generator, oracles, shrinker). No app: runs anywhere.

  python3 scripts/fuzz/browser/test_fuzz_model.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fuzz_model as model  # noqa: E402


class GeneratorTests(unittest.TestCase):
    def test_same_seed_same_ops(self):
        self.assertEqual(model.generate(7, 200), model.generate(7, 200))
        self.assertNotEqual(model.generate(7, 200), model.generate(8, 200))

    def test_ops_are_json_and_start_with_an_open(self):
        ops = model.generate(1, 300, "http://localhost:1", "fz1")
        self.assertEqual(len(ops), 300)
        self.assertEqual(ops[0]["op"], "open")
        json.dumps(ops)
        self.assertTrue(all(op["op"] in model.WEIGHTS for op in ops))

    def test_corpus_covers_every_category_the_row_names(self):
        categories = {op.get("category") for seed in range(40) for op in model.generate(seed, 200) if "category" in op}
        for wanted in ("local", "example", "malformed", "huge", "script", "internal", "file", "external", "idn"):
            self.assertIn(wanted, categories)
        names = {op["op"] for seed in range(40) for op in model.generate(seed, 200)}
        for wanted in ("back", "forward", "reload", "open_storm", "close_storm", "move_storm", "move_workspace",
                       "move_new_window", "devtools", "download", "kill_renderer", "crash_page"):
            self.assertIn(wanted, names)

    def test_origin_placeholder_stays_until_the_op_runs(self):
        ops = model.generate(3, 200)
        local = [op["url"] for op in ops if op.get("category") == "local"]
        self.assertTrue(local and all(url.startswith("{origin}/") for url in local))


class SchemeTests(unittest.TestCase):
    def test_scheme_as_chromium_reads_it(self):
        self.assertEqual(model.scheme_of("  JavaScript:alert(1)"), "javascript")
        self.assertEqual(model.scheme_of("java\tscript:x"), "javascript")
        self.assertEqual(model.scheme_of("jav\nascript:x"), "javascript")
        self.assertEqual(model.scheme_of("example.com"), "")
        self.assertEqual(model.scheme_of("1http://x"), "")
        self.assertEqual(model.scheme_of("münchen:x"), "")

    def test_agent_policy_matches_the_app(self):
        # schemas/agent-url-policy/vectors.json is the shared truth; check it when present.
        vectors = os.path.join(HERE, "..", "..", "..", "schemas", "agent-url-policy", "vectors.json")
        if os.path.exists(vectors):
            with open(vectors) as handle:
                data = json.load(handle)
            cases = data.get("cases") if isinstance(data, dict) else data
            checked = 0
            for case in cases or []:
                url = case.get("url") if isinstance(case, dict) else None
                want = case.get("refused") if isinstance(case, dict) else None
                if isinstance(url, str) and isinstance(want, bool):
                    self.assertEqual(model.agent_refuses(url), want, url)
                    checked += 1
            self.assertGreater(checked, 0, "no {url, refused} vectors read")
        for url in ("chrome://settings", "CHROME://settings", "view-source:http://x", "about:version", "blob:chrome://x/y",
                    "filesystem:blob:blob:http://x", "cmux://history", "cmux-page://cmux/", "cmux-page://shell/"):
            self.assertTrue(model.agent_refuses(url), url)
        for url in ("http://x.test/", "about:blank", "about:srcdoc", "blob:http://x/y", "cmux-page://com.example.app/", "file:///etc/hosts"):
            self.assertFalse(model.agent_refuses(url), url)


class OracleTests(unittest.TestCase):
    def test_stalls_over_counts_only_stalls_over_the_limit(self):
        records = [{"kind": "stall", "duration_ms": 99.9}, {"kind": "stall", "duration_ms": 140, "frames": ["a cmux frame"]},
                   {"kind": "busy", "duration_ms": 900}, {"kind": "over_budget", "duration_ms": 300}]
        over = model.stalls_over(records)
        self.assertEqual([r["duration_ms"] for r in over], [140])
        self.assertIn("140 ms", model.stall_summary(over[0]))

    def test_committed_url(self):
        ok = model.committed_url_violation
        self.assertIsNone(ok("http://localhost:1/page", "fuzz page", agent_op=True, via_web=True))
        self.assertIn("payload ran", ok("http://localhost:1/x", model.CANARY, agent_op=False, via_web=False))
        self.assertIn("javascript", ok("javascript:alert(1)", "", agent_op=False, via_web=False))
        self.assertIn("data", ok("data:text/html,x", "", agent_op=False, via_web=False))
        self.assertIn("agent policy", ok("chrome://settings/", "Settings", agent_op=True, via_web=False))
        self.assertIsNone(ok("chrome://settings/", "Settings", agent_op=False, via_web=False))
        self.assertIn("web page", ok("file:///etc/hosts", "hosts", agent_op=False, via_web=True))
        self.assertIsNone(ok("file:///etc/hosts", "hosts", agent_op=False, via_web=False))

    def test_download_path(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(model.download_violation({"destination": os.path.join(folder, "fuzz.bin")}, folder))
            self.assertIn("outside", model.download_violation({"destination": os.path.join(folder, "..", "x.bin")}, folder))
            self.assertIn("unsafe", model.download_violation({"destination": os.path.join(folder, ".hidden")}, folder))
            self.assertIn("unsafe", model.download_violation({"destination": os.path.join(folder, "a‮gnp.exe")}, folder))
            self.assertIsNone(model.download_violation({}, folder))

    def test_stall_signature_drops_addresses_and_offsets(self):
        a = {"frames": ["CmuxNextApp 0x1000a3f0 + 1234 cmux.Foo.bar()", "AppKit 0x1 -[NSView display]"]}
        b = {"frames": ["CmuxNextApp 0x2000beef +0x4d2 cmux.Foo.bar()", "AppKit 0x2 -[NSView display]"]}
        self.assertEqual(model.stall_signature(a), model.stall_signature(b))
        self.assertNotIn("0x", model.stall_signature(b))

    def test_touches_external(self):
        self.assertTrue(model.touches_external("mailto:x@example.test"))
        self.assertTrue(model.touches_external("cmux://history"))
        self.assertTrue(model.touches_external("{origin}/redirect?n=1&to=mailto%3Afuzz%40example.test"))
        self.assertFalse(model.touches_external("{origin}/redirect?n=1&to=chrome%3A%2F%2Fsettings"))
        self.assertFalse(model.touches_external("https://example.com/"))

    def test_tab_count(self):
        self.assertIsNone(model.tab_count_violation(4, 4))
        self.assertIsNone(model.tab_count_violation(4, 5))
        self.assertIn("1 Chromium tab", model.tab_count_violation(4, 3))


class ShrinkTests(unittest.TestCase):
    def test_ddmin_finds_the_two_ops_that_fail_together(self):
        ops = [{"op": "open", "i": 0}] + [{"op": "navigate", "i": i} for i in range(1, 60)]
        fails = lambda c: {17, 42} <= {op["i"] for op in c}  # noqa: E731
        shrunk, calls = model.ddmin(ops, fails, budget=500)
        self.assertEqual([op["i"] for op in shrunk], [0, 17, 42])
        self.assertLess(calls, 500)

    def test_ddmin_keeps_the_first_op_and_honours_the_budget(self):
        ops = [{"op": "open", "i": i} for i in range(30)]
        shrunk, calls = model.ddmin(ops, lambda c: True, budget=3)
        self.assertEqual(shrunk[0]["i"], 0)
        self.assertLessEqual(calls, 3)


class VerdictTests(unittest.TestCase):
    def verdict(self, log):
        out = subprocess.run([sys.executable, os.path.join(HERE, "verdict.py")], input=log, capture_output=True, text=True)
        return out.stdout.strip()

    def test_reads_only_the_oracles_own_line(self):
        self.assertEqual(self.verdict("x\nBROWSER-FUZZ-VERDICT PASS seeds 3, ops 450\n"), "PASS seeds 3, ops 450")
        self.assertTrue(self.verdict("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) (stall)\n").startswith("FAIL 1 finding"))
        self.assertTrue(self.verdict("done\nexit 0\n").startswith("NOVERDICT"))
        self.assertTrue(self.verdict("BROWSER-FUZZ-VERDICT NOVERDICT no op ran\n").startswith("NOVERDICT"))
        # The last verdict line counts (a replay before the run must not mask it).
        self.assertTrue(self.verdict("BROWSER-FUZZ-VERDICT PASS a\nBROWSER-FUZZ-VERDICT FAIL b\n").startswith("FAIL"))


class LocalSiteTests(unittest.TestCase):
    """The fuzz's own pages (browser_fuzz.LocalSite), over real HTTP on 127.0.0.1."""

    @classmethod
    def setUpClass(cls):
        import browser_fuzz
        cls.site = browser_fuzz.LocalSite()

    @classmethod
    def tearDownClass(cls):
        cls.site.server.shutdown()
        cls.site.server.server_close()

    def get(self, path):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.site.port, timeout=10)
        conn.request("GET", path)
        try:
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_redirect_chain_counts_down_to_its_target(self):
        status, headers, _ = self.get("/redirect?n=3&to=" + model.urllib.parse.quote("/page?id=9", safe=""))
        self.assertEqual(status, 302)
        self.assertTrue(headers["Location"].startswith("/redirect?n=2&to="))
        status, headers, _ = self.get("/redirect?n=1&to=" + model.urllib.parse.quote("javascript:x", safe=""))
        self.assertEqual((status, headers["Location"]), (302, "javascript:x"))

    def test_download_names_stay_in_one_header_line(self):
        name = "fz1-2-fuzz\r\nX-Injected: 1.bin"
        status, headers, body = self.get("/download?kb=2&name=" + model.urllib.parse.quote(name, safe=""))
        self.assertEqual(status, 200)
        self.assertNotIn("X-Injected", headers)
        self.assertIn("attachment;", headers["Content-Disposition"])
        self.assertEqual(len(body), 2048)

    def test_meta_refresh_keeps_its_target_in_the_attribute(self):
        _, _, body = self.get("/meta?to=" + model.urllib.parse.quote('x"><script>1</script>', safe=""))
        self.assertNotIn(b"<script>", body)

    def test_every_corpus_path_answers(self):
        for path in model.LOCAL_PATHS:
            filled = path.format(n=1, ms=0, kb=1, k=2, code=404, unsafe="%2Fpage", name="fz-1-a.bin")
            status, _, _ = self.get(filled)
            self.assertIn(status, (200, 204, 302, 404), filled)


if __name__ == "__main__":
    unittest.main()
