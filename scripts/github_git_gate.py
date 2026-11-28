#!/usr/bin/env python3
"""One machine-wide gate in front of every git HTTPS request to github.com.

On 2026-11-25 github.com started answering every git and web request from the
build Mac with 403 "Access to this site has been restricted" (api.github.com
kept working; git data API calls through it got 429 "gitmon refuses to
schedule us: fail-fast:network"). The traffic that tripped it came from the
Mac's blobless partial clones: about 1,900 promisor packs were written in one
day across six clones, almost all of them single-object packs, written about
one per second for half an hour at a time (cmuxterm-hq/.clones/cmux-48536 wrote
535 between 04:00 and 05:00). Each is one lazy `git fetch --filter=blob:none
--stdin` that git starts by itself when a command (rebase, log -p/--stat,
blame, `show REV:PATH`, checkout) reads a blob the clone lacks: one HTTPS
round trip per object, from every agent at once, with no shared limit and no
pause when GitHub starts refusing. A refused request was simply retried by the
next command.

Installed (`install --repo DIR` or `--scan ROOT`), each github.com https remote
of a clone gets `remote.<name>.vcs=ghgate`, so git runs the remote helper
`git-remote-ghgate` for it: fetches, pushes, ls-remotes and git's own lazy blob
fetches (which use the promisor remote) all pass here before the real
`git remote-https` runs. A clone's worktrees share its config, so routing the
clone routes them all. Not a machine-wide url.ghgate::...insteadOf rule: that
form also rewrites what `git remote -v` prints, and gh then finds no GitHub
remote in any repository. Each request:

- waits while GitHub's last refusal backs everyone off. A 403 block, a 429 or a
  gitmon refusal starts a machine-wide backoff (BLOCK_BACKOFF, doubling per
  strike up to BLOCK_BACKOFF_CAP); a 5xx a shorter one. Inside the backoff a
  request that would wait longer than BACKOFF_WAIT fails at once, with the time
  the backoff ends, instead of adding to the traffic GitHub is refusing. One
  success clears it.
- takes one of SLOTS machine-wide slots (an flock per slot file), so at most
  SLOTS requests to github.com run at once from every agent, script and job.
- spends a token from a one-minute window: PER_MINUTE for all requests and
  LAZY_PER_MINUTE for git's lazy blob fetches, the kind that storms.
- appends one JSON line to events.jsonl: what ran it (the git command and the
  command above it, with its folder), the kind (lazy, fetch, push, clone,
  ls-remote), the wait, the duration and how it ended. `stats` sums them;
  `audit` counts promisor packs per clone, the trace a lazy-fetch storm leaves
  even where this gate was not installed.

`prefetch` is the batched form of a lazy-fetch storm: it lists every blob REV.. (each REV's whole tree, or
A..B's changes) needs that the clone lacks, without fetching any (GIT_NO_LAZY_FETCH=1, --missing=print),
and asks the promisor remote for all of them in one request. Run it once after making a worktree, or
before a rebase of a blobless checkout, and the rebase reads blobs it already has.

- runs the real helper with a low-speed floor (GIT_HTTP_LOW_SPEED_LIMIT /
  GIT_HTTP_LOW_SPEED_TIME, unless the caller set them): a transfer that stalls
  is aborted instead of holding its slot. One agent's `git fetch` sat at 0 B/s
  for 16 hours on 2026-11-26.

Lazy fetches are the storm, so the other half of the fix is to stop needing
them. `mirror sync` keeps one full (not blobless) bare mirror per GitHub repo
under MIRROR_ROOT, fetched by one process at a time and at most once per
`--min-interval`, so a dozen agents asking at once cost one fetch. `--seed DIR`
makes a new mirror from a full local clone with no download. `mirror adopt
--repo DIR` adds the mirror's objects as an alternate of DIR's clone (every
worktree of it shares that object store) and drops the clone's blob:none
filter, so a blob any agent reads is found locally and later fetches carry
their blobs in one pack instead of one request per blob. The mirror never
prunes objects (gc.auto=0, gc.pruneExpire=never): an adopted clone may need
any object it once had. `mirror unadopt` copies what the clone uses back
before removing the alternate.

A bug in the gate's own bookkeeping never stops git: it runs the real helper
anyway (fail open). CMUX_GH_GATE_BYPASS=1 skips the gate for one command.

    github_git_gate.py install [--repo DIR]... [--scan ROOT]... [--bin-dir DIR]
    github_git_gate.py uninstall [--repo DIR]... [--scan ROOT]...
    github_git_gate.py prefetch [--repo DIR] [--remote origin] REV...
    github_git_gate.py status | stats [--hours H] | audit [--hours H] GIT_DIR...
    github_git_gate.py mirror sync [--url URL] [--seed DIR] [--min-interval S]
    github_git_gate.py mirror adopt|unadopt --repo DIR [--url URL] [--keep-filter]
    git-remote-ghgate REMOTE URL      (what git runs; the `helper` command)
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Callable, Sequence

HELPER_NAME = "git-remote-ghgate"
TRANSPORT = "ghgate::"
GITHUB_HTTPS = "https://github.com/"
VCS_NAME = "ghgate"
# The machine-wide rule an earlier install wrote; install and uninstall now remove it (see route_repo).
INSTEAD_OF_KEY = f"url.{TRANSPORT}{GITHUB_HTTPS}.insteadOf"

SLOTS = 4
PER_MINUTE = 60
LAZY_PER_MINUTE = 20
# Longest a request waits for a slot or a token before it fails: long enough to queue behind a clone of
# cmux (minutes) rather than fail an agent's fetch, short enough that a wedged slot still ends.
MAX_WAIT = 600.0
# Longest a request waits out a backoff; a longer backoff fails it at once.
BACKOFF_WAIT = 30.0
BLOCK_BACKOFF = 120.0
BLOCK_BACKOFF_CAP = 3600.0
SERVER_BACKOFF = 15.0
SERVER_BACKOFF_CAP = 300.0
POLL = 0.25
WINDOW = 60.0
EVENTS_MAX_BYTES = 8 * 1024 * 1024
STDERR_TAIL = 64 * 1024
REFUSED_EXIT = 128
# A transfer under LOW_SPEED_BYTES a second for LOW_SPEED_SECONDS is aborted by git itself.
LOW_SPEED_BYTES = "1"
LOW_SPEED_SECONDS = "120"
MIRROR_MIN_INTERVAL = 300.0
MIRROR_LOCK_WAIT = 900.0
DEFAULT_URL = "https://github.com/manaflow-ai/cmux.git"
# launchd jobs here run with this PATH; the helper must resolve on it too.
MINIMAL_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

BLOCK_PATTERNS = (
    re.compile(r"returned error: 429"),
    re.compile(r"\bHTTP 429\b"),
    re.compile(r"Access to this site has been restricted", re.I),
    re.compile(r"gitmon", re.I),
    re.compile(r"rate limit", re.I),
)
FORBIDDEN = re.compile(r"returned error: 403")
# A 403 that is about this account's access to one repository, not a host-wide block.
PERMISSION_403 = re.compile(r"Permission to .* denied|denied to |Write access to repository not granted|"
                            r"Repository not found", re.I)
SERVER_ERROR = re.compile(r"returned error: 5\d\d")


def env_float(env: dict[str, str], name: str, default: float) -> float:
    try:
        return float(env.get(name, ""))
    except ValueError:
        return default


def state_dir(env: dict[str, str]) -> Path:
    if env.get("CMUX_GH_GATE_STATE"):
        return Path(env["CMUX_GH_GATE_STATE"])
    base = env.get("XDG_CACHE_HOME") or str(Path(env.get("HOME", "~")).expanduser() / ".cache")
    return Path(base) / "cmux" / "github-git-gate"


def classify(stderr_text: str, returncode: int) -> str:
    """'ok', 'block' (host-wide refusal: back everyone off), 'server' (5xx) or 'error' (anything else)."""
    if returncode == 0:
        return "ok"
    if any(p.search(stderr_text) for p in BLOCK_PATTERNS):
        return "block"
    if FORBIDDEN.search(stderr_text) and not PERMISSION_403.search(stderr_text):
        return "block"
    if SERVER_ERROR.search(stderr_text):
        return "server"
    return "error"


def request_kind(parent_args: str) -> str:
    """What the git process that started this helper is doing."""
    words = parent_args.split()
    if "--stdin" in words and any(w.startswith("--filter=") for w in words) and "fetch" in words:
        return "lazy"  # promisor-remote.c: fetch --filter=blob:none --stdin with the missing ids
    for kind in ("push", "clone", "ls-remote", "fetch", "pull", "send-pack", "fetch-pack"):
        if kind in words:
            return {"send-pack": "push", "fetch-pack": "fetch", "pull": "fetch"}.get(kind, kind)
    return "other"


class Gate:
    """The shared state: a backoff, a token window and SLOTS slot locks, under STATE_DIR."""

    def __init__(self, root: Path, env: dict[str, str], clock: Callable[[], float] = time.time,
                 sleep: Callable[[float], None] = time.sleep):
        self.root = root
        self.clock = clock
        self.sleep = sleep
        self.slots = max(1, int(env_float(env, "CMUX_GH_GATE_SLOTS", SLOTS)))
        self.per_minute = max(1, int(env_float(env, "CMUX_GH_GATE_PER_MINUTE", PER_MINUTE)))
        self.lazy_per_minute = max(1, int(env_float(env, "CMUX_GH_GATE_LAZY_PER_MINUTE", LAZY_PER_MINUTE)))
        self.max_wait = env_float(env, "CMUX_GH_GATE_MAX_WAIT", MAX_WAIT)
        self.backoff_wait = env_float(env, "CMUX_GH_GATE_BACKOFF_WAIT", BACKOFF_WAIT)
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        (root / "slots").mkdir(exist_ok=True, mode=0o700)

    # -- shared state, read-modify-written under state.lock -------------------------------------
    def _locked(self, change: Callable[[dict], object]) -> object:
        with open(self.root / "state.lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                path = self.root / "state.json"
                try:
                    state = json.loads(path.read_text())
                    if not isinstance(state, dict):
                        state = {}
                except (OSError, ValueError):
                    state = {}
                result = change(state)
                tmp = path.with_name(f"state.json.{os.getpid()}.tmp")
                tmp.write_text(json.dumps(state))
                os.replace(tmp, path)
                return result
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def read_state(self) -> dict:
        return dict(self._locked(lambda s: dict(s)))  # type: ignore[arg-type]

    def backoff_remaining(self) -> tuple[float, dict]:
        state = self.read_state()
        return max(0.0, float(state.get("backoff_until", 0)) - self.clock()), state

    def take_token(self, kind: str) -> float:
        """0 when a token was taken now, else the seconds until the window has one."""
        def change(state: dict) -> float:
            now = self.clock()
            window = [t for t in state.get("window", []) if isinstance(t, (int, float)) and now - t < WINDOW]
            lazy = [t for t in state.get("lazy_window", []) if isinstance(t, (int, float)) and now - t < WINDOW]
            waits = []
            if len(window) >= self.per_minute:
                waits.append(window[-self.per_minute] + WINDOW - now)
            if kind == "lazy" and len(lazy) >= self.lazy_per_minute:
                waits.append(lazy[-self.lazy_per_minute] + WINDOW - now)
            if not waits:
                window.append(now)
                if kind == "lazy":
                    lazy.append(now)
            state["window"], state["lazy_window"] = window, lazy
            return max(waits) if waits else 0.0
        return float(self._locked(change))  # type: ignore[arg-type]

    def record(self, outcome: str, detail: str) -> None:
        def change(state: dict) -> None:
            now = self.clock()
            if outcome == "ok":
                state.update(strikes=0, backoff_until=0, last_ok=now)
                return
            if outcome not in ("block", "server"):
                return
            strikes = int(state.get("strikes", 0)) + 1
            base, cap = (BLOCK_BACKOFF, BLOCK_BACKOFF_CAP) if outcome == "block" else (SERVER_BACKOFF, SERVER_BACKOFF_CAP)
            delay = min(cap, base * 2 ** (strikes - 1))
            state.update(strikes=strikes, backoff_until=max(float(state.get("backoff_until", 0)), now + delay),
                         last_refusal=now, last_refusal_kind=outcome, last_refusal_detail=detail[-300:])
        self._locked(change)

    # -- slots ------------------------------------------------------------------------------------
    def try_slot(self):
        """An open, flocked slot file (hold it for the request's life), or None when all are taken."""
        for index in range(self.slots):
            handle = open(self.root / "slots" / f"slot-{index}.lock", "a+")
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return handle
            except OSError as error:
                handle.close()
                if error.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                    raise
        return None

    def admit(self, kind: str) -> tuple[object | None, float, str]:
        """(slot handle, seconds waited, '') when the request may go, else (None, waited, why not)."""
        start = self.clock()
        remaining, state = self.backoff_remaining()
        if remaining > 0:
            if remaining > self.backoff_wait:
                until = time.strftime("%H:%M:%S", time.localtime(start + remaining))
                return None, 0.0, (f"github.com refused git traffic from this machine "
                                   f"({state.get('last_refusal_kind', 'block')}: "
                                   f"{str(state.get('last_refusal_detail', '')).strip()[-160:]}); "
                                   f"every git request to it waits until {until} ({int(remaining)}s)")
            self.sleep(remaining)
        while True:
            waited = self.clock() - start
            wait = self.take_token(kind)
            if wait <= 0:
                break
            if waited + wait > self.max_wait:
                return None, waited, (f"more than {self.per_minute} git requests a minute to github.com "
                                      f"({self.lazy_per_minute} for lazy blob fetches) from this machine")
            self.sleep(wait)
        while True:
            slot = self.try_slot()
            waited = self.clock() - start
            if slot is not None:
                return slot, waited, ""
            if waited > self.max_wait:
                return None, waited, f"all {self.slots} github.com git slots stayed busy for {int(waited)}s"
            self.sleep(POLL)

    def log(self, event: dict) -> None:
        path = self.root / "events.jsonl"
        try:
            if path.exists() and path.stat().st_size > EVENTS_MAX_BYTES:
                os.replace(path, path.with_suffix(".jsonl.1"))
            with open(path, "a") as out:
                out.write(json.dumps(event, sort_keys=True) + "\n")
        except OSError:
            pass


def process_args(pid: int) -> tuple[int, str]:
    """(parent pid, command line) of PID, or (0, '') when it is gone."""
    try:
        out = subprocess.run(["ps", "-o", "ppid=,args=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=5).stdout.strip()
        ppid, _, args = out.partition(" ")
        return int(ppid), args.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0, ""


def real_helper(url: str, env: dict[str, str]) -> list[str]:
    if env.get("CMUX_GH_GATE_REAL_HELPER"):  # tests: a JSON argv list
        return list(json.loads(env["CMUX_GH_GATE_REAL_HELPER"]))
    scheme = url.split("://", 1)[0] if "://" in url else "https"
    return ["git", f"remote-{scheme}"]


def run_passing_stderr(argv: Sequence[str], env: dict[str, str]) -> tuple[int, str]:
    """Run ARGV on this process's stdin and stdout (the helper protocol), copy its stderr through, keep the tail."""
    child = subprocess.Popen(list(argv), stderr=subprocess.PIPE, env=env)
    tail = b""
    assert child.stderr is not None
    while True:
        chunk = os.read(child.stderr.fileno(), 4096)
        if not chunk:
            break
        try:
            os.write(2, chunk)
        except OSError:
            pass
        tail = (tail + chunk)[-STDERR_TAIL:]
    child.stderr.close()
    return child.wait(), tail.decode(errors="replace")


def helper_main(argv: Sequence[str], env: dict[str, str] | None = None, gate: Gate | None = None) -> int:
    env = dict(os.environ if env is None else env)
    if argv[:1] == ["--gate-ping"]:
        print("ghgate ok")
        return 0
    if len(argv) < 1:
        print(f"{HELPER_NAME}: usage: {HELPER_NAME} REMOTE [URL]", file=sys.stderr)
        return 2
    remote = argv[0]
    url = argv[1] if len(argv) > 1 else remote
    if url.startswith(TRANSPORT):
        url = url[len(TRANSPORT):]
    target = [*real_helper(url, env), remote, url]
    env.setdefault("GIT_HTTP_LOW_SPEED_LIMIT", LOW_SPEED_BYTES)
    env.setdefault("GIT_HTTP_LOW_SPEED_TIME", LOW_SPEED_SECONDS)
    if env.get("CMUX_GH_GATE_BYPASS") == "1":
        return subprocess.call(target, env=env)

    slot = None
    event: dict = {"pid": os.getpid(), "url": url}
    try:
        gate = gate or Gate(state_dir(env), env)
        ppid, parent = (int(env["CMUX_GH_GATE_PARENT_PID"]), env.get("CMUX_GH_GATE_PARENT_ARGS", "")) \
            if env.get("CMUX_GH_GATE_PARENT_PID") else (os.getppid(), "")
        grand_pid, parent_args = process_args(ppid) if not parent else (0, parent)
        # git starts a helper outside its own exec dir through `git remote-ghgate`, a second git process:
        # skip it so the kind and caller come from the git command that asked.
        for _ in range(3):
            if "remote-ghgate" not in parent_args or grand_pid <= 1:
                break
            grand_pid, parent_args = process_args(grand_pid)
        _, caller = process_args(grand_pid) if grand_pid > 1 else (0, "")
        kind = request_kind(parent_args)
        event.update(kind=kind, git=parent_args[:300], caller=caller[:300], cwd=os.getcwd(),
                     git_dir=env.get("GIT_DIR", ""), started=round(gate.clock(), 3))
        slot, waited, refused = gate.admit(kind)
        event["waited"] = round(waited, 3)
        if refused:
            event.update(result="refused", reason=refused)
            gate.log(event)
            print(f"fatal: {HELPER_NAME}: not sending this git request to github.com: {refused}. "
                  f"(CMUX_GH_GATE_BYPASS=1 overrides; scripts/github_git_gate.py status shows the state)",
                  file=sys.stderr)
            return REFUSED_EXIT
    except Exception as error:  # the gate's own failure never stops git
        print(f"{HELPER_NAME}: gate unavailable ({error!r}); running git without it", file=sys.stderr)
        gate = None
    try:
        began = time.monotonic()
        returncode, stderr_text = run_passing_stderr(target, env)
        if gate is not None:
            outcome = classify(stderr_text, returncode)
            gate.record(outcome, stderr_text.strip().splitlines()[-1] if stderr_text.strip() else "")
            event.update(result=outcome, rc=returncode, seconds=round(time.monotonic() - began, 3))
            gate.log(event)
        return returncode
    finally:
        if slot is not None:
            slot.close()  # type: ignore[attr-defined]


# -- install / status ---------------------------------------------------------------------------------
def default_bin_dir(env: dict[str, str]) -> Path:
    for candidate in ("/opt/homebrew/bin", "/usr/local/bin"):
        if os.access(candidate, os.W_OK):
            return Path(candidate)
    return Path(env.get("HOME", "~")).expanduser() / ".local" / "bin"


def write_helper(bin_dir: Path, share_dir: Path, python: str) -> Path:
    share_dir.mkdir(parents=True, exist_ok=True)
    installed = share_dir / "github_git_gate.py"
    tmp = installed.with_name(f".github_git_gate.py.{os.getpid()}")
    shutil.copyfile(Path(__file__).resolve(), tmp)
    os.replace(tmp, installed)
    bin_dir.mkdir(parents=True, exist_ok=True)
    helper = bin_dir / HELPER_NAME
    tmp = bin_dir / f".{HELPER_NAME}.{os.getpid()}"
    tmp.write_text(f'#!/bin/sh\nexec "{python}" -I "{installed}" helper "$@"\n')
    tmp.chmod(0o755)
    os.replace(tmp, helper)
    return helper


def helper_resolves(path_value: str) -> bool:
    try:
        out = subprocess.run(["git", "remote-ghgate", "--gate-ping"], capture_output=True, text=True, timeout=30,
                             env={**os.environ, "PATH": path_value})
        return out.returncode == 0 and "ghgate ok" in out.stdout
    except (OSError, subprocess.SubprocessError):
        return False


def git_config(scope: list[str], *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *scope, "config", *args], capture_output=True, text=True)


def find_clones(roots: Sequence[str], depth: int = 3) -> list[str]:
    """Clones (folders whose .git is a directory) at most DEPTH levels under each ROOT. A worktree's .git is a
    file and its remotes live in the clone's config, so routing the clone routes all its worktrees."""
    found: list[str] = []
    for root in roots:
        base = Path(root).expanduser()
        frontier = [base]
        for _ in range(depth + 1):
            nxt = []
            for folder in frontier:
                if (folder / ".git").is_dir():
                    found.append(str(folder))
                    continue
                try:
                    nxt += [c for c in folder.iterdir() if c.is_dir() and not c.is_symlink()
                            and (not c.name.startswith(".") or c.name == ".clones")]
                except OSError:
                    pass
            frontier = nxt
    return sorted(set(found))


def github_remotes(repo: str, env: dict[str, str] | None = None) -> dict[str, str]:
    """{remote name: url} for REPO's remotes whose url is https://github.com/... (their requests can be gated)."""
    listing = git("-C", repo, "config", "--local", "--get-regexp", r"^remote\..*\.url$", env=env, check=False).stdout
    remotes = {}
    for line in filter(None, listing.split("\n")):
        key, _, url = line.partition(" ")
        if url.startswith(GITHUB_HTTPS):
            remotes[key[len("remote."):-len(".url")]] = url
    return remotes


def route_repo(repo: str, env: dict[str, str] | None = None) -> list[str]:
    """Send REPO's github.com remotes through the gate with remote.<name>.vcs, which git honors for fetch, push,
    ls-remote and lazy promisor fetches alike. Unlike a url.ghgate::...insteadOf rule it leaves `git remote -v`
    showing the plain https URL, so gh still recognizes the repository (the insteadOf form, installed
    machine-wide on 2026-11-26, made every `gh pr` command fail with "none of the git remotes ... point to a
    known GitHub host")."""
    routed = []
    for name, url in github_remotes(repo, env).items():
        git("-C", repo, "config", "--local", f"remote.{name}.vcs", VCS_NAME, env=env)
        shown = git("-C", repo, "remote", "get-url", name, env=env).stdout.strip()
        if shown != url:
            git("-C", repo, "config", "--local", "--unset-all", f"remote.{name}.vcs", env=env, check=False)
            raise RuntimeError(f"{repo}: routing {name} changed its url to {shown!r}; left it unrouted")
        routed.append(name)
    return routed


def unroute_repo(repo: str, env: dict[str, str] | None = None) -> list[str]:
    listing = git("-C", repo, "config", "--local", "--get-regexp", r"^remote\..*\.vcs$", env=env, check=False).stdout
    removed = []
    for line in filter(None, listing.split("\n")):
        key, _, value = line.partition(" ")
        if value == VCS_NAME:
            git("-C", repo, "config", "--local", "--unset-all", key, env=env)
            removed.append(key[len("remote."):-len(".vcs")])
    return removed


def drop_legacy_global(env: dict[str, str] | None = None) -> bool:
    """Remove the machine-wide insteadOf rule an earlier install wrote; True when one was there."""
    done = git("config", "--global", "--unset-all", INSTEAD_OF_KEY, env=env, check=False)
    return done.returncode == 0


def install(args) -> int:
    env = dict(os.environ)
    bin_dir = Path(args.bin_dir) if args.bin_dir else default_bin_dir(env)
    share = Path(args.share_dir) if args.share_dir else Path(env.get("HOME", "~")).expanduser() / ".local/share/cmux/github-git-gate"
    helper = write_helper(bin_dir, share, args.python or sys.executable or "/usr/bin/python3")
    print(f"helper: {helper}")
    # A routed repository whose git cannot find the helper fails every github.com request, so check the
    # PATH of this shell and the short one launchd jobs get before routing anything.
    paths = {"this PATH": env.get("PATH", ""), "launchd's PATH": MINIMAL_PATH}
    unresolved = [name for name, value in paths.items() if not helper_resolves(value)]
    if unresolved:
        print(f"install: git cannot find {HELPER_NAME} on {', '.join(unresolved)}; pick a --bin-dir on it"
              + (" (routing anyway: --force)" if args.force else ". No git config was changed."), file=sys.stderr)
        if not args.force:
            return 1
    if drop_legacy_global():
        print(f"removed the machine-wide {INSTEAD_OF_KEY} rule (it hid github remotes from gh)")
    status = 0
    for repo in [*args.repo, *find_clones(args.scan)]:
        try:
            routed = route_repo(repo)
            print(f"routed: {repo} ({', '.join(routed) or 'no github.com https remote'})")
        except RuntimeError as error:
            print(f"FAILED: {error}", file=sys.stderr)
            status = 1
    return status


def uninstall(args) -> int:
    if drop_legacy_global():
        print(f"removed the machine-wide {INSTEAD_OF_KEY} rule")
    status = 0
    for repo in [*args.repo, *find_clones(args.scan)]:
        try:
            print(f"unrouted: {repo} ({', '.join(unroute_repo(repo)) or 'nothing routed'})")
        except RuntimeError as error:
            print(f"FAILED: {error}", file=sys.stderr)
            status = 1
    return status


def read_events(root: Path, since: float) -> list[dict]:
    events = []
    for name in ("events.jsonl.1", "events.jsonl"):
        try:
            lines = (root / name).read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and float(event.get("started", 0)) >= since:
                events.append(event)
    return events


def caller_key(event: dict) -> str:
    words = str(event.get("caller", "")).split()
    head = " ".join(Path(w).name if i == 0 else w for i, w in enumerate(words[:3]))
    return f"{head or '?'} @ {event.get('cwd', '?')}"


def stats(root: Path, hours: float, now: float) -> dict:
    events = read_events(root, now - hours * 3600)
    return {
        "requests": len(events),
        "by_kind": dict(Counter(str(e.get("kind")) for e in events)),
        "by_result": dict(Counter(str(e.get("result")) for e in events)),
        "top_callers": Counter(caller_key(e) for e in events).most_common(15),
        "waited_seconds": round(sum(float(e.get("waited", 0)) for e in events), 1),
    }


def idx_objects(idx: Path) -> int:
    """Objects in a v2 pack index, from its size (header 8 + fanout 1024 + 28 per sha1 object + trailer 40)."""
    try:
        return max(0, (idx.stat().st_size - 8 - 1024 - 40) // 28)
    except OSError:
        return -1


def audit(git_dirs: Sequence[str], hours: float, now: float) -> list[dict]:
    """Promisor packs (one per fetch from the promisor remote) written in the last HOURS, per git dir."""
    rows = []
    for git_dir in git_dirs:
        pack_dir = Path(git_dir) / "objects" / "pack"
        recent = [p for p in pack_dir.glob("*.promisor") if now - p.stat().st_mtime < hours * 3600] \
            if pack_dir.is_dir() else []
        single = sum(1 for p in recent if idx_objects(p.with_suffix(".idx")) == 1)
        per_hour = Counter(time.strftime("%m-%d %H", time.localtime(p.stat().st_mtime)) for p in recent)
        # What a killed fetch or repack leaves behind: tmp_pack_* files are never cleaned by git until gc.
        leftovers = list(pack_dir.glob("tmp_*")) if pack_dir.is_dir() else []
        rows.append({"git_dir": git_dir, "promisor_packs": len(recent), "single_object": single,
                     "busiest_hour": per_hour.most_common(1)[0] if per_hour else None,
                     "tmp_packs": len(leftovers),
                     "tmp_pack_gb": round(sum(p.stat().st_size for p in leftovers) / 1e9, 2)})
    return sorted(rows, key=lambda r: -r["promisor_packs"])


def missing_blobs(repo: str, revs: Sequence[str]) -> list[str]:
    """Ids REVS need that the clone lacks, listed without fetching anything."""
    env = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}
    out = subprocess.run(["git", "-C", repo, "rev-list", "--objects", "--missing=print", *revs, "--"],
                         capture_output=True, text=True, env=env, check=True).stdout
    return sorted({line[1:].split()[0] for line in out.splitlines() if line.startswith("?")})


def prefetch(repo: str, remote: str, revs: Sequence[str]) -> int:
    wanted = missing_blobs(repo, revs)
    print(f"prefetch: {len(wanted)} missing object(s) for {' '.join(revs)}", file=sys.stderr)
    if not wanted:
        return 0
    # The ids go in from a file, never a pipe: piped stdin past ~10 KB hangs on some hosts
    # (scripts/cmux-next/git_batch.py).
    with tempfile.TemporaryFile() as ids:
        ids.write(("\n".join(wanted) + "\n").encode())
        ids.seek(0)
        done = subprocess.run(["git", "-C", repo, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "-q", remote,
                               "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none",
                               "--stdin"], stdin=ids, env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
    return done.returncode


# -- shared mirror ------------------------------------------------------------------------------------
def mirror_root(env: dict[str, str]) -> Path:
    if env.get("CMUX_GH_MIRROR_ROOT"):
        return Path(env["CMUX_GH_MIRROR_ROOT"])
    base = env.get("XDG_CACHE_HOME") or str(Path(env.get("HOME", "~")).expanduser() / ".cache")
    return Path(base) / "cmux" / "git-mirrors"


def mirror_path(root: Path, url: str) -> Path:
    """ROOT/OWNER/REPO.git for a github.com URL, else ROOT/other/<url as a name>.git."""
    match = re.match(r"^(?:ghgate::)?(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                     r"([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", url)
    if match:
        return root / match.group(1) / f"{match.group(2)}.git"
    return root / "other" / (re.sub(r"[^\w.-]+", "_", url).strip("_") + ".git")


def git(*args: str, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess:
    done = subprocess.run(["git", *args], capture_output=True, text=True, env=env)
    if check and done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()[-400:]}")
    return done


MIRROR_CONFIG = (("gc.auto", "0"), ("gc.pruneExpire", "never"), ("maintenance.auto", "false"),
                 ("fetch.writeCommitGraph", "true"), ("remote.origin.fetch", "+refs/heads/*:refs/heads/*"))


def mirror_sync(url: str, root: Path, seed: str | None, min_interval: float, env: dict[str, str],
                clock: Callable[[], float] = time.time, lock_wait: float = MIRROR_LOCK_WAIT,
                sleep: Callable[[float], None] = time.sleep) -> dict:
    """Make or refresh the mirror of URL. One sync at a time; a fresh mirror is not fetched again."""
    path = mirror_path(root, url)
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = path.parent / f".{path.name}.synced"
    with open(path.parent / f".{path.name}.lock", "a+") as lock:
        start = clock()
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                    raise
                if clock() - start > lock_wait:
                    return {"mirror": str(path), "result": "busy"}
                sleep(1.0)
        try:
            try:
                age = clock() - float(stamp.read_text())
            except (OSError, ValueError):
                age = float("inf")
            if (path / "HEAD").exists() and age < min_interval:
                return {"mirror": str(path), "result": "fresh", "age_seconds": round(age)}
            made = False
            if not (path / "HEAD").exists():
                tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
                shutil.rmtree(tmp, ignore_errors=True)
                # A seed is a full local clone: copying it costs no GitHub request at all.
                if seed and git("-C", seed, "config", "--get-regexp", r"^remote\..*\.partialclonefilter$",
                                env=env, check=False).stdout.strip():
                    raise RuntimeError(f"seed {seed} is a partial clone; a mirror needs every blob")
                git("clone", "--bare", "--no-tags", "--quiet", seed or url, str(tmp), env=env)
                os.replace(tmp, path)
                made = True
            for key, value in MIRROR_CONFIG:
                git("--git-dir", str(path), "config", "--replace-all", key, value, env=env)
            git("--git-dir", str(path), "config", "remote.origin.url", url, env=env)
            for key in ("remote.origin.partialclonefilter", "remote.origin.promisor"):
                git("--git-dir", str(path), "config", "--unset-all", key, env=env, check=False)
            if seed or not made:
                git("--git-dir", str(path), "fetch", "--quiet", "--no-tags", "--no-auto-maintenance", "origin",
                    env=env)
            stamp.write_text(str(clock()))
            return {"mirror": str(path), "result": "made" if made else "fetched"}
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def common_git_dir(repo: str, env: dict[str, str] | None = None) -> Path:
    out = git("-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir", env=env).stdout.strip()
    return Path(out)


def alternates_file(repo: str, env: dict[str, str] | None = None) -> Path:
    return common_git_dir(repo, env) / "objects" / "info" / "alternates"


def mirror_adopt(repo: str, mirror: Path, keep_filter: bool, env: dict[str, str] | None = None) -> dict:
    """Read missing objects from MIRROR before asking GitHub, for REPO's clone and all its worktrees."""
    objects = (mirror / "objects").resolve()
    if not objects.is_dir():
        raise RuntimeError(f"no mirror at {mirror}; run `mirror sync` first")
    path = alternates_file(repo, env)
    lines = path.read_text().splitlines() if path.exists() else []
    added = str(objects) not in lines
    if added:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{line}\n" for line in [*lines, str(objects)]))
    dropped = []
    if not keep_filter:
        listing = git("-C", repo, "config", "--local", "--get-regexp", r"^remote\..*\.partialclonefilter$",
                      env=env, check=False).stdout.split("\n")
        for line in filter(None, listing):
            key = line.split()[0]
            git("-C", repo, "config", "--local", "--unset-all", key, env=env)
            dropped.append(key)
    return {"repo": repo, "alternate": str(objects), "added": added, "dropped_filters": dropped}


def mirror_unadopt(repo: str, mirror: Path, env: dict[str, str] | None = None) -> dict:
    """Copy every object REPO reaches through the mirror into REPO, then stop using the mirror."""
    objects = str((mirror / "objects").resolve())
    path = alternates_file(repo, env)
    lines = path.read_text().splitlines() if path.exists() else []
    if objects not in lines:
        return {"repo": repo, "removed": False}
    git("-C", repo, "repack", "-a", "-d", "-q", env=env)
    rest = [line for line in lines if line != objects]
    if rest:
        path.write_text("".join(f"{line}\n" for line in rest))
    else:
        path.unlink()
    return {"repo": repo, "removed": True}


def main(argv: Sequence[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if Path(sys.argv[0]).name == HELPER_NAME:
        return helper_main(argv)
    if argv[:1] == ["helper"]:
        return helper_main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "uninstall"):
        one = sub.add_parser(name)
        one.add_argument("--repo", action="append", default=[], help="a checkout whose shared config to change")
        one.add_argument("--scan", action="append", default=[],
                         help="route every clone up to 3 folders under this one (repeatable)")
        if name == "install":
            one.add_argument("--bin-dir", help="where git-remote-ghgate goes (default: first writable of "
                                               "/opt/homebrew/bin, /usr/local/bin, ~/.local/bin)")
            one.add_argument("--share-dir", help="where the gate's own copy goes")
            one.add_argument("--python", help="python3 the helper runs")
            one.add_argument("--force", action="store_true", help="route even when launchd's PATH cannot find it")
    one = sub.add_parser("prefetch")
    one.add_argument("--repo", default=".")
    one.add_argument("--remote", default="origin")
    one.add_argument("rev", nargs="+")
    sub.add_parser("status")
    one = sub.add_parser("stats")
    one.add_argument("--hours", type=float, default=24)
    one = sub.add_parser("audit")
    one.add_argument("--hours", type=float, default=24)
    one.add_argument("git_dir", nargs="+")
    mirror = sub.add_parser("mirror").add_subparsers(dest="mirror_command", required=True)
    one = mirror.add_parser("sync")
    one.add_argument("--url", default=DEFAULT_URL)
    one.add_argument("--seed", help="a full local clone to copy a new mirror from instead of GitHub")
    one.add_argument("--min-interval", type=float, default=MIRROR_MIN_INTERVAL,
                     help="skip the fetch when the last sync is newer than this many seconds")
    for name in ("adopt", "unadopt"):
        one = mirror.add_parser(name)
        one.add_argument("--repo", action="append", required=True, help="a checkout (any worktree of the clone)")
        one.add_argument("--url", default=DEFAULT_URL)
        if name == "adopt":
            one.add_argument("--keep-filter", action="store_true", help="keep the blob:none filter for new fetches")
    args = parser.parse_args(argv)
    env = dict(os.environ)
    if args.command == "mirror":
        root = mirror_root(env)
        if args.mirror_command == "sync":
            print(json.dumps(mirror_sync(args.url, root, args.seed, args.min_interval, env)))
            return 0
        for repo in args.repo:
            if args.mirror_command == "adopt":
                print(json.dumps(mirror_adopt(repo, mirror_path(root, args.url), args.keep_filter)))
            else:
                print(json.dumps(mirror_unadopt(repo, mirror_path(root, args.url))))
        return 0
    if args.command == "install":
        return install(args)
    if args.command == "uninstall":
        return uninstall(args)
    if args.command == "prefetch":
        return prefetch(args.repo, args.remote, args.rev)
    if args.command == "status":
        gate = Gate(state_dir(env), env)
        remaining, state = gate.backoff_remaining()
        state.pop("window", None)
        state.pop("lazy_window", None)
        print(json.dumps({"backoff_seconds": round(remaining), **state, "state_dir": str(gate.root)}, indent=2))
        return 0
    if args.command == "stats":
        print(json.dumps(stats(state_dir(env), args.hours, time.time()), indent=2))
        return 0
    print(json.dumps(audit(args.git_dir, args.hours, time.time()), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
