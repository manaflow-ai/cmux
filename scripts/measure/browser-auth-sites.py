#!/usr/bin/env python3
"""Sign-in start pages of real sites, signed out, in cmux NEXT's browser (Chromium, WebKit) against Chrome.

Run by scripts/measure/browser-auth-flows.sh with the side copy of the NIGHTLY already made. No account, no
password: each page is opened, read after it settles, and judged by what it says and where it ends up.

  browser-auth-sites.py --side SIDE_SH --name NAME --work DIR --out DIR [--only a,b]

Per browser it records navigator.userAgent, userAgentData (brands, high-entropy values), the Sec-CH-UA request
headers (a local echo server), and which sign-in APIs exist (IdentityCredential for FedCM, PublicKeyCredential,
window.open). Then every site in SITES: final URL, title, and whether the page shows an unsupported-browser or
bot-block message. A cmux run FAILs when it shows such a message that Chrome does not, or fails to load where
Chrome loads. Without Chrome on the Mac, a message alone FAILs. Prints AUTHSITES {json} and a table.
"""
import argparse, http.server, json, re, socketserver, sys, threading, time, importlib.util, types
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("meet_browser", HERE / "meet-browser.py")
mb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mb)

# (name, url, what a healthy page still has in its text)
SITES = [
    ("google-accounts", "https://accounts.google.com/signin/v2/identifier?flowName=GlifWebSignIn", r"sign in|email or phone"),
    ("github-login", "https://github.com/login", r"sign in"),
    ("github-oauth-authorize", "https://github.com/login/oauth/authorize?client_id=Iv1.0000000000000000&scope=read:user", r"sign in|not found|oauth|application"),
    ("microsoft-login", "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=00000000-0000-0000-0000-000000000000&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%2Fcb&scope=openid", r"sign in|microsoft|application"),
    ("apple-id", "https://appleid.apple.com/sign-in", r"apple|sign in"),
    ("slack-signin", "https://slack.com/signin", r"sign in|slack"),
    ("stripe-login", "https://dashboard.stripe.com/login", r"sign in|stripe"),
    ("cloudflare-login", "https://dash.cloudflare.com/login", r"log in|cloudflare"),
    ("turnstile-demo", "https://demo.turnstile.workers.dev/", r"turnstile|cloudflare|verify"),
    ("recaptcha-demo", "https://www.google.com/recaptcha/api2/demo", r"recaptcha|submit"),
]
BAD = re.compile(r"browser or app may not be secure|couldn.t sign you in|unsupported browser|browser is not supported|"
                 r"update your browser|upgrade your browser|access denied|you have been blocked|verify you are human.{0,40}failed|"
                 r"enable javascript and cookies|this browser is no longer supported|try using a different browser", re.I)

parser = argparse.ArgumentParser()
for flag in ("--side", "--name", "--work", "--out"):
    parser.add_argument(flag, required=True)
parser.add_argument("--only", default="")
opts = parser.parse_args()
Path(opts.out).mkdir(parents=True, exist_ok=True)
mb.OPTS = types.SimpleNamespace(out=opts.out, work=opts.work, call=0)
mb.AGENT = "AuthSites"
only = set(filter(None, opts.only.split(",")))
log = lambda t: print(f"AUTHSITES {t}", flush=True)  # noqa: E731


class Echo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/hdr"):
            body = json.dumps({k.lower(): v for k, v in self.headers.items() if k.lower().startswith(("sec-ch", "user-agent", "accept-language"))})
            ctype = "text/html"
            # Ask for the high-entropy hints so a second load carries them, as a site's Accept-CH would.
            extra = {"Accept-CH": "Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform-Version, Sec-CH-UA-Arch, Sec-CH-UA-Model"}
        else:
            body, ctype, extra = "<!doctype html><title>blank</title>ok", "text/html", {}
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_address[1]}"

PROBE = """(function(){var u=navigator.userAgentData;window.__he=null;
 if(u&&u.getHighEntropyValues)u.getHighEntropyValues(['fullVersionList','platformVersion','architecture','model','uaFullVersion']).then(function(v){window.__he=v;});
 return JSON.stringify({ua:navigator.userAgent,vendor:navigator.vendor,platform:navigator.platform,webdriver:navigator.webdriver,
  uad:u?{brands:u.brands,mobile:u.mobile,platform:u.platform}:null,
  idc:typeof IdentityCredential,pkc:typeof PublicKeyCredential,creds:!!navigator.credentials,
  cookies:navigator.cookieEnabled,langs:navigator.languages,plugins:navigator.plugins.length});})()"""
TEXT = "JSON.stringify({href:location.href,title:document.title,text:(document.body?document.body.innerText:'').slice(0,1500),frames:document.querySelectorAll('iframe').length,ready:document.readyState})"


def load(js, nav, url, settle=8):
    err = nav(url)
    deadline = time.monotonic() + 45
    time.sleep(settle)
    page = {}
    while time.monotonic() < deadline:
        raw = js(TEXT)
        try:
            page = json.loads(raw) if raw else {}
        except ValueError:
            page = {}
        if page.get("ready") == "complete" and page.get("href") not in (None, "about:blank"):
            break
        time.sleep(2)
    page["navError"] = err
    return page


def run_browser(label, js, nav):
    out = {"browser": label, "sites": {}}
    nav(f"{BASE}/hdr")
    time.sleep(2)
    nav(f"{BASE}/hdr")  # second load: the echo's Accept-CH made the browser send the high-entropy hints
    time.sleep(2)
    try:
        out["headers"] = json.loads(js("document.body.innerText") or "{}")
    except ValueError:
        out["headers"] = {}
    try:
        out["env"] = json.loads(js(PROBE) or "{}")
    except ValueError:
        out["env"] = {}
    time.sleep(1)
    out["env"]["highEntropy"] = js("JSON.stringify(window.__he)")
    for name, url, healthy in SITES:
        page = load(js, nav, url)
        text = (page.get("title", "") + "\n" + page.get("text", ""))
        bad = BAD.search(text)
        page.update(bad=bad.group(0) if bad else None, healthy=bool(re.search(healthy, text, re.I)))
        out["sites"][name] = page
        log(f"{label} {name}: {page.get('href', '?')[:90]} bad={page['bad']} healthy={page['healthy']} navError={page.get('navError')}")
    return out


def run_cmux(cmux, engine, agent):
    label = f"cmux-{engine}-{'agent' if agent else 'person'}"
    tab = cmux.open(engine, f"{BASE}/blank")
    if not tab:
        return {"browser": label, "error": "tab was not created"}
    def js(s):
        reply = cmux.page(tab, "eval", script=s) if agent else cmux.rpc("browser.page.eval", {"tab": tab, "script": s}, 45)
        return None if reply.get("error") else reply.get("value")
    def nav(url):
        reply = cmux.page(tab, "navigate", url=url) if agent else cmux.rpc("browser.page.navigate", {"tab": tab, "url": url}, 45)
        return reply.get("error")
    try:
        return run_browser(label, js, nav)
    finally:
        cmux.close(tab)


runs = {}
cmux = mb.Cmux(opts.side, opts.name, log)
if cmux.launch([]):
    for engine in ("chromium", "webkit"):
        for agent in (True, False):
            n = f"cmux-{engine}-{'agent' if agent else 'person'}"
            if only and n not in only:
                continue
            runs[n] = run_cmux(cmux, engine, agent)
else:
    runs["cmux"] = {"browser": "cmux", "error": "the side copy gave no control socket"}
cmux.stop()
if not only or "chrome" in only:
    binary, clabel = mb.find_chrome(Path(opts.work), log)
    if binary:
        try:
            chrome = mb.Chrome(binary, "chrome", [], Path(opts.work), f"{BASE}/blank", log)
            runs["chrome"] = run_browser(clabel, chrome.js, lambda u: chrome.call("Page.navigate", {"url": u}).get("errorText")) | {"version": chrome.version()}
            chrome.quit()
        except Exception as error:  # noqa: BLE001
            runs["chrome"] = {"browser": "Chrome", "error": str(error)}

chrome = runs.get("chrome", {})
fails, rows = [], ["| run | site | final URL | verdict |", "|---|---|---|---|"]
for rn, r in runs.items():
    if r.get("error"):
        if rn != "chrome":
            fails.append(f"{rn}: {r['error']}")
        continue
    for name, page in r.get("sites", {}).items():
        ref = chrome.get("sites", {}).get(name)
        verdict = "ok"
        if rn != "chrome":
            loaded = bool(page.get("href")) and page["href"] != "about:blank"
            if page.get("bad") and not (ref and ref.get("bad")):
                verdict = f"FAIL shows '{page['bad']}'"
            elif not loaded and (not ref or ref.get("href")):
                verdict = "FAIL did not load"
            elif ref and ref.get("healthy") and not page.get("healthy"):
                verdict = "FAIL no sign-in content where Chrome has it"
            if verdict != "ok":
                fails.append(f"{rn} {name}: {verdict}")
        rows.append(f"| {rn} | {name} | {page.get('href', '')[:70]} | {verdict} |")
    e = r.get("env", {})
    rows.append(f"| {rn} | env | UA {e.get('ua')} | brands {json.dumps((e.get('uad') or {}).get('brands'))} fedcm={e.get('idc')} passkey={e.get('pkc')} webdriver={e.get('webdriver')} |")
    rows.append(f"| {rn} | headers | {json.dumps(r.get('headers'))[:300]} | |")
report = {"runs": runs, "fails": fails}
(Path(opts.out) / "auth-sites.json").write_text(json.dumps(report, indent=2))
(Path(opts.out) / "auth-sites.md").write_text("\n".join(rows) + "\n")
print("\n".join(rows))
print("AUTHSITES " + json.dumps({"fails": fails}))
sys.exit(1 if fails else 0)
