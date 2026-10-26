#!/usr/bin/env python3
"""PTY replay player: writes recorded terminal output to its stdout at the recorded offsets (task 112).

    python3 -I scripts/perf-lab/corpus/pty_replay.py schemas/terminal-corpus/shell-prompt.vt [--speed 2]
    python3 -I scripts/perf-lab/corpus/pty_replay.py --manifest perf-corpus/dev-loop.json --track 0
    python3 -I scripts/perf-lab/corpus/pty_replay.py --blob SHA256 --bytes N --loop --timing-json out.json

A corpus story (p12-perf-process.md 3.8) runs this as the command of a terminal surface, so the bytes go
through the real PTY into the terminal's parser. Sources:

  - a timed recording in ttyrec format: per frame a 12-byte header (seconds, microseconds, length; each
    a little-endian uint32) and the frame's bytes. The first frame is offset 0. This is the format of PTY
    track blobs, and any repository source that is not a .vt file.
  - an untimed .vt stream (schemas/terminal-corpus/*.vt): RAW_CHUNK_BYTES-byte frames, one every
    RAW_CHUNK_MS ms, since the file has no offsets of its own.

A blob is read through corpus/manifest.py's BlobCache (task 110), which checks its sha256 on every read.

Timing: frame k of pass p is due at start + (p * pass + offset_k) / speed on the monotonic clock. Every
deadline is absolute, so a late frame does not shift the frames after it, as Chromium's
base::MetronomeTimer runs on a fixed phase rather than a delay after the last run (base/timer/timer.h).
A pass is the recording's length (a ttyrec's last offset, a raw stream's chunk count times the chunk
interval) plus --loop-gap-ms. Without --loop the player exits after --passes passes (default 1); with
--loop it plays until SIGTERM (the soak).

Byte identity: when stdout is a tty, the player turns off output post-processing (termios OPOST, so the
line discipline does not turn "\\n" into "\\r\\n") and restores the modes on exit. --timing-json writes
how late each write started against its deadline (perf_stats.summary of the last LATENESS_SAMPLES
writes, and the worst of all, in ms), for the story to check the replay was faithful.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_pty_replay.py
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import signal
import struct
import sys
import time
from collections import deque
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]

TTYREC_HEADER = struct.Struct("<III")
RAW_SUFFIX = ".vt"
RAW_CHUNK_BYTES = 512
RAW_CHUNK_MS = 8.0
NS_PER_MS = 1_000_000
LATENESS_SAMPLES = 65_536


class PtyReplayError(RuntimeError):
    pass


@dataclass(frozen=True)
class Frame:
    offset_ns: int
    data: bytes


@dataclass(frozen=True)
class Recording:
    """FRAMES and the length of one pass: a ttyrec ends at its last frame, a raw stream one interval later."""
    frames: tuple[Frame, ...]
    length_ns: int = 0

    @property
    def data(self) -> bytes:
        return b"".join(frame.data for frame in self.frames)



# ---------------------------------------------------------------- sources

def decode_ttyrec(data: bytes) -> Recording:
    """Frames of a ttyrec stream, with offsets from the first frame. Truncation or a time going back raises."""
    frames, position, start_us, previous_us = [], 0, None, 0
    while position < len(data):
        if len(data) - position < TTYREC_HEADER.size:
            raise PtyReplayError(f"ttyrec: truncated header at byte {position}")
        seconds, micros, length = TTYREC_HEADER.unpack_from(data, position)
        position += TTYREC_HEADER.size
        if micros >= 1_000_000:
            raise PtyReplayError(f"ttyrec: frame {len(frames)} has {micros} microseconds")
        if len(data) - position < length:
            raise PtyReplayError(f"ttyrec: frame {len(frames)} needs {length} bytes, {len(data) - position} left")
        stamp_us = seconds * 1_000_000 + micros
        start_us = stamp_us if start_us is None else start_us
        if stamp_us < previous_us:
            raise PtyReplayError(f"ttyrec: frame {len(frames)} is earlier than the frame before it")
        previous_us = stamp_us
        frames.append(Frame((stamp_us - start_us) * 1000, data[position:position + length]))
        position += length
    return Recording(tuple(frames), frames[-1].offset_ns if frames else 0)


def encode_ttyrec(frames: Sequence[tuple[float, bytes]], *, epoch_s: int = 0) -> bytes:
    """A ttyrec stream of (offset_ms, bytes) frames: what the recorder (task 116) writes and tests build."""
    out = bytearray()
    for offset_ms, data in frames:
        stamp_us = epoch_s * 1_000_000 + round(offset_ms * 1000)
        out += TTYREC_HEADER.pack(stamp_us // 1_000_000, stamp_us % 1_000_000, len(data)) + data
    return bytes(out)


def chunk_raw(data: bytes, *, chunk_bytes: int = RAW_CHUNK_BYTES, chunk_ms: float = RAW_CHUNK_MS) -> Recording:
    """An untimed stream as fixed-size frames at a fixed interval."""
    if chunk_bytes <= 0 or chunk_ms < 0:
        raise PtyReplayError("raw pacing needs chunk_bytes > 0 and chunk_ms >= 0")
    step_ns = round(chunk_ms * NS_PER_MS)
    frames = tuple(Frame(index * step_ns, data[start:start + chunk_bytes])
                   for index, start in enumerate(range(0, len(data), chunk_bytes)))
    return Recording(frames, len(frames) * step_ns)


def load_recording(data: bytes, *, raw: bool, chunk_bytes: int = RAW_CHUNK_BYTES,
                   chunk_ms: float = RAW_CHUNK_MS) -> Recording:
    if raw:
        return chunk_raw(data, chunk_bytes=chunk_bytes, chunk_ms=chunk_ms)
    return decode_ttyrec(data)


def _load_manifest_module():
    name = "perf_lab_corpus_manifest"
    if name not in sys.modules:
        path = HERE / "manifest.py"
        if not path.is_file():
            raise PtyReplayError(f"{path} is missing; blob sources need the corpus manifest module (task 110)")
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def default_blob_reader() -> Callable[[Mapping[str, Any]], bytes]:
    """Reads a {sha256, bytes} ref through the corpus BlobCache (local cache, then R2)."""
    corpus = _load_manifest_module()
    cache = corpus.BlobCache(corpus.default_cache_dir(), corpus.http_fetcher())

    def read(ref: Mapping[str, Any]) -> bytes:
        try:
            return cache.get(ref)
        except corpus.CorpusError as error:
            raise PtyReplayError(str(error)) from error

    return read


def read_source(ref: Mapping[str, Any], *, root: Path, read_blob: Callable[[Mapping[str, Any]], bytes]
                ) -> tuple[bytes, bool]:
    """(bytes, raw) of a manifest source: a repository file checked against its digest, or a blob."""
    if "path" not in ref:
        return read_blob(ref), False
    path = root / ref["path"]
    try:
        data = path.read_bytes()
    except OSError as error:
        raise PtyReplayError(f"{ref['path']}: {error}") from error
    if len(data) != ref["bytes"] or hashlib.sha256(data).hexdigest() != ref["sha256"]:
        raise PtyReplayError(f"{ref['path']} does not match its sha256 and bytes")
    return data, path.suffix == RAW_SUFFIX


def manifest_track(manifest: Mapping[str, Any], index: int) -> Mapping[str, Any]:
    tracks = manifest.get("pty") or []
    if not 0 <= index < len(tracks):
        raise PtyReplayError(f"{manifest.get('id')}: no pty track {index} (it has {len(tracks)})")
    track = tracks[index]
    if track.get("source") is None:
        raise PtyReplayError(f"{manifest.get('id')}: pty track {index} is not recorded yet")
    return track


# ---------------------------------------------------------------- playback

class Clock(Protocol):
    def now_ns(self) -> int: ...

    def sleep_until(self, deadline_ns: int) -> None: ...


class MonotonicClock:
    """time.sleep is clock_nanosleep on Linux; the deadline is rechecked so an early wake sleeps again."""

    def now_ns(self) -> int:
        return time.monotonic_ns()

    def sleep_until(self, deadline_ns: int) -> None:
        while (remaining := deadline_ns - time.monotonic_ns()) > 0:
            time.sleep(remaining / 1e9)


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


@contextlib.contextmanager
def raw_output(fd: int) -> Iterator[None]:
    """Turns off OPOST on a tty FD for the block, so the terminal gets the recorded bytes unchanged."""
    if not os.isatty(fd):
        yield
        return
    import termios

    saved = termios.tcgetattr(fd)
    changed = list(saved)
    changed[1] = saved[1] & ~termios.OPOST
    termios.tcsetattr(fd, termios.TCSANOW, changed)
    try:
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


@dataclass
class Playback:
    """Counts of a replay. lateness_ns keeps the last LATENESS_SAMPLES writes, so an 8 h soak stays small."""
    passes: int = 0
    frames: int = 0
    bytes: int = 0
    lateness_ns: deque[int] = field(default_factory=lambda: deque(maxlen=LATENESS_SAMPLES))
    max_lateness_ns: int = 0

    def record(self, lateness_ns: int, size: int) -> None:
        self.lateness_ns.append(lateness_ns)
        self.max_lateness_ns = max(self.max_lateness_ns, lateness_ns)
        self.frames += 1
        self.bytes += size

    def report(self) -> dict[str, Any]:
        stats = _load_sibling("perf_stats").summary([late / NS_PER_MS for late in self.lateness_ns])
        return {"passes": self.passes, "frames": self.frames, "bytes": self.bytes, "lateness_ms": stats,
                "max_lateness_ms": self.max_lateness_ns / NS_PER_MS}


def play(recording: Recording, write: Callable[[bytes], None], *, clock: Clock, speed: float = 1.0,
         passes: int | None = 1, loop_gap_ms: float = 0.0, playback: Playback | None = None) -> Playback:
    """Writes RECORDING's frames at their offsets / SPEED, PASSES times (None: until interrupted).
    Counts go into PLAYBACK as they happen, so an interrupted soak still has its numbers."""
    if speed <= 0:
        raise PtyReplayError("speed must be above 0")
    if passes is not None and passes < 1:
        raise PtyReplayError("passes must be at least 1")
    if loop_gap_ms < 0:
        raise PtyReplayError("loop_gap_ms must not be negative")
    if not recording.frames:
        raise PtyReplayError("the recording has no frames")
    pass_ns = recording.length_ns + round(loop_gap_ms * NS_PER_MS)
    if passes != 1 and pass_ns == 0:
        raise PtyReplayError("a looped recording needs a length: all frames are at offset 0; set a loop gap")
    result = playback if playback is not None else Playback()
    start_ns, index = clock.now_ns(), 0
    while passes is None or index < passes:
        for frame in recording.frames:
            deadline_ns = start_ns + round((index * pass_ns + frame.offset_ns) / speed)
            clock.sleep_until(deadline_ns)
            lateness_ns = clock.now_ns() - deadline_ns
            write(frame.data)
            result.record(lateness_ns, len(frame.data))
        index += 1
        result.passes = index
    return result


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name not in sys.modules:
        spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
    return sys.modules[module_name]


# ---------------------------------------------------------------- CLI

def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("source", nargs="?", type=Path, help="a .vt stream or a ttyrec recording")
    source.add_argument("--blob", metavar="SHA256", help="a ttyrec blob from the corpus cache or R2 (with --bytes)")
    source.add_argument("--manifest", type=Path, help="a perf-corpus manifest; plays its pty track --track")
    parser.add_argument("--bytes", type=int, help="the blob's size, with --blob")
    parser.add_argument("--track", type=int, default=0, help="the pty track index, with --manifest (default 0)")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="where manifest repository sources live")
    parser.add_argument("--speed", type=float, default=None, help="playback rate (default 1, or the track's)")
    loop = parser.add_mutually_exclusive_group()
    loop.add_argument("--loop", action="store_true", default=None, help="play until SIGTERM (soak)")
    loop.add_argument("--passes", type=int, default=None, help="passes before exiting (default 1)")
    parser.add_argument("--loop-gap-ms", type=float, default=0.0, help="time after a pass's last frame")
    parser.add_argument("--raw-chunk-bytes", type=int, default=RAW_CHUNK_BYTES)
    parser.add_argument("--raw-chunk-ms", type=float, default=RAW_CHUNK_MS)
    parser.add_argument("--timing-json", type=Path, help="write passes, frames, bytes and lateness_ms here")
    return parser


BlobReaderFactory = Callable[[], Callable[[Mapping[str, Any]], bytes]]


def _resolve(args: argparse.Namespace, blob_reader: BlobReaderFactory) -> tuple[Recording, float, int | None]:
    track: Mapping[str, Any] = {}
    if args.manifest is not None:
        try:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PtyReplayError(f"{args.manifest}: {error}") from error
        track = manifest_track(manifest, args.track)
        data, raw = read_source(track["source"], root=args.root, read_blob=lambda ref: blob_reader()(ref))
    elif args.blob is not None:
        if args.bytes is None:
            raise PtyReplayError("--blob needs --bytes")
        data, raw = blob_reader()({"sha256": args.blob, "bytes": args.bytes}), False
    else:
        try:
            data = args.source.read_bytes()
        except OSError as error:
            raise PtyReplayError(str(error)) from error
        raw = args.source.suffix == RAW_SUFFIX
    recording = load_recording(data, raw=raw, chunk_bytes=args.raw_chunk_bytes, chunk_ms=args.raw_chunk_ms)
    speed = args.speed if args.speed is not None else float(track.get("speed", 1.0))
    if args.loop or (args.loop is None and args.passes is None and track.get("loop") is True):
        passes = None
    else:
        passes = args.passes if args.passes is not None else 1
    return recording, speed, passes


def main(argv: list[str] | None = None, *, clock: Clock | None = None, out_fd: int | None = None,
         blob_reader: BlobReaderFactory = default_blob_reader) -> int:
    args = _parser().parse_args(argv)
    fd = sys.stdout.fileno() if out_fd is None else out_fd
    playback = None
    try:
        recording, speed, passes = _resolve(args, blob_reader)
        with raw_output(fd):
            playback = Playback()
            try:
                play(recording, lambda data: write_all(fd, data), clock=clock or MonotonicClock(), speed=speed,
                     passes=passes, loop_gap_ms=args.loop_gap_ms, playback=playback)
            except KeyboardInterrupt:
                pass
    except (PtyReplayError, OSError) as error:
        print(f"pty_replay: {error}", file=sys.stderr)
        return 1
    if args.timing_json is not None and playback is not None:
        args.timing_json.write_text(json.dumps(playback.report(), indent=2) + "\n", encoding="utf-8")
    return 0


def _interrupt_on_sigterm() -> None:
    def handler(signum: int, frame: Any) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, handler)


if __name__ == "__main__":
    _interrupt_on_sigterm()
    sys.exit(main())
