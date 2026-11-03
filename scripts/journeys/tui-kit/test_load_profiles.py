#!/usr/bin/env python3
"""load_profiles.py against a stand-in app socket and CLI (no cmux, no fleet).

    python3 scripts/journeys/tui-kit/test_load_profiles.py

The profiles need --app-socket and refuse the shipped bundle; L1 holds its asked rate over 8 workers and
logs every call; no profile uses a focus verb or --focus, and none touches --keep except to split beside
it; the focus guard reports a focus change made during the load; L2 talks MCP (initialize, tools/call,
no tab_move to another pane); L3 makes 30 browser tabs (4 beside --keep) and navigates; L4 makes 6
agent panes; L6 runs L1..L5 at once with one LOAD-READY L6; every profile tears down what it made.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
TOOL = os.path.join(HERE, "load_profiles.py")
PY = sys.executable

FAKE_CLI = r'''
import fcntl, json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
state_path = os.path.join(here, "state.json")
log_path = os.path.join(here, "argv.jsonl")
args = sys.argv[1:]
assert args[0] == "--socket" and args[2] == "--app-socket", args
args = args[4:]
if args and args[0] == "--json":
    args = args[1:]
with open(log_path, "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["mcp", "serve"]:
    n = 0
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg:
            continue
        result = {}
        if msg["method"] == "initialize":
            result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
        elif msg["method"] == "tools/call":
            n += 1
            name = msg["params"]["name"]
            with open(log_path, "a") as log:
                log.write(json.dumps(["mcp-tool", name, msg["params"]["arguments"]]) + "\n")
            allowed = {"workspace_list", "tab_list", "terminal_screen_read", "browser_list", "notification_list",
                       "browser_profile_open", "tab_move"}
            if name not in allowed:
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"isError": True,
                                 "content": [{"type": "text", "text": "unknown tool " + name}]}}) + "\n")
                sys.stdout.flush()
                continue
            value = {"tab_id": "tab_mcp%d_%d" % (os.getpid(), n)} if name == "browser_profile_open" else {}
            result = {"content": [{"type": "text", "text": json.dumps({"value": value})}], "structuredContent": {"value": value}}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n")
        sys.stdout.flush()
    sys.exit(0)
import re
GRAMMAR = [  # the CLI shapes the profiles may use (topology_help.rs, scope_help.rs, app/page.rs)
    r"workspace create --name \S+( -- .+)?", r"workspace ws_\w+ (close|focus)",
    r"workspace ws_\w+ status set \S+ .+", r"workspace ws_\w+ progress set [0-9.]+ --label \S+",
    r"workspace ws_\w+ log append .+ --level info --source \S+", r"workspace list",
    r"pane list --workspace ws_\w+", r"pane pane_\w+ close",
    r"pane pane_\w+ split (--right|--down) --ratio [0-9.]+( -- .+)?",
    r"tab list --pane pane_\w+", r"tab tab_\w+ close",
    r"tab create terminal (--workspace ws_\w+ )?--pane pane_\w+( --name \S+)?( -- .+)?",
    r"tab create browser --pane pane_\w+ --url \S+",
    r"terminal list --pane pane_\w+", r"terminal term_\w+ write --text .+", r"terminal term_\w+ screen read",
    r"notify --title .+ --body .+ --workspace ws_\w+ --desktop false",
    r"browser tab_\w+ (navigate \S+|click \S+|snapshot|eval .+)",
]
line = " ".join(args).replace("\n", " ")
if not any(re.fullmatch(g, line, re.S) for g in GRAMMAR):
    print("stand-in CLI: not a known command shape: " + line, file=sys.stderr)
    sys.exit(64)
if os.path.exists(os.path.join(here, "fail-split-3")) and args[:1] == ["pane"] and "split" in args:
    count_path = os.path.join(here, "splits")
    count = int(open(count_path).read()) + 1 if os.path.exists(count_path) else 1
    open(count_path, "w").write(str(count))
    if count == 3:
        print("split refused", file=sys.stderr); sys.exit(1)
lock = open(state_path + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
state = json.load(open(state_path)) if os.path.exists(state_path) else {"n": 0, "workspaces": [], "focus": {}}
argv = args[args.index("--") + 1:] if "--" in args else None
head = args[:args.index("--")] if "--" in args else args
def new(prefix):
    state["n"] += 1
    return "%s_%d" % (prefix, state["n"])
def pane_of(pid):
    for ws in state["workspaces"]:
        for p in ws["panes"]:
            if p["id"] == pid:
                return ws, p
    print("no pane " + pid, file=sys.stderr); sys.exit(3)
def opt(name):
    return head[head.index(name) + 1]
value = {}
steal = os.path.exists(os.path.join(here, "steal-focus"))
if head[:2] == ["workspace", "create"]:
    ws = {"id": new("ws"), "name": opt("--name"), "panes": []}
    pane = {"id": new("pane"), "tabs": [{"id": new("tab"), "kind": "terminal"}]}
    ws["panes"].append(pane); state["workspaces"].append(ws)
    value = {"workspace_id": ws["id"], "pane_id": pane["id"], "tab_id": pane["tabs"][0]["id"], "terminal_id": new("term")}
elif len(head) > 2 and head[0] == "pane" and head[2] == "split":
    ws, _ = pane_of(head[1])
    pane = {"id": new("pane"), "tabs": [{"id": new("tab"), "kind": "terminal"}], "split": head[3:]}
    ws["panes"].append(pane)
    value = {"workspace_id": ws["id"], "pane_id": pane["id"], "tab_id": pane["tabs"][0]["id"], "terminal_id": new("term")}
elif len(head) > 2 and head[0] == "pane" and head[2] == "close":
    for ws in state["workspaces"]:
        ws["panes"] = [p for p in ws["panes"] if p["id"] != head[1]]
elif head[:2] == ["tab", "create"]:
    ws, pane = pane_of(opt("--pane"))
    tab = {"id": new("tab"), "kind": head[2]}
    pane["tabs"].append(tab)
    value = {"tab_id": tab["id"], ("browser_id" if head[2] == "browser" else "terminal_id"): new(head[2][:4])}
    if steal:
        state["focus"] = {"pane": pane["id"], "workspace": ws["id"]}
elif len(head) > 2 and head[0] == "tab" and head[2] == "close":
    for ws in state["workspaces"]:
        for p in ws["panes"]:
            p["tabs"] = [t for t in p["tabs"] if t["id"] != head[1]]
elif len(head) > 2 and head[0] == "workspace" and head[2] == "close":
    state["workspaces"] = [w for w in state["workspaces"] if w["id"] != head[1]]
elif len(head) > 2 and head[0] == "workspace" and head[2] == "focus":
    state["focus"] = {"workspace": head[1]}
with open(state_path + ".tmp", "w") as f:
    json.dump(state, f)
os.replace(state_path + ".tmp", state_path)
print(json.dumps({"value": value, "generation": 1, "revision": state["n"]}))
'''


class FakeApp:
    def __init__(self, folder, bundle="com.cmuxterm.app.debug.test", keep_ws=True):
        self.folder = folder
        self.path = os.path.join(folder, "app.sock")
        self.state = os.path.join(folder, "state.json")
        self.bundle = bundle
        self.methods = []
        with open(self.state, "w") as f:  # the person's workspace with the typing pane, focused
            json.dump({"n": 1000, "focus": {"workspace": "ws_person", "pane": "pane_keep", "tab": "tab_keep"},
                       "workspaces": [{"id": "ws_person", "name": "person", "panes": [
                           {"id": "pane_keep", "tabs": [{"id": "tab_keep", "kind": "terminal"}]}]}]}, f)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(64)
        self.closing = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def read_state(self):
        for _ in range(20):
            try:
                with open(self.state) as f:
                    return json.load(f)
            except ValueError:
                time.sleep(0.01)
        return {"workspaces": [], "focus": {}}

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            if self.closing:
                conn.close()
                return
            threading.Thread(target=self.answer_conn, args=(conn,), daemon=True).start()

    def answer_conn(self, conn):
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
        try:
            req = json.loads(buf)
            self.methods.append((req["method"], req.get("params") or {}))
            conn.sendall((json.dumps(self.answer(req["method"], req.get("params") or {})) + "\n").encode())
        except (ValueError, OSError):
            pass
        conn.close()

    def answer(self, method, params):
        if method == "system.identify":
            return {"ok": True, "result": {"pid": os.getpid(), "bundle_id": self.bundle}}
        if method == "debug.daemon":
            return {"ok": True, "result": {"pid": None}}
        if method == "snapshot.get":
            st = self.read_state()
            return {"ok": True, "result": {"topology": {"focus": st.get("focus"), "windows": [{"id": "w1", "key_window": True}],
                    "workspaces": [{"id": w["id"], "name": w["name"], "screens": [{"id": "s", "panes": [
                        {"id": p["id"], "tabs": [{"id": t["id"], "kind": t["kind"]} for t in p["tabs"]]}
                        for p in w["panes"]]}]} for w in st["workspaces"]]}}}
        if method == "debug.focus":
            return {"ok": True, "result": {"key_window": "w1", "windows": [{"appkit": {"first_responder": "GhosttyView"}}]}}
        if method == "action.run":
            action, target = params.get("action"), str(params.get("target", ""))
            if action == "toggleBrowserDeveloperTools":
                if not target.startswith("pane:"):  # targets: [.pane] (BrowserActionCatalog.swift)
                    return {"ok": False, "error": {"code": "invalid_target"}}
                return {"ok": False, "error": {"code": "unavailable", "message": "no focused web view"}}
            return {"ok": False, "error": {"code": "unavailable"}}
        if method == "debug.agent_pane":
            return {"ok": False, "error": {"code": "unknown"}}
        return {"ok": False, "error": {"code": "unknown_method"}}

    def close(self):
        self.closing = True
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as poke:
                poke.connect(self.path)
        except OSError:
            pass
        self.thread.join(5)
        self.server.close()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tk-load-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cli = os.path.join(self.tmp, "cmux")
        with open(self.cli, "w") as f:
            f.write("#!%s\n%s" % (PY, FAKE_CLI))
        os.chmod(self.cli, 0o755)

    def app(self, **kw):
        app = FakeApp(self.tmp, **kw)
        self.addCleanup(app.close)
        return app

    def run_tool(self, profile, *extra, timeout=120, app=None):
        app = app or self.app()
        out = os.path.join(self.tmp, "out")
        argv = [PY, TOOL, "run", profile, "--app-socket", app.path, "--socket", "/x/daemon.sock", "--cli", self.cli,
                "--app", os.path.join(self.tmp, "X.app"), "--home", self.tmp, "--out", out, "--seed", "3"] + list(extra)
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return done, out, app

    def argv_log(self):
        path = os.path.join(self.tmp, "argv.jsonl")
        with open(path) as f:
            return [json.loads(line) for line in f]

    def manifest(self, out, profile):
        with open(os.path.join(out, profile, "manifest.json")) as f:
            return json.load(f)

    def assert_no_focus_verbs(self):
        for args in self.argv_log():
            flat = [str(x) for x in args]
            self.assertNotIn("--focus", flat, args)
            self.assertFalse(len(flat) > 2 and flat[2] == "focus", args)
            self.assertFalse(flat[:3] == ["pane", "pane_keep", "close"], args)
            self.assertNotIn("activate", flat[:3], args)
            if flat[0] == "terminal":
                self.assertNotIn("tab_keep", flat)

    def assert_torn_down(self, app):
        st = app.read_state()
        self.assertEqual([w["id"] for w in st["workspaces"]], ["ws_person"], st)
        self.assertEqual([p["id"] for p in st["workspaces"][0]["panes"]], ["pane_keep"], st)


class Reach(Base):
    def test_app_socket_is_required(self):
        done = subprocess.run([PY, TOOL, "run", "L1"], capture_output=True, text=True, timeout=20)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--app-socket is required", done.stderr)

    def test_shipped_bundle_is_refused(self):
        done, _, app = self.run_tool("L1", "--duration", "1", app=self.app(bundle="com.cmuxterm.app"))
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("LOAD-REFUSED L1", done.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "argv.jsonl")), "no CLI call at all")


class StormL1(Base):
    def test_rate_mix_focus_and_teardown(self):
        done, out, app = self.run_tool("L1", "--duration", "3", "--rate", "60", "--keep", "pane_keep")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertRegex(done.stdout, r"LOAD-READY L1 t_mono=\d")
        m = self.manifest(out, "L1")
        self.assertFalse(m["focus_changed"])
        self.assertEqual(m["refusals"], [])
        calls = m["calls"]
        self.assertTrue(40 <= calls["achieved_per_s"] <= 75, calls)  # 60 asked; process start-up on a busy host
        self.assertEqual(calls["asked_per_s"], 60)
        self.assertIn("ok_per_s", calls)
        self.assertEqual(calls["failed"], 0, calls)
        for kind in ("workspace.list", "terminal.write", "screen.read", "status.set", "log.append"):
            self.assertIn(kind, calls["by_kind"])
        workers = set()
        with open(os.path.join(out, "L1", "calls.jsonl")) as f:
            for line in f:
                workers.add(json.loads(line)["worker"])
        self.assertEqual(workers, set(range(8)))
        self.assert_no_focus_verbs()
        self.assert_torn_down(app)

    def test_focus_change_is_reported(self):
        open(os.path.join(self.tmp, "steal-focus"), "w").close()  # the stand-in moves focus on tab create
        done, out, _ = self.run_tool("L1", "--duration", "3", "--rate", "60")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        m = self.manifest(out, "L1")
        self.assertTrue(m["focus_changed"])
        with open(os.path.join(out, "L1", "focus.jsonl")) as f:
            events = [json.loads(line)["ev"] for line in f]
        self.assertEqual(events[0], "baseline")
        self.assertIn("change", events)


class Safety(Base):
    def test_failed_split_beside_keep_leaves_nothing(self):
        open(os.path.join(self.tmp, "fail-split-3"), "w").close()
        done, out, app = self.run_tool("L3", "--duration", "1", "--keep", "pane_keep")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        m = self.manifest(out, "L3")
        self.assertEqual(len([p for p in m["made"]["panes"]]), 2, "the two panes made before the refusal are recorded")
        self.assert_torn_down(app)

    def test_sigterm_during_setup_tears_down(self):
        app = self.app()
        out = os.path.join(self.tmp, "out")
        proc = subprocess.Popen([PY, TOOL, "run", "L3", "--app-socket", app.path, "--socket", "/x/d.sock", "--cli",
                                 self.cli, "--app", os.path.join(self.tmp, "X.app"), "--home", self.tmp, "--out", out,
                                 "--keep", "pane_keep", "--duration", "30"], stdout=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:  # wait until set-up made its first tabs
            if os.path.exists(os.path.join(out, "L3", "manifest.json")) and \
                    len(self.manifest(out, "L3")["made"]["tabs"]) >= 3:
                break
            time.sleep(0.05)
        proc.terminate()
        stdout, _ = proc.communicate(timeout=60)
        self.assertNotIn("LOAD-READY", stdout)
        self.assertIn("LOAD-DONE L3", stdout)
        self.assert_torn_down(app)

    def test_l6_exit_code_counts_a_killed_child(self):
        import load_profiles
        self.assertEqual(load_profiles.l6_exit({"L1": 0, "L2": -15, "L3": 0}), 1)
        self.assertEqual(load_profiles.l6_exit({"L1": 0, "L2": 0}), 0)
        self.assertEqual(load_profiles.l6_exit({"L1": 2, "L2": 1}), 2)
        self.assertEqual(load_profiles.l6_exit({}), 2)


class McpL2(Base):
    def test_clients_tools_and_no_cross_pane_move(self):
        done, out, app = self.run_tool("L2", "--duration", "2")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        m = self.manifest(out, "L2")
        self.assertEqual(m["clients"], 4)
        tools = [a for a in self.argv_log() if a[0] == "mcp-tool"]
        names = {t[1] for t in tools}
        self.assertIn("browser_profile_open", names)
        self.assertTrue({"tab_list", "terminal_screen_read", "workspace_list"} <= names, names)
        self.assertFalse(any(n.startswith("browser_repl") for n in names), "the REPL host is not on --app-socket")
        self.assertEqual(m["calls"]["failed"], 0, m["calls"])
        lanes = {w["workspace_id"]: w["pane_id"] for w in m["made"]["workspaces"]}
        for _, name, args in tools:
            if name == "browser_profile_open":
                self.assertIs(args["activate"], False)
                self.assertIn(args["pane"], lanes.values())
            if name == "tab_move":
                self.assertIn(args["destination_pane"], lanes.values())
        self.assertFalse(m["focus_changed"])
        self.assert_no_focus_verbs()
        self.assert_torn_down(app)


class BrowserL3(Base):
    def test_tabs_beside_keep_and_navigation(self):
        done, out, app = self.run_tool("L3", "--duration", "4.5", "--keep", "pane_keep", "--devtools")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        m = self.manifest(out, "L3")
        tabs = m["browser_tabs"]
        self.assertEqual(len(tabs), 30)
        self.assertEqual(sum(1 for t in tabs if t["for"].startswith("visible")), 4)
        self.assertEqual({t["for"] for t in tabs if t["for"].startswith("visible")},
                         {"visible video", "visible spa", "visible anim"})
        splits = [a for a in self.argv_log() if a[:3] == ["pane", "pane_keep", "split"]]
        self.assertEqual(len(splits), 1, "one column beside the typing pane")
        self.assertGreaterEqual(m["calls"]["by_kind"].get("browser.navigate", 0), 2)
        self.assertGreaterEqual(sum(m["calls"]["by_kind"].get("browser." + v, 0) for v in ("click", "snapshot", "eval")), 3)
        actions = [p for meth, p in app.methods if meth == "action.run"]
        self.assertEqual([p["action"] for p in actions], ["toggleBrowserDeveloperTools"], "no focus action at all")
        self.assertTrue(actions[0]["target"].startswith("pane:"))
        hidden_pane = [w["pane_id"] for w in m["made"]["workspaces"]][0]
        self.assertEqual(actions[0]["target"], "pane:" + hidden_pane)
        self.assertFalse(m["devtools"]["opened"])
        self.assertEqual(m["calls"]["failed"], 0, m["calls"])
        self.assertFalse(m["focus_changed"])
        self.assert_no_focus_verbs()
        self.assert_torn_down(app)

    def test_beside_needs_keep(self):
        done, out, _ = self.run_tool("L3", "--duration", "1")
        self.assertEqual(done.returncode, 1)
        self.assertTrue(any("needs --keep" in r["error"] for r in self.manifest(out, "L3")["refusals"]))


class AgentsL4(Base):
    def test_six_agent_panes_fall_back_to_terminal(self):
        done, out, app = self.run_tool("L4", "--duration", "1")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        m = self.manifest(out, "L4")
        self.assertEqual(len(m["agents"]), 6)
        self.assertTrue(all(a["mode"] == "terminal" and a["why"] for a in m["agents"]))
        self.assertEqual(m["agent_modes"], ["terminal"])

    def test_acp_falls_back_once_not_per_pane(self):
        start = time.monotonic()
        done, out, app = self.run_tool("L4", "--duration", "1", "--acp", timeout=200)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        m = self.manifest(out, "L4")
        self.assertEqual(len(m["agents"]), 6)
        self.assertEqual(m["agent_modes"], ["terminal"])
        # the chat is tried on the first pane only (its poll waits up to 60 s); the other 5 go straight on
        self.assertLess(time.monotonic() - start, 120)
        self.assertLessEqual(sum(1 for meth, p in app.methods if meth == "action.run"), 1)
        self.assertEqual(len([a for a in m["agents"] if a.get("why") == "the first pane's agent chat did not stream"]), 5)
        self.assert_torn_down(app)
        self.assert_no_focus_verbs()
        self.assert_torn_down(app)


class AllL6(Base):
    def test_l1_to_l5_together(self):
        done, out, app = self.run_tool("L6", "--duration", "3", "--keep", "pane_keep", "--rate", "40",
                                       "--heavy-shape", "4,12,4", timeout=300)
        self.assertEqual(done.returncode, 0, done.stdout[-3000:] + done.stderr[-2000:])
        self.assertEqual(done.stdout.count("LOAD-READY L6 "), 1)
        for name in ("L1", "L2", "L3", "L4", "L5"):
            self.assertIn("LOAD-READY %s " % name, done.stdout)
            self.assertIn("LOAD-DONE %s " % name, done.stdout)
        with open(os.path.join(out, "L6", "manifest.json")) as f:
            m = json.load(f)
        self.assertTrue(m["all_ready"])
        self.assertEqual({k: v["exit"] for k, v in m["children"].items()}, {k: 0 for k in ("L1", "L2", "L3", "L4", "L5")})
        heavy = self.manifest(os.path.join(out, "L6"), "L5")["heavy"]
        self.assertIn("--no-focus", heavy["argv"])
        self.assert_no_focus_verbs()
        self.assert_torn_down(app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
