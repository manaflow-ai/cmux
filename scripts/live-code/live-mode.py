#!/usr/bin/env python3
"""Swift live mode: restart a running tagged cmux NEXT into its live code build, and back.

Leo (2026-11-05): "toggling it on will slow things because the functions become more... loose? But
there should likely be a way to switch it on and off for when you're hot-building", then: "Yes
build that 'restart into the live-code build and back'".

The live code build (scripts/live-code/build.sh: CmuxNextApp unoptimized, a file at a time,
interposable calls) is slower and bigger than the normal build, and that cost is in how the app is
built, so live mode swaps builds instead of flipping a setting:

  start   build (once per commit, cached) the live code build of the commit the app runs, turn
          Labs > Live Code (`labs.liveCode`) on, and restart into it keeping every session.
  stop    turn Live Code off and restart into the normal build of the same commit, sessions kept.
  status  one line: which build runs, since when, and the patches applied.
  patch   compile edited Swift files against the running live code build (scripts/live-code/patch.py).

  scripts/live-code/live-mode.py start [--tag TAG] [--detach] [--json]
  scripts/live-code/live-mode.py stop|status [--tag TAG] [--json]
  scripts/live-code/live-mode.py patch [--tag TAG] FILE.swift...

Only a tagged DEV build switches (`scripts/reload.sh --tag TAG`). A NIGHTLY has no live code
variant to restart into yet, and a Release build loads only team-signed patches (cmux#13742).

Per commit, ~/Library/Caches/cmux-next/live-mode/<tag>/<commit>/ keeps the build folder (its
xcodebuild.log is what patches compile with) and whichever app is not installed: live.app while
the normal build runs, normal.app while the live one does. A swap is two renames on one volume.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
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


def running_commit(info, tree):
    """The commit the app was built from: CMUXCommit, else the HEAD of the checkout it names."""
    commit = info.get("CMUXCommit") or ""
    if re.fullmatch(r"[0-9a-f]{7,40}", commit):
        return commit
    root = (info.get("LSEnvironment") or {}).get("CMUXTERM_REPO_ROOT") or str(tree)
    return git(root, "rev-parse", "HEAD")


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


def swap(path, ident, into, keep_as):
    """Quit the app behind `path` keeping sessions, install `into` at its bundle path (the
    installed one goes to `keep_as`), start it, and wait for it. Returns the timings and sessions."""
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
        raise
    how = launch(app, ident["bundle_id"])
    wait_ready(path)
    ready = time.monotonic()
    after = sessions(path)
    return {"restart_s": round(ready - started, 2), "quit_s": round(down - started, 2),
            "launch_s": round(ready - down, 2), "launched_by": how, "sessions": kept(before, after),
            "binary": binary_id(app)}


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


def start(args):
    path = socket_path(args)
    ident = identify(path)
    tag = ident.get("tag") or args.tag or os.environ.get("CMUX_TAG") or ""
    root = cache_root(slug(tag))
    state = read_state(root)
    app = ident["app_bundle_path"]
    if state.get("mode") == "live" and state.get("binary") == binary_id(app):
        return {"mode": "live", "already": True, **state}
    info = app_info(app)
    commit = running_commit(info, args.tree)
    if not commit:
        raise Refused("cannot tell which commit the running app was built from")
    head = git(args.tree, "rev-parse", "HEAD")
    if not same_commit(commit, head):
        raise Refused(f"the running app is {commit[:12]}, {args.tree} is at {head[:12]}: check that commit out "
                      f"(or pass --tree) so the live code build and your patches match the app")
    entry = root / commit[:12]
    log = root / "live-mode.log"
    built_s = None
    # The tag's live derived data holds one commit's intermediates, which patches compile against:
    # an entry is good only while it is that commit's.
    holds = (root / "derived-data.commit")
    current = holds.read_text().strip() if holds.is_file() else ""
    if not ((entry / "live.app").is_dir() and (entry / "build/xcodebuild.log").is_file() and current == commit):
        print(f"live mode: building the live code build of {commit[:12]} (once per commit; log {log})",
              file=sys.stderr, flush=True)
        holds.unlink(missing_ok=True)  # a build that stops half way leaves no commit's intermediates
        built_s = build_live(args.tree, tag, entry, log, app)
        holds.write_text(commit + "\n")
    setting = "skipped" if args.setting_done else live_code_setting(path, True)
    result = swap(path, ident, into=entry / "live.app", keep_as=entry / "normal.app")
    state = {"mode": "live", "commit": commit, "tag": tag, "app": app, "since": now(),
             "entry": str(entry), "binary": result["binary"], "tree": str(args.tree)}
    write_state(root, state)
    return {**state, **result, "built_s": built_s, "setting": setting}


def stop(args):
    path = socket_path(args)
    ident = identify(path)
    tag = ident.get("tag") or args.tag or os.environ.get("CMUX_TAG") or ""
    root = cache_root(slug(tag))
    state = read_state(root)
    app = ident["app_bundle_path"]
    if state.get("mode") != "live" or state.get("binary") != binary_id(app):
        return {"mode": "normal", "already": True}
    entry = Path(state["entry"])
    if not (entry / "normal.app").is_dir():
        raise Refused(f"the normal build of {state['commit'][:12]} is gone from {entry}: "
                      f"run scripts/reload.sh --tag {tag} to build it")
    setting = "skipped" if args.setting_done else live_code_setting(path, False)
    result = swap(path, ident, into=entry / "normal.app", keep_as=entry / "live.app")
    state = {"mode": "normal", "commit": state["commit"], "tag": tag, "app": app, "since": now(),
             "entry": str(entry), "binary": result["binary"], "tree": state.get("tree", str(args.tree))}
    write_state(root, state)
    return {**state, **result, "setting": setting}


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


def status(args):
    try:
        path = socket_path(args)
    except Refused:
        path = None
    tag = args.tag or os.environ.get("CMUX_TAG") or ""
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
    return result


def line(result):
    """`cmux live status`'s Swift line."""
    if result.get("mode") == "live":
        text = (f"Swift live mode: on, cmux DEV {result.get('tag')} runs the live code build of "
                f"{(result.get('commit') or '')[:12]} since {result.get('since')}")
        if "applied" in result:
            text += f"; {result['applied']} patch(es) applied, {result['refused']} refused"
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
    what = "the live code build" if verb == "start" else "the normal build"
    built = f"; built in {result['built_s']} s" if result.get("built_s") else ""
    return (f"Swift live mode {'on' if verb == 'start' else 'off'}: restarted into {what} of "
            f"{result['commit'][:12]} in {result['restart_s']} s (quit {result['quit_s']} s, launch "
            f"{result['launch_s']} s); {kept_text}{built}")


def patch(args):
    path = socket_path(args)
    ident = identify(path)
    root = cache_root(slug(ident.get("tag") or ""))
    state = read_state(root)
    if state.get("mode") != "live" or state.get("binary") != binary_id(ident["app_bundle_path"]):
        raise Refused("live mode is off: run `cmux live start --swift` first")
    command = [sys.executable, str(TREE / "scripts/live-code/patch.py"), "--log",
               str(Path(state["entry"]) / "build/xcodebuild.log"), "--module", "CmuxNextApp",
               "--live", str(live_folder()), *args.files]
    return subprocess.run(command, cwd=args.tree).returncode


def detach(argv, root):
    """Run this command again in its own session, so the app quitting does not end it (the app's
    Live Mode buttons run it as their child). Its output goes to the log."""
    root.mkdir(parents=True, exist_ok=True)
    log = root / "live-mode.log"
    with open(log, "a") as out:
        out.write(f"\n== {now()} {' '.join(argv)}\n")
        subprocess.Popen([sys.executable, __file__, *argv], stdout=out, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True, cwd=TREE)
    return log


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("verb", choices=["start", "stop", "status", "patch"])
    parser.add_argument("files", nargs="*")
    parser.add_argument("--tag")
    parser.add_argument("--socket")
    parser.add_argument("--tree", type=Path, default=TREE)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--detach", action="store_true", help="start or stop in the background (the app's buttons)")
    parser.add_argument("--setting-done", action="store_true",
                        help="the app already set labs.liveCode (its Live Mode button, the person's click)")
    args = parser.parse_args(argv)
    try:
        if args.verb == "patch":
            return patch(args)
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
