#!/usr/bin/env python3
"""Tests for facets_v0.py, driver_app_v0.py and the v0 parts of driver_daemon.py (p15-oracle-006).

Run: python3 -I scripts/cmux-next/oracle/facets_v0_test.py (stdlib unittest; selftest.py, task 019, runs it too).
The unit tests need nothing. The live tests capture the push base on a real daemon when CMUX_ORACLE_DAEMON_BINARY
names a cmux-tui built at the push base (or any later SHA): Linux or a fleet Mac only, never the person's Mac.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import case_values  # noqa: E402
import driver_app_v0 as app_driver  # noqa: E402
import facets_v0 as v0  # noqa: E402
import normalize  # noqa: E402

BINARY = os.environ.get("CMUX_ORACLE_DAEMON_BINARY", "")
EXAMPLE = v0.REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"
DAEMON_CASE = v0.REPO / "schemas" / "oracle" / "fixtures" / "case-example-daemon.json"
APP_CASE = v0.REPO / "schemas" / "oracle" / "fixtures" / "case-example-app.json"
WIRE = v0.REPO / "schemas" / "oracle" / "fixtures" / "wire"
WINDOW_KEY = "6F1C2A4E-0B7D-4C1F-9E8A-3D2B1C0A9F8E"


def push_base_replies() -> dict:
    """Replies of every v0 method in the shapes the push-base encoders write: snapshot.get is the example's
    topology (ControlTopology+JSON.swift), debug.focus follows DebugFocus.report, debug.desync
    AppControl+Input.swift desync(check: true), debug.tunables DebugTunables list, the daemon methods are the
    recorded wire fixtures."""
    example = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    tab, pane = "tab_000000000000000000000000000000e1", "pane_000000000000000000000000000000d1"
    focus = {
        "windows": [{
            "id": WINDOW_KEY, "workspace": "ws_000000000000000000000000000000b1", "is_key": True,
            "model": {"pane": pane, "target": "content", "resolved": "terminal", "resolved_pane": pane, "resolved_tab": tab,
                      "overlays": [], "expectation": None, "dragging": False, "browser_focus_mode": [],
                      "window_key": True, "sidebar_hidden": False, "generation": 12.0},
            "topology": [{"pane": pane, "selected": tab, "tabs": [f"{tab}:terminal"]}],
            "appkit": {"first_responder": "GhosttySurfaceView", "classified": f"content:{pane}", "child_window_page": None,
                       "devtools_tab": None},
            "layout_focused_pane": pane, "recent_events": ["focus pane"], "mismatches": [], "consistent": True,
        }],
        # WindowInvariants.problems at the push base: model keys (per-launch UUIDs) inside the text.
        "window_invariants": [f"window {WINDOW_KEY.lower()} is presented but none of its workspaces is mirrored",
                              "open window 0a1b2c3d-0000-4000-8000-00000000abcd has no controller"],
        "ghostty_focused_tabs": [tab], "key_window": "AppWindow", "app_active": True,
        "keyboard_given_back": None, "new_tab_key_log": [], "new_tab_key_holds": [],
        "context": {"terminal_focused": True, "browser_focused": False, "agent_focused": False, "palette_open": False},
        "consistent": True,
    }
    return {
        "snapshot.get": example["facets"]["topology"],
        "debug.focus": focus,
        "debug.desync": {"check": {"violations": [{"invariant": "W1", "window": WINDOW_KEY, "detail": "x"}],
                                   "unsettled": []}, "checks": 31.0, "count": 0.0, "directory": None, "reports": []},
        "debug.tunables": {"count": 2.0, "tunables": [
            {"key": "browserResize.layerHosting", "section": "browser", "label": "Layer hosting", "value": True,
             "default": False, "changed": True},
            {"key": "pages.debugSettings", "section": "pages", "label": "Debug Settings", "value": "web",
             "default": "native", "changed": True}]},
        "session.snapshot": json.loads((WIRE / "session.snapshot.json").read_text(encoding="utf-8"))["result"],
        "settings.snapshot": json.loads((WIRE / "settings.snapshot.json").read_text(encoding="utf-8"))["result"],
    }


def app_snapshot(replies: dict, facets=v0.PRODUCT_FACETS["app"] + ("layout", "crashes")) -> dict:
    built = v0.build_facets(facets, "app", replies, v0.load_v1())
    return v0.snapshot(case="journeys/v0", step=0, checkpoint="settled", product="app", sha="0" * 40, facets=built,
                       host={"os": "darwin", "arch": "arm64", "model": "Mac16,10"}, captured_at_ms=1)


class SchemaTests(unittest.TestCase):
    def test_v0_schema_passes_normalize_and_the_readme_contract(self):
        schema = v0.v0_schema()
        self.assertIsInstance(schema, normalize.Schema)

    def test_every_v0_field_names_a_push_base_method(self):
        doc = v0.derive_schema(v0.load_v1())

        def sources(node, at):
            if isinstance(node, dict):
                source = node.get("x-oracle-source")
                if isinstance(source, dict):
                    yield at, source
                for key, value in node.items():
                    if key != "x-oracle-source":
                        yield from sources(value, f"{at}/{key}")
            elif isinstance(node, list):
                for index, item in enumerate(node):
                    yield from sources(item, f"{at}/{index}")

        allowed = set(v0.METHODS) | {"oracle.runner"} | v0.STEP_RECEIPTS
        for name, facet in doc["properties"]["facets"]["properties"].items():
            for at, source in sources(facet, name):
                methods = {m.strip() for m in source["method"].split("+")}
                self.assertLessEqual(methods, allowed, f"{at} names {methods - allowed}")

    def test_the_v1_v0_tag_and_the_table_agree(self):
        facets = v0.load_v1()["properties"]["facets"]["properties"]
        for name, node in facets.items():
            tag = node["x-oracle-source"].get("v0")
            if tag is None:
                self.assertNotIn(name, v0.FIELDS, f"{name} has v0: null in snapshot-v1 but a v0 table")
            else:
                self.assertIn(name, v0.FIELDS, f"{name} names v0 {tag} but has no v0 table")
                self.assertLessEqual({m.strip() for m in tag.split("+")}, set(v0.facet_methods(name)))

    def test_a_facet_without_a_push_base_method_is_only_not_comparable(self):
        facet = v0.derive_schema(v0.load_v1())["properties"]["facets"]["properties"]["layout"]
        self.assertEqual(facet["oneOf"], [{"$ref": "#/definitions/notComparable"}])

    def test_a_table_field_the_v1_schema_lacks_is_refused(self):
        original = v0.FIELDS["focus"]
        v0.FIELDS["focus"] = {**original, "windows/*/bogus": v0.F("debug.focus", "/windows/*/bogus")}
        try:
            with self.assertRaises(v0.V0Error):
                v0.derive_schema(v0.load_v1())
        finally:
            v0.FIELDS["focus"] = original

    @unittest.skipUnless((v0.REPO / ".git").exists(), "no git checkout")
    def test_every_method_is_found_at_the_push_base(self):
        found = subprocess.run(["git", "-C", str(v0.REPO), "cat-file", "-e", f"{v0.PUSH_BASE}^{{commit}}"],
                               capture_output=True, check=False)
        if found.returncode != 0:
            self.skipTest("the push base is not in this clone")
        for name in v0.METHODS:
            self.assertTrue(v0.method_found(name, v0.PUSH_BASE), name)


class FacetTests(unittest.TestCase):
    def test_push_base_replies_give_a_valid_canonical_snapshot(self):
        snapshot = app_snapshot(push_base_replies())
        facets = snapshot["facets"]
        self.assertEqual(facets["focus"]["windows"][0]["id"], "win_000000000000000000000000000000a1")
        self.assertEqual(facets["invariants"]["violations"], ["W1"])
        self.assertEqual(facets["focus"]["windows"][0]["responder"], "content")
        self.assertEqual(facets["invariants"]["windowInvariants"], [
            "open window <uuid> has no controller", "window <window> is presented but none of its workspaces is mirrored"])
        self.assertEqual(facets["switches"], {"arms": {"browserResize.layerHosting": "true",
                                                       "pages.debugSettings": "web"}})
        self.assertEqual(facets["layout"]["status"], "not-comparable")
        self.assertNotIn("journalHead", facets["daemon"])
        self.assertTrue(facets["settings"]["effectiveSha256"].startswith("sha256:"))
        errors, _ = v0.v0_schema().validate(snapshot)
        self.assertEqual(errors, [])
        value = v0.canonicalize([snapshot])[0]
        self.assertNotIn("checks", value["facets"]["invariants"], "a volatile v1 field survives")

    def test_hash_is_stable_under_id_renaming_and_reply_order(self):
        first = v0.canonicalize([app_snapshot(push_base_replies())])[0]
        replies = push_base_replies()
        text = json.dumps(replies).replace("000000000000000000000000000000", "1234567890abcdef1234567890ab")
        new_key = "11111111-2222-3333-4444-555555555555"
        replies = json.loads(text.replace(WINDOW_KEY, new_key).replace(WINDOW_KEY.lower(), new_key))
        replies["debug.tunables"]["tunables"].reverse()
        second = v0.canonicalize([app_snapshot(replies)])[0]
        self.assertEqual(normalize.canonical_json(first["facets"]), normalize.canonical_json(second["facets"]))

    def test_two_launches_with_new_pane_ids_and_window_keys_hash_equal(self):
        """The push-base daemon has no oracle seed: every launch makes new pane ids and window model keys."""
        def launch(pane_hex: str, key: str, other: str) -> dict:
            text = json.dumps(push_base_replies())
            text = text.replace("pane_000000000000000000000000000000d1", "pane_" + pane_hex * 32)
            text = text.replace(WINDOW_KEY, key.upper()).replace(WINDOW_KEY.lower(), key)
            text = text.replace("0a1b2c3d-0000-4000-8000-00000000abcd", other)
            return v0.canonicalize([app_snapshot(json.loads(text))])[0]["facets"]

        first = launch("a", "11111111-2222-4333-8444-555555555555", "99999999-8888-4777-8666-555555555555")
        second = launch("b", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "12345678-1234-4123-8123-123456789abc")
        for facet in ("focus", "invariants"):
            self.assertEqual(normalize.canonical_json(first[facet]), normalize.canonical_json(second[facet]), facet)

    def test_problem_class_drops_every_id(self):
        line = "ws_" + "c" * 32 + " owned by win_" + "a" * 32 + " and 6F1C2A4E-0B7D-4C1F-9E8A-3D2B1C0A9F8E"
        self.assertEqual(v0.problem_class(line, []), "<workspace> owned by <window> and <uuid>")
        self.assertEqual(v0.problem_class("recency out of sync", ["k"]), "recency out of sync")

    def test_a_focus_window_missing_from_snapshot_get_is_refused(self):
        replies = push_base_replies()
        replies["debug.focus"]["windows"][0]["id"] = "OTHER"
        with self.assertRaises(v0.V0Error):
            app_snapshot(replies)

    def test_a_v1_field_in_a_v0_snapshot_is_refused(self):
        snapshot = app_snapshot(push_base_replies())
        snapshot["facets"]["daemon"]["journalHead"] = "9"
        errors, _ = v0.v0_schema().validate(snapshot)
        self.assertTrue(errors)

    def test_daemon_product_gives_only_the_daemon_facet(self):
        built = v0.build_facets(["daemon", "settings", "focus"], "daemon", push_base_replies(), v0.load_v1())
        self.assertIn("session", built["daemon"])
        self.assertEqual(built["settings"]["status"], "not-comparable")
        self.assertEqual(built["focus"]["status"], "not-comparable")
        self.assertEqual(v0.methods_for(["daemon", "focus"], "daemon"), ["session.snapshot", "settings.snapshot"])

    def test_terminal_extra_is_volatile_only_at_v0(self):
        doc = v0.derive_schema(v0.load_v1())
        session = doc["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]["session"]
        self.assertIn("x-oracle-volatile", session["properties"]["terminals"]["items"]["properties"]["extra"])
        v1 = v0.load_v1()["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]["session"]
        self.assertNotIn("x-oracle-volatile", v1["properties"]["terminals"]["items"]["properties"]["extra"])

    def test_compare_runs_names_the_first_differing_checkpoint(self):
        with tempfile.TemporaryDirectory() as root:
            dirs = []
            for name, sha in (("run-1", "a"), ("run-2", "b")):
                path = Path(root, name)
                path.mkdir()
                path.joinpath("checkpoints.jsonl").write_text(json.dumps(
                    {"case": "s/c", "index": 0, "step": "x", "checkpoint": "settled", "sha256": sha}) + "\n")
                dirs.append((path, {"cases": {"s/c": {"status": "Pass"}}}))
            result = v0.compare_runs(dirs)
            self.assertFalse(result["equal"])
            self.assertEqual(result["differences"][0]["case"], "s/c")
            same = v0.compare_runs([dirs[0], dirs[0]])
            self.assertTrue(same["equal"])


class FakeBench:
    """The app's control socket. `targets` is what action.describe says each action takes; `on_action` changes
    the replies when an action.run arrives; `after_reply` answers a `snapshot.get {after: <number>}`."""

    def __init__(self, replies: dict, refusals: dict = None, targets: dict = None, on_action=None, after_reply=None):
        self.replies = replies
        self.refusals = refusals or {}
        self.targets = targets or {}
        self.on_action = on_action
        self.after_reply = after_reply
        self.calls = []
        self.stopped = False

    def rpc(self, method, params=None, timeout=60):
        self.calls.append((method, params))
        if method in self.refusals:
            return {"error": self.refusals[method]}
        if method == "debug.daemon":
            return {"pid": 1}
        if method == "action.describe":
            return {"action": {"id": params["action"], "targets": self.targets.get(params["action"], [])}}
        if method == "action.run" and self.on_action:
            self.on_action(self.replies)
        if method in ("action.run", "debug.key"):
            return {"ok": True}
        if method == "snapshot.get" and isinstance((params or {}).get("after"), int) and self.after_reply is not None:
            return self.after_reply
        return copy.deepcopy(self.replies[method])

    def stop(self):
        self.stopped = True


class FakeDaemon:
    closed = False

    def __init__(self, replies):
        self.replies = replies

    def request(self, method, params, idempotency_key=None, timeout=None):
        return copy.deepcopy(self.replies[method])

    def close(self):
        self.closed = True


class AppDriverTests(unittest.TestCase):
    def session(self, bench):
        def launcher(tag, out_dir):
            return bench

        session = app_driver.AppSession({"facets": "v0", "tag": "t", "ref": "0" * 40}, launcher=launcher)
        return session

    def run_app_case(self, steps, bench):
        replies = bench.replies
        original = app_driver.App.daemon
        app_driver.App.daemon = lambda self, step: FakeDaemon(replies)
        try:
            with tempfile.TemporaryDirectory() as out:
                session = self.session(bench)
                session.session_ctx["out_dir"] = out
                return session.run_case({"id": "c", "suite": "journeys", "steps": steps},
                                        {"case_id": "journeys/c", "key": "1"})
        finally:
            app_driver.App.daemon = original

    def test_action_then_snapshot_records_v0_facets(self):
        bench = FakeBench(push_base_replies(), targets={"pane.split.right": ["pane"]})
        result = self.run_app_case([
            {"id": "split", "op": "action.run", "target": {"window": "main"}, "args": {"action": "pane.split.right"},
             "expect": {"outcome": "ok", "noReceiptReason": "the fake app"}},
            {"id": "shot", "op": "snapshot", "args": {"facets": ["focus", "layout"]}},
        ], bench)
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertTrue(bench.stopped)
        self.assertTrue(result["session_dirty"])
        self.assertEqual([c["step"] for c in result["checkpoints"]], ["split", "shot"])
        last = result["checkpoints"][-1]["snapshot"]
        self.assertEqual(sorted(last["facets"]), ["focus", "layout"])
        self.assertIn(("snapshot.get", {"after": "sync"}), bench.calls)
        run = [params for method, params in bench.calls if method == "action.run"][0]
        # The case names only the window; a pane action takes none of it and runs on the focused pane.
        self.assertEqual(run, {"action": "pane.split.right", "wait": True})

    def test_the_app_example_cases_action_and_key_steps_run_on_the_push_base_shapes(self):
        case = json.loads(APP_CASE.read_text(encoding="utf-8"))
        steps = [dict(s) for s in case["steps"] if s["id"] in ("split-right", "split-key", "open-page")]
        for step in steps:  # turn checkpoints and waitFor on app facets need debug.oracle.* (030, 031)
            step.pop("waitFor", None)
            step["checkpoint"] = ["settled"]
        bench = FakeBench(push_base_replies(), targets={"splitRight": ["pane", "tab"], "newBrowserWorkspace": []})
        result = self.run_app_case(steps, bench)
        self.assertEqual(result["status"], "Pass", result["message"])
        runs = [params for method, params in bench.calls if method == "action.run"]
        self.assertEqual(runs[0], {"action": "splitRight", "wait": True, "origin": "script",
                                   "target": "pane:pane_000000000000000000000000000000d1"})
        self.assertEqual(runs[1], {"action": "newBrowserWorkspace", "wait": True, "args": {"url": "$WEB/load.html"}})
        keys = [params for method, params in bench.calls if method == "debug.key"]
        self.assertEqual(keys, [{"key": "d", "modifiers": ["cmd"], "window": WINDOW_KEY}])

    def test_a_window_action_gets_the_main_window_and_a_person_entrypoint_is_refused(self):
        bench = FakeBench(push_base_replies(), targets={"window.close": ["window"]})
        self.run_app_case([{"id": "w", "op": "action.run", "target": {"window": "main"},
                            "args": {"action": "window.close"}, "expect": {"outcome": "ok"}}], bench)
        run = [params for method, params in bench.calls if method == "action.run"][0]
        self.assertEqual(run["target"], "window:win_000000000000000000000000000000a1")
        result = self.run_app_case([{"id": "k", "op": "action.run", "target": {"window": "main"},
                                     "args": {"action": "window.close", "entrypoint": "key"}}], FakeBench(push_base_replies()))
        self.assertEqual((result["status"], result["step"]), ("Crash", "k"))

    def test_an_unknown_fixture_handle_fails_the_step(self):
        result = self.run_app_case([{"id": "x", "op": "key", "target": {"window": "other"}, "args": {"keys": ["cmd+d"]},
                                     "expect": {"outcome": "ok"}}], FakeBench(push_base_replies()))
        self.assertEqual((result["status"], result["step"]), ("Failure", "x"))

    def test_wait_changed_compares_with_the_value_before_the_step(self):
        def split(replies):
            replies["snapshot.get"]["tab_count"] = 3

        bench = FakeBench(push_base_replies(), on_action=split)
        result = self.run_app_case([{"id": "s", "op": "action.run", "target": {"window": "main"},
                                     "args": {"action": "pane.split.right"}, "expect": {"outcome": "ok"},
                                     "waitFor": {"pointer": "/topology/tab_count", "predicate": "changed", "maxMs": 2000}}],
                                   bench)
        self.assertEqual(result["status"], "Pass", result["message"])
        order = [method for method, _ in bench.calls]
        self.assertLess(order.index("snapshot.get", 1), order.index("action.run"), "no baseline read before acting")

    def test_wait_without_a_change_times_out_within_its_bound(self):
        bench = FakeBench(push_base_replies(), after_reply={"error": "timed out", "unreachable": True})
        started = time.monotonic()
        result = self.run_app_case([{"id": "s", "op": "settle",
                                     "waitFor": {"pointer": "/topology/tab_count", "equals": 9, "maxMs": 50}}], bench)
        self.assertEqual((result["status"], result["step"]), ("Timeout", "s"))
        self.assertLess(time.monotonic() - started, 5)
        bounded = [params for method, params in bench.calls if method == "snapshot.get" and params.get("after") != "sync"]
        self.assertTrue(bounded and all(isinstance(p["after"], int) for p in bounded))

    def test_wait_on_an_app_local_facet_is_refused_with_its_task(self):
        result = self.run_app_case([{"id": "s", "op": "settle",
                                     "waitFor": {"pointer": "/focus/paletteOpen", "equals": True, "maxMs": 50}}],
                                   FakeBench(push_base_replies()))
        self.assertEqual((result["status"], result["step"]), ("Crash", "s"))
        self.assertIn("p15-oracle-031", result["message"])

    def test_a_typed_refusal_is_an_error_outcome(self):
        bench = FakeBench(push_base_replies(), refusals={"action.run": {"code": "not_found", "message": "no"}})
        result = self.run_app_case([
            {"id": "bad", "op": "action.run", "args": {"action": "nope"},
             "expect": {"outcome": "error", "error": "not_found"}}], bench)
        self.assertEqual(result["status"], "Pass", result["message"])

    def test_steps_of_other_drivers_crash_and_say_whose(self):
        result = self.run_app_case([{"id": "k", "op": "kill", "target": {"process": "app"}}], FakeBench(push_base_replies()))
        self.assertEqual((result["status"], result["step"]), ("Crash", "k"))
        self.assertIn("p15-oracle-047", result["message"])

    def test_v1_facets_are_refused(self):
        with self.assertRaises(ValueError):
            app_driver.AppSession({"tag": "t"})

    def test_keystrokes_map_to_push_base_debug_key(self):
        self.assertEqual(app_driver.key_params("cmd+shift+d"), {"key": "d", "modifiers": ["cmd", "shift"]})
        self.assertEqual(app_driver.key_params("opt+left"), {"key": "left", "modifiers": ["option"]})

    def test_resource_params_map_fixture_handles_and_step_refs(self):
        step = {"id": "s", "op": "resource.call", "target": {"machine": "local", "session": "fixture",
                                                             "pane": "$step:c#/value/pane_id"},
                "args": {"method": "pane.split", "params": {"direction": "right"}, "idempotencyKey": "k"}}
        replies = {"c": {"value": {"pane_id": "pane_" + "1" * 32}}}
        fixture = app_driver.Fixture(push_base_replies()["snapshot.get"])
        method, params, key = app_driver.resource_params(step, replies, fixture.target(step, replies))
        self.assertEqual((method, key), ("pane.split", "k"))
        self.assertEqual(params, {"machine": "current", "session": "current", "pane": "pane_" + "1" * 32,
                                  "direction": "right"})
        shell = {"id": "s", "target": {"pane": "shell", "window": "main"}}
        self.assertEqual(fixture.target(shell, {}), {"pane": "pane_000000000000000000000000000000d1",
                                                     "window": "win_000000000000000000000000000000a1"})

    def test_both_drivers_share_one_predicate(self):
        import driver_daemon

        self.assertIs(app_driver.predicate_holds, driver_daemon.predicate_holds)
        self.assertIs(app_driver.MISSING, driver_daemon.MISSING)


class PredicateTests(unittest.TestCase):
    """case_values.predicate_holds: what every driver means by a waitFor."""

    def holds(self, wait, value, baseline=case_values.MISSING):
        return case_values.predicate_holds(wait, value, baseline)

    def test_changed_reads_the_baseline(self):
        self.assertTrue(self.holds({"predicate": "changed"}, 3, 2))
        self.assertFalse(self.holds({"predicate": "changed"}, 2, 2))
        self.assertTrue(self.holds({"predicate": "changed"}, None, case_values.MISSING))
        self.assertFalse(self.holds({"predicate": "changed"}, case_values.MISSING, case_values.MISSING))

    def test_absent_is_a_missing_value_only(self):
        self.assertTrue(self.holds({"predicate": "absent"}, case_values.MISSING))
        self.assertFalse(self.holds({"predicate": "absent"}, []))
        self.assertFalse(self.holds({"predicate": "absent"}, None))

    def test_exists_holds_for_a_present_null(self):
        self.assertTrue(self.holds({"predicate": "exists"}, None))
        self.assertFalse(self.holds({"predicate": "exists"}, case_values.MISSING))

    def test_empty_is_a_sized_value_of_length_zero(self):
        self.assertTrue(self.holds({"predicate": "empty"}, []))
        self.assertFalse(self.holds({"predicate": "empty"}, None))
        self.assertFalse(self.holds({"predicate": "nonEmpty"}, case_values.MISSING))

    def test_contains_checks_a_dict_key(self):
        self.assertTrue(self.holds({"predicate": {"op": "contains", "value": "a"}}, {"a": 1}))
        self.assertTrue(self.holds({"predicate": {"op": "lengthEquals", "value": 2}}, [1, 2]))
        self.assertFalse(self.holds({"equals": "running"}, "launching"))

    def test_pointers(self):
        doc = {"a": [{"b/c": 1}], "0": "zero"}
        self.assertEqual(case_values.resolve_pointer(doc, "/a/0/b~1c"), 1)
        self.assertIs(case_values.resolve_pointer(doc, "/a/01"), case_values.MISSING)
        self.assertEqual(case_values.resolve_pointer(doc, ""), doc)


def runnable_daemon_case() -> dict:
    """The schema's daemon example as the push base runs it: no virtual-clock step, and the restart compares
    only after both restored terminals run."""
    case = json.loads(DAEMON_CASE.read_text(encoding="utf-8"))
    case.pop("$schema", None)
    case["steps"] = [s for s in case["steps"] if s["op"] != "advance_clock"]
    for step in case["steps"]:
        if step["id"] == "restart-daemon":
            step["checkpoint"] = ["before"]
            step["waitFor"] = {"pointer": "/daemon/session/terminals/0/lifecycle", "equals": "running", "maxMs": 5000}
        if step["id"] == "settle-after-restart":
            step["waitFor"] = {"pointer": "/daemon/session/terminals/1/lifecycle", "equals": "running", "maxMs": 5000}
    return case


@unittest.skipUnless(BINARY, "CMUX_ORACLE_DAEMON_BINARY names no cmux-tui")
class LiveCaptureTests(unittest.TestCase):
    """The task's test phase: capture a build twice with v0 facets; the hashes are equal."""

    def test_capture_twice_gives_equal_hashes(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            corpus = Path(root, "corpus", "daemon-ops")
            corpus.mkdir(parents=True)
            case = runnable_daemon_case()
            corpus.joinpath("v0-example.json").write_text(json.dumps(dict(case, id="v0-example")))
            out = Path(root, "capture")
            code = v0.main(["capture", "--product", "daemon", "--binary", BINARY, "--sha", v0.PUSH_BASE,
                            "--corpus", str(corpus.parent), "--out", str(out)])
            capture = json.loads(out.joinpath("capture.json").read_text())
            self.assertEqual(code, 0, json.dumps(capture["differences"])[:2000])
            self.assertTrue(capture["equal"])
            self.assertGreater(capture["checkpoints"], 5)
            row = json.loads(out.joinpath("run-1", "checkpoints.jsonl").read_text().splitlines()[-1])
            daemon = row["snapshot"]["facets"]["daemon"]
            self.assertNotIn("oracle", daemon, "a v0 capture read oracle-state")
            self.assertEqual(row["snapshot"]["meta"]["clock"], "wall")

    def test_v0_advance_clock_is_a_crash_on_any_build(self):
        import driver_daemon

        with tempfile.TemporaryDirectory(dir="/tmp") as root:
            schema = v0.write_schema(Path(root))
            session = driver_daemon.open_session({"binary": BINARY, "run_id": f"v0-test-{os.getpid()}",
                                                  "facets": "v0", "snapshot_schema": str(schema)})
            case = {"id": "clock", "suite": "daemon-ops", "steps": [{"id": "tick", "op": "advance_clock",
                                                                     "args": {"ms": 10}}]}
            state = Path("/tmp/o", driver_daemon.short_token(f"v0-test-{os.getpid()}"), "000001")
            try:
                result = session.run_case(case, {"case_id": "daemon-ops/clock", "state_root": str(state)})
            finally:
                driver_daemon.remove_empty_dir(state.parent)
            self.assertEqual((result["status"], result.get("step")), ("Crash", "tick"))
            self.assertIn("wall clock", result["message"])


if __name__ == "__main__":
    unittest.main()
