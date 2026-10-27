#!/usr/bin/env python3
"""Offline tests of driver_app.py (p15-oracle-047): a fake app answers the control methods, so the step runner,
barriers, turn checkpoints, launch rules and the oracle.py protocol run on any host. The fleet test of the task
(20 action cases twice, equal hashes) is `driver_app.py run-case --app ... --repeat 2` or
`oracle.py run --product app --binary APP --repeat 2` on a mini.

    python3 -I scripts/cmux-next/oracle/driver_app_test.py
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_app  # noqa: E402
import oracle  # noqa: E402

SHA = "a" * 40
APP = "/tmp/fleet/cmux DEV oracle-t.app"
MAIN_ACTOR = ("topology", "focus", "layout", "sidebar", "tabs", "overlays", "intents", "windows", "invariants")
PROVIDED = MAIN_ACTOR + ("terminals",)


class FakeApp:
    """The app's control surface as the driver sees it, with a tiny model: a workspace count that action.run
    `workspace.new` and the key cmd+n raise by one."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        self.env = dict(env)
        self.calls: List[tuple] = []
        self.launches: List[driver_app.LaunchSpec] = []
        self.running = False
        self.workspaces = 1
        self.sequence = 10
        self.armed: Optional[List[str]] = None
        self.ring: List[Dict[str, Any]] = []
        self.next_checkpoint = 1
        self.dropped = 0
        self.settle_pending: List[str] = []
        self.fail_launch = False
        self.stops = 0
        self.hang: set = set()

    # -- the port

    def launch(self, spec: driver_app.LaunchSpec) -> None:
        if self.fail_launch:
            raise driver_app.AppLaunchFailed("no-gui-session", "nobody is on the console")
        self.launches.append(spec)
        self.running = True

    def alive(self) -> bool:
        return self.running

    def stop(self) -> None:
        self.stops += 1
        self.running = False

    socket_path = "/tmp/cmux-debug-oracle-t.sock"
    cli_path = APP + "/Contents/Resources/bin/cmux"

    def cli_env(self) -> Dict[str, str]:
        return {"HOME": self.env["HOME"], "CMUX_NEXT_CONFIG_FILE": "/tmp/scratch/cmux.json"}

    def daemon_socket(self) -> Optional[str]:
        return None

    def request(self, method: str, params: Mapping[str, Any], timeout: float) -> Dict[str, Any]:
        self.calls.append((method, json.loads(json.dumps(params))))
        if method in self.hang:
            raise socket.timeout()
        handler = getattr(self, "m_" + method.replace(".", "_"), None)
        if handler is None:
            return {"ok": False, "error": {"code": "method_not_found", "message": method}}
        return handler(dict(params))

    # -- the model

    def facets(self, names) -> Dict[str, Any]:
        out = {}
        for name in names:
            if name == "topology":
                out[name] = {"workspaces": self.workspaces}
            elif name in PROVIDED:
                out[name] = {"value": name}
            else:
                out[name] = {"status": "not-comparable", "reason": f"no provider for {name} in this build",
                             "task": "p15-oracle-188"}
        return out

    def checkpoint(self, kind: str, label: str, **extra) -> Dict[str, Any]:
        entry = {"sequence": self.next_checkpoint, "kind": kind, "label": label, **extra}
        self.next_checkpoint += 1
        self.ring.append(entry)
        return entry

    def turn(self, action: str) -> None:
        self.workspaces += 1
        self.sequence += 1
        if self.armed is not None:
            self.checkpoint("turn", action, origin="cli", ran=True, facets=self.facets(self.armed))

    def status(self, **extra) -> Dict[str, Any]:
        return {"ok": True, "result": {"armed": self.armed is not None, "dropped": self.dropped, **extra}}

    # -- methods

    def m_debug_oracle_snapshot(self, params):
        if params.get("list"):
            return {"ok": True, "result": [{"facet": f, "provided": f in PROVIDED, "task": "t"}
                                           for f in driver_app.FACETS if f != "daemon"]}
        return {"ok": True, "result": self.facets(params["facets"])}

    def m_debug_oracle_settle(self, params):
        return {"ok": True, "result": {"settled": not self.settle_pending, "pending": self.settle_pending,
                                       "elapsed_ms": 1, "sequence": self.sequence}}

    def m_debug_oracle_wait_for(self, params):
        value = driver_app.resolve_pointer({"topology": {"workspaces": self.workspaces}}, params["pointer"])
        value = None if value is driver_app.MISSING else value
        if "equals" in params:
            ok = value == params["equals"]
        elif params["predicate"] == "changed":
            ok = value != params["since"]
        else:
            ok = value is not None
        return {"ok": True, "result": {"satisfied": ok, "value": value, "evaluations": 1, "elapsed_ms": 1}}

    def m_debug_oracle_recorder(self, params):
        if params.get("clear"):
            self.ring = []
        if params.get("arm") is True:
            facets = params.get("facets") or list(driver_app.FACETS)
            if any(f not in MAIN_ACTOR for f in facets):
                return {"ok": False, "error": {"code": "invalid_params", "message": "a facet read off the main actor"}}
            self.armed = facets
            return self.status(checkpoint=self.checkpoint("mark", "armed", facets=self.facets(facets)))
        if params.get("arm") is False:
            self.armed = None
        return self.status()

    def m_debug_oracle_turns(self, params):
        after = params.get("after") or 0
        return {"ok": True, "result": {"armed": self.armed is not None, "dropped": self.dropped,
                                       "checkpoints": [c for c in self.ring if c["sequence"] > after]}}

    def m_action_run(self, params):
        if params["action"] != "workspace.new":
            return {"ok": False, "error": {"code": "not_found", "message": "no such action"}}
        self.turn(params["action"])
        reply = {"action": params["action"], "ran": True, "waited": True, "args": {},
                 "target": params.get("target"), "created": [f"ws_{self.sequence}"], "sequence": self.sequence,
                 "idempotency_key": None}
        if "name" in params["args"]:
            reply["result"] = {"name": params["args"]["name"]}
        return {"ok": True, "result": reply}

    def m_debug_key(self, params):
        if params["key"] == "n" and params["modifiers"] == ["cmd"]:
            self.turn("workspace.new")
            return {"ok": True, "result": {"handled_by": "app", "action": "workspace.new", "window_kind": "shell"}}
        return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}


def identity(app: str):
    return "oracle-t", "com.cmuxterm.app.debug.oracle.t", "bench-hooks", SHA


def identity_canonicalizer():
    return (lambda snapshots, paths, labels: [json.loads(json.dumps(s)) for s in snapshots]), {}


class Recorder:
    """subprocess.run for cli and mcp steps."""

    def __init__(self, stdout: str = "", returncode: int = 0):
        self.stdout = stdout
        self.returncode = returncode
        self.calls: List[Dict[str, Any]] = []

    def __call__(self, argv, **kwargs):
        # As subprocess.run needs them for str stdout and a str input, and no inherited stdin.
        assert kwargs.get("capture_output") is True and kwargs.get("text") is True, kwargs
        assert ("input" in kwargs) != (kwargs.get("stdin") is subprocess.DEVNULL), kwargs
        self.calls.append({"argv": list(argv), **kwargs})
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, "")


def step(sid: str, op: str, **extra) -> Dict[str, Any]:
    return {"id": sid, "op": op, **extra}


def case(*steps, **extra) -> Dict[str, Any]:
    return {"corpusVersion": 1, "id": "c", "suite": "actions", "source": {}, "environment": {},
            "fixture": {"seed": "s", "network": "offline", "clock": "fixed"}, "preconditions": [],
            "requires": ["actions"], "platforms": ["mac"], "steps": list(steps), "invariants": [], "teardown": [],
            **extra}


NEW_WORKSPACE = step("new", "action.run", target={"workspace": "current"}, args={"action": "workspace.new"},
                     expect={"outcome": "ok", "receipt": "action.done"}, checkpoint=["before", "turn", "settled"])


class AppSessionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.apps: List[FakeApp] = []
        self.run_proc = Recorder()

    def session(self, run=None, canonicalizer=None, **ctx) -> driver_app.AppSession:
        def make(app, out, env):
            fake = FakeApp(app, out, env)
            self.apps.append(fake)
            return fake

        base = {"run_id": "r", "product": "app", "build": "bench", "binary": APP, "out_dir": self.tmp.name}
        return driver_app.AppSession({**base, **ctx}, make_app=make, identity=identity,
                                     canonicalizer=canonicalizer or identity_canonicalizer(),
                                     run=run or self.run_proc,
                                     host=lambda: {"os": "macOS 26.1", "arch": "arm64", "model": "Mac16,10"},
                                     root_base=Path(self.tmp.name) / "o")

    def test_action_run_records_before_turn_and_settled(self) -> None:
        session = self.session()
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        app = self.apps[0]
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual([(c["step"], c["checkpoint"]) for c in result["checkpoints"]],
                         [("new", "before"), ("new", "turn"), ("new", "settled")])
        before, turn, settled = (c["snapshot"] for c in result["checkpoints"])
        self.assertEqual(before["facets"]["topology"], {"workspaces": 1})
        self.assertEqual(turn["facets"]["topology"], {"workspaces": 2}, "the turn shows the optimistic state")
        self.assertEqual(settled["facets"]["topology"], {"workspaces": 2})
        self.assertEqual(turn["facets"]["terminals"]["status"], "not-comparable", "terminals is read off main")
        self.assertEqual(settled["facets"]["daemon"]["status"], "not-comparable")
        self.assertEqual(settled["meta"]["product"], "app")
        self.assertEqual(settled["meta"]["sha"], SHA)
        # The settle after the action waits for the action's own reply sequence, never a sleep.
        settles = [p for m, p in app.calls if m == driver_app.SETTLE]
        self.assertEqual(settles[0]["sequence"], "sync", "the case starts from a settled app")
        self.assertEqual(settles[-1]["sequence"], 11)
        run = next(p for m, p in app.calls if m == "action.run")
        self.assertNotIn("target", run, "`current` is the focused object")
        arms = [p for m, p in app.calls if m == driver_app.RECORDER and p.get("arm") is True and "paths" in p]
        self.assertEqual(sorted(arms[0]["facets"]), sorted(MAIN_ACTOR), "only facets read inside a turn are armed")
        self.assertIsNone(app.armed, "the recorder is disarmed after the step")
        paths = next(p for m, p in app.calls if m == driver_app.SNAPSHOT and "facets" in p)["paths"]
        self.assertEqual(paths["home"], [str(session.paths.home)])
        self.assertIn(str(session.paths.root), paths["root"])

    def test_the_same_case_twice_gives_equal_hashes(self) -> None:
        def without_time(snapshots, paths, labels):  # normalize.py drops the volatile capturedAtMs
            out = [json.loads(json.dumps(s)) for s in snapshots]
            for snap in out:
                snap["meta"].pop("capturedAtMs")
            return out

        ctx = {"run_id": "r", "product": "app", "build": "bench", "binary": APP, "out_dir": self.tmp.name}
        lines: List[str] = []
        code = driver_app.run_repeats(ctx, case(NEW_WORKSPACE), 2,
                                      open_session=lambda c: self.session(canonicalizer=(without_time, {})),
                                      emit=lines.append)
        self.assertEqual(code, 0, lines)
        self.assertIn("equal", lines[-1])
        self.assertEqual(len(self.apps), 2, "each repeat is its own launch")
        self.assertEqual([a.stops for a in self.apps], [1, 1])
        # The same two runs in one launch start from different state: that is why each repeat relaunches.
        session = self.session(canonicalizer=(without_time, {}))
        rows = [[oracle.snapshot_sha256(c["snapshot"]) for c in
                 session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})["checkpoints"]] for _ in range(2)]
        self.assertNotEqual(rows[0], rows[1])

    def test_launch_is_bench_config_with_animations_off(self) -> None:
        session = self.session()
        self.assertEqual(driver_app.ORACLE_CONFIG["ui"]["animations"]["enabled"], False)
        self.assertEqual(driver_app.ORACLE_CONFIG["mcp"]["enabled"], True)
        self.assertEqual(session.build, "bench")
        env = self.apps[0].env
        self.assertEqual(env["HOME"], str(session.paths.home))
        self.assertIn(str(session.paths.root), env["CMUX_NEXT_ORACLE_ROOT"].split(":"))
        session.close()
        self.assertFalse(session.paths.root.exists(), "the session root goes with the session")

    def test_refuses_the_user_app_release_bundles_and_a_build_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "user's cmux"):
            self.session(binary="/Applications/cmux.app")
        with self.assertRaisesRegex(ValueError, "user's cmux"):
            driver_app.check_not_user_app(APP, "com.cmuxterm.app")
        driver_app.check_not_user_app(APP, "com.cmuxterm.app.debug.oracle.t")
        with self.assertRaisesRegex(ValueError, "no debug.oracle"):
            driver_app.run_build("release", "bench")
        with self.assertRaisesRegex(ValueError, "--config bench"):
            driver_app.run_build("debug", "bench")
        self.assertEqual(driver_app.run_build("debug", "debug"), "debug")
        with self.assertRaisesRegex(ValueError, "p15-oracle-049"):
            self.session(switches={"terminal-holder": "new"})
        with self.assertRaisesRegex(ValueError, "tag"):
            self.session(tag="other")

    def test_settle_timeout_is_a_timeout_with_the_pending_list(self) -> None:
        session = self.session()
        session.run_case(case(step("s", "snapshot")), {"case_id": "actions/c"})
        self.apps[0].settle_pending = ["daemon.intents"]
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Timeout")
        self.assertIn("daemon.intents", result["message"])
        self.assertTrue(result["session_dirty"])

    def test_wait_for_changed_sends_the_value_before_the_step(self) -> None:
        session = self.session()
        waiting = dict(NEW_WORKSPACE, waitFor={"pointer": "/topology/workspaces", "predicate": "changed", "maxMs": 2000},
                       checkpoint=["settled"])
        result = session.run_case(case(waiting), {"case_id": "actions/c", "timeout_multiplier": 5})
        self.assertEqual(result["status"], "Pass", result["message"])
        wait = next(p for m, p in self.apps[0].calls if m == driver_app.WAIT_FOR)
        self.assertEqual(wait["since"], 1)
        self.assertEqual(wait["maxMs"], 10000, "Slow multiplies the bound")
        unmet = dict(waiting, waitFor={"pointer": "/topology/workspaces", "equals": 99, "maxMs": 100})
        self.assertEqual(session.run_case(case(unmet), {"case_id": "actions/c"})["status"], "Timeout")
        daemon_wait = dict(waiting, waitFor={"pointer": "/daemon/session", "predicate": "exists", "maxMs": 100})
        self.assertEqual(session.run_case(case(daemon_wait), {"case_id": "actions/c"})["status"], "Crash")

    def test_key_steps_go_through_debug_key(self) -> None:
        self.assertEqual(driver_app.debug_key("cmd+shift+d", "k"), {"key": "d", "modifiers": ["cmd", "shift"]})
        self.assertEqual(driver_app.debug_key("opt+alt+left", "k"), {"key": "left", "modifiers": ["option"]})
        self.assertEqual(driver_app.debug_key("cmd+plus", "k"), {"key": "+", "modifiers": ["cmd"]})
        # A shifted glyph goes as itself: DebugKey.keyPress types ":" (Shift and the ; key code); "shift+;" would
        # keep the characters ";".
        self.assertEqual(driver_app.debug_key(":", "k"), {"key": ":", "modifiers": []})
        for stroke in ("fn+left", "f5"):
            with self.assertRaises(driver_app.CaseError):
                driver_app.debug_key(stroke, "k")
        session = self.session()
        key = step("k", "key", target={"window": "current"}, args={"keys": ["cmd+n"]},
                   expect={"outcome": "ok", "receipt": "action.done"}, checkpoint=["turn", "settled"])
        result = session.run_case(case(key), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual([c["checkpoint"] for c in result["checkpoints"]], ["turn", "settled"])
        typed = dict(key, args={"keys": ["x"]}, checkpoint=["settled"])
        result = session.run_case(case(typed), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Failure", "a key that ran no action has no action receipt")

    def test_cli_and_mcp_steps_use_the_bundle_cli(self) -> None:
        session = self.session()
        self.run_proc.stdout = json.dumps({"value": {"id": "ws_1"}})
        cli = step("c", "cli", target={"workspace": "current"}, args={"argv": ["workspace", "create", "--json"]},
                   expect={"outcome": "ok", "noReceiptReason": "the cli prints the created id only"})
        result = session.run_case(case(cli), {"case_id": "cli/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        call = self.run_proc.calls[0]
        self.assertEqual(call["argv"][:3], [FakeApp.cli_path, "--app-socket", FakeApp.socket_path])
        self.assertNotIn("/tmp/cmux-cli", " ".join(call["argv"]))
        self.assertFalse([k for k in call["env"] if k.startswith("CMUX") and k != "CMUX_NEXT_CONFIG_FILE"])
        self.run_proc.stdout = json.dumps({"jsonrpc": "2.0", "id": 2, "result": {"structuredContent": {"ok": 1}}})
        mcp = step("m", "mcp", target={"workspace": "current"}, args={"tool": "workspace_list"},
                   expect={"outcome": "ok", "result": {"ok": 1}, "noReceiptReason": "a read through mcp has none"})
        result = session.run_case(case(mcp), {"case_id": "mcp/m"})
        self.assertEqual(result["status"], "Pass", result["message"])
        sent = [json.loads(line) for line in self.run_proc.calls[1]["input"].splitlines()]
        self.assertEqual(self.run_proc.calls[1]["argv"][3:], ["mcp", "serve", "--all-tools"])
        self.assertEqual(sent[-1]["params"], {"name": "workspace_list", "arguments": {}})
        self.run_proc.returncode = 1
        self.run_proc.stdout = json.dumps({"error": {"code": "not_found"}})
        failing = dict(cli, expect={"outcome": "error", "error": "cli.not_found"})
        self.assertEqual(session.run_case(case(failing), {"case_id": "cli/c"})["status"], "Pass")

    def test_action_errors_are_typed_and_checked(self) -> None:
        session = self.session()
        refused = step("x", "action.run", target={"workspace": "current"}, args={"action": "nope.missing"},
                       expect={"outcome": "error", "error": "control.not_found"})
        self.assertEqual(session.run_case(case(refused), {"case_id": "actions/x"})["status"], "Pass")
        wrong = dict(refused, expect={"outcome": "ok", "receipt": "action.done"})
        self.assertEqual(session.run_case(case(wrong), {"case_id": "actions/x"})["status"], "Failure")
        user = dict(NEW_WORKSPACE, args={"action": "workspace.new", "entrypoint": "key"})
        self.assertEqual(session.run_case(case(user), {"case_id": "actions/x"})["status"], "Crash")
        # The reply gives no details: an errorDetails check is a Crash, never a silent pass.
        detailed = dict(refused, expect={**refused["expect"], "errorDetails": {"extra": {"code": "x"}}})
        result = session.run_case(case(detailed), {"case_id": "actions/x"})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("errorDetails", result["message"])

    def test_other_drivers_ops_and_unsupported_environment_fail_loudly(self) -> None:
        session = self.session()
        call = step("r", "resource.call", target={"session": "fixture"}, readOnly=True,
                    args={"method": "session.snapshot"})
        result = session.run_case(case(call), {"case_id": "reads/r"})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("driver_daemon.py", result["message"])
        themed = case(NEW_WORKSPACE, environment={"theme": "dark"})
        self.assertEqual(session.run_case(themed, {"case_id": "actions/c"})["status"], "Crash")
        missing = case(NEW_WORKSPACE, fixture={"seed": "s", "network": "offline", "clock": "fixed",
                                               "setup": "no-such-family"})
        result = session.run_case(missing, {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("p15-oracle-046", result["message"])

    def test_viewport_relaunches_and_a_failed_launch_is_a_dirty_crash(self) -> None:
        session = self.session()
        session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        session.run_case(case(NEW_WORKSPACE, environment={"viewport": {"width": 800, "height": 600}}),
                         {"case_id": "actions/c"})
        app = self.apps[0]
        self.assertEqual([s.window for s in app.launches], [(40, 40, 1440, 900), (40, 40, 800, 600)])
        self.assertEqual(app.stops, 1)
        broken = self.session()
        self.apps[-1].fail_launch = True
        result = broken.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Crash")
        self.assertTrue(result["session_dirty"])
        self.assertIn("no-gui-session", result["message"])

    def test_cli_and_mcp_through_the_real_subprocess_run(self) -> None:
        stub = Path(self.tmp.name) / "cmux"
        stub.write_text("#!/bin/sh\n"
                        "case \"$3\" in\n"
                        "  mcp) /bin/cat >/dev/null; echo '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":"
                        "{\"structuredContent\":{\"ok\":1}}}' ;;\n"
                        "  hang) exec /bin/sleep 30 ;;\n"
                        "  *) /bin/cat ;;\n"
                        "esac\n")
        os.chmod(stub, 0o755)
        session = self.session(run=subprocess.run)
        self.apps[0].cli_path = str(stub)
        ctx = {"case_id": "cli/c", "timeout_multiplier": 0.05}
        piped = step("c", "cli", target={"workspace": "current"}, args={"argv": ["read"], "stdin": '{"piped": 1}'},
                     expect={"outcome": "ok", "result": {"exit": 0, "stdout": {"piped": 1}},
                             "noReceiptReason": "the stub echoes its input"})
        result = session.run_case(case(piped), ctx)
        self.assertEqual(result["status"], "Pass", result["message"])
        quiet = dict(piped, args={"argv": ["read"]},
                     expect={"outcome": "ok", "result": {"exit": 0, "stdout": None},
                             "noReceiptReason": "no input: the runner's stdin stays out"})
        result = session.run_case(case(quiet), ctx)
        self.assertEqual(result["status"], "Pass", result["message"])
        mcp = step("m", "mcp", target={"workspace": "current"}, args={"tool": "workspace_list"},
                   expect={"outcome": "ok", "result": {"ok": 1}, "noReceiptReason": "a read through mcp has none"})
        result = session.run_case(case(mcp), {"case_id": "mcp/m"})
        self.assertEqual(result["status"], "Pass", result["message"])
        hung = dict(piped, args={"argv": ["hang"]})
        result = session.run_case(case(hung), {"case_id": "cli/c", "timeout_multiplier": 0.02})
        self.assertEqual((result["status"], result.get("step")), ("Timeout", "c"), result["message"])
        self.assertIn("cmux hang", result["message"])
        self.apps[0].cli_path = str(Path(self.tmp.name) / "missing")
        result = session.run_case(case(piped), ctx)
        self.assertEqual((result["status"], result.get("step")), ("Crash", "c"), result["message"])

    def test_a_key_aimed_past_its_window_fails_loudly(self) -> None:
        session = self.session()
        window = step("w", "key", target={"window": "$step:new#/created/0"}, args={"keys": ["x"]},
                      expect={"outcome": "ok", "noReceiptReason": "a typed key runs no action here"})
        result = session.run_case(case(NEW_WORKSPACE, window), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        sent = [p for m, p in self.apps[0].calls if m == "debug.key"][-1]
        self.assertEqual(sent["window"], "ws_11")
        for aimed in ({"window": "current", "pane": "$step:new#/created/0"}, {"browser": "$step:new#/created/0"}):
            result = session.run_case(case(NEW_WORKSPACE, dict(window, target=aimed)), {"case_id": "actions/c"})
            self.assertEqual((result["status"], result.get("step")), ("Crash", "w"), result["message"])
            self.assertIn("focused pane", result["message"])

    def test_expect_result_is_the_action_value_not_the_run_reply(self) -> None:
        session = self.session()
        named = dict(NEW_WORKSPACE, args={"action": "workspace.new", "params": {"name": "a"}},
                     expect={"outcome": "ok", "result": {"name": "a"}, "noReceiptReason": "the result is checked"})
        for _ in range(2):  # the reply's sequence and created ids change; the action's value does not
            result = session.run_case(case(named), {"case_id": "actions/c"})
            self.assertEqual(result["status"], "Pass", result["message"])
        wrong = dict(named, expect={"outcome": "ok", "result": {"name": "b"}, "noReceiptReason": "it differs"})
        self.assertEqual(session.run_case(case(wrong), {"case_id": "actions/c"})["status"], "Failure")
        none = dict(NEW_WORKSPACE, expect={"outcome": "ok", "result": {}, "noReceiptReason": "no value at all"})
        self.assertEqual(session.run_case(case(none), {"case_id": "actions/c"})["status"], "Failure")

    def test_an_expected_receipt_kind_is_never_a_silent_pass(self) -> None:
        session = self.session()
        result = session.run_case(case(NEW_WORKSPACE, step("s", "snapshot")), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertIn("receipt kind not compared", result["message"])
        self.assertIn("new action.done", result["message"])
        flags = {(c["step"], c["checkpoint"]): c.get("uncertain") for c in result["checkpoints"]}
        self.assertEqual(flags, {("new", "before"): True, ("new", "turn"): True, ("new", "settled"): True,
                                 ("s", "settled"): None})
        coerced = oracle.coerce_result(result)
        self.assertTrue(all(row.get("uncertain") for row in coerced["rows"] if row["step"] == "new"))

    def test_fixture_conditions_the_launch_cannot_apply_fail_loudly(self) -> None:
        session = self.session()
        base = {"seed": "s", "network": "offline", "clock": "fixed"}
        for fixture, owner in (({**base, "agent": "none"}, "p15-oracle-200"),
                               ({**base, "clock": "virtual"}, "p15-oracle-185")):
            result = session.run_case(case(NEW_WORKSPACE, fixture=fixture), {"case_id": "actions/c"})
            self.assertEqual(result["status"], "Crash")
            self.assertIn(owner, result["message"])
        named = dict(NEW_WORKSPACE, target={"window": "main"})
        result = session.run_case(case(named), {"case_id": "actions/c"})
        self.assertEqual((result["status"], result.get("step")), ("Crash", "new"))
        self.assertIn("p15-oracle-180", result["message"])
        self.assertEqual(self.apps[0].launches, [], "a case the launch cannot run starts no app")
        mocked = case(NEW_WORKSPACE, fixture={**base, "agent": "mock"})
        self.assertEqual(session.run_case(mocked, {"case_id": "actions/c"})["status"], "Pass")

    def test_unexpected_errors_are_this_case_crash_with_its_step(self) -> None:
        session = self.session()
        result = session.run_case(case(NEW_WORKSPACE, {"id": "bad"}), {"case_id": "actions/c"})
        self.assertEqual((result["status"], result.get("step")), ("Crash", "bad"), result["message"])
        self.assertEqual(len(result["checkpoints"]), 3, "the checkpoints before the bad step are kept")
        self.assertTrue(result["session_dirty"])
        fixtures = Path(self.tmp.name) / "fx"
        (fixtures / "action_fixtures").mkdir(parents=True)
        (fixtures / "action_fixtures" / "__init__.py").write_text("")
        (fixtures / "action_fixtures" / "broken.py").write_text("def setup(rpc:\n")
        original = driver_app.FIXTURES
        driver_app.FIXTURES = fixtures / "action_fixtures"
        sys.path.insert(0, str(fixtures))
        saved = {name: sys.modules.pop(name) for name in list(sys.modules) if name.startswith("action_fixtures")}

        def restore() -> None:
            driver_app.FIXTURES = original
            sys.path.remove(str(fixtures))
            for name in [n for n in sys.modules if n.startswith("action_fixtures")]:
                del sys.modules[name]
            sys.modules.update(saved)

        self.addCleanup(restore)
        broken = case(NEW_WORKSPACE, fixture={"seed": "s", "network": "offline", "clock": "fixed", "setup": "broken"})
        result = session.run_case(broken, {"case_id": "actions/c"})
        self.assertEqual((result["status"], result.get("step")), ("Crash", "setup"), result["message"])
        self.assertIn("SyntaxError", result["message"])

    def test_a_hung_turn_step_keeps_its_own_timeout(self) -> None:
        session = self.session()
        session.run_case(case(step("s", "snapshot")), {"case_id": "actions/c"})
        app = self.apps[0]
        app.hang = {"action.run"}
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual((result["status"], result.get("step")), ("Timeout", "new"), result["message"])
        self.assertIn("action.run gave no answer", result["message"])
        self.assertTrue(result["session_dirty"])
        after = app.calls[[m for m, _ in app.calls].index("action.run") + 1:]
        self.assertEqual(after, [], "no disarm wait on a hung app")
        # A Failure on a healthy app disarms; a disarm that fails then keeps the Failure and dirties the session.
        app.hang = set()
        typed = step("k", "key", target={"window": "current"}, args={"keys": ["x"]},
                     expect={"outcome": "ok", "receipt": "action.done"}, checkpoint=["turn"])
        result = session.run_case(case(typed), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Failure")
        self.assertIsNone(app.armed)
        self.assertNotIn("session_dirty", result)
        original = app.m_debug_oracle_recorder
        app.m_debug_oracle_recorder = lambda p: original(p) if p.get("arm") is True else {"ok": False, "error": {}}
        result = session.run_case(case(typed), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Failure", result["message"])
        self.assertIn("no action ran", result["message"])
        self.assertTrue(result["session_dirty"])

    def test_the_app_log_outlives_the_session_root(self) -> None:
        session = self.session(out_dir=None)
        out = session.out
        self.assertFalse(str(out).startswith(str(session.paths.root)))
        (out / "app.log").write_text("launch failed\n")
        session.close()
        self.assertFalse(session.paths.root.exists())
        self.assertEqual((out / "app.log").read_text(), "launch failed\n")

    def test_results_pass_oracle_protocol_checks(self) -> None:
        session = self.session()
        result = oracle.coerce_result(session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"}))
        self.assertEqual(result["status"], "Pass")
        self.assertEqual(len(result["checkpoints"]), 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
