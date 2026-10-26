#!/usr/bin/env python3
"""Recorder for synthetic corpus sessions (p12-perf-process.md 3.8, task p12-perf-process-116).

    python3 scripts/perf-lab/corpus/record.py record --app "/path/cmux DEV <tag>.app" --story dev-loop --out DIR \\
        [--layout layout.json] [--duration-ms 60000] [--pty '@w0.p0.t0=COMMAND' ...] [--cache DIR]
    python3 scripts/perf-lab/corpus/record.py record --socket /tmp/cmux-debug-<tag>.sock --story dev-loop --out DIR
    python3 scripts/perf-lab/corpus/record.py pty-tap --out FILE --stop-file FILE -- COMMAND ...

It launches a tagged bench app with CMUX_NEXT_INPUT_JOURNAL=1 (`--app`, through bench_launch.BenchApp) or attaches to
a running one (`--socket`), and records one story of the corpus while a person or a story driver works in it:

  - the layout snapshot at the start (session_io.export_layout; `--layout` first imports one into the fresh app)
  - the input track from the input journal (`debug.journal`): key classes and mouse records, never characters. A
    typing key keeps no key code, so the player types the next character of its fixed synthetic text instead.
    Actions a driver runs through `Recording.action` are recorded as action events.
  - PTY tracks through the PTY tap (`pty-tap`), the bench hook a `--pty` terminal runs its command under: it reads
    the command's output from a pty of its own, shows it, and keeps it as ttyrec frames on the monotonic clock. It
    gives the command /dev/null as input, so nothing typed reaches the command or its track.
  - checkpoints at the story's checkpoint times: the debug.focus and debug.surfaces digests (`checkpoint_digests`,
    which the player (task 115) uses too, so a replay can be compared with its recording)

and writes the manifest to DIR/<id>.json and the blobs (layout, NDJSON input track over INLINE_EVENTS events, PTY
tracks) into the corpus cache, from where `manifest.py --upload` puts them in R2. The manifest starts from the
story's planned manifest (perf-corpus/<id>.json or `--template`): its description, owner, metrics, agents and web
archive stay. It is `recorded` only when no source is still null, else it stays `planned` and says what is missing.
Chromium records its stories the same way: one recorder run per story set writes the archive and its hash file, and
the upload is by hash (tools/perf/record_wpr, third_party/catapult/telemetry/telemetry/record_wpr.py).

Privacy (rule R10): the recorder refuses /Applications/cmux.app, the bundle id com.cmuxterm.app, any bundle that is
not a tagged bench-hooks build (`scripts/reload.sh --config bench`; a Debug build is the one that can journal
characters), any target environment with CMUX_NEXT_INPUT_JOURNAL_CHARACTERS set (whatever its value), and a journal
that says it records characters. Key payloads are built from an allowlist, so a journal that carried characters
anyway still stores none. A PTY track holding the account's home path, user name or host name is refused. The
manifest and its input blob pass manifest.py's text checks before anything is written.

Stdlib only. Tests: python3 -m unittest scripts/perf-lab/tests/test_record.py
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import fcntl
import importlib.util
import json
import os
import pty
import pwd
import select
import shlex
import signal
import socket
import subprocess
import sys
import termios
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]
CMUX_NEXT_SCRIPTS = REPO_ROOT / "scripts" / "cmux-next"

ENABLE_KEY = "CMUX_NEXT_INPUT_JOURNAL"
CHARACTERS_KEY = "CMUX_NEXT_INPUT_JOURNAL_CHARACTERS"
USER_APP = "/Applications/cmux.app"
USER_BUNDLE_ID = "com.cmuxterm.app"
BENCH_ID_PREFIX = "com.cmuxterm.app.debug."
BENCH_KIND = "bench-hooks"  # bench_launch.bundle_kind of a --config bench, bench-checks or profile app

JOURNAL_LAST = 4096  # InputJournal.defaultCapacity: one read returns the whole ring
POLL_S = 0.25  # a read of the journal every POLL_S keeps well ahead of the ring at any typing rate
MARKER = "corpus-record"  # the recorder's own journal marker; markers are never recorded as events
MARK_LAST = 16  # a mark reads this many entries: its marker and what other threads appended right after it
INLINE_EVENTS = 400  # more events than this go to an NDJSON input blob
TAP_START_S = 15.0
TAP_STOP_S = 15.0
TAP_READ_BYTES = 1 << 16

MODIFIERS = ((1, "cmd"), (2, "shift"), (4, "option"), (8, "ctrl"), (16, "fn"), (32, "caps"))  # ModifierClasses bits
KEY_CLASSES = frozenset({"letter", "digit", "punctuation", "space", "named", "modifier", "other"})
KEY_PHASES = frozenset({"down", "up", "flags"})
MOUSE_PHASES = frozenset({"down", "up", "drag", "scroll"})
# The player's fixed synthetic text, one cycle per typing class (task 115 types these for typing keys).
SYNTHETIC_TEXT = {"letter": "etaoinshrdlucmfwypvbgkjqxz", "digit": "0123456789", "punctuation": ".,;:-_/()[]=+",
                  "space": " ", "other": "éüñåß"}


class RecordError(RuntimeError):
    """The target may not be recorded, or the recording cannot be written truthfully."""


def _load(name: str, path: Path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
        spec.loader.exec_module(module)
    return sys.modules[name]


def corpus_manifest():
    return _load("perf_lab_corpus_manifest", HERE / "manifest.py")


def session_io():
    return _load("perf_lab_corpus_session_io", HERE / "session_io.py")


def pty_replay():
    return _load("perf_lab_corpus_pty_replay", HERE / "pty_replay.py")


def bench_launch():
    return _load("bench_launch", CMUX_NEXT_SCRIPTS / "bench_launch.py")


class SyntheticText:
    """The fixed text a replay types: the next character of the key's class, each class cycling on its own."""

    def __init__(self):
        self.used = dict.fromkeys(SYNTHETIC_TEXT, 0)

    def next(self, key_class: str) -> str:
        text = SYNTHETIC_TEXT[key_class]
        index, self.used[key_class] = self.used[key_class], self.used[key_class] + 1
        return text[index % len(text)]


# ---------------------------------------------------------------- what may be recorded

def bundle_refusal(app: str, *, reported_id: str | None = None) -> str | None:
    """Why the recorder may not attach to bundle APP (None when it may): the person's cmux, a bundle that is not a
    tagged `cmux DEV <tag>.app` with a com.cmuxterm.app.debug.* id, or a build without bench hooks. `reported_id` is
    the id the running app gave (`system.identify`); it must be the bundle's own."""
    real = os.path.realpath(app).rstrip("/")
    if real == USER_APP or os.path.basename(real) == "cmux.app":
        return f"{app} is the person's cmux, never a recording target"
    launch = bench_launch()
    try:
        launch.tag_of(real)
    except SystemExit:
        return f"{app} is not a tagged `cmux DEV <tag>.app` bench bundle"
    plist_id = launch.bundle_id(real)
    for found in (plist_id, reported_id):
        if found is not None and found.lower() == USER_BUNDLE_ID:
            return f"{app} has the bundle id {USER_BUNDLE_ID} of the person's cmux"
    if not (plist_id or "").lower().startswith(BENCH_ID_PREFIX):
        return f"{app} has the bundle id {plist_id!r}, not a {BENCH_ID_PREFIX}* bench id"
    if reported_id is not None and reported_id != plist_id:
        return f"the running app says bundle id {reported_id!r}, but {app} is {plist_id!r}"
    try:
        kind = launch.bundle_kind(real, launch.main_binary(real))
    except (SystemExit, OSError) as error:
        return f"{app}: cannot read its executable ({error})"
    if kind != BENCH_KIND:
        return f"{app} is a {kind} build, not a bench build (scripts/reload.sh --config bench)"
    return None


def env_refusal(env: Mapping[str, str], where: str = "the target environment") -> str | None:
    if CHARACTERS_KEY in env:
        return f"{CHARACTERS_KEY} is set in {where}: the corpus never holds typed characters"
    return None


ENV_PROOF_KEYS = ("HOME", "PATH", ENABLE_KEY)  # one of them is in every launch's environment


def process_env_refusal(pid: int, run: Callable[..., Any] = subprocess.run) -> str | None:
    """The environment check for a running app: `ps -E` of PID (the account's own process). Fails closed: an
    environment it cannot read is refused. ps prints only the command when it cannot read the environment
    (KERN_PROCARGS2 fails), so an output with none of ENV_PROOF_KEYS is no environment."""
    try:
        done = run(["/bin/ps", "-E", "-ww", "-o", "command=", "-p", str(int(pid))], capture_output=True, text=True,
                   timeout=10)
    except (OSError, subprocess.SubprocessError, TypeError, ValueError) as error:
        return f"cannot read the environment of pid {pid}: {error}"
    if done.returncode != 0 or not done.stdout.strip():
        return f"cannot read the environment of pid {pid} (ps exit {done.returncode})"
    words = done.stdout.split()
    if not any(word.startswith(f"{key}=") for key in ENV_PROOF_KEYS for word in words):
        return f"cannot read the environment of pid {pid}: ps printed no environment"
    return env_refusal({CHARACTERS_KEY: ""} if f"{CHARACTERS_KEY}=" in done.stdout else {}, f"pid {pid}")


def journal_refusal(stats: Any) -> str | None:
    if not isinstance(stats, Mapping) or stats.get("enabled") is not True:
        return f"the input journal is off: launch the bench app with {ENABLE_KEY}=1"
    if stats.get("recordsCharacters") is not False:
        return "the input journal records characters: the corpus never holds typed characters"
    return None


def pty_privacy_problem(data: bytes, private: Iterable[str]) -> str | None:
    for value in private:
        if len(value) >= 3 and value.encode() in data:
            return f"the PTY output holds the account's {value!r}: a corpus track is synthetic output only"
    return None


def account_private() -> list[str]:
    entry = pwd.getpwuid(os.getuid())
    return sorted({entry.pw_dir, entry.pw_name, os.path.expanduser("~"), socket.gethostname().split(".")[0]})


# ---------------------------------------------------------------- journal records to events

def modifier_names(bits: Any) -> list[str]:
    if not isinstance(bits, int) or isinstance(bits, bool) or bits < 0:
        raise RecordError(f"journal modifiers {bits!r} are not ModifierClasses bits")
    return [name for bit, name in MODIFIERS if bits & bit]


def key_payload(key: Mapping[str, Any]) -> dict[str, Any]:
    """The manifest key payload of a journal key record, from an allowlist: never `characters`, and no key code for a
    typing key (a text class without cmd or ctrl), whatever the journal held."""
    phase, key_class = key.get("phase"), key.get("keyClass")
    if phase not in KEY_PHASES or key_class not in KEY_CLASSES:
        raise RecordError(f"journal key record with phase {phase!r} and class {key_class!r}")
    modifiers = modifier_names(key.get("modifiers"))
    payload: dict[str, Any] = {"phase": phase, "class": key_class, "modifiers": modifiers}
    typing = key_class in corpus_manifest().TYPING_CLASSES and not {"cmd", "ctrl"} & set(modifiers)
    code = key.get("keyCode")
    if not typing and isinstance(code, int) and not isinstance(code, bool) and 0 <= code <= 0xFFFF:
        payload["key_code"] = code
    if key.get("isRepeat") is True:
        payload["repeat"] = True
    return payload


def mouse_payload(mouse: Mapping[str, Any]) -> dict[str, Any]:
    phase, button = mouse.get("phase"), mouse.get("button")
    if phase not in MOUSE_PHASES:
        raise RecordError(f"journal mouse record with phase {phase!r}")
    payload: dict[str, Any] = {"phase": phase, "button": button if button in (0, 1) else 2,
                               "x": round(float(mouse.get("x", 0)), 1), "y": round(float(mouse.get("y", 0)), 1),
                               "modifiers": modifier_names(mouse.get("modifiers"))}
    if isinstance(mouse.get("clickCount"), int) and mouse["clickCount"] > 0:
        payload["click_count"] = mouse["clickCount"]
    if phase == "scroll":
        payload["dx"], payload["dy"] = round(float(mouse.get("dx", 0)), 3), round(float(mouse.get("dy", 0)), 3)
    return payload


class WindowRefs:
    """Journal window ids as layout refs: the snapshot's window has none (the default), others @win1, @win2, ... in
    the order they first appear."""

    def __init__(self, main: str | None):
        self.main, self.others = main, {}

    def ref(self, window: Any) -> str | None:
        if window is None or window == self.main:
            return None
        return self.others.setdefault(window, f"@win{len(self.others) + 1}")


def journal_event(entry: Mapping[str, Any], t0_ns: int, windows: WindowRefs) -> dict[str, Any] | None:
    """The input event of a journal entry (Swift's synthesized enum JSON, {"key": {"_0": {...}}}), or None for an
    entry that is no input: focus, responder, attach, content and window records, markers."""
    kind = entry.get("kind")
    if not isinstance(kind, Mapping) or len(kind) != 1:
        return None
    (name, value), = kind.items()
    if name not in ("key", "mouse"):
        return None
    record = value.get("_0") if isinstance(value, Mapping) else None
    if not isinstance(record, Mapping):
        raise RecordError(f"journal {name} entry {entry.get('seq')} has no record")
    t_ms = (int(entry["uptimeNanos"]) - t0_ns) / 1e6
    if t_ms < 0:
        return None
    payload = key_payload(record) if name == "key" else mouse_payload(record)
    window = windows.ref(entry.get("window"))
    if window:
        payload["window"] = window
    return {"t_ms": round(t_ms, 3), "kind": name, "payload": payload}


def is_marker(entry: Mapping[str, Any]) -> bool:
    """Whether ENTRY is a journal marker the recorder appended."""
    marker = (entry.get("kind") or {}).get("marker")
    return isinstance(marker, Mapping) and marker.get("_0") == MARKER


class JournalReader:
    """Every journal entry after the recorder's start marker, read a ring at a time. A drag or scroll run is one
    entry the app keeps updating, so the newest entry of a read is read again in the next one."""

    def __init__(self, rpc: Callable[..., Any]):
        self.rpc, self.entries, self.last_seq, self.mark_seq = rpc, {}, None, None

    def call(self, params: Mapping[str, Any]) -> dict[str, Any]:
        reply = self.rpc("debug.journal", dict(params))
        if not isinstance(reply, Mapping) or "error" in reply or not isinstance(reply.get("entries"), list):
            raise RecordError(f"debug.journal: {str(reply)[:200]}")
        refusal = journal_refusal(reply.get("stats"))
        if refusal:
            raise RecordError(refusal)
        return dict(reply)

    def clear(self) -> None:
        """Empties the ring, so the next `mark` is the start marker."""
        self.call({"clear": True, "last": 0})

    def mark(self) -> int:
        """Appends a marker and returns its uptime on the journal's clock (ns). The app appends the marker and reads
        the ring under two lock turns and records from other threads (attach, input) may land between them, so the
        marker is the newest MARKER entry after the previous one, not the newest entry."""
        entries = self.call({"marker": MARKER, "last": MARK_LAST})["entries"]
        marker = max((entry for entry in entries if is_marker(entry)
                      and (self.mark_seq is None or int(entry["seq"]) > self.mark_seq)),
                     key=lambda entry: int(entry["seq"]), default=None)
        if marker is None:
            raise RecordError("debug.journal did not return its marker")
        self.mark_seq = int(marker["seq"])
        if self.last_seq is None:
            self.last_seq = self.mark_seq
        return int(marker["uptimeNanos"])

    def read(self) -> None:
        entries = sorted(self.call({"last": JOURNAL_LAST})["entries"], key=lambda entry: int(entry["seq"]))
        if not entries:
            return
        oldest = int(entries[0]["seq"])
        if self.last_seq is not None and oldest > self.last_seq + 1:
            raise RecordError(f"the journal ring dropped entries {self.last_seq + 1}..{oldest - 1} between two reads")
        for entry in entries:
            if self.last_seq is None or int(entry["seq"]) >= self.last_seq:
                self.entries[int(entry["seq"])] = entry
        self.last_seq = int(entries[-1]["seq"])

    def events(self, t0_ns: int, windows: WindowRefs) -> list[dict[str, Any]]:
        made = (journal_event(self.entries[seq], t0_ns, windows) for seq in sorted(self.entries))
        return [event for event in made if event is not None]


# ---------------------------------------------------------------- layout refs and checkpoint digests

def _result(rpc: Callable[..., Any], method: str, params: Mapping[str, Any] | None = None) -> dict[str, Any]:
    reply = rpc(method, dict(params or {}))
    if not isinstance(reply, Mapping) or "error" in reply:
        raise RecordError(f"{method}: {str(reply)[:200]}")
    return dict(reply)


def panes_of(workspace: Mapping[str, Any]) -> list[dict[str, Any]]:
    return session_io().load_stress().Stress.panes(workspace)


def shown_orders(rpc: Callable[..., Any], topology: Mapping[str, Any]) -> dict[str, list[str]]:
    """{workspace id: its pane ids in the snapshot's leaf order} for each workspace a window shows (read from its
    laid-out pane frames, session_io.tree_from_frames) and each one-pane workspace. Nothing is shown to read them."""
    io = session_io()
    shown = {window.get("workspace"): window.get("key") for window in topology.get("windows") or []
             if window.get("workspace")}
    orders = {}
    for workspace in topology.get("workspaces") or []:
        panes = [pane["id"] for pane in panes_of(workspace) if pane.get("id")]
        if len(panes) == 1:
            orders[workspace["id"]] = panes
        elif workspace.get("id") in shown and panes:
            try:
                layers = io.settled_window(rpc, shown[workspace["id"]], set(panes), f"workspace {workspace['id']}")
                _, _, order = io.tree_from_frames(io.pane_frames(layers, set(panes)),
                                                  lambda pane: {"tabs": ["terminal"], "selected": 0})
            except io.LayoutSnapshotError as error:
                raise RecordError(f"the shown workspace's pane order: {error}") from error
            orders[workspace["id"]] = order
    return orders


def layout_refs(topology: Mapping[str, Any], orders: Mapping[str, list[str]]) -> dict[str, str]:
    """{layout ref: object id}: every workspace (@wN, sidebar order) and the panes and tabs of each workspace whose
    pane order is known (`shown_orders`), as @wN.pM and @wN.pM.tK."""
    refs = {}
    for index, workspace in enumerate(w for w in topology.get("workspaces") or [] if w.get("id")):
        refs[f"@w{index}"] = workspace["id"]
        panes = {pane["id"]: pane for pane in panes_of(workspace) if pane.get("id")}
        for pane_index, pane_id in enumerate(orders.get(workspace["id"], [])):
            refs[f"@w{index}.p{pane_index}"] = pane_id
            for tab_index, tab in enumerate(panes.get(pane_id, {}).get("tabs") or []):
                refs[f"@w{index}.p{pane_index}.t{tab_index}"] = tab.get("id")
    return refs


def _kind(tab: Mapping[str, Any]) -> str:
    io = session_io()
    try:
        return io.tab_kind(tab, None)
    except io.LayoutSnapshotError:
        return f"other:{tab.get('kind')}"


def checkpoint_state(topology: Mapping[str, Any], orders: Mapping[str, list[str]], focus: Mapping[str, Any],
                     surfaces: Mapping[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """The id-free (focus, surfaces) state a checkpoint digests, the same in every replay of a story: ids differ per
    launch, so each pane and tab is its position (workspace in sidebar order, pane in leaf order where `orders` knows
    it, else panes sorted by their tab kinds), and nothing that only timing changes (generations, recent events,
    paint phases) is in it."""
    workspaces = [w for w in topology.get("workspaces") or [] if w.get("id")]
    at, shapes = {}, []
    for index, workspace in enumerate(workspaces):
        panes = {pane["id"]: pane for pane in panes_of(workspace) if pane.get("id")}

        def shape(pane):
            tabs = pane.get("tabs") or []
            selected = session_io().load_stress().Stress.selected_tab(pane)
            return {"tabs": [_kind(tab) for tab in tabs],
                    "selected": next((i for i, tab in enumerate(tabs) if tab.get("id") == selected), None)}

        order = orders.get(workspace["id"]) or sorted(panes, key=lambda pane_id: json.dumps(shape(panes[pane_id]),
                                                                                           sort_keys=True))
        shapes.append([shape(panes[pane_id]) for pane_id in order if pane_id in panes])
        for pane_index, pane_id in enumerate(order):
            at[pane_id] = [index, pane_index]
            for tab_index, tab in enumerate(panes.get(pane_id, {}).get("tabs") or []):
                at[tab.get("id")] = [index, pane_index, tab_index]
    workspace_at = {workspace["id"]: index for index, workspace in enumerate(workspaces)}
    models = {entry.get("id"): entry.get("model") or {} for entry in focus.get("windows") or []}
    windows = []
    for window in topology.get("windows") or []:
        model = models.get(window.get("key"), {})
        windows.append({"workspace": workspace_at.get(window.get("workspace")),
                        "focused_pane": at.get(window.get("focused_pane")),
                        "resolved": model.get("resolved"), "resolved_pane": at.get(model.get("resolved_pane")),
                        "resolved_tab": at.get(model.get("resolved_tab")), "overlays": model.get("overlays") or [],
                        "sidebar_hidden": model.get("sidebar_hidden")})
    focus_state = {"windows": sorted(windows, key=lambda w: json.dumps(w, sort_keys=True)),
                   "context": focus.get("context") or {}}
    panes = []
    for window in surfaces.get("windows") or []:
        for pane in window.get("panes") or []:
            panes.append({"at": at.get(pane.get("pane")), "kind": pane.get("kind"), "visible": pane.get("visible"),
                          "presence": pane.get("presence"), "selected_tab": at.get(pane.get("selected_tab")),
                          "shown_tab": at.get(pane.get("shown_tab"))})
    surface_state = {"workspaces": shapes, "panes": sorted(panes, key=lambda p: json.dumps(p, sort_keys=True))}
    return focus_state, surface_state


def checkpoint_digests(rpc: Callable[..., Any]) -> tuple[str, str]:
    """(focus, surfaces) sha256 digests of the app behind `rpc` now (`checkpoint_state`)."""
    topology = _result(rpc, "snapshot.get").get("topology") or {}
    focus_state, surface_state = checkpoint_state(topology, shown_orders(rpc, topology), _result(rpc, "debug.focus"),
                                                  _result(rpc, "debug.surfaces"))
    io = session_io()
    return io.digest(focus_state), io.digest(surface_state)


# ---------------------------------------------------------------- the PTY tap (the bench hook in a terminal)

def tap(command: list[str], out_path: str, stop_path: str, *, output_fd: int = 1,
        clock: Callable[[], int] = time.monotonic_ns) -> int:
    """Runs COMMAND on a pty of its own, writes its output to OUTPUT_FD (the terminal) and keeps every read as a
    ttyrec frame stamped with CLOCK (absolute monotonic ns) in OUT_PATH, until the command ends or STOP_PATH exists.
    OUT_PATH + ".done" says the file is complete. The command's input is /dev/null: nothing typed reaches it.
    The pty follows OUTPUT_FD's size: when the terminal is resized (a split, a pane resize) the tap gets SIGWINCH,
    sets the new size on the pty and sends SIGWINCH to the command, as a terminal emulator does for its own pty."""
    header = pty_replay().TTYREC_HEADER
    master, slave = pty.openpty()

    def copy_size() -> None:
        with contextlib.suppress(OSError):  # an output that is no tty keeps the pty's default size
            fcntl.ioctl(master, termios.TIOCSWINSZ, fcntl.ioctl(output_fd, termios.TIOCGWINSZ, b"\0" * 8))

    copy_size()
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, start_new_session=True,
                             close_fds=True)
    os.close(slave)

    def resized(_signum, _frame) -> None:
        copy_size()
        with contextlib.suppress(OSError):  # the command has no controlling tty, so the kernel does not signal it
            os.killpg(child.pid, signal.SIGWINCH)

    previous = signal.signal(signal.SIGWINCH, resized)
    try:
        _tap_loop(child, master, out_path, stop_path, header, output_fd, clock)
    finally:
        signal.signal(signal.SIGWINCH, previous)
    os.close(master)
    with contextlib.suppress(OSError):
        os.killpg(child.pid, signal.SIGKILL)
    code = child.wait()
    Path(out_path + ".done").write_text(str(code), encoding="utf-8")
    return 0


def _tap_loop(child: subprocess.Popen, master: int, out_path: str, stop_path: str, header: Any, output_fd: int,
              clock: Callable[[], int]) -> None:
    stop_at = None
    with open(out_path, "wb") as record:
        while True:
            if stop_at is None and (os.path.exists(stop_path) or child.poll() is not None):
                stop_at = time.monotonic() + 2.0
                with contextlib.suppress(OSError):
                    os.killpg(child.pid, signal.SIGTERM)
            if stop_at is not None and time.monotonic() > stop_at:
                break
            if not select.select([master], [], [], 0.05)[0]:
                continue
            try:
                data = os.read(master, TAP_READ_BYTES)
            except OSError:  # EIO: the command and every process on its pty have ended
                break
            if not data:
                break
            stamp = clock()
            record.write(header.pack(stamp // 1_000_000_000, (stamp // 1000) % 1_000_000, len(data)) + data)
            pty_replay().write_all(output_fd, data)


def trim_tap(data: bytes, start_ns: int, end_ns: int) -> bytes:
    """The PTY track of a tap file: its frames from START_NS to END_NS as ttyrec offsets from START_NS, led by an
    empty frame at offset 0, since a track plays from the start of the input track."""
    header, frames, position = pty_replay().TTYREC_HEADER, [(0.0, b"")], 0
    while position < len(data):
        if len(data) - position < header.size:
            raise RecordError(f"PTY tap: truncated frame header at byte {position}")
        seconds, micros, length = header.unpack_from(data, position)
        position += header.size
        stamp = seconds * 1_000_000_000 + micros * 1000
        if start_ns <= stamp <= end_ns:
            frames.append(((stamp - start_ns) / 1e6, data[position:position + length]))
        position += length
    return pty_replay().encode_ttyrec(frames)


@dataclass
class Tap:
    ref: str
    out: Path
    stop: Path

    @property
    def done(self) -> Path:
        return Path(f"{self.out}.done")


def tap_line(out: Path, stop: Path, command: str) -> str:
    return shlex.join([sys.executable, "-I", str(Path(__file__).resolve()), "pty-tap", "--out", str(out),
                       "--stop-file", str(stop), "--", "/bin/sh", "-c", command]) + "\r"


def parse_pty(spec: str) -> tuple[str, str]:
    ref, _, command = spec.partition("=")
    if not command or corpus_manifest().REF.fullmatch(ref) is None or ref.count(".") != 2:
        raise RecordError(f"--pty {spec!r} is not @wN.pM.tK=COMMAND")
    return ref, command


# ---------------------------------------------------------------- the recording

def load_template(story: str | None, template: Path | None) -> dict[str, Any]:
    path = template or REPO_ROOT / corpus_manifest().CORPUS_DIR / f"{story}.json"
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RecordError(f"{path}: {error}") from error
    errors = corpus_manifest().validation_errors(loaded)
    if errors:
        raise RecordError(f"{path} is not a valid corpus manifest: {'; '.join(errors[:4])}")
    return loaded


def checkpoint_plan(template: Mapping[str, Any], duration_ms: int) -> list[tuple[int, str]]:
    """The story's checkpoints that fall inside DURATION_MS, and `end` at DURATION_MS unless one is there."""
    plan = [(int(c["t_ms"]), c["name"]) for c in template["checkpoints"] if c["t_ms"] <= duration_ms]
    if not plan or plan[-1][0] != duration_ms:
        name = "end" if all(name != "end" for _, name in plan) else "recording-end"
        plan.append((duration_ms, name))
    return plan


class Recording:
    """One story's recording against the app behind `rpc`. `start` exports the layout, starts the PTY taps and
    marks the zero; then `poll` and `checkpoint` (or `run`, which does both on the story's schedule) until `finish`
    returns the manifest. A driver may call `action` in between. `close` stops every PTY tap; `start`, `run` and
    `finish` call it when they fail, and a caller calls it on every exit."""

    def __init__(self, rpc: Callable[..., Any], template: Mapping[str, Any], *, cache: Any, folder: Path,
                 duration_ms: int | None = None, builder: Any = None, clock: Callable[[], int] = time.monotonic_ns,
                 private: Iterable[str] | None = None):
        self.rpc, self.template, self.cache = rpc, copy.deepcopy(dict(template)), cache
        self.folder = Path(folder).resolve()  # the taps' shells have their own working folder
        self.duration_ms = int(duration_ms or template["duration_ms"])
        self.builder, self.clock = builder, clock
        self.private = list(account_private() if private is None else private)
        self.journal = JournalReader(rpc)
        self.taps: list[Tap] = []
        self.actions: list[dict[str, Any]] = []
        self.checkpoints: list[dict[str, Any]] = []
        self.layout_ref = self.workspaces = self.windows = None
        self.t0_ns = self.start_mono = 0
        self.ended = False  # the plan's last checkpoint (at the duration) is taken

    def elapsed_ms(self) -> float:
        return (self.clock() - self.start_mono) / 1e6

    def close(self) -> None:
        """Stops every PTY tap the recording started, each whatever happens to the others; idempotent."""
        for tap_files in self.taps:
            with contextlib.suppress(OSError):
                tap_files.stop.touch()

    def start(self, pty: Iterable[str] = (), sleep: Callable[[float], None] = time.sleep) -> None:
        try:
            self._start(pty, sleep)
        except BaseException:
            self.close()
            raise

    def _start(self, pty: Iterable[str], sleep: Callable[[float], None]) -> None:
        io = session_io()
        self.journal.call({"last": 0})  # refuses a journal that is off or records characters before anything else
        try:
            snapshot = io.export_layout(self.rpc, builder=self.builder)
        except io.LayoutSnapshotError as error:
            raise RecordError(f"layout export: {error}") from error
        self.layout_ref = self.cache.add(io.canonical_bytes(snapshot))
        self.workspaces = len(snapshot["workspaces"])
        topology = _result(self.rpc, "snapshot.get").get("topology") or {}
        main = next((w.get("key") for w in topology.get("windows") or [] if w.get("workspace")), None)
        self.windows = WindowRefs(main)
        refs = layout_refs(topology, shown_orders(self.rpc, topology))
        self.folder.mkdir(parents=True, exist_ok=True)
        for index, spec in enumerate(pty):
            ref, command = parse_pty(spec)
            if ref not in refs:
                raise RecordError(f"--pty {ref}: no such tab, or not in a shown or one-pane workspace")
            if any(t.ref == ref for t in self.taps):
                raise RecordError(f"--pty {ref} twice")
            tap_files = Tap(ref, self.folder / f"pty-{index}.ttyrec", self.folder / f"pty-{index}.stop")
            for path in (tap_files.out, tap_files.stop, tap_files.done):
                path.unlink(missing_ok=True)
            _result(self.rpc, "action.run", {"action": "terminal.sendText", "target": f"tab:{refs[ref]}",
                                             "args": {"text": tap_line(tap_files.out, tap_files.stop, command)},
                                             "focus": False, "origin": "script"})
            self.taps.append(tap_files)
        deadline = time.monotonic() + TAP_START_S
        while not all(t.out.exists() for t in self.taps):
            if time.monotonic() > deadline:
                raise RecordError(f"the PTY tap of {[t.ref for t in self.taps if not t.out.exists()]} did not start")
            sleep(0.05)  # recorder script: the shells start their taps
        self.journal.clear()
        before = self.clock()  # after the clear: the zero comes from the marker's round trip alone
        self.t0_ns = self.journal.mark()
        self.start_mono = (before + self.clock()) // 2  # the zero on this process's clock, which the taps share

    def poll(self) -> None:
        self.journal.read()

    def checkpoint(self, name: str, *, final: bool = False) -> None:
        """Takes checkpoint NAME at its marker's time; the FINAL one (the plan's last) is at the duration, where the
        input and PTY tracks end."""
        t_ms = max(0, min(round((self.journal.mark() - self.t0_ns) / 1e6), self.duration_ms))
        if self.checkpoints and t_ms < self.checkpoints[-1]["t_ms"]:
            t_ms = self.checkpoints[-1]["t_ms"]
        if final:
            t_ms, self.ended = self.duration_ms, True
        focus, surfaces = checkpoint_digests(self.rpc)
        self.checkpoints.append({"t_ms": t_ms, "name": name, "focus": focus, "surfaces": surfaces})
        self.journal.read()

    def action(self, action_id: str, **args: Any) -> dict[str, Any]:
        """Runs action ACTION_ID through action.run and records it. Only a vocabulary action with its declared
        argument shapes is run (corpus-input-vocabulary-v1.json); a `target` ref names a workspace, pane or tab."""
        manifest = corpus_manifest()
        event = {"t_ms": round(max(self.elapsed_ms(), 0.0), 3), "kind": "action",
                 "payload": {"id": action_id, **({"args": dict(args)} if args else {})}}
        problems = manifest.text_errors("action", event, manifest.load_vocabulary())
        if problems:
            raise RecordError("; ".join(problems))
        params: dict[str, Any] = {"action": action_id, "args": {k: v for k, v in args.items() if k != "target"},
                                  "focus": True, "origin": "script"}
        if "target" in args:
            topology = _result(self.rpc, "snapshot.get").get("topology") or {}
            refs = layout_refs(topology, shown_orders(self.rpc, topology))
            target = refs.get(args["target"])
            if target is None:
                raise RecordError(f"{action_id}: no object at {args['target']}")
            noun = {0: "workspace", 1: "pane", 2: "tab"}.get(args["target"].count("."))
            params["target"] = f"{noun}:{target}"
        reply = _result(self.rpc, "action.run", params)
        self.actions.append(event)
        return reply

    def run(self, sleep: Callable[[float], None] = time.sleep) -> dict[str, Any]:
        """Polls the journal and takes the story's checkpoints on schedule until the duration ends."""
        try:
            plan = checkpoint_plan(self.template, self.duration_ms)
            for index, (t_ms, name) in enumerate(plan):
                while self.elapsed_ms() < t_ms:
                    self.poll()
                    sleep(max(0.0, min(POLL_S, (t_ms - self.elapsed_ms()) / 1000)))  # recorder script: the next read
                self.checkpoint(name, final=index == len(plan) - 1)
        except BaseException:
            self.close()
            raise
        return self.finish()

    def finish(self) -> dict[str, Any]:
        """Takes the last checkpoint if `run` did not, stops the PTY taps and returns the validated manifest; the
        input and PTY tracks end at the duration."""
        try:
            if not self.ended:
                self.checkpoint(checkpoint_plan(self.template, self.duration_ms)[-1][1], final=True)
            self.journal.read()
        finally:
            self.close()  # every tap stops before any is read, so a refused track leaves none of the others running
        events = [event for event in self.journal.events(self.t0_ns, self.windows) + self.actions
                  if event["t_ms"] <= self.duration_ms]
        events.sort(key=lambda event: event["t_ms"])
        end_mono = self.start_mono + self.duration_ms * 1_000_000
        tracks = [{"surface": tap_files.ref, "source": self.cache.add(self.stop_tap(tap_files, end_mono)),
                   "speed": 1, "loop": False} for tap_files in self.taps]
        return self.manifest(events, tracks)

    def stop_tap(self, tap_files: Tap, end_mono: int) -> bytes:
        """The trimmed track of a tap `close` stopped, once the tap has drained its pty."""
        deadline = time.monotonic() + TAP_STOP_S
        while not tap_files.done.exists():
            if time.monotonic() > deadline:
                raise RecordError(f"the PTY tap of {tap_files.ref} did not stop")
            time.sleep(0.05)  # recorder script: the tap drains its pty
        data = trim_tap(tap_files.out.read_bytes(), self.start_mono, end_mono)
        problem = pty_privacy_problem(data, self.private)
        if problem:
            raise RecordError(f"{tap_files.ref}: {problem}")
        return data

    def manifest(self, events: list[dict[str, Any]], tracks: list[dict[str, Any]]) -> dict[str, Any]:
        manifest_module = corpus_manifest()
        manifest = copy.deepcopy(self.template)
        manifest["duration_ms"] = self.duration_ms
        manifest["layout"] = {"snapshot": self.layout_ref, "workspaces": self.workspaces}
        if len(events) > INLINE_EVENTS:
            ndjson = "".join(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n" for event in events)
            manifest["input"] = {"blob": self.cache.add(ndjson.encode())}
        else:
            manifest["input"] = {"events": events}
        recorded = {track["surface"]: track for track in tracks}
        # A track the story plans keeps its speed and loop; the recording gives it its source.
        manifest["pty"] = [{**track, "source": recorded.pop(track["surface"])["source"]} if track["surface"] in recorded
                           else track for track in manifest["pty"]] + list(recorded.values())
        manifest["checkpoints"] = self.checkpoints
        missing = [where for where, ref in manifest_module._sources(manifest) if ref is None]
        if manifest["web_archive"] is not None and manifest["web_archive"]["spki"] is None:
            missing.append("$.web_archive.spki")
        manifest.pop("planned", None)
        if missing:
            manifest["status"] = "planned"
            manifest["planned"] = f"Partly recorded by record.py (task 116); still null: {', '.join(missing)}."
        else:
            manifest["status"] = "recorded"
        errors = manifest_module.validation_errors(manifest)
        if not errors and "blob" in manifest["input"]:
            errors = manifest_module.blob_input_errors(manifest, self.cache, manifest_module.load_schema(),
                                                       manifest_module.load_vocabulary())
        if errors:
            raise RecordError("the recording is not a valid corpus manifest: " + "; ".join(errors[:6]))
        return manifest


def write_manifest(manifest: Mapping[str, Any], folder: Path) -> Path:
    path = Path(folder) / f"{manifest['id']}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------- CLI

def attach(socket_path: str) -> Callable[..., Any]:
    """The rpc of a running bench app, once it may be recorded (bundle, bundle id, process environment)."""
    rpc = session_io().load_stress().socket_rpc(socket_path)
    identity = _result(rpc, "system.identify")
    path = identity.get("app_bundle_path")
    if not path:
        raise RecordError(f"{socket_path}: the app does not say its bundle path")
    refusal = bundle_refusal(path, reported_id=identity.get("bundle_id")) or process_env_refusal(identity.get("pid"))
    if refusal:
        raise RecordError(refusal)
    return rpc


def record_command(args: argparse.Namespace) -> int:
    manifest_module = corpus_manifest()
    template = load_template(args.story, args.template)
    cache = manifest_module.BlobCache(args.cache or manifest_module.default_cache_dir(), manifest_module.http_fetcher())
    folder = Path(args.out).resolve()
    bench = builder = recording = None
    try:
        if args.app:
            refusal = bundle_refusal(args.app) or env_refusal(os.environ, "the recorder's environment")
            if refusal:
                raise RecordError(refusal)
            bench = bench_launch().BenchApp(args.app, out=str(folder), env={ENABLE_KEY: "1"})
            refusal = env_refusal(bench.environment())
            if refusal:
                raise RecordError(refusal)
            bench.launch()
            refusal = env_refusal(bench.launched_env or {CHARACTERS_KEY: "unknown"})
            identity = _result(bench.rpc, "system.identify")
            refusal = refusal or bundle_refusal(args.app, reported_id=identity.get("bundle_id"))
            if refusal:
                raise RecordError(refusal)
            rpc = bench.rpc
            if args.layout:
                io = session_io()
                builder, _ = io.roundtrip(rpc, io.read(args.layout))
        else:
            rpc = attach(args.socket)
        recording = Recording(rpc, template, cache=cache, folder=folder, duration_ms=args.duration_ms, builder=builder)
        recording.start(args.pty)
        manifest = recording.run()
        path = write_manifest(manifest, folder)
        print("CORPUS-RECORD " + json.dumps({"manifest": str(path), "status": manifest["status"],
                                             "events": len(manifest["input"].get("events") or []) or "blob",
                                             "pty": len(recording.taps), "checkpoints": len(manifest["checkpoints"]),
                                             "cache": str(cache.directory)}), flush=True)
        return 0
    finally:
        if recording is not None:
            recording.close()
        if builder is not None:
            builder.close()
        if bench is not None:
            bench.stop()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("record", help="record one corpus story from a bench app")
    target = record.add_mutually_exclusive_group(required=True)
    target.add_argument("--app", help="a tagged bench `cmux DEV <tag>.app` to launch with the journal on")
    target.add_argument("--socket", help="the control socket of a running tagged bench app")
    story = record.add_mutually_exclusive_group(required=True)
    story.add_argument("--story", help="a story of perf-corpus/ (its planned manifest is the template)")
    story.add_argument("--template", type=Path, help="a corpus manifest to start from")
    record.add_argument("--out", required=True, help="the folder for the manifest and the PTY tap files")
    record.add_argument("--duration-ms", type=int, default=None, help="default: the template's duration_ms")
    record.add_argument("--layout", help="with --app: a layout snapshot to import first (session_io.py)")
    record.add_argument("--pty", action="append", default=[], metavar="@wN.pM.tK=COMMAND",
                        help="run COMMAND under the PTY tap in that terminal tab and record its output")
    record.add_argument("--cache", type=Path, default=None, help="the corpus blob cache (default manifest.py's)")
    hook = commands.add_parser("pty-tap", help="the PTY hook a recorded terminal runs its command under")
    hook.add_argument("--out", required=True)
    hook.add_argument("--stop-file", required=True)
    hook.add_argument("cmd", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command == "pty-tap":
        command = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
        if not command:
            parser.error("pty-tap needs a command after --")
        return tap(command, args.out, args.stop_file)
    if args.layout and not args.app:
        parser.error("--layout imports into a fresh app: use it with --app")
    for number in (signal.SIGTERM, signal.SIGHUP):  # exit through the finally blocks, which stop the app
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        return record_command(args)
    except RecordError as error:
        print(f"record: refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
