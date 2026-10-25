#!/usr/bin/env python3
"""Whether this Mac may measure now, and its host fingerprint and class.

Runs before every lab job (perf-lab.sh) and try job. An invalid host refuses with `env-invalid` and stores nothing.
Chrome's lab gates a device the same way before it runs a story: catapult devil/android/tools/device_status.py
takes an unhealthy device out of the pool and devil/android/perf/thermal_throttle.py refuses a throttled one.

Checks (each failing one adds its own reason code; a probe that cannot be read fails closed with `<check>-unreadable`):
- `thermal-limit`: `pmset -g therm` CPU_Speed_Limit is not 100.
- `system-sleep`, `low-power-mode`: `pmset -g` sleep and lowpowermode are not 0.
- `load-high`: `sysctl -n vm.loadavg` 1-minute load stays >= 1.0 for LOAD_WAIT_S.
- `memory-low`: `vm_stat` free + inactive pages <= MIN_FREE_INACTIVE_BYTES.
- `spotlight-on`: `mdutil -s` says the data volume is indexed.
- `no-gui-session`: the console user (scutil State:/Users/ConsoleUser) is not the bench user. The same rule as
  scripts/cmux-next/bench_launch.py console_user and hq build-fleet console_session.go.
- `other-cmux-app`: a cmux app bundle's executable runs that is not one of the job's own pids.
- `network-egress`: in one NETTOP_WINDOW_S nettop session, an app or daemon pid has a connection to a non-loopback
  address. Checked only when the job passes those pids.
- `vdisplay-not-ready`, `refresh-below-60`: the vdisplay `ready ID P50_MS ...` (or `probe`'s `main ID P50_MS`) line
  is missing or ticks slower than 60 Hz. A display that cannot hold 8.33 ms is hz=60, not a refusal: its frame-target
  stories are skipped (p12-perf-process-160).
- `host-unknown`: chip, memory or macOS build could not be read.

fingerprint = sha256(chip, macOS build, Hz, memory), class = store.host_class (chip + memory + Hz, no macOS build),
the same formula as bench_launch.host_record, so an OS update is a step inside one series.

    python3 -I scripts/perf-lab/host_env.py --vdisplay-out OUT/vdisplay.out [--pid APP --pid DAEMON]
                                              [--bench-user NAME]

Prints one `HOST-ENV {json}` line; exit 0 when the host is valid, 3 when it refuses (env-invalid).
Stdlib only, loaded by file path; tests inject the command runner and the clock.
"""
import argparse
import dataclasses
import hashlib
import importlib.util
import ipaddress
import json
import os
import pwd
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

MIN_FREE_INACTIVE_BYTES = 8 * 2**30
MAX_LOAD_1MIN = 1.0
LOAD_WAIT_S = 30.0
LOAD_POLL_S = 5.0
NETTOP_WINDOW_S = 60
NETTOP_GRACE_S = 15.0
COMMAND_TIMEOUT_S = 10.0
FRAME_120_MS = 1000.0 / 120
FRAME_60_MS = 1000.0 / 60
# CVDisplayLink's p50 interval may sit a little above the nominal frame; past 5 % the host does not hold the rate.
FRAME_TOLERANCE = 1.05
SPOTLIGHT_VOLUME = "/System/Volumes/Data"
EXIT_ENV_INVALID = 3


@dataclasses.dataclass(frozen=True)
class CommandResult:
    stdout: str
    returncode: int


class Commands:
    """Runs a probe command. None when it could not run or timed out."""

    def run(self, argv, timeout=COMMAND_TIMEOUT_S, stdin=None):
        try:
            done = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return CommandResult(done.stdout, done.returncode)


class Clock:
    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


def load_store():
    name = "perf_lab_store"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "store.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


# Parsers: canned text in, value out (None when the text does not say).

def parse_speed_limit(text):
    """CPU_Speed_Limit from `pmset -g therm`. Apple silicon prints no CPU power block until it throttles, only
    "No CPU power status has been recorded": that is 100."""
    match = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", text)
    if match:
        return int(match.group(1))
    return 100 if "No CPU power status has been recorded" in text else None


def parse_pmset_settings(text):
    """{key: first value} of the `pmset -g` setting rows (`sleep 0 (sleep prevented by ...)` -> sleep: "0")."""
    settings = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and line.startswith(" "):
            settings.setdefault(parts[0], parts[1])
    return settings


def parse_load_1min(text):
    match = re.match(r"\s*\{?\s*([0-9.]+)", text)
    return float(match.group(1)) if match else None


def parse_free_inactive_bytes(text):
    page = re.search(r"page size of (\d+) bytes", text)
    free = re.search(r"^Pages free:\s+(\d+)\.", text, re.M)
    inactive = re.search(r"^Pages inactive:\s+(\d+)\.", text, re.M)
    if not (page and free and inactive):
        return None
    return (int(free.group(1)) + int(inactive.group(1))) * int(page.group(1))


def parse_indexing(text):
    """True when `mdutil -s` says indexing is on, False when off, None when it says neither."""
    if re.search(r"Indexing (and searching )?disabled", text):
        return False
    if "Indexing enabled" in text:
        return True
    return None


def parse_console_user(text):
    """`Name` of State:/Users/ConsoleUser; None at the login window or with no answer (fail closed)."""
    match = re.search(r"^\s*Name : (\S+)", text, re.M)
    if not match or match.group(1) == "loginwindow":
        return None
    return match.group(1)


CMUX_APP_EXECUTABLE = re.compile(r"/[^/]*cmux[^/]*\.app/Contents/MacOS/[^/]+$", re.I)


def parse_cmux_apps(text):
    """[(pid, path)] of `ps -axww -o pid=,comm=` rows that are a cmux bundle's own executable. A helper app nested
    inside another bundle is that bundle's process, so only the outermost `.app` counts."""
    apps = []
    for line in text.splitlines():
        match = re.match(r"\s*(\d+)\s+(.+?)\s*$", line)
        if not match:
            continue
        path = match.group(2)
        if path.count(".app/") == 1 and CMUX_APP_EXECUTABLE.search(path):
            apps.append((int(match.group(1)), path))
    return apps


NETTOP_PROCESS = re.compile(r"^(.*)\.(\d+)$")
NETTOP_FLOW = re.compile(r"^(tcp|udp)[46]? (\S+)<->(\S+)$")


def remote_host(endpoint):
    """The address of a nettop endpoint (`17.57.146.20:5223`, `fe80::1%en0.5223`); None for `*:*`."""
    if endpoint.startswith("*"):
        return None
    if endpoint.count(":") == 1:
        host = endpoint.rsplit(":", 1)[0]
    else:
        host = endpoint.rsplit(".", 1)[0]
    return host.split("%", 1)[0]


def is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False  # not an address (a name): counted as egress


def parse_egress(text, pids):
    """[(pid, flow)] of nettop -L rows that connect one of `pids` to a non-loopback address. A flow row belongs to
    the process row above it."""
    owner, out = None, []
    for row in text.splitlines():
        fields = row.split(",")
        if len(fields) < 3:
            continue
        process = NETTOP_PROCESS.match(fields[1])
        if process and not fields[2]:
            owner = int(process.group(2))
            continue
        flow = NETTOP_FLOW.match(fields[1])
        if not flow or owner not in pids:
            continue
        host = remote_host(flow.group(3))
        if host is not None and not is_loopback(host):
            out.append((owner, fields[1]))
    return out


def parse_vdisplay(text):
    """p50 interval in ms from the last `ready ID P50 ...` or `main ID P50` line; None when it never ticked."""
    p50 = None
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] in ("ready", "main"):
            try:
                p50 = float(parts[2])
            except ValueError:
                p50 = None
    return p50 if p50 and p50 > 0 else None


def hz_for(p50_ms):
    """120 when the display holds 8.33 ms, else 60; None when it does not hold 60 Hz either."""
    if p50_ms <= FRAME_120_MS * FRAME_TOLERANCE:
        return 120
    if p50_ms <= FRAME_60_MS * FRAME_TOLERANCE:
        return 60
    return None


def fingerprint(chip, macos_build, hz, memory_bytes):
    return hashlib.sha256("\0".join(str(v) for v in (chip, macos_build, hz, memory_bytes)).encode()).hexdigest()


def host_class(chip, memory_bytes, hz):
    return load_store().host_class(chip=chip, memory_gb=round(memory_bytes / 2**30), display_hz=hz)


class Validation:
    def __init__(self, commands, clock, bench_user, vdisplay_text, egress_pids=(), own_pids=()):
        self.commands, self.clock = commands, clock
        self.bench_user, self.vdisplay_text = bench_user, vdisplay_text
        self.egress_pids, self.own_pids = frozenset(egress_pids), frozenset(own_pids) | frozenset(egress_pids)
        self.reasons, self.details, self.facts = [], {}, {}

    def refuse(self, code, detail):
        self.reasons.append(code)
        self.details[code] = detail

    def text(self, argv, timeout=COMMAND_TIMEOUT_S, stdin=None):
        result = self.commands.run(argv, timeout=timeout, stdin=stdin)
        return result.stdout if result is not None and result.returncode == 0 else None

    def check_thermal(self):
        text = self.text(["/usr/bin/pmset", "-g", "therm"])
        limit = parse_speed_limit(text) if text is not None else None
        self.facts["cpu_speed_limit"] = limit
        if limit is None:
            self.refuse("thermal-unreadable", "pmset -g therm gave no CPU_Speed_Limit")
        elif limit != 100:
            self.refuse("thermal-limit", f"CPU_Speed_Limit is {limit}, not 100")

    def check_power(self):
        text = self.text(["/usr/bin/pmset", "-g"])
        settings = parse_pmset_settings(text) if text is not None else {}
        for key, code in (("sleep", "system-sleep"), ("lowpowermode", "low-power-mode")):
            value = settings.get(key)
            self.facts[key] = value
            if value is None:
                self.refuse(f"{code}-unreadable", f"pmset -g has no {key} row")
            elif value != "0":
                self.refuse(code, f"pmset {key} is {value}, not 0")

    def check_load(self):
        deadline = self.clock.monotonic() + LOAD_WAIT_S
        while True:
            text = self.text(["/usr/sbin/sysctl", "-n", "vm.loadavg"])
            load = parse_load_1min(text) if text is not None else None
            self.facts["load_1min"] = load
            if load is None:
                self.refuse("load-unreadable", "sysctl vm.loadavg gave no 1-minute load")
                return
            if load < MAX_LOAD_1MIN:
                return
            left = deadline - self.clock.monotonic()
            if left <= 0:
                self.refuse("load-high", f"1-minute load {load} stayed >= {MAX_LOAD_1MIN} for {LOAD_WAIT_S:.0f} s")
                return
            self.clock.sleep(min(LOAD_POLL_S, left))

    def check_memory(self):
        text = self.text(["/usr/bin/vm_stat"])
        available = parse_free_inactive_bytes(text) if text is not None else None
        self.facts["free_inactive_bytes"] = available
        if available is None:
            self.refuse("memory-unreadable", "vm_stat gave no page size, free or inactive count")
        elif available <= MIN_FREE_INACTIVE_BYTES:
            self.refuse("memory-low", f"free+inactive is {available / 2**30:.1f} GB, not > 8 GB")

    def check_spotlight(self):
        text = self.text(["/usr/bin/mdutil", "-s", SPOTLIGHT_VOLUME])
        indexing = parse_indexing(text) if text is not None else None
        self.facts["spotlight_indexing"] = indexing
        if indexing is None:
            self.refuse("spotlight-unreadable", f"mdutil -s {SPOTLIGHT_VOLUME} said neither enabled nor disabled")
        elif indexing:
            self.refuse("spotlight-on", f"Spotlight indexes {SPOTLIGHT_VOLUME}")

    def check_console(self):
        text = self.text(["/usr/sbin/scutil"], stdin="show State:/Users/ConsoleUser\n")
        console = parse_console_user(text or "")
        self.facts["console_user"] = console
        if console != self.bench_user:
            who = console or "nobody (login window)"
            self.refuse("no-gui-session", f"the console user is {who}, not the bench user {self.bench_user}")

    def check_cmux_apps(self):
        text = self.text(["/bin/ps", "-axww", "-o", "pid=,comm="])
        if text is None:
            self.refuse("other-cmux-app-unreadable", "ps gave no process list")
            return
        others = [(pid, path) for pid, path in parse_cmux_apps(text) if pid not in self.own_pids]
        if others:
            self.refuse("other-cmux-app", "; ".join(f"{pid} {path}" for pid, path in others))

    def check_egress(self):
        if not self.egress_pids:
            self.facts["egress_checked"] = False
            return
        self.facts["egress_checked"] = True
        argv = ["/usr/bin/nettop", "-n", "-L", str(NETTOP_WINDOW_S), "-s", "1"]
        for pid in sorted(self.egress_pids):
            argv += ["-p", str(pid)]
        started = self.clock.monotonic()
        text = self.text(argv, timeout=NETTOP_WINDOW_S + NETTOP_GRACE_S)
        watched = self.clock.monotonic() - started
        if text is None or watched < NETTOP_WINDOW_S * 0.9:
            self.refuse("network-egress-unreadable", f"nettop watched {watched:.0f} s of {NETTOP_WINDOW_S} s")
            return
        flows = parse_egress(text, self.egress_pids)
        if flows:
            self.refuse("network-egress", "; ".join(sorted({f"{pid} {flow}" for pid, flow in flows})))

    def measured_hz(self):
        p50 = parse_vdisplay(self.vdisplay_text or "")
        self.facts["refresh_ms"] = p50
        if p50 is None:
            self.refuse("vdisplay-not-ready", "no vdisplay ready line with a ticking refresh")
            return None
        hz = hz_for(p50)
        if hz is None:
            self.refuse("refresh-below-60", f"the display ticks every {p50} ms, slower than 60 Hz")
        return hz

    def host(self, hz):
        chip = self.text(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"])
        memory = self.text(["/usr/sbin/sysctl", "-n", "hw.memsize"])
        macos = self.text(["/usr/bin/sw_vers", "-productVersion"])
        build = self.text(["/usr/bin/sw_vers", "-buildVersion"])
        chip, macos, build = ((v.strip() or None) if v else None for v in (chip, macos, build))
        memory = int(memory) if memory and memory.strip().isdigit() else None
        missing = [n for n, v in (("chip", chip), ("memory", memory), ("macOS build", build)) if not v]
        if missing:
            self.refuse("host-unknown", f"{', '.join(missing)} could not be read")
            return None
        if hz is None:
            return None
        return {"fingerprint": fingerprint(chip, build, hz, memory), "class": host_class(chip, memory, hz),
                "chip": chip, "macos": macos, "macos_build": build, "display_hz": hz, "memory_bytes": memory}

    def run(self):
        for check in (self.check_thermal, self.check_power, self.check_memory, self.check_spotlight,
                      self.check_console, self.check_cmux_apps, self.check_load, self.check_egress):
            check()
        hz = self.measured_hz()
        host = self.host(hz)
        report = {"ok": not self.reasons, "reasons": self.reasons, "details": self.details, "hz": hz,
                  "refresh_ms": self.facts.get("refresh_ms"),
                  "fingerprint": host["fingerprint"] if host else None, "class": host["class"] if host else None,
                  "host": host, "facts": self.facts}
        if self.reasons:
            report["refusal"] = "env-invalid"
        return report


def validate(commands=None, clock=None, bench_user=None, vdisplay_text="", egress_pids=(), own_pids=()):
    """{ok, reasons[], details, hz, refresh_ms, fingerprint, class, host, facts}, plus refusal=env-invalid when not
    ok. `egress_pids` are the app and daemon pids nettop watches; `own_pids` (with them) are not "another" cmux app."""
    user = bench_user or pwd.getpwuid(os.getuid()).pw_name
    return Validation(commands or Commands(), clock or Clock(), user, vdisplay_text, egress_pids, own_pids).run()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate this lab host before a measurement; print its fingerprint.")
    parser.add_argument("--vdisplay-out", help="the vdisplay helper's stdout (its ready line), or VDisplay probe's")
    parser.add_argument("--pid", type=int, action="append", default=[],
                        help="an app or daemon pid: nettop watches it for outbound connections (repeatable)")
    parser.add_argument("--own-pid", type=int, action="append", default=[],
                        help="a pid of this job's own cmux app, not counted as another cmux app (repeatable)")
    parser.add_argument("--bench-user", help="the account that must be the console user (default: this account)")
    opts = parser.parse_args(argv)
    text = ""
    if opts.vdisplay_out:
        try:
            with open(opts.vdisplay_out, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            text = ""
    report = validate(bench_user=opts.bench_user, vdisplay_text=text, egress_pids=opts.pid, own_pids=opts.own_pid)
    print("HOST-ENV " + json.dumps(report, sort_keys=True))
    return 0 if report["ok"] else EXIT_ENV_INVALID


if __name__ == "__main__":
    sys.exit(main())
