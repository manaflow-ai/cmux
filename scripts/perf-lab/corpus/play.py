#!/usr/bin/env python3
"""Corpus story player: replays a recorded session into a bench app and measures it (p12-perf-process.md 3.8, task 115).

    python3 -I scripts/perf-lab/corpus/play.py perf-corpus/dev-loop.json --app APP --out DIR
    python3 -I scripts/perf-lab/corpus/play.py --all --verify --app APP --out DIR

One replay of a recorded manifest (schemas/perf/corpus-story-v1.schema.json):

  1. Load and check before any launch: the manifest validator (manifest.py, text checks included, also for an
     input blob), the layout snapshot (session_io.check), every key code the player must send, the sources it
     needs (blobs are fetched into the corpus cache now, so nothing is fetched while the app runs).
  2. Start the story's Web Page Replay (wpr.py, task 113: its CEF switch pair goes to the app as
     CMUX_NEXT_BENCH_CEF_SWITCHES) and stage its agent transcripts (agent_replay.py, task 114, under
     CMUX_NEXT_ACPMUX_ROOT), then launch the bench app (bench_launch.BenchApp; a failed launch raises
     bench_launch.LaunchError) and import the layout (session_io.import_layout).
  3. Start each PTY track: `pty_replay.py --manifest M --track N` typed into its terminal (task 112).
  4. The measured window, the input track only: signposts (`log stream`, perf-signposts.py) and `debug.frames`
     run around it, and the `window(bench)` hook of `replay()` wraps it. Each event is sent at its recorded
     time on absolute deadlines (a late send does not shift the ones after it, as Chromium's
     base::MetronomeTimer keeps a fixed phase, base/timer/timer.h):
       key    debug.key with the client's send time as the event's timestamp (CLOCK_UPTIME_RAW); a typing key
              has no key code in the corpus and types the next character of the fixed SYNTHETIC text
       mouse  debug.mouse at the recorded window point
       action action.run (origin script)
       cli    the app's bundled cmux CLI, its send time stamped on the signposts' clock (CLOCK_MONOTONIC_RAW)
     At each checkpoint the player reads debug.focus and debug.surfaces and compares their digests with the
     recorded ones; the first one that differs (after CHECKPOINT_SETTLE_S) ends the replay with DigestMismatch.
     The time a checkpoint takes moves the rest of the schedule, so the recorded spacing of events stays.
  5. Write result-v1 (BenchApp.record, session corpus:<id>) for each series the manifest declares:
       key_to_frame         key.frame signposts plus the key's age (send to the end of its frame's commit)
       action_to_frame      action.commit of actions that were not sent by the CLI
       cli_to_frame         a CLI event's send to the end of the first CLI action.commit after it
       switch_to_frame      switch.workspace, switch.tab and switch.pane_focus
       tab_switch_to_frame  switch.tab
       dropped_frames       debug.frames `missed` over the window
     as `corpus.<id with _ for ->.<series>`. A declared metric the player does not compute is listed as
     unmeasured in the summary (its story measures it around `replay()`). A replay whose send lateness p95 is
     over --max-late-ms did not keep its timing: it raises ScheduleError and writes no result.

Layout references (`@w3.p0.t1`: workspace 3, pane 0, tab 1) are positions in the app's `snapshot.get` topology
at the moment of the event: workspaces in sidebar order, panes in the order of their screen's pane list, tabs in
their pane's order. The recorder (task 116) writes them by the same rule (``Refs``), so a tab a replay opens has
the same reference it had when it was recorded.

--verify plays each story twice: the checkpoint digests of both runs must be equal and each metric's p50 must
agree within --max-cv (coefficient of variation over the two runs). --all plays every recorded, non-compose
story of perf-corpus/; a planned story is listed as skipped, and a run that plays nothing fails.

`replay(manifest, *, app, out, window=None)` is the API stories that measure around a replay call
(blocking_hangs.py, main_turn.py). `out` gets the replay's result-v1 files, its summary and the
host-env-full-<pid>.json of its launch.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_play.py
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import math
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
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
RPC_TIMEOUT_S = 10
CLI_TIMEOUT_S = 60
SIGNPOST_CATEGORIES = ("key", "action", "switch")

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
REF = re.compile(r"@w(\d+)(?:\.p(\d+)(?:\.t(\d+))?)?")
REF_KINDS = ("workspace", "pane", "tab")

# The fields of debug.surfaces rows and debug.focus windows a checkpoint digest covers: state, never an id, a
# time, a counter or a field that changes with load (a page's paint phase, warm-terminal counts).
SURFACE_FIELDS = ("visible", "presence", "kind", "content_installed", "content_in_window", "content_size", "blank",
                  "collapsed", "focused")
FOCUS_CONTEXT = ("terminal_focused", "browser_focused", "agent_focused", "palette_open")


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


# ---------------------------------------------------------------- checkpoint digests

def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _sha(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode()).hexdigest()


def _position(items: Sequence[str], wanted: Any) -> int | None:
    return items.index(wanted) if wanted in items else None


def focus_view(report: Mapping[str, Any]) -> dict[str, Any]:
    """The part of a debug.focus report a checkpoint compares: per window its focus target kind, overlays, sidebar,
    consistency, and the shown workspace's panes as tab kinds with the selected and focused positions. Ids become
    positions and windows are sorted, so two replays of the same state give the same view."""
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
        windows.append({"resolved": model.get("resolved"), "overlays": sorted(model.get("overlays") or []),
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


def focus_digest(report: Mapping[str, Any]) -> str:
    return _sha(focus_view(report))


def surfaces_digest(report: Mapping[str, Any]) -> str:
    return _sha(surfaces_view(report))


def read_checkpoint(rpc: Callable[..., Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """(debug.focus, debug.surfaces) of the app behind `rpc`; PlayError when either has no report."""
    reports = []
    for method in ("debug.focus", "debug.surfaces"):
        reply = rpc(method, {}, RPC_TIMEOUT_S)
        if not isinstance(reply, dict) or reply.get("error") is not None:
            raise PlayError(f"{method} gave no report: {json.dumps(reply)[:200]}")
        reports.append(reply)
    return reports[0], reports[1]


# ---------------------------------------------------------------- layout references

class Refs:
    """Resolves `@wN[.pN[.tN]]` against the app's `snapshot.get` topology. The topology is read again after any
    sent event (it may have changed the layout), and only when a reference needs it."""

    def __init__(self, rpc: Callable[..., Any]):
        self.rpc = rpc
        self._workspaces: list[dict[str, Any]] | None = None

    def invalidate(self) -> None:
        self._workspaces = None

    def resolve(self, ref: str) -> tuple[str, str]:
        """(kind, id): kind is workspace, pane or tab. PlayError when the position does not exist now."""
        match = REF.fullmatch(ref)
        if match is None:
            raise PlayError(f"{ref}: the player resolves @wN, @wN.pN and @wN.pN.tN")
        if self._workspaces is None:
            reply = self.rpc("snapshot.get", {}, RPC_TIMEOUT_S)
            topology = reply.get("topology") if isinstance(reply, dict) else None
            if not isinstance(topology, dict):
                raise PlayError(f"snapshot.get gave no topology: {json.dumps(reply)[:200]}")
            self._workspaces = [w for w in topology.get("workspaces") or [] if w.get("id")]
        indexes = [int(group) for group in match.groups() if group is not None]
        node: Any = {"children": self._workspaces}
        for depth, index in enumerate(indexes):
            children = node["children"] if depth == 0 else (
                [p for s in node.get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]
                if depth == 1 else node.get("tabs") or [])
            if index >= len(children):
                raise PlayError(f"{ref}: there is no {REF_KINDS[depth]} {index} (the app has {len(children)})")
            node = children[index]
        return REF_KINDS[len(indexes) - 1], str(node["id"])

    def target(self, ref: str) -> str:
        kind, ident = self.resolve(ref)
        return f"{kind}:{ident}"


# ---------------------------------------------------------------- the story

@dataclass(frozen=True)
class Step:
    """One input event to send: `params` are the socket call's, with layout references still unresolved."""
    t_ms: float
    index: int
    kind: str
    params: Mapping[str, Any]


@dataclass(frozen=True)
class Checkpoint:
    t_ms: float
    name: str
    focus: str
    surfaces: str


@dataclass
class Story:
    manifest: dict[str, Any]
    path: Path              # a manifest file pty_replay.py can read
    snapshot: dict[str, Any]
    timeline: list[Step | Checkpoint]
    skipped: int            # events with nothing to send (key ups, flag changes, bare modifier presses)
    engine: str

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
    """debug.mouse's params. A recorded drag point continues the drag from the last point (no press, no release);
    a down or up carries one click, so a double click replays as its two presses."""
    x, y = payload["x"], payload["y"]
    common = {"button": BUTTONS[payload["button"]], "modifiers": [MODIFIERS[m] for m in payload.get("modifiers", [])
                                                                   if m in MODIFIERS]}
    phase = payload["phase"]
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


def plan(manifest: Mapping[str, Any], events: Sequence[Mapping[str, Any]], typing_classes: frozenset[str]
         ) -> tuple[list[Step | Checkpoint], int]:
    """The timeline: steps and checkpoints by time, a checkpoint before the events of its own time (the state at t
    is the state before the input at t). Raises PlayError before any launch for an event the player cannot send."""
    typist, last, steps, skipped = Typist(), [0.0, 0.0], [], 0
    for index, event in enumerate(events):
        kind, payload = event["kind"], event["payload"]
        if kind == "key":
            params = key_params(payload, typist, typing_classes)
        elif kind == "mouse":
            params = mouse_params(payload, last)
        elif kind == "action":
            params = {"id": payload["id"], "args": dict(payload.get("args", {}))}
        else:
            params = {"argv": list(payload["argv"])}
        if params is None:
            skipped += 1
            continue
        refs = ([v for value in params.get("args", {}).values() for v in _refs_in(value)]
                + [part.partition("=")[2] or part for part in params.get("argv", []) if "@" in part])
        for ref in refs:
            if REF.fullmatch(ref) is None:
                raise PlayError(f"event {index}: {ref} is not a reference the player resolves (@wN, @wN.pN, @wN.pN.tN)")
        steps.append(Step(float(event["t_ms"]), index, kind, params))
    checkpoints = [Checkpoint(float(c["t_ms"]), c["name"], c["focus"], c["surfaces"]) for c in manifest["checkpoints"]]
    timeline = sorted([*checkpoints, *steps], key=lambda item: (item.t_ms, 0 if isinstance(item, Checkpoint) else 1))
    return timeline, skipped


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
    paused_ms: float = 0.0
    checkpoints: list[dict[str, str]] = field(default_factory=list)

    def report(self) -> dict[str, Any]:
        return {"sent": len(self.lateness_ms), "lateness_ms": perf_stats().summary(self.lateness_ms),
                "paused_ms": round(self.paused_ms, 3)}


def play_track(timeline: Sequence[Step | Checkpoint], *, send: Callable[[Step], None],
               checkpoint: Callable[[Checkpoint], dict[str, str]], clock: Clock) -> Track:
    """Sends each step at origin + t_ms on absolute deadlines and reads each checkpoint. Lateness is the send's start
    against its deadline; a checkpoint's own time moves the origin, so the steps after it keep their spacing."""
    track = Track()
    origin = clock.now_ns()
    for item in timeline:
        deadline = origin + round(item.t_ms * NS_PER_MS)
        clock.sleep_until(deadline)
        now = clock.now_ns()
        if isinstance(item, Checkpoint):
            track.checkpoints.append(checkpoint(item))
            pause = clock.now_ns() - now
            origin += pause
            track.paused_ms += pause / NS_PER_MS
        else:
            track.lateness_ms.append(max(now - deadline, 0) / NS_PER_MS)
            send(item)
    return track


# ---------------------------------------------------------------- sending

class Sender:
    """Sends steps to the app: debug.key, debug.mouse and action.run on the socket, CLI events as processes (not
    waited for in the window; `finish` collects them). A refused event fails the replay at once."""

    def __init__(self, bench: Any, refs: Refs, clock: Clock, spawn: Callable[[Sequence[str]], Any]):
        self.bench, self.refs, self.clock, self.spawn = bench, refs, clock, spawn
        self.cli: list[tuple[float, Any, Step]] = []

    def send(self, step: Step) -> None:
        try:
            if step.kind == "cli":
                argv = [self._cli_part(part) for part in step.params["argv"]]
                stamp = self.clock.signpost_s()
                self.cli.append((stamp, self.spawn(argv), step))
                return
            if step.kind == "key":
                method, params = "debug.key", {**step.params, "timestamp": self.clock.event_s()}
            elif step.kind == "mouse":
                method, params = "debug.mouse", dict(step.params)
            else:
                args = {name: self.refs.resolve(value)[1] if _refs_in(value) else value
                        for name, value in step.params["args"].items() if name != "target"}
                params = {"action": step.params["id"], "args": args, "focus": True, "origin": "script"}
                if "target" in step.params["args"]:
                    params["target"] = self.refs.target(step.params["args"]["target"])
                method = "action.run"
            reply = self.bench.rpc(method, params, RPC_TIMEOUT_S)
            if isinstance(reply, dict) and reply.get("error") is not None:
                raise PlayError(f"refused: {json.dumps(reply['error'])[:300]}")
        except PlayError as error:
            raise PlayError(f"event {step.index} ({step.kind} at {step.t_ms:g} ms): {error}") from error
        finally:
            self.refs.invalidate()

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


# ---------------------------------------------------------------- series

def series(parsed: Mapping[str, Any], cli_stamps: Sequence[float], window: tuple[float, float],
           frames: Mapping[str, Any]) -> dict[str, list[float]]:
    """The player's series (module docstring) from perf-signposts.parse output inside `window` (signpost seconds)."""
    start, end = window
    done = [i for i in parsed["intervals"] if start <= i["at_s"] <= end and not i["missed"] and not i["nested_loop"]]
    out: dict[str, list[float]] = {"key_to_frame": [], "action_to_frame": [], "cli_to_frame": [], "switch_to_frame": [],
                                   "tab_switch_to_frame": []}
    cli_commits = []
    for interval in done:
        name, info = interval["name"], interval["fields"]
        if name == "key.frame" and float(info.get("age_ms", "-1")) >= 0:
            out["key_to_frame"].append(interval["ms"] + float(info["age_ms"]))
        elif name == "action.commit":
            if info.get("origin") == "cli":
                cli_commits.append(interval)
            else:
                out["action_to_frame"].append(interval["ms"])
        elif name in ("switch.workspace", "switch.tab", "switch.pane_focus"):
            out["switch_to_frame"].append(interval["ms"])
            if name == "switch.tab":
                out["tab_switch_to_frame"].append(interval["ms"])
    cli_commits.sort(key=lambda i: i["at_s"])
    used = 0
    for stamp in sorted(cli_stamps):
        while used < len(cli_commits) and cli_commits[used]["at_s"] < stamp:
            used += 1
        if used < len(cli_commits):
            commit = cli_commits[used]
            out["cli_to_frame"].append((commit["at_s"] - stamp) * 1000 + commit["ms"])
            used += 1
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


def default_bench(app: str, *, out: Path, env: Mapping[str, str], session: str):
    return bench_launch().BenchApp(app, out=str(out), env=dict(env), perf_session=session)


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


def default_web_replay(archive: Path, spki: str, out: Path):
    """wpr.py's `serve(archive, spki=, out=)` (task 113): a context manager that runs `wpr replay` and yields the
    CEF switches ({name: value}) that point Chromium at it."""
    return _load("perf_lab_corpus_wpr", HERE / "wpr.py").serve(archive, spki=spki, out=out)


def default_agents(root: Path, agents: Sequence[Mapping[str, Any]], fetch: Callable[[Mapping[str, Any]], Path]) -> None:
    """agent_replay.py's `prepare(root, agents, fetch)` (task 114): stages the replay harness and each transcript
    under the acpmux root the app gets as CMUX_NEXT_ACPMUX_ROOT."""
    _load("perf_lab_corpus_agent_replay", HERE / "agent_replay.py").prepare(root, list(agents), fetch)


class Player:
    """replay() with its seams: tests pass fakes for the app, the clock, the signposts and the source reads."""

    def __init__(self, *, root: Path = REPO_ROOT, clock: Clock | None = None,
                 fetch: Callable[[Mapping[str, Any]], Path] | None = None, make_bench: Callable[..., Any] = default_bench,
                 import_layout: Callable[..., Any] = default_import, signposts: Callable[[int], Any] = _Signposts,
                 spawn: Callable[[Sequence[str]], Any] = CliProcess, web_replay: Callable[..., Any] = default_web_replay,
                 agents: Callable[..., None] = default_agents, max_late_ms: float = MAX_LATE_P95_MS,
                 settle_s: float = CHECKPOINT_SETTLE_S, cache_dir: Path | None = None):
        self.root, self.clock = Path(root), clock or HostClock()
        self.fetch = fetch or (lambda ref: default_fetch(ref, self.root))
        self.make_bench, self.import_layout, self.signposts = make_bench, import_layout, signposts
        self.spawn, self.web_replay, self.agents = spawn, web_replay, agents
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
        for track in doc["pty"]:
            self.fetch(track["source"])  # into the cache now: the terminal never fetches while the app is measured
        if doc["pty"] and not (HERE / "pty_replay.py").is_file():
            raise PlayError(f"{doc['id']}: PTY tracks need scripts/perf-lab/corpus/pty_replay.py (p12-perf-process-112)")
        timeline, skipped = plan(doc, events, corpus.TYPING_CLASSES)
        if path is None:
            path = scratch / f"{doc['id']}.json"
            path.write_text(json.dumps(doc), encoding="utf-8")
        return Story(doc, path.resolve(), snapshot, timeline, skipped, story_engine(doc, snapshot))

    # Replay.

    def replay(self, manifest: str | os.PathLike | Mapping[str, Any], *, app: str, out: str | os.PathLike,
               window: Callable[[Any], contextlib.AbstractContextManager] | None = None,
               story_name: str | None = None) -> Replay:
        out = Path(out)
        out.mkdir(parents=True, exist_ok=True)
        story = self.load(manifest, out)
        manifest_doc = story.manifest
        with contextlib.ExitStack() as stack:
            env: dict[str, str] = {}
            archive = manifest_doc["web_archive"]
            if archive is not None:
                switches = stack.enter_context(self.web_replay(self.fetch(archive["wprgo"]), archive["spki"], out))
                env["CMUX_NEXT_BENCH_CEF_SWITCHES"] = "\n".join(f"{name}={value}" for name, value in switches.items())
            if manifest_doc["agents"]:
                root = out / "acpmux"
                self.agents(root, manifest_doc["agents"], self.fetch)
                env["CMUX_NEXT_ACPMUX_ROOT"] = str(root)
            bench = self.make_bench(app, out=out, env=env, session=f"corpus:{story.id}")
            stack.callback(bench.stop)
            bench.launch()  # bench_launch.LaunchError when the app does not come up
            stack.callback(self.import_layout(bench.rpc, story.snapshot).close)
            refs = Refs(bench.rpc)
            self.start_pty(story, bench, refs)
            sender = Sender(bench, refs, self.clock, lambda argv: self.spawn([bench.cli, "--app-socket", bench.socket, *argv]))
            track, frames, lines, span = self.measure(story, bench, sender, window, out)
            cli_stamps = sender.finish()
            schedule = track.report()
            p95 = schedule["lateness_ms"]["p95"]
            if p95 is not None and p95 > self.max_late_ms:
                raise ScheduleError(f"{story.id}: sends were {p95:.2f} ms late at p95 (bound {self.max_late_ms:g} ms): "
                                    "the input track did not keep its recorded timing")
            measured = series(perf_signposts().parse(lines, None), cli_stamps, span, frames)
            result = self.record(story, bench, measured, track, schedule, story_name)
        (out / f"corpus-play-{story.id}.json").write_text(json.dumps(result.summary(), indent=1), encoding="utf-8")
        return result

    def start_pty(self, story: Story, bench: Any, refs: Refs) -> None:
        """Types `pty_replay.py --manifest M --track N` into each track's terminal (the bytes go through the PTY)."""
        cache = self.cache_dir or corpus_manifest().default_cache_dir()
        for index, track in enumerate(story.manifest["pty"]):
            kind, tab = refs.resolve(track["surface"])
            if kind != "tab":
                raise PlayError(f"pty track {index}: {track['surface']} is a {kind}, not a terminal tab")
            command = shlex.join([sys.executable, "-I", str(HERE / "pty_replay.py"), "--manifest", str(story.path),
                                  "--track", str(index), "--root", str(self.root)])
            text = f"CMUX_PERF_CORPUS_CACHE={shlex.quote(str(cache))} {command}\n"
            reply = bench.rpc("action.run", {"action": "terminal.sendText", "args": {"text": text},
                                             "target": f"tab:{tab}", "focus": False, "origin": "script"}, RPC_TIMEOUT_S)
            if isinstance(reply, dict) and reply.get("error") is not None:
                raise PlayError(f"pty track {index}: terminal.sendText refused: {json.dumps(reply['error'])[:300]}")

    def measure(self, story: Story, bench: Any, sender: Sender, window, out: Path):
        """The measured window: signposts and frames around the `window(bench)` hook around the input track."""
        recording = self.signposts(bench.process.pid)
        lines: list[str] | None = None
        try:
            started = bench.rpc("debug.frames", {"action": "start"}, RPC_TIMEOUT_S)
            if isinstance(started, dict) and started.get("error") is not None:
                raise PlayError(f"debug.frames: {json.dumps(started['error'])[:200]}")
            start = self.clock.signpost_s()
            with (window(bench) if window is not None else contextlib.nullcontext()):
                track = play_track(story.timeline, send=sender.send, clock=self.clock,
                                   checkpoint=lambda item: self.checkpoint(bench.rpc, item, out))
            end = self.clock.signpost_s()
            frames = bench.rpc("debug.frames", {"action": "stop"}, RPC_TIMEOUT_S)
            lines = recording.stop()
        finally:
            if lines is None:
                recording.stop()
        return track, frames if isinstance(frames, dict) else {}, lines, (start, end)

    def checkpoint(self, rpc: Callable[..., Any], item: Checkpoint, out: Path) -> dict[str, str]:
        """Reads the checkpoint until both digests are the recorded ones or settle_s passes; DigestMismatch names the
        first digest that differs, and the views are kept in `out` for the diff."""
        deadline = self.clock.now_ns() + round(self.settle_s * 1e9)
        while True:
            focus, surfaces = read_checkpoint(rpc)
            got = {"focus": focus_digest(focus), "surfaces": surfaces_digest(surfaces)}
            if got["focus"] == item.focus and got["surfaces"] == item.surfaces:
                return {"name": item.name, **got}
            if self.clock.now_ns() >= deadline:
                break
            self.clock.sleep_until(self.clock.now_ns() + round(CHECKPOINT_POLL_S * 1e9))
        (out / f"checkpoint-{item.name}.json").write_text(
            json.dumps({"focus": focus_view(focus), "surfaces": surfaces_view(surfaces)}, indent=1), encoding="utf-8")
        which = "focus" if got["focus"] != item.focus else "surfaces"
        raise DigestMismatch(item.name, item.t_ms, which, getattr(item, which), got[which])

    def record(self, story: Story, bench: Any, measured: dict[str, list[float]], track: Track,
               schedule: dict[str, Any], story_name: str | None) -> Replay:
        name = story_name or os.environ.get("PERF_LAB_STORY") or f"corpus-{story.id}"
        written, kept = [], {}
        for series_name, samples in sorted(measured.items()):
            metric = f"corpus.{metric_id(story.id)}.{series_name}"
            spec = declared(story.manifest, metric)
            if spec is None:
                continue
            kept[metric] = samples
            written.append(str(bench.record(name, metric, spec["unit"], samples, spec["better"], story.engine)))
        unmeasured = [m["name"] for m in story.manifest["metrics"] if not any(re.fullmatch(m["name"], k) for k in kept)]
        return Replay(story.id, track.checkpoints, schedule, kept, written, unmeasured, story.skipped)


def replay(manifest: str | os.PathLike | Mapping[str, Any], *, app: str, out: str | os.PathLike,
           window: Callable[[Any], contextlib.AbstractContextManager] | None = None, player: Player | None = None,
           story_name: str | None = None) -> Replay:
    """Replays one recorded corpus story into a fresh launch of `app` (module docstring). After the launch and the
    layout import, `window(bench)` is called once with the BenchApp and the input track plays inside the context
    manager it returns. A failed launch raises bench_launch.LaunchError; a divergence raises PlayError."""
    return (player or Player()).replay(manifest, app=app, out=out, window=window, story_name=story_name)


# ---------------------------------------------------------------- verify

def compare_runs(first: Replay, second: Replay, max_cv: float = VERIFY_MAX_CV) -> list[str]:
    """Why two replays of one story disagree: the first checkpoint whose digests differ, and each metric whose p50
    varies over the two runs by more than `max_cv` (stdev over mean)."""
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
        medians = [stats.pct(first.series[metric], 0.5), stats.pct(second.series[metric], 0.5)]
        mean = sum(medians) / 2
        cv = 0.0 if mean == 0 else math.sqrt(sum((m - mean) ** 2 for m in medians)) / mean  # n-1 = 1
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
    sys.exit(main())
