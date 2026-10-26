#!/usr/bin/env python3
"""Child process crashes on a running tagged cmux-next app (bd cx-d0d.2; crash-elimination.md
section 3, classes 13 and 14): the app stays up and the page that lost its process says so.

  1. Agent page WebContent: SIGKILL the WebContent process of the New Tab page (an agent page,
     `debug.agent_pane` pid). The page reloads in a new process by itself (AgentPaneView+CrashNotice).
  2. Chromium renderer: SIGKILL the renderer of a Chromium tab. The tab shows the sad tab with
     Reload (`debug.browser.page_status` gone and gone_text); Reload brings the page back.
  3. Chromium GPU process: SIGKILL it. Chromium starts a new one and the tab's page still answers;
     a sad tab, if one shows, reloads.
  4. WebKit WebContent: SIGKILL the WebContent process of a WebKit tab (page_status page_pid).
     Same as 2.
  5. Chromium host app (F2, `browserHost.helperPrototype`; cef-helper-app-DESIGN.md): a page whose
     Chromium browser process runs in `<App> Chromium Host.app` (`debug.chromium_host`). SIGKILL the
     host: a new host loads the saved page. Then navigate it to chrome://inducebrowsercrashforrealz
     (Chromium's own browser-process crash, content/browser/renderer_host/debug_urls.cc): the host
     ends by its crash and, ending again within the restart window, stays ended with no page shown
     (ChromiumHostRestartPolicy); opening the page again starts a new host with it. Skips with the
     reason when the build has no host (Release, or a Debug build without CEF).

After each kill the app's process must still run. Every kill names an exact pid: a child of the
app's process (`--type=renderer`, `--type=gpu-process`) found by its parent pid, or the pid the app
reports for the page. The app runs already (a capture slot: `capture-host launch`), with its debug
socket; the script never launches or quits it.

Usage: child-crash-e2e.py --socket <path> [--app-pid PID] [--only renderer,gpu,webkit,agent,host]
"""
import argparse, functools, http.server, json, os, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--app-pid", type=int, help="the app's pid (default: the process listening on --socket)")
KINDS = ("renderer", "gpu", "webkit", "agent", "host")
parser.add_argument("--only", default=",".join(KINDS), help="comma-separated kinds: " + ", ".join(KINDS))
# Accepted for the capture-slot harness, which passes them to every e2e.
parser.add_argument("--runs", type=int, default=1)
parser.add_argument("--out", default="/tmp/child-crash-e2e")
opts = parser.parse_args()
if set(opts.only.split(",")) - set(KINDS):
    parser.error(f"unknown --only kinds {sorted(set(opts.only.split(',')) - set(KINDS))}; kinds: {', '.join(KINDS)}")

failures = []
skips = []


def rpc(method, params=None, timeout=40):
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def run(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True, "confirm": True})


def js(tab, script):
    reply = rpc("browser.page.eval", {"tab": tab, "script": script}) or {}
    return reply.get("value") if "error" not in reply else None


def status(tab, press=None):
    return rpc("debug.browser.page_status", {"tab": tab, **({"press": press} if press else {})}) or {}


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail else ''}", flush=True)
    if not ok:
        failures.append(name)
    return ok


def skip(name, reason):
    print(f"SKIP {name}: {reason}", flush=True)
    skips.append(name)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def children(parent, kind):
    """Pids of `parent`'s child processes started with --type=<kind>."""
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == str(parent) and f"--type={kind}" in parts[2]:
            pids.append(int(parts[0]))
    return pids


def app_pid():
    if opts.app_pid:
        return opts.app_pid
    # lsof lists a unix socket by the path it is bound to, under the process that holds it.
    out = subprocess.run(["lsof", "-U", "-Fpn"], capture_output=True, text=True).stdout
    pid = None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and line[1:] == opts.socket:
            return pid
    return None


def parent_of(child):
    out = subprocess.run(["ps", "-o", "ppid=", "-p", str(child)], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def serve():
    root = tempfile.mkdtemp(prefix="child-crash-e2e-")
    with open(os.path.join(root, "index.html"), "w") as page:
        page.write("<!doctype html><title>crash-e2e</title><p id=alive>alive</p>")
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    handler = functools.partial(Quiet, directory=root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://localhost:{server.server_address[1]}/"


def open_tab(engine, url):
    opened = wait(lambda: (lambda r: r if (r or {}).get("created") else None)(run("openBrowser", {"url": url, "engine": engine})), 90, 3)
    created = (opened or {}).get("created") or []
    tab = created[0] if created else None
    loaded = bool(tab) and wait(lambda: js(tab, "document.title") == "crash-e2e", 60, 0.5)
    check(f"{engine} tab loads {url}", loaded, opened)
    return tab if loaded else None


def sad_tab_reloads(name, tab, pid):
    """The tab shows the sad tab with Reload, and Reload brings the page back."""
    gone = wait(lambda: (lambda s: s if s.get("gone") == "1" else None)(status(tab)), 20)
    check(f"{name}: app still runs", alive(pid))
    lines = ((gone or {}).get("gone_text") or "").split("\n")
    check(f"{name}: the tab shows the crashed page with Reload", bool(gone) and len(lines) == 3 and lines[2] != "", lines)
    if not gone:
        return
    pressed = status(tab, press="reload").get("pressed") == "1"
    back = pressed and wait(lambda: status(tab).get("gone") == "0" and js(tab, "document.getElementById('alive')?.textContent") == "alive", 30, 0.5)
    check(f"{name}: Reload brings the page back", bool(back), f"pressed={pressed}")


HOST_TUNABLE = "browserHost.helperPrototype"
HOST_CRASH_URL = "chrome://inducebrowsercrashforrealz"


def host_state():
    return rpc("debug.chromium_host") or {}


def answers():
    return "error" not in (rpc("debug.crashes", timeout=5) or {"error": "no reply"})


def host_shows(title, previous_pid=None, restarts=None):
    """The host state once a host other than `previous_pid` shows the page titled `title`."""
    def ready():
        state = host_state()
        fresh = state.get("pid") and state.get("pid") != previous_pid
        counted = restarts is None or state.get("restarts", 0) >= restarts
        return state if fresh and counted and state.get("shown_context_id") and state.get("title") == title else None
    return wait(ready, 90, 0.25)


def host_kind(pid, url):
    """Kind 5: the Chromium host app ends (SIGKILL, then Chromium's own crash URL); cmux stays up."""
    probe = rpc("debug.chromium_host")
    if not isinstance(probe, dict) or "error" in probe:
        return skip("host", f"this build has no debug.chromium_host (Debug builds only): {(probe or {}).get('error')}")
    tunable = rpc("debug.tunables", {"action": "get", "key": HOST_TUNABLE}) or {}
    if "error" in tunable or "value" not in tunable:
        return skip("host", f"this build has no {HOST_TUNABLE} tunable: {tunable.get('error')}")
    was_on = tunable.get("value") is True
    if not was_on:
        rpc("debug.tunables", {"action": "set", "key": HOST_TUNABLE, "value": True})
    try:
        opened = rpc("debug.chromium_host", {"op": "open", "url": url}) or {}
        if "this build has no Chromium host app" in str(opened.get("error")):
            return skip("host", opened["error"])
        if not check("host: the host app starts", "error" not in opened, opened):
            return
        first = host_shows("crash-e2e")
        if not check("host: the host page loads the page", bool(first), host_state()):
            return
        host = int(first["pid"])
        check("host: the browser process runs in a host app, not in cmux", host != pid and first.get("app_pid") == pid, first)
        if not check("host: the host is a child of the app", parent_of(host) == pid, parent_of(host)):
            return

        os.kill(host, signal.SIGKILL)
        print(f"killed Chromium host {host}", flush=True)
        check("host: app still runs after the host is killed", alive(pid))
        restarted = host_shows("crash-e2e", previous_pid=host, restarts=1)
        check("host: a new host loads the saved page", bool(restarted), host_state())
        check("host: the app answers after the kill", answers())
        if not restarted:
            return

        second = int(restarted["pid"])
        known_exits = len(restarted.get("exits") or [])
        rpc("debug.chromium_host", {"op": "open", "url": HOST_CRASH_URL})
        print(f"navigated host {second} to {HOST_CRASH_URL}", flush=True)
        # A second end within ChromiumHostRestartPolicy.quickEnd (60 s) keeps the host ended; if the
        # restarted host ran longer, it restarts once on the crash URL and that end stops it.
        ended = wait(lambda: (lambda s: s if str(s.get("phase", "")).startswith("ended") else None)(host_state()), 90, 0.25)
        state = ended or host_state()
        crashes = (state.get("exits") or [])[known_exits:]
        check("host: Chromium's crash URL ends the host", bool(ended) and not alive(second), state)
        check("host: the host ended by its own crash, not a kill", bool(crashes) and crashes[0] != f"signal {int(signal.SIGKILL)}", crashes)
        check("host: app still runs after the host crashes", alive(pid))
        check("host: the crashed host stays ended with no page shown", bool(ended) and not state.get("shown_context_id"), state)
        check("host: the app answers after the crash", answers())

        last = int(state.get("pid") or second)
        reopened = rpc("debug.chromium_host", {"op": "open", "url": url}) or {}
        back = "error" not in reopened and host_shows("crash-e2e", previous_pid=last)
        check("host: opening the page again starts a new host with it", bool(back), back or reopened or host_state())
    finally:
        rpc("debug.chromium_host", {"op": "close"})
        if not was_on:
            rpc("debug.tunables", {"action": "set", "key": HOST_TUNABLE, "value": None})


def main():
    pid = app_pid()
    if not pid or not alive(pid):
        sys.exit(f"FAIL no app process for {opts.socket}")
    if not wait(lambda: "error" not in (rpc("debug.crashes", timeout=5) or {"error": "no reply"}), 60):
        sys.exit("FAIL the app does not answer on its socket")
    url = serve()
    only = set(opts.only.split(","))
    print(f"app pid {pid}, page {url}", flush=True)

    # First, while the window still shows its New Tab page (an agent page).
    if "agent" in only:
        # Any agent page: the reply names them when none is focused.
        probe = rpc("debug.agent_pane", {"action": "pid"}) or {}
        pane = probe.get("pane") or ((probe.get("agent_panes") or [None])[0])
        if not pane:
            run("newTab")  # a new workspace opens on the New Tab page, an agent page
            probe = wait(lambda: (lambda r: r if r.get("pid") else None)(rpc("debug.agent_pane", {"action": "pid"}) or {}), 30) or {}
            pane = probe.get("pane")
        reply = (rpc("debug.agent_pane", {"action": "pid", "pane": pane}) or {}) if pane else probe
        page = reply.get("pid")
        if check("agent: an agent page reports its WebContent process", bool(page), reply):
            os.kill(int(page), signal.SIGKILL)
            print(f"killed agent WebContent {int(page)}", flush=True)
            time.sleep(1.0)  # test harness wait: WebKit reports the process ended
            check("agent: app still runs", alive(pid))
            fresh = wait(lambda: (lambda p: p if p and p != page else None)((rpc("debug.agent_pane", {"action": "pid", "pane": pane}) or {}).get("pid")), 30)
            check("agent: the page reloads in a new WebContent process", bool(fresh), fresh)
            # A page that keeps crashing stops reloading (PageCrashReloads: 3 reloads in 10 minutes)
            # and offers Reload instead; Reload starts it again.
            notice, current = None, fresh
            for crash in range(2, 6):
                if not current:
                    break
                os.kill(int(current), signal.SIGKILL)
                notice = wait(lambda: (lambda r: r if r.get("shown") else None)(rpc("debug.agent_pane", {"action": "crash_notice", "pane": pane}) or {}), 3)
                if notice:
                    break
                previous = current
                current = wait(lambda: (lambda p: p if p and p != previous else None)((rpc("debug.agent_pane", {"action": "pid", "pane": pane}) or {}).get("pid")), 30)
            print(f"agent: notice after crash {crash}", flush=True)
            texts = (notice or {}).get("texts") or []
            check("agent: a page that keeps crashing shows the crashed page with Reload", len(texts) == 2 and all(texts), texts)
            check("agent: app still runs after repeated crashes", alive(pid))
            if notice:
                pressed = (rpc("debug.agent_pane", {"action": "crash_notice", "pane": pane, "press": "reload"}) or {}).get("pressed")
                back = pressed and wait(lambda: (lambda p: p if p and p != current else None)((rpc("debug.agent_pane", {"action": "pid", "pane": pane}) or {}).get("pid")), 30)
                gone = not (rpc("debug.agent_pane", {"action": "crash_notice", "pane": pane}) or {}).get("shown")
                check("agent: Reload starts the page again", bool(back) and gone, f"pressed={pressed} pid={back}")

    cef_tab = None
    if only & {"renderer", "gpu"}:
        before = set(children(pid, "renderer"))
        cef_tab = open_tab("cef", url)
        if cef_tab and "renderer" in only:
            renderers = wait(lambda: sorted(set(children(pid, "renderer")) - before), 10)
            if check("renderer: the Chromium tab has its own renderer process", bool(renderers), children(pid, "renderer")):
                for renderer in renderers:
                    os.kill(renderer, signal.SIGKILL)
                print(f"killed renderer {renderers}", flush=True)
                sad_tab_reloads("renderer", cef_tab, pid)
        if cef_tab and "gpu" in only:
            gpus = children(pid, "gpu-process")
            if check("gpu: Chromium runs a GPU process", bool(gpus)):
                for gpu in gpus:
                    os.kill(gpu, signal.SIGKILL)
                print(f"killed gpu-process {gpus}", flush=True)
                time.sleep(2.0)  # test harness wait: Chromium notices the GPU process ended
                check("gpu: app still runs", alive(pid))
                restarted = wait(lambda: set(children(pid, "gpu-process")) - set(gpus), 20)
                check("gpu: Chromium starts a new GPU process", bool(restarted), children(pid, "gpu-process"))
                if status(cef_tab).get("gone") == "1":
                    sad_tab_reloads("gpu", cef_tab, pid)
                answers = wait(lambda: js(cef_tab, "document.getElementById('alive')?.textContent") == "alive", 30, 0.5)
                check("gpu: the Chromium tab's page still answers", bool(answers))

    if "webkit" in only:
        tab = open_tab("webkit", url)
        page = tab and wait(lambda: status(tab).get("page_pid"), 20)
        if check("webkit: the WebKit tab reports its WebContent process", bool(page), status(tab) if tab else None):
            os.kill(int(page), signal.SIGKILL)
            print(f"killed WebContent {page}", flush=True)
            sad_tab_reloads("webkit", tab, pid)
            fresh = status(tab).get("page_pid")
            check("webkit: the page runs in a new WebContent process", bool(fresh) and fresh != page, fresh)

    # Last: the host page covers the focused pane until it closes.
    if "host" in only:
        host_kind(pid, url)

    check("app still runs at the end", alive(pid))
    if failures:
        sys.exit(f"FAIL {len(failures)}: {', '.join(failures)}")
    if skips:
        print(f"PASS every child process crash that ran is contained; skipped: {', '.join(skips)}")
    else:
        print("PASS every child process crash is contained")


main()
