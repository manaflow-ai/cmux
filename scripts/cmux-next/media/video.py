"""A bounded, window-only ScreenCaptureKit recording, with no desktop fallback."""
from __future__ import annotations

from pathlib import Path
import selectors
import subprocess
import sys

MAX_SECONDS = 300


class WindowVideo:
    def __init__(self, session, pid: int | None, directory: Path, scratch: Path):
        self.session, self.pid = session, pid
        self.path = directory / "capture.mov"
        self.scratch = scratch
        self.process = None
        self.log = None
        self.reason = ""
        self.log_path = self.scratch / "record-window.log"

    def start(self) -> bool:
        if sys.platform != "darwin" or self.pid is None:
            self.reason = "ScreenCaptureKit requires macOS and an app PID"
            return False
        binary = self.scratch / "record-window"
        source = Path(__file__).with_name("record-window.swift")
        try:
            built = subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=120)
            if built.returncode:
                self.reason = "ScreenCaptureKit helper unavailable: " + built.stderr[-500:]
                return False
            # Both existing console routes can have different Screen Recording grants.
            for mode, prefix in self.session.capture_routes:
                self.path.unlink(missing_ok=True)
                self.log = self.log_path.open("w+")
                self.process = subprocess.Popen(prefix + [str(binary), str(self.pid), str(self.path)],
                                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                                text=True)
                with selectors.DefaultSelector() as ready:
                    ready.register(self.process.stdout, selectors.EVENT_READ)
                    if ready.select(timeout=30) and self.process.stdout.readline().strip() == "READY":
                        return True
                self.stop()
                self.reason = f"ScreenCaptureKit unavailable through {mode}: " + self.log_path.read_text()[-500:].strip()
        except (OSError, subprocess.SubprocessError) as error:
            self.reason = str(error)
            self.stop()
        self.path.unlink(missing_ok=True)
        return False

    def stop(self) -> bool:
        if self.process is None:
            return False
        process, self.process = self.process, None
        try:
            process.communicate(input="\n", timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()
            process.communicate()
        finally:
            if self.log:
                self.log.close()
                self.log = None
        return process.returncode == 0 and self.path.is_file() and self.path.stat().st_size > 0
