#!/usr/bin/env python3
"""Where a published NEXT nightly's fresh-home launch spends its time (goal next-launch-instant, CMUX-571).

    nightly-fresh-launch.py --dmg DMG --out DIR [--rounds N] [--seconds S]

The nightly dogfood's launch number (app_launch_ms) is a first install's launch: a fresh copy of the app out of the
DMG, an empty HOME (scripts/ci/fresh_home_launch_smoke.py). It mixes two kinds of first-time cost: the first exec
of a binary no process has run yet (the kernel's and dyld's first look at a new file, the signature checks), and the
app's own first-run work in an empty home. Each round here launches three times, with the smoke's own environment,
defaults set aside as it does, and its watch (Home rendered in a visible window):

  fresh-copy   a new copy of the app (ditto out of the DMG), a new HOME: the nightly dogfood's launch
  same-copy    the same copy again, another new HOME: the first-exec cost of the copy is gone, the home's is not
  warm         the same copy and the same-copy arm's HOME again: a person's next launch

and prints, per launch, every launch mark the app streamed (ms since its process start) and the phases:
  pre_main   process start to main_start (exec, dyld, static initializers)
  to_frame   main_start to first_window_frame_committed
  to_page    first_window_frame_committed to home.first_page (Home's first page in)
  harness    the smoke's time to Home rendered (it polls snapshot.get every 0.25 s)
It also records the copy's facts once: its size, its main executable's size and load commands, its extended
attributes (quarantine, provenance) and its signature (codesign -dv).

Lines: NFL-FACT <json>, NFL-LAUNCH <round> <arm> <json>, NFL-MEDIAN <arm> <json>. report.json keeps it all.
Exit 0: every launch rendered Home. 1: one did not. 3: could not run.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import mmap
import select
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SMOKE_PATH = HERE.parent / "ci" / "fresh_home_launch_smoke.py"
ARMS = ("fresh-copy", "same-copy", "warm")
# --arms=extra: where a new copy's first-exec cost lives and whether a pre-warm of the copy keeps (each its own copy):
#   prewarm-main    the copy runs once until main_start (exec and dyld only, then killed), then the fresh-home launch
#   prewarm-moved   as prewarm-main, but in a staging folder, then renamed into another folder before the launch
#                   (Sparkle's installer moves its staged copy into place: a rename on one volume)
#   prewarm-home    the copy runs once to Home in a staging folder (every helper and the daemon), renamed, launched
#   spctl           `spctl --assess --type execute` on the copy (the system's own assessment), then the launch
#   gktool          `gktool scan` on the copy (what Sparkle 2 runs on a staged update when its Autoupdate has the
#                   update's team), then the launch
#   gktool-moved    as gktool, in a staging folder, then renamed into place (Sparkle's install of a scanned update)
#   prewarm-bins-moved  as prewarm-moved, and the bundled `cmux` and `cmux-tui` (Contents/Resources/bin) run once
#                   with --version: the launch's other first execs (the CLI's cloud env read, the daemon)
#   prewarm-helpers-moved  as prewarm-bins-moved, and each Chromium helper app's executable run once with --version
#   prewarm-chromium-moved as prewarm-helpers-moved, and the copy's executable once with --cmux-prewarm-chromium (Chromium
#                   starts for real in a throwaway profile, one hidden about:blank page, then shuts down; the update
#                   path's pre-warm, StagedUpdatePrewarm.chromiumArgument)
#   prewarm-pages-moved  as prewarm-helpers-moved, and every page of every file in Contents/Frameworks read once
#                   through a read-only mapping (touch_pages): is what is left after a helper's --version the
#                   framework's pages, which a helper with no --type never touches
EXTRA_ARMS = ("prewarm-main", "prewarm-moved", "prewarm-bins-moved", "prewarm-home", "spctl", "gktool", "gktool-moved")
# --arms=prewarm: the pre-warms only (the update path's pre-warm and what it could add), beside the base arms.
PREWARM_ARMS = ("prewarm-bins-moved", "prewarm-helpers-moved", "prewarm-pages-moved", "prewarm-chromium-moved", "prewarm-home", "gktool-moved")
# --arms=adhoc: whether an ad-hoc signed new copy (a tagged build's, dmg=build) pays the first-exec cost a Developer ID
# signed one does, so a dmg=build A/B's fresh-copy result transfers to the published DMG:
#   adhoc-copy      a new copy of the same DMG's app re-signed ad hoc from the inside out, as reload.sh signs a tagged
#                   build (adhoc_sign: no flags, no entitlements), then the fresh-home launch: the same code on the same
#                   Mac, only the signature differs
ADHOC_ARMS = ("adhoc-copy",)
PREWARM_BINS = ("cmux", "cmux-tui")
# The unified log around a fresh copy's launch: who works on a new executable before main.
FIRST_EXEC_LOG = ('process == "syspolicyd" OR process == "amfid" OR process == "XProtect" OR process == "trustd" '
                  'OR process == "kernel" OR subsystem == "com.apple.dyld" OR subsystem BEGINSWITH "com.apple.syspolicy" '
                  'OR process == "lsd" OR process == "mds_stores"')
PHASE_KEYS = ("main_start", "first_window_frame_committed", "home.first_page", "reveal.home")
# The sample's span (start_sample): from the first window frame (about 2.2 s after spawn on a fleet Mac) through the
# wait for the Chief owner that Home's first page needs (home.chief_owner_ready about 4.1 s).
SAMPLE_AT, SAMPLE_SECONDS = 2.2, 2


def load_smoke():
    spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SMOKE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_text(args: list[str], timeout: float = 120) -> str:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return f"error: {error}"
    return (done.stdout + done.stderr).strip()


def facts(app: Path, executable: str, copy_s: float) -> dict:
    exe = app / "Contents" / "MacOS" / executable
    loads = run_text(["otool", "-L", str(exe)]).splitlines()[1:]
    frameworks = app / "Contents" / "Frameworks"
    started = time.monotonic()
    verify = run_text(["codesign", "--verify", "--strict", str(exe)], timeout=600)
    verify_s = time.monotonic() - started
    # The whole bundle, as a first-launch Gatekeeper check of an app hashes it (every nested framework and resource).
    started = time.monotonic()
    deep = run_text(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=900)
    deep_s = time.monotonic() - started
    return {
        "codesign_verify_deep_s": round(deep_s, 2), "codesign_verify_deep": deep or "ok",
        "frameworks_du": run_text(["du", "-sh", str(frameworks)]).split("\t")[0] if frameworks.is_dir() else None,
        "copy_s": round(copy_s, 2),
        "bundle_du": run_text(["du", "-sh", str(app)]).split("\t")[0],
        "frameworks": sorted(p.name for p in frameworks.iterdir()) if frameworks.is_dir() else [],
        "exe_bytes": exe.stat().st_size,
        "exe_loads": [line.strip().split(" (")[0] for line in loads],
        "xattr_app": run_text(["xattr", str(app)]).splitlines(),
        "xattr_exe": run_text(["xattr", str(exe)]).splitlines(),
        "codesign": [line for line in run_text(["codesign", "-dv", str(exe)]).splitlines()
                     if not line.startswith("Executable=")],
        "codesign_verify_exe_s": round(verify_s, 2), "codesign_verify": verify or "ok",
        # Sparkle runs `gktool scan` on a staged update only when its Autoupdate has the update's team (SUPlainInstaller).
        "autoupdate_codesign": [line for line in run_text(["codesign", "-dv", str(frameworks / "Sparkle.framework" / "Versions" / "B" / "Autoupdate")]).splitlines()
                                if line.startswith(("TeamIdentifier", "Authority", "Identifier"))],
        "bundled_bin": sorted(p.name for p in (app / "Contents" / "Resources" / "bin").iterdir())
                       if (app / "Contents" / "Resources" / "bin").is_dir() else [],
        "macos": run_text(["sw_vers", "-productVersion"]), "chip": run_text(["sysctl", "-n", "machdep.cpu.brand_string"]),
    }


def phases(marks: dict, rendered_at: float | None) -> dict:
    def get(key):
        return marks.get(key)
    start, frame, page = get("main_start"), get("first_window_frame_committed"), get("home.first_page")
    def gap(a, b):
        return None if a is None or b is None else round(b - a, 1)
    return {"pre_main": start, "to_frame": gap(start, frame), "to_page": gap(frame, page),
            "frame": frame, "page": page, "reveal_home": get("reveal.home"),
            "harness": None if rendered_at is None else round(rendered_at * 1000)}


def repeated_marks(path: Path) -> list[list]:
    """Every mark a launch wrote more than once, with each time (read_marks keeps only the first): a step that ran
    again, such as a Home ensure that a later connection restarted."""
    seen: dict[str, list[float]] = {}
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    for line in lines:
        name, _, ms = line.rpartition(" ")
        try:
            seen.setdefault(name, []).append(round(float(ms), 1))
        except ValueError:
            continue
    return sorted(([name, times] for name, times in seen.items() if len(times) > 1), key=lambda item: item[1][0])


def start_sample(pid: int, path: Path) -> threading.Thread:
    """`sample` of the app from SAMPLE_AT to SAMPLE_AT + SAMPLE_SECONDS after its spawn, through `sudo -n` (a hardened
    app takes no task port from its own user), on a thread so the watch goes on. No passwordless sudo: no sample."""
    spawned = time.monotonic()

    def run() -> None:
        time.sleep(max(0.0, SAMPLE_AT - (time.monotonic() - spawned)))
        try:
            subprocess.run(["sudo", "-n", "/usr/bin/sample", str(pid), str(SAMPLE_SECONDS), "1", "-mayDie", "-file", str(path)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=SAMPLE_SECONDS + 25)
        except (OSError, subprocess.SubprocessError):
            pass

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def main_thread_summary(path: Path, lines: int = 120) -> list[str]:
    """The main thread's call graph from a sample report, its first LINES lines (the heaviest frames first)."""
    try:
        text = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    start = next((i for i, line in enumerate(text) if "Thread_" in line and ("main-thread" in line or "DispatchQueue_1" in line)), None)
    return [] if start is None else [line.rstrip() for line in text[start:start + lines]]


def launch(smoke, root: Path, app: Path, executable: str, home_root: Path, seconds: float, name: str,
           sample: bool = False) -> dict:
    """One launch of APP from HOME_ROOT/h (the smoke's fresh_env), watched until Home rendered and SECONDS passed.
    SAMPLE: also `sample` it over the span where Home waits (start_sample) and keep its main thread's call graph."""
    socket_path, marks_path = home_root / f"{name}.sock", home_root / f"marks-{name}"
    marks_read, marks_write = os.pipe()
    try:
        try:
            env = smoke.fresh_env(home_root, socket_path, marks_write)
            smoke.login_keychain(env)  # a person's home has one: no Safe Storage Keychain dialog (cmuxterm-hq#11994)
            with open(home_root / f"app-{name}.log", "wb") as app_log:
                process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable),
                                            "-ApplePersistenceIgnoreState", "YES"],
                                           env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                           stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
        finally:
            os.close(marks_write)
        sampler = start_sample(process.pid, home_root / f"sample-{name}.txt") if sample else None
        try:
            seen = smoke.watch(process, marks_read, marks_path, socket_path, seconds, max(seconds, 90.0))
        finally:
            if sampler is not None:
                sampler.join(timeout=30)
            smoke.stop_child(process)
            smoke.stop(smoke.own_pids(root))
    finally:
        os.close(marks_read)
    marks = dict(sorted(smoke.read_marks(marks_path).items(), key=lambda kv: kv[1]))
    return {"exit": seen["exit"], "rendered_at": seen["rendered_at"], "host": seen["host"],
            "phases": phases(marks, seen["rendered_at"]), "marks": marks, "repeats": repeated_marks(marks_path),
            "sample_main": main_thread_summary(home_root / f"sample-{name}.txt", 200) if sample else None}


def prewarm_until_main(smoke, root: Path, app: Path, executable: str, home_root: Path) -> dict:
    """Runs APP once with HOME_ROOT's fresh home until its main_start mark (exec, dyld and static initializers
    done), then kills it: the pre-warm a launcher would do. Returns its seconds and when main_start came."""
    started = time.monotonic()
    marks_read, marks_write = os.pipe()
    try:
        try:
            env = smoke.fresh_env(home_root, home_root / "prewarm.sock", marks_write)
            process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable), "-ApplePersistenceIgnoreState", "YES"],
                                       env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, pass_fds=(marks_write,), start_new_session=True)
        finally:
            os.close(marks_write)
        seen, buf = None, b""
        try:
            while time.monotonic() - started < 60 and process.poll() is None:
                ready, _, _ = select.select([marks_read], [], [], 0.25)
                if ready:
                    chunk = os.read(marks_read, 1 << 16)
                    if not chunk:
                        break
                    buf += chunk
                    if b"main_start" in buf:
                        seen = time.monotonic() - started
                        break
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            smoke.stop(smoke.own_pids(root))
    finally:
        os.close(marks_read)
    return {"seconds": round(time.monotonic() - started, 3), "main_start_at": None if seen is None else round(seen, 3)}


def touch_pages(root: Path) -> dict:
    """Maps each regular file under ROOT read-only and reads one byte per 16 KiB page, so every page is resident (and,
    for a signed Mach-O whose signature a process already attached, validated) before the launch that maps it."""
    files = pages = 0
    started = time.monotonic()
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        size = path.stat().st_size
        if size == 0:
            continue
        with open(path, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
            for offset in range(0, size, 16384):
                mapped[offset]
                pages += 1
        files += 1
    return {"files": files, "pages": pages, "seconds": round(time.monotonic() - started, 3)}


def adhoc_sign(app: Path) -> str:
    """Re-signs APP ad hoc from the inside out, as a tagged build is signed: each nested bundle, framework, dylib and
    executable, deepest first, then APP, with no flags and no entitlements, as scripts/reload.sh signs a tagged build
    (`codesign --force --sign - --timestamp=none`). The Developer ID build's team-restricted entitlements under an ad-hoc
    signature got the process killed at exec (SIGKILL), and its hardened runtime kept made library validation refuse the
    ad-hoc frameworks before `main` (SIGABRT). Returns the last lines of codesign's output."""
    contents = app / "Contents"
    items = [p for p in contents.rglob("*") if p.suffix in (".app", ".framework", ".dylib", ".xpc", ".appex")]
    items += [p for d in ("MacOS", "Resources/bin") for p in (contents / d).glob("*")
              if p.is_file() and not p.is_symlink() and os.access(p, os.X_OK)]
    items += [p for p in (contents / "Frameworks").rglob("*") if p.is_file() and not p.is_symlink()
              and os.access(p, os.X_OK) and p.parent.name in ("MacOS", "Helpers")]
    out = []
    for item in sorted(set(items), key=lambda p: len(p.parts), reverse=True) + [app]:
        line = run_text(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(item)], timeout=300)
        if "error" in line.lower() or item == app:
            out.append(f"{item.relative_to(app.parent)}: {line.strip()[-200:]}")
    return "\n".join(out)[-800:]


def first_exec_log(since: float, until: float) -> dict:
    """The unified log's FIRST_EXEC_LOG lines between SINCE and UNTIL (epoch seconds): a count per process and the
    first lines, best effort."""
    fmt = "%Y-%m-%d %H:%M:%S"
    out = run_text(["/usr/bin/log", "show", "--style", "compact", "--info", "--debug",
                    "--start", time.strftime(fmt, time.localtime(since)),
                    "--end", time.strftime(fmt, time.localtime(until + 1)), "--predicate", FIRST_EXEC_LOG], timeout=180)
    lines = [line[:300] for line in out.splitlines() if line and not line.startswith(("Timestamp", "Filtering"))]
    counts: dict[str, int] = {}
    for line in lines:
        parts = line.split()
        who = parts[3].split("[")[0] if len(parts) > 3 else "?"
        counts[who] = counts.get(who, 0) + 1
    return {"count": len(lines), "by_process": counts, "lines": lines[:400]}


def extra_arm(smoke, mount_app: Path, bundle_id: str, executable: str, seconds: float, arm: str) -> dict:
    """One EXTRA_ARMS launch, on its own new copy and a new home."""
    root = Path(tempfile.mkdtemp(prefix="cmux-nfl-", dir="/tmp"))
    try:
        stage = root / "stage"
        stage.mkdir()
        app = smoke.copy_app(mount_app, stage)
        before: dict = {}
        with smoke.DefaultsAside(bundle_id, root):
            if arm in ("prewarm-main", "prewarm-moved", "prewarm-bins-moved", "prewarm-helpers-moved",
                       "prewarm-pages-moved", "prewarm-chromium-moved"):
                (root / "w").mkdir()
                before = prewarm_until_main(smoke, root, app, executable, root / "w")
                if arm in ("prewarm-bins-moved", "prewarm-helpers-moved", "prewarm-pages-moved", "prewarm-chromium-moved"):
                    for name in PREWARM_BINS:
                        binary = app / "Contents" / "Resources" / "bin" / name
                        if binary.exists():
                            started = time.monotonic()
                            run_text([str(binary), "--version"], timeout=60)
                            before[f"{name}_s"] = round(time.monotonic() - started, 3)
                if arm in ("prewarm-helpers-moved", "prewarm-pages-moved", "prewarm-chromium-moved"):
                    # Each Chromium helper with no --type: it loads the CEF framework (LoadInHelper), then
                    # CefExecuteProcess returns at once for a process that is no subprocess (helper_main.mm).
                    for helper in sorted((app / "Contents" / "Frameworks").glob("* Helper*.app")):
                        binary = helper / "Contents" / "MacOS" / helper.stem
                        if binary.exists():
                            started = time.monotonic()
                            out = run_text([str(binary), "--version"], timeout=60)
                            before[f"{helper.stem}_s"] = round(time.monotonic() - started, 3)
                            before[f"{helper.stem}_out"] = out[-160:]
                if arm == "prewarm-pages-moved":
                    before["pages"] = touch_pages(app / "Contents" / "Frameworks")
                if arm == "prewarm-chromium-moved":
                    # The update path's last run (StagedUpdatePrewarm.chromiumArgument): Chromium's first real start
                    # in this copy, in a throwaway profile; exit 0 when its hidden page loaded (CEFStagedPrewarm).
                    started = time.monotonic()
                    try:
                        done = subprocess.run([str(app / "Contents" / "MacOS" / executable), "--cmux-prewarm-chromium"],
                                              capture_output=True, text=True, timeout=60)
                        before["chromium_exit"] = done.returncode
                        before["chromium_out"] = (done.stdout + done.stderr).strip()[-300:]
                    except (OSError, subprocess.SubprocessError) as error:
                        before["chromium_exit"] = f"error: {error}"
                    before["chromium_s"] = round(time.monotonic() - started, 3)
            elif arm == "prewarm-home":
                (root / "w").mkdir()
                started = time.monotonic()
                run = launch(smoke, root, app, executable, root / "w", 0.0, "prewarm")
                before = {"seconds": round(time.monotonic() - started, 3), "rendered_at": run["rendered_at"]}
            elif arm == "spctl":
                started = time.monotonic()
                before = {"spctl": run_text(["spctl", "--assess", "--type", "execute", "-vv", str(app)], timeout=600)[:400],
                          "seconds": round(time.monotonic() - started, 3)}
            elif arm == "adhoc-copy":
                started = time.monotonic()
                before = {"codesign": adhoc_sign(app), "seconds": round(time.monotonic() - started, 3)}
            elif arm in ("gktool", "gktool-moved"):
                started = time.monotonic()
                before = {"gktool": run_text(["/usr/bin/gktool", "scan", str(app)], timeout=900)[-400:],
                          "seconds": round(time.monotonic() - started, 3)}
            if arm in ("prewarm-moved", "prewarm-bins-moved", "prewarm-helpers-moved", "prewarm-pages-moved",
                       "prewarm-chromium-moved", "prewarm-home", "gktool-moved"):
                placed = root / "placed"
                placed.mkdir()
                os.rename(app.parent, placed / "app")
                app = placed / "app" / app.name
            (root / "m").mkdir()
            row = launch(smoke, root, app, executable, root / "m", seconds, "measured")
        return {"arm": arm, "before": before, **row}
    finally:
        smoke.stop(smoke.own_pids(root))
        shutil.rmtree(root, ignore_errors=True)


def round_once(smoke, mount_app: Path, bundle_id: str, executable: str, seconds: float, index: int,
               report: dict, more: tuple = (), log_first_exec: bool = False) -> list[dict]:
    root = Path(tempfile.mkdtemp(prefix="cmux-nfl-", dir="/tmp"))
    rows: list[dict] = []
    try:
        started = time.monotonic()
        app = smoke.copy_app(mount_app, root)
        copy_s = time.monotonic() - started
        if index == 1:
            report["facts"] = facts(app, executable, copy_s)
            print("NFL-FACT", json.dumps(report["facts"]), flush=True)
        first, second = root / "a", root / "b"
        first.mkdir()
        second.mkdir()
        with smoke.DefaultsAside(bundle_id, root):
            since = time.time()
            rows.append({"arm": "fresh-copy", **launch(smoke, root, app, executable, first, seconds, "fresh", sample=index == 1)})
            if log_first_exec:
                log = rows[-1]["first_exec_log"] = first_exec_log(since, since + 6)
                print("NFL-FIRST-EXEC-LOG", index, json.dumps({k: log[k] for k in ("count", "by_process")}), flush=True)
                for line in log["lines"][:150]:
                    print("NFL-LOG", index, line, flush=True)
        with smoke.DefaultsAside(bundle_id, root):
            rows.append({"arm": "same-copy", **launch(smoke, root, app, executable, second, seconds, "same", sample=index == 1)})
            rows.append({"arm": "warm", **launch(smoke, root, app, executable, second, seconds, "warm")})
        if more:
            for arm in more:
                rows.append(extra_arm(smoke, mount_app, bundle_id, executable, seconds, arm))
        for row in rows:
            row["round"] = index
            print("NFL-LAUNCH", index, row["arm"],
                  json.dumps({k: row[k] for k in ("exit", "rendered_at", "phases", "before") if k in row}), flush=True)
            print("NFL-MARKS", index, row["arm"], json.dumps(row["marks"]), flush=True)
            print("NFL-REPEATS", index, row["arm"], json.dumps(row["repeats"]), flush=True)
            for line in row.get("sample_main") or []:
                print("NFL-SAMPLE", index, row["arm"], line, flush=True)
    finally:
        smoke.stop(smoke.own_pids(root))
        shutil.rmtree(root, ignore_errors=True)
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=2, choices=range(1, 6))
    parser.add_argument("--seconds", type=float, default=8.0)
    parser.add_argument("--arms", choices=("base", "extra", "prewarm", "adhoc"), default="base",
                        help="extra: also the EXTRA_ARMS and the unified log around each fresh-copy launch; prewarm: also the PREWARM_ARMS")
    args = parser.parse_args(argv)
    more = {"extra": EXTRA_ARMS, "prewarm": PREWARM_ARMS, "adhoc": ADHOC_ARMS}.get(args.arms, ())
    os.umask(0o022)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    smoke = load_smoke()
    report: dict = {"dmg": args.dmg, "launches": []}
    problem = smoke.gui_session_problem()
    if smoke.signing_keychains_present() or problem:
        print(f"NFL cannot run: {problem or 'a signing keychain is present'}", flush=True)
        return 3
    mount = Path(tempfile.mkdtemp(prefix="cmux-nfl-mnt-", dir="/tmp"))
    status = 0
    try:
        subprocess.run(["hdiutil", "attach", args.dmg, "-nobrowse", "-readonly", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=300)
        apps = sorted(mount.glob("*.app"))
        if not apps:
            print("NFL cannot run: no app in the DMG", flush=True)
            return 3
        bundle_id, executable = smoke.bundle_info(apps[0])
        report["bundle_id"] = bundle_id
        for index in range(1, args.rounds + 1):
            rows = round_once(smoke, apps[0], bundle_id, executable, args.seconds, index, report, more=more,
                              log_first_exec=args.arms == "extra")
            report["launches"].extend(rows)
            # A diagnostic arm that cannot launch (ADHOC_ARMS) is reported in its own NFL-LAUNCH line, not as the step's failure.
            if any(row["rendered_at"] is None for row in rows if row["arm"] not in ADHOC_ARMS):
                status = 1
    except (smoke.CannotRun, OSError, subprocess.SubprocessError) as error:
        print(f"NFL cannot run: {error}", flush=True)
        status = 3
    finally:
        smoke.detach(mount)
        shutil.rmtree(mount, ignore_errors=True)
    medians = {}
    for arm in ARMS + more:
        rows = [r for r in report["launches"] if r["arm"] == arm and r["rendered_at"] is not None]
        med = {}
        for key in ("pre_main", "to_frame", "to_page", "frame", "page", "harness"):
            vals = [r["phases"][key] for r in rows if r["phases"].get(key) is not None]
            med[key] = round(statistics.median(vals), 1) if vals else None
        medians[arm] = {"n": len(rows), **med}
        print("NFL-MEDIAN", arm, json.dumps(medians[arm]), flush=True)
    report["medians"] = medians
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"NFL verdict exit {status}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
