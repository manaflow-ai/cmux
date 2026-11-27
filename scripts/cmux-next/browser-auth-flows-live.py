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
  6. SameSite=None; Secure cookie is stored, a non-Secure SameSite=None one is refused (as Chrome); WebKit
     keeps it, as Safari does (WebKit never shipped "SameSite=None requires Secure");
  7. an iframe on another host sees its own cookie (Chromium: third-party cookies on, as Chrome) and keeps
     its localStorage partitioned from the top-level site's. WebKit blocks every third-party cookie, as
     Safari does (no public WKWebView switch); there an embedded sign-in must use the Storage Access API,
     so the check is that the cookie is withheld and document.requestStorageAccess is offered.

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
parser.add_argument("--app-pid", type=int, default=0, help="the app's pid: sampled when its control socket stops answering")
parser.add_argument("--diag-dir", default="", help="where a hang's sample and screenshot go (the report folder)")
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


DIAGNOSED = []


def diagnose_hang(why):
    """The control socket stopped answering: once, sample the app's threads (a main thread blocked in a
    syscall, a sync wait or a modal shows there) and capture the screen (a system prompt the app waits on)."""
    if DIAGNOSED or not opts.diag_dir:
        return
    DIAGNOSED.append(why)
    os.makedirs(opts.diag_dir, exist_ok=True)
    print(f"HANG control socket: {why}; sampling pid {opts.app_pid or '?'} into {opts.diag_dir}", flush=True)
    steps = [["screencapture", "-x", os.path.join(opts.diag_dir, "hang-screen.png")]]
    if opts.app_pid:
        steps.append(["sample", str(opts.app_pid), "3", "-file", os.path.join(opts.diag_dir, "hang-sample.txt")])
    for step in steps:
        try:
            subprocess.run(step, capture_output=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"HANG diagnostics {step[0]} failed: {error!r}", flush=True)
    sample = os.path.join(opts.diag_dir, "hang-sample.txt")
    if os.path.exists(sample):
        with open(sample, errors="replace") as handle:
            lines = handle.read().splitlines()
        # The main thread's stack, so the run log names what it waits on.
        start = next((i for i, line in enumerate(lines) if "Thread_" in line and ("main-thread" in line or "DispatchQueue_1" in line)), None)
        if start is not None:
            print("\n".join("HANG " + line for line in lines[start:start + 60]), flush=True)


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
        error = reply.get("error") if not reply.get("ok") else None
        if isinstance(error, dict) and error.get("code") == "timeout" and (error.get("data") or {}).get("not_run"):
            # A call that timed out before it ran: the main thread never got to it, the app is stalled though
            # the socket answers (a download's first look into ~/Downloads waited on macOS's access prompt).
            diagnose_hang(f"{method} never ran in the app: {error.get('message', '')}")
        return (reply.get("result") if reply.get("ok") else {"error": reply.get("error")}) or {}
    except socket.timeout as error:
        diagnose_hang(f"{method} got no answer in {timeout} s")
        return {"error": str(error)}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def downloads():
    """The app's downloads list, every tab's (`browser.page.downloads` with no tab): a list of rows."""
    rows = rpc("browser.page.downloads").get("downloads")
    return rows if isinstance(rows, list) else []


def new_download(before, wait=10):
    """The first download from the fixture's /dl not among the ids `before` that ended (finished, failed,
    blocked, cancelled) within `wait` s, else the newest such row still running, else None."""
    end = time.monotonic() + wait
    seen = None
    while time.monotonic() < end:
        fresh = [r for r in downloads() if r.get("id") not in before and str(r.get("url") or "").endswith("/dl")]
        done = [r for r in fresh if r.get("status") != "in_progress"]
        if done:
            return done[0]
        seen = fresh[-1] if fresh else seen
        time.sleep(0.5)
    return seen


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


LAST = {}


def popups():
    reply = debug_or_release("debug.popups", "browser.popups")
    LAST["popups"] = reply
    return reply.get("panels") or []


def prompts_of_tab():
    reply = debug_or_release("debug.browser.prompts", "browser.prompts", {"tab": TAB} if TAB else None)
    LAST["prompts"] = reply
    return reply.get("prompts") or []


def tab_ids():
    return {t.get("id") for t in rpc("browser.page.tabs", {"all": True}).get("tabs") or []}


def other_tabs_prompts(before):
    """Pending prompts of browser tabs opened since `before` (tab ids): an agent tab's window.open opens a
    tab, not a popup panel."""
    listing = rpc("browser.page.tabs", {"all": True})
    LAST["tabs"] = listing
    got = []
    for tab in listing.get("tabs") or []:
        if tab.get("id") not in before and tab.get("id") != TAB:
            reply = rpc("browser.prompts", {"tab": tab.get("id")})
            got += [dict(p, tab=tab.get("id"), url=tab.get("url")) for p in reply.get("prompts") or []]
    return got


def scheme_handler(url):
    """The app macOS opens `url` with (LaunchServices), or "" when none does: no app, no question to ask."""
    js = ('ObjC.import("AppKit");var u=$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString('
          + json.dumps(url) + '));u.isNil()?"":ObjC.unwrap(u.path)')
    try:
        return subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "?"


def wait_prompts(read, seconds=8):
    """`read()` until it lists something or `seconds` pass (a prompt can land after a Keychain read)."""
    end = time.monotonic() + seconds
    while True:
        got = read()
        if got or time.monotonic() >= end:
            return got
        time.sleep(0.5)


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
    if opts.engine == "webkit":  # Safari keeps a SameSite=None cookie without Secure; Chrome refuses it
        check("a=1" in got and "n=1" in got and "l=1" in got, f"cookies: Secure SameSite=None, Lax and insecure None kept, as Safari ({got})")
    else:
        check("a=1" in got and "n=1" not in got and "l=1" in got, f"cookies: Secure SameSite=None and Lax kept, insecure None refused ({got})")

    nav(IDP + "/cookies"); ev("localStorage.setItem('k','toplevel');1")
    nav(RP + "/embed", settle=3)
    seen = ev("JSON.stringify(__m)")
    if opts.engine == "webkit":  # WebKit's third-party cookie blocking, as Safari: Storage Access API is the way in
        check('"cookie":""' in seen and '"saa":"function"' in seen,
              f"iframe on another host gets no third-party cookie and is offered requestStorageAccess, as Safari ({seen})")
    else:
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

    def scheme(via, in_popup, to):
        what = f"{'popup' if in_popup else 'main tab'} ending on {to.split(':')[0]}: by {via}"
        rpc("debug.browser.external_opens", {"clear": True})
        before = tab_ids()
        if in_popup:
            nav(RP + f"/schemeopen?via={via}&to=" + urllib.parse.quote(to, safe=""))
            click("#go")
        else:
            nav(RP + "/cb?via=" + via + "&to=" + urllib.parse.quote(to, safe=""), settle=1)
        time.sleep(1)
        # A popup of an agent tab opens as a tab (no panel): its question is that tab's.
        read = (lambda: [p for p in popups() if p.get("prompts")] or other_tabs_prompts(before)) if in_popup else prompts_of_tab
        pending = wait_prompts(read)
        opened = rpc("debug.browser.external_opens").get("urls") or []
        # The raw reply on a fail: an RPC error or a missing tab must not read as "no prompt".
        raw = LAST.get("popups" if in_popup else "prompts"), LAST.get("tabs") if in_popup else None
        check(bool(pending) or bool(opened), f"{what}: asked or opened, not silent ({pending or opened or raw})")
        if in_popup:
            shown = [p for p in popups() if p.get("prompt_shown")] or [p for p in pending if p.get("tab")]
            check(bool(shown), f"{what}: the popup window shows the question ({LAST.get('popups')})")

    def c10():
        # A login that returns to an app (vscode://): macOS may have no app for it on this Mac, and cmux
        # then tells the person so; mailto: always has one (Mail), so the open-in-app question is judged too.
        print(f"     vscode: opens with {scheme_handler('vscode://auth?code=1') or 'no app'}", flush=True)
        for to in ("vscode://auth?code=1", "mailto:signin@example.com"):
            for via in ("js", "302"):
                scheme(via, False, to)
                close_popups()
                scheme(via, True, to)
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
        # The app's own downloads list over the control socket, not `cmux browser right download list
        # --agent`: that resolves an agent tab first, and the tab here is the one the harness opened
        # (the person's), so it refused the read. A second download of login.bin lands as
        # "login (1).bin": rows are matched by their source URL, not by the file name.
        nav(RP + "/dlflow")
        before = {r.get("id") for r in downloads()}
        click("#dl")
        row = new_download(before)
        check(bool(row) and row.get("status") == "finished",
              f"a link to an attachment downloads and the page stays ({row or 'no download listed'})")
        check(ev("location.pathname") == "/dlflow", "the tab stays on the login page after the download")
        before = {r.get("id") for r in downloads()}
        click("#go")
        row = new_download(before)
        check(bool(row) and row.get("status") == "finished",
              f"a popup sent to an attachment downloads it ({row or 'no download listed'})")
        check(ev("location.pathname") == "/dlflow", "the opener stays on the login page after the popup's download")

    def c15():
        nav(IDP + "/basic", settle=1)
        asked = wait_prompts(lambda: [p for p in prompts_of_tab() if "credentials" in p.get("kind", "").lower() or "auth" in p.get("kind", "").lower()])
        # On a fail: the read's raw reply, the other tabs' questions (did it land on another tab?) and the page.
        elsewhere = [] if asked else other_tabs_prompts({TAB})
        check(bool(asked), f"a 401 Basic challenge asks for credentials ({LAST.get('prompts')}, tab {TAB}, elsewhere {elsewhere}, "
                           f"page: {rpc('browser.page.state', {'tab': TAB})})")
        nav(f"http://user:pw@127.0.0.1:{opts.port}/basic", settle=3)
        check(ev("document.title") == "basic ok", f"user:pw in the URL answers the challenge (title {ev('document.title')})")

    import urllib.parse
    for n, fn in ((8, c8), (9, c9), (10, c10), (11, c11), (12, c12), (13, c13), (14, c14), (15, c15)):
        run(n, fn)
finally:
    server.terminate()
sys.exit(1 if failures else 0)
