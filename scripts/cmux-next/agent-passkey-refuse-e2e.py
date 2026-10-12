#!/usr/bin/env python3
"""Agents never complete a passkey ceremony (plans/cmux-next/passkeys.md 3.5, cx-d0d.48), live in a
running cmux-next Debug build's CEF tab. Serves the test RP (tests/passkeys/rp/agent.html) on
localhost, opens it as an agent does (`openBrowser`, `browser.page.eval`) and clicks its buttons
with trusted input (`debug.cef.devtools` Input.dispatchMouseEvent), as an agent's click arrives.

The tab carries a DevTools virtual authenticator holding a passkey for the RP, so without the
refusal every request would succeed: the authenticator is the oracle that no ceremony ran (no
new credential, the passkey's sign count stays 0), and no real authenticator or Touch ID sheet
is reachable while it is attached. Checks:
  create, signin   an agent's click rejects with NotAllowedError at once (under 3 s)
  conditional      the page's autofill (conditional) request, started on load, rejects too
  authenticator    the virtual authenticator saw nothing (NOTE, not judged, when its id is unknown)
  notice           the tab shows cmux's refusal ("Sign in yourself") in its prompt bar
  disable          WebAuthn.disable from the agent does not lift the refusal
  popup            a popup the leased tab opens refuses too
  sign-in-yourself answering the notice reloads the page (the RP serves it again) and clears it

The script attaches to the app through its socket and never launches or quits it.

Usage: agent-passkey-refuse-e2e.py --socket SOCK [--rp DIR] [--out DIR]
Writes agent-passkey-refuse.json to --out. Exit status 0 when every check passes.
"""
import argparse, functools, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--rp", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../tests/passkeys/rp"))
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
SOCK = opts.socket
# A throwaway P-256 key (PKCS#8) for the virtual authenticator's passkey; it signs nothing real.
TEST_KEY = ("MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgUh6Unik7nJnIKGYVhev63X8J9bYcn1OelJlEoA+0Q+6hRANCAAST"
            "COn30gsE5XCjxnBtI1VSweiCUoSEvh4iTKOL3/UL4whGn+k5t/ldPNT5YofA2OhPITDBH3cV4lNfsouqd1rs")
FAST_MS = 3000
ROWS = []
SERVED = []


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
    # The socket gives async methods ~2 s; a DevTools call past that still runs (`not_run` false).
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}}) or {}
    if reply.get("error"):
        return {"__error": reply["error"]}
    try:
        return json.loads(reply.get("result") or "{}")
    except ValueError:
        return {"raw": reply.get("result")}


class Logged(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        SERVED.append(self.path)
        super().do_GET()

    def log_message(self, *args):
        pass


def check(name, ok, detail):
    status = "NOTE" if ok is None else "PASS" if ok else "FAIL"
    ROWS.append({"check": name, "status": status, "detail": detail})
    print(f"{status} | {name:18} | {str(detail)[:240]}", flush=True)


def click(tab, element_id):
    """A trusted click on #element_id, as an agent's click arrives (Input.dispatchMouseEvent)."""
    rect = wait(lambda: (lambda r: r if isinstance(r, list) else None)(
        js(tab, f"(() => {{ const r = document.getElementById('{element_id}').getBoundingClientRect();"
                " return [r.x + r.width / 2, r.y + r.height / 2]; })()")), 10)
    if not rect:
        return False
    for kind in ("mousePressed", "mouseReleased"):
        devtools("Input.dispatchMouseEvent", {"type": kind, "x": rect[0], "y": rect[1], "button": "left", "clickCount": 1})
    return True


def outcome(tab, name, seconds=30):
    value = wait(lambda: (lambda v: v if isinstance(v, dict) and "__error" not in v else None)(
        js(tab, f"window.__agent && window.__agent[{json.dumps(name)}] || null")), seconds, 0.5)
    return value


def refused(value):
    return bool(value) and value.get("error") == "NotAllowedError" and value.get("ms", FAST_MS) < FAST_MS


def agent_notice(tab):
    prompts = (rpc("debug.browser.prompts", {"tab": tab}) or {}).get("prompts") or []
    return [p for p in prompts if "agentPasskey" in str(p.get("kind"))]


def main():
    if not wait(lambda: "error" not in (rpc("system.identify") or {"error": 1}), 90):
        sys.exit("the app does not answer")
    run("palette.closeOtherWorkspaces")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Logged, directory=os.path.abspath(opts.rp)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://localhost:{server.server_address[1]}/agent.html"
    print("RP", url, flush=True)
    # A first launch can keep the main thread busy past the socket's 2 s deadline (`not_run`).
    opened = wait(lambda: (lambda r: r if (r or {}).get("created") else None)(run("openBrowser", {"url": url, "engine": "cef"})), 90, 3)
    tab = ((opened or {}).get("created") or [None])[0]
    if not tab or not wait(lambda: js(tab, "typeof window.__agent") == "object", 60, 1):
        check("setup", False, f"RP did not load: {opened}")
        return finish()

    authenticator, added = None, {}
    for _ in range(4):
        # The first DevTools WebAuthn calls can pass the socket's 2 s deadline (they still run):
        # start clean, so the one authenticator with a known id is the only one.
        devtools("WebAuthn.disable")
        devtools("WebAuthn.enable", {"enableUI": False})
        added = devtools("WebAuthn.addVirtualAuthenticator", {"options": {
            "protocol": "ctap2", "transport": "internal", "hasResidentKey": True, "hasUserVerification": True,
            "isUserVerified": True, "automaticPresenceSimulation": True}})
        authenticator = added.get("authenticatorId")
        if authenticator:
            break
        time.sleep(2)  # test harness: let the timed-out call finish
    # A DevTools call that times out was still sent (the socket's `not_run` false, or the tab's own wait).
    if not authenticator and "'not_run': False" not in str(added) and "timedOut" not in str(added):
        check("setup", False, f"no virtual authenticator: {added}")
        return finish()
    if authenticator:
        devtools("WebAuthn.addCredential", {"authenticatorId": authenticator, "credential": {
            "credentialId": "Y211eC1hZ2VudC1yZWZ1c2U", "isResidentCredential": True, "rpId": "localhost",
            "privateKey": TEST_KEY, "userHandle": "YWdlbnQ", "signCount": 0}})
    # Without its id (an app that answers DevTools past the socket deadline) the authenticator is
    # attached but holds no passkey: create runs first, so an unrefused sign-in still has one.

    # Before any click: a click aborts the page's autofill request (AbortError).
    value = outcome(tab, "conditional", 3)
    check("conditional", refused(value), value or "still pending: autofill would offer the passkey")
    for name, element in (("create", "create"), ("signin", "signin")):
        clicked = click(tab, element)
        value = outcome(tab, name)
        check(name, clicked and refused(value), value if clicked else "could not click")

    credentials = devtools("WebAuthn.getCredentials", {"authenticatorId": authenticator}).get("credentials") if authenticator else "id unknown: the add passed the socket deadline"
    unused = isinstance(credentials, list) and len(credentials) == 1 and credentials[0].get("signCount") == 0
    check("authenticator", unused if authenticator else None, [{"rpId": c.get("rpId"), "signCount": c.get("signCount")} for c in credentials]
          if isinstance(credentials, list) else credentials)

    notices = wait(lambda: agent_notice(tab), 5)
    check("notice", bool(notices), notices or (rpc("debug.browser.prompts", {"tab": tab}) or {}).get("prompts"))

    devtools("WebAuthn.disable")  # drops the virtual authenticator: a real request would reach the system now
    js(tab, "delete window.__agent.create")
    clicked = click(tab, "create")
    value = outcome(tab, "create", 25)
    check("disable", clicked and refused(value), value)

    clicked = click(tab, "popup")
    value = outcome(tab, "popup", 25)
    check("popup", clicked and refused(value), value)

    before = SERVED.count("/agent.html")
    answered = (rpc("debug.browser.prompts", {"tab": tab, "respond": "accept"}) or {}).get("responded")
    reloaded = wait(lambda: SERVED.count("/agent.html") > before, 15)
    cleared = not agent_notice(tab)
    check("sign-in-yourself", bool(answered and reloaded and cleared),
          {"responded": answered, "served again": bool(reloaded), "notice cleared": cleared})
    finish()


def finish():
    with open(os.path.join(opts.out, "agent-passkey-refuse.json"), "w") as handle:
        json.dump(ROWS, handle, indent=1)
    judged = [r for r in ROWS if r["status"] != "NOTE"]
    passed = sum(r["status"] == "PASS" for r in judged)
    print(f"RESULT {passed}/{len(judged)}", flush=True)
    sys.exit(0 if judged and passed == len(judged) else 1)


main()
