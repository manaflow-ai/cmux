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
ad slot; the d3ward ad block test score; the popup opens; the dashboard
loads; a dynamic rule (`* * 3p-script block`) blocks a third-party script
that loads without it.
"""
import argparse
import base64
import functools
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402
from ext_e2e import cdp  # noqa: E402
from ext_e2e.app import free_port  # noqa: E402

STORE_EXTENSION = ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader")  # MV3 on the store
UBO_NAME = "uBlock Origin"
D3WARD = "https://d3ward.github.io/toolz/adblock.html"
JQUERY = "https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"

ADS_PAGE = """<!doctype html><meta charset="utf-8"><title>mv2 ads</title>
<body style="background:#fff;font:16px -apple-system,sans-serif">
<h1>Ad test page</h1>
<div class="adsbygoogle ad-banner" id="ad-slot" style="width:300px;height:120px;background:#fdd">ad slot (.adsbygoogle)</div>
<p id="state">running</p>
<script>window.mv2 = {};</script>
<script src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"
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
""" % JQUERY


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
        env = {
            "CMUX_NEXT_NO_ACTIVATE": "1",
            # Never the person's Chief home; the proof opens no Home or Chief pane.
            "CMUX_NEXT_CHIEF_ISOLATED": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={self.port}:remote-allow-origins=*",
        }
        if self.extensions:
            env["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] = ":".join(self.extensions)
        command = ["/usr/bin/open", "-g", "-n", "-a", self.app]
        for key, value in env.items():
            command += ["--env", f"{key}={value}"]
        logfile = os.path.join(self.out, "app.log")
        command += ["--stdout", logfile, "--stderr", logfile]
        subprocess.run(command, check=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                self.client = Client(self.socket, timeout=30)
                if (self.client.call("debug.cef").get("result") or {}).get("ok", True):
                    break
            except (OSError, ConnectionError, ValueError):
                time.sleep(0.3)
        else:
            raise SystemExit("the app socket never answered")
        binary = os.path.join(self.app, "Contents/MacOS")
        binary = os.path.join(binary, os.listdir(binary)[0])
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        pids = [int(p) for p, _, c in (line.strip().partition(" ") for line in listing.splitlines()) if c == binary]
        self.pid = pids[-1] if pids else None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                cdp.targets(self.port)
                break
            except OSError:
                time.sleep(0.3)
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
        opened = self.call("action.run", {"action": "tab new-chromium", "args": {"url": url}})
        for tab in ((opened.get("result") or {}).get("created") or [])[:1]:
            self.call("tab.focus", {"tab": tab})
        key = match or url
        target = cdp.wait_target(self.port, lambda t: t.get("type") == "page" and t.get("id") not in before
                                 and key in t.get("url", ""), timeout)
        if not target:
            raise RuntimeError(f"no Chromium page for {url}: {opened}")
        return cdp.Session(target["webSocketDebuggerUrl"], timeout=30)

    def extensions_report(self):
        return (self.call("browser.extensions").get("result") or {}).get("extensions") or []

    # -- evidence ---------------------------------------------------------
    def row(self, check, ok, detail):
        self.results.append({"check": check, "ok": bool(ok), "detail": detail})
        log(f"{'PASS' if ok else 'FAIL'} {check}: {json.dumps(detail)[:400]}")

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
        ok = bool(self.results) and all(r["ok"] for r in self.results)
        with open(os.path.join(self.out, "results.json"), "w") as out:
            json.dump({"phase": self.phase, "ok": ok, "results": self.results}, out, indent=2)
        log(f"{self.phase}: {'ALL PASS' if ok else 'FAILURES'} ({sum(r['ok'] for r in self.results)}/{len(self.results)})")
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


def d3ward_score(job, label):
    session = job.open_tab(D3WARD, match="d3ward.github.io")
    try:
        time.sleep(20)  # the page runs its probes, then writes the score
        text = session.evaluate("document.body.innerText") or ""
        shot = job.page_shot(session, f"{label}-d3ward", full=True)
    finally:
        session.close()
    numbers = re.findall(r"(\d{1,3}(?:\.\d+)?)\s*%", text)
    detail = {"percents": numbers[:6], "text_head": text[:600], "shot": shot}
    job.row(f"{label}: d3ward score read", bool(numbers), detail)
    return detail


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
        d3ward_score(job, "baseline")
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
        ads_check(job, url, "ublock", expect_blocked=True)
        d3ward_score(job, "ublock")

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
