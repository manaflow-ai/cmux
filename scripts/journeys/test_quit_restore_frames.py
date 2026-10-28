#!/usr/bin/env python3
"""app-life-quit-restore's frame checks on its side-by-side split, no fleet, no app.

    python3 scripts/journeys/test_quit_restore_frames.py

On v2.2.2 (job 829d7791fc920697de860155, a8eba57c504) the journey failed 3 of 3: twice at step 19
(after Cmd-Q and the reopen) and once at step 14 (before the quit), each time on
`frame_text "second-<nonce>-42" never held`. The daemon, the app's viewport and the frame all had
the text: check-101.png of run1 (100 reads of one unchanged image) shows "second-873498-42" in the
right pane, but the whole-window text recognition returned 10 lines, the two panes' first lines run
together and no other terminal line. The split journeys read the pane's crop for this reason
(ext_window pane_frame_text); this one still read the whole window.

The fake reader below returns the recorded whole-window reads, and for a crop the lines of the pane
the crop is in (what its pixels show). A frame check of the journey must pass on what the frame shows.
"""
import json
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
# driver.py imports build_names.py, which run.py sends beside it; in the repo it is in scripts/cmux-next.
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

if "pane_frame_text" not in D.EXT_CONDITIONS:
    D.load_extensions(D)
import ext_window as W  # noqa: E402  (the module load_extensions installed)

JOURNEY = HERE / "journeys" / "p0" / "app-life-quit-restore.json"
NONCE = "873498"

# The whole-window reads the reader returned on the failing frames (the frames show the text).
RUN1_CHECK_101 = [  # after the reopen, step 19
    "• /tmp/jr-873498-left", "• /tmp/jr-873498-right", "• /tmp/jr-873498-second",
    "J> mkdir -p /tmp/jr-873498-left å& cd /tmp/jr-873498-l J> mkdir -p /tmp/jr-873498-second å& cd /tmp/jr-873498",
    "@ Home", "• App Store", "jr-restore", "jr-tabs", "jr-move", "• a"]
RUN3_CHECK_17 = [  # before the quit, step 14 (nonce 667927 in that run; the same frame with this nonce)
    "• /tmp/jr-873498-right", "• /tmp/jr-873498-second",
    "J> mkdir -p /tmp/jr-873498-left && cd /tmp/jr-873498-l J> mkdir -p /tmp/jr-873498-second å& cd /tmp/jr-873498",
    "Q Home", "• App Store", "jr-restore", "Did you know?", "Command Palette",
    "Run any cmux action by typing", "its name.", "Try It", "×"]

WIDTH, HEIGHT = 1100, 720  # the snapshot's pixels; the window is 1100 x 720 points (scale 1)


def png(width, height):
    """A blank PNG of this size (png_size reads its header; the fake reader never decodes it)."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"\xff" * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def pane(pid, x, lines, window):
    """A terminal pane as debug.surfaces reports it: its view's frame and grid in window points."""
    return {"pane": pid, "kind": "terminal", "text": "\n".join(lines),
            "grid": {"window": window, "frame_x": x, "frame_y": 30, "frame_width": 445, "frame_height": 690,
                     "origin_x": x + 4, "origin_y": 32, "cell_width": 8, "cell_height": 17}}


class FakeApp:
    """The restored window of run1: left pane x 208-653, right pane x 655-1100 (its selected tab "second")."""

    def __init__(self, window_read, window="win_restored", back=False):
        self.window_read, self.window, self.snapshot_window = window_read, window, None
        left = [f"J> mkdir -p /tmp/jr-{NONCE}-left && cd /tmp/jr-{NONCE}-l", f"eft && echo left-{NONCE}-$((6*7))",
                f"left-{NONCE}-42", "J>"]
        right = [f"J> mkdir -p /tmp/jr-{NONCE}-second && cd /tmp/jr-{NONCE}", f"-second && echo second-{NONCE}-$((6*7))",
                 f"second-{NONCE}-42", "J>"]
        if back:
            right[-1:] = [f"J> echo back-{NONCE}-$(basename $PWD)", f"back-{NONCE}-jr-{NONCE}-second", "J>"]
        self.panes_ = [pane("pane_left", 208, left, window), pane("pane_right", 655, right, window)]
        self.crops = {}

    def rpc(self, method, params=None, timeout=None):
        if method == "debug.layers":
            return {"windows": [{"id": self.window, "window_number": 7, "frame": [0, 0, WIDTH, HEIGHT]}]}
        if method == "debug.surfaces":
            return {"windows": [{"window": 7, "panes": self.panes_}]}
        raise AssertionError(f"unexpected rpc {method}")

    def snapshot(self, path):
        Path(path).write_bytes(png(WIDTH, HEIGHT))
        return Path(path)

    def read_text(self, image):
        box = self.crops.get(Path(image).name)
        if box is None:
            return list(self.window_read)
        cx = box[0] + box[2] / 2.0
        for p in self.panes_:
            g = p["grid"]
            if g["frame_x"] <= cx < g["frame_x"] + g["frame_width"]:
                return [l for l in p["text"].split("\n") if l.strip()]
        return []


def fake_sips(app):
    """/usr/bin/sips: a crop writes its --out file and the fake reader remembers its box."""
    def run(argv, **_kwargs):
        if argv[:2] == ["/usr/bin/sips", "--cropOffset"]:
            y, x, h, w = int(argv[2]), int(argv[3]), int(argv[5]), int(argv[6])
            out = Path(argv[argv.index("--out") + 1])
            shutil.copyfile(argv[7], out)
            app.crops[out.name] = (x, y, w, h)
        return D.subprocess.CompletedProcess(argv, 0, "", "")
    return run


def journey(app, out, pane_key, cached_window=None):
    j = D.Journey.__new__(D.Journey)
    j.app, j.out, j.checks = app, Path(out), 0
    j.pane, j.term, j.host_pid = pane_key, "term_" + pane_key, 1
    j.vars = {"nonce": NONCE, "prompt": D.PROMPT}
    if cached_window:
        j.ext_window = cached_window
    return j


def frame_conditions(title):
    spec = json.loads(JOURNEY.read_text())
    step = next(s for s in spec["steps"] if s.get("title") == title)
    return [c for c in step["all"] for name in c if D.KIND.get(name) == "frame"]


class QuitRestoreFrameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.real_run = D.subprocess.run

    def tearDown(self):
        D.subprocess.run = self.real_run
        shutil.rmtree(self.tmp)

    def check(self, title, window_read, pane_key, cached_window=None, back=False):
        app = FakeApp(window_read, back=back)
        D.subprocess.run = fake_sips(app)
        j = journey(app, self.tmp, pane_key, cached_window)
        conditions = frame_conditions(title)
        self.assertTrue(conditions, f"step {title!r} has no frame check")
        for condition in conditions:
            (name, want), = condition.items()
            holds, detail = j.evaluate(name, j.sub(want), {})
            self.assertTrue(holds, f"{name} {j.sub(want)!r} on what the frame shows: {json.dumps(detail)[:600]}")

    def test_restored_text_reads_in_the_shown_pane(self):
        # run1 and run2, step 19: the restored right pane shows second-N-42; the window read drops it.
        self.check("the shown terminal's text came back in the daemon, the view and the frame", RUN1_CHECK_101, "pane_right")

    def test_text_before_the_quit_reads_in_the_shown_pane(self):
        # run3, step 14: the same split before the quit.
        self.check("before the quit: two panes, three tabs, three folders", RUN3_CHECK_17, "pane_right")

    def test_typed_line_after_the_reopen_reads_in_the_shown_pane(self):
        self.check("the restored shell takes input, in its folder", RUN1_CHECK_101, "pane_right", back=True)

    def test_left_pane_text_reads_in_the_left_pane(self):
        self.check("the left pane's text came back too", RUN1_CHECK_101, "pane_left")

    def test_frame_check_reads_the_panes_window_after_the_reopen(self):
        # A window id remembered before the quit need not name a window after the reopen: the crop
        # is placed in the window the pane is in now.
        self.check("the shown terminal's text came back in the daemon, the view and the frame", RUN1_CHECK_101,
                   "pane_right", cached_window="win_before_quit")


if __name__ == "__main__":
    unittest.main()
