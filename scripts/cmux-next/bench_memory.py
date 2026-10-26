#!/usr/bin/env python3
"""Resident memory of a cmux-next app and every process it owns.

Measures resident size (RSS) and physical footprint (what Activity Monitor
calls Memory) per process: the app, its Chromium helpers, the WebKit
processes it is responsible for (agent chats and pages), the cmux-tui
daemons and terminal hosts, acpmux, and the other bundled helpers. It
builds workspaces over the app socket (each takes the next entry of
--mix, for example terminal+chat, terminal+browser, terminal), measures at
each count in --workspaces after --settle seconds, then optionally churns:
for --churn-minutes it opens a workspace of the mix and closes it again,
and every --sample-minutes it lets the app settle at the same workspace
count and samples again. Growth across those samples at an unchanged
workspace count is a leak.

--tabs 1,10,20 measures browser tabs instead (the Ardia/Helium/Dia comparison):
N Chromium tabs in the launch workspace's focused pane, one URL each from --urls
(`local`: N distinct sites `siteN.localhost` served by this script, the same
page each, so a run is deterministic; `real`: 20 well-known public sites; or a
comma list). Each count is sampled after --settle seconds.

Two ways to run (macOS only, a fleet or capture mini, never a laptop):
  attach  --socket PATH --app-pid PID: an app someone else launched, for
          example by `capture-host launch` into a capture slot (capture
          leases end after 10 minutes, so churn there stays short).
  launch  no --socket: starts the bundle's app with a scratch HOME,
          TMPDIR and config, and quits it at the end.

Usage:
  bench_memory.py --app BUNDLE [--socket PATH --app-pid PID]
      [--workspaces 1,10,30] [--mix terminal+chat,terminal+browser,terminal]
      [--settle 30] [--measure 0] [--churn-minutes 0] [--sample-minutes 5]
      [--url URL] [--top 15] [--config JSON] [--fake-agent SCRIPT] [--out FILE.json]
  bench_memory.py --app BUNDLE --tabs 1,10,20 [--urls local|real|URL,URL,...] [--settle 30]
  bench_memory.py --app BUNDLE --hidden-workspaces 100 [--grace 960] [--mix terminal] [--terminal-host-model hosts|holder]
  bench_memory.py --app BUNDLE --pressure warning|critical [--pressure-window 10]
  bench_memory.py --app BUNDLE ... --kernel-pressure warn|critical [--kernel-pressure-window 5]

Phases (plans/cmux-next/chrome-parity/p07-memory.md, DC6 and DC10):
  --hidden-workspaces N [--grace S]
          opens N workspaces of --mix, shows the first workspace again so all
          N are hidden, and samples after --settle and again S seconds after
          they went hidden (960 is past the 15 min parked idle timeout). It
          prints, per process kind, the processes added and the footprint
          each hidden workspace adds at both points, and debug.memory's
          workspace states (mounted, parked, unmounted). DC6 runs with
          --terminal-host-model holder (launch only); the table names the
          model the launch gave the app, says when the daemon started
          terminal hosts all the same, and says unknown-attach for an attached app.
  --pressure warning|critical [--pressure-window S]
          runs last. It sets the debug pressure override
          (debug.hibernation.pressure, DEBUG and bench-hook builds), follows
          the app's footprint for S seconds, and prints released_mb (app
          footprint before minus its lowest), release_s (time from sending
          the override to 90 % of that drop) and the footprint of the managed
          memory consumers before (stateful and supporting a limit, from
          debug.memory, summed over every consumer of a name; volatile bytes
          left out). It clears the override (`none`) at the end, also after
          a failed request.
  On a build without debug.memory both phases report process footprint only;
  a build without the override skips the pressure phase and says so; any
  other override failure is printed and recorded as the phase's error.

--kernel-pressure warn|critical then feeds real kernel pressure
(`/usr/bin/memory_pressure -S -l LEVEL`, root or passwordless sudo; without
either it says so and skips that step): kern.memorystatus_vm_pressure_level
changes and the app's kernel source reads it. Printed as PERF-KERNEL-PRESSURE:
when the kernel reached the level and the footprint before and after
--kernel-pressure-window seconds.

Prints a table per measurement (top processes by footprint, totals per
kind) and writes every sample to --out. It records no budgets and gates
nothing.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

MB = 1048576.0


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
_responsible = None
# macOS only; elsewhere the module still loads, so --help works and main() refuses to run.
if sys.platform == "darwin":
    _libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    _libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    try:
        _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
        _responsible.restype = ctypes.c_int
        _responsible.argtypes = [ctypes.c_int]
    except AttributeError:  # an OS without the call: WebKit processes are not attributed
        _responsible = None
    _libsystem.mach_timebase_info(ctypes.byref(_timebase))


def usage(pid: int):
    """(resident, footprint, lifetime max footprint, cpu ns, wakeups), or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    # RUSAGE_INFO_V4 in u64 words: uuid (2), user, system (mach ticks), pkg
    # idle wakeups, interrupt wakeups, pageins, wired (7), resident (8),
    # phys_footprint (9), ... ri_lifetime_max_phys_footprint (30).
    cpu_ns = (buf[2] + buf[3]) * _timebase.numer // _timebase.denom
    return buf[8], buf[9], buf[30], cpu_ns, buf[4] + buf[5]


def process_table():
    rows = []
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def in_bundle(cmd: str, bundle: str) -> str | None:
    """`cmd` relative to the bundle, or None. The app runs from the real
    path (/private/tmp/...) while its daemons keep the path it handed them
    (/tmp/...), so both spellings count."""
    for root in (bundle, bundle.removeprefix("/private")):
        if cmd.startswith(root + "/"):
            return cmd[len(root):]
    return None


def kind_of(cmd: str, bundle: str) -> str:
    rel = in_bundle(cmd, bundle) or cmd
    if " Helper" in rel:
        for flag, name in (("--type=renderer", "cef-renderer"), ("--type=gpu-process", "cef-gpu"),
                           ("--type=utility", "cef-utility"), ("--type=plugin", "cef-plugin")):
            if flag in rel:
                return name
        return "cef-helper"
    # The Chromium Host is a second executable of the app (embed-cef.sh), not the app.
    if re.match(r"/Contents/MacOS/[^/]* Chromium Host( |$)", rel):
        return "cef-host"
    if rel.startswith("/Contents/MacOS/"):
        return "app"
    if "/bin/cmux-tui" in rel or "/bin/cmux " in rel or rel.endswith("/bin/cmux"):
        if "__terminal-host" in rel:
            return "terminal-host"
        if "--session cmux-chief" in rel:
            return "tui-daemon-chief"
        return "tui-daemon"
    if "/bin/acpmux" in rel:
        return "acpmux-" + (rel.split("/bin/acpmux", 1)[1].split() or ["agent"])[0]
    if "/bin/" in rel:
        return rel.split("/bin/", 1)[1].split()[0]
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    return os.path.basename(cmd.split()[0])


def owned(app_pid: int, bundle: str):
    """{pid: (kind, command)} for every process from the bundle, plus the
    WebKit processes the app is responsible for."""
    found = {}
    for pid, _ppid, cmd in process_table():
        if in_bundle(cmd, bundle) is not None:
            _run_pids.add(pid)
            found[pid] = (kind_of(cmd, bundle), cmd)
        elif _responsible is not None and "com.apple.WebKit." in cmd and _responsible(pid) == app_pid:
            found[pid] = (kind_of(cmd, bundle), cmd)
    return found


def sample(app_pid: int, bundle: str, label: str, workspaces: int, measure: float = 0):
    """Memory per process now; with `measure` > 0 also CPU % and wakeups/s
    over that many idle seconds (proc_pid_rusage at both ends, so the bench
    adds no wakeups to the measured processes)."""
    start = {}
    if measure > 0:
        for pid in owned(app_pid, bundle):
            got = usage(pid)
            if got is not None:
                start[pid] = got
        time.sleep(measure)  # test script: the measured idle window
    rows = []
    for pid, (kind, cmd) in owned(app_pid, bundle).items():
        got = usage(pid)
        if got is None:
            continue
        row = {"pid": pid, "kind": kind, "rss_mb": round(got[0] / MB, 1),
               "footprint_mb": round(got[1] / MB, 1), "footprint_bytes": got[1],
               "max_footprint_mb": round(got[2] / MB, 1), "command": cmd[:160]}
        if pid in start:
            row["cpu_pct"] = round(100 * (got[3] - start[pid][3]) / 1e9 / measure, 3)
            row["wakeups_per_s"] = round((got[4] - start[pid][4]) / measure, 2)
        rows.append(row)
    rows.sort(key=lambda row: -row["footprint_mb"])
    kinds = {}
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"count": 0, "rss_mb": 0.0, "footprint_mb": 0.0, "footprint_bytes": 0})
        entry["count"] += 1
        entry["footprint_bytes"] += row["footprint_bytes"]
        entry["rss_mb"] = round(entry["rss_mb"] + row["rss_mb"], 1)
        entry["footprint_mb"] = round(entry["footprint_mb"] + row["footprint_mb"], 1)
        if "cpu_pct" in row:
            entry["cpu_pct"] = round(entry.get("cpu_pct", 0.0) + row["cpu_pct"], 3)
            entry["wakeups_per_s"] = round(entry.get("wakeups_per_s", 0.0) + row["wakeups_per_s"], 2)
    return {"measure_s": measure, "label": label, "workspaces": workspaces, "time": round(time.time()),
            "total_rss_mb": round(sum(r["rss_mb"] for r in rows), 1),
            "total_footprint_mb": round(sum(r["footprint_mb"] for r in rows), 1),
            "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["footprint_mb"])),
            "processes": rows}


def print_sample(result, top: int):
    print(f"== {result['label']}: {result['workspaces']} workspaces, {len(result['processes'])} processes, "
          f"footprint {result['total_footprint_mb']:.0f} MB, RSS {result['total_rss_mb']:.0f} MB")
    print(f"   {'kind':<22}{'n':>4}{'footprint MB':>14}{'RSS MB':>10}{'CPU %':>9}{'wakeups/s':>11}")
    for kind, entry in result["kinds"].items():
        print(f"   {kind:<22}{entry['count']:>4}{entry['footprint_mb']:>14.1f}{entry['rss_mb']:>10.1f}"
              f"{entry.get('cpu_pct', float('nan')):>9.3f}{entry.get('wakeups_per_s', float('nan')):>11.2f}")
    print(f"   top {top} processes by footprint:")
    for row in result["processes"][:top]:
        print(f"   {row['footprint_mb']:>8.1f} MB  RSS {row['rss_mb']:>7.1f}  max {row['max_footprint_mb']:>7.1f}  "
              f"{row['kind']:<20} pid {row['pid']}")
    sys.stdout.flush()


class App:
    """The app's control socket, through the app's own bundled CLI."""

    def __init__(self, bundle: str, socket_path: str):
        self.cli_path = os.path.join(bundle, "Contents/Resources/bin/cmux")
        self.socket = socket_path

    def run(self, action: str, target: str | None = None, **args):
        argv = [self.cli_path, "--app-socket", self.socket, "--json", "action", "run", action]
        if target:
            argv += ["--target", target]
        for name, value in args.items():
            argv += [f"--{name}", str(value)]
        out = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            # A refused action exits non-zero with its reason on stderr.
            return {"error": (out.stderr or out.stdout).strip()[:300] or f"exit {out.returncode}"}
        try:
            return json.loads(out.stdout or "{}")
        except ValueError:
            return {"error": (out.stdout + out.stderr).strip()[:300]}

    def action(self, action: str, *, focus: bool = False, **args) -> dict:
        """`action.run` over the socket itself: the CLI reads `--session`
        as its own option, so an action argument of that name never reaches
        the app through it. `focus` moves the app's focus to what the action
        opens or selects, as the user's shortcut would; without it a new tab
        opens in the background and does not load until it is shown."""
        params = {"action": action, "args": args, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, label=action)

    def call(self, method: str, params: dict | None = None, label: str | None = None, timeout: float = 120) -> dict:
        """One control-socket request; its result, or {"error": ...} (an unknown method, a refusal, a timeout)."""
        reply = b""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(timeout)
                stream.connect(self.socket)
                stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                while not reply.endswith(b"\n"):
                    chunk = stream.recv(1 << 20)
                    if not chunk:
                        break
                    reply += chunk
        except OSError as error:  # includes a timeout: this step is skipped, the run goes on
            return {"error": f"{label or method}: {error}"}
        try:
            answer = json.loads(reply or b"{}")
        except ValueError:
            return {"error": reply.decode(errors="replace")[:300]}
        if answer.get("error"):
            return {"error": json.dumps(answer["error"])[:300]}
        result = answer.get("result")
        return result if isinstance(result, dict) else {"value": result}

    def identify(self) -> dict:
        try:
            out = subprocess.run([self.cli_path, "--app-socket", self.socket, "--json", "app", "identify"],
                                 capture_output=True, text=True, timeout=10)
            return json.loads(out.stdout or "{}")
        except (subprocess.TimeoutExpired, ValueError):
            return {}

    def ping(self) -> bool:
        out = subprocess.run([self.cli_path, "--app-socket", self.socket, "app", "ping"],
                             capture_output=True, text=True, timeout=30)
        return out.returncode == 0


FAKE_AGENT_ID = "bench-memory-fake"


class FakeChats:
    """Chats on an ACP test agent whose turns end (--fake-agent).

    A prompt sent through the app's CLI waits in a new chat's composer for a
    Send, so such a chat never gets a session. Each chat here is instead an
    acpmux session made on the app's own acpmux, with its first turn already
    answered, opened as a workspace (`agent.openSessionWorkspace`): an idle
    chat, as one is after its reply. Its sessions stay in that acpmux's
    store (the app's tag under ~/.acpmux)."""

    def __init__(self, app: App, bundle: str, script: str):
        self.app = app
        added = app.run("agent.harness.add", id=FAKE_AGENT_ID, name="Memory bench", command=sys.executable,
                        args=os.path.abspath(script), protocol="acp", replace="true")
        if added.get("error") or added.get("code"):
            raise SystemExit(f"bench-memory: agent.harness.add: {added.get('message') or added.get('error')}")
        self.env = dict(os.environ, ACPMUX_SOCKET=self.acpmux_socket(bundle))

    @staticmethod
    def acpmux_socket(bundle: str) -> str:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            for pid, _, cmd in process_table():
                if in_bundle(cmd, bundle) is not None and "/bin/acpmux daemon run" in cmd:
                    listed = subprocess.run(["lsof", "-a", "-p", str(pid), "-U", "-Fn"],
                                            capture_output=True, text=True, timeout=30).stdout
                    # `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<hash>.sock` when that path is too long.
                    paths = [line[1:] for line in listed.splitlines()
                             if line.startswith("n/") and line.endswith(".sock") and "acpmux" in line]
                    if paths:
                        return paths[0]
            time.sleep(1)  # test script: waiting for the app's acpmux to listen
        raise SystemExit("bench-memory: the app's acpmux opened no socket within 90 s")

    def open(self, index: int) -> str | None:
        """A new workspace on a new answered chat; returns the workspace id."""
        made = subprocess.run([self.app.cli_path, "acp", "new", "--json", "-d", "-m", FAKE_AGENT_ID,
                               f"memory bench chat {index}"],
                              capture_output=True, text=True, timeout=120, env=self.env)
        try:
            session = json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            print(f"   acp new: {(made.stdout + made.stderr).strip()[:300]}", file=sys.stderr)
            return None
        response = self.app.action("agent.openSessionWorkspace", session=session)
        created = [item for item in response.get("created", []) if str(item).startswith("ws_")]
        if not created:
            print(f"   agent.openSessionWorkspace: {response.get('error') or response}", file=sys.stderr)
            return None
        return created[0]


def open_workspace(app: App, recipe: str, url: str, index: int, chats: FakeChats | None = None):
    """One workspace of `recipe` (kinds joined by +); returns its id or None."""
    kinds = recipe.split("+")
    if chats and "chat" in kinds:
        # The workspace opens on its chat (with a terminal first, as every such workspace).
        kinds.remove("chat")
        workspace = chats.open(index)
        if workspace is None:
            return None
        app.action("goToWorkspace", workspace=workspace)
    else:
        made = app.run("workspace.newAtBottom")
        created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made.get('message') or made}", file=sys.stderr)
            return None
        workspace = created[0]
        # Browser and chat tabs open in the focused pane (they take a tab or pane
        # target, not a workspace), so show the new workspace first, as a user
        # who opened it would; that also loads its pages and renderers.
        app.run("workspace.selectLast")
    for kind in kinds:
        if kind == "none":
            # The workspace alone (its first page): `--mix none` churns workspaces only.
            continue
        if kind == "terminal":
            response = app.run("newSurface")
        elif kind == "browser":
            response = app.run("openBrowser.chromium", url=url)
        elif kind == "chat":
            # A prompt opens an agent chat tab. It waits in the composer for a
            # Send (fleet minis carry no agent credentials either): --fake-agent
            # makes chats that answered.
            response = app.run("newTab.submit", text=f"memory bench chat {index}")
        else:
            raise SystemExit(f"bench-memory: unknown kind {kind!r} in --mix")
        if response.get("error") or response.get("code"):
            print(f"   {kind} in {workspace}: {response.get('message') or response.get('error')}", file=sys.stderr)
    return workspace


def close_workspace(app: App, workspace: str):
    response = app.run("closeWorkspace", target=workspace)
    if response.get("error") or response.get("code"):
        response = app.run("closeWorkspace", target=workspace, confirm="true")
    return response


# Every process of the bundle this run saw: the terminal hosts its daemons
# start run outside the bundle and name their daemon (`--owner ...@<pid>`).
_run_pids: set[int] = set()


def bundle_pids(bundle: str) -> set[int]:
    """The bundle's processes, with the terminal hosts this run's daemons started."""
    table = process_table()
    pids = {pid for pid, _, cmd in table if in_bundle(cmd, bundle) is not None}
    _run_pids.update(pids)
    hosts = set()
    for pid, _, cmd in table:
        owner = re.search(r"--owner \S+@(\d+)", cmd) if "__terminal-host" in cmd else None
        if owner and int(owner.group(1)) in _run_pids:
            hosts.add(pid)
    return pids | hosts


def is_binary(cmd: str, binary: str) -> bool:
    return cmd == binary or cmd.startswith(binary + " ")


def end_processes(pids: set[int]):
    """SIGTERM, then SIGKILL what is still there after a grace period."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        alive = set()
        for pid in pids:
            try:
                os.kill(pid, sig)
                alive.add(pid)
            except ProcessLookupError:
                pass
        pids = {pid for pid in alive if not wait_gone(pid, 10)}
        if not pids:
            return


def control_socket(bundle: str, pid: int, dirs: list[str]) -> str | None:
    """The control socket whose app answers `identify` with `pid`: another
    cmux on this Mac may bind one meanwhile. (lsof shows the app's bind
    path, not the name it is reached by.)"""
    for directory in dirs:
        if not os.path.isdir(directory):
            continue
        for name in os.listdir(directory):
            path = os.path.join(directory, name)
            if name.startswith("cmux") and name.endswith(".sock") and App(bundle, path).identify().get("pid") == pid:
                return path
    return None


def end_bundle(bundle: str):
    """Ends every process of the bundle, the app first: a live app (it can
    ignore SIGTERM) respawns daemons ended before it. No process of this
    bundle ran before the launch (`launch`), so every one is this run's."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    apps = {pid for pid, _, cmd in process_table() if cmd.startswith(binary_dir + "/")}
    bundle_pids(bundle)  # notes the daemons before they go, for their terminal hosts
    end_processes(apps)
    end_processes(bundle_pids(bundle))


def wait_gone(pid: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.5)  # test script: waiting for the app to quit
    return False


def merged(base: dict, extra: dict) -> dict:
    out = dict(base)
    for key, value in extra.items():
        out[key] = merged(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
    return out


def tail(path: str, lines: int = 20) -> str:
    """The last `lines` of the app's own output, for a launch that failed (empty when none)."""
    try:
        with open(path, errors="replace") as handle:
            text = handle.read().splitlines()[-lines:]
    except OSError:
        return ""
    return ("\napp output:\n" + "\n".join(text)) if text else ""


def launch(bundle: str, config: dict, extra_env: dict | None = None, direct: bool | None = None):
    """Starts the app with a scratch HOME, TMPDIR and config; returns (pid, socket, scratch).

    Through LaunchServices (`open`), as a user's launch: the app is then the
    responsible process of its WebKit processes. A child of this script
    would leave them attributed to the shell that ran it.

    `direct` (default: CMUX_BENCH_LAUNCH=direct) runs the app binary as a child instead, as
    palette-open-stages.py does: a fleet step has no LaunchServices session (`open` starts
    nothing on the minis, and the AWS workers refuse it), so a measure script must launch so."""
    if direct is None:
        direct = os.environ.get("CMUX_BENCH_LAUNCH") == "direct"
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    # The bundle's own executable (Info.plist): a DEV build also ships `__preview.dylib` there,
    # which sorts first, so the first file is not the app.
    with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
        binary = os.path.join(binary_dir, plistlib.load(handle)["CFBundleExecutable"])
    # Every process from this bundle at the end is this run's (cleanup ends
    # them all), so none may exist before: an earlier app's detached daemons
    # and terminal hosts would otherwise be ended too.
    running = bundle_pids(bundle)
    if running:
        raise SystemExit(f"bench-memory: processes from {bundle} are running ({sorted(running)}); end them first")
    scratch = tempfile.mkdtemp(prefix="bench-memory-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json")}
    env.update(extra_env or {})
    os.makedirs(env["TMPDIR"], exist_ok=True)
    # Sparkle would otherwise download a newer nightly into the bundle under
    # test mid-run (and its installer counts as the bundle's process).
    with open(env["CMUX_NEXT_CONFIG_FILE"], "w") as handle:
        json.dump(merged({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, config), handle)
    log_path = os.path.join(scratch, "app.log")
    if direct:
        env.setdefault("CMUX_NEXT_TEST_WINDOW_FRAME", "40,40,1400,900")
        with open(log_path, "a") as log:
            subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    else:
        argv = ["open", "-n", "-g"] + [arg for name, value in env.items() for arg in ("--env", f"{name}={value}")]
        subprocess.run(argv + ["-a", bundle], check=True, timeout=60)
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            pid = next((p for p, _, cmd in process_table() if is_binary(cmd, binary)), None)
            # Only a socket the launched app itself holds: another cmux on
            # this Mac may bind one meanwhile.
            # A DEV build binds its socket in <HOME>/.local/state/cmux (build_names.py), linked from /tmp
            # only when that path fits; look in all three.
            path = control_socket(bundle, pid, [os.path.join(home, ".local", "state", "cmux"), "/tmp", env["TMPDIR"]]) if pid else None
            if path:
                return pid, path, scratch
            time.sleep(1)  # test script: waiting for the launched app's socket
        state = os.path.join(home, ".local", "state", "cmux")
        seen = sorted(os.listdir(state)) if os.path.isdir(state) else []
        raise SystemExit(f"bench-memory: the launched app opened no socket within 90 s "
                         f"(app pid {pid or 'none: it did not start'}; {state}: {seen}; "
                         f"launch {'direct' if direct else 'open'})" + tail(log_path))
    except BaseException:
        end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        raise


REAL_SITES = [
    "https://en.wikipedia.org/wiki/Main_Page", "https://github.com/explore", "https://news.ycombinator.com",
    "https://www.apple.com", "https://developer.mozilla.org/en-US/", "https://www.reddit.com",
    "https://www.nytimes.com", "https://www.bbc.com/news", "https://stackoverflow.com/questions",
    "https://www.youtube.com", "https://www.amazon.com", "https://docs.python.org/3/",
    "https://www.figma.com", "https://www.notion.so", "https://vercel.com", "https://www.cloudflare.com",
    "https://www.theverge.com", "https://arxiv.org", "https://www.espn.com", "https://www.imdb.com",
]

_LOCAL_PAGE = """<!doctype html><html><head><meta charset=utf-8><title>bench %(n)d</title>
<style>body{font:15px -apple-system,sans-serif;max-width:760px;margin:40px auto;line-height:1.5}
.card{border:1px solid #ccc;border-radius:8px;padding:12px;margin:12px 0}</style></head><body>
<h1>Memory bench site %(n)d</h1>%(cards)s
<script>document.querySelectorAll('.card').forEach((c,i)=>c.dataset.i=i)</script></body></html>"""


def local_sites(count: int) -> list[str]:
    """`count` distinct sites (siteN.localhost, its own renderer under site isolation) served here."""
    import http.server
    import threading

    cards = "".join(f"<div class=card><h3>Card {i}</h3><p>{'lorem ipsum dolor sit amet ' * 12}</p></div>" for i in range(40))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = (self.headers.get("Host") or "site0").split(".")[0]
            number = int(re.sub(r"\D", "", host) or 0)
            body = (_LOCAL_PAGE % {"n": number, "cards": cards}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    return [f"http://site{i}.localhost:{port}/" for i in range(count)]


def tab_urls(spec: str, count: int) -> list[str]:
    if spec == "local":
        return local_sites(count)
    urls = REAL_SITES if spec == "real" else [u for u in spec.split(",") if u]
    return [urls[i % len(urls)] for i in range(count)]


def open_browser_tab(app: App, url: str) -> bool:
    response = app.run("openBrowser.chromium", url=url)
    if response.get("error") or response.get("code"):
        print(f"   browser tab {url}: {response.get('message') or response.get('error')}", file=sys.stderr)
        return False
    return True


def known_int(value) -> int | None:
    """A count or byte count of the debug.memory JSON: an integer, or None for null (unknown, never 0)."""
    return value if isinstance(value, int) and not isinstance(value, bool) else None


class MemoryReport:
    """The app's own memory accounting through `debug.memory`, read as MemoryDiagnosticsReport (p07-memory-010)
    writes it: snake_case keys, integer byte counts, null for unknown. `read` gives None on a build without it,
    and every phase then reports process footprint only."""

    def __init__(self, raw: dict):
        self.raw = raw

    @staticmethod
    def read(app: App) -> MemoryReport | None:
        answer = app.call("debug.memory", timeout=30)
        return None if "error" in answer or "consumers" not in answer else MemoryReport(answer)

    def consumers(self) -> list[dict]:
        return [consumer for consumer in self.raw.get("consumers") or [] if isinstance(consumer, dict)]

    def managed_consumers(self) -> list[dict]:
        """The consumers the report marks `managed`: Chrome's ShouldManageConsumer
        (memory_saver_memory_coordinator_policy.h), stateful and supporting a limit."""
        return [consumer for consumer in self.consumers() if consumer.get("managed") is True]

    def managed(self) -> dict[str, dict]:
        """{name: {"instances", "footprint_bytes", "unknown"}} over the managed consumers. A name is not unique
        (one `tab-hover-cards` per tab strip; every name that is not a plain token is `redacted`), so a row adds
        up every consumer of that name; `unknown` counts the ones with null bytes, which add nothing."""
        rows: dict[str, dict] = {}
        for consumer in self.managed_consumers():
            row = rows.setdefault(str(consumer.get("name")), {"instances": 0, "footprint_bytes": 0, "unknown": 0})
            row["instances"] += 1
            footprint = known_int(consumer.get("footprint_bytes"))
            if footprint is None:
                row["unknown"] += 1
            else:
                row["footprint_bytes"] += footprint
        return rows

    def managed_bytes(self) -> tuple[int, int]:
        """(known footprint bytes of every managed consumer, how many have unknown bytes). Volatile bytes are
        left out: the kernel takes them without the app (DC10)."""
        footprints = [known_int(consumer.get("footprint_bytes")) for consumer in self.managed_consumers()]
        return sum(b for b in footprints if b is not None), sum(1 for b in footprints if b is None)

    def level(self) -> str | None:
        pressure = self.raw.get("pressure")
        return pressure.get("level") if isinstance(pressure, dict) else None

    @staticmethod
    def workspace_state(row: dict) -> str:
        """parked (hidden, kept mounted until the parked idle timeout), mounted or unmounted, from the row's
        `parked` and `mounted` flags (memory-DESIGN.md section 7)."""
        if row.get("parked") is True:
            return "parked"
        return "mounted" if row.get("mounted") is True else "unmounted"

    def workspaces(self) -> dict:
        """{state: {"count", "attributed_mb", "terminal_surfaces", "gpu_resident_surfaces"}} over the workspace
        rows; attributed is the app bytes debug.memory gives each workspace."""
        states: dict = {}
        for row in self.raw.get("workspaces") or []:
            if not isinstance(row, dict):
                continue
            entry = states.setdefault(self.workspace_state(row), {"count": 0, "attributed_mb": 0.0,
                                                                  "terminal_surfaces": 0, "gpu_resident_surfaces": 0})
            entry["count"] += 1
            attributed = known_int(row.get("app_bytes"))
            if attributed is not None:
                entry["attributed_mb"] = round(entry["attributed_mb"] + attributed / MB, 2)
            for name in ("terminal_surfaces", "gpu_resident_surfaces"):
                value = known_int(row.get(name))
                if value is not None:
                    entry[name] += value
        return states

    def hidden_iosurface_mb(self) -> float | None:
        """terminal.hidden_nonvolatile_iosurface_bytes: what hidden terminals keep in GPU memory."""
        terminal = self.raw.get("terminal")
        value = known_int(terminal.get("hidden_nonvolatile_iosurface_bytes")) if isinstance(terminal, dict) else None
        return None if value is None else round(value / MB, 2)


def kind_deltas(base: dict, after: dict, per: int) -> dict:
    """{kind: {"processes_added", "mb_each"}}: footprint from `base` to `after` divided by `per`, plus a
    "total" row."""
    out = {}
    for kind in set(base["kinds"]) | set(after["kinds"]):
        first, last = base["kinds"].get(kind, {}), after["kinds"].get(kind, {})
        out[kind] = {"processes_added": last.get("count", 0) - first.get("count", 0),
                     "mb_each": round((last.get("footprint_bytes", 0) - first.get("footprint_bytes", 0))
                                      / MB / max(per, 1), 3)}
    grown = (sum(entry.get("footprint_bytes", 0) for entry in after["kinds"].values())
             - sum(entry.get("footprint_bytes", 0) for entry in base["kinds"].values()))
    out["total"] = {"processes_added": len(after["processes"]) - len(base["processes"]),
                    "mb_each": round(grown / MB / max(per, 1), 3)}
    return dict(sorted(out.items(), key=lambda item: -item[1]["mb_each"]))


def hidden_workspaces_phase(app: App, count: int, grace: float, recipes: list[str], url: str, opened: list,
                            chats, settle_and_sample, host_model: str) -> dict:
    """DC6. Opens `count` workspaces of the mix, shows the first workspace again so all of them are hidden,
    samples after --settle and again `grace` seconds after they went hidden (past the parked idle timeout),
    and prints what one hidden workspace costs per process kind. `host_model` is the terminal host model the
    launch gave the app (`unknown-attach` for an app this run did not launch)."""
    app.run("workspace.selectFirst")
    base = settle_and_sample("hidden-base")
    made = 0
    while made < count:
        workspace = open_workspace(app, recipes[made % len(recipes)], url, 2000 + made, chats)
        if workspace is None:
            break
        opened.append(workspace)
        made += 1
    app.run("workspace.selectFirst")
    hidden_at = time.monotonic()
    phase = {"requested": count, "hidden": made, "grace_s": grace, "mix": recipes,
             "terminal_host_model": host_model, "terminal_host_model_requested": host_model}
    settled = settle_and_sample(f"hidden-{made}-settled")
    phase["settled"] = kind_deltas(base, settled, made)
    if host_model == "holder" and phase["settled"].get("terminal-host", {}).get("processes_added", 0) > 0:
        # Holder terminals start no terminal host: this daemon did not get the model (an older build).
        phase["terminal_host_model"] = "hosts"
    report = MemoryReport.read(app)
    if report is not None:
        phase["debug_memory_settled"] = report.workspaces()
        phase["hidden_iosurface_mb_settled"] = report.hidden_iosurface_mb()
    after = settled
    if grace > 0:
        time.sleep(max(0.0, grace - (time.monotonic() - hidden_at)))  # test script: the hidden workspaces' grace
        after = settle_and_sample(f"hidden-{made}-grace")
        report = MemoryReport.read(app)
        if report is not None:
            phase["debug_memory_after_grace"] = report.workspaces()
            phase["hidden_iosurface_mb_after_grace"] = report.hidden_iosurface_mb()
    phase["after_grace"] = kind_deltas(base, after, made)
    print(f"== hidden workspaces: {made} of {count} hidden (mix {','.join(recipes)}), grace {grace:.0f} s, "
          f"terminal host model {phase['terminal_host_model']}"
          + (f" (requested {host_model}; the daemon started terminal hosts)"
             if phase["terminal_host_model"] != host_model else ""))
    print(f"   {'kind':<22}{'added':>7}{'MB/ws settled':>15}{'MB/ws after grace':>19}")
    for kind, entry in phase["after_grace"].items():
        early = phase["settled"].get(kind, {"mb_each": 0.0})
        print(f"   {kind:<22}{entry['processes_added']:>+7}{early['mb_each']:>15.3f}{entry['mb_each']:>19.3f}")
    states = phase.get("debug_memory_after_grace", phase.get("debug_memory_settled"))
    if states is None:
        print("   debug.memory: not in this build; process footprint only")
    else:
        for state, entry in sorted(states.items()):
            print(f"   debug.memory workspaces {state:<10}{entry['count']:>5}  attributed {entry['attributed_mb']:.2f} MB  "
                  f"terminals {entry['terminal_surfaces']} (GPU-resident {entry['gpu_resident_surfaces']})")
        iosurface = phase.get("hidden_iosurface_mb_after_grace", phase.get("hidden_iosurface_mb_settled"))
        shown = "unknown" if iosurface is None else f"{iosurface:.2f} MB"
        print(f"   hidden terminal IOSurface (non-volatile): {shown}")
    sys.stdout.flush()
    return phase


def set_pressure(app: App, level: str) -> tuple[str, str | None]:
    """The debug pressure override (DEBUG and bench-hook builds), which the memory coordinator and browser
    hibernation both take (p07-memory-004); `none` clears it and hands both the kernel's level again.
    ("set", None) when the reply's `override` is `level` (null for `none`); ("missing", error) when this build
    has no such method; ("failed", why) for anything else (a timeout, a refusal, another override)."""
    reply = app.call("debug.hibernation.pressure", {"level": level}, timeout=30)
    error = reply.get("error")
    if error is not None:
        # ControlRouter.methodNotFound: a release build without the debug method.
        return ("missing" if "method_not_found" in str(error) else "failed"), str(error)
    want = None if level == "none" else level
    if "override" not in reply or reply["override"] != want:
        return "failed", f"override {reply.get('override', 'absent')!r}, not {want!r}: {json.dumps(reply)[:200]}"
    return "set", None


def pressure_phase(app: App, app_pid: int, level: str, window: float, interval: float, settle_and_sample) -> dict:
    """DC10. Sets the pressure override to `level` and follows the app's footprint for `window` seconds
    through proc_pid_rusage (no request to the app while it releases). released_mb is the app footprint
    before minus the lowest in the window, release_s the time to 90 % of that drop, counted from the moment
    the override request is sent (the app releases in the request's own main-actor turn), and the managed
    consumers' footprint before is what the drop should reach 80 % of."""
    before = settle_and_sample(f"pressure-{level}-before")
    phase: dict = {"level": level, "window_s": window}
    report = MemoryReport.read(app)
    if report is not None:
        managed, unknown = report.managed_bytes()
        phase.update({"managed_before_mb": round(managed / MB, 1), "managed_unknown": unknown,
                      "managed_consumers_before": report.managed(), "level_before": report.level()})
    start = usage(app_pid)
    if start is None:
        raise SystemExit("bench-memory: the app exited before the pressure phase")
    began = time.monotonic()
    outcome, error = set_pressure(app, level)
    if outcome == "missing":
        print(f"== pressure {level}: skipped, this build has no debug.hibernation.pressure override "
              "(DEBUG and bench-hook builds have it)")
        phase["skipped"] = "no pressure override"
        return phase
    timeline = [(0.0, start[1])]
    try:
        if outcome == "failed":
            # The override may be set all the same (a reply that timed out); the finally clears it.
            print(f"== pressure {level}: the override request failed: {error}")
            phase["error"] = error
            return phase
        while True:
            got = usage(app_pid)
            if got is None:
                break
            timeline.append((round(time.monotonic() - began, 3), got[1]))
            if time.monotonic() - began >= window:
                break
            time.sleep(interval)  # test script: footprint samples while the app releases
        lowest = min(footprint for _, footprint in timeline)
        released = start[1] - lowest
        release_s = (next(t for t, footprint in timeline if start[1] - footprint >= 0.9 * released)
                     if released >= MB else None)
        phase.update({"app_before_mb": round(start[1] / MB, 1), "app_lowest_mb": round(lowest / MB, 1),
                      "released_mb": round(released / MB, 1), "release_s": release_s,
                      "timeline": [(t, round(footprint / MB, 1)) for t, footprint in timeline]})
        after = settle_and_sample(f"pressure-{level}-after")
        phase["kinds_delta_mb"] = {kind: entry["mb_each"] for kind, entry in kind_deltas(before, after, 1).items()}
        report = MemoryReport.read(app)
        if report is not None:
            managed, _ = report.managed_bytes()
            phase.update({"managed_after_mb": round(managed / MB, 1),
                          "managed_consumers_after": report.managed(), "level_after": report.level()})
    finally:
        cleared, why = set_pressure(app, "none")
        if cleared != "set":
            print(f"bench-memory: clearing the pressure override failed ({why}); the app may keep it",
                  file=sys.stderr)
            phase["clear_error"] = why
    if phase.get("managed_before_mb"):
        phase["released_pct_of_managed"] = round(100 * phase["released_mb"] / phase["managed_before_mb"], 1)
    release = f"{phase['release_s']:.2f}" if phase["release_s"] is not None else "n/a (under 1 MB)"
    print(f"== pressure {level} (override): released_mb {phase['released_mb']:.1f}, release_s {release}, "
          f"app {phase['app_before_mb']:.1f} -> lowest {phase['app_lowest_mb']:.1f} MB in {window:.0f} s")
    if "managed_before_mb" not in phase:
        print("   managed footprint before: unknown (no debug.memory in this build; process footprint only)")
    else:
        share = phase.get("released_pct_of_managed")
        print(f"   managed footprint before {phase['managed_before_mb']:.1f} MB "
              f"({phase['managed_unknown']} consumers unknown), after {phase.get('managed_after_mb', 'n/a')} MB, "
              f"released {f'{share:.0f} %' if share is not None else 'n/a'} of managed")
        before_rows, later = phase["managed_consumers_before"], phase.get("managed_consumers_after", {})
        empty = {"instances": 0, "footprint_bytes": 0, "unknown": 0}
        rows = sorted(((name, before_rows.get(name, empty), later.get(name, empty))
                       for name in set(before_rows) | set(later)),
                      key=lambda row: row[2]["footprint_bytes"] - row[1]["footprint_bytes"])
        for name, first, last in rows[:10]:
            unknown = first["unknown"] + last["unknown"]
            print(f"   {first['footprint_bytes'] / MB:>8.1f} -> {last['footprint_bytes'] / MB:>8.1f} MB  {name} "
                  f"(x{first['instances']} -> x{last['instances']}{f', {unknown} unknown' if unknown else ''})")
    print("   footprint change per kind (after - before):")
    for kind, delta in phase["kinds_delta_mb"].items():
        print(f"   {kind:<22}{delta:>+10.1f} MB")
    sys.stdout.flush()
    return phase


KERNEL_LEVELS = {"warn": 2, "critical": 4}
MEMORY_PRESSURE = "/usr/bin/memory_pressure"


def kernel_pressure_level() -> int | None:
    """kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4 critical): the
    level the app's KernelMemoryPressureSource reads on each event. None when
    sysctl fails."""
    value = ctypes.c_int32(0)
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if _libsystem.sysctlbyname(b"kern.memorystatus_vm_pressure_level", ctypes.byref(value),
                               ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
        return None
    return value.value


def owned_footprint_mb(app_pid: int, bundle: str) -> float:
    total = 0
    for pid in owned(app_pid, bundle):
        got = usage(pid)
        if got is not None:
            total += got[1]
    return round(total / MB, 1)


def kernel_pressure(app_pid: int, bundle: str, level: str, window: float, workspaces: int, top: int) -> dict:
    """Real kernel pressure (`memory_pressure -S -l LEVEL`), not the app's
    debug override: the kernel's level changes, every process's dispatch
    source fires, and the app reads the new level. Samples the footprint of
    the app and its processes before, every 0.5 s for `window` seconds, and
    after. memory_pressure -S needs root: without it (and without passwordless
    sudo) this records why and the run goes on.

    memory_pressure holds the level for -s seconds, then resets it to normal;
    it has no signal handler, so a killed simulator never resets. The hold is
    the window, so it ends with the window; on an interrupt the run waits only
    for the rest of the hold, then terminates the simulator."""
    hold = max(1, math.ceil(window))
    result = {"level": level, "window_s": window}
    argv = [MEMORY_PRESSURE, "-S", "-l", level, "-s", str(hold)]
    if not os.access(MEMORY_PRESSURE, os.X_OK):
        result["skipped"] = f"{MEMORY_PRESSURE} not found"
    elif os.geteuid() != 0:
        if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
            result["skipped"] = "memory_pressure -S needs root: run as root or allow passwordless sudo"
        argv = ["sudo", "-n"] + argv
    if "skipped" in result:
        print(f"bench-memory: --kernel-pressure {level} skipped: {result['skipped']}", flush=True)
        return result
    want = KERNEL_LEVELS[level]
    before = sample(app_pid, bundle, f"kernel-pressure-{level}-before", workspaces)
    print_sample(before, top)
    result["kernel_level_before"] = kernel_pressure_level()
    simulator = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    started = time.monotonic()
    timeline = []
    try:
        while time.monotonic() - started < window:
            time.sleep(0.5)  # test script: the footprint timeline under pressure
            seen = kernel_pressure_level()
            timeline.append({"t_s": round(time.monotonic() - started, 2), "kernel_level": seen,
                             "total_footprint_mb": owned_footprint_mb(app_pid, bundle)})
            if seen == want and "kernel_level_reached_s" not in result:
                result["kernel_level_reached_s"] = timeline[-1]["t_s"]
            if simulator.poll() is not None and simulator.returncode != 0:
                break
        after = sample(app_pid, bundle, f"kernel-pressure-{level}-after", workspaces)
        print_sample(after, top)
    except BaseException:
        # Ctrl-C or SIGTERM: wait at most for the rest of the hold (its reset), then stop it.
        stop_simulator(simulator, max(0.0, hold - (time.monotonic() - started)) + 2)
        raise
    _, errors = stop_simulator(simulator, hold + 10)
    result["kernel_level_after"] = kernel_pressure_level()
    if simulator.returncode != 0:
        result["simulator_error"] = (errors or "").strip()[:300] or f"exit {simulator.returncode}"
    fall = before["total_footprint_mb"] - after["total_footprint_mb"]
    result.update({"timeline": timeline, "footprint_before_mb": before["total_footprint_mb"],
                   "footprint_after_mb": after["total_footprint_mb"], "fall_mb": round(fall, 1),
                   "fall_pct": round(100 * fall / before["total_footprint_mb"], 1) if before["total_footprint_mb"] else None,
                   "samples": [before, after]})
    print(f"PERF-KERNEL-PRESSURE level={level} kernel_level_reached_s={result.get('kernel_level_reached_s')} "
          f"footprint_before_mb={result['footprint_before_mb']} footprint_after_mb={result['footprint_after_mb']} "
          f"fall_mb={result['fall_mb']} fall_pct={result['fall_pct']} "
          f"simulator_error={result.get('simulator_error')}", flush=True)
    if "kernel_level_reached_s" not in result:
        print(f"bench-memory: kern.memorystatus_vm_pressure_level never reached {want} within {window} s", flush=True)
    return result


def stop_simulator(simulator: subprocess.Popen, timeout: float) -> tuple[str | None, str | None]:
    """Waits up to `timeout` s for memory_pressure to reset the level and
    exit; terminates it after that, saying the level may stay simulated."""
    try:
        return simulator.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        simulator.terminate()
        print("bench-memory: memory_pressure did not end with its hold and was terminated; the simulated "
              "level stays until the next memory_pressure -S run resets it", file=sys.stderr, flush=True)
        return simulator.communicate()


def launch_env(cef_switches: str, host_model: str | None) -> dict:
    """The launch knobs of the app's environment. The app strips every inherited CMUX_* variable that is not
    CMUX_NEXT_* (LaunchIdentity.stripInheritedEnvironment), so the daemon's host model goes under its app name,
    which DaemonDiagnosticKnobs passes on to the daemon."""
    env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": cef_switches} if cef_switches else {}
    if host_model:
        env["CMUX_NEXT_TUI_TERMINAL_HOST_MODEL"] = host_model
    return env


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the .app bundle")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--workspaces", help="workspace counts to sample (default 1,10,30; 1 with --hidden-workspaces)")
    parser.add_argument("--mix", default="terminal+chat,terminal+browser,terminal")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--measure", type=float, default=0,
                        help="seconds of idle CPU and wakeup measurement after each settle (0: memory only)")
    parser.add_argument("--churn-minutes", type=float, default=0)
    parser.add_argument("--sample-minutes", type=float, default=5)
    parser.add_argument("--url", default="https://example.com")
    parser.add_argument("--tabs", help="browser-tab counts to sample, e.g. 1,10,20 (instead of --workspaces)")
    parser.add_argument("--urls", default="local", help="--tabs: local, real or a comma list of URLs")
    parser.add_argument("--cef-switches", default="",
                        help="launch, DEBUG builds: extra Chromium switches, colon-separated (CMUX_NEXT_CEF_EXTRA_SWITCHES)")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--config", default="{}",
                        help='launch: cmux.json settings as JSON, e.g. \'{"browser": {"hibernation": 1}}\'')
    parser.add_argument("--fake-agent", metavar="SCRIPT",
                        help="an ACP agent script (cmux-tui/crates/acpmux/tests/fake_agent.py) the chats use: "
                             "its turns end, as a chat's do after its reply")
    parser.add_argument("--hidden-workspaces", type=int, metavar="N",
                        help="hidden-workspace phase: open N workspaces of --mix, show the first one again, and "
                             "print the footprint each hidden workspace adds per process kind, after --settle and "
                             "after --grace")
    parser.add_argument("--grace", type=float, default=0, metavar="S",
                        help="--hidden-workspaces: seconds after the workspaces went hidden for the second sample "
                             "(960 is past the 15 min parked idle timeout)")
    parser.add_argument("--terminal-host-model", choices=("hosts", "holder"),
                        help="launch: the daemon's terminal host model (CMUX_NEXT_TUI_TERMINAL_HOST_MODEL on the app, "
                             "which its daemon launch passes on as CMUX_TUI_TERMINAL_HOST_MODEL); default hosts, the "
                             "daemon's default. --hidden-workspaces names it")
    parser.add_argument("--pressure", choices=("warning", "critical"),
                        help="pressure phase, last: set the debug pressure override (DEBUG and bench-hook builds) "
                             "and print released_mb, release_s and the managed consumers' footprint before")
    parser.add_argument("--pressure-window", type=float, default=10, metavar="S",
                        help="--pressure: seconds of footprint samples after the override")
    parser.add_argument("--kernel-pressure", choices=sorted(KERNEL_LEVELS),
                        help="after the counts, feed real kernel pressure (/usr/bin/memory_pressure -S, needs root "
                             "or passwordless sudo) and sample the footprint before, during and after")
    parser.add_argument("--kernel-pressure-window", type=float, default=5,
                        help="--kernel-pressure: seconds to sample under pressure")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.grace and args.hidden_workspaces is None:
        parser.error("--grace needs --hidden-workspaces")
    if args.hidden_workspaces is not None and args.tabs:
        parser.error("--hidden-workspaces and --tabs are separate runs")
    if args.terminal_host_model and args.socket:
        parser.error("--terminal-host-model sets the model of an app this run launches, not of an attached one")
    # SIGTERM (a timeout, a scheduler) ends the run through its cleanup, as Ctrl-C does.
    signal.signal(signal.SIGTERM, interrupted)
    if sys.platform != "darwin":
        raise SystemExit("bench-memory: macOS only (run it on a fleet or capture mini)")

    bundle = os.path.realpath(args.app)
    launched = scratch = None
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-memory: --socket needs --app-pid")
        socket_path, app_pid = args.socket, args.app_pid
        host_model = "unknown-attach"
    else:
        host_model = args.terminal_host_model or "hosts"
        launched, socket_path, scratch = launch(bundle, json.loads(args.config),
                                                launch_env(args.cef_switches, args.terminal_host_model))
        app_pid = launched
    app = App(bundle, socket_path)
    chats = None
    recipes = args.mix.split(",")
    workspaces = args.workspaces or ("1" if args.hidden_workspaces is not None else "1,10,30")
    counts = sorted(int(n) for n in workspaces.split(",") if n)
    report = {"app": bundle, "mix": recipes, "settle_s": args.settle, "samples": [], "cef_switches": args.cef_switches,
              "webkit_attributed": _responsible is not None}
    opened = []

    def settle_and_sample(label):
        time.sleep(args.settle)  # test script: let the app and its helpers go idle
        result = sample(app_pid, bundle, label, len(opened) + 1, args.measure)
        report["samples"].append(result)
        print_sample(result, args.top)
        return result

    try:
        if args.fake_agent:
            chats = FakeChats(app, bundle, args.fake_agent)
        settle_and_sample("idle-launch")
        if args.tabs:
            tab_counts = sorted(int(n) for n in args.tabs.split(",") if n)
            urls = tab_urls(args.urls, max(tab_counts))
            report["tabs"] = tab_counts
            report["urls"] = args.urls
            made = 0
            for count in tab_counts:
                while made < count and open_browser_tab(app, urls[made]):
                    made += 1
                result = settle_and_sample(f"tabs-{made}")
                result["tabs"] = made
            counts = []
        for count in counts:
            # The launch workspace counts as the first one.
            while len(opened) + 1 < count:
                workspace = open_workspace(app, recipes[len(opened) % len(recipes)], args.url, len(opened), chats)
                if workspace is None:
                    break
                opened.append(workspace)
            settle_and_sample(f"idle-{count}")
        report["debug_memory"] = MemoryReport.read(app) is not None
        if not report["debug_memory"] and (args.hidden_workspaces is not None or args.pressure):
            print("bench-memory: this build has no debug.memory; the phases report process footprint only")
        if args.hidden_workspaces is not None:
            report["hidden_workspaces"] = hidden_workspaces_phase(app, args.hidden_workspaces, args.grace, recipes,
                                                                  args.url, opened, chats, settle_and_sample,
                                                                  host_model)
        if args.kernel_pressure:
            report["kernel_pressure"] = kernel_pressure(app_pid, bundle, args.kernel_pressure,
                                                        args.kernel_pressure_window, len(opened) + 1, args.top)
        if args.churn_minutes > 0:
            end = time.monotonic() + args.churn_minutes * 60
            next_sample = time.monotonic() + args.sample_minutes * 60
            cycles = 0
            while time.monotonic() < end:
                workspace = open_workspace(app, recipes[cycles % len(recipes)], args.url, 1000 + cycles, chats)
                time.sleep(2)  # test script: let the new tabs load before closing them
                if workspace:
                    close_workspace(app, workspace)
                cycles += 1
                if time.monotonic() >= next_sample:
                    settle_and_sample(f"churn-{cycles}")
                    next_sample = time.monotonic() + args.sample_minutes * 60
            report["churn_cycles"] = cycles
            churn = [s for s in report["samples"] if s["label"].startswith("churn-")]
            base = report["samples"][-len(churn) - 1] if churn else None
            if base and churn:
                growth = {}
                for kind in set(base["kinds"]) | set(churn[-1]["kinds"]):
                    first = base["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    last = churn[-1]["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    growth[kind] = round(last - first, 1)
                report["churn_growth_mb"] = dict(sorted(growth.items(), key=lambda item: -item[1]))
                print(f"== churn: {cycles} open/close cycles; footprint growth at {base['workspaces']} workspaces:")
                for kind, delta in report["churn_growth_mb"].items():
                    print(f"   {kind:<22}{delta:>+10.1f} MB")
        if args.pressure:
            # Last: a lossy release (discarded pages, torn-down workspaces) changes what any later phase measures.
            report["pressure"] = pressure_phase(app, app_pid, args.pressure, args.pressure_window, 0.1,
                                                settle_and_sample)
    finally:
        for workspace in opened:
            close_workspace(app, workspace)
        if launched is not None:
            app.run("quit")
            # A quit the app holds (a confirmation) and SIGTERM can both leave
            # it running, and a live app respawns its daemons: end it first.
            wait_gone(launched, 20)
            end_bundle(bundle)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=2)
            print(f"bench-memory: wrote {args.out}")
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
