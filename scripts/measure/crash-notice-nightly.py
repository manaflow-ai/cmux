#!/usr/bin/env python3
"""Does the published NIGHTLY still offer a crash report after a crash? (goal feedback-to-fix-hours)

Downloads the newest signed NIGHTLY from the feed (as accounts-nightly-launch.py), launches it in a
private state root, ends it with SIGSEGV, launches it again, and reads what the second launch did:
- `report`: a new `<bundle>-app-*.json` in ~/Library/Logs/cmux-next naming signal 11 (the restart
  was recognized and recorded, CrashRecoveryService.appReport);
- `log`: the "previous run ended unexpectedly signal=11" line in the unified log;
- `notice`: the restart notice ("cmux restarted after a problem.") and its Report button on screen,
  read through Accessibility (best effort: a host without Accessibility for the step reads null).
It never presses Report and never opens a browser: Report only opens a prefilled issues/new page that
the person sends themselves, so a probe that stops at the notice files nothing. Sentry is off (fresh
defaults are opt-in), so the deliberate crash is sent nowhere.

dialog_files is true when the report and log both show the restart and the notice was not read as
missing. Last line: CRASH_NOTICE {json}.
Run: cmux-ci run --class exclusive --label gui-session-v1 --script scripts/measure/crash-notice-nightly.py --ref SHA
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.cmuxterm.app.nightly"
LOGS = Path.home() / "Library/Logs/cmux-next"
NOTICE = "restarted after a problem"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run(argv, timeout=120, **kwargs):
    return subprocess.run(argv, check=True, timeout=timeout, **kwargs)


def fetch(work: Path) -> tuple[Path, dict]:
    launch = module("accounts_nightly_launch", ROOT / "scripts/measure/accounts-nightly-launch.py")
    run(["curl", "-fsSL", "--max-time", "60", "-o", str(work / "feed.xml"), launch.FEED])
    selected = launch.pick_feed((work / "feed.xml").read_bytes())
    run(["curl", "-fsSL", "--max-time", "600", "-o", str(work / "nightly.dmg"), selected["url"]], timeout=620)
    artifact = module("nightly_artifact", ROOT / "scripts/ci/nightly_next_artifact_check.py")
    selected["sha256"] = artifact.check_dmg(work / "nightly.dmg", selected["length"], selected["signature"])
    mount = work / "mount"
    mount.mkdir()
    run(["hdiutil", "attach", str(work / "nightly.dmg"), "-nobrowse", "-readonly", "-mountpoint", str(mount)],
        stdout=subprocess.DEVNULL)
    try:
        apps = list(mount.glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("expected exactly one app in the NIGHTLY DMG")
        app = (work / "cmux NIGHTLY.app").resolve()
        run(["ditto", str(apps[0]), str(app)], timeout=300)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True, timeout=30)
    (work / "nightly.dmg").unlink()
    with (app / "Contents/Info.plist").open("rb") as handle:
        meta = plistlib.load(handle)
    if meta.get("CFBundleIdentifier") != BUNDLE or str(meta.get("CFBundleVersion")) != selected["build"]:
        raise RuntimeError("app identity/build does not match the feed")
    selected["commit"] = meta.get("CMUXCommit")
    selected["version"] = meta.get("CFBundleShortVersionString")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    return app, selected


class Launch:
    """One launch of `app` in the shared private state root; `pid` once its socket answers."""

    def __init__(self, app: Path, work: Path, env: dict):
        self.app, self.cli = app, str(app / "Contents/Resources/bin/cmux")
        socket = str(work / "control.sock")
        self.values = {"CMUX_NEXT_SOCKET_PATH": socket, "CMUX_NEXT_STATE_ROOT": str(work / "state"),
                       "CMUX_NEXT_CONFIG_FILE": str(work / "cmux-next.json"), "CMUX_NEXT_ALLOW_SECOND_INSTANCE": "1",
                       "CMUX_NEXT_NO_ACTIVATE": "1"}
        self.env = {**env, **self.values, "CMUX_SOCKET_PATH": socket}
        command = ["/usr/bin/open", "-W", "-g", "-n"]
        for key, value in self.values.items():
            command += ["--env", f"{key}={value}"]
        self.launcher = subprocess.Popen(command + [str(app)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.started = dt.datetime.now(dt.timezone.utc)
        self.pid = None
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline and self.pid is None:
            if self.launcher.poll() is not None:
                raise RuntimeError("NIGHTLY exited before its private socket was ready")
            identity = self.identify()
            if identity.get("app_bundle_path") == str(app) and isinstance(identity.get("pid"), int):
                self.pid = identity["pid"]
            else:
                time.sleep(1)
        if self.pid is None:
            raise RuntimeError("NIGHTLY did not identify its private app path within 90 seconds")

    def identify(self) -> dict:
        try:
            reply = subprocess.run([self.cli, "app", "identify", "--json"], env=self.env,
                                   capture_output=True, text=True, timeout=10)
            return json.loads(reply.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return {}

    def owned(self) -> bool:
        identity = self.identify()
        return identity.get("pid") == self.pid and identity.get("app_bundle_path") == str(self.app)

    def end(self, how: int) -> bool:
        """Sends `how` to our own launch only, then waits for its open -W helper."""
        if self.pid and self.owned():
            try:
                os.kill(self.pid, how)
            except ProcessLookupError:
                pass
        try:
            self.launcher.wait(timeout=60)
            return True
        except subprocess.TimeoutExpired:
            return False


def new_reports(after: float) -> list[dict]:
    rows = []
    for path in sorted(LOGS.glob(f"{BUNDLE}-app-*.json")):
        if path.stat().st_mtime < after:
            continue
        try:
            body = json.loads(path.read_text())
        except ValueError:
            continue
        rows.append({"file": path.name, "signal": body.get("signal"), "version": body.get("version")})
    return rows


def log_line(since: dt.datetime) -> str | None:
    start = since.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    reply = subprocess.run(["log", "show", "--style", "compact", "--start", start, "--predicate",
                            'subsystem == "com.cmuxterm.app.next" AND category == "crash"'],
                           capture_output=True, text=True, timeout=120)
    hits = [line for line in reply.stdout.splitlines() if "previous run ended unexpectedly" in line]
    return hits[-1].strip()[-240:] if hits else None


def notice(pid: int) -> dict | None:
    """The restart notice's text and buttons through Accessibility; None when AX is not allowed here."""
    script = f'''
tell application "System Events"
  set p to first process whose unix id is {pid}
  set out to {{}}
  repeat with w in windows of p
    try
      repeat with e in (entire contents of w)
        try
          set r to role of e
          if r is "AXStaticText" or r is "AXButton" then
            set v to ""
            try
              set v to value of e as text
            end try
            if v is "" or v is "missing value" then set v to (name of e as text)
            set end of out to (r & "|" & v)
          end if
        end try
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return out as text
end tell'''
    try:
        reply = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None
    if reply.returncode != 0:
        return None
    rows = [line.split("|", 1) for line in reply.stdout.splitlines() if "|" in line]
    texts = [v for r, v in rows if r == "AXStaticText" and NOTICE in v]
    return {"text": texts[0][:200] if texts else None,
            "report_button": any(r == "AXButton" and v.strip() == "Report" for r, v in rows)}


def main() -> int:
    out = ROOT / ".build/crash-notice-nightly"
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="crash-notice-"))
    (work / "state").mkdir()
    (work / "cmux-next.json").write_text("{}\n")
    result: dict = {"synthetic": True, "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    first = second = None
    clean = True
    try:
        app, selected = fetch(work)
        result.update(build=selected["build"], version=selected.get("version"), commit=selected.get("commit"))
        env = module("app_launch_env", ROOT / "scripts/cmux-next/app_launch_env.py").launch_env(os.environ)
        env = {k: v for k, v in env.items() if not k.startswith(("CMUX_UITEST_", "CMUX_DOGFOOD_", "CMUX_GITHUB_TEST_", "CMUX_AUTH_"))}
        first = Launch(app, work, env)
        time.sleep(8)  # past the quick-exit window, so the crash reads as a crash and not a launch failure
        crashed_at = time.time()
        if not first.end(signal.SIGSEGV):
            raise RuntimeError("the crashed NIGHTLY did not end within 60 s")
        second = Launch(app, work, env)
        deadline = time.monotonic() + 45
        seen = None
        while time.monotonic() < deadline:
            seen = notice(second.pid)
            if seen is None or seen["text"]:
                break
            time.sleep(3)
        result["notice"] = seen
        result["reports"] = new_reports(crashed_at)
        result["log"] = log_line(first.started)
        recorded = any(row.get("signal") == 11 for row in result["reports"])
        result["dialog_files"] = bool(recorded and result["log"] and (seen is None or (seen["text"] and seen["report_button"])))
        if seen is None:
            result["notice_read"] = "no Accessibility for this step: the notice is inferred from the report and log"
        subprocess.run(["screencapture", "-x", str(out / "after-restart.png")], capture_output=True, timeout=30)
    except Exception as error:  # noqa: BLE001 — every failure is the probe's answer, as JSON
        result["dialog_files"] = None
        result["error"] = str(error) if type(error) is RuntimeError else f"{type(error).__name__}: {error}"[:300]
    finally:
        for launch in (second, first):
            if launch and launch.launcher.poll() is None:
                clean &= launch.end(signal.SIGTERM)
        if clean:
            shutil.rmtree(work, ignore_errors=True)  # this run alone made the temp tree
        result["cleanup_ok"] = clean
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("CRASH_NOTICE " + json.dumps(result, sort_keys=True), flush=True)
    return 0 if result.get("dialog_files") else 1


if __name__ == "__main__":
    raise SystemExit(main())
