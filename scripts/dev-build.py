#!/usr/bin/env python3
"""Find and stop tagged cmux NEXT dev builds and every process they started.

A tagged dev build (`cmux DEV <tag>.app`) starts helpers that are detached on purpose: the
terminal owner (`cmux-tui --headless`), acpmux, the Chief host, `cmux-files-host`, `cmux-cloud`,
and below them shells and agents. A build since issue 55842 ends them when its app exits
(`cmux-tui __dev-reaper`, started by the app). This script is the same rule from the outside,
for a build that is still running, one that predates the reaper, or a Mac full of them
(https://github.com/manaflow-ai/cmux/issues/55842: one Mac held 136 processes for 7 builds).

    dev-build.py list [--json]
        Every tag with a process on this Mac: whether its app runs, its process count, and the
        agent chat that owns it (`claim`) with that chat's state.
    dev-build.py stop --tag TAG [--dry-run]
        Quit the tag's app the way reload.sh does (SIGTERM, the app's own quit; a second SIGTERM,
        its force exit), then end every process whose command line names `cmux DEV TAG.app/`,
        every terminal holder or host owned by the tag's app (`--owner <bundle id>:`), and their
        descendants: SIGTERM, a grace period, SIGKILL. Exits 1 when any process survives.
    dev-build.py stop --all-idle [--dry-run] [--except TAG]
        `stop` every tag that nobody uses: its app is gone and only helpers are left, or the agent
        chat that owns it has finished: closed, gone from acpmux, or idle (no turn, background task
        or command) for CMUX_DEV_BUILD_IDLE_HOURS (default 12). The owner is the chat that claimed
        the tag, else the chat whose shell launched the app (ACPMUX_SESSION_ID in the app's own
        environment), so a build an agent started with `open` or from a fleet artifact has one
        too. A running app no chat owns (the person's Tag Opener launch) is left alone and listed.
        `reload.sh --launch` runs this in the background for every other tag (issue 63351: one
        Mac held a build for 42 hours after its chat's last turn, 83 processes).
    dev-build.py claim --tag TAG [--session ID]
        Record the agent chat that uses the tag (default: this chat, ACPMUX_SESSION_ID).
        `reload.sh --tag TAG --launch` claims for the chat that runs it.

Never the person's own cmux: only processes naming a `cmux DEV <tag>.app` bundle, and the tag
`next` (the NEXT DEV daily) is refused.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Set

APP_PREFIX = "cmux DEV "
DAILY_TAG = "next"
# Tags are lowercase (reload.sh sanitizes them); a nested "cmux DEV Helper.app" (Chromium) is not one.
TAG_IN_COMMAND = re.compile(r"(?<!/Contents/Frameworks)/cmux DEV ([a-z0-9._-]+?)\.app/Contents/")
CLAIMS_DIR = Path(os.environ.get("CMUX_DEV_BUILD_CLAIMS_DIR")
                  or Path.home() / ".local/state/cmux/dev-builds")
# A chat that has done nothing for this long is done with its build (issue 63351). Chats are
# rarely closed: an agent's chat sits idle after its last turn, so "closed" alone kept builds for days.
IDLE_HOURS = float(os.environ.get("CMUX_DEV_BUILD_IDLE_HOURS") or 12)
# The chat states that mean the chat is between turns with nothing waiting on the person.
QUIET_STATES = {"idle", "ready"}
SESSION_IN_ENV = re.compile(r"(?:^| )ACPMUX_SESSION_ID=([0-9A-Za-z_-]+)(?= |$)")
QUIT_TIMEOUT = float(os.environ.get("CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS") or 30)
FORCE_EXIT_TIMEOUT = float(os.environ.get("CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS") or 5)
HELPER_GRACE = float(os.environ.get("CMUX_DEV_BUILD_HELPER_GRACE_SECONDS") or 5)
ROUNDS = 3


class Process:
    """One process: its command line, and its executable's path (`ps -o comm=`), which an
    argument cannot spoof."""
    __slots__ = ("pid", "ppid", "command", "exe")

    def __init__(self, pid: int, ppid: int, command: str, exe: Optional[str] = None) -> None:
        self.pid, self.ppid, self.command = pid, ppid, command
        self.exe = command.split(" ", 1)[0] if exe is None else exe

    def __repr__(self) -> str:
        return f"Process({self.pid}, {self.ppid}, {self.command!r}, {self.exe!r})"

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Process) and (self.pid, self.ppid, self.command, self.exe) == (
            other.pid, other.ppid, other.command, other.exe)


def parse_ps(commands: str, executables: str) -> List[Process]:
    """Joins `ps -axww -o pid=,ppid=,command=` with `ps -axww -o pid=,comm=` by pid; a process
    missing from either is left out."""
    exes = {}
    for line in executables.splitlines():
        parts = line.strip().split(None, 1)
        if parts and parts[0].isdigit():
            exes[int(parts[0])] = parts[1] if len(parts) > 1 else ""
    rows = []
    for line in commands.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit() or int(parts[0]) not in exes:
            continue
        rows.append(Process(int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else "", exes[int(parts[0])]))
    return rows


def snapshot() -> List[Process]:
    def ps(columns: str) -> str:
        return subprocess.run(["/bin/ps", "-axww", "-o", columns], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    return parse_ps(ps("pid=,ppid=,command="), ps("pid=,comm="))


def valid_tag(tag: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9._-]+", tag)) and tag != DAILY_TAG


def bundle_marker(tag: str) -> str:
    return f"/{APP_PREFIX}{tag}.app/"


def owner_marker(tag: str) -> str:
    """How the tag's terminal holders and hosts name their app (`--owner <bundle id>:…`); they run
    from a copy outside the bundle and outlive a restarted daemon. reload.sh's sanitize_bundle."""
    cleaned = re.sub(r"[^a-z0-9]+", ".", tag.lower()).strip(".") or "agent"
    return f"--owner com.cmuxterm.app.debug.{cleaned}:"


def app_pids(tag: str, processes: Iterable[Process]) -> List[int]:
    """The pids running the app's own executable (`…/cmux DEV TAG.app/Contents/MacOS/…`), not
    a helper inside it (`…/Contents/Library/cmux Files (dev).app/…`, `…/Contents/Resources/…`)."""
    return [p.pid for p in processes if is_app(p.exe, tag)]


def is_app(exe: str, tag: str) -> bool:
    first = exe.find(".app/Contents/")
    if first < 0:
        return False
    return (exe[:first + len(".app/")].endswith(bundle_marker(tag))
            and exe[first + len(".app/Contents/"):].startswith("MacOS/"))


def started_by(process: Process, tag: str) -> bool:
    """Whether the tag's build started `process`: its executable is inside the bundle; it is the
    shared `cmux-files-host host` copy running a program of the bundle; or it is one of cmux's own
    executables (a terminal holder or host) naming the app as its owner. A shell or an agent whose
    command only mentions the bundle in an argument never matches by itself."""
    marker, base = bundle_marker(tag), process.exe.rsplit("/", 1)[-1]
    return (marker in process.exe
            or (base == "cmux-files-host" and marker in process.command)
            or (base.startswith("cmux") and owner_marker(tag) in process.command))


def tree(tag: str, processes: List[Process], own: Set[int]) -> List[Process]:
    """Every process naming the tag's bundle or owned by its app, and their descendants, except `own`."""
    spared = lambda p: p.pid in own or p.pid <= 1  # noqa: E731
    chosen = {p.pid for p in processes if not spared(p) and started_by(p, tag)}
    children: Dict[int, List[Process]] = {}
    for process in processes:
        children.setdefault(process.ppid, []).append(process)
    queue = list(chosen)
    while queue:
        for child in children.get(queue.pop(), []):
            if not spared(child) and child.pid not in chosen:
                chosen.add(child.pid)
                queue.append(child.pid)
    return [p for p in processes if p.pid in chosen]


def tags_in(processes: Iterable[Process]) -> Set[str]:
    """Tags of the builds whose executables run here."""
    return {m for p in processes for m in TAG_IN_COMMAND.findall(p.exe) if m != DAILY_TAG}


class System:
    """Signals and waiting; replaced in tests."""

    def snapshot(self) -> List[Process]:
        return snapshot()

    def launch_env(self, pid: int) -> str:
        """The process's command line followed by its environment (`ps -E`), or "" when unreadable."""
        try:
            return subprocess.run(["/bin/ps", "-E", "-ww", "-o", "command=", "-p", str(pid)],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                  timeout=10).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return ""

    def signal(self, pid: int, sig: int) -> None:
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def alive(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def wait(self, pids: List[int], timeout: float) -> List[int]:
        deadline = time.monotonic() + timeout
        left = [pid for pid in pids if self.alive(pid)]
        while left and time.monotonic() < deadline:
            time.sleep(0.1)
            left = [pid for pid in left if self.alive(pid)]
        return left


def stop(tag: str, system: System, dry_run: bool = False, log: Callable[[str], None] = print) -> List[Process]:
    """Quits the tag's app, then ends its tree. Returns the processes still running after."""
    if not valid_tag(tag):
        raise SystemExit(f"dev-build: refusing tag {tag!r}")
    own = {os.getpid(), os.getppid()}
    processes = system.snapshot()
    apps = app_pids(tag, processes)
    if dry_run:
        for process in tree(tag, processes, own):
            log(f"would end {process.pid} {process.command[:160]}")
        return []
    if apps:
        log(f"{tag}: quitting app pid(s) {' '.join(map(str, apps))}")
        for pid in apps:
            system.signal(pid, signal.SIGTERM)
        left = system.wait(apps, QUIT_TIMEOUT)
        if left:
            log(f"{tag}: app still running after {QUIT_TIMEOUT:g}s; second SIGTERM (force exit)")
            for pid in left:
                system.signal(pid, signal.SIGTERM)
            left = system.wait(left, FORCE_EXIT_TIMEOUT)
            for pid in left:
                system.signal(pid, signal.SIGKILL)
            system.wait(left, 2)
    for _ in range(ROUNDS):
        processes = system.snapshot()
        if app_pids(tag, processes):
            log(f"{tag}: a new instance of the app started; leaving its processes")
            return []
        targets = tree(tag, processes, own)
        if not targets:
            break
        log(f"{tag}: ending {len(targets)} process(es)")
        for process in targets:
            system.signal(process.pid, signal.SIGTERM)
        system.wait([p.pid for p in targets], HELPER_GRACE)
        now = {p.pid: p.command for p in system.snapshot()}
        for process in targets:
            if now.get(process.pid) == process.command:
                system.signal(process.pid, signal.SIGKILL)
        system.wait([p.pid for p in targets], 2)
    return tree(tag, system.snapshot(), own)


# ---- claims: which agent chat uses a tag ------------------------------------------------------

def claim_path(tag: str) -> Path:
    return CLAIMS_DIR / f"{tag}.json"


def claim(tag: str, session: str, name: str = "") -> Path:
    CLAIMS_DIR.mkdir(parents=True, exist_ok=True)
    path = claim_path(tag)
    path.write_text(json.dumps({"tag": tag, "session": session, "name": name, "claimedAt": int(time.time())}) + "\n")
    return path


def read_claim(tag: str) -> Optional[dict]:
    try:
        data = json.loads(claim_path(tag).read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("session") else None


def launch_session(env: str) -> Optional[str]:
    """The agent chat whose shell launched a process: the last ACPMUX_SESSION_ID in its `ps -E`
    line (the environment follows the arguments, so the last one is the environment's)."""
    found = SESSION_IN_ENV.findall(env)
    return found[-1] if found else None


def owner(tag: str, processes: List[Process], system: Optional["System"] = None) -> Optional[dict]:
    """The chat that owns the tag: its claim, else the chat that launched the running app."""
    claimed = read_claim(tag)
    if claimed is not None or system is None:
        return claimed
    for pid in app_pids(tag, processes):
        session = launch_session(system.launch_env(pid))
        if session:
            return {"tag": tag, "session": session, "source": "launch"}
    return None


def chat_row(row: dict) -> dict:
    """What the idle rule needs of one `acpmux ls --json` session."""
    turn = row.get("lastTurn") if isinstance(row.get("lastTurn"), dict) else {}
    stamps = [v for v in (turn.get("endedAt"), row.get("updatedAt"), row.get("createdAt"))
              if isinstance(v, (int, float)) and v > 0]
    busy = any(row.get(k) for k in ("bgTasksRunning", "commandsRunning", "subagentsRunning", "pendingPermissions"))
    return {"state": row.get("state") or "", "quietSinceMs": max(stamps) if stamps else None, "busy": bool(busy)}


def acpmux_states() -> Optional[Dict[str, dict]]:
    """Session id to state for this Mac's agent chats (`chat_row`), or None when acpmux cannot be asked."""
    binary = os.environ.get("ACPMUX_BIN") or "acpmux"
    try:
        result = subprocess.run([binary, "ls", "--json", "--machine", "local"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        rows = json.loads(result.stdout).get("sessions", [])
    except (ValueError, AttributeError):
        return None
    return {row.get("sessionId"): chat_row(row) for row in rows if isinstance(row, dict) and row.get("sessionId")}


def verdict(tag: str, processes: List[Process], states: Optional[Dict[str, object]],
            system: Optional["System"] = None, now: Optional[float] = None) -> str:
    """Why a tag is idle (`idle: …`) or kept (`keep: …`)."""
    if not app_pids(tag, processes):
        return "idle: app not running, helpers left"
    chat = owner(tag, processes, system)
    if chat is None:
        return "keep: app running, no chat owns it"
    session = chat["session"]
    if states is None:
        return "keep: app running, acpmux not reachable"
    row = states.get(session)
    if row is None:
        return f"idle: its chat {session} is gone"
    if isinstance(row, str):
        row = {"state": row, "quietSinceMs": None, "busy": False}
    state = row.get("state") or ""
    if state == "closed":
        return f"idle: its chat {session} is closed"
    quiet = row.get("quietSinceMs")
    if state in QUIET_STATES and not row.get("busy") and isinstance(quiet, (int, float)):
        hours = ((time.time() if now is None else now) - quiet / 1000) / 3600
        if hours >= IDLE_HOURS:
            return f"idle: its chat {session} has been {state} for {hours:.0f}h (limit {IDLE_HOURS:g}h)"
    return f"keep: its chat {session} is {state}"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--json", action="store_true")
    stopping = sub.add_parser("stop")
    which = stopping.add_mutually_exclusive_group(required=True)
    which.add_argument("--tag")
    which.add_argument("--all-idle", action="store_true")
    stopping.add_argument("--dry-run", action="store_true")
    stopping.add_argument("--except", dest="spare", action="append", default=[],
                          help="with --all-idle: a tag to leave alone (the one being launched)")
    claiming = sub.add_parser("claim")
    claiming.add_argument("--tag", required=True)
    claiming.add_argument("--session", default=os.environ.get("ACPMUX_SESSION_ID", ""))
    claiming.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    system = System()

    if args.command == "claim":
        if not valid_tag(args.tag):
            print(f"dev-build: refusing tag {args.tag!r}", file=sys.stderr)
            return 2
        if not args.session:
            if not args.quiet:
                print("dev-build: no --session and no ACPMUX_SESSION_ID; nothing claimed", file=sys.stderr)
            return 0 if args.quiet else 2
        path = claim(args.tag, args.session, os.environ.get("ACPMUX_SESSION_NAME", ""))
        if not args.quiet:
            print(f"claimed {args.tag} for {args.session} ({path})")
        return 0

    processes = system.snapshot()
    if args.command == "list":
        states = acpmux_states()
        rows = []
        for tag in sorted(tags_in(processes)):
            chat = owner(tag, processes, system) or {}
            rows.append({"tag": tag, "app": app_pids(tag, processes),
                         "processes": len(tree(tag, processes, {os.getpid()})),
                         "chat": chat.get("session"), "verdict": verdict(tag, processes, states, system)})
        if args.json:
            print(json.dumps(rows, indent=2))
        else:
            for row in rows:
                print(f"{row['tag']:<48} app={'yes' if row['app'] else 'no ':<3} processes={row['processes']:<4} {row['verdict']}")
        return 0

    if args.tag:
        survivors = stop(args.tag, system, dry_run=args.dry_run)
        for process in survivors:
            print(f"still running: {process.pid} {process.command[:160]}", file=sys.stderr)
        return 1 if survivors else 0

    states = acpmux_states()
    failed = False
    for tag in sorted(tags_in(processes) - set(args.spare)):
        why = verdict(tag, processes, states, system)
        print(f"{tag}: {why}")
        if why.startswith("idle"):
            survivors = stop(tag, system, dry_run=args.dry_run)
            failed = failed or bool(survivors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
