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

  8. (Chromium gaps, ask-2d244f2b2e) target=_blank implies noopener, rel=opener keeps it, noreferrer drops the
     Referer, a named target is reused;
  9. COOP: same-origin on the opener, or on a popup, severs window.opener; same-origin-allow-popups keeps it
     for a popup with no COOP;
 10. a popup whose OAuth flow ends on a custom scheme (script or 302), and the main tab doing the same: the
     person is asked (a prompt the window shows), never a silent hang;
 11. a popup opened by an agent's tab does not take the focus, and the agent can list it;
 12. window.open from a same-origin iframe keeps its opener and gets the code back;
 13. a popup's opener.location redirect-back lands the opener on the callback;
 14. a download mid-login (popup sent to an attachment, or a link in the page) completes and leaves the tab;
 15. an HTTP 401 Basic challenge asks for credentials (a prompt), and user:pw in the URL answers it.

Exits 1 on any failure. Run on a GUI host that may draw (offscreen on Leo's Macs).
"""
import argparse, json, socket, subprocess, sys, time, os, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--only", default="", help="comma list of case numbers 8..15 (default: all)")
parser.add_argument("--engine", choices=("chromium", "webkit"), default="chromium")
opts = parser.parse_args()
HERE = os.path.dirname(os.path.abspath(__file__))
failures = []


def cli(*args, agent=True):
    out = subprocess.run(["cmux", "--app-socket", opts.socket, "browser", "right", *args, *(["--agent", "authflows"] if agent else [])],
                         capture_output=True, text=True, timeout=60)
    return out.stdout + out.stderr


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


def rpc(method, params=None, timeout=20):
    """The app's control socket (DEBUG builds answer debug.*): {} when it does not."""
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
        return (reply.get("result") if reply.get("ok") else {"error": reply.get("error")}) or {}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def reports():
    try:
        return json.loads(urllib.request.urlopen(f"http://127.0.0.1:{opts.port}/reports", timeout=5).read())
    except (OSError, ValueError):
        return {}


def report(key, wait=8):
    """What the page `key` told the fixture (it fetches /report once loaded): {} if it never did."""
    end = time.monotonic() + wait
    while time.monotonic() < end:
        got = reports().get(key)
        if got is not None:
            return got
        time.sleep(0.5)
    return {}


def debug_or_release(debug, release, params=None):
    """A DEBUG build's `debug.*` method, else (a release NIGHTLY registers none) its
    read-only release twin (BrowserPromptsControl), so a NIGHTLY is judged, not failed."""
    reply = rpc(debug, params)
    return rpc(release, params) if "error" in reply else reply


def popups():
    return (debug_or_release("debug.popups", "browser.popups").get("panels") or [])


def prompts_of_tab():
    return (debug_or_release("debug.browser.prompts", "browser.prompts", {"tab": TAB} if TAB else None).get("prompts") or [])


def click(selector):
    ev(f"document.querySelector({json.dumps(selector)}).click();1")


def case(n):
    return not opts.only or str(n) in opts.only.split(",")


def close_popups():
    debug_or_release("debug.popups", "browser.popups", {"action": "close"})


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

    # ---- Chromium gaps (ask-2d244f2b2e): each its own try, so one broken case never hides the rest --------
    def run(n, fn):
        if not case(n):
            return
        try:
            fn()
        except Exception as error:  # a harness error is a failure to read, not an ok
            check(False, f"case {n} did not run: {error!r}")
        finally:
            close_popups()

    def c8():
        urllib.request.urlopen(f"http://127.0.0.1:{opts.port}/reset").read()
        nav(RP + "/links")
        for sel, key in (("#l_blank", "blank"), ("#l_noopener", "noopener"), ("#l_noreferrer", "noreferrer"), ("#l_opener", "relopener")):
            click(sel); time.sleep(1.5)
        got = {k: report(k) for k in ("blank", "noopener", "noreferrer", "relopener")}
        check(got["blank"].get("opener") == "false", f"target=_blank link has no opener, as Chrome ({got['blank']})")
        check(got["noopener"].get("opener") == "false", f"rel=noopener link has no opener ({got['noopener']})")
        check(got["relopener"].get("opener") == "true", f"rel=opener on target=_blank keeps the opener ({got['relopener']})")
        refs = reports().get("ref", {})
        check(got["noreferrer"].get("opener") == "false" and refs.get("noreferrer") == "(none)",
              f"rel=noreferrer sends no Referer and no opener (referer {refs.get('noreferrer')})")
        check(refs.get("noopener", "(none)") != "(none)", f"rel=noopener still sends the Referer ({refs.get('noopener')})")
        click("#l_named"); time.sleep(1.5); click("#l_named"); time.sleep(1.5)
        check(report("named").get("name") == "named_win", f"a named target opens with that window name ({report('named')})")

    def coop(opener_coop, popup_coop, key, want):
        urllib.request.urlopen(f"http://127.0.0.1:{opts.port}/reset").read()
        q = (f"coop={opener_coop}&" if opener_coop else "") + (f"popupcoop={popup_coop}&" if popup_coop else "") + f"k={key}"
        nav(RP + "/coopopener?" + q)
        click("#go"); time.sleep(2)
        got = report(key)
        check(got.get("opener") == want, f"COOP opener={opener_coop or 'none'} popup={popup_coop or 'none'}: window.opener {want} in the popup ({got})")

    def c9():
        coop("same-origin", "", "coopA", "false")
        coop("same-origin-allow-popups", "", "coopB", "true")
        coop("", "same-origin", "coopC", "false")
        coop("", "", "coopD", "true")

    def scheme(via, in_popup, key):
        what = f"{'popup' if in_popup else 'main tab'} ending on a custom scheme by {via}"
        rpc("debug.browser.external_opens", {"clear": True})
        if in_popup:
            nav(RP + f"/schemeopen?via={via}&to=" + urllib.parse.quote("vscode://auth?code=1", safe=""))
            click("#go")
        else:
            nav(RP + "/cb?via=" + via + "&to=" + urllib.parse.quote("vscode://auth?code=1", safe=""), settle=1)
        time.sleep(4)
        shown = [p for p in popups() if p.get("prompt_shown")] if in_popup else None
        pending = [p for p in popups() if p.get("prompts")] if in_popup else prompts_of_tab()
        opened = rpc("debug.browser.external_opens").get("urls") or []
        check(bool(pending) or bool(opened), f"{what}: asked or opened, not silent ({pending or opened})")
        if in_popup:
            check(bool(shown), f"{what}: the popup window shows the question ({[p.get('prompts') for p in popups()]})")

    def c10():
        for via in ("js", "302"):
            scheme(via, False, "m")
            close_popups()
            scheme(via, True, "p")
            close_popups()

    def c11():
        before = rpc("system.identify")
        nav(RP + "/schemeopen")
        click("#go"); time.sleep(3)
        panels = popups()
        listing = cli("tabs", "--all")
        keyed = [p for p in panels if p.get("key")]
        check(not keyed, f"an agent tab's popup does not take key focus ({[(p.get('url'), p.get('key')) for p in panels]})")
        check(bool(panels) or "127.0.0.1" in listing, f"the agent can find the popup it opened ({listing.strip()[:200]})")

    def c12():
        urllib.request.urlopen(f"http://127.0.0.1:{opts.port}/reset").read()
        nav(RP + "/iframeopen")
        ev("document.querySelector('#fr').contentDocument.querySelector('#go').click();1"); time.sleep(3)
        check('"code":"abc"' in ev("JSON.stringify(__m)"), f"window.open from a same-origin iframe gets the code back ({ev('JSON.stringify(__m)')})")

    def c13():
        nav(RP + "/openerrp")
        click("#go"); time.sleep(4)
        check(ev("location.href") == RP + "/done?code=9", f"popup sets opener.location and the opener lands on the callback ({ev('location.href')})")

    def c14():
        nav(RP + "/dlflow")
        before = cli("download", "list")
        click("#dl"); time.sleep(3)
        after = cli("download", "list")
        check("login.bin" in after and after != before, f"a link to an attachment downloads and the page stays ({after.strip()[-160:]})")
        check(ev("location.pathname") == "/dlflow", "the tab stays on the login page after the download")
        click("#go"); time.sleep(4)
        n = cli("download", "list").count("login.bin")
        check(n >= 2, f"a popup sent to an attachment downloads it ({n} login.bin downloads listed)")
        check(ev("location.pathname") == "/dlflow", "the opener stays on the login page after the popup's download")

    def c15():
        nav(IDP + "/basic", settle=3)
        asked = [p for p in prompts_of_tab() if "credentials" in p.get("kind", "").lower() or "auth" in p.get("kind", "").lower()]
        check(bool(asked), f"a 401 Basic challenge asks for credentials ({prompts_of_tab()}, page: {ev('document.title')})")
        nav(f"http://user:pw@127.0.0.1:{opts.port}/basic", settle=3)
        check(ev("document.title") == "basic ok", f"user:pw in the URL answers the challenge (title {ev('document.title')})")

    import urllib.parse
    for n, fn in ((8, c8), (9, c9), (10, c10), (11, c11), (12, c12), (13, c13), (14, c14), (15, c15)):
        run(n, fn)
finally:
    server.terminate()
sys.exit(1 if failures else 0)
