#!/usr/bin/env python3
"""xbench: the one cross-browser benchmark for cmux NEXT (msg 2654).

Measures the rows of Ardia's 2026-10-19 comparison for cmux NEXT (a Chromium
tab, a WebKit tab, terminals only) and for Chrome, Helium, Dia, Ardia and
Safari, on one Mac, the same way for every browser:

  power-idle-hidden    mW, 20 tabs, app hidden (NSRunningApplication.hide)
  power-idle-visible   mW, 20 tabs, window in view, idle
  power-scroll         mW, a page scrolling itself every frame
  power-video          mW, a looping 720p clip the page recorded itself
  power-switch         mW, switching tabs every 1.5 s
  launch-window        ms, launch -> first on-screen window >= 300x200 (CGWindowList)
  launch-link          ms, launch with a URL -> that page's first contentful paint (Chromium only)
  newtab-paint         ms, new tab command -> its first contentful paint
  tab-switch           ms, switch command -> visibilitychange + 2 frames
  idle-wakeups-20      /s, 20 tabs, idle in view
  idle-cpu-20          %,  20 tabs, idle in view (100 % = one core)
  idle-cpu-1, idle-wakeups-1, power-idle-visible-1   the same with 1 tab
  memory-1/10/20       MB, physical footprint over every process of the instance
  memory-closed        MB, back to 1 tab after 20
  power-home-idle, idle-cpu-home, idle-wakeups-home  cmux-terminal only: cmux idle on Home
  <power row>-billed   mW, the same window's billed energy (CPU + billed to the process - serviced for others)
  <power row>-gpu      ms/s, the same window's GPU time (IORegistry accumulatedGPUTime)
  <wakeups row>-pkg-idle  /s, the same window's package-idle wakeups (a subset of the interrupt wakeups)
  budget-*             cmux-budget only: the resource budget session (budget.py, budgets.json)

Method (after Ardia's docs/perf/vs-browsers.md, so numbers compare):
  - local pages on 127.0.0.1 (pages.py), no network-dependent rows;
  - every launch starts from its own APFS clone of a template profile made
    once per browser (one launch, settle, quit); HOME and CFFIXED_USER_HOME
    point into the run folder, so nothing touches the worker's ~/Library;
  - Chromium browsers get --user-data-dir --remote-debugging-port
    --no-first-run --no-default-browser-check --password-store=basic
    --use-mock-keychain --mute-audio --window-size=1280,800 and are driven
    over CDP's HTTP endpoints (/json/new, /json/activate, /json/close);
    cmux NEXT is driven over its control socket (app actions);
    Safari through `open` (no switch/close rows: they need Automation);
  - counters are proc_pid_rusage V6 over the whole instance (procs.py):
    ri_energy_nj (CPU energy, no root; GPU and display are not in it), ri_billed_energy and
    ri_serviced_energy (the -billed rows), CPU time, interrupt wakeups (the wakeups rows: Chrome's
    GetIdleWakeupsPerSecond, Activity Monitor) and package-idle wakeups apart (the -pkg-idle rows;
    rows before 2026-10-25 summed the two), phys_footprint; GPU time from the IORegistry; each window
    sample also keeps the app's resource coalition (`coalition`: energy, billed energy, GPU time,
    wakeups of everything the app started; null when unreadable);
  - browsers interleave and rotate each round; every row is the median of
    all its runs with min, max and n; each item waits for a quiet machine
    (1-min load under --max-load) and the run holds `caffeinate -dimsu`.

Usage (on a fleet mini; scripts/measure/perf-bench.sh is the fleet entry):
  xbench.py run --out DIR --app NAME=BUNDLE ... [--browsers a,b] [--rounds 3]
      [--launches 2] [--idle 60] [--active 30] [--settle 30] [--max-load 4]
      [--chrome-extension DIR]   (D6: the uBlock Origin cmux bundles, scripts/cmux-next/fetch-ublock.sh; MV2, so
                                  --app chrome= must be a Chromium that runs MV2, such as ungoogled-chromium)
  xbench.py report --out DIR [--md BENCH.md] [--json results.json] [--budgets budgets.json]
  xbench.py gate --results results.json --baseline baseline.json [--tolerance 0.15]

While scripts/perf-lab/OWNS_MEASUREMENT exists, every subcommand prints
"xbench: perf lab owns measurement" and exits 0: the perf lab measures instead.
The lab's own stories pass --perf-lab, which the sentinel does not stop:
  xbench.py --perf-lab run --out DIR ...

The perf lab's T2 story vs-browsers (scripts/perf-lab/stories.d/vs-browsers.json, p12-perf-process task 208)
runs `xbench.py --perf-lab run --browsers cmux-chromium,chrome --fetch chrome --app APP --tag TAG --out DIR`,
where APP is the prebuilt bench artifact (`--app PATH` with no NAME= is the cmux bundle). A --perf-lab run
names the measured cmux build and host before it measures (perf_import.measured_build) and then writes
cmux-perf-result/v1 into DIR: one run per browser arm, with the arm's engine, and one metric per row,
`xbench.<arm>.<row>` (raw samples of every round), so every series is keyed by browser. A cmux arm's <arm> is
its name (the build's commit names what it measured); a vendor browser's is `<name>-<version>` (chrome-155.0.8059.85),
because the vendor ships it, not cmux: an update of that browser starts new series instead of stepping a series at
the cmux commit measured that night. Chrome is the reference arm: it runs interleaved with cmux on the same host,
and each cmux row also gets `xbench.<browser>.<row>.vs-chrome-<version>`, the per-round ratio to that Chrome,
which a host-wide change cancels out of. A --perf-lab run refuses to start when an arm it was asked for (the
reference arm included) has no bundle, and it makes its template profiles in a scratch folder of its own, so
no run starts from a profile an earlier build wrote. scripts/perf-lab/import_xbench.py imports the nightly's
baseline/*.json under the same metric names as legacy points.

Browser names: cmux-chromium, cmux-webkit, cmux-terminal, cmux-budget (all --app cmux=BUNDLE),
chrome, helium, dia, ardia, safari (default /Applications/Safari.app).
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import platform
import plistlib
import random
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))
import budget  # noqa: E402
import pages  # noqa: E402
import procs  # noqa: E402

# The perf lab's sentinel (p12-perf-process task 026); scripts/cmux-next/perf-cron.py's plan reads the same file.
LAB_SENTINEL = os.path.normpath(os.path.join(HERE, "..", "perf-lab", "OWNS_MEASUREMENT"))
LAB_REASON = "perf lab owns measurement"
PERF_IMPORT = os.path.normpath(os.path.join(HERE, "..", "perf-lab", "perf_import.py"))
FETCH_BROWSERS = os.path.join(HERE, "fetch_browsers.py")

ROWS = [
    # id, label, unit, in the tweet's table
    ("power-idle-hidden", "Power, idle, hidden", "mW", True),
    ("power-idle-visible", "Power, idle, in view", "mW", True),
    ("power-scroll", "Power, scrolling", "mW", True),
    ("power-video", "Power, video", "mW", True),
    ("power-switch", "Power, switching tabs", "mW", True),
    ("launch-window", "Cold launch, window up", "ms", True),
    ("newtab-paint", "New tab first paint", "ms", True),
    ("idle-wakeups-20", "Wakeups, idle, 20 tabs", "/s", True),
    ("idle-cpu-20", "CPU, idle, 20 tabs", "%", True),
    ("memory-1", "Memory, 1 tab", "MB", True),
    ("memory-10", "Memory, 10 tabs", "MB", True),
    ("memory-20", "Memory, 20 tabs", "MB", True),
    ("launch-link", "Cold launch, link -> page painted", "ms", False),
    ("tab-switch", "Tab switch -> shown", "ms", False),
    ("memory-closed", "Memory, back to 1 tab after 20", "MB", False),
    ("idle-cpu-1", "CPU, idle, 1 tab", "%", False),
    ("idle-wakeups-1", "Wakeups, idle, 1 tab", "/s", False),
    ("power-idle-visible-1", "Power, idle, in view, 1 tab", "mW", False),
    ("power-home-idle", "Power, cmux idle on Home", "mW", False),
    ("idle-cpu-home", "CPU, cmux idle on Home", "%", False),
    ("idle-wakeups-home", "Wakeups, cmux idle on Home", "/s", False),
]
# Each window row has companions from the same window (procs.Instance.window keys).
COMPANIONS = {"mW": (("-billed", "energy_mw_billed", "billed energy", "mW"), ("-gpu", "gpu_ms_per_s", "GPU time", "ms/s")),
              "/s": (("-pkg-idle", "pkg_idle_wakeups_per_s", "package-idle", "/s"),)}
WINDOW_KEYS = {"mw": "mW", "wakeups_per_s": "/s"}
ROWS += [(row + suffix, f"{label}, {what}", companion_unit, False)
         for row, label, unit, _main in list(ROWS)
         if unit == "mW" or row.startswith("idle-wakeups-")
         for suffix, _key, what, companion_unit in COMPANIONS[unit]]
ROW_INFO = {row: (label, unit, main) for row, label, unit, main in ROWS}
ROW_INFO.update(budget.ROW_INFO)

# Ardia's tweet (2026-10-19, Apple M5 Pro, macOS 27.2): Ardia 0.2.38-nightly.8, Helium 0.19.3.1, Dia 1.53.0.
PUBLISHED = {
    "ardia": {"power-idle-hidden": 3.9, "power-idle-visible": 3.5, "power-scroll": 28.2, "power-video": 82.0,
              "power-switch": 136, "launch-window": 280, "newtab-paint": 54.9, "idle-wakeups-20": 13.6,
              "idle-cpu-20": 0.45, "memory-1": 298, "memory-10": 714, "memory-20": 1082},
    "helium": {"power-idle-hidden": 3.1, "power-idle-visible": 4.0, "power-scroll": 51.9, "power-video": 90.9,
               "power-switch": 173, "launch-window": 353, "newtab-paint": 71.5, "idle-wakeups-20": 28.1,
               "idle-cpu-20": 1.02, "memory-1": 374, "memory-10": 773, "memory-20": 1121},
    "dia": {"power-idle-hidden": 1223, "power-idle-visible": 848, "power-scroll": 626, "power-video": 779,
            "power-switch": 763, "launch-window": 2262, "newtab-paint": 88.9, "idle-wakeups-20": 38.7,
            "idle-cpu-20": 1.05, "memory-1": 480, "memory-10": 1273, "memory-20": 1822},
}

CHROMIUM = {"chrome", "helium", "dia", "ardia"}
CMUX = {"cmux-chromium", "cmux-webkit", "cmux-terminal", budget.NAME}
LABELS = {"cmux-chromium": "cmux NEXT (Chromium tab)", "cmux-webkit": "cmux NEXT (WebKit tab)",
          "cmux-terminal": "cmux NEXT (terminals)", budget.NAME: budget.LABEL, "chrome": "Chrome", "helium": "Helium", "dia": "Dia",
          "ardia": "Ardia", "safari": "Safari"}
DEFAULT_BROWSERS = "cmux-chromium,cmux-webkit,cmux-terminal,cmux-budget,chrome,helium,ardia,dia,safari"
# The names `--app NAME=BUNDLE` takes; any other value is the cmux bundle's path (the lab's `--app PATH`).
APP_NAMES = {"cmux", "safari"} | CHROMIUM

# result-v1 of a --perf-lab run (task 208): the story id (stories.d/vs-browsers.json), the reference arm and
# each arm's result-v1 engine.
STORY = "vs-browsers"
REFERENCE_ARM = "chrome"
ENGINES = {"cmux-chromium": "chromium", "cmux-webkit": "webkit", "cmux-terminal": "none", budget.NAME: "none",
           "chrome": "chromium", "helium": "chromium", "dia": "chromium", "ardia": "chromium", "safari": "webkit"}
# The arms a vendor ships, not cmux; their series names carry the version (Info.plist CFBundleShortVersionString:
# 155.0.8059.85).
VENDORS = set(ENGINES) - CMUX
VENDOR_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*")
# An xbench row unit -> (result-v1 unit, factor from the row's value to that unit). MB is procs.MB (2^20 bytes),
# KB/s is procs' disk_kb_per_s (1024 bytes), and GPU ms/s is a percent of one GPU.
RESULT_UNITS = {"ms": ("ms", 1.0), "mW": ("mW", 1.0), "%": ("percent", 1.0), "/s": ("per_s", 1.0),
                "MB": ("bytes", 1048576.0), "KB/s": ("bytes_per_s", 1024.0), "ms/s": ("percent", 0.1),
                "n": ("count", 1.0)}


def log(message: str):
    print(f"[xbench {time.strftime('%H:%M:%S')}] {message}", flush=True)


def now_ms() -> float:
    return time.time() * 1000


def sleep(seconds: float):
    time.sleep(seconds)  # bench: a deliberate settle or idle window


# ---------------------------------------------------------------- helper


class Helper:
    """benchhelper.swift, compiled once per worker into a cache keyed by its source hash."""

    def __init__(self, cache: str):
        source = os.path.join(HERE, "benchhelper.swift")
        digest = hashlib.sha256(open(source, "rb").read()).hexdigest()[:16]
        self.path = os.path.join(cache, f"benchhelper-{digest}")
        if not os.path.exists(self.path):
            os.makedirs(cache, exist_ok=True)
            subprocess.run(["xcrun", "swiftc", "-O", "-o", self.path + ".tmp", source], check=True, timeout=600)
            os.replace(self.path + ".tmp", self.path)

    def run(self, *args: str, timeout: float = 30) -> subprocess.CompletedProcess:
        return subprocess.run([self.path, *args], capture_output=True, text=True, timeout=timeout)

    def wait_window(self, prefix: str, timeout: float) -> subprocess.Popen:
        return subprocess.Popen([self.path, "wait-window", prefix, str(timeout)], stdout=subprocess.PIPE, text=True)

    def displays(self) -> dict:
        try:
            return json.loads(self.run("displays").stdout)
        except ValueError:
            return {}


# ---------------------------------------------------------------- browsers


def bundle_version(bundle: str) -> str:
    try:
        with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        return str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "?")
    except OSError:
        return "?"


def team_id(bundle: str) -> str:
    out = subprocess.run(["codesign", "-dv", bundle], capture_output=True, text=True).stderr
    for line in out.splitlines():
        if line.startswith("TeamIdentifier="):
            return line.split("=", 1)[1]
    return "?"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def clone(src: str, dst: str):
    """An APFS clone of a template profile (cp -c), a plain copy elsewhere."""
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.isdir(src):
        if subprocess.run(["cp", "-cR", src, dst], capture_output=True).returncode != 0:
            shutil.copytree(src, dst, symlinks=True)
    else:
        os.makedirs(dst)
    for root, _dirs, files in os.walk(dst):
        for name in files:
            if name.startswith("Singleton"):
                try:
                    os.unlink(os.path.join(root, name))
                except OSError:
                    pass


class Browser:
    """One browser under test: launch, tabs, hide, quit. Subclasses drive one family."""

    can_switch = True
    can_close = True
    can_link = False
    tab_kind = "page"

    def __init__(self, name: str, bundle: str, helper: Helper, server: pages.BeaconServer):
        self.name = name
        self.bundle = os.path.abspath(bundle)  # procs matches this path and its realpath (Safari's is a cryptex)
        self.helper = helper
        self.server = server
        self.instance: procs.Instance | None = None
        self.tabs: list[str] = []  # tab handles, oldest first
        self.ids: dict[str, str] = {}  # handle -> the page's beacon id

    def info(self) -> dict:
        return {"name": LABELS.get(self.name, self.name), "bundle": self.bundle,
                "version": bundle_version(self.bundle), "team": team_id(self.bundle)}

    def running(self) -> bool:
        return procs.main_pid(self.bundle) is not None

    def wait_main(self, timeout: float = 30) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid = procs.main_pid(self.bundle)
            if pid:
                return pid
            time.sleep(0.02)  # bench: waiting for LaunchServices to start the app
        raise RuntimeError(f"{self.name}: no app process within {timeout} s")

    def hide(self) -> bool:
        """True once the app is hidden (NSRunningApplication.isHidden), not only asked to hide."""
        self.helper.run("hide", str(self.instance.pid))
        return self.wait_hidden(True)

    def unhide(self):
        self.helper.run("unhide", str(self.instance.pid))

    def is_hidden(self) -> bool:
        return self.helper.run("ishidden", str(self.instance.pid)).returncode == 0

    def wait_hidden(self, hidden: bool, timeout: float = 3) -> bool:
        """True once the app's hidden state is `hidden` (hide and unhide land asynchronously)."""
        deadline = time.monotonic() + timeout
        while self.is_hidden() != hidden:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.1)  # bench: waiting for the app to apply the hide or unhide
        return True

    def quit(self):
        if self.instance:
            self.helper.run("terminate", str(self.instance.pid))
            self.instance.end(grace=15)
            self.instance = None
        self.tabs = []

    # Subclasses: launch(profile, url) -> starts and sets self.instance; ready(timeout);
    # new_tab(url, tab_id) -> handle; activate(handle); close(handle); template(profile).


class ChromiumBrowser(Browser):
    can_link = True
    flags = ["--no-first-run", "--no-default-browser-check", "--password-store=basic", "--use-mock-keychain",
             "--mute-audio", "--window-size=1280,800", "--window-position=40,80", "--remote-allow-origins=*",
             "--hide-crash-restore-bubble"]
    disabled_features = ["ChromeWhatsNewUI"]
    # --load-extension: branded Google Chrome ignores it from 137 with no switch back from 142 (Chromium
    # 04f6233ce5be), and Chromium runs no Manifest V2 extension from 139 (full uBlock Origin is MV2). Load
    # extensions into a Chromium that runs them (ungoogled-chromium for MV2); extension_targets() reports
    # what actually started.

    def __init__(self, *args, extensions: list[str] | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        self.port = 0
        self.extensions = [os.path.abspath(path) for path in extensions or []]  # unpacked extension folders
        if self.name == "ardia":
            self.can_link = False  # Ardia ignores URLs in argv (its own method says so)

    def info(self) -> dict:
        return {**super().info(), **({"extensions": self.extensions} if self.extensions else {})}

    def switches(self) -> list[str]:
        """The launch switches: the shared flags, the unpacked extensions, and one --disable-features
        (Chromium reads only the last one on a command line)."""
        loads = [f"--load-extension={','.join(self.extensions)}"] if self.extensions else []
        return [*self.flags, *loads, f"--disable-features={','.join(self.disabled_features)}"]

    def launch(self, profile: str, url: str | None):
        self.port = free_port()
        home = os.path.join(profile, "home")
        os.makedirs(os.path.join(home, "Library"), exist_ok=True)
        env = {"HOME": home, "CFFIXED_USER_HOME": home}
        if self.name == "ardia":
            env.update({"ARDIA_REMOTE_DEBUGGING_PORT": str(self.port), "ARDIA_DATA_DIR": os.path.join(profile, "data")})
        argv = ["open", "-n", "-g"] + [x for k, v in env.items() for x in ("--env", f"{k}={v}")]
        argv += ["-a", self.bundle, "--args", f"--user-data-dir={os.path.join(profile, 'data')}",
                 f"--remote-debugging-port={self.port}", *self.switches()]
        if url and self.can_link:
            argv.append(url)
        subprocess.run(argv, check=True, timeout=60)
        self.instance = procs.Instance(self.bundle, self.wait_main())

    def cdp(self, path: str, method: str = "GET", timeout: float = 10):
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
        try:
            return json.loads(body)
        except ValueError:
            return body.decode(errors="replace")

    def ready(self, timeout: float = 45):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                self.cdp("/json/version", timeout=2)
                return
            except OSError as error:
                last = error
                time.sleep(0.2)  # bench: waiting for the DevTools port
        raise RuntimeError(f"{self.name}: no DevTools endpoint on port {self.port} ({last})")

    def pages(self) -> list[dict]:
        return [t for t in self.cdp("/json/list") if t.get("type") == "page"]

    def extension_targets(self) -> list[dict]:
        """The extension background pages and service workers DevTools lists: the extensions that run."""
        return [t for t in self.cdp("/json/list") if t.get("type") in ("background_page", "service_worker")
                and t.get("url", "").startswith("chrome-extension://")]

    def adopt_first(self, tab_id: str):
        """The launch URL's tab becomes tabs[0]; every other page closes."""
        handle = None
        for target in self.pages():
            if f"id={tab_id}" in target.get("url", "") and handle is None:
                handle = target["id"]
            else:
                try:
                    self.cdp(f"/json/close/{target['id']}")
                except OSError:
                    pass
        if handle is None:
            handle = self.new_tab(self.server.url("idle", tab_id), tab_id)
        else:
            self.tabs = [handle]
            self.ids[handle] = tab_id
        return handle

    def new_tab(self, url: str, tab_id: str) -> str:
        made = self.cdp("/json/new?" + urllib.parse.quote(url, safe=":/?=&"), method="PUT")
        self.tabs.append(made["id"])
        self.ids[made["id"]] = tab_id
        return made["id"]

    def activate(self, handle: str):
        self.cdp(f"/json/activate/{handle}")

    def probe_cdp(self):
        """Turns off switching and closing when this browser's CDP lacks /json/activate or
        /json/close, so the session goes on to its other rows instead of ending."""
        if not self.tabs:
            return
        for path, attr in ((f"/json/activate/{self.tabs[-1]}", "can_switch"), ("/json/close/xbench-missing-target", "can_close")):
            try:
                self.cdp(path)
            except urllib.error.HTTPError as error:
                # Chrome answers a missing target with 404 "No such target id"; a 404 without
                # that text means the endpoint itself does not exist.
                if error.code == 404 and "no such target" not in error.read().decode(errors="replace").lower():
                    setattr(self, attr, False)
                    log(f"{self.name}: CDP {path.split('/')[2]} unsupported (404), its rows are skipped")
            except OSError:
                pass

    def close(self, handle: str):
        self.cdp(f"/json/close/{handle}")
        if handle in self.tabs:
            self.tabs.remove(handle)

    def template(self, profile: str, settle: float):
        self.launch(profile, self.server.url("idle", "template"))
        try:
            self.ready()
            if not self.can_link:
                self.new_tab(self.server.url("idle", "template"), "template")
            sleep(settle)
        finally:
            self.quit()


class CmuxBrowser(Browser):
    """cmux NEXT, driven over its control socket like a user's shortcuts would."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.engine = self.name.split("-", 1)[1]
        self.tab_kind = "terminal" if self.engine == "terminal" else "page"
        self.can_switch = self.engine != "terminal"
        self.socket = None

    def launch(self, profile: str, url: str | None):
        import bench_memory as bm  # the cmux-next scripts' socket client and process helpers
        if self.running():
            bm.end_bundle(self.bundle)
        home = os.path.join(profile, "home")
        tmp = os.path.join(profile, "tmp")
        os.makedirs(os.path.join(home, "Library"), exist_ok=True)
        os.makedirs(tmp, exist_ok=True)
        config = os.path.join(profile, "cmux.json")
        if not os.path.exists(config):
            with open(config, "w") as handle:
                json.dump({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, handle)
        env = {"HOME": home, "CFFIXED_USER_HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": tmp + "/",
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
               "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
               # As the Chromium browsers' --use-mock-keychain: a locked login keychain on a bench
               # host otherwise holds CEF at a keychain prompt and no Chromium tab loads.
               "CMUX_MOCK_KEYCHAIN": "1"}
        argv = ["open", "-n", "-g"] + [x for k, v in env.items() for x in ("--env", f"{k}={v}")] + ["-a", self.bundle]
        subprocess.run(argv, check=True, timeout=60)
        self.instance = procs.Instance(self.bundle, self.wait_main())
        self._tmp = tmp
        self._state = os.path.join(home, ".local/state/cmux")

    def ready(self, timeout: float = 90):
        import bench_memory as bm
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            # The app binds in its HOME's state folder; /tmp holds only a symlink, which a later
            # instance may leave pointing at the previous session's socket.
            dirs = [d for d in (self._state, self._tmp, "/tmp") if os.path.isdir(d)]
            path = bm.control_socket(self.bundle, self.instance.pid, dirs)
            if path:
                self.socket = path
                self.app = bm.App(self.bundle, path)
                return
            time.sleep(0.5)  # bench: waiting for the app's control socket
        raise RuntimeError("cmux: no control socket within 90 s")

    def hide(self) -> bool:
        """NSRunningApplication.hide, else the app's own NSApp.hide.

        hide() is refused for an app `open -g` started on some fleet hosts (budget.py rows
        'the app did not hide' on cmux20 and mac26). showHideAllWindows with `hidden` hides
        whether or not cmux is active and never shows or focuses a window (a build older than
        the argument ignores it and toggles, which shows the window). The caller checks the
        result: a visible app is never reported hidden."""
        if super().hide():
            return True
        if self.app.action("showHideAllWindows", hidden=True).get("error"):
            return False
        return self.wait_hidden(True)

    def unhide(self):
        super().unhide()
        if not self.wait_hidden(False):
            # Unhides without activating cmux or raising a window, so the next phase starts as before.
            self.app.action("showHideAllWindows", hidden=False)
            self.wait_hidden(False)

    def act(self, action: str, **args) -> dict:
        # focus: a user's Cmd-T / Cmd-1..9 shows the tab (Chrome's /json/new opens a foreground tab);
        # a background cmux tab does not load at all, so no paint or visibility row would exist.
        reply = self.app.action(action, focus=True, **args)
        if reply.get("error"):
            raise RuntimeError(f"cmux {action}: {reply['error']}")
        return reply

    def start_workspace(self):
        self.act("workspace.newAtBottom")
        self.app.action("workspace.selectLast", focus=True)

    def new_tab(self, url: str, tab_id: str) -> str:
        if self.engine == "terminal":
            self.act("newSurface")
        else:
            self.act("openBrowser.chromium" if self.engine == "chromium" else "openBrowser.webkit", url=url)
        self.tabs.append(tab_id)
        return tab_id

    def adopt_first(self, tab_id: str):
        self.start_workspace()
        return self.new_tab(self.server.url("idle", tab_id), tab_id)

    def activate(self, handle: str):
        # Shortcut tabs 1..9 (Cmd+1..9): the bench cycles among the first nine.
        self.act("selectSurfaceByNumber", index=self.tabs.index(handle) + 1)

    def close(self, handle: str):
        # closeTab closes the focused tab: the bench only closes the newest one it focused.
        self.act("closeTab")
        if handle in self.tabs:
            self.tabs.remove(handle)

    def quit(self):
        import bench_memory as bm
        if self.instance:
            bm.end_bundle(self.bundle)
            self.instance = None
        self.tabs = []

    def template(self, profile: str, settle: float):
        self.launch(profile, None)
        try:
            self.ready()
            sleep(settle)
        finally:
            self.quit()


class SafariBrowser(Browser):
    """Safari through `open` only: tab switch and close need Automation, so those rows are null."""

    can_switch = False
    can_close = False

    def launch(self, profile: str, url: str | None):
        argv = ["open", "-g", "-a", self.bundle] + ([url] if url else [])
        subprocess.run(argv, check=True, timeout=60)
        self.instance = procs.Instance(self.bundle, self.wait_main())

    def ready(self, timeout: float = 30):
        return

    def adopt_first(self, tab_id: str):
        self.tabs = [tab_id]
        return tab_id

    def new_tab(self, url: str, tab_id: str) -> str:
        subprocess.run(["open", "-g", "-a", self.bundle, url], check=True, timeout=60)
        self.tabs.append(tab_id)
        return tab_id

    def template(self, profile: str, settle: float):
        return


def window_rows(rows: dict) -> dict:
    """{row: Instance.window key} of the asked rows and their companions from the same window."""
    out = dict(rows)
    for row, key in rows.items():
        for suffix, companion, _what, _unit in COMPANIONS.get(WINDOW_KEYS.get(key), ()):
            out[row + suffix] = companion
    return out


def make_browser(name: str, bundle: str, helper: Helper, server: pages.BeaconServer,
                 extensions: list[str] | None = None) -> Browser:
    if name in CMUX:
        return CmuxBrowser(name, bundle, helper, server)
    if name == "safari":
        return SafariBrowser(name, bundle, helper, server)
    return ChromiumBrowser(name, bundle, helper, server, extensions=extensions)


def can_launch_apps() -> bool:
    """Whether LaunchServices starts an app for this process (Calculator, quit at once)."""
    calculator = "/System/Applications/Calculator.app"
    if subprocess.run(["open", "-g", "-j", "-n", "-a", calculator], capture_output=True, timeout=30).returncode != 0:
        return False
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        pid = procs.main_pid(calculator)
        if pid:
            os.kill(pid, signal.SIGKILL)
            return True
        time.sleep(0.2)  # bench: waiting for the probe app
    return False


def parse_apps(items: list[str]) -> dict[str, str]:
    """{name: bundle} of the --app values: NAME=BUNDLE for a name in APP_NAMES; any other value is the cmux
    bundle's path (the perf lab runner appends `--app PATH`, stories.d/README.md)."""
    apps = {}
    for item in items:
        name, sep, bundle = item.partition("=")
        if sep and name in APP_NAMES:
            apps[name] = bundle
        else:
            apps["cmux"] = item
    return apps


def fetch(names: list[str], run=subprocess.run) -> dict[str, str]:
    """{name: bundle} of each named browser fetch_browsers.py has, as the nightly entry (scripts/measure/perf-bench.sh)
    gets them: vendor-signed, read-only copies in the worker cache. A browser it cannot fetch (fetch_browsers.py names
    why on stderr, or the fetch fails or times out) is left out, so its arm has no bundle: a nightly run skips it and a
    --perf-lab run refuses to start (Run.arms)."""
    if not names:
        return {}
    try:
        done = run([sys.executable, "-I", FETCH_BROWSERS, *names], stdout=subprocess.PIPE, text=True, timeout=3600)
    except subprocess.TimeoutExpired:
        log(f"fetch_browsers.py {' '.join(names)}: no answer within 3600 s")
        return {}
    if done.returncode:
        log(f"fetch_browsers.py {' '.join(names)}: exit status {done.returncode}")
    apps = {}
    for line in (done.stdout or "").splitlines():
        name, sep, bundle = line.strip().partition("=")
        if sep and name in names:
            apps[name] = bundle
    return apps


# ---------------------------------------------------------------- perf lab result-v1


def load_perf_import():
    """scripts/perf-lab/perf_import.py by path, once per process (a lab bench runs under python3 -I)."""
    if "perf_import" in sys.modules:
        return sys.modules["perf_import"]
    spec = importlib.util.spec_from_file_location("perf_import", PERF_IMPORT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["perf_import"] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules["perf_import"]
        raise
    return module


def arm_name(browser: str, versions: dict[str, str]) -> str:
    """The name a browser arm has in its metrics: a cmux arm's own (the build's commit says what was measured), a
    vendor browser's with its version (`chrome-155.0.8059.85`), so a vendor update starts new series and is never a
    step at the cmux commit measured that night. Chromium's perf bots pin their reference build for the same reason
    (tools/perf/update_reference_build.py): a reference that moves on its own breaks the comparison."""
    return f"{browser}-{versions[browser]}" if browser in VENDORS else browser


def result_metric(browser: str, row: str, versions: dict[str, str]) -> str:
    """The result-v1 metric of one row of one browser arm: the arm is in the name, so it keys the series."""
    return f"xbench.{arm_name(browser, versions)}.{row}"


def result_unit(row: str) -> tuple[str, float]:
    """(result-v1 unit, factor from the row's value) of a row; tab-switch and palette rows are ms, as `gate` reads them."""
    return RESULT_UNITS[ROW_INFO[row][1] if row in ROW_INFO else "ms"]


def vendor_versions(bundles: dict[str, str]) -> dict[str, str]:
    """{browser: version} of the vendor arms in `bundles` ({browser: bundle}); raises SystemExit for one whose
    Info.plist names no version, since its results could not say which build of it they measured."""
    versions = {}
    for browser, bundle in bundles.items():
        if browser not in VENDORS:
            continue
        version = bundle_version(bundle)
        if not VENDOR_VERSION.fullmatch(version):
            raise SystemExit(f"xbench: {browser} ({bundle}) names no version ({version!r}); no result-v1 can name it")
        versions[browser] = version
    return versions


def lab_series(samples: list[dict], browser: str, versions: dict[str, str],
               reference: str = REFERENCE_ARM) -> list[tuple]:
    """(metric, unit, better, samples) of every row `browser` measured, in result-v1 units, every measurement of every
    round; `versions` holds each vendor arm's version (vendor_versions). A cmux arm also gets each row's ratio to the
    reference arm: per round that measured the row in both arms, the round's median over the reference's. The arms
    of a round run back to back on one host, so a change of the host moves both and leaves the ratio, as Chrome's
    perf bots run a reference build beside tip (tools/perf/core/bot_platforms.py run_reference_build)."""
    rounds: dict[str, dict[str, dict[int, list[float]]]] = {}
    for sample in samples:
        if sample.get("value") is None or sample["row"] not in ROW_INFO:
            continue
        rounds.setdefault(sample["browser"], {}).setdefault(sample["row"], {}).setdefault(
            sample["round"], []).append(sample["value"])
    own = rounds.get(browser, {})
    ref = rounds.get(reference, {}) if browser in CMUX and browser != reference else {}
    series = []
    for row in sorted(own):
        unit, factor = result_unit(row)
        by_round = sorted(own[row].items())
        metric = result_metric(browser, row, versions)
        series.append((metric, unit, "lower", [v * factor for _, values in by_round for v in values]))
        ref_row = ref.get(row, {})
        ratios = [statistics.median(values) / statistics.median(ref_row[number]) for number, values in by_round
                  if number in ref_row and statistics.median(ref_row[number]) > 0]
        if ratios:
            series.append((f"{metric}.vs-{arm_name(reference, versions)}", "ratio", "lower", ratios))
    return series


def features_reply(app) -> dict:
    """The cmux app's `features.list` reply in the shape bench_launch.features_snapshot reads: bench_memory.App.call
    gives a JSON error object as text, and a build without the method must read as method_not_found."""
    reply = app.call("features.list", {}, label="features.list", timeout=10)
    error = reply.get("error")
    if isinstance(error, str):
        try:
            return {"error": json.loads(error)}
        except ValueError:
            return reply
    return reply


class LabRecord:
    """What a --perf-lab run needs to write result-v1. The build and host are named before anything is measured
    (a run that cannot be recorded never starts); the cmux app's features snapshot and the lab's full host
    validation (BenchApp.validate_lab_host's `host-env-full-<pid>.json`, which the runner needs) are taken once, at
    the first cmux launch. `versions` is each vendor arm's version (vendor_versions), which its metrics carry."""

    def __init__(self, cmux_bundle: str | None, versions: dict[str, str], environ=None):
        environ = os.environ if environ is None else environ
        self.versions = dict(versions)
        self.perf_import = load_perf_import()
        launch = self.perf_import.bench_launch()
        if not cmux_bundle:
            raise SystemExit("xbench: a --perf-lab run measures a cmux build: --app PATH names none")
        try:
            self.build, self.host = self.perf_import.measured_build(cmux_bundle, environ.get(launch.LAB_CONFIG) or None)
        except launch.RecordError as error:
            raise SystemExit(f"xbench: no result-v1 can name this run: {error}") from None
        self.session = environ.get(launch.LAB_SESSION) or "light"
        self.vdisplay_out = environ.get(launch.LAB_VDISPLAY_OUT)
        self.run = self.perf_import.load("perf_result").Run.start()
        self.features = None
        self.host_checked = False

    def launched(self, browser: "CmuxBrowser", out: str):
        """After a cmux session's app answered on its socket."""
        launch = self.perf_import.bench_launch()
        if self.features is None:
            self.features = launch.features_snapshot(features_reply(browser.app))
        if self.vdisplay_out and not self.host_checked:
            self.host_checked = True
            pids = sorted(browser.instance.pids())
            report = launch.lab_host_check(self.vdisplay_out, pids)
            with open(os.path.join(out, f"{launch.LAB_CHECK_PREFIX}{pids[0] if pids else 'none'}.json"), "w") as f:
                json.dump(report, f, sort_keys=True)
            if not report.get("ok"):
                log(f"WARNING: env-invalid after launch ({', '.join(report.get('reasons') or ['no reason'])}): "
                    "the lab rejects this run's results")

    def write(self, out: str, samples: list[dict], browsers: list[str]) -> list[str]:
        """One result-v1 file per measured arm in `out`, each its own run (one engine per run); the paths. Nothing is
        written when a cmux arm has no features snapshot: its results could not say what they measured."""
        measured = [b for b in browsers if lab_series(samples, b, self.versions)]
        if any(b in CMUX for b in measured) and self.features is None:
            raise SystemExit("xbench: the cmux app gave no features.list snapshot; no result-v1 is written")
        perf_result = self.perf_import.load("perf_result")
        paths = []
        for browser in measured:
            series = [self.perf_import.Series(*s) for s in lab_series(samples, browser, self.versions)]
            run = perf_result.Run(id=f"{self.run.id}.{browser}", started_at=self.run.started_at)
            paths.append(str(self.perf_import.write_series(
                out, STORY, self.session, ENGINES[browser], series, self.build, self.host, run=run,
                features=self.features if browser in CMUX else None)))
        return paths


# ---------------------------------------------------------------- run


class Run:
    def __init__(self, args):
        self.args = args
        self.out = os.path.abspath(args.out)
        os.makedirs(self.out, exist_ok=True)
        self.samples_path = os.path.join(self.out, "samples.jsonl")
        self.helper = Helper(args.cache)
        self.server = pages.BeaconServer()
        self.counter = 0
        self.samples: list[dict] = []  # this run's samples (samples.jsonl may hold an earlier run's too)
        self.lab: LabRecord | None = None  # a --perf-lab run's result-v1 record
        os.makedirs(args.work, exist_ok=True)
        # A --perf-lab run makes its templates and profiles in a folder of its own, which main() removes: a
        # template that an earlier run (another build, or a failed template) left in --work is never cloned.
        self.work = tempfile.mkdtemp(prefix="lab-", dir=args.work) if args.perf_lab else args.work

    def record(self, browser: str, round_no: int, row: str, value, **extra):
        sample = {"browser": browser, "round": round_no, "row": row,
                  "value": None if value is None else round(float(value), 3), "time": round(time.time()), **extra}
        self.samples.append(sample)
        with open(self.samples_path, "a") as handle:
            handle.write(json.dumps(sample) + "\n")
        log(f"{browser} r{round_no} {row} = {sample['value']}" + (f" ({extra.get('note')})" if extra.get("note") else ""))

    def quiet(self) -> float:
        """Waits (at most --quiet-wait s) for the 1-minute load to drop under --max-load."""
        deadline = time.monotonic() + self.args.quiet_wait
        while procs.load_average() > self.args.max_load and time.monotonic() < deadline:
            time.sleep(5)  # bench: waiting for a quiet machine
        return round(procs.load_average(), 2)

    def tab_id(self, prefix: str) -> str:
        self.counter += 1
        return f"{prefix}{self.counter}"

    def profile(self, browser: Browser, label: str) -> str:
        template = os.path.join(self.work, "templates", browser.name)
        run_dir = os.path.join(self.work, "runs", f"{browser.name}-{label}")
        clone(template, run_dir)
        return run_dir

    def make_template(self, browser: Browser):
        template = os.path.join(self.work, "templates", browser.name)
        if os.path.isdir(template) or browser.name == "safari":
            return
        log(f"{browser.name}: template profile ({self.args.template_settle:.0f} s)")
        os.makedirs(template)
        try:
            browser.template(template, self.args.template_settle)
        except BaseException:
            shutil.rmtree(template, ignore_errors=True)  # a half-made template is never cloned
            raise

    # -- cold launches

    def launches(self, browser: Browser, round_no: int):
        for index in range(self.args.launches):
            load = self.quiet()
            profile = self.profile(browser, f"launch{round_no}-{index}")
            tab_id = self.tab_id("launch")
            url = self.server.url("idle", tab_id)
            watch = self.helper.wait_window(os.path.join(os.path.realpath(browser.bundle), "Contents/MacOS/"), 30)
            t0 = now_ms()
            try:
                browser.launch(profile, url if browser.can_link or browser.name == "safari" else None)
                line = (watch.communicate(timeout=40)[0] or "").split()
                window = float(line[0]) - t0 if line else None
                self.record(browser.name, round_no, "launch-window", window, load=load,
                            **({} if line else {"note": "no window within 30 s"}))
                if browser.can_link:
                    painted = self.server.wait("fcp", tab_id, timeout=30)
                    self.record(browser.name, round_no, "launch-link", painted["t"] - t0 if painted else None,
                                load=load, **({} if painted else {"note": "no paint within 30 s"}))
                sleep(3)
            except Exception as error:  # noqa: BLE001 - one failed launch is logged, the run goes on
                self.record(browser.name, round_no, "launch-window", None, note=f"error: {error}"[:300])
            finally:
                if watch.poll() is None:
                    watch.kill()
                browser.quit()
                shutil.rmtree(profile, ignore_errors=True)

    # -- the session: memory, idle, new tab, switch, scroll, video, hidden

    def window(self, browser: Browser, round_no: int, rows: dict, seconds: float, during=None, **extra):
        load = round(procs.load_average(), 2)
        got = browser.instance.window(seconds, during)
        for row, key in window_rows(rows).items():
            self.record(browser.name, round_no, row, got[key], load=load, kinds=got["kinds"],
                        coalition=got["coalition"], **extra)
        return got

    def memory(self, browser: Browser, round_no: int, row: str):
        got = browser.instance.memory()
        self.record(browser.name, round_no, row, got["mb"], processes=got["processes"], kinds=got["kinds"],
                    tabs=len(browser.tabs))

    def open_to(self, browser: Browser, count: int):
        while len(browser.tabs) < count:
            tab_id = self.tab_id("t")
            browser.new_tab(self.server.url("idle", tab_id), tab_id)
            sleep(0.3)  # bench: a user's pace between new tabs

    def session(self, browser: Browser, round_no: int):
        a = self.args
        load = self.quiet()
        profile = self.profile(browser, f"session{round_no}")
        first = self.tab_id("s")
        try:
            browser.launch(profile, self.server.url("idle", first) if browser.can_link or browser.name == "safari" else None)
            browser.ready()
            if self.lab and isinstance(browser, CmuxBrowser):
                self.lab.launched(browser, self.out)
            log(f"{browser.name} r{round_no}: session (load {load})")
            if isinstance(browser, ChromiumBrowser) and browser.extensions:
                sleep(2)  # bench: the extensions' background pages start after the DevTools port
                running = [t["url"] for t in browser.extension_targets()]
                log(f"{browser.name}: extensions asked {browser.extensions}, running {running}")
            if browser.name == "cmux-terminal":
                sleep(a.settle)
                self.window(browser, round_no, {"power-home-idle": "mw", "idle-cpu-home": "cpu_pct",
                                                "idle-wakeups-home": "wakeups_per_s"}, a.idle)
            browser.adopt_first(first)
            if browser.tab_kind == "page":
                painted = self.server.wait("fcp", first, timeout=30)
                if not painted:
                    log(f"{browser.name}: first tab never painted")
            sleep(a.settle)
            self.memory(browser, round_no, "memory-1")
            self.window(browser, round_no, {"power-idle-visible-1": "mw", "idle-cpu-1": "cpu_pct",
                                            "idle-wakeups-1": "wakeups_per_s"}, a.idle)
            if browser.tab_kind == "page":
                for _ in range(a.newtabs):
                    tab_id = self.tab_id("n")
                    t0 = now_ms()
                    handle = browser.new_tab(self.server.url("idle", tab_id), tab_id)
                    painted = self.server.wait("fcp", tab_id, after=t0, timeout=15)
                    self.record(browser.name, round_no, "newtab-paint", painted["t"] - t0 if painted else None,
                                **({} if painted else {"note": "no paint within 15 s"}))
                    sleep(1)
                    if browser.can_close:
                        browser.close(handle)
                        sleep(1)
                    else:
                        browser.tabs.remove(handle)  # Safari keeps it open: it is one of the 20 below
                        browser.tabs.append(handle)
            self.open_to(browser, 10)
            sleep(10)
            self.memory(browser, round_no, "memory-10")
            self.open_to(browser, 20)
            sleep(15)
            self.memory(browser, round_no, "memory-20")
            sleep(a.settle)
            self.window(browser, round_no, {"power-idle-visible": "mw", "idle-cpu-20": "cpu_pct",
                                            "idle-wakeups-20": "wakeups_per_s"}, a.idle)
            if isinstance(browser, ChromiumBrowser):
                browser.probe_cdp()  # Ardia's CDP has no /json/activate or /json/close
            if browser.can_switch or browser.name == "cmux-terminal":
                latencies = []

                def switch(seconds: float):
                    deadline = time.monotonic() + seconds
                    pool = browser.tabs[:9] if isinstance(browser, CmuxBrowser) else browser.tabs[:16]
                    index = 0
                    while time.monotonic() < deadline:
                        handle = pool[(index * 5 + 1) % len(pool)]
                        index += 1
                        t0 = now_ms()
                        browser.activate(handle)
                        if browser.tab_kind == "page":
                            # cmux's pane also holds the workspace's terminal, so its shortcut
                            # index is not the bench's: any page shown after the command counts.
                            shown = self.server.wait("shown", browser.ids.get(handle)
                                                     if isinstance(browser, ChromiumBrowser) else None,
                                                     after=t0, timeout=1.4)
                            if shown:
                                latencies.append(shown["t"] - t0)
                        left = 1.5 - (now_ms() - t0) / 1000
                        if left > 0:
                            time.sleep(left)  # bench: one switch every 1.5 s

                self.window(browser, round_no, {"power-switch": "mw"}, a.active, during=switch)
                if browser.tab_kind == "page":
                    value = statistics.median(latencies) if latencies else None
                    self.record(browser.name, round_no, "tab-switch", value, switches=len(latencies),
                                **({} if latencies else {"note": "no visibilitychange seen"}))
            if browser.tab_kind == "page":
                for page, row, settle, ready_ev in (("scroll", "power-scroll", 3, "load"),
                                                    ("video", "power-video", 3, "playing")):
                    tab_id = self.tab_id(page[0])
                    handle = browser.new_tab(self.server.url(page, tab_id), tab_id)
                    ok = self.server.wait(ready_ev, tab_id, timeout=40)
                    sleep(settle)
                    self.window(browser, round_no, {row: "mw"}, a.active,
                                **({} if ok else {"note": f"no {ready_ev} beacon"}))
                    if browser.can_close:
                        browser.close(handle)
                    sleep(2)
            if browser.hide():
                sleep(10)
                self.window(browser, round_no, {"power-idle-hidden": "mw"}, a.idle)
                browser.unhide()
            else:  # a visible app's idle is not the hidden app's (as budget.py)
                self.record(browser.name, round_no, "power-idle-hidden", None, note="the app did not hide")
            if browser.can_close:
                while len(browser.tabs) > 1:
                    browser.close(browser.tabs[-1])
                    sleep(0.2)  # bench: a user's pace closing tabs
                sleep(30)
                self.memory(browser, round_no, "memory-closed")
        except Exception as error:  # noqa: BLE001 - a failed session is logged, the run goes on
            self.record(browser.name, round_no, "session-error", None, note=f"{type(error).__name__}: {error}"[:400])
        finally:
            browser.quit()
            shutil.rmtree(profile, ignore_errors=True)

    def machine(self) -> dict:
        def sysctl(name):
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
        return {"host": subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
                or platform.node(), "model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"),
                "cores": int(sysctl("hw.ncpu") or 0), "ram_gb": int(sysctl("hw.memsize") or 0) // 2**30,
                "macos": platform.mac_ver()[0], "build": subprocess.run(["sw_vers", "-buildVersion"],
                                                                       capture_output=True, text=True).stdout.strip(),
                "load_start": round(procs.load_average(), 2), "displays": self.helper.displays(),
                "session": subprocess.run(["launchctl", "managername"], capture_output=True,
                                          text=True).stdout.strip()}

    def main(self):
        try:
            self.measure()
        finally:
            if self.work != self.args.work:
                shutil.rmtree(self.work, ignore_errors=True)

    def arms(self) -> dict[str, str]:
        """{browser: bundle} of the --browsers arms that have a bundle, in --browsers order. A nightly run skips an arm
        with none; a --perf-lab run refuses to start, since its story compares cmux with the reference arm."""
        a = self.args
        apps = parse_apps(a.app)
        apps.update(fetch([name for name in a.fetch if name not in apps]))
        apps.setdefault("safari", "/Applications/Safari.app")
        names = a.browsers.split(",")
        arms, missing = {}, []
        for name in names:
            bundle = apps.get("cmux" if name in CMUX else name)
            if bundle and os.path.isdir(bundle):
                arms[name] = bundle
            else:
                missing.append(name)
                log(f"{name}: no bundle (--app {'cmux' if name in CMUX else name}=PATH), skipped")
        if a.perf_lab and (missing or REFERENCE_ARM not in names):
            reasons = [f"no bundle for {', '.join(missing)}"] if missing else []
            if REFERENCE_ARM not in names:
                reasons.append(f"--browsers has no reference arm {REFERENCE_ARM}")
            raise SystemExit(f"xbench: a --perf-lab run measures every arm it names: {'; '.join(reasons)}; "
                             "nothing measured")
        return arms

    def measure(self):
        a = self.args
        arms = self.arms()
        if a.perf_lab:
            self.lab = LabRecord(next((b for name, b in arms.items() if name in CMUX), None), vendor_versions(arms))
        browsers = [make_browser(name, bundle, self.helper, self.server,
                                 a.chrome_extension if name == "chrome" else None) for name, bundle in arms.items()]
        meta_path = os.path.join(self.out, "meta.json")
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        meta.update({"machine": self.machine(), "cmux_ref": a.cmux_ref, "tag": a.tag, "args": vars(a),
                     "browsers": {b.name: b.info() for b in browsers}})
        with open(meta_path, "w") as handle:
            json.dump(meta, handle, indent=1)
        log(f"machine {json.dumps(meta['machine'])}")
        if not can_launch_apps():
            # LaunchServices refuses to start apps for a process outside a logged-in
            # console user's session (RBSRequestErrorDomain Code=5 "Launch failed"):
            # no row can be measured on this host.
            print(f"PERF-BENCH-NO-GUI launchd domain {meta['machine']['session']!r}: `open` cannot start an app "
                  "here (needs a host with a logged-in console user)", flush=True)
            sys.exit(3)
        if not meta["machine"]["displays"].get("count"):
            log("WARNING: no active display: paint, switch and video rows may not be meaningful")
        caffeinate = subprocess.Popen(["caffeinate", "-dimsu"])
        try:
            for browser in browsers:
                try:
                    self.make_template(browser)
                except Exception as error:  # noqa: BLE001
                    log(f"{browser.name}: template failed: {error}")
                    browser.quit()
            order = list(browsers)
            for round_no in range(1, a.rounds + 1):
                order = order[1:] + order[:1] if round_no > 1 else order  # rotate each round
                for browser in order:
                    if browser.name == budget.NAME:
                        budget.session(self, browser, round_no, log, a.budgets)
                        continue
                    self.launches(browser, round_no)
                    self.session(browser, round_no)
        finally:
            caffeinate.terminate()
        if self.lab:
            for path in self.lab.write(self.out, self.samples, [b.name for b in browsers]):
                log(f"result-v1 {path}")


# ---------------------------------------------------------------- report


def aggregate(samples: list[dict]) -> dict:
    rows: dict[str, dict[str, dict]] = {}
    for sample in samples:
        if sample.get("value") is None or sample["row"] not in ROW_INFO:
            continue
        rows.setdefault(sample["row"], {}).setdefault(sample["browser"], []).append(sample["value"])
    result = {}
    for row, per in rows.items():
        result[row] = {b: {"median": round(statistics.median(v), 3), "min": min(v), "max": max(v), "n": len(v)}
                       for b, v in per.items()}
    return result


def fmt(value, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "MB":
        return f"{value:,.0f} MB"
    if unit == "ms":
        return f"{value:,.0f} ms" if value >= 100 else f"{value:.1f} ms"
    if unit == "%":
        return f"{value:.2f}%"
    if unit == "/s":
        return f"{value:.1f}/s"
    if unit == "ms/s":
        return f"{value:.1f} ms/s"
    return f"{value:,.0f} mW" if value >= 100 else f"{value:.1f} mW"


def ratio(cmux_value, other) -> str:
    if cmux_value is None or other is None:
        return "–"
    if cmux_value <= 0:
        return "∞x less"
    r = other / cmux_value
    return f"{r:.1f}x less" if r >= 1 else f"{1 / r:.1f}x MORE"


TAB_SWITCH_KINDS = {"chromium": "Browser (Chromium)", "webkit": "Browser (WebKit)", "markdown": "Markdown",
                    "chat": "Chat", "terminal": "Terminal", "file": "Code file"}
TAB_SWITCH_BROWSER = "cmux-debug"  # the matrix needs a tagged Debug build (debug.key, debug.tab_switch)


def tab_switch_rows(path: str | None) -> tuple[dict, list[str]]:
    """Rows and BENCH.md lines from tab-switch-matrix.py's report: end-to-end ms (OS input event to
    the Core Animation commit that shows the tab) per kind, tab count and input, in a real window."""
    if not path or not os.path.exists(path):
        return {}, []
    data = json.load(open(path))
    rows, lines = {}, []
    lines += ["## Tab switch in a real window (cmux NEXT, tagged Debug build)", "",
              "**Debug only:** these rows come from a tagged Debug build (the timing hooks exist only in "
              "Debug), not the Release or nightly build in the table above. Compare them only with other "
              "Debug runs.", "",
              "tab-switch-matrix.py: one pane holding N tabs of a kind, warm; end-to-end = OS input event to "
              "the Core Animation commit that shows the tab (p50 / p90 ms); late = switches past their first frame.", "",
              "| Kind | Tabs | Ctrl-Tab | Cmd-Shift-] | Click | late | per hidden tab |", "|---|---|---|---|---|---|---|"]
    for scenario in data.get("scenarios", []):
        kind, count = scenario["kind"], scenario["count"]
        cells, late = [], []
        for input_kind in ("ctrl_tab", "cmd_shift_bracket", "click"):
            table = (scenario.get(input_kind) or {}).get("table") or {}
            # Keyed by the switched-to surface's kind: Markdown and chat tabs are both `page`.
            line = table.get(kind) or table.get("page") or next(
                (v for k, v in table.items() if k != "terminal"), {})
            e2e = line.get("e2e") or line.get("commit") or {}
            if e2e.get("p50") is None:
                cells.append("–")
                continue
            cells.append(f"{e2e['p50']:.1f} / {e2e['p90']:.1f}")
            late.append(f"{line.get('late_switches')}/{line.get('n')}")
            rows.setdefault(f"tab-switch-{kind}-{count}-{input_kind}", {})[TAB_SWITCH_BROWSER] = {
                "median": e2e["p50"], "p90": e2e["p90"], "n": line.get("n")}
        per_tab = scenario.get("per_tab") or {}
        lines.append(f"| {TAB_SWITCH_KINDS.get(kind, kind)} | {count} | " + " | ".join(cells) +
                     f" | {', '.join(late) or '–'} | {per_tab.get('footprint_mb', '–')} MB |")
    lines.append("")
    return rows, lines


def palette_rows(path: str | None) -> tuple[dict, list[str]]:
    """Rows and BENCH.md lines from palette-open-stages.py's report (a182): key-down to the palette's
    committed first frame, per focused surface, for Cmd-Shift-P (Command Palette) and Cmd-P."""
    if not path or not os.path.exists(path):
        return {}, []
    data = json.load(open(path))
    rows, lines = {}, []
    lines += ["## Palette open (cmux NEXT, tagged Debug build)", "",
              "**Debug only**, like the tab switch rows. palette-open-stages.py: key-down (`debug.key`, the key "
              "router's real path) to the Core Animation commit of the palette's first frame, warm, p50 / p90 ms; "
              "the budget is one 60 Hz frame (p90 <= 16 ms).", "",
              "| Focused surface | Cmd-Shift-P | Cmd-P | missed |", "|---|---|---|---|"]
    surfaces = {}
    for name, entry in (data.get("surfaces") or {}).items():
        label, _, key = name.rpartition(" ")
        key_stage = (entry.get("table") or {}).get("key") or {}
        surfaces.setdefault(label, {})[key] = (key_stage, entry.get("missed", 0), len(entry.get("samples") or []))
        if key_stage.get("p50") is not None:
            slug = re.sub(r"[^a-z0-9]+", "-", f"{label} {key}".lower()).strip("-")
            rows.setdefault(f"palette-open-{slug}", {})[TAB_SWITCH_BROWSER] = {
                "median": key_stage["p50"], "p90": key_stage["p90"], "n": len(entry.get("samples") or [])}
    for label, keys in surfaces.items():
        cells, missed = [], []
        for key in ("Cmd-Shift-P", "Cmd-P"):
            stage, miss, n = keys.get(key, ({}, 0, 0))
            cells.append(f"{stage['p50']:.1f} / {stage['p90']:.1f}" if stage.get("p50") is not None else "–")
            if miss + n:
                missed.append(f"{miss}/{miss + n}")
        lines.append(f"| {label} | " + " | ".join(cells) + f" | {', '.join(missed) or '–'} |")
    lines.append("")
    return rows, lines


def report(out: str, md_path: str | None, json_path: str | None, tabswitch: str | None = None,
           palette: str | None = None, budgets: str | None = None):
    path = os.path.join(out, "samples.jsonl")
    samples = [json.loads(line) for line in open(path) if line.strip()] if os.path.exists(path) else []
    meta = json.load(open(os.path.join(out, "meta.json")))
    rows = aggregate(samples)
    switch_rows, switch_lines = tab_switch_rows(tabswitch)
    rows.update(switch_rows)
    palette_found, palette_lines = palette_rows(palette)
    rows.update(palette_found)
    errors = [s for s in samples if s["row"] == "session-error" or (s.get("value") is None and s.get("note"))]
    budget_errors = sum(1 for sample in samples if sample["browser"] == budget.NAME and sample["row"] == "session-error")
    # The run's budgets file decides, so samples are judged against the scenario that collected them.
    budgets = budgets or meta.get("args", {}).get("budgets") or budget.DEFAULT_BUDGETS
    budget_result, budget_lines = budget.evaluate(rows, budget.NAME in meta.get("browsers", {}), budgets,
                                                  int(meta.get("args", {}).get("rounds") or 0), budget_errors)
    result = {"date": time.strftime("%Y-%m-%d"), "machine": meta["machine"], "cmux_ref": meta.get("cmux_ref"),
              "browsers": meta["browsers"], "rows": rows, "published": PUBLISHED,
              "errors": [{k: s.get(k) for k in ("browser", "round", "row", "note")} for s in errors],
              "budgets": budget_result, "method": "scripts/perf-bench/README.md", "samples": samples}
    if json_path:
        with open(json_path, "w") as handle:
            json.dump(result, handle, indent=1)
    m = meta["machine"]
    present = [b for b in ["cmux-chromium", "cmux-webkit", "cmux-terminal", "chrome", "helium", "ardia", "dia", "safari"]
               if any(b in per for per in rows.values())]
    others = [b for b in present if b not in CMUX]
    lines = [f"# xbench, {result['date']}: cmux NEXT against Chrome, Helium, Ardia, Dia, Safari", "",
             f"{m['chip']} ({m['model']}), {m['cores']} cores, {m['ram_gb']} GB, macOS {m['macos']} ({m['build']}), "
             f"host {m['host']}, cmux ref `{(result['cmux_ref'] or '?')[:12]}`. Medians over runs (n per cell in "
             "results.json, min-max there too). Lower is better.", ""]
    versions = ", ".join(f"{meta['browsers'][b]['name']} {meta['browsers'][b]['version']}" for b in present
                         + ([budget.NAME] if budget_result["measured"] and budget.NAME in meta["browsers"] else []))
    lines += [f"Versions: {versions}.", ""]
    if present:  # a budget-only run has no comparison table
        head = ["Metric"] + [LABELS[b] for b in present] + ["best other", "cmux vs best other", "Ardia (published, M5 Pro)",
                                                       "Helium (published)"]
        lines += ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
        for row, label, unit, main in ROWS:
            per = rows.get(row, {})
            if not per:
                continue
            cells = [fmt(per.get(b, {}).get("median"), unit) for b in present]
            best = min((per[b]["median"], b) for b in others if b in per) if any(b in per for b in others) else None
            cmux_best = min((per[b]["median"] for b in CMUX if b in per), default=None)
            lines.append("| " + " | ".join([label + ("" if main else " *")] + cells + [
                f"{fmt(best[0], unit)} ({LABELS[best[1]]})" if best else "–",
                ratio(cmux_best, best[0] if best else None),
                fmt(PUBLISHED["ardia"].get(row), unit), fmt(PUBLISHED["helium"].get(row), unit)]) + " |")
        lines += ["", "\\* not in Ardia's tweet. \"cmux vs best other\" uses the best cmux variant of the row. "
                  "Power is CPU energy (ri_energy_nj) over every process of the browser; GPU and display are not in it. "
                  "The -billed rows add the energy other processes (WindowServer, the render server) spent for it and "
                  "take off what it spent for them. Wakeups are interrupt wakeups (Chrome's GetIdleWakeupsPerSecond); "
                  "package-idle wakeups, a subset, are the -pkg-idle rows. "
                  "The 10x goal: every cmux cell at a tenth of the best other.", ""]
    lines += budget_lines
    lines += switch_lines
    lines += palette_lines
    if errors:
        lines += ["## Rows that could not be measured", ""]
        seen = set()
        for e in result["errors"]:
            key = (e["browser"], e["row"], (e.get("note") or "")[:80])
            if key not in seen:
                seen.add(key)
                lines.append(f"- {e['browser']} {e['row']}: {e.get('note')}")
        lines.append("")
    text = "\n".join(lines)
    if md_path:
        with open(md_path, "w") as handle:
            handle.write(text)
    print(text)
    return result


# ---------------------------------------------------------------- gate

FLOORS = {"ms": 5.0, "MB": 15.0, "mW": 2.0, "%": 0.1, "/s": 2.0, "ms/s": 1.0}


def gate(results_path: str, baseline_path: str, tolerance: float) -> int:
    """Fail on regressions *or incomplete coverage*.

    A missing current cell used to be skipped, which made a timed-out or
    unsupported bench look like a clean pass. The baseline is the explicit
    expected row/browser matrix; callers can put a ``row|browser`` key in an
    ``unsupported`` list when a surface is intentionally unavailable.
    """
    with open(results_path) as handle:
        result_doc = json.load(handle)
    with open(baseline_path) as handle:
        baseline_doc = json.load(handle)
    results = result_doc.get("rows", {})
    baseline = baseline_doc.get("rows", {})
    def unsupported_entries(document):
        entries = {}
        for item in document.get("unsupported") or []:
            if isinstance(item, str):
                entries[item] = "explicitly allowlisted"
            elif isinstance(item, dict) and item.get("key"):
                entries[item["key"]] = item.get("reason") or "explicitly allowlisted"
        return entries

    allowlisted = unsupported_entries(baseline_doc)
    allowlisted.update(unsupported_entries(result_doc))
    failed = 0
    incomplete = []
    expected = measured = unsupported = 0
    if not baseline:
        incomplete.append("baseline has no rows")
    for row, per in baseline.items():
        if row not in ROW_INFO and not row.startswith(("tab-switch-", "palette-open-")):
            continue
        if row in budget.ROW_INFO:
            continue  # budgets.json gates these (advisory or enforced), not the baseline's 15 %
        unit = ROW_INFO[row][1] if row in ROW_INFO else "ms"
        for browser in (*CMUX, TAB_SWITCH_BROWSER):
            # The checked-in baseline is the manifest for each row. Resource
            # budget and Debug-only surfaces have separate reports and are not
            # present in the cross-browser baseline.
            if browser not in per:
                continue
            expected += 1
            base = per.get(browser, {}).get("median")
            now = results.get(row, {}).get(browser, {}).get("median")
            key = f"{row}|{browser}"
            if key in allowlisted:
                unsupported += 1
                print(f"PERF-BENCH-GATE UNSUPPORTED {key}: {allowlisted[key]}")
                continue
            if base is None:
                incomplete.append(f"{key}: missing baseline median")
                continue
            if now is None:
                incomplete.append(f"{key}: missing current median")
                continue
            measured += 1
            limit = base + max(base * tolerance, FLOORS[unit])
            verdict = "REGRESSED" if now > limit else "ok"
            failed += verdict != "ok"
            print(f"PERF-BENCH-GATE {verdict} {browser} {row} now={now} baseline={base} limit={round(limit, 3)} {unit}")
    # Rows newly emitted by a bench are not expected until a baseline records
    # them. This keeps an older sparse baseline usable while still failing
    # closed when one of its recorded cells disappears from the current run.
    for reason in incomplete:
        print(f"PERF-BENCH-GATE INCOMPLETE {reason}")
    verdict = "FAIL" if failed or incomplete else "PASS"
    print(f"PERF-BENCH-GATE {verdict} regressions={failed} incomplete={len(incomplete)} "
          f"expected={expected} measured={measured} unsupported={unsupported}")
    return 1 if failed or incomplete else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--perf-lab", action="store_true",
                        help="the perf lab runs this (scripts/perf-lab): measure even while its sentinel exists")
    sub =parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--out", required=True)
    run.add_argument("--app", action="append", default=[], metavar="NAME=BUNDLE")
    run.add_argument("--browsers", default=DEFAULT_BROWSERS)
    run.add_argument("--rounds", type=int, default=3)
    run.add_argument("--launches", type=int, default=2, help="cold launches per browser per round")
    run.add_argument("--newtabs", type=int, default=5)
    run.add_argument("--idle", type=float, default=60)
    run.add_argument("--active", type=float, default=30)
    run.add_argument("--settle", type=float, default=30)
    run.add_argument("--template-settle", type=float, default=45)
    run.add_argument("--max-load", type=float, default=4)
    run.add_argument("--quiet-wait", type=float, default=120)
    run.add_argument("--chrome-extension", action="append", default=[], metavar="DIR",
                     help="an unpacked extension Chrome loads (D6: the uBlock Origin cmux bundles, "
                     "scripts/cmux-next/fetch-ublock.sh; branded Chrome 137+ ignores it, so --app chrome= a "
                     "Chromium that runs MV2)")
    run.add_argument("--fetch", action="append", default=[], choices=sorted(CHROMIUM), metavar="NAME",
                     help="fetch this browser with fetch_browsers.py when no --app names it (the lab's Chrome arm)")
    run.add_argument("--tag", default="", help="the perf lab runner's tag of the cmux build (kept in meta.json)")
    run.add_argument("--cmux-ref", default="")
    run.add_argument("--work", default="/private/tmp/xbench")
    run.add_argument("--cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"))
    run.add_argument("--budgets", default=budget.DEFAULT_BUDGETS, type=os.path.abspath,
                     help="cmux-budget's scenario and budgets (kept in meta.json for report)")
    rep = sub.add_parser("report")
    rep.add_argument("--out", required=True)
    rep.add_argument("--md")
    rep.add_argument("--json")
    rep.add_argument("--tabswitch", help="tab-switch-matrix.py's --json report")
    rep.add_argument("--palette", help="palette-open-stages.py's --json report")
    rep.add_argument("--budgets", help="budgets.json (default: the one the run used); an enforced budget "
                     "the cmux-budget session broke exits 1")
    gat = sub.add_parser("gate")
    gat.add_argument("--results", required=True)
    gat.add_argument("--baseline", required=True)
    gat.add_argument("--tolerance", type=float, default=0.15)
    args = parser.parse_args(argv)
    if os.path.exists(LAB_SENTINEL) and not args.perf_lab:
        print(f"xbench: {LAB_REASON} (scripts/perf-lab/OWNS_MEASUREMENT); nothing measured", flush=True)
        sys.exit(0)
    if args.command == "run":
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        random.seed(0)
        Run(args).main()
    elif args.command == "report":
        result = report(args.out, args.md, args.json, args.tabswitch, args.palette, args.budgets)
        sys.exit(1 if result["budgets"]["failed"] else 0)
    else:
        sys.exit(gate(args.results, args.baseline, args.tolerance))


if __name__ == "__main__":
    main()
