#!/usr/bin/env python3
"""update-dev-daily.sh moves cmux NEXT DEV from build N to N+1 with no hand work.

The script runs against stand-ins for the network and the macOS tools (curl,
shasum, ditto, plutil, codesign, osascript, open, and the app's bundled cmux
CLI), each recording its call. The stand-ins play a running app: the bundled
CLI's `app quit-keep-sessions` and osascript's quit stop it, `open` starts it.

- When the release asset's `updated_at` is the one already installed, the
  script says so and leaves the running app alone: no download, no quit.
- An update quits through the app's own Quit and Keep Sessions (terminals and
  agents keep running), swaps the bundle, and opens the app again.
- An app that was not running is installed and stays closed.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "cmux-next" / "update-dev-daily.sh"
APP = "cmux NEXT DEV.app"

STAND_IN = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
state = Path(os.environ["FAKE_STATE"])
name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
with open(state / "calls.log", "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
def running(value=None):
    path = state / "running"
    if value is not None: path.write_text("true" if value else "false")
    return path.exists() and path.read_text() == "true"
if name == "curl":
    url = args[-3] if "-o" in args else args[-1]
    out = args[args.index("-o") + 1] if "-o" in args else None
    if "/releases/tags/" in url:
        body = (state / "release.json").read_text()
    elif url.endswith(".sha256"):
        body = (state / "sha256").read_text()
    else:
        body = "zip " + (state / "sha256").read_text()
    if out: Path(out).write_text(body)
    else: sys.stdout.write(body)
elif name == "shasum":
    pass
elif name == "ditto":
    if args[0] == "-x":
        app = Path(args[-1]) / "cmux NEXT DEV.app" / "Contents"
        (app / "Resources" / "bin").mkdir(parents=True)
        (app / "Info.plist").write_text("com.cmuxterm.app.debug.next")
        (app / "VERSION").write_text((state / "sha256").read_text())
        cli = app / "Resources" / "bin" / "cmux"
        shutil.copy(sys.argv[0], cli)
    else:
        shutil.copytree(args[0], args[1], symlinks=True)
elif name == "plutil":
    key, path = args[args.index("-extract") + 1], args[-1]
    if path.endswith("Info.plist"):
        print(Path(path).read_text())
    else:
        value = json.loads(Path(path).read_text())
        for part in key.split("."):
            try: value = value[int(part)] if isinstance(value, list) else value[part]
            except (KeyError, IndexError, ValueError): sys.exit(1)
        print(len(value) if isinstance(value, (list, dict)) else value)
elif name == "codesign":
    pass
elif name == "osascript":
    script = " ".join(args)
    if "exists process" in script: print("true" if running() else "false")
    elif "to quit" in script: running(False)
elif name == "open":
    running(True)
elif name == "cmux":
    if args[:2] == ["app", "quit-keep-sessions"]: running(False)
    elif args[:2] == ["app", "ping"]: sys.exit(0 if running() else 1)
'''


def release(updated_at: str) -> str:
    asset = lambda name, at: {"name": name, "updated_at": at}
    return json.dumps({"tag_name": "cmux-next-dev", "assets": [
        asset("cmux-NEXT-DEV.zip.sha256", updated_at), asset("cmux-NEXT-DEV.zip", updated_at)]})


class Mac:
    """A scratch home with the stand-ins on PATH and an installed build N."""

    def __init__(self, scratch: str, *, running: bool) -> None:
        self.root = Path(scratch)
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.home = self.root / "home"
        for folder in (self.state, self.bin, self.home / "Applications"):
            folder.mkdir(parents=True)
        tool = self.bin / "stand-in"
        tool.write_text(STAND_IN)
        tool.chmod(tool.stat().st_mode | stat.S_IEXEC)
        for name in ("curl", "shasum", "ditto", "plutil", "codesign", "osascript", "open"):
            (self.bin / name).symlink_to(tool)
        (self.state / "running").write_text("true" if running else "false")
        self.app = self.home / "Applications" / APP
        self.publish("2026-10-11T17:25:52Z", "aaaa  cmux-NEXT-DEV.zip\n")
        # Build N, installed by the script.
        assert self.update().returncode == 0
        (self.state / "calls.log").unlink()
        (self.state / "running").write_text("true" if running else "false")

    def publish(self, updated_at: str, sha256: str) -> None:
        (self.state / "release.json").write_text(release(updated_at))
        (self.state / "sha256").write_text(sha256)

    def update(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home), "FAKE_STATE": str(self.state),
               "TMPDIR": str(self.root)}
        return subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=60)

    def calls(self) -> list[list[str]]:
        log = self.state / "calls.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def running(self) -> bool:
        return (self.state / "running").read_text() == "true"

    def installed(self) -> str:
        return (self.app / "Contents" / "VERSION").read_text()


def test_nothing_new_leaves_the_running_app_alone() -> None:
    with tempfile.TemporaryDirectory(prefix="dev-daily-") as scratch:
        mac = Mac(scratch, running=True)
        result = mac.update()
        assert result.returncode == 0, result.stderr
        assert "up to date" in result.stdout, result.stdout
        calls = mac.calls()
        assert not [c for c in calls if c[0] in ("ditto", "osascript", "open") or c[:3] == ["cmux", "app", "quit-keep-sessions"]], calls
        assert not [c for c in calls if c[0] == "curl" and c[-3].endswith(".zip")], calls
        assert mac.running()


def test_an_update_keeps_sessions_and_reopens_the_app() -> None:
    with tempfile.TemporaryDirectory(prefix="dev-daily-") as scratch:
        mac = Mac(scratch, running=True)
        mac.publish("2026-10-11T19:02:10Z", "bbbb  cmux-NEXT-DEV.zip\n")
        result = mac.update()
        assert result.returncode == 0, result.stderr
        calls = [c for c in mac.calls() if c[0] in ("cmux", "osascript", "open")
                 and "exists process" not in " ".join(c) and c[1:3] != ["app", "ping"]]
        # Quit and Keep Sessions, never a bare quit, then the new build opens.
        assert calls == [["cmux", "app", "quit-keep-sessions"], ["open", str(mac.app)]], calls
        assert mac.installed() == "bbbb  cmux-NEXT-DEV.zip\n"
        assert mac.running()
        # Installed now, so the same asset is nothing new.
        assert "up to date" in mac.update().stdout


def test_a_closed_app_is_updated_and_stays_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="dev-daily-") as scratch:
        mac = Mac(scratch, running=False)
        mac.publish("2026-10-11T19:02:10Z", "bbbb  cmux-NEXT-DEV.zip\n")
        result = mac.update()
        assert result.returncode == 0, result.stderr
        assert mac.installed() == "bbbb  cmux-NEXT-DEV.zip\n"
        assert not [c for c in mac.calls() if c[0] == "open"], mac.calls()
        assert not mac.running()


def test_a_republished_identical_archive_is_nothing_new() -> None:
    with tempfile.TemporaryDirectory(prefix="dev-daily-") as scratch:
        mac = Mac(scratch, running=True)
        # Re-uploaded (new updated_at) with the same bytes.
        mac.publish("2026-10-11T19:02:10Z", "aaaa  cmux-NEXT-DEV.zip\n")
        result = mac.update()
        assert result.returncode == 0, result.stderr
        assert "up to date" in result.stdout, result.stdout
        assert not [c for c in mac.calls() if c[0] in ("ditto", "osascript", "open")], mac.calls()


def main() -> int:
    failures = 0
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok   {name}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {name}: {error}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
