#!/usr/bin/env python3
"""Swift live mode: restart a running tagged cmux NEXT into its live code build, and back.

Leo (2026-11-05): "toggling it on will slow things because the functions become more... loose? But
there should likely be a way to switch it on and off for when you're hot-building", then: "Yes
build that 'restart into the live-code build and back'".

The live code build (scripts/live-code/build.sh: CmuxNextApp unoptimized, a file at a time,
interposable calls) is slower and bigger than the normal build, and that cost is in how the app is
built, so live mode swaps builds instead of flipping a setting.

Then: "For the swift bit why can't we simply apply after switching the build?" So it is one flow:

  start   build (once per commit, cached) the live code build of the checkout's HEAD, turn
          Labs > Live Code (`labs.liveCode`) on, restart into it keeping every session, and patch
          in every CmuxNextApp file that differs from what that build compiled: the edits apply now.
  watch   (started by start, in the background) patch each saved file in; once saves go quiet,
          make the optimized build of the edited checkout. Ends when live mode does.
  stop    turn Live Code off and restart into that optimized build, sessions kept (`--discard`:
          the build that ran before live mode).
  status  one line: which build runs, since when, the patches, what waits for the stop build.
  patch   compile edited Swift files against the running live code build (scripts/live-code/patch.py).

  scripts/live-code/live-mode.py start [--tag TAG] [--detach] [--json]
  scripts/live-code/live-mode.py stop [--discard] [--tag TAG] [--detach] [--json]
  scripts/live-code/live-mode.py status [--tag TAG] [--json]
  scripts/live-code/live-mode.py patch [--tag TAG] FILE.swift...

Edits that can't apply live wait for the stop build: a stored property or other change of a
type's layout (the app refuses the patch), a file of another module, a new or deleted file.

Only a tagged DEV build switches (`scripts/reload.sh --tag TAG`). A NIGHTLY has no live code
variant to restart into yet, and a Release build loads only team-signed patches (cmux#13742).

~/Library/Caches/cmux-next/live-mode/<tag>/ keeps, per commit, the live build folder (its
xcodebuild.log is what patches compile with), the Swift it compiled and live.app while it is not
installed; before.app, the build that ran before live mode; edited.app, the optimized build of the
edited checkout. A swap is two renames on one volume.
"""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

TREE = Path(__file__).resolve().parents[2]
QUIT_TIMEOUT_S = 30
FORCE_EXIT_TIMEOUT_S = 5
LAUNCH_TIMEOUT_S = 120
LOADED_TIMEOUT_S = 60
NIGHTLY_REFUSAL = (
    "live mode switches only a tagged DEV build (scripts/reload.sh --tag TAG). This app is {bundle}: "
    "a NIGHTLY has no live code build of its commit to restart into, and a Release build would load "
    "only team-signed patches (cmux#13742), which a person's own checkout cannot make. On a NIGHTLY "
    "you can try a pull request's web side live (cmux live start) and its Swift side in a copy "
    "(scripts/cmux-next/try-pr.sh N --live-code LOG); you can't patch the NIGHTLY's own Swift."
)


class Refused(Exception):
    """What the person reads, with exit code 1."""


def slug(tag):
    """reload.sh's tag slug (scripts/lib/mobile-attach.sh cmux_attach__slug_raw)."""
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.lower())).strip("-")


def cache_root(tag_slug, home=None):
    home = Path(home or os.environ.get("HOME") or Path.home())
    return home / "Library/Caches/cmux-next/live-mode" / tag_slug


def live_folder(home=None):
    """The folder Labs > Live Code watches (LiveCode.labsSwitch)."""
    home = Path(home or os.environ.get("HOME") or Path.home())
    return home / "Library/Caches/cmux-next/live-code"


def socket_path(args):
    if args.socket:
        return args.socket
    tag = args.tag or os.environ.get("CMUX_TAG")
    if not tag:
        named = re.search(r"/cmux-debug-([a-z0-9-]+)\.sock$", os.environ.get("CMUX_SOCKET_PATH", ""))
        tag = named.group(1) if named else None
    if tag:
        return tagged_socket(slug(tag))
    raise Refused("name the tagged build: --tag TAG (or run this in one of its terminals)")


def tagged_socket(tag_slug, home=None):
    """A tagged DEV build's control socket (ControlSocketPath.swift): the state folder's, which the
    app keeps a /tmp link to; the /tmp name when only it is there (a path too long to move)."""
    home = Path(home or os.environ.get("HOME") or Path.home())
    state, old = home / f".local/state/cmux/cmux-debug-{tag_slug}.sock", Path(f"/tmp/cmux-debug-{tag_slug}.sock")
    return str(old if old.exists() and not state.exists() else state)


def call(path, method, params=None, timeout=10.0):
    """One request on the app's control socket; the result, or raises Refused with its error."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    answer = json.loads(data or b"{}")
    if answer.get("error"):
        error = answer["error"]
        raise Refused(error.get("message") if isinstance(error, dict) else str(error))
    return answer.get("result")


def answers(path):
    try:
        call(path, "system.ping", timeout=2.0)
        return True
    except (OSError, ValueError, Refused):
        return False


def app_info(app):
    with open(Path(app) / "Contents/Info.plist", "rb") as f:
        return plistlib.load(f)


def executable(app):
    info = app_info(app)
    return Path(app) / "Contents/MacOS" / info.get("CFBundleExecutable", "cmux")


def binary_id(app):
    """The installed executable's identity: a rename keeps it, a new build changes it."""
    st = os.stat(executable(app))
    return f"{st.st_dev}:{st.st_ino}"


def git(tree, *argv):
    out = subprocess.run(["git", "-C", str(tree), *argv], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else ""


def same_commit(left, right):
    """Whether two commit names (full or abbreviated, at least 7 hex digits) name one commit."""
    short = min(len(left), len(right))
    return short >= 7 and left[:short] == right[:short]


def sessions(path):
    """Workspace ids and terminal ids the app shows (snapshot.get), to compare across a restart."""
    topology = (call(path, "snapshot.get", timeout=10.0) or {}).get("topology") or {}
    return topology_sessions(topology)


def topology_sessions(topology):
    """Workspace ids, tab ids and the terminals still running (a tab whose terminal is not `dead`)."""
    workspaces, tabs, terminals = set(), set(), set()
    for workspace in topology.get("workspaces") or []:
        if workspace.get("id"):
            workspaces.add(workspace["id"])
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id"):
                        tabs.add(tab["id"])
                    if tab.get("terminal") and not tab.get("dead"):
                        terminals.add(tab["terminal"])
    return {"workspaces": sorted(workspaces), "tabs": sorted(tabs), "terminals": sorted(terminals),
            "loaded": bool(topology.get("loaded"))}


def kept(before, after):
    """Every workspace, tab and running terminal from before the restart is there after it."""
    out, lost = {}, []
    for key in ("workspaces", "tabs", "terminals"):
        gone = sorted(set(before.get(key, [])) - set(after.get(key, [])))
        out[key] = f"{len(before.get(key, [])) - len(gone)}/{len(before.get(key, []))}"
        lost += gone
    return {**out, "all": not lost, "lost": lost}


def wait_exit(pid, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def quit_keep_sessions(pid):
    """SIGTERM is "Quit, keep sessions" with no alert (QuitSignal.swift), the stop reload.sh uses
    (scripts/lib/stop-app-instances.sh): a second SIGTERM is the force exit, never SIGKILL."""
    os.kill(pid, signal.SIGTERM)
    if wait_exit(pid, QUIT_TIMEOUT_S):
        return
    os.kill(pid, signal.SIGTERM)
    if not wait_exit(pid, FORCE_EXIT_TIMEOUT_S):
        raise Refused(f"cmux (pid {pid}) did not quit; nothing was swapped")


def move(source, target):
    """Rename `source` to `target` (one volume: instant), else copy it with ditto and remove it."""
    source, target = Path(source), Path(target)
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(source, target)
    except OSError:
        subprocess.run(["/usr/bin/ditto", str(source), str(target)], check=True)
        shutil.rmtree(source)


def launch(app, bundle_id):
    """Start the swapped bundle the way its last reload did: the tag's one-shot launchd job holds the
    tagged environment (reload.sh), so run it again; without one, open the bundle (its LSEnvironment
    carries the same values)."""
    label = f"gui/{os.getuid()}/{bundle_id}.reload"
    if subprocess.run(["/bin/launchctl", "print", label], capture_output=True).returncode == 0:
        if subprocess.run(["/bin/launchctl", "kickstart", label], capture_output=True).returncode == 0:
            return "launchd"
    subprocess.run(["/usr/bin/open", "-n", "-g", str(app)], check=True)
    return "open"


def wait_ready(path, timeout_answer=LAUNCH_TIMEOUT_S, timeout_loaded=LOADED_TIMEOUT_S):
    end = time.monotonic() + timeout_answer
    while not answers(path):
        if time.monotonic() > end:
            raise Refused(f"the restarted app did not answer on {path} within {timeout_answer} s")
        time.sleep(0.1)
    end = time.monotonic() + timeout_loaded
    while True:
        try:
            if sessions(path)["loaded"]:
                return
        except (OSError, ValueError, Refused):
            pass
        if time.monotonic() > end:
            return
        time.sleep(0.1)


def swap(path, ident, into, keep_as, swapped=None):
    """Quit the app behind `path` keeping sessions, install `into` at its bundle path (the
    installed one goes to `keep_as`), start it, and wait for it. `swapped(binary)` runs once the
    bundles are renamed, before the launch, so the state on disk already names what is installed.
    A launch that fails puts the old bundle back and starts it. Returns the timings and sessions."""
    app = ident["app_bundle_path"]
    before = sessions(path)
    started = time.monotonic()
    quit_keep_sessions(int(ident["pid"]))
    down = time.monotonic()
    move(app, keep_as)
    try:
        move(into, app)
    except Exception:
        move(keep_as, app)
        launch(app, ident["bundle_id"])
        raise
    if swapped:
        swapped(binary_id(app))
    try:
        how = launch(app, ident["bundle_id"])
        wait_ready(path)
    except (OSError, subprocess.CalledProcessError, Refused) as failure:
        undo_failed_launch(path, ident, app, into, keep_as, swapped)
        raise Refused(f"{failure}; the build that ran before is back") from failure
    ready = time.monotonic()
    after = sessions(path)
    return {"restart_s": round(ready - started, 2), "quit_s": round(down - started, 2),
            "launch_s": round(ready - down, 2), "launched_by": how, "sessions": kept(before, after),
            "binary": binary_id(app)}


def undo_failed_launch(path, ident, app, into, keep_as, swapped):
    """The swapped build did not come up: quit whatever of it runs, rename the bundles back and
    start the old one, so the person is never left without their app."""
    if answers(path):
        try:
            quit_keep_sessions(int((call(path, "system.identify") or {}).get("pid") or 0))
        except (OSError, ValueError, Refused):
            pass
    move(app, into)
    move(keep_as, app)
    if swapped:
        swapped(None)
    launch(app, ident["bundle_id"])
    wait_ready(path)


def live_code_setting(path, on):
    """Labs > Live Code. A socket write of this user-only key asks the person on a native sheet
    (`--confirm`), so an agent cannot turn it on alone; the app's own button sets it first."""
    current = (call(path, "settings.get", {"path": ["labs", "liveCode"]}) or {}).get("value")
    if bool(current) == on:
        return "unchanged"
    print(f"live mode: approve Labs > Live Code {'on' if on else 'off'} in cmux", file=sys.stderr, flush=True)
    call(path, "settings.set", {"path": ["labs", "liveCode"], "value": on, "confirm": True}, timeout=125.0)
    return "set"


def read_state(root):
    try:
        return json.loads((root / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def write_state(root, state):
    root.mkdir(parents=True, exist_ok=True)
    (root / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    # `cmux live stop|status --swift` finds this checkout's script from here when run elsewhere.
    (root.parent / "tree").write_text(str(TREE) + "\n")


def identify(path):
    if not answers(path):
        raise Refused(f"no tagged cmux answers on {path}")
    ident = call(path, "system.identify") or {}
    bundle = ident.get("bundle_id") or "?"
    if not bundle.startswith("com.cmuxterm.app.debug.") or not ident.get("app_bundle_path"):
        raise Refused(NIGHTLY_REFUSAL.format(bundle=bundle))
    return ident


def build_live(tree, tag, entry, log, installed):
    """scripts/live-code/build.sh, build-only: the running app keeps running while it builds. It
    builds in the tag's own live derived data (beside the commits' entries, reused from commit to
    commit), so the normal build's derived data is untouched and a patch compiles against the live
    build's intermediates."""
    entry.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CMUX_LIVE_CODE_KEEP_APP=str(entry / "live.app"),
               CMUX_LIVE_CODE_DERIVED_DATA=str(entry.parent / "derived-data"), CMUX_RELOAD_INSTALLED_APP=str(installed))
    started = time.monotonic()
    with open(log, "a") as out:
        done = subprocess.run(["bash", str(tree / "scripts/live-code/build.sh"), str(entry / "build"), tag, "debug"],
                              cwd=tree, env=env, stdout=out, stderr=subprocess.STDOUT)
    if done.returncode != 0 or not (entry / "live.app").is_dir():
        raise Refused(f"the live code build failed; its log is {log}")
    return round(time.monotonic() - started, 1)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# The edited tree. The live code build compiles the checkout as it is; a patch compiles a file of
# CmuxNextApp against that build. So each live build records the Swift it was compiled from, and
# every file that differs from it later is patched in (start), or waits for a build (stop).
SOURCES = "Packages/macOS/CmuxNext/Sources"
PATCHED_MODULE = "CmuxNextApp"
QUIET_S = 20  # no save for this long: the optimized build of the edits starts in the background
WATCH_MAX_S = 24 * 3600


def swift_sources(tree, seen=None):
    """{relative path: (mtime_ns, sha1)} of the app's Swift sources. `seen` (the last answer) skips
    hashing a file whose mtime did not move, so a watcher's scan reads only what was saved."""
    out = {}
    base = Path(tree) / SOURCES
    for path in base.rglob("*.swift"):
        rel = str(path.relative_to(tree))
        try:
            mtime = path.stat().st_mtime_ns
        except OSError:
            continue
        old = (seen or {}).get(rel)
        if old and old[0] == mtime:
            out[rel] = old
            continue
        try:
            out[rel] = (mtime, hashlib.sha1(path.read_bytes()).hexdigest())
        except OSError:
            continue
    return out


def changed_sources(built, now_sources):
    """Files that differ from what the live build compiled: (patchable, waiting). Only an existing
    CmuxNextApp file patches in; a file of another module, a new file or a deleted one waits for
    the optimized build that stop restarts into."""
    patchable, waiting = [], []
    for rel in sorted(set(built) | set(now_sources)):
        was, is_ = built.get(rel), now_sources.get(rel)
        if (was and was[1]) == (is_ and is_[1]):
            continue
        in_app = rel.startswith(f"{SOURCES}/{PATCHED_MODULE}/")
        (patchable if in_app and was and is_ else waiting).append(rel)
    return patchable, waiting


def save_sources(path, sources):
    path.write_text(json.dumps({rel: list(v) for rel, v in sources.items()}) + "\n")


def load_sources(path):
    try:
        return {rel: tuple(v) for rel, v in json.loads(path.read_text()).items()}
    except (OSError, ValueError):
        return {}


def tree_hash(tree):
    """The checkout as it is on disk, edits and new files included, as one git tree id: a copy of
    the index takes `git add -A` (only changed files are hashed again) and `git write-tree`."""
    index = git(tree, "rev-parse", "--git-path", "index")
    if not index:
        return ""
    index = Path(index) if Path(index).is_absolute() else Path(tree) / index
    with tempfile.TemporaryDirectory(prefix="cmux-live-mode-") as scratch:
        copy = Path(scratch) / "index"
        if index.exists():
            shutil.copyfile(index, copy)
        env = dict(os.environ, GIT_INDEX_FILE=str(copy))
        if subprocess.run(["git", "-C", str(tree), "add", "-A"], env=env, capture_output=True).returncode != 0:
            return ""
        out = subprocess.run(["git", "-C", str(tree), "write-tree"], env=env, capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 else ""


class SwapLock:
    """One start or stop at a time per tag: a second one is refused at once instead of renaming
    bundles under the first or quitting a process the first already replaced."""

    def __init__(self, root):
        root.mkdir(parents=True, exist_ok=True)
        self.file = open(root / "swap.lock", "w")

    def __enter__(self):
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.file.close()
            raise Refused("another live mode start or stop runs for this build; wait for it") from None
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.file, fcntl.LOCK_UN)
        self.file.close()


def with_setting_back(path, on, changed, swap_it):
    """Runs the swap; if it fails after Labs > Live Code was changed for it, puts the setting back,
    so a failed start leaves no normal build watching and a failed stop no live build blind."""
    try:
        return swap_it()
    except Refused:
        if changed:
            try:
                live_code_setting(path, not on)
            except (OSError, ValueError, Refused):
                pass
        raise


class BuildLock:
    """One optimized build at a time per tag (the watcher's background one, or stop's)."""

    def __init__(self, root):
        root.mkdir(parents=True, exist_ok=True)
        self.file = open(root / "build.lock", "w")

    def __enter__(self):
        fcntl.flock(self.file, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.file, fcntl.LOCK_UN)
        self.file.close()


def build_optimized(tree, tag, root, installed, log):
    """The normal build of the edited checkout (scripts/reload.sh --tag TAG --build-only), in the
    tag's own derived data, so it is the incremental build a reload of this checkout is, kept beside
    the installed app as edited.app with the tree it was built from. At background priority."""
    with BuildLock(root):
        tree_id = tree_hash(tree)
        if tree_id and read_json(root / "edited.json").get("tree") == tree_id and (root / "edited.app").is_dir():
            return {"tree": tree_id, "built_s": 0}
        building = root / "edited-building.app"
        env = dict(os.environ, CMUX_RELOAD_INSTALLED_APP=str(installed))
        started = time.monotonic()
        with open(log, "a") as out:
            out.write(f"\n== {now()} optimized build of {tree_id[:12]}\n")
            out.flush()
            done = subprocess.run(["nice", "-n", "10", "bash", str(Path(tree) / "scripts/reload.sh"), "--tag", tag,
                                   "--build-only", "--keep-app", str(building)],
                                  cwd=tree, env=env, stdout=out, stderr=subprocess.STDOUT)
        if done.returncode != 0 or not building.is_dir():
            raise Refused(f"the optimized build of your edits failed; its log is {log}")
        move(building, root / "edited.app")
        (root / "edited.json").write_text(json.dumps({"tree": tree_id, "built": now()}) + "\n")
        return {"tree": tree_id, "built_s": round(time.monotonic() - started, 1)}


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def apply_edits(tree, entry, files):
    """Compile `files` (of CmuxNextApp) against the running live build into one patch."""
    if not files:
        return {"files": [], "exit": 0}
    command = [sys.executable, str(TREE / "scripts/live-code/patch.py"), "--log", str(entry / "build/xcodebuild.log"),
               "--module", PATCHED_MODULE, "--live", str(live_folder()), *[str(Path(tree) / f) for f in files]]
    done = subprocess.run(command, cwd=tree, capture_output=True, text=True)
    return {"files": files, "exit": done.returncode, "output": (done.stdout + done.stderr).strip()[-2000:]}


def start(args):
    path = socket_path(args)
    ident = identify(path)
    tag = ident.get("tag") or args.tag or os.environ.get("CMUX_TAG") or ""
    root = cache_root(slug(tag))
    with SwapLock(root):
        return start_locked(args, path, identify(path), tag, root)


def start_locked(args, path, ident, tag, root):
    state = read_state(root)
    app = ident["app_bundle_path"]
    if state.get("mode") == "live" and state.get("binary") == binary_id(app):
        return {"mode": "live", "already": True, **state}
    info = app_info(app)
    head = git(args.tree, "rev-parse", "HEAD")
    commit = info.get("CMUXCommit") or ""
    if re.fullmatch(r"[0-9a-f]{7,40}", commit) and not same_commit(commit, head):
        raise Refused(f"the running app is {commit[:12]}, {args.tree} is at {head[:12]}: check that commit out "
                      f"(or pass --tree) so the live code build and your patches match the app")
    if not head:
        raise Refused(f"{args.tree} is not a git checkout")
    entry = root / head[:12]
    log = root / "live-mode.log"
    built_s = None
    # The tag's live derived data holds one commit's intermediates, which patches compile against:
    # an entry is good only while it is that commit's.
    holds = root / "derived-data.commit"
    current = holds.read_text().strip() if holds.is_file() else ""
    built_from = entry / "sources.json"
    if not ((entry / "live.app").is_dir() and (entry / "build/xcodebuild.log").is_file() and current == head
            and built_from.is_file()):
        print(f"live mode: building the live code build of {head[:12]} (once per commit; log {log})",
              file=sys.stderr, flush=True)
        holds.unlink(missing_ok=True)  # a build that stops half way leaves no commit's intermediates
        entry.mkdir(parents=True, exist_ok=True)
        save_sources(built_from, swift_sources(args.tree))  # before: a save during the build patches in after
        built_s = build_live(args.tree, tag, entry, log, app)
        holds.write_text(head + "\n")
    setting = "skipped" if args.setting_done else live_code_setting(path, True)
    state = {"mode": "live", "commit": head, "tag": tag, "app": app, "since": now(), "entry": str(entry),
             "tree": str(args.tree)}

    def swapped(binary):
        write_state(root, {**state, "binary": binary} if binary else {**state, "mode": "normal", "binary": None})

    result = with_setting_back(path, True, setting != "unchanged", lambda: swap(
        path, ident, into=entry / "live.app", keep_as=root / "before.app", swapped=swapped))
    state["binary"] = result["binary"]
    # The person's edits since the live build compiled: in right away, then every save (watch).
    patchable, waiting = changed_sources(load_sources(built_from), swift_sources(args.tree))
    applied = apply_edits(args.tree, entry, patchable)
    if applied["exit"]:
        waiting = sorted(set(waiting) | set(patchable))  # did not compile: they wait for the stop build
    write_state(root, {**state, "waiting": waiting})
    watcher = detach(["watch", "--tag", tag, "--tree", str(args.tree)], root, quiet=True)
    return {**state, **result, "built_s": built_s, "setting": setting, "edits": applied, "waiting": waiting,
            "watcher": watcher}


def stop(args):
    path = socket_path(args)
    ident = identify(path)
    tag = ident.get("tag") or args.tag or os.environ.get("CMUX_TAG") or ""
    root = cache_root(slug(tag))
    with SwapLock(root):
        return stop_locked(args, path, identify(path), tag, root)


def stop_locked(args, path, ident, tag, root):
    state = read_state(root)
    app = ident["app_bundle_path"]
    if state.get("mode") != "live" or state.get("binary") != binary_id(app):
        return {"mode": "normal", "already": True}
    entry = Path(state["entry"])
    tree = Path(state.get("tree") or args.tree)
    log = root / "live-mode.log"
    built = None
    if args.discard:
        into, what = root / "before.app", "the build that ran before live mode (your edits stay on disk, not in it)"
        if not into.is_dir():
            raise Refused(f"the build from before live mode is gone from {root}: run scripts/reload.sh --tag {tag}")
    else:
        print("live mode: making the optimized build of your edits (the background one, if it is current)",
              file=sys.stderr, flush=True)
        built = build_optimized(tree, tag, root, app, log)
        into, what = root / "edited.app", "the optimized build of your edits"
    setting = "skipped" if args.setting_done else live_code_setting(path, False)
    off = {"mode": "normal", "commit": state["commit"], "tag": tag, "app": app, "since": now(),
           "entry": str(entry), "tree": str(tree)}

    def swapped(binary):
        write_state(root, {**off, "binary": binary} if binary else state)

    result = with_setting_back(path, False, setting != "unchanged", lambda: swap(
        path, ident, into=into, keep_as=entry / "live.app", swapped=swapped))
    if not args.discard:
        (root / "edited.json").unlink(missing_ok=True)  # edited.app is installed now
    write_state(root, {**off, "binary": result["binary"]})
    return {**off, **result, "setting": setting, "into": what, "optimized": built}


def watch(args):
    """While live mode is on: patch each saved CmuxNextApp file in, and once saves go quiet for
    QUIET_S, make the optimized build of the edited checkout so stop is only a restart. Stop
    condition: live mode is off (the installed build is not the live one), or WATCH_MAX_S."""
    tag = args.tag or ""
    root = cache_root(slug(tag))
    pid_file = root / "watch.pid"
    try:
        other = int(pid_file.read_text())
        os.kill(other, 0)
        if other != os.getpid():
            return 0  # one watcher per tag
    except (OSError, ValueError):
        pass
    pid_file.write_text(f"{os.getpid()}\n")
    state = read_state(root)
    tree, entry = Path(state.get("tree") or args.tree), Path(state.get("entry") or "")
    seen = swift_sources(tree)
    # Files whose last patch did not compile: they wait for the stop build until a save compiles.
    refused = {f for f in state.get("waiting") or [] if f.startswith(f"{SOURCES}/{PATCHED_MODULE}/")}
    built_tree, last_save = None, time.monotonic()
    started = time.monotonic()
    while time.monotonic() - started < WATCH_MAX_S:
        time.sleep(1.0)
        state = read_state(root)
        app = state.get("app")
        if state.get("mode") != "live" or not app or not Path(app).exists() or binary_id(app) != state.get("binary"):
            break
        now_sources = swift_sources(tree, seen)
        patchable, waiting = changed_sources(seen, now_sources)
        seen = now_sources
        if patchable or waiting:
            last_save = time.monotonic()
            applied = apply_edits(tree, entry, patchable)
            refused = (refused | set(patchable)) if applied["exit"] else (refused - set(patchable))
            print(f"{now()} saved {len(patchable) + len(waiting)} file(s): patch exit {applied['exit']}"
                  + (f"; waiting for the stop build: {', '.join(waiting)}" if waiting else ""), flush=True)
            # What waits is what differs from the live build now: a reverted file no longer waits.
            patchable_now, waiting_now = changed_sources(load_sources(entry / "sources.json"), now_sources)
            refused &= set(patchable_now)  # a reverted file no longer waits
            still = sorted(set(waiting_now) | refused)
            if still != (state.get("waiting") or []):
                try:
                    with SwapLock(root):  # never over a start or stop's state
                        fresh = read_state(root)
                        if fresh.get("mode") == "live" and fresh.get("binary") == state.get("binary"):
                            write_state(root, {**fresh, "waiting": still})
                except Refused:
                    pass  # a start or stop runs; the next save writes it
        if time.monotonic() - last_save >= QUIET_S:
            tree_id = tree_hash(tree)
            if tree_id and tree_id != built_tree and read_json(root / "edited.json").get("tree") != tree_id:
                try:
                    built = build_optimized(tree, tag, root, app, root / "live-mode.log")
                    print(f"{now()} optimized build of {built['tree'][:12]} ready in {built['built_s']} s", flush=True)
                except Refused as failure:
                    print(f"{now()} {failure}", flush=True)
            built_tree = tree_id
    pid_file.unlink(missing_ok=True)
    return 0


def patches(home=None):
    """Applied and refused lines in the live folder's log since the watcher last started."""
    try:
        lines = (live_folder(home) / "live-code.log").read_text(errors="replace").splitlines()
    except OSError:
        return {"applied": 0, "refused": 0}
    start_at = max((i for i, line in enumerate(lines) if "live code: watching" in line), default=-1)
    tail = lines[start_at + 1:]
    return {"applied": sum(" applied " in f" {line} " for line in tail) - sum("rolled back" in line for line in tail),
            "refused": sum("refused" in line for line in tail)}


def recorded_live_tag(home=None):
    """The tag a live mode was last started for, when no tag is named (a terminal outside cmux)."""
    newest = None
    for state_file in cache_root("", home).glob("*/state.json"):
        state = read_json(state_file)
        if state.get("mode") == "live" and state.get("tag") and (newest is None or state.get("since", "") > newest[0]):
            newest = (state.get("since", ""), state["tag"])
    return newest[1] if newest else None


def status(args):
    tag = args.tag or os.environ.get("CMUX_TAG") or ""
    try:
        path = socket_path(args)
    except Refused:
        tag = recorded_live_tag() or ""
        path = tagged_socket(slug(tag)) if tag else None
    ident = {}
    if path and answers(path):
        ident = call(path, "system.identify") or {}
        tag = ident.get("tag") or tag
    root = cache_root(slug(tag)) if tag else None
    state = read_state(root) if root else {}
    app = ident.get("app_bundle_path")
    on = bool(state.get("mode") == "live" and app and state.get("binary") == binary_id(app))
    result = {"mode": "live" if on else "normal", "tag": tag or None, "running": bool(ident),
              "commit": state.get("commit"), "since": state.get("since") if on else None}
    if on:
        result.update(patches())
        result["waiting"] = state.get("waiting") or []
        edited = read_json(root / "edited.json")
        result["stop_build"] = "ready" if edited.get("tree") and edited.get("tree") == tree_hash(state.get("tree") or args.tree) \
            else "not yet"
    return result


def line(result):
    """`cmux live status`'s Swift line."""
    if result.get("mode") == "live":
        text = (f"Swift live mode: on, cmux DEV {result.get('tag')} runs the live code build of "
                f"{(result.get('commit') or '')[:12]} since {result.get('since')}")
        if "applied" in result:
            text += f"; {result['applied']} patch(es) applied, {result['refused']} refused"
        if result.get("waiting"):
            text += f"; {len(result['waiting'])} file(s) wait for the stop build"
        if "stop_build" in result:
            text += f"; the optimized build of your edits is {result['stop_build']}"
        return text
    if result.get("running") is False and result.get("tag"):
        return f"Swift live mode: off (cmux DEV {result['tag']} is not running)"
    return "Swift live mode: off" + (f", cmux DEV {result['tag']} runs its normal build" if result.get("tag") else "")


def summary(verb, result):
    if result.get("already"):
        return line(dict(result, mode=result["mode"]))
    sessions_kept = result["sessions"]
    kept_text = (f"sessions kept: {sessions_kept['workspaces']} workspaces, {sessions_kept['tabs']} tabs, "
                 f"{sessions_kept['terminals']} running terminals"
                 + ("" if sessions_kept["all"] else f" (lost {', '.join(sessions_kept['lost'][:5])})"))
    what = f"the live code build of {result['commit'][:12]}" if verb == "start" else result.get("into", "the normal build")
    built = f"; built in {result['built_s']} s" if result.get("built_s") else ""
    text = (f"Swift live mode {'on' if verb == 'start' else 'off'}: restarted into {what} in {result['restart_s']} s "
            f"(quit {result['quit_s']} s, launch {result['launch_s']} s); {kept_text}{built}")
    edits = result.get("edits") or {}
    if edits.get("files"):
        text += f"; your edits to {len(edits['files'])} file(s) patched in (exit {edits['exit']})"
    if result.get("waiting"):
        text += (f"; {len(result['waiting'])} file(s) cannot patch in (another module, a new or deleted file) "
                 f"and wait for the stop build")
    return text


def patch(args):
    path = socket_path(args)
    ident = identify(path)
    root = cache_root(slug(ident.get("tag") or ""))
    state = read_state(root)
    if state.get("mode") != "live" or state.get("binary") != binary_id(ident["app_bundle_path"]):
        raise Refused("live mode is off: run `cmux live start --swift` first")
    command = [sys.executable, str(TREE / "scripts/live-code/patch.py"), "--log",
               str(Path(state["entry"]) / "build/xcodebuild.log"), "--module", PATCHED_MODULE,
               "--live", str(live_folder()), *args.files]
    return subprocess.run(command, cwd=args.tree).returncode


def detach(argv, root, quiet=False):
    """Run this command again in its own session, so the app quitting does not end it (the app's
    Live Mode buttons run it as their child; start runs its watcher so). Its output goes to the log."""
    root.mkdir(parents=True, exist_ok=True)
    log = root / "live-mode.log"
    with open(log, "a") as out:
        out.write(f"\n== {now()} {' '.join(argv)}\n")
        subprocess.Popen([sys.executable, __file__, *argv], stdout=out, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True, cwd=TREE)
    return str(log)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("verb", choices=["start", "stop", "status", "patch", "watch"])
    parser.add_argument("files", nargs="*")
    parser.add_argument("--tag")
    parser.add_argument("--socket")
    parser.add_argument("--tree", type=Path, default=TREE)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--detach", action="store_true", help="start or stop in the background (the app's buttons)")
    parser.add_argument("--discard", action="store_true",
                        help="stop: restart into the build from before live mode, not the optimized build of your edits")
    parser.add_argument("--setting-done", action="store_true",
                        help="the app already set labs.liveCode (its Live Mode button, the person's click)")
    args = parser.parse_args(argv)
    try:
        if args.verb == "patch":
            return patch(args)
        if args.verb == "watch":
            return watch(args)
        if args.detach and args.verb in ("start", "stop"):
            tag = args.tag or os.environ.get("CMUX_TAG") or ""
            if not tag:
                tag = (call(socket_path(args), "system.identify") or {}).get("tag") or ""
            rest = [a for a in argv if a != "--detach"] + ([] if args.tag else ["--tag", tag])
            log = detach(rest, cache_root(slug(tag)))
            print(f"live mode: {args.verb} runs in the background; cmux restarts when it is ready (log {log})")
            return 0
        result = {"start": start, "stop": stop, "status": status}[args.verb](args)
    except Refused as refusal:
        print(f"live mode: {refusal}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, indent=2))
    elif args.verb == "status":
        print(line(result))
    else:
        print(summary(args.verb, result))
    return 0 if args.verb == "status" or result.get("already") or result["sessions"]["all"] else 2


if __name__ == "__main__":
    sys.exit(main())
