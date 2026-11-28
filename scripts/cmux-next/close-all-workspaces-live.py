#!/usr/bin/env python3
"""Live behavior proof of Close All Workspaces (cx-5qewo, Lawrence 2026-10-14: "we need cmd shift p
close all workspaces ... make sure it all works via cmd shift p, cli, mcp etc").

Launches the tagged app itself (no activation, a scratch cmux.json with MCP on, an isolated Chief
home; it never opens Home or the Chief pane) on a GUI host, then drives every surface of the new
actions through the real product boundaries:

  palette   palette.query lists Close All Workspaces and Close All Workspaces in All Windows; the
            palette opens with the query (debug.palette.capture), and Return runs the top row: a
            terminal in the window runs `sleep`, so the close asks ("Still running: sleep");
            Cancel keeps all four workspaces.
  script    action.run without confirm is refused ("is destructive").
  cli       `cmux workspace close-all` without --confirm is refused; `close-other --confirm` and
            `close-all-in-all-windows --confirm` close.
  windows   `cmux app close-other-windows` leaves one window.
  mcp       `cmux mcp serve` lists app_workspace_close_all, the window, group, section and agent archive verbs, and app_workspace_close_all_in_all_windows,
            and tools/call app_workspace_close_all (confirm) closes the active window's workspaces.
  undo      a person's Close All Workspaces of window 1, confirmed, closes its four workspaces and
            shows "Closed 4 workspaces" with Undo in a window that stays open; Undo reopens all four.
The store's hidden home workspace never closes (home_not_closable), so the window that owns it stays.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  close-all-workspaces-live.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/proof"
Stop the app afterwards with "$NX_APP_STOP". Exit 0 only when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"closeall-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
failures = []


def check(ok, what, detail=None):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok or detail is None else f"  ({json.dumps(detail)[:300]})"), flush=True)
    if not ok:
        failures.append(what)
    return ok


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    return env


def cli(*args):
    done = subprocess.run([CLI, "--app-socket", SOCKET, *args], env=cli_env(), capture_output=True, text=True, timeout=60)
    print("cli", " ".join(args), "->", done.returncode, (done.stdout + done.stderr).strip()[-240:], flush=True)
    return done


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def windows():
    return (rpc("debug.windows") or {}).get("windows") or []


def window_ids():
    return [w.get("id") for w in windows()]


def workspace_titles():
    return [r.get("title") for w in (rpc("debug.sidebar_rows") or {}).get("windows") or [] for r in w.get("rows") or []
            if str(r.get("key", "")).startswith("workspace(")]


def toasts():
    return [t for w in (rpc("debug.toast") or {}).get("windows", []) for t in w.get("toasts", [])]


def dialogs():
    return (rpc("debug.dialog") or {}).get("dialogs", [])


def action(name, args=None, confirm=False):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if confirm:
        params["confirm"] = True
    reply = rpc("action.run", params)
    print("action", name, json.dumps(reply)[:200], flush=True)
    return reply


def shot(name):
    path = os.path.join(opts.out, f"{name}.png")
    done = subprocess.run(["bash", os.environ["NX_CAPTURE"], "shot", "--pid", str(app.pid), "--with-popups", "--out", path],
                          capture_output=True, text=True, timeout=120)
    print("shot", name, done.returncode, (done.stdout + done.stderr).strip()[-200:], flush=True)
    return done.returncode == 0


def make_workspaces(names):
    """Names the current workspace names[0], then creates one workspace per remaining name.
    Returns {name: terminal id} for the created ones."""
    cli("workspace", "current", "rename", names[0])
    terminals = {}
    for name in names[1:]:
        done = cli("workspace", "create", "--name", name, "--json")
        try:
            terminals[name] = (json.loads(done.stdout).get("value") or {}).get("terminal_id")
        except ValueError:
            terminals[name] = None
    wait(lambda: all(n in workspace_titles() for n in names), 15)
    return terminals


def mcp(requests):
    """One `cmux mcp serve` session: sends the JSON-RPC requests, returns the replies by id."""
    lines = "".join(json.dumps(r) + "\n" for r in requests)
    done = subprocess.run([CLI, "--app-socket", SOCKET, "mcp", "serve"], input=lines, env=cli_env(), capture_output=True,
                          text=True, timeout=120)
    replies = {}
    for line in done.stdout.splitlines():
        try:
            reply = json.loads(line)
        except ValueError:
            continue
        if "id" in reply:
            replies[reply["id"]] = reply
    if done.returncode != 0 or not replies:
        print("mcp serve", done.returncode, done.stderr.strip()[-400:], flush=True)
    return replies


app = None
try:
    with open(CONFIG, "w") as f:
        json.dump({"mcp": {"enabled": True}}, f)
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,980,640"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and workspace_titles(), 180):
        sys.exit("the tagged app did not come up")
    terminals = make_workspaces(["alpha", "beta", "gamma", "delta"])
    check(all(n in workspace_titles() for n in ["alpha", "beta", "gamma", "delta"]), "window 1 lists four workspaces", workspace_titles())
    if terminals.get("delta"):
        cli("terminal", str(terminals["delta"]), "write", "--text", "sleep 600\n")
        time.sleep(1.5)  # test harness: the shell starts sleep before the close asks process-info

    # palette ---------------------------------------------------------------------------------
    reply = rpc("palette.query", {"scope": "root", "query": "close all workspaces", "limit": 8}) or {}
    ids = [item.get("id") for item in reply.get("items") or []]
    json.dump(reply, open(os.path.join(opts.out, "palette-query.json"), "w"), indent=1)
    check(any(str(i).endswith("workspace.closeAll") for i in ids), "the palette lists Close All Workspaces", ids)
    check(any(str(i).endswith("workspace.closeAllInAllWindows") for i in ids), "the palette lists Close All Workspaces in All Windows", ids)
    rpc("action.run", {"action": "palette.open", "args": {"query": "Close All Workspaces"}, "focus": True}, timeout=20)
    time.sleep(1.5)  # test harness: the palette ranks and paints its rows
    capture = rpc("debug.palette.capture", {"path": os.path.join(opts.out, "palette-close-all.png")}, timeout=30)
    check("error" not in (capture or {"error": 1}), "the palette shows the query", capture)
    shot("palette-window")
    # Return in the open palette: its submit key action, run as a person's gesture.
    print("submit:", json.dumps(rpc("debug.toast", {"perform": "paletteKey.submit"}))[:200], flush=True)
    asked = wait(lambda: next((d for d in dialogs() if "sleep" in json.dumps(d)), None), 10)
    check(bool(asked), "Return in the palette runs Close All Workspaces, which asks (sleep runs)", dialogs())
    shot("confirm-dialog")
    json.dump(dialogs(), open(os.path.join(opts.out, "dialogs.json"), "w"), indent=1)
    rpc("debug.dialog", {"press": "cancel"})
    wait(lambda: not dialogs(), 5)
    time.sleep(1)  # test harness: a cancelled close must change nothing
    check(all(n in workspace_titles() for n in ["alpha", "beta", "gamma", "delta"]), "Cancel keeps all four workspaces", workspace_titles())

    # script and cli refusals ---------------------------------------------------------------------
    reply = action("workspace.closeAll")
    check("destructive" in json.dumps(reply), "action.run without confirm is refused", reply)
    done = cli("workspace", "close-all")
    check(done.returncode != 0 and "destructive" in (done.stdout + done.stderr), "`cmux workspace close-all` without --confirm is refused")
    check(len(workspace_titles()) == 4, "the refusals closed nothing", workspace_titles())

    # mcp tools -----------------------------------------------------------------------------------
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "close-all-proof", "version": "1"}}}
    replies = mcp([init, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
    tools = [t.get("name") for t in ((replies.get(2) or {}).get("result") or {}).get("tools") or []]
    json.dump(tools, open(os.path.join(opts.out, "mcp-tools.json"), "w"), indent=1)
    check("app_workspace_close_all" in tools, "MCP lists app_workspace_close_all", tools[:20])
    check("app_workspace_close_all_in_all_windows" in tools, "MCP lists app_workspace_close_all_in_all_windows")
    for name in ["app_close_other_windows", "app_close_all_windows", "app_workspace_group_close_others", "app_workspace_group_duplicate",
                 "app_sidebar_close_section_workspaces", "app_sidebar_new_section_workspace", "app_agent_archive_chat"]:
        check(name in tools, f"MCP lists {name}", [t for t in tools if t.startswith(name[:14])][:6])

    # undo: window 2 stays, so a person's close runs at once with a toast --------------------------
    first = window_ids()[0] if window_ids() else None
    action("newWindow")
    second = wait(lambda: next((w for w in window_ids() if w != first), None), 30)
    check(bool(second), "a second window opens", window_ids())
    wait(lambda: len(workspace_titles()) >= 5, 20)
    reply = rpc("debug.toast", {"perform": "workspace.closeAll", "target_kind": "window", "target_id": first})
    print("perform closeAll:", json.dumps(reply)[:300], flush=True)
    check(bool(wait(lambda: next((d for d in dialogs() if "sleep" in json.dumps(d)), None), 10)), "the close of window 1 asks again (sleep runs)", dialogs())
    rpc("debug.dialog", {"press": "confirm"})
    check(bool(wait(lambda: not any(n in workspace_titles() for n in ["alpha", "beta", "gamma", "delta"]), 15)),
          "Close confirmed: window 1's four workspaces close", workspace_titles())
    toast = wait(lambda: next((t for t in toasts() if t.get("id") == "workspaces-closed"), None), 10)
    check(bool(toast) and "4" in json.dumps(toast), "a window that stays shows “Closed 4 workspaces”", toasts())
    shot("undo-toast")
    reply = rpc("debug.toast", {"undo": True})
    check(bool((reply or {}).get("undone")), "Undo runs", reply)
    check(bool(wait(lambda: all(n in workspace_titles() for n in ["alpha", "beta", "gamma", "delta"]), 20)),
          "Undo reopens all four workspaces", workspace_titles())
    shot("after-undo")

    # cli close-other, then mcp close-all, then cli close-all-in-all-windows ---------------------
    count = len(workspace_titles())
    done = cli("workspace", "close-other", "--confirm")
    check(done.returncode == 0 and bool(wait(lambda: len(workspace_titles()) < count, 15)), "`cmux workspace close-other --confirm` closes", workspace_titles())
    before = window_ids()
    action("newWindow")
    made = wait(lambda: next((w for w in window_ids() if w not in before), None), 30)
    replies = mcp([init, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                   {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": {"name": "app_workspace_close_all", "arguments": {"window": made or "", "confirm": True}}}])
    print("mcp call:", json.dumps(replies.get(3))[:300], flush=True)
    check(not ((replies.get(3) or {}).get("result") or {}).get("isError", True), "MCP app_workspace_close_all runs", replies.get(3))
    check(bool(made) and bool(wait(lambda: made not in window_ids(), 15)), "MCP close-all (window argument) closes that window's workspaces and the window",
          (made, window_ids()))
    action("newWindow")
    wait(lambda: len(window_ids()) >= 2, 30)
    keep = len(window_ids())
    done = cli("app", "close-other-windows")
    check(done.returncode == 0 and bool(wait(lambda: len(window_ids()) == 1, 15)), "`cmux app close-other-windows` leaves one window",
          (keep, window_ids()))
    done = cli("workspace", "close-all-in-all-windows", "--confirm")
    check(done.returncode == 0 and bool(wait(lambda: not workspace_titles(), 15)),
          "`cmux workspace close-all-in-all-windows --confirm` closes every listed workspace", workspace_titles())
    print("windows left (the home workspace's window stays):", window_ids(), flush=True)
finally:
    if app is not None:
        print("the job's NX_APP_STOP stops the app (pid %d)" % app.pid, flush=True)
print("RESULT:", "PASS" if not failures else "FAIL " + "; ".join(failures), flush=True)
sys.exit(1 if failures else 0)
