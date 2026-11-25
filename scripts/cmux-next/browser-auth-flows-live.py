#!/usr/bin/env python3
"""Login flows on the Chromium or WebKit engine, against any running cmux (a `cmux app try .` copy or a tagged build).

  scripts/cmux-next/browser-auth-flows-live.py --socket PATH [--port 8765] [--engine chromium|webkit]

Serves a local fixture OAuth provider (browser-auth-flows-fixture/provider.py: relying party on
localhost, identity provider on 127.0.0.1, no real credentials) and drives one browser tab, opened by
`action.run openBrowser.<engine>`, over the control socket (the agent verbs of `cmux browser`). Checks, each as a fail-or-ok line:

  1. window.open popup (user gesture) keeps window.opener and postMessages the code back, origin intact;
  2. a popup with window features, same;
  3. a popup that calls window.close() reports closed to its opener;
  4. a script popup with no user activation is blocked (window.open returns null);
  5. a redirect across hosts lands on the final URL;
  6. SameSite=None; Secure cookie is stored, a non-Secure SameSite=None one is refused (as Chrome);
  7. an iframe on another host sees its own cookie and keeps its localStorage partitioned from the
     top-level site's.

Exits 1 on any failure. Run on a GUI host that may draw (offscreen on Leo's Macs).
"""
import argparse, json, socket, subprocess, sys, time, os

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--engine", choices=("chromium", "webkit"), default="chromium")
opts = parser.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
failures = []


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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


TAB = None


def open_tab(url):
    for _ in range(2):
        reply = rpc("action.run", {"action": "openBrowser." + opts.engine, "args": {"url": url}, "focus": True}, timeout=90)
        created = [c for c in (reply.get("created") or []) if str(c).startswith("tab_")]
        if created:
            return created[0]
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})  # a launch on Home has no pane
        time.sleep(2)
    sys.exit("could not open a " + opts.engine + " tab")


def ev(js):
    # An agent's eval runs as a user gesture (cmux's agent scripts do); a fresh other-origin page has none.
    reply = rpc("browser.page.eval", {"tab": TAB, "script": js}) or {}
    value = reply.get("value")
    return "" if value is None else (value if isinstance(value, str) else json.dumps(value))


def nav(url, settle=2):
    rpc("browser.page.navigate", {"tab": TAB, "url": url})
    time.sleep(settle)


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


RP, IDP = f"http://localhost:{opts.port}", f"http://127.0.0.1:{opts.port}"
server = subprocess.Popen([sys.executable, os.path.join(HERE, "browser-auth-flows-fixture/provider.py"), str(opts.port)])
try:
    time.sleep(1)
    TAB = open_tab(RP + "/rp")
    time.sleep(2)
    ev("window.__msgs=[];1")
    ev("document.querySelector('#gesture').click();1"); time.sleep(3)
    check(ev("String(window.__w)") == "true" and '"code":"abc"' in ev("JSON.stringify(__msgs)"),
          "popup keeps opener and postMessage reaches the opener")
    check(f'"origin":"{IDP}"' in ev("JSON.stringify(__msgs)"), "postMessage carries the provider's origin")
    ev("document.querySelector('#g2').click();1"); time.sleep(3)
    check(ev("window.__w2") == "true" and ev("__msgs.length") == "2", "popup with window features keeps opener")
    ev("window.__pc=window.open('" + IDP + "/idp/authorize?close=1','closer','popup,width=400,height=500');1"); time.sleep(4)
    check(ev("String(__pc.closed)") == "true", "popup's window.close() is seen by the opener")

    nav("https://example.com")
    nav(RP + "/auto", settle=4)
    check(ev("String(window.__autoResult)") == "false", "script popup without user activation is blocked")

    nav(RP + "/redir?to=" + IDP + "/idp/plain")
    check(ev("location.href") == IDP + "/idp/plain", "cross-host redirect lands on the final URL")

    nav(IDP + "/setcookie"); nav(IDP + "/cookies")
    got = ev("document.body.innerText")
    check("a=1" in got and "n=1" not in got and "l=1" in got, f"cookies: Secure SameSite=None and Lax kept, insecure None refused ({got})")

    nav(IDP + "/cookies"); ev("localStorage.setItem('k','toplevel');1")
    nav(RP + "/embed", settle=3)
    seen = ev("JSON.stringify(__m)")
    check('"cookie":"a=1"' in seen, f"iframe on another host sends and sees its cookie ({seen})")
    nav(IDP + "/idp/plain")
    check(ev("localStorage.getItem('k')") == "toplevel", "iframe localStorage is partitioned from the top-level site's")
finally:
    server.terminate()
sys.exit(1 if failures else 0)
