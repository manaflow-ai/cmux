#!/usr/bin/env python3
"""Passkey availability parity and the GitHub "partial passkey support" check
(plans/cmux-next/passkeys.md K19 and section 7.2).

For each page (the local test RP, https://webauthn.io, https://passkeys.dev/device-support/,
https://github.com/login) it records, in a cmux CEF tab, a cmux WebKit tab and Google Chrome on
the same Mac:
  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
  PublicKeyCredential.isConditionalMediationAvailable()
  PublicKeyCredential.getClientCapabilities()
and, on github.com/login, whether the page shows "This browser or device is reporting partial
passkey support" (GitHub shows it when isUserVerifyingPlatformAuthenticatorAvailable() is false).

Judging (exit 1 on any FAIL):
- CEF: every capability Chrome reports true must be true in cmux, except where the cmux build
  cannot have it: userVerifyingPlatformAuthenticator / passkeyPlatformAuthenticator need the
  "<team>.<bundle>.webauthn" keychain group in the signed app (tagged DEV builds have none); a
  key Chrome has and cmux's Chromium does not know at all (version skew) is a NOTE.
- WebKit: uvpaa must be true when the app has com.apple.developer.web-browser.public-key-credential
  (and the person has not denied passkeys), else NOTE.
- GitHub: the text must not show where uvpaa is expected true. `--virtual-platform` adds a
  DevTools virtual platform authenticator to the CEF tab first (Debug builds), which makes
  Chromium report a platform authenticator, so a DEV build proves the page logic too.

Usage:
  passkeys-parity-e2e.py --socket SOCK --app "/path/cmux DEV x.app" [--engines cef,webkit]
      [--chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"] [--no-chrome]
      [--virtual-platform] [--pages rp,webauthn.io,passkeys.dev,github] [--out DIR]
Writes parity.json and parity.md to --out. The script attaches to a running app (never launches
or quits it) and runs Chrome with a throwaway profile, then quits that Chrome.
"""
import argparse, base64, functools, http.server, json, os, plistlib, shutil, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser()
parser.add_argument("--socket", help="the cmux app's control socket (omit for Chrome only)")
parser.add_argument("--app", help="the cmux .app bundle (to read its signed entitlements)")
parser.add_argument("--engines", default="cef,webkit")
parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
parser.add_argument("--no-chrome", action="store_true")
parser.add_argument("--chrome-headed", action="store_true", help="run Chrome with a window (default headless=new)")
parser.add_argument("--virtual-platform", action="store_true", help="CEF: add a virtual platform authenticator (Debug builds)")
parser.add_argument("--pages", default="rp,webauthn.io,passkeys.dev,github")
parser.add_argument("--rp", default=os.path.join(HERE, "../../tests/passkeys/rp"))
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()

PAGES = {"webauthn.io": "https://webauthn.io/", "passkeys.dev": "https://passkeys.dev/device-support/",
         "github": "https://github.com/login"}
GITHUB_TEXT = "partial passkey support"
PLATFORM_KEYS = {"userVerifyingPlatformAuthenticator", "passkeyPlatformAuthenticator"}
# The probe stores its answer in the page; a second read collects it (page eval returns no promise).
PROBE = ("(async () => { const P = window.PublicKeyCredential; const out = {secure: window.isSecureContext};"
         " try { out.uvpaa = P ? await P.isUserVerifyingPlatformAuthenticatorAvailable() : 'no PublicKeyCredential'; } catch (e) { out.uvpaa = 'error ' + e.name; }"
         " try { out.conditional = P && P.isConditionalMediationAvailable ? await P.isConditionalMediationAvailable() : 'missing'; } catch (e) { out.conditional = 'error ' + e.name; }"
         " try { out.caps = P && P.getClientCapabilities ? await P.getClientCapabilities() : 'missing'; } catch (e) { out.caps = 'error ' + e.name; }"
         " out.ua = navigator.userAgent; window.__cmuxParity = out; return out; })()")
GITHUB_SHOWS = f"(document.body && document.body.innerText.includes({json.dumps(GITHUB_TEXT)}))"
ROWS = []


def row(engine, page, check, status, detail):
    ROWS.append({"engine": engine, "page": page, "check": check, "status": status, "detail": detail})
    print(f"{status:5} | {engine:7} | {page:12} | {check:34} | {str(detail)[:200]}", flush=True)


def wait(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live page
    return None


# --- entitlements of the cmux build ---------------------------------------------------------

def entitlements(app):
    if not app:
        return {}
    out = subprocess.run(["codesign", "-d", "--entitlements", ":-", app], capture_output=True)
    try:
        return plistlib.loads(out.stdout) if out.stdout.strip() else {}
    except Exception:
        return {}


ENT = entitlements(opts.app)
HAS_WEBAUTHN_GROUP = any(str(g).endswith(".webauthn") for g in ENT.get("keychain-access-groups", []))
HAS_BROWSER_ENTITLEMENT = ENT.get("com.apple.developer.web-browser.public-key-credential") is True


# --- cmux app over its socket ------------------------------------------------------------------

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


def run_action(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True, "confirm": True})


def cmux_js(tab, script):
    reply = rpc("browser.page.eval", {"tab": tab, "script": script}) or {}
    return reply.get("value") if "error" not in reply else {"__error": reply.get("error")}


def devtools(method, params=None):
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}}) or {}
    return {"__error": reply["error"]} if reply.get("error") else reply


class CmuxTab:
    def __init__(self, engine, url):
        self.engine = engine
        opened = wait(lambda: (lambda r: r if (r or {}).get("created") else None)(run_action("openBrowser", {"url": url, "engine": engine})), 90, 3)
        created = (opened or {}).get("created") or []
        self.tab = created[0] if created else None

    def ready(self):
        return bool(self.tab) and wait(lambda: cmux_js(self.tab, "document.readyState") == "complete", 45, 1)

    def probe(self):
        cmux_js(self.tab, "window.__cmuxParity = null; " + PROBE)
        return wait(lambda: (lambda v: v if isinstance(v, dict) and "__error" not in v else None)(cmux_js(self.tab, "window.__cmuxParity")), 15)

    def eval(self, script):
        return cmux_js(self.tab, script)

    def close(self):
        if self.tab:
            run_action("closeTab")
            time.sleep(1)  # test harness: the next tab takes the pane


# --- Google Chrome over the DevTools protocol (stdlib WebSocket) ------------------------------

class WebSocket:
    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.sock.recv(1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise OSError(f"websocket upgrade refused: {head[:80]!r}")
        self.next_id = 0

    def _read_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise OSError("websocket closed")
            data += chunk
        return data

    def _recv_text(self):
        message = b""
        while True:
            b0, b1 = self._read_exact(2)
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            payload = self._read_exact(length)
            if b0 & 0x0F in (0x1, 0x0):
                message += payload
                if b0 & 0x80:
                    return message.decode()

    def call(self, method, params=None):
        self.next_id += 1
        data = json.dumps({"id": self.next_id, "method": method, "params": params or {}}).encode()
        header = bytes([0x81]) + (bytes([0x80 | len(data)]) if len(data) < 126 else bytes([0x80 | 126]) + struct.pack(">H", len(data)) if len(data) < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", len(data)))
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
        while True:
            reply = json.loads(self._recv_text())
            if reply.get("id") == self.next_id:
                return reply


class Chrome:
    def __init__(self, binary, headed):
        self.profile = tempfile.mkdtemp(prefix="cmux-passkeys-chrome-")
        args = [binary, f"--user-data-dir={self.profile}", "--remote-debugging-port=0", "--no-first-run",
                "--no-default-browser-check", "--disable-sync", "about:blank"]
        if not headed:
            args.insert(1, "--headless=new")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        port_file = os.path.join(self.profile, "DevToolsActivePort")
        self.port = wait(lambda: open(port_file).read().split("\n")[0] if os.path.exists(port_file) else None, 30)
        version = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=10))
        self.version = version.get("Browser")

    def open(self, url):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/json/new?{url}", method="PUT")
        target = json.load(urllib.request.urlopen(req, timeout=15))
        return ChromeTab(target)

    def quit(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)


class ChromeTab:
    engine = "chrome"

    def __init__(self, target):
        self.ws = WebSocket(target["webSocketDebuggerUrl"])
        self.tab = target["id"]

    def ready(self):
        return wait(lambda: self.eval("document.readyState") == "complete", 45, 1)

    def eval(self, script, await_promise=False):
        reply = self.ws.call("Runtime.evaluate", {"expression": script, "awaitPromise": await_promise, "returnByValue": True})
        return ((reply.get("result") or {}).get("result") or {}).get("value")

    def probe(self):
        return self.eval(PROBE, await_promise=True)

    def close(self):
        self.ws.sock.close()


# --- judging -------------------------------------------------------------------------------------

def expected_uvpaa(engine):
    if engine == "cef":
        return HAS_WEBAUTHN_GROUP or opts.virtual_platform
    if engine == "webkit":
        return HAS_BROWSER_ENTITLEMENT
    return True


def judge_against_chrome(engine, page, probe, chrome):
    caps = probe.get("caps") if isinstance(probe.get("caps"), dict) else {}
    ccaps = chrome.get("caps") if isinstance(chrome.get("caps"), dict) else {}
    for key in sorted(k for k, v in ccaps.items() if v is True):
        value = caps.get(key)
        if value is True:
            row(engine, page, f"cap {key}", "PASS", "true, as Chrome")
        elif key in PLATFORM_KEYS and not expected_uvpaa(engine):
            row(engine, page, f"cap {key}", "NOTE", f"{value} (expected: this build has no platform authenticator group/entitlement)")
        elif value is None and engine == "cef":
            row(engine, page, f"cap {key}", "NOTE", "unknown to this Chromium (version skew with Chrome)")
        elif engine == "webkit":
            row(engine, page, f"cap {key}", "NOTE", f"{value} (WebKit; recorded, not judged)")
        else:
            row(engine, page, f"cap {key}", "FAIL", f"{value}; Chrome reports true")
    if chrome.get("conditional") is True:
        status = "PASS" if probe.get("conditional") is True else ("NOTE" if engine == "webkit" else "FAIL")
        row(engine, page, "isConditionalMediationAvailable", status, f"{probe.get('conditional')} (Chrome true)")


def check(tab, page_name, chrome_probe=None):
    engine = tab.engine
    if not tab.ready():
        row(engine, page_name, "(load)", "FAIL", "page did not load")
        return None
    probe = tab.probe()
    if not isinstance(probe, dict):
        row(engine, page_name, "(probe)", "FAIL", f"no answer: {probe}")
        return None
    uv = probe.get("uvpaa")
    if engine == "chrome":
        row(engine, page_name, "isUVPAA", "NOTE", f"{uv}; caps {json.dumps(probe.get('caps'))}")
    elif expected_uvpaa(engine):
        row(engine, page_name, "isUVPAA", "PASS" if uv is True else "FAIL", uv)
    else:
        row(engine, page_name, "isUVPAA", "NOTE", f"{uv} (this build cannot have a platform authenticator)")
    if chrome_probe and engine != "chrome":
        judge_against_chrome(engine, page_name, probe, chrome_probe)
    if page_name == "github":
        # GitHub's webauthn-get element reads uvpaa after its fragment loads.
        shows = wait(lambda: tab.eval(GITHUB_SHOWS) is True, 10, 1)
        if engine == "chrome" or expected_uvpaa(engine):
            row(engine, page_name, "no 'partial passkey support'", "FAIL" if shows else "PASS",
                "the text shows" if shows else "not shown after 10 s")
        else:
            row(engine, page_name, "no 'partial passkey support'", "NOTE", f"shows={bool(shows)} (expected in this build)")
    return probe


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(
        type("Quiet", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *a: None}), directory=os.path.abspath(opts.rp)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    pages = dict(PAGES, rp=f"http://localhost:{server.server_address[1]}/")
    wanted = [p for p in opts.pages.split(",") if p in pages]
    print(f"build: webauthn group {HAS_WEBAUTHN_GROUP}, browser entitlement {HAS_BROWSER_ENTITLEMENT}, app {opts.app}", flush=True)

    chrome_probes = {}
    if not opts.no_chrome and os.path.exists(opts.chrome):
        chrome = Chrome(opts.chrome, opts.chrome_headed)
        print("chrome", chrome.version, flush=True)
        try:
            for name in wanted:
                tab = chrome.open(pages[name])
                chrome_probes[name] = check(tab, name)
                tab.close()
        finally:
            chrome.quit()
    elif not opts.no_chrome:
        row("chrome", "-", "(launch)", "NOTE", f"no Chrome at {opts.chrome}")

    if opts.socket:
        if not wait(lambda: "error" not in (rpc("system.identify") or {"error": 1}), 90):
            sys.exit("the app does not answer")
        for engine in opts.engines.split(","):
            for name in wanted:
                tab = CmuxTab(engine, pages[name])
                if engine == "cef" and opts.virtual_platform and tab.ready():
                    # The virtual environment belongs to the focused tab (this one) and survives a
                    # reload; reload so the page's load-time checks (GitHub's) see the authenticator.
                    devtools("WebAuthn.enable", {"enableUI": False})
                    devtools("WebAuthn.addVirtualAuthenticator", {"options": {"protocol": "ctap2", "transport": "internal",
                             "hasResidentKey": True, "hasUserVerification": True, "isUserVerified": True, "automaticPresenceSimulation": True}})
                    tab.eval("location.reload()")
                    time.sleep(2)  # test harness: the reload starts before readyState is read again
                check(tab, name, chrome_probes.get(name))
                if engine == "cef" and opts.virtual_platform:
                    devtools("WebAuthn.disable")
                tab.close()

    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, "parity.json"), "w") as handle:
        json.dump({"webauthn_group": HAS_WEBAUTHN_GROUP, "browser_entitlement": HAS_BROWSER_ENTITLEMENT,
                   "chrome": chrome_probes, "rows": ROWS}, handle, indent=1)
    with open(os.path.join(opts.out, "parity.md"), "w") as handle:
        handle.write("| Engine | Page | Check | Status | Detail |\n| --- | --- | --- | --- | --- |\n")
        for r in ROWS:
            handle.write(f"| {r['engine']} | {r['page']} | {r['check']} | {r['status']} | {str(r['detail'])[:160].replace('|', '/')} |\n")
    judged = [r for r in ROWS if r["status"] in ("PASS", "FAIL")]
    failed = [r for r in judged if r["status"] == "FAIL"]
    print(f"RESULT {len(judged) - len(failed)}/{len(judged)}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
