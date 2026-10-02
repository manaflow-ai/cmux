"""Real Chrome Web Store extensions: install, worker, popup, main-use check."""
import base64
import json
import os
import time
import urllib.request

from . import cdp, crx, pages
from .app import TaggedApp
from .collector import Collector

HERE = os.path.dirname(os.path.abspath(__file__))
LIST = os.path.join(os.path.dirname(HERE), "ext-store", "extensions.json")

EXTENSIONS_INFO_JS = """
new Promise((resolve) => chrome.developerPrivate.getExtensionsInfo({includeDisabled: true}, (items) =>
  resolve(items.map((e) => ({id: e.id, name: e.name, version: e.version, state: e.state,
    disableReasons: e.disableReasons, manifestErrors: (e.manifestErrors || []).map((x) => x.message),
    runtimeErrors: (e.runtimeErrors || []).filter((x) => x.severity === 'ERROR').map((x) => x.message),
    views: (e.views || []).map((v) => v.type + ' ' + v.url)})))))
"""

# Text and element count including open shadow roots (Grammarly, Loom).
DEEP_TEXT_JS = """
(() => { let text = '', nodes = 0; const walk = (root) => { for (const el of root.querySelectorAll('*')) { nodes++;
  if (el.shadowRoot) { text += ' ' + el.shadowRoot.textContent; walk(el.shadowRoot); } } };
  walk(document); text = ((document.body && document.body.innerText) || '') + text;
  return {w: innerWidth, h: innerHeight, text: text.replace(/\\s+/g, ' ').trim().slice(0, 120), nodes}; })()
"""

# DevTools panel ids, including panels in the tab strip's overflow menu
# (extension panels usually are, in a docked pane). Falls back to visible tabs.
DEVTOOLS_PANELS_JS = """
(async () => { try { const UI = await import('./ui/legacy/legacy.js'); const view = UI.InspectorView.InspectorView.instance();
  const pane = view.tabbedPane || view.tabbedPaneInternal; if (pane) return pane.tabIds(); } catch (e) {}
  const out = []; const walk = (root) => root.querySelectorAll('*').forEach((el) => {
    if (el.getAttribute && el.getAttribute('role') === 'tab') out.push(el.textContent.trim());
    if (el.shadowRoot) walk(el.shadowRoot); }); walk(document); return out; })()
"""


def schedule(items, batch):
    """Batches of `batch`, at most one ad blocker and one page-changing check each."""
    exclusive = [e for e in items if e["check"] in ("adblock", "darkreader", "json_viewer", "vimium", "new_tab")]
    rest = [e for e in items if e not in exclusive]
    batches = [[e] for e in exclusive]
    for index, entry in enumerate(rest):
        target = min(batches, key=len) if batches and min(len(b) for b in batches) < batch else None
        if target is None:
            target = []
            batches.append(target)
        target.append(entry)
        del index
    return batches


class StoreRun:
    def __init__(self, tag, out, log, only=None, limit=0, batch=6):
        self.tag = tag
        self.out = out
        self.log = log
        items = json.load(open(LIST))["extensions"]
        if only:
            wanted = set(only.split(","))
            items = [e for e in items if e["id"] in wanted]
        if limit:
            items = items[:limit]
        self.items = items
        self.batch = batch
        self.rows = []
        os.makedirs(os.path.join(out, "shots"), exist_ok=True)

    def row(self, entry, check, status, detail=""):
        self.rows.append({"suite": entry["name"], "api": entry["id"], "test": check, "status": status,
                          "detail": str(detail)[:300]})

    def execute(self):
        prepared = []
        for entry in self.items:
            if entry.get("unavailable"):
                self.row(entry, "install", "unsupported", entry["unavailable"])
                continue
            target = os.path.join(self.out, "ext", entry["id"])
            try:
                manifest, unpacked_id = crx.unpack(crx.fetch(entry["id"], source=entry.get("source")), target)
                entry = dict(entry, dir=target, manifest=manifest)
                if entry.get("source"):
                    entry["id"] = unpacked_id  # signed by its developer, not the Web Store
                same = unpacked_id == entry["id"]
                self.row(entry, "install", "pass" if same else "fail",
                         f"CRX {manifest.get('version')} MV{manifest.get('manifest_version')}" + ("" if same else f", id {unpacked_id}"))
                prepared.append(entry)
            except Exception as error:  # noqa: BLE001 - one bad download must not stop the run
                self.row(entry, "install", "fail", f"download/unpack: {error}")
        for number, group in enumerate(schedule(prepared, self.batch), 1):
            self.log(f"batch {number}: {', '.join(e['name'] for e in group)}")
            try:
                self.run_batch(group)
            except (Exception, SystemExit) as error:  # noqa: BLE001
                for entry in group:
                    self.row(entry, "batch", "error", f"batch aborted: {error}")
        return self.rows

    def run_batch(self, group):
        collector = Collector(run_id="store", extra_routes=pages.ROUTES).start()
        app = TaggedApp(self.tag, extensions=[e["dir"] for e in group], log_dir=self.out).launch()
        try:
            app.action("tab new-chromium", {"url": collector.url + "/home.html"})
            if not cdp.wait_target(app.cdp_port, lambda t: "/home.html" in t.get("url", ""), 90):
                raise RuntimeError("Chromium did not start within 90 s")
            time.sleep(6)  # let workers finish onInstalled before reading errors
            info = self.retry(lambda: self.extension_info(app), 3)
            for entry in group:
                try:
                    self.check(app, collector, entry, info.get(entry["id"]))
                except Exception as error:  # noqa: BLE001 - one extension must not end the batch
                    self.row(entry, "runner", "error", f"runner error: {error!r}")
        finally:
            app.quit()
            collector.stop()

    @staticmethod
    def retry(step, attempts):
        for attempt in range(attempts):
            try:
                return step()
            except (OSError, ConnectionError, RuntimeError, TypeError):
                if attempt == attempts - 1:
                    raise
                time.sleep(3)
        return None

    def browser_session(self, app):
        with urllib.request.urlopen(f"http://127.0.0.1:{app.cdp_port}/json/version", timeout=5) as response:
            return cdp.Session(json.loads(response.read())["webSocketDebuggerUrl"])

    def extension_info(self, app):
        browser = self.browser_session(app)
        try:
            # Open it as a cmux tab: CDP's createTarget uses the default
            # browser context, which has no cmux window (cmux refuses the
            # tab), and DevTools does not know the pane profiles' contexts.
            before = {t.get("id") for t in cdp.targets(app.cdp_port)}
            app.action("tab new-chromium", {"url": "chrome://extensions"})
            opened = cdp.wait_target(app.cdp_port, lambda t: t.get("id") not in before
                                     and t.get("url", "").startswith("chrome://extensions"), 15)
            if not opened:
                raise RuntimeError("chrome://extensions did not open")
            target = opened["id"]
            page = cdp.wait_target(app.cdp_port, lambda t: t.get("id") == target, 10)
            session = cdp.Session(page["webSocketDebuggerUrl"])
            time.sleep(1)
            items = session.evaluate(EXTENSIONS_INFO_JS) or []
            session.close()
            browser.call("Target.closeTarget", {"targetId": target})
            return {item["id"]: item for item in items}
        finally:
            browser.close()

    def check(self, app, collector, entry, info):
        if not info:
            self.row(entry, "loaded", "fail", "not in chrome://extensions")
            return
        enabled = info["state"] == "ENABLED"
        self.row(entry, "loaded", "pass" if enabled else "fail",
                 f"{info['name']} {info['version']}" + ("" if enabled else f" state {info['state']} {info['disableReasons']}"))
        errors = info["manifestErrors"] + info["runtimeErrors"]
        self.row(entry, "worker_no_errors", "pass" if not errors else "fail", "; ".join(errors[:3]) or ", ".join(info["views"]) or "idle")
        manifest = entry["manifest"]
        action = manifest.get("action") or manifest.get("browser_action") or {}
        check = entry["check"]
        if check in ("popup", "password_popup") or (action.get("default_popup") and check != "action_opens_tab"):
            try:
                self.popup(app, entry, info["name"], action)
            except Exception as error:  # noqa: BLE001
                self.row(entry, "popup", "fail", f"runner error: {error!r}")
                app.call("debug.extensions.popup", {"hide": True})
        kind, _, argument = check.partition(":")
        runner = getattr(self, "check_" + kind, None)
        if runner:
            try:
                runner(app, collector, entry, info, argument)
            except Exception as error:  # noqa: BLE001
                self.row(entry, check, "fail", error)

    @staticmethod
    def wait_tabs_settled(app, quiet=2.0, timeout=15):
        def shown():
            return [t.get("url") for t in (app.call("debug.cef").get("result") or {}).get("devtools") or []]
        deadline = time.monotonic() + timeout
        last, since = shown(), time.monotonic()
        while time.monotonic() < deadline and time.monotonic() - since < quiet:
            time.sleep(0.25)
            now = shown()
            if now != last:
                last, since = now, time.monotonic()

    def popup(self, app, entry, name, action):
        if not action.get("default_popup"):
            self.row(entry, "popup", "unsupported", "no default_popup in the manifest")
            return
        prefix = f"chrome-extension://{entry['id']}/"
        # Extensions open welcome tabs after install; a new foreground tab
        # closes an open action popup. Click once the shown
        # tabs stopped changing.
        self.wait_tabs_settled(app)
        before = {t.get("id") for t in cdp.targets(app.cdp_port)}
        clicked = app.call("debug.extensions.click", {"extension": entry["id"]}).get("result")
        target = cdp.wait_target(app.cdp_port, lambda t: t.get("id") not in before and t.get("type") == "page"
                                 and t.get("url", "").startswith(prefix), 8)
        if not target:
            # Say what the first click did, then click once more: a popup on
            # the second click means the first one was lost.
            first = {"click": clicked, "popup": app.call("debug.extensions.popup").get("result"),
                     "tabs": [t.get("url") for t in (app.call("debug.cef").get("result") or {}).get("devtools") or []]}
            app.call("debug.extensions.click", {"extension": entry["id"]})
            second = cdp.wait_target(app.cdp_port, lambda t: t.get("id") not in before and t.get("type") == "page"
                                     and t.get("url", "").startswith(prefix), 8)
            self.row(entry, "popup", "fail", f"toolbar click opened no popup; first click {first}; "
                     f"second click {'opened it' if second else 'opened none'}")
            return
        session = cdp.Session(target["webSocketDebuggerUrl"])
        try:
            state = {}
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                time.sleep(1)
                state = session.evaluate(DEEP_TEXT_JS)
                if state["w"] > 60 and state["h"] > 60 and (state["text"] or state["nodes"] > 20):
                    break
            shot = session.call("Page.captureScreenshot", {"format": "png"})
            png = base64.b64decode(shot["data"])
            path = os.path.join(self.out, "shots", f"{entry['id']}-popup.png")
            with open(path, "wb") as out:
                out.write(png)
            # Text can live in cross-origin iframes (Todoist, Toggl); a
            # blank or single-color popup compresses to a few KB.
            painted = len(png) > 6000
            rendered = state["w"] >= 50 and state["h"] >= 50 and (state["text"] or state["nodes"] > 20 or painted)
            self.row(entry, "popup", "pass" if rendered else "fail",
                     f"{state['w']}x{state['h']}, {state['nodes']} nodes, {len(png) // 1024} KB, text {state['text'][:60]!r}, "
                     f"shot shots/{os.path.basename(path)}")
        finally:
            session.close()
            app.call("debug.extensions.popup", {"hide": True})

    def open_page(self, app, collector, path):
        app.action("tab new-chromium", {"url": collector.url + path})
        target = cdp.wait_target(app.cdp_port, lambda t: t.get("type") == "page" and path in t.get("url", ""), 15)
        if not target:
            raise RuntimeError(f"no Chromium page for {path}")
        return cdp.Session(target["webSocketDebuggerUrl"])

    def poll(self, session, expression, timeout):
        deadline = time.monotonic() + timeout
        value = None
        while time.monotonic() < deadline:
            value = session.evaluate(expression)
            if value:
                return value
            time.sleep(0.5)
        return value

    def check_adblock(self, app, collector, entry, info, _):
        session = self.open_page(app, collector, "/ads.html")
        result = {}
        try:
            for attempt in range(5):
                result = self.poll(session, "window.cxtAds && window.cxtAds.script && window.cxtAds", 20) or {}
                if result.get("script") == "blocked":
                    break
                time.sleep(5)  # filter lists can still be downloading right after install
                session.call("Page.reload")
            result["attempts"] = attempt + 1
        finally:
            session.close()
        self.row(entry, "adblock", "pass" if result.get("script") == "blocked" else "fail", result)

    def check_darkreader(self, app, collector, entry, info, _):
        session = self.open_page(app, collector, "/light.html")
        try:
            result = self.poll(session, "(() => { const bg = getComputedStyle(document.body).backgroundColor;"
                                        " const styled = !!document.querySelector('style.darkreader');"
                                        " return (styled || bg !== 'rgb(255, 255, 255)') && {bg, styled}; })()", 12)
        finally:
            session.close()
        self.row(entry, "darkreader", "pass" if result else "fail", result or "page stayed white")

    def check_vimium(self, app, collector, entry, info, _):
        session = self.open_page(app, collector, "/links.html")
        try:
            time.sleep(1.5)
            session.call("Emulation.setFocusEmulationEnabled", {"enabled": True})
            for kind in ("keyDown", "keyUp"):
                session.call("Input.dispatchKeyEvent", {"type": kind, "key": "f", "code": "KeyF", "text": "f" if kind == "keyDown" else "",
                                                        "windowsVirtualKeyCode": 70, "nativeVirtualKeyCode": 3})
            result = self.poll(session, "(() => { let n = 0; const walk = (root) => root.querySelectorAll('*').forEach((el) => {"
                                        " if (/vimium/i.test(el.className + ' ' + el.id + ' ' + el.tagName)) n++; if (el.shadowRoot) walk(el.shadowRoot); });"
                                        " walk(document); return n; })()", 6)
        finally:
            session.close()
        self.row(entry, "vimium_link_hints", "pass" if result else "fail", f"{result or 0} Vimium hint nodes after 'f'")

    def check_json_viewer(self, app, collector, entry, info, _):
        session = self.open_page(app, collector, "/data.json")
        try:
            result = self.poll(session, "(() => { const known = document.querySelector('#json-viewer, .CodeMirror, #jsonFormatterParsed,"
                                        " #formattedJson, .json-formatter-row, #jfContent, json-viewer');"
                                        " return known ? known.tagName + '#' + known.id + '.' + known.className : ''; })()", 8)
        finally:
            session.close()
        self.row(entry, "json_formatted", "pass" if result else "fail", result or "raw JSON left unformatted")

    def check_devtools_panel(self, app, collector, entry, info, tab_text):
        page = {"Components": "/react.html", "Vue": "/vue.html"}.get(tab_text, "/home.html")
        session = self.open_page(app, collector, page)
        try:
            # Content scripts an extension registers at install miss a page
            # that loaded first (Chrome too); reload once, as a user would.
            time.sleep(2)
            session.call("Page.reload")
            time.sleep(3)
        finally:
            session.close()
        app.action("browser toggle-developer-tools")
        target = cdp.wait_target(app.cdp_port, lambda t: t.get("url", "").startswith("devtools://"), 10)
        if not target:
            self.row(entry, "devtools_panel", "fail", "no DevTools frontend target after Toggle Developer Tools")
            return
        session = cdp.Session(target["webSocketDebuggerUrl"])
        try:
            wanted = json.dumps(tab_text.lower())
            panels = self.poll(session, f"(async () => {{ const p = await {DEVTOOLS_PANELS_JS.strip()};"
                                        f" return p.some((x) => x.toLowerCase().includes({wanted})) && p; }})()", 20)
            if panels:
                ours = [p for p in panels if tab_text.lower() in p.lower()]
                self.row(entry, "devtools_panel", "pass", f"panels {ours}")
            else:
                self.row(entry, "devtools_panel", "fail", f"no {tab_text!r} panel; panels {session.evaluate(DEVTOOLS_PANELS_JS)}")
        finally:
            session.close()
            app.action("browser toggle-developer-tools")

    def check_action_opens_tab(self, app, collector, entry, info, _):
        before = {t.get("id") for t in cdp.targets(app.cdp_port)}
        app.call("debug.extensions.click", {"extension": entry["id"]})
        prefix = f"chrome-extension://{entry['id']}/"
        target = cdp.wait_target(app.cdp_port, lambda t: t.get("id") not in before and t.get("type") == "page"
                                 and t.get("url", "").startswith(prefix), 15)
        in_cmux = False
        for _ in range(25 if target else 0):  # cmux adopts Chromium-made tabs on a later main-actor turn
            in_cmux = any(url.startswith(prefix) for url in app.urls())
            if in_cmux:
                break
            time.sleep(0.2)
        self.row(entry, "action_opens_tab", "pass" if in_cmux else "fail",
                 (target or {}).get("url", "no extension page opened") + ("" if in_cmux else " (not a cmux tab)" if target else ""))

    def check_new_tab(self, app, collector, entry, info, _):
        app.action("tab new-chromium", {"url": "chrome://newtab/"})
        prefix = f"chrome-extension://{entry['id']}/"
        target = cdp.wait_target(app.cdp_port, lambda t: t.get("type") == "page" and t.get("url", "").startswith(prefix), 10)
        self.row(entry, "new_tab_override", "pass" if target else "fail",
                 target["url"] if target else "chrome://newtab did not show the override")
