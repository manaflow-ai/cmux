#!/usr/bin/env python3
"""Passkey feature matrix (plans/cmux-next/passkeys.md section 7, cx-d0d.5) in a running cmux-next
app's CEF tab and WebKit tab. Serves the test RP (tests/passkeys/rp) on localhost, opens it in each
engine and runs every scenario through `browser.page.eval`.

CEF: each scenario gets a fresh DevTools virtual authenticator (`debug.cef.devtools`
WebAuthn.addVirtualAuthenticator, as tests/passkeys/run.mjs does), so no Touch ID is involved;
`debug.cef.devtools` needs a Debug build. WebKit has no virtual authenticator: it runs the
scenarios that need none, and the rest are SKIP. `--no-virtual-authenticator` does the same in
CEF (a Release build). Both engines report the page's availability probe first (K1).

The script attaches to the app through its socket and never launches or quits it.

`--k16` (cx-d0d.47, passkeys.md K16) runs instead: in a CEF tab, create-platform with the page
uncovered, then with the command palette open over part of it, then (the control) in a
background tab, which Chromium must refuse. Chromium runs a ceremony only
while the tab's WebContents is VISIBLE, so a partly covered tab must still complete it.

Usage: passkeys-matrix-e2e.py --socket SOCK [--engines cef,webkit] [--only a,b] [--no-virtual-authenticator] [--k16]
Writes passkeys.json to --out. Exit status 0 when every judged scenario passes.
"""
import argparse, functools, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--engines", default="cef,webkit")
parser.add_argument("--only", default="", help="scenario names, comma separated")
parser.add_argument("--no-virtual-authenticator", action="store_true", help="Release builds: no debug.cef.devtools")
parser.add_argument("--rp", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../tests/passkeys/rp"))
parser.add_argument("--out", default="/tmp")
parser.add_argument("--k16", action="store_true", help="the partly-covered CEF tab check only")
opts = parser.parse_args()
SOCK = opts.socket
NO_AUTHENTICATOR = ["client-capabilities", "user-id-too-long", "insecure-rp-id", "cross-origin-iframe-denied",
                    "opaque-origin-iframe-uvpa", "sandboxed-iframe-create", "abort-modal"]
ROWS = []


def rpc(method, params=None, timeout=40):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCK)
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
    return reply.get("value") if "error" not in reply else {"__error": reply.get("error")}


def devtools(method, params=None):
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}}) or {}
    if reply.get("error"):
        return {"__error": reply["error"]}
    try:
        return json.loads(reply.get("result") or "{}")
    except ValueError:
        return {"raw": reply.get("result")}


class Quiet(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


def row(engine, name, status, detail):
    ROWS.append({"engine": engine, "scenario": name, "status": status, "detail": detail})
    print(f"{status} | {engine:6} | {name:30} | {str(detail)[:220]}", flush=True)


def click_go(tab, name):
    """A trusted click on the #go button of the scenario's cross-origin frame (CEF)."""
    rect = wait(lambda: js(tab, f"(() => {{ const f = document.querySelector('iframe[data-scenario=\"{name}\"]');"
                                 " if (!f) return null; const r = f.getBoundingClientRect(); return [r.x, r.y]; })()"), 10)
    if not isinstance(rect, list):
        frames = js(tab, "JSON.stringify([...document.querySelectorAll('iframe')].map(f => [f.dataset.scenario, f.src]))")
        return f"no frame (got {rect}; iframes {frames})"
    time.sleep(1.0)  # test harness: the frame document loads
    x, y = rect[0] + 20, rect[1] + 18
    for kind in ("mousePressed", "mouseReleased"):
        devtools("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})
    return f"clicked {x:.0f},{y:.0f}"


def scenario(engine, tab, name, spec):
    authenticator = None
    note = ""
    if engine == "cef" and not opts.no_virtual_authenticator:
        devtools("WebAuthn.enable", {"enableUI": False})
        added = devtools("WebAuthn.addVirtualAuthenticator",
                         {"options": {"automaticPresenceSimulation": True, **(spec.get("authenticator") or {})}})
        authenticator = added.get("authenticatorId")
        # The socket gives async methods ~2 s; a DevTools call past that still runs (`not_run`
        # false), so a timed-out add can still have attached the authenticator.
        # CEF's in-process DevTools loses this reply (timedOut after its own 5 s) while the
        # call runs; the 6 s socket deadline (2026-10-14) now reports that instead of not_run.
        lost = "not_run': False" in str(added) or ("timedOut" in str(added) and "addVirtualAuthenticator" in str(added))
        if not authenticator and not lost:
            return "FAIL", f"no virtual authenticator: {added}"
        note = "" if authenticator else "authenticator add timed out (sent); "
    started = js(tab, "(() => { window.__pk = null; runPasskeyScenario(" + json.dumps(name) + ")"
                      ".then(r => { window.__pk = r; }, e => { window.__pk = {pass: false, detail: String(e)}; });"
                      " return 'started'; })()")
    if started != "started":
        return "FAIL", f"could not start: {started}"
    if (spec.get("frame") or {}).get("click"):
        note = click_go(tab, name) + "; "
    result = wait(lambda: (lambda v: v if isinstance(v, dict) and v and "__error" not in v else None)(js(tab, "window.__pk")), 35, 0.5)
    if authenticator:
        devtools("WebAuthn.removeVirtualAuthenticator", {"authenticatorId": authenticator})
    if engine == "cef" and not opts.no_virtual_authenticator:
        devtools("WebAuthn.disable")  # drops every virtual authenticator, a timed-out one too
    if not result:
        js(tab, "location.reload()")
        time.sleep(2)  # test harness: a stuck scenario must not poison the next one
        return "FAIL", note + "did not settle in 35 s"
    status = {True: "PASS", False: "FAIL"}.get(result.get("pass"), "NOTE")
    return status, note + str(result.get("detail"))


def palette_open():
    return (rpc("debug.focus") or {}).get("context", {}).get("palette_open")


def k16(tab):
    """K16: a partly covered CEF tab stays VISIBLE, so its ceremony completes."""
    specs = js(tab, "JSON.stringify(window.PASSKEY_SCENARIOS['create-platform'].authenticator || {})")
    spec = {"authenticator": json.loads(specs) if isinstance(specs, str) else {}}
    judged = lambda status: "PASS" if status == "PASS" else "FAIL"
    status, detail = scenario("cef", tab, "create-platform", spec)
    row("cef", "k16 uncovered", judged(status), detail)
    run("commandPalette")
    if not wait(palette_open, 10):
        row("cef", "k16 palette over the tab", "FAIL", f"the palette did not open: {rpc('debug.focus')}")
        return
    status, detail = scenario("cef", tab, "create-platform", spec)
    still = palette_open()
    row("cef", "k16 palette over the tab", judged(status) if still else "FAIL",
        detail if still else f"the palette closed during the ceremony ({detail})")
    if palette_open():
        run("commandPalette")
    # The control: the same tab in the background is not VISIBLE, so Chromium refuses its ceremony
    # at once ("the page does not have focus": its IsFocused check is GetVisibility() == VISIBLE). `debug.cef.devtools` reaches the focused tab, so the authenticator goes on first.
    devtools("WebAuthn.enable", {"enableUI": False})
    devtools("WebAuthn.addVirtualAuthenticator", {"options": {"automaticPresenceSimulation": True, **spec["authenticator"]}})
    other = (run("openBrowser", {"url": "about:blank", "engine": "cef"}) or {}).get("created") or []
    time.sleep(2)  # test harness: the new tab takes the pane
    began = time.time()
    js(tab, "(() => { window.__pk = null; runPasskeyScenario('create-platform')"
            ".then(r => { window.__pk = r; }, e => { window.__pk = {pass: false, detail: String(e)}; }); })()")
    result = wait(lambda: (lambda v: v if isinstance(v, dict) and v and "__error" not in v else None)(js(tab, "window.__pk")), 35, 0.25)
    elapsed = time.time() - began
    detail = f"{(result or {}).get('detail')} after {elapsed:.1f} s"
    # Visibility refuses at once; the RP's own timeout is 20 s, so a slow refusal is not this check.
    refused = bool(result) and result.get("pass") is False and "NotAllowedError" in str(result.get("detail")) and elapsed < 5
    row("cef", "k16 control: background tab is refused", "PASS" if refused else "FAIL", detail)
    if other:
        run("closeTab")
        time.sleep(1)  # test harness: the RP tab is focused again
    devtools("WebAuthn.disable")


def main():
    if not wait(lambda: "error" not in (rpc("system.identify") or {"error": 1}), 90):
        sys.exit("the app does not answer")
    run("palette.closeOtherWorkspaces")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=os.path.abspath(opts.rp)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://localhost:{server.server_address[1]}/"
    print("RP", url, flush=True)
    only = [n for n in opts.only.split(",") if n]
    for engine in (["cef"] if opts.k16 else opts.engines.split(",")):
        # A first launch can keep the main thread busy past the socket's 2 s deadline (`not_run`).
        opened = wait(lambda: (lambda r: r if (r or {}).get("created") else None)(run("openBrowser", {"url": url, "engine": engine})), 90, 3)
        created = (opened or {}).get("created") or []
        tab = created[0] if created else None
        print(engine, "openBrowser", json.dumps(opened)[:200], flush=True)
        if not tab or not wait(lambda: js(tab, "typeof runPasskeyScenario") == "function", 60, 1):
            row(engine, "(setup)", "FAIL", f"RP did not load: {js(tab, 'location.href') if tab else opened}")
            continue
        # The eval hands back a promise as {}, so the page stores the answer for a second read.
        js(tab, "(async () => { window.__probe = {uvpa: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),"
                " conditional: await (PublicKeyCredential.isConditionalMediationAvailable?.() ?? 'missing'),"
                " capabilities: typeof PublicKeyCredential.getClientCapabilities, secure: window.isSecureContext,"
                " focused: document.hasFocus(),"
                # Without an authenticator CEF's dialog stays up, so only WebKit tries a plain get.
                + (" plainGet: await navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 3000}})"
                   ".then(() => 'resolved', e => e.name + ': ' + e.message)," if engine == "webkit" else "") +
                " ua: navigator.userAgent}; })()")
        probe = wait(lambda: js(tab, "window.__probe"), 10)
        row(engine, "probe (no authenticator)", "NOTE", json.dumps(probe))
        if opts.k16:
            k16(tab)
            break
        specs = js(tab, "JSON.stringify(Object.fromEntries(Object.entries(window.PASSKEY_SCENARIOS)"
                        ".map(([k, v]) => [k, {authenticator: v.authenticator, frame: v.frame}])))")
        specs = json.loads(specs) if isinstance(specs, str) else {}
        for name, spec in specs.items():
            if only and name not in only:
                continue
            if (engine == "webkit" or opts.no_virtual_authenticator) and name not in NO_AUTHENTICATOR:
                row(engine, name, "SKIP", "needs an authenticator; no virtual authenticator here")
                continue
            status, detail = scenario(engine, tab, name, spec)
            row(engine, name, status, detail)
        run("closeTab")
        time.sleep(1)  # test harness
    with open(os.path.join(opts.out, "passkeys.json"), "w") as handle:
        json.dump(ROWS, handle, indent=1)
    judged = [r for r in ROWS if r["status"] in ("PASS", "FAIL")]
    passed = sum(r["status"] == "PASS" for r in judged)
    print(f"RESULT {passed}/{len(judged)}", flush=True)
    return 0 if passed == len(judged) else 1


if __name__ == "__main__":
    sys.exit(main())
