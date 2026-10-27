#!/usr/bin/env python3
"""Live proof (p13-webui-055): with the feature chromiumAdBlockerAtFirstTab on, the built-in uBlock
Origin is in a profile before that profile's first browser tab loads its first page, on both ways a
first tab gets its browser.

Runs inside `nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA` on the GUI host of a
fleet-built app on a fork with cmux_ext_load_command_line_async, like ext-mv2-live.py (it reuses that
script's job, page server and checks). The app stops through NX_APP_STOP between phases.

  adblock-first-tab-live.py warm     # feature off: uBlock Origin compiles and caches its filter lists
  adblock-first-tab-live.py fresh    # feature on: the first tab builds the pane's Chromium window
  adblock-first-tab-live.py spare    # feature on: Home starts Chromium, the first tab takes the spare (tab_add)
  adblock-first-tab-live.py all      # warm, fresh, spare in order

Each phase writes results.json and screenshots to $NX_ARTIFACTS/<phase>/; exit 0 when every gating check
of every phase run passed.

Checks (fresh and spare): the first browser tab of the profile is the local ad page, opened once and never
reloaded; its ad server request (a fetch uBlock Origin blocks outright) is blocked on that first load; uBlock
Origin then runs in the profile. Spare also checks Home's side of the feature (the home bench's row): with
Chromium up and a browser spare ready, so the first tab joins the spare's window, no extension renderer and
no uBlock Origin background page runs before the first tab. `warm` exists so the first load measures
the load order, not uBlock Origin's one-time list compile (it filters nothing until its lists are ready, as
in Chrome with --load-extension).
"""
import argparse
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
_spec = importlib.util.spec_from_file_location("ext_mv2_live", os.path.join(HERE, "ext-mv2-live.py"))
mv2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mv2)
from bench_cli_storm import Client  # noqa: E402
from ext_e2e import cdp  # noqa: E402

FEATURE = "chromiumAdBlockerAtFirstTab"
UBO_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  # the built-in copy keeps the Web Store id (fetch-ublock.sh)


def log(message):
    print(f"[adblock-first-tab] {message}", flush=True)


class FirstTabJob(mv2.Job):
    """ext-mv2-live's job, launched with the feature set and without opening any tab: the phase's first
    browser tab is the one under test."""

    def __init__(self, phase, feature_on, disable=()):
        super().__init__(phase)
        self.feature_on = feature_on
        self.enable = [FEATURE] if feature_on else []
        self.disable = ([] if feature_on else [FEATURE]) + list(disable)

    def launch(self):
        with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as plist:
            binary = os.path.join(self.app, "Contents/MacOS", plistlib.load(plist)["CFBundleExecutable"])
        config = os.path.join(self.out, "cmux.json")
        with open(config, "w") as empty:
            empty.write("{}\n")
        env = {
            "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1",
            "CMUX_NEXT_CHIEF_ISOLATED": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CONFIG_FILE": config,
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,860",
            "CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={self.port}:remote-allow-origins=*",
        }
        if self.enable:
            env["CMUX_ENABLE_FEATURES"] = ",".join(self.enable)
        if self.disable:
            env["CMUX_DISABLE_FEATURES"] = ",".join(self.disable)
        if "NX_JOB_ID" in os.environ:
            env["NX_JOB_ID"] = os.environ["NX_JOB_ID"]
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        log_file = open(os.path.join(self.out, "app.log"), "w")
        process = subprocess.Popen([binary], env=env, stdout=log_file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
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
        features = {f.get("name"): f for f in (self.call("features.list").get("result") or {}).get("features") or []
                    if isinstance(f, dict)}
        state = (features.get(FEATURE) or {}).get("state")
        self.row(f"launch: {FEATURE} is {'on' if self.feature_on else 'off'}", state == ("on" if self.feature_on else "off"),
                 features.get(FEATURE) or "not listed")
        log(f"app up: pid {self.pid}, cdp {self.port}")

    def census(self):
        """`debug.webui`'s report: extension renderers and spare windows."""
        reply = self.call("debug.webui").get("result") or {}
        processes = [p for p in reply.get("processes") or [] if isinstance(p, dict)]
        spares = [s for s in reply.get("spares") or [] if isinstance(s, dict)]
        return {"extension_renderers": sum(1 for p in processes if p.get("kind") == "extension_renderer"),
                "spares": [{"spare": s.get("spare"), "state": s.get("state")} for s in spares]}


def ubo_background(port):
    try:
        return next((t for t in cdp.targets(port) if t.get("type") == "background_page"
                     and t.get("url", "").startswith(f"chrome-extension://{UBO_ID}/")), None)
    except OSError:
        return None


def ubo_ready(port):
    """uBlock Origin's own readiness (µBlock.readyToFilter), as diagnosis."""
    target = ubo_background(port)
    if not target:
        return "no background page"
    session = cdp.Session(target["webSocketDebuggerUrl"])
    try:
        return session.evaluate("self.µBlock ? self.µBlock.readyToFilter === true : 'no µBlock'")
    finally:
        session.close()


def first_tab(job, url, label):
    """Opens `url` as the profile's first browser tab (a person's tab: extensions reach it) and reads the
    page's own record of its first load; the page is never reloaded."""
    opened = job.call("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "remote"})
    target = cdp.wait_target(job.port, lambda t: t.get("type") == "page" and url in t.get("url", ""), 60)
    if not target:
        job.row(f"{label}: the first tab's page", False, {"opened": opened})
        return None
    session = cdp.Session(target["webSocketDebuggerUrl"])
    try:
        state = mv2.poll(session, "window.mv2 && window.mv2.done && window.mv2", 30) or {}
        state["navigations"] = session.evaluate("performance.getEntriesByType('navigation').map(e => e.type)")
        state["shot"] = job.page_shot(session, f"{label}-first-page")
    finally:
        session.close()
    state["ubo_ready_after"] = ubo_ready(job.port)
    state["opened"] = (opened.get("result") or {}) if isinstance(opened, dict) else opened
    return state


def first_load_checks(job, state, label):
    if state is None:
        return
    job.row(f"{label}: the first page loaded once (no reload)", state.get("navigations") == ["navigate"], state)
    job.row(f"{label}: the first page's ad server request is blocked on its first load", state.get("beacon") == "blocked", state)
    ubo = next((e for e in job.extensions_report() if e.get("id") == UBO_ID), None)
    job.row(f"{label}: the built-in uBlock Origin runs in the profile", bool(ubo and ubo.get("enabled")), ubo or "not listed")
    job.row(f"{label}: diagnose: extension renderers after the first tab", True, job.census(), gating=False)


def outcome(job):
    """The phase's exit code: 0 when it recorded gating checks and every one passed (results.json says the same)."""
    gating = [r for r in job.results if r["gating"]]
    return 0 if gating and all(r["ok"] for r in gating) else 1


def browser_spare_live(census):
    """The default profile's Chromium spare window (`debug.webui` names it cef_window) is built."""
    return any(s.get("spare") == "cef_window" and s.get("state") == "live" for s in census["spares"])


def phase_warm(url):
    job = FirstTabJob("warm", feature_on=False)

    def start_chromium():
        job.call("action.run", {"action": "openBrowser.chromium", "args": {"url": "about:blank"}, "focus": True, "origin": "remote"})
        up = cdp.wait_target(job.port, lambda t: t.get("type") == "page", 120) is not None
        job.row("warm: Chromium is up", up, {"cdp": job.port})
        return None if up else "stop"

    def lists():
        """ext-mv2-live's ad page check, which reloads until uBlock Origin's lists are compiled."""
        mv2.ads_check(job, url + "?warm=1", "warm", expect_blocked=True)
        ready = ubo_ready(job.port)
        job.row("warm: uBlock Origin's lists are ready", ready is True, ready)

    mv2.run_phase(job, [("warm: Chromium", start_chromium), ("warm: lists", lists)])
    return outcome(job)


def phase_fresh(url):
    job = FirstTabJob("fresh", feature_on=True)

    def first():
        first_load_checks(job, first_tab(job, url + "?fresh=1", "fresh"), "fresh")

    mv2.run_phase(job, [("fresh: first tab", first)])
    return outcome(job)


def phase_spare(url):
    # The spare is built before any browser tab only with chromiumSpareAfterFirstTab off (its default).
    job = FirstTabJob("spare", feature_on=True, disable=["chromiumSpareAfterFirstTab"])

    def home():
        """Home starts Chromium for its cmux pages; the warmup then builds the default profile's spare window."""
        job.call("action.run", {"action": "home.show", "origin": "remote"})
        deadline = time.monotonic() + 120
        census = job.census()
        while time.monotonic() < deadline:
            census = job.census()
            if browser_spare_live(census):
                break
            time.sleep(1)
        ready = browser_spare_live(census)
        job.row("spare: a browser spare window is ready before the first tab", ready, census)
        if not ready:
            return "stop"
        time.sleep(2)
        census = job.census()
        background = ubo_background(job.port)
        job.row("spare: no extension renderer before the first browser tab (home bench row)", census["extension_renderers"] == 0, census)
        job.row("spare: no uBlock Origin background page before the first browser tab", background is None,
                (background or {}).get("url") or "none")
        job.window_shot("spare-home")
        return None

    def first():
        first_load_checks(job, first_tab(job, url + "?spare=1", "spare"), "spare")

    mv2.run_phase(job, [("spare: home", home), ("spare: first tab", first)])
    return outcome(job)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("phase", choices=["warm", "fresh", "spare", "all"])
    args = parser.parse_args()
    server, url = mv2.serve()
    try:
        phases = ["warm", "fresh", "spare"] if args.phase == "all" else [args.phase]
        runs = {"warm": phase_warm, "fresh": phase_fresh, "spare": phase_spare}
        codes = [runs[name](url) for name in phases]
    finally:
        server.shutdown()
    summary = {"phases": phases, "exit_codes": codes}
    out = os.environ.get("NX_ARTIFACTS", "/tmp/adblock-first-tab")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    return 0 if all(code == 0 for code in codes) else 1


if __name__ == "__main__":
    sys.exit(main())
