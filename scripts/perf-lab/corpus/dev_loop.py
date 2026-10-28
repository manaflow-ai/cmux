#!/usr/bin/env python3
"""The dev-loop corpus story's scripted parts (p12-perf-process.md 3.8, task 118).

    python3 -I scripts/perf-lab/corpus/dev_loop.py --check   # the committed files are what this script makes
    python3 -I scripts/perf-lab/corpus/dev_loop.py --write   # makes them again

dev-loop is a scripted story, as Chromium's system_health stories are: code says what the session does
(tools/perf/page_sets/system_health/browsing_stories.py and its action_runner scrolls), and nothing comes from a
person's session. This script makes, deterministically (a seeded random.Random, read only through random()):

  perf-corpus/dev-loop/layout.json       the layout snapshot (session_io.py, task 111): 4 workspaces, w0 the
                                         editor (left) and build log (right), w1 the docs tab (a Chromium tab;
                                         the layout import gives it a long generated local page), w2 and w3 shells
  perf-corpus/dev-loop/build-log.ttyrec  the build log PTY track (pty_replay.py, task 112): synthetic cargo and
                                         swiftc output, bursts at BURST_RATE bytes/s (4000-byte writes every 2 ms)
                                         separated by progress lines, PASS_MS per pass, looped
  perf-corpus/dev-loop.json              layout, PTY tracks, input track and checkpoints. The input track runs
                                         ROUNDS rounds of: typing in the alt-screen editor, Cmd-Shift-P palette
                                         queries, scrolling the docs tab, Cmd-D split and closePane, Cmd-T and
                                         Cmd-W, Cmd-N (a new workspace, shown) and Cmd-Shift-W, then the editor

Keys go only where their text is harmless: the editor and build-log terminals run pty_replay.py, which drops its
input, the palette is closed with two Escapes (the first clears the query, the second closes it:
PaletteNavReducer.escape), and the split and new-workspace shells get no Return. Objects the story creates are
closed through focus or by a ref that does not depend on placement settings: Cmd-Shift-W closes the workspace
Cmd-N showed wherever `workspaces.newPlacement` put it, so every @wN ref names a layout workspace.
The docs tab has no Web Page Replay archive (web_archive is null): no player step can load an archived URL into a
layout tab yet, and the input vocabulary carries no URLs. The fields a lab host records (checkpoint digests,
status) are kept from the committed manifest.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_dev_loop.py
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import random
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
STORY = "dev-loop"
MANIFEST_PATH = f"perf-corpus/{STORY}.json"
LAYOUT_PATH = f"perf-corpus/{STORY}/layout.json"
BUILD_LOG_PATH = f"perf-corpus/{STORY}/build-log.ttyrec"
EDITOR_PATH = "schemas/terminal-corpus/alt-screen-editor.vt"
SEED = 118

DURATION_MS = 150_000
ROUNDS = 3
ROUND_MS = DURATION_MS // ROUNDS

# The build log: BURST_RATE bytes/s while a burst runs, as WRITE_BYTES every WRITE_MS (a pipe-sized write).
BURST_RATE = 2_000_000
WRITE_MS = 2
WRITE_BYTES = BURST_RATE * WRITE_MS // 1000
PASS_MS = 6000
BURSTS = ((0, 96_000), (2000, 64_000), (4000, 64_000))  # (start ms, bytes) per pass
PROGRESS_EVERY_MS = 250

WINDOW = (1440, 900)
DOCS_POINT = (860, 480)  # window points (top-left origin) inside w1's only pane
SCROLL_HZ = 60
SCROLL_DECAY = 0.9

# macOS virtual key codes (play.py KEY_NAMES): the keys that are not typed text.
KEY_T, KEY_N, KEY_W, KEY_P, KEY_D = 17, 45, 13, 35, 2
KEY_RETURN, KEY_ESCAPE, KEY_DELETE, KEY_DOWN = 36, 53, 51, 125
ARROWS = (123, 124, KEY_DOWN, 126)

EDITOR, BUILD_LOG, DOCS, SHELL_A, SHELL_B = "@w0.p0", "@w0.p1", "@w1.p0", "@w2.p0", "@w3.p0"
SPLIT_PANE = "@w0.p2"  # Cmd-D on the build log's pane puts the new pane right of it

METRICS = ("key_to_frame", "action_to_frame", "switch_to_frame", "palette_key_to_frame", "dropped_frames",
           "main_turn")
METRIC_UNITS = {"dropped_frames": "count"}

PLANNED = ("Scripted by scripts/perf-lab/corpus/dev_loop.py (task 118). A lab host adds the checkpoint digests of a "
           "recording replay (task 116).")
DESCRIPTION = ("An alt-screen editor next to 2 MB/s build-log bursts, a Chromium docs tab (a generated local page) "
               "scrolled with a trackpad, Cmd-D split and close, Cmd-T/W, Cmd-N and Cmd-Shift-W, and Cmd-Shift-P "
               "palette queries, in 3 rounds of 50 s.")


def _load(name: str, path: Path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def session_io():
    return _load("perf_lab_corpus_session_io", HERE / "session_io.py")


def pty_replay():
    return _load("perf_lab_corpus_pty_replay", HERE / "pty_replay.py")


def manifest_module():
    return _load("perf_lab_corpus_manifest", HERE / "manifest.py")


# ---------------------------------------------------------------- layout

def layout() -> dict[str, Any]:
    terminal = {"tabs": ["terminal"], "selected": 0}
    return {
        "schema": "cmux-layout-snapshot/v1",
        "window": list(WINDOW),
        "workspaces": [
            {"tree": {"split": "right", "children": [terminal, terminal]}, "even": True},
            {"tree": {"tabs": ["chromium"], "selected": 0}, "even": True},
            {"tree": terminal, "even": True},
            {"tree": terminal, "even": True},
        ],
        "shown": 0,
        "focused_pane": 0,
        "busy": [],
    }


# ---------------------------------------------------------------- build log

class _Words:
    """Synthetic crate, module and file names: syllables picked by the seeded generator."""

    SYLLABLES = ("ab", "cor", "da", "fen", "gil", "hu", "ka", "lor", "mi", "nos", "pa", "qui", "ro", "sel", "tu",
                 "vel", "wa", "xin", "yo", "zer")

    def __init__(self, rng: random.Random):
        self.rng = rng

    def int(self, low: int, high: int) -> int:
        return low + int(self.rng.random() * (high - low + 1))

    def name(self, parts: int = 2) -> str:
        return "".join(self.SYLLABLES[self.int(0, len(self.SYLLABLES) - 1)] for _ in range(parts))

    def module(self) -> str:
        return "Cmux" + self.name().capitalize() + self.name(1).capitalize()


def _build_line(words: _Words) -> str:
    roll = words.rng.random()
    if roll < 0.55:
        return (f"\x1b[1m\x1b[32m   Compiling\x1b[0m {words.name()}-{words.name(1)} "
                f"v{words.int(0, 3)}.{words.int(0, 40)}.{words.int(0, 20)}\r\n")
    if roll < 0.75:
        module = words.module()
        flags = " ".join(f"-I/src/.build/arm64/{words.module()}.build" for _ in range(words.int(4, 9)))
        return (f"CompileSwift normal arm64 /src/Packages/{module}/Sources/{module}/{words.name(3).capitalize()}"
                f".swift (in target '{module}' from project 'cmux')\r\n    cd /src\r\n    /usr/bin/swiftc "
                f"-module-name {module} -O -whole-module-optimization -enable-batch-mode {flags}\r\n")
    if roll < 0.9:
        return (f"\x1b[1m\x1b[33mwarning\x1b[0m\x1b[1m: unused variable `{words.name()}`\x1b[0m\r\n"
                f"  \x1b[1m\x1b[34m-->\x1b[0m src/{words.name()}.rs:{words.int(1, 900)}:{words.int(1, 80)}\r\n"
                f"   \x1b[1m\x1b[34m|\x1b[0m\r\n")
    return f"\x1b[2mnote: {words.name()} is up to date ({words.int(1, 999)} files)\x1b[0m\r\n"


def build_log() -> bytes:
    """One pass of the build log as ttyrec: each burst is whole lines, written WRITE_BYTES every WRITE_MS (the
    last write of a burst is shorter); between bursts a progress line every PROGRESS_EVERY_MS."""
    words = _Words(random.Random(SEED))
    frames: list[tuple[float, bytes]] = []
    ends = [start for start, _ in BURSTS[1:]] + [PASS_MS]
    built = 0
    for (start, size), end in zip(BURSTS, ends):
        text = bytearray(b"\r\x1b[K")  # clears the progress line
        while len(text) < size:
            text += _build_line(words).encode("ascii")
        for index, offset in enumerate(range(0, len(text), WRITE_BYTES)):
            frames.append((start + index * WRITE_MS, bytes(text[offset:offset + WRITE_BYTES])))
        built += words.int(20, 60)
        tick = (start + (len(text) + WRITE_BYTES - 1) // WRITE_BYTES * WRITE_MS) // PROGRESS_EVERY_MS + 1
        while tick * PROGRESS_EVERY_MS < end:
            done = built + tick
            bar = "=" * (done % 24) + ">" + " " * (23 - done % 24)
            frames.append((tick * PROGRESS_EVERY_MS, (f"\x1b[1m\x1b[36m    Building\x1b[0m [{bar}] {done}/1288: "
                                                      f"{words.name()}\x1b[K\r").encode("ascii")))
            tick += 1
    frames.append((PASS_MS, f"\x1b[K\x1b[1m\x1b[32m    Finished\x1b[0m `dev` profile in "
                            f"{PASS_MS / 1000:.2f}s\r\n".encode("ascii")))
    return pty_replay().encode_ttyrec(frames)


# ---------------------------------------------------------------- input track

class _Track:
    def __init__(self, rng: random.Random):
        self.rng, self.events, self.checkpoints = rng, [], []

    def between(self, low: float, high: float) -> int:
        return round(low + self.rng.random() * (high - low))

    def add(self, t_ms: float, kind: str, payload: dict[str, Any]) -> None:
        self.events.append({"t_ms": round(t_ms), "kind": kind, "payload": payload})

    def key(self, t_ms: float, key_class: str, *, key_code: int | None = None,
            modifiers: tuple[str, ...] = ()) -> None:
        """A key press. Only the down: debug.key sends the down and the up, and play.py skips recorded ups."""
        down = {"phase": "down", "class": key_class, "modifiers": list(modifiers)}
        if key_code is not None:
            down["key_code"] = key_code
        self.add(t_ms, "key", down)

    def chord(self, t_ms: float, key_code: int, *modifiers: str) -> None:
        self.key(t_ms, "letter", key_code=key_code, modifiers=("cmd", *modifiers))

    def action(self, t_ms: float, action: str, target: str) -> None:
        self.add(t_ms, "action", {"id": action, "args": {"target": target}})

    def type_words(self, t_ms: float, until_ms: float, *, editor: bool) -> None:
        """Typing at about 7 keys/s: words of 2 to 9 letters, a space or punctuation between them. In the
        editor a Return ends some lines, and every few seconds Escape and arrow keys move about."""
        t, word, next_motion = t_ms, self.between(2, 9), t_ms + self.between(2500, 4000)
        while True:
            if editor and t >= next_motion:
                presses = [(KEY_ESCAPE, "named")] + [(ARROWS[self.between(0, 3)], "named")
                                                     for _ in range(self.between(2, 5))]
                next_motion = t + self.between(2500, 4000)
            elif word:
                presses, word = [(None, "letter")], word - 1
            else:
                roll = self.rng.random()
                if editor and roll < 0.12:
                    presses = [(KEY_RETURN, "named")]
                elif roll < 0.25:
                    presses = [(None, "punctuation"), (None, "space")]
                elif roll < 0.3:
                    presses = [(KEY_DELETE, "named")]
                else:
                    presses = [(None, "space")]
                word = self.between(2, 9)
            for key_code, key_class in presses:
                if t > until_ms:
                    return
                self.key(t, key_class, key_code=key_code)
                t += self.between(95, 180)

    def scroll(self, t_ms: float, amplitude: float) -> int:
        """One trackpad flick on the docs tab: SCROLL_HZ events with momentum, until under half a point."""
        x, y = DOCS_POINT
        index, dy = 0, amplitude
        while abs(dy) >= 0.5:
            self.add(t_ms + index * 1000 / SCROLL_HZ, "mouse",
                     {"phase": "scroll", "button": 0, "x": x, "y": y, "dy": round(dy, 2)})
            index, dy = index + 1, dy * SCROLL_DECAY
        return round(t_ms + index * 1000 / SCROLL_HZ)

    def checkpoint(self, t_ms: float, name: str) -> None:
        self.checkpoints.append({"t_ms": round(t_ms), "name": name})

    def round(self, number: int) -> None:
        base = number * ROUND_MS

        def at(offset_ms: float) -> float:
            return base + offset_ms

        self.action(at(0), "pane.focus", EDITOR)
        self.type_words(at(300), at(12_500), editor=True)

        self.chord(at(13_000), KEY_P, "shift")  # the command palette
        self.type_words(at(13_400), at(14_600), editor=False)
        self.key(at(14_800), "named", key_code=KEY_DOWN)  # the next match
        self.key(at(15_400), "named", key_code=KEY_ESCAPE)  # clears the query
        self.key(at(15_600), "named", key_code=KEY_ESCAPE)  # closes the palette
        self.checkpoint(at(16_000), f"palette-closed-{number}")

        self.action(at(16_500), "pane.focus", DOCS)
        t = at(17_000)
        for flick in range(4):
            t = self.scroll(t, 48.0 if flick == 2 else -64.0) + self.between(300, 700)
        self.checkpoint(at(26_000), f"docs-scrolled-{number}")

        self.action(at(26_500), "pane.focus", BUILD_LOG)
        self.chord(at(27_000), KEY_D)  # split right
        self.type_words(at(27_800), at(30_000), editor=False)
        self.action(at(30_500), "closePane", SPLIT_PANE)
        self.checkpoint(at(31_500), f"split-closed-{number}")

        self.chord(at(32_000), KEY_T)  # the New Tab page in the build log's pane
        self.chord(at(34_000), KEY_W)
        self.checkpoint(at(35_000), f"tab-closed-{number}")

        self.action(at(35_500), "pane.focus", SHELL_B)
        self.chord(at(36_000), KEY_N)  # a new workspace, shown and focused
        self.type_words(at(37_000), at(39_000), editor=False)
        self.chord(at(39_500), KEY_W, "shift")  # closeWorkspace: the shown one, the workspace Cmd-N made
        self.checkpoint(at(40_500), f"workspace-closed-{number}")

        self.action(at(41_000), "pane.focus", EDITOR)
        self.type_words(at(41_300), at(ROUND_MS - 300), editor=True)


def input_track() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(events, checkpoints without digests), both in time order."""
    track = _Track(random.Random(SEED + 1))
    track.checkpoint(0, "layout-imported")
    for number in range(ROUNDS):
        track.round(number)
    track.checkpoint(DURATION_MS, "end")
    events = sorted(track.events, key=lambda event: event["t_ms"])  # stable: a key's up stays after its down
    return events, track.checkpoints


# ---------------------------------------------------------------- the manifest

def file_ref(path: str, data: bytes) -> dict[str, Any]:
    return {"path": path, **manifest_module().blob_ref(data)}


def outputs(root: Path = REPO_ROOT, current: dict[str, Any] | None = None) -> dict[str, bytes]:
    """{repository path: bytes} of every file this script makes. CURRENT (the committed manifest, if any) gives
    the recorded fields to keep: status and each checkpoint's digests by name."""
    layout_bytes = session_io().canonical_bytes(session_io().check(layout()))
    log_bytes = build_log()
    editor = (root / EDITOR_PATH).read_bytes()
    events, checkpoints = input_track()
    current = current or {}
    digests = {c["name"]: (c.get("focus"), c.get("surfaces")) for c in current.get("checkpoints", [])}
    manifest = {
        "schema": "cmux-perf-corpus-story/v1",
        "id": STORY,
        "tier": "T1",
        "status": current.get("status", "planned"),
        **({"planned": PLANNED} if current.get("status", "planned") == "planned" else {}),
        "description": DESCRIPTION,
        "owner": "PL-perf-lab",
        "duration_ms": DURATION_MS,
        "layout": {"snapshot": file_ref(LAYOUT_PATH, layout_bytes), "workspaces": len(layout()["workspaces"])},
        "input": {"events": "@events"},
        "pty": [
            {"surface": f"{EDITOR}.t0", "source": file_ref(EDITOR_PATH, editor), "speed": 1, "loop": True},
            {"surface": f"{BUILD_LOG}.t0", "source": file_ref(BUILD_LOG_PATH, log_bytes), "speed": 1, "loop": True},
        ],
        "web_archive": None,
        "agents": [],
        "checkpoints": [{**c, "focus": digests.get(c["name"], (None, None))[0],
                         "surfaces": digests.get(c["name"], (None, None))[1]} for c in checkpoints],
        "metrics": [{"name": rf"corpus\.dev_loop\.{name}", "unit": METRIC_UNITS.get(name, "ms"), "better": "lower"}
                    for name in METRICS],
    }
    text = json.dumps(manifest, indent=2)
    lines = ",\n".join("      " + json.dumps(event, separators=(",", ":")) for event in events)
    text = text.replace('"@events"', f"[\n{lines}\n    ]", 1)
    return {MANIFEST_PATH: (text + "\n").encode("utf-8"), LAYOUT_PATH: layout_bytes, BUILD_LOG_PATH: log_bytes}


def stale(root: Path = REPO_ROOT) -> list[str]:
    """The made files that are missing or differ from what this script makes now."""
    manifest = root / MANIFEST_PATH
    current = json.loads(manifest.read_text(encoding="utf-8")) if manifest.is_file() else None
    return [path for path, data in outputs(root, current).items()
            if not (root / path).is_file() or (root / path).read_bytes() != data]


def write(root: Path = REPO_ROOT) -> list[str]:
    manifest = root / MANIFEST_PATH
    current = json.loads(manifest.read_text(encoding="utf-8")) if manifest.is_file() else None
    written = []
    for path, data in outputs(root, current).items():
        target = root / path
        if target.is_file() and target.read_bytes() == data:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        written.append(path)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    args = parser.parse_args(argv)
    if args.write:
        print("\n".join(write(args.root)) or "up to date")
        return 0
    problems = stale(args.root)
    for path in problems:
        print(f"{path}: not what dev_loop.py makes; run python3 -I scripts/perf-lab/corpus/dev_loop.py --write",
              file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
