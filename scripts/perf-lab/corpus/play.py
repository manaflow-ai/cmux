#!/usr/bin/env python3
"""Corpus story player: replays a recorded session into a bench app and measures it (p12-perf-process.md 3.8, task 115).

    python3 -I scripts/perf-lab/corpus/play.py perf-corpus/dev-loop.json --app APP --out DIR
    python3 -I scripts/perf-lab/corpus/play.py --all --verify --app APP --out DIR

One replay of a recorded manifest (schemas/perf/corpus-story-v1.schema.json):

  1. Load and check before any launch: the manifest validator (manifest.py, text checks included, also for an
     input blob), the layout snapshot (session_io.check), every key code and click count the player must send,
     every layout reference, the modules the story's tracks need (pty_replay.py, wpr.py, agent_replay.py and the
     functions the player calls in them), and the sources (blobs are fetched into the corpus cache now, so nothing
     is fetched while the app runs).
  2. Web Page Replay (wpr.py, task 113): `wpr replay` of the story's archive on the bench host (WprServer, the
     wpr build host-setup.sh made, its certificate checked against the story's spki), the bench bundle's Chromium
     storage emptied, and its switch pair (bench_switches) in the app's launch environment as
     CMUX_NEXT_BENCH_CEF_SWITCHES. Agent tracks (agent_replay.py, task 114): the transcripts and the replay harness
     installed in the bench's acpmux home (install, bench_acpmux_home) and launch_env in the app's environment.
     Then the bench app launches (bench_launch.BenchApp, with the manifest's `config` settings over its default
     config; a failed launch raises bench_launch.LaunchError) and the layout is imported (session_io.import_layout).
  3. Each PTY track's terminal gets `play.py pty-track --go FIFO -- <pty_replay.py args>` (task 112): pty_replay
     loads its recording, then its clock waits on the FIFO. The player waits until every track holds its FIFO.
     Each agent track's chat tab is resolved; its prompt `replay <transcript sha256>` (agent_replay's PROMPT) goes
     through `debug.agent_pane send_prompt`, which reaches the agent tab a window shows, so an agent track must
     name the selected tab of a pane in the shown workspace (no socket method prompts a hidden chat tab).
  4. The measured window: signposts (`log stream`, perf-signposts.py) and `debug.frames` run around it, and the
     `window(bench)` hook of `replay()` wraps it. At the input track's origin the player releases every PTY FIFO
     and sends every agent prompt (on its own control connection), so all tracks keep their recorded offsets.
     Each input event is sent at its recorded time on absolute deadlines (a late send does not shift the ones
     after it, as Chromium's base::MetronomeTimer keeps a fixed phase, base/timer/timer.h):
       key    debug.key with the client's send time as the event's timestamp (CLOCK_UPTIME_RAW); a typing key
              has no key code in the corpus and types the next character of the fixed SYNTHETIC text
       mouse  debug.mouse at the recorded window point
       action action.run (origin script)
       cli    the app's bundled cmux CLI, a process the player does not wait for
     Socket events are pipelined on one control connection: the player writes each request at its deadline and
     never waits for its reply on the schedule path, so the app's response time is not the player's timing error.
     The app serves a connection's requests in order, so the events apply in their recorded order; a key that
     waits behind a slow reply carries that wait in its age (its timestamp is its send time). The replies are read
     at each checkpoint and after the last event, and an error reply fails the replay naming its event. Layout
     references are resolved before the event's deadline; the player reads the topology again only after an event
     that can change it, and that read waits for the events before it. When it ends past the event's deadline the
     rest of the schedule moves by that much (`waited_ms`), as it does by a checkpoint's own time (`paused_ms`),
     so the recorded spacing of events stays. Lateness is measured at the socket write (the CLI's spawn), after
     the references are resolved.
     At each checkpoint the player reads debug.focus and debug.surfaces and compares their digests with the
     recorded ones; the first one that differs (after CHECKPOINT_SETTLE_S) ends the replay with DigestMismatch.
  5. Write result-v1 (BenchApp.record, session corpus:<id>) for each series the manifest declares:
       key_to_frame         key.frame signposts plus the key's age (send to the end of its frame's commit)
       action_to_frame      action.commit
       switch_to_frame      switch.workspace, switch.tab and switch.pane_focus
       tab_switch_to_frame  switch.tab
       dropped_frames       debug.frames `missed` over the window
     as `corpus.<id with _ for ->.<series>`. A declared metric the player does not compute is listed as
     unmeasured in the summary (its story measures it around `replay()`). That includes `cli_to_frame`: the
     vocabulary's CLI commands are daemon resource ops (cmux-tui maps `workspace W move` to the daemon's
     workspace.move), which never run through the app's ActionRegistry, so no app signpost names them; the series
     needs one (or a correlation id the app echoes) first. A replay whose send lateness p95 is over --max-late-ms
     did not keep its timing: it raises ScheduleError and writes no result.

Layout references are positions in the app's `snapshot.get` topology at the moment of the event: `@w3.p0.t1` is
workspace 3 (sidebar order), pane 0 (its screen's pane list) and tab 1 (its pane's order); `@g0` is workspace group
0 (`workspace_groups` order); `@win1` is the first window other than the main one (the first window that shows a
workspace when the replay starts) in `windows` order, as the recorder (task 116, ``WindowRefs``) numbers the windows
it sees. A key or mouse event with no `window` goes to the main window.

--verify plays each story twice: the checkpoint digests of both runs must be equal; each latency metric with at
least VERIFY_MIN_SAMPLES samples in both runs must have p50s within --max-cv (coefficient of variation over the two
runs), and each count metric (unit `count`) must agree within VERIFY_COUNT_TOLERANCE or --max-cv. --all plays every
recorded, non-compose story of perf-corpus/; a planned story is listed as skipped, and a run that plays nothing fails.

`replay(manifest, *, app, out, window=None)` is the API stories that measure around a replay call
(blocking_hangs.py, main_turn.py). `out` gets the replay's result-v1 files, its summary and the
host-env-full-<pid>.json of its launch.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_play.py
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import hashlib
import importlib.util
import json
import math
import os
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]
CORPUS_DIR = "perf-corpus"
NS_PER_MS = 1_000_000

MAX_LATE_P95_MS = 5.0       # a replay later than this at p95 did not replay its recorded timing
CHECKPOINT_SETTLE_S = 5.0   # how long a checkpoint waits for the recorded state before it fails
CHECKPOINT_POLL_S = 0.05
VERIFY_MAX_CV = 0.10        # --verify: the largest coefficient of variation of a metric's p50 over two runs
VERIFY_MIN_SAMPLES = 10     # --verify: fewer samples than this make no p50 worth a CV
VERIFY_COUNT_TOLERANCE = 2  # --verify: how far a count metric (dropped frames) may differ between two runs
RPC_TIMEOUT_S = 10
CLI_TIMEOUT_S = 60
PTY_READY_TIMEOUT_S = 30    # how long a PTY track's process may take to start and open its go FIFO
SIGNPOST_CATEGORIES = ("key", "action", "switch")
GO = b"g"

# The fixed synthetic text a typing key types, per key class: the corpus records the class, never the character.
SYNTHETIC = {"letter": "thequickbrownfoxjumpsoverthelazydog", "digit": "0123456789", "punctuation": ".,;-/'",
             "space": " ", "other": "=[]"}
# debug.key's names for the key codes a corpus key may carry (DebugKey.named and ansiKeyCodes, macOS ANSI codes).
KEY_NAMES = {0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
             13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
             24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i",
             35: "p", 36: "return", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
             45: "n", 46: "m", 47: ".", 48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
             115: "home", 116: "pageup", 117: "forwarddelete", 119: "end", 121: "pagedown", 123: "left",
             124: "right", 125: "down", 126: "up"}
MODIFIERS = {"cmd": "cmd", "shift": "shift", "option": "option", "ctrl": "ctrl"}  # fn and caps: debug.key has none
BUTTONS = {0: "left", 1: "right", 2: "middle"}
REF = re.compile(r"@(?:w(\d+)(?:\.p(\d+)(?:\.t(\d+))?)?|g(\d+)|win(\d+))")
REF_KINDS = ("workspace", "pane", "tab")
TARGET_KINDS = frozenset(REF_KINDS)

# The fields of debug.surfaces rows and debug.focus windows a checkpoint digest covers: state, never an id, a
# time, a counter or a field that changes with load (a page's paint phase, warm-terminal counts).
SURFACE_FIELDS = ("visible", "presence", "kind", "content_installed", "content_in_window", "content_size", "blank",
                  "collapsed", "focused")
FOCUS_CONTEXT = ("terminal_focused", "browser_focused", "agent_focused", "palette_open")

# The functions the player calls in its sibling tracks' modules; a module without one is refused before launch.
WPR_API = ("WprError", "WprServer", "wpr_commit", "default_wpr_dir", "checked_wpr_dir", "spki_of_pem",
           "bench_bundle_problem", "chromium_root", "empty_chromium_root", "bench_switches", "bench_env")
AGENT_API = ("install", "bench_acpmux_home", "launch_env")


class PlayError(RuntimeError):
    """The story cannot be replayed, or the replay diverged from the recording."""


class DigestMismatch(PlayError):
    def __init__(self, checkpoint: str, t_ms: float, which: str, want: str, got: str):
        self.checkpoint, self.which = checkpoint, which
        super().__init__(f"checkpoint {checkpoint} (t={t_ms:g} ms): the {which} digest is {got[:12]}, the recording's "
                         f"is {want[:12]}")


class ScheduleError(PlayError):
    pass


def _load(name: str, path: Path):
    """The module at `path` as `name`, once per process: stories share one bench_launch, so LaunchError is one class."""
    if name in sys.modules:
        return sys.modules[name]
    if not path.is_file():
        raise PlayError(f"{path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path} is missing")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def _require(name: str, filename: str, task: str, functions: Sequence[str]):
    """The corpus module `filename` (task `task`) with every name in `functions`; PlayError names what is missing."""
    path = HERE / filename
    if not path.is_file():
        raise PlayError(f"scripts/perf-lab/corpus/{filename} ({task}) is missing")
    module = _load(name, path)
    missing = [function for function in functions if not callable(getattr(module, function, None))]
    if missing:
        raise PlayError(f"scripts/perf-lab/corpus/{filename} ({task}) has no {', '.join(missing)}")
    return module


def corpus_manifest():
    return _load("perf_lab_corpus_manifest", HERE / "manifest.py")


def session_io():
    return _load("perf_lab_corpus_session_io", HERE / "session_io.py")


def bench_launch():
    return _load("bench_launch", REPO_ROOT / "scripts" / "cmux-next" / "bench_launch.py")


def perf_signposts():
    return _load("perf_signposts", REPO_ROOT / "scripts" / "cmux-next" / "perf-signposts.py")


def perf_stats():
    return _load("perf_lab_perf_stats", LAB / "perf_stats.py")


def pty_replay():
    return _require("perf_lab_corpus_pty_replay", "pty_replay.py", "p12-perf-process-112", ("main", "MonotonicClock",
                                                                                            "StopRequest"))


def wpr_module():
    return _require("perf_lab_corpus_wpr", "wpr.py", "p12-perf-process-113", WPR_API)


def agent_replay():
    return _require("perf_lab_corpus_agent_replay", "agent_replay.py", "p12-perf-process-114", AGENT_API)


# ---------------------------------------------------------------- clock

class Clock(Protocol):
    def now_ns(self) -> int: ...

    def sleep_until(self, deadline_ns: int) -> None: ...

    def event_s(self) -> float: ...

    def signpost_s(self) -> float: ...


class HostClock:
    """Scheduling on the monotonic clock; stamps on the clocks the app reads: NSEvent.timestamp is CLOCK_UPTIME_RAW,
    the signposts' machTimestamp is mach_continuous_time (CLOCK_MONOTONIC_RAW on macOS)."""

    def now_ns(self) -> int:
        return time.monotonic_ns()

    def sleep_until(self, deadline_ns: int) -> None:
        while (remaining := deadline_ns - time.monotonic_ns()) > 0:
            time.sleep(remaining / 1e9)  # the schedule's own deadline; an early wake sleeps again

    def event_s(self) -> float:
        return time.clock_gettime(getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC))

    def signpost_s(self) -> float:
        return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


# ---------------------------------------------------------------- the control connection

class Channel(Protocol):
    def send(self, method: str, params: Mapping[str, Any]) -> int:
        """Writes one request and returns its ticket; never waits for the reply."""

    def reply(self, ticket: int, timeout: float) -> Any:
        """The reply of `ticket` (bench_launch.rpc_at's form: the result, or {"error": ...})."""

    def close(self) -> None: ...


def call(channel: Channel, method: str, params: Mapping[str, Any] | None = None) -> Any:
    return channel.reply(channel.send(method, dict(params or {})), RPC_TIMEOUT_S)


class SocketChannel:
    """One control-socket connection with pipelined requests: newline JSON with increasing ids, replies kept by id.
    A send reads whatever replies already arrived (never blocking), so neither side's buffer fills while the
    player does not wait; the app answers a connection's requests in order (ControlSocketServer)."""

    def __init__(self, path: str, timeout: float = RPC_TIMEOUT_S):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError as error:
            self.sock.close()
            raise PlayError(f"control socket {path}: {error}") from error
        self.pending, self.replies, self.next_id = b"", {}, 0

    def send(self, method: str, params: Mapping[str, Any]) -> int:
        self.next_id += 1
        line = json.dumps({"id": self.next_id, "method": method, "params": dict(params)}) + "\n"
        try:
            self.sock.sendall(line.encode())
        except OSError as error:
            raise PlayError(f"control socket: {method}: {error}") from error
        self._read(0)
        return self.next_id

    def reply(self, ticket: int, timeout: float) -> Any:
        deadline = time.monotonic() + timeout
        while ticket not in self.replies:
            left = deadline - time.monotonic()
            if left <= 0:
                return {"error": f"no reply in {timeout:g} s", "unreachable": True}
            self._read(left)
        return self.replies.pop(ticket)

    def _read(self, timeout: float) -> None:
        if not select.select([self.sock], [], [], timeout)[0]:
            return
        try:
            chunk = self.sock.recv(1 << 20)
        except OSError as error:
            raise PlayError(f"control socket: {error}") from error
        if not chunk:
            raise PlayError("the app closed the control connection")
        *lines, self.pending = (self.pending + chunk).split(b"\n")
        for line in lines:
            if line.strip():
                try:
                    message = json.loads(line)
                except ValueError as error:
                    raise PlayError(f"control socket: a reply that is not JSON: {error}") from error
                self.replies[message.get("id")] = message.get("result") if message.get("ok") \
                    else {"error": message.get("error")}

    def close(self) -> None:
        self.sock.close()


def default_channel(bench: Any) -> Channel:
    return SocketChannel(bench.socket)


# ---------------------------------------------------------------- checkpoint digests

def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _sha(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode()).hexdigest()


def _position(items: Sequence[str], wanted: Any) -> int | None:
    return items.index(wanted) if wanted in items else None


def workspace_order(snapshot: Mapping[str, Any]) -> list[list[str]]:
    """The workspaces of a snapshot.get reply in sidebar order, each as the names it may be reported by (its public
    id and its model key)."""
    topology = snapshot.get("topology") or {}
    return [[str(w[name]) for name in ("id", "key") if w.get(name)] for w in topology.get("workspaces") or []
            if w.get("id")]


def focus_view(report: Mapping[str, Any], workspaces: Sequence[Sequence[str]] = ()) -> dict[str, Any]:
    """The part of a debug.focus report a checkpoint compares: per window the position of the workspace it shows (in
    `workspaces`, workspace_order), its focus target kind, overlays, sidebar, consistency, and the shown workspace's
    panes as tab kinds with the selected and focused positions. Ids become positions and windows are sorted, so two
    replays of the same state give the same view."""
    windows = []
    for window in report.get("windows") or []:
        model = window.get("model") or {}
        panes = window.get("topology") or []
        pane_ids = [pane.get("pane") for pane in panes]
        rows = []
        for pane in panes:
            tabs = [str(tab).rpartition(":") for tab in pane.get("tabs") or []]
            rows.append({"tabs": [kind for _, _, kind in tabs],
                         "selected": _position([tab_id for tab_id, _, _ in tabs], pane.get("selected"))})
        focused = _position(pane_ids, model.get("resolved_pane"))
        focused_tabs = [str(tab).rpartition(":")[0] for tab in panes[focused].get("tabs") or []] if focused is not None else []
        shown = window.get("workspace")
        windows.append({"workspace": next((index for index, names in enumerate(workspaces) if shown in names), None),
                        "resolved": model.get("resolved"), "overlays": sorted(model.get("overlays") or []),
                        "sidebar_hidden": model.get("sidebar_hidden"), "consistent": window.get("consistent"),
                        "panes": rows, "focused_pane": focused,
                        "focused_tab": _position(focused_tabs, model.get("resolved_tab"))})
    context = report.get("context") or {}
    return {"windows": sorted(windows, key=_canonical), "context": {key: context.get(key) for key in FOCUS_CONTEXT},
            "consistent": report.get("consistent")}


def surfaces_view(report: Mapping[str, Any]) -> dict[str, Any]:
    """The part of a debug.surfaces report a checkpoint compares: per workspace, each pane's surface state
    (SURFACE_FIELDS and whether it shows its selected tab), and the blank and collapsed counts. Pane and workspace
    ids order nothing: rows and workspaces are sorted by their content. Which workspace shows and what has focus is
    the focus digest's part."""
    workspaces: dict[str, list[dict[str, Any]]] = {}
    for window in report.get("windows") or []:
        for row in window.get("panes") or []:
            view = {key: row.get(key) for key in SURFACE_FIELDS}
            view["shows_selected"] = row.get("selected_tab") == row.get("shown_tab")
            workspaces.setdefault(str(row.get("workspace")), []).append(view)
    return {"workspaces": sorted((sorted(rows, key=_canonical) for rows in workspaces.values()), key=_canonical),
            "blank_panes": report.get("blank_panes"), "collapsed_panes": report.get("collapsed_panes")}


def focus_digest(report: Mapping[str, Any], workspaces: Sequence[Sequence[str]] = ()) -> str:
    return _sha(focus_view(report, workspaces))


def surfaces_digest(report: Mapping[str, Any]) -> str:
    return _sha(surfaces_view(report))


def read_checkpoint(read: Callable[[str], Any]) -> tuple[dict[str, Any], dict[str, Any], list[list[str]]]:
    """(debug.focus, debug.surfaces, workspace_order of snapshot.get) of the app behind `read` (one blocking request
    by method name); PlayError when one has no report."""
    reports = []
    for method in ("snapshot.get", "debug.focus", "debug.surfaces"):
        reply = read(method)
        if not isinstance(reply, dict) or reply.get("error") is not None:
            raise PlayError(f"{method} gave no report: {json.dumps(reply)[:200]}")
        reports.append(reply)
    return reports[1], reports[2], workspace_order(reports[0])


# ---------------------------------------------------------------- layout references

class Refs:
    """Resolves layout references (module docstring) against the app's `snapshot.get` topology. The topology is read
    when a reference needs it and was invalidated by an event that can change it (or never read)."""

    def __init__(self, read: Callable[[str, Mapping[str, Any]], Any]):
        self.read = read
        self._topology: dict[str, Any] | None = None
        self.main_window: str | None = None

    def invalidate(self) -> None:
        self._topology = None

    @property
    def stale(self) -> bool:
        return self._topology is None

    def topology(self) -> dict[str, Any]:
        if self._topology is None:
            reply = self.read("snapshot.get", {})
            topology = reply.get("topology") if isinstance(reply, dict) else None
            if not isinstance(topology, dict):
                raise PlayError(f"snapshot.get gave no topology: {json.dumps(reply)[:200]}")
            self._topology = topology
            if self.main_window is None:
                self.main_window = next((str(w["key"]) for w in topology.get("windows") or []
                                         if w.get("workspace") and w.get("key")), None)
        return self._topology

    def pin(self) -> str:
        """Reads the main window now (before any event can open another); PlayError when no window shows a workspace."""
        self.topology()
        if self.main_window is None:
            raise PlayError("no window shows a workspace")
        return self.main_window

    def node(self, ref: str) -> tuple[str, dict[str, Any]]:
        """(kind, the topology object): kind is workspace, pane, tab, group or window. PlayError when the position
        does not exist now."""
        match = REF.fullmatch(ref)
        if match is None:
            raise PlayError(f"{ref}: the player resolves @wN, @wN.pN, @wN.pN.tN, @gN and @winN")
        workspace, pane, tab, group, window = match.groups()
        topology = self.topology()
        if group is not None:
            return "group", self._at(ref, "group", [g for g in topology.get("workspace_groups") or [] if g.get("id")],
                                     int(group))
        if window is not None:
            others = [w for w in topology.get("windows") or [] if w.get("key") and str(w["key"]) != self.pin()]
            if int(window) < 1:
                raise PlayError(f"{ref}: other windows count from @win1 (the main window has no reference)")
            return "window", self._at(ref, "window", others, int(window) - 1)
        node: dict[str, Any] = {}
        indexes = [int(index) for index in (workspace, pane, tab) if index is not None]
        for depth, index in enumerate(indexes):
            children = [w for w in topology.get("workspaces") or [] if w.get("id")] if depth == 0 else (
                [p for s in node.get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]
                if depth == 1 else node.get("tabs") or [])
            node = self._at(ref, REF_KINDS[depth], children, index)
        return REF_KINDS[len(indexes) - 1], node

    @staticmethod
    def _at(ref: str, kind: str, items: list[dict[str, Any]], index: int) -> dict[str, Any]:
        if index >= len(items):
            raise PlayError(f"{ref}: there is no {kind} {index} (the app has {len(items)})")
        return items[index]

    def resolve(self, ref: str) -> tuple[str, str]:
        """(kind, id); a window's id is its key, which debug.key and debug.mouse take."""
        kind, node = self.node(ref)
        return kind, str(node["key"] if kind == "window" else node["id"])

    def target(self, ref: str) -> str:
        kind, ident = self.resolve(ref)
        if kind not in TARGET_KINDS:
            raise PlayError(f"{ref} is a {kind}, not an action target")
        return f"{kind}:{ident}"

    def window(self, ref: str | None) -> str:
        if ref is None:
            return self.main_window or self.pin()
        kind, ident = self.resolve(ref)
        if kind != "window":
            raise PlayError(f"{ref} is a {kind}, not a window")
        return ident


# ---------------------------------------------------------------- the story

@dataclass(frozen=True)
class Step:
    """One input event to send: `params` are the socket call's, with layout references still unresolved; `window`
    is the event's window reference (None: the main window); `changes_topology` says whether the event can change
    what a reference names, so the topology is read again before the next reference."""
    t_ms: float
    index: int
    kind: str
    params: Mapping[str, Any]
    window: str | None = None
    changes_topology: bool = True


@dataclass(frozen=True)
class Checkpoint:
    t_ms: float
    name: str
    focus: str
    surfaces: str


@dataclass(frozen=True)
class AgentTrack:
    surface: str    # the chat tab's reference
    pane: str       # its pane's reference
    transcript: str  # the transcript's sha256, the prompt's argument


@dataclass
class Story:
    manifest: dict[str, Any]
    path: Path              # a manifest file pty_replay.py can read
    snapshot: dict[str, Any]
    timeline: list[Step | Checkpoint]
    skipped: int            # events with nothing to send (key ups, flag changes, bare modifier presses)
    engine: str
    agents: list[AgentTrack] = field(default_factory=list)

    @property
    def id(self) -> str:
        return self.manifest["id"]


class Typist:
    """The next synthetic character of each key class (SYNTHETIC), the same on every replay."""

    def __init__(self):
        self.used = {name: 0 for name in SYNTHETIC}

    def next(self, key_class: str) -> str:
        text = SYNTHETIC[key_class]
        character = text[self.used[key_class] % len(text)]
        self.used[key_class] += 1
        return character


def key_params(payload: Mapping[str, Any], typist: Typist, typing_classes: frozenset[str]) -> dict[str, Any] | None:
    """debug.key's params for a key-down, None for a record debug.key has no event for (an up, a flags change, a bare
    modifier press)."""
    if payload["phase"] != "down" or payload["class"] == "modifier":
        return None
    modifiers = [MODIFIERS[m] for m in payload["modifiers"] if m in MODIFIERS]
    if "key_code" in payload:
        name = KEY_NAMES.get(payload["key_code"])
        if name is None:
            raise PlayError(f"key code {payload['key_code']} has no debug.key name (play.py KEY_NAMES)")
    elif payload["class"] in typing_classes:
        name = typist.next(payload["class"])
        if "shift" in modifiers and payload["class"] == "letter":
            name = name.upper()  # debug.key gives a capital its Shift
        modifiers = [m for m in modifiers if m != "shift"]
    else:
        raise PlayError(f"a {payload['class']} key without a key code has nothing to send")
    return {"key": name, "modifiers": modifiers}


def mouse_params(payload: Mapping[str, Any], last: list[float]) -> dict[str, Any]:
    """debug.mouse's params. A recorded drag point continues the drag from the last point (no press, no release).
    debug.mouse's down and up carry click count 1 (DebugMouse.swift), so a press or release recorded with a higher
    click count (the second press of a double click) cannot be replayed and is refused."""
    x, y = payload["x"], payload["y"]
    common = {"button": BUTTONS[payload["button"]], "modifiers": [MODIFIERS[m] for m in payload.get("modifiers", [])
                                                                   if m in MODIFIERS]}
    phase = payload["phase"]
    if phase in ("down", "up") and payload.get("click_count", 1) > 1:
        raise PlayError(f"a mouse {phase} with click_count {payload['click_count']}: debug.mouse down and up send "
                        "click count 1 only (DebugMouse.swift has no clicks parameter for them)")
    if phase == "drag":
        params = {"action": "drag", "x": last[0], "y": last[1], "to_x": x, "to_y": y, "steps": 1, "press": False,
                  "release": False, **common}
    elif phase == "scroll":
        params = {"action": "scroll", "x": x, "y": y, "dx": payload.get("dx", 0), "dy": payload.get("dy", 0), **common}
    else:
        params = {"action": phase, "x": x, "y": y, **common}
    last[:] = [x, y]
    return params


def _refs_in(value: Any) -> list[str]:
    return [value] if isinstance(value, str) and value.startswith("@") else []


def _changes_topology(kind: str, payload: Mapping[str, Any], typing_classes: frozenset[str]) -> bool:
    """Whether an event can change what a layout reference names. A typing key (no key code: text into the focused
    view) and a scroll cannot; a shortcut, a click, a drag, an action and a CLI op can."""
    if kind == "key":
        return "key_code" in payload or payload["class"] not in typing_classes
    if kind == "mouse":
        return payload["phase"] != "scroll"
    return True


def plan(manifest: Mapping[str, Any], events: Sequence[Mapping[str, Any]], typing_classes: frozenset[str]
         ) -> tuple[list[Step | Checkpoint], int]:
    """The timeline: steps and checkpoints by time, a checkpoint before the events of its own time (the state at t
    is the state before the input at t). Raises PlayError before any launch for an event the player cannot send."""
    typist, last, steps, skipped = Typist(), [0.0, 0.0], [], 0
    for index, event in enumerate(events):
        kind, payload = event["kind"], event["payload"]
        try:
            if kind == "key":
                params = key_params(payload, typist, typing_classes)
            elif kind == "mouse":
                params = mouse_params(payload, last)
            elif kind == "action":
                params = {"id": payload["id"], "args": dict(payload.get("args", {}))}
            else:
                params = {"argv": list(payload["argv"])}
        except PlayError as error:
            raise PlayError(f"event {index}: {error}") from error
        if params is None:
            skipped += 1
            continue
        window = payload.get("window") if kind in ("key", "mouse") else None
        refs = ([v for value in params.get("args", {}).values() for v in _refs_in(value)]
                + [part.partition("=")[2] or part for part in params.get("argv", []) if "@" in part]
                + ([window] if window else []))
        for ref in refs:
            if REF.fullmatch(ref) is None:
                raise PlayError(f"event {index}: {ref} is not a reference the player resolves "
                                "(@wN, @wN.pN, @wN.pN.tN, @gN, @winN)")
        steps.append(Step(float(event["t_ms"]), index, kind, params, window,
                          _changes_topology(kind, payload, typing_classes)))
    checkpoints = [Checkpoint(float(c["t_ms"]), c["name"], c["focus"], c["surfaces"]) for c in manifest["checkpoints"]]
    timeline = sorted([*checkpoints, *steps], key=lambda item: (item.t_ms, 0 if isinstance(item, Checkpoint) else 1))
    return timeline, skipped


def agent_tracks(manifest: Mapping[str, Any], snapshot: Mapping[str, Any]) -> list[AgentTrack]:
    """The story's agent tracks, refused before launch unless each names the selected tab of a pane in the
    snapshot's shown workspace: its prompt goes through debug.agent_pane send_prompt, which reaches only the agent
    tab a window shows (DebugAgentPane.agentPane), and no socket method sends a prompt to another chat tab."""
    tracks = []
    for index, agent in enumerate(manifest["agents"]):
        match = REF.fullmatch(agent["surface"])
        if match is None or match.group(3) is None:
            raise PlayError(f"agent track {index}: {agent['surface']} is not a tab reference (@wN.pN.tN)")
        workspace, pane, tab = (int(match.group(n)) for n in (1, 2, 3))
        leaves = session_io().leaves(snapshot["workspaces"][workspace]["tree"]) \
            if workspace < len(snapshot["workspaces"]) else []
        if workspace != snapshot["shown"] or pane >= len(leaves) or leaves[pane]["selected"] != tab:
            raise PlayError(f"agent track {index}: {agent['surface']} is not the selected tab of a pane in the "
                            f"shown workspace (@w{snapshot['shown']}); debug.agent_pane send_prompt reaches only a "
                            "shown agent tab, and no socket method sends a prompt to a hidden chat tab")
        tracks.append(AgentTrack(agent["surface"], f"@w{workspace}.p{pane}", agent["transcript"]["sha256"]))
    return tracks


def story_engine(manifest: Mapping[str, Any], snapshot: Mapping[str, Any]) -> str:
    """The result-v1 engine: chromium when the story has Chromium pages (a `browser` tab is the app's default engine,
    Chromium, and Web Page Replay serves Chromium only), webkit for WebKit pages only, else none."""
    kinds = {kind for workspace in snapshot["workspaces"] for leaf in session_io().leaves(workspace["tree"])
             for kind in leaf["tabs"]}
    if manifest["web_archive"] is not None or kinds & {"chromium", "browser"}:
        return "chromium"
    return "webkit" if "webkit" in kinds else "none"


# ---------------------------------------------------------------- the schedule

@dataclass
class Track:
    lateness_ms: list[float] = field(default_factory=list)
    paused_ms: float = 0.0   # checkpoint reads
    waited_ms: float = 0.0   # topology reads for references that ran past their event's deadline
    origin_ns: int = 0
    checkpoints: list[dict[str, str]] = field(default_factory=list)

    def report(self) -> dict[str, Any]:
        return {"sent": len(self.lateness_ms), "lateness_ms": perf_stats().summary(self.lateness_ms),
                "paused_ms": round(self.paused_ms, 3), "waited_ms": round(self.waited_ms, 3)}


def play_track(timeline: Sequence[Step | Checkpoint], *, prepare: Callable[[Step], tuple[Any, bool]],
               send: Callable[[Step, Any], None], checkpoint: Callable[[Checkpoint], dict[str, str]], clock: Clock,
               at_origin: Callable[[], None] | None = None) -> Track:
    """Sends each step at origin + t_ms on absolute deadlines and reads each checkpoint. `at_origin` runs once at the
    origin (the other tracks' start). `prepare(step)` resolves the step before its deadline and says whether it read
    the app (a topology read waits for the events before it); a read that ends past the deadline moves the origin by
    the overrun, as a checkpoint's own time does, so the steps after it keep their spacing. Lateness is the time
    `send` starts (the socket write) against its deadline."""
    track = Track()
    origin = track.origin_ns = clock.now_ns()
    if at_origin is not None:
        at_origin()
    for item in timeline:
        deadline = origin + round(item.t_ms * NS_PER_MS)
        if isinstance(item, Checkpoint):
            clock.sleep_until(deadline)
            began = clock.now_ns()
            track.checkpoints.append(checkpoint(item))
            pause = clock.now_ns() - began
            origin += pause
            track.paused_ms += pause / NS_PER_MS
            continue
        prepared, read_app = prepare(item)
        overrun = clock.now_ns() - deadline
        if read_app and overrun > 0:
            origin += overrun
            deadline += overrun
            track.waited_ms += overrun / NS_PER_MS
        clock.sleep_until(deadline)
        track.lateness_ms.append(max(clock.now_ns() - deadline, 0) / NS_PER_MS)
        send(item, prepared)
    return track


# ---------------------------------------------------------------- sending

class Sender:
    """Sends steps to the app: debug.key, debug.mouse and action.run pipelined on `channel`, CLI events as processes
    (`finish` collects them). `collect` reads the replies of what was sent and fails on the first refusal."""

    def __init__(self, channel: Channel, refs: Refs, clock: Clock, spawn: Callable[[Sequence[str]], Any]):
        self.channel, self.refs, self.clock, self.spawn = channel, refs, clock, spawn
        self.cli: list[tuple[float, Any, Step]] = []
        self.sent: list[tuple[int, Step]] = []

    def prepare(self, step: Step) -> tuple[tuple[str, Any], bool]:
        """((method, params or argv) with every reference resolved, whether the topology was read for it)."""
        stale = self.refs.stale
        try:
            if step.kind == "cli":
                prepared: tuple[str, Any] = ("cli", [self._cli_part(part) for part in step.params["argv"]])
            elif step.kind in ("key", "mouse"):
                method = "debug.key" if step.kind == "key" else "debug.mouse"
                prepared = (method, {**step.params, "window": self.refs.window(step.window)})
            else:
                args = {name: self.refs.resolve(value)[1] if _refs_in(value) else value
                        for name, value in step.params["args"].items() if name != "target"}
                params = {"action": step.params["id"], "args": args, "focus": True, "origin": "script"}
                if "target" in step.params["args"]:
                    params["target"] = self.refs.target(step.params["args"]["target"])
                prepared = ("action.run", params)
        except PlayError as error:
            raise PlayError(f"event {step.index} ({step.kind} at {step.t_ms:g} ms): {error}") from error
        return prepared, stale and not self.refs.stale

    def send(self, step: Step, prepared: tuple[str, Any]) -> None:
        method, params = prepared
        if method == "cli":
            self.cli.append((self.clock.signpost_s(), self.spawn(params), step))
        else:
            if step.kind == "key":
                params = {**params, "timestamp": self.clock.event_s()}
            self.sent.append((self.channel.send(method, params), step))
        if step.changes_topology:
            self.refs.invalidate()

    def collect(self) -> None:
        """Reads the reply of every event sent so far; PlayError names the first one the app refused."""
        sent, self.sent = self.sent, []
        for ticket, step in sent:
            reply = self.channel.reply(ticket, RPC_TIMEOUT_S)
            if isinstance(reply, dict) and reply.get("error") is not None:
                raise PlayError(f"event {step.index} ({step.kind} at {step.t_ms:g} ms): refused: "
                                f"{json.dumps(reply['error'])[:300]}")

    def _cli_part(self, part: str) -> str:
        flag, equals, value = part.partition("=")
        if equals and value.startswith("@"):
            return f"{flag}={self.refs.resolve(value)[1]}"
        return self.refs.resolve(part)[1] if part.startswith("@") else part

    def finish(self) -> list[float]:
        """Waits for the CLI events; their send stamps. PlayError names the first that failed."""
        for _, handle, step in self.cli:
            code, error = handle.wait(CLI_TIMEOUT_S)
            if code != 0:
                raise PlayError(f"event {step.index} (cli at {step.t_ms:g} ms): exit {code}: {error[:300]}")
        return [stamp for stamp, _, _ in self.cli]


class CliProcess:
    def __init__(self, argv: Sequence[str]):
        self.process = subprocess.Popen(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, text=True)

    def wait(self, timeout: float) -> tuple[int, str]:
        try:
            _, error = self.process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()  # the CLI process this player started
            _, error = self.process.communicate()
            return -1, f"no exit in {timeout:g} s"
        return self.process.returncode, error or ""


# ---------------------------------------------------------------- the PTY tracks' start

class FifoGate:
    """The player's end of a PTY track's go signal: a FIFO the track's process (GatedClock) opens for reading once it
    has loaded its recording. `wait_ready` holds the write end (the process is waiting); `release` writes GO."""

    def __init__(self, path: Path):
        self.path, self.fd = Path(path), None
        self.path.unlink(missing_ok=True)
        os.mkfifo(self.path, 0o600)

    def wait_ready(self, timeout_s: float) -> None:
        deadline = time.monotonic() + timeout_s
        while self.fd is None:
            try:
                self.fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise PlayError(f"{self.path.name}: {error}") from error
                if time.monotonic() > deadline:
                    raise PlayError(f"{self.path.name}: the PTY track's process did not start in {timeout_s:g} s")
                time.sleep(0.01)  # perf-lab player: the terminal's shell starts the track's process (no reader yet)

    def release(self) -> None:
        if self.fd is None:
            raise PlayError(f"{self.path.name}: released before its PTY track was ready")
        os.write(self.fd, GO)
        self.close()

    def close(self) -> None:
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        self.path.unlink(missing_ok=True)


class GatedClock:
    """pty_replay's clock for a corpus PTY track: its first `now_ns` (pty_replay.play's start, after the recording
    is loaded) waits for the player's GO on the FIFO, so the track starts at the input track's origin. A closed FIFO
    without GO (the player went away) raises; a stop request ends the wait (play then writes nothing)."""

    def __init__(self, base: Any, fifo: Path, *, wake_fd: int | None = None, stop: Callable[[], bool] = lambda: False):
        self.base, self.fifo, self.wake_fd, self.stop = base, Path(fifo), wake_fd, stop
        self.started = False

    def now_ns(self) -> int:
        if not self.started:
            self._wait_for_go()
            self.started = True
        return self.base.now_ns()

    def sleep_until(self, deadline_ns: int) -> None:
        self.base.sleep_until(deadline_ns)

    def _wait_for_go(self) -> None:
        fd = os.open(self.fifo, os.O_RDONLY)  # returns once the player holds the write end (FifoGate.wait_ready)
        try:
            while not self.stop():
                ready = select.select([fd] + ([self.wake_fd] if self.wake_fd is not None else []), [], [])[0]
                if fd in ready:
                    if os.read(fd, 1) != GO:
                        raise ConnectionAbortedError(f"{self.fifo}: the player closed the go signal")
                    return
                with contextlib.suppress(BlockingIOError):
                    os.read(self.wake_fd, 1 << 10)  # the signal wakeup pipe; the loop checks the stop
        finally:
            os.close(fd)


def pty_track_main(argv: Sequence[str]) -> int:
    """`play.py pty-track --go FIFO -- PTY_REPLAY_ARGS`: pty_replay.main with a GatedClock (the PTY track's command)."""
    parser = argparse.ArgumentParser(prog="play.py pty-track")
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("rest", nargs=argparse.REMAINDER)
    opts = parser.parse_args(list(argv))
    rest = opts.rest[1:] if opts.rest[:1] == ["--"] else opts.rest
    pty = pty_replay()
    stop = pty.StopRequest()
    stdin = sys.stdin.fileno() if sys.stdin is not None and os.isatty(sys.stdin.fileno()) else None
    base = pty.MonotonicClock(discard_fd=stdin if os.isatty(1) else None, wake_fd=stop.wake_fd, stop=stop)
    return pty.main(rest, clock=GatedClock(base, opts.go, wake_fd=stop.wake_fd, stop=stop), stop=stop)


# ---------------------------------------------------------------- series

def series(parsed: Mapping[str, Any], window: tuple[float, float], frames: Mapping[str, Any]) -> dict[str, list[float]]:
    """The player's series (module docstring) from perf-signposts.parse output inside `window` (signpost seconds)."""
    start, end = window
    done = [i for i in parsed["intervals"] if start <= i["at_s"] <= end and not i["missed"] and not i["nested_loop"]]
    out: dict[str, list[float]] = {"key_to_frame": [], "action_to_frame": [], "switch_to_frame": [],
                                   "tab_switch_to_frame": []}
    for interval in done:
        name, info = interval["name"], interval["fields"]
        if name == "key.frame" and float(info.get("age_ms", "-1")) >= 0:
            out["key_to_frame"].append(interval["ms"] + float(info["age_ms"]))
        elif name == "action.commit":
            out["action_to_frame"].append(interval["ms"])
        elif name in ("switch.workspace", "switch.tab", "switch.pane_focus"):
            out["switch_to_frame"].append(interval["ms"])
            if name == "switch.tab":
                out["tab_switch_to_frame"].append(interval["ms"])
    if isinstance(frames.get("missed"), int):
        out["dropped_frames"] = [frames["missed"]]
    return {name: samples for name, samples in out.items() if samples}


def metric_id(story_id: str) -> str:
    return story_id.replace("-", "_")


def declared(manifest: Mapping[str, Any], metric: str) -> Mapping[str, Any] | None:
    return next((m for m in manifest["metrics"] if re.fullmatch(m["name"], metric)), None)


# ---------------------------------------------------------------- the player

@dataclass
class Replay:
    story: str
    checkpoints: list[dict[str, str]]
    schedule: dict[str, Any]
    series: dict[str, list[float]]
    results: list[str]
    unmeasured: list[str]
    skipped_events: int
    units: dict[str, str] = field(default_factory=dict)

    def summary(self) -> dict[str, Any]:
        return {"story": self.story, "checkpoints": self.checkpoints, "schedule": self.schedule,
                "metrics": {name: perf_stats().summary(samples) for name, samples in self.series.items()},
                "results": self.results, "unmeasured": self.unmeasured, "skipped_events": self.skipped_events}


def default_fetch(ref: Mapping[str, Any], root: Path = REPO_ROOT) -> Path:
    """A local file with a manifest source's bytes: a repository file (checked against its digest) or a blob in the
    corpus cache (BlobCache checks it on every read)."""
    corpus = corpus_manifest()
    if "path" in ref:
        path = root / ref["path"]
        data = path.read_bytes() if path.is_file() else b""
        if corpus.blob_ref(data) != {"sha256": ref["sha256"], "bytes": ref["bytes"]}:
            raise PlayError(f"{ref['path']} is missing or does not match its sha256 and bytes")
        return path
    cache = corpus.BlobCache(corpus.default_cache_dir(), corpus.http_fetcher())
    try:
        cache.get(ref)
    except corpus.CorpusError as error:
        raise PlayError(str(error)) from error
    return cache.path(ref)


def bench_config(base: Mapping[str, Any], settings: Mapping[str, Any]) -> dict[str, Any]:
    """BASE (a cmux-next.json object) with SETTINGS (a story's `config`: dotted setting paths) set over it."""
    config = json.loads(json.dumps(base))
    for dotted, value in settings.items():
        *parents, leaf = dotted.split(".")
        node = config
        for part in parents:
            node = node.setdefault(part, {})
        node[leaf] = value
    return config


def default_bench(app: str, *, out: Path, env: Mapping[str, str | None], session: str,
                  config: Mapping[str, Any] | None = None):
    """A BenchApp; a story's `config` settings go over BenchApp's default config (bench_launch.DEFAULT_CONFIG)."""
    launch = bench_launch()
    written = None if config is None else bench_config(launch.DEFAULT_CONFIG, config)
    return launch.BenchApp(app, out=str(out), env=dict(env), config=written, perf_session=session)


def default_import(rpc: Callable[..., Any], snapshot: Mapping[str, Any]):
    io = session_io()
    try:
        return io.import_layout(rpc, snapshot)
    except io.LayoutSnapshotError as error:
        raise PlayError(f"layout import: {error}") from error


class _Signposts:
    def __init__(self, pid: int):
        self.recording = perf_signposts().Recording(pid, list(SIGNPOST_CATEGORIES))

    def stop(self) -> list[str]:
        return self.recording.stop()


class WebReplay:
    """The story's Web Page Replay (wpr.py, task 113), as wpr.py's own verify runs it: host-setup.sh's wpr build at
    pool.json's commit (its certificate must be the story's spki), the bench bundle checked (a shipped bundle would
    ignore the switches and load the live sites), its Chromium storage emptied (no cached subresource bypasses wpr),
    then `wpr replay` (WprServer) for the replay. Yields the app's env: CMUX_NEXT_BENCH_CEF_SWITCHES with
    bench_switches over the server's ports. Tests pass the wpr folder, the bundle id and the Chromium root."""

    def __init__(self, *, wpr_dir: Path | None = None, bundle_id: Callable[[str], str | None] | None = None,
                 chromium_root: Callable[[str], Path] | None = None):
        self.wpr_dir, self.bundle_id, self.chromium_root = wpr_dir, bundle_id, chromium_root

    def require(self) -> None:
        """Before launch: PlayError when wpr.py or a function this calls is missing."""
        wpr_module()

    @contextlib.contextmanager
    def __call__(self, archive: Path, spki: str, out: Path, app: str) -> Iterator[dict[str, str]]:
        wpr = wpr_module()
        server = None
        try:
            commit = wpr.wpr_commit()
            directory = wpr.checked_wpr_dir(self.wpr_dir or wpr.default_wpr_dir(commit), commit)
            own = wpr.spki_of_pem((directory / "wpr_cert.pem").read_text(encoding="utf-8"))
            if own != spki:
                raise PlayError(f"the story's spki {spki} is not this wpr build's certificate {own}: its archive was "
                                "recorded with another wpr commit")
            bundle = (self.bundle_id or bench_launch().bundle_id)(app)
            problem = wpr.bench_bundle_problem(bundle)
            if problem:
                raise PlayError(problem)
            wpr.empty_chromium_root((self.chromium_root or wpr.chromium_root)(bundle))
            server = wpr.WprServer(directory, "replay", archive, out / "wpr-replay.log")
            server.start()
            env = wpr.bench_env(wpr.bench_switches(server.http_port, server.https_port, spki))
        except (wpr.WprError, OSError, KeyError, ValueError) as error:
            if server is not None:
                server.stop()
            raise PlayError(f"web page replay: {error}") from error
        try:
            yield env
        finally:
            server.stop()


class AgentTracks:
    """The story's agent tracks in the bench (agent_replay.py, task 114): the transcripts in a folder named by
    sha256, the replay harness installed in the bench bundle's acpmux home under CMUX_NEXT_ACPMUX_ROOT with a
    scratch XDG_CONFIG_HOME (install, bench_acpmux_home), and launch_env for the app's environment (None unsets).
    Each turn's frames digest goes to agent-replay.ndjson in `out`."""

    def __init__(self, *, bundle_id: Callable[[str], str | None] | None = None):
        self.bundle_id = bundle_id

    def require(self) -> None:
        """Before launch: PlayError when agent_replay.py or a function this calls is missing."""
        agent_replay()

    def __call__(self, out: Path, agents: Sequence[Mapping[str, Any]], fetch: Callable[[Mapping[str, Any]], Path],
                 app: str) -> dict[str, str | None]:
        replay_module = agent_replay()
        bundle = (self.bundle_id or bench_launch().bundle_id)(app)
        if not bundle:
            raise PlayError(f"{app} has no bundle id: its acpmux home is unknown")
        root, config_home, transcripts = out / "acpmux", out / "agent-config", out / "agent-transcripts"
        transcripts.mkdir(parents=True, exist_ok=True)
        try:
            for agent in agents:
                shutil.copyfile(fetch(agent["transcript"]), transcripts / agent["transcript"]["sha256"])
            replay_module.install(replay_module.bench_acpmux_home(root, bundle), config_home, transcripts,
                                  log=out / "agent-replay.ndjson")
        except (OSError, ValueError) as error:
            raise PlayError(f"agent tracks: {error}") from error
        return dict(replay_module.launch_env(root, config_home))


class Player:
    """replay() with its seams: tests pass fakes for the app, its control connections, the clock, the signposts, the
    PTY go signals, the web replay and the agent install (each with `require()`, called before launch, and the call
    WebReplay and AgentTracks have) and the source reads."""

    def __init__(self, *, root: Path = REPO_ROOT, clock: Clock | None = None,
                 fetch: Callable[[Mapping[str, Any]], Path] | None = None, make_bench: Callable[..., Any] = default_bench,
                 import_layout: Callable[..., Any] = default_import, signposts: Callable[[int], Any] = _Signposts,
                 spawn: Callable[[Sequence[str]], Any] = CliProcess, web_replay: Callable[..., Any] | None = None,
                 agents: Callable[..., dict[str, str | None]] | None = None,
                 open_channel: Callable[[Any], Channel] = default_channel, pty_gate: Callable[[Path], Any] = FifoGate,
                 max_late_ms: float = MAX_LATE_P95_MS, settle_s: float = CHECKPOINT_SETTLE_S,
                 cache_dir: Path | None = None):
        self.root, self.clock = Path(root), clock or HostClock()
        self.fetch = fetch or (lambda ref: default_fetch(ref, self.root))
        self.make_bench, self.import_layout, self.signposts = make_bench, import_layout, signposts
        self.spawn, self.web_replay, self.agents = spawn, web_replay or WebReplay(), agents or AgentTracks()
        self.open_channel, self.pty_gate = open_channel, pty_gate
        self.max_late_ms, self.settle_s = max_late_ms, settle_s
        self.cache_dir = cache_dir

    # Loading.

    def load(self, manifest: str | os.PathLike | Mapping[str, Any], scratch: Path) -> Story:
        corpus = corpus_manifest()
        if isinstance(manifest, Mapping):
            doc, path = dict(manifest), None
        else:
            path = Path(manifest)
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                raise PlayError(f"{path}: {error}") from error
        schema, vocabulary = corpus.load_schema(self.root), corpus.load_vocabulary(self.root)
        errors = corpus.validation_errors(doc, root=self.root, schema=schema, vocabulary=vocabulary)
        if errors:
            raise PlayError(f"{doc.get('id', path)}: invalid manifest: " + "; ".join(errors[:6]))
        if doc["status"] != "recorded":
            raise PlayError(f"{doc['id']} is planned, not recorded: {doc['planned']}")
        if "compose" in doc:
            raise PlayError(f"{doc['id']} composes other stories: its soak (task 122) plays them")
        if "blob" in doc["input"]:
            text = self.fetch(doc["input"]["blob"]).read_text(encoding="utf-8")
            try:
                events = [json.loads(line) for line in text.splitlines() if line.strip()]
            except json.JSONDecodeError as error:
                raise PlayError(f"{doc['id']}: the input blob is not NDJSON: {error}") from error
            errors = corpus.event_errors(events, doc["duration_ms"], schema, vocabulary, "$.input.blob")
            if errors:
                raise PlayError(f"{doc['id']}: invalid input blob: " + "; ".join(errors[:6]))
        else:
            events = doc["input"]["events"]
        io = session_io()
        try:
            snapshot = io.check(json.loads(self.fetch(doc["layout"]["snapshot"]).read_text(encoding="utf-8")))
        except (ValueError, io.LayoutSnapshotError) as error:
            raise PlayError(f"{doc['id']}: layout snapshot: {error}") from error
        if len(snapshot["workspaces"]) != doc["layout"]["workspaces"]:
            raise PlayError(f"{doc['id']}: the snapshot has {len(snapshot['workspaces'])} workspaces, the manifest says "
                            f"{doc['layout']['workspaces']}")
        try:
            if doc["pty"]:
                pty_replay()
            if doc["web_archive"] is not None:
                self.web_replay.require()
            agents = agent_tracks(doc, snapshot)
            if agents:
                self.agents.require()
            timeline, skipped = plan(doc, events, corpus.TYPING_CLASSES)
        except PlayError as error:
            raise PlayError(f"{doc['id']}: {error}") from error
        for track in doc["pty"]:
            self.fetch(track["source"])  # into the cache now: the terminal never fetches while the app is measured
        for agent in doc["agents"]:
            self.fetch(agent["transcript"])
        if path is None:
            path = scratch / f"{doc['id']}.json"
            path.write_text(json.dumps(doc), encoding="utf-8")
        return Story(doc, path.resolve(), snapshot, timeline, skipped, story_engine(doc, snapshot), agents)

    # Replay.

    def replay(self, manifest: str | os.PathLike | Mapping[str, Any], *, app: str, out: str | os.PathLike,
               window: Callable[[Any], contextlib.AbstractContextManager] | None = None,
               story_name: str | None = None) -> Replay:
        out = Path(out)
        out.mkdir(parents=True, exist_ok=True)
        story = self.load(manifest, out)
        manifest_doc = story.manifest
        with contextlib.ExitStack() as stack:
            env: dict[str, str | None] = {}
            archive = manifest_doc["web_archive"]
            if archive is not None:
                served = self.web_replay(self.fetch(archive["wprgo"]), archive["spki"], out, app)
                env.update(stack.enter_context(served))
            if manifest_doc["agents"]:
                env.update(self.agents(out, manifest_doc["agents"], self.fetch, app))
            bench = self.make_bench(app, out=out, env=env, session=f"corpus:{story.id}",
                                    config=manifest_doc.get("config"))
            stack.callback(bench.stop)
            bench.launch()  # bench_launch.LaunchError when the app does not come up
            stack.callback(self.import_layout(bench.rpc, story.snapshot).close)
            channel = stack.enter_context(contextlib.closing(self.open_channel(bench)))
            refs = Refs(lambda method, params: call(channel, method, params))
            refs.pin()
            gates = self.start_pty(story, bench, refs, out)
            for gate in gates:
                stack.callback(gate.close)
            prompts = self.agent_prompts(story, refs)
            side = stack.enter_context(contextlib.closing(self.open_channel(bench))) if prompts else None
            prompt_tickets: list[int] = []

            def start_tracks() -> None:
                for gate in gates:
                    gate.release()
                prompt_tickets.extend(side.send("debug.agent_pane", params) for params in prompts)

            sender = Sender(channel, refs, self.clock,
                            lambda argv: self.spawn([bench.cli, "--app-socket", bench.socket, *argv]))
            track, frames, lines, span = self.measure(story, bench, sender, window, out, start_tracks)
            for index, ticket in enumerate(prompt_tickets):
                reply = side.reply(ticket, RPC_TIMEOUT_S)
                if not isinstance(reply, dict) or reply.get("error") is not None:
                    raise PlayError(f"agent track {index} ({story.agents[index].surface}): send_prompt failed: "
                                    f"{json.dumps(reply)[:300]}")
            sender.finish()
            schedule = track.report()
            p95 = schedule["lateness_ms"]["p95"]
            if p95 is not None and p95 > self.max_late_ms:
                raise ScheduleError(f"{story.id}: sends were {p95:.2f} ms late at p95 (bound {self.max_late_ms:g} ms): "
                                    "the input track did not keep its recorded timing")
            measured = series(perf_signposts().parse(lines, None), span, frames)
            result = self.record(story, bench, measured, track, schedule, story_name)
        (out / f"corpus-play-{story.id}.json").write_text(json.dumps(result.summary(), indent=1), encoding="utf-8")
        return result

    def start_pty(self, story: Story, bench: Any, refs: Refs, out: Path) -> list[Any]:
        """Types `play.py pty-track --go FIFO -- <pty_replay args>` into each track's terminal (the bytes go through
        the PTY) and waits until each track's process holds its FIFO; returns the gates the origin releases."""
        cache = self.cache_dir or corpus_manifest().default_cache_dir()
        gates = []
        try:
            for index, track in enumerate(story.manifest["pty"]):
                kind, tab = refs.resolve(track["surface"])
                if kind != "tab":
                    raise PlayError(f"pty track {index}: {track['surface']} is a {kind}, not a terminal tab")
                gate = self.pty_gate(out / f"pty-{index}.go")
                gates.append(gate)
                command = shlex.join([sys.executable, "-I", str(Path(__file__).resolve()), "pty-track", "--go",
                                      str(gate.path), "--", "--manifest", str(story.path), "--track", str(index),
                                      "--root", str(self.root), "--timing-json", str(out / f"pty-{index}-timing.json")])
                text = f"CMUX_PERF_CORPUS_CACHE={shlex.quote(str(cache))} {command}\n"
                reply = bench.rpc("action.run", {"action": "terminal.sendText", "args": {"text": text},
                                                 "target": f"tab:{tab}", "focus": False, "origin": "script"},
                                  RPC_TIMEOUT_S)
                if isinstance(reply, dict) and reply.get("error") is not None:
                    raise PlayError(f"pty track {index}: terminal.sendText refused: {json.dumps(reply['error'])[:300]}")
            for gate in gates:
                gate.wait_ready(PTY_READY_TIMEOUT_S)
        except BaseException:
            for gate in gates:
                gate.close()
            raise
        return gates

    def agent_prompts(self, story: Story, refs: Refs) -> list[dict[str, Any]]:
        """debug.agent_pane send_prompt params for each agent track: its chat tab must be the selected tab of its pane
        in a workspace a window shows (agent_tracks checked the snapshot; this checks the app)."""
        prompts = []
        shown = {str(w.get("workspace")) for w in refs.topology().get("windows") or [] if w.get("workspace")}
        for index, agent in enumerate(story.agents):
            _, tab = refs.resolve(agent.surface)
            _, pane = refs.node(agent.pane)
            _, workspace = refs.node(agent.pane.partition(".")[0])
            if str(pane.get("selected_tab")) != tab or str(workspace["id"]) not in shown:
                raise PlayError(f"agent track {index}: {agent.surface} is not the agent tab its window shows after the "
                                "layout import; debug.agent_pane send_prompt reaches only a shown agent tab")
            prompts.append({"action": "send_prompt", "pane": str(pane["id"]), "text": f"replay {agent.transcript}"})
        return prompts

    def measure(self, story: Story, bench: Any, sender: Sender, window, out: Path, start_tracks: Callable[[], None]):
        """The measured window: signposts and frames around the `window(bench)` hook around the input track, the
        other tracks started at its origin, and the app's replies read before the window ends."""
        recording = self.signposts(bench.process.pid)
        lines: list[str] | None = None
        try:
            started = bench.rpc("debug.frames", {"action": "start"}, RPC_TIMEOUT_S)
            if isinstance(started, dict) and started.get("error") is not None:
                raise PlayError(f"debug.frames: {json.dumps(started['error'])[:200]}")
            start = self.clock.signpost_s()
            with (window(bench) if window is not None else contextlib.nullcontext()):
                track = play_track(story.timeline, prepare=sender.prepare, send=sender.send, clock=self.clock,
                                   checkpoint=lambda item: self.checkpoint(sender, item, out), at_origin=start_tracks)
                sender.collect()
            end = self.clock.signpost_s()
            frames = bench.rpc("debug.frames", {"action": "stop"}, RPC_TIMEOUT_S)
            lines = recording.stop()
        finally:
            if lines is None:
                recording.stop()
        return track, frames if isinstance(frames, dict) else {}, lines, (start, end)

    def checkpoint(self, sender: Sender, item: Checkpoint, out: Path) -> dict[str, str]:
        """Reads the replies of the events before it (a refusal fails here), then the checkpoint until both digests are
        the recorded ones or settle_s passes; DigestMismatch names the first digest that differs, and the views are
        kept in `out` for the diff."""
        sender.collect()
        deadline = self.clock.now_ns() + round(self.settle_s * 1e9)
        while True:
            focus, surfaces, order = read_checkpoint(lambda method: call(sender.channel, method))
            got = {"focus": focus_digest(focus, order), "surfaces": surfaces_digest(surfaces)}
            if got["focus"] == item.focus and got["surfaces"] == item.surfaces:
                return {"name": item.name, **got}
            if self.clock.now_ns() >= deadline:
                break
            self.clock.sleep_until(self.clock.now_ns() + round(CHECKPOINT_POLL_S * 1e9))
        (out / f"checkpoint-{item.name}.json").write_text(
            json.dumps({"focus": focus_view(focus, order), "surfaces": surfaces_view(surfaces)}, indent=1),
            encoding="utf-8")
        which = "focus" if got["focus"] != item.focus else "surfaces"
        raise DigestMismatch(item.name, item.t_ms, which, getattr(item, which), got[which])

    def record(self, story: Story, bench: Any, measured: dict[str, list[float]], track: Track,
               schedule: dict[str, Any], story_name: str | None) -> Replay:
        name = story_name or os.environ.get("PERF_LAB_STORY") or f"corpus-{story.id}"
        written, kept, units = [], {}, {}
        for series_name, samples in sorted(measured.items()):
            metric = f"corpus.{metric_id(story.id)}.{series_name}"
            spec = declared(story.manifest, metric)
            if spec is None:
                continue
            kept[metric], units[metric] = samples, spec["unit"]
            written.append(str(bench.record(name, metric, spec["unit"], samples, spec["better"], story.engine)))
        unmeasured = [m["name"] for m in story.manifest["metrics"] if not any(re.fullmatch(m["name"], k) for k in kept)]
        return Replay(story.id, track.checkpoints, schedule, kept, written, unmeasured, story.skipped, units)


def replay(manifest: str | os.PathLike | Mapping[str, Any], *, app: str, out: str | os.PathLike,
           window: Callable[[Any], contextlib.AbstractContextManager] | None = None, player: Player | None = None,
           story_name: str | None = None) -> Replay:
    """Replays one recorded corpus story into a fresh launch of `app` (module docstring). After the launch and the
    layout import, `window(bench)` is called once with the BenchApp and the input track plays inside the context
    manager it returns. A failed launch raises bench_launch.LaunchError; a divergence raises PlayError."""
    return (player or Player()).replay(manifest, app=app, out=out, window=window, story_name=story_name)


# ---------------------------------------------------------------- verify

def compare_runs(first: Replay, second: Replay, max_cv: float = VERIFY_MAX_CV,
                 min_samples: int = VERIFY_MIN_SAMPLES, count_tolerance: float = VERIFY_COUNT_TOLERANCE) -> list[str]:
    """Why two replays of one story disagree: the first checkpoint whose digests differ; each latency metric with at
    least `min_samples` samples in both runs whose p50 varies by more than `max_cv` (stdev over mean); each count
    metric (unit count) whose p50s differ by more than `count_tolerance` and `max_cv`."""
    problems = []
    for a, b in zip(first.checkpoints, second.checkpoints):
        if a != b:
            problems.append(f"checkpoint {a['name']}: run 1 {a['focus'][:12]}/{a['surfaces'][:12]}, "
                            f"run 2 {b['focus'][:12]}/{b['surfaces'][:12]}")
            break
    if len(first.checkpoints) != len(second.checkpoints):
        problems.append(f"run 1 read {len(first.checkpoints)} checkpoints, run 2 {len(second.checkpoints)}")
    stats = perf_stats()
    for metric in sorted(set(first.series) | set(second.series)):
        if metric not in first.series or metric not in second.series:
            problems.append(f"{metric}: only one run measured it")
            continue
        runs = (first.series[metric], second.series[metric])
        count = "count" in (first.units.get(metric), second.units.get(metric))
        if not count and min(len(samples) for samples in runs) < min_samples:
            continue  # too few samples for a p50 to compare
        medians = [stats.pct(samples, 0.5) for samples in runs]
        mean = sum(medians) / 2
        cv = 0.0 if mean == 0 else math.sqrt(sum((m - mean) ** 2 for m in medians)) / mean  # n-1 = 1
        if count and abs(medians[0] - medians[1]) <= count_tolerance:
            continue
        if cv > max_cv:
            problems.append(f"{metric}: p50 {medians[0]:.3g} vs {medians[1]:.3g}, cv {cv:.3f} over {max_cv:g}")
    return problems


# ---------------------------------------------------------------- CLI

def corpus_paths(root: Path) -> list[Path]:
    return sorted((root / CORPUS_DIR).glob("*.json"))


def playable(path: Path) -> str | None:
    """Why --all skips the manifest at `path` (None: it plays)."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return f"unreadable: {error}"
    if doc.get("status") != "recorded":
        return "planned, not recorded"
    if "compose" in doc:
        return "a compose story: its soak plays it"
    return None


def play_one(player: Player, path: Path, opts) -> dict[str, Any]:
    story_out = Path(opts.out) / path.stem
    launch_error = bench_launch().LaunchError
    try:
        runs = [player.replay(path, app=opts.app, out=story_out / f"run-{n}" if opts.verify else story_out)
                for n in ((1, 2) if opts.verify else (1,))]
    except (PlayError, launch_error) as error:
        return {"story": path.stem, "ok": False, "reason": str(error)[:600]}
    report = {"story": path.stem, "ok": True, "runs": [run.summary() for run in runs]}
    if opts.verify:
        problems = compare_runs(runs[0], runs[1], opts.max_cv)
        report.update(ok=not problems, problems=problems)
    return report


def main(argv: list[str] | None = None, player: Player | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("manifests", nargs="*", type=Path, help="perf-corpus manifests to play")
    parser.add_argument("--all", action="store_true", help="every recorded story of perf-corpus/")
    parser.add_argument("--app", required=True, help="a bench `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--tag", help="the app's tag (the lab runner passes it; the bundle names its own)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--verify", action="store_true", help="play each story twice; compare digests and CV")
    parser.add_argument("--max-late-ms", type=float, default=MAX_LATE_P95_MS, help="send lateness p95 bound")
    parser.add_argument("--max-cv", type=float, default=VERIFY_MAX_CV, help="--verify: p50 CV bound per metric")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    opts = parser.parse_args(argv)
    if bool(opts.manifests) == opts.all:
        parser.error("name manifests or pass --all")
    for number in (signal.SIGTERM, signal.SIGHUP):  # exit through the finally blocks, which stop the app
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    player = player or Player(root=opts.root, max_late_ms=opts.max_late_ms)
    paths = corpus_paths(opts.root) if opts.all else opts.manifests
    played, failed = 0, False
    for path in paths:
        reason = playable(path) if opts.all else None
        if reason is not None:
            print("CORPUS-PLAY " + json.dumps({"story": path.stem, "skipped": reason}), flush=True)
            continue
        report = play_one(player, path, opts)
        played += 1
        failed |= not report["ok"]
        print("CORPUS-PLAY " + json.dumps(report), flush=True)
    if played == 0:
        print("play: no recorded story to play", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(pty_track_main(sys.argv[2:]) if sys.argv[1:2] == ["pty-track"] else main())
