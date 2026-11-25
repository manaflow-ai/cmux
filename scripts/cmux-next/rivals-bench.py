#!/usr/bin/env python3
"""rivals-bench: cmux NEXT head to head with Claude Code desktop, the Codex app and T3 Code, one harness, one Mac.

Leo, 2026-11-25: "the app speed on idle and on load we need to be better tho i recall us not being as good as
claude code desktop. idk where we stand compared to codex or t3 code and where our "speed of light" optimizations
stand we need to be working on those"

Each app is the vendor's public release (scripts/perf-bench/fetch_browsers.py downloads it into the bench cache;
nothing of theirs is copied into this repo), run as a person runs it: a copy of the bundle, an empty home, signed out.
Per app, --repeats rounds (default 10), each round:

  cold    quit everything, `sudo -n purge` (dropped file cache, the nearest a step gets to a reboot; without
          passwordless sudo the row says so), `open` the app: ms to the first window, and ms to interactive
          (Accessibility: a window and a focused text input, scripts/cmux-next/rivals-ax.swift; generic, the same
          probe for every app), both from the clock just before `open`.
  idle    the same launch, left alone --settle s, then a --idle s window over the app's whole process tree
          (main, helpers, renderers, GPU, utilities): CPU % of one core, wakeups/s, energy (mW from the kernel's
          per-process billed energy, and `powermetrics --samplers tasks` energy impact when passwordless sudo
          allows), and phys_footprint of the tree at the window's end (what `RSS` means here).
  warm    quit, `open` again at once: window and interactive ms.

Output JSON (schema cmux-rivals-bench/v1): host, chip, macOS, app versions, and per app per metric the samples,
p50 and p95; metrics a rival cannot be driven for without an account are {"n/a": "<reason>"}, never a guess.
With --long the 1 h idle with 10 chats open variant runs for cmux (rivals: n/a, no offline chats).
Screen recording (`screencapture -v -V`) of the first round of each test goes to OUT/recordings/ when the Mac
grants Screen Recording; otherwise the JSON says so.

Usage (scripts/measure/rivals-bench.sh is the fleet entry; any Mac with a console user works):
  rivals-bench.py --out DIR [--apps cmux,claude,codex,t3code] [--repeats 10] [--idle 60] [--settle 15] [--long]
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import pwd
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PERF = os.path.join(HERE, "..", "perf-bench")
sys.path.insert(0, PERF)

SCHEMA = "cmux-rivals-bench/v1"
LABELS = {"cmux": "cmux NIGHTLY", "claude": "Claude Code desktop", "codex": "Codex app", "t3code": "T3 Code"}
FETCH = {"cmux": "cmux-nightly"}

LAUNCH_METRICS = ["cold_window_ms", "cold_interactive_ms", "warm_window_ms", "warm_interactive_ms"]
IDLE_METRICS = ["idle_cpu_pct", "idle_wakeups_per_s", "idle_energy_mw", "idle_energy_impact", "idle_rss_mb",
                "idle_processes"]

NO_LOGIN = ("needs a signed-in account to reach a chat; no documented offline/base-URL path was driven in this "
            "version, and nothing is faked")
RIVAL_REASONS = {
    "claude": "Claude desktop reaches a chat only after an Anthropic login (the Code tab's ANTHROPIC_BASE_URL is "
              "read from the signed-in session's environment); " + "no offline model path",
    "codex": "Codex app reaches a chat only after a ChatGPT/OpenAI login; its codex engine reads model_providers "
             "base_url from config.toml, but the app's login gate is not bypassed by it",
    "t3code": "T3 Code drives the local codex/claude CLIs (needs their login or a mock provider configured in "
              "those CLIs); a mock provider is not wired in this version",
}
CHAT_METRICS = ["chat_open_long_transcript_ms", "keystroke_to_glyph_ms", "stream_high_rate_dropped_frames",
                "scroll_5000_messages_dropped_frames", "eight_agents_streaming_dropped_frames"]
CMUX_CHAT_POINTERS = {
    "chat_open_long_transcript_ms": "scripts/measure/chat-open.sh (chat-open-bench.py, case big)",
    "keystroke_to_glyph_ms": "scripts/cmux-next/typing-frame-bench.py",
    "stream_high_rate_dropped_frames": "webviews scripts/chat-sim.ts --long N with scripts/measure/stress.sh",
    "scroll_5000_messages_dropped_frames": "webviews scripts/chat-sim.ts --long 5000, scripts/cmux-next/stress-bench.py",
    "eight_agents_streaming_dropped_frames": "scripts/cmux-next/stress-bench.py (8 streams)",
}


def log(message: str):
    print(f"[rivals-bench {time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def percentile(values: list[float], q: float):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * q
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def summarize(samples: list, unit: str, notes: list | None = None) -> dict:
    nums = [float(v) for v in samples if v is not None]
    row = {"unit": unit, "n": len(nums), "samples": [None if v is None else round(float(v), 3) for v in samples],
           "p50": None if not nums else round(percentile(nums, 0.5), 3),
           "p95": None if not nums else round(percentile(nums, 0.95), 3)}
    if notes:
        row["notes"] = sorted(set(notes))
    return row


def sh(*argv: str, timeout: float = 60) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def host_info() -> dict:
    return {"host": sh("scutil", "--get", "ComputerName") or sh("hostname"),
            "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
            "macos": sh("sw_vers", "-productVersion"), "macos_build": sh("sw_vers", "-buildVersion"),
            "cores": sh("sysctl", "-n", "hw.ncpu"), "memory_gb": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30),
            "load": sh("sysctl", "-n", "vm.loadavg")}


def bundle_version(bundle: str) -> str:
    try:
        with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        return f"{info.get('CFBundleShortVersionString', '?')} ({info.get('CFBundleVersion', '?')})"
    except Exception:  # noqa: BLE001
        return "unknown"


def sudo_ok(*argv: str) -> bool:
    try:
        return subprocess.run(["sudo", "-n", *argv], capture_output=True, timeout=120).returncode == 0
    except Exception:  # noqa: BLE001
        return False


class Recorder:
    """screencapture -v -V SECONDS, started in the background; a failure is a note, never a failed test."""

    def __init__(self, folder: str):
        self.folder = os.path.join(folder, "recordings")
        os.makedirs(self.folder, exist_ok=True)
        self.status = "untried"

    def start(self, name: str, seconds: float):
        path = os.path.join(self.folder, f"{name}.mov")
        try:
            proc = subprocess.Popen(["screencapture", "-v", "-x", "-V", str(int(seconds) + 1), path],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            return proc, path
        except Exception as error:  # noqa: BLE001
            self.status = f"screencapture failed to start: {error}"
            return None, path

    def finish(self, handle):
        proc, path = handle
        if proc is None:
            return None
        try:
            _, err = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            err = "timeout"
        if os.path.exists(path) and os.path.getsize(path) > 1024:
            self.status = "recorded"
            return os.path.relpath(path, os.path.dirname(self.folder))
        self.status = f"no recording: {(err or 'empty file')[:160].strip()}"
        return None


class AX:
    def __init__(self, cache: str):
        source = os.path.join(HERE, "rivals-ax.swift")
        self.path = os.path.join(cache, "rivals-ax")
        self.error = None
        try:
            os.makedirs(cache, exist_ok=True)
            subprocess.run(["xcrun", "swiftc", "-O", "-o", self.path, source], check=True, timeout=600,
                           capture_output=True)
        except Exception as error:  # noqa: BLE001
            self.error = f"rivals-ax did not compile: {error}"

    def watch(self, pid: int, timeout: float):
        if self.error:
            return None
        return subprocess.Popen([self.path, str(pid), str(timeout)], stdout=subprocess.PIPE, text=True)


class Bench:
    def __init__(self, args):
        import rivals
        import xbench
        self.args = args
        self.rivals = rivals
        self.xbench = xbench
        self.out = os.path.abspath(args.out)
        os.makedirs(self.out, exist_ok=True)
        self.cache = args.cache
        self.helper = xbench.Helper(self.cache)
        self.ax = AX(self.cache)
        self.recorder = Recorder(self.out) if args.record else None
        self.purge = sudo_ok("/usr/sbin/purge")
        self.powermetrics = sudo_ok("/usr/bin/powermetrics", "--samplers", "tasks", "-i", "100", "-n", "1")
        self.work = os.path.abspath(args.work)
        os.makedirs(self.work, exist_ok=True)
        self.ax_trusted = None
        self.results: dict = {}
        self.notes: dict = {}

    # --- one launch
    def launch(self, app, profile: str, record_name: str | None = None):
        """Open the app; (window_ms, interactive_ms, note). Leaves the app running."""
        prefix = os.path.join(os.path.realpath(app.bundle), "Contents/MacOS/")
        watch = self.helper.wait_window(prefix, 60)
        recording = self.recorder.start(record_name, 12) if self.recorder and record_name else None
        note = None
        t0 = time.time() * 1000
        try:
            app.launch(profile)
            ax = self.ax.watch(app.instance.pid, 45)
            line = self.rivals.first_line([watch], 70)
            window_ms = float(line[0]) - t0 if line else None
            interactive = None
            if ax is None:
                note = self.ax.error
            else:
                try:
                    out, _ = ax.communicate(timeout=60)
                    got = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
                except Exception as error:  # noqa: BLE001
                    got = {}
                    note = f"ax probe failed: {error}"
                if got.get("trusted") is False:
                    note = "n/a: Accessibility not granted to the bench process (no focused-field timing)"
                    self.ax_trusted = False
                elif got.get("field_ms") is not None:
                    interactive = float(got["field_ms"]) - t0
                    self.ax_trusted = True
                elif got:
                    note = "no focused text field within 45 s (window only)"
                    self.ax_trusted = True
                    if window_ms is None and got.get("window_ms") is not None:
                        window_ms = float(got["window_ms"]) - t0
            return window_ms, interactive, note
        finally:
            if watch.poll() is None:
                watch.kill()
            if recording:
                self.recorder.finish(recording)

    def quit(self, app):
        app.quit()
        time.sleep(3)  # sleep-ok: quit() waited for exit; late writes have no signal

    def idle_window(self, app, record_name: str | None):
        """settle, then the idle window over the whole tree. Returns a dict of metrics."""
        a = self.args
        time.sleep(a.settle)  # sleep-ok: launch work settles; the window below is the measurement
        recording = self.recorder.start(record_name, min(a.idle, 15)) if self.recorder and record_name else None
        pm = None
        pm_path = os.path.join(self.work, f"pm-{app.name}-{os.getpid()}.plist")
        pids = set(app.instance.pids())
        if self.powermetrics:
            pm = subprocess.Popen(["sudo", "-n", "/usr/bin/powermetrics", "--samplers", "tasks", "-f", "plist",
                                   "-i", str(int(a.idle * 1000)), "-n", "1", "-o", pm_path],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        window = app.instance.window(a.idle)
        memory = app.instance.memory(per_pid=True)
        pids |= set(app.instance.pids())
        out = {"idle_cpu_pct": window["cpu_pct"], "idle_wakeups_per_s": window["wakeups_per_s"],
               "idle_energy_mw": window["mw"], "idle_rss_mb": memory["mb"],
               "idle_processes": window["processes"], "kinds": memory["kinds"]}
        if pm is not None:
            try:
                pm.wait(timeout=30)
                out["idle_energy_impact"] = energy_impact(pm_path, pids)
            except Exception:  # noqa: BLE001
                out["idle_energy_impact"] = None
        if recording:
            self.recorder.finish(recording)
        return out

    def app_rounds(self, name: str, bundle: str):
        a = self.args
        app = self.rivals.App(name, bundle, self.helper)
        copy_dir = os.path.join(self.cache, "rivals-bench-copies", f"{name}-{os.getpid()}")
        metrics = {m: [] for m in LAUNCH_METRICS + IDLE_METRICS}
        notes: dict[str, list] = {m: [] for m in metrics}
        kinds_last: dict = {}
        recordings: dict = {}
        profile = os.path.join(self.work, "profiles", name)
        self.rivals.make_writable_and_remove(profile)
        os.makedirs(copy_dir, exist_ok=True)
        app.bundle = os.path.join(copy_dir, os.path.basename(bundle))
        subprocess.run(["cp", "-R", bundle, app.bundle], check=True, timeout=900)
        try:
            for index in range(a.repeats):
                first = index == 0
                log(f"{name} round {index + 1}/{a.repeats}")
                try:
                    if self.purge:
                        sub = subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True, timeout=180)
                        purged = sub.returncode == 0
                    else:
                        purged = False
                    w, i, note = self.launch(app, profile, f"{name}-cold-launch" if first else None)
                    metrics["cold_window_ms"].append(w)
                    metrics["cold_interactive_ms"].append(i)
                    if note:
                        notes["cold_interactive_ms"].append(note)
                    if not purged:
                        notes["cold_window_ms"].append("no passwordless sudo for purge: cold = quit, not purged")
                    idle = self.idle_window(app, f"{name}-idle" if first else None)
                    for key in IDLE_METRICS:
                        metrics[key].append(idle.get(key))
                    kinds_last = idle.get("kinds", {})
                    if not self.powermetrics:
                        notes["idle_energy_impact"].append("n/a: no passwordless sudo for powermetrics")
                    self.quit(app)
                    w, i, note = self.launch(app, profile, f"{name}-warm-launch" if first else None)
                    metrics["warm_window_ms"].append(w)
                    metrics["warm_interactive_ms"].append(i)
                    if note:
                        notes["warm_interactive_ms"].append(note)
                except Exception as error:  # noqa: BLE001 - one failed round is a gap, not a failed run
                    log(f"{name} round {index + 1} failed: {error!r}")
                    for m in metrics:
                        notes[m].append(f"round failed: {error}"[:160])
                finally:
                    self.quit(app)
        finally:
            app.quit()
            self.rivals.make_writable_and_remove(copy_dir)
        units = {"idle_cpu_pct": "%", "idle_wakeups_per_s": "1/s", "idle_energy_mw": "mW", "idle_energy_impact": "pts",
                 "idle_rss_mb": "MB", "idle_processes": "n"}
        rows = {m: summarize(v, units.get(m, "ms"), notes[m]) for m, v in metrics.items()}
        for m, row in rows.items():
            if row["n"] == 0 and row.get("notes"):
                rows[m] = {"n/a": "; ".join(row["notes"])[:300], "n": 0}
        rows["idle_rss_by_kind_mb_last_round"] = kinds_last
        return rows

    def long_idle(self, name: str, bundle: str):
        return {"n/a": "--long variant (1 h idle, 10 chats open) is a cmux-only run: needs 10 chats, which a "
                       "signed-out rival cannot open" if name != "cmux" else
                "--long: 10 chats are opened with the app's own debug/chat-sim hooks; not yet wired in this version"}

    def main(self):
        a = self.args
        helper_names = [n for n in a.apps.split(",") if n]
        bundles = dict(item.split("=", 1) for item in a.app)
        want = [FETCH.get(n, n) for n in helper_names if n not in bundles]
        if want:
            out = subprocess.run([sys.executable, os.path.join(PERF, "fetch_browsers.py"), *want],
                                 capture_output=True, text=True, timeout=3600)
            sys.stderr.write(out.stderr)
            for line in out.stdout.splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    bundles["cmux" if key == "cmux-nightly" else key] = value
        meta = {"schema": SCHEMA, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **host_info(),
                "args": {k: v for k, v in vars(a).items()}, "purge": self.purge,
                "powermetrics": self.powermetrics, "cmux_ref": a.cmux_ref}
        apps: dict = {}
        log(f"{json.dumps(meta)}")
        if not self.xbench.can_launch_apps():
            print("RIVALS-BENCH-NO-GUI: `open` cannot start an app here (needs a logged-in console user)")
            sys.exit(3)
        caffeinate = subprocess.Popen(["caffeinate", "-dimsu"])
        try:
            for name in helper_names:
                bundle = bundles.get(name)
                entry: dict = {"label": LABELS.get(name, name)}
                apps[name] = entry
                if not bundle or not os.path.isdir(bundle):
                    entry["n/a"] = "app unavailable on this host (download failed or no arm64 slice)"
                    continue
                entry["version"] = bundle_version(bundle)
                entry["bundle"] = bundle
                entry["metrics"] = self.app_rounds(name, bundle)
                entry["metrics"]["idle_1h_10_chats"] = (self.long_idle(name, bundle) if a.long else
                                                         {"n/a": "behind --long"})
                chat = {}
                for metric in CHAT_METRICS:
                    if name == "cmux":
                        chat[metric] = {"n/a": "measured by its own bench, not this entry: " + CMUX_CHAT_POINTERS[metric]}
                    else:
                        chat[metric] = {"n/a": RIVAL_REASONS.get(name, NO_LOGIN)}
                entry["metrics"].update(chat)
                self.write(meta, apps)
        finally:
            caffeinate.terminate()
        meta["ax_trusted"] = self.ax_trusted
        meta["recording"] = self.recorder.status if self.recorder else "off"
        self.write(meta, apps)
        print(table(apps))

    def write(self, meta, apps):
        meta = {**meta, "ax_trusted": self.ax_trusted, "recording": self.recorder.status if self.recorder else "off"}
        with open(os.path.join(self.out, "results.json"), "w") as handle:
            json.dump({**meta, "apps": apps}, handle, indent=1)
        with open(os.path.join(self.out, "RIVALS-BENCH.md"), "w") as handle:
            handle.write(table(apps) + "\n")


def energy_impact(path: str, pids: set[int]):
    """Sum of powermetrics' per-task energy_impact over the app's process tree (plist from --samplers tasks)."""
    with open(path, "rb") as handle:
        raw = handle.read()
    # powermetrics writes NUL-separated plists, one per sample
    doc = plistlib.loads(raw.split(b"\x00")[0].strip())
    total = 0.0
    found = False
    for task in doc.get("tasks", []):
        if int(task.get("pid", -1)) in pids:
            total += float(task.get("energy_impact", 0.0))
            found = True
    return round(total, 3) if found else None


def table(apps: dict) -> str:
    names = [n for n, e in apps.items() if "metrics" in e]
    lines = ["| metric | " + " | ".join(f"{apps[n]['label']} p50 / p95" for n in names) + " |",
             "|---|" + "---|" * len(names)]
    keys = LAUNCH_METRICS + IDLE_METRICS
    for key in keys:
        cells = []
        for n in names:
            row = apps[n]["metrics"].get(key, {})
            cells.append("n/a" if row.get("p50") is None else f"{row['p50']} / {row['p95']} {row.get('unit', '')}")
        lines.append(f"| {key} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--work", default="/private/tmp/rivals-bench")
    parser.add_argument("--cache", default=os.path.join(pwd.getpwuid(os.getuid()).pw_dir,
                                                          "Library/Caches/cmux-perf-bench"))
    parser.add_argument("--apps", default="cmux,claude,codex,t3code")
    parser.add_argument("--app", action="append", default=[], help="NAME=BUNDLE (skips the download)")
    parser.add_argument("--repeats", type=int, default=10)
    parser.add_argument("--idle", type=float, default=60, help="idle window seconds")
    parser.add_argument("--settle", type=float, default=15, help="seconds after the window before the idle window")
    parser.add_argument("--long", action="store_true", help="the 1 h idle with 10 chats open variant")
    parser.add_argument("--no-record", dest="record", action="store_false")
    parser.add_argument("--cmux-ref", default=None)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("rivals-bench.py: macOS only")
    Bench(args).main()


if __name__ == "__main__":
    main()
