#!/usr/bin/env python3
"""What every generated corpus story shares (p12-perf-process.md 3.8): fixed-seed numbers, the input track, the
manifest with its kept checkpoint digests, the two-run capture of those digests, and the write / check / blobs /
capture commands.

A generated story is a script in scripts/perf-lab/corpus/stories/ that makes its sources (layout snapshot, input
track, transcripts) from fixed seeds and describes itself as a `Story`; `main(story)` is its command line:

    write    perf-corpus/<id>.json and the blobs into the corpus cache ($CMUX_PERF_CORPUS_CACHE, manifest.py)
    check    the committed manifest is what the script makes (exit 1 otherwise)
    blobs    only put the blobs into the cache, for a lab host that cannot reach R2
    capture --app APP --out DIR
             replay the story twice into fresh launches of a bench app (play.py's Player, task 115) with each
             checkpoint reading the state the app settles on, and write the manifest as `recorded` only when both
             runs read the same digests

Chromium's synthetic stories are made by code the same way (tools/perf/page_sets/system_health/: the page set is the
source of truth and the recording follows it). `write` keeps the committed digests while the sources stay the same;
a change of any source drops them, and the story is `planned` again until the next capture.

Stdlib only; runs under python3 -I.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent
REPO_ROOT = CORPUS.parents[2]
STORY_SCHEMA = "cmux-perf-corpus-story/v1"
# The manifest fields that name a story's sources: a change of any of them drops the captured digests.
SOURCE_FIELDS = ("duration_ms", "layout", "input", "pty", "web_archive", "agents")
CAPTURE_RUNS = 2
UNREAD = "0" * 64  # a capture's checkpoints read the state and never compare it: the digests it plays with are unused


class CaptureError(RuntimeError):
    """A capture cannot read the checkpoint digests, or its runs read different ones."""


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


def play_module():
    path = CORPUS / "play.py"
    if not path.is_file():
        raise CaptureError("capture replays through scripts/perf-lab/corpus/play.py (p12-perf-process-115), "
                           "which this checkout does not have")
    return _load("perf_lab_corpus_play", path)


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

    def choice(self, items: Sequence[Any]) -> Any:
        return items[self.next() % len(items)]


class Track:
    """Input events in time order; events at the same time keep the order they were added in."""

    def __init__(self):
        self._events: list[tuple[int, int, dict[str, Any]]] = []

    def add(self, t_ms: int, kind: str, payload: dict[str, Any]) -> None:
        self._events.append((t_ms, len(self._events), {"t_ms": t_ms, "kind": kind, "payload": payload}))

    def events(self) -> list[dict[str, Any]]:
        return [event for _, _, event in sorted(self._events, key=lambda item: item[:2])]


def ndjson(rows: Sequence[Mapping[str, Any]]) -> bytes:
    return "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows).encode()


def layout_bytes(snapshot: Mapping[str, Any]) -> bytes:
    """A layout snapshot's blob: session_io's canonical bytes, after its validator."""
    io = session_io()
    return io.canonical_bytes(io.check(snapshot))


# ---------------------------------------------------------------- the manifest

@dataclass(frozen=True)
class Story:
    """A generated story: `sources()` makes {name: bytes} of its blobs, `manifest(blobs, previous)` its manifest
    (with `story_manifest`), `checkpoints` are its (name, t_ms)."""
    id: str
    script: str
    checkpoints: tuple[tuple[str, int], ...]
    sources: Callable[[], dict[str, bytes]]
    manifest: Callable[[dict[str, bytes], dict[str, Any] | None], dict[str, Any]]

    @property
    def manifest_path(self) -> str:
        return f"perf-corpus/{self.id}.json"


def story_manifest(story: Story, *, tier: str, planned: str, description: str, owner: str, sources: Mapping[str, Any],
                   metrics: Sequence[tuple[str, str]], previous: Mapping[str, Any] | None) -> dict[str, Any]:
    """The manifest of `story` with `sources` (every SOURCE_FIELDS key) and `metrics` ((series, unit), lower is
    better). The checkpoint digests of `previous` (the committed manifest) stay while it names the same sources; the
    story is recorded once every checkpoint has both digests."""
    same = previous is not None and all(previous.get(key) == sources[key] for key in SOURCE_FIELDS)
    kept = {c["name"]: c for c in previous["checkpoints"]} if same else {}
    checkpoints = []
    for name, t_ms in story.checkpoints:
        old = kept.get(name) if kept.get(name, {}).get("t_ms") == t_ms else None
        checkpoints.append({"t_ms": t_ms, "name": name, "focus": old and old.get("focus"),
                            "surfaces": old and old.get("surfaces")})
    recorded = all(c["focus"] and c["surfaces"] for c in checkpoints)
    doc: dict[str, Any] = {"schema": STORY_SCHEMA, "id": story.id, "tier": tier,
                           "status": "recorded" if recorded else "planned"}
    if not recorded:
        doc["planned"] = planned
    doc.update({"description": description, "owner": owner})
    doc.update({key: sources[key] for key in SOURCE_FIELDS})
    series_id = story.id.replace("-", "_")
    doc["checkpoints"] = checkpoints
    doc["metrics"] = [{"name": rf"corpus\.{series_id}\.{name}", "unit": unit, "better": "lower"}
                      for name, unit in metrics]
    return doc


def render(doc: Mapping[str, Any]) -> str:
    return json.dumps(doc, indent=2) + "\n"


def cache_blobs(blobs: Mapping[str, bytes], cache_dir: Path | None) -> Path:
    corpus = corpus_manifest()
    cache = corpus.BlobCache(cache_dir or corpus.default_cache_dir(), corpus.http_fetcher())
    for data in blobs.values():
        cache.add(data)
    return cache.directory


# ---------------------------------------------------------------- capture

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
    """A play.Player whose checkpoints report the settled state instead of comparing it with the manifest's: as
    Player.checkpoint, the replies of the events before it first (a refusal fails here), then the same reads and
    digests."""

    class CapturePlayer(play.Player):
        def checkpoint(self, sender, item, out):
            sender.collect()
            reports: dict[str, Any] = {}

            def read() -> dict[str, str]:
                focus, surfaces, order = play.read_checkpoint(lambda method: play.call(sender.channel, method))
                reports.update(focus=focus, surfaces=surfaces, order=order)
                return {"focus": play.focus_digest(focus, order), "surfaces": play.surfaces_digest(surfaces)}

            try:
                got = settle(read, self.clock, self.settle_s, play.CHECKPOINT_POLL_S)
            except CaptureError as error:
                raise CaptureError(f"checkpoint {item.name} (t={item.t_ms:g} ms): {error}") from error
            (out / f"checkpoint-{item.name}.json").write_text(json.dumps(
                {"focus": play.focus_view(reports["focus"], reports["order"]),
                 "surfaces": play.surfaces_view(reports["surfaces"])}, indent=1), encoding="utf-8")
            return {"name": item.name, **got}

    return CapturePlayer(**seams)


def capture(story: Story, blobs: dict[str, bytes], *, app: str, out: Path, player: Any,
            runs: int = CAPTURE_RUNS) -> dict[str, Any]:
    """The story's manifest with the checkpoint digests that `runs` replays into fresh launches of `app` read.
    CaptureError when the runs read different digests: the story does not replay to one state and is not recorded."""
    doc = story.manifest(blobs, None)
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
    return story.manifest(blobs, captured)


def run_capture(story: Story, args: argparse.Namespace, blobs: dict[str, bytes], player: Any | None,
                out: Callable[[str], None]) -> dict[str, Any] | None:
    """`capture`: the recorded manifest, or None after printing why there is none."""
    corpus = corpus_manifest()
    directory = cache_blobs(blobs, args.cache)
    store = corpus.BlobCache(directory, corpus.http_fetcher())

    def fetch(ref: Mapping[str, Any]) -> Path:
        store.get(ref)
        return store.path(ref)

    failures: tuple[type[BaseException], ...] = (CaptureError,)
    try:
        if player is None:
            play = play_module()
            failures += (play.PlayError, play.bench_launch().LaunchError)
            player = capture_player(play, root=args.root, fetch=fetch, cache_dir=directory)
        doc = capture(story, blobs, app=args.app, out=args.out, player=player)
    except failures as error:
        print(f"capture: {error}", file=sys.stderr)
        return None
    out(f"captured {len(doc['checkpoints'])} checkpoints, the same in {CAPTURE_RUNS} runs")
    return doc


# ---------------------------------------------------------------- the command line

def main(story: Story, argv: list[str] | None = None, out: Callable[[str], None] = print,
         player: Any | None = None, doc: str = "") -> int:
    parser = argparse.ArgumentParser(prog=story.script, description=doc.split("\n\n")[0] or None)
    parser.add_argument("command", choices=("write", "check", "blobs", "capture"))
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="the checkout whose perf-corpus/ to use")
    parser.add_argument("--cache", type=Path, default=None, help="the corpus blob cache (manifest.py's default)")
    parser.add_argument("--app", help="capture: a bench `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", type=Path, help="capture: the directory for the replays' results and checkpoint views")
    args = parser.parse_args(argv)
    if args.command == "capture" and not (args.app and args.out):
        parser.error("capture needs --app and --out")
    path = args.root / story.manifest_path
    previous = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None
    blobs = story.sources()
    text = render(story.manifest(blobs, previous))
    if args.command == "check":
        if previous is None or path.read_text(encoding="utf-8") != text:
            print(f"{story.manifest_path} is not what {story.script} makes: run `{story.script} write`", file=sys.stderr)
            return 1
        out(f"ok: {story.manifest_path} matches its generator")
        return 0
    if args.command == "capture":
        captured = run_capture(story, args, blobs, player, out)
        if captured is None:
            return 1
        path.write_text(render(captured), encoding="utf-8")
        out(f"wrote {story.manifest_path} ({captured['status']})")
        return 0
    directory = cache_blobs(blobs, args.cache)
    if args.command == "write":
        path.write_text(text, encoding="utf-8")
        out(f"wrote {story.manifest_path}")
    out(f"{len(blobs)} blobs in {directory}")
    return 0
