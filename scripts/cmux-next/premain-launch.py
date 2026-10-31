#!/usr/bin/env python3
"""Pre-main launch gap: where the time from the kernel's process start to CmuxNextApp.main goes.

A cold fleet launch drew its first terminal frame 8.7 s after the process start, and 7.9 s of it came before
main_start (STATUS 1800). This suite separates the parts of that gap on one mini, in one step:

  copy A   the bundle split-spring.sh staged for this step (a fresh `ditto` of the app cache), launched 3 times
  copy B   a new `ditto` copy at a new path, made now, launched 3 times
  copy C   a new APFS clone (`cp -c`, same data blocks, new files) at a new path, launched 3 times

Run 1 of a copy is the first exec of those files; runs 2 and 3 exec the same files again (what a person's
second and later launches do). Every run is cold for the tag (no daemon, empty state), so the work after main is
the same in all of them. `purge` needs root: it runs only through `sudo -n` (never a password); otherwise the
report says "purge not run" and each run's file cache is warm (the copy was just written or already run).

For each launch window (spawn .. main_start) the report has:
  - main_start and first_terminal_frame (ms after the kernel's process start, the app's launch marks)
  - the app's CPU time when main_start arrived (ps, every 100 ms): a gap with no CPU is a wait (signature
    checks, IPC to amfid or syspolicyd), a gap with CPU is the app's own image loading or initializers
  - cmux-ad's exact system log query (amfid, syspolicyd, trustd; --style compact), its line count and the
    lines that name the app (path, bundle name or tag) or an assessment, and a wider query (XProtect, kernel
    AMFI, taskgated) for context
Then, once: a `sample` of the process from its spawn on a fresh copy (what its threads wait in before main),
a DYLD_PRINT_LIBRARIES / DYLD_PRINT_INITIALIZERS run (images and initializers loaded before main), an
`xctrace record --template 'App Launch'` of a fresh copy and of copy A, and a static scan of the bundle:
every Mach-O's size, its static initializer count (__mod_init_func / __init_offsets), its signature
(codesign -dv) and the bundle's extended attributes (quarantine, provenance).

Used through the allowlisted fleet entry: `scripts/measure/split-spring.sh --config=bench --app-cache
--vdisplay=120 --suite=premain` (split-spring-terminal.py dispatches here with --app/--out/--json).
Exit 0 with a report; exit 1 only when no run reached main_start.
"""
import argparse
import datetime
import select
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402
_spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
bs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bs)

CHECKERS = ("amfid", "syspolicyd", "trustd", "XprotectService", "XProtect", "taskgated")
# cmux-ad's query (16:18Z), as written.
LOG_PREDICATE = 'process == "amfid" OR process == "syspolicyd" OR process == "trustd"'
WIDE_PREDICATE = ('process == "amfid" OR process == "syspolicyd" OR process == "trustd" OR process CONTAINS "XProtect" '
                  'OR process == "taskgated" OR process == "taskgated-helper" OR (process == "kernel" AND '
                  '(senderImagePath CONTAINS "AppleMobileFileIntegrity" OR eventMessage CONTAINS[c] "AMFI" '
                  'OR eventMessage CONTAINS[c] "code signature"))')
ASSESS_RE = re.compile(r"assess|evaluat|scan|xprotect|notari|ticket|ocsp|revocation|cdhash|signature|validat|"
                       r"gatekeeper|policy|trust|certificate|malware|yara", re.I)
NETWORK_RE = re.compile(r"network|ocsp|https?://|url|connection|timed out|timeout|offline|dns|api\.apple", re.I)
TIMEOUT = 60.0
# One TagTeardown per copy path: a launch's terminal hosts and holders run from cmux-tui's host-exe copy outside the
# bundle, so `bs.stop(bs.tag_pids(tag))` (bundle path) never finds them; the teardown does (tag_teardown.py).
TEARDOWNS = {}


def teardown_for(path):
    if path not in TEARDOWNS:
        TEARDOWNS[path] = TagTeardown(path, log=lambda line: log(line))
    return TEARDOWNS[path]


def log(msg):
    print(f"premain: {msg}", file=sys.stderr, flush=True)


def run(cmd, timeout=120):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.returncode, out.stdout, out.stderr
    except (OSError, subprocess.TimeoutExpired) as error:
        return -1, "", str(error)


def wall(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def try_purge():
    """`purge` through passwordless sudo only; never a password."""
    code, _, err = run(["sudo", "-n", "/usr/sbin/purge"], timeout=120)
    return code == 0, (err.strip()[:200] or f"exit {code}")


def checker_pids():
    code, out, _ = run(["ps", "-A", "-o", "pid=,comm="])
    pids = {}
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        name = os.path.basename(comm.strip())
        if name in CHECKERS:
            pids[int(pid)] = name
    return pids


def cpu_seconds(text):
    """ps `time` (M:SS.ss or H:MM:SS.ss) in seconds."""
    total = 0.0
    for part in text.strip().split(":"):
        total = total * 60 + float(part or 0)
    return total


class Poller(threading.Thread):
    """ps every 100 ms: the app's CPU time, RSS and state, and the signature checkers' CPU time."""

    def __init__(self, pid, start_t, checkers):
        super().__init__(daemon=True)
        # start_t: time.monotonic() just before the spawn, so t_ms is on the launch marks' clock (within the spawn).
        self.pid, self.start_t, self.samples, self.stop_flag = pid, start_t, [], threading.Event()
        self.checkers = checkers

    def run(self):
        ids = ",".join(str(p) for p in [self.pid, *self.checkers])
        while not self.stop_flag.is_set():
            code, out, _ = run(["ps", "-o", "pid=,time=,rss=,state=", "-p", ids], timeout=5)
            row = {"t_ms": round((time.monotonic() - self.start_t) * 1000)}
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 4:
                    pid = int(parts[0])
                    name = "app" if pid == self.pid else self.checkers.get(pid, str(pid))
                    row[name] = {"cpu_s": cpu_seconds(parts[1]), "rss_kb": int(parts[2]), "state": parts[3]}
            self.samples.append(row)
            self.stop_flag.wait(0.1)


def scan_log(start, end, predicate, app, limit=80):
    code, out, err = run(["log", "show", "--start", wall(start - 0.5), "--end", wall(end + 1.5),
                          "--predicate", predicate, "--style", "compact", "--info", "--debug"], timeout=180)
    lines = [line for line in out.splitlines() if line and not line.startswith(("Timestamp", "Filtering"))]
    names = [app, os.path.basename(app), "split-spring", os.path.realpath(app)]
    app_lines = [line for line in lines if any(name in line for name in names)]
    assess = [line for line in lines if ASSESS_RE.search(line)]
    by_process = {}
    for line in lines:
        match = re.search(r"\s(\S+)\[\d+:", line)
        if match:
            by_process[match.group(1)] = by_process.get(match.group(1), 0) + 1
    return {"exit": code, "error": err.strip()[:300] if code else None, "window": [wall(start), wall(end)],
            "lines": len(lines), "app_lines": len(app_lines), "assessment_lines": len(assess),
            "app_assessment_lines": len([line for line in app_lines if ASSESS_RE.search(line)]),
            "network_lines": len([line for line in lines if NETWORK_RE.search(line)]), "by_process": by_process,
            "app_excerpt": app_lines[:limit], "excerpt": lines[:limit]}


def use_copy(path):
    """Points the bench helpers' tag at this copy (its processes are found by their bundle path)."""
    bs.APPS.clear()
    bs.APPS[bs.app_tag(path)] = path
    return bs.app_tag(path)


def launch_once(path, label, extra_env=None, sample_to=None, logs=True):
    tag = use_copy(path)
    bs.reset_state(tag)  # cold: no daemon, empty state (bench-startup --profile empty --mode cold)
    if bs.tag_pids(tag):
        raise SystemExit(f"{label}: processes of the tag still run after the reset")
    scratch = tempfile.mkdtemp(prefix="premain-")
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write("{}\n")
    teardown = teardown_for(path)
    teardown.remember()  # re-arms end() for this launch, so a cancel during it still ends its hosts and holders
    checkers = checker_pids()
    t0, spawn_t = time.time(), time.monotonic()
    launch = bs.Launch(tag, scratch, extra_env)
    sampler = None
    if sample_to:
        sampler = subprocess.Popen(["/usr/bin/sample", str(launch.process.pid), "4", "1", "-mayDie", "-file", sample_to],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    poller = Poller(launch.process.pid, spawn_t, checkers)
    poller.start()
    try:
        got_main = launch.wait_for("main_start", TIMEOUT)
        main_seen_t = time.monotonic() if got_main else None  # the line arrived (select wakes on it)
        poller.stop_flag.set()
        launch.wait_for([bs.FINAL_MARK, bs.AGENT_MARK], TIMEOUT, any_of=True)
        teardown.remember()  # the daemon runs now: its state root (and so its hosts and holders) is recorded
    finally:
        poller.stop_flag.set()
        launch.quit()
        teardown.end()
        bs.stop(bs.tag_pids(tag))
        if sampler:
            try:
                sampler.wait(timeout=30)
            except subprocess.TimeoutExpired:
                sampler.kill()
    poller.join(5)
    marks = launch.marks
    main_ms = marks.get("main_start")
    at_main = None
    if main_ms is not None:
        before = [s for s in poller.samples if "app" in s and s["t_ms"] <= main_ms]
        at_main = before[-1] if before else None
    # An independent spawn -> main time on this script's clock: from just before the Popen to the main_start line's
    # arrival. It is an upper bound (it holds the `launchctl limit` read and the pipe hop). If the app's main_start_ms
    # (kernel p_starttime -> Date() in main) is much larger, the gap is in the process-start reference, not launch work.
    observed = round((main_seen_t - spawn_t) * 1000, 1) if main_seen_t else None
    record = {"label": label, "path": path, "spawn": wall(t0), "main_start_ms": main_ms,
              "spawn_to_main_observed_ms": observed,
              "reference_excess_ms": round(main_ms - observed, 1) if observed is not None and main_ms is not None else None,
              "first_window_frame_ms": marks.get("first_window_frame_committed"),
              "first_terminal_frame_ms": marks.get(bs.FINAL_MARK), "agent_handshake_ms": marks.get(bs.AGENT_MARK),
              "app_cpu_s_at_main": at_main["app"]["cpu_s"] if at_main else None,
              "checker_cpu_s_delta": checker_delta(poller.samples, main_ms), "ps_samples": poller.samples[:120]}
    if logs and main_ms is not None:
        # The earlier of the two main_start times ends the window, so a bad reference never pulls in work after main.
        end = t0 + min(main_ms, observed if observed is not None else main_ms) / 1000
        record["log_window_end"] = "observed" if observed is not None and observed < main_ms else "main_start_ms"
        record["log"] = scan_log(t0, end, LOG_PREDICATE, path)
        record["log_wide"] = scan_log(t0, end, WIDE_PREDICATE, path, limit=40)
    log(f"{label}: main_start {fmt(main_ms)} (observed by this script {fmt(observed)}), first terminal frame {fmt(marks.get(bs.FINAL_MARK))}, app cpu at main "
        f"{record['app_cpu_s_at_main']} s, log lines {record.get('log', {}).get('lines')} "
        f"(naming the app {record.get('log', {}).get('app_lines')}, assessment {record.get('log', {}).get('assessment_lines')})")
    return record


def checker_delta(samples, main_ms):
    """CPU seconds each checker process used between the first sample and main_start."""
    inside = [s for s in samples if main_ms is None or s["t_ms"] <= main_ms]
    if len(inside) < 2:
        return {}
    first, last = inside[0], inside[-1]
    return {name: round(last[name]["cpu_s"] - first[name]["cpu_s"], 2) for name in last
            if name not in ("t_ms", "app") and name in first}


def fmt(ms):
    return "missing" if ms is None else f"{ms:.0f} ms"


def exec_floor(runs=5, limits=True):
    """Spawn -> exit of /usr/bin/true with the bench's Popen shape (new session, a passed pipe, and with `limits` the
    Finder limits): the launcher's own share of any spawn -> main time. The kernel's p_starttime (the app's reference)
    is the FORK, so a child that spends seconds between fork and exec (CPython's close_fds loop runs up to the soft
    RLIMIT_NOFILE) shows up as time before main."""
    import contextlib
    times = []
    for _ in range(runs):
        read_fd, write_fd = os.pipe()
        start = time.monotonic()
        with (bs.finder_limits() if limits else contextlib.nullcontext()):
            proc = subprocess.Popen(["/usr/bin/true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True, pass_fds=(write_fd,))
        proc.wait()
        times.append(round((time.monotonic() - start) * 1000, 1))
        os.close(read_fd)
        os.close(write_fd)
    return times


NIGHTLY_FEED = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"


def checker_cpu():
    """CPU seconds so far of syspolicyd and XprotectService (root processes: `ps` reads them)."""
    pids = {name: pid for pid, name in checker_pids().items() if name in ("syspolicyd", "XprotectService")}
    if not pids:
        return {}
    _, out, _ = run(["ps", "-o", "pid=,time=", "-p", ",".join(str(p) for p in pids.values())], timeout=5)
    by_pid = {int(parts[0]): cpu_seconds(parts[1]) for parts in (line.split() for line in out.splitlines()) if len(parts) == 2}
    return {name: by_pid.get(pid) for name, pid in pids.items()}


def launch_release(app, label):
    """One full launch of a release bundle (the notarized nightly) to main_start and its first frame, with its own
    scratch home (HOME and CFFIXED_USER_HOME, as capture-host launches do), so it reads no account state; its marks
    come on the same pipe as a bench build's (LaunchMarkSink is in every build). Quit, then its processes are ended
    by TagTeardown (bundle path and id)."""
    import plistlib
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as info:
        binary = os.path.join(app, "Contents/MacOS", plistlib.load(info)["CFBundleExecutable"])
    home = tempfile.mkdtemp(prefix="premain-home-")
    with open(os.path.join(home, "cmux.json"), "w") as out:
        out.write("{}\n")
    teardown = teardown_for(app)
    teardown.remember()
    read_fd, write_fd = os.pipe()
    env = {"HOME": home, "CFFIXED_USER_HOME": home, "USER": os.environ.get("USER", ""),
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
           "CMUX_NEXT_CONFIG_FILE": os.path.join(home, "cmux.json"), "CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd)}
    before = checker_cpu()
    t0, spawn_t = time.time(), time.monotonic()
    with bs.finder_limits():
        proc = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True, pass_fds=(write_fd,))
    os.close(write_fd)
    marks, buffer, main_seen, after = {}, b"", None, None
    deadline = spawn_t + TIMEOUT
    try:
        while not ({bs.FINAL_MARK, bs.AGENT_MARK} & marks.keys()) and time.monotonic() < deadline:
            ready, _, _ = select.select([read_fd], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(read_fd, 65536)
            if not chunk:
                break
            buffer += chunk
            *lines, buffer = buffer.split(b"\n")
            for line in lines:
                name, _, ms = line.decode(errors="replace").partition(" ")
                if name and ms:
                    marks.setdefault(name, float(ms))
            if "main_start" in marks and main_seen is None:
                main_seen = time.monotonic()
                after = checker_cpu()
        teardown.remember()
    finally:
        os.close(read_fd)
        bs.stop([proc.pid], timeout=20)
        proc.wait()
        teardown.end()
        shutil.rmtree(home, ignore_errors=True)
    main_ms = marks.get("main_start")
    observed = round((main_seen - spawn_t) * 1000, 1) if main_seen else None
    record = {"label": label, "path": app, "main_start_ms": main_ms, "spawn_to_main_observed_ms": observed,
              "first_terminal_frame_ms": marks.get(bs.FINAL_MARK), "agent_handshake_ms": marks.get(bs.AGENT_MARK),
              # a checker that started during the launch (XprotectService on a first exec) counts from 0 s
              "checker_cpu_s": {k: round(v - (before.get(k) or 0.0), 2) for k, v in (after or {}).items() if v is not None},
              "exit_status": proc.returncode}
    if main_ms is not None:
        end = t0 + min(main_ms, observed if observed is not None else main_ms) / 1000
        lg = scan_log(t0, end, LOG_PREDICATE, app, limit=12)
        record["log"] = {k: lg[k] for k in ("lines", "app_lines", "assessment_lines", "app_assessment_lines", "by_process",
                                            "network_lines", "app_excerpt")}
    log(f"{label}: main_start {fmt(main_ms)} (observed {fmt(observed)}), checkers {record['checker_cpu_s']}, "
        f"log {record.get('log', {}).get('lines')} lines, {record.get('log', {}).get('app_lines')} naming the app")
    return record


def bench_launch(path, label):
    """launch_once (cold, empty state) without its ps samples; checker_cpu_s_delta holds the checkers' CPU to main."""
    record = launch_once(path, label)
    record.pop("ps_samples", None)
    return record


def notarized_probe(root, adhoc_app):
    """Full launches to main_start: the newest notarized Developer ID nightly-next (what a person runs), without and
    with a user-approved quarantine attribute, the same nightly re-signed ad hoc (same bytes, only the signature
    differs), and a new copy of the ad-hoc bench app. Each series is 3 launches of ONE new copy: launch 1 is the copy's
    first exec, 2 and 3 repeat it. The staged copy A is never launched here."""
    result = {"method": "full launches to main_start (launch marks), 3 per new copy",
              "limits": "the quarantined copy carries the flag a download has AFTER the person clicked Open (01c1): the "
                        "first launch of an unapproved download waits for that click in a Gatekeeper dialog, which "
                        "cannot be timed and would block the mini"}
    try:
        notarized_probe_body(root, adhoc_app, result)
    except Exception as error:  # noqa: BLE001 - the probe must never lose the report; SystemExit (a cancel) passes
        result["error"] = f"{type(error).__name__}: {error}"[:300]
    return result


def probe_copy(source, root, name):
    try:
        return fresh_copy(source, root, name)
    except SystemExit as error:
        if isinstance(error.code, str):  # fresh_copy's own copy failure (a signal's SystemExit carries an int)
            raise RuntimeError(error.code) from None
        raise


def notarized_probe_body(root, adhoc_app, result):
    adhoc_fresh = probe_copy(adhoc_app, root, "F")
    result["adhoc_new_copy"] = [bench_launch(adhoc_fresh, f"bench ad hoc (new copy) run {i}") for i in (1, 2, 3)]
    shutil.rmtree(os.path.dirname(adhoc_fresh), ignore_errors=True)
    work = os.path.join(root, "N")
    os.makedirs(work, exist_ok=True)
    code, feed, err = run(["curl", "-fsSL", "--max-time", "30", NIGHTLY_FEED], timeout=60)
    urls = re.findall(r'url="(https://files-next\.cmux\.com/nightly-next/next/[^"]+\.dmg)"', feed)
    if not urls:
        result["error"] = f"no DMG in the feed ({err.strip()[:200] or code})"
        return
    dmg, mount = os.path.join(work, "nightly.dmg"), os.path.join(work, "mnt")
    result["dmg"] = urls[0]
    code, _, err = run(["curl", "-fsSL", "--max-time", "600", "-o", dmg, urls[0]], timeout=660)
    if code != 0:
        result["error"] = f"download failed: {err.strip()[:200]}"
        return
    os.makedirs(mount, exist_ok=True)
    code, _, err = run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg], timeout=300)
    if code != 0:
        result["error"] = f"hdiutil attach: {err.strip()[:200]}"
        return
    try:
        apps = [name for name in os.listdir(mount) if name.endswith(".app")]
        if not apps:
            result["error"] = "no .app in the DMG"
            return
        app = os.path.join(work, apps[0])
        code, _, err = run(["ditto", os.path.join(mount, apps[0]), app], timeout=600)  # curl and ditto set no quarantine
        if code != 0:
            result["error"] = f"ditto from the DMG: {err.strip()[:200]}"
            return
    finally:
        run(["hdiutil", "detach", "-force", mount], timeout=120)
    os.remove(dmg)
    _, out, err = run(["codesign", "-dv", "--verbose=2", app])
    result["signature"] = [line for line in (out + err).splitlines() if line.startswith(("Authority", "TeamIdentifier", "Notarization", "Runtime", "flags", "CodeDirectory"))]
    result["spctl"] = " ".join(run(["spctl", "-a", "-vv", "-t", "exec", app])[2].split())[:300]
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as info:
        import plistlib
        plist = plistlib.load(info)
    result["notarized_version"] = plist.get("CFBundleVersion")
    result["notarized_new_copy"] = [launch_release(app, f"notarized (new copy) run {i}") for i in (1, 2, 3)]
    quarantined = probe_copy(app, root, "Q")
    flag = f"01c1;{int(time.time()):x};Safari;"
    code, _, err = run(["xattr", "-w", "com.apple.quarantine", flag, quarantined])
    result["quarantine"] = {"flag": flag, "set": code == 0, "error": err.strip()[:200] or None,
                            "spctl": " ".join(run(["spctl", "-a", "-vv", "-t", "exec", quarantined])[2].split())[:300]}
    if code == 0:
        result["notarized_quarantined_approved"] = [launch_release(quarantined, f"notarized quarantined (approved) run {i}")
                                                    for i in (1, 2, 3)]
    shutil.rmtree(os.path.dirname(quarantined), ignore_errors=True)
    # The same bytes signed ad hoc (as reload.sh and the fleet build sign): only the signature differs from N.
    resigned = probe_copy(app, root, "R")
    # As reload.sh and the fleet build sign: ad hoc, no entitlements (restricted ones would make AMFI kill it at exec).
    code, _, err = run(["codesign", "--force", "--deep", "--sign", "-", resigned], timeout=900)
    if code != 0:
        result["resigned_error"] = err.strip()[:300]
    else:
        result["nightly_resigned_adhoc"] = [launch_release(resigned, f"nightly re-signed ad hoc run {i}") for i in (1, 2, 3)]
    shutil.rmtree(os.path.dirname(resigned), ignore_errors=True)
    shutil.rmtree(work, ignore_errors=True)


def fresh_copy(source, root, name, clone=False):
    dest_dir = os.path.join(root, name)
    shutil.rmtree(dest_dir, ignore_errors=True)
    os.makedirs(dest_dir)
    dest = os.path.join(dest_dir, os.path.basename(source))
    start = time.monotonic()
    cmd = ["cp", "-c", "-R", source, dest] if clone else ["ditto", source, dest]
    code, _, err = run(cmd, timeout=600)
    if code != 0:
        raise SystemExit(f"{' '.join(cmd)}: {err.strip()[:300]}")
    log(f"{name}: {'APFS clone' if clone else 'ditto'} in {time.monotonic() - start:.1f} s -> {dest}")
    return dest


def macho_files(app):
    found = []
    for base, _, files in os.walk(app):
        for name in files:
            path = os.path.join(base, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    magic = f.read(4)
            except OSError:
                continue
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xfe\xed\xfa\xcf"):
                found.append(path)
    return found


def static_scan(app):
    """Each Mach-O's size, static initializers and signature; the main binary's direct links; xattrs."""
    use_copy(app)
    images = []
    for path in macho_files(app):
        code, out, _ = run(["otool", "-l", "-arch", "arm64", path], timeout=120)
        inits = 0
        for match in re.finditer(r"sectname (__mod_init_func|__init_offsets)\n\s+segname \S+\n\s+addr \S+\n\s+size (0x[0-9a-f]+)",
                                 out):
            size = int(match.group(2), 16)
            inits += size // (8 if match.group(1) == "__mod_init_func" else 4)
        images.append({"path": os.path.relpath(path, app), "bytes": os.path.getsize(path), "static_initializers": inits})
    images.sort(key=lambda image: -image["bytes"])
    binary = bs.app_binary(bs.app_tag(app))
    links = run(["otool", "-L", binary])[1].splitlines()[1:] if binary else []
    signatures = {}
    for path in [binary] + [os.path.join(app, i["path"]) for i in images[:6]]:
        if path:
            _, out, err = run(["codesign", "-dv", "--verbose=2", path])
            signatures[os.path.relpath(path, app)] = [line for line in (out + err).splitlines()
                                                      if line.split("=")[0] in ("Format", "CodeDirectory v", "Signature",
                                                                                "Authority", "TeamIdentifier", "Runtime Version",
                                                                                "Signature size", "Hash type", "flags")
                                                      or line.startswith(("CodeDirectory", "Authority", "Signature"))]
    return {"images": images, "image_count": len(images), "bundle_bytes": sum(i["bytes"] for i in images),
            "static_initializers_total": sum(i["static_initializers"] for i in images),
            "main_links": [line.strip() for line in links], "signatures": signatures,
            "xattrs": sorted({line.rsplit(": ", 1)[-1].strip() for line in run(["xattr", "-r", app], timeout=60)[1].splitlines()
                              if ": " in line})}


def dyld_print(app):
    """One launch with dyld's own logging: the images and initializers it ran before main."""
    out_file = os.path.join(tempfile.mkdtemp(prefix="premain-dyld-"), "dyld.txt")
    record = launch_once(app, "dyld-print (copy A)", {"DYLD_PRINT_LIBRARIES": "1", "DYLD_PRINT_INITIALIZERS": "1",
                                                      "DYLD_PRINT_TO_FILE": out_file}, logs=False)
    try:
        with open(out_file, errors="replace") as f:
            text = f.read()
    except OSError:
        text = ""
    if not text:
        record["dyld_note"] = ("no dyld output: dyld ignored DYLD_* (hardened runtime without "
                               "allow-dyld-environment-variables), so this is NOT zero initializers")
    loads = [line for line in text.splitlines() if "dyld" in line and ("load" in line or "<" in line)]
    inits = [line for line in text.splitlines() if "initializer" in line.lower()]
    ours = [line for line in inits if "/System/" not in line and "/usr/lib/" not in line]
    record["dyld_scope"] = "the app and every child it started (server ensure, daemon, hosts) append to one file"
    record.update({"dyld_lines": len(text.splitlines()), "image_lines": len(loads), "initializer_lines": len(inits),
                   "initializers_outside_system": ours[:200], "dyld_head": text.splitlines()[:30]})
    return record


def xctrace_launch(app, label):
    """`xctrace record --template 'App Launch'` of the app's binary; the trace's tables, exported."""
    tag = use_copy(app)
    bs.reset_state(tag)
    scratch = tempfile.mkdtemp(prefix="premain-xctrace-")  # outside the step's artifacts: a trace is large
    trace = os.path.join(scratch, f"premain-{label}.trace")
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write("{}\n")
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={os.path.join(scratch, 'cmux.json')}"]
    cmd = ["xcrun", "xctrace", "record", "--template", "App Launch", "--time-limit", "20s", "--no-prompt",
           "--output", trace]
    for item in env:
        cmd += ["--env", item]
    cmd += ["--launch", "--", bs.app_binary(tag)]
    teardown = teardown_for(app)
    teardown.remember()  # re-arms end() before the traced launch (a cancel during it ends its hosts)
    start = time.monotonic()
    code, out, err = run(cmd, timeout=180)
    teardown.remember()  # the daemon outlives the traced app: read its state root before ending it
    teardown.end()
    bs.stop(bs.tag_pids(tag))
    result = {"label": label, "exit": code, "seconds": round(time.monotonic() - start, 1),
              "stderr": (err or out).strip()[-600:]}
    if not os.path.exists(trace):
        shutil.rmtree(scratch, ignore_errors=True)
        return result
    _, toc, _ = run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], timeout=180)
    schemas = sorted(set(re.findall(r'schema="([^"]+)"', toc)))
    result["schemas"] = schemas
    tables = {}
    for schema in schemas:
        if not re.search(r"life-cycle|lifecycle|dyld|static|initiali|image|launch|process|signpost-interval", schema):
            continue
        _, xml, _ = run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                         f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], timeout=180)
        tables[schema] = summarize_table(xml)
    result["tables"] = tables
    shutil.rmtree(scratch, ignore_errors=True)
    return result


def summarize_table(xml):
    """Rows of an xctrace table as text: each row's leaf values (the `fmt` attribute when it has one)."""
    rows = []
    for row in re.findall(r"<row>(.*?)</row>", xml, re.S)[:400]:
        values = re.findall(r'fmt="([^"]*)"', row)
        rows.append(" | ".join(values[:10]))
    return {"rows": len(re.findall(r"<row>", xml)), "first": rows[:150]}


def run_exec_probe(report, root, app, save):
    report["exec_probe"] = notarized_probe(root, app)
    log("exec probe: " + "; ".join(f"{k} {[r.get('main_start_ms') for r in v]}" for k, v in report["exec_probe"].items()
                                     if isinstance(v, list) and v and isinstance(v[0], dict)))
    save()


def table(runs):
    lines = ["| copy | run | main_start ms | observed spawn->main ms | first terminal frame ms | app CPU s at main | log lines | naming the app | assessment lines |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in runs:
        lg = r.get("log", {})
        lines.append(f"| {r['label'].split()[0]} | {r['label'].split()[-1]} | {fmt(r['main_start_ms'])} | "
                     f"{fmt(r.get('spawn_to_main_observed_ms'))} | {fmt(r['first_terminal_frame_ms'])} | {r['app_cpu_s_at_main']} | {lg.get('lines')} | "
                     f"{lg.get('app_lines')} | {lg.get('assessment_lines')} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--no-xctrace", action="store_true")
    parser.add_argument("--exec-probe", action="store_true",
                        help="also the exec-wait probe (ad-hoc bench app, notarized nightly, nightly re-signed ad hoc), after the launches")
    parser.add_argument("--exec-probe-only", action="store_true", help="only the exec-wait probe, no app launch")
    args, _ = parser.parse_known_args()
    app = os.path.abspath(args.app)
    root = os.path.join(os.path.abspath(args.out), "premain-copies")
    report = {"suite": "premain", "app": app, "macos": run(["sw_vers", "-productVersion"])[1].strip(),
              "host": os.uname().nodename, "runs": [], "notes": []}
    copies = [app]

    def save():
        with open(args.json, "w") as f:
            json.dump(report, f, indent=1)
    teardown_for(app).install()  # SIGTERM and SIGHUP (a cancelled step) raise SystemExit, so the finally below runs
    try:
        purged, why = try_purge()
        report["purge"] = ("run before each A, B and C launch (not before D, dyld-print or xctrace)" if purged
                           else f"purge not run ({why}): each copy's files are in the page cache (just written or run)")
        log(report["purge"])
        import resource
        report["python"] = sys.version.split()[0]
        report["nofile_rlimit"] = list(resource.getrlimit(resource.RLIMIT_NOFILE))
        report["launchctl_maxfiles"] = run(["/bin/launchctl", "limit", "maxfiles"])[1].strip()
        report["exec_floor_ms"] = exec_floor()
        report["exec_floor_inherit_limits_ms"] = exec_floor(limits=False)
        if args.exec_probe_only:
            run_exec_probe(report, root, app, save)
            return
        log(f"exec floor (/usr/bin/true, same Popen shape): Finder limits {report['exec_floor_ms']} ms, the caller's "
            f"{report['exec_floor_inherit_limits_ms']} ms (python {report['python']}, nofile {report['nofile_rlimit']}, "
            f"launchctl {report['launchctl_maxfiles']})")
        save()
        copy_b = fresh_copy(app, root, "B")
        copies.append(copy_b)
        copy_c = fresh_copy(app, root, "C", clone=True)
        copies.append(copy_c)
        for name, path in (("A", app), ("B", copy_b), ("C", copy_c)):
            for index in range(1, args.runs + 1):
                if purged:
                    try_purge()
                report["runs"].append(launch_once(path, f"{name} (first exec of the copy) run {index}" if index == 1
                                                  else f"{name} run {index}"))
                save()
        report["static"] = static_scan(app)  # after the timed runs, so it does not warm copy A's first exec
        log(f"static: {report['static']['image_count']} Mach-O files, {report['static']['bundle_bytes'] / 1e6:.0f} MB, "
            f"{report['static']['static_initializers_total']} static initializers")
        save()
        copy_d = fresh_copy(app, root, "D")
        copies.append(copy_d)
        sample_file = os.path.join(tempfile.mkdtemp(prefix="premain-sample-"), "sample-D.txt")
        report["sampled"] = launch_once(copy_d, "D (fresh copy, sampled from spawn) run 1", sample_to=sample_file, logs=False)
        try:
            with open(sample_file, errors="replace") as f:
                report["sampled"]["sample_head"] = f.read().splitlines()[:260]
        except OSError as error:
            report["sampled"]["sample_head"] = [f"no sample: {error}"]
        save()
        report["dyld_print"] = dyld_print(app)
        save()
        if not args.no_xctrace:
            copy_e = fresh_copy(app, root, "E")
            copies.append(copy_e)
            report["xctrace"] = [xctrace_launch(copy_e, "E-fresh"), xctrace_launch(app, "A-reused")]
            save()
        if args.exec_probe:
            run_exec_probe(report, root, app, save)
    finally:
        for path in copies:
            use_copy(path)
            teardown_for(path).end()
            bs.stop(bs.tag_pids(bs.app_tag(path)))
        report["table"] = table(report["runs"])
        save()
        shutil.rmtree(root, ignore_errors=True)  # the copies this script made (B to E), never the staged app
        print(report["table"], flush=True)
    if not any(r.get("main_start_ms") is not None for r in report["runs"]):
        sys.exit(1)


if __name__ == "__main__":
    main()
