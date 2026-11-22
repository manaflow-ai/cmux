#!/usr/bin/env python3
"""Tests of the browser fuzz's pure part (generator, oracles, shrinker). No app: runs anywhere.

  python3 scripts/fuzz/browser/test_fuzz_model.py
"""
import io
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

    def test_canary_is_judged_once_the_tab_leaves_script_nav(self):
        # A tab that showed /script-nav before and now shows another page: a payload title there is a finding.
        self.assertEqual(model.judged_title("http://localhost:1/page?id=3", model.CANARY), model.CANARY)
        self.assertIn("payload ran", model.committed_url_violation(
            "http://localhost:1/page?id=3", model.judged_title("http://localhost:1/page?id=3", model.CANARY),
            agent_op=True, via_web=False))
        # The page that runs its own script is not judged, also after a reload.
        self.assertEqual(model.judged_title("http://localhost:1/script-nav?to=javascript%3Ax", model.CANARY), "")
        # A query that only names /script-nav does not exempt a page.
        self.assertEqual(model.judged_title("http://localhost:1/page?from=/script-nav", model.CANARY), model.CANARY)

    def test_stale_title_while_the_next_page_loads_is_skipped_once(self):
        nav = ("http://localhost:1/script-nav?to=javascript%3Ax", model.CANARY)
        slow = "http://localhost:1/slow?ms=3000"
        # The navigation started (new URL) but the old page's title is still shown: not a finding.
        self.assertEqual(model.judged_title(slow, model.CANARY, previous=nav), "")
        # The next reading (previous is the slow URL now): the same title is judged.
        self.assertEqual(model.judged_title(slow, model.CANARY, previous=(slow, model.CANARY)), model.CANARY)
        # A new title on the new page is judged at once.
        self.assertEqual(model.judged_title(slow, "fuzz slow", previous=nav), "fuzz slow")
        # No earlier reading on /script-nav: judged.
        self.assertEqual(model.judged_title(slow, model.CANARY, previous=("http://localhost:1/page", "x")), model.CANARY)

    def test_url_path_never_raises_on_the_malformed_corpus(self):
        for url in model._payloads()["malformed"] + model._payloads()["huge"] + ["http://[zz::]/script-nav", "http://[::1"]:
            model.url_path(url)
            model.judged_title(url, model.CANARY, previous=(url, model.CANARY))
        self.assertEqual(model.url_path("http://[zz::]/script-nav?x=1"), "/script-nav")
        self.assertEqual(model.url_path("http://x.test"), "/")
        self.assertEqual(model.url_path("about:blank"), "blank")

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
        bare = {"frames": ["7ff81a2b3c4d cmux.Foo.bar()"]}
        other = {"frames": ["7ff8000b0c0d cmux.Foo.bar()"]}
        self.assertEqual(model.stall_signature(bare), model.stall_signature(other))

    def test_touches_external(self):
        self.assertTrue(model.touches_external("mailto:x@example.test"))
        self.assertTrue(model.touches_external("cmux://history"))
        self.assertTrue(model.touches_external("ftp://127.0.0.1/"))
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


class HangTests(unittest.TestCase):
    """Job 78618b4ec57bde51c8195e4a (cmux24, seed 368488418): the driver printed nothing after 'seed ... (150 ops)' for
    45 min and the controller stopped it as hung. A slow op and a hung op must both name themselves."""

    def test_op_watch_names_the_op_that_runs_past_its_deadline(self):
        now = [100.0]
        watch = model.OpWatch(limit_s=300, clock=lambda: now[0])
        self.assertIsNone(watch.overdue())
        watch.start(seed=368488418, index=7, op={"op": "open", "url": "http://x/big?kb=64"}, label="seed 368488418")
        now[0] += 299
        self.assertIsNone(watch.overdue())
        now[0] += 2
        hung = watch.overdue()
        self.assertEqual((hung["seed"], hung["index"], hung["op"]["op"]), (368488418, 7, "open"))
        self.assertGreaterEqual(hung["elapsed_s"], 300)
        # Reported once, not on every tick.
        self.assertIsNone(watch.overdue())
        # A finished op is never overdue.
        watch.start(seed=1, index=8, op={"op": "back"}, label="seed 1")
        watch.done()
        now[0] += 1000
        self.assertIsNone(watch.overdue())

    def test_a_hang_is_a_finding_when_the_app_does_not_answer(self):
        op = {"op": "navigate", "url": "file:///etc/hosts"}
        line, finding = model.hang_verdict(368488418, 2, op, 301, app_alive=True, ping_answered=False, main_stall_ms=290000)
        self.assertTrue(finding)
        self.assertTrue(line.startswith("FAIL HANG at op 2 navigate"), line)
        self.assertIn("seed 368488418", line)
        line, finding = model.hang_verdict(5, 3, {"op": "back"}, 301, app_alive=False, ping_answered=False, main_stall_ms=None)
        self.assertTrue(finding)
        self.assertIn("app process ended", line)

    def test_a_hang_with_an_answering_app_is_the_harness(self):
        line, finding = model.hang_verdict(9, 4, {"op": "download"}, 301, app_alive=True, ping_answered=True, main_stall_ms=12)
        self.assertFalse(finding)
        self.assertTrue(line.startswith("NOVERDICT HANG at op 4 download"), line)
        self.assertIn("the harness", line)

    def test_the_verdict_reader_takes_a_hang_line(self):
        out = subprocess.run([sys.executable, os.path.join(HERE, "verdict.py")], capture_output=True, text=True,
                             input="browser-fuzz: seed 1 op 2/150 navigate\nBROWSER-FUZZ-VERDICT FAIL HANG at op 2 navigate (seed 1)\n")
        self.assertEqual(out.stdout.strip(), "FAIL HANG at op 2 navigate (seed 1)")


class HangPathTests(unittest.TestCase):
    """The driver's watchdog path end to end (its thread, the stacks, the verdict line, os._exit), with no app."""

    def test_a_stuck_op_ends_the_run_with_a_hang_line_that_names_it(self):
        script = (
            "import sys, threading, time; sys.path.insert(0, %r)\n"
            "import browser_fuzz as b, fuzz_model as m\n"
            "class O: op_deadline = 0.2; ops = 150; build_config = 'debug'\n"
            "b.WATCH_POLL_S = 0.05\n"
            "b.LIVE['watch'] = m.OpWatch(0.2)\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.LIVE['watch'].start(368488418, 3, {'op': 'back'}, 'seed 368488418')\n"
            "time.sleep(30)\n"
            "print('NOT REACHED')\n"
        ) % HERE
        out = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        self.assertNotIn("NOT REACHED", out.stdout)
        self.assertIn("browser-fuzz: HANG: seed 368488418 op 3 back", out.stdout)
        self.assertIn("HANG stack of thread", out.stdout)
        last = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-VERDICT ")][-1]
        self.assertTrue(last.startswith("BROWSER-FUZZ-VERDICT NOVERDICT HANG at op 3 back"), last)
        self.assertIn("harness", last)


class FinalVerdictTests(unittest.TestCase):
    """Review of #29662 (BLOCK at 2d9ab261d01): the HANG verdict was followed by the main thread's own verdict, and
    verdict.py reads the last line, so a hang read as PASS."""

    def run_driver(self, body, timeout=60):
        script = ("import sys, threading, time, types; sys.path.insert(0, %r)\n"
                  "import browser_fuzz as b, fuzz_model as m\n"
                  "class O: op_deadline = 0.2; ops = 150; build_config = 'debug'\n"
                  "b.WATCH_POLL_S = 0.05\n"
                  "b.LIVE['watch'] = m.OpWatch(0.2)\n" % HERE) + body
        return subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=timeout)

    def verdicts(self, out):
        return [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-VERDICT ")]

    def test_the_main_threads_verdict_never_follows_the_hang_verdict(self):
        # The watchdog's probe takes a while (the app is slow to answer); meanwhile the hung op returns and the main
        # thread reaches its own end-of-run verdict. The HANG verdict must be the only one, with its exit code.
        out = self.run_driver(
            "class S:\n"
            "    sock = '/nonexistent/cmux-fuzz.sock'\n"
            "    opts = types.SimpleNamespace(app='/nonexistent/cmux DEV fuzz.app')\n"
            "    def app_gone(self):\n"
            "        time.sleep(1.0)\n"
            "        return False\n"
            "b.LIVE['session'] = S()\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.LIVE['watch'].start(368488418, 2, {'op': 'navigate', 'url': 'file:///etc/hosts'}, 'seed 368488418')\n"
            "time.sleep(0.6)\n"
            "b.LIVE['watch'].done()\n"
            "sys.exit(b.final_verdict('PASS replay of x', 0))\n")
        lines = self.verdicts(out)
        self.assertEqual(len(lines), 1, out.stdout + out.stderr)
        self.assertTrue(lines[0].startswith("BROWSER-FUZZ-VERDICT FAIL HANG at op 2 navigate"), lines)
        self.assertEqual(out.returncode, 1)
        self.assertIn("BROWSER-FUZZ-FINDING ", out.stdout)

    def test_a_dead_control_socket_is_no_answer(self):
        import browser_fuzz
        self.assertEqual(browser_fuzz.answers("/nonexistent/cmux-fuzz.sock", "system.ping", 1)[0], False)

    def test_a_harness_hang_after_a_finding_keeps_the_finding(self):
        out = self.run_driver(
            "b.LIVE['findings'].append({'oracle': 'sad_tab', 'seed': 7})\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.LIVE['watch'].start(8, 3, {'op': 'back'}, 'seed 8')\n"
            "time.sleep(30)\n")
        lines = self.verdicts(out)
        self.assertEqual(len(lines), 1, out.stdout + out.stderr)
        self.assertTrue(lines[0].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before HANG at op 3 back"), lines)
        self.assertEqual(out.returncode, 1)

    def test_a_hang_during_a_shrink_prints_that_failure_unshrunk(self):
        out = self.run_driver(
            "b.LIVE['pending'] = {'oracle': 'lost_tab', 'seed': 9, 'ops': [{'op': 'open'}, {'op': 'close'}]}\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.LIVE['watch'].start(9, 1, {'op': 'close'}, 'shrink 9')\n"
            "time.sleep(30)\n")
        found = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-FINDING ")]
        self.assertEqual(len(found), 1, out.stdout + out.stderr)
        self.assertIn('"oracle": "lost_tab"', found[0])
        self.assertIn("unshrunk", found[0])
        self.assertTrue(self.verdicts(out)[-1].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before HANG"), out.stdout)


class EndPhaseTests(unittest.TestCase):
    """Jobs 78618b4ec57b (cmux24) and 580e82955ed0 (cmux18), seed 368488418: all 150 ops ran in 166 s, then the run
    printed nothing for 45 min. The op watchdog watched only ops; the end of a seed (a final probe of the app, its quit,
    the kill, the cleanup) had no deadline and no line."""

    def test_an_end_phase_hang_names_its_step(self):
        line, finding = model.hang_verdict(368488418, 150, {"op": "end", "step": "quit"}, 181,
                                           app_alive=True, ping_answered=False, main_stall_ms=5000.0)
        self.assertTrue(finding)
        self.assertTrue(line.startswith("FAIL HANG in end:quit after 181 s (seed 368488418)"), line)
        # The harness's own cleanup steps never blame the app (it is being ended on purpose).
        for step in ("kill", "cleanup"):
            line, finding = model.hang_verdict(368488418, 150, {"op": "end", "step": step}, 181,
                                               app_alive=False, ping_answered=False, main_stall_ms=None)
            self.assertFalse(finding, step)
            self.assertTrue(line.startswith(f"NOVERDICT HANG in end:{step} after 181 s (seed 368488418)"), line)
            self.assertIn("harness", line)

    def test_the_end_of_a_seed_is_watched_and_announced(self):
        # run_ops with a stand-in Session whose close never returns: the run must end with a HANG verdict that names
        # the end step, and print a line for each end step it reached.
        script = ("import sys, threading, time; sys.path.insert(0, %r)\n"
                  "import browser_fuzz as b, fuzz_model as m\n"
                  "class O: op_deadline = 5; end_deadline = 0.3; ops = 2; build_config = 'debug'; app = '/nonexistent/x.app'\n"
                  "b.WATCH_POLL_S = 0.05\n"
                  "b.LIVE['watch'] = m.OpWatch(5)\n"
                  "class S:\n"
                  "    sock = '/nonexistent/cmux-fuzz.sock'; pid = 0; counts = {}; notes = []; stalls = {}\n"
                  "    opts = O\n"
                  "    def __init__(self, *a): b.LIVE['session'] = self\n"
                  "    def settle_launch(self): pass\n"
                  "    def run_op(self, op, index): self.counts['ops'] = self.counts.get('ops', 0) + 1\n"
                  "    def end_probe(self): pass\n"
                  "    def quit_app(self): pass\n"
                  "    def kill_app(self): time.sleep(60)\n"
                  "    def cleanup(self): pass\n"
                  "    def app_gone(self): return False\n"
                  "b.Session = S\n"
                  "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
                  "b.run_ops(O, None, [{'op': 'back'}, {'op': 'back'}], 'fz', lambda line: None, 'seed 368488418', seed=368488418)\n"
                  "print('NOT REACHED')\n") % HERE
        out = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)
        self.assertNotIn("NOT REACHED", out.stdout, out.stdout + out.stderr)
        for step in ("probe", "quit", "kill"):
            self.assertIn(f"browser-fuzz: seed 368488418 end:{step}", out.stdout, out.stdout + out.stderr)
        verdicts = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-VERDICT ")]
        self.assertEqual(len(verdicts), 1, out.stdout + out.stderr)
        self.assertTrue(verdicts[0].startswith("BROWSER-FUZZ-VERDICT NOVERDICT HANG in end:kill"), verdicts)


class EndPhaseFindingTests(unittest.TestCase):
    """Review of #29662 (BLOCK at 28023dced16): an end-probe no_answer kept a 1-op repro, and a hang in an end step
    after a Failure lost that Failure."""

    STANDIN = ("import sys, threading, time; sys.path.insert(0, %r)\n"
               "import browser_fuzz as b, fuzz_model as m\n"
               "class O: op_deadline = 5; end_deadline = 0.3; ops = 3; build_config = 'debug'; app = '/nonexistent/x.app'\n"
               "b.WATCH_POLL_S = 0.05\n"
               "b.LIVE['watch'] = m.OpWatch(5)\n"
               "class S:\n"
               "    sock = '/nonexistent/cmux-fuzz.sock'; pid = 0; counts = {}; notes = []; stalls = {}\n"
               "    opts = O\n"
               "    def __init__(self, *a): b.LIVE['session'] = self\n"
               "    def settle_launch(self): pass\n"
               "    def end_probe(self): pass\n"
               "    def quit_app(self): pass\n"
               "    def kill_app(self): pass\n"
               "    def cleanup(self): pass\n"
               "    def app_gone(self): return False\n")

    def run_standin(self, body):
        script = (self.STANDIN % HERE) + body
        return subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)

    def test_an_end_probe_no_answer_keeps_every_op_that_ran(self):
        out = self.run_standin(
            "S.run_op = lambda self, op, index: None\n"
            "def probe(self): raise b.Failure('no_answer', 'system.ping gave no answer in 30 s', -2)\n"
            "S.end_probe = probe\n"
            "b.Session = S\n"
            "failure, counts, stalls = b.run_ops(O, None, [{'op': 'open'}, {'op': 'back'}, {'op': 'close'}], 'fz', lambda l: None,"
            " 'seed 5', seed=5)\n"
            "print('RESULT', failure.oracle, failure.op_index, failure.extra.get('phase'))\n")
        self.assertIn("RESULT no_answer 2 end:probe", out.stdout, out.stdout + out.stderr)

    def test_a_hang_in_an_end_step_after_a_failure_keeps_that_failure(self):
        out = self.run_standin(
            "def op(self, op, index):\n"
            "    raise b.Failure('app_crash', 'the app process 1 ended', index)\n"
            "S.run_op = op\n"
            "S.kill_app = lambda self: time.sleep(60)\n"
            "b.Session = S\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.run_ops(O, None, [{'op': 'open'}, {'op': 'back'}], 'fz', lambda l: None, 'seed 6', seed=6)\n"
            "print('NOT REACHED')\n")
        found = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-FINDING ")]
        self.assertEqual(len(found), 1, out.stdout + out.stderr)
        self.assertIn('"oracle": "app_crash"', found[0])
        verdicts = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-VERDICT ")]
        self.assertEqual(len(verdicts), 1, out.stdout + out.stderr)
        self.assertTrue(verdicts[0].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before HANG in end:kill"), verdicts)


class EndSlotTests(unittest.TestCase):
    """Re-review of #29662 (BLOCK at c88eca0b1f7): run_ops wrote the seed's failure into the shrink's pending slot.
    A failure already reported (report() returns early) stayed there and was printed again by a later hang, and a
    shrink replay's own failure overwrote the failure being shrunk."""

    def run_standin(self, body):
        script = (EndPhaseFindingTests.STANDIN % HERE) + body
        return subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)

    def lines(self, out, head):
        return [l for l in out.stdout.splitlines() if l.startswith(head)]

    def test_an_already_reported_failure_is_not_printed_again_by_a_later_hang(self):
        out = self.run_standin(
            "rec = {'target': 'browser', 'oracle': 'app_crash', 'detail': 'the app process 1 ended', 'extra': {}, 'seed': 1}\n"
            "b.LIVE['findings'].append(rec)\n"
            "b.LIVE['seen'].add(b.finding_key(rec))\n"
            "def crash(self, op, index): raise b.Failure('app_crash', 'the app process 1 ended', index)\n"
            "S.run_op = crash\n"
            "b.Session = S\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.run_ops(O, None, [{'op': 'open'}], 'fz', lambda l: None, 'seed 2', seed=2)\n"
            "S.run_op = lambda self, op, index: None\n"
            "S.kill_app = lambda self: time.sleep(60)\n"
            "b.run_ops(O, None, [{'op': 'open'}], 'fz', lambda l: None, 'seed 3', seed=3)\n"
            "print('NOT REACHED')\n")
        self.assertEqual(self.lines(out, "BROWSER-FUZZ-FINDING "), [], out.stdout + out.stderr)
        verdicts = self.lines(out, "BROWSER-FUZZ-VERDICT ")
        self.assertEqual(len(verdicts), 1, out.stdout + out.stderr)
        self.assertTrue(verdicts[0].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before HANG in end:kill"), verdicts)

    def test_a_shrink_replays_own_failure_does_not_replace_the_failure_being_shrunk(self):
        out = self.run_standin(
            "b.LIVE['pending'] = {'target': 'browser', 'oracle': 'app_crash', 'detail': 'the app process 1 ended',"
            " 'extra': {}, 'seed': 4, 'ops': [{'op': 'open'}]}\n"
            "def answerless(self, op, index): raise b.Failure('no_answer', 'system.ping gave no answer in 30 s', index)\n"
            "S.run_op = answerless\n"
            "S.kill_app = lambda self: time.sleep(60)\n"
            "b.Session = S\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.run_ops(O, None, [{'op': 'open'}], 'fz', lambda l: None, 'shrink 4', seed=4)\n"
            "print('NOT REACHED')\n")
        found = self.lines(out, "BROWSER-FUZZ-FINDING ")
        self.assertEqual(len(found), 1, out.stdout + out.stderr)
        self.assertIn('"oracle": "app_crash"', found[0])
        verdicts = self.lines(out, "BROWSER-FUZZ-VERDICT ")
        self.assertEqual(len(verdicts), 1, out.stdout + out.stderr)
        self.assertTrue(verdicts[0].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before HANG in end:kill"), verdicts)


class DownloadsFolderTests(unittest.TestCase):
    """Replay c980cdb0c1c9b0a8583f8628 (cmux24): the run hung 184 s in cleanup() -> glob.glob -> os.scandir of the
    account's real ~/Downloads (the app saves there: FileManager ignores the step's HOME), most likely a Files and
    Folders prompt nobody can answer in the fleet session. The same hang ended jobs 78618b4ec57b and 580e82955ed0.
    The harness must never list that folder; it deletes only the exact paths the app reported for its downloads."""

    def session(self, scratch, downloads):
        import browser_fuzz
        session = object.__new__(browser_fuzz.Session)
        session.scratch = scratch
        session.home = os.path.join(scratch, "home")
        session.notes = []
        session.download_paths = set()
        session.record_download({"destination": os.path.join(downloads, "fzA-1-x.bin")}, "fzA-1")
        session.record_download({"destination": os.path.join(downloads, "user-file.txt")}, "fzA-1")  # not ours
        return session

    def test_cleanup_never_lists_a_shared_folder_and_removes_only_recorded_downloads(self):
        import glob as glob_module
        from unittest import mock
        with tempfile.TemporaryDirectory() as downloads, tempfile.TemporaryDirectory() as root:
            scratch = os.path.join(root, "scratch")
            os.makedirs(os.path.join(scratch, "home"))
            for name in ("fzA-1-x.bin", "fzA-2-y.bin", "user-file.txt"):
                open(os.path.join(downloads, name), "w").close()
            session = self.session(scratch, downloads)
            real_scandir = os.scandir

            def scandir(path="."):
                # shutil.rmtree of the scratch walks it through directory file descriptors.
                if isinstance(path, int):
                    return real_scandir(path)
                if not os.path.abspath(os.fspath(path)).startswith(scratch):
                    raise AssertionError(f"listed a folder outside the run's scratch: {path}")
                return real_scandir(path)

            def refuse(*args, **kwargs):
                raise AssertionError(f"listed a folder: {args}")

            with mock.patch.object(os, "scandir", scandir), mock.patch.object(os, "listdir", refuse), \
                    mock.patch.object(glob_module, "glob", refuse), mock.patch.object(glob_module, "iglob", refuse):
                session.cleanup()
            self.assertEqual(sorted(os.listdir(downloads)), ["fzA-2-y.bin", "user-file.txt"])
            self.assertFalse(os.path.exists(scratch))

    def test_a_delete_that_blocks_does_not_hold_the_run(self):
        import time as time_module
        from unittest import mock
        import browser_fuzz
        with tempfile.TemporaryDirectory() as downloads, tempfile.TemporaryDirectory() as root:
            scratch = os.path.join(root, "scratch")
            os.makedirs(os.path.join(scratch, "home"))
            open(os.path.join(downloads, "fzA-1-x.bin"), "w").close()
            session = self.session(scratch, downloads)
            with mock.patch.object(browser_fuzz, "DOWNLOAD_DELETE_S", 0.2), \
                    mock.patch.object(os, "remove", lambda path: time_module.sleep(30)):
                started = time_module.monotonic()
                session.cleanup()
                self.assertLess(time_module.monotonic() - started, 5)
            self.assertTrue(any("did not finish" in note for note in session.notes), session.notes)

    def test_the_download_oracle_reads_no_file_system(self):
        from unittest import mock

        def refuse(*args, **kwargs):
            raise AssertionError(f"touched the file system: {args}")

        with mock.patch.object(os.path, "realpath", refuse):
            self.assertIsNone(model.download_violation({"destination": "/Users/x/Downloads/fz-1-a.bin"}, "/Users/x/Downloads"))
            self.assertIn("outside", model.download_violation({"destination": "/Users/x/Downloads/../fz-1-a.bin"},
                                                             "/Users/x/Downloads"))


class DownloadCleanupNoteTests(unittest.TestCase):
    """Review of #29769: the 'left in place' note was added after run_ops copied the notes, so nobody saw it; and a
    token such as fz5-12 also matched fz5-123456-... ."""

    def test_a_blocked_delete_is_printed(self):
        import time as time_module
        from unittest import mock
        import browser_fuzz
        with tempfile.TemporaryDirectory() as downloads, tempfile.TemporaryDirectory() as root:
            scratch = os.path.join(root, "scratch")
            os.makedirs(os.path.join(scratch, "home"))
            session = object.__new__(browser_fuzz.Session)
            session.scratch, session.home, session.notes, session.download_paths = scratch, os.path.join(scratch, "home"), [], set()
            session.record_download({"destination": os.path.join(downloads, "fzA-1-x.bin")}, "fzA-1")
            out = io.StringIO()
            with mock.patch.object(browser_fuzz, "DOWNLOAD_DELETE_S", 0.2), \
                    mock.patch.object(os, "remove", lambda path: time_module.sleep(30)), mock.patch("sys.stdout", out):
                session.cleanup()
            self.assertIn("did not finish", out.getvalue())
            self.assertIn("fzA-1-x.bin", out.getvalue())

    def test_a_token_matches_only_its_own_downloads(self):
        import browser_fuzz
        session = object.__new__(browser_fuzz.Session)
        session.download_paths = set()
        session.record_download({"destination": "/Users/x/Downloads/fz5-123456-a.bin"}, "fz5-12")
        session.record_download({"destination": "/Users/x/Downloads/fz5-12-a.bin"}, "fz5-12")
        self.assertEqual(session.download_paths, {"/Users/x/Downloads/fz5-12-a.bin"})


class ReviewGapTests(unittest.TestCase):
    """Non-blocking findings of the #29662 and #29769 reviews: a failure that waits for report() must never be lost by
    a hang or a stop, and a download op must read its own row."""

    def run_standin(self, body):
        script = (EndPhaseFindingTests.STANDIN % HERE) + body
        return subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=60)

    def found(self, out):
        return [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-FINDING ")]

    def test_a_download_op_reads_its_own_row(self):
        rows = [{"filename": "fz5-12-a.bin", "status": "finished"}, {"filename": "fz5-123456-b.bin", "status": "finished"}]
        self.assertEqual(model.download_row(rows, "fz5-12")["filename"], "fz5-12-a.bin")
        self.assertEqual(model.download_row(rows, "fz5-123456")["filename"], "fz5-123456-b.bin")
        self.assertIsNone(model.download_row(rows, "fz5-1"))
        # The app may report only the destination (a sanitized or suffixed name keeps the token at its start).
        self.assertEqual(model.download_row([{"destination": "/d/fz5-12-x (1).bin"}], "fz5-12")["destination"], "/d/fz5-12-x (1).bin")
        # Review of #29818 (BLOCK at 34f8507c00c): a name the app did not clean is the case the download_path oracle
        # exists for, so its row must be found too.
        for escape in ("fz5-12-../../fuzz-escape.bin", "fz5-12-/etc/fuzz-abs.bin"):
            self.assertEqual(model.download_row([{"filename": escape}], "fz5-12")["filename"], escape)
        self.assertEqual(model.download_row([{"destination": "/Users/x/fz5-12-../fuzz-escape.bin"}], "fz5-12")["destination"],
                         "/Users/x/fz5-12-../fuzz-escape.bin")

    def test_a_hang_during_a_shrink_keeps_the_seeds_waiting_stalls(self):
        out = self.run_standin(
            "b.LIVE['pending'] = {'target': 'browser', 'oracle': 'app_crash', 'detail': 'the app process 1 ended', 'extra': {}, 'seed': 4}\n"
            "b.LIVE['seen'].add(b.finding_key(b.LIVE['pending']))\n"
            "b.LIVE['queued'] = [{'target': 'browser', 'oracle': 'stall', 'detail': 'a stall', 'extra': {'signature': 'cmux.A'}, 'seed': 4}]\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.LIVE['watch'].start(4, 1, {'op': 'back'}, 'shrink 4', limit_s=0.2)\n"
            "time.sleep(30)\n")
        oracles = sorted(json.loads(l.split(' ', 1)[1])["oracle"] for l in self.found(out))
        self.assertEqual(oracles, ["app_crash", "stall"], out.stdout + out.stderr)

    def test_a_hang_during_an_op_of_a_bench_seed_prints_its_stalls(self):
        out = self.run_standin(
            "O.build_config = 'bench'\n"
            "def op(self, op, index):\n"
            "    self.stalls['cmux.B'] = b.Failure('stall', 'a stall over 100 ms', index, {'signature': 'cmux.B'})\n"
            "    time.sleep(60)\n"
            "S.run_op = op\n"
            "b.Session = S\n"
            "O.op_deadline = 0.3\n"
            "b.LIVE['watch'] = m.OpWatch(0.3)\n"
            "threading.Thread(target=b.watchdog, args=(O,), daemon=True).start()\n"
            "b.run_ops(O, None, [{'op': 'open'}], 'fz', lambda l: None, 'seed 5', seed=5)\n")
        oracles = [json.loads(l.split(' ', 1)[1])["oracle"] for l in self.found(out)]
        self.assertIn("stall", oracles, out.stdout + out.stderr)

    def test_a_stop_right_after_the_end_steps_keeps_the_seeds_failure(self):
        out = self.run_standin(
            "def crash(self, op, index): raise b.Failure('app_crash', 'the app process 1 ended', index)\n"
            "S.run_op = crash\n"
            "b.Session = S\n"
            "b.run_ops(O, None, [{'op': 'open'}], 'fz', lambda l: None, 'seed 6', seed=6)\n"
            "b.stopped(15, None)\n")
        self.assertEqual([json.loads(l.split(' ', 1)[1])["oracle"] for l in self.found(out)], ["app_crash"],
                         out.stdout + out.stderr)
        verdicts = [l for l in out.stdout.splitlines() if l.startswith("BROWSER-FUZZ-VERDICT ")]
        self.assertTrue(verdicts and verdicts[0].startswith("BROWSER-FUZZ-VERDICT FAIL 1 finding(s) before the run was stopped"),
                        out.stdout + out.stderr)

    def test_queued_failures_are_reported_in_order_and_taken_once(self):
        import browser_fuzz
        taken = []
        browser_fuzz.LIVE["queued"] = [{"oracle": "app_crash", "detail": "x", "op_index": 2, "extra": {}},
                                       {"oracle": "stall", "detail": "y", "op_index": 3, "extra": {"signature": "s"}}]
        try:
            browser_fuzz.drain_queued(lambda failure, seed, ops, queued=None: taken.append((failure.oracle, failure.op_index)),
                                      7, [{"op": "open"}] * 4)
            self.assertEqual(taken, [("app_crash", 2), ("stall", 3)])
            self.assertEqual(browser_fuzz.LIVE["queued"], [])
        finally:
            browser_fuzz.LIVE["queued"] = []


class ReportOrderTests(unittest.TestCase):
    """Review of #29818: in report(), the key went into `seen` before the failure was the pending one (a stop there lost
    the queued record), and between findings.append and the clear of pending a stop printed and counted it twice."""

    def test_a_queued_failure_whose_key_is_seen_but_not_yet_pending_is_still_printed(self):
        import browser_fuzz as b
        record = {"target": "browser", "oracle": "app_crash", "detail": "x", "extra": {}, "seed": 1}
        saved = (list(b.LIVE["queued"]), set(b.LIVE["seen"]), b.LIVE["pending"], list(b.LIVE["findings"]))
        try:
            b.LIVE["queued"], b.LIVE["pending"], b.LIVE["findings"] = [record], None, []
            b.LIVE["seen"].clear()
            key = b.finding_key(record)
            # Before report() starts the shrink, the queued failure is printed (its key is not seen yet) ...
            self.assertEqual([r["oracle"] for r in b.unreported()], ["app_crash"])
            self.assertNotIn(key, b.LIVE["seen"])
            # ... and start_pending (the one place report() makes it pending) leaves it printed once, as pending,
            # with the key seen only after it is pending and out of the queue.
            b.start_pending(dict(record, ops=[]), key, record)
            self.assertEqual(b.LIVE["queued"], [])
            self.assertIn(key, b.LIVE["seen"])
            printed = b.unreported()
            self.assertEqual([r["oracle"] for r in printed], ["app_crash"])
            self.assertIn("shrink was cut short", printed[0]["note"])
        finally:
            b.LIVE["queued"], b.LIVE["pending"], b.LIVE["findings"] = saved[0], saved[2], saved[3]
            b.LIVE["seen"].clear(); b.LIVE["seen"].update(saved[1])

    def test_a_finding_already_appended_is_not_printed_again_as_pending(self):
        import browser_fuzz as b
        record = {"target": "browser", "oracle": "lost_tab", "detail": "y", "extra": {}, "seed": 2}
        saved = (b.LIVE["pending"], list(b.LIVE["findings"]))
        try:
            b.LIVE["pending"], b.LIVE["findings"] = dict(record), [dict(record)]
            self.assertEqual(b.unreported(), [])
        finally:
            b.LIVE["pending"], b.LIVE["findings"] = saved


class OmnibarTypingTests(unittest.TestCase):
    """Job 4509405d8be4, seed 368488420: debug.omnibar_type types one character at a time (AddressBarView.debugType), so
    a 200,015-character URL was 200,015 keystrokes in one main-actor call and the socket gave no answer in 30 s. A
    person pastes such a URL as one insert; the fuzz types at most OMNIBAR_TYPE_MAX characters."""

    def test_typed_omnibar_text_is_capped_and_the_random_stream_is_unchanged(self):
        for seed in range(200):
            ops = model.generate(seed, 150, "http://localhost:1", f"fz{seed:x}")
            for op in ops:
                if op["op"] == "omnibar":
                    self.assertLessEqual(len(op["url"]), model.OMNIBAR_TYPE_MAX, (seed, op["category"]))
        # The cap changes no other op: the stream of ops (names, slots, other URLs) is the one it was.
        capped = model.generate(368488420, 150, "{origin}", "fz15f6afe4")
        self.assertEqual(capped[60]["op"], "omnibar")
        self.assertEqual(capped[60]["category"], "huge")
        self.assertTrue(capped[60]["url"].startswith("http://x.test/#fff"))
        self.assertEqual(len(capped[60]["url"]), model.OMNIBAR_TYPE_MAX)
        huge_navigations = [op for seed in range(40) for op in model.generate(seed, 150)
                            if op["op"] in ("navigate", "open") and len(op.get("url") or "") > model.OMNIBAR_TYPE_MAX]
        self.assertTrue(huge_navigations, "huge URLs must still reach navigate and open")


class OmnibarCapStreamTests(unittest.TestCase):
    """Review of #29925: the cap must change only the typed URL of huge omnibar ops (whole stream compared), and stay
    above every other typed entry so no op changes meaning; and short enough that typing it in one main-actor call
    (debug.omnibar_type types per character) stays under the stall limit on a bench build."""

    def test_the_cap_changes_only_huge_typed_urls(self):
        from unittest import mock
        for seed in list(range(120)) + [368488420]:
            capped = model.generate(seed, 150, "http://localhost:1", f"fz{seed:x}")
            with mock.patch.object(model, "OMNIBAR_TYPE_MAX", 10 ** 9):
                uncapped = model.generate(seed, 150, "http://localhost:1", f"fz{seed:x}")
            self.assertEqual(len(capped), len(uncapped))
            for a, b in zip(capped, uncapped):
                if a == b:
                    continue
                self.assertEqual((a["op"], a["category"]), ("omnibar", "huge"), (seed, a, b))
                self.assertEqual({k: v for k, v in a.items() if k != "url"}, {k: v for k, v in b.items() if k != "url"})
                self.assertTrue(b["url"].startswith(a["url"]))

    def test_the_cap_is_above_every_non_huge_typed_entry_and_at_most_400(self):
        longest = max(len(op["url"]) for seed in range(300) for op in model.generate(seed, 150)
                      if op["op"] == "omnibar" and op["category"] != "huge")
        self.assertLess(longest, model.OMNIBAR_TYPE_MAX)
        self.assertLessEqual(model.OMNIBAR_TYPE_MAX, 400)


if __name__ == "__main__":
    unittest.main()
