#!/usr/bin/env python3
"""Live proof: Chrome Web Store install and full uBlock Origin (Manifest V2)
in a fleet-built tagged cmux-next app (bead cx-d0d.100).

Runs inside `nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA`
on the GUI host. It uses the job's NX_APP, NX_APP_SOCKET, NX_APP_STOP,
NX_CAPTURE and NX_ARTIFACTS; it never signals a process (the app stops
through NX_APP_STOP).

  ext-mv2-live.py store              # Web Store "Add to Chrome" of an MV3 extension
  ext-mv2-live.py ublock --ubo DIR   # unpacked uBlock Origin (MV2) from DIR
  ext-mv2-live.py baseline           # the ad pages without uBlock Origin

Every phase writes results.json and 2x screenshots to
$NX_ARTIFACTS/<phase>/. Exit 0 when every check of the phase passed.

Checks (ublock): loaded and enabled as manifest 2 with a background page;
a known ad script is blocked by a network filter; a cosmetic filter hides an
ad slot (with a control that the host itself reaches both scripts); the
popup opens; the dashboard loads; a dynamic rule (`* * 3p-script block`)
blocks a third-party script that loads without it. The public score pages
(d3ward, turtlecute) are recorded as information, not checks.
"""
import argparse
import base64
import functools
import http.server
import json
import os
import plistlib
import re
import subprocess
import sys
import threading
import time
import traceback
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402
from ext_e2e import cdp  # noqa: E402
from ext_e2e.app import free_port  # noqa: E402

STORE_EXTENSION = ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader")  # MV3 on the store
UBO_NAME = "uBlock Origin"
# Public ad block score pages: informational only (third-party pages that can
# change or stop running; d3ward's is archived and shows no score). The gating checks are the
# local ad page and dynamic filtering.
SCORE_PAGES = (("turtlecute", "https://adblock.turtlecute.org/", "adblock.turtlecute.org"),)
AD_SCRIPT = "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"
AD_BEACON = "https://pagead2.googlesyndication.com/pagead/gen_204?id=mv2-proof"
JQUERY = "https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"

ADS_PAGE = """<!doctype html><meta charset="utf-8"><title>mv2 ads</title>
<body style="background:#fff;font:16px -apple-system,sans-serif">
<h1>Ad test page</h1>
<div class="adsbygoogle-box ad-banner-300x250" id="ad-slot" style="width:300px;height:120px;background:#fdd">ad slot (EasyList ##.adsbygoogle-box, ##.ad-banner-300x250)</div>
<p id="state">running</p>
<script>window.mv2 = {};</script>
<script src="%s"
  onload="mv2.ad='loaded'" onerror="mv2.ad='blocked'"></script>
<script src="%s" onload="mv2.jq='loaded'" onerror="mv2.jq='blocked'"></script>
<script>
// A request to an ad server that uBlock Origin blocks outright (a script can get a
// neutered surrogate instead, which still fires onload).
mv2.beacon = 'pending';
fetch('%s', {mode: 'no-cors', cache: 'no-store'}).then(() => mv2.beacon = 'loaded', () => mv2.beacon = 'blocked');
</script>
<script>
addEventListener('load', () => setTimeout(function finish() {
  if (mv2.beacon === 'pending') return setTimeout(finish, 250);
  const slot = document.getElementById('ad-slot');
  mv2.slot = slot && getComputedStyle(slot).display === 'none' ? 'hidden' : 'shown';
  mv2.done = true;
  document.getElementById('state').textContent = JSON.stringify(mv2);
}, 1500));
</script>
""" % (AD_SCRIPT, JQUERY, AD_BEACON)


def log(message):
    print(f"[ext-mv2] {message}", flush=True)


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = ADS_PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def serve():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/ads.html"


class Job:
    config = "{}"

    def __init__(self, phase, extensions=()):
        self.phase = phase
        self.app = os.environ["NX_APP"]
        self.socket = os.environ["NX_APP_SOCKET"]
        self.out = os.path.join(os.environ.get("NX_ARTIFACTS", "/tmp/ext-mv2"), phase)
        os.makedirs(self.out, exist_ok=True)
        self.port = free_port()
        self.extensions = list(extensions)
        self.results = []
        self.client = None
        self.pid = None

    # -- app --------------------------------------------------------------
    def launch(self):
        """Starts the app's executable from this job (so nx-remote tracks it and the
        environment reaches it; `open --env` did not), with an empty config file."""
        with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as plist:
            binary = os.path.join(self.app, "Contents/MacOS", plistlib.load(plist)["CFBundleExecutable"])
        config = os.path.join(self.out, "cmux.json")
        with open(config, "w") as empty:
            empty.write(Job.config + "\n")
        env = {
            "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1",
            # Never the person's Chief home; the proof opens no Home or Chief pane.
            "CMUX_NEXT_CHIEF_ISOLATED": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CONFIG_FILE": config,
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,860",
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={self.port}:remote-allow-origins=*",
        }
        if "NX_JOB_ID" in os.environ:
            env["NX_JOB_ID"] = os.environ["NX_JOB_ID"]
        if self.extensions:
            env["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] = ":".join(self.extensions)
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        log_file = open(os.path.join(self.out, "app.log"), "w")
        process = subprocess.Popen([binary], env=env, stdout=log_file, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL)
        self.pid = process.pid
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise SystemExit(f"the app exited with {process.returncode}")
            try:
                self.client = Client(self.socket, timeout=30)
                if self.client.call("debug.cef").get("ok"):
                    break
            except (OSError, ConnectionError, ValueError):
                pass
            time.sleep(0.3)
        else:
            raise SystemExit("the app socket never answered")
        if not (self.call("debug.focus").get("result") or {}).get("windows"):
            self.call("action.run", {"action": "newWindow", "origin": "script"})
        # Chromium starts with the first Chromium tab (CEFRuntime.start is lazy).
        self.call("action.run", {"action": "openBrowser.chromium", "args": {"url": "about:blank"},
                                 "focus": True, "origin": "remote"})
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                cdp.targets(self.port)
                break
            except OSError:
                time.sleep(0.3)
        else:
            raise SystemExit(f"no DevTools port {self.port}: CMUX_NEXT_CEF_EXTRA_SWITCHES did not apply")
        log(f"app up: pid {self.pid}, cdp {self.port}")

    def stop(self):
        stop = os.environ.get("NX_APP_STOP")
        if stop:
            subprocess.run([stop], check=False)

    def call(self, method, params=None):
        try:
            return self.client.call(method, params or {})
        except (OSError, ConnectionError, ValueError):
            self.client = Client(self.socket, timeout=30)
            return self.client.call(method, params or {})

    def open_tab(self, url, match=None, timeout=30):
        before = {t.get("id") for t in cdp.targets(self.port)}
        # A tab a person opens (origin remote), not an agent-driven one: extensions
        # cannot reach agent-driven tabs (fork API 20, cmux_tab_set_extension_access).
        for _ in range(3):  # right after a start the action can miss its 2 s deadline
            opened = self.call("action.run", {"action": "openBrowser.chromium", "args": {"url": url},
                                              "focus": True, "origin": "remote"})
            if (opened.get("error") or {}).get("code") != "timeout":
                break
            time.sleep(2)
        self.last_created = ((opened.get("result") or {}).get("created") or [None])[0]
        key = match or url
        target = cdp.wait_target(self.port, lambda t: t.get("type") == "page" and t.get("id") not in before
                                 and key in t.get("url", ""), timeout)
        if not target:
            raise RuntimeError(f"no Chromium page for {url}: {opened}")
        return cdp.Session(target["webSocketDebuggerUrl"], timeout=30)

    def extensions_report(self):
        return (self.call("browser.extensions").get("result") or {}).get("extensions") or []

    # -- evidence ---------------------------------------------------------
    def row(self, check, ok, detail, gating=True):
        """`gating=False`: recorded evidence that does not decide the phase."""
        self.results.append({"check": check, "ok": bool(ok), "gating": gating, "detail": detail})
        label = ("PASS" if ok else "FAIL") if gating else "INFO"
        log(f"{label} {check}: {json.dumps(detail)[:400]}")

    def page_shot(self, session, name, full=False):
        """A 2x PNG of a Chromium page through CDP."""
        params = {"format": "png", "captureBeyondViewport": full}
        try:
            metrics = session.call("Page.getLayoutMetrics")
            size = metrics.get("cssContentSize" if full else "cssLayoutViewport") or {}
            width = size.get("width") or size.get("clientWidth") or 1200
            height = min(size.get("height") or size.get("clientHeight") or 800, 4000)
            params["clip"] = {"x": 0, "y": 0, "width": width, "height": height, "scale": 2}
        except RuntimeError:
            pass
        try:
            data = session.call("Page.captureScreenshot", params, timeout=30)["data"]
        except Exception as error:  # noqa: BLE001 - a shot is evidence, not a check
            log(f"page shot {name} failed: {error!r}")
            return None
        path = os.path.join(self.out, f"{name}.png")
        with open(path, "wb") as png:
            png.write(base64.b64decode(data))
        return os.path.basename(path)

    def window_shot(self, name, popups=False):
        """The app window (and its open popovers) through the host's capture helper."""
        capture = os.environ.get("NX_CAPTURE")
        if not capture or not self.pid:
            return None
        path = os.path.join(self.out, f"{name}.png")
        command = ["bash", capture, "shot", "--pid", str(self.pid), "--out", path]
        if popups:
            command.insert(5, "--with-popups")
        done = subprocess.run(command, capture_output=True, text=True)
        if done.returncode != 0:
            log(f"window shot {name} failed: {done.stderr.strip()[:300]}")
            return None
        return os.path.basename(path)

    def finish(self):
        gating = [r for r in self.results if r["gating"]]
        ok = bool(gating) and all(r["ok"] for r in gating)
        with open(os.path.join(self.out, "results.json"), "w") as out:
            json.dump({"phase": self.phase, "ok": ok, "results": self.results}, out, indent=2)
        log(f"{self.phase}: {'ALL PASS' if ok else 'FAILURES'} ({sum(r['ok'] for r in gating)}/{len(gating)} gating)")
        return 0 if ok else 1


def drain_contexts(session):
    """Isolated worlds (extension content scripts) named in Runtime.executionContextCreated
    events: re-enabling Runtime replays one event per live context."""
    session.call("Runtime.disable")
    session._send(json.dumps({"id": 999999, "method": "Runtime.enable", "params": {}}))
    names = []
    session.sock.settimeout(5)
    try:
        while True:
            message = session._recv()
            if message.get("method") == "Runtime.executionContextCreated":
                context = message["params"]["context"]
                names.append([context.get("name"), (context.get("auxData") or {}).get("type"), context.get("origin")])
            if message.get("id") == 999999:
                break
    except OSError:
        pass
    return names


def observed_load(job, url, label, watch):
    """Loads `url` in a person's tab with the cache off and DevTools' Network domain
    on, and returns the page state plus, for each watched URL, what happened to it:
    "blocked" (net::ERR_BLOCKED_BY_CLIENT), "redirected to <url>" (uBlock Origin
    answers some ad scripts and ad requests with a neutered local resource, so the
    page still sees a load), "loaded" or "not requested"."""
    session = job.open_tab("about:blank", match="about:blank")
    events = []
    try:
        session.call("Network.enable")
        session.call("Network.setCacheDisabled", {"cacheDisabled": True})
        session._send(json.dumps({"id": 888888, "method": "Page.navigate", "params": {"url": url}}))
        deadline = time.monotonic() + 12
        session.sock.settimeout(1)
        while time.monotonic() < deadline:
            try:
                message = session._recv()
            except OSError:
                continue
            if message.get("method", "").startswith("Network."):
                events.append(message)
        state = poll(session, "window.mv2 && window.mv2.done && window.mv2", 10) or {}
        time.sleep(2)
        state["slot_late"] = session.evaluate("getComputedStyle(document.getElementById('ad-slot')).display")
        state["ubo_world"] = ubo_world_state(session)
        state["shot"] = job.page_shot(session, f"{label}-page")
    finally:
        session.close()
    by_id = {}
    for event in events:
        params = event["params"]
        rid = params.get("requestId")
        if event["method"] == "Network.requestWillBeSent":
            entry = by_id.setdefault(rid, {"url": params["request"]["url"], "chain": []})
            entry["chain"].append(params["request"]["url"])
        elif event["method"] == "Network.loadingFailed" and rid in by_id:
            by_id[rid]["failed"] = params.get("blockedReason") or params.get("errorText")
        elif event["method"] == "Network.loadingFinished" and rid in by_id:
            by_id[rid]["finished"] = True
    outcomes = {}
    for name, target in watch.items():
        entry = next((e for e in by_id.values() if e["chain"][0] == target), None)
        if not entry:
            outcomes[name] = "not requested"
        elif entry.get("failed"):
            outcomes[name] = "blocked" if "BLOCKED_BY_CLIENT" in str(entry["failed"]).upper() or entry["failed"] == "inspector" \
                else f"failed {entry['failed']}"
        elif any(u.startswith("chrome-extension://") or u.startswith("data:") for u in entry["chain"][1:]):
            outcomes[name] = "redirected to " + entry["chain"][-1][:80]
        else:
            outcomes[name] = "loaded"
    return state, outcomes


def ubo_world_state(session):
    """What uBlock Origin's content script sees in the page (its isolated world)."""
    try:
        session.call("Runtime.disable")
        session._send(json.dumps({"id": 777777, "method": "Runtime.enable", "params": {}}))
        session.sock.settimeout(5)
        context = None
        while True:
            message = session._recv()
            if message.get("method") == "Runtime.executionContextCreated" and message["params"]["context"].get("name") == "uBlock Origin":
                context = message["params"]["context"]["id"]
            if message.get("id") == 777777:
                break
        if context is None:
            return "no uBlock Origin world"
        result = session.call("Runtime.evaluate", {"contextId": context, "returnByValue": True, "expression":
            "JSON.stringify({vapi: typeof vAPI, noGeneric: self.vAPI && vAPI.noGenericCosmeticFiltering,"
            " noSpecific: self.vAPI && vAPI.noSpecificCosmeticFiltering, filterer: !!(self.vAPI && vAPI.domFilterer),"
            " surveyor: !!(self.vAPI && vAPI.domSurveyor), bootstrapped: self.vAPI && vAPI.bootstrap === undefined})"})
        return result.get("result", {}).get("value")
    except Exception as error:  # noqa: BLE001 - diagnosis only
        return repr(error)


def enforced(outcome):
    """Blocked, or answered by uBlock Origin with a neutered resource (its
    web_accessible_resources surrogate or a data: no-op)."""
    return outcome == "blocked" or outcome.startswith(("redirected to chrome-extension://", "redirected to data:"))


def poll(session, expression, timeout, interval=0.5):
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        try:
            value = session.evaluate(expression)
        except RuntimeError:
            value = None
        if value:
            return value
        time.sleep(interval)
    return value


def ads_check(job, url, label, expect_blocked):
    """The local ad page: network filter (ad script), cosmetic filter (ad slot)."""
    session = job.open_tab(url)
    state = {}
    try:
        for attempt in range(6):
            state = poll(session, "window.mv2 && window.mv2.done && window.mv2", 20) or {}
            if not expect_blocked or (state.get("beacon") == "blocked" and state.get("slot") == "hidden"):
                break
            time.sleep(5)  # first run: uBlock Origin may still compile its filter lists
            session.call("Page.reload")
        state["attempts"] = attempt + 1
        state["shot"] = job.page_shot(session, f"{label}-ads-page")
    finally:
        session.close()
    if expect_blocked:
        job.row(f"{label}: ad server request blocked (network filter)", state.get("beacon") == "blocked", state)
        job.row(f"{label}: ad slot hidden (cosmetic filter)", state.get("slot") == "hidden", state)
    else:
        job.row(f"{label}: ad server request and ad script load without a blocker",
                state.get("beacon") == "loaded" and state.get("ad") == "loaded" and state.get("slot") == "shown", state)
    return state


def host_reaches(url):
    """The GUI host itself reaches `url` (the control for a "blocked" result)."""
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=15) as response:
            return response.status
    except Exception as error:  # noqa: BLE001
        return repr(error)


def score_pages(job, label):
    """Informational: the public ad block score pages, text and a full-page shot."""
    scores = {}
    for name, url, match in SCORE_PAGES:
        try:
            session = job.open_tab(url, match=match)
        except RuntimeError as error:
            job.row(f"{label}: {name} score page", False, repr(error), gating=False)
            continue
        try:
            time.sleep(25)  # the page runs its probes, then writes the score
            text = session.evaluate("document.body.innerText") or ""
            shot = job.page_shot(session, f"{label}-{name}", full=True)
        finally:
            session.close()
        percents = re.findall(r"(\d{1,3}(?:\.\d+)?)\s*%", text)
        scores[name] = percents[:6]
        job.row(f"{label}: {name} score page", bool(percents),
                {"percents": percents[:6], "text_head": text[:500], "shot": shot}, gating=False)
    return scores


def guarded(job, name, fn, *args):
    """Runs one step; an exception becomes a failed row, so later steps still run
    and results.json is always written."""
    try:
        return fn(*args)
    except BaseException as error:  # noqa: BLE001 - SystemExit from launch included
        if isinstance(error, KeyboardInterrupt):
            raise
        job.row(f"{name}: runner error", False, f"{error!r} {traceback.format_exc()[-900:]}")
        return None


def run_phase(job, steps, cleanup=()):
    try:
        if guarded(job, f"{job.phase}: launch", job.launch) is not False and job.client:
            for name, fn in steps:
                if guarded(job, name, fn) == "stop":
                    break
    finally:
        job.stop()
        for done in cleanup:
            done()
    return job.finish()


def phase_store(_args):
    job = Job("store")
    ext_id, _ = STORE_EXTENSION
    state = {}

    def install():
        session = job.open_tab(f"https://chromewebstore.google.com/detail/{ext_id}", match=ext_id, timeout=45)
        try:
            find = ("(() => { const b = [...document.querySelectorAll('button')].find(e => /add to chrome/i.test(e.innerText));"
                    " if (!b) return null; b.scrollIntoView({block: 'center'}); const r = b.getBoundingClientRect();"
                    " return [r.x + r.width / 2, r.y + r.height / 2, b.innerText.trim()]; })()")
            button = poll(session, find, 45)
            job.page_shot(session, "store-detail")
            job.row("store: Add to Chrome button", bool(button), button or "no button within 45 s")
            if not button:
                return "stop"
            time.sleep(1)
            button = poll(session, find, 5) or button
            session.click(button[0], button[1])  # a trusted click: user gesture
            prompt = None
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline and not prompt:
                prompts = (job.call("debug.extensions.prompt").get("result") or {}).get("prompts") or []
                prompt = next((p for p in prompts if p.get("extension_id") == ext_id), None)
                time.sleep(0.5)
            job.row("store: install prompt shown", prompt is not None, prompt or "no prompt in 45 s")
            job.window_shot("store-prompt", popups=True)
            if not prompt:
                return "stop"
            answer = job.call("debug.extensions.prompt", {"id": prompt["id"], "answer": "accept"}).get("result")
            installed = None
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline and not (installed and installed.get("enabled")):
                installed = next((e for e in job.extensions_report() if e.get("id") == ext_id), None)
                time.sleep(1)
            job.row("store: installed and enabled (no FAILED_TO_COPY error)",
                    bool(installed and installed.get("enabled")), {"answer": answer, "extension": installed})
            errors = poll(session, "(() => { const t = document.body.innerText;"
                                   " const m = t.match(/Could not install package[^\\n]*/); return m ? m[0] : ''; })()", 2)
            job.row("store: no install error on the page", not errors, errors or "none", gating=False)
            job.page_shot(session, "store-after-install")
            job.window_shot("store-window")
        finally:
            session.close()

    def downloads():
        folder = os.path.expanduser("~/Downloads")
        stray = [f for f in os.listdir(folder) if f.endswith((".crx", ".cmuxdownload"))
                 and os.path.getmtime(os.path.join(folder, f)) > time.time() - 600]
        job.row("store: no CRX copied into Downloads", not stray, stray or "none", gating=False)

    return run_phase(job, [("store: install", install), ("store: downloads", downloads)])


def phase_baseline(_args):
    server, url = serve()
    job = Job("baseline")
    return run_phase(job, [("baseline: ads", lambda: ads_check(job, url, "baseline", expect_blocked=False)),
                           ("baseline: score pages", lambda: score_pages(job, "baseline"))],
                     cleanup=[server.shutdown])


def phase_ublock(args):
    server, url = serve()
    # Without --ubo the app's built-in copy (browser.builtInAdBlocker, on by default) is checked.
    job = Job(args.label or ("ublock" if args.ubo else "builtin"), extensions=[args.ubo] if args.ubo else [])
    ctx = {}

    def person_load():
        """The person's own copy: Load Unpacked (Extensions menu action) of `--load-unpacked`."""
        result = job.call("action.run", {"action": "browser.extensions.loadUnpacked",
                                         "args": {"path": args.load_unpacked}, "origin": "remote"})
        job.row("person: Load Unpacked of a uBlock Origin copy", "error" not in result, result)
        time.sleep(3)

    def loaded():
        ubo = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not ubo:
            ubo = next((e for e in job.extensions_report() if e.get("name") == UBO_NAME), None)
            time.sleep(0.5)
        if not args.ubo and not args.person and "false" in Job.config.replace(" ", ""):
            job.row("builtin-off: with browser.builtInAdBlocker false uBlock Origin does not run",
                    not (ubo and ubo.get("enabled")), ubo or "not listed")
            return "stop"
        job.row("ublock: loaded and enabled", bool(ubo and ubo.get("enabled")), ubo or "not listed")
        if not ubo:
            return "stop"
        if not args.ubo:
            job.row("builtin: the bundled copy keeps the Web Store id", ubo["id"] == "cjpalhdlnbpafiamejdnhcphjbkeiagm", ubo)
        ctx["id"] = ubo["id"]
        ctx["prefix"] = f"chrome-extension://{ubo['id']}/"

    def diagnose():
        """Raw extension APIs inside uBlock Origin's own MV2 background page: does a
        blocking webRequest listener cancel a page's request, and which tab id do
        the page's requests carry (uBlock Origin files requests with tab id -1
        under "behind-the-scene", where it filters much less)."""
        target = ctx.get("bg")
        if not target:
            job.row("diagnose: background page session", False, "no background page")
            return
        bg = cdp.Session(target["webSocketDebuggerUrl"])
        try:
            bg.evaluate("""(() => {
              self.mv2probe = {requests: [], nav: [], updated: []};
              chrome.webRequest.onBeforeRequest.addListener(d => {
                if (self.mv2probe.requests.length < 80) self.mv2probe.requests.push([d.type, d.tabId, d.frameId, d.url.slice(0, 90)]);
              }, {urls: ['<all_urls>']});
              chrome.webRequest.onBeforeRequest.addListener(d => ({cancel: true}),
                {urls: ['*://*/*mv2-cancel-probe*']}, ['blocking']);
              chrome.webNavigation.onCommitted.addListener(d => self.mv2probe.nav.push([d.tabId, d.frameId, d.url.slice(0, 90)]));
              chrome.tabs.onUpdated.addListener((id, info) => self.mv2probe.updated.push([id, info.status || '', (info.url || '').slice(0, 90)]));
              return true; })()""")
            page = job.open_tab(url + "?probe=1", match="/ads.html?probe=1")
            try:
                poll(page, "window.mv2 && window.mv2.done", 20)
                probe = page.evaluate("fetch('" + JQUERY.replace("jquery.min.js", "package.json") + "?mv2-cancel-probe', {mode: 'no-cors', cache: 'no-store'})"
                                      ".then(() => 'loaded', () => 'blocked')")
            finally:
                page.close()
            time.sleep(1)
            seen = bg.evaluate("""new Promise(r => chrome.tabs.query({}, tabs => r({
              probe: self.mv2probe, tabs: tabs.map(t => [t.id, t.windowId, t.active, (t.url || '').slice(0, 90)])})))""")
        finally:
            bg.close()
        job.row("ublock: webRequestBlocking cancels a page request (raw API, MV2)", probe == "blocked", {"probe": probe})
        requests = (seen or {}).get("probe", {}).get("requests", [])
        page_requests = [r for r in requests if "127.0.0.1" in r[3] or "googlesyndication" in r[3] or "jsdelivr" in r[3]]
        job.row("diagnose: page requests seen by webRequest (type, tabId, frameId, url)", bool(page_requests),
                {"requests": page_requests[:20], "tabs": (seen or {}).get("tabs"),
                 "webNavigation.onCommitted": (seen or {}).get("probe", {}).get("nav", [])[:10],
                 "tabs.onUpdated": (seen or {}).get("probe", {}).get("updated", [])[:10]}, gating=False)

    def background():
        prefix = ctx["prefix"]
        target = cdp.wait_target(job.port, lambda t: t.get("type") == "background_page"
                                 and t.get("url", "").startswith(prefix), 30)
        version = None
        ctx["bg"] = target
        if target:
            bg = cdp.Session(target["webSocketDebuggerUrl"])
            try:
                version = poll(bg, "chrome.runtime && chrome.runtime.getManifest().manifest_version", 20)
            finally:
                bg.close()
        job.row("ublock: MV2 background page runs", version == 2 and target is not None,
                {"background": (target or {}).get("url"), "manifest_version": version})

    def ready():
        """uBlock Origin filters only after its lists are compiled (µBlock.readyToFilter)."""
        bg = cdp.Session(ctx["bg"]["webSocketDebuggerUrl"])
        try:
            state = poll(bg, "self.µBlock && self.µBlock.readyToFilter === true && {lists: Object.entries(self.µBlock.availableFilterLists || {})"
                             ".filter(([k, v]) => v.content === 'filters' && !v.off).map(([k]) => k)}", 90, interval=1)
        finally:
            bg.close()
        job.row("ublock: filter lists ready (µBlock.readyToFilter)", bool(state), state or "not ready in 90 s")

    def verdicts():
        """One uncached load of the ad page; then uBlock Origin's own page store for
        that tab (what it counted) and whether its content script runs in the page."""
        session = job.open_tab("about:blank", match="about:blank")
        contexts = []
        try:
            session.call("Network.enable")
            session.call("Network.setCacheDisabled", {"cacheDisabled": True})
            session.call("Runtime.enable")
            session.call("Page.navigate", {"url": url + "?verdict=1"})
            state = poll(session, "window.mv2 && window.mv2.done && window.mv2", 25) or {}
            time.sleep(2)  # uBlock Origin commits its page journal about once a second
            # executionContextCreated events arrived on this socket while we waited; read them.
            contexts = drain_contexts(session)
            tab_url = url + "?verdict=1"
        finally:
            session.close()
        bg = cdp.Session(ctx["bg"]["webSocketDebuggerUrl"])
        try:
            store = bg.evaluate("""new Promise(r => chrome.tabs.query({}, tabs => {
              const t = tabs.find(t => (t.url || '').includes('?verdict=1'));
              const ps = t && self.µBlock.pageStoreFromTabId(t.id);
              r({tab: t && t.id, found: !!ps, url: ps && ps.rawURL, netFiltering: ps && ps.getNetFilteringSwitch(),
                 counts: ps && JSON.parse(JSON.stringify(ps.counts || null)),
                 journal: ps && (ps.journal || []).length,
                 hostnames: ps && ps.hostnameDetailsMap ? [...ps.hostnameDetailsMap.keys()] : null});
            }))""")
        finally:
            bg.close()
        job.row("diagnose: uncached ad page as the page sees it", True, state, gating=False)
        job.row("diagnose: uBlock Origin page store for that tab", bool(store and store.get("found")), store, gating=False)
        job.row("diagnose: extension worlds in the page (content scripts)", bool(contexts), contexts, gating=False)

    def blocking():
        time.sleep(3)
        # Controls: the host reaches both scripts, so "blocked" in the page is uBlock Origin.
        for name, address in (("ad server", AD_BEACON), ("jQuery CDN", JQUERY)):
            status = host_reaches(address)
            job.row(f"control: the host reaches the {name}", status in (200, 204), {"url": address, "status": status})
        ctx["ads"] = ads_check(job, url, "ublock", expect_blocked=True)

    def network():
        state, outcomes = observed_load(job, url + "?net=1", "ublock-network",
                                        {"ad script": AD_SCRIPT, "ad server request": AD_BEACON, "jQuery": JQUERY})
        ctx["net"] = outcomes
        job.row("ublock: network filters enforced (ad script and ad server request blocked or neutered)",
                enforced(outcomes["ad script"]) and enforced(outcomes["ad server request"]),
                {"outcomes": outcomes, "page": state})
        job.row("ublock: a normal third-party script still loads", outcomes["jQuery"] == "loaded", outcomes)
        job.row("diagnose: ad slot on the 127.0.0.1 page (uBlock Origin skips generic cosmetic filters there)",
                state.get("slot") == "hidden", state, gating=False)
        session = job.open_tab("https://example.com/", match="example.com")
        try:
            poll(session, "location.host === 'example.com' && document.readyState === 'complete' && !!document.body", 30)
            time.sleep(1)
            session.evaluate("document.body.insertAdjacentHTML('beforeend', '<div id=\"mv2-slot\" class=\"adsbygoogle-box\" "
                             "style=\"width:300px;height:100px;background:#fdd\">ad slot</div>'); true")
            hidden = poll(session, "(() => { const e = document.getElementById('mv2-slot');"
                                   " return e && getComputedStyle(e).display === 'none'; })()", 10)
            hidden = {"hidden": bool(hidden), "slot": session.evaluate("(() => { const e = document.getElementById('mv2-slot');"
                                                                      " return e ? getComputedStyle(e).display : 'missing'; })()")}
            world = ubo_world_state(session)
            shot = job.page_shot(session, f"{job.phase}-cosmetic-example")
        finally:
            session.close()
        job.row("ublock: EasyList generic cosmetic filter hides an ad slot (##.adsbygoogle-box on example.com)",
                hidden["hidden"], {"result": hidden, "ubo_world": world, "shot": shot})

    def insert_css():
        """The API uBlock Origin's cosmetic filtering uses (tabs.insertCSS, user origin)."""
        session = job.open_tab(url + "?css=1", match="/ads.html?css=1")
        bg = cdp.Session(ctx["bg"]["webSocketDebuggerUrl"])
        try:
            poll(session, "window.mv2 && window.mv2.done", 20)
            time.sleep(2)  # the tab's URL reaches chrome.tabs after load
            result = bg.evaluate("""new Promise(r => chrome.tabs.query({}, tabs => {
              const t = tabs.find(t => (t.url || '').includes('?css=1'));
              if (!t) return r({error: 'no tab'});
              chrome.tabs.insertCSS(t.id, {code: '#state{display:none!important}', cssOrigin: 'user'},
                () => r({tab: t.id, lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null}));
            }))""")
            time.sleep(1)
            hidden = session.evaluate("getComputedStyle(document.getElementById('state')).display === 'none'")
        finally:
            bg.close()
            session.close()
        job.row("ublock: tabs.insertCSS applies in a person's tab", bool(hidden), {"result": result, "hidden": hidden})

    def popup():
        prefix = ctx["prefix"]
        before = {t.get("id") for t in cdp.targets(job.port)}
        click = job.call("debug.extensions.click", {"extension": ctx["id"]}).get("result")
        target = cdp.wait_target(job.port, lambda t: t.get("id") not in before and t.get("type") == "page"
                                 and t.get("url", "").startswith(prefix + "popup"), 10)
        detail = {"click": click, "url": (target or {}).get("url")}
        if target:
            session = cdp.Session(target["webSocketDebuggerUrl"])
            try:
                detail["size"] = poll(session, "(() => { const r = document.body.getBoundingClientRect();"
                                               " return r.width > 100 && r.height > 100 && document.body.innerText.length > 10"
                                               " ? [r.width, r.height] : null; })()", 15)
                time.sleep(1)
                detail["text"] = (session.evaluate("document.body.innerText") or "")[:300]
                detail["shot"] = job.page_shot(session, "ublock-popup")
                # Dynamic filtering through uBlock Origin's own privileged messaging (an
                # extension page may use the dashboard channel), as "My rules" does.
                # uBlock Origin applies dynamic rules only in its advanced-user mode
                # (pagestore.js: userSettings.advancedUserEnabled).
                session.evaluate("vAPI.messaging.send('dashboard', {what: 'userSettings', name: 'advancedUserEnabled', value: true})")
                ctx["rule"] = session.evaluate(
                    "vAPI.messaging.send('dashboard', {what: 'modifyRuleset', permanent: false,"
                    " toAdd: '* * 3p-script block', toRemove: ''})"
                    ".then(r => (r && r.sessionRules || []).filter(x => /3p-script/.test(x)))")
            finally:
                session.close()
            detail["window_shot"] = job.window_shot("ublock-popup-window", popups=True)
        job.row("ublock: popup opens", bool(target and detail.get("size")), detail)
        job.call("debug.extensions.popup", {"hide": True})

    def dynamic():
        state, outcomes = observed_load(job, url + "?dyn=1", "ublock-dynamic", {"jQuery": JQUERY})
        before = (ctx.get("net") or {}).get("jQuery")
        job.row("ublock: dynamic filtering (* * 3p-script block) blocks a third-party script",
                before == "loaded" and (outcomes["jQuery"] == "blocked" or state.get("jq") == "blocked") and bool(ctx.get("rule")),
                {"before": before, "rule": ctx.get("rule"), "after": outcomes["jQuery"], "page": state})

    def agent_read():
        """An agent's page read (`cmux browser <tab> eval`, the CLI over the app
        socket) of a page every enabled extension can reach (example.com)."""
        session = job.open_tab("https://example.com/?agent=1", match="example.com/?agent=1")
        try:
            poll(session, "document.readyState === 'complete'", 20)
        finally:
            session.close()
        tab = job.last_created
        cli = os.path.join(job.app, "Contents/Resources/bin/cmux")
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        env["CMUX_SOCKET_PATH"] = job.socket
        for _ in range(3):  # a page that reopens (password fill guard) asks for a retry
            done = subprocess.run([cli, "browser", str(tab), "eval", "document.title"], env=env,
                                  capture_output=True, text=True, timeout=60)
            out = (done.stdout + done.stderr).strip()
            if "retry" not in out:
                break
            time.sleep(2)
        refused = "enabled extension with access" in out or "extension_host_access" in out
        want = args.agent_read
        ok = ("Example Domain" in out and not refused) if want == "allowed" else refused
        job.row(f"agent: page read is {want}", ok, {"tab": tab, "exit": done.returncode, "output": out[:400]})

    def menu_note():
        """The Extensions menu says the full uBlock Origin is built in (the Web Store
        lists only uBlock Origin Lite)."""
        job.call("debug.extensions.click", {"button": "extensions"})
        state = {}
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not state.get("open"):
            state = job.call("debug.extensions.menu").get("result") or {}
            time.sleep(0.25)
        shot = job.window_shot("builtin-extensions-menu", popups=True)
        job.call("debug.extensions.menu", {"dismiss": True})
        note = [i for i in state.get("items", []) if isinstance(i, dict) and str(i.get("identifier", "")).endswith(".builtInAdBlocker")]
        want = getattr(main, "menu_note", None) or "present"
        job.row(f"menu: the built-in line is {want} (built-in copy {'loaded' if want == 'present' else 'skipped'})",
                bool(state.get("open")) and bool(note) == (want == "present"), {"note": note, "shot": shot, "open": state.get("open")})

    def dashboard():
        """Automation may not open extension pages as tabs; a person's tab is
        navigated there through DevTools, as typing the address would."""
        session = job.open_tab(url + "?dash=1", match="/ads.html?dash=1")
        try:
            session.call("Page.navigate", {"url": ctx["prefix"] + "dashboard.html"})
            ready = poll(session, "(() => { const f = document.querySelector('iframe');"
                                  " return location.href.includes('dashboard.html') && f && f.contentDocument"
                                  " && f.contentDocument.readyState === 'complete'"
                                  " && f.contentDocument.body.innerText.length > 50 ? f.src : null; })()", 20)
            if ready:
                time.sleep(1)
            shot = job.page_shot(session, "ublock-dashboard")
            where = session.evaluate("location.href")
        finally:
            session.close()
        job.row("ublock: dashboard loads", bool(ready), {"pane": ready, "url": where, "shot": shot})
        job.window_shot("ublock-window")

    return run_phase(job, [*([("person: load", person_load)] if args.load_unpacked else []), ("ublock: loaded", loaded), ("ublock: background", background),
                           *([("menu note", menu_note)] if not args.ubo or args.menu_note else []),
                           *([("agent read", agent_read)] if args.agent_read else []),
                           ("ublock: ready", ready), ("ublock: network", network),
                           ("ublock: insertCSS", insert_css), ("ublock: popup", popup),
                           ("ublock: dynamic filtering", dynamic), ("ublock: dashboard", dashboard),
                           ("ublock: score pages", lambda: score_pages(job, "ublock"))],
                     cleanup=[server.shutdown])


def ads_check_jq(job, url):
    session = job.open_tab(url + "?jq=" + str(time.monotonic_ns()), match="/ads.html?jq=")
    try:
        state = poll(session, "window.mv2 && window.mv2.done && window.mv2", 20) or {}
        job.page_shot(session, f"ublock-jq-{state.get('jq')}")
    finally:
        session.close()
    return state.get("jq")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("phase", choices=["store", "baseline", "ublock", "builtin"])
    parser.add_argument("--ubo", help="ublock: unpacked uBlock Origin directory")
    parser.add_argument("--label", help="artifact folder name (default: the phase)")
    parser.add_argument("--load-unpacked", help="builtin: first Load Unpacked this folder as the person's own copy")
    parser.add_argument("--agent-read", choices=["allowed", "refused"],
                        help="check an agent page read on example.com (the extension guard)")
    parser.add_argument("--person", action="store_true", help="builtin: the profile holds the person's copy (expect it to run)")
    parser.add_argument("--menu-note", choices=["present", "absent"],
                        help="check the Extensions menu's built-in line (default: present for builtin)")
    parser.add_argument("--config", default="{}", help="cmux.json the app starts with, e.g. {\"browser\": {\"builtInAdBlocker\": false}}")
    args = parser.parse_args()
    Job.config = args.config
    main.menu_note = args.menu_note
    if args.phase == "ublock" and not args.ubo:
        parser.error("--ubo is required")
    if args.phase == "builtin":
        args.ubo = None
    args.person = args.person or bool(args.load_unpacked)
    return {"store": phase_store, "baseline": phase_baseline, "ublock": phase_ublock, "builtin": phase_ublock}[args.phase](args)


if __name__ == "__main__":
    sys.exit(main())
