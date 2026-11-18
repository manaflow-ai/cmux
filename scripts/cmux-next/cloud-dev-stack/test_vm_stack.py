#!/usr/bin/env python3
"""Unit tests for vm_stack.py (no VM needed): python3 scripts/cmux-next/cloud-dev-stack/test_vm_stack.py"""
import json
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
