#!/usr/bin/env python3
"""Startup paths of the quit gamut (quit_gamut_check.py) that are not a quit (CMUX-629).

Leo, 2026-11-17: "ok but 1. the whole point is a fresh launch somebody installing and launching from scratch" and
"i mean across all startups we shoudl be fast ofc". Each path gives rows with the gamut's fields (first_window_ms,
settled_ms, prior_chat_front_ms, prior_chat_live_ms, warm_switch_ms; t0 = the process's start):

  fresh-install  a brand-new user's first launch. Per round: a new copy of the DMG file gets the quarantine a browser
                 writes (0083;<hex time>;Safari;<uuid>), is attached (checksum verified, as a Finder double-click
                 does), the app is copied out (ditto keeps the quarantine the image gives its files) and the image
                 detached; the disk cache is purged when `sudo -n purge` is allowed; then `open -n` the copy with a
                 new HOME (CFFIXED_USER_HOME, a login keychain, the bundle's defaults set aside), as a double-click.
                 `defaults_before` is the domain just before the `open` (its key names, and the value of each
                 cmuxNext.launchSnapshotPath.* key) and `launch_snapshot_applied` whether the launch marked it: the
                 row fails when the domain held any key or the mark is there. A new HOME is not enough: cfprefsd
                 keeps the bundle's defaults in the account's real preferences, so an earlier run's leak in.
                 The first-launch "downloaded from the Internet" prompt is answered Open (cua-driver, else System
                 Events) and the time it waited for a person is kept apart (prompt_wait_ms). Also from the `open`:
                 open_to_spawn_ms, open_to_first_window_ms, open_to_settled_ms; Home or the first-run page in a
                 visible window (home_ms); and from the unified log, syspolicyd's and XProtect's first and last event
                 after the `open` (gate.syspolicyd_span_ms, gate.xprotect_span_ms) with the lines naming an
                 assessment, scan, ticket, prompt or translocation. No new macOS user: that needs root and a login.
  cold-cache     the reopen after a quit with the disk cache purged (`sudo -n purge`). A fleet step cannot reboot,
                 so this approximates a first launch after a reboot; without passwordless sudo the bundle is replaced
                 by a fresh copy instead (its files are in no page cache, but a new copy also pays its first exec):
                 the row's `cold.how` says which.
  loaded         the reopen after a quit under a fixed synthetic load: half the CPUs busy (`yes`) and a writer of
                 256 MiB files with a sync between, until the reopen settled; the row's `load` records the level.

    startup_paths.py --self-test     the parts that need no Mac
"""
from __future__ import annotations

import datetime
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

QUARANTINE_FLAGS = 0x0083  # what Safari writes: downloaded, by a browser, quarantined
GATE_LOG = ('process == "syspolicyd" OR process BEGINSWITH[c] "xprotect" OR process == "amfid" '
            'OR process == "trustd" OR process == "lsd" OR process == "CoreServicesUIAgent" '
            'OR subsystem BEGINSWITH "com.apple.syspolicy" OR subsystem BEGINSWITH "com.apple.xprotect" '
            'OR subsystem == "com.apple.launchservices" OR eventMessage CONTAINS[c] "translocat"')
GATE_WORDS = ("assess", "xprotect", "scan", "ticket", "notar", "prompt", "quarantine", "translocat", "gatekeeper",
              "malware", "yara", "evaluat")
SETTLE_MARKS = ("first_window_frame_committed", "reveal.sidebar", "reveal.tabs")
CUA = Path("~/.local/bin/cua-driver").expanduser()
STARTUP_S = 150.0
SETTLE_GRACE_S = 10.0


def run_text(args: list[str], timeout: float = 120) -> tuple[int, str]:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return -1, f"error: {error}"
    return done.returncode, (done.stdout + done.stderr).strip()


def quarantine_value(now: float | None = None, ident: str | None = None) -> str:
    stamp = int(time.time() if now is None else now)
    return f"{QUARANTINE_FLAGS:04x};{stamp:x};Safari;{(ident or str(uuid.uuid4())).upper()}"


def xattr_quarantine(path: Path) -> str | None:
    code, out = run_text(["xattr", "-p", "com.apple.quarantine", str(path)], timeout=30)
    return out if code == 0 else None


def purge() -> str:
    code, out = run_text(["sudo", "-n", "/usr/sbin/purge"], timeout=300)
    return "purged" if code == 0 else f"not purged ({out[:120] or code})"


def settled(marks: dict) -> float | None:
    """The gamut's settled for a launch with no prior chat: the window, sidebar, tab strips and the front content
    (Home's reveal, or a pane's) all in, as ms since the process started."""
    needed = [marks.get(k) for k in SETTLE_MARKS] + [marks.get("reveal.home", marks.get("reveal.pane"))]
    return max(needed) if all(v is not None for v in needed) else None


# ---- fresh-install ---------------------------------------------------------------------------

def own_executables() -> list[tuple[int, str]]:
    """(pid, executable path) of this user's processes (macOS `ps -o comm` is the full path)."""
    code, out = run_text(["ps", "-ww", "-U", str(os.getuid()), "-o", "pid=", "-o", "comm="], timeout=30)
    rows = []
    for line in out.splitlines() if code == 0 else []:
        pid, _, path = line.strip().partition(" ")
        if pid.isdigit():
            rows.append((int(pid), path.strip()))
    return rows


def app_pid(executable: str, known: set[int]) -> tuple[int, str] | None:
    """The new process of the app's main executable, from any path (a translocated copy runs from another one)."""
    tail = f".app/Contents/MacOS/{executable}"
    fresh = [(pid, path) for pid, path in own_executables() if path.endswith(tail) and pid not in known]
    return max(fresh) if fresh else None


def cua(tool: str, args: dict) -> dict:
    code, out = run_text([str(CUA), "call", tool, json.dumps(args)], timeout=60)
    try:
        return json.loads(out) if code == 0 else {"error": out[-300:]}
    except ValueError:
        return {"error": out[-300:]}


def walk(obj, pred, out=None) -> list:
    out = [] if out is None else out
    if pred(obj):
        out.append(obj)
    for value in obj.values() if isinstance(obj, dict) else obj if isinstance(obj, list) else ():
        walk(value, pred, out)
    return out


def answer_prompt() -> dict | None:
    """When the first-launch prompt is on screen, press its Open button; None while there is none. cua-driver holds
    the Accessibility grant a measure step lacks; System Events only without it (a first System Events call may ask
    for the Automation grant in a dialog of its own)."""
    code, out = run_text(["pgrep", "-x", "-U", str(os.getuid()), "CoreServicesUIAgent"], timeout=10)
    agents = [int(p) for p in out.split() if p.isdigit()] if code == 0 else []
    if not agents:
        return None
    if CUA.exists():
        wins = [w for w in walk(cua("list_windows", {"pid": agents[0]}), lambda o: isinstance(o, dict) and "window_id" in o)
                if w.get("is_on_screen")]
        for win in wins:
            state = cua("get_window_state", {"pid": agents[0], "window_id": win["window_id"],
                                             "include_screenshot": False, "max_depth": 30, "max_elements": 400})
            buttons = [e for e in walk(state, lambda o: isinstance(o, dict) and "frame" in o and "role" in o)
                       if "button" in str(e.get("role", "")).lower()
                       and str(e.get("label") or e.get("title") or "").strip() == "Open"]
            if buttons:
                f = buttons[0]["frame"]
                click = cua("click", {"x": f["x"] + f["w"] / 2, "y": f["y"] + f["h"] / 2, "scope": "desktop"})
                return {"by": "cua-driver", "click": None if click.get("error") else click}
        return {"by": "cua-driver", "click": None, "windows": len(wins)} if wins else None
    script = ('tell application "System Events" to tell process "CoreServicesUIAgent"\n'
              'if (count of windows) is 0 then return "none"\n'
              'click button "Open" of window 1\nreturn "clicked"\nend tell')
    code, out = run_text(["osascript", "-e", script], timeout=20)
    if code == 0 and out == "none":
        return None
    if code != 0:  # no grant: it cannot see a prompt, so none is counted
        return {"by": "system-events", "shown": False, "error": out[-200:]}
    return {"by": "system-events", "click": out}


def parse_log_time(stamp: str) -> float | None:
    """A unified log ndjson timestamp (2026-11-17 00:40:01.123456-0800) as epoch seconds."""
    try:
        return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except (TypeError, ValueError):
        return None


def gate_summary(lines: list[str], opened_wall: float) -> dict:
    """Per process after the `open`: events and the first and last event's ms; the lines naming a gate word."""
    procs: dict[str, dict] = {}
    words: list[str] = []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        at = parse_log_time(event.get("timestamp", "")) if isinstance(event, dict) else None
        if at is None or at < opened_wall:
            continue
        ms = round((at - opened_wall) * 1000)
        who = Path(event.get("processImagePath") or "?").name
        if who.lower().startswith("xprotect"):
            who = "XProtect"
        row = procs.setdefault(who, {"n": 0, "first_ms": ms, "last_ms": ms})
        row["n"] += 1
        row["first_ms"], row["last_ms"] = min(row["first_ms"], ms), max(row["last_ms"], ms)
        message = str(event.get("eventMessage") or "")
        if any(word in message.lower() for word in GATE_WORDS):
            words.append(f"+{ms}ms {who}: {message[:220]}")
    span = {who: r["last_ms"] - r["first_ms"] for who, r in procs.items()}
    return {"by_process": procs, "syspolicyd_span_ms": span.get("syspolicyd"), "xprotect_span_ms": span.get("XProtect"),
            "lines": words[:200]}


def gate_log(opened_wall: float, until_wall: float) -> dict:
    fmt = "%Y-%m-%d %H:%M:%S"
    code, out = run_text(["/usr/bin/log", "show", "--style", "ndjson", "--info", "--debug",
                          "--start", time.strftime(fmt, time.localtime(opened_wall - 1)),
                          "--end", time.strftime(fmt, time.localtime(until_wall + 1)), "--predicate", GATE_LOG],
                         timeout=300)
    return {**gate_summary(out.splitlines(), opened_wall), "log_exit": code}


def install(smoke, dmg: Path, root: Path) -> tuple[Path, dict]:
    """A new copy of the DMG file with a browser's quarantine, attached, its app copied out, detached."""
    image = root / dmg.name
    shutil.copyfile(dmg, image)
    value = quarantine_value()
    subprocess.run(["xattr", "-w", "com.apple.quarantine", value, str(image)], check=True, timeout=30)
    info: dict = {"dmg_quarantine": xattr_quarantine(image)}
    mount = root / "mnt"
    mount.mkdir()
    try:
        started = time.monotonic()
        subprocess.run(["hdiutil", "attach", str(image), "-nobrowse", "-readonly", "-noautofsck", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=600)
        info["mount_ms"] = round((time.monotonic() - started) * 1000)
        apps = sorted(mount.glob("*.app"))
        if not apps:
            raise smoke.CannotRun("no app in the DMG")
        info["mounted_app_quarantine"] = xattr_quarantine(apps[0])
        dest = root / "Applications" / apps[0].name
        dest.parent.mkdir()
        started = time.monotonic()
        subprocess.run(["ditto", str(apps[0]), str(dest)], check=True, timeout=900)
        info["copy_ms"] = round((time.monotonic() - started) * 1000)
    finally:
        smoke.detach(mount)
    image.unlink(missing_ok=True)
    info["app_quarantine"] = xattr_quarantine(dest)
    if info["app_quarantine"] is None:
        # The image did not hand its quarantine to the copy: put it on the bundle, as a browser download's copy has.
        subprocess.run(["xattr", "-w", "com.apple.quarantine", value, str(dest)], check=True, timeout=30)
        info["app_quarantine"], info["quarantine_set_by_harness"] = xattr_quarantine(dest), True
    return dest, info


def fresh_install_round(smoke, dmg: Path, index: int, prepare_env=None, seconds: float = 6.0) -> dict:
    """One brand-new user's install and first launch (the module's fresh-install), as a gamut row."""
    root = Path(tempfile.mkdtemp(prefix="cmux-gfi-", dir="/tmp"))
    row: dict = {"path": "fresh-install", "state": "first-run", "fresh_round": index, "failures": [],
                 "prior_chat_front_ms": None, "prior_chat_live_ms": None, "warm_switch_ms": None}
    try:
        app, row["install"] = install(smoke, dmg, root)
        bundle_id, executable = smoke.bundle_info(app)
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            import plistlib
            info = plistlib.load(handle)
        row["build"] = {"version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                        "commit": info.get("CMUXCommit")}
        row["install"]["purge"] = purge()
        with smoke.DefaultsAside(bundle_id, root):
            row.update(open_launch(smoke, root, app, executable, bundle_id, seconds, prepare_env))
    except (smoke.CannotRun, OSError, subprocess.SubprocessError) as error:
        row["failures"].append(f"could not install: {error}")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if not row["failures"]:
        row["failures"] += defaults_leak_failures(row)
        if row.get("first_window_ms") is None:
            row["failures"].append("no first window frame")
        if row.get("home_ms") is None:
            row["failures"].append(f"Home or the first-run page never showed within {STARTUP_S:.0f} s")
        if row.get("settled_ms") is None:
            row["failures"].append(f"not settled (marks {sorted(row.get('marks') or {})[:40]})")
    return row


def defaults_leak_failures(row: dict) -> list[str]:
    """A fresh install's first launch must start with an empty defaults domain and must not apply a launch snapshot:
    a key in `defaults_before` was left by an earlier launch of the same bundle id (cfprefsd keeps the domain in the
    account's real preferences, whatever HOME and CFFIXED_USER_HOME say), and `launch_snapshot_applied` means the
    launch opened a snapshot it did not write (an earlier run's `cmuxNext.launchSnapshotPath.<session>`)."""
    failures = []
    before = row.get("defaults_before") or {}
    if before.get("error"):
        failures.append(f"could not read the defaults domain before the launch: {before['error']}")
    elif before.get("keys"):
        paths = before.get("launch_snapshot_paths") or {}
        failures.append(f"the defaults domain held {len(before['keys'])} keys before a fresh install's launch "
                        f"({', '.join(before['keys'][:8])})" + (f"; snapshot paths {json.dumps(paths)}" if paths else ""))
    if row.get("launch_snapshot_applied"):
        failures.append("a fresh install's launch applied a launch snapshot (launch_snapshot_applied), one an earlier run wrote")
    return failures


def open_launch(smoke, root: Path, app: Path, executable: str, bundle_id: str, seconds: float, prepare_env) -> dict:
    """`open -n` APP with a new HOME under ROOT, as a double-click; its marks arrive on a FIFO
    (CMUX_NEXT_LAUNCH_MARKS_PATH), each with its arrival time, so the process's start is known on this clock."""
    env = smoke.fresh_env(root, root / "s.sock", 0)
    env.pop("CMUX_NEXT_LAUNCH_MARKS_FD", None)
    env.pop("CMUX_NEXT_NO_ACTIVATE", None)  # a double-click activates the app
    if prepare_env is not None:
        prepare_env(env)
    fifo = root / "marks.fifo"
    env["CMUX_NEXT_LAUNCH_MARKS_PATH"] = str(fifo)
    os.mkfifo(fifo, 0o600)
    read_fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    hold_fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)  # no end of file before the app opens its end
    known = {pid for pid, _ in own_executables()}
    command = ["/usr/bin/open", "-n", "-a", str(app)] + [a for k, v in env.items() for a in ("--env", f"{k}={v}")]
    command += ["--args", "-ApplePersistenceIgnoreState", "YES"]
    marks: dict[str, float] = {}
    arrivals: dict[str, float] = {}
    prompt: dict = {}
    before = smoke.defaults_before(bundle_id)  # just before the `open`, inside the round's DefaultsAside
    found, home_at, snap, buffer, exited = None, None, None, b"", False
    next_look = 0.5
    opened_wall, opened = time.time(), time.monotonic()
    opener = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        while True:
            elapsed = time.monotonic() - opened
            try:
                buffer += os.read(read_fd, 1 << 16)
            except (BlockingIOError, OSError):
                pass
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                name, _, ms = line.decode(errors="replace").rpartition(" ")
                try:
                    marks.setdefault(name, round(float(ms)))
                    arrivals.setdefault(name, elapsed)
                except ValueError:
                    pass
            if found is None:
                found = app_pid(executable, known)
            elif not smoke.alive(found[0]):
                exited = True
                break
            if "main_start" not in marks and not prompt.get("clicked_ms") and elapsed >= next_look:
                answer = answer_prompt()
                next_look = elapsed + 0.5
                if answer is not None and answer.get("shown", True):
                    prompt.setdefault("shown_ms", round(elapsed * 1000))
                    prompt["answer"] = answer
                    if answer.get("click"):
                        prompt["clicked_ms"] = round((time.monotonic() - opened) * 1000)
                elif answer is not None:
                    prompt.setdefault("look_error", answer.get("error"))
            if home_at is None and "first_window_frame_committed" in marks:
                snap = smoke.snapshot(root / "s.sock", timeout=2.0) or snap
                if smoke.home_rendered(snap, marks):
                    home_at = elapsed
            if home_at is not None and elapsed >= home_at + seconds and (
                    settled(marks) is not None or elapsed >= home_at + SETTLE_GRACE_S):
                break
            if home_at is None and elapsed >= STARTUP_S:
                break
            time.sleep(0.05 if "first_window_frame_committed" not in marks else 0.25)
    finally:
        until_wall = time.time()
        pids = set(smoke.own_pids(root))
        if found is not None:
            bundle = found[1].split("/Contents/MacOS/")[0]
            pids |= {found[0]} | {pid for pid, args in smoke.user_processes() if f"{bundle}/" in args}
        smoke.stop(sorted(pids))
        for fd in (read_fd, hold_fd):
            os.close(fd)
        try:
            opener.wait(timeout=10)
        except subprocess.TimeoutExpired:
            opener.kill()
    record = root / "h" / "Library" / "Application Support" / bundle_id / "launch-times.jsonl"
    try:
        launch_times = json.loads(record.read_text().splitlines()[-1])
    except (OSError, ValueError, IndexError):
        launch_times = None
    out = timings(marks, arrivals, home_at, prompt)
    out.update(exited=exited, pid=found[0] if found else None,
               translocated=bool(found and "/AppTranslocation/" in found[1]), prompt=prompt, marks=marks,
               first_run=smoke.FIRST_RUN_MARK in marks, launch_times=launch_times, defaults_before=before,
               launch_snapshot_applied="launch_snapshot_applied" in marks,
               open_stderr=opener.stderr.read().decode(errors="replace")[-400:] if opener.stderr else "")
    out["gate"] = gate_log(opened_wall, until_wall)
    return out


def timings(marks: dict, arrivals: dict, home_at: float | None, prompt: dict) -> dict:
    """The gamut's fields (ms since the process started) and the same from the `open` (open_to_*)."""
    spawn = round(arrivals["main_start"] * 1000 - marks["main_start"]) if "main_start" in marks and "main_start" in arrivals else None
    first, settle = marks.get("first_window_frame_committed"), settled(marks)
    home = round(home_at * 1000) - spawn if home_at is not None and spawn is not None else None
    wait = prompt["clicked_ms"] - prompt["shown_ms"] if prompt.get("clicked_ms") is not None else None
    def from_open(ms):
        return spawn + ms if spawn is not None and ms is not None else None
    return {"pre_main_ms": marks.get("main_start"), "first_window_ms": first, "settled_ms": settle, "home_ms": home,
            "open_to_spawn_ms": spawn, "open_to_first_window_ms": from_open(first),
            "open_to_settled_ms": from_open(settle), "open_to_home_ms": round(home_at * 1000) if home_at is not None else None,
            "prompt_shown_ms": prompt.get("shown_ms"), "prompt_wait_ms": wait}


# ---- cold-cache and loaded -------------------------------------------------------------------

def make_cold(bundle: Path, pristine: Path | None, swap_bundle) -> dict:
    """Before a reopen: purge the disk cache, or, without passwordless sudo, replace the bundle by a fresh copy."""
    done = purge()
    if done == "purged":
        return {"how": "sudo purge (a reboot's cold disk cache, approximated: a fleet step cannot reboot)"}
    if pristine is None:
        return {"how": f"none: {done}, and no copy to swap in", "approximation": True}
    swap_bundle(bundle, pristine)
    return {"how": f"fresh bundle copy ({done}): its files are in no page cache, but it also pays a new copy's first exec",
            "approximation": True}


class SyntheticLoad:
    """A fixed load while a reopen runs: CPU_SHARE of the CPUs spinning (`yes`) and one writer of 256 MiB files with
    a sync between. Every worker is this process's child in its own process group, stopped by that group."""

    running: list["SyntheticLoad"] = []

    def __init__(self, root: Path, cpu_share: float = 0.5):
        self.root, self.cpu_share = root, cpu_share
        self.procs: list[subprocess.Popen] = []

    def start(self) -> dict:
        cpus = os.cpu_count() or 1
        workers = max(1, int(cpus * self.cpu_share))
        for _ in range(workers):
            self.procs.append(subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL, start_new_session=True))
        target = self.root / "load.bin"
        self.procs.append(subprocess.Popen(
            ["/bin/sh", "-c", 'while :; do dd if=/dev/zero of="$1" bs=1048576 count=256 2>/dev/null; sync; rm -f "$1"; done',
             "load", str(target)], stdout=subprocess.DEVNULL, start_new_session=True))
        SyntheticLoad.running.append(self)
        time.sleep(1.0)  # the load is on before the reopen
        return {"cpu_workers": workers, "cpus": cpus, "io": "256 MiB dd writes and a sync, in a loop",
                "load1_at_reopen": round(os.getloadavg()[0], 2)}

    def stop(self) -> dict:
        load = round(os.getloadavg()[0], 2)
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)  # its own group, made by start_new_session
                except OSError:
                    pass
                proc.wait(timeout=10)
        self.procs = []
        (self.root / "load.bin").unlink(missing_ok=True)
        if self in SyntheticLoad.running:
            SyntheticLoad.running.remove(self)
        return {"load1_at_settled": load}

    @classmethod
    def stop_all(cls) -> None:
        for load in list(cls.running):
            load.stop()


def self_test() -> int:
    assert quarantine_value(now=0x6739A000, ident="ab") == "0083;6739a000;Safari;AB"
    opened = parse_log_time("2026-11-17 00:40:01.000000+0000")
    lines = [json.dumps({"timestamp": "2026-11-17 00:40:00.500000+0000", "processImagePath": "/usr/libexec/syspolicyd",
                         "eventMessage": "before open"}),
             json.dumps({"timestamp": "2026-11-17 00:40:01.100000+0000", "processImagePath": "/usr/libexec/syspolicyd",
                         "eventMessage": "GK process assessment"}),
             json.dumps({"timestamp": "2026-11-17 00:40:01.700000+0000", "processImagePath": "/usr/libexec/syspolicyd",
                         "eventMessage": "done"}),
             json.dumps({"timestamp": "2026-11-17 00:40:01.200000+0000",
                         "processImagePath": "/Library/Apple/System/Library/CoreServices/XProtect.app/XProtectPluginService",
                         "eventMessage": "XProtect scan"}),
             "not json", "[1]"]
    gate = gate_summary(lines, opened)
    assert gate["syspolicyd_span_ms"] == 600 and gate["by_process"]["syspolicyd"]["n"] == 2, gate
    assert gate["xprotect_span_ms"] == 0 and len(gate["lines"]) == 2, gate
    marks = {"main_start": 50, "first_window_frame_committed": 1050, "reveal.sidebar": 1100, "reveal.tabs": 1080,
             "reveal.home": 1400}
    got = timings(marks, {"main_start": 0.9}, 2.0, {"shown_ms": 300, "clicked_ms": 500})
    assert got["open_to_spawn_ms"] == 850 and got["first_window_ms"] == 1050 and got["settled_ms"] == 1400, got
    assert got["open_to_first_window_ms"] == 1900 and got["open_to_settled_ms"] == 2250, got
    assert got["home_ms"] == 1150 and got["prompt_wait_ms"] == 200, got
    assert settled({"first_window_frame_committed": 1, "reveal.sidebar": 2, "reveal.tabs": 3}) is None
    assert settled({"first_window_frame_committed": 1, "reveal.sidebar": 2, "reveal.tabs": 3, "reveal.pane": 9}) == 9
    assert timings({}, {}, None, {})["first_window_ms"] is None
    print("startup_paths self-test: ok")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    print(__doc__)
    sys.exit(2)
