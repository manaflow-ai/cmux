#!/usr/bin/env python3
"""Unit tests for vm_stack.py (no VM needed): python3 scripts/cmux-next/cloud-dev-stack/test_vm_stack.py"""
import contextlib
import io
import json
import re
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_stack as v  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


class JsoncTests(unittest.TestCase):
    def test_comments_and_trailing_commas(self):
        text = '{\n // a "comment"\n "a": "x // not a comment", /* b */ "b": [1, 2,],\n "c": "q\\"//",\n}'
        self.assertEqual(json.loads(v.strip_jsonc(text)), {"a": "x // not a comment", "b": [1, 2], "c": 'q"//'})

    def test_repo_api_config_parses(self):
        cfg = v.load_jsonc(ROOT / "backend/apps/api/wrangler.jsonc")
        self.assertIn("development", cfg["env"])


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.cfg = v.load_jsonc(ROOT / "backend/apps/api/wrangler.jsonc")

    def test_api_alone_drops_remote_only_bindings(self):
        out = v.render_api_config(self.cfg, "t1", "https://h:4799", with_platform=False)
        dev = out["env"]["development"]
        self.assertNotIn("ai", dev)
        self.assertNotIn("services", dev)
        self.assertNotIn("triggers", dev)
        self.assertFalse([b for b in dev["durable_objects"]["bindings"] if b.get("script_name")])
        self.assertEqual(dev["vars"]["CLOUD_API_ORIGIN"], "https://h:4799")
        self.assertEqual(dev["hyperdrive"], self.cfg["env"]["development"]["hyperdrive"])  # local strings come from run.sh
        self.assertIn("ai", self.cfg["env"]["development"])  # the input is not mutated

    def test_api_with_platform_keeps_platform_names(self):
        dev = v.render_api_config(self.cfg, "t1", "https://h:4799", with_platform=True)["env"]["development"]
        self.assertEqual([s["service"] for s in dev["services"]], [v.PLATFORM_DEV_NAME])
        self.assertTrue([b for b in dev["durable_objects"]["bindings"] if b.get("script_name") == v.PLATFORM_DEV_NAME])

    def test_platform_points_at_local_api(self):
        cfg = {"env": {"development": {"vars": {"API_ORIGIN": "https://x", "CMUX_AUTH_JWKS_URL": "https://x/jwks", "OTHER": "1"},
                                       "services": [{"binding": "CMUX_API", "service": v.API_DEV_NAME}, {"binding": "R", "service": "cmux-remote-relay-development"}],
                                       "durable_objects": {"bindings": [{"name": "A", "class_name": "A"}, {"name": "B", "class_name": "B", "script_name": "elsewhere"}]},
                                       "routes": [{"pattern": "x"}], "triggers": {"crons": ["*"]}}}}
        dev = v.render_platform_config(cfg, "https://h:4799")["env"]["development"]
        self.assertEqual(dev["vars"]["API_ORIGIN"], "https://h:4799")
        self.assertEqual(dev["vars"]["CMUX_AUTH_JWKS_URL"], "https://h:4799/.well-known/jwks.json")
        self.assertEqual([s["binding"] for s in dev["services"]], ["CMUX_API"])
        self.assertEqual([b["name"] for b in dev["durable_objects"]["bindings"]], ["A"])
        self.assertNotIn("routes", dev)
        self.assertNotIn("triggers", dev)


class PortTests(unittest.TestCase):
    def test_highest_free_port_skips_classic_serve_listening_and_ours(self):
        serve = {"TCP": {str(v.PORT_MAX): {}}, "Web": {}}
        port = v.pick_port("t", None, taken_by_us={v.PORT_MAX - 1}, classic={v.PORT_MAX - 2}, serve=serve, listening={v.PORT_MAX - 3})
        self.assertEqual(port, v.PORT_MAX - 4)

    def test_previous_port_kept_when_still_ours(self):
        serve = {"TCP": {"4700": {}}, "Web": {"h:4700": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:4700"}}}}}
        self.assertEqual(v.pick_port("t", 4700, set(), set(), serve, {4700}), 4700)

    def test_previous_port_dropped_when_a_classic_stack_took_it(self):
        serve = {"TCP": {"4700": {}}, "Web": {"h:4700": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8478"}}}}}
        self.assertNotEqual(v.pick_port("t", 4700, set(), set(), serve, set()), 4700)
        self.assertNotEqual(v.pick_port("t", 4700, set(), {4700}, {"TCP": {}, "Web": {}}, set()), 4700)


    def test_previous_port_dropped_when_another_of_our_stacks_holds_it(self):
        self.assertNotEqual(v.pick_port("t", 4700, {4700}, set(), {"TCP": {}, "Web": {}}, set()), 4700)


class RegistryTests(unittest.TestCase):
    """reap_one and ports_held against a temporary registry; systemd and Serve are stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (v.BASE, v.CLASSIC_BASE, v.unit_active, v.stop_stack)
        v.BASE = v.CLASSIC_BASE = Path(self.tmp.name)
        self.stopped = []
        v.unit_active = lambda tag: True
        v.stop_stack = lambda tag, keep_files, serve=True: self.stopped.append(tag) or ["stopped"]

    def tearDown(self):
        v.BASE, v.CLASSIC_BASE, v.unit_active, v.stop_stack = self.saved
        self.tmp.cleanup()

    def test_ports_held_counts_starting_and_failed_stacks(self):
        for tag, state, port in (("a", "starting", 4799), ("b", "failed", 4798), ("c", "reaped", 4797), ("d", "running", 4796)):
            v.write_entry({"tag": tag, "state": state, "port": port})
        self.assertEqual(v.ports_held("d"), {4799, 4798})

    def test_young_preparing_entry_is_left_alone(self):
        v.write_entry({"tag": "p", "state": "preparing", "last_up_at": 1000})
        self.assertIsNone(v.reap_one("p", 1000 + 600))
        self.assertEqual(self.stopped, [])

    def test_idle_running_entry_is_reaped_and_kept_for_gc(self):
        v.write_entry({"tag": "r", "state": "running", "port": 4799, "last_up_at": 1000, "started_at": 1000, "last_request_at": 1000, "idle_secs": 60, "max_secs": 43200})
        out = v.reap_one("r", 1000 + 61)
        self.assertEqual(out["action"], "reaped")
        self.assertEqual(v.read_entry("r")["state"], "reaped")
        self.assertEqual(self.stopped, ["r"])

    def test_failed_entry_is_cleaned_once(self):
        v.write_entry({"tag": "f", "state": "failed", "port": 4799, "last_up_at": 1000})
        self.assertEqual(v.reap_one("f", 1000 + 3601)["action"], "cleaned failed stack")
        self.assertIsNone(v.reap_one("f", 1000 + 3901))
        self.assertIsNone(v.read_entry("f")["port"])
        self.assertEqual(self.stopped, ["f"])


class IdleTests(unittest.TestCase):
    def entry(self, **kw):
        return {"last_up_at": 1000, "started_at": 1000, "last_request_at": 1000, "idle_secs": 7200, "max_secs": 43200, **kw}

    def test_fresh_request_keeps_it(self):
        self.assertIsNone(v.idle_verdict(self.entry(last_request_at=8000), 9000, None, True))

    def test_idle_past_limit_stops(self):
        self.assertIn("idle", v.idle_verdict(self.entry(), 1000 + 7201, None, True))

    def test_heartbeat_counts_as_activity(self):
        self.assertIsNone(v.idle_verdict(self.entry(), 1000 + 7201, 1000 + 7000, True))

    def test_hard_cap(self):
        self.assertIn("older", v.idle_verdict(self.entry(last_request_at=50000), 1000 + 43201, 50000, True))

    def test_dead_unit(self):
        self.assertIn("not running", v.idle_verdict(self.entry(), 1001, None, False))

    def test_request_line_pattern(self):
        self.assertTrue(v.REQUEST_LINE.search(b"[wrangler:info] GET /v1/health 200 OK (3ms)"))
        self.assertFalse(v.REQUEST_LINE.search(b"[wrangler:info] Ready on http://127.0.0.1:4799"))


class ReviewFixTests(unittest.TestCase):
    """The second review of #45835 (findings 1-9), against a temporary registry. systemd, Serve and
    the host's memory and disk are stubbed; nothing here touches a VM."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        names = ("BASE", "CLASSIC_BASE", "unit_active", "stop_stack", "mem_available_gib", "disk_free_gib", "serve_lock",
                 "registry_lock", "serve_config", "classic_ports")
        self.saved = {n: getattr(v, n) for n in names}
        v.BASE = v.CLASSIC_BASE = Path(self.tmp.name)
        self.stopped = []
        self.active = True
        v.unit_active = lambda tag: self.active
        v.stop_stack = lambda tag, keep_files, serve=True: self.stopped.append(tag) or ["stopped"]
        self.mem, self.disk = 60.0, 300.0
        v.mem_available_gib = lambda: self.mem
        v.disk_free_gib = lambda path=None: self.disk

    def tearDown(self):
        for n, f in self.saved.items():
            setattr(v, n, f)
        self.tmp.cleanup()

    def args(self, **kw):
        return types.SimpleNamespace(**kw)

    # 1. gc claims before it releases; an up of the same tag wins or waits
    def test_claim_refused_once_an_up_of_the_tag_got_there(self):
        v.write_entry({"tag": "t", "state": "reaped", "reaped_at": 1})
        v.cmd_prepare(self.args(tag="t"))  # the owner re-ups first
        with self.assertRaises(v.Refused):
            v.cmd_claim_release(self.args(tag="t"))
        self.assertEqual(v.read_entry("t")["state"], "preparing")

    def test_up_refuses_a_tag_a_gc_has_claimed(self):
        v.write_entry({"tag": "t", "state": "reaped", "reaped_at": 1})
        self.assertEqual(v.cmd_claim_release(self.args(tag="t"))["state"], "releasing")
        with self.assertRaises(v.Refused):
            v.cmd_prepare(self.args(tag="t"))
        with self.assertRaises(v.Refused):  # and a second gc does not claim it again
            v.cmd_claim_release(self.args(tag="t"))

    def test_a_lapsed_claim_is_claimable_and_running_never_is(self):
        now = int(time.time())
        self.assertTrue(v.claimable({"state": "releasing", "releasing_at": now - v.RELEASE_CLAIM_SECS - 1}, now))
        self.assertFalse(v.claimable({"state": "releasing", "releasing_at": now}, now))
        self.assertFalse(v.claimable({"state": "running"}, now))
        self.assertFalse(v.claimable({"state": "failed", "last_up_at": now - 60}, now))
        self.assertTrue(v.claimable({"state": "failed", "last_up_at": now - 3601}, now))

    # 2. registry, then Serve: publish holds only the Serve lock and changes nothing when refused
    def test_publish_refuses_a_taken_port_holding_only_the_serve_lock(self):
        held = []

        @contextlib.contextmanager
        def lock(name):
            held.append(name)
            try:
                yield
            finally:
                held.remove(name)

        v.serve_lock = lambda: lock("serve")
        v.registry_lock = lambda: (_ for _ in ()).throw(AssertionError("registry lock taken inside publish"))
        v.serve_config = lambda: {"TCP": {}, "Web": {}}
        v.classic_ports = lambda: {4799}
        self.assertFalse(v.publish(4799))
        self.assertEqual(held, [])

    def test_reaper_pass_has_a_timeout(self):
        self.assertIn("TimeoutStartSec=", v.REAPER_SERVICE)

    # 3. a kept credential must outlive the 12 h cap this up starts
    def test_credential_kept_only_when_it_outlives_the_new_cap(self):
        now = time.time()
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        entry = lambda exp, mode="shared": {"db": {"pg": {"mode": mode, "expires_at": iso(exp)}}}
        self.assertFalse(v.cred_fresh(entry(now + 3 * 3600), "pg", "shared", True, now))  # >2 h left was enough before
        self.assertFalse(v.cred_fresh(entry(now + v.MAX_SECS), "pg", "shared", True, now))
        self.assertTrue(v.cred_fresh(entry(now + 14 * 3600), "pg", "shared", True, now))
        self.assertFalse(v.cred_fresh(entry(now + 14 * 3600), "pg", "shared", False, now))  # file gone (reaped)
        self.assertFalse(v.cred_fresh(entry(now + 14 * 3600, "branch"), "pg", "shared", True, now))

    def test_one_up_of_a_tag_at_a_time_and_up_done_ends_it(self):
        first = v.cmd_prepare(self.args(tag="t"))
        with self.assertRaises(v.Refused):  # a second up of the same tag while the first runs
            v.cmd_prepare(self.args(tag="t"))
        self.assertFalse(v.cmd_up_done(self.args(tag="t", token="not-mine", failed=True))["cleared"])
        out = v.cmd_up_done(self.args(tag="t", token=first["token"], failed=True))
        self.assertEqual(out["state"], "failed")  # never started: gc may release it after an hour
        self.assertTrue(v.cmd_prepare(self.args(tag="t"))["token"])  # and the next up may start

    def test_failed_reup_leaves_a_running_stack_running(self):
        v.write_entry({"tag": "r", "state": "running", "port": 4799, "last_up_at": 1})
        token = v.cmd_prepare(self.args(tag="r"))["token"]
        self.assertEqual(v.cmd_up_done(self.args(tag="r", token=token, failed=True))["state"], "running")
        self.assertNotIn("reup_at", v.read_entry("r"))

    # 4. a re-up keeps a running stack running; a re-up that fails before start leaves it so
    def test_reup_keeps_running_and_the_reaper_waits(self):
        v.write_entry({"tag": "r", "state": "running", "port": 4799, "last_up_at": 1, "started_at": 1, "last_request_at": int(time.time())})
        self.assertEqual(v.cmd_prepare(self.args(tag="r"))["state"], "running")
        e = v.read_entry("r")
        self.assertEqual(e["state"], "running")
        self.assertIn("reup_at", e)
        self.active = False  # start is restarting the unit
        self.assertIsNone(v.reap_one("r", int(time.time()) + 60))
        self.assertEqual(self.stopped, [])

    # 5. admission counts stacks that are preparing or starting and reserves their memory
    def test_admission_counts_and_reserves_pending_stacks(self):
        v.write_entry({"tag": "a", "state": "preparing"})
        v.write_entry({"tag": "b", "state": "starting"})
        v.write_entry({"tag": "c", "state": "running"})
        self.mem = v.MIN_MEM_GIB + v.PENDING_MEM_GIB * 3 - 0.1  # floor + this + 2 pending, just short
        with self.assertRaises(v.Refused):
            v.admit("new")
        self.mem += 0.2
        v.admit("new")
        for i in range(v.MAX_STACKS - 3):
            v.write_entry({"tag": f"p{i}", "state": "preparing"})
        self.mem = 1000
        with self.assertRaises(v.Refused):
            v.admit("new")

    # 6. the stack user owns its log; one stack's error does not end a reaper pass
    def test_log_is_written_by_run_sh_not_systemd(self):
        self.assertNotIn("StandardOutput=append", v.UNIT_TEMPLATE)
        text = v.render_run_sh(Path("/s/t"), "/bin", 4799, "abc", Path("/w"), ["-c", "x"])
        self.assertLess(text.index('exec >>"/s/t/logs/wrangler.log" 2>&1'), text.index("exec /w dev"))

    def test_reaper_pass_survives_one_stack_error(self):
        v.write_entry({"tag": "bad", "state": "running"})
        v.write_entry({"tag": "good", "state": "running"})
        real = v.reap_one
        v.reap_one = lambda tag, now: (_ for _ in ()).throw(PermissionError("log")) if tag == "bad" else {"tag": tag, "action": "reaped"}
        try:
            out = v.cmd_reap(None)["reaped"]
        finally:
            v.reap_one = real
        self.assertEqual([(r["tag"], r["action"]) for r in out], [("bad", "error"), ("good", "reaped")])

    # 7. a log tail never carries a credential
    def test_redact_removes_stored_urls_passwords_and_userinfo(self):
        d = Path(self.tmp.name) / "stacks/t"
        (d / "secrets").mkdir(parents=True)
        (d / "secrets/mysql.url").write_text("mysql://user1:s3cr3t-pa%2Bss@aws.connect.psdb.cloud:3306/db")
        text = "ERR mysql://user1:s3cr3t-pa%2Bss@aws.connect.psdb.cloud:3306/db; pw s3cr3t-pa+ss; postgresql://u:other-pass@h/x"
        out = v.redact(text, d)
        for secret in ("s3cr3t-pa%2Bss", "s3cr3t-pa+ss", "other-pass"):
            self.assertNotIn(secret, out)

    # 8. the orphan sweep's ledger holds only branches this host made
    def test_put_cred_records_a_branch_in_the_host_ledger(self):
        raw = json.dumps({"id": "i1", "name": "n", "username": "u", "plain_text": "p" * 20, "access_host_url": "h", "expires_at": "2099-01-01T00:00:00Z"})
        stdin = sys.stdin
        try:
            sys.stdin = io.StringIO(raw)
            v.cmd_put_cred(self.args(tag="t", kind="mysql", db_name="cmux-next-vitess", branch="lane-wd-t", database="cmux-next-vitess", mode="branch"))
            sys.stdin = io.StringIO(raw.replace("i1", "i2"))
            v.cmd_put_cred(self.args(tag="u", kind="mysql", db_name="cmux-next-vitess", branch="development", database="cmux-next-vitess", mode="shared"))
        finally:
            sys.stdin = stdin
        self.assertEqual(list(v.ledger()), ["cmux-next-vitess/lane-wd-t"])
        v.ledger_drop(["cmux-next-vitess/lane-wd-t"])
        self.assertEqual(v.ledger(), {})

    # 9. pinned tools are checked; the unit is sandboxed
    def test_download_with_the_wrong_checksum_is_refused(self):
        dest = Path(self.tmp.name) / "tool.bin"
        real = v.subprocess.run
        v.subprocess.run = lambda cmd, **kw: dest.write_bytes(b"not the release")
        try:
            with self.assertRaises(v.Refused):
                v.fetch_verified("https://example.invalid/tool", v.NODE_SHA256, dest)
        finally:
            v.subprocess.run = real
        self.assertFalse(dest.exists())

    def test_unit_is_sandboxed(self):
        for line in ("ProtectSystem=strict", "ReadWritePaths={base}/stacks/%i", "PrivateTmp=yes", "NoNewPrivileges=yes"):
            self.assertIn(line, v.UNIT_TEMPLATE)


class MacScriptTests(unittest.TestCase):
    """release_db from cloud-dev-stack.sh, run by bash with stub pscale/ssh that read their stdin the way
    ssh does. Found live: an ssh inside the loop swallowed the remaining credentials, leaving them behind."""

    def test_release_db_handles_every_credential(self):
        script = (ROOT / "scripts/cmux-next/cloud-dev-stack.sh").read_text()
        fn = re.search(r"^release_db\(\) \{.*?^\}", script, re.S | re.M).group(0)
        entry = {"db": {"mysql": {"database": "v", "branch": "lane-wd-t", "mode": "branch", "cred_id": "1"},
                        "mysql-parent": {"database": "v", "branch": "development", "mode": "shared", "cred_id": "2"},
                        "pg": {"database": "p", "branch": "development", "mode": "shared", "cred_id": "3"}}}
        prog = "set -euo pipefail\nps() { cat >/dev/null; }\nvm() { cat >/dev/null; }\n" + fn + "\nrelease_db"
        out = subprocess.run(["bash", "-c", prog], input=json.dumps(entry), capture_output=True, text=True, check=True).stdout
        self.assertIn("deleted branch v/lane-wd-t", out)
        self.assertIn("deleted credential v/development 2", out)
        self.assertIn("deleted credential p/development 3", out)


if __name__ == "__main__":
    unittest.main()
