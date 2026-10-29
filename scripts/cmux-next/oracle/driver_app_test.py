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
        # The I11-I14 side channels: counters since launch that each action moves.
        self.blocking_compiled = True
        self.main_blocks = 0
        self.blocks_per_turn = 0
        self.hang_records: List[Dict[str, Any]] = [{"sequence": 2, "kind": "stall", "duration_ms": 90.0}]
        self.runs: List[Dict[str, Any]] = []
        self.commit_ms = 3.0
        self.stall_ms = 0.0
        self.uptime = 500.0
        self.idle_wakes = 0
        self.left_clients: List[str] = []
        # The switches facet's `arms` (None: no provider in this build) and the per-key hit counts (None: no
        # debug.oracle.switch_hits in this build); each turn counts one hit on the arm the key runs.
        self.switch_arms: Optional[Dict[str, str]] = None
        self.hits: Optional[Dict[str, Dict[str, int]]] = None
        self.daemon_sock: Optional[str] = None
        self.tabs: Optional[Dict[str, Any]] = None
        self.palette_open = False
        self.daemon_pid: Optional[int] = 4242
        self.signals: List[int] = []
        self.relaunches = 0
        # The app's pid: a restart relaunches it, a child crash the app survives keeps it.
        self.pid = 4242

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
        return self.daemon_sock

    def daemon_owner_pid(self) -> Optional[int]:
        return self.daemon_pid

    def signal_daemon(self, signum: int) -> Optional[int]:
        if self.daemon_pid is None:
            return None
        self.signals.append(signum)
        return self.daemon_pid

    def relaunch(self) -> None:
        if self.fail_launch:
            raise driver_app.AppLaunchFailed("quit-keep-sessions", "the app still runs 30 s after quitKeepSessions")
        self.relaunches += 1
        self.pid += 1

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
            elif name == "switches" and self.switch_arms is not None:
                out[name] = {"arms": dict(self.switch_arms), "hits": []}
            elif name == "tabs" and self.tabs is not None:
                out[name] = json.loads(json.dumps(self.tabs))
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
        self.main_blocks += self.blocks_per_turn
        self.runs.append({"sequence": len(self.runs) + 1, "id": action, "entrypoint": "socket",
                          "commit_ms": self.commit_ms, "outcome": "committed"})
        if self.stall_ms:
            self.hang_records.append({"sequence": self.hang_records[-1]["sequence"] + 1, "kind": "stall",
                                      "duration_ms": self.stall_ms})
        for key, counts in (self.hits or {}).items():
            counts[(self.switch_arms or {}).get(key, "old")] += 1
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
        if params["action"] == "page.crash":
            # A renderer crash the app survives (pid unchanged), or with `takeApp` one that relaunched it.
            if params["args"].get("takeApp"):
                self.pid += 1
            return {"ok": True, "result": {"action": params["action"], "ran": True, "sequence": self.sequence}}
        if params["action"] != "workspace.new":
            # As ControlError+ActionRun gives it: the details name the action and the reason.
            return {"ok": False, "error": {"code": "not_found", "message": "no such action",
                                           "data": {"action": params["action"], "reason": "no such action"}}}
        self.turn(params["action"])
        reply = {"action": params["action"], "ran": True, "waited": True, "args": {},
                 "target": params.get("target"), "created": [f"ws_{self.sequence}"], "sequence": self.sequence,
                 "idempotency_key": None}
        if "name" in params["args"]:
            reply["result"] = {"name": params["args"]["name"]}
        return {"ok": True, "result": reply}

    def m_debug_blocking(self, params):
        sites = [{"context": "main", "kind": "blocking-call", "seam_kind": "none", "location": "Store.swift:9",
                  "count": self.main_blocks, "total_ms": 1.0, "max_ms": 1.0}] if self.main_blocks else []
        return {"ok": True, "result": {"compiled_in": self.blocking_compiled, "overflow": 0, "sites": sites,
                                       "contexts": {"main": {"sites": len(sites), "count": self.main_blocks,
                                                             "overflow": 0}}}}

    def m_debug_hangs(self, params):
        records = [r for r in self.hang_records if r["sequence"] > params.get("after", 0)]
        records = records[-params["limit"]:] if "limit" in params else records
        gaps = sum(1 for r in self.hang_records if r["duration_ms"] >= 250)
        return {"ok": True, "result": {"installed": True, "count": len(self.hang_records), "count250": gaps,
                                       "records": records}}

    def m_debug_action_budget(self, params):
        return {"ok": True, "result": {"action_budget_ms": 10, "recent": self.runs[-params.get("limit", 64):]}}

    def m_debug_wakeups(self, params):
        self.uptime += 1.5
        reply = {"uptime_s": self.uptime, "active_frame_clients": list(self.left_clients),
                 "ledger": [{"owner": "IdleScheduler", "reason": "period", "count": self.idle_wakes}]}
        return {"ok": True, "result": reply}
    def m_debug_oracle_switch_hits(self, params):
        if self.hits is None:
            return {"ok": False, "error": {"code": "method_not_found", "message": "debug.oracle.switch_hits"}}
        report = {"switches": {key: {**counts, "sites": {"Site.run": dict(counts)}} for key, counts in self.hits.items()}}
        if params.get("reset"):
            self.hits = {key: {"old": 0, "new": 0} for key in self.hits}
        return {"ok": True, "result": report}

    def m_debug_key(self, params):
        if params.get("target") == "palette":  # DebugKey.send: the palette's visible panel, else an error
            if not self.palette_open:
                return {"ok": True, "result": {"error": "the palette is not open"}}
            return {"ok": True, "result": {"handled_by": "palette", "action": None, "window_kind": "palette"}}
        if params["key"] == "n" and params["modifiers"] == ["cmd"]:
            self.turn("workspace.new")
            return {"ok": True, "result": {"handled_by": "app", "action": "workspace.new", "window_kind": "shell"}}
        return {"ok": True, "result": {"handled_by": "responder", "action": None, "window_kind": "shell"}}


def identity(app: str):
    return "oracle-t", "com.cmuxterm.app.debug.oracle.t", "bench-hooks", SHA


def identity_canonicalizer():
    return (lambda snapshots, paths, labels, drop: [json.loads(json.dumps(s)) for s in snapshots]), {}


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


class SessionTestBase(unittest.TestCase):
    """A session on a FakeApp, with an empty switch registry unless a test gives one."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.apps: List[FakeApp] = []
        self.run_proc = Recorder()

    def session(self, run=None, canonicalizer=None, *, switch_roots=None, read_daemon_arms=None, read_daemon=None,
                read_resources=None,                 **ctx) -> driver_app.AppSession:
        def make(app, out, env):
            fake = FakeApp(app, out, env)
            self.apps.append(fake)
            return fake

        base = {"run_id": "r", "product": "app", "build": "bench", "binary": APP, "out_dir": self.tmp.name}
        extra = {"read_daemon_arms": read_daemon_arms} if read_daemon_arms else {}
        if read_daemon:
            extra["read_daemon"] = read_daemon
        return driver_app.AppSession({**base, **ctx}, make_app=make, identity=identity,
                                     canonicalizer=canonicalizer or identity_canonicalizer(),
                                     run=run or self.run_proc,
                                     host=lambda: {"os": "macOS 26.1", "arch": "arm64", "model": "Mac16,10"},
                                     root_base=Path(self.tmp.name) / "o",
                                     switch_roots=switch_roots or self.empty_registry(), 
                                     read_resources=read_resources or (lambda pid: None), **extra)

    def empty_registry(self) -> "driver_app.switches.Roots":
        return driver_app.switches.selftest_tree(Path(self.tmp.name) / "registry-empty", {}, None)


class AppSessionTest(SessionTestBase):
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
        def without_time(snapshots, paths, labels, drop):  # normalize.py drops the volatile capturedAtMs
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
        with self.assertRaisesRegex(ValueError, "unknown switch: ghost"):
            self.session(switches={"ghost": "new"})
        self.assertEqual(self.apps, [], "nothing launches on a switch the run cannot apply")
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

    def test_shift_alone_types_the_shifted_symbol(self) -> None:
        # A US keyboard: Shift-; is `:`, so a case types chrome:// without a `:` keystroke (case-v1 has none).
        self.assertEqual(driver_app.debug_key("shift+;", "k"), {"key": ":", "modifiers": []})
        self.assertEqual(driver_app.debug_key("shift+/", "k"), {"key": "?", "modifiers": []})
        self.assertEqual(driver_app.debug_key("shift+1", "k"), {"key": "!", "modifiers": []})
        # With another modifier it is a shortcut on the base key, as before; letters keep their Shift flag.
        self.assertEqual(driver_app.debug_key("cmd+shift+[", "k"), {"key": "[", "modifiers": ["cmd", "shift"]})
        self.assertEqual(driver_app.debug_key("shift+a", "k"), {"key": "a", "modifiers": ["shift"]})
        self.assertEqual(driver_app.debug_key(";", "k"), {"key": ";", "modifiers": []})

    def test_a_child_crash_that_takes_the_app_with_it_fails_the_case(self) -> None:
        session = self.session()
        crash = step("crash", "action.run", target={"window": "current"}, args={"action": "page.crash"},
                     expect={"outcome": "ok", "receipt": "action.done"})
        allow = [{"kind": "renderer", "reason": "the step crashes the page on purpose", "steps": ["crash"]}]
        result = session.run_case(case(crash, allow_crashes=allow), {"case_id": "journeys/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        relaunched = dict(crash, args={"action": "page.crash", "params": {"takeApp": True}})
        result = session.run_case(case(relaunched, allow_crashes=allow), {"case_id": "journeys/c"})
        self.assertEqual((result["status"], result.get("step")), ("Crash", "crash"), result["message"])
        self.assertIn("pid 4242, now 4243", result["message"])

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
        # errorDetails is a subset of the refusal's error.data, compared key by key.
        detailed = dict(refused, expect={**refused["expect"], "errorDetails": {"action": "nope.missing"}})
        result = session.run_case(case(detailed), {"case_id": "actions/x"})
        self.assertEqual(result["status"], "Pass", result["message"])
        other = dict(refused, expect={**refused["expect"], "errorDetails": {"action": "workspace.new"}})
        result = session.run_case(case(other), {"case_id": "actions/x"})
        self.assertEqual(result["status"], "Failure")
        self.assertIn('/action: expected "workspace.new", got "nope.missing"', result["message"])
        absent = dict(refused, expect={**refused["expect"], "errorDetails": {"extra": {"code": "x"}}})
        result = session.run_case(case(absent), {"case_id": "actions/x"})
        self.assertEqual(result["status"], "Failure")
        self.assertIn("/extra: missing", result["message"])

    def test_error_details_on_a_reply_with_no_details_are_a_crash(self) -> None:
        # The cli reply reaches the driver as a typed code only: the check is a Crash, never a silent pass.
        session = self.session()
        self.run_proc.returncode = 1
        self.run_proc.stdout = json.dumps({"error": {"code": "not_found"}})
        cli = step("c", "cli", target={"workspace": "current"}, args={"argv": ["workspace", "list"]},
                   expect={"outcome": "error", "error": "cli.not_found", "errorDetails": {"action": "x"}})
        result = session.run_case(case(cli), {"case_id": "cli/c"})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("errorDetails: the cli reply gives this driver no error details", result["message"])

    def test_focus_reaches_action_run_only_when_the_step_asks(self) -> None:
        session = self.session()
        focused = dict(NEW_WORKSPACE, args={"action": "workspace.new", "focus": True})
        self.assertEqual(session.run_case(case(focused), {"case_id": "actions/f"})["status"], "Pass")
        session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/n"})
        runs = [params for method, params in self.apps[-1].calls if method == "action.run"]
        self.assertEqual([run.get("focus") for run in runs], [True, None])

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

    def test_the_engine_arm_and_a_case_pin_set_the_launch_default_engine(self) -> None:
        session = self.session(engine="webkit")
        session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        session.run_case(case(NEW_WORKSPACE, environment={"engine": "none"}), {"case_id": "actions/c"})
        session.run_case(case(NEW_WORKSPACE, environment={"engine": "chromium"}), {"case_id": "actions/c"})
        app = self.apps[0]
        self.assertEqual([s.engine for s in app.launches], ["webkit", "chromium"])
        self.assertEqual(app.stops, 1, "a case that needs no engine shares the arm's launch")
        self.assertEqual(driver_app.launch_config(app.launches[0])["browser"], {"defaultEngine": "webkit"})
        default = driver_app.launch_config(driver_app.launch_spec(case(NEW_WORKSPACE)))
        self.assertNotIn("browser", default, "no arm and no pin: the app's own default engine")
        self.assertEqual(default, driver_app.ORACLE_CONFIG)
        with self.assertRaises(ValueError):
            self.session(engine="gecko")

    def test_an_engine_arm_canonicalizes_without_the_tab_engine_and_reads_it_back(self) -> None:
        drops: List[tuple] = []

        def recording(snapshots, paths, labels, drop):
            drops.append(tuple(drop))
            return [json.loads(json.dumps(s)) for s in snapshots]

        tabs = {"panes": [{"pane": "p1", "selected": "t1", "tabs": [
            {"tab": "t1", "kind": "browser", "engine": "webkit"}, {"tab": "t2", "kind": "browser", "engine": "cef"},
            {"tab": "t3", "kind": "page", "engine": None}]}]}
        for engine, want in (("webkit", (driver_app.ENGINE_DROP,)), (None, ())):
            drops.clear()
            session = self.session(canonicalizer=(recording, {}), engine=engine)
            session.ensure_launched(driver_app.launch_spec(case(NEW_WORKSPACE), engine))
            self.apps[-1].tabs = tabs
            result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
            self.assertEqual(result["status"], "Pass", result["message"])
            self.assertEqual(set(drops), {want}, engine)
            rows = result["checkpoints"]
            if engine is None:
                self.assertTrue(all("engines" not in row for row in rows))
                continue
            with_tabs = [row for row in rows if "tabs" in row["snapshot"].get("facets", {})]
            self.assertTrue(with_tabs)
            self.assertTrue(all(row["engines"] == {"cef": 1, "webkit": 1} for row in with_tabs), with_tabs)
        self.assertEqual(driver_app.tab_engines({"facets": {"tabs": {"status": "not-comparable"}}}), {})

    def test_daemon_kill_and_app_restart_run_here_and_dirty_the_session(self) -> None:
        session = self.session()
        kill = step("drop", "kill", target={"process": "daemon"}, args={"signal": "KILL"},
                    expect={"outcome": "ok", "noReceiptReason": "a killed process runs no action"})
        restart = step("relaunch", "restart", target={"process": "app"},
                       expect={"outcome": "ok", "noReceiptReason": "a relaunch runs no action"})
        result = session.run_case(case(NEW_WORKSPACE, kill, restart, requires=["actions", "restart"]),
                                  {"case_id": "journeys/c"})
        app = self.apps[0]
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual(app.signals, [driver_app.signal.SIGKILL])
        self.assertEqual(app.relaunches, 1)
        self.assertTrue(result["session_dirty"])
        # No owner to kill, and a relaunch that does not come back, are this case's Crash at that step.
        app.daemon_pid = None
        result = session.run_case(case(kill, requires=["restart"]), {"case_id": "journeys/c"})
        self.assertEqual((result["status"], result["step"]), ("Crash", "drop"), result["message"])
        app.fail_launch = True
        result = session.run_case(case(restart, requires=["restart"]), {"case_id": "journeys/c"})
        self.assertEqual((result["status"], result["step"]), ("Crash", "relaunch"), result["message"])
        self.assertIn("quit-keep-sessions", result["message"])

    def test_other_process_kills_and_restarts_are_other_drivers(self) -> None:
        session = self.session()
        for op, process in (("kill", "renderer"), ("kill", "holder"), ("restart", "daemon")):
            other = step("x", op, target={"process": process}, expect={"outcome": "ok", "noReceiptReason": "no action"})
            result = session.run_case(case(NEW_WORKSPACE, other, requires=["restart"]), {"case_id": "journeys/c"})
            self.assertEqual((result["status"], result["step"]), ("Crash", "x"), result["message"])
            self.assertIn(f"target.process {process}", result["message"])
            self.assertIn("driver_daemon.py", result["message"])
        # Refused before any launch.
        self.assertEqual(self.apps[0].launches, [])

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

    def test_key_window_page_makes_the_page_the_key_window(self) -> None:
        # Without keyWindow debug.key sends to the shell window, whose terminal takes the keys: a chat prompt would
        # never reach the agent chat's Chromium page (DebugKey.send). The palette is target.overlay, not keyWindow.
        session = self.session()
        typed = step("t", "key", target={"window": "current"}, args={"keys": ["h", "return"], "keyWindow": "page"},
                     expect={"outcome": "ok", "noReceiptReason": "typing into the page runs no action"})
        result = session.run_case(case(typed), {"case_id": "journeys/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        sent = [p for m, p in self.apps[0].calls if m == "debug.key"]
        self.assertEqual([(p["key"], p.get("target")) for p in sent], [("h", "page"), ("return", "page")])
        self.assertNotIn("window", sent[0], "`current` names no window")
        shell = dict(typed, args={"keys": ["h"]})
        result = session.run_case(case(shell), {"case_id": "journeys/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("target", [p for m, p in self.apps[0].calls if m == "debug.key"][-1])
        for bad, words in ((dict(typed, args={"keys": ["h"], "keyWindow": "palette"}), "keyWindow"),
                           (dict(typed, args={"keys": ["h"], "keyWindow": "devtools"}), "keyWindow"),
                           (dict(typed, target={"overlay": "palette"}), "not both")):
            result = session.run_case(case(bad), {"case_id": "journeys/c"})
            self.assertEqual((result["status"], result.get("step")), ("Crash", "t"), result["message"])
            self.assertIn(words, result["message"])

    def test_a_palette_key_goes_to_the_palette_panel(self) -> None:
        """target.overlay palette is debug.key's target palette (the palette's visible panel), never the shell
        window's first responder; with the palette closed the key is refused, not typed into the terminal."""
        session = self.session()
        typed = step("q", "key", target={"overlay": "palette"}, args={"keys": ["a", "escape"]},
                     expect={"outcome": "ok", "noReceiptReason": "the palette panel answers it"},
                     checkpoint=["before", "settled"])
        result = session.run_case(case(typed), {"case_id": "live/c"})
        self.assertEqual((result["status"], result.get("step")), ("Failure", "q"), result["message"])
        self.assertIn("error key.refused", result["message"])
        app = self.apps[0]
        app.palette_open = True
        result = session.run_case(case(typed), {"case_id": "live/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        sent = [p for m, p in app.calls if m == "debug.key"][-2:]
        self.assertEqual(sent, [{"key": "a", "modifiers": [], "target": "palette"},
                                {"key": "escape", "modifiers": [], "target": "palette"}])
        in_window = dict(typed, target={"window": "$step:new#/created/0", "overlay": "palette"})
        result = session.run_case(case(NEW_WORKSPACE, in_window), {"case_id": "live/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual([p for m, p in app.calls if m == "debug.key"][-1],
                         {"key": "escape", "modifiers": [], "window": "ws_11", "target": "palette"})
        for bad in (dict(NEW_WORKSPACE, target={"overlay": "palette"}), dict(typed, target={"overlay": "toast"})):
            result = session.run_case(case(bad), {"case_id": "live/c"})
            self.assertEqual((result["status"], result.get("step")), ("Crash", bad["id"]), result["message"])
            self.assertIn("routes keys only", result["message"])

    def test_a_web_case_gets_its_own_loopback_fixture(self) -> None:
        """fixture.web: the case's $WEB is its own server's origin in every step, the server stops with the case,
        and the checkpoints are canonicalized with that origin (normalize.py --web), so no snapshot holds the port."""
        origin = "http://127.0.0.1:4321"

        class FakeWeb:
            started = stopped = 0

            def start(self) -> str:
                FakeWeb.started += 1
                return origin

            def stop(self) -> None:
                FakeWeb.stopped += 1

            def expand(self, value):
                return driver_app.webfixture.expand(value, origin)

        seen: List[Any] = []

        def canonicalize(snapshots, paths, labels, drop):
            seen.append(paths)
            return [json.loads(json.dumps(s)) for s in snapshots]

        session = self.session(canonicalizer=(canonicalize, {}))
        session.web_fixture = FakeWeb
        load = step("open", "cli", target={"window": "current"},
                    args={"argv": ["tab", "new-webkit", "--url", "$WEB/load.html", "--focus"]},
                    expect={"outcome": "ok", "noReceiptReason": "the cli prints the created id only"})
        web = {"seed": "s", "network": "offline", "clock": "fixed", "web": True}
        result = session.run_case(case(load, fixture=web), {"case_id": "live/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual(self.run_proc.calls[-1]["argv"][-4:], ["new-webkit", "--url", f"{origin}/load.html", "--focus"])
        self.assertEqual((FakeWeb.started, FakeWeb.stopped), (1, 1))
        self.assertEqual(seen[-1].web, (origin,))
        self.assertEqual(seen[-1].control_paths(), session.paths.control_paths(), "the app gets no web prefix")
        session.run_case(case(NEW_WORKSPACE), {"case_id": "live/c"})
        self.assertEqual((seen[-1].web, FakeWeb.started), ((), 1), "a case without fixture.web starts no server")

        class Refused(FakeWeb):
            def start(self) -> str:
                raise driver_app.webfixture.FixtureError("cannot listen on 127.0.0.1:0")

        session.web_fixture = Refused
        result = session.run_case(case(load, fixture=web), {"case_id": "live/c"})
        self.assertEqual((result["status"], result.get("step")), ("Crash", "setup"), result["message"])
        self.assertIn("cannot listen", result["message"])

    def test_a_web_case_runs_on_a_real_loopback_server(self) -> None:
        """The default factory is webfixture.WebFixture: a port the OS picks on 127.0.0.1, stopped after the case."""
        seen: List[Any] = []

        def canonicalize(snapshots, paths, labels, drop):
            seen.append(paths)
            return [json.loads(json.dumps(s)) for s in snapshots]

        session = self.session(canonicalizer=(canonicalize, {}))
        load = step("open", "cli", target={"window": "current"}, args={"argv": ["tab", "new-webkit", "--url",
                                                                               "$WEB/load.html"]},
                    expect={"outcome": "ok", "noReceiptReason": "the cli prints the created id only"})
        web = {"seed": "s", "network": "offline", "clock": "fixed", "web": True}
        result = session.run_case(case(load, fixture=web), {"case_id": "live/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        url = self.run_proc.calls[-1]["argv"][-1]
        self.assertRegex(url, r"^http://127\.0\.0\.1:\d+/load\.html$")
        (origin,) = seen[-1].web
        self.assertTrue(url.startswith(origin + "/"))
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", int(origin.rsplit(":", 1)[1])), timeout=2).close()

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

    # -- the trace of invariants I11-I15

    TRACED = step("new", "action.run", target={"workspace": "current"}, args={"action": "workspace.new"},
                  expect={"outcome": "ok"}, checkpoint=["before", "settled"])
    RESOURCES = {"pid": 4242, "fds": 20, "threads": 8, "children": 1, "source": "/proc/<pid>/fd",
                 "liveObjects": {"workspaces": 1, "terminals": 1}}

    def traced_run(self, the_case: Dict[str, Any], teardown_threads: int = 8):
        readings = [self.RESOURCES, {**self.RESOURCES, "threads": teardown_threads}]
        read = []

        def read_resources(pid):
            read.append(pid)
            return dict(readings[len(read) - 1])

        session = self.session(trace=True, read_resources=read_resources)
        return session, session.run_case(the_case, {"case_id": "actions/c"}), read

    def check(self, trace: Dict[str, Any]):
        import invariants

        return invariants.check_trace(json.loads(json.dumps(trace)), schema=invariants.load_schema())

    def test_a_traced_case_reads_each_side_channel_around_the_step(self) -> None:
        session, result, read = self.traced_run(case(self.TRACED), teardown_threads=9)
        app = self.apps[0]
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual(read, [4242, 4242], "the tag daemon after the fixture setup and after its teardown")
        trace = result["trace"]
        self.assertEqual(trace["setup"]["daemonResources"]["threads"], 8)
        self.assertEqual(trace["teardown"]["daemonResources"]["threads"], 9)
        self.assertNotIn("recorderArmed", trace)
        (record,) = trace["steps"]
        self.assertEqual(sorted(record["checkpoints"]), ["before", "settled"])
        self.assertEqual({k: sorted(v) for k, v in record["sideChannels"].items()},
                         {"blocking": ["after", "before"], "hangs": ["after", "before"],
                          "actionBudget": ["after", "before"], "wakeups": ["idle", "settled"]})
        methods = [m for m, _ in app.calls]
        blocking = [i for i, m in enumerate(methods) if m == "debug.blocking"]
        wakeups = [i for i, m in enumerate(methods) if m == "debug.wakeups"]
        settle = max(i for i, m in enumerate(methods) if m == driver_app.SETTLE)
        captures = [i for i, (m, p) in enumerate(app.calls) if m == driver_app.SNAPSHOT and "facets" in p]
        self.assertLess(captures[0], blocking[0], "the before capture is not part of the step")
        self.assertLess(blocking[0], methods.index("action.run"))
        self.assertLess(settle, blocking[1], "the after readings follow the settle")
        self.assertLess(blocking[1], captures[1], "and come before the settled capture")
        self.assertLess(wakeups[0], captures[1])
        self.assertLess(captures[1], wakeups[1], "the idle window spans the settled capture")
        hangs = [p for m, p in app.calls if m == "debug.hangs"]
        self.assertEqual(hangs, [{"limit": 1}, {"after": 2, "limit": driver_app.HANGS_AFTER_LIMIT}])
        report = self.check(trace)
        self.assertEqual([report.checked[i] for i in ("I11", "I12", "I13", "I14", "I15")], [1, 1, 1, 1, 1])
        self.assertEqual(report.perf_queue, [])
        self.assertEqual([(v.invariant, v.pointer) for v in report.violations if v.invariant == "I15"],
                         [("I15", "/daemonResources/threads")])

    def test_a_slow_step_gives_one_perf_queue_line_per_side_channel(self) -> None:
        def slow(app):
            app.blocks_per_turn, app.commit_ms, app.stall_ms = 1, 14.0, 400.0
            app.left_clients = ["Motion.clock"]

        session = self.session(trace=True)
        slow(self.apps[0])
        result = session.run_case(case(self.TRACED), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        report = self.check(result["trace"])
        self.assertEqual([(v.invariant, v.step, v.source, v.pointer) for v in report.perf_queue],
                         [("I11", "new", "debug.blocking", "/sideChannels/blocking/after/sites/0"),
                          ("I12", "new", "debug.hangs", "/sideChannels/hangs/after/records/0"),
                          ("I13", "new", "debug.action_budget", "/sideChannels/actionBudget/after/recent/0"),
                          ("I14", "new", "debug.wakeups", "/sideChannels/wakeups/idle/active_frame_clients/0")])
        self.assertEqual([v.invariant for v in report.violations if v.invariant in ("I11", "I12", "I13", "I14")], [])
        self.assertIn("I15", [n.invariant for n in report.not_checked], "no daemon counts were read")

    def test_a_recorder_case_reads_no_side_channel(self) -> None:
        session, result, _ = self.traced_run(case(NEW_WORKSPACE))
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("debug.blocking", [m for m, _ in self.apps[0].calls])
        self.assertTrue(result["trace"]["recorderArmed"])
        self.assertNotIn("sideChannels", result["trace"]["steps"][0])
        report = self.check(result["trace"])
        self.assertIn("debug.oracle.recorder", next(n.reason for n in report.not_checked if n.invariant == "I11"))

    def test_a_refused_side_channel_is_recorded_and_not_checked(self) -> None:
        session = self.session(trace=True)
        self.apps[0].m_debug_blocking = lambda p: {"ok": False, "error": {"code": "method_not_found"}}
        result = session.run_case(case(self.TRACED), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        reading = result["trace"]["steps"][0]["sideChannels"]["blocking"]["before"]
        self.assertEqual(reading, {"error": {"code": "method_not_found"}})
        report = self.check(result["trace"])
        self.assertEqual(report.checked["I11"], 0)
        self.assertEqual(report.checked["I13"], 1)

    def test_an_untraced_run_reads_no_side_channel_and_writes_no_trace(self) -> None:
        session = self.session()
        result = session.run_case(case(self.TRACED), {"case_id": "actions/c"})
        self.assertNotIn("trace", result)
        self.assertFalse({"debug.blocking", "debug.hangs", "debug.action_budget", "debug.wakeups"}
                         & {m for m, _ in self.apps[0].calls})

    def test_run_case_trace_writes_each_attempts_trace(self) -> None:
        ctx = {"run_id": "r", "product": "app", "build": "bench", "binary": APP, "out_dir": self.tmp.name}
        lines: List[str] = []
        opened: List[Dict[str, Any]] = []

        def open_session(c):
            opened.append(c)
            return self.session(**{k: v for k, v in c.items() if k not in ctx})

        out = Path(self.tmp.name) / "traces"
        driver_app.run_repeats(ctx, case(self.TRACED), 2, open_session=open_session, emit=lines.append, trace_dir=out)
        self.assertEqual([c["trace"] for c in opened], [True, True])
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["0.trace.json", "1.trace.json"])
        self.assertEqual(json.loads((out / "0.trace.json").read_text())["schema"], "cmux.oracle.trace/v1")

    def test_results_pass_oracle_protocol_checks(self) -> None:
        session = self.session()
        result = oracle.coerce_result(session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"}))
        self.assertEqual(result["status"], "Pass")
        self.assertEqual(len(result["checkpoints"]), 3)


class SwitchArmsTest(SessionTestBase):
    """p15-oracle-049: the app driver applies the run's arms and reads them back before any step."""

    def registry(self) -> "driver_app.switches.Roots":
        sw = driver_app.switches
        return sw.selftest_tree(Path(self.tmp.name) / "registry", {"layer-hosting": sw.selftest_entry(),
                                                                   "holder": sw.daemon_entry()}, None)

    def arms_session(self, arms: Dict[str, str], *, app_arms: Optional[Dict[str, str]],
                     daemon: Optional[Any] = None, hits: bool = True) -> driver_app.AppSession:
        """A session on the test registry; `daemon` is the tag daemon's arm sources (an Exception: the read
        fails; None: no daemon of the tag runs)."""

        def read_daemon_arms(path: str) -> Mapping[str, Any]:
            if isinstance(daemon, Exception):
                raise daemon
            return daemon

        session = self.session(switch_roots=self.registry(), switches=arms, read_daemon_arms=read_daemon_arms,
                               read_daemon=lambda path, doc: {"session": {}, "settings": {}})
        fake = self.apps[-1]
        fake.switch_arms = app_arms
        fake.hits = {"browser.layer-hosting": {"old": 0, "new": 0}} if hits else None
        fake.daemon_sock = "/tmp/oracle-t/daemon.sock" if daemon is not None else None
        return session

    def refused(self, session: driver_app.AppSession, want: str) -> "driver_app.switches.ArmNotApplied":
        with self.assertRaises(driver_app.switches.ArmNotApplied) as caught:
            session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertIn(want, str(caught.exception))
        self.assertTrue(str(caught.exception).startswith("arm-not-applied: "), caught.exception)
        self.assertFalse([m for m, _ in self.apps[-1].calls if m == "action.run"], "no step ran")
        return caught.exception

    def test_both_app_arms_are_applied_and_read_back(self) -> None:
        for arm in ("old", "new"):
            session = self.arms_session({"layer-hosting": arm}, app_arms={"browser.layer-hosting": arm, "holder": "old"})
            fake = self.apps[-1]
            self.assertEqual(fake.env["CMUX_NEXT_SWITCHES"], f"browser.layer-hosting={arm}")
            self.assertNotIn("CMUX_NEXT_TUI_SWITCHES", fake.env, "no daemon switch was requested")
            fake.hits["browser.layer-hosting"][arm] = 7  # startup and the first window, before the first case
            result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
            self.assertEqual(result["status"], "Pass", result["message"])
            self.assertEqual(result["switch_readback"], {"layer-hosting": arm, "holder": "old"})
            other = "new" if arm == "old" else "old"
            self.assertEqual(result["switch_hits"], {"layer-hosting": {arm: 1, other: 0}})
            self.assertEqual(result["launch_switch_hits"], {"layer-hosting": {arm: 7, other: 0}})
            coerced = oracle.coerce_result(result)
            self.assertEqual(coerced["switch_hits"], {"layer-hosting": {arm: 1, other: 0}})
            self.assertEqual(coerced["switch_readback"], {"layer-hosting": arm, "holder": "old"})
            again = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
            self.assertNotIn("launch_switch_hits", again, "a launch's hits are carried once")

    def test_hits_between_two_cases_count_for_the_next_case(self) -> None:
        session = self.arms_session({"layer-hosting": "new"}, app_arms={"browser.layer-hosting": "new"})
        fake = self.apps[-1]
        self.assertEqual(session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})["switch_hits"],
                         {"layer-hosting": {"old": 0, "new": 1}})
        fake.hits["browser.layer-hosting"]["new"] += 2  # work that lands after the first case's read
        self.assertEqual(session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})["switch_hits"],
                         {"layer-hosting": {"old": 0, "new": 3}})

    def test_a_site_hit_only_at_launch_exercises_the_arm(self) -> None:
        session = self.arms_session({"layer-hosting": "new"}, app_arms={"browser.layer-hosting": "new"})
        self.apps[-1].hits["browser.layer-hosting"]["new"] = 5  # CEFEngine.start-like: once, at startup
        tmp = Path(self.tmp.name)
        cases = [oracle.Case(f"actions/c{i}", "actions", tmp / f"c{i}.json", case(id=f"c{i}")) for i in range(3)]
        options = oracle.RunOptions(
            product="app", suites=("all",), filters=(), shard=(0, 1), jobs=1, batch_limit=10, repeat=1, retry_limit=0,
            seed=None, platform="mac", build="bench", switch="layer-hosting", arm="new", switches={"layer-hosting": "new"},
            ref=SHA, tag=None, binary=APP, corpus=tmp, out=tmp / "run", state_base=tmp / "state", run_id="r",
            isolation="none")
        receipt, code = oracle.perform_run(options, cases, lambda ctx: session, None, {})
        self.assertEqual(code, 0, receipt)
        self.assertEqual(receipt["switch_hits"], {"layer-hosting": {"old": 0, "new": 5}})
        self.assertEqual(receipt["launch_switch_hits"], {"layer-hosting": {"old": 0, "new": 5}})
        self.assertTrue(receipt["arm_exercised"])
        self.assertTrue(receipt["arm_applied"])
        self.assertEqual(receipt["switch_readback"], {"layer-hosting": {"new": 3}})
        self.assertEqual(receipt["cases"]["actions/c0"]["switch_readback"], {"layer-hosting": "new"})
        self.assertIsNone(receipt["arm_not_applied"])

    def test_one_arm_mismatch_stops_the_run_after_one_launch(self) -> None:
        opened: List[driver_app.AppSession] = []

        def open_session(ctx):
            opened.append(self.arms_session({"layer-hosting": "new"}, app_arms={"browser.layer-hosting": "old"}))
            return opened[-1]

        tmp = Path(self.tmp.name)
        cases = [oracle.Case(f"actions/c{i}", "actions", tmp / f"c{i}.json", case(NEW_WORKSPACE, id=f"c{i}"))
                 for i in range(4)]
        options = oracle.RunOptions(
            product="app", suites=("all",), filters=(), shard=(0, 1), jobs=1, batch_limit=2, repeat=1, retry_limit=3,
            seed=None, platform="mac", build="bench", switch="layer-hosting", arm="new", switches={"layer-hosting": "new"},
            ref=SHA, tag=None, binary=APP, corpus=tmp, out=tmp / "run", state_base=tmp / "state", run_id="r",
            isolation="none")
        receipt, code = oracle.perform_run(options, cases, open_session, None, {})
        self.assertEqual(code, 1)
        self.assertEqual(len(opened), 1, "no relaunch per case")
        self.assertEqual(len(self.apps[-1].launches), 1)
        self.assertEqual(self.apps[-1].stops, 1, "the refused session is closed")
        refusal = receipt["arm_not_applied"]
        self.assertEqual((refusal["verdict"], refusal["case"], refusal["phase"]), ("arm-not-applied", "actions/c0", "run"))
        self.assertEqual(refusal["readback"], {"layer-hosting": "old"})
        self.assertIn("layer-hosting=new: snapshot.switches read back browser.layer-hosting=old", refusal["problems"][0])
        self.assertEqual(receipt["counts"], {"not-run": 4}, "no retry ran")
        self.assertFalse(receipt["arm_applied"])
        self.assertEqual(receipt["switch_readback"], {"layer-hosting": {"old": 1}})
        self.assertFalse(receipt["ok"])

    def test_the_other_arm_read_back_is_arm_not_applied_before_any_step(self) -> None:
        session = self.arms_session({"layer-hosting": "new"}, app_arms={"browser.layer-hosting": "old"})
        error = self.refused(session, "layer-hosting=new: snapshot.switches read back browser.layer-hosting=old")
        self.assertEqual(error.readback, {"layer-hosting": "old"})

    def test_a_build_without_the_switches_facet_is_arm_not_applied(self) -> None:
        self.refused(self.arms_session({"layer-hosting": "new"}, app_arms=None),
                     "no app reader in this build reports its arms")

    def test_a_default_arm_that_leaked_in_is_arm_not_applied(self) -> None:
        session = self.arms_session({"holder": "old"}, app_arms={"browser.layer-hosting": "new"},
                                    daemon={"identify": {"holder": "old"}, "oracle-state": None})
        self.refused(session, "layer-hosting=old (default): snapshot.switches read back browser.layer-hosting=new")

    def test_a_default_run_whose_build_reports_another_arm_is_arm_not_applied(self) -> None:
        session = self.arms_session({}, app_arms={"browser.layer-hosting": "new"})
        self.refused(session, "layer-hosting=old (default): snapshot.switches read back browser.layer-hosting=new")
        session = self.arms_session({}, app_arms={"browser.layer-hosting": "old"},
                                    daemon={"identify": None, "oracle-state": {"holder": "new"}})
        self.refused(session, "holder=old (default): oracle-state read back holder=new")

    def test_a_default_run_reads_both_products_and_no_hits(self) -> None:
        session = self.arms_session({}, app_arms={"browser.layer-hosting": "old"},
                                    daemon={"identify": {"holder": "old"}, "oracle-state": {"holder": "old"}})
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertEqual(result["switch_readback"], {"holder": "old", "layer-hosting": "old"})
        self.assertFalse([m for m, _ in self.apps[-1].calls if m == driver_app.SWITCH_HITS])
        session = self.arms_session({}, app_arms=None)  # a build with no readers: nothing to compare
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("switch_readback", result)

    def test_an_empty_registry_reads_no_arms(self) -> None:
        session = self.session()
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertFalse([p for m, p in self.apps[-1].calls if m == driver_app.SNAPSHOT and p.get("facets") == ["switches"]])

    def test_daemon_arms_reach_the_app_daemon_and_read_back(self) -> None:
        for arm in ("old", "new"):
            session = self.arms_session({"holder": arm}, app_arms={},
                                        daemon={"identify": {"holder": arm}, "oracle-state": {"holder": arm}})
            fake = self.apps[-1]
            self.assertEqual(fake.env["CMUX_NEXT_TUI_SWITCHES"], f"holder={arm}")
            self.assertNotIn("CMUX_TUI_SWITCHES", fake.env, "the app's launch strip would unset it")
            self.assertNotIn("CMUX_NEXT_SWITCHES", fake.env)
            result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
            self.assertEqual(result["status"], "Pass", result["message"])
            self.assertEqual(result["switch_readback"], {"holder": arm})

    def test_a_daemon_on_the_other_arm_missing_or_unreadable_is_arm_not_applied(self) -> None:
        error = self.refused(self.arms_session({"holder": "new"}, app_arms={},
                                               daemon={"identify": None, "oracle-state": {"holder": "old"}}),
                             "holder=new: oracle-state read back holder=old")
        self.assertEqual(error.readback, {"holder": "old"})
        self.refused(self.arms_session({"holder": "new"}, app_arms={}), "holder: no cmux-tui of this tag is running")
        self.refused(self.arms_session({}, app_arms={}, daemon=RuntimeError("oracle-state gave no switches")),
                     "daemon switch readback from /tmp/oracle-t/daemon.sock: RuntimeError('oracle-state gave no switches')")

    def test_a_build_without_hit_counters_reports_no_hits(self) -> None:
        session = self.arms_session({"layer-hosting": "new"}, app_arms={"browser.layer-hosting": "new"}, hits=False)
        result = session.run_case(case(NEW_WORKSPACE), {"case_id": "actions/c"})
        self.assertEqual(result["status"], "Pass", result["message"])
        self.assertNotIn("switch_hits", result, "oracle.py then reports arm-not-exercised")
        self.assertNotIn("launch_switch_hits", result)

    def test_run_case_with_an_unknown_switch_exits_2_before_any_launch(self) -> None:
        import io
        from contextlib import redirect_stderr

        path = Path(self.tmp.name) / "case.json"
        path.write_text(json.dumps(case(NEW_WORKSPACE)), encoding="utf-8")
        err = io.StringIO()
        with redirect_stderr(err):
            code = driver_app.main(["run-case", str(path), "--app", APP, "--switch", "ghost=new"])
        self.assertEqual(code, 2)
        self.assertIn("unknown switch: ghost", err.getvalue())
        with redirect_stderr(err):
            self.assertEqual(driver_app.main(["run-case", str(path), "--app", APP, "--switch", "ghost"]), 2)
        self.assertIn("is not NAME=ARM", err.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
