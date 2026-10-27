#!/usr/bin/env python3
"""The stress-recorded corpus story: STRESS under trace.py's stress-storm, generated (p12-perf-process.md 3.8,
task p12-perf-process-120).

    python3 -I scripts/perf-lab/corpus/stories/stress_recorded.py write    # perf-corpus/stress-recorded.json + blobs
    python3 -I scripts/perf-lab/corpus/stories/stress_recorded.py check    # the committed manifest is what this makes
    python3 -I scripts/perf-lab/corpus/stories/stress_recorded.py blobs    # only put the blobs into the corpus cache
    python3 -I scripts/perf-lab/corpus/stories/stress_recorded.py capture --app APP --out DIR   # checkpoint digests

The session is STRESS as perf-stress-session.py builds it (60 workspaces: the app's launch terminal, 10 with two
Chromium pages, 48 lone terminals, and last the measured workspace, shown, with 14 panes of 6 tabs and 10 busy
terminals). The input is the storm of `trace.py record --scenario stress-storm` at its defaults (`Storm`,
`Typist`, `CHORDS`), on a fixed schedule instead of a thread's pace:

  CLI     a call every 100 ms (--storm-hz 10) through the app's bundled CLI, cycling workspace move to the top,
          task status, and two status pills (`workspace @wN status set trace <call>`). The storm's third kind,
          a group add, needs a group: a layout snapshot holds none and only a name (text) creates one, so that
          slot plays a pill, as trace.py does when it has no groups. No key_to_frame-like series for the calls:
          play.py has no app signpost that names a CLI op (its `cli_to_frame` note), so the story declares none.
  keys    a letter every 120 ms (--key-interval 0.12) into the measured workspace's focused terminal; typing keys
          carry only their class (manifest.py's rule), the player types its fixed synthetic text. The focused pane
          is the one trace.py's focus_quiet_terminal moves typing to: the last measured pane whose selected tab is
          a terminal that is not busy, so a key's first output is its echo and not the busy loop's line.
  chords  every 10 letters (--chord-every 10) an action pair, its keys 350 ms apart, cycling Cmd-T/Cmd-W,
          Cmd-D/Cmd-W and Ctrl-Cmd-[/Ctrl-Cmd-]. The step pair goes back then forward, the reverse of trace.py's:
          the measured workspace is the last row, and a step forward from it leaves the rows (to Home under the
          default sidebar.stepping and sidebar.steppingWraps), which is app state the story does not fix.

Deterministic replay: a storm call names a workspace by its sidebar position at the time it is sent (play.py's
`Refs`), and its targets are positions 0-57 only, never the measured workspace (59) or the one Ctrl-Cmd-[ shows (58).
A move to the top permutes only the rows above the one it moves, so rows 58 and 59 hold the same workspaces for the
whole story, and the step pair shows the same workspace in every replay however late a CLI call lands. A chord
never runs within CHORD_QUIET_MS before a checkpoint, so each checkpoint reads the measured workspace at rest.
A key that falls on a storm call's time goes first: the player spawns a CLI process synchronously, and a key after
it would be late by the spawn time (play.py's lateness bound is on the sends' p95).

Every source is made here from fixed seeds (story_kit.Rng), so the bytes and their sha256 are the same on every host:
the layout snapshot (session_io.py format) and the input track (NDJSON). `capture` reads the checkpoint digests on a
lab host (story_kit). Once two hosts replay it with a run-to-run CV of key->frame p50 <= 5 %, this story's
key_to_frame replaces the synthetic STRESS key->frame series in T0.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_story_stress_recorded.py
"""
from __future__ import annotations

import importlib.util
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent


def _kit():
    name = "perf_lab_corpus_story_kit"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, HERE / "story_kit.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


kit = _kit()
stress = kit.session_io().load_stress()

STORY_ID = "stress-recorded"
DURATION_MS = 60_000
CHECKPOINTS = (("layout-imported", 0), ("midpoint", 30_000), ("end", DURATION_MS))
WORKSPACES = stress.WORKSPACES
MEASURED = WORKSPACES - 1            # STRESS builds the measured workspace last and shows it
STEP_TARGET = MEASURED - 1           # the row Ctrl-Cmd-[ shows from the measured workspace
STORM_ROWS = STEP_TARGET             # the storm's targets: positions 0 .. STORM_ROWS - 1

STORM_PERIOD_MS = 100                # trace.py --storm-hz 10
STORM_KINDS = ("move", "task", "group", "pill")   # trace.py Storm.run, in its order
STATUSES = ("todo", "working", "needs-attention", "review", "done")  # trace.py Storm.STATUSES
KEY_INTERVAL_MS = 120                # trace.py --key-interval 0.12
CHORD_EVERY = 10                     # trace.py --chord-every 10
CHORD_GAP_MS = 350                   # Typist: the chord's frames land before its partner
TYPIST_START_MS = 120
CHORD_QUIET_MS = 1_200               # no chord starts this close before a checkpoint
END_QUIET_MS = 1_000                 # no key in the last second: the end checkpoint reads the session at rest
STORM_SEED = 0x120_0007              # trace.py seeds its storm with 7

# macOS ANSI key codes (play.py KEY_NAMES) and the journal's key classes of the chord keys.
KEY_T, KEY_W, KEY_D, KEY_LEFT_BRACKET, KEY_RIGHT_BRACKET = 17, 13, 2, 33, 30
CMD, CTRL_CMD = ("cmd",), ("ctrl", "cmd")
# (key code, class, modifiers, action) per chord key: trace.py CHORDS, the step pair back then forward.
CHORDS = (
    ((KEY_T, "letter", CMD, "newTab.default"), (KEY_W, "letter", CMD, "closeTab")),
    ((KEY_D, "letter", CMD, "splitRight"), (KEY_W, "letter", CMD, "closeTab")),
    ((KEY_LEFT_BRACKET, "punctuation", CTRL_CMD, "prevSidebarTab"),
     (KEY_RIGHT_BRACKET, "punctuation", CTRL_CMD, "nextSidebarTab")),
)
METRICS = (("key_to_frame", "ms"), ("action_to_frame", "ms"), ("switch_to_frame", "ms"),
           ("dropped_frames", "count"), ("main_turn", "ms"), ("hangs", "count"))


# ---------------------------------------------------------------- layout

def quiet_pane(snapshot: dict[str, Any]) -> int:
    """trace.py focus_quiet_terminal's pick: the last pane of the shown workspace whose selected tab is a terminal
    that is not busy."""
    shown = snapshot["shown"]
    busy = {(pane, tab) for workspace, pane, tab in snapshot["busy"] if workspace == shown}
    leaves = kit.session_io().leaves(snapshot["workspaces"][shown]["tree"])
    return next(index for index in reversed(range(len(leaves)))
                if leaves[index]["tabs"][leaves[index]["selected"]] == "terminal"
                and (index, leaves[index]["selected"]) not in busy)


def layout() -> dict[str, Any]:
    """STRESS as perf-stress-session.py builds it and session_io.py exports it: the launch workspace's terminal,
    the background (Chromium workspaces first), then the measured grid of columns of rows, its quiet pane focused
    (trace.py's build_stress runs focus_quiet_terminal after the builder focuses the first, busy pane)."""
    terminal = {"tabs": ["terminal"], "selected": 0}
    chromium = {"tabs": ["terminal"] + ["chromium"] * stress.CHROMIUM_PER_WORKSPACE,
                "selected": stress.CHROMIUM_PER_WORKSPACE}
    # Each measured pane: its first terminal, then the builder's fill order; the last one made is selected.
    measured_tabs = ["terminal", "chromium", "chromium", "webkit", "chat", "terminal"]
    pane = {"tabs": measured_tabs, "selected": len(measured_tabs) - 1}
    columns = [{"split": "down", "children": [pane] * (stress.ROWS + (column in stress.NESTED_COLUMNS))}
               for column in range(stress.COLUMNS)]
    background = WORKSPACES - 2
    workspaces = ([{"even": True, "tree": terminal}]
                  + [{"even": True, "tree": chromium}] * stress.CHROMIUM_WORKSPACES
                  + [{"even": True, "tree": terminal}] * (background - stress.CHROMIUM_WORKSPACES)
                  + [{"even": True, "tree": {"split": "right", "children": columns}}])
    snapshot = {"schema": "cmux-layout-snapshot/v1", "window": list(stress.WINDOW_SIZE), "workspaces": workspaces,
                "shown": MEASURED, "focused_pane": 0,
                "busy": [[MEASURED, index, len(measured_tabs) - 1] for index in range(stress.BUSY_TERMINALS)]}
    return {**snapshot, "focused_pane": quiet_pane(snapshot)}


# ---------------------------------------------------------------- input track

def storm(track: Any, rng: Any) -> None:
    """A CLI call every STORM_PERIOD_MS through the window, the kinds in trace.py's cycle; a group slot is a pill."""
    for call in range(1, DURATION_MS // STORM_PERIOD_MS):
        kind = STORM_KINDS[(call - 1) % len(STORM_KINDS)]
        target = f"@w{rng.between(0, STORM_ROWS - 1)}"
        if kind == "move":
            argv = ["workspace", target, "move", "--index", "0"]
        elif kind == "task":
            argv = ["workspace", target, "update", "--task-status", rng.choice(STATUSES)]
        else:
            argv = ["workspace", target, "status", "set", "trace", str(call)]
        track.add(call * STORM_PERIOD_MS, "cli", {"argv": argv})


def _key(track: Any, t_ms: int, payload: dict[str, Any]) -> None:
    """debug.key posts the down and the up together: the journal records both at the send time."""
    track.add(t_ms, "key", {"phase": "down", **payload})
    track.add(t_ms, "key", {"phase": "up", **payload})


def chord_start(t_ms: int) -> int:
    """When a chord due at t_ms starts: at t_ms, or at the checkpoint it would run into (after its read)."""
    for _, checkpoint in CHECKPOINTS:
        if t_ms < checkpoint <= t_ms + CHORD_QUIET_MS:
            return checkpoint
    return t_ms


def typist(track: Any) -> None:
    """trace.py's Typist on a schedule: a letter every KEY_INTERVAL_MS; before every CHORD_EVERY-th one a chord pair,
    its keys CHORD_GAP_MS apart, then the letter after another CHORD_GAP_MS."""
    t, keys, pair, end = TYPIST_START_MS, 0, 0, DURATION_MS - END_QUIET_MS
    while t < end:
        if keys and keys % CHORD_EVERY == 0:
            t = chord_start(t)
            if t + 2 * CHORD_GAP_MS >= end:
                break
            for step, (code, key_class, modifiers, _) in enumerate(CHORDS[pair % len(CHORDS)]):
                _key(track, t + step * CHORD_GAP_MS, {"class": key_class, "key_code": code, "modifiers": list(modifiers)})
            pair += 1
            t += 2 * CHORD_GAP_MS
        _key(track, t, {"class": "letter", "modifiers": []})
        keys += 1
        t += KEY_INTERVAL_MS


def input_events() -> list[dict[str, Any]]:
    """The typist's keys are added before the storm's calls, so at an equal time a key is sent first."""
    track = kit.Track()
    typist(track)
    storm(track, kit.Rng(STORM_SEED))
    return track.events()


# ---------------------------------------------------------------- the manifest

def sources() -> dict[str, bytes]:
    """{name: bytes} of every blob: `layout` and `input`."""
    return {"layout": kit.layout_bytes(layout()), "input": kit.ndjson(input_events())}


def manifest(blobs: dict[str, bytes], previous: dict[str, Any] | None = None) -> dict[str, Any]:
    ref = kit.corpus_manifest().blob_ref
    return kit.story_manifest(
        STORY,
        tier="T1",
        planned="Sources are generated by scripts/perf-lab/corpus/stories/stress_recorded.py (task 120); "
                "`stress_recorded.py capture --app APP --out DIR` on a lab host reads the checkpoint digests "
                "(it needs play.py, task 115).",
        description="STRESS (60 workspaces) under trace.py's stress-storm: a CLI call every 100 ms (workspace move, "
                    "task status, status pill), a letter every 120 ms and an action chord pair every 10 letters "
                    "(Cmd-T/Cmd-W, Cmd-D/Cmd-W, Ctrl-Cmd-[/]), deterministic with checkpoints.",
        owner="PL-perf-lab",
        sources={"duration_ms": DURATION_MS, "layout": {"snapshot": ref(blobs["layout"]), "workspaces": WORKSPACES},
                 "input": {"blob": ref(blobs["input"])}, "pty": [], "web_archive": None, "agents": []},
        metrics=METRICS,
        previous=previous,
    )


STORY = kit.Story(id=STORY_ID, script="stress_recorded.py", checkpoints=CHECKPOINTS, sources=sources,
                  manifest=manifest)


def main(argv: list[str] | None = None, out: Callable[[str], None] = print, player: Any | None = None) -> int:
    return kit.main(STORY, argv, out=out, player=player, doc=__doc__)


if __name__ == "__main__":
    sys.exit(main())
