#!/usr/bin/env python3
"""Live proof that a workspace group pins and unpins on the sidebar document
(https://github.com/manaflow-ai/cmux/issues/22259), on one tagged DEBUG app
with a bounded, never-activated window, through the tagged app's own sockets.

Checks, each on a fresh group:
  gui   Pin/Unpin Group as the header menu runs it (`workspaceGroup.togglePin`
        on the group id the sidebar shows), twice: Pinned, then back.
  cli   `cmux workspace group <id> update --pinned true|false`.
  mcp   `action.run workspaceGroup.togglePin` with a `pinned` argument and the
        personal group id (the path the cmux MCP tool and scripts take).

A group reads as pinned when the header menu offers "Unpin Group" and the
group lists above the machine section (in Pinned).

Teardown: quit with End Sessions, `cmux server stop --end-terminals`; signals
only to the PID this script launched. Run on a GUI host, never the laptop.
Usage: group-pin-live.py TAG APP OUT_DIR
"""
import json, os, signal, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
SESSION = "cmux-app-%s" % TAG
os.makedirs(OUT, exist_ok=True)
results = []
RUN = "%x" % (int(time.time()) % 0xFFFFFF)  # unique names: a tag's daemon keeps an earlier run's workspaces


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("%s %s %s" % ("PASS" if ok else "FAIL", name, str(detail)[:600]), flush=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    r = subprocess.run([CLI, "--session", SESSION, *args], env=env, capture_output=True, text=True, timeout=60)
    return (r.stdout.strip() or r.stderr.strip()), r.returncode


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def window():
    return next(iter((rpc("debug.sidebar_rows") or {}).get("windows", [])), {})


def rows():
    return window().get("rows", [])


def group_row(group):
    """The group's header row: the row whose key or item names the group."""
    return next((r for r in rows() if r.get("key") == "group(%s)" % group), None)


def menu(group):
    row = group_row(group)
    if not row:
        return []
    f = row["window_frame"]
    x, y, w, h = f["x"], f["y"], f["width"], f["height"]
    return (rpc("debug.sidebar_rows", {"menu_x": x + w / 2, "menu_y": y + h / 2}) or {}).get("menu") or []


def pinned_section_lists(group):
    """The group's header lists before every loose workspace row of the machine list (Pinned lists first)."""
    all_rows = rows()
    row = group_row(group)
    loose = [r for r in all_rows if str(r.get("key", "")).startswith("workspace(") and not r.get("group")]
    if not row or not loose:
        return None
    return row["window_frame"]["y"] < min(r["window_frame"]["y"] for r in loose)


def reads_pinned(group):
    return "Unpin Group" in menu(group) and pinned_section_lists(group) is True


def reads_unpinned(group):
    return "Pin Group" in menu(group) and pinned_section_lists(group) is False


def personal_pinned(personal):
    out, _ = cli("workspace", "group", "list", "--json")
    try:
        data = json.loads(out)
    except ValueError:
        return None
    groups = data.get("value", data) if isinstance(data, dict) else data
    groups = groups.get("groups", groups) if isinstance(groups, dict) else groups
    return next((g.get("pinned") for g in groups or [] if g.get("id") == personal), None)


def launch():
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
    proc = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print("launched pid %d" % proc.pid, flush=True)
    wins = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180, 0.5)
    check("launch", wins, json.dumps(wins)[:200])
    return proc


def make_group(name):
    """A workspace in a new group; returns (the id the sidebar shows, the personal id)."""
    title = "pin-%s-%s" % (name, RUN)
    created, _ = cli("workspace", "create", "--name", title, "--json")
    print("workspace create:", created[:300], flush=True)
    row = wait(lambda: next((r for r in rows() if r.get("title") == title), None), 15)
    check("%s-setup-row" % name, row, [r.get("title") for r in rows()])
    if not row:
        return None, None
    made, _ = cli("workspace", "group", "create", "--name", "Pin %s" % name, "--json")
    print("group create:", made[:300], flush=True)
    try:
        value = json.loads(made).get("value") or {}
    except ValueError:
        value = {}
    group = value.get("id") or value.get("workspace_group") or (value.get("group") or {}).get("id")
    added = cli("workspace", "group", str(group), "add", "--workspace", title, "--json") if group else ("no group id", 1)
    print("group add:", added[0][:300], flush=True)
    # The header lists under the document's item for the group (`itm_g_<id>`).
    shown = "itm_g_%s" % group
    grouped = wait(lambda: group_row(shown), 15)
    check("%s-setup-group" % name, grouped, (made[:200], added[0][:200]))
    if not grouped:
        return None, None
    personal = group
    json.dump(window(), open(os.path.join(OUT, "sidebar-%s.json" % name), "w"), indent=1)
    print("%s group shown=%s personal=%s header=%s" % (name, shown, personal, json.dumps(group_row(shown))[:300]), flush=True)
    return shown, personal


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="group-pin-")
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
app = launch()
try:
    print("doc:", json.dumps((rpc("debug.sidebar_rows") or {}).get("doc"))[:300], flush=True)

    # gui: the header menu's Pin/Unpin Group ----------------------------------------
    shown, personal = make_group("gui")
    if shown:
        check("gui-menu-offers-pin", wait(lambda: "Pin Group" in menu(shown), 5), menu(shown))
        reply = rpc("debug.toast", {"perform": "workspaceGroup.togglePin", "target_kind": "workspace-group", "target_id": shown})
        check("gui-pin-ran", reply.get("performed") and not reply.get("error"), reply)
        check("gui-pin-shows-pinned", wait(lambda: reads_pinned(shown), 10), (menu(shown), pinned_section_lists(shown)))
        check("gui-pin-saves-personal", wait(lambda: personal_pinned(personal) is True, 10), personal_pinned(personal))
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "gui-pinned.png")}, timeout=60)
        reply = rpc("debug.toast", {"perform": "workspaceGroup.togglePin", "target_kind": "workspace-group", "target_id": shown})
        check("gui-unpin-ran", reply.get("performed") and not reply.get("error"), reply)
        check("gui-unpin-shows-unpinned", wait(lambda: reads_unpinned(shown), 10), (menu(shown), pinned_section_lists(shown)))
        check("gui-unpin-saves-personal", wait(lambda: personal_pinned(personal) is False, 10), personal_pinned(personal))

    # cli: workspace group <id> update --pinned ----------------------------------------
    shown, personal = make_group("cli")
    if shown:
        out, code = cli("workspace", "group", personal, "update", "--pinned", "true", "--json")
        check("cli-pin-ran", code == 0, out)
        check("cli-pin-shows-pinned", wait(lambda: reads_pinned(shown), 10), (menu(shown), pinned_section_lists(shown)))
        out, code = cli("workspace", "group", personal, "update", "--pinned", "false", "--json")
        check("cli-unpin-ran", code == 0, out)
        check("cli-unpin-shows-unpinned", wait(lambda: reads_unpinned(shown), 10), (menu(shown), pinned_section_lists(shown)))

    # mcp: action.run with the personal id and an explicit state --------------------------
    shown, personal = make_group("mcp")
    if shown:
        for pinned, name in ((True, "pin"), (False, "unpin")):
            reply = rpc("action.run", {"id": "workspaceGroup.togglePin", "target": "workspace-group:%s" % personal,
                                       "args": {"pinned": pinned}})
            check("mcp-%s-ran" % name, isinstance(reply, dict) and not reply.get("error"), reply)
            read = reads_pinned if pinned else reads_unpinned
            check("mcp-%s-shows" % name, wait(lambda: read(shown), 10), (menu(shown), pinned_section_lists(shown)))
        # The same state twice is no toggle.
        rpc("action.run", {"id": "workspaceGroup.togglePin", "target": "workspace-group:%s" % personal, "args": {"pinned": False}})
        check("mcp-explicit-state-is-no-toggle", wait(lambda: reads_unpinned(shown), 5), (menu(shown), pinned_section_lists(shown)))
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "end.png")}, timeout=60)
finally:
    print("teardown quit:", json.dumps(rpc("action.run", {"id": "quit", "args": {"endSessions": True}}, timeout=10))[:200])
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print("pid %d did not quit; SIGKILL" % app.pid, flush=True)
        os.kill(app.pid, signal.SIGKILL)  # the PID launched here, never a pattern
    subprocess.run([CLI, "server", "stop", "--session", SESSION, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
failed = [name for name, ok in results if not ok]
print("RESULT pass=%d fail=%d %s" % (len(results) - len(failed), len(failed), " ".join(failed)), flush=True)
sys.exit(1 if failed else 0)
