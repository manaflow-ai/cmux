#!/usr/bin/env python3
"""Live behavior proof of link routing (cx-ir3z4), through a tagged app's own socket.

One rule (`browser.openLinksInCmuxBrowser`, LinkRouter) for every surface. Checks:
  1. with the default setting, a terminal link and an agent-chat link open a cmux browser tab;
  2. the palette's Links: Open in Default Browser writes the setting false; then a link would go
     to the system (the DEBUG routing probe, and a terminal click recorded, never opened), and
     Shift-Command routes it back to cmux; Links: Open in cmux Browser turns it back on;
  3. a link's right-click rows: Open in cmux Browser, Open in New cmux Browser Tab, Open in
     Default Browser, Open In (the default browser first), Copy Link;
  4. a path's right-click rows: Open, Open in Text Editor, Open With (apps, then Other...),
     Reveal in Finder, Copy Path; a relative path resolves against the terminal's folder.
The app records opens meant for another app instead of opening them
(CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1), so no Safari window opens.
Run on cmux-lawrence-2 through `nx-remote --needs gui --app-from-fleet cmux`, never the laptop.
Usage: link-routing-live.py TAG APP OUT_DIR
"""
import json, os, socket, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
SESSION = "cmux-app-%s" % TAG
SETTING = "browser.openLinksInCmuxBrowser"
os.makedirs(OUT, exist_ok=True)
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("%s %s %s" % ("PASS" if ok else "FAIL", name, str(detail)[:800]), flush=True)
    return ok


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
        result = r.get("result") if r.get("ok") else {"error": r.get("error")}
        return result if isinstance(result, dict) else {"value": result}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def wait(predicate, seconds, step=0.25):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


TERMINAL = None


def links(params=None):
    return rpc("debug.terminal.links", {**(params or {}), **({"tab": TERMINAL} if TERMINAL else {})})


def opened_after(action):
    """Clears the record, runs `action`, and returns what opened (the opens run after the click returns)."""
    links({"clear": True})
    action()
    return wait(lambda: links().get("opened") or [], 10) or []


def kinds(rows):
    return [row.get("kind") for row in rows or []]


def palette_run(query, action):
    """Runs a palette action as the person does (Cmd-Shift-P, typing, Return): the link keys are
    the person's own, so a socket or script run is refused (SettingsSchema.agentRefusedKeys)."""
    ranked = [item.get("id") for item in (rpc("palette.query", {"scope": "root", "query": query, "limit": 8}) or {}).get("items") or []]
    check("the palette lists %s" % action, any(str(i).endswith(action) for i in ranked), ranked)
    rpc("debug.key", {"key": "p", "modifiers": ["command", "shift"]})
    time.sleep(1)  # test harness: the palette window appears
    for char in query:
        rpc("debug.key", {"key": "space" if char == " " else char, "target": "palette"})
    time.sleep(1.5)  # test harness: the palette ranks and paints its rows
    rpc("debug.palette.capture", {"path": os.path.join(OUT, "palette-%s.png" % action)}, timeout=60)
    print("palette return:", json.dumps(rpc("debug.key", {"key": "return", "target": "palette"}))[:200], flush=True)


def browser_tabs():
    count = 0
    for workspace in (rpc("snapshot.get").get("topology") or {}).get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                count += sum(1 for tab in pane.get("tabs") or [] if "browser" in str(tab.get("kind", "")))
    return count


def setting_in_file():
    try:
        return (json.load(open(CONFIG)).get("browser") or {}).get("openLinksInCmuxBrowser")
    except (OSError, ValueError):
        return None


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = os.path.realpath(tempfile.mkdtemp(prefix="link-routing-"))
CONFIG, GHOSTTY = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
REPO = os.path.join(scratch, "repo")
os.makedirs(os.path.join(REPO, ".git"))
os.makedirs(os.path.join(REPO, "notes"))
UNIQUE = "link-routing-%s.md" % TAG
open(os.path.join(REPO, "notes", UNIQUE), "w").write("# proof\n")
open(CONFIG, "w").write("{}\n")
open(GHOSTTY, "w").write("link-previews = true\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1"}
# Through LaunchServices (`open -n`, build-host README): an app a script spawns directly may not activate.
log = os.path.join(OUT, "app-%s.log" % TAG)
launch = ["open", "-n", "--stdout", log, "--stderr", log] + [a for k, v in env.items() for a in ("--env", "%s=%s" % (k, v))]
print("open:", subprocess.run(launch + [APP], capture_output=True, text=True).returncode, flush=True)
try:
    check("launch", wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 180, 0.5))
    check("the build has debug.terminal.links", "error" not in rpc("debug.terminal.links"))
    made = rpc("action.run", {"action": "workspace new", "args": {"cwd": os.path.join(REPO, "notes"), "focus": True}, "origin": "script"})
    workspace = (made.get("created") or [None])[0]
    print("workspace new:", json.dumps(made)[:300], flush=True)

    def fixture_terminal():
        global TERMINAL
        for listed in (rpc("snapshot.get").get("topology") or {}).get("workspaces") or []:
            if listed.get("id") != workspace:
                continue
            for screen in listed.get("screens") or []:
                for pane in screen.get("panes") or []:
                    for tab in pane.get("tabs") or []:
                        if tab.get("kind") in ("terminal", "pty") and "error" not in rpc("debug.terminal.links", {"tab": tab["id"]}):
                            TERMINAL = tab["id"]
                            return TERMINAL
        return None

    check("the fixture workspace's terminal", wait(fixture_terminal, 30))
    time.sleep(2)  # test harness: the shell starts and reports its cwd

    # 1. Default setting: the terminal link and the agent-chat link open cmux browser tabs.
    check("default route is cmux", links({"route": "https://example.com/a"}).get("route") == "cmuxBrowser", links({"route": "https://example.com/a"}))
    before = browser_tabs()
    got = opened_after(lambda: links({"open": "https://example.com/terminal-link"}))
    check("terminal link opens in cmux", "browser:https://example.com/terminal-link" in got, got)
    check("a cmux browser tab opened", wait(lambda: browser_tabs() > before, 15), "tabs %d -> %d" % (before, browser_tabs()))
    before = browser_tabs()
    got = opened_after(lambda: check("agent chat link accepted", links({"agentLink": "https://example.com/agent-link"}).get("agentOpened") is True))
    check("agent chat link opens in cmux", "browser:https://example.com/agent-link" in got, got)
    check("a second cmux browser tab opened", wait(lambda: browser_tabs() > before, 15), "tabs %d -> %d" % (before, browser_tabs()))

    # 2. The palette turns links to the default browser.
    refused = rpc("action.run", {"action": "links.openInDefaultBrowser", "origin": "script"})
    check("a script cannot change the link setting", "error" in refused and setting_in_file() is None, refused)
    palette_run("links open in default browser", "links.openInDefaultBrowser")
    check("palette wrote %s false" % SETTING, wait(lambda: setting_in_file() is False, 10), setting_in_file())
    check("route is now the system", wait(lambda: links({"route": "https://example.com/b"}).get("route") == "system", 10),
          links({"route": "https://example.com/b"}))
    check("Shift-Command routes to cmux", links({"route": "https://example.com/b", "other": True}).get("route") == "cmuxBrowser")
    got = opened_after(lambda: links({"open": "https://example.com/system-link"}))
    check("terminal link goes to the system (recorded, not opened)", "system:https://example.com/system-link" in got, got)
    check("a non-web scheme always goes to the system", links({"route": "mailto:a@example.com", "other": True}).get("route") == "system")
    palette_run("links open in cmux browser", "links.openInCmuxBrowser")
    check("palette wrote %s true" % SETTING, wait(lambda: setting_in_file() is True, 10), setting_in_file())

    # 3. A link's right-click rows.
    rows = links({"menu": "https://example.com/menu"}).get("menu") or []
    want = ["openInCmuxBrowser", "openInNewCmuxTab", "openInDefaultBrowser", "openIn", "copyLink"]
    check("link menu rows", kinds(rows)[:5] == want, kinds(rows))
    browsers = next((row.get("children") for row in rows if row.get("kind") == "openIn"), []) or []
    check("Open In lists browsers with app paths", browsers and all(b.get("app", "").endswith(".app") for b in browsers),
          [b.get("title") for b in browsers])

    # 4. A path's right-click rows, the path relative to the terminal's folder.
    rows = links({"menu": UNIQUE}).get("menu") or []
    check("relative path resolves against the terminal's folder", rows, "menu for %s: %s" % (UNIQUE, kinds(rows)))
    present = kinds(rows)
    check("path menu rows", all(k in present for k in ["open", "openWith", "revealInFinder", "copyPath"]), present)
    check("Open in Text Editor is offered", "openInTextEditor" in present, present)
    choices = next((row.get("children") for row in rows if row.get("kind") == "openWith"), []) or []
    check("Open With ends with Other…", choices and choices[-1].get("kind") == "openWithOther", kinds(choices))
    missing = links({"menu": "no-such-%s.md" % TAG}).get("menu")
    check("a path that exists nowhere has no rows", missing == [], missing)
    json.dump({"results": results}, open(os.path.join(OUT, "link-routing-live.json"), "w"), indent=2)
finally:
    print("teardown quit:", json.dumps(rpc("action.run", {"action": "quit", "args": {"endSessions": True}}, timeout=10))[:200])
    gone = wait(lambda: not os.path.exists(SOCKET) or "error" in (rpc("debug.windows", timeout=2) or {}), 60, 0.5)
    stop = os.environ.get("NX_APP_STOP")
    if not gone and stop:
        print("app did not quit; NX_APP_STOP", flush=True)
        subprocess.run([stop], timeout=60)
    subprocess.run([CLI, "server", "stop", "--session", SESSION, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
failed = [name for name, ok in results if not ok]
print("RESULT pass=%d fail=%d %s" % (len(results) - len(failed), len(failed), " ".join(failed)), flush=True)
sys.exit(1 if failed else 0)
