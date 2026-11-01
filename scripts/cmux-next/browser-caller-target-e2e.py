#!/usr/bin/env python3
"""#26648 with two windows: an agent's `cmux browser` commands drive the browser in its own
workspace, not the person's focused browser in another window.

Window A (the app's first window, which keeps its focus: the bench app never activates) holds
the person's workspace with a focused browser tab ("front"). Window B holds the agent's
workspace: its terminal and a browser tab beside it ("own"). The pages come from a local HTTP
server (cmux refuses data: URLs). With focus on the front browser, the real `cmux` CLI run as
that terminal (CMUX_TUI_TERMINAL_ID) must answer for the own tab: `browser page state`, `browser page eval`, `identify` (`browser`) and the
daemon form `browser show` (a `current` browser). The same `browser page state` with no
caller keeps the focused tab. Then the own browser closes: the agent's call is refused
rather than run on the front browser.

With --app it launches that tagged app through bench_launch.BenchApp (CMUX_NEXT_NO_ACTIVATE:
it never takes the display) and quits it at the end; with --socket it attaches to a running one
($NX_APP_SOCKET, $NX_APP_CLI) and never launches or quits it. The CLI runs with the
environment a cmux terminal gives its shell (CMUX_SOCKET_PATH, CMUX_TAG, CMUX_TUI_TERMINAL_ID).
Writes steps.json and verdict.json to --out; exit 0 when every check holds.
Usage: browser-caller-target-e2e.py (--app APP | --socket SOCKET) --out DIR
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket")
parser.add_argument("--app")
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
steps = []
launcher = None
if opts.app:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_launch import BenchApp
    launcher = BenchApp(opts.app, out=opts.out, window=(40, 40, 1100, 800))
    launcher.launch(timeout=180)
    opts.socket, TAG = launcher.socket, launcher.tag
    CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
else:
    CLI, TAG = os.environ["NX_APP_CLI"], os.environ["NX_APP_TAG"]


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def cli(args, terminal=None):
    """The real cmux CLI against this app, as the given terminal (or with no caller)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_") and k not in ("CLAUDECODE",)}
    if terminal:
        env["CMUX_TUI_TERMINAL_ID"] = terminal
    env.update({"CMUX_SOCKET_PATH": opts.socket, "CMUX_TAG": TAG, "CMUX_QUIET": "1"})
    command = [CLI, "--json"] + args
    run = subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
    try:
        value = json.loads(run.stdout) if run.stdout.strip() else None
    except ValueError:
        value = run.stdout
    steps.append({"cli": args, "terminal": terminal, "exit": run.returncode, "out": value, "err": run.stderr[-2000:]})
    return run.returncode, value, run.stderr


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def topology():
    snap = rpc("snapshot.get") or {}
    return snap.get("topology") or {}


def is_ws(workspace, wid):
    return wid is not None and wid in (workspace.get("id"), workspace.get("resource_id"), workspace.get("resourceID"), workspace.get("public_id"))


def tabs(top):
    for workspace in top.get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    yield workspace, pane, tab


def run(action, target=None, args=None, focus=False):
    params = {"action": action, "wait": True, "focus": focus}
    if target:
        params["target"] = target
    if args:
        params["args"] = args
    result = rpc("action.run", params, timeout=60)
    steps.append({"action": action, "target": target, "result": result})
    return result


import http.server, threading


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        title = self.path.strip("/") or "blank"
        body = ("<title>%s</title><h1>%s</h1>" % (title, title)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()


def page(title):
    return "http://127.0.0.1:%d/%s" % (server.server_address[1], title)


checks = {}
def finish(code):
    if launcher:
        launcher.stop()
    sys.exit(code)


if not wait(lambda: (rpc("system.ping") or {}).get("error") is None and topology().get("loaded"), 60):
    print("app never answered", file=sys.stderr)
    finish(2)
wait(lambda: any(t.get("kind") == "terminal" for _, _, t in tabs(topology())), 60)

# The first window is the agent's (window B): a new workspace there ("newTab" is New Workspace) with
# its terminal, and a browser tab beside it.
def created(result):
    return ((result or {}).get("created") or [None])[0]


def timed_out(result):
    """An action.run answer that only says the app did not finish in time (a socket error is a string)."""
    error = result.get("error") if isinstance(result, dict) else None
    return (isinstance(error, str) and "timed out" in error) or (
        isinstance(error, dict) and error.get("code") == "timeout"
    )


def again(action, **kw):
    """The action, asked again while the app answers only that it did not finish in time."""
    for _ in range(5):
        result = run(action, **kw)
        if not timed_out(result):
            return result
    return result


def dump(label):
    steps.append({"dump": label, "focus": topology().get("focus"), "windows": topology().get("windows"),
                  "tabs": [(w.get("id"), w.get("name"), p.get("id"), t.get("id"), t.get("kind"), t.get("terminal"), t.get("title"))
                           for w, p, t in tabs(topology())]})


# The first window is the person's (window A): it keeps the app's focus (the bench app never
# activates, so focus stays with the window it started in). A workspace there with a terminal and
# the front browser beside it, focused.
term = lambda ws: next((t for w, _, t in tabs(topology()) if is_ws(w, ws) and t.get("kind") == "terminal" and t.get("terminal")), None)
browser_in = lambda ws: next((t for w, _, t in tabs(topology()) if is_ws(w, ws) and t.get("kind") == "browser"), None)
window_a = topology()["windows"][0]["id"]
front_ws_id = created(again("newTab"))
front_term = wait(lambda: term(front_ws_id), 60)
again("openBrowser", target="tab:" + front_term["id"], args={"url": page("front")}) if front_term else None
front = wait(lambda: browser_in(front_ws_id), 30)
dump("after front")

# Then the agent's window (window B): a new window, a terminal split off its first tab (the agent's
# terminal), and the agent's own browser beside it.
agent_ws_id = created(run("newWindow"))
second = wait(lambda: [w for w in topology().get("windows") or [] if w["id"] != window_a], 30)
window_b = second[0]["id"] if second else None
agent_ws_id = second[0].get("workspace") if second else agent_ws_id
first = wait(lambda: next((p for w, p, t in tabs(topology()) if is_ws(w, agent_ws_id) and t["id"].startswith("tab_")), None), 30)
again("splitRight", target="pane:" + first["id"]) if first else None
agent = wait(lambda: term(agent_ws_id), 60)
agent_terminal = agent["terminal"] if agent else None
again("openBrowser", target="tab:" + agent["id"], args={"url": page("own")}) if agent else None
own = wait(lambda: browser_in(agent_ws_id), 30)

# The person works in window A, on the front browser.
again("tab.focus", target="tab:" + front["id"], focus=True) if front else None
focused = wait(lambda: (lambda f: f if front and f.get("tab") == front["id"] else None)(topology().get("focus") or {}), 15)
dump("after agent")
in_a = lambda wid: any(wid in (w.get("workspaces") or []) for w in topology().get("windows") or [] if w["id"] == window_a)
checks["setup"] = bool(front and own and agent_terminal and window_a and focused and in_a(front_ws_id) and not in_a(agent_ws_id))
steps.append({"front": front, "own": own, "agent_terminal": agent_terminal, "window_a": window_a, "window_b": window_b,
              "focus": topology().get("focus"), "windows": topology().get("windows")})

if checks["setup"]:
    _, state, _ = cli(["browser", "page", "state"], terminal=agent_terminal)
    checks["page_state_is_own"] = isinstance(state, dict) and state.get("tab") == own["id"]
    _, title, _ = cli(["browser", "page", "eval", "document.title"], terminal=agent_terminal)
    checks["page_eval_is_own"] = isinstance(title, dict) and title.get("value") == "own"
    _, identity, _ = cli(["identify"], terminal=agent_terminal)
    checks["identify_reports_own"] = isinstance(identity, dict) and (identity.get("browser") or {}).get("tab") == own["id"]
    _, shown, _ = cli(["browser", "show"], terminal=agent_terminal)
    shown_text = json.dumps(shown)
    checks["daemon_current_is_own"] = own["id"] in shown_text and front["id"] not in shown_text
    _, plain, _ = cli(["browser", "page", "state"])
    checks["no_caller_keeps_focus"] = isinstance(plain, dict) and plain.get("tab") == front["id"]
    # No browser near the agent: refused, never the front one.
    run("closeTab", target="tab:" + own["id"])
    wait(lambda: not any(t["id"] == own["id"] for _, _, t in tabs(topology())), 15)
    dump("after close")
    code, refused, err = cli(["browser", "page", "state"], terminal=agent_terminal)
    checks["refused_without_own"] = code != 0 and front["id"] not in json.dumps(refused) + err

verdict = {"pass": all(checks.values()), "checks": checks}
json.dump(steps, open(os.path.join(opts.out, "steps.json"), "w"), indent=2)
json.dump(verdict, open(os.path.join(opts.out, "verdict.json"), "w"), indent=2)
print(json.dumps(verdict, indent=2))
finish(0 if verdict["pass"] else 1)
