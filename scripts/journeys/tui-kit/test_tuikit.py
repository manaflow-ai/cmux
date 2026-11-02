#!/usr/bin/env python3
"""The TUI load kit's own checks: no app, no fleet. Each program runs in a real pseudo-terminal.

    python3 scripts/journeys/tui-kit/test_tuikit.py

The same seed gives the same first frames (byte for byte, with --fake-clock), another seed other
frames; every program leaves the terminal as it found it (alternate screen, cursor, mouse, autowrap);
sigwinch logs each SIGWINCH and reflows once per size; mouse logs an SGR 1006 press where it lands;
flood lines verify and a torn one is caught; vim-scroll scrolls and quits by itself (skipped without
vim); the scenario and the heavy profile plan are seeded and have the asked counts; the heavy profile
builds against a stand-in app and CLI and tears down; the ACP stand-in streams the same text twice.
"""
import ast
import fcntl
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "tuikit.py")
sys.path.insert(0, HERE)
import heavy_profile  # noqa: E402
import tuikit  # noqa: E402

PY = sys.executable


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class PtyRun:
    """A program on the child side of a new pseudo-terminal (its controlling terminal, so a size change
    sends it SIGWINCH). read_until/collect read what it drew."""

    def __init__(self, argv, cols=80, rows=24, env=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            set_size(0, cols, rows)
            e = dict(os.environ, TERM="xterm-256color", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
            e.update(env or {})
            os.execvpe(argv[0], argv, e)
        self.buf = b""
        self.status = None

    def pump(self, timeout):
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return True
        try:
            data = os.read(self.fd, 1 << 16)
        except OSError:
            return False
        if not data:
            return False
        self.buf += data
        return True

    def read_until(self, needle, timeout=10):
        deadline = time.monotonic() + timeout
        while needle not in self.buf and time.monotonic() < deadline:
            if not self.pump(0.05):
                break
        return needle in self.buf

    def write(self, data):
        os.write(self.fd, data)

    def resize(self, cols, rows):
        set_size(self.fd, cols, rows)

    def collect(self, timeout=20):
        """Everything until the program ends; its exit status."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.pump(0.05):
                break
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                while self.pump(0.05):
                    pass
                self.status = status
                break
        if self.status is None:
            try:
                _, self.status = os.waitpid(self.pid, 0 if time.monotonic() < deadline else os.WNOHANG)
            except ChildProcessError:
                pass
        if self.status is None:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
            raise AssertionError("program did not end in %ss" % timeout)
        os.close(self.fd)
        return self.buf, os.waitstatus_to_exitcode(self.status) if hasattr(os, "waitstatus_to_exitcode") else self.status


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f]


def frames(data):
    """The synchronized-update frames in the output (the text between BSU and ESU)."""
    out = []
    for part in data.split(tuikit.BSU.encode())[1:]:
        end = part.find(tuikit.ESU.encode())
        if end >= 0:
            out.append(part[:end])
    return out


def run_frames(args, count, cols=90, rows=30, timeout=30):
    run = PtyRun([PY, KIT] + args, cols, rows)
    data, code = run.collect(timeout)
    return data, code


class Grammar(unittest.TestCase):
    def test_python_3_9(self):
        """The minis run /usr/bin/python3 3.9.6: no newer syntax."""
        for name in ("tuikit.py", "heavy_profile.py", "agent_stream_acp.py", "pace_probe.py", "test_tuikit.py"):
            with open(os.path.join(HERE, name), encoding="utf-8") as f:
                ast.parse(f.read(), filename=name, feature_version=(3, 9))


class Gradient(unittest.TestCase):
    ARGS = ["gradient", "--frames", "40", "--fake-clock", "--duration", "0"]

    def test_same_seed_same_frames(self):
        a, code_a = run_frames(self.ARGS + ["--seed", "7"], 40)
        b, code_b = run_frames(self.ARGS + ["--seed", "7"], 40)
        c, _ = run_frames(self.ARGS + ["--seed", "8"], 40)
        self.assertEqual((code_a, code_b), (0, 0))
        fa, fb, fc = frames(a), frames(b), frames(c)
        self.assertEqual(len(fa), 40)
        self.assertEqual(fa, fb)
        self.assertNotEqual(fa[:5], fc[:5])
        self.assertNotEqual(fa[0], fa[1], "the gradient moves every frame")

    def test_counter_barcode_and_clean_exit(self):
        data, code = run_frames(self.ARGS + ["--seed", "3"], 40)
        self.assertEqual(code, 0)
        fs = frames(data)
        for k in (0, 1, 37):
            text = fs[k].decode("utf-8")
            self.assertIn(" F%07d t=%9.3fs seed=3 90x30 " % (k, k / 120.0), text)
            bits = text.rsplit("\x1b[2;1H", 1)[1]
            white = tuikit.bg(255, 255, 255) + " "
            black = tuikit.bg(0, 0, 0) + " "
            start = tuikit.bg(*tuikit.GUARD_START) + " "
            self.assertTrue(bits.startswith(start))
            body = bits[len(start):]
            code_bits = ""
            for _ in range(tuikit.BARCODE_BITS):
                if body.startswith(white):
                    code_bits, body = code_bits + "1", body[len(white):]
                else:
                    self.assertTrue(body.startswith(black))
                    code_bits, body = code_bits + "0", body[len(black):]
            self.assertEqual(int(code_bits, 2), k)
        tail = data[data.rindex(tuikit.ESU.encode()):]
        for seq in (tuikit.WRAP_ON, tuikit.SHOW, tuikit.ALT_OFF):
            self.assertIn(seq.encode(), tail)
        self.assertTrue(data.startswith(tuikit.ALT_ON.encode()))

    def test_wide_cells_at_described_columns(self):
        style = tuikit.gradient_style(5)
        lay = tuikit.gradient_layout(90, 30, style)
        cols = [e["col"] for e in lay["wide"]]
        self.assertEqual(cols[:4], [2, 3, 5, 6])
        self.assertTrue(all(e["width"] == 2 for e in lay["emoji"] if not e["char"].isdigit()))
        self.assertIn("big_counter", lay)
        data, _ = run_frames(["gradient", "--frames", "2", "--fake-clock", "--seed", "5", "--duration", "0"], 2)
        text = frames(data)[0].decode("utf-8")
        row = "\x1b[12;3H" + "".join(e["char"] for e in lay["wide"])
        self.assertIn(row, text)

    def test_pace_modes_keep_the_frames_and_seed(self):
        """Every pace mode draws the same frames."""
        base = ["gradient", "--frames", "12", "--fake-clock", "--seed", "4", "--duration", "0"]
        outs = [run_frames(base + ["--pace", mode], 12)[0] for mode in tuikit.PACE_MODES]
        self.assertEqual(frames(outs[0]), frames(outs[1]))
        self.assertEqual(frames(outs[0]), frames(outs[2]))
        with self.assertRaises(ValueError):
            tuikit.Pacer(120, "nap")

    def test_pace_defaults(self):
        """gradient spins by default (a sleeping 120 fps loop woke in bursts on a fleet mini, job
        0a364ec0ef40: interval p95 47 ms); top sleeps; the heavy profile's hidden gradients sleep."""
        parser = tuikit.build_parser()
        self.assertEqual(parser.parse_args(["gradient"]).pace, "spin")
        self.assertEqual(parser.parse_args(["top"]).pace, "sleep")
        hidden = [extra for program, extra in heavy_profile.HIDDEN_PROGRAMS if program == "gradient"]
        self.assertTrue(hidden and all(extra[extra.index("--pace") + 1] == "sleep" for extra in hidden))

    def test_pacer_modes_on_a_fake_clock(self):
        """A sleep that wakes 1 ms late: sleep mode starts the frame 1 ms late; hybrid sleeps to 2 ms
        before the due time and polls the rest; spin never sleeps. The clock moves 0.1 ms a read."""
        class Fake:
            def __init__(self):
                self.now, self.sleeps = 100.0, []

            def clock(self):
                self.now += 0.0001
                return self.now

            def sleep(self, seconds):
                self.sleeps.append(seconds)
                self.now += seconds + 0.001

        for mode, sleeps, late in (("sleep", 1, 0.001), ("hybrid", 1, 0.0), ("spin", 0, 0.0)):
            fake = Fake()
            pacer = tuikit.Pacer(100, mode, 2.0, clock=fake.clock, sleep=fake.sleep)
            got = pacer.wait(1)  # due 10 ms after the start
            self.assertEqual(len(fake.sleeps), sleeps, mode)
            self.assertAlmostEqual(got, late, delta=0.0003, msg=mode)
            self.assertEqual(pacer.before, 0.0)
            if mode == "hybrid":
                self.assertAlmostEqual(fake.sleeps[0], 0.008, delta=0.0003)
        fake = Fake()
        pacer = tuikit.Pacer(100, "sleep", clock=fake.clock, sleep=fake.sleep)
        fake.now += 1.0  # a second behind: drawn at once, counted as late before the wait, schedule restarts
        self.assertAlmostEqual(pacer.wait(0), 1.0, delta=0.001)
        self.assertAlmostEqual(pacer.before, 1.0, delta=0.001)
        self.assertEqual((pacer.base, fake.sleeps), (0, []))
        self.assertAlmostEqual(pacer.start, fake.now, delta=0.0002)

    def test_pace_probe_reports_each_variant(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run([PY, os.path.join(HERE, "pace_probe.py"), "--seconds", "0.5", "--out", tmp,
                                   "--only", "sleep,hybrid,spin,taskpolicy-B-pid+sleep"],
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            lines = [l for l in done.stdout.splitlines() if l.startswith("TUI-KIT-PACE-VARIANT ")]
            self.assertEqual([l.split()[1] for l in lines], ["sleep", "hybrid", "spin", "taskpolicy-B-pid+sleep"])
            data = load_json(os.path.join(tmp, "pace.json"))
        for name in ("sleep", "hybrid", "spin"):  # structure only: the timing is the host's, the probe's output
            r = data["results"][name]
            self.assertGreater(r["frames"], 0, name)
            for key in ("p50", "p95", "p99", "max", "late_hist", "nvcsw", "nivcsw", "draw_max", "darwin_bg"):
                self.assertIn(key, r)

    def test_fps_must_be_positive(self):
        done = subprocess.run([PY, KIT, "gradient", "--fps", "0", "--frames", "1", "--size", "10x5"],
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(done.returncode, 2)
        self.assertIn("must be above 0", done.stderr)

    def test_sigterm_ends_cleanly(self):
        run = PtyRun([PY, KIT, "gradient", "--seed", "1", "--duration", "0"], 60, 20)
        self.assertTrue(run.read_until(tuikit.ESU.encode(), 10))
        os.kill(run.pid, signal.SIGTERM)
        data, code = run.collect(10)
        self.assertEqual(code, 0)
        self.assertTrue(data.endswith((tuikit.ESU + tuikit.RESET + tuikit.WRAP_ON + tuikit.SHOW + tuikit.ALT_OFF).encode()))


class Sigwinch(unittest.TestCase):
    def test_logs_each_sigwinch_and_reflows_per_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "w.jsonl")
            run = PtyRun([PY, KIT, "sigwinch", "--seed", "4", "--duration", "3", "--tick", "20", "--log", log], 80, 24)
            self.assertTrue(run.read_until(b"SIGWINCH 80x24", 10))
            # Read the pty all the time, as a terminal does: macOS pty buffers are small, and a program
            # blocked on a full pty reflows only when it can write again (cmux21, 01:22Z: one reflow).
            last = (80, 24)
            for cols, rows in ((100, 30), (60, 20), (60, 20), (120, 40)):
                seen = len(run.buf)
                run.resize(cols, rows)
                header = b"SIGWINCH %dx%d" % (cols, rows)
                deadline = time.monotonic() + (0.3 if (cols, rows) == last else 5)
                while time.monotonic() < deadline and ((cols, rows) == last or header not in run.buf[seen:]):
                    run.pump(0.02)
                if (cols, rows) != last:
                    self.assertIn(header, run.buf[seen:], "no reflow drawn for %dx%d" % (cols, rows))
                last = (cols, rows)
            data, code = run.collect(15)
            self.assertEqual(code, 0)
            events = read_jsonl(log)
        winch = [e for e in events if e["ev"] == "sigwinch"]
        reflow = [e for e in events if e["ev"] == "reflow"]
        # Setting the same size again sends no SIGWINCH on Linux, and one on macOS: 3 or 4.
        self.assertIn(len(winch), (3, 4))
        self.assertEqual([(e["cols"], e["rows"]) for e in reflow], [(100, 30), (60, 20), (120, 40)])
        self.assertTrue(all(e["wall"] > 0 and e["mono"] > 0 for e in winch))
        self.assertIn(b"SIGWINCH 120x40", data)
        self.assertIn(b"bottom row 40 of 40", data)
        self.assertEqual(events[-1]["ev"], "end")

    def test_same_seed_same_first_frame(self):
        def first(seed):
            run = PtyRun([PY, KIT, "sigwinch", "--seed", str(seed), "--frames", "3", "--tick", "50",
                          "--fake-clock", "--duration", "0"], 70, 22)
            data, code = run.collect(10)
            self.assertEqual(code, 0)
            return frames(data)
        a, b, c = first(9), first(9), first(10)
        self.assertEqual(a, b)
        self.assertEqual(len(a), 4)  # the layout and 3 header ticks
        self.assertNotEqual(a[0], c[0])


class Mouse(unittest.TestCase):
    def test_press_lands_and_is_logged(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "m.jsonl")
            run = PtyRun([PY, KIT, "mouse", "--seed", "2", "--duration", "4", "--log", log], 80, 24)
            self.assertTrue(run.read_until(b"tui-mouse seed=2", 10))
            self.assertIn(tuikit.MOUSE_ON.encode(), run.buf)
            run.write(b"\x1b[<0;10;7M\x1b[<32;11;7M\x1b[<0;11;7m")
            self.assertTrue(run.read_until(b"(10,7,b0)", 5))  # curses redraws only what changed
            run.write(b"q")
            data, code = run.collect(10)
            self.assertEqual(code, 0)
            events = read_jsonl(log)
        kinds = [e["ev"] for e in events]
        self.assertEqual(kinds[0], "start")
        self.assertEqual(events[0]["cursor"], [12, 40])
        press = [e for e in events if e["ev"] == "press"]
        self.assertEqual([(e["x"], e["y"], e["b"]) for e in press], [(10, 7, 0)])
        self.assertIn("drag", kinds)
        self.assertIn("release", kinds)
        self.assertIn(tuikit.MOUSE_OFF.encode(), data)

    def test_same_seed_same_first_frame(self):
        def first(seed):
            run = PtyRun([PY, KIT, "mouse", "--seed", str(seed), "--frames", "2", "--tick", "20", "--fake-clock",
                          "--duration", "0"], 80, 24)
            data, code = run.collect(10)
            self.assertEqual(code, 0)
            return frames(data)
        a, b, c = first(5), first(5), first(6)
        self.assertGreaterEqual(len(a), 3)
        self.assertEqual(a, b)
        self.assertNotEqual(a[0], c[0])


class Flood(unittest.TestCase):
    def out(self, *args):
        return subprocess.run([PY, KIT, "flood"] + list(args), capture_output=True, text=True, timeout=30).stdout

    def test_same_seed_same_lines_and_verify(self):
        a = self.out("--seed", "3", "--lines", "20000")
        self.assertEqual(a, self.out("--seed", "3", "--lines", "20000"))
        self.assertNotEqual(a, self.out("--seed", "4", "--lines", "20000"))
        lines = a.splitlines()
        self.assertEqual(lines[-1], "\x1b[0mtuikit flood end lines=20000")
        self.assertTrue(all(len(line) <= 48 for line in lines[:-1]))
        report = tuikit.verify_lines(lines)
        self.assertTrue(report["ok"], report)
        self.assertEqual((report["first"], report["last"], report["valid"]), (0, 19999, 20000))

    def test_verify_finds_torn_and_stale(self):
        lines = self.out("--seed", "3", "--lines", "50").splitlines()[:-1]
        torn = list(lines)
        torn[10] = torn[10][:20] + torn[11][20:]
        report = tuikit.verify_lines(torn)
        self.assertFalse(report["ok"])
        self.assertEqual(len(report["torn"]), 1)
        stale = lines[:20] + lines[15:30]
        report = tuikit.verify_lines(stale)
        self.assertEqual(report["jumps"], [{"after": 19, "next": 15}])

    def test_sigterm_never_cuts_a_line(self):
        proc = subprocess.Popen([PY, KIT, "flood", "--seed", "5", "--duration", "0"], stdout=subprocess.PIPE)
        time.sleep(0.5)
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=20)
        lines = out.decode().splitlines()
        self.assertEqual(proc.returncode, 0)
        self.assertRegex(lines[-1], r"^\x1b\[0mtuikit flood end lines=\d+$")
        report = tuikit.verify_lines(lines[:-1])
        self.assertTrue(report["ok"], report["torn"][:2])
        self.assertEqual(report["valid"], int(lines[-1].rsplit("=", 1)[1]))

    def test_width_fits_the_seed(self):
        done = subprocess.run([PY, KIT, "flood", "--seed", "123456789012", "--width", "32", "--lines", "3"],
                              capture_output=True, text=True, timeout=20)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("--width is at least", done.stderr)

    def test_rate_and_duration(self):
        start = time.monotonic()
        out = self.out("--seed", "1", "--rate", "1000", "--duration", "1")
        took = time.monotonic() - start
        count = len(out.splitlines()) - 1
        self.assertLess(took, 5)
        self.assertTrue(800 <= count <= 1300, count)


class VimScroll(unittest.TestCase):
    def test_file_is_seeded(self):
        a = tuikit.vim_file_lines(11, 5000)
        self.assertEqual(a, tuikit.vim_file_lines(11, 5000))
        self.assertNotEqual(a, tuikit.vim_file_lines(12, 5000))
        self.assertEqual(len(a), 5000)
        self.assertIn("/* L005000 */", a[-1])

    @unittest.skipUnless(shutil.which("vim"), "no vim on this host")
    def test_vim_scrolls_and_quits(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "v.jsonl")
            run = PtyRun([PY, KIT, "vim-scroll", "--seed", "3", "--lines", "3000", "--duration", "2",
                          "--file", os.path.join(tmp, "f.c"), "--log", log], 100, 30, env={"TMPDIR": tmp})
            data, code = run.collect(20)
            self.assertEqual(code, 0)
            ticks = read_jsonl(log)
        self.assertGreater(len(ticks), 20)
        self.assertGreater(ticks[-1]["top"], ticks[0]["top"])
        self.assertIn(b"tuikit-vim seed=3", data)


class Top(unittest.TestCase):
    def test_same_seed_same_frames(self):
        args = ["top", "--frames", "10", "--fake-clock", "--duration", "0", "--fps", "60"]
        a, code = run_frames(args + ["--seed", "2"], 10)
        b, _ = run_frames(args + ["--seed", "2"], 10)
        c, _ = run_frames(args + ["--seed", "3"], 10)
        self.assertEqual(code, 0)
        self.assertEqual(len(frames(a)), 10)
        self.assertEqual(frames(a), frames(b))
        self.assertNotEqual(frames(a)[0], frames(c)[0])
        self.assertIn(b"PID USER", frames(a)[0])


class AgentStream(unittest.TestCase):
    def test_same_seed_same_text(self):
        def text(seed):
            return subprocess.run([PY, KIT, "agent-stream", "--seed", str(seed), "--chars", "4000", "--fake-clock"],
                                  capture_output=True, timeout=20).stdout
        a = text(5)
        self.assertEqual(a, text(5))
        self.assertNotEqual(a, text(6))
        self.assertIn("[p0001]", a.decode())
        self.assertGreaterEqual(len(a.decode()), 4000)

    def test_paced(self):
        start = time.monotonic()
        subprocess.run([PY, KIT, "agent-stream", "--seed", "1", "--cps", "2000", "--chars", "1000"],
                       capture_output=True, timeout=20)
        self.assertGreater(time.monotonic() - start, 0.4)


class Page(unittest.TestCase):
    def test_seeded_page(self):
        a = tuikit.page_html(4)
        self.assertEqual(a, tuikit.page_html(4))
        self.assertNotEqual(a, tuikit.page_html(5))
        for needle in ("@keyframes slide", "requestAnimationFrame", "window.tuikit", "tuikit seed=4"):
            self.assertIn(needle, a)

    def test_serve(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.Popen([PY, KIT, "serve", "--seed", "4", "--dir", tmp, "--duration", "5"],
                                    stdout=subprocess.PIPE, text=True)
            try:
                url = json.loads(proc.stdout.readline())["url"]
                import urllib.request
                body = urllib.request.urlopen(url, timeout=5).read().decode()
                self.assertEqual(body, tuikit.page_html(4))
            finally:
                proc.terminate()
                proc.wait(10)
                proc.stdout.close()


class Scenario(unittest.TestCase):
    def manifest(self, panes, seed):
        out = subprocess.run([PY, KIT, "scenario", "--panes", str(panes), "--seed", str(seed), "--kit", "/k/tuikit.py",
                              "--out", "/o"], capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_counts_and_seed(self):
        parser = tuikit.build_parser()
        for n in range(4, 13):
            m = self.manifest(n, 3)
            self.assertEqual(m, self.manifest(n, 3))
            programs = [p["program"] for p in m["panes"]]
            self.assertEqual(len(programs), n)
            self.assertIn("gradient", programs)
            self.assertIn("sigwinch", programs)
            if n >= 6:
                self.assertEqual(set(programs), set(tuikit.KINDS))
            self.assertEqual(sum(m["layout"]["rows_per_column"]), n)
            for p in m["panes"] + [{"argv": m["agent"]["terminal"]["argv"]}]:
                self.assertEqual(p["argv"][1], "/k/tuikit.py")
                parser.parse_args(p["argv"][2:])  # every command line parses
        self.assertNotEqual(self.manifest(12, 3)["panes"], self.manifest(12, 4)["panes"])


class HeavyPlan(unittest.TestCase):
    def plan(self, **kw):
        args = ["plan", "--seed", "7", "--kit", "/k/tuikit.py", "--out", "/o"]
        for key, value in kw.items():
            args += ["--" + key, str(value)]
        out = subprocess.run([PY, os.path.join(HERE, "heavy_profile.py")] + args, capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_counts_and_seed(self):
        p = self.plan()
        self.assertEqual(p, self.plan())
        self.assertNotEqual(p["hidden"], self.plan(seed=8)["hidden"])
        shown = p["shown"]
        tui = [c for col in shown["columns"] for c in col]
        self.assertEqual(len(tui), 12)
        self.assertEqual(len(p["hidden"]) + 1, 40)
        tabs = len(tui) + len(shown["extra_column"]) + sum(len(ws["tabs"]) for ws in p["hidden"])
        self.assertEqual(tabs, 200)
        self.assertGreater(len(shown["columns"]), 1)
        self.assertGreater(max(len(col) for col in shown["columns"]), 1, "columns and rows")
        self.assertEqual([e["kind"] for e in shown["extra_column"]], ["browser", "agent"])
        self.assertTrue(all(ws["tabs"][0]["kind"] == "terminal" for ws in p["hidden"]))
        parser = tuikit.build_parser()
        for cell in tui:
            parser.parse_args(cell["argv"][2:])


# ---- a stand-in app: control socket + CLI ----------------------------------------------------------

FAKE_CLI = r'''
import json, os, sys
state_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")
state = json.load(open(state_path)) if os.path.exists(state_path) else {"n": 0, "workspaces": []}
args = sys.argv[1:]
assert args[0] == "--socket" and args[2] == "--app-socket" and args[4] == "--json", args
args = args[5:]
argv = args[args.index("--") + 1:] if "--" in args else None
head = args[:args.index("--")] if "--" in args else args
def new(prefix):
    state["n"] += 1
    return "%s_%d" % (prefix, state["n"])
def pane_of(pid):
    for ws in state["workspaces"]:
        for p in ws["panes"]:
            if p["id"] == pid:
                return ws, p
    sys.exit("no pane " + pid)
def opt(name):
    return head[head.index(name) + 1]
value = {}
if head[:2] == ["workspace", "create"]:
    ws = {"id": new("ws"), "name": opt("--name"), "panes": []}
    pane = {"id": new("pane"), "tabs": [{"id": new("tab"), "kind": "terminal", "argv": argv}]}
    ws["panes"].append(pane)
    state["workspaces"].append(ws)
    value = {"workspace_id": ws["id"], "pane_id": pane["id"], "tab_id": pane["tabs"][0]["id"], "terminal_id": new("term")}
elif head[0] == "pane" and head[2] == "split":
    ws, _ = pane_of(head[1])
    pane = {"id": new("pane"), "tabs": [{"id": new("tab"), "kind": "terminal", "argv": argv}], "split": head[3:]}
    ws["panes"].append(pane)
    value = {"workspace_id": ws["id"], "pane_id": pane["id"], "tab_id": pane["tabs"][0]["id"], "terminal_id": new("term")}
elif head[:2] == ["tab", "create"]:
    ws, pane = pane_of(opt("--pane"))
    tab = {"id": new("tab"), "kind": head[2], "argv": argv, "url": opt("--url") if "--url" in head else None}
    pane["tabs"].append(tab)
    value = {"tab_id": tab["id"], ("browser_id" if head[2] == "browser" else "terminal_id"): new(head[2][:4])}
elif head[0] == "tab" and head[2] == "close":
    for ws in state["workspaces"]:
        for p in ws["panes"]:
            p["tabs"] = [t for t in p["tabs"] if t["id"] != head[1]]
elif head[0] == "workspace" and head[2] == "focus":
    state["focus"] = head[1]
elif head[0] == "workspace" and head[2] == "close":
    state["workspaces"] = [w for w in state["workspaces"] if w["id"] != head[1]]
else:
    sys.exit("unknown " + " ".join(head))
json.dump(state, open(state_path, "w"))
print(json.dumps({"value": value, "generation": 1, "revision": state["n"]}))
'''


class FakeApp:
    """Answers system.identify, debug.daemon, snapshot.get (from the stand-in CLI's state), action.run
    and debug.agent_pane on a unix socket."""

    def __init__(self, tmp, agent_ok):
        self.path = os.path.join(tmp, "app.sock")
        self.state = os.path.join(tmp, "state.json")
        self.agent_ok = agent_ok
        self.calls = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(16)
        self.closing = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            if self.closing:
                conn.close()
                return
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            req = json.loads(buf)
            self.calls.append(req)
            conn.sendall((json.dumps(self.answer(req["method"], req.get("params") or {})) + "\n").encode())
            conn.close()

    def answer(self, method, params):
        if method == "system.identify":
            return {"ok": True, "result": {"pid": os.getpid(), "bundle_id": "test", "tag": "t"}}
        if method == "debug.daemon":
            return {"ok": True, "result": {"pid": None}}
        if method == "snapshot.get":
            st = load_json(self.state) if os.path.exists(self.state) else {"workspaces": []}
            return {"ok": True, "result": {"topology": {"focus": {"workspace": st.get("focus")}, "workspaces": [
                {"id": w["id"], "name": w["name"], "screens": [{"id": "s", "panes": [
                    {"id": p["id"], "tabs": [{"id": t["id"], "kind": t["kind"]} for t in p["tabs"]]}
                    for p in w["panes"]]}]} for w in st["workspaces"]]}}}
        if method == "action.run":
            if not self.agent_ok:
                return {"ok": False, "error": {"code": "unknown_action"}}
            st = load_json(self.state)
            pane = params["target"].split(":", 1)[1]
            for w in st["workspaces"]:
                for p in w["panes"]:
                    if p["id"] == pane:
                        p["tabs"].append({"id": "tab_chat", "kind": "conversation"})
            with open(self.state, "w") as f:
                json.dump(st, f)
            return {"ok": True, "result": {"created": True}}
        if method == "debug.agent_pane":
            if params["action"] == "chat_state":
                return {"ok": True, "result": {"sessionId": "fake-1", "connection": "LocalApp"}}
            return {"ok": True, "result": {}}
        return {"ok": False, "error": {"code": "unknown"}}

    def close(self):
        self.closing = True
        try:  # wake the accept() so the thread ends before later tests fork
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as poke:
                poke.connect(self.path)
        except OSError:
            pass
        self.thread.join(5)
        self.server.close()


class HeavyBuild(unittest.TestCase):
    def build(self, agent_ok):
        tmp = tempfile.mkdtemp(prefix="tk-heavy-test-")
        self.addCleanup(shutil.rmtree, tmp, True)
        app = FakeApp(tmp, agent_ok)
        self.addCleanup(app.close)
        cli = os.path.join(tmp, "cmux")
        with open(cli, "w") as f:
            f.write("#!%s\n%s" % (PY, FAKE_CLI))
        os.chmod(cli, 0o755)
        env = dict(os.environ, FAKE_STATE=app.state)
        out = os.path.join(tmp, "out")
        home = os.path.join(tmp, "home")
        argv = [PY, os.path.join(HERE, "heavy_profile.py"), "build", "--seed", "3", "--workspaces", "6", "--tabs", "30",
                "--visible", "8", "--duration", "5", "--python", PY, "--app-socket", app.path, "--socket", "/x/daemon.sock",
                "--cli", cli, "--app", os.path.join(tmp, "X.app"), "--home", home, "--out", out]
        done = subprocess.run(argv, capture_output=True, text=True, timeout=120, env=env)
        manifest = os.path.join(out, "heavy.json")
        return done, load_json(manifest), manifest, argv, env, app

    def test_build_records_and_tears_down(self):
        done, data, manifest, argv, env, app = self.build(agent_ok=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(data["check"]["ok"], data["check"])
        self.assertEqual(data["check"]["found"]["workspaces"], 6)
        self.assertEqual(data["check"]["found"]["tabs"], 30)
        self.assertEqual(data["check"]["found"]["shown_panes"], 10)
        panes = data["made"]["shown"]["panes"]
        self.assertEqual(len([p for p in panes if p.get("program")]), 8)
        agent = [p for p in panes if p.get("kind") == "agent"][0]
        self.assertEqual(agent["mode"], "terminal", "no agent chat in this stand-in: the terminal stand-in runs")
        browser = [p for p in panes if p.get("kind") == "browser"][0]
        self.assertTrue(browser["url"].startswith(data["page_server"]["base"]))
        state = load_json(env["FAKE_STATE"])
        splits = [p.get("split") for w in state["workspaces"] if w["name"] == "tk-3-shown" for p in w["panes"]]
        self.assertTrue(any(s and "--right" in s for s in splits))
        self.assertTrue(any(s and "--down" in s for s in splits))
        teardown = subprocess.run([PY, os.path.join(HERE, "heavy_profile.py"), "teardown", "--manifest", manifest,
                                   "--home", os.path.dirname(manifest)], capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(teardown.returncode, 0, teardown.stdout + teardown.stderr)
        report = json.loads(teardown.stdout)
        self.assertEqual(len(report["closed"]), 6)
        self.assertEqual(report["page_server"], "stopped")
        self.assertEqual(load_json(env["FAKE_STATE"])["workspaces"], [])

    def test_agent_chat_when_the_app_opens_it(self):
        done, data, *_ = self.build(agent_ok=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        agent = [p for p in data["made"]["shown"]["panes"] if p.get("kind") == "agent"][0]
        # No build_names.py acpmux home for a stand-in bundle without Info.plist: the terminal stand-in.
        self.assertIn(agent["mode"], ("acp", "terminal"))
        subprocess.run([PY, os.path.join(HERE, "heavy_profile.py"), "teardown", "--manifest",
                        os.path.join(data["plan"]["out"], "heavy.json")], capture_output=True, timeout=60,
                       env=dict(os.environ, FAKE_STATE=os.path.join(os.path.dirname(data["plan"]["out"]), "state.json")))

    def test_columns_and_rows_split_even(self):
        done, data, manifest, argv, env, app = self.build(agent_ok=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        state = load_json(env["FAKE_STATE"])
        shown = [w for w in state["workspaces"] if w["name"] == "tk-3-shown"][0]
        rights = [p["split"] for p in shown["panes"] if p.get("split") and "--right" in p["split"]]
        columns = data["plan"]["counts"]["columns"] + 1
        self.assertEqual(len(rights), columns - 1)
        self.assertTrue(all("--viewport-width" not in r for r in rights))
        ratios = [float(r[r.index("--ratio") + 1]) for r in rights]
        expect = [1 - 1 / (columns - c + 1) for c in range(1, columns)]
        self.assertEqual([round(x, 4) for x in ratios], [round(x, 4) for x in expect])
        width, cols = 1.0, []  # each new pane takes its ratio of what is left: every column 1/N
        for ratio in ratios:
            cols.append(width * (1 - ratio))
            width *= ratio
        cols.append(width)
        self.assertTrue(all(abs(c - 1 / columns) < 1e-3 for c in cols), cols)
        subprocess.run([PY, os.path.join(HERE, "heavy_profile.py"), "teardown", "--manifest", manifest],
                       capture_output=True, timeout=60, env=env)

    def test_teardown_spares_a_reused_pid(self):
        self.assertTrue(heavy_profile.stop_page_server(os.getpid(), "/nowhere").startswith("not running"))


# ---- the ACP stand-in --------------------------------------------------------------------------------

FAKE_AGENT = os.path.join(HERE, "..", "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")


@unittest.skipUnless(os.path.exists(FAKE_AGENT), "no fake_agent.py in this checkout")
class AcpStream(unittest.TestCase):
    def converse(self, seed):
        proc = subprocess.Popen([PY, os.path.join(HERE, "agent_stream_acp.py")], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True, env=dict(os.environ, CMUX_TUIKIT_FAKE_AGENT=FAKE_AGENT))
        try:
            def send(obj):
                proc.stdin.write(json.dumps(obj) + "\n")
                proc.stdin.flush()

            def until(rid):
                seen = []
                while True:
                    line = proc.stdout.readline()
                    self.assertTrue(line, "the agent ended")
                    msg = json.loads(line)
                    seen.append(msg)
                    if msg.get("id") == rid and ("result" in msg or "error" in msg):
                        return msg, seen
            send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}})
            until(1)
            send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/tmp", "mcpServers": []}})
            sid = until(2)[0]["result"]["sessionId"]
            start = time.monotonic()
            send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                  "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "stream: %d 0.6 2000" % seed}]}})
            done, seen = until(3)
            took = time.monotonic() - start
        finally:
            proc.stdin.close()
            proc.terminate()
            proc.wait(10)
            proc.stdout.close()
        chunks = "".join(m["params"]["update"]["content"]["text"] for m in seen
                         if m.get("method") == "session/update" and m["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        return done["result"]["stopReason"], chunks, took

    def test_streams_seeded_text_for_its_time(self):
        reason, a, took = self.converse(4)
        self.assertEqual(reason, "end_turn")
        self.assertGreater(took, 0.5)
        self.assertIn("## Step 1 [p0001]", a)
        _, b, _ = self.converse(4)
        n = min(len(a), len(b), 600)
        self.assertGreater(n, 300)
        self.assertEqual(a[:n], b[:n])


if __name__ == "__main__":
    unittest.main(verbosity=2)
