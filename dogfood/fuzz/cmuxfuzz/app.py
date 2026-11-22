"""Launch, watch and stop one cmux DEV app for a fuzz session."""

from __future__ import annotations

import os
import plistlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from .sock import CmuxSocket

HOME = Path.home()
DIAGNOSTIC_REPORTS = HOME / "Library/Logs/DiagnosticReports"
HANG_DIR = HOME / "Library/Logs/cmux/hangs"
GHOSTTY_CRASH_DIR = HOME / ".local/state/cmux/crash"
# macOS crash and hang dialogs that would otherwise sit over the next GUI job.
REPORTER_PROCESSES = ("Problem Reporter", "UserNotificationCenter")
WINDOW_W, WINDOW_H = 1440, 900
LAUNCH_SETTLE_S = 2.5
# A Unix socket path must fit sun_path (104 bytes on macOS), with room to spare.
MAX_SOCKET_PATH = 100
SANDBOX_ROOT = Path("/private/tmp")


class LaunchError(RuntimeError):
    pass


def executable_of(app: Path) -> Path:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    return app / "Contents/MacOS" / info["CFBundleExecutable"]


def make_private_dir() -> Path:
    """A fresh 0700 directory only this user can enter, for one session's socket and debug log. A socket
    at a fixed shared-temp path (/tmp/cmux-debug-<tag>.sock) is one any other user on the Mac can reach."""
    path = Path(tempfile.mkdtemp(prefix="cmux-fuzz-"))
    if len(str(path / "cmux.sock")) > MAX_SOCKET_PATH:  # a long $TMPDIR; mkdtemp is 0700 wherever it is
        os.rmdir(path)
        path = Path(tempfile.mkdtemp(prefix="cmux-fuzz-", dir="/tmp"))
    os.chmod(path, 0o700)
    return path


class AppSession:
    def __init__(self, app: Path, *, tag: str = "fuzz", workdir: Path, socket_path: str | None = None,
                 debug_log: Path | None = None):
        """socket_path and debug_log default to a private per-session directory, removed by close();
        read them from the session, never from a path built from the tag."""
        self.app = app
        self.tag = tag
        self.workdir = workdir
        self.executable = executable_of(app)
        self.process_name = self.executable.name
        self.sandbox = self._make_sandbox()  # first: it can refuse, and nothing is made yet to clean up
        self.private_dir: Path | None = make_private_dir() if socket_path is None or debug_log is None else None
        self.socket_path = socket_path or str(self.private_dir / "cmux.sock")
        self.debug_log = Path(debug_log) if debug_log is not None else self.private_dir / "debug.log"
        self.sock = CmuxSocket(self.socket_path)
        self.pid: int | None = None
        self._proc: subprocess.Popen | None = None
        self._last_returncode: int | None = None
        self.started_at = 0.0
        self._log_offset = 0

    # ------------------------------------------------------------ lifecycle

    def env(self) -> dict[str, str]:
        return {
            "CMUX_TAG": self.tag,
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_SOCKET_ENABLE": "1",
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_PATH": self.socket_path,
            "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            "CMUX_DEBUG_LOG": str(self.debug_log),
            "CMUX_DISABLE_SESSION_RESTORE": "1",
            "CMUX_CLI_SENTRY_DISABLED": "1",
            # An empty home with a bare prompt: frames and issues must never show the Mac's user, host
            # name or files (the file explorer lists the terminal's directory).
            "HOME": str(self.sandbox),
            "ZDOTDIR": str(self.sandbox),
        }

    def _make_sandbox(self) -> Path:
        # A neutral path: the sidebar and the file explorer show it. Ours alone: another user's directory
        # there would be one they could write the shells' .zshrc in.
        path = SANDBOX_ROOT / f"cmux-fuzz-home-{self.tag}"
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.is_symlink() or path.stat().st_uid != os.getuid():
            raise LaunchError(f"{path} belongs to another user; remove it or pick another --tag")
        os.chmod(path, 0o700)
        rc = path / ".zshrc"
        # The app hands its shells the real home whatever HOME says, so cd to the sandbox by its path.
        rc.write_text("PROMPT='%# '\nRPROMPT=''\nunsetopt PROMPT_SP\nHISTFILE=/dev/null\n"
                      f"export HOME={shlex.quote(str(path))}\ncd {shlex.quote(str(path))}\n")
        (path / ".hushlogin").write_text("")
        return path

    def _output_tail(self, limit: int = 1500) -> str:
        with _suppress():
            return (self.workdir / "app-stdout.log").read_text(errors="replace")[-limit:].strip()
        return ""

    def launch(self, *, timeout: float = 60.0) -> None:
        """Start the app as our own child, in our process group: whatever stops this fuzzer (a job
        preempting it kills the group) stops the app with it, and nothing is left on the console."""
        self.stop_all()
        with _suppress():
            os.unlink(self.socket_path)
        with _suppress():
            self.debug_log.unlink()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "GHOSTTY_", "XCODE_"))}
        env.update(self.env())
        # A dev build's dylib carries an absolute rpath to the DerivedData it was built in, ahead of
        # @executable_path/../Frameworks. A staged copy outlives that directory, and a later compile
        # there leaves mismatched frameworks dyld would load first; prefer the ones the app shipped with.
        env["DYLD_FRAMEWORK_PATH"] = str(self.executable.parent.parent / "Frameworks")
        output = open(self.workdir / "app-stdout.log", "ab")
        try:
            self._proc = subprocess.Popen([str(self.executable)], env=env, cwd=str(self.sandbox), stdin=subprocess.DEVNULL,
                                          stdout=output, stderr=subprocess.STDOUT)
        finally:
            output.close()
        self.pid = self._proc.pid
        self.started_at = time.time()
        try:
            self._await_ready(timeout)
        except BaseException:
            self.stop()  # an app that never came up must not outlive the attempt (a run can end right after)
            raise

    def _await_ready(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._proc.poll() is not None:
                raise LaunchError(f"{self.app.name} exited with {self._proc.returncode} while starting: "
                                  f"{self._output_tail()}")
            if self.sock.ready():
                break
            time.sleep(0.25)
        else:
            raise LaunchError(f"{self.app.name} did not open its socket within {timeout:g} s (pid {self.pid})")
        # The first window appears shortly after the socket.
        window = None
        for _ in range(40):
            try:
                windows = self.sock.call("system.tree", timeout=5).get("windows") or []
                if windows:
                    window = windows[0]
                    break
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.25)
        if window is None:
            raise LaunchError(f"{self.app.name} opened no window")
        # A fresh app opens a narrow window on a headless mini; give every session the same roomy one.
        with _suppress_all():
            self.sock.call("remote.tmux.test_set_frame", {"window_id": window["id"], "width": float(WINDOW_W),
                                                          "height": float(WINDOW_H), "x": 40.0, "y": 40.0},
                           timeout=30)
        # Let the first shell read the sandbox's .zshrc and move there before any frame is taken.
        time.sleep(LAUNCH_SETTLE_S)
        self._log_offset = 0

    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def returncode(self) -> int | None:
        """The app's exit status once it is gone (negative: the signal that ended it), else None."""
        return self._proc.poll() if self._proc is not None else self._last_returncode

    def stop(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            with _suppress():
                self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with _suppress():
                    self._proc.kill()
                with _suppress_all():
                    self._proc.wait(timeout=5)
        if self._proc is not None:
            self._last_returncode = self._proc.returncode
        self._proc = None
        self.pid = None
        self.dismiss_reporters()

    def close(self) -> None:
        """Stop the app and remove the private directory its socket and debug log were in. Copy any
        evidence (copy_debug_log_tail) first. Safe to call more than once."""
        self.stop()
        if self.private_dir is not None:
            shutil.rmtree(self.private_dir, ignore_errors=True)
            self.private_dir = None

    def stop_all(self) -> None:
        """Instances of this very executable a previous session left (a fuzzer killed with SIGKILL). The build
        is the fuzzer's own copy, so nothing else runs this path; matched exactly, never as a pattern."""
        out = subprocess.run(["/bin/ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, _, command = line.strip().partition(" ")
            if command == str(self.executable) and pid.isdigit() and int(pid) != os.getpid():
                with _suppress():
                    os.kill(int(pid), signal.SIGKILL)
        self.dismiss_reporters()

    @staticmethod
    def dismiss_reporters() -> None:
        for name in REPORTER_PROCESSES:
            subprocess.run(["/usr/bin/pkill", "-9", "-x", name], capture_output=True)

    # ------------------------------------------------------------ evidence

    def rss_mb(self) -> float | None:
        if not self.pid:
            return None
        out = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True)
        text = out.stdout.strip()
        return int(text) / 1024 if text.isdigit() else None

    def sample(self, dest: Path, seconds: int = 3) -> Path | None:
        if not self.pid:
            return None
        try:
            subprocess.run(["/usr/bin/sample", str(self.pid), str(seconds), "-file", str(dest)],
                           capture_output=True, timeout=seconds + 30)
        except subprocess.TimeoutExpired:
            return None
        return dest if dest.exists() else None

    def crash_reports_since(self, since: float) -> list[Path]:
        found: list[Path] = []
        for directory in (DIAGNOSTIC_REPORTS, GHOSTTY_CRASH_DIR, self.sandbox / ".local/state/cmux/crash"):
            if not directory.is_dir():
                continue
            for path in directory.iterdir():
                name = path.name
                if directory == DIAGNOSTIC_REPORTS and not name.startswith(self.process_name):
                    continue
                try:
                    if path.stat().st_mtime >= since - 1:
                        found.append(path)
                except OSError:
                    continue
        return sorted(found, key=lambda p: p.stat().st_mtime)

    def wait_for_crash_report(self, since: float, timeout: float = 20.0) -> Path | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reports = [p for p in self.crash_reports_since(since) if p.suffix == ".ips"]
            if reports:
                return reports[-1]
            time.sleep(0.5)
        return None

    def hang_samples_since(self, since: float) -> list[Path]:
        out = []
        # The app reads HOME from its environment (the sandbox) or the user record, depending on the API.
        paths = [*HANG_DIR.glob("cmux-hang-*.sample.txt"),
                 *(self.sandbox / "Library/Logs/cmux/hangs").glob("cmux-hang-*.sample.txt")]
        for path in paths:
            try:
                if path.stat().st_mtime >= since and (self.pid is None or f"-{self.pid}-" in path.name):
                    out.append(path)
            except OSError:
                continue
        return sorted(out)

    def new_log_lines(self, limit_bytes: int = 1 << 20) -> list[str]:
        try:
            with open(self.debug_log, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                start = max(self._log_offset, size - limit_bytes)
                handle.seek(start)
                data = handle.read()
                self._log_offset = size
        except OSError:
            return []
        return data.decode("utf-8", "replace").splitlines()

    def copy_debug_log_tail(self, dest: Path, limit_bytes: int = 2 << 20) -> None:
        try:
            with open(self.debug_log, "rb") as src:
                src.seek(0, os.SEEK_END)
                src.seek(max(0, src.tell() - limit_bytes))
                dest.write_bytes(src.read())
        except OSError:
            pass


class _suppress_all:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return exc[0] is not None and issubclass(exc[0], Exception)


class _suppress:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return exc[0] is not None and issubclass(exc[0], OSError)
