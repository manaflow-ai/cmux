#!/usr/bin/env python3
"""Background browser use: every agent verb on every kind of hidden tab (user 2026-11-05: "make sure
background browser use works, aka agent can use browser of tabs/workspaces/panes/columns browsers
that are not visible/in focus").

Drives a running tagged cmux-next DEBUG build through its control socket the way `cmux browser
<tab> <verb>` and the MCP browser tools do (`browser.page.*`, each with `agent`), in a WebKit and a
Chromium tab per hidden state, over one local page (served on 127.0.0.1):

  states   visible (control: the tab its pane shows in the key window)
           background (made and shown, then covered by a newer tab in the same pane)
           never_shown (opened without focus: the pane never showed it)
           other_workspace (shown, then its workspace was left for another one)
           other_window (in a second window, behind the key window)
           minimized (in a third window that is minimized)
           hibernated (made, covered, then Hibernate Tab: the engine page is closed)

  verbs    navigate+wait, state, eval, snapshot, click, fill, type, press, scroll, hover,
           raw mouse click (native, trusted), raw key (native, trusted), raw wheel, screenshot,
           raf (requestAnimationFrame runs: >= 20 frames in 1 s), timers (a 50 ms interval
           fires >= 10 times in 1 s), focus_kept (no window, workspace, pane tab, key window
           or app activation changed, and the tab is still not shown)

Each cell is pass, fail or n/a (screenshot: refused for agents on the visible control as well:
person-only outside cmux-browser-host). Writes OUT/results.json and OUT/matrix.md; exit 1 when a
cell of a hidden state fails where the visible control passes.

It never launches, quits or activates the app. Run it on a capture slot through
scripts/cmux-next/restore-journey-slot.sh with RJ_DRIVER=scripts/cmux-next/browser-hidden-matrix-live.py
(it takes that runner's --socket, --out, --src and --max-seconds), or against a tagged build
started in the background:

  browser-hidden-matrix-live.py --socket /tmp/cmux-debug-<tag>.sock --out DIR
      [--engines webkit,chromium] [--states visible,background,...]
"""
import argparse, functools, http.server, json, os, socket, socketserver, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--engines", default="webkit,chromium")
parser.add_argument("--states", default="visible,background,never_shown,other_workspace,other_window,minimized,hibernated")
parser.add_argument("--max-seconds", type=float, default=900)
# restore-journey-slot.sh's driver arguments this script does not use.
parser.add_argument("--fake-agent")
parser.add_argument("--src")
parser.add_argument("--update-to")
opts, _ = parser.parse_known_args()
os.makedirs(opts.out, exist_ok=True)
DEADLINE = time.monotonic() + opts.max_seconds
AGENT = "MatrixAgent"
VERBS = ["navigate", "state", "eval", "snapshot", "click", "fill", "type", "press", "scroll", "hover",
         "mouse_native", "key_native", "wheel", "screenshot", "raf", "timers", "focus_kept"]

PAGE = """<!doctype html><html><head><meta charset=utf-8><title>bgm</title>
<style>body{font:14px system-ui;margin:20px;height:4000px} #hov{width:200px;height:40px;background:#ddd}
#hov:hover{background:#9c9}</style></head><body>
<h1>Hidden matrix</h1>
<button id=btn onclick="window.__clicks=(window.__clicks||0)+1;btn.textContent='clicked '+window.__clicks">Click me</button>
<input id=in placeholder=text>
<input id=in2 placeholder=keys>
<div id=hov>hover me</div>
<script>
window.__raf = 0; window.__ticks = 0; window.__keys = []; window.__trusted = []; window.__hover = 0;
(function loop(){ window.__raf++; requestAnimationFrame(loop); })();
setInterval(() => { window.__ticks++; }, 50);
addEventListener('keydown', e => { window.__keys.push(e.key); if (e.isTrusted) window.__trusted.push('key:' + e.key); }, true);
addEventListener('mousedown', e => { if (e.isTrusted) window.__trusted.push('mousedown'); }, true);
addEventListener('wheel', e => { if (e.isTrusted) window.__trusted.push('wheel'); }, true);
hov.addEventListener('mouseover', () => { window.__hover++; });
</script></body></html>"""


def rpc(method, params=None, timeout=60):
    """One request on the app's control socket (line JSON); the result or {"error": ...}."""
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
        result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
        return result if result is not None else {}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.2):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # test harness: bounded wait for the app's own state
        try:
            value = check()
        except Exception:  # the page may be navigating
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def action(name, target=None, focus=False, **args):
    params = {"action": name, "origin": "script", "focus": focus, "args": args}
    if target:
        params["target"] = target
    return rpc("action.run", params, timeout=90)


def created(reply, prefix="tab_"):
    return [c for c in (reply.get("created") or []) if str(c).startswith(prefix)]


def focus_report():
    return rpc("debug.focus")


def windows():
    return (focus_report() or {}).get("windows") or []


def key_window_id():
    return next((w.get("id") for w in windows() if w.get("is_key")), None)


def focus_signature():
    """What the person sees and types into: each window's workspace, focused pane and tab, which
    window is key, each shown pane's selected tab, and whether the app is active."""
    report = focus_report() or {}
    sig = {"app_active": report.get("app_active"), "key_window": report.get("key_window"), "windows": {}}
    for w in report.get("windows") or []:
        model = w.get("model") or {}
        sig["windows"][w.get("id")] = {
            "workspace": w.get("workspace"), "is_key": w.get("is_key"), "pane": model.get("pane"),
            "tab": model.get("resolved_tab"),
            "selected": sorted(str(p.get("selected")) for p in w.get("topology") or []),
        }
    return sig


def signature_diff(before, after):
    """Only what changed between two focus signatures, as {path: [before, after]}."""
    out = {}
    for key in ("app_active", "key_window"):
        if before.get(key) != after.get(key):
            out[key] = [before.get(key), after.get(key)]
    bw, aw = before.get("windows") or {}, after.get("windows") or {}
    for wid in sorted(set(bw) | set(aw), key=str):
        b, a = bw.get(wid) or {}, aw.get(wid) or {}
        for field in sorted(set(b) | set(a)):
            if b.get(field) != a.get(field):
                out[f"{str(wid)[:8]}.{field}"] = [b.get(field), a.get(field)]
    return out


def shown_tabs(key_only=False):
    """Every tab some window's shown workspace selects in a pane (only the key window's: what the
    person looks at)."""
    out = set()
    for w in windows():
        if key_only and not w.get("is_key"):
            continue
        for p in w.get("topology") or []:
            if p.get("selected"):
                out.add(p["selected"])
    return out


class Quiet(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def serve():
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Quiet)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


BASE = serve()
OPEN = {"webkit": "openBrowser.webkit", "chromium": "openBrowser.chromium"}


def open_tab(engine, near, focus, label):
    """A browser tab of `engine` next to tab `near` (its pane), shown when `focus`."""
    reply = action(OPEN[engine], target=f"tab:{near}" if near else None, focus=focus, url=f"{BASE}/{label}")
    tab = (created(reply) or [None])[0]
    if not tab:
        print(f"  open {engine} {label}: {json.dumps(reply)[:300]}", flush=True)
    return tab


def first_tab_of(window_id):
    w = next((w for w in windows() if w.get("id") == window_id), None) or {}
    return next((p.get("selected") for p in w.get("topology") or [] if p.get("selected")), None)


def minimized_window():
    """True once an app window is minimized and occluded (`debug.window_list`)."""
    reply = rpc("debug.window_list") or {}
    listed = reply.get("windows") if isinstance(reply, dict) else reply
    return any(w.get("miniaturized") and w.get("occluded") for w in listed or [] if isinstance(w, dict))


def new_window():
    before = {w.get("id") for w in windows()}
    action("newWindow", focus=True)
    return wait(lambda: next((w.get("id") for w in windows() if w.get("id") not in before), None), 30)


def build(engines, states):
    """The tabs, one per (engine, state), then the key window back on the control workspace."""
    home = wait(key_window_id, 20) or (windows() or [{}])[0].get("id")
    if not home:
        home = new_window()
    anchor = first_tab_of(home)
    if not anchor:
        action("newTab", focus=True)
        anchor = wait(lambda: first_tab_of(home), 20)
    home_ws = next((w.get("workspace") for w in windows() if w.get("id") == home), None)
    tabs = {}
    for engine in engines:
        for state in states:
            label = f"{engine}-{state}"
            if state == "visible":
                tabs[(engine, state)] = open_tab(engine, anchor, True, label)
            elif state == "background":
                tab = open_tab(engine, anchor, True, label)
                wait(lambda: tab in shown_tabs(), 20)
                open_tab(engine, tab, True, label + "-cover")
                tabs[(engine, state)] = tab
            elif state == "never_shown":
                tabs[(engine, state)] = open_tab(engine, anchor, False, label)
            elif state == "hibernated":
                tab = open_tab(engine, anchor, True, label)
                wait(lambda: tab in shown_tabs(), 20)
                time.sleep(1.5)  # the page loads before it is put to sleep (its picture)
                open_tab(engine, tab, True, label + "-cover")
                # The object target names a tab no window shows (a `tab:` string resolves only shown ones).
                reply = action("hibernateTab", target={"kind": "tab", "id": tab})
                if reply.get("error"):
                    print(f"  hibernateTab {tab}: {json.dumps(reply)[:200]}", flush=True)
                tabs[(engine, state)] = tab
            elif state == "other_workspace":
                reply = action("workspace.newBelow", target=f"workspace:{home_ws}", focus=True)
                ws = (created(reply, "ws_") or [None])[0]
                wait(lambda: next((w.get("workspace") for w in windows() if w.get("id") == home), None) == ws, 20)
                near = wait(lambda: first_tab_of(home), 20)
                tabs[(engine, state)] = open_tab(engine, near, True, label)
                action("workspace.select", target=f"workspace:{home_ws}", focus=True)
                wait(lambda: next((w.get("workspace") for w in windows() if w.get("id") == home), None) == home_ws, 20)
            elif state in ("other_window", "minimized"):
                window = new_window()
                near = wait(lambda: first_tab_of(window), 20) if window else None
                tab = open_tab(engine, near, True, label)
                wait(lambda: tab in shown_tabs(), 20)
                tabs[(engine, state)] = tab
                if state == "minimized":
                    # minimizeWindow acts on the active window, not its target: make this one active.
                    rpc("debug.window.focus", {"window": window})
                    wait(lambda: key_window_id() == window, 10)
                    action("minimizeWindow", target=f"window:{window}", focus=True)
                    # The Dock animation ends later: a verb run before it ends meets a window that
                    # still draws, and one during it meets the change mid-call.
                    if not wait(minimized_window, 20):
                        listed = (rpc("debug.window_list") or {}).get("windows") or []
                        print("note: the window did not report minimized in 20 s; windows: " + json.dumps(
                            [{k: w.get(k) for k in ("id", "class", "key", "visible", "miniaturized", "occluded")} for w in listed
                             if isinstance(w, dict)])[:1200] + f"; key before: {key_window_id()}", flush=True)
    # The person's place: the control workspace in the first window, key and in front.
    rpc("debug.window.focus", {"window": home})
    action("workspace.select", target=f"workspace:{home_ws}", focus=True)
    for engine in engines:
        if tabs.get((engine, "visible")):
            action("tab.focus", target=f"tab:{tabs[(engine, 'visible')]}", focus=True)
    time.sleep(2)
    return tabs


class Cell:
    def __init__(self):
        self.result, self.detail = "fail", ""


def page(tab, verb, **params):
    params["tab"] = tab
    params["agent"] = AGENT
    return rpc("browser.page." + verb, params, timeout=45)


def js(tab, script):
    reply = page(tab, "eval", script=script)
    return reply.get("value") if not reply.get("error") else None


def run_tab(engine, state, tab, visible_now):
    cells = {verb: Cell() for verb in VERBS}

    def mark(verb, ok, detail=""):
        cells[verb].result = "pass" if ok else "fail"
        cells[verb].detail = detail if isinstance(detail, str) else json.dumps(detail)[:1200]
        print(f"  {'ok  ' if ok else 'FAIL'} {engine:8} {state:16} {verb:12} {cells[verb].detail[:160]}", flush=True)

    if not tab:
        for verb in VERBS:
            mark(verb, False, "tab was not created")
        return cells
    before = focus_signature()
    url = f"{BASE}/m-{engine}-{state}"
    started = time.monotonic()
    nav = page(tab, "navigate", url=url)
    if nav.get("error") and nav["error"].get("code") == "unavailable":
        nav = page(tab, "navigate", url=url)  # the first agent touch may rebuild the page: retry once
    loaded = page(tab, "wait", load_state="complete", timeout_ms=20000)
    title_ok = wait(lambda: js(tab, "document.title") == "bgm" and js(tab, "location.pathname") == f"/m-{engine}-{state}", 15)
    mark("navigate", not nav.get("error") and title_ok, {"nav": nav.get("error"), "wait": loaded.get("error"), "s": round(time.monotonic() - started, 2)})
    st = page(tab, "state")
    mark("state", (st.get("url") or "").endswith(f"/m-{engine}-{state}"), {"url": st.get("url"), "error": st.get("error")})
    mark("eval", js(tab, "1 + 1") == 2, "")
    snap = page(tab, "snapshot", interactive=True)
    mark("snapshot", "Click me" in json.dumps(snap), {"error": snap.get("error"), "refs": len(snap.get("refs") or {})})
    reply = page(tab, "click", selector="#btn")
    mark("click", js(tab, "window.__clicks || 0") >= 1, reply.get("error") or "")
    reply = page(tab, "fill", selector="#in", text="hello")
    mark("fill", js(tab, "document.querySelector('#in').value") == "hello", reply.get("error") or "")
    reply = page(tab, "type", selector="#in", text=" world")
    mark("type", js(tab, "document.querySelector('#in').value") == "hello world", reply.get("error") or "")
    reply = page(tab, "press", key="Enter", selector="#in")
    mark("press", "Enter" in (js(tab, "window.__keys") or []), reply.get("error") or "")
    reply = page(tab, "scroll", dy=600)
    mark("scroll", wait(lambda: (js(tab, "scrollY") or 0) > 0, 3), {"error": reply.get("error"), "y": js(tab, "scrollY")})
    js(tab, "scrollTo(0, 0)")
    reply = page(tab, "hover", selector="#hov")
    mark("hover", (js(tab, "window.__hover") or 0) >= 1, reply.get("error") or "")
    # Native input: trusted events through the engine, not page script.
    rect = js(tab, "(() => { const r = btn.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()") or [40, 40]
    reply = page(tab, "mouse", kind="click", x=rect[0], y=rect[1])
    trusted = js(tab, "window.__trusted") or []
    mark("mouse_native", reply.get("native") is True and "mousedown" in trusted, {"native": reply.get("native"), "error": reply.get("error"), "trusted": trusted})
    js(tab, "document.querySelector('#in2').focus()")
    reply = page(tab, "key", key="a", kind="press")
    trusted = js(tab, "window.__trusted") or []
    mark("key_native", reply.get("native") is True and "key:a" in trusted, {"native": reply.get("native"), "error": reply.get("error"), "trusted": trusted})
    reply = page(tab, "wheel", x=100, y=100, dy=400)
    moved = wait(lambda: (js(tab, "scrollY") or 0) > 0, 3)
    mark("wheel", not reply.get("error") and moved, {"native": reply.get("native"), "error": reply.get("error"), "y": js(tab, "scrollY")})
    shot = page(tab, "screenshot")
    if shot.get("error") and "person" in json.dumps(shot["error"]).lower():
        cells["screenshot"].result, cells["screenshot"].detail = "n/a", "person-only for agents (cmux-browser-host captures)"
        print(f"  n/a  {engine:8} {state:16} screenshot   person-only", flush=True)
    else:
        mark("screenshot", bool(shot.get("path")) and (shot.get("width") or 0) > 0, {"error": shot.get("error"), "w": shot.get("width")})
    # Throttling: rAF and timers over one second.
    r0, t0 = js(tab, "window.__raf"), js(tab, "window.__ticks")
    time.sleep(1.0)
    r1, t1 = js(tab, "window.__raf"), js(tab, "window.__ticks")
    raf = (r1 - r0) if isinstance(r0, (int, float)) and isinstance(r1, (int, float)) else None
    ticks = (t1 - t0) if isinstance(t0, (int, float)) and isinstance(t1, (int, float)) else None
    vis = js(tab, "document.visibilityState")
    mark("raf", raf is not None and raf >= 20, {"frames_per_s": raf, "visibility": vis})
    mark("timers", ticks is not None and ticks >= 10, {"ticks_per_s": ticks, "visibility": vis})
    after = focus_signature()
    still_hidden = visible_now or tab not in shown_tabs(key_only=True)
    mark("focus_kept", before == after and still_hidden, {"shown_now": not still_hidden, "changed": signature_diff(before, after)})
    return cells


def main():
    engines = [e for e in opts.engines.split(",") if e]
    states = [s for s in opts.states.split(",") if s]
    tabs, results = {}, {}
    for engine in engines:
        # One engine at a time: its visible control is the tab the key window's pane shows.
        tabs.update(build([engine], states))
        for state in states:
            if time.monotonic() > DEADLINE - 30:
                print("out of time", flush=True)
                break
            cells = run_tab(engine, state, tabs.get((engine, state)), state == "visible")
            results[f"{engine}/{state}"] = {v: {"result": c.result, "detail": c.detail} for v, c in cells.items()}
    with open(os.path.join(opts.out, "results.json"), "w") as f:
        json.dump({"tabs": {f"{e}/{s}": t for (e, s), t in tabs.items()}, "results": results}, f, indent=1)
    lines = []
    failed = 0
    for engine in engines:
        lines += [f"### {engine}", "", "| verb | " + " | ".join(states) + " |", "|---" * (len(states) + 1) + "|"]
        for verb in VERBS:
            row = []
            control = results.get(f"{engine}/visible", {}).get(verb, {}).get("result")
            for state in states:
                cell = results.get(f"{engine}/{state}", {}).get(verb, {}).get("result", "-")
                row.append({"pass": "pass", "fail": "FAIL", "n/a": "n/a"}.get(cell, cell))
                if state != "visible" and cell == "fail" and control != "fail":
                    failed += 1
            lines.append(f"| {verb} | " + " | ".join(row) + " |")
        lines.append("")
    text = "\n".join(lines)
    with open(os.path.join(opts.out, "matrix.md"), "w") as f:
        f.write(text)
    print(text, flush=True)
    print(f"hidden-state failures where the visible control passes: {failed}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
