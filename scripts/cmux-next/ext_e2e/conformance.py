"""API conformance run: install the test extensions, run their automatic
phase, drive the UI-only checks through the cmux socket and CDP, and collect
the matrix."""
import json
import os
import shutil
import time

from . import cdp
from .app import TaggedApp
from .collector import Collector

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(os.path.dirname(HERE), "ext-conformance")
MV3_ID = "ndhjbbklkfjgahebkncbjidjanefmeeh"
MV2_ID = "lmdckjkaimgajjbpcoaafllmmfjcgikf"

# Checks that need a runner step. Each gets a result even when the step cannot
# run, so the matrix never silently drops a row.
UI_CHECKS = [
    ("mv3", "action", "toolbar_button"),
    ("mv3", "action", "toolbar_title"),
    ("mv3", "action", "pin_to_toolbar"),
    ("mv3", "action", "onClicked"),
    ("mv3", "action", "popup_click"),
    ("mv3", "action", "popup_size"),
    ("mv3", "action", "openPopup"),
    ("mv3", "action", "openPopup_loaded"),
    ("mv3", "runtime", "sendMessage_popup_to_sw"),
    ("mv3", "runtime", "connect_port"),
    ("mv3", "tabs", "query_from_popup"),
    ("mv3", "permissions", "request_prompt"),
    ("mv3", "sidePanel", "open"),
    ("mv3", "sidePanel", "page_loaded"),
    ("mv3", "sidePanel", "cmux_header_keyboard"),
    ("mv3", "commands", "onCommand"),
    ("mv3", "contextMenus", "onClicked"),
    ("mv3", "devtools", "devtools_page_loaded"),
    ("mv3", "devtools", "panels.create"),
    ("mv3", "devtools", "inspectedWindow.eval"),
    ("mv3", "omnibox", "onInputEntered"),
    ("mv3", "content_scripts", "all_frames.top"),
    ("mv3", "content_scripts", "all_frames.same_origin_iframe"),
    ("mv3", "content_scripts", "all_frames.cross_origin_iframe"),
    ("mv3", "runtime", "sendMessage_content_to_sw"),
    ("mv3", "web_accessible_resources", "listed_resource"),
    ("mv3", "web_accessible_resources", "unlisted_resource_denied"),
    ("mv3", "tabs", "create_on_install"),
    ("mv3", "cmux", "tabs.create_adopted"),
    ("mv3", "cmux", "windows.create_mapped"),
    ("mv3", "cmux", "windows.create_popup_mapped"),
    ("mv3", "cmux", "tabs_in_sync"),
    ("mv2", "mv2", "loaded"),
    ("mv2", "mv2", "popup_getBackgroundPage"),
]


def stage(run_dir, collector):
    """Copies the test extensions with harness.js and config.json."""
    out = []
    for suite in ("mv3", "mv2"):
        target = os.path.join(run_dir, "ext", suite)
        shutil.copytree(os.path.join(SOURCE, suite), target, dirs_exist_ok=True)
        shutil.copy(os.path.join(SOURCE, "shared", "harness.js"), target)
        with open(os.path.join(target, "config.json"), "w") as config:
            json.dump({"collector": collector.url, "run": collector.run_id}, config)
        out.append(target)
    return out


class Run:
    def __init__(self, tag, run_dir, log):
        self.tag = tag
        self.run_dir = run_dir
        self.log = log
        self.collector = Collector(run_id=str(int(time.time()))).start()
        self.app = None
        self.context = None

    def note(self, suite, api, test, status, detail=""):
        self.collector.record("/r", {"suite": suite, "api": api, "test": test, "status": status,
                                     "detail": str(detail)[:400], "source": "runner"})

    def has(self, suite, api, test, statuses=("pass", "fail", "unsupported")):
        result = self.collector.result(suite, api, test)
        return bool(result and result.get("status") in statuses)

    def wait(self, suite, api, test, timeout):
        return self.collector.wait_for(lambda c: self.has(suite, api, test), timeout)

    def profile_target(self, kind, prefix, timeout=20):
        """A target of the cmux profile (the Chromium tab's browser context)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                infos = cdp.target_infos(self.app.cdp_port)
            except (OSError, ConnectionError, RuntimeError):
                time.sleep(0.25)  # Chromium (and its DevTools port) is still starting
                continue
            if self.context is None:
                home = next((t for t in infos if t["type"] == "page" and "/home.html" in t["url"]), None)
                self.context = home and home.get("browserContextId")
            match = next((t for t in infos if t["type"] == kind and t["url"].startswith(prefix)
                          and t.get("browserContextId") == self.context), None)
            if match:
                return cdp.page_session(self.app.cdp_port, match["targetId"])
            time.sleep(0.25)
        return None

    def sw_session(self, extension_id):
        return self.profile_target("service_worker", f"chrome-extension://{extension_id}/")

    def call_when_defined(self, session, name, timeout=15):
        """The worker target can appear before its script has run."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if session.evaluate(f"typeof {name}") == "function":
                return session.evaluate(f"{name}()")
            time.sleep(0.25)
        raise RuntimeError(f"{name} never defined: {session.evaluate('location.href')}")

    def start_phases(self):
        worker = self.sw_session(MV3_ID)
        if not worker:
            self.note("mv3", "harness", "worker_found", "fail", "no MV3 service worker in the cmux profile")
        else:
            self.log(f"MV3 auto phase: {self.call_when_defined(worker, 'startAutoPhase')}")
            worker.close()
        page = self.profile_target("background_page", f"chrome-extension://{MV2_ID}/")
        if not page:
            self.note("mv2", "harness", "background_found", "fail", "no MV2 background page in the cmux profile")
        else:
            self.log(f"MV2 phase: {self.call_when_defined(page, 'startMV2Phase')}")
            page.close()

    def execute(self):
        """Launch 1: the API phases (they create and close many tabs and
        windows), then tab-list consistency. Launch 2: the UI checks on a
        fresh profile, so a tab-mapping failure in launch 1 cannot hide the
        state of the toolbar, popups, commands and menus."""
        extensions = stage(self.run_dir, self.collector)
        try:
            self.launch(extensions)
            self.start_phases()
            self.watch_auto_phase()
            self.collector.wait_for(lambda c: c.has_event("phase", phase="mv2", state="done"), 30)
            self.guarded(self.tabs_in_sync_check)
            self.guarded(self.focus_page_tab)
            self.app.quit()
            self.launch(extensions)
            self.worker_call("resetForUIPhase")
            opened = self.app.action("tab new-chromium", {"url": self.collector.url + "/page.html?suite=mv3"})
            self.log(f"UI launch: page tab {opened.get('ok')}")
            self.guarded(self.ui_checks)
        finally:
            self.finish()
        return self.collector.snapshot()

    def watch_auto_phase(self, timeout=600):
        """Waits for the MV3 automatic phase; checks cmux adopted the tabs and
        windows the extension created while it runs."""
        deadline = time.monotonic() + timeout
        handled = set()
        while time.monotonic() < deadline:
            snapshot = self.collector.snapshot()
            for index, event in enumerate(snapshot["events"]):
                if event.get("kind") != "tab" or index in handled:
                    continue
                handled.add(index)
                self.check_adoption(event)
            if self.collector.has_event("phase", phase="auto", state="done"):
                self.log("auto phase done")
                return True
            time.sleep(0.3)
        self.note("mv3", "harness", "auto_phase_done", "fail", f"no 'done' after {timeout} s")
        return False

    def check_adoption(self, event):
        role = event.get("role")
        found = False
        for _ in range(20):
            urls = self.app.urls()
            if role == "page":
                found = any("/page.html?suite=mv3" in url for url in urls)
            else:
                found = any(("window=1" if role == "window" else "popup=1") in url for url in urls)
                if not found and role == "popup-window":
                    # Fork API 13: the popup keeps its own window, shown in a
                    # popup panel (debug.popups), not as a pane tab.
                    panels = (self.app.call("debug.popups").get("result") or {}).get("panels") or []
                    found = any("popup=1" in (panel.get("url") or "") and panel.get("child_windows") for panel in panels)
                    self.popup_panels = [(panel.get("url"), len(panel.get("child_windows") or [])) for panel in panels]
                    if not found:
                        try:
                            windows = (self.app.call("debug.cef").get("result") or {}).get("windows") or {}
                            self.popup_panels = {"popup_windows": windows.get("popup_windows"), "panels": self.popup_panels,
                                                 "fork_foreign": windows.get("fork_foreign_browsers")}
                        except Exception:  # noqa: BLE001 - diagnostics only
                            pass
            if found:
                break
            time.sleep(0.15)
        if role == "page":
            self.note("mv3", "cmux", "tabs.create_adopted", "pass" if found else "fail",
                      "cmux owns the tab" if found else "chrome.tabs.create tab missing from the cmux snapshot")
        elif role == "window":
            self.note("mv3", "cmux", "windows.create_mapped", "pass" if found else "fail",
                      "cmux shows the window's tab" if found else "chrome.windows.create window missing from the cmux snapshot")
        elif role == "popup-window":
            self.note("mv3", "cmux", "windows.create_popup_mapped", "pass" if found else "fail",
                      "cmux shows the popup window's tab" if found else
                      f"chrome.windows.create(type popup) tab missing from the cmux snapshot and popup panels {getattr(self, 'popup_panels', None)}")

    def poll(self, read, done, timeout):
        deadline = time.monotonic() + timeout
        value = read()
        while not done(value) and time.monotonic() < deadline:
            time.sleep(0.2)
            value = read()
        return value

    def wait_menu(self, timeout=5):
        state = self.poll(lambda: self.app.call("debug.extensions.menu").get("result") or {}, lambda m: m.get("open"), timeout)
        return bool(state.get("open"))

    def extensions(self):
        return self.app.call("browser.extensions").get("result") or {}

    def launch(self, extensions):
        self.context = None
        self.app = TaggedApp(self.tag, extensions=extensions, log_dir=self.run_dir).launch()
        self.log(f"app pid {self.app.process.pid}, collector {self.collector.url}, cdp {self.app.cdp_port}")
        opened = self.app.action("tab new-chromium", {"url": self.collector.url + "/home.html"})
        self.log(f"open Chromium tab: {opened.get('ok')} {opened.get('error') or ''}")

    def guarded(self, step):
        try:
            return step()
        except (OSError, ConnectionError, RuntimeError) as error:
            self.note("mv3", "harness", step.__name__, "fail", f"runner error: {error!r}")
            return None

    def worker_call(self, name):
        worker = self.sw_session(MV3_ID)
        if worker:
            try:
                return self.call_when_defined(worker, name)
            finally:
                worker.close()
        return None

    def browser_tabs(self):
        topology = self.app.snapshot().get("topology") or {}
        return [(tab.get("id"), tab.get("url") or "") for workspace in topology.get("workspaces", [])
                for screen in workspace.get("screens", []) for pane in screen.get("panes", [])
                for tab in pane.get("tabs", []) if tab.get("kind") == "browser"]

    def tabs_in_sync_check(self):
        """chrome.tabs (cmux profile) and the cmux tab list name the same pages."""
        worker = self.sw_session(MV3_ID)
        if not worker:
            return
        query = "chrome.tabs.query({}).then((t) => t.map((x) => x.url || x.pendingUrl))"
        chrome_urls, cmux_urls = [], []
        for _ in range(10):
            chrome_urls = sorted(worker.evaluate(query) or [])
            cmux_urls = sorted(url for _, url in self.browser_tabs())
            if chrome_urls == cmux_urls:
                break
            time.sleep(0.5)
        worker.close()
        extra_cmux = [u for u in cmux_urls if u not in chrome_urls]
        extra_chrome = [u for u in chrome_urls if u not in cmux_urls]
        self.log(f"tabs: chrome {chrome_urls} cmux {cmux_urls}")
        self.note("mv3", "cmux", "tabs_in_sync", "pass" if not extra_cmux and not extra_chrome else "fail",
                  {"only_in_cmux": extra_cmux, "only_in_chrome": extra_chrome})

    def focus_page_tab(self):
        """chrome.tabs.update(active) must select the tab in cmux (checked);
        after that, select it through cmux so the UI checks run on a live
        Chromium tab even when the check failed."""
        url = self.collector.url + "/page.html?suite=mv3"
        worker = self.sw_session(MV3_ID)
        if worker:
            worker.evaluate(f"chrome.tabs.query({{url: {json.dumps(url)}}}).then((t) => t[0] && chrome.tabs.update(t[0].id, {{active: true}}))")
            worker.close()
        focus = self.poll(self.focused_url, lambda u: u == url, 5)
        self.note("mv3", "cmux", "tabs.update_active_selects", "pass" if focus == url else "fail",
                  f"focused tab {focus!r} after chrome.tabs.update(active: true)")
        if focus != url:
            tab = next((tab_id for tab_id, tab_url in self.browser_tabs() if tab_url == url), None)
            if tab:
                self.app.action("tab go-to", {"tab": tab})
                focus = self.poll(self.focused_url, lambda u: u == url, 5)
        return focus == url

    def ui_checks(self):
        app = self.app
        page = self.collector.url + "/page.html?suite=mv3"
        if self.poll(self.focused_url, lambda u: u == page, 10) != page:
            self.note("mv3", "harness", "ui_page_focused", "fail", f"focused tab {self.focused_url()!r}")
        # Toolbar action for the MV3 extension, with the badge and title the worker set.
        report = self.extensions()
        action = next((a for a in report.get("actions", []) if a.get("id") == MV3_ID), None)
        toolbar = app.call("debug.extensions.toolbar").get("result") or {}
        # Unpinned actions live in the Extensions menu.
        placed = MV3_ID in toolbar.get("visible_actions", []) + toolbar.get("overflow_actions", []) or (
            action and not action.get("pinned") and toolbar.get("shows_extensions_button"))
        self.note("mv3", "action", "toolbar_button", "pass" if action and placed else "fail",
                  {"action": action, "visible": toolbar.get("visible_actions"), "overflow": toolbar.get("overflow_actions"),
                   "error": report.get("error") or toolbar.get("error")})
        if action:
            ok = action.get("badge") == "OK" and action.get("title") == "cmux conformance ready"
            self.note("mv3", "action", "toolbar_title", "pass" if ok else "fail",
                      f"badge {action.get('badge')!r}, title {action.get('title')!r}")
        # Pin through the Extensions menu, then the action has its own button.
        app.call("debug.extensions.click", {"button": "extensions"})
        opened = self.wait_menu()
        chose = app.call("debug.extensions.menu", {"choose": "pin", "extension": MV3_ID}).get("result") or {}
        app.call("debug.extensions.menu", {"dismiss": True})
        toolbar = self.poll(lambda: (app.call("debug.extensions.toolbar").get("result") or {}), lambda t: MV3_ID in t.get("visible_actions", []), 5)
        self.note("mv3", "action", "pin_to_toolbar", "pass" if MV3_ID in toolbar.get("visible_actions", []) else "fail",
                  {"menu_open": opened, "chose": chose.get("chose") or chose.get("error"), "visible": toolbar.get("visible_actions")})
        # Popup through the toolbar button (the button's click path).
        clicked = app.call("debug.extensions.click", {"extension": MV3_ID}).get("result") or {}
        self.log(f"toolbar click: {clicked}")
        if not self.wait("mv3", "action", "popup_click", 10):
            self.note("mv3", "action", "popup_click", "fail", f"popup never loaded after the toolbar click {clicked}")
        popup = app.call("debug.extensions.popup").get("result") or {}
        self.log(f"open popup: {popup}")
        self.popup_gesture_checks()
        app.call("debug.extensions.popup", {"hide": True})
        # chrome.action.openPopup() from the worker.
        session = self.sw_session(MV3_ID)
        if session:
            try:
                session.evaluate("runUIPhase('openPopup')", timeout=15)
            except (RuntimeError, OSError) as error:
                self.note("mv3", "action", "openPopup", "fail", error)
            opened = self.collector.result("mv3", "action", "openPopup") or {}
            if "active browser window" in opened.get("detail", "") or "inactive" in opened.get("detail", "").lower():
                # openPopup requires the active window; this launch never activates (AGENT-BRIEF).
                reason = "needs an active (key) window; this no-activate launch cannot check it: " + opened["detail"]
                self.collector.results[("mv3", "action", "openPopup")]["status"] = "unverified"
                self.note("mv3", "action", "openPopup_loaded", "unverified", reason)
            elif not self.wait("mv3", "action", "openPopup_loaded", 8):
                self.note("mv3", "action", "openPopup_loaded", "fail", "no popup after chrome.action.openPopup()")
            session.close()
        app.call("debug.extensions.popup", {"hide": True})
        # Extension command shortcut through the app's key routing.
        key = app.call("debug.key", {"key": "u", "modifiers": ["option", "shift"], "target": "page"})
        self.log(f"command key: {key.get('result')}")
        if not self.wait("mv3", "commands", "onCommand", 5):
            self.note("mv3", "commands", "onCommand", "fail", f"no onCommand for Option-Shift-U ({key.get('result')})")
        # No popup: the click fires chrome.action.onClicked (OneTab, Session Buddy style).
        worker = self.sw_session(MV3_ID)
        if worker:
            worker.evaluate("setPopupForUI('')")
            clicked = app.call("debug.extensions.click", {"extension": MV3_ID}).get("result") or {}
            if not self.wait("mv3", "action", "onClicked", 8):
                self.note("mv3", "action", "onClicked", "fail", f"no chrome.action.onClicked after the toolbar click {clicked}")
            worker.evaluate("setPopupForUI('popup.html')")
            worker.close()
        # MV2 browser action popup (chrome.extension.getBackgroundPage).
        app.call("debug.extensions.click", {"extension": MV2_ID})
        if not self.wait("mv2", "mv2", "popup_getBackgroundPage", 10):
            self.note("mv2", "mv2", "popup_getBackgroundPage", "fail", "MV2 popup never loaded after the toolbar click")
        app.call("debug.extensions.popup", {"hide": True})
        self.context_menu_check()
        self.devtools_check()
        self.omnibox_check()
        self.side_panel_header_check()

    def side_panel_header_check(self):
        """Opens the side panel with a toolbar click (openPanelOnActionClick)
        and reads cmux's header from debug.cef: cmux draws it, so none of
        Chromium's own header buttons may stay in the Tab/F6 order."""
        app = self.app
        worker = self.sw_session(MV3_ID)
        if not worker:
            self.note("mv3", "sidePanel", "cmux_header_keyboard", "fail", "no extension service worker")
            return
        worker.evaluate("chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true}).then(() => setPopupForUI(''))")
        if self.focused_url() is None:
            self.focus_page_tab()
        app.call("debug.extensions.click", {"extension": MV3_ID})

        def header():
            tabs = (app.call("debug.cef").get("result") or {}).get("devtools") or []
            return next((t["side_panel"] for t in tabs if t.get("side_panel")), None)
        panel = self.poll(header, lambda p: p is not None and "chromium_focusable" in p, 8)
        ok = bool(panel) and panel.get("chromium_focusable") == 0 and "close" in (panel.get("controls") or [])
        self.note("mv3", "sidePanel", "cmux_header_keyboard", "pass" if ok else "fail",
                  panel or "no cmux side panel header (or no chromium_focusable) after the toolbar click")
        if panel:
            app.call("debug.cef", {"side_panel": "close"})
        worker.evaluate("chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: false}).then(() => setPopupForUI('popup.html'))")
        worker.close()

    def popup_gesture_checks(self):
        session = self.profile_target("page", f"chrome-extension://{MV3_ID}/popup.html", 5)
        if not session:
            self.note("mv3", "permissions", "request_prompt", "fail", "no popup target to click in")
            return
        try:
            session.click_selector("#side")
            if not self.wait("mv3", "sidePanel", "open", 5):
                self.note("mv3", "sidePanel", "open", "fail", "no result from sidePanel.open")
            if not self.wait("mv3", "sidePanel", "page_loaded", 5):
                self.note("mv3", "sidePanel", "page_loaded", "fail", "sidepanel.html never loaded")
            session.click_selector("#perm")
            if not self.answer_prompt("permissions"):
                self.note("mv3", "permissions", "request_prompt", "fail",
                          "no cmux permission prompt appeared (debug.extensions.prompt)")
            elif not self.wait("mv3", "permissions", "request_prompt", 8):
                self.note("mv3", "permissions", "request_prompt", "fail",
                          "chrome.permissions.request did not settle after the prompt was accepted")
        except (RuntimeError, OSError, ConnectionError) as error:
            self.note("mv3", "permissions", "request_prompt", "fail", error)
        finally:
            session.close()

    def answer_prompt(self, kind, timeout=6):
        """Accepts the cmux extension prompt of `kind` through its sheet's
        debug verb (fork API 12). False when none appeared."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            prompts = (self.app.call("debug.extensions.prompt").get("result") or {}).get("prompts") or []
            for prompt in prompts:
                if prompt.get("kind") == kind:
                    self.app.call("debug.extensions.prompt", {"id": prompt["id"], "answer": "accept"})
                    return True
            time.sleep(0.2)
        return False

    def omnibox_check(self):
        """Types the extension's keyword, a space and text into a new tab's
        omnibar (debug.key, this app only), then Enter: onInputEntered."""
        app = self.app
        app.action("openBrowser", {"engine": "cef"})
        # Type only once the new tab's omnibar has focus (a fixed wait lost
        # the keys on a loaded machine).
        self.poll(lambda: app.call("debug.omnibar").get("result") or {},
                  lambda o: o.get("has_focus") and o.get("field_editor_active"), 10)
        for key in list("cxt hello"):
            app.call("debug.key", {"key": key})
        state = app.call("debug.omnibar").get("result") or {}
        app.call("debug.key", {"key": "return"})
        if not self.wait("mv3", "omnibox", "onInputEntered", 8):
            self.note("mv3", "omnibox", "onInputEntered", "fail",
                      "no onInputEntered after typing the keyword session in the omnibar; omnibar before Enter: "
                      f"text={state.get('field_text')!r} keyword={state.get('keyword')!r} focus={state.get('has_focus')}")

    def context_menu_check(self):
        """Right-click the focused test page (trusted input through
        debug.cef.devtools), then choose the extension's item in the page menu."""
        url = self.collector.url + "/page.html?suite=mv3"
        if self.focused_url() != url and not self.focus_page_tab():
            self.note("mv3", "contextMenus", "onClicked", "fail", "could not focus the test page tab")
            return
        for kind in ("mousePressed", "mouseReleased"):
            self.app.call("debug.cef.devtools", {"method": "Input.dispatchMouseEvent",
                                                 "params": {"type": kind, "x": 40, "y": 30, "button": "right", "buttons": 2, "clickCount": 1}})
        menu = self.poll(lambda: self.app.call("debug.menu").get("result") or {}, lambda m: m.get("open"), 5)
        if menu.get("open"):
            menu = self.app.call("debug.menu", {"choose": "cxt page item"}).get("result") or {}
        self.log(f"page menu: {menu}")
        if not self.wait("mv3", "contextMenus", "onClicked", 8):
            self.note("mv3", "contextMenus", "onClicked", "fail", f"page menu {menu}")

    def focused_url(self):
        topology = self.app.snapshot().get("topology") or {}
        tab_id = (topology.get("focus") or {}).get("tab")
        for workspace in topology.get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if tab.get("id") == tab_id:
                            return tab.get("url")
        return None

    def devtools_check(self):
        self.focus_page_tab()
        result = self.app.action("browser toggle-developer-tools")
        self.log(f"devtools: {result.get('ok')} {result.get('error') or ''}")
        if not self.wait("mv3", "devtools", "devtools_page_loaded", 10):
            self.note("mv3", "devtools", "devtools_page_loaded", "fail", "devtools_page never loaded after opening DevTools")
        else:
            self.wait("mv3", "devtools", "panels.create", 10)
            self.wait("mv3", "devtools", "inspectedWindow.eval", 10)
        self.app.action("browser toggle-developer-tools")

    def note_if_missing(self, suite, api, test, status, detail):
        if not self.has(suite, api, test):
            self.note(suite, api, test, status, detail)

    def finish(self):
        for suite, api, test in UI_CHECKS:
            if not self.collector.result(suite, api, test):
                self.note(suite, api, test, "missing", "no result reported")
        snapshot = self.collector.snapshot()
        self.app.dump("results.json", snapshot)
        self.app.quit()
        self.collector.stop()
