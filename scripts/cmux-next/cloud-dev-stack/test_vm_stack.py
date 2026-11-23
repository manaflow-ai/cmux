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
        dev = v.render_api_config(self.cfg, "t1", "https://h:4799", with_platform=False)
        self.assertNotIn("env", dev)  # flat: wrangler dev runs it with no --env
        self.assertEqual(dev["name"], v.API_DEV_NAME)
        self.assertEqual(dev["main"], self.cfg["main"])  # inherited from the top level
        self.assertNotIn("ai", dev)
        self.assertNotIn("services", dev)
        self.assertNotIn("triggers", dev)
        self.assertFalse([b for b in dev["durable_objects"]["bindings"] if b.get("script_name")])
        self.assertEqual(dev["vars"]["CLOUD_API_ORIGIN"], "https://h:4799")
        self.assertEqual(dev["hyperdrive"], self.cfg["env"]["development"]["hyperdrive"])  # local strings come from run.sh
        self.assertIn("ai", self.cfg["env"]["development"])  # the input is not mutated

    def test_api_with_platform_keeps_platform_names(self):
        dev = v.render_api_config(self.cfg, "t1", "https://h:4799", with_platform=True)
        self.assertEqual([s["service"] for s in dev["services"]], [v.PLATFORM_DEV_NAME])
        self.assertTrue([b for b in dev["durable_objects"]["bindings"] if b.get("script_name") == v.PLATFORM_DEV_NAME])

    def test_platform_points_at_local_api(self):
        cfg = {"main": "src/index.ts", "env": {"development": {"vars": {"API_ORIGIN": "https://x", "CMUX_AUTH_JWKS_URL": "https://x/jwks", "OTHER": "1"},
                                       "services": [{"binding": "CMUX_API", "service": v.API_DEV_NAME}, {"binding": "R", "service": "cmux-remote-relay-development"}],
                                       "durable_objects": {"bindings": [{"name": "A", "class_name": "A"}, {"name": "B", "class_name": "B", "script_name": "elsewhere"}]},
                                       "routes": [{"pattern": "x"}], "triggers": {"crons": ["*"]}}}}
        dev = v.render_platform_config(cfg, "https://h:4799")
        self.assertEqual(dev["vars"]["API_ORIGIN"], "https://h:4799")
        self.assertEqual(dev["vars"]["CMUX_AUTH_JWKS_URL"], "https://h:4799/.well-known/jwks.json")
        self.assertEqual([s["binding"] for s in dev["services"]], ["CMUX_API"])
        self.assertEqual([b["name"] for b in dev["durable_objects"]["bindings"]], ["A"])
        self.assertNotIn("routes", dev)
        self.assertNotIn("triggers", dev)


class PortTests(unittest.TestCase):
    """A stack holds three consecutive ports: its API at the base, then the mobile Worker and the device hub."""

    def test_highest_free_triple_skips_classic_serve_listening_and_ours(self):
        top = v.PORT_MAX - 2  # the highest base whose three ports fit the range
        self.assertEqual(v.pick_port("t", None, set(), set(), {"TCP": {}, "Web": {}}, set()), top)
        # One port of the top triple taken on any account moves the whole stack below it.
        for taken, port in (({"taken_by_us": {v.PORT_MAX}}, v.PORT_MAX), ({"classic": {v.PORT_MAX - 1}}, v.PORT_MAX - 1),
                            ({"listening": {v.PORT_MAX - 2}}, v.PORT_MAX - 2), ({"serve": {"TCP": {str(v.PORT_MAX): {}}, "Web": {}}}, v.PORT_MAX)):
            args = {"taken_by_us": set(), "classic": set(), "serve": {"TCP": {}, "Web": {}}, "listening": set(), **taken}
            base = v.pick_port("t", None, **args)
            self.assertEqual(base, port - 3, taken)  # the highest triple that leaves the taken port out
            self.assertEqual(v.stack_ports(base), [base, base + 1, base + 2])
            self.assertNotIn(port, v.stack_ports(base))

    def test_previous_ports_kept_when_all_still_ours(self):
        own = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:4700"}}}
        serve = {"TCP": {"4700": {}, "4701": {}, "4702": {}}, "Web": {f"h:{p}": own for p in (4700, 4701, 4702)}}
        self.assertEqual(v.pick_port("t", 4700, set(), set(), serve, {4700, 4701, 4702}), 4700)

    def test_previous_ports_dropped_when_a_classic_stack_took_one(self):
        classic = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8478"}}}
        serve = {"TCP": {"4702": {}}, "Web": {"h:4702": classic}}
        self.assertNotEqual(v.pick_port("t", 4700, set(), set(), serve, set()), 4700)
        self.assertNotEqual(v.pick_port("t", 4700, set(), {4701}, {"TCP": {}, "Web": {}}, set()), 4700)

    def test_previous_ports_dropped_when_another_of_our_stacks_holds_one(self):
        self.assertNotEqual(v.pick_port("t", 4700, {4702}, set(), {"TCP": {}, "Web": {}}, set()), 4700)


class StackWorkersTests(unittest.TestCase):
    """All three Workers a dev build talks to run in the stack, behind the front Worker."""

    def test_mobile_worker_runs_its_dev_env_without_crons(self):
        cfg = v.load_jsonc(ROOT / "cmux-next-ios/backend/wrangler.jsonc")
        dev = v.render_mobile_config(cfg)
        self.assertEqual(dev["name"], "cmux-mobile-api-dev")
        self.assertEqual(dev["main"], "src/index.ts")
        self.assertEqual(dev["vars"]["ENVIRONMENT"], "dev")  # serves dev build spaces (index.ts DEV_SPACE_ENVIRONMENTS)
        self.assertNotIn("triggers", dev)
        self.assertEqual([h["binding"] for h in dev["hyperdrive"]], ["PS_MYSQL"])  # run.sh's Vitess string, as the API's
        self.assertNotIn("env", dev)

    def test_device_hub_signals_on_the_origin_each_request_came_by(self):
        cfg = v.load_wrangler_config(ROOT / "workers/device-hub/wrangler.toml")
        dev = v.render_hub_config(cfg)
        self.assertEqual(dev["name"], "cmux-device-hub-dev")
        # Empty: the hub derives signal URLs from the request, which the front rewrites to the tailnet or the
        # public hub origin it arrived on, so a phone off the tailnet gets URLs it can reach.
        self.assertEqual(dev["vars"]["PUBLIC_BASE_URL"], "")
        self.assertIn("454ecd03-1db2-4050-845e-4ce5b0cd9895", dev["vars"]["STACK_PROJECT_IDS"])  # dev builds' Stack project
        self.assertEqual(dev["compatibility_flags"], cfg["compatibility_flags"])
        self.assertEqual({b["class_name"] for b in dev["durable_objects"]["bindings"]}, {"UserDO", "SessionDO"})

    def test_an_environment_never_inherits_top_level_bindings(self):
        cfg = {"name": "w", "main": "m.ts", "vars": {"TOP": "1"}, "kv_namespaces": [{"binding": "K"}],
               "env": {"dev": {"vars": {"DEV": "1"}, "triggers": {"crons": ["*"]}}}}
        dev = v.flatten_env(cfg, "dev")
        self.assertEqual(dev, {"main": "m.ts", "vars": {"DEV": "1"}, "name": "w-dev"})
        with self.assertRaises(v.Refused):
            v.flatten_env(cfg, "development")

    def test_front_routes_each_port_to_its_worker_and_names_the_stacks_origins(self):
        origins = v.stack_origins("vm.tail.ts.net", 4700)
        self.assertEqual(origins, {"api": "https://vm.tail.ts.net:4700", "mobile": "https://vm.tail.ts.net:4701",
                                   "hub": "https://vm.tail.ts.net:4702"})
        routes = v.front_routes("VM.tail.ts.net", 4700, slot="s7")
        self.assertEqual(routes, {"vm.tail.ts.net:4700": ["api", "tailnet"], "vm.tail.ts.net:4701": ["mobile", "tailnet"],
                                  "vm.tail.ts.net:4702": ["hub", "tailnet"], "127.0.0.1:4700": ["api", "tailnet"],
                                  "api.s7.wdev.cmux.dev": ["api", "public"], "mobile.s7.wdev.cmux.dev": ["mobile", "public"],
                                  "hub.s7.wdev.cmux.dev": ["hub", "public"]})
        self.assertNotIn("api.s7.wdev.cmux.dev", v.front_routes("vm.tail.ts.net", 4700))  # no slot: tailnet only
        public = v.public_origins("s7")
        self.assertEqual(public, {"api": "https://api.s7.wdev.cmux.dev", "mobile": "https://mobile.s7.wdev.cmux.dev",
                                  "hub": "https://hub.s7.wdev.cmux.dev"})
        names = {"api": v.API_DEV_NAME, "mobile": "cmux-mobile-api-dev", "hub": "cmux-device-hub-dev"}
        cc = dict(v.FALLBACK_CLIENT_CONFIG)
        front = v.render_front_config(names, routes, {"tailnet": origins, "public": public}, cc)
        self.assertEqual({s["binding"]: s["service"] for s in front["services"]},
                         {"API": v.API_DEV_NAME, "MOBILE": "cmux-mobile-api-dev", "HUB": "cmux-device-hub-dev"})
        self.assertEqual(json.loads(front["vars"]["WDEV_ORIGINS"]), {"tailnet": origins, "public": public})
        self.assertEqual(json.loads(front["vars"]["WDEV_ROUTES"]), routes)
        # A public client is told the public origins: the origin family comes from the route.
        self.assertIn("JSON.parse(env.WDEV_ORIGINS)[family]", v.FRONT_JS)
        # The client-config the front answers is the API's with the stack's three origins over it.
        for key in ("api_origin", "mobile_origin", "device_hub_origin"):
            self.assertIn(f"config.{key} = origins.", v.FRONT_JS)
        self.assertIn('url.pathname === "/v1/client-config"', v.FRONT_JS)

    def test_entry_wrapper_reexports_classes_and_never_constants(self):
        source = ROOT.joinpath("cmux-next-ios/backend/src/index.ts").read_text()
        cfg = v.render_mobile_config(v.load_jsonc(ROOT / "cmux-next-ios/backend/wrangler.jsonc"))
        names = v.entry_exports(source, cfg)
        self.assertIn("TeamHub", names)
        self.assertIn("ConnectivityAlertDesk", names)
        self.assertIn("CloudAttentionPush", names)  # a WorkerEntrypoint declared in the main module
        self.assertNotIn("BUILD_SPACE_HEADER", names)  # workerd refuses a non-class export of an auxiliary Worker
        self.assertNotIn("spaceOf", names)
        api = v.entry_exports(ROOT.joinpath("backend/apps/api/src/index.ts").read_text(),
                              v.render_api_config(v.load_jsonc(ROOT / "backend/apps/api/wrangler.jsonc"), "t", "https://h:1", False))
        self.assertIn("UserDO", api)
        self.assertIn("AutomationRunWorkflow", api)
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "src").mkdir()
            (project / "src/index.ts").write_text("export const X_Y = 1\nexport class Hub {}\nexport default {}\n")
            out = v.write_entry_wrapper(project, {"main": "src/index.ts", "durable_objects": {"bindings": [{"class_name": "Hub"}]}})
            self.assertEqual(out["main"], "wdev-entry.generated.ts")
            wrapper = (project / "wdev-entry.generated.ts").read_text()
            self.assertIn('export { default } from "./src/index.ts"', wrapper)
            self.assertIn('export { Hub } from "./src/index.ts"', wrapper)
            self.assertNotIn("X_Y", wrapper)

    def test_run_sh_runs_every_config_with_no_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "secrets").mkdir()
            (d / "secrets/mysql.url").write_text("mysql://u:p@h/db")
            body = v.render_run_sh(d, "/bin", 4700, "abc", Path("/w/wrangler"), ["-c", "front.json", "-c", "api.json", "-c", "mobile.json"])
        self.assertNotIn("--env", body)
        self.assertIn("-c front.json -c api.json -c mobile.json", body)
        self.assertIn("CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_PS_MYSQL=", body)


def router_serve():
    """Serve as publish leaves it: every port of every registered stack goes to the router."""
    return {"TCP": {}, "Web": {f"vm.ts.net:{p}": {"Handlers": {"/": {"Proxy": v.ROUTER_TARGET}}}
                               for e in v.all_entries() for p in v.entry_ports(e)}}


class RegistryTests(unittest.TestCase):
    """reap_one and ports_held against a temporary registry; systemd and Serve are stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (v.BASE, v.CLASSIC_BASE, v.unit_active, v.stop_stack, v.systemctl, v.serve_config)
        v.BASE = v.CLASSIC_BASE = Path(self.tmp.name)
        v.serve_config = router_serve
        self.stopped = []
        self.units_stopped = []
        self.active = True
        v.unit_active = lambda tag: self.active
        v.stop_stack = lambda tag, keep_files, serve=True: self.stopped.append(tag) or ["stopped"]
        v.systemctl = lambda *a, check=True: self.units_stopped.append(a) or types.SimpleNamespace(returncode=0, stdout="")

    def tearDown(self):
        v.BASE, v.CLASSIC_BASE, v.unit_active, v.stop_stack, v.systemctl, v.serve_config = self.saved
        self.tmp.cleanup()

    def test_ports_held_counts_starting_and_failed_stacks(self):
        for tag, state, port in (("a", "starting", 4799), ("b", "failed", 4798), ("c", "reaped", 4797), ("d", "running", 4796)):
            v.write_entry({"tag": tag, "state": state, "port": port})
        self.assertEqual(v.ports_held("d"), {4799, 4798})

    def test_ports_held_counts_every_port_of_a_three_worker_stack(self):
        v.write_entry({"tag": "a", "state": "running", "port": 4790, "ports": [4790, 4791, 4792]})
        v.write_entry({"tag": "b", "state": "running", "port": 4780})  # an entry from before: one port
        self.assertEqual(v.ports_held("x"), {4790, 4791, 4792, 4780})

    def test_young_preparing_entry_is_left_alone(self):
        v.write_entry({"tag": "p", "state": "preparing", "last_up_at": 1000})
        self.assertIsNone(v.reap_one("p", 1000 + 600))
        self.assertEqual(self.stopped, [])

    def running(self, tag, **kw):
        v.write_entry({"tag": tag, "state": "running", "host": "vm.ts.net", "port": 4790, "ports": [4790, 4791, 4792],
                       "last_up_at": 1000, "started_at": 1000, "last_request_at": 1000, "idle_secs": 60, **kw})

    def test_an_idle_stack_stops_and_keeps_everything_for_its_wake(self):
        self.running("r")
        out = v.reap_one("r", 1000 + 61)
        self.assertEqual(out["action"], "stopped")
        e = v.read_entry("r")
        self.assertEqual(e["state"], "stopped")
        self.assertEqual(e["ports"], [4790, 4791, 4792])  # same origins when it wakes
        self.assertEqual(self.stopped, [], "files, data and Serve stay")
        self.assertIn(("stop", v.unit("r")), self.units_stopped)
        self.assertEqual(v.ports_held("x"), {4790, 4791, 4792})
        self.assertEqual(set(v.routes_table(v.all_entries())), {"vm.ts.net:4790", "vm.ts.net:4791", "vm.ts.net:4792"})

    def test_a_crashed_stack_stops_and_wakes_rather_than_being_released(self):
        self.running("c", idle_secs=7200)
        self.active = False
        self.assertEqual(v.reap_one("c", 1100)["action"], "stopped")
        self.assertEqual(self.stopped, [])

    def test_a_used_stack_outlives_the_old_12_h_cap(self):
        now = 10**6
        self.running("u", idle_secs=7200, last_up_at=now - 13 * 3600, started_at=now - 13 * 3600, last_request_at=now - 60)
        self.assertIsNone(v.reap_one("u", now), "13 h after its up, a stack in use keeps running")
        self.assertEqual(v.read_entry("u")["state"], "running")

    def test_retention_releases_a_stack_a_week_after_its_last_up(self):
        self.running("old")
        v.reap_one("old", 1000 + 61)  # stopped
        self.assertIsNone(v.reap_one("old", 1000 + v.RETAIN_SECS - 1))
        out = v.reap_one("old", 1000 + v.RETAIN_SECS + 1)
        self.assertEqual(out["action"], "released")
        self.assertEqual(v.read_entry("old")["state"], "reaped")  # the Mac's gc frees its credentials and branch
        self.assertEqual(self.stopped, ["old"])
        self.assertEqual(v.routes_table(v.all_entries()), {})

    def test_failed_entry_is_cleaned_once(self):
        v.write_entry({"tag": "f", "state": "failed", "port": 4799, "last_up_at": 1000})
        self.assertEqual(v.reap_one("f", 1000 + 3601)["action"], "cleaned failed stack")
        self.assertIsNone(v.reap_one("f", 1000 + 3901))
        self.assertIsNone(v.read_entry("f")["port"])
        self.assertEqual(self.stopped, ["f"])


class IdleTests(unittest.TestCase):
    def entry(self, **kw):
        return {"last_up_at": 1000, "started_at": 1000, "last_request_at": 1000, "idle_secs": 7200, **kw}

    def test_fresh_request_keeps_it(self):
        self.assertIsNone(v.idle_verdict(self.entry(last_request_at=8000), 9000, None, True))

    def test_idle_past_limit_stops(self):
        action, why = v.idle_verdict(self.entry(), 1000 + 7201, None, True)
        self.assertEqual(action, "stop")
        self.assertIn("idle", why)

    def test_heartbeat_counts_as_activity(self):
        self.assertIsNone(v.idle_verdict(self.entry(), 1000 + 7201, 1000 + 7000, True))

    def test_no_hard_cap_only_retention(self):
        self.assertIsNone(v.idle_verdict(self.entry(last_request_at=50000), 1000 + 43201, 50000, True))
        self.assertEqual(v.idle_verdict(self.entry(last_request_at=10**9), 1000 + v.RETAIN_SECS + 1, 10**9, True)[0], "release")

    def test_dead_unit_stops(self):
        action, why = v.idle_verdict(self.entry(), 1001, None, False)
        self.assertEqual(action, "stop")
        self.assertIn("not running", why)

    def test_request_line_pattern(self):
        self.assertTrue(v.REQUEST_LINE.search(b"[wrangler:info] GET /v1/health 200 OK (3ms)"))
        self.assertFalse(v.REQUEST_LINE.search(b"[wrangler:info] Ready on http://127.0.0.1:4799"))


class ReviewFixTests(unittest.TestCase):
    """The second review of #45835 (findings 1-9), against a temporary registry. systemd, Serve and
    the host's memory and disk are stubbed; nothing here touches a VM."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        names = ("BASE", "CLASSIC_BASE", "unit_active", "stop_stack", "mem_available_gib", "disk_free_gib", "serve_lock",
                 "registry_lock", "serve_config", "classic_ports", "systemctl", "unit_memory_mib")
        self.saved = {n: getattr(v, n) for n in names}
        v.unit_memory_mib = lambda tag: 3072
        v.BASE = v.CLASSIC_BASE = Path(self.tmp.name)
        self.stopped = []
        self.active = True
        v.unit_active = lambda tag: self.active
        v.stop_stack = lambda tag, keep_files, serve=True: self.stopped.append(tag) or ["stopped"]
        self.mem, self.disk = 60.0, 300.0
        v.mem_available_gib = lambda: self.mem
        v.disk_free_gib = lambda path=None: self.disk
        v.systemctl = lambda *a, check=True: types.SimpleNamespace(returncode=0, stdout="")

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
        self.assertFalse(v.publish([4797, 4798, 4799], 4797))  # one port of the stack is a classic stack's
        self.assertEqual(held, [])

    def test_reaper_pass_has_a_timeout(self):
        self.assertIn("TimeoutStartSec=", v.REAPER_SERVICE)

    # 3. a kept credential must outlive the 12 h cap this up starts
    def test_credential_kept_only_when_it_outlives_the_new_cap(self):
        now = time.time()
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        entry = lambda exp, mode="shared": {"db": {"pg": {"mode": mode, "expires_at": iso(exp)}}}
        self.assertFalse(v.cred_fresh(entry(now + 3 * 3600), "pg", "shared", True, now))  # >2 h left was enough before
        self.assertFalse(v.cred_fresh(entry(now + 14 * 3600), "pg", "shared", True, now), "a 14 h credential would expire under a stopped stack")
        self.assertFalse(v.cred_fresh(entry(now + v.RETAIN_SECS), "pg", "shared", True, now))
        self.assertTrue(v.cred_fresh(entry(now + 192 * 3600), "pg", "shared", True, now))
        self.assertFalse(v.cred_fresh(entry(now + 192 * 3600), "pg", "shared", False, now))  # file gone (released)
        self.assertFalse(v.cred_fresh(entry(now + 192 * 3600, "branch"), "pg", "shared", True, now))

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
        with mock_sleep(), self.assertRaises(v.Refused):  # the running one stops for room; still short, so refused
            v.admit("new")
        self.assertEqual(v.read_entry("c")["state"], "stopped")
        self.assertEqual(v.read_entry("a")["state"], "preparing", "an up in progress is never stopped")
        self.mem += 0.2
        v.admit("new")
        for i in range(v.MAX_STACKS - 2):
            v.write_entry({"tag": f"p{i}", "state": "preparing"})
        self.mem = 1000
        with self.assertRaises(v.Refused):  # MAX_STACKS starting, none running to stop
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

    def test_no_runtime_cap_and_a_router_unit(self):
        self.assertNotIn("RuntimeMaxSec", v.UNIT_TEMPLATE, "a stack in use is never killed at a fixed age")
        self.assertIn("router.mjs", v.ROUTER_SERVICE)
        self.assertIn("Restart=always", v.ROUTER_SERVICE)
        self.assertIn("CRED_TTL=192h", (ROOT / "scripts/cmux-next/cloud-dev-stack.sh").read_text())
        self.assertGreater(192 * 3600, v.RETAIN_SECS + v.CRED_MARGIN_SECS)


class LifetimeTests(unittest.TestCase):
    """Admission, LRU stop and release, and wake, against a temporary registry; systemd, Serve and the host's
    memory and disk are stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        names = ("BASE", "CLASSIC_BASE", "unit_active", "stop_stack", "systemctl", "mem_available_gib", "disk_free_gib",
                 "wait_healthy", "MAX_STACKS", "MAX_KEPT", "serve_config", "classic_ports", "unit_memory_mib", "dir_gib")
        self.saved = {n: getattr(v, n) for n in names}
        v.BASE = v.CLASSIC_BASE = Path(self.tmp.name)
        v.serve_config = router_serve
        v.classic_ports = lambda: set()
        v.unit_memory_mib = lambda tag: 3072  # what stopping one running stack frees (systemctl below adds it back)
        v.dir_gib = lambda path: 10.0  # what releasing one stopped stack frees
        self.mem, self.disk, self.active = 60.0, 300.0, {}
        self.released, self.calls = [], []
        v.mem_available_gib = lambda: self.mem
        v.disk_free_gib = lambda path=None: self.disk
        v.unit_active = lambda tag: self.active.get(tag, False)
        v.stop_stack = lambda tag, keep_files, serve=True: self.released.append(tag) or ["released"]

        def systemctl(*a, check=True):
            self.calls.append(a)
            if a[0] == "stop":
                self.active[a[1].split("@")[1].removesuffix(".service")] = False
                self.mem += 3
            if a[0] == "start":
                self.active[a[1].split("@")[1].removesuffix(".service")] = True
            return types.SimpleNamespace(returncode=0, stdout="")
        v.systemctl = systemctl
        self.sleeps = []
        self.saved_sleep = time.sleep

    def tearDown(self):
        for n, f in self.saved.items():
            setattr(v, n, f)
        self.tmp.cleanup()

    def stack(self, tag, state, used, **kw):
        d = v.stack_dir(tag)
        (d / "logs").mkdir(parents=True, exist_ok=True)
        (d / "run.sh").write_text("#!/bin/bash\n")
        v.write_entry({"tag": tag, "state": state, "host": "vm.ts.net", "port": kw.pop("port", 4700), "last_up_at": used,
                       "started_at": used, "last_request_at": used, **kw})
        self.active[tag] = state == "running"

    def test_a_full_vm_stops_the_least_recently_used_stack_instead_of_refusing(self):
        v.MAX_STACKS = 2
        self.stack("old", "running", 100)
        self.stack("new", "running", 900)
        with mock_sleep():
            made = v.admit("third", now=1000)
        self.assertEqual(made, ["stopped old"])
        self.assertEqual(v.read_entry("old")["state"], "stopped")
        self.assertEqual(v.read_entry("new")["state"], "running")

    def test_memory_short_stops_lru_stacks_until_it_fits_and_refuses_with_none_left(self):
        self.mem = v.MIN_MEM_GIB + v.PENDING_MEM_GIB - 4  # two stops (3 GiB each) make room
        for i, t in enumerate(("a", "b", "c")):
            self.stack(t, "running", 100 + i)
        with mock_sleep():
            self.assertEqual(v.admit("x", now=1000), ["stopped a", "stopped b"])
        self.mem = 0
        for t in ("a", "b", "c"):
            e = v.read_entry(t); e["state"] = "stopped"; v.write_entry(e)
        with mock_sleep(), self.assertRaises(v.Refused):
            v.admit("x", now=1000)

    def test_a_shortfall_stopping_every_stack_cannot_cover_stops_none(self):
        self.mem = v.MIN_MEM_GIB - 20  # short by more than the two running stacks hold (3 GiB each)
        self.stack("a", "running", 100)
        self.stack("b", "running", 200)
        with mock_sleep(), self.assertRaises(v.Refused) as r:
            v.admit("x", now=1000)
        self.assertIn("frees only", str(r.exception))
        self.assertEqual([v.read_entry(t)["state"] for t in ("a", "b")], ["running", "running"])
        self.disk, self.mem = v.MIN_DISK_GIB - 50, 60.0  # short by more than the one stopped stack holds (10 GiB)
        self.stack("s", "stopped", 50)
        with mock_sleep(), self.assertRaises(v.Refused):
            v.admit("x", now=1000)
        self.assertEqual(v.read_entry("s")["state"], "stopped")

    def test_disk_short_releases_lru_stopped_stacks(self):
        self.disk = v.MIN_DISK_GIB  # under floor + pending reservation
        self.stack("s1", "stopped", 100)
        self.stack("s2", "stopped", 200)
        calls = iter([v.MIN_DISK_GIB, v.MIN_DISK_GIB + 50])
        v.disk_free_gib = lambda path=None: next(calls)
        with mock_sleep():
            self.assertEqual(v.admit("x", now=1000), ["released s1"])
        self.assertEqual(v.read_entry("s1")["state"], "reaped")
        self.assertEqual(v.read_entry("s2")["state"], "stopped")

    def test_more_than_max_kept_stopped_stacks_releases_the_oldest(self):
        v.MAX_KEPT = 1
        self.stack("s1", "stopped", 100)
        self.stack("s2", "stopped", 200)
        out = v.trim_kept(1000)
        self.assertEqual([o["tag"] for o in out], ["s1"])
        self.assertEqual(v.read_entry("s2")["state"], "stopped")

    def test_wake_starts_the_same_unit_and_port_and_marks_it_running(self):
        self.stack("w", "stopped", 100, port=4710, ports=[4710, 4711, 4712], local_port=23810)
        # Asked as its tailnet authorities (vm.ts.net:4710-4712), on wrangler's local port.
        v.wait_healthy = lambda tag, port, host, timeout, local=None, **kw: (port == 4710 and local == 23810 and host == "vm.ts.net", "")
        out = v.cmd_wake(types.SimpleNamespace(tag="w", wait=5))
        self.assertTrue(out["woke"])
        e = v.read_entry("w")
        self.assertEqual((e["state"], e["port"], e["ports"]), ("running", 4710, [4710, 4711, 4712]))
        self.assertIn(("start", v.unit("w")), self.calls)
        self.assertFalse(v.cmd_wake(types.SimpleNamespace(tag="w", wait=5))["woke"], "a running stack returns at once")

    def test_a_failed_wake_stays_stopped_and_is_not_retried_at_once(self):
        self.stack("f", "stopped", 100)
        v.wait_healthy = lambda *a, **kw: (False, "mobile: connection refused")
        with self.assertRaises(v.Refused):
            v.cmd_wake(types.SimpleNamespace(tag="f", wait=1))
        e = v.read_entry("f")
        self.assertEqual(e["state"], "stopped")
        self.assertIn("connection refused", e["wake_error"])
        with self.assertRaises(v.Refused) as again:
            v.cmd_wake(types.SimpleNamespace(tag="f", wait=1))
        self.assertIn("retry in a minute", str(again.exception))

    def test_a_released_stack_does_not_wake(self):
        self.stack("gone", "reaped", 100)
        with self.assertRaises(v.Refused) as r:
            v.cmd_wake(types.SimpleNamespace(tag="gone", wait=1))
        self.assertIn("up --tag gone", str(r.exception))

    # A re-up whose start fails keeps a stopped stack's data and Serve
    def test_a_failed_reup_of_a_stopped_stack_keeps_its_data_ports_and_serve(self):
        self.stack("r", "stopped", 100, port=4710, ports=[4710, 4711, 4712], local_port=23800)
        data = v.stack_dir("r") / "state/v3/do/feed.sqlite"
        data.parent.mkdir(parents=True)
        data.write_text("rows")
        token = v.cmd_prepare(types.SimpleNamespace(tag="r"))["token"]
        e = v.read_entry("r")
        self.assertEqual(e["state"], "stopped", "a re-up leaves a stopped stack stopped (and wakeable) until start")
        self.assertIn("reup_at", e)
        e["state"] = "starting"  # start took it and restarted the unit, whose Workers never answered
        v.write_entry(e)
        self.assertEqual(v.settle_failed_start(v.read_entry("r")), "stopped")
        e = v.read_entry("r")
        self.assertEqual((e["state"], e["port"], e["ports"], e["local_port"]), ("stopped", 4710, [4710, 4711, 4712], 23800))
        self.assertEqual(self.released, [], "no stop_stack: its Serve entries and files stay")
        self.assertIn(("stop", v.unit("r")), self.calls)
        self.assertEqual(data.read_text(), "rows")
        self.assertNotIn("reup_at", e)
        self.assertEqual(v.routes_table(v.all_entries())["vm.ts.net:4711"], {"tag": "r", "port": 23800}, "still routed: a request wakes it")
        self.assertEqual(v.cmd_up_done(types.SimpleNamespace(tag="r", token=token, failed=True))["state"], "stopped")

    def test_a_failed_first_start_still_fails(self):
        self.stack("n", "preparing", 100)
        e = v.read_entry("n")
        e["state"] = "starting"
        self.assertEqual(v.settle_failed_start(e), "failed")
        self.assertEqual(self.released, ["n"])

    def test_up_done_after_a_reup_died_mid_start_keeps_the_stack(self):
        for tag, unit_up, want in (("down", False, "stopped"), ("up", True, "running")):
            self.stack(tag, "stopped", 100, port=4720 if tag == "down" else 4730)
            token = v.cmd_prepare(types.SimpleNamespace(tag=tag))["token"]
            e = v.read_entry(tag)
            e["state"] = "starting"  # start took the stack, then the Mac's ssh died before start settled it
            v.write_entry(e)
            self.active[tag] = unit_up
            self.assertEqual(v.cmd_up_done(types.SimpleNamespace(tag=tag, token=token, failed=True))["state"], want, tag)
            self.assertEqual(self.released, [])
        # A first up that died mid-start is not a re-up: it is not kept as a stopped stack.
        token = v.cmd_prepare(types.SimpleNamespace(tag="fresh2"))["token"]
        e = v.read_entry("fresh2")
        e["state"] = "starting"
        v.write_entry(e)
        self.assertEqual(v.cmd_up_done(types.SimpleNamespace(tag="fresh2", token=token, failed=True))["state"], "starting")

    # The router kills a wake after the wake's own wait; a live wake is waited for, a dead one restarted
    def test_a_wake_records_its_deadline_and_only_a_dead_one_is_stopped(self):
        self.stack("w", "stopped", 100)
        seen = {}

        def healthy(tag, port, host, timeout, local=None, **kw):
            seen.update(v.read_entry(tag))
            return True, ""
        v.wait_healthy = healthy
        before = int(time.time())
        v.cmd_wake(types.SimpleNamespace(tag="w", wait=150))
        self.assertGreaterEqual(seen["wake_deadline"], before + 150 + 90, "past the router's kill (its wait + 90 s)")
        self.assertFalse({"wake_deadline", "wake_token", "wake_started_at"} & set(v.read_entry("w")), "a settled wake clears its marks")
        now = int(time.time())
        e = v.read_entry("w")
        e.update({"state": "starting", "wake_started_at": now - 300, "wake_deadline": now + 60, "wake_token": "x"})
        v.write_entry(e)
        self.assertIsNone(v.reap_one("w", now), "a slow wake still inside its deadline is left alone")
        self.assertEqual(v.read_entry("w")["state"], "starting")
        self.assertIsNotNone(v.reap_one("w", now + 61))
        e = v.read_entry("w")
        self.assertEqual(e["state"], "stopped")
        self.assertFalse({"wake_deadline", "wake_token", "wake_started_at"} & set(e))

    def test_a_wake_that_lost_the_stack_to_an_up_leaves_its_unit_alone(self):
        self.stack("l", "stopped", 100)

        def taken_by_start(tag, port, host, timeout, local=None, **kw):
            e = v.read_entry(tag)  # cmd_start takes the stack and restarts its unit while the wake waits
            for k in v.WAKE_KEYS:
                e.pop(k, None)
            e["state"] = "starting"
            v.write_entry(e)
            return False, "its unit stopped"
        v.wait_healthy = taken_by_start
        with self.assertRaises(v.Refused):
            v.cmd_wake(types.SimpleNamespace(tag="l", wait=5))
        self.assertNotIn(("stop", v.unit("l")), self.calls, "the start that owns it now is not stopped under it")
        self.assertEqual(v.read_entry("l")["state"], "starting")

    # Review of 7e3a284: an up-done that cleared the re-up mark, a wake in progress, an up in progress
    def test_a_start_that_fails_after_the_macs_up_done_still_keeps_the_stack(self):
        self.stack("m", "stopped", 100, port=4750)
        token = v.cmd_prepare(types.SimpleNamespace(tag="m"))["token"]
        e = v.read_entry("m")
        e["state"] = "starting"  # start took it; then the Mac's ssh dropped and its up-done ran
        v.write_entry(e)
        self.active["m"] = True  # start is still booting the new code on the VM
        self.assertEqual(v.cmd_up_done(types.SimpleNamespace(tag="m", token=token, failed=True))["state"], "running")
        self.assertNotIn("reup_at", v.read_entry("m"))
        self.assertEqual(v.settle_failed_start(v.read_entry("m")), "stopped", "the start's own failure still keeps it")
        self.assertEqual(self.released, [])

    def test_up_done_leaves_a_wake_in_progress_alone(self):
        self.stack("k", "stopped", 100, port=4760)
        token = v.cmd_prepare(types.SimpleNamespace(tag="k"))["token"]
        e = v.read_entry("k")
        e.update({"state": "starting", "wake_token": "w1", "wake_started_at": int(time.time())})  # a request woke it
        v.write_entry(e)
        self.active["k"] = False
        v.cmd_up_done(types.SimpleNamespace(tag="k", token=token, failed=True))
        e = v.read_entry("k")
        self.assertEqual((e["state"], e["wake_token"]), ("starting", "w1"), "the wake settles its own entry")

    def test_a_stopped_stack_is_never_released_under_an_up(self):
        week = v.RETAIN_SECS
        self.stack("u", "stopped", 100, port=4770)
        v.cmd_prepare(types.SimpleNamespace(tag="u"))  # its re-up is syncing
        now = int(time.time())
        self.assertGreater(now - 100, week)  # its last up is past retention
        self.assertIsNone(v.reap_one("u", now + 60), "retention waits for the up")
        v.MAX_KEPT = 0
        self.assertEqual(v.trim_kept(now), [])
        self.disk = v.MIN_DISK_GIB - 1
        with mock_sleep(), self.assertRaises(v.Refused):
            v.admit("other", now=now)
        self.assertEqual(v.read_entry("u")["state"], "stopped")
        self.assertEqual(self.released, [])

    def test_a_stack_whose_last_start_failed_refuses_a_wake_at_once(self):
        self.stack("b", "stopped", 100, port=4780, served_at=100)
        e = v.read_entry("b")
        e["state"] = "starting"
        self.assertEqual(v.settle_failed_start(e), "stopped")
        v.wait_healthy = lambda *a, **kw: self.fail("no wake attempt for code whose start failed")
        with self.assertRaises(v.Refused) as r:
            v.cmd_wake(types.SimpleNamespace(tag="b", wait=150))
        self.assertIn("did not start", str(r.exception))
        self.assertNotIn(("start", v.unit("b")), self.calls)

    def test_a_wake_stops_waiting_when_the_build_failed(self):
        log = v.stack_dir("w") / "logs/wrangler.log"
        log.parent.mkdir(parents=True)
        log.write_text("old run: Build failed\n")
        self.active["w"] = True
        saved = v.probe
        v.probe = lambda port, authority: (False, "connection refused")
        try:
            with mock_sleep():
                ok, why = v.wait_healthy("w", 4700, "vm.ts.net", 0.3, local=23800, log=log, log_start=log.stat().st_size)
                self.assertEqual((ok, "build failed" in why), (False, False), "an earlier run's failure is not this wake's")
                with open(log, "a") as f:
                    f.write("✘ [ERROR] Build failed with 1 error\n")
                started = time.time()
                self.assertEqual(v.wait_healthy("w", 4700, "vm.ts.net", 150, local=23800, log=log, log_start=0), (False, "build failed"))
                self.assertLess(time.time() - started, 5)
        finally:
            v.probe = saved

    def test_an_up_that_starts_while_a_request_wakes_the_stack_keeps_it(self):
        self.stack("q", "stopped", 100, port=4790, served_at=100)
        e = v.read_entry("q")
        e.update({"state": "starting", "wake_token": "w1", "wake_started_at": int(time.time())})  # a request is waking it
        v.write_entry(e)
        token = v.cmd_prepare(types.SimpleNamespace(tag="q"))["token"]
        e = v.read_entry("q")
        self.assertEqual((e["state"], e.get("served_at")), ("starting", 100), "still the served stack, its wake still runs")
        e.pop("wake_token")
        e["state"] = "starting"  # start took it from the wake, then never answered
        v.write_entry(e)
        self.assertEqual(v.settle_failed_start(v.read_entry("q")), "stopped")
        self.assertEqual(v.cmd_up_done(types.SimpleNamespace(tag="q", token=token, failed=True))["state"], "stopped")
        self.assertEqual(self.released, [])

    def test_serve_points_every_stack_port_at_the_router(self):
        saved = (v.serve_lock, v.serve_config, v.classic_ports, subprocess.run)
        served = []
        try:
            v.serve_lock = lambda: contextlib.nullcontext()
            v.serve_config = lambda: {"TCP": {}, "Web": {"h:4700": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:4700"}}}}}
            v.classic_ports = lambda: set()
            v.subprocess.run = lambda cmd, **kw: served.append(cmd) or types.SimpleNamespace(returncode=0, stdout="", stderr="")
            self.assertTrue(v.publish([4700, 4701, 4702], 4700))
        finally:
            v.serve_lock, v.serve_config, v.classic_ports, v.subprocess.run = saved
        self.assertEqual([c[-1] for c in served], [v.ROUTER_TARGET] * 3)
        self.assertEqual([c[-2] for c in served], ["--https=4700", "--https=4701", "--https=4702"])


class PublicSlotTests(unittest.TestCase):
    """Public slots (cloud-dev-stack/gateway) against a temporary registry."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = v.BASE
        v.BASE = Path(self.tmp.name)

    def tearDown(self):
        v.BASE = self.saved
        self.tmp.cleanup()

    def put(self, slots, domain="wdev.cmux.dev"):
        stdin = sys.stdin
        sys.stdin = io.StringIO(json.dumps({"domain": domain, "slots": slots}))
        try:
            return v.cmd_put_public(None)
        finally:
            sys.stdin = stdin

    def test_a_stack_keeps_its_slot_and_a_released_ones_slot_is_free_again(self):
        self.put(["s2", "s1", "x9", "s1000"])
        self.assertEqual(v.public_slots(), ("wdev.cmux.dev", ["s1", "s2"]))
        v.write_entry({"tag": "a", "state": "running", "slot": "s1"})
        self.assertEqual(v.assign_slot("b", {"tag": "b"}), "s2")
        self.assertEqual(v.assign_slot("a", v.read_entry("a")), "s1", "kept across ups")
        v.write_entry({"tag": "b", "state": "stopped", "slot": "s2"})
        self.assertIsNone(v.assign_slot("c", {"tag": "c"}), "a stopped stack keeps its slot: none free")
        v.write_entry({"tag": "b", "state": "reaped", "slot": "s2"})
        self.assertEqual(v.assign_slot("c", {"tag": "c"}), "s2")

    def test_only_our_domain_and_routes_name_public_hosts(self):
        with self.assertRaises(v.Refused):
            self.put(["s1"], domain="attacker.example")
        self.put(["s1"])
        v.write_entry({"tag": "a", "state": "stopped", "host": "vm.ts.net", "port": 4700, "ports": [4700, 4701, 4702], "slot": "s1", "domain": "wdev.cmux.dev"})
        table = json.loads((v.BASE / "routes.json").read_text())
        self.assertEqual(table["mobile.s1.wdev.cmux.dev"], {"tag": "a", "port": 4700, "public": True})
        self.assertNotIn("public", table["vm.ts.net:4701"])
        v.write_entry({"tag": "a", "state": "reaped", "host": "vm.ts.net", "port": 4700, "slot": "s1"})
        self.assertEqual(json.loads((v.BASE / "routes.json").read_text()), {})

    def test_public_jwks_carry_public_halves_only(self):
        d = v.BASE / "stacks/t"
        (d / "secrets").mkdir(parents=True)
        priv = {"kty": "EC", "crv": "P-256", "x": "X1", "y": "Y1", "d": "SECRET1", "kid": "k1"}
        (d / "secrets/jwt.jwk").write_text(json.dumps(priv))
        (d / "secrets/hub.vars").write_text("SESSION_KEY='%s'\nTICKET_KEY='%s'\n" % (
            json.dumps({**priv, "x": "X2", "d": "SECRET2"}), json.dumps({**priv, "x": "X3", "d": "SECRET3"})))
        v.write_public_jwks(d)
        text = (d / "public-jwks.json").read_text()
        self.assertNotIn("SECRET", text)
        self.assertEqual([k["x"] for k in json.loads(text)["keys"]], ["X1", "X2", "X3"])


@contextlib.contextmanager
def mock_sleep():
    saved = v.time.sleep
    v.time.sleep = lambda s: None
    try:
        yield
    finally:
        v.time.sleep = saved


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
