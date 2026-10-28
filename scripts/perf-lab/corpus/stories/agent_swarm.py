#!/usr/bin/env python3
"""The agent-swarm corpus story, generated (p12-perf-process.md 3.8, task p12-perf-process-117).

    python3 -I scripts/perf-lab/corpus/stories/agent_swarm.py write    # perf-corpus/agent-swarm.json + cached blobs
    python3 -I scripts/perf-lab/corpus/stories/agent_swarm.py check    # the committed manifest is what this makes
    python3 -I scripts/perf-lab/corpus/stories/agent_swarm.py blobs    # only put the blobs into the corpus cache
    python3 -I scripts/perf-lab/corpus/stories/agent_swarm.py capture --app APP --out DIR   # the checkpoint digests

The story: 40 workspaces, the first 12 with a terminal beside an agent chat whose acpmux fake agent (task 114) streams
a 180 s transcript; the sidebar ticks (a `workspace @wN status set trace N` CLI call every 500 ms, round the 40 rows);
the person types at 8 keys/s into the shown workspace's terminal, switches workspace every 3 s (next or previous,
then focuses its terminal pane, or a jump straight to another workspace's terminal pane) and opens and closes a tab
with Cmd-T / Cmd-W every 15 s.

Every source is synthetic and made here from fixed seeds, so the bytes and their sha256 are the same on every host
and Python version (splitmix64, not `random`): the layout snapshot (session_io.py format, task 111), the input track
(NDJSON, manifest.py's event rules: typing keys carry only their class) and the 12 ACP transcripts
(cmux-perf-acp-transcript/v1 of agent_replay.py, task 114: sizes and shapes, no text). Chromium's synthetic stories
are made by code in the same way (tools/perf/page_sets/system_health/, the page set is the source of truth and
the recording follows it). `blobs` puts them into the corpus cache ($CMUX_PERF_CORPUS_CACHE, manifest.py), so a
lab host can replay the story without R2; `manifest.py --upload perf-corpus/agent-swarm.json` publishes them.

The checkpoint digests (debug.focus and debug.surfaces) are app state, so only a replay can read them: `capture` plays
the story twice in fresh launches of a bench app (play.py's Player, task 115) with each checkpoint reading the state
the app settles on instead of comparing it, and writes the manifest as `recorded` only when both runs read the same
digests. `write` keeps the digests of the committed manifest while the sources stay the same; a change of any source
drops them, and the story is `planned` again until the next capture.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_story_agent_swarm.py
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent
REPO_ROOT = CORPUS.parents[2]
STORY_ID = "agent-swarm"
MANIFEST_PATH = f"perf-corpus/{STORY_ID}.json"

DURATION_MS = 180_000
WORKSPACES = 40
AGENTS = 12
WINDOW = [1600, 1000]           # perf-stress-session.py WINDOW_SIZE: the bench window the layout import sizes
SLOT_MS = 3_000                 # a workspace switch every 3 s
PAIR_EVERY = 5                  # a Cmd-T / Cmd-W pair in every 5th slot: every 15 s
KEY_INTERVAL_MS = 125           # 8 keys/s
KEY_JITTER_MS = 35
TICK_MS = 500                   # a sidebar status tick every 500 ms
CHECKPOINTS = (("layout-imported", 0), ("midpoint", 90_000), ("end", DURATION_MS))
INPUT_SEED = 0x117_0001
AGENT_SEED = 0x117_1000

# macOS ANSI key codes (play.py KEY_NAMES): only shortcut and named keys carry one in the corpus.
KEY_T, KEY_W, KEY_DELETE, KEY_CMD, KEY_SHIFT = 17, 13, 51, 55, 56
TRANSCRIPT_SCHEMA = "cmux-perf-acp-transcript/v1"
METRICS = (("key_to_frame", "ms"), ("switch_to_frame", "ms"), ("dropped_frames", "count"), ("main_turn", "ms"),
           ("hangs", "count"))


def _load(name: str, path: Path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
        spec.loader.exec_module(module)
    return sys.modules[name]


def corpus_manifest():
    return _load("perf_lab_corpus_manifest", CORPUS / "manifest.py")


def session_io():
    return _load("perf_lab_corpus_session_io", CORPUS / "session_io.py")


class Rng:
    """splitmix64: the same numbers on every Python, so the blobs and their digests never move."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int):
        self.state = seed & self.MASK

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def between(self, low: int, high: int) -> int:
        """An integer in [low, high]."""
        return low + self.next() % (high - low + 1)

    def percent(self) -> int:
        return self.next() % 100


# ---------------------------------------------------------------- layout

def layout() -> dict[str, Any]:
    """12 agent workspaces (terminal | chat, side by side) and 28 lone terminals; workspace 0 shown, its terminal
    pane focused. The agent tracks play in @wN.p1.t0."""
    agent = {"even": True, "tree": {"split": "right", "children": [{"tabs": ["terminal"], "selected": 0},
                                                                   {"tabs": ["chat"], "selected": 0}]}}
    lone = {"even": True, "tree": {"tabs": ["terminal"], "selected": 0}}
    return {"schema": "cmux-layout-snapshot/v1", "window": list(WINDOW),
            "workspaces": [agent] * AGENTS + [lone] * (WORKSPACES - AGENTS), "shown": 0, "focused_pane": 0, "busy": []}


def agent_surface(index: int) -> str:
    return f"@w{index}.p1.t0"


# ---------------------------------------------------------------- input track

class Track:
    """Events in time order; events at the same time keep the order they were added in."""

    def __init__(self):
        self._events: list[tuple[int, int, dict[str, Any]]] = []

    def add(self, t_ms: int, kind: str, payload: dict[str, Any]) -> None:
        self._events.append((t_ms, len(self._events), {"t_ms": t_ms, "kind": kind, "payload": payload}))

    def events(self) -> list[dict[str, Any]]:
        return [event for _, _, event in sorted(self._events, key=lambda item: item[:2])]


def _key(track: Track, t_ms: int, key_class: str, modifiers: list[str], dwell_ms: int, key_code: int | None = None):
    down = {"phase": "down", "class": key_class, "modifiers": modifiers}
    if key_code is not None:
        down["key_code"] = key_code
    track.add(t_ms, "key", down)
    track.add(t_ms + dwell_ms, "key", {**down, "phase": "up"})


def _flags(track: Track, t_ms: int, key_code: int, modifiers: list[str]) -> None:
    track.add(t_ms, "key", {"phase": "flags", "class": "modifier", "key_code": key_code, "modifiers": modifiers})


def shortcut(track: Track, t_ms: int, key_code: int) -> None:
    """Cmd-<key> as the input journal records it: Cmd down, the key down and up, Cmd up."""
    _flags(track, t_ms - 40, KEY_CMD, ["cmd"])
    _key(track, t_ms, "letter", ["cmd"], 70, key_code)
    _flags(track, t_ms + 110, KEY_CMD, [])


def typing(track: Track, rng: Rng, start_ms: int, end_ms: int) -> int:
    """Keys from start_ms to before end_ms at 8 keys/s: words of 2-8 letters with a space after each, now and then a
    digit or punctuation, a capital with its Shift, and after 30 % of the words 1-5 deletes (never more than
    this stretch typed). Typing keys carry no key code: the player types its fixed synthetic text. Returns the key downs."""
    t, downs, typed, words, deleting, capital = start_ms, 0, 0, 0, 0, False
    word_left = rng.between(2, 8)
    while t < end_ms:
        dwell = rng.between(50, 95)
        if deleting:
            _key(track, t, "named", [], dwell, KEY_DELETE)
            typed, deleting = typed - 1, deleting - 1
        elif word_left == 0:
            _key(track, t, "space", [], dwell)
            typed, words, word_left, capital = typed + 1, words + 1, rng.between(2, 8), rng.percent() < 8
            if rng.percent() < 30:
                deleting = min(rng.between(1, 5), typed)
        else:
            roll = rng.percent()
            key_class = "digit" if roll < 6 else "punctuation" if roll < 10 else "letter"
            if capital and key_class == "letter":
                _flags(track, t - 25, KEY_SHIFT, ["shift"])
                _key(track, t, "letter", ["shift"], dwell)
                _flags(track, t + dwell + 10, KEY_SHIFT, [])
                capital = False
            else:
                _key(track, t, key_class, [], dwell)
            typed, word_left = typed + 1, word_left - 1
        downs += 1
        t += KEY_INTERVAL_MS + rng.between(-KEY_JITTER_MS, KEY_JITTER_MS)
    return downs


def switch(track: Track, rng: Rng, t_ms: int, shown: int) -> int:
    """One workspace switch at t_ms: the next workspace (45 %), the previous one (25 %), or a jump to any other
    workspace by reference (the rest: pane.focus on its terminal pane, the path of `cmux pane <ref> focus`). A step
    is followed 40 ms later by focusing the shown workspace's terminal pane (no second switch), so typing and
    Cmd-T / Cmd-W land in a terminal pane. Steps never leave the workspaces, and there is no Cmd-1...9: both walk
    the top items too by default (sidebar.numbering and sidebar.stepping `allItems`: Home = 1, App Store = 2,
    SidebarItemOrder.pick), and the top items are app state the story does not fix. Returns the shown workspace."""
    roll = rng.percent()
    if roll < 45 and shown < WORKSPACES - 1:
        track.add(t_ms, "action", {"id": "nextSidebarTab"})
        shown += 1
    elif roll < 70 and shown > 0:
        track.add(t_ms, "action", {"id": "prevSidebarTab"})
        shown -= 1
    else:
        target = rng.between(0, WORKSPACES - 2)
        shown = target + 1 if target >= shown else target
        track.add(t_ms, "action", {"id": "pane.focus", "args": {"target": f"@w{shown}.p0"}})
        return shown
    track.add(t_ms + 40, "action", {"id": "pane.focus", "args": {"target": f"@w{shown}.p0"}})
    return shown


def input_events() -> list[dict[str, Any]]:
    track, rng, shown = Track(), Rng(INPUT_SEED), 0
    for slot in range(DURATION_MS // SLOT_MS):
        t0 = slot * SLOT_MS
        if slot:
            shown = switch(track, rng, t0, shown)
        if slot % PAIR_EVERY == PAIR_EVERY // 2:
            typing(track, rng, t0 + 200, t0 + 900)
            shortcut(track, t0 + 1_000, KEY_T)   # the New Tab page opens in the terminal's pane
            shortcut(track, t0 + 1_800, KEY_W)   # and closes again
            typing(track, rng, t0 + 2_000, t0 + 2_900)
        else:
            typing(track, rng, t0 + 200, t0 + 2_900)
    for tick, t_ms in enumerate(range(TICK_MS // 2, DURATION_MS, TICK_MS)):
        track.add(t_ms, "cli", {"argv": ["workspace", f"@w{tick % WORKSPACES}", "status", "set", "trace",
                                         str(tick + 1)]})
    return track.events()


def ndjson(rows: list[dict[str, Any]]) -> bytes:
    return "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows).encode()


# ---------------------------------------------------------------- agent transcripts

def transcript(index: int) -> list[dict[str, Any]]:
    """Agent `index`'s turn: 180 s of thinking, streamed messages, tool calls with their output and plan updates, at a
    streaming pace (a chunk every 30-90 ms, 12-64 bytes of message), starting index * 150 ms in so the 12 agents do
    not stream in step. Sizes and shapes only: agent_replay.py writes fixed synthetic text of each size."""
    rng, rows = Rng(AGENT_SEED + index), [{"schema": TRANSCRIPT_SCHEMA}]
    t, tools, done, entries = index * 150, 0, 0, rng.between(4, 8)
    end = DURATION_MS - 500
    rows.append({"t_ms": t, "kind": "plan", "entries": entries, "done": 0})
    while True:
        roll = rng.percent()
        if roll < 20:
            phase = [("thought", rng.between(40, 160), rng.between(40, 90)) for _ in range(rng.between(5, 20))]
        elif roll < 70:
            shape = ("prose", "prose", "prose", "code", "list", "table")[rng.between(0, 5)]
            phase = [("message", rng.between(12, 64), rng.between(30, 90), shape) for _ in range(rng.between(20, 120))]
        elif roll < 90:
            tools += 1
            phase = [("tool", f"tool-{tools}")]
        elif done < entries:
            done += 1
            phase = [("plan",)]
        else:
            phase = [("idle",)]
        for step in phase:
            if step[0] == "thought":
                t += step[2]
                if t >= end:
                    break
                rows.append({"t_ms": t, "kind": "thought", "bytes": step[1]})
            elif step[0] == "message":
                t += step[2]
                if t >= end:
                    break
                rows.append({"t_ms": t, "kind": "message", "bytes": step[1], "shape": step[3]})
            elif step[0] == "tool":
                kind = ("read", "edit", "search", "execute", "execute", "read")[rng.between(0, 5)]
                start, running, finish = t + 50, t + rng.between(100, 400), t + rng.between(500, 6_000)
                if finish >= end:
                    t = end
                    break
                rows.append({"t_ms": start, "kind": "tool_call", "tool": step[1], "tool_kind": kind, "status": "pending"})
                rows.append({"t_ms": running, "kind": "tool_update", "tool": step[1], "status": "in_progress", "bytes": 0})
                status = "failed" if rng.percent() < 5 else "completed"
                rows.append({"t_ms": finish, "kind": "tool_update", "tool": step[1], "status": status,
                             "bytes": rng.between(200, 6_000)})
                t = finish
            elif step[0] == "plan":
                t += rng.between(100, 300)
                if t >= end:
                    break
                rows.append({"t_ms": t, "kind": "plan", "entries": entries, "done": done})
            else:
                t += rng.between(500, 3_000)
        if t >= end:
            break
    rows.append({"t_ms": end, "kind": "end", "stop": "end_turn"})
    return rows


# ---------------------------------------------------------------- the manifest

def sources() -> dict[str, bytes]:
    """{name: bytes} of every blob: `layout`, `input` and `agent-<n>`."""
    made = {"layout": session_io().canonical_bytes(session_io().check(layout())), "input": ndjson(input_events())}
    made.update({f"agent-{index}": ndjson(transcript(index)) for index in range(AGENTS)})
    return made


def manifest(blobs: dict[str, bytes], previous: dict[str, Any] | None = None) -> dict[str, Any]:
    """The story's manifest for `blobs`. The digests of `previous` (the committed manifest) stay while it names the
    same sources; the story is recorded once every checkpoint has both digests."""
    ref = corpus_manifest().blob_ref
    agents = [{"surface": agent_surface(index), "agent": "acp-replay", "transcript": ref(blobs[f"agent-{index}"])}
              for index in range(AGENTS)]
    layout_ref, input_ref = ref(blobs["layout"]), ref(blobs["input"])
    same = previous is not None and previous.get("layout", {}).get("snapshot") == layout_ref \
        and previous.get("input") == {"blob": input_ref} and previous.get("agents") == agents
    kept = {c["name"]: c for c in previous["checkpoints"]} if same else {}
    checkpoints = []
    for name, t_ms in CHECKPOINTS:
        old = kept.get(name) if kept.get(name, {}).get("t_ms") == t_ms else None
        checkpoints.append({"t_ms": t_ms, "name": name, "focus": old and old.get("focus"),
                            "surfaces": old and old.get("surfaces")})
    recorded = all(c["focus"] and c["surfaces"] for c in checkpoints)
    doc: dict[str, Any] = {"schema": "cmux-perf-corpus-story/v1", "id": STORY_ID, "tier": "T1",
                           "status": "recorded" if recorded else "planned"}
    if not recorded:
        doc["planned"] = ("Sources are generated by scripts/perf-lab/corpus/stories/agent_swarm.py (task 117); "
                          "`agent_swarm.py capture --app APP --out DIR` on a lab host reads the checkpoint digests "
                          "(it needs play.py, task 115, and agent_replay.py, task 114).")
    doc.update({
        "description": "40 workspaces with 12 streaming agents and the sidebar ticking; typing at 8 keys/s, a "
                       "workspace switch every 3 s and Cmd-T/Cmd-W pairs.",
        "owner": "PL-perf-lab",
        "duration_ms": DURATION_MS,
        "layout": {"snapshot": layout_ref, "workspaces": WORKSPACES},
        "input": {"blob": input_ref},
        "pty": [],
        "web_archive": None,
        "agents": agents,
        "checkpoints": checkpoints,
        "metrics": [{"name": rf"corpus\.agent_swarm\.{name}", "unit": unit, "better": "lower"} for name, unit in METRICS],
    })
    return doc


# ---------------------------------------------------------------- capture

CAPTURE_RUNS = 2
UNREAD = "0" * 64  # a capture's checkpoints read the state and never compare it: the digests it plays with are unused


class CaptureError(RuntimeError):
    pass


def play_module():
    path = CORPUS / "play.py"
    if not path.is_file():
        raise CaptureError("capture replays through scripts/perf-lab/corpus/play.py (p12-perf-process-115), "
                           "which this checkout does not have")
    return _load("perf_lab_corpus_play", path)


def settle(read: Callable[[], dict[str, str]], clock: Any, settle_s: float, poll_s: float) -> dict[str, str]:
    """The digests `read` gives twice in a row, poll_s apart: the state a replay's checkpoint finds once it settles.
    CaptureError when it is still changing after settle_s (the replay's own bound on a checkpoint)."""
    deadline = clock.now_ns() + round(settle_s * 1e9)
    last = None
    while True:
        got = read()
        if got == last:
            return got
        if clock.now_ns() >= deadline:
            raise CaptureError(f"the app state did not settle in {settle_s:g} s")
        last = got
        clock.sleep_until(clock.now_ns() + round(poll_s * 1e9))


def capture_player(play: Any, **seams: Any) -> Any:
    """A play.Player whose checkpoints report the settled state instead of comparing it with the manifest's."""

    class CapturePlayer(play.Player):
        def checkpoint(self, rpc, item, out):
            reports: dict[str, Any] = {}

            def read() -> dict[str, str]:
                reports["focus"], reports["surfaces"] = play.read_checkpoint(rpc)
                return {"focus": play.focus_digest(reports["focus"]),
                        "surfaces": play.surfaces_digest(reports["surfaces"])}

            try:
                got = settle(read, self.clock, self.settle_s, play.CHECKPOINT_POLL_S)
            except CaptureError as error:
                raise CaptureError(f"checkpoint {item.name} (t={item.t_ms:g} ms): {error}") from error
            (out / f"checkpoint-{item.name}.json").write_text(json.dumps(
                {"focus": play.focus_view(reports["focus"]), "surfaces": play.surfaces_view(reports["surfaces"])},
                indent=1), encoding="utf-8")
            return {"name": item.name, **got}

    return CapturePlayer(**seams)


def capture(blobs: dict[str, bytes], *, app: str, out: Path, player: Any, runs: int = CAPTURE_RUNS) -> dict[str, Any]:
    """The story's manifest with the checkpoint digests that `runs` replays into fresh launches of `app` read.
    CaptureError when the runs read different digests: the story does not replay to one state and is not recorded."""
    doc = manifest(blobs)
    names = [checkpoint["name"] for checkpoint in doc["checkpoints"]]
    playable = {**{key: value for key, value in doc.items() if key != "planned"}, "status": "recorded",
                "checkpoints": [dict(c, focus=UNREAD, surfaces=UNREAD) for c in doc["checkpoints"]]}
    reads = [player.replay(playable, app=app, out=Path(out) / f"run-{n}").checkpoints for n in range(1, runs + 1)]
    for n, read in enumerate(reads, 1):
        if [checkpoint["name"] for checkpoint in read] != names:
            raise CaptureError(f"run {n} read checkpoints {[c['name'] for c in read]}, the story has {names}")
    for n, read in enumerate(reads[1:], 2):
        for first, other in zip(reads[0], read):
            if first != other:
                raise CaptureError(f"checkpoint {first['name']}: run 1 read {first['focus'][:12]}/"
                                   f"{first['surfaces'][:12]}, run {n} {other['focus'][:12]}/{other['surfaces'][:12]}")
    read = {checkpoint["name"]: checkpoint for checkpoint in reads[0]}
    captured = dict(doc, checkpoints=[dict(c, focus=read[c["name"]]["focus"], surfaces=read[c["name"]]["surfaces"])
                                      for c in doc["checkpoints"]])
    return manifest(blobs, captured)


def run_capture(args: argparse.Namespace, blobs: dict[str, bytes], player: Any | None,
                out: Callable[[str], None]) -> dict[str, Any] | None:
    """`capture`: the recorded manifest, or None after printing why there is none."""
    corpus = corpus_manifest()
    directory = cache_blobs(blobs, args.cache)
    store = corpus.BlobCache(directory, corpus.http_fetcher())

    def fetch(ref: dict[str, Any]) -> Path:
        store.get(ref)
        return store.path(ref)

    failures: tuple[type[BaseException], ...] = (CaptureError,)
    try:
        if player is None:
            play = play_module()
            failures += (play.PlayError,)
            failures += (play.bench_launch().LaunchError,)
            player = capture_player(play, root=args.root, fetch=fetch, cache_dir=directory)
        doc = capture(blobs, app=args.app, out=args.out, player=player)
    except failures as error:
        print(f"capture: {error}", file=sys.stderr)
        return None
    out(f"captured {len(doc['checkpoints'])} checkpoints, the same in {CAPTURE_RUNS} runs")
    return doc


def render(doc: dict[str, Any]) -> str:
    return json.dumps(doc, indent=2) + "\n"


def cache_blobs(blobs: dict[str, bytes], cache_dir: Path | None) -> Path:
    corpus = corpus_manifest()
    cache = corpus.BlobCache(cache_dir or corpus.default_cache_dir(), corpus.http_fetcher())
    for data in blobs.values():
        cache.add(data)
    return cache.directory


def main(argv: list[str] | None = None, out: Callable[[str], None] = print, player: Any | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("write", "check", "blobs", "capture"))
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="the checkout whose perf-corpus/ to use")
    parser.add_argument("--cache", type=Path, default=None, help="the corpus blob cache (manifest.py's default)")
    parser.add_argument("--app", help="capture: a bench `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", type=Path, help="capture: the directory for the replays' results and checkpoint views")
    args = parser.parse_args(argv)
    if args.command == "capture" and not (args.app and args.out):
        parser.error("capture needs --app and --out")
    path = args.root / MANIFEST_PATH
    previous = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
    blobs = sources()
    text = render(manifest(blobs, previous))
    if args.command == "check":
        if previous is None or path.read_text(encoding="utf-8") != text:
            print(f"{MANIFEST_PATH} is not what agent_swarm.py makes: run `agent_swarm.py write`", file=sys.stderr)
            return 1
        out(f"ok: {MANIFEST_PATH} matches its generator")
        return 0
    if args.command == "capture":
        doc = run_capture(args, blobs, player, out)
        if doc is None:
            return 1
        path.write_text(render(doc), encoding="utf-8")
        out(f"wrote {MANIFEST_PATH} ({doc['status']})")
        return 0
    directory = cache_blobs(blobs, args.cache)
    if args.command == "write":
        path.write_text(text, encoding="utf-8")
        out(f"wrote {MANIFEST_PATH}")
    out(f"{len(blobs)} blobs in {directory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
