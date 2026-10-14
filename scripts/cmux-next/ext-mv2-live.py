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
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402
from ext_e2e import cdp  # noqa: E402
from ext_e2e.app import free_port  # noqa: E402

STORE_EXTENSION = ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader")  # MV3 on the store
UBO_NAME = "uBlock Origin"
# Public ad block score pages: informational only (third-party pages that can
# change or stop running; d3ward's is archived). The gating checks are the
# local ad page and dynamic filtering.
SCORE_PAGES = (("d3ward", "https://d3ward.github.io/toolz/adblock.html", "d3ward.github.io"),
               ("turtlecute", "https://adblock.turtlecute.org/", "adblock.turtlecute.org"))
AD_SCRIPT = "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"
JQUERY = "https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"

ADS_PAGE = """<!doctype html><meta charset="utf-8"><title>mv2 ads</title>
<body style="background:#fff;font:16px -apple-system,sans-serif">
<h1>Ad test page</h1>
<div class="adsbygoogle ad-banner" id="ad-slot" style="width:300px;height:120px;background:#fdd">ad slot (.adsbygoogle)</div>
<p id="state">running</p>
<script>window.mv2 = {};</script>
<script src="%s"
  onload="mv2.ad='loaded'" onerror="mv2.ad='blocked'"></script>
<script src="%s" onload="mv2.jq='loaded'" onerror="mv2.jq='blocked'"></script>
<script>
addEventListener('load', () => setTimeout(() => {
  const slot = document.getElementById('ad-slot');
  mv2.slot = slot && getComputedStyle(slot).display === 'none' ? 'hidden' : 'shown';
  mv2.done = true;
  document.getElementById('state').textContent = JSON.stringify(mv2);
}, 1500));
</script>
""" % (AD_SCRIPT, JQUERY)


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
            empty.write("{}\n")
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
        deadline = time.monotonic() + 90
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
        opened = self.call("action.run", {"action": "openBrowser.chromium", "args": {"url": url},
                                          "focus": True, "origin": "remote"})
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
        data = session.call("Page.captureScreenshot", params, timeout=30)["data"]
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
            if not expect_blocked or (state.get("ad") == "blocked" and state.get("slot") == "hidden"):
                break
            time.sleep(5)  # first run: uBlock Origin may still compile its filter lists
            session.call("Page.reload")
        state["attempts"] = attempt + 1
        state["shot"] = job.page_shot(session, f"{label}-ads-page")
    finally:
        session.close()
    if expect_blocked:
        job.row(f"{label}: ad script blocked (network filter)", state.get("ad") == "blocked", state)
        job.row(f"{label}: ad slot hidden (cosmetic filter)", state.get("slot") == "hidden", state)
    else:
        job.row(f"{label}: ad script loads without a blocker", state.get("ad") == "loaded", state)
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


def phase_store(_args):
    job = Job("store")
    job.launch()
    try:
        ext_id, name = STORE_EXTENSION
        session = job.open_tab(f"https://chromewebstore.google.com/detail/{ext_id}", match=ext_id, timeout=45)
        try:
            find = ("(() => { const b = [...document.querySelectorAll('button')].find(e => /add to chrome/i.test(e.innerText));"
                    " if (!b) return null; b.scrollIntoView({block: 'center'}); const r = b.getBoundingClientRect();"
                    " return [r.x + r.width / 2, r.y + r.height / 2, b.innerText.trim()]; })()")
            button = poll(session, find, 45)
            job.page_shot(session, "store-detail")
            if not button:
                job.row("store: Add to Chrome button", False, "no button within 45 s")
                return job.finish()
            time.sleep(1)
            button = session.evaluate(find)
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
                return job.finish()
            answer = job.call("debug.extensions.prompt", {"id": prompt["id"], "answer": "accept"}).get("result")
            installed = None
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline and not installed:
                installed = next((e for e in job.extensions_report() if e.get("id") == ext_id), None)
                time.sleep(1)
            job.row("store: installed and enabled (no FAILED_TO_COPY error)",
                    bool(installed and installed.get("enabled")), {"answer": answer, "extension": installed})
            errors = poll(session, "(() => { const t = document.body.innerText;"
                                   " const m = t.match(/Could not install package[^\\n]*/); return m ? m[0] : ''; })()", 2)
            job.row("store: no install error on the page", not errors, errors or "none")
            job.page_shot(session, "store-after-install")
            job.window_shot("store-window")
        finally:
            session.close()
        downloads = os.path.expanduser("~/Downloads")
        stray = [f for f in os.listdir(downloads) if f.endswith(".crx") and os.path.getmtime(os.path.join(downloads, f)) > time.time() - 600]
        job.row("store: no CRX copied into Downloads", not stray, stray or "none")
    finally:
        job.stop()
    return job.finish()


def phase_baseline(_args):
    server, url = serve()
    job = Job("baseline")
    job.launch()
    try:
        ads_check(job, url, "baseline", expect_blocked=False)
        score_pages(job, "baseline")
    finally:
        job.stop()
        server.shutdown()
    return job.finish()


def phase_ublock(args):
    server, url = serve()
    job = Job("ublock", extensions=[args.ubo])
    job.launch()
    try:
        ubo = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not ubo:
            ubo = next((e for e in job.extensions_report() if e.get("name") == UBO_NAME), None)
            time.sleep(0.5)
        job.row("ublock: loaded and enabled", bool(ubo and ubo.get("enabled")), ubo or "not listed")
        if not ubo:
            return job.finish()
        ext_id = ubo["id"]
        prefix = f"chrome-extension://{ext_id}/"
        background = cdp.wait_target(job.port, lambda t: t.get("type") == "background_page"
                                     and t.get("url", "").startswith(prefix), 30)
        manifest_version = None
        if background:
            bg = cdp.Session(background["webSocketDebuggerUrl"])
            try:
                manifest_version = bg.evaluate("chrome.runtime.getManifest().manifest_version")
            finally:
                bg.close()
        job.row("ublock: MV2 background page runs", manifest_version == 2 and background is not None,
                {"background": (background or {}).get("url"), "manifest_version": manifest_version})
        time.sleep(10)  # first start compiles the bundled filter lists
        # Controls: the host reaches both scripts, so "blocked" in the page is uBlock Origin.
        for name, address in (("ad script", AD_SCRIPT), ("jQuery CDN", JQUERY)):
            status = host_reaches(address)
            job.row(f"control: the host reaches the {name}", status == 200, {"url": address, "status": status})
        ads_check(job, url, "ublock", expect_blocked=True)
        score_pages(job, "ublock")

        # Popup through the toolbar button's own click path.
        before = {t.get("id") for t in cdp.targets(job.port)}
        click = job.call("debug.extensions.click", {"extension": ext_id}).get("result")
        popup = cdp.wait_target(job.port, lambda t: t.get("id") not in before and t.get("type") == "page"
                                and t.get("url", "").startswith(prefix + "popup"), 10)
        popup_detail = {"click": click, "url": (popup or {}).get("url")}
        if popup:
            session = cdp.Session(popup["webSocketDebuggerUrl"])
            try:
                ready = poll(session, "(() => { const b = document.body; const r = b.getBoundingClientRect();"
                                      " return r.width > 100 && r.height > 100 && document.querySelector('#switch') ? [r.width, r.height] : null; })()", 15)
                popup_detail["size"] = ready
                popup_detail["shot"] = job.page_shot(session, "ublock-popup")
            finally:
                session.close()
            popup_detail["window_shot"] = job.window_shot("ublock-popup-window", popups=True)
        job.row("ublock: popup opens", bool(popup and popup_detail.get("size")), popup_detail)
        job.call("debug.extensions.popup", {"hide": True})

        # Dashboard.
        session = job.open_tab(prefix + "dashboard.html", match="dashboard.html")
        try:
            ready = poll(session, "(() => { const f = document.querySelector('iframe');"
                                  " return f && f.contentDocument && f.contentDocument.readyState === 'complete'"
                                  " && f.contentDocument.body.innerText.length > 50 ? f.src : null; })()", 20)
            shot = job.page_shot(session, "ublock-dashboard")
        finally:
            session.close()
        job.row("ublock: dashboard loads", bool(ready), {"pane": ready, "shot": shot})

        # Dynamic filtering: the third-party script loads, then a rule blocks it.
        jq_before = ads_check_jq(job, url)
        rules = job.open_tab(prefix + "dyna-rules.html", match="dyna-rules.html")
        try:
            poll(rules, "typeof vAPI === 'object' && vAPI.messaging && true", 15)
            result = rules.evaluate(
                "vAPI.messaging.send('dashboard', {what: 'modifyRuleset', permanent: false,"
                " toAdd: '* * 3p-script block', toRemove: ''}).then(r => r && r.sessionRules ? r.sessionRules.filter(x => /3p-script/.test(x)) : r)")
            rules.call("Page.reload")
            time.sleep(2)
            rules_shot = job.page_shot(rules, "ublock-dynamic-rules")
        finally:
            rules.close()
        jq_after = ads_check_jq(job, url)
        job.row("ublock: dynamic filtering blocks a third-party script",
                jq_before == "loaded" and jq_after == "blocked",
                {"before": jq_before, "rule": result, "after": jq_after, "shot": rules_shot})
        job.window_shot("ublock-window")
    finally:
        job.stop()
        server.shutdown()
    return job.finish()


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
    parser.add_argument("phase", choices=["store", "baseline", "ublock"])
    parser.add_argument("--ubo", help="ublock: unpacked uBlock Origin directory")
    args = parser.parse_args()
    if args.phase == "ublock" and not args.ubo:
        parser.error("--ubo is required")
    return {"store": phase_store, "baseline": phase_baseline, "ublock": phase_ublock}[args.phase](args)


if __name__ == "__main__":
    sys.exit(main())
