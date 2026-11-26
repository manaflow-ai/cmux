#!/usr/bin/env python3
'''Exercise the conformance harness's broker probe through a real macOS script PTY.'''

import errno
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def alive(pid):
    state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                           capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


@unittest.skipUnless(sys.platform == "darwin", "exercises macOS /usr/bin/script argv and PTY behavior")
class BrokerProbeTests(unittest.TestCase):
    def run_probe(self, interactive):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            broker = root / "broker"
            broker.write_text(f"#!{sys.executable}\n" + r'''
import os, pathlib, signal, sys
root = pathlib.Path(__file__).parent
assert all(os.isatty(fd) for fd in (0, 1, 2)), "broker lost its terminal"
fd = os.open("/dev/tty", os.O_RDWR)
os.close(fd)
if os.environ["PROBE_INTERACTIVE"] == "1":
    print("BROKER_PROMPT", flush=True)
    answer = sys.stdin.readline().strip()
    print("BROKER_ANSWER=" + answer, flush=True)
    raise SystemExit(0 if answer == "test-answer" else 9)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
(root / "broker.pid").write_text(str(os.getpid()))
if os.fork() == 0:
    os.setsid()
    (root / "descendant.pid").write_text(str(os.getpid()))
    print("BROKER_CHILD_READY", flush=True)
while True:
    signal.pause()
''')
            broker.chmod(0o755)
            # A deterministic stand-in for GNU timeout --foreground. It delivers
            # TERM only to script(1), exactly the boundary the reported leak crosses.
            # This keeps the regression runnable on stock macOS without coreutils.
            timeout = root / "timeout"
            timeout.write_text(f"#!{sys.executable}\n" + r'''
import subprocess, sys
assert sys.argv[1] == "--foreground"
p = subprocess.Popen(sys.argv[3:])
try:
    raise SystemExit(p.wait(timeout=float(sys.argv[2])))
except subprocess.TimeoutExpired:
    p.terminate()
    p.wait(timeout=5)
    raise SystemExit(124)
''')
            timeout.chmod(0o755)
            # Load the actual shell function, without starting an ET server or the
            # rest of the conformance sweep. Assertions concern processes and I/O,
            # not the source spelling or how the timeout is implemented.
            source = (ROOT / "scripts/remote-tmux-et-conformance.sh").read_text()
            start = source.index("et_run() {")
            function = source[start:source.index("\n}\n", start) + 3]
            runner = root / "probe.sh"
            variables = {
                "STATE": str(root), "TMUX_TMPDIR": str(root), "ET_RUN_SEQ": "0",
                "TRANSPORT_BROKER": str(broker), "TRANSPORT_BROKER_ARGS": "",
                "TRANSPORT_HOST": "fixture", "ET_RUN_NO_GRACE": "1",
                "TIMEOUT_BIN": str(timeout), "TTY_SINK": "/dev/null",
            }
            runner.write_text("set -uo pipefail\n" + "\n".join(
                f"{key}={shlex.quote(value)}" for key, value in variables.items()
            ) + "\n" + function + f"\net_run {10 if interactive else 2} probe\n"
              + "status=$?\nprintf 'PROBE_STATUS=%s\\n' \"$status\"\nexit \"$status\"\n")
            unrelated = subprocess.Popen([sys.executable, "-c", "import signal; signal.pause()"])
            pid, master = pty.fork()
            if pid == 0:
                os.chdir(ROOT)
                os.environ["PROBE_INTERACTIVE"] = "1" if interactive else "0"
                os.execv("/bin/bash", ["/bin/bash", str(runner)])
            output = bytearray()
            status = None
            answered = False
            try:
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if ready:
                        try:
                            data = os.read(master, 65536)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            data = b""
                        output.extend(data)
                        if interactive and not answered and b"BROKER_PROMPT" in output:
                            os.write(master, b"test-answer\n")
                            answered = True
                    finished, result = os.waitpid(pid, os.WNOHANG)
                    if finished:
                        status = os.waitstatus_to_exitcode(result)
                        break
                self.assertIsNotNone(status, output.decode(errors="replace"))
                with self.subTest("exit status"):
                    self.assertEqual(status, 0 if interactive else 124, output.decode(errors="replace"))
                self.assertIsNone(unrelated.poll(), "cleanup affected an unrelated process")
                if interactive:
                    self.assertIn(b"BROKER_ANSWER=test-answer", output)
                    transcript = next(root.glob("*.script")).read_bytes()
                    self.assertIn(b"BROKER_ANSWER=test-answer", transcript)
                else:
                    records = [root / "broker.pid", root / "descendant.pid"]
                    self.assertTrue(all(path.exists() for path in records), output.decode(errors="replace"))
                    children = [int(path.read_text()) for path in records]
                    deadline = time.monotonic() + 2
                    while any(alive(child) for child in children) and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertEqual([child for child in children if alive(child)], [],
                                     "broker descendants survived the probe timeout: " + output.decode(errors="replace"))
            finally:
                if status is None:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)
                os.close(master)
                for path in root.glob("*.pid"):
                    child = int(path.read_text())
                    if alive(child):
                        os.kill(child, signal.SIGKILL)
                unrelated.terminate()
                unrelated.wait(timeout=5)

    def test_prompt_and_answer_keep_real_terminals_and_transcript(self):
        self.run_probe(interactive=True)

    def test_timeout_reaps_broker_and_detached_descendant(self):
        self.run_probe(interactive=False)


if __name__ == "__main__":
    unittest.main()
