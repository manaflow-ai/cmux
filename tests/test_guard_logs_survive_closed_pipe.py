#!/usr/bin/env python3
"""A shell guard's message before its kill never skips the kill when nobody reads its output any more.

cmux#41832 review F1 [P2]: "`echo ... >&2 || true` does not save a guard whose stderr pipe has no reader: bash can
take SIGPIPE and die before `|| true` runs, which skips the kill anyway." Bash does not ignore SIGPIPE: a builtin
echo to a pipe with no reader ends the shell at once, and an EXIT trap does not run either. It is the shell form of
cmux#41803's class (a BrokenPipeError before os.killpg in push_range.py's fetch guard).

The fix, one form everywhere: a message (or report) right before a kill or a cleanup runs in a subshell that
ignores SIGPIPE, `( trap '' PIPE; echo ... ) || true`; the write then fails with EPIPE inside the subshell, and the
caller goes on to its kill. Or the kill comes first (smoke-test-ci.sh).

Two detectors:
- Behaviour rows: each guard runs with its stdout and stderr on a pipe whose reader is gone, and the process it
  must stop has to be gone afterwards (red before the fix: the guard dies at its message and the process lives on).
- A scan of every shell script under scripts/ for a message followed within a few lines by a kill (or a lease
  release) that is not in the safe form. Fix the hit, or list it in SCAN_NOT_IN_CLASS with the reason.

Not in CI (tests/test-execution.d/other.toml: manual; no new CI tests, Lawrence 2026-10-23): run
`python3 -I tests/test_guard_logs_survive_closed_pipe.py` after adding or changing a shell guard that logs before
it kills (about 30 s; needs bash, curl, xargs, pgrep and ps).
"""

from __future__ import annotations

import builtins
import importlib.util
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

# Scan hits that are not this class, keyed by (path, a piece of the message line), with the reason.
SCAN_NOT_IN_CLASS = {
    ("scripts/measure/agent-loop.sh", 'echo "AGENT-LOOP setup: $name"'):
        "the message comes before the phase starts; the kill a few lines down is the watchdog's own, in a "
        "background subshell with its output on /dev/null",
    ("scripts/ci/frame-pacing/golden.sh", 'echo "lingering after quit: $pid $comm" | tee'):
        "the echo writes into a pipeline to tee, so a closed stderr ends tee, not the shell, and the script has "
        "no set -e (cmux#41832 checked it)",
}

SHELL_SHEBANG = re.compile(r"^#!\s*(/usr/bin/env\s+)?(/bin/|/usr/bin/)?(ba|z|k|da)?sh\b")
# A message: echo or printf at a command's start (not inside $(...)).
LOG_START = re.compile(r"(?:^|[;{]\s*|&&\s*|\|\|\s*|\bthen\s+|\bdo\s+|\belse\s+)(echo|printf)\b")
# A kill that stops something (not kill -0, a liveness check), or a lease release.
KILLS = re.compile(r"\bkill\s+(?!-0\b)(?!-l\b)[-\"$\w]|\bcapture-host\s+release\b")
SAFE = "trap '' PIPE"
WINDOW = 4  # lines after the message, comments and blank lines not counted


def _shell_scripts():
    for path in sorted((ROOT / "scripts").rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if path.suffix in (".sh", ".bash", ".zsh") or SHELL_SHEBANG.match(text):
            yield path, text


def _is_log(statement: str) -> bool:
    """True for a message to stdout or stderr: not into a file or /dev/null, not piped into a command but tee."""
    match = LOG_START.search(statement)
    if not match:
        return False
    rest = statement[match.start(1):]
    rest = re.split(r"\s(?:;|&&|\|\|)\s|;\s*(?:exit|return)\b", rest, maxsplit=1)[0]
    pipe = re.search(r"(?<!\|)\|(?!\|)\s*(\S+)", rest)
    if pipe and pipe.group(1) != "tee":
        return False
    redirect = re.sub(r"[12]?>&[12]", "", rest)
    return not re.search(r"(?<![<>])>{1,2}\s*\S", redirect)


QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')
# The end of the message's block (a closer or another branch less indented) or a function definition (its body
# runs later): a kill past it is not the message's.
BLOCK_END = re.compile(r"(fi|done|esac|else|elif|\}|;;|\))(\s|;|$)")
FUNCTION = re.compile(r"^(function\s+)?[\w:.-]+\s*\(\)\s*\{?")


def _unquoted(line: str) -> str:
    return QUOTED.sub('""', line)


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def scan_log_then_kill() -> list[str]:
    """Lines where a message to stdout or stderr comes before a kill and is not in the safe form."""
    hits = []
    for path, text in _shell_scripts():
        rel = path.relative_to(ROOT).as_posix()
        lines = text.split("\n")
        safe_depth = 0  # inside a multi-line `( trap '' PIPE ... ) || true` group
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("#") or not stripped:
                continue
            if SAFE in stripped and stripped.count("(") > stripped.count(")"):
                safe_depth += 1
                continue
            if safe_depth and re.match(r"\)\s*\|\|\s*true\b", stripped):
                safe_depth -= 1
                continue
            plain = _unquoted(stripped)
            if safe_depth or SAFE in stripped or not _is_log(plain):
                continue
            log_at = LOG_START.search(plain)
            if plain[:log_at.start(1)].count("$(") > plain[:log_at.start(1)].count(")"):
                continue  # inside a command substitution: its output is captured, not written out
            if any(rel == p and piece in stripped for p, piece in SCAN_NOT_IN_CLASS):
                continue
            after = [plain[log_at.end():]]
            for follow in lines[index + 1:]:
                if not follow.strip() or follow.strip().startswith("#"):
                    continue
                body = _unquoted(follow.strip())
                if FUNCTION.match(body) or (BLOCK_END.match(body) and _indent(follow) < _indent(line)):
                    break
                after.append(body)
                if len(after) > WINDOW:
                    break
            for candidate in after:
                kill = KILLS.search(candidate)
                leave = re.search(r"\b(exit|return)\b", candidate)
                if leave and (not kill or leave.start() < kill.start()):
                    break
                if kill:
                    hits.append(f"{rel}:{index + 1}: {stripped[:140]}")
                    break
    return hits


def closed_pipe() -> int:
    """The write end of a pipe whose reader is already gone."""
    read_end, write_end = os.pipe()
    os.close(read_end)
    return write_end


# tests/process_gone.py, loaded by path (`python3 -I` puts no script folder on sys.path). Its probe reads /proc where
# /proc exists and asks `ps` where it does not: macOS has no /proc, and a probe that read a missing /proc entry as
# "gone" passed assert_gone with the target still running (review of cmux#41850 F1).
_process_gone_spec = importlib.util.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
process_gone = importlib.util.module_from_spec(_process_gone_spec)
_process_gone_spec.loader.exec_module(process_gone)


def alive(pid: int) -> bool:
    """A process still running (a zombie counts as gone), with or without /proc."""
    return process_gone.running(pid)


class NoProcfs:
    """No /proc and no pidfd, as on macOS: the probe must still see a live process."""

    def __enter__(self) -> "NoProcfs":
        real_open, real_isdir, real_exists = builtins.open, os.path.isdir, os.path.exists

        def no_proc(path, *args, **kwargs):
            if str(path).startswith("/proc"):
                raise FileNotFoundError(2, "No such file or directory", str(path))
            return real_open(path, *args, **kwargs)
        self.patches = [mock.patch.object(os, "pidfd_open", side_effect=AttributeError, create=True),
                        mock.patch("builtins.open", no_proc),
                        mock.patch.object(os.path, "isdir", lambda p: False if str(p).startswith("/proc") else real_isdir(p)),
                        mock.patch.object(os.path, "exists", lambda p: False if str(p).startswith("/proc") else real_exists(p))]
        for patch in self.patches:
            patch.start()
        return self

    def __exit__(self, *exc: object) -> None:
        for patch in reversed(self.patches):
            patch.stop()


class GuardFixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="cmux-guard-pipe.")
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(os.path.realpath(tmp.name))

    def start(self, script: str, *args: str, argv0: str | None = None) -> int:
        """Starts a process this test owns (its own session), killed by its PID group at cleanup."""
        command = ["bash", "-c", script, argv0 or "target", *args]
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self._stop, proc)
        time.sleep(0.3)  # let bash install its traps and exec
        # The probe's self-check: a process this test just started must read as alive, or assert_gone proves nothing.
        self.assertTrue(alive(proc.pid), f"the probe cannot see live pid {proc.pid}; assert_gone would pass on any target")
        return proc.pid

    @staticmethod
    def _stop(proc: subprocess.Popen) -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()

    def run_guard(self, script: str, env: dict[str, str], timeout: float = 60) -> int:
        """Runs SCRIPT under bash with stdout and stderr on a pipe nobody reads."""
        out, err = closed_pipe(), closed_pipe()
        try:
            proc = subprocess.Popen(["bash", "-c", script], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    env={**os.environ, **env}, start_new_session=True)
        finally:
            os.close(out)
            os.close(err)
        self.addCleanup(self._stop, proc)
        return proc.wait(timeout=timeout)

    def assert_gone(self, pid: int, what: str, within: float = 5) -> None:
        self.assertTrue(process_gone.died(pid, within=within), what)
        try:
            os.waitpid(pid, os.WNOHANG)  # reap a child of this test's that died
        except ChildProcessError:
            pass

    @staticmethod
    def function(path: str, name: str) -> str:
        """The text of shell function NAME in PATH (from `NAME() {` to its closing `}` at column 0)."""
        text = (ROOT / path).read_text(encoding="utf-8")
        match = re.search(rf"^{re.escape(name)}\(\) \{{\n.*?^\}}\n", text, re.S | re.M)
        if not match:
            raise AssertionError(f"{path}: no function {name}")
        return match.group(0)


IGNORES_TERM = "trap '' TERM; exec -a \"$0\" sleep 600"
EXITS_ON_SECOND_TERM = "n=0; trap 'n=$((n + 1)); [ $n -ge 2 ] && exit 0' TERM; while :; do sleep 0.1; done"


class StopAppInstances(GuardFixture):
    """scripts/lib/stop-app-instances.sh: both messages before a kill (second SIGTERM, opt-in SIGKILL)."""

    def stop(self, target: int, env: dict[str, str]) -> int:
        lib = ROOT / "scripts/lib/stop-app-instances.sh"
        # The instance lookup and the exit wait are macOS (lsappinfo, kqueue): here they name the target and poll.
        script = textwrap.dedent(f"""\
            set -euo pipefail
            source '{lib}'
            cmux_app_instance_pids() {{ echo {target}; }}
            cmux_wait_for_pids_exit() {{
              local end=$((SECONDS + ${{1%%.*}} + 1)) p s left; shift
              while :; do
                left=""
                for p in "$@"; do
                  s="$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')"
                  [[ -n "$s" && "$s" != Z* ]] && left="$left $p"
                done
                [[ -z "$left" ]] && return 0
                (( SECONDS < end )) || {{ printf '%s\\n' $left; return 1; }}
                sleep 0.1
              done
            }}
            cmux_stop_app_instances com.cmuxterm.test.guardpipe '{self.tmp}/cmux DEV.app/Contents/MacOS/cmux DEV'
            """)
        return self.run_guard(script, {"CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS": "1",
                                       "CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS": "1", **env})

    def test_second_sigterm_reaches_an_instance_with_stderr_unread(self) -> None:
        target = self.start(EXITS_ON_SECOND_TERM)
        self.stop(target, {})
        self.assert_gone(target, "the message before the second SIGTERM ended the stop; the instance lives on")

    def test_opt_in_sigkill_reaches_an_instance_with_stderr_unread(self) -> None:
        target = self.start(IGNORES_TERM)
        self.stop(target, {"CMUX_STOP_APP_FORCE_KILL": "1"})
        self.assert_gone(target, "a message before the SIGKILL ended the stop; the instance lives on")


class SmokeDmgMountProcesses(GuardFixture):
    """scripts/ci/smoke-dmg.sh stop_mount_processes: SIGTERM, then SIGKILL, each after a message on stdout."""

    def test_processes_from_the_mount_are_stopped_with_stdout_unread(self) -> None:
        mount = self.tmp / "mount"
        mount.mkdir()
        target = self.start(IGNORES_TERM, argv0=f"{mount}/cmux.app/Contents/MacOS/cmux")
        path = "scripts/ci/smoke-dmg.sh"
        script = ("set -euo pipefail\n" + f"MOUNT_DIR='{mount}'\n" + self.function(path, "mount_pids")
                  + self.function(path, "stop_mount_processes") + "stop_mount_processes\n")
        self.run_guard(script, {})
        self.assert_gone(target, "a message before a kill ended stop_mount_processes; a process from the mount lives on")


class MessagesLabStopAfter(GuardFixture):
    """scripts/cmux-next/messageslab-selftest.sh stop_after: a message on stdout, then SIGTERM, then SIGKILL."""

    def test_the_app_is_stopped_with_stdout_unread(self) -> None:
        exe = f"{self.tmp}/MessagesLabAppKitNative.app/Contents/MacOS/MessagesLabAppKitNative"
        target = self.start(IGNORES_TERM, argv0=exe)
        path = "scripts/cmux-next/messageslab-selftest.sh"
        script = "set -uo pipefail\n" + f"exe='{exe}'\n" + self.function(path, "stop_after") + f"stop_after {target} 1\n"
        self.run_guard(script, {})
        self.assert_gone(target, "the message before the kill ended stop_after; the app lives on")


class StopCmuxTuiOwners(GuardFixture):
    """scripts/lib/stop-cmux-tui-owners.sh: a message on stderr, then SIGTERM to an owner that would not stop."""

    def test_the_owner_gets_sigterm_with_stderr_unread(self) -> None:
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        exe = bin_dir / "cmux-tui"
        exe.write_text("#!/bin/sh\nexit 1\n")  # `server stop` fails: the helper falls back to SIGTERM
        exe.chmod(0o755)
        target = self.start("exec -a \"$0\" sleep 600", argv0=f"{exe} --headless --socket {self.tmp}/s.sock")
        lib = ROOT / "scripts/lib/stop-cmux-tui-owners.sh"
        self.run_guard(f"set -euo pipefail\nsource '{lib}'\ncmux_stop_cmux_tui_owners '{bin_dir}'\n", {})
        self.assert_gone(target, "the message before the SIGTERM ended the helper; the owner lives on")


class SeedZigWatchdog(GuardFixture):
    """scripts/ci/seed-zig-package-archives.sh: at its deadline the watchdog reports, then stops the downloads."""

    def test_the_deadline_stops_downloads_once_stderr_has_no_reader(self) -> None:
        if not shutil.which("curl"):
            self.skipTest("no curl")
        port_socket = socket.socket()
        port_socket.bind(("127.0.0.1", 0))
        port = port_socket.getsockname()[1]
        port_socket.close()
        started = self.tmp / "started"
        server = self.tmp / "hang.py"
        server.write_text(textwrap.dedent("""\
            import http.server, sys, time
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    open(sys.argv[2], "a").close()
                    time.sleep(600)
                def log_message(self, *a): pass
            http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
            """))
        server_proc = subprocess.Popen([sys.executable, "-I", str(server), str(port), str(started)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self._stop, server_proc)
        for _ in range(50):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.1)
        src, cache = self.tmp / "src", self.tmp / "cache"
        src.mkdir()
        (cache / "p").mkdir(parents=True)
        (src / "build.zig.zon").write_text(
            f'.{{ .dependencies = .{{ .hang = .{{ .url = "http://127.0.0.1:{port}/hang.tar.gz", .hash = "N-hang" }}, }} }}\n')
        seed_timeout = 4
        env = {**os.environ, "CMUX_ZIG_MIRROR_ONLY": "0", "CMUX_ZIG_LOCK": str(self.tmp / "no.lock"),
               "CMUX_ZIG_SEED_TIMEOUT": str(seed_timeout), "TMPDIR": str(self.tmp)}
        env.pop("CI", None)
        read_end, write_end = os.pipe()
        began = time.monotonic()
        seed = subprocess.Popen([str(ROOT / "scripts/ci/seed-zig-package-archives.sh"), str(cache), str(src)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=write_end, env=env,
                                start_new_session=True)
        os.close(write_end)
        self.addCleanup(self._stop, seed)
        while not started.exists() and time.monotonic() - began < seed_timeout - 1 and seed.poll() is None:
            time.sleep(0.05)
        self.assertTrue(started.exists(), "no seed download reached the server before the deadline")
        os.close(read_end)  # nobody reads the seed's stderr from here on; the deadline comes after
        self.assertLess(time.monotonic() - began, seed_timeout, "the reader closed after the deadline")
        deadline = time.monotonic() + seed_timeout + 15
        while seed.poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
        left = subprocess.run(["pgrep", "-f", f"seed-zig-package-archives.sh --one {cache}"],
                              capture_output=True, text=True).stdout.split()
        self.assertEqual(left, [], "the watchdog died at its message; the downloads it should stop live on")
        self.assertIsNotNone(seed.poll(), "the seed is still waiting on downloads past its deadline")


class ProbeWithoutProcfs(GuardFixture):
    """Review of cmux#41850 F1: on macOS there is no /proc; the probe must still see a live process."""

    def test_a_live_process_reads_as_alive_with_procfs_hidden(self) -> None:
        target = self.start("exec sleep 600")
        with NoProcfs():
            self.assertTrue(alive(target), "with /proc hidden, a live process read as gone")

    def test_a_surviving_target_fails_assert_gone_with_procfs_hidden(self) -> None:
        target = self.start("exec sleep 600")
        with NoProcfs(), self.assertRaises(AssertionError, msg="assert_gone passed with its target still running"):
            self.assert_gone(target, "the target lives on", within=1)


class ScanLogThenKill(unittest.TestCase):
    def test_no_shell_guard_logs_unsafely_before_its_kill(self) -> None:
        hits = scan_log_then_kill()
        self.assertEqual(hits, [], "a message before a kill can end the script on a closed output (SIGPIPE) and "
                                   "skip the kill: write it as `( trap '' PIPE; echo ... ) || true`, kill first, or "
                                   "list it in SCAN_NOT_IN_CLASS with the reason:\n" + "\n".join(hits))

    def test_the_scan_sees_the_unsafe_form(self) -> None:
        unsafe = 'stop() {\n  echo "stopping $pid" >&2 || true\n  kill -TERM "$pid"\n}\n'
        safe = "stop() {\n  ( trap '' PIPE; echo \"stopping $pid\" >&2 ) || true\n  kill -TERM \"$pid\"\n}\n"
        to_file = 'stop() {\n  echo "$pid" > "$dir/pid"\n  kill -TERM "$pid"\n}\n'
        not_logs = textwrap.dedent("""\
            [[ -n "$x" ]] || { echo "x is not set"; exit 2; }
            kill -TERM "$pid"
            left="$(for p in $pids; do kill -0 "$p" && echo "$p"; done)"
            kill -9 $left
            if [[ -n "$y" ]]; then
              echo "warning: y"
            fi
            kill "$tunnel"
            echo "machine $run"
            printf "a crash, kill or truncation of %s" "$x"
            cleanup() {
              kill "$pid"
            }
            """)
        global ROOT
        saved = ROOT
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in (("unsafe.sh", unsafe), ("safe.sh", safe), ("to_file.sh", to_file), ("not_logs.sh", not_logs)):
                (Path(tmp) / "scripts").mkdir(exist_ok=True)
                (Path(tmp) / "scripts" / name).write_text(text)
            ROOT = Path(tmp)
            try:
                hits = scan_log_then_kill()
            finally:
                ROOT = saved
        self.assertEqual([hit.split(":")[0] for hit in hits], ["scripts/unsafe.sh"])


if __name__ == "__main__":
    unittest.main()
