#!/usr/bin/env python3
"""rivals: cmux NEXT's launch, RAM and CPU against the agent apps and browsers people run beside it.

Leo, 2026-11-22 (ask-7c96907088): "did you guys do it against the fresh starts first install type timings?
those are the ones too. and after shutdown or whatever. restarting a computer. or close enough to it. and
gauging our ram/cpu ceiling and growth too probably. compare more exhaustively. much more. compare to claude
and codex and t3 code too. [...] hell, go look at edge/chrome/safari/slack/helium too."

Every app runs the same session on one Mac, one app at a time, each launch in an empty home
(HOME and CFFIXED_USER_HOME point into the run folder, so nothing touches the worker's ~/Library):

  fresh     a new copy of the vendor's bundle (ditto from the verified cache, the bytes a download or an
            update lays down; not quarantined, so no Gatekeeper prompt) opened for the first time with an
            empty home: the first launch a new install pays (first exec signature check, first-run setup).
            Safari is the system's and cannot be copied: its fresh row is an empty home only.
  restart   the same copy and home, quit, `sudo -n /usr/sbin/purge` (drops the file cache, the closest a
            step gets to a reboot without one), opened again. With no passwordless sudo the row is null and
            says so. A real reboot for cmux alone: scripts/measure/launch-reboot.sh.
  warm      quit and opened again at once, --warm times (the everyday relaunch).
  quarantined  (opt-in, --quarantined) another new copy with an empty home, the `com.apple.quarantine` xattr set on
            every item as a browser download leaves it (RFD 0131 option G: the launch a new user gets from a DMG
            or zip in Downloads), opened for the first time. macOS shows its first-open prompt ("downloaded from
            the Internet") and runs the full Gatekeeper and XProtect check; the copy is opened where it lies, so
            it is also translocated (the window and processes are found under the AppTranslocation folder).
            The prompt waits for a click: on a Mac that does not approve it on its own the row is null ("no window
            within 60 s") and the prompt stays up until someone answers it. Run it on a fleet Mac set to approve
            first-open prompts; with an approver, its click latency is in the number. Nothing here clears the
            quarantine or approves the prompt (no policy is changed or skipped). Safari has no download: null.

Per launch: ms from the open request to the first on-screen window >= 300x200 (benchhelper wait-window,
as xbench's launch-window), then every second for --after s the instance's physical footprint (its peak),
and the CPU seconds every process of the instance spent from its start to the end of that window.
Per app, once: `bundle-size` (du) and `signed-items` (RFD 0131 option F), the code items `codesign --verify --deep`
and the first-exec Gatekeeper check walk: every Mach-O file (thin or fat; executables, dylibs, helpers) and every
sealed nested bundle (a folder holding `_CodeSignature`: frameworks, helper apps, XPC services, plug-ins), the app
itself included; symlinks are not followed (a framework's Versions/Current counts once). The breakdown is kept in
the sample's `machos`, `bundles` and `kinds`.

After the last warm launch, an idle soak: --soak s in --sample s windows of footprint, CPU % (of one core),
wakeups/s, threads, processes and disk writes. Rows: start, end and peak footprint (the ceiling), growth
(MB per minute, least squares over the soak), mean and peak CPU, mean wakeups.

By process group (RFD 0062, hq docs/rfd/0062-ram-cpu-ceiling-and-growth.md): every soak window also splits the
footprint, CPU and wakeups over five groups, for cmux and every rival alike: app (the app process, its CEF or
Electron browser-side helpers and utility processes), renderer (Chromium renderers; Safari's WebKit WebContent),
gpu (Chromium's GPU process; Safari's WebKit GPU), acpmux, terminals (cmux-tui, its holders and terminal hosts);
anything else is "other". The soak's last window also records every process (pid, kind, group, footprint, CPU,
wakeups) as a soak-detail sample. Safari's WebContent, GPU and Networking processes are XPC services, not
children of Safari: procs.Instance counts them through responsibility_get_pid_responsible_for_pid, and the
report says so when a Safari soak found no WebKit process.

Apps sign in nowhere: an agent app's window is its signed-out first screen, a browser's its new tab page.
That is what a person sees on a first launch, and the same for every app.

Growth (RFD 0062's growth bounds): the short slope drops the first --settle-cut s (default 90: launch work
settling, cmux's release takes 90 s); the whole-soak slope stays as its own row. A long soak (--soak 28800, 8 h)
also reads troughs every --trough-every s (default: off under 30 min, else soak/12): at each trough, with
passwordless sudo, `memory_pressure -S -l warn` (Chromium, Electron and WebKit collect garbage and drop caches
on the system's pressure notice) and a read --sample s later, back to normal after; without sudo the trough is
the bucket's lowest sample. Rows: trough growth (MB per minute, least squares over the troughs), the last
trough, and the mean drop a pressure notice bought.

More rows, each its own idle soak after the signed-out session (row ids prefixed signed-in- and tabs-):
  --signed-in NAME=DIR   the app launched from a signed-in profile: DIR's contents (home/ and, for Chromium,
                         data/, as a run's profile folder) copied into a new profile. Made once by hand on the
                         bench Mac (sign in with the app's home pointed at DIR/home); never committed.
  --tabs N               browsers (Chrome, Edge, Helium, Safari): N local idle pages (pages.py, 127.0.0.1) opened
                         as tabs in one window, all but the first in the background: discard, freeze and
                         sleeping tabs show here, given a soak longer than their timers (Chrome and Edge: 5 min).

Usage (on a fleet Mac with a console user; scripts/measure/rivals.sh is the fleet entry):
  rivals.py run --out DIR --app NAME=BUNDLE ... [--rounds 1] [--warm 3] [--after 20] [--soak 300] [--sample 10]
                [--quarantined]
  rivals.py report --out DIR [--md RIVALS.md] [--json results.json]

App names: cmux (cmux NEXT), rex, zed, claude, codex, t3code, slack, chrome, edge, helium, safari; any other name is
launched the same generic way.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import pwd
import shutil
import statistics
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROWS = [
    # id, label, unit, the summary table
    ("fresh-window", "First launch of a new install, window up", "ms", True),
    ("restart-window", "Launch after purge (close to a restart), window up", "ms", True),
    ("warm-window", "Warm relaunch, window up", "ms", True),
    ("fresh-cpu", "First launch: CPU spent to window + after", "s", True),
    ("restart-cpu", "After purge: CPU spent to window + after", "s", False),
    ("warm-cpu", "Warm relaunch: CPU spent to window + after", "s", False),
    ("fresh-memory-peak", "First launch: peak footprint", "MB", False),
    ("restart-memory-peak", "After purge: peak footprint", "MB", False),
    ("warm-memory-peak", "Warm relaunch: peak footprint", "MB", False),
    ("quarantined-window", "First launch of a quarantined download, window up (prompt included)", "ms", True),
    ("quarantined-cpu", "Quarantined first launch: CPU spent to window + after", "s", False),
    ("quarantined-memory-peak", "Quarantined first launch: peak footprint", "MB", False),
    ("bundle-size", "Bundle on disk", "MB", True),
    ("signed-items", "Signed code items in the bundle (Mach-O files + sealed bundles)", "n", True),
]
SOAK_ROWS = [
    ("memory-start", "footprint at start", "MB", True),
    ("memory-end", "footprint at end", "MB", False),
    ("memory-peak", "peak footprint (ceiling)", "MB", True),
    ("memory-growth", "footprint growth, after the settle cut", "MB/min", True),
    ("memory-growth-all", "footprint growth, whole soak", "MB/min", False),
    ("memory-trough-growth", "trough growth", "MB/min", False),
    ("memory-trough-last", "last trough", "MB", False),
    ("memory-pressure-drop", "drop at a memory-pressure notice, mean", "MB", False),
    ("cpu", "CPU, mean", "%", True),
    ("cpu-peak", "CPU, peak window", "%", False),
    ("wakeups", "wakeups, mean", "/s", True),
    ("processes", "processes", "n", False),
    ("threads", "threads", "n", False),
    ("disk", "disk writes", "KB/s", False),
]
# A soak pass: its row prefix and its label. "soak" is the signed-out idle soak after the last warm launch.
PASSES = [("soak", "Idle"), ("signed-in-soak", "Signed in, idle"), ("tabs-soak", "Background tabs, idle")]
for _prefix, _pass_label in PASSES:
    ROWS += [(f"{_prefix}-{row}", f"{_pass_label}: {label}", unit, summary and _prefix == "soak")
             for row, label, unit, summary in SOAK_ROWS]
for _kind, _kind_label in (("signed-in", "Signed in"), ("tabs", "Background tabs")):
    ROWS += [(f"{_kind}-window", f"{_kind_label}: launch, window up", "ms", False),
             (f"{_kind}-cpu", f"{_kind_label}: CPU spent to window + after", "s", False),
             (f"{_kind}-memory-peak", f"{_kind_label}: peak footprint", "MB", False)]
UNITS = {row: unit for row, _label, unit, _summary in ROWS}
LABELS = {"cmux": "cmux NEXT", "claude": "Claude", "codex": "Codex", "t3code": "T3 Code", "rex": "Rex",
          "slack": "Slack", "chrome": "Chrome", "edge": "Microsoft Edge", "helium": "Helium", "safari": "Safari",
          "zed": "Zed"}
ORDER = ["cmux", "rex", "zed", "claude", "codex", "t3code", "slack", "chrome", "edge", "helium", "safari"]
CHROMIUM = {"chrome", "edge", "helium"}
ELECTRON = {"claude", "codex", "t3code", "slack"}
NATIVE = {"zed"}  # native UI, no webview (Zed: Rust and its own GPU UI): launched with no extra switches
SYSTEM = {"safari"}  # sealed system apps: no fresh copy
BROWSERS = CHROMIUM | SYSTEM
GROUPS = ["app", "renderer", "gpu", "acpmux", "terminals", "other"]
GROUP_LABELS = {"app": "app (shell + browser process, helpers, utility)", "renderer": "renderer", "gpu": "GPU",
                "acpmux": "acpmux", "terminals": "terminals (cmux-tui, holders, terminal hosts)", "other": "other"}
GROUP_METRICS = [("memory", "footprint, end", "MB"), ("growth", "footprint growth, after the settle cut", "MB/min"),
                 ("cpu", "CPU, mean", "%"), ("wakeups", "wakeups, mean", "/s"), ("processes", "processes", "n")]
for _prefix, _pass_label in PASSES:
    for _group in GROUPS:
        for _metric, _label, _unit in GROUP_METRICS:
            ROWS.append((f"{_prefix}-group-{_group}-{_metric}", f"{_pass_label}, {GROUP_LABELS[_group]}: {_label}",
                         _unit, False))
UNITS.update({row: unit for row, _label, unit, _summary in ROWS})


def group_of(kind: str) -> str:
    """The RFD 0062 process group of a procs.kind_of kind."""
    if kind in ("renderer", "webkit-webcontent"):
        return "renderer"
    if kind in ("gpu", "webkit-gpu"):
        return "gpu"
    if kind == "acpmux" or kind.startswith("acpmux"):
        return "acpmux"
    if kind in ("terminal-host", "cmux-tui", "cmux-holder", "holder") or kind.startswith("cmux-tui"):
        return "terminals"
    if kind in ("main", "helper") or kind.startswith("utility:") or kind.startswith("webkit-"):
        return "app"
    return "other"


def by_group(memory_kinds: dict, window_kinds: dict) -> dict:
    """{group: {memory, cpu, wakeups, processes}} from one memory() and one window() read."""
    out = {g: {"memory": 0.0, "cpu": 0.0, "wakeups": 0.0, "processes": 0} for g in GROUPS}
    for kind, mb in (memory_kinds or {}).items():
        out[group_of(kind)]["memory"] += mb
    for kind, entry in (window_kinds or {}).items():
        group = out[group_of(kind)]
        group["cpu"] += entry.get("cpu_pct", 0.0)
        group["wakeups"] += entry.get("wakeups_per_s", 0.0)
        group["processes"] += entry.get("n", 0)
    return out


def log(message: str):
    print(f"[rivals {time.strftime('%H:%M:%S')}] {message}", flush=True)


def now_ms() -> float:
    return time.time() * 1000


def slope_per_min(points: list[tuple[float, float]]) -> float | None:
    """Least squares slope of (seconds, MB) points, in MB per minute; None under two points."""
    if len(points) < 2:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    var = sum((x - mx) ** 2 for x in xs)
    if var == 0:
        return None
    return 60 * sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / var


def troughs(points: list[tuple[float, float]], every: float) -> list[tuple[float, float]]:
    """The lowest (seconds, MB) point of each `every`-second bucket: the sawtooth's troughs."""
    if every <= 0:
        return []
    buckets: dict[int, tuple[float, float]] = {}
    for t, mb in points:
        key = int(t // every)
        if key not in buckets or mb < buckets[key][1]:
            buckets[key] = (t, mb)
    return [buckets[k] for k in sorted(buckets)]


def trough_every(soak: float, given: float | None) -> float:
    """--trough-every, or by default none under 30 min and soak/12 from there (40 min troughs over 8 h)."""
    if given is not None:
        return max(0.0, given)
    return 0.0 if soak < 1800 else soak / 12


def memory_pressure(level: str) -> bool:
    """Simulate a system memory-pressure level (root: sudo -n). False when it cannot."""
    try:
        return subprocess.run(["sudo", "-n", "/usr/bin/memory_pressure", "-S", "-l", level], capture_output=True,
                              timeout=60).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def bundle_mb(bundle: str) -> float | None:
    out = subprocess.run(["du", "-sk", bundle], capture_output=True, text=True).stdout.split()
    return int(out[0]) / 1024 if out else None


# The first bytes of a Mach-O file: thin 32/64-bit in either byte order, and the fat (universal) headers.
MACHO_THIN = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"}
MACHO_FAT = {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}  # FAT_MAGIC, FAT_MAGIC_64 (big-endian on disk)


def is_macho(path: str) -> bool:
    """Whether PATH is a Mach-O file. 0xcafebabe is also a Java class file's magic: a fat header's next word is
    its slice count (a handful), a class file's is its version (45 and up), as `file` tells them apart."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
    except OSError:
        return False
    if head[:4] in MACHO_THIN:
        return True
    return head[:4] in MACHO_FAT and len(head) == 8 and 0 < int.from_bytes(head[4:], "big") < 30


def bundle_kind(name: str) -> str:
    ext = os.path.splitext(name)[1].lstrip(".")
    return ext or "bundle"


def signed_items(bundle: str) -> dict:
    """The code items a first-exec check walks in BUNDLE: Mach-O files and sealed bundles (folders with a
    _CodeSignature), the app itself included. Symlinks are not followed or counted (Versions/Current)."""
    machos = 0
    kinds: dict[str, int] = {}
    root = os.path.abspath(bundle)
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(folder, d))]
        if "_CodeSignature" in dirs:
            # A framework seals Versions/A, an app Contents: the bundle is the folder named NAME.EXT above it.
            owner = folder
            while owner != root and not os.path.splitext(os.path.basename(owner))[1]:
                owner = os.path.dirname(owner)
            if os.path.basename(os.path.dirname(owner)) == "Versions":  # a version folder with a dot (C.1)
                owner = os.path.dirname(os.path.dirname(owner))
            kind = bundle_kind(os.path.basename(owner))
            kinds[kind] = kinds.get(kind, 0) + 1
        for name in files:
            path = os.path.join(folder, name)
            if not os.path.islink(path) and is_macho(path):
                machos += 1
    bundles = sum(kinds.values())
    return {"count": machos + bundles, "machos": machos, "bundles": bundles, "kinds": kinds}


def quarantine_value(now: float | None = None, agent: str = "Safari") -> str:
    """A `com.apple.quarantine` value as a browser download writes it: flags;hex seconds;agent;event UUID.
    0083 is the flags field Safari writes on a download the person has not opened yet."""
    stamp = int(time.time() if now is None else now)
    return f"0083;{stamp:08x};{agent};{str(uuid.uuid4()).upper()}"


def quarantine(bundle: str, value: str | None = None):
    """Set the quarantine xattr on every item of BUNDLE, as an unzip or a copy out of a downloaded DMG leaves it.
    The copy is made writable first (setxattr needs it; modes are not part of a signature)."""
    subprocess.run(["chmod", "-R", "u+w", bundle], check=True, timeout=300)
    subprocess.run(["xattr", "-r", "-w", "com.apple.quarantine", value or quarantine_value(), bundle],
                   check=True, timeout=300)


def translocation_root() -> str | None:
    """The folder macOS translocates a quarantined app into when it is opened where it lies:
    $(getconf DARWIN_USER_TEMP_DIR)AppTranslocation/."""
    out = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return os.path.join(os.path.realpath(out), "AppTranslocation") + "/" if out else None


def can_purge() -> bool:
    return subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True, timeout=180).returncode == 0


def make_writable_and_remove(path: str):
    subprocess.run(["chmod", "-R", "u+w", path], capture_output=True)
    shutil.rmtree(path, ignore_errors=True)


def translocated_bundle(name: str) -> str | None:
    """The translocated copy of the app named NAME (Zed.app) that is running now, or None."""
    import procs
    root = translocation_root()
    if not root:
        return None
    marker = "/" + name + "/Contents/MacOS/"
    for _pid, _ppid, cmd in procs.process_table():
        for path in (cmd, "/private" + cmd):
            if path.startswith(root) and marker in path:
                return path.split(marker, 1)[0] + "/" + name
    return None


# ---------------------------------------------------------------- one app


class App:
    def __init__(self, name: str, bundle: str, helper):
        self.name = name
        self.source = os.path.abspath(bundle)
        self.bundle = self.source
        self.helper = helper
        self.instance = None
        self.translocated = False  # quarantined launch: look for the app under AppTranslocation too

    def launch(self, profile: str, urls: list[str] | None = None):
        import procs
        home = os.path.join(profile, "home")
        tmp = os.path.join(profile, "tmp")
        os.makedirs(os.path.join(home, "Library"), exist_ok=True)
        os.makedirs(tmp, exist_ok=True)
        env = {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/"}
        args: list[str] = []
        if self.name == "cmux":
            config = os.path.join(profile, "cmux.json")
            if not os.path.exists(config):
                with open(config, "w") as handle:
                    json.dump({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, handle)
            env.update({"USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "CMUX_NEXT_CONFIG_FILE": config, "CMUX_MOCK_KEYCHAIN": "1", "CMUX_NEXT_NO_ACTIVATE": "1"})
        if self.name in CHROMIUM:
            args = [f"--user-data-dir={os.path.join(profile, 'data')}", "--password-store=basic", "--use-mock-keychain"]
        elif self.name in ELECTRON:
            # Chromium's switches reach an Electron app's own Chromium: a locked login keychain on a bench
            # host would otherwise hold the app at a keychain prompt.
            args = ["--password-store=basic", "--use-mock-keychain"]
        argv = ["open", "-n", "-g"]
        if self.name not in SYSTEM:
            argv += [x for k, v in env.items() for x in ("--env", f"{k}={v}")]
        argv += ["-a", self.bundle]
        if urls and self.name in SYSTEM:
            argv += list(urls)  # Safari opens each as a tab of one window
        elif urls:
            args = [*args, *urls]  # Chromium: each URL a tab, the first one in front
        if args:
            argv += ["--args", *args]
        subprocess.run(argv, check=True, timeout=60)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            pid = procs.main_pid(self.bundle)
            if not pid and self.translocated:
                moved = translocated_bundle(os.path.basename(self.bundle))
                if moved:
                    self.bundle = moved
                    pid = procs.main_pid(moved)
            if pid:
                self.instance = procs.Instance(self.bundle, pid)
                return
            time.sleep(0.02)  # bench: waiting for LaunchServices to start the app
        raise RuntimeError(f"{self.name}: no app process within 60 s")

    def quit(self):
        if self.instance:
            self.helper.run("terminate", str(self.instance.pid))
            self.instance.end(grace=15)
            self.instance = None

    def cpu_seconds(self) -> float:
        import procs
        total = 0
        for pid in self.instance.pids():
            got = procs.counters(pid)
            if got:
                total += got[1]
        return total / 1e9


class Run:
    def __init__(self, args):
        import xbench
        self.args = args
        self.out = os.path.abspath(args.out)
        os.makedirs(self.out, exist_ok=True)
        self.samples_path = os.path.join(self.out, "samples.jsonl")
        self.work = os.path.abspath(args.work)
        os.makedirs(self.work, exist_ok=True)
        self.helper = xbench.Helper(args.cache)
        self.xbench = xbench
        self.server = None
        self.signed_in = {}
        for item in args.signed_in:
            name, _, folder = item.partition("=")
            if not os.path.isdir(folder):
                raise SystemExit(f"--signed-in {item}: no such folder")
            self.signed_in[name] = os.path.abspath(folder)
        self.pressure = False

    def record(self, app: str, round_no: int, row: str, value, **extra):
        sample = {"browser": app, "round": round_no, "row": row,
                  "value": None if value is None else round(float(value), 3), "time": round(time.time()), **extra}
        with open(self.samples_path, "a") as handle:
            handle.write(json.dumps(sample) + "\n")
        log(f"{app} r{round_no} {row} = {sample['value']}" + (f" ({extra.get('note')})" if extra.get("note") else ""))

    def quiet(self) -> float:
        import procs
        deadline = time.monotonic() + self.args.quiet_wait
        while procs.load_average() > self.args.max_load and time.monotonic() < deadline:
            time.sleep(5)  # bench: waiting for a quiet machine
        return round(procs.load_average(), 2)

    def launch(self, app: App, round_no: int, kind: str, profile: str, urls: list[str] | None = None) -> bool:
        """One measured launch: window ms, then peak footprint and CPU over --after s. Leaves the app running."""
        load = self.quiet()
        prefixes = [os.path.join(os.path.realpath(app.bundle), "Contents/MacOS/")]
        if app.translocated and translocation_root():
            prefixes.append(translocation_root())  # only quarantined apps opened in place run from there
        watches = [self.helper.wait_window(prefix, 60) for prefix in prefixes]
        t0 = now_ms()
        try:
            app.launch(profile, urls)
            line = first_line(watches, 70)
            note = {} if line else {"note": "no window within 60 s"}
            if not line and kind == "quarantined":
                note = {"note": "no window within 60 s: the first-open prompt waits for a click "
                                "(needs a fleet Mac that approves it)"}
            if line and kind == "fresh" and app.name in SYSTEM:
                note = {"scope": "empty home only: a sealed system app has no new copy"}
            self.record(app.name, round_no, f"{kind}-window", float(line[0]) - t0 if line else None, load=load, **note)
            peak = 0.0
            per_kind = {}
            end = time.monotonic() + self.args.after
            while time.monotonic() < end:
                memory = app.instance.memory()
                if memory["mb"] >= peak:
                    peak, per_kind = memory["mb"], memory["kinds"]
                time.sleep(1)  # bench: sampling the launch's footprint
            self.record(app.name, round_no, f"{kind}-memory-peak", peak, kinds=per_kind)
            self.record(app.name, round_no, f"{kind}-cpu", app.cpu_seconds())
            return True
        except Exception as error:  # noqa: BLE001 - one failed launch is logged, the run goes on
            self.record(app.name, round_no, f"{kind}-window", None, note=f"error: {error}"[:300])
            return False
        finally:
            for watch in watches:
                if watch.poll() is None:
                    watch.kill()

    def soak(self, app: App, round_no: int, prefix: str = "soak"):
        a = self.args
        points = []
        cpu, wakeups, disk = [], [], []
        groups: list[dict] = []
        threads = processes = 0
        every = trough_every(a.soak, a.trough_every)
        pressure = every > 0 and self.pressure
        forced: list[tuple[float, float]] = []
        drops: list[float] = []
        next_trough = every
        began = time.monotonic()
        last_memory = last_window = detail_memory = None
        while time.monotonic() - began < a.soak:
            last_round = time.monotonic() - began + a.sample >= a.soak
            window = app.instance.window(a.sample, per_pid=last_round)
            memory = app.instance.memory(per_pid=last_round)
            points.append((time.monotonic() - began, memory["mb"]))
            groups.append(by_group(memory["kinds"], window["kinds"]))
            if last_round:
                last_window, detail_memory = window, memory
            cpu.append(window["cpu_pct"])
            wakeups.append(window["wakeups_per_s"])
            disk.append(window["disk_kb_per_s"])
            threads, processes, last_memory = window["threads"], window["processes"], memory
            if pressure and time.monotonic() - began >= next_trough:
                next_trough += every
                if memory_pressure("warn"):
                    app.instance.window(a.sample)  # the app's answer to the notice (GC, cache drops)
                    after = app.instance.memory()["mb"]
                    memory_pressure("normal")
                    forced.append((time.monotonic() - began, after))
                    drops.append(memory["mb"] - after)
                else:
                    pressure = False
        if not points:
            return
        settled = [p for p in points if p[0] >= a.settle_cut]
        self.record(app.name, round_no, f"{prefix}-memory-start", points[0][1])
        self.record(app.name, round_no, f"{prefix}-memory-end", points[-1][1], kinds=(last_memory or {}).get("kinds"))
        self.record(app.name, round_no, f"{prefix}-memory-peak", max(p[1] for p in points))
        self.record(app.name, round_no, f"{prefix}-memory-growth", slope_per_min(settled),
                    settle_cut=a.settle_cut, points=[[round(t), round(mb, 1)] for t, mb in points])
        self.record(app.name, round_no, f"{prefix}-memory-growth-all", slope_per_min(points))
        if every > 0:
            low = forced or troughs(settled, every)
            how = "forced: memory_pressure -S -l warn" if forced else "natural: lowest sample per bucket"
            self.record(app.name, round_no, f"{prefix}-memory-trough-growth", slope_per_min(low), how=how,
                        every=every, troughs=[[round(t), round(mb, 1)] for t, mb in low])
            self.record(app.name, round_no, f"{prefix}-memory-trough-last", low[-1][1] if low else None, how=how)
            if drops:
                self.record(app.name, round_no, f"{prefix}-memory-pressure-drop", statistics.fmean(drops))
        self.record(app.name, round_no, f"{prefix}-cpu", statistics.fmean(cpu))
        self.record(app.name, round_no, f"{prefix}-cpu-peak", max(cpu))
        self.record(app.name, round_no, f"{prefix}-wakeups", statistics.fmean(wakeups))
        self.record(app.name, round_no, f"{prefix}-disk", statistics.fmean(disk))
        self.record(app.name, round_no, f"{prefix}-threads", threads)
        self.record(app.name, round_no, f"{prefix}-processes", processes)
        for group in GROUPS:
            self.record(app.name, round_no, f"{prefix}-group-{group}-memory", groups[-1][group]["memory"])
            self.record(app.name, round_no, f"{prefix}-group-{group}-growth",
                        slope_per_min([(t, g[group]["memory"]) for (t, _mb), g in zip(points, groups)
                                       if t >= a.settle_cut]))
            self.record(app.name, round_no, f"{prefix}-group-{group}-cpu",
                        statistics.fmean(g[group]["cpu"] for g in groups))
            self.record(app.name, round_no, f"{prefix}-group-{group}-wakeups",
                        statistics.fmean(g[group]["wakeups"] for g in groups))
            self.record(app.name, round_no, f"{prefix}-group-{group}-processes", groups[-1][group]["processes"])
        # Every process of the last window: answers "what is each rival's GPU footprint" process by process.
        cpu_of = {row["pid"]: row for row in (last_window or {}).get("pids", [])}
        detail = [{**row, "group": group_of(row["kind"]), "cpu_pct": (cpu_of.get(row["pid"]) or {}).get("cpu_pct"),
                   "wakeups_per_s": (cpu_of.get(row["pid"]) or {}).get("wakeups_per_s")}
                  for row in (detail_memory or {}).get("pids", [])]
        self.record(app.name, round_no, f"{prefix}-detail", len(detail), pids=detail)

    def extra_pass(self, app: App, round_no: int, kind: str):
        """One more launch and idle soak after the signed-out session: signed-in (a copied profile) or tabs."""
        profile = os.path.join(self.work, "runs", f"{app.name}-r{round_no}-{kind}")
        make_writable_and_remove(profile)
        urls = None
        if kind == "signed-in":
            template = self.signed_in[app.name]
            shutil.copytree(template, profile, symlinks=True)
        else:
            os.makedirs(profile, exist_ok=True)
            if self.server is None:
                import pages
                self.server = pages.BeaconServer()
            urls = [self.server.url("idle", f"{app.name}-bg{i}") for i in range(self.args.tabs)]
        try:
            if self.launch(app, round_no, kind, profile, urls):
                self.soak(app, round_no, f"{kind}-soak")
        finally:
            app.quit()
            time.sleep(2)  # bench: the quit's last writes

    def session(self, app: App, round_no: int, purge: bool):
        copies = os.path.join(self.args.cache, "rivals-copies")
        copy_dir = os.path.join(copies, f"{app.name}-r{round_no}-{os.getpid()}")
        profile = os.path.join(self.work, "runs", f"{app.name}-r{round_no}")
        make_writable_and_remove(profile)
        try:
            if app.name in SYSTEM:
                app.bundle = app.source
            else:
                os.makedirs(copy_dir, exist_ok=True)
                app.bundle = os.path.join(copy_dir, os.path.basename(app.source))
                # cp -R, not ditto: the cache is read-only (chmod a-w), and ditto copies a directory's mode before
                # its contents, so it cannot write into Chrome's read-only framework folders ("Permission denied",
                # cmux-ci step ae86578f9527fb43dc8ffcb2). BSD cp makes each folder writable until its contents are in,
                # and keeps the extended attributes, so the signature still verifies.
                subprocess.run(["cp", "-R", app.source, app.bundle], check=True, timeout=900)
            if round_no == 1:
                self.record(app.name, round_no, "bundle-size", bundle_mb(app.bundle))
                items = signed_items(app.bundle)
                self.record(app.name, round_no, "signed-items", items["count"], machos=items["machos"],
                            bundles=items["bundles"], kinds=items["kinds"])
            if not self.launch(app, round_no, "fresh", profile):
                app.quit()
                return
            app.quit()
            time.sleep(3)  # sleep-ok: quit() already waited for exit; writes after exit (prefs, caches) have no signal
            if purge:
                subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True, timeout=180)
                self.launch(app, round_no, "restart", profile)
                app.quit()
                time.sleep(3)  # sleep-ok: quit() already waited for exit; writes after exit (prefs, caches) have no signal
            else:
                self.record(app.name, round_no, "restart-window", None, note="no passwordless sudo for purge")
            for index in range(self.args.warm):
                ok = self.launch(app, round_no, "warm", profile)
                if ok and index == self.args.warm - 1:
                    self.soak(app, round_no)
                app.quit()
                time.sleep(2)  # bench: the quit's last writes
            if app.name in self.signed_in:
                self.extra_pass(app, round_no, "signed-in")
            if self.args.tabs > 0 and app.name in BROWSERS:
                self.extra_pass(app, round_no, "tabs")
        finally:
            app.quit()
            if app.name not in SYSTEM:
                make_writable_and_remove(copy_dir)  # best effort: App Management may keep a launched copy
        if self.args.quarantined:
            self.quarantined(app, round_no)

    def quarantined(self, app: App, round_no: int):
        """RFD 0131 G: the first launch of a new copy that carries a browser download's quarantine."""
        if app.name in SYSTEM:
            self.record(app.name, round_no, "quarantined-window", None, note="a sealed system app is never downloaded")
            return
        copy_dir = os.path.join(self.args.cache, "rivals-copies", f"{app.name}-q{round_no}-{os.getpid()}")
        profile = os.path.join(self.work, "runs", f"{app.name}-q{round_no}")
        make_writable_and_remove(profile)
        try:
            os.makedirs(copy_dir, exist_ok=True)
            app.bundle = os.path.join(copy_dir, os.path.basename(app.source))
            subprocess.run(["cp", "-R", app.source, app.bundle], check=True, timeout=900)
            quarantine(app.bundle)
            app.translocated = True
            self.launch(app, round_no, "quarantined", profile)
        except Exception as error:  # noqa: BLE001 - the row is null with its reason, the run goes on
            self.record(app.name, round_no, "quarantined-window", None, note=f"error: {error}"[:300])
        finally:
            app.quit()
            app.translocated = False
            make_writable_and_remove(copy_dir)

    def main(self):
        a = self.args
        apps = dict(item.split("=", 1) for item in a.app)
        apps.setdefault("safari", "/Applications/Safari.app")
        if "rex" not in apps and os.path.isdir("/Applications/Rex.app"):
            apps["rex"] = "/Applications/Rex.app"  # Rex is a beta with no public download: the host's own copy
        names = [n for n in a.apps.split(",") if n]
        chosen = []
        for name in names:
            bundle = apps.get(name)
            if not bundle or not os.path.isdir(bundle):
                log(f"{name}: no bundle (--app {name}=PATH), skipped")
                self.record(name, 0, "fresh-window", None, note="no bundle on this host")
                continue
            chosen.append(App(name, bundle, self.helper))
        machine = self.xbench.Run.machine(self)
        purge = can_purge()
        self.pressure = trough_every(a.soak, a.trough_every) > 0 and memory_pressure("normal")
        meta = {"machine": machine, "cmux_ref": a.cmux_ref, "args": vars(a), "purge": purge,
                "pressure": self.pressure, "signed_in": sorted(self.signed_in),
                "apps": {app.name: {"name": LABELS.get(app.name, app.name), "bundle": app.source,
                                    "version": self.xbench.bundle_version(app.source),
                                    "team": self.xbench.team_id(app.source)} for app in chosen}}
        with open(os.path.join(self.out, "meta.json"), "w") as handle:
            json.dump(meta, handle, indent=1)
        log(f"machine {json.dumps(machine)}; purge {'yes' if purge else 'no (restart rows are null)'}")
        if not self.xbench.can_launch_apps():
            print("PERF-BENCH-NO-GUI: `open` cannot start an app here (needs a logged-in console user)", flush=True)
            sys.exit(3)
        caffeinate = subprocess.Popen(["caffeinate", "-dimsu"])
        try:
            order = list(chosen)
            for round_no in range(1, a.rounds + 1):
                order = order[1:] + order[:1] if round_no > 1 else order  # rotate each round
                for app in order:
                    log(f"{app.name} round {round_no}")
                    try:
                        self.session(app, round_no, purge)
                    except Exception as error:  # one app's failure costs its row, never the other apps' numbers
                        log(f"{app.name} round {round_no} failed: {error!r}")
                        self.record(app.name, round_no, "fresh-window", None, note=f"session failed: {error}"[:200])
        finally:
            caffeinate.terminate()


# ---------------------------------------------------------------- report


def aggregate(samples: list[dict]) -> dict:
    rows: dict[str, dict[str, dict]] = {}
    grouped: dict[tuple[str, str], list[float]] = {}
    for s in samples:
        if s.get("value") is not None and s.get("row") in UNITS:
            grouped.setdefault((s["row"], s["browser"]), []).append(s["value"])
    for (row, app), values in grouped.items():
        rows.setdefault(row, {})[app] = {"median": round(statistics.median(values), 3), "min": min(values),
                                         "max": max(values), "n": len(values)}
    return rows


def group_rows(rows: dict, prefix: str = "soak") -> list[str]:
    """The per-group row ids of the groups some app has a nonzero number in."""
    def used(group):
        return any(cell["median"] for m, _l, _u in GROUP_METRICS
                   for cell in rows.get(f"{prefix}-group-{group}-{m}", {}).values())
    return [f"{prefix}-group-{g}-{m}" for g in GROUPS if used(g) for m, _l, _u in GROUP_METRICS]


def pass_rows(rows: dict, prefix: str) -> list[str]:
    """A soak pass's row ids: every one for the signed-out soak, only the measured ones for the others."""
    ids = [f"{prefix}-{row}" for row, _l, _u, _s in SOAK_ROWS]
    optional = {f"{prefix}-{r}" for r in ("memory-growth-all", "memory-trough-growth", "memory-trough-last",
                                          "memory-pressure-drop")}
    return [i for i in ids if i in rows or (prefix == "soak" and i not in optional)]


def fmt(value, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "ms":
        return f"{value:,.0f}"
    if unit == "MB":
        return f"{value:,.0f}"
    if unit == "MB/min":  # RFD 0062's long bound is 0.02 MB/min: small slopes keep three places
        return f"{value:+.3f}" if abs(value) < 1 else f"{value:+.1f}"
    if unit in ("%", "/s", "s", "KB/s"):
        return f"{value:.2f}" if value < 10 else f"{value:.1f}"
    return f"{value:g}"


def ratio(cmux_value, other) -> str:
    if cmux_value is None or other is None or other == 0 or cmux_value == 0:
        return ""
    return f" (cmux {cmux_value / other:.1f}x more)" if cmux_value >= other else f" (cmux {other / cmux_value:.1f}x less)"


def first_line(watches: list, timeout: float) -> list[str]:
    """The first window line any of the wait-window helpers prints, split; [] if none does within TIMEOUT s."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        running = False
        for watch in watches:
            code = watch.poll()
            if code is None:
                running = True
            elif code == 0:
                return (watch.stdout.read() or "").split()
        if not running:
            return []
        time.sleep(0.005)  # bench: the helpers poll windows every 2 ms; this only collects their answer
    return []


def report(out: str, md_path: str | None, json_path: str | None) -> int:
    path = os.path.join(out, "samples.jsonl")
    samples = [json.loads(line) for line in open(path) if line.strip()] if os.path.exists(path) else []
    meta = json.load(open(os.path.join(out, "meta.json")))
    rows = aggregate(samples)
    errors = [{k: s.get(k) for k in ("browser", "round", "row", "note")} for s in samples
              if s.get("value") is None and s.get("note")]
    result = {"date": time.strftime("%Y-%m-%d"), "machine": meta["machine"], "cmux_ref": meta.get("cmux_ref"),
              "apps": meta["apps"], "purge": meta.get("purge"), "rows": rows, "errors": errors,
              "method": "scripts/perf-bench/rivals.py", "samples": samples}
    if json_path:
        with open(json_path, "w") as handle:
            json.dump(result, handle, indent=1)
    present = [a for a in ORDER if a in meta["apps"]] + sorted(a for a in meta["apps"] if a not in ORDER)
    m = meta["machine"]
    lines = [f"# rivals, {result['date']}: cmux NEXT against agent apps and browsers", "",
             f"{m.get('chip')} ({m.get('model')}), {m.get('cores')} cores, {m.get('ram_gb')} GB, macOS {m.get('macos')} "
             f"({m.get('build')}), host {m.get('host')}. cmux ref {meta.get('cmux_ref') or '?'}. "
             f"Rounds {meta['args'].get('rounds')}, warm launches {meta['args'].get('warm')}, after-launch window "
             f"{meta['args'].get('after')} s, idle soak {meta['args'].get('soak')} s in {meta['args'].get('sample')} s "
             f"windows. Purge before the restart launch: {'yes' if meta.get('purge') else 'no (no passwordless sudo)'}.",
             "", "| App | Version | Team |", "|---|---|---|"]
    for app in present:
        info = meta["apps"][app]
        lines.append(f"| {info['name']} | {info.get('version')} | {info.get('team')} |")
    lines.append("")
    sections = [
        ("Launch to window (ms, median [min–max]; in brackets, cmux against that app)",
         ["fresh-window", "restart-window", "warm-window"]),
        ("First launch of a quarantined download (--quarantined; the first-open prompt is in the number)",
         ["quarantined-window", "quarantined-cpu", "quarantined-memory-peak"]),
        ("What a launch costs (to window + the after-launch window)",
         ["fresh-cpu", "restart-cpu", "warm-cpu", "fresh-memory-peak", "restart-memory-peak", "warm-memory-peak"]),
        ("Idle: RAM ceiling and growth, CPU, wakeups", pass_rows(rows, "soak")),
        ("Idle by process group (RFD 0062: footprint at the soak's end, CPU and wakeups mean over the soak)",
         group_rows(rows)),
        ("Signed in: launch and idle (--signed-in)", [r for r in ("signed-in-window", "signed-in-cpu",
                                                               "signed-in-memory-peak") if r in rows]
         + pass_rows(rows, "signed-in-soak") + group_rows(rows, "signed-in-soak")),
        (f"Background tabs: {meta['args'].get('tabs') or 0} local idle pages, idle (--tabs)",
         [r for r in ("tabs-window", "tabs-cpu", "tabs-memory-peak") if r in rows]
         + pass_rows(rows, "tabs-soak") + group_rows(rows, "tabs-soak")),
        ("On disk", ["bundle-size", "signed-items"]),
    ]
    labels = {row: (label, unit) for row, label, unit, _summary in ROWS}
    for title, ids in sections:
        if not ids:
            continue
        lines += [f"## {title}", "", "| Row | " + " | ".join(LABELS.get(a, a) for a in present) + " |",
                  "|---|" + "---:|" * len(present)]
        for row in ids:
            label, unit = labels[row]
            per = rows.get(row, {})
            cmux_value = (per.get("cmux") or {}).get("median")
            cells = []
            for app in present:
                cell = per.get(app)
                if not cell:
                    cells.append("–")
                    continue
                spread = f" [{fmt(cell['min'], unit)}–{fmt(cell['max'], unit)}]" if cell["n"] > 1 else ""
                rel = "" if app == "cmux" or UNITS.get(row) == "MB/min" else ratio(cmux_value, cell["median"])
                cells.append(fmt(cell["median"], unit) + spread + rel)
            lines.append(f"| {label} ({unit}) | " + " | ".join(cells) + " |")
        lines.append("")
    if "safari" in meta["apps"] and rows.get("soak-processes", {}).get("safari"):
        webkit = [p for s in samples if s.get("browser") == "safari" and s.get("row") == "soak-detail"
                  for p in s.get("pids") or [] if str(p.get("kind", "")).startswith("webkit-")]
        lines += ["Safari's WebKit XPC processes (WebContent, GPU, Networking) counted: " +
                  (f"{len(webkit)} in the soak's last window." if webkit else
                   "NONE FOUND: Safari's rows miss its web content (responsibility lookup failed)."), ""]
    if errors:
        lines += ["## Not measured", ""]
        seen = set()
        for e in errors:
            key = (e["browser"], e["row"], e["note"])
            if key not in seen:
                seen.add(key)
                lines.append(f"- {LABELS.get(e['browser'], e['browser'])} {e['row']}: {e['note']}")
        lines.append("")
    lines += ["Method: scripts/perf-bench/rivals.py (docstring). Every app is signed out (its first screen) outside the Signed in rows.", ""]
    import growth_bounds
    lines += growth_bounds.lines(rows, "cmux", meta["args"].get("soak"))
    text = "\n".join(lines)
    if md_path:
        with open(md_path, "w") as handle:
            handle.write(text)
    print(text, flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--out", required=True)
    run.add_argument("--work", default="/private/tmp/rivals")
    # The account's own home, not the step's $HOME (fetch_browsers.py: a launched copy cannot be deleted).
    run.add_argument("--cache", default=os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/Caches/cmux-perf-bench"))
    run.add_argument("--app", action="append", default=[], help="NAME=BUNDLE")
    run.add_argument("--apps", default=",".join(ORDER), help="the apps to measure, in order")
    run.add_argument("--rounds", type=int, default=1)
    run.add_argument("--warm", type=int, default=3, help="warm relaunches per round (the last one soaks)")
    run.add_argument("--after", type=float, default=20, help="seconds sampled after each launch's window")
    run.add_argument("--soak", type=float, default=300, help="idle soak seconds after the last warm launch")
    run.add_argument("--sample", type=float, default=10, help="soak window seconds")
    run.add_argument("--settle-cut", type=float, default=90,
                     help="seconds of the soak's start left out of the growth slope (launch work settling)")
    run.add_argument("--trough-every", type=float, default=None,
                     help="trough reading period, s (default: none under a 30 min soak, else soak/12)")
    run.add_argument("--signed-in", action="append", default=[], metavar="NAME=DIR",
                     help="a signed-in profile folder for NAME (home/, data/): one more launch and soak from it")
    run.add_argument("--tabs", type=int, default=0, help="browsers: one more launch with N background tabs and soak")
    run.add_argument("--max-load", type=float, default=4)
    run.add_argument("--quiet-wait", type=float, default=120)
    run.add_argument("--cmux-ref", default=None)
    run.add_argument("--quarantined", action="store_true",
                     help="also a first launch of a quarantined copy (needs a Mac that approves the first-open prompt)")
    rep = sub.add_parser("report")
    rep.add_argument("--out", required=True)
    rep.add_argument("--md")
    rep.add_argument("--json")
    args = parser.parse_args()
    if args.command == "run":
        if platform.system() != "Darwin":
            raise SystemExit("rivals.py run: macOS only")
        Run(args).main()
        return 0
    return report(args.out, args.md, args.json)


if __name__ == "__main__":
    sys.exit(main())
