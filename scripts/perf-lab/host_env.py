#!/usr/bin/env python3
"""Whether this Mac may measure now, and its host fingerprint and class.

Runs before every lab job (perf-lab.sh) and try job. An invalid host refuses with `env-invalid` and stores nothing.
Chrome's lab gates a device the same way before it runs a story: catapult devil/android/tools/device_status.py
takes an unhealthy device out of the pool and devil/android/perf/thermal_throttle.py refuses a throttled one.

Checks (each failing one adds its own reason code; a probe that cannot be read fails closed with `<check>-unreadable`):
- `thermal-limit`: `pmset -g therm` records a non-zero thermal or performance warning level (how Apple silicon reports
  throttling) or a CPU_Speed_Limit other than 100 (the Intel XCPM block). Each of the three is either its
  "No ... has been recorded" note or a value; any other text is `thermal-unreadable`.
- `system-sleep`: `pmset -g` sleep is not 0.
- `low-power-mode`: `pmset -g` lowpowermode is not 0, or (Macs with High Power Mode print `powermode` instead:
  0 automatic, 1 low, 2 high) powermode is 1.
- `load-high`: `sysctl -n vm.loadavg` 1-minute load stays >= 1.0 for LOAD_WAIT_S.
- `memory-low`: `vm_stat` free + inactive pages <= MIN_FREE_INACTIVE_BYTES.
- `spotlight-on`: `mdutil -s` says the data volume is indexed.
- `no-gui-session`: the console user (scutil State:/Users/ConsoleUser) is not the bench user. The same rule as
  scripts/cmux-next/bench_launch.py console_user and hq build-fleet console_session.go.
- `other-cmux-app`: a cmux app bundle's executable runs that is not one of the job's own pids.
- `powermetrics-running`: a powermetrics process runs that is not one of the job's own pids. pool.json's sudoers
  command line samples a fixed count, but a sampler from a killed job runs as root until then, and the bench user
  cannot signal it.
- `network-egress`: in one NETTOP_WINDOW_S nettop session, an app or daemon pid has a connection to a non-loopback
  address. A full validation needs those pids (`--pid`); without them it refuses `network-egress-no-pids`.
  `--pre-launch` (before the job starts its app) skips nettop instead and says so: `mode: "pre-launch"`,
  `checks_skipped: ["network-egress"]`. Its ok covers only the other checks: the job validates again with its pids
  before it measures.
- `vdisplay-not-ready`, `refresh-below-60`: the vdisplay `ready ID P50_MS ...` (or `probe`'s `main ID P50_MS`) line
  is missing or ticks slower than 60 Hz. A display that cannot hold 8.33 ms is hz=60, not a refusal: its frame-target
  stories are skipped (p12-perf-process-160).
- `host-unknown`: chip, memory or macOS build could not be read.

The host block (fingerprint = sha256(chip, macOS build, Hz, memory), class = chip + memory + Hz with no macOS build,
so an OS update is a step inside one series) is bench_launch.host_record's, from the measured Hz. `--host-out` writes
that block, and the job's BenchApp records it (`BenchApp(host=host_env.host_reader(PATH))`), so result-v1 keys the
run by the Hz the display really ticks at, not the nominal mode refresh bench_launch.read_host would read.

    python3 -I scripts/perf-lab/host_env.py --vdisplay-out OUT/vdisplay.out --pid APP --pid DAEMON
                                              [--host-out OUT/host.json] [--bench-user NAME]
    python3 -I scripts/perf-lab/host_env.py --vdisplay-out OUT/vdisplay.out --pre-launch

Prints one `HOST-ENV {json}` line; exit 0 when every check that ran passed (all of them unless `checks_skipped`
names one), 3 when it refuses (env-invalid).
Stdlib only, loaded by file path; tests inject the command runner and the clock.
"""
import argparse
import dataclasses
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
BENCH_LAUNCH = os.path.join(os.path.dirname(os.path.dirname(HERE)), "scripts", "cmux-next", "bench_launch.py")

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


def load_bench_launch():
    name = "bench_launch"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, BENCH_LAUNCH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


# Parsers: canned text in, value out (None when the text does not say).

THERM_CHANNELS = (  # (fact, its "nothing recorded" note, its value line, the value that is not throttled)
    ("thermal_warning_level", "No thermal warning level has been recorded",
     re.compile(r"^\s*thermal[ _]?(?:warning[ _]?)?level\b[^0-9\n]*(\d+)", re.I | re.M), 0),
    ("performance_warning_level", "No performance warning level has been recorded",
     re.compile(r"^\s*performance[ _]?(?:warning[ _]?)?level\b[^0-9\n]*(\d+)", re.I | re.M), 0),
    ("cpu_speed_limit", "No CPU power status has been recorded",
     re.compile(r"^\s*CPU_Speed_Limit\s*=\s*(\d+)", re.M), 100),
)


def parse_therm(text):
    """{fact: value} of `pmset -g therm`'s thermal and performance warning levels and CPU_Speed_Limit. A channel with
    its "No ... has been recorded" note is its unthrottled value; a channel with neither the note nor a value is None
    (unreadable). A recorded value wins over a note."""
    facts = {}
    for fact, note, value, unthrottled in THERM_CHANNELS:
        match = value.search(text)
        facts[fact] = int(match.group(1)) if match else (unthrottled if note in text else None)
    return facts


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


def parse_powermetrics(text):
    """[pid] of `ps -axww -o pid=,comm=` rows whose executable is powermetrics."""
    return [int(match.group(1)) for match in re.finditer(r"^\s*(\d+)\s+(?:\S*/)?powermetrics\s*$", text, re.M)]


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
NETTOP_FLOW_PREFIX = re.compile(r"^(tcp|udp)[46]?\s")
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
    the process row above it. A row is a flow by its protocol prefix, never by its interface column (a SynSent or
    unbound flow has none); a flow row of a watched pid whose endpoints do not parse counts as egress."""
    owner, out = None, []
    for row in text.splitlines():
        fields = row.split(",")
        if len(fields) < 3:
            continue
        if not NETTOP_FLOW_PREFIX.match(fields[1]):
            process = NETTOP_PROCESS.match(fields[1])
            if process:
                owner = int(process.group(2))
            continue
        if owner not in pids:
            continue
        flow = NETTOP_FLOW.match(fields[1])
        host = remote_host(flow.group(3)) if flow else ""
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


def host_reader(path):
    """BenchApp's `host` seam for the block `--host-out` wrote: result-v1 then records the measured Hz."""
    def read():
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return read


def write_host_out(path, report):
    """Writes the host block of a valid report to `path`; removes `path` otherwise, so a refused host leaves no block
    an earlier run wrote for its BenchApp to record."""
    if report["ok"] and report["host"]:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(report["host"], f, sort_keys=True)
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


class Validation:
    def __init__(self, commands, clock, bench_user, vdisplay_text, egress_pids=(), own_pids=(), pre_launch=False):
        self.commands, self.clock, self.pre_launch = commands, clock, pre_launch
        self.bench_user, self.vdisplay_text = bench_user, vdisplay_text
        self.egress_pids, self.own_pids = frozenset(egress_pids), frozenset(own_pids) | frozenset(egress_pids)
        self.reasons, self.details, self.facts, self.skipped = [], {}, {}, []

    def refuse(self, code, detail):
        self.reasons.append(code)
        self.details[code] = detail

    def text(self, argv, timeout=COMMAND_TIMEOUT_S, stdin=None):
        result = self.commands.run(argv, timeout=timeout, stdin=stdin)
        return result.stdout if result is not None and result.returncode == 0 else None

    def check_thermal(self):
        text = self.text(["/usr/bin/pmset", "-g", "therm"])
        therm = parse_therm(text) if text is not None else {fact: None for fact, *_ in THERM_CHANNELS}
        self.facts.update(therm)
        unread = [fact for fact, value in therm.items() if value is None]
        throttled = [f"{fact} is {therm[fact]}, not {unthrottled}" for fact, _, _, unthrottled in THERM_CHANNELS
                     if therm[fact] is not None and therm[fact] != unthrottled]
        if throttled:
            self.refuse("thermal-limit", "; ".join(throttled))
        elif unread:
            self.refuse("thermal-unreadable", f"pmset -g therm gave neither a value nor a note for {', '.join(unread)}")

    def check_power(self):
        text = self.text(["/usr/bin/pmset", "-g"])
        settings = parse_pmset_settings(text) if text is not None else {}
        sleep = self.facts["sleep"] = settings.get("sleep")
        if sleep is None:
            self.refuse("system-sleep-unreadable", "pmset -g has no sleep row")
        elif sleep != "0":
            self.refuse("system-sleep", f"pmset sleep is {sleep}, not 0")
        low = self.facts["lowpowermode"] = settings.get("lowpowermode")
        mode = self.facts["powermode"] = settings.get("powermode")
        if low is not None:
            if low != "0":
                self.refuse("low-power-mode", f"pmset lowpowermode is {low}, not 0")
        elif mode is None:
            self.refuse("low-power-mode-unreadable", "pmset -g has neither a lowpowermode nor a powermode row")
        elif mode == "1":
            self.refuse("low-power-mode", "pmset powermode is 1 (low power)")
        elif mode not in ("0", "2"):
            self.refuse("low-power-mode-unreadable", f"pmset powermode is {mode}, not 0, 1 or 2")

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

    def check_processes(self):
        text = self.text(["/bin/ps", "-axww", "-o", "pid=,comm="])
        if text is None:
            self.refuse("other-cmux-app-unreadable", "ps gave no process list")
            return
        others = [(pid, path) for pid, path in parse_cmux_apps(text) if pid not in self.own_pids]
        if others:
            self.refuse("other-cmux-app", "; ".join(f"{pid} {path}" for pid, path in others))
        samplers = [pid for pid in parse_powermetrics(text) if pid not in self.own_pids]
        if samplers:
            self.refuse("powermetrics-running", f"powermetrics pid {', '.join(map(str, samplers))} still samples")

    def check_egress(self):
        if self.pre_launch:
            self.skipped.append("network-egress")
            return
        if not self.egress_pids:
            self.refuse("network-egress-no-pids", "a full validation watches the app and daemon pids (--pid); "
                                                  "before the app starts, run --pre-launch")
            return
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
        self.facts["memory_bytes"] = memory
        if hz is None:
            return None
        return load_bench_launch().host_record(chip, memory, macos, build, hz)

    def run(self):
        for check in (self.check_thermal, self.check_power, self.check_memory, self.check_spotlight,
                      self.check_console, self.check_processes, self.check_load, self.check_egress):
            check()
        hz = self.measured_hz()
        host = self.host(hz)
        report = {"ok": not self.reasons, "mode": "pre-launch" if self.pre_launch else "full",
                  "checks_skipped": self.skipped, "reasons": self.reasons, "details": self.details, "hz": hz,
                  "refresh_ms": self.facts.get("refresh_ms"),
                  "fingerprint": host["fingerprint"] if host else None, "class": host["class"] if host else None,
                  "host": host, "facts": self.facts}
        if self.reasons:
            report["refusal"] = "env-invalid"
        return report


def validate(commands=None, clock=None, bench_user=None, vdisplay_text="", egress_pids=(), own_pids=(),
             pre_launch=False):
    """{ok, mode, checks_skipped[], reasons[], details, hz, refresh_ms, fingerprint, class, host, facts}, plus
    refusal=env-invalid when not ok. `egress_pids` are the app and daemon pids nettop watches; `own_pids` (with them)
    are not "another" cmux app. `pre_launch` skips nettop (mode "pre-launch", checks_skipped ["network-egress"])."""
    user = bench_user or pwd.getpwuid(os.getuid()).pw_name
    return Validation(commands or Commands(), clock or Clock(), user, vdisplay_text, egress_pids, own_pids,
                      pre_launch).run()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate this lab host before a measurement; print its fingerprint.")
    parser.add_argument("--vdisplay-out", help="the vdisplay helper's stdout (its ready line), or VDisplay probe's")
    parser.add_argument("--pid", type=int, action="append", default=[],
                        help="an app or daemon pid: nettop watches it for outbound connections (repeatable)")
    parser.add_argument("--own-pid", type=int, action="append", default=[],
                        help="a pid of this job's own cmux app, not counted as another cmux app (repeatable)")
    parser.add_argument("--pre-launch", action="store_true",
                        help="before the job starts its app: skip nettop and report it in checks_skipped")
    parser.add_argument("--host-out", help="write the host block (measured Hz) for BenchApp(host=host_reader(PATH))")
    parser.add_argument("--bench-user", help="the account that must be the console user (default: this account)")
    opts = parser.parse_args(argv)
    if opts.pre_launch and opts.pid:
        parser.error("--pre-launch watches no pids; pass --pid only for the full validation")
    text = ""
    if opts.vdisplay_out:
        try:
            with open(opts.vdisplay_out, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            text = ""
    report = validate(bench_user=opts.bench_user, vdisplay_text=text, egress_pids=opts.pid, own_pids=opts.own_pid,
                      pre_launch=opts.pre_launch)
    if opts.host_out:
        write_host_out(opts.host_out, report)
    print("HOST-ENV " + json.dumps(report, sort_keys=True))
    return 0 if report["ok"] else EXIT_ENV_INVALID


if __name__ == "__main__":
    sys.exit(main())
