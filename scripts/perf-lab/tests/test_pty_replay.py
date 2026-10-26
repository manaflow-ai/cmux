"""Tests for scripts/perf-lab/corpus/pty_replay.py (PTY replay player, task p12-perf-process-112).

Run: python3 -m unittest scripts/perf-lab/tests/test_pty_replay.py
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import select
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
PLAYER = PERF_LAB / "corpus" / "pty_replay.py"
TERMINAL_CORPUS = REPO_ROOT / "schemas" / "terminal-corpus"


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


replay = load("pty_replay_under_test", PLAYER)


class FakeClock:
    """Time moves only when the player sleeps, plus `lag_ns` after each sleep (a late wake)."""

    def __init__(self, start_ns=1_000_000_000, lag_ns=0):
        self.now, self.lag_ns, self.deadlines = start_ns, lag_ns, []

    def now_ns(self):
        return self.now

    def sleep_until(self, deadline_ns):
        self.deadlines.append(deadline_ns)
        self.now = max(self.now, deadline_ns) + self.lag_ns


def frames_with_text_bytes(count, spacing_ms):
    """COUNT distinct frames, bare newlines and non-UTF-8 bytes included, at an uneven schedule."""
    frames, offset = [], 0.0
    for index in range(count):
        body = b"\x1b[3%dmframe %04d\x1b[0m\n" % (index % 8, index) + bytes([0x80 + index % 64, 0xff])
        frames.append((offset, body))
        offset += spacing_ms * (1 + (index % 3) / 2)
    return frames


class TtyrecTests(unittest.TestCase):
    def test_round_trip_keeps_bytes_and_offsets(self):
        source = [(0.0, b"a"), (1.5, b"bc\n"), (1000.25, b"\x00\xff")]
        recording = replay.decode_ttyrec(replay.encode_ttyrec(source, epoch_s=1_700_000_000))
        self.assertEqual([f.data for f in recording.frames], [b"a", b"bc\n", b"\x00\xff"])
        self.assertEqual([f.offset_ns for f in recording.frames], [0, 1_500_000, 1_000_250_000])

    def test_truncated_and_backwards_streams_raise(self):
        good = replay.encode_ttyrec([(0, b"hello"), (5, b"x")])
        with self.assertRaisesRegex(replay.PtyReplayError, "needs 1 bytes"):
            replay.decode_ttyrec(good[:-1])
        with self.assertRaisesRegex(replay.PtyReplayError, "truncated header"):
            replay.decode_ttyrec(good + b"\x00\x00")
        with self.assertRaisesRegex(replay.PtyReplayError, "earlier"):
            replay.decode_ttyrec(replay.encode_ttyrec([(5, b"a"), (1, b"b")]))
        with self.assertRaisesRegex(replay.PtyReplayError, "microseconds"):
            replay.decode_ttyrec(replay.TTYREC_HEADER.pack(0, 1_000_000, 0))

    def test_raw_vt_is_chunked_at_a_fixed_rate(self):
        data = (TERMINAL_CORPUS / "alt-screen-editor.vt").read_bytes()
        recording = replay.chunk_raw(data, chunk_bytes=512, chunk_ms=8)
        self.assertEqual(recording.data, data)
        self.assertEqual(len(recording.frames), -(-len(data) // 512))
        self.assertEqual([f.offset_ns for f in recording.frames[:3]], [0, 8_000_000, 16_000_000])
        self.assertEqual(recording.length_ns, len(recording.frames) * 8_000_000)

    def test_a_raw_loop_restarts_one_interval_after_its_last_chunk(self):
        clock = FakeClock(start_ns=0)
        replay.play(replay.chunk_raw(b"abcde", chunk_bytes=2, chunk_ms=1), lambda _: None, clock=clock, passes=2)
        self.assertEqual(clock.deadlines, [ms * 1_000_000 for ms in (0, 1, 2, 3, 4, 5)])


class PlayTests(unittest.TestCase):
    def test_deadlines_are_absolute_and_scaled_by_speed(self):
        recording = replay.decode_ttyrec(replay.encode_ttyrec([(0, b"a"), (10, b"b"), (30, b"c")]))
        clock, out = FakeClock(lag_ns=400_000), []
        playback = replay.play(recording, out.append, clock=clock, speed=2.0, passes=2, loop_gap_ms=10)
        start = 1_000_000_000
        # Pass length 40 ms at speed 2 is 20 ms; a late wake (0.4 ms) never pushes later deadlines.
        expected = [start + ms * 1_000_000 for ms in (0, 5, 15, 20, 25, 35)]
        self.assertEqual(clock.deadlines, expected)
        self.assertEqual(b"".join(out), b"abcabc")
        self.assertEqual((playback.passes, playback.frames, playback.bytes), (2, 6, 6))
        self.assertEqual(list(playback.lateness_ns), [400_000] * 6)
        report = playback.report()
        self.assertAlmostEqual(report["lateness_ms"]["p95"], 0.4)
        self.assertEqual(report["lateness_ms"]["n"], 6)
        self.assertAlmostEqual(report["max_lateness_ms"], 0.4)

    def test_a_long_soak_keeps_a_bounded_lateness_window_and_the_worst_write(self):
        playback = replay.Playback()
        playback.record(9_000_000, 1)
        for _ in range(replay.LATENESS_SAMPLES):
            playback.record(1_000, 1)
        self.assertEqual(len(playback.lateness_ns), replay.LATENESS_SAMPLES)
        self.assertEqual(playback.frames, replay.LATENESS_SAMPLES + 1)
        report = playback.report()
        self.assertAlmostEqual(report["lateness_ms"]["max"], 0.001)
        self.assertAlmostEqual(report["max_lateness_ms"], 9.0)

    def test_bad_arguments_raise(self):
        recording = replay.decode_ttyrec(replay.encode_ttyrec([(0, b"a")]))
        for kwargs, message in (({"speed": 0}, "speed"), ({"passes": 0}, "passes"),
                                ({"passes": 2}, "needs a length"), ({"loop_gap_ms": -1}, "negative")):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(replay.PtyReplayError, message):
                replay.play(recording, lambda _: None, clock=FakeClock(), **kwargs)
        with self.assertRaisesRegex(replay.PtyReplayError, "no frames"):
            replay.play(replay.Recording(()), lambda _: None, clock=FakeClock())

    def test_a_stopped_soak_counts_every_frame_it_wrote(self):
        recording = replay.decode_ttyrec(replay.encode_ttyrec([(0, b"ab"), (1, b"c")]))
        playback, out = replay.Playback(), []
        playback = replay.play(recording, out.append, clock=FakeClock(), passes=None, loop_gap_ms=1,
                               playback=playback, stop=lambda: len(out) == 7)
        self.assertEqual(len(out), 7)
        self.assertEqual((playback.passes, playback.frames, playback.bytes), (3, 7, len(b"".join(out))))


class MonotonicClockTests(unittest.TestCase):
    def pipe(self):
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        self.addCleanup(os.close, write_fd)
        return read_fd, write_fd

    def test_the_wait_drops_input_and_still_reaches_its_deadline(self):
        read_fd, write_fd = self.pipe()
        os.write(write_fd, b"\x1b[<0;10;5M\x1b[?62;22c")
        clock = replay.MonotonicClock(discard_fd=read_fd)
        deadline = clock.now_ns() + 20_000_000
        clock.sleep_until(deadline)
        self.assertGreaterEqual(clock.now_ns(), deadline)
        self.assertEqual(select.select([read_fd], [], [], 0)[0], [], "the input was not drained")

    def test_a_wake_ends_the_wait_only_when_a_stop_was_requested(self):
        read_fd, write_fd = self.pipe()
        os.set_blocking(read_fd, False)
        stop = {"requested": False}
        clock = replay.MonotonicClock(wake_fd=read_fd, stop=lambda: stop["requested"])
        os.write(write_fd, b"\x0f")
        deadline = clock.now_ns() + 20_000_000
        clock.sleep_until(deadline)
        self.assertGreaterEqual(clock.now_ns(), deadline, "a wake with no stop ended the wait early")
        stop["requested"] = True
        os.write(write_fd, b"\x0f")
        deadline = clock.now_ns() + 10_000_000_000
        clock.sleep_until(deadline)
        self.assertLess(clock.now_ns(), deadline - 9_000_000_000, "the stop did not end the wait")


class SourceTests(unittest.TestCase):
    def manifest(self, source, **track):
        return {"id": "story", "pty": [{"surface": "@w0.p0.t0", "source": source, "speed": 1, "loop": False,
                                        **track}]}

    def test_repository_vt_source_is_checked_and_raw(self):
        path = "schemas/terminal-corpus/wide-combining.vt"
        data = (REPO_ROOT / path).read_bytes()
        ref = {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.assertEqual(replay.read_source(ref, root=REPO_ROOT, read_blob=None), (data, True))
        with self.assertRaisesRegex(replay.PtyReplayError, "does not match"):
            replay.read_source({**ref, "bytes": len(data) + 1}, root=REPO_ROOT, read_blob=None)

    def test_blob_source_is_a_ttyrec_through_the_reader(self):
        blob = replay.encode_ttyrec([(0, b"x")])
        ref = {"sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)}
        self.assertEqual(replay.read_source(ref, root=REPO_ROOT, read_blob=lambda r: blob if r == ref else b""),
                         (blob, False))

    def test_unrecorded_or_missing_track_raises(self):
        with self.assertRaisesRegex(replay.PtyReplayError, "not recorded"):
            replay.manifest_track(self.manifest(None), 0)
        with self.assertRaisesRegex(replay.PtyReplayError, "no pty track 1"):
            replay.manifest_track(self.manifest(None), 1)

    def test_cli_plays_a_manifest_blob_track_with_its_speed_and_passes(self):
        blob = replay.encode_ttyrec([(0, b"one\n"), (20, b"two\n")])
        ref = {"sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)}
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "story.json"
            manifest.write_text(json.dumps(self.manifest(ref, speed=4)), encoding="utf-8")
            timing = Path(tmp) / "timing.json"
            read_fd, write_fd = os.pipe()
            clock = FakeClock()
            try:
                code = replay.main([f"--manifest={manifest}", "--passes", "3", "--loop-gap-ms", "20",
                                    f"--timing-json={timing}"], clock=clock, out_fd=write_fd,
                                   blob_reader=lambda: (lambda r: blob))
            finally:
                os.close(write_fd)
                with os.fdopen(read_fd, "rb") as reader:
                    written = reader.read()
            self.assertEqual(code, 0)
            self.assertEqual(written, b"one\ntwo\n" * 3)
            # 40 ms per pass at the track's speed 4.
            self.assertEqual(clock.deadlines[-1] - clock.deadlines[0], 25_000_000)
            report = json.loads(timing.read_text(encoding="utf-8"))
            self.assertEqual((report["passes"], report["frames"], report["bytes"]), (3, 6, 24))

    def test_cli_reports_errors_and_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.ttyrec"
            bad.write_bytes(b"\x01\x02")
            with open(os.devnull, "wb") as sink, contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(replay.main([str(bad)], clock=FakeClock(), out_fd=sink.fileno()), 1)
                self.assertEqual(replay.main(["--blob", "0" * 64], clock=FakeClock(), out_fd=sink.fileno()), 1)
            self.assertIn("pty_replay: ttyrec: truncated header", stderr.getvalue())
            self.assertIn("--blob needs --bytes", stderr.getvalue())


@unittest.skipUnless(hasattr(os, "openpty"), "needs a pty")
class RealPtyTests(unittest.TestCase):
    """Runs the CLI with its stdout on a real pty slave and reads the master, as a terminal surface does."""

    def run_on_pty(self, args, *, typed=None):
        """Without TYPED the player's stdin is /dev/null. With it, its stdin is the pty too, as in a terminal
        surface, and TYPED is written to the master after each read, as a terminal sends input and replies."""
        master, slave = os.openpty()
        process = subprocess.Popen([sys.executable, "-I", str(PLAYER), *args], stdout=slave,
                                   stdin=subprocess.DEVNULL if typed is None else slave)
        os.close(slave)
        reads = []
        try:
            while True:
                ready, _, _ = select.select([master], [], [], 30)
                if not ready:
                    self.fail("the player stopped writing")
                try:
                    chunk = os.read(master, 1 << 16)
                except OSError:  # EIO: the slave side closed
                    break
                if not chunk:
                    break
                reads.append((time.monotonic_ns(), chunk))
                if typed is not None:
                    with contextlib.suppress(OSError):
                        os.write(master, typed)
        finally:
            os.close(master)
            self.assertEqual(process.wait(timeout=30), 0)
        return reads

    def test_terminal_corpus_streams_arrive_byte_identical(self):
        for name in ("shell-prompt.vt", "alt-screen-editor.vt", "kitty-graphics.vt"):
            with self.subTest(name):
                data = (TERMINAL_CORPUS / name).read_bytes()
                reads = self.run_on_pty([str(TERMINAL_CORPUS / name), "--raw-chunk-ms", "0.05", "--passes", "2"])
                self.assertEqual(b"".join(chunk for _, chunk in reads), data * 2)

    def test_input_and_replies_from_the_terminal_never_reach_the_output(self):
        # A mouse press and release (SGR 1006), a DA reply, a focus report, typed text and the keys that
        # would be signals or flow control in a cooked tty (Ctrl-C, Ctrl-Z, Ctrl-S).
        typed = b"\x1b[<0;10;5M\x1b[<0;10;5m\x1b[?62;22c\x1b[Ihello\r\x03\x1a\x13"
        data = (TERMINAL_CORPUS / "alt-screen-editor.vt").read_bytes()
        reads = self.run_on_pty([str(TERMINAL_CORPUS / "alt-screen-editor.vt"), "--raw-chunk-bytes", "64",
                                 "--raw-chunk-ms", "1", "--passes", "3"], typed=typed)
        self.assertEqual(b"".join(chunk for _, chunk in reads), data * 3)

    def test_a_soak_loops_until_sigterm_then_restores_the_tty_and_reports(self):
        import termios

        master, slave = os.openpty()
        source = TERMINAL_CORPUS / "wide-combining.vt"
        data = source.read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            timing = Path(tmp) / "timing.json"
            process = subprocess.Popen([sys.executable, "-I", str(PLAYER), str(source), "--loop", "--raw-chunk-ms", "1",
                                        f"--timing-json={timing}"], stdout=slave, stdin=subprocess.DEVNULL)
            received = bytearray()
            try:
                while len(received) < 3 * len(data):
                    ready, _, _ = select.select([master], [], [], 30)
                    self.assertTrue(ready, "the soak stopped writing")
                    received += os.read(master, 1 << 16)
                process.terminate()
                self.assertEqual(process.wait(timeout=30), 0)
                while select.select([master], [], [], 0.2)[0]:
                    received += os.read(master, 1 << 16)
                modes = termios.tcgetattr(slave)
                self.assertTrue(modes[1] & termios.OPOST, "OPOST was not restored")
                self.assertEqual(modes[3] & (termios.ECHO | termios.ICANON), termios.ECHO | termios.ICANON,
                                 "ECHO and ICANON were not restored")
            finally:
                os.close(master)
                os.close(slave)
            report = json.loads(timing.read_text(encoding="utf-8"))
        self.assertGreaterEqual(report["passes"], 3)
        self.assertEqual(report["bytes"], len(received))
        self.assertEqual(bytes(received), (data * (report["passes"] + 1))[:len(received)])

    def test_recorded_offsets_hold_within_1_ms_p95(self):
        frames = frames_with_text_bytes(240, spacing_ms=4)
        stats = load("perf_lab_perf_stats", PERF_LAB / "perf_stats.py")
        for speed in (1.0, 2.0):
            with self.subTest(speed=speed), tempfile.TemporaryDirectory() as tmp:
                recording = Path(tmp) / "track.ttyrec"
                recording.write_bytes(replay.encode_ttyrec(frames, epoch_s=1_700_000_000))
                reads = self.run_on_pty([str(recording), "--speed", str(speed)])
                self.assertEqual(b"".join(chunk for _, chunk in reads), b"".join(body for _, body in frames))
                errors_ms = arrival_errors_ms(frames, reads, speed)
                p95 = stats.pct(errors_ms, 0.95)
                self.assertLessEqual(p95, 1.0, f"timing error p95 {p95:.3f} ms at speed {speed}")


def arrival_errors_ms(frames, reads, speed):
    """|arrival - scheduled| per frame, both from the first frame's arrival; a frame arrives with its first byte."""
    arrivals, consumed, read_index, read_end = [], 0, 0, len(reads[0][1])
    for _, body in frames:
        while consumed >= read_end:
            read_index += 1
            read_end += len(reads[read_index][1])
        arrivals.append(reads[read_index][0])
        consumed += len(body)
    return [abs((arrival - arrivals[0]) / 1e6 - offset_ms / speed)
            for arrival, (offset_ms, _) in zip(arrivals, frames)]


if __name__ == "__main__":
    unittest.main()
