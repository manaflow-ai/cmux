#!/usr/bin/env python3
"""#26648 with two windows: an agent's `cmux browser` commands drive the browser in its own
workspace, not the person's focused browser in another window.

Window A holds the person's workspace with a focused browser tab ("front"). Window B holds
the agent's workspace: its terminal and a browser tab beside it ("own"). With focus on the
front browser, the real `cmux` CLI run as that terminal (CMUX_TUI_TERMINAL_ID) must answer
for the own tab: `browser page state`, `browser page eval`, `identify` (`browser`) and the
daemon form `browser show` (a `current` browser). The same `browser page state` with no
caller keeps the focused tab. Then the own browser closes: the agent's call is refused
rather than run on the front browser.

Attaches to a running tagged app (never launches or quits it); writes steps.json and
verdict.json to --out. Exit 0 when every check holds.
Usage: browser-caller-target-e2e.py --socket "$NX_APP_SOCKET" --out DIR
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CLI, TAG = os.environ["NX_APP_CLI"], os.environ["NX_APP_TAG"]
steps = []


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
    command = [CLI, "--app-socket", opts.socket, "--session", "cmux-app-%s" % TAG, "--json"] + args
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


def page(title):
    return "data:text/html,<title>%s</title><h1>%s</h1>" % (title, title)


checks = {}
if not wait(lambda: (rpc("system.ping") or {}).get("error") is None and topology().get("loaded"), 60):
    print("app never answered", file=sys.stderr)
    sys.exit(2)
wait(lambda: any(t.get("kind") == "terminal" for _, _, t in tabs(topology())), 60)

# Window A: the person's workspace and its first terminal; a browser tab there.
top = topology()
window_a = top["windows"][0]["id"]
front_ws, _, front_term = next((w, p, t) for w, p, t in tabs(top) if t.get("kind") == "terminal")
run("openBrowser", target="tab:" + front_term["id"], args={"url": page("front")})
front = wait(lambda: next((t for _, _, t in tabs(topology()) if t.get("kind") == "browser"), None), 30)

# Window B: a new window, its workspace's terminal is the agent's; a browser tab beside it.
run("newWindow")
second = wait(lambda: [w for w in topology().get("windows") or [] if w["id"] != window_a], 30)
window_b = second[0]["id"] if second else None
agent_ws_id = second[0].get("workspace") if second else None
agent = wait(lambda: next((t for w, _, t in tabs(topology()) if w["id"] == agent_ws_id and t.get("kind") == "terminal"
                           and t.get("terminal")), None), 60)
agent_terminal = agent["terminal"] if agent else None
run("openBrowser", target="tab:" + agent["id"], args={"url": page("own")}) if agent else None
own = wait(lambda: next((t for w, _, t in tabs(topology()) if w["id"] == agent_ws_id and t.get("kind") == "browser"), None), 30)

# The person works in window A, on the front browser.
run("tab.focus", target="tab:" + front["id"], focus=True)
focused = wait(lambda: (lambda f: f if f.get("tab") == front["id"] else None)(topology().get("focus") or {}), 15)
checks["setup"] = bool(front and own and agent_terminal and window_b and focused)
steps.append({"front": front, "own": own, "agent_terminal": agent_terminal, "window_a": window_a, "window_b": window_b,
              "focus": topology().get("focus")})
subprocess.run(["screencapture", "-x", os.path.join(opts.out, "two-windows.png")], check=False)

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
    code, refused, err = cli(["browser", "page", "state"], terminal=agent_terminal)
    checks["refused_without_own"] = code != 0 and front["id"] not in json.dumps(refused) + err

verdict = {"pass": all(checks.values()), "checks": checks}
json.dump(steps, open(os.path.join(opts.out, "steps.json"), "w"), indent=2)
json.dump(verdict, open(os.path.join(opts.out, "verdict.json"), "w"), indent=2)
print(json.dumps(verdict, indent=2))
sys.exit(0 if verdict["pass"] else 1)
