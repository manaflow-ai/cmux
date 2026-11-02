#!/usr/bin/env python3
"""Fresh-home launch smoke of a signed cmux NEXT app, the nightly-next publish gate.

A NEXT nightly shipped an app that crashed on a first launch (Home's first-run
panel, 4b5c86ed, fixed by 1daea603) while every static check passed. This
launches the exact app the feed would offer as a first install would: an empty
HOME (CFFIXED_USER_HOME too, so Application Support, caches and logs start
empty), no defaults, an empty TMPDIR and none of the runner's environment. It
passes when

  1. the app stays up SECONDS (default 30) after launch, with no crash report
     and no recorded uncaught exception (run.exception), and
  2. the app rendered Home's first-run view: the release control socket's
     snapshot.get shows a visible window with Home's page tab (`home-dock`,
     HomeDock.page: the Chief conversation, whose empty state is the first-run
     panel) selected, and the launch marks the app streams to
     CMUX_NEXT_LAUNCH_MARKS_FD (LaunchMarkSink) include
     first_window_frame_committed.

The app keeps its defaults in the account's preferences whatever HOME says
(cfprefsd), so the run holds a per-bundle lock, sets the domain aside
(defaults export, then delete) and puts it back afterwards: the app starts with
no defaults and the account's are as before once the run ends.

Usage: fresh_home_launch_smoke.py (--app APP | --dmg DMG) [--seconds S]
           [--startup-timeout S] [--out DIR]

--dmg copies the app out of the DMG (mounted read-only, detached at once);
--app copies it too. Every process the run starts runs from its private root
(/tmp/cmux-fresh-*): cleanup stops the app, then each process of this user
whose command line names that root, by exact PID, and deletes the root. --out
keeps the evidence: report.json (verdict, launch marks, snapshot), the app's
output, its crash files (run.exception, the .ips) and a screenshot when the
runner may take one (evidence only, never the verdict).

Exit 0: passed. 1: the app crashed, exited or never rendered Home. 2: usage.
3: the smoke could not run (no app, no GUI session, a signing keychain still
present). A publish gate treats anything but 0 as a failure: a build that was
never launched is never published.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PASS, FAIL, USAGE, CANNOT_RUN = 0, 1, 2, 3
# A caller that drives the rendered app further (scripts/ci/stable_next_ui_journey.py) sets this to
# journey(process, socket_path, env, app, out, report) -> list of failures. It runs once Home has
# rendered and the app is still up, before the app is stopped; it may quit the app itself.
AFTER_RENDER = None
RENDER_MARK = "first_window_frame_committed"
HOME_PAGE = "home-dock"


class CannotRun(Exception):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def signing_keychains_present() -> list[str]:
    """scripts/ci/lib/signing-runtime-guard.sh: bundle code never runs while this job holds a signing keychain."""
    state = os.environ.get("CMUX_SIGNING_KEYCHAIN_STATE_DIR") or (
        os.path.join(os.environ["RUNNER_TEMP"], "cmux-signing-keychain") if os.environ.get("RUNNER_TEMP") else "")
    if not state or not os.path.isdir(state):
        return []
    return sorted(name[:-len(".password")] for name in os.listdir(state) if name.endswith(".password"))


def gui_session_problem() -> str | None:
    """A Mac process outside an Aqua session gets no working window server (CEF hangs the main thread)."""
    if sys.platform != "darwin" or os.environ.get("CMUX_FRESH_SMOKE_SKIP_SESSION_CHECK") == "1":
        return None
    try:
        name = subprocess.run(["launchctl", "managername"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "launchctl managername did not answer"
    return None if name == "Aqua" else f"this process is in a {name or 'unknown'} session, not Aqua (no GUI)"


def bundle_info(app: Path) -> tuple[str, str]:
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    return info["CFBundleIdentifier"], info["CFBundleExecutable"]


def copy_app(source: Path, root: Path) -> Path:
    dest = root / "app" / source.name
    dest.parent.mkdir(exist_ok=True)
    if shutil.which("ditto"):
        subprocess.run(["ditto", str(source), str(dest)], check=True, timeout=600)
    else:
        shutil.copytree(source, dest, symlinks=True)
    return dest


def copy_app_from_dmg(dmg: Path, root: Path) -> Path:
    mount = root / "mnt"
    mount.mkdir()
    try:
        subprocess.run(["hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=300)
        apps = sorted(mount.glob("*.app"))
        if not apps:
            raise CannotRun(f"no app in {dmg}")
        return copy_app(apps[0], root)
    finally:
        detach(mount)


def detach(mount: Path) -> None:
    """Detach the image if it is attached (a timed-out attach may still finish), forcing it if needed; never raises."""
    if not os.path.ismount(mount):
        return
    for args in (["hdiutil", "detach", str(mount)], ["hdiutil", "detach", "-force", str(mount)]):
        try:
            if subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120).returncode == 0:
                return
        except (OSError, subprocess.SubprocessError):
            pass
    log(f"warning: could not detach {mount}")


def fresh_env(root: Path, socket_path: Path, marks_fd: int) -> dict[str, str]:
    """No runner variable reaches the app (no token, no key, no CMUX_* routing): only these."""
    home = root / "h"
    for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"):
        (home / sub).mkdir(parents=True, exist_ok=True)
    (root / "t").mkdir(exist_ok=True)
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    return {
        "HOME": str(home),
        "CFFIXED_USER_HOME": str(home),
        "TMPDIR": str(root / "t") + "/",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": user,
        "LOGNAME": user,
        "LANG": "en_US.UTF-8",
        "SHELL": "/bin/zsh",
        "CMUX_NEXT_SOCKET_PATH": str(socket_path),
        "CMUX_NEXT_SOCKET_MODE": "allowAll",
        "CMUX_NEXT_NO_ACTIVATE": "1",
        "CMUX_NEXT_LAUNCH_MARKS_FD": str(marks_fd),
    }


class DefaultsAside:
    """The bundle's defaults domain, set aside for the run under a per-bundle lock and put back after it.

    `defaults export` of a domain that does not exist writes an empty dictionary, so the copy always
    exists and putting it back also removes whatever the app wrote. The copy lives beside the lock,
    outside the run's temp root, so a harness that is killed mid-run (a step timeout) leaves it for the
    next run to put back before it sets anything aside. Any export, delete or import that fails is
    CannotRun: the gate fails closed and the copy stays for the next run."""

    def __init__(self, bundle_id: str, root: Path):
        self.bundle_id = bundle_id
        self.tool = os.environ.get("CMUX_FRESH_SMOKE_DEFAULTS_TOOL") or shutil.which("defaults")
        lock_dir = os.environ.get("CMUX_FRESH_SMOKE_LOCK_DIR") or "/tmp"
        stem = os.path.join(lock_dir, f"cmux-fresh-smoke-{bundle_id}")
        self.lock_path = stem + ".lock"
        self.backup = Path(stem + ".aside.plist")
        self.lock = None

    def defaults(self, *args: str) -> int:
        return subprocess.run([self.tool, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=60).returncode

    def holds_keys(self) -> bool:
        """Whether the domain still has any key (cfprefsd answers an emptied domain as {}, exit 0)."""
        probe = self.backup.with_name(self.backup.name + ".probe")
        try:
            if self.defaults("export", self.bundle_id, str(probe)) != 0 or not probe.exists():
                return True  # cannot tell: treat it as not cleared
            try:
                with open(probe, "rb") as handle:
                    return bool(plistlib.load(handle))
            except Exception:
                return True
        finally:
            probe.unlink(missing_ok=True)

    def clear(self) -> None:
        """Delete the domain (it fails when there is nothing to delete) and confirm it holds no key."""
        self.defaults("delete", self.bundle_id)
        if self.holds_keys():
            raise CannotRun(f"could not delete the {self.bundle_id} defaults; the copy stays in {self.backup}")

    def put_back(self) -> None:
        """Restore the copy set aside (this run's, or one a killed run left), then forget it."""
        if not self.backup.exists():
            return
        self.clear()
        if self.defaults("import", self.bundle_id, str(self.backup)) != 0:
            raise CannotRun(f"could not put back the {self.bundle_id} defaults; they stay set aside in {self.backup}")
        self.backup.unlink()

    def __enter__(self):
        if not self.tool:
            log("note: no defaults tool here; the app's defaults are not set aside")
            return self
        self.lock = open(self.lock_path, "a")
        wait = float(os.environ.get("CMUX_FRESH_SMOKE_LOCK_WAIT_SECONDS", 900))
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.lock.close()
                    raise CannotRun(f"another fresh-home smoke of {self.bundle_id} held {self.lock_path} for {wait:.0f}s")
                time.sleep(1)
        try:
            if self.backup.exists():
                log(f"note: putting back the {self.bundle_id} defaults an earlier smoke left set aside")
                self.put_back()
            partial = self.backup.with_name(self.backup.name + ".partial")
            partial.unlink(missing_ok=True)
            if self.defaults("export", self.bundle_id, str(partial)) != 0 or not partial.exists():
                partial.unlink(missing_ok=True)
                raise CannotRun(f"could not export the {self.bundle_id} defaults; nothing was set aside")
            os.replace(partial, self.backup)
            self.clear()  # on failure the copy stays: the delete may have half-run
        except BaseException:
            self.release()
            raise
        return self

    def release(self) -> None:
        if self.lock is not None:
            fcntl.flock(self.lock, fcntl.LOCK_UN)
            self.lock.close()
            self.lock = None

    def __exit__(self, *_exc):
        if not self.tool:
            return False
        try:
            self.put_back()
        finally:
            self.release()
        return False


def snapshot(socket_path: Path, timeout: float = 5.0) -> dict | None:
    """snapshot.get over the release control socket (newline-delimited JSON), None while it does not answer."""
    if not socket_path.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(socket_path))
            sock.sendall(b'{"id": 1, "method": "snapshot.get", "params": {}}\n')
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    return None
                buffer += chunk
        reply = json.loads(buffer.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None
    result = reply.get("result")
    return result if isinstance(result, dict) else None


def visible_windows(snap: dict | None) -> int:
    windows = ((snap or {}).get("topology") or {}).get("windows") or []
    return sum(1 for window in windows if isinstance(window, dict) and window.get("visible"))


def home_tab(snap: dict | None) -> dict | None:
    """Home's page tab, selected in a pane of a workspace a visible window shows; None otherwise."""
    topology = (snap or {}).get("topology") or {}
    shown = {window.get("workspace") for window in topology.get("windows") or []
             if isinstance(window, dict) and window.get("visible")}
    for workspace in topology.get("workspaces") or []:
        if not isinstance(workspace, dict) or workspace.get("id") not in shown:
            continue
        for screen in workspace.get("screens") or []:
            for pane in (screen or {}).get("panes") or []:
                for tab in (pane or {}).get("tabs") or []:
                    if isinstance(tab, dict) and tab.get("page") == HOME_PAGE and tab.get("id") == pane.get("selected_tab"):
                        return tab
    return None


def read_marks(path: Path) -> dict[str, float]:
    marks: dict[str, float] = {}
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return marks
    for line in text.splitlines():
        name, _, ms = line.rpartition(" ")
        try:
            marks.setdefault(name, float(ms))
        except ValueError:
            continue
    return marks


def crash_reports(directory: Path, executable: str, since: float) -> list[Path]:
    if not directory.is_dir():
        return []
    found = []
    for path in directory.iterdir():
        if path.suffix not in (".ips", ".crash") or not path.name.startswith(f"{executable}-"):
            continue
        try:
            if path.stat().st_mtime >= since:
                found.append(path)
        except OSError:
            continue
    return sorted(found)


def pids_under(root: Path) -> list[int]:
    """This user's processes whose command line names the run's private root, never by name."""
    real = os.path.realpath(root)
    try:
        out = subprocess.run(["ps", "-ww", "-o", "pid=", "-o", "args=", "-U", str(os.getuid())],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in out.splitlines():
        pid, _, args = line.strip().partition(" ")
        if pid.isdigit() and int(pid) != os.getpid() and (f"{root}/" in args or f"{real}/" in args):
            pids.append(int(pid))
    return pids


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def stop_child(process: subprocess.Popen, grace: float = 5.0) -> None:
    """The app this run started: SIGTERM, reaped within GRACE, else SIGKILL."""
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=grace)


def stop(pids: list[int], grace: float = 5.0) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and any(alive(pid) for pid in pids):
        time.sleep(0.1)
    for pid in pids:
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass


def system_log_errors(pid: int, since: float, limit: int = 40) -> list[str]:
    """The app's error and fault lines in the unified log (where AppKit reports an assertion), best effort."""
    if sys.platform != "darwin" or not os.path.exists("/usr/bin/log"):
        return []
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    try:
        out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--predicate",
                              f"processID == {int(pid)} AND (messageType == error OR messageType == fault)"],
                             capture_output=True, text=True, timeout=90).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    lines = [line[:400] for line in out.splitlines() if f"[{pid}:" in line and "com.apple.network" not in line]
    keyed = [line for line in lines if "Assertion failure" in line or "xception" in line]
    return (keyed or lines)[:limit]


def screenshot(out: Path) -> str | None:
    if shutil.which("screencapture") is None:
        return None
    path = out / "fresh-home.png"
    try:
        ok = subprocess.run(["screencapture", "-x", str(path)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=20).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    return str(path) if ok and path.exists() else None


def watch(process: subprocess.Popen, marks_fd: int, marks_path: Path, socket_path: Path,
          seconds: float, startup_timeout: float) -> dict:
    """Until SECONDS have passed with Home rendered (or STARTUP_TIMEOUT without it), or the app exits."""
    os.set_blocking(marks_fd, False)
    started = time.monotonic()
    snap, rendered_at, status = None, None, None
    with open(marks_path, "ab") as marks:
        while True:
            try:
                chunk = os.read(marks_fd, 1 << 16)
                if chunk:
                    marks.write(chunk)
                    marks.flush()
            except (BlockingIOError, OSError):
                pass
            elapsed = time.monotonic() - started
            status = process.poll()
            if status is not None:
                break
            if rendered_at is None:
                snap = snapshot(socket_path) or snap
                if home_tab(snap) and RENDER_MARK in read_marks(marks_path):
                    rendered_at = elapsed
                    log(f"ok: Home rendered in a visible window {elapsed:.1f}s after launch")
            if elapsed >= seconds and (rendered_at is not None or elapsed >= startup_timeout):
                break
            time.sleep(0.25)
    return {"snapshot": snap, "rendered_at": rendered_at, "exit": status,
            "seconds_up": round(time.monotonic() - started, 1)}


def run(args: argparse.Namespace, root: Path, report: dict) -> int:
    present = signing_keychains_present()
    if present:
        raise CannotRun(f"a CI signing keychain is still present ({' '.join(present)}); bundle code never runs beside it")
    problem = gui_session_problem()
    if problem:
        raise CannotRun(problem)
    source = Path(args.dmg or args.app)
    if not source.exists():
        raise CannotRun(f"{source} does not exist")
    app = copy_app_from_dmg(source, root) if args.dmg else copy_app(source, root)
    if not (app / "Contents" / "Info.plist").is_file():
        raise CannotRun(f"no app bundle at {app}")
    bundle_id, executable = bundle_info(app)
    report.update(bundle_id=bundle_id, executable=executable)
    out = Path(args.out) if args.out else None
    socket_path, marks_path = root / "s.sock", root / "marks"
    diagnostics = Path(os.environ.get("CMUX_FRESH_SMOKE_DIAGNOSTIC_DIR")
                       or os.path.expanduser("~/Library/Logs/DiagnosticReports"))
    with DefaultsAside(bundle_id, root):
        marks_read, marks_write = os.pipe()
        env = fresh_env(root, socket_path, marks_write)
        log(f"==> fresh-home launch of {bundle_id} ({app}), HOME={env['HOME']}, {args.seconds:.0f}s")
        launched_wall = time.time() - 1
        with open(root / "app.log", "wb") as app_log:
            process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable), "-ApplePersistenceIgnoreState", "YES"],
                                       env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                       stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
        report["pid"] = process.pid
        os.close(marks_write)
        try:
            seen = watch(process, marks_read, marks_path, socket_path, args.seconds,
                         max(args.seconds, args.startup_timeout))
        finally:
            os.close(marks_read)
        report.update(seen)
        report["marks"] = read_marks(marks_path)
        report["home_tab"] = home_tab(seen["snapshot"])
        if out is not None and seen["exit"] is None:
            report["screenshot"] = screenshot(out)
        journey_failures = []
        if AFTER_RENDER is not None and seen["exit"] is None and seen["rendered_at"] is not None:
            journey_failures = list(AFTER_RENDER(process, socket_path, env, app, out, report) or [])
        stop_child(process)
        stop(pids_under(root))
    # ReportCrash writes the .ips a few seconds after the process died.
    wait = float(os.environ.get("CMUX_FRESH_SMOKE_CRASH_REPORT_WAIT_SECONDS", 10))
    deadline = time.monotonic() + (wait if seen["exit"] is not None else 0)
    crashes = crash_reports(diagnostics, executable, launched_wall)
    while not crashes and time.monotonic() < deadline:
        time.sleep(1)
        crashes = crash_reports(diagnostics, executable, launched_wall)
    exceptions = sorted((root / "h").rglob("run.exception"))
    report["crash_reports"] = [str(path) for path in crashes]
    report["run_exceptions"] = [str(path) for path in exceptions]
    if out is not None:
        for path in [*crashes, *exceptions]:
            shutil.copyfile(path, out / path.name)
    failures = list(journey_failures)
    status, elapsed = seen["exit"], seen["seconds_up"]
    if status is not None:
        how = f"signal {-status}" if status < 0 else f"status {status}"
        failures.append(f"the app exited ({how}) {elapsed:.1f}s after launch")
    if crashes:
        failures.append(f"crash report: {', '.join(path.name for path in crashes)}")
    if exceptions:
        failures.append("the app recorded an uncaught exception (run.exception)")
    if seen["rendered_at"] is None and status is None:
        failures.append(f"Home did not render within {elapsed:.0f}s (visible windows {visible_windows(seen['snapshot'])}, "
                        f"Home tab {'selected' if report['home_tab'] else 'not selected'}, "
                        f"{RENDER_MARK} {'seen' if RENDER_MARK in report['marks'] else 'missing'})")
    if not failures:
        report["verdict"] = "pass"
        log(f"==> fresh-home launch smoke OK: up {elapsed:.0f}s, Home at {seen['rendered_at']:.1f}s, no crash")
        return PASS
    errors = system_log_errors(report["pid"], launched_wall)
    if errors:
        report["system_log_errors"] = errors
        log("--- the app's errors in the system log (an uncaught exception or assertion names itself here)\n"
            + "\n".join(errors))
    for path in exceptions:
        log(f"--- {path.name}\n{path.read_text(errors='replace')[:4000]}")
    for path in crashes:
        log(f"--- {path.name} (first 6000 bytes)\n{path.read_text(errors='replace')[:6000]}")
    tail = [line for line in (root / "app.log").read_text(errors="replace").splitlines() if not line.startswith("objc[")]
    log("--- app output (last 60 lines)\n" + "\n".join(tail[-60:]))
    for failure in failures:
        log(f"FAIL: {failure}")
    report["verdict"], report["failures"] = "fail", failures
    return FAIL


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app")
    source.add_argument("--dmg")
    parser.add_argument("--seconds", type=float, default=30.0, help="how long the app must stay up")
    parser.add_argument("--startup-timeout", type=float, default=90.0, help="how long Home may take to render")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    # Evidence stays readable by the runner account when this runs as the console user (a sudo hop).
    os.umask(0o022)
    if args.out:
        os.makedirs(args.out, exist_ok=True)
    # A short root: the socket path must fit sun_path (104 bytes).
    root = Path(tempfile.mkdtemp(prefix="cmux-fresh-", dir="/tmp"))
    report: dict = {"root": str(root)}

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    status = CANNOT_RUN
    try:
        status = run(args, root, report)
    except (CannotRun, OSError, subprocess.SubprocessError) as error:
        log(f"CANNOT RUN: {error}")
        report.update(verdict="cannot-run", failures=[str(error)])
        status = CANNOT_RUN
    finally:
        if report.get("pid"):
            stop([report["pid"]])
        stop(pids_under(root))
        if args.out:
            if (root / "app.log").exists():
                shutil.copyfile(root / "app.log", Path(args.out) / "app.log")
            with open(Path(args.out) / "report.json", "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
        left = pids_under(root)
        if left:
            log(f"warning: processes still under {root}: {left}")
        shutil.rmtree(root, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
