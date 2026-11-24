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

Per launch: ms from the open request to the first on-screen window >= 300x200 (benchhelper wait-window,
as xbench's launch-window), then every second for --after s the instance's physical footprint (its peak),
and the CPU seconds every process of the instance spent from its start to the end of that window.
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
That is what a person sees on a first launch, and the same for every app; signed-in sessions are a later row.

Usage (on a fleet Mac with a console user; scripts/measure/rivals.sh is the fleet entry):
  rivals.py run --out DIR --app NAME=BUNDLE ... [--rounds 1] [--warm 3] [--after 20] [--soak 300] [--sample 10]
  rivals.py report --out DIR [--md RIVALS.md] [--json results.json]

App names: cmux (cmux NEXT), claude, codex, t3code, rex, slack, chrome, edge, helium, safari; any other name is
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
    ("soak-memory-start", "Idle: footprint at start", "MB", True),
    ("soak-memory-end", "Idle: footprint at end", "MB", False),
    ("soak-memory-peak", "Idle: peak footprint (ceiling)", "MB", True),
    ("soak-memory-growth", "Idle: footprint growth", "MB/min", True),
    ("soak-cpu", "Idle: CPU, mean", "%", True),
    ("soak-cpu-peak", "Idle: CPU, peak window", "%", False),
    ("soak-wakeups", "Idle: wakeups, mean", "/s", True),
    ("soak-processes", "Idle: processes", "n", False),
    ("soak-threads", "Idle: threads", "n", False),
    ("soak-disk", "Idle: disk writes", "KB/s", False),
    ("bundle-size", "Bundle on disk", "MB", True),
]
UNITS = {row: unit for row, _label, unit, _summary in ROWS}
LABELS = {"cmux": "cmux NEXT", "claude": "Claude", "codex": "Codex", "t3code": "T3 Code", "rex": "Rex",
          "slack": "Slack", "chrome": "Chrome", "edge": "Microsoft Edge", "helium": "Helium", "safari": "Safari"}
ORDER = ["cmux", "rex", "claude", "codex", "t3code", "slack", "chrome", "edge", "helium", "safari"]
CHROMIUM = {"chrome", "edge", "helium"}
ELECTRON = {"claude", "codex", "t3code", "slack"}
SYSTEM = {"safari"}  # sealed system apps: no fresh copy
GROUPS = ["app", "renderer", "gpu", "acpmux", "terminals", "other"]
GROUP_LABELS = {"app": "app (shell + browser process, helpers, utility)", "renderer": "renderer", "gpu": "GPU",
                "acpmux": "acpmux", "terminals": "terminals (cmux-tui, holders, terminal hosts)", "other": "other"}
GROUP_METRICS = [("memory", "footprint, end", "MB"), ("cpu", "CPU, mean", "%"), ("wakeups", "wakeups, mean", "/s"),
                 ("processes", "processes", "n")]
for _group in GROUPS:
    for _metric, _label, _unit in GROUP_METRICS:
        ROWS.append((f"soak-group-{_group}-{_metric}", f"Idle {GROUP_LABELS[_group]}: {_label}", _unit, False))
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


def bundle_mb(bundle: str) -> float | None:
    out = subprocess.run(["du", "-sk", bundle], capture_output=True, text=True).stdout.split()
    return int(out[0]) / 1024 if out else None


def can_purge() -> bool:
    return subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True, timeout=180).returncode == 0


def make_writable_and_remove(path: str):
    subprocess.run(["chmod", "-R", "u+w", path], capture_output=True)
    shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------- one app


class App:
    def __init__(self, name: str, bundle: str, helper):
        self.name = name
        self.source = os.path.abspath(bundle)
        self.bundle = self.source
        self.helper = helper
        self.instance = None

    def launch(self, profile: str):
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
        if args:
            argv += ["--args", *args]
        subprocess.run(argv, check=True, timeout=60)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            pid = procs.main_pid(self.bundle)
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

    def launch(self, app: App, round_no: int, kind: str, profile: str) -> bool:
        """One measured launch: window ms, then peak footprint and CPU over --after s. Leaves the app running."""
        load = self.quiet()
        watch = self.helper.wait_window(os.path.join(os.path.realpath(app.bundle), "Contents/MacOS/"), 60)
        t0 = now_ms()
        try:
            app.launch(profile)
            line = (watch.communicate(timeout=70)[0] or "").split()
            note = {} if line else {"note": "no window within 60 s"}
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
            if watch.poll() is None:
                watch.kill()

    def soak(self, app: App, round_no: int):
        points = []
        cpu, wakeups, disk = [], [], []
        groups: list[dict] = []
        threads = processes = 0
        began = time.monotonic()
        last_memory = last_window = detail_memory = None
        while time.monotonic() - began < self.args.soak:
            last_round = time.monotonic() - began + self.args.sample >= self.args.soak
            window = app.instance.window(self.args.sample, per_pid=last_round)
            memory = app.instance.memory(per_pid=last_round)
            groups.append(by_group(memory["kinds"], window["kinds"]))
            if last_round:
                last_window, detail_memory = window, memory
            points.append((time.monotonic() - began, memory["mb"]))
            cpu.append(window["cpu_pct"])
            wakeups.append(window["wakeups_per_s"])
            disk.append(window["disk_kb_per_s"])
            threads, processes, last_memory = window["threads"], window["processes"], memory
        if not points:
            return
        self.record(app.name, round_no, "soak-memory-start", points[0][1])
        self.record(app.name, round_no, "soak-memory-end", points[-1][1], kinds=(last_memory or {}).get("kinds"))
        self.record(app.name, round_no, "soak-memory-peak", max(p[1] for p in points))
        self.record(app.name, round_no, "soak-memory-growth", slope_per_min(points),
                    points=[[round(t), round(mb, 1)] for t, mb in points])
        self.record(app.name, round_no, "soak-cpu", statistics.fmean(cpu))
        self.record(app.name, round_no, "soak-cpu-peak", max(cpu))
        self.record(app.name, round_no, "soak-wakeups", statistics.fmean(wakeups))
        self.record(app.name, round_no, "soak-disk", statistics.fmean(disk))
        self.record(app.name, round_no, "soak-threads", threads)
        self.record(app.name, round_no, "soak-processes", processes)
        for group in GROUPS:
            self.record(app.name, round_no, f"soak-group-{group}-memory", groups[-1][group]["memory"])
            self.record(app.name, round_no, f"soak-group-{group}-cpu", statistics.fmean(g[group]["cpu"] for g in groups))
            self.record(app.name, round_no, f"soak-group-{group}-wakeups",
                        statistics.fmean(g[group]["wakeups"] for g in groups))
            self.record(app.name, round_no, f"soak-group-{group}-processes", groups[-1][group]["processes"])
        # Every process of the last window: answers "what is each rival's GPU footprint" process by process.
        cpu_of = {row["pid"]: row for row in (last_window or {}).get("pids", [])}
        detail = [{**row, "group": group_of(row["kind"]), "cpu_pct": (cpu_of.get(row["pid"]) or {}).get("cpu_pct"),
                   "wakeups_per_s": (cpu_of.get(row["pid"]) or {}).get("wakeups_per_s")}
                  for row in (detail_memory or {}).get("pids", [])]
        self.record(app.name, round_no, "soak-detail", len(detail), pids=detail)

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
        finally:
            app.quit()
            if app.name not in SYSTEM:
                make_writable_and_remove(copy_dir)  # best effort: App Management may keep a launched copy

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
        meta = {"machine": machine, "cmux_ref": a.cmux_ref, "args": vars(a), "purge": purge,
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


def group_rows(rows: dict) -> list[str]:
    """The per-group row ids of the groups some app has a nonzero number in."""
    def used(group):
        return any(cell["median"] for m, _l, _u in GROUP_METRICS
                   for cell in rows.get(f"soak-group-{group}-{m}", {}).values())
    return [f"soak-group-{g}-{m}" for g in GROUPS if used(g) for m, _l, _u in GROUP_METRICS]


def fmt(value, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "ms":
        return f"{value:,.0f}"
    if unit == "MB":
        return f"{value:,.0f}"
    if unit == "MB/min":
        return f"{value:+.1f}"
    if unit in ("%", "/s", "s", "KB/s"):
        return f"{value:.2f}" if value < 10 else f"{value:.1f}"
    return f"{value:g}"


def ratio(cmux_value, other) -> str:
    if cmux_value is None or other is None or other == 0 or cmux_value == 0:
        return ""
    return f" (cmux {cmux_value / other:.1f}x more)" if cmux_value >= other else f" (cmux {other / cmux_value:.1f}x less)"


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
        ("What a launch costs (to window + the after-launch window)",
         ["fresh-cpu", "restart-cpu", "warm-cpu", "fresh-memory-peak", "restart-memory-peak", "warm-memory-peak"]),
        ("Idle: RAM ceiling and growth, CPU, wakeups",
         ["soak-memory-start", "soak-memory-end", "soak-memory-peak", "soak-memory-growth", "soak-cpu",
          "soak-cpu-peak", "soak-wakeups", "soak-disk", "soak-processes", "soak-threads"]),
        ("Idle by process group (RFD 0062: footprint at the soak's end, CPU and wakeups mean over the soak)",
         group_rows(rows)),
        ("On disk", ["bundle-size"]),
    ]
    labels = {row: (label, unit) for row, label, unit, _summary in ROWS}
    for title, ids in sections:
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
                rel = "" if app == "cmux" or row == "soak-memory-growth" else ratio(cmux_value, cell["median"])
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
    lines += ["Method: scripts/perf-bench/rivals.py (docstring). Every app is signed out: its first screen.", ""]
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
    run.add_argument("--max-load", type=float, default=4)
    run.add_argument("--quiet-wait", type=float, default=120)
    run.add_argument("--cmux-ref", default=None)
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
