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

--purge-hidden also measures, after each count's sample, what Chromium's own
memory purge gives back with nothing reloaded: every hidden cmux page's renderer
gets a critical memory-pressure notice (DevTools Memory.simulatePressureNotification
through `debug.cef_page_devtools`, a bench or DEV build), then the app settles and
is sampled again as `purged-N` (one count per run, so `idle-N` is an unpurged app). The page keeps its DOM, scroll and state, as the
"a page never reloads unless the person asks" design (#25791) requires.

--release-hidden-chats MINUTES measures lossless discard of hidden agent chats (Leo, 2026-11-07:
"if it really isn't being used after a while, can't things be more aggressive?"): the app runs with
the app runs with discard off until the count's `idle-N` sample, then the bench sets
`agents.hiddenChats.discardAfterMinutes` MINUTES and `agents.hiddenChats.discard` on through the
app's `settings.set` (its own settings writer; the reply's values are kept in the sample), so the
baseline holds no released chat. It waits for the hidden chats to be
released, samples `released-N` with the live Chromium page count, then shows the --restore-chats oldest
workspaces' chat tabs one at a time and times each chat back on screen with the app's own chat-open trace
(`debug.chat_open_trace`: first content, first kept image, longest empty run). The trace binds only to
a chat that loads again; a chat whose page stayed live shows at once and is counted as `live`, not
timed. One count per run, like --purge-hidden.

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
      [--url URL] [--top 15] [--config JSON] [--fake-agent SCRIPT] [--purge-hidden]
      [--release-hidden-chats MINUTES [--restore-chats 10]] [--out FILE.json]
  bench_memory.py --app BUNDLE --tabs 1,10,20 [--urls local|real|URL,URL,...] [--settle 30]

Prints a table per measurement (top processes by footprint, totals per
kind) and writes every sample to --out.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
try:
    _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
    _responsible.restype = ctypes.c_int
    _responsible.argtypes = [ctypes.c_int]
except AttributeError:  # an OS without the call: WebKit processes are not attributed
    _responsible = None

MB = 1048576.0


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
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
        elif _responsible is not None and "com.apple.WebKit." in cmd and webkit_owned(pid, app_pid):
            found[pid] = (kind_of(cmd, bundle), cmd)
    return found


# A direct launch (CMUX_BENCH_LAUNCH=direct) makes the app a child of this script, so macOS holds the
# script's own responsible process responsible for the app and for its WebKit processes too. Those
# then count as the app's when they did not run before the launch (`launch` records the ones that did).
_direct_launch = False
_webkit_before: set[int] = set()


def webkit_owned(pid: int, app_pid: int) -> bool:
    owner = _responsible(pid)
    if owner == app_pid:
        return True
    return _direct_launch and pid not in _webkit_before and owner == _responsible(app_pid)


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
               "footprint_mb": round(got[1] / MB, 1), "max_footprint_mb": round(got[2] / MB, 1),
               "command": cmd[:160]}
        if pid in start:
            row["cpu_pct"] = round(100 * (got[3] - start[pid][3]) / 1e9 / measure, 3)
            row["wakeups_per_s"] = round((got[4] - start[pid][4]) / measure, 2)
        rows.append(row)
    rows.sort(key=lambda row: -row["footprint_mb"])
    kinds = {}
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"count": 0, "rss_mb": 0.0, "footprint_mb": 0.0})
        entry["count"] += 1
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

    def action(self, action: str, *, focus: bool = False, wait: bool = True, **args) -> dict:
        """`action.run` over the socket itself: the CLI reads `--session`
        as its own option, so an action argument of that name never reaches
        the app through it. `focus` moves the app's focus to what the action
        opens or selects, as the user's shortcut would; without it a new tab
        opens in the background and does not load until it is shown. `wait`
        False answers once the handler ran, before the work it started ends."""
        params = {"action": action, "args": args, "wait": wait, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, label=action)

    def call(self, method: str, params: dict | None = None, timeout: float = 120, label: str | None = None) -> dict:
        """One control socket method: its result, or {"error": ...}."""
        action = label or method
        reply = b""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(timeout)
                stream.connect(self.socket)
                stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                while not reply.endswith(b"\n"):
                    chunk = stream.recv(65536)
                    if not chunk:
                        break
                    reply += chunk
        except OSError as error:  # includes a timeout: this workspace is skipped, the run goes on
            return {"error": f"{action}: {error}"}
        try:
            answer = json.loads(reply or b"{}")
        except ValueError:
            return {"error": reply.decode(errors="replace")[:300]}
        return {"error": json.dumps(answer["error"])[:300]} if answer.get("error") else answer.get("result") or {}

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
# The first prompt of each --fake-agent chat (--chat-prompt); the fake agent echoes it back, so a
# long one gives the chat a long history to hold.
CHAT_PROMPT = ""


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
        # The app splits `args` into words like a shell: a fleet step's checkout is under
        # "/Library/Application Support/...", so the path is quoted or the agent never starts.
        for attempt in range(5):
            added = app.run("agent.harness.add", id=FAKE_AGENT_ID, name="Memory bench", command=sys.executable,
                            args=shlex.quote(os.path.abspath(script)), protocol="acp", replace="true")
            # The action answers "timeout" after 2 s while its work goes on (the harness is still added),
            # most often just after launch: wait, then try again (it replaces the same id).
            if "timeout" not in str(added.get("code") or added.get("error") or ""):
                break
            time.sleep(5)  # test script: the app is still starting; try again (5 tries)
        else:
            added = {}  # five timeouts: the work went on in the app; a missing harness fails `acp new` below
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

    def workspace_ids(self) -> set[str]:
        """The ids of the app's workspaces (`snapshot.get`)."""
        found: set[str] = set()

        def walk(node):
            if isinstance(node, dict):
                value = node.get("id")
                if isinstance(value, str) and value.startswith("ws_"):
                    found.add(value)
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(self.app.call("snapshot.get", timeout=30))
        return found

    def open(self, index: int) -> str | None:
        """A new workspace on a new answered chat; returns the workspace id."""
        made = subprocess.run([self.app.cli_path, "acp", "new", "--json", "-d", "-m", FAKE_AGENT_ID,
                               f"memory bench chat {index}" + (f"\n\n{CHAT_PROMPT}" if CHAT_PROMPT else "")],
                              capture_output=True, text=True, timeout=120, env=self.env)
        try:
            session = json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            print(f"   acp new: {(made.stdout + made.stderr).strip()[:300]}", file=sys.stderr)
            return None
        before = self.workspace_ids()
        response = self.app.action("agent.openSessionWorkspace", session=session)
        created = [item for item in response.get("created", []) if str(item).startswith("ws_")]
        if not created and "in_progress" in json.dumps(response):
            # The action answers "timeout" at its deadline while the open goes on (its state
            # "in_progress"): the workspace it makes is the one that was not there before.
            deadline = time.monotonic() + 60
            while not created and time.monotonic() < deadline:
                time.sleep(1)  # test script: waiting for the open that went on to make its workspace
                created = sorted(self.workspace_ids() - before)
        if not created:
            print(f"   agent.openSessionWorkspace: {response.get('error') or response}", file=sys.stderr)
            return None
        remember_chat_tab(created[0], response)
        return created[0]


def purge_hidden_pages(app: App) -> dict:
    """A critical memory-pressure notice to the renderer of every hidden cmux page, nothing reloaded.

    Chromium's own response to pressure: V8 collects and shrinks its heap, Blink drops its caches
    (decoded images, fonts, resources), Skia its GPU and raster caches. The notice goes to the
    page's renderer process, so a frozen page's renderer takes it too."""
    pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages")
    if not isinstance(pages, list):
        return {"error": "no debug.cef_pages (a bench or DEV build has it)"}
    hidden = [p for p in pages if p.get("hidden") and str(p.get("origin", "")).startswith("cmux-page://")]
    params = {"method": "Memory.simulatePressureNotification", "params": {"level": "critical"}}

    def notify(page):
        reply = app.call("debug.cef_page_devtools", dict(params, browser=page["browser"]), timeout=40)
        return reply.get("error")

    with ThreadPoolExecutor(max_workers=8) as pool:
        errors = [error for error in pool.map(notify, hidden) if error]
    return {"pages": len(pages), "hidden": len(hidden), "notified": len(hidden) - len(errors),
            "errors": errors[:5]}


# Each workspace's chat tab (from the `created` ids of the action that made it): a workspace shows the
# tab it showed last, which the terminal+chat mix leaves on its terminal, so a restore shows the chat itself.
CHAT_TABS: dict[str, str] = {}


def remember_chat_tab(workspace: str, response: dict):
    tab = next((str(item) for item in response.get("created", []) if str(item).startswith("tab_")), None)
    if tab:
        CHAT_TABS[workspace] = tab


def cef_page_count(app: App) -> int | None:
    """Live Chromium pages of cmux's own (`cmux-page://`), from `debug.cef_pages`."""
    pages = (app.call("debug.cef_pages", timeout=30) or {}).get("pages")
    if not isinstance(pages, list):
        return None
    return sum(1 for p in pages if str(p.get("origin", "")).startswith("cmux-page://"))


def percentile(values: list[float], share: float) -> float | None:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))] if ordered else None


def restore_chats(app: App, workspaces: list[str], count: int) -> dict:
    """Shows each of `workspaces[:count]` (oldest first: the least recently seen, released first) and
    times its chat back on screen with the app's chat-open trace."""
    opens = []
    for workspace in workspaces[:count]:
        tab = CHAT_TABS.get(workspace)
        armed = app.call("debug.chat_open_trace", {"action": "arm"}, timeout=30)
        if not isinstance(armed, dict) or armed.get("error"):
            opens.append({"workspace": workspace, "error": f"arm: {armed}"})
            continue
        shown = app.action("goToWorkspace", focus=True, workspace=workspace)
        if not shown.get("error"):
            # No recorded id: the chat is the tab before the terminal the mix added last. The trace
            # binds only when a chat loads, so a wrong guess reads as `live`, never as a restore time.
            shown = app.run("tab.focus", target=tab) if tab else app.action("prevSurface")
        trace = app.call("debug.chat_open_trace", {"action": "wait", "timeout_ms": 15000, "settle_ms": 300}, timeout=40) or {}
        frames = trace.get("frames") or []
        opens.append({
            "workspace": workspace, "tab": tab or "prevSurface",
            "error": shown.get("error") or trace.get("error"),
            "timed_out": trace.get("timed_out"),
            "first_content_ms": trace.get("first_content_ms"),
            "first_image_ms": next((ms for ms, surface in frames if surface == "image"), None),
            "longest_empty_ms": trace.get("longest_empty_ms"),
        })
    content = [o["first_content_ms"] for o in opens if isinstance(o.get("first_content_ms"), (int, float))]
    empty = [o["longest_empty_ms"] for o in opens if isinstance(o.get("longest_empty_ms"), (int, float))]
    errors = sum(1 for o in opens if o.get("error"))
    live = sum(1 for o in opens if not o.get("error") and o.get("timed_out") and o.get("first_content_ms") is None)
    return {"opens": opens, "n": len(content), "errors": errors, "live": live,
            "first_content_p50_ms": percentile(content, 0.5), "first_content_p95_ms": percentile(content, 0.95),
            "longest_empty_p50_ms": percentile(empty, 0.5), "longest_empty_p95_ms": percentile(empty, 0.95),
            "with_image": sum(1 for o in opens if o.get("first_image_ms") is not None)}


# The panes a workspace's recipe asked for that the app refused (the report's `pane_failures`).
PANE_FAILURES: list[str] = []


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
            remember_chat_tab(workspace, response)
        else:
            raise SystemExit(f"bench-memory: unknown kind {kind!r} in --mix")
        if response.get("error") or response.get("code"):
            print(f"   {kind} in {workspace}: {response.get('message') or response.get('error')}", file=sys.stderr)
            PANE_FAILURES.append(f"{kind} in {workspace}: {response.get('message') or response.get('error')}"[:200])
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


def end_processes(pids: set[int], grace: float = 10.0, kill_grace: float = 5.0):
    """SIGTERM every pid, then SIGKILL what is still there once `grace` s have passed for the whole set (one
    deadline, not one per pid), waiting at most `kill_grace` s more. A child of this script that exited is
    reaped (`gone`), so an unreaped zombie never holds the teardown."""
    for sig, seconds in ((signal.SIGTERM, grace), (signal.SIGKILL, kill_grace)):
        sent = set()
        for pid in pids:
            try:
                os.kill(pid, sig)
                sent.add(pid)
            except ProcessLookupError:
                pass
        pids = still_running(sent, seconds)
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


# Chromium's code-sign clone cleanup helper. CEF clones the app at each launch to
# $TMPDIR/../X/<bundle id>.code_sign_clone/ (about 1 GB); after the app quits, this
# helper (`<app>/Contents/MacOS/<exe> --type=code-sign-clone-cleanup`) removes the
# clone about 1 s later. Ended with the app, it leaves the clone until reboot: 29 GB
# on cmux18 (2026-11-02). A teardown lets it finish, up to CLONE_CLEANUP_WAIT_S.
CLONE_CLEANUP = "--type=code-sign-clone-cleanup"
CLONE_CLEANUP_WAIT_S = 15


def is_clone_cleanup(cmd: str) -> bool:
    return CLONE_CLEANUP in cmd


def end_bundle(bundle: str):
    """Ends every process of the bundle, the app first: a live app (it can
    ignore SIGTERM) respawns daemons ended before it. No process of this
    bundle ran before the launch (`launch`), so every one is this run's.
    Chromium's clone cleanup helper is ended last, and only when it is still
    there after CLONE_CLEANUP_WAIT_S."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    apps = {pid for pid, _, cmd in process_table() if cmd.startswith(binary_dir + "/") and not is_clone_cleanup(cmd)}
    bundle_pids(bundle)  # notes the daemons before they go, for their terminal hosts
    end_processes(apps)
    cleanups = {pid for pid, _, cmd in process_table() if in_bundle(cmd, bundle) is not None and is_clone_cleanup(cmd)}
    end_processes(bundle_pids(bundle) - cleanups)
    deadline = time.monotonic() + CLONE_CLEANUP_WAIT_S
    end_processes(still_running(cleanups, max(0.0, deadline - time.monotonic())))


def gone(pid: int) -> bool:
    """Whether `pid` has exited. A child of this script is reaped (waitpid): kill(pid, 0) succeeds on an
    unreaped zombie, which would read as alive until a timeout. Any other pid is probed with kill(pid, 0)."""
    try:
        reaped, _status = os.waitpid(pid, os.WNOHANG)
        return reaped == pid
    except ChildProcessError:
        pass  # not this script's child
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def still_running(pids: set[int], seconds: float) -> set[int]:
    """The pids not gone within `seconds`, one deadline for all; each is checked at least once."""
    deadline = time.monotonic() + seconds
    while True:
        pids = {pid for pid in pids if not gone(pid)}
        if not pids or time.monotonic() >= deadline:
            return pids
        time.sleep(0.05)  # test script: waiting for processes to exit


def wait_gone(pid: int, seconds: float) -> bool:
    """True once `pid` is gone; it is checked at least once, also with no time left."""
    return not still_running({pid}, seconds)


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


def exception_records(bundle: str, since: float) -> str:
    """The app's own record of the exception it died on (AppRunMarker's `run.exception`), written
    since `since`. The app reads the account's real home (`homeDirectoryForCurrentUser`), not the
    scratch HOME, so it is under ~/Library/Application Support/cmux-next/<bundle id>/."""
    import pwd
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
            bundle_id = plistlib.load(handle).get("CFBundleIdentifier", "")
    except OSError:
        return ""
    real_home = pwd.getpwuid(os.getuid()).pw_dir
    path = os.path.join(real_home, "Library", "Application Support", "cmux-next", bundle_id, "run.exception")
    if not bundle_id or not os.path.exists(path) or os.path.getmtime(path) < since:
        return ""
    with open(path, errors="replace") as handle:
        return f"\n--- {path}\n{handle.read()[:4000]}"


def downloads_dir(scratch: str) -> str:
    """The folder `launch` gives the app for its downloads (CMUX_NEXT_DOWNLOADS_DIR), in its scratch."""
    return os.path.join(scratch, "downloads")


def launch(bundle: str, config: dict, extra_env: dict | None = None, direct: bool | None = None,
           scratch: str | None = None):
    """Starts the app with a scratch HOME, TMPDIR and config; returns (pid, socket, scratch).

    `scratch` relaunches into an earlier launch's scratch (its HOME and state), as a relaunch after
    an update does (bench_relaunch_reconnect.py): that launch's daemons may still run then.

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
    relaunch = scratch is not None
    running = bundle_pids(bundle)
    if running and not relaunch:
        raise SystemExit(f"bench-memory: processes from {bundle} are running ({sorted(running)}); end them first")
    scratch = scratch or tempfile.mkdtemp(prefix="bench-memory-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
           # Downloads go to the scratch, never the account's real ~/Downloads (the app ignores HOME there, and
           # macOS asks for Downloads access in a prompt that covers a fleet Mac's screen). Debug and bench
           # builds only; a Release app ignores it (DownloadsFolder.swift).
           "CMUX_NEXT_DOWNLOADS_DIR": downloads_dir(scratch)}
    env.update(extra_env or {})
    # A None in `extra_env` drops that default (CMUX_NEXT_NO_ACTIVATE for a bench that needs the keyboard).
    env = {name: value for name, value in env.items() if value is not None}
    os.makedirs(env["TMPDIR"], exist_ok=True)
    os.makedirs(env["CMUX_NEXT_DOWNLOADS_DIR"], exist_ok=True)
    # Sparkle would otherwise download a newer nightly into the bundle under
    # test mid-run (and its installer counts as the bundle's process).
    with open(env["CMUX_NEXT_CONFIG_FILE"], "w") as handle:
        json.dump(merged({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, config), handle)
    log_path = os.path.join(scratch, "app.log")
    launched_at = time.time()
    if direct:
        global _direct_launch
        _direct_launch = True
        _webkit_before.update(p for p, _, cmd in process_table() if "com.apple.WebKit." in cmd)
        env.setdefault("CMUX_NEXT_TEST_WINDOW_FRAME", "40,40,1400,900")
        with open(log_path, "a") as log:
            child = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    else:
        child = None
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
        # A direct child that ended says how (its exit status, or the signal that ended it).
        ended = ""
        if child is not None and child.poll() is not None:
            code = child.returncode
            ended = f"; the app process {child.pid} ended with {'signal ' + str(-code) if code < 0 else 'exit status ' + str(code)}"
        elif child is not None:
            ended = f"; the app process {child.pid} still runs, as {next((cmd for p, _, cmd in process_table() if p == child.pid), '?')[:200]!r}"
        raise SystemExit(f"bench-memory: the launched app opened no socket within 90 s "
                         f"(app pid {pid or 'none: it did not start'}{ended}; {state}: {seen}; "
                         f"launch {'direct' if direct else 'open'})" + tail(log_path) + exception_records(bundle, launched_at))
    except BaseException:
        end_bundle(bundle)
        if not relaunch:
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


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the .app bundle")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--workspaces", default="1,10,30")
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
    parser.add_argument("--purge-hidden", action="store_true",
                        help="after each count, purge hidden pages' renderers (no reload) and sample again")
    parser.add_argument("--release-hidden-chats", type=float, default=0, metavar="MINUTES",
                        help="run with agents.hiddenChats.discard after MINUTES; sample released chats and time their restore")
    parser.add_argument("--restore-chats", type=int, default=10,
                        help="--release-hidden-chats: how many released chats to show again and time")
    parser.add_argument("--chat-prompt", default="",
                        help="--fake-agent: text added to each chat's first prompt (echoed back: a chat with history)")
    parser.add_argument("--out")
    args = parser.parse_args()
    global CHAT_PROMPT
    CHAT_PROMPT = args.chat_prompt
    if (args.purge_hidden or args.release_hidden_chats > 0) and len([n for n in args.workspaces.split(",") if n]) > 1:
        # A later count's idle sample would follow the earlier purge, not an unpurged app. Checked
        # before the launch, so a refused run leaves no app behind.
        parser.error("--purge-hidden and --release-hidden-chats take one --workspaces count; run each count on its own")
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
    else:
        extra = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": args.cef_switches} if args.cef_switches else {}
        config = json.loads(args.config)
        launched, socket_path, scratch = launch(bundle, config, extra)
        app_pid = launched
    app = App(bundle, socket_path)
    chats = None
    recipes = args.mix.split(",")
    counts = sorted(int(n) for n in args.workspaces.split(",") if n)
    report = {"app": bundle, "mix": recipes, "settle_s": args.settle, "samples": [], "cef_switches": args.cef_switches,
              "webkit_attributed": _responsible is not None}
    opened = []

    def settle_and_sample(label):
        time.sleep(args.settle)  # test script: let the app and its helpers go idle
        result = sample(app_pid, bundle, label, len(opened) + 1, args.measure)
        result["pane_failures"] = len(PANE_FAILURES)
        report["samples"].append(result)
        report["pane_failures"] = PANE_FAILURES[:20]
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
            if args.purge_hidden:
                purge = purge_hidden_pages(app)
                print(f"== purge at {count}: {json.dumps(purge)}", flush=True)
                settle_and_sample(f"purged-{count}")["purge"] = purge
            if args.release_hidden_chats > 0:
                before = cef_page_count(app)
                applied = {}
                for key, value in (("agents.hiddenChats.discardAfterMinutes", args.release_hidden_chats),
                                   ("agents.hiddenChats.discard", True)):
                    reply = app.call("settings.set", {"path": key, "value": value}, timeout=30) or {}
                    applied[key] = reply.get("value") if not reply.get("error") else f"error: {reply.get('error')}"
                print(f"== discard settings: {json.dumps(applied)}", flush=True)
                # test script: the hidden chats come due after the setting's minutes (plus the planner's slack)
                time.sleep(args.release_hidden_chats * 60 + 30)
                result = settle_and_sample(f"released-{count}")
                result["cef_pages"] = {"before": before, "after": cef_page_count(app)}
                result["discard_settings"] = applied
                print(f"== released at {count}: cmux pages {json.dumps(result['cef_pages'])}", flush=True)
                report["restore"] = restore_chats(app, opened, args.restore_chats)
                print(f"== restore: {json.dumps({k: v for k, v in report['restore'].items() if k != 'opens'})}", flush=True)
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
