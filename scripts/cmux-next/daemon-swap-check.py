#!/usr/bin/env python3
"""Replace a running cmux-tui daemon (and acpmux daemon) with another build
while terminals and agent sessions run, and time it (HQ#7149 row L7: "R4
daemon swap: terminals and agent sessions survive, < 10 s").

Each phase starts the OLD build, opens live work, stops the old daemon the
way supervisors and the app's update do (SIGTERM), starts the NEW build on
the same state, and waits until the new daemon has adopted every piece of
work. The swap time runs from the SIGTERM to the last check passing.

  terminals: N shells in their own workspaces. Survival means the new daemon
    resolves each terminal running with the same incarnation, the same host
    pid and the same shell pid (`echo $$` before and after), the screen still
    shows the marker written before the swap, and new input echoes.
    Optional terminal scenarios (`--drill` turns all of them on, with 24
    shells and `--rollback`):
    --hidden      a shell behind a second tab of its pane (nobody shows it).
    --fullscreen  a program on the alternate screen with bracketed paste and
                  mouse reporting on: after the swap the alternate screen is
                  still up, typed input reaches the program as plain text, and
                  leaving it shows the primary screen with its marker.
                  --fullscreen-gap-host BINARY reports, not fails, a lost
                  primary screen under a program whose host BINARY's daemon
                  started (builds before the alternate-screen replay fix).
    --flood SECS  a terminal printing numbered lines through the swap: the
                  visible lines count up by one (nothing repeated, reordered or
                  missing) and end at the count the program printed.
    --typist      input typed every 10 ms before, during and after the swap
                  (each line appends its number to a file): every line a
                  daemon acknowledged arrives exactly once and in order, and no
                  refused line arrives. The terminal runs cat, so a lost line
                  is lost before the program.
    --typist-shell  a second typist into the interactive shell, as a person
                  types: its lost lines are reported with their send times
                  relative to the swap, not a failure.
    --control     the same work, load and steps with no swap: the losses of a
                  control run and of a swap run compare.
    --rollback    after old -> new, two more shells start under the new build
                  and the new daemon is swapped back to the old build, which
                  must adopt hosts started by both builds.
  agents: one acpmux session on a scripted ACP agent (this script, run as
    `--fake-agent`, so no credential or model is needed). Survival means the
    new acpmux daemon lists the session live with the same agent host pid and
    a prompt after the swap gets its answer in the same conversation.

Binaries: `--old`/`--new` take cmux-tui binaries, `--old-acpmux`/
`--new-acpmux` the matching `cmux-tui-acpmux`. `--fetch OLD_SHA NEW_SHA`
downloads both pairs from files.cmux.com (the Linux musl daemons every
trusted feat-cmux-next push publishes) into `--cache`. `--fetch nightly`
takes the two newest NEXT NIGHTLYs from the feed and swaps the daemon the
older one bundles for the newer one's, so a scheduled run swaps real builds.
Old and new must differ in bytes; two local builds may report the same
version and no commit stamp, so the new daemon is recognized by its process.

Cleanup SIGKILLs only host processes this check claimed from their records,
through a pidfd (Linux): a process that started after its record was
written, or whose start time has changed since, holds a reused pid and is
left alone. Where there are no pidfds (macOS) it signals nothing and reports
a host still alive; the graceful shutdowns end them.

Prints one JSON report and exits 0 only when every check passed and every
phase's swap took less than `--budget` seconds (10).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

FILES = "https://files.cmux.com/cmux-tui"
APPCAST = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"  # the one feed since #36287
TARGET = "x86_64-unknown-linux-musl"


# ---------------------------------------------------------------- utilities


def now() -> float:
    return time.monotonic()


def request(sock: Path, payload: dict, timeout: float = 10.0) -> dict:
    """One newline-delimited JSON request to the cmux-tui socket."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(sock))
        conn.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf)


def data(sock: Path, payload: dict) -> dict:
    response = request(sock, payload)
    if response.get("ok") is not True:
        raise RuntimeError(f"{payload.get('cmd')}: {response}")
    return response.get("data") or {}


def wait_until(what: str, deadline: float, probe):
    last = None
    while now() < deadline:
        try:
            value = probe()
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            last = error
            value = None
        if value:
            return value
        time.sleep(0.02)
    raise TimeoutError(f"{what}: timed out (last: {last})")


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def kill(pid: int) -> None:
    """SIGKILL a process this check started; it may have exited already."""
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


LINUX_PROC = Path("/proc/self/stat").exists()


def process_start(pid: int) -> float | None:
    """When a process started, None once it is gone: on Linux in seconds since
    boot (its /proc start ticks, CLOCK_BOOTTIME), elsewhere since the epoch
    (`ps -o lstart`, whole seconds, rounded down)."""
    if LINUX_PROC:
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            return int(fields[19]) / os.sysconf("SC_CLK_TCK")
        except (OSError, IndexError, ValueError):
            return None
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    try:
        return time.mktime(time.strptime(out.stdout.strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def clock_now() -> float:
    """Now, on process_start's clock."""
    return time.clock_gettime(time.CLOCK_BOOTTIME) if LINUX_PROC else time.time()


def recorded_at(path: Path) -> float:
    """When a host record was last written, on process_start's clock."""
    return path.stat().st_mtime - (time.time() - clock_now())


def start_resolution() -> float:
    """How coarse process_start is: one clock tick on Linux, a whole second from `ps`."""
    return 1 / os.sysconf("SC_CLK_TCK") if LINUX_PROC else 1.0


# Claimed host processes: pid -> (start time, a pidfd opened when claimed, or None without pidfds).
Owned = dict[int, tuple[float, int | None]]

# Recorded pids not claimed (yet), with why: kill_owned reports those still unclaimed at cleanup.
UNCLAIMED: dict[int, str] = {}


def names_root(pid: int, root: Path) -> bool:
    """Whether a process's executable, or one of its arguments (or an
    argument's `--flag=` value), is ROOT, this run's own work dir (made by
    mkdtemp), or a path inside it: whole path components only, so a pid reused
    by any other process, even one whose path merely starts with ROOT's name
    or mentions it mid-argument, does not."""
    def inside(path: str) -> bool:
        return path == str(root) or path.startswith(f"{root}/")
    def any_arg(args: list[str]) -> bool:
        return any(inside(arg) or inside(arg.partition("=")[2]) for arg in args)
    if LINUX_PROC:
        try:
            if inside(os.readlink(f"/proc/{pid}/exe")):
                return True
            raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        except OSError:
            return False
        return any_arg(raw.decode(errors="replace").split("\0"))
    out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    # mkdtemp's name has no spaces, so ps's space-joined command line splits cleanly around it.
    return any_arg(out.stdout.split())


def claim(owned: Owned, pid: int | None, written: float, root: Path) -> None:
    """Remember a recorded host process with its start time. A process that
    started after its record was written holds a reused pid, not ours. A start
    is rounded down to process_start's resolution, so a process that started
    within that much after the write could look earlier than it was: inside
    that window a pid is claimed only when its executable or command line
    names this run's work dir ROOT (a host writes its record right after it
    starts, so most fall inside it). Anything else is reported, never signalled."""
    if not pid or pid in owned:
        return
    # Never later than now: a record time read from a file's mtime can land a
    # little ahead of this clock. Then any process that takes this pid from
    # here on started after WRITTEN, so it can never pass as clearly older
    # (even with the same rounded start as the one checked) and must name ROOT.
    written = min(written, clock_now())
    start = process_start(pid)
    if start is None:
        UNCLAIMED[pid] = "gone or unreadable"
    elif start > written:
        UNCLAIMED[pid] = "started after its record was written"
    elif start + start_resolution() > written and not names_root(pid, root):
        UNCLAIMED[pid] = "not clearly older than its record, and not this run's process"
    else:
        # The pidfd is opened now, while the process is the one just checked,
        # and kept: a pid reused later (even within one tick) never takes it.
        pidfd = None
        if hasattr(os, "pidfd_open"):
            try:
                pidfd = os.pidfd_open(pid)
            except ProcessLookupError:
                UNCLAIMED[pid] = "gone or unreadable"
                return
            except OSError:
                pidfd = None  # no pidfd syscall here (ENOSYS): reported at cleanup
            if pidfd is not None and process_start(pid) != start:
                os.close(pidfd)
                UNCLAIMED[pid] = "its pid changed hands while it was claimed"
                return
        owned[pid] = (start, pidfd)
        UNCLAIMED.pop(pid, None)


def kill_owned(owned: Owned) -> None:
    """SIGKILL each claimed process through the pidfd claim() opened: it names
    that process only, so a pid reused since never receives the signal. With
    no pidfd (macOS, or a kernel without the syscall) nothing is signalled: a
    check and a kill by pid could race a reuse, so each such pid still alive is
    reported instead (the graceful shutdowns end the hosts). Every recorded pid
    left unclaimed that still runs is reported too."""
    for pid, why in sorted(UNCLAIMED.items()):
        if pid not in owned and pid_alive(pid):
            print(f"daemon-swap-check: left pid {pid} alive: {why}", file=sys.stderr)
    UNCLAIMED.clear()
    for pid, (start, pidfd) in owned.items():
        if pidfd is None:
            if pid_alive(pid):
                same = "" if process_start(pid) == start else " (its start time changed: maybe another process now)"
                print(f"daemon-swap-check: left pid {pid} alive: no pidfd to signal it safely{same}", file=sys.stderr)
            continue
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        except ProcessLookupError:
            pass  # it exited: its pid, reused or not, is left alone
        finally:
            os.close(pidfd)
    owned.clear()


def stop(proc: subprocess.Popen) -> float:
    """SIGTERM a daemon this script started; returns the time it took to exit."""
    start = now()
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    return now() - start


def digest(binary: Path) -> str:
    return hashlib.sha256(binary.read_bytes()).hexdigest()


def version(binary: Path) -> str:
    out = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=20)
    return (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr) else "?"


# ---------------------------------------------------------------- fetching


def curl_head(url: str) -> bool:
    # R2 refuses some urllib requests; curl is the documented client.
    code = subprocess.run(
        ["curl", "-sI", "-o", "/dev/null", "-w", "%{http_code}", url],
        capture_output=True, text=True, timeout=30,
    ).stdout
    return code == "200"


def fetch(sha: str, cache: Path) -> tuple[Path, Path]:
    out = cache / sha
    out.mkdir(parents=True, exist_ok=True)
    paths = []
    for name in ("cmux-tui", "cmux-tui-acpmux"):
        path = out / name
        if not path.exists():
            tmp = path.with_suffix(".part")
            subprocess.run(
                ["curl", "-sfL", "-o", str(tmp), f"{FILES}/{sha}/{name}-{TARGET}"],
                check=True, timeout=600,
            )
            tmp.chmod(0o755)
            tmp.rename(path)
        if sha[:9] not in version(path):
            raise RuntimeError(f"{path} does not report commit {sha}: {version(path)}")
        paths.append(path)
    return paths[0], paths[1]


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def feed_builds() -> list[tuple[str, str]]:
    """(version, source commit) of every NEXT NIGHTLY in the feed, newest first."""
    done = subprocess.run(["curl", "-sSf", APPCAST], capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        raise RuntimeError(f"the NEXT feed {APPCAST} is unreadable (curl exit {done.returncode}): {done.stderr.strip()[:200]}")
    xml = done.stdout
    builds = []
    for item in re.findall(r"<item>(.*?)</item>", xml, re.S):
        version_match = re.search(r"1\.0\.0-nightly\.(\d+)", item)
        if not version_match:
            continue
        commit = re.search(r"<cmux:sourceCommit[^>]*>([0-9a-f]{40})<", item)
        # The feed keeps the source commit on its newest item only (2026-11-05).
        sha = commit.group(1) if commit else nightly_run_commit(version_match.group(1))
        if sha:
            builds.append((version_match.group(0), sha))
    builds.sort(key=lambda b: int(b[0].rsplit(".", 1)[1]), reverse=True)
    return builds


def nightly_run_commit(number: str) -> str | None:
    """A NIGHTLY's number is its nightly.yml run id and a two-digit attempt
    (4191131679101 is run 41911316791, attempt 1): the run's head commit."""
    if len(number) < 3:
        return None
    # That attempt, not the run's latest: a re-run of failed jobs keeps the number.
    url = (f"https://api.github.com/repos/manaflow-ai/cmux/actions/runs/{number[:-2]}"
           f"/attempts/{int(number[-2:])}")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    auth = ["-H", f"Authorization: Bearer {token}"] if token else []
    result = subprocess.run(["curl", "-sf", *auth, url], capture_output=True, text=True, timeout=60)
    try:
        run = json.loads(result.stdout)
    except ValueError:
        return None
    if run.get("path") != ".github/workflows/nightly.yml":
        return None
    sha = run.get("head_sha") or ""
    return sha if re.fullmatch(r"[0-9a-f]{40}", sha) else None


def published_daemon(repo: Path, commit: str) -> str:
    """The Linux daemon of a NIGHTLY: its commit's published build, else the
    newest published commit in its first-parent history (a nightly-next
    commit is often published only under an earlier feat-cmux-next id)."""
    git(repo, "fetch", "-q", "origin", commit)
    for candidate in git(repo, "rev-list", "--first-parent", "-400", commit).split():
        if curl_head(f"{FILES}/{candidate}/cmux-tui-{TARGET}"):
            return candidate
    raise RuntimeError(f"no published Linux daemon in the history of {commit}")


def nightly_pair(repo: Path) -> dict:
    """The two newest NEXT NIGHTLYs in the feed and the daemons they bundle."""
    builds = feed_builds()
    if len(builds) < 2:
        raise RuntimeError(f"the NEXT feed lists {len(builds)} NIGHTLY builds; the swap needs two")
    (new_version, new_commit), (old_version, old_commit) = builds[0], builds[1]
    pair = {"old_nightly": old_version, "old_nightly_commit": old_commit,
            "new_nightly": new_version, "new_nightly_commit": new_commit}
    for side, commit in (("old", old_commit), ("new", new_commit)):
        daemon = published_daemon(repo, commit)
        pair[f"{side}_daemon_commit"] = daemon
        # Whether that daemon is the NIGHTLY's own cmux-tui (same tree).
        pair[f"{side}_same_cmux_tui_tree"] = (
            git(repo, "rev-parse", f"{daemon}:cmux-tui") == git(repo, "rev-parse", f"{commit}:cmux-tui"))
    return pair


# ---------------------------------------------------------------- terminals


class Daemon:
    def __init__(self, root: Path, session: str = "swap-check"):
        self.root = root
        self.session = session
        self.socket = root / "mux.sock"
        self.state = root / "state"
        (root / "cmux-tui").mkdir(mode=0o700, parents=True, exist_ok=True)
        self.proc: subprocess.Popen | None = None

    def start(self, binary: Path) -> None:
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("ACPMUX_", "CMUX_")) and k not in ("ENV", "BASH_ENV")}
        env.update(
            CMUX_TUI_STATE_DIR=str(self.root / "cmux-tui" / "sessions"),
            CMUX_TUI_HOST_EXE_DIR=str(self.root / "host-exe"),
            CMUX_TUI_SHELL_INTEGRATION="none",
            SHELL="/bin/sh",
        )
        with open(self.root / f"daemon-{int(time.time() * 1000)}.log", "wb") as log:
            self.proc = subprocess.Popen(
                [str(binary), "--headless", "--session", self.session, "--socket", str(self.socket),
                 "--state", str(self.state)],
                env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )

    def wait_ready(self, deadline: float) -> None:
        wait_until("daemon socket", deadline, lambda: data(self.socket, {"cmd": "identify"}))

    def screen(self, surface: int) -> str:
        return data(self.socket, {"cmd": "read-screen", "surface": surface}).get("text") or ""

    def shutdown_with_terminals(self, hosts: Owned, fallback: Path) -> None:
        """End the daemon and every terminal this check started. When no daemon
        answers (the new one never came up), a daemon of FALLBACK, the old
        build, adopts the hosts and ends them: the one way that needs no
        signal by pid, which macOS cleanup never sends."""
        try:
            for binary in (None, fallback):
                if binary is not None:
                    if self.proc is not None and self.proc.poll() is None:
                        stop(self.proc)
                    try:
                        self.socket.unlink()
                    except FileNotFoundError:
                        pass
                    self.start(binary)
                    try:
                        self.wait_ready(now() + 30)
                        # Its end_terminals ends only the terminals it has adopted.
                        wait_until("terminals adopted for cleanup", now() + 15, lambda: all(
                            data(self.socket, {"cmd": "resolve-terminal", "terminal_id": terminal})
                            .get("lifecycle") == "running" for terminal in host_pids(self.state)))
                    except TimeoutError:
                        pass
                    if self.proc.poll() is not None:
                        break
                try:
                    ident = data(self.socket, {"cmd": "identify"})
                    data(self.socket, {"cmd": "shutdown-daemon", "pid": ident.get("pid"),
                                       "generation": ident.get("generation"), "end_terminals": True})
                    if self.proc.poll() is None:
                        self.proc.wait(timeout=20)
                    break
                except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
                    if self.proc.poll() is None:
                        stop(self.proc)
        finally:
            # Only the hosts this check started (claimed from their records
            # above), even when starting or stopping a daemon raised.
            kill_owned(hosts)


def host_pids(state: Path) -> dict[str, int]:
    """terminal id -> host pid, from the host records under the state dir."""
    found: dict[str, int] = {}
    for path in state.rglob("*.json"):
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and "host_pid" in record:
            key = norm(record.get("terminal_id") or record.get("id") or path.stem)
            found[key] = int(record["host_pid"])
    return found


def claim_hosts(state: Path, owned: Owned) -> None:
    for path in state.rglob("*.json"):
        try:
            record = json.loads(path.read_text())
            if isinstance(record, dict) and "host_pid" in record:
                claim(owned, int(record["host_pid"]), recorded_at(path), state.parent)
        except (OSError, ValueError, TypeError):
            continue


def shell_pid(screen: str, tag: str) -> int | None:
    for line in reversed(screen.splitlines()):
        line = line.strip()
        if line.startswith(f"{tag}=") and line[len(tag) + 1:].isdigit():
            return int(line[len(tag) + 1:])
    return None


class Scenarios:
    """Which extra kinds of live work the terminals phase opens (`--drill` turns all on)."""

    def __init__(self, args: argparse.Namespace):
        self.hidden = args.hidden
        self.fullscreen = args.fullscreen
        self.flood_secs = args.flood
        self.typist = args.typist
        # A second typist into an interactive shell: reported, not a failure (see Typist).
        self.typist_shell = getattr(args, "typist_shell", False)
        # No swap: the same work, load and steps with the daemon left running (a control run).
        self.control = getattr(args, "control", False)
        # Hosts of these binaries may lose the primary screen under a full-screen program.
        self.gap_hosts = {same_file_key(b) for b in getattr(args, "fullscreen_gap_host", None) or []}

    @classmethod
    def none(cls) -> "Scenarios":
        return cls(argparse.Namespace(hidden=False, fullscreen=False, flood=0, typist=False,
                                      typist_shell=False, control=False))


def same_file_key(binary: Path) -> str:
    """One spelling per file, so a binary named twice compares equal."""
    return str(Path(binary).expanduser().resolve())


def printed(screen: str, line: str) -> bool:
    """Whether the screen holds LINE as a whole line of output (a typed
    command line never equals what it prints: they use `$((n))`)."""
    return any(row.strip() == line for row in screen.splitlines())


def open_shell(daemon: Daemon, kind: str, tag: str, born: int, **where) -> dict:
    """BORN is the index of the build (in the swap order) whose daemon started the host."""
    """A /bin/sh terminal with its shell pid read from its own screen."""
    created = data(daemon.socket, {"cmd": "run", "argv": ["/bin/sh"], **where})
    term = {
        "surface": created["surface"],
        "terminal_id": created["terminal_id"],
        "incarnation": created["terminal_incarnation"],
        "pane": created.get("pane"),
        "kind": kind, "tag": tag, "born": born,
    }
    data(daemon.socket, {"cmd": "send", "surface": term["surface"], "text": "echo PIDS$((0))=$$\n"})
    screen = wait_until(f"{tag} shell pid", now() + 15,
                        lambda: (s := daemon.screen(term["surface"])) and shell_pid(s, "PIDS0") and s)
    term["shell_pid"] = shell_pid(screen, "PIDS0")
    return term


def open_work(daemon: Daemon, count: int, scenarios: Scenarios, born: int) -> list[dict]:
    """COUNT shells in their own workspaces, plus the scenario terminals."""
    tag = f"T{os.getpid()}B{born}"
    terms = [open_shell(daemon, "shell", f"{tag}N{i}", born, new_workspace=True) for i in range(count)]
    if scenarios.hidden and terms:
        # A second tab in the first shell's pane: the first shell is now a tab nobody shows.
        pane = terms[0]["pane"] or data(daemon.socket, {
            "cmd": "resolve-terminal", "terminal_id": terms[0]["terminal_id"]}).get("pane")
        if pane is None:
            raise RuntimeError("the run response names no pane for the hidden-tab scenario")
        terms[0]["kind"] = "behind-a-tab"
        terms.append(open_shell(daemon, "front-tab", f"{tag}H", born, pane=pane))
    if scenarios.fullscreen:
        terms.append(open_shell(daemon, "fullscreen", f"{tag}F", born, new_workspace=True))
    if born == 0:
        if scenarios.flood_secs > 0:
            terms.append(open_shell(daemon, "flood", f"{tag}L", born, new_workspace=True))
        if scenarios.typist:
            terms.append(open_shell(daemon, "typist", f"{tag}Y", born, new_workspace=True))
        if scenarios.typist_shell:
            terms.append(open_shell(daemon, "typist-shell", f"{tag}S", born, new_workspace=True))
    return terms


def norm(terminal_id: str) -> str:
    """A terminal id as host records spell it: lowercase hex, no dashes."""
    return str(terminal_id).replace("-", "").lower()


def resolve(sock: Path, terminal_id: str) -> dict:
    return data(sock, {"cmd": "resolve-terminal", "terminal_id": terminal_id})


# How often a typist types a line (`--typist-every`).
TYPIST_EVERY_SECS = 0.01

# A control run's pause where the swap would be: about the old daemon's exit plus the new one's start.
CONTROL_PAUSE_SECS = 0.5

FULLSCREEN_ENTER = ("printf '\\033[?1049h\\033[?2004h\\033[?1000h\\033[2J\\033[H'; echo ALT$(({k})); read x; "
                    "printf '\\033[?1000l\\033[?2004l\\033[?1049l'; echo LEFT$(({k}))-$x\n")
FLOOD = ("perl -e '$t=time; $i=0; while (time-$t < {secs}) {{ print \"F{k}L$i\\n\"; $i++ }} "
         "print \"F{k}DONE$i\\n\"'\n")


def flood_report(screen: str, step: int) -> dict:
    """The visible flood lines must count up by one with nothing repeated,
    reordered or missing between them, and end where the program said."""
    line, last = re.compile(rf"F{step}L(\d+)"), re.compile(rf"F{step}DONE(\d+)")
    nums = [int(m.group(1)) for row in screen.splitlines() if (m := line.fullmatch(row.strip()))]
    done = [int(m.group(1)) for row in screen.splitlines() if (m := last.fullmatch(row.strip()))]
    consecutive = bool(nums) and nums == list(range(nums[0], nums[0] + len(nums)))
    ends_right = bool(done) and bool(nums) and nums[-1] == done[-1] - 1
    return {"lines_seen": len(nums), "printed": done[-1] if done else None,
            "consecutive": consecutive, "ends_at_the_last_line": ends_right,
            "passed": consecutive and ends_right}


class Typist:
    """Types the line `K` into one terminal every 10 ms through whichever
    daemon answers on the socket, before, during and after the swap. Each K is
    `acked` (the daemon answered ok), `refused` (no daemon took the
    connection: never delivered), `rejected` (a daemon answered an error) or
    `unknown` (a connection that broke after the request was sent). After the
    swap every acked K must be in FILE exactly once, nothing twice, refused
    and rejected never, in the order typed.

    Two kinds. `cat` (the pass/fail one): the terminal runs `exec cat >> FILE`, which
    writes every line it reads, so a lost line is lost before the program. `shell`
    (reported, not a failure): the line is `echo K >> FILE` typed into the interactive
    /bin/sh, as a person types; its line editor takes the input, so a loss there may be
    the shell's. Its report keeps the send time of each lost line relative to the swap,
    to set a loss near the new daemon's start apart from a loss at any time (`--control`)."""

    def __init__(self, daemon: Daemon, term: dict, path: Path, round_no: int, kind: str = "cat"):
        import threading
        self.daemon, self.term, self.path, self.kind = daemon, term, path, kind
        self.base = round_no * 1_000_000
        self.sent_at: dict[int, float] = {}
        self.every = TYPIST_EVERY_SECS
        # exec keeps the shell's pid, so the terminal's process is the same.
        if kind == "cat" and term.get("typing_into") != path:
            data(daemon.socket, {"cmd": "send", "terminal_id": term["terminal_id"],
                                 "text": f"exec cat >> {shlex.quote(str(path))}\n"})
            wait_until("typist cat", now() + 15, lambda: path.exists())
            term["typing_into"] = path
        self.status: dict[int, str] = {}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def run(self) -> None:
        k = self.base
        while not self.stop.is_set():
            k += 1
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                    conn.settimeout(5)
                    conn.connect(str(self.daemon.socket))
                    sent = False
                    try:
                        # By the stable terminal id: a surface id does not survive a swap.
                        self.sent_at[k] = time.time()
                        conn.sendall((json.dumps({"cmd": "send", "terminal_id": self.term["terminal_id"],
                                                  "text": self.line(k)}) + "\n").encode())
                        sent = True
                        buf = b""
                        while not buf.endswith(b"\n"):
                            chunk = conn.recv(65536)
                            if not chunk:
                                break
                            buf += chunk
                        response = json.loads(buf)
                        self.status[k] = "acked" if response.get("ok") is True else "rejected"
                    except (OSError, ValueError):
                        self.status[k] = "unknown" if sent else "refused"
            except (OSError, RuntimeError, ValueError):
                self.status[k] = "refused"
            time.sleep(self.every)

    def line(self, word) -> str:
        return f"{word}\n" if self.kind == "cat" else f"echo {word} >> {shlex.quote(str(self.path))}\n"

    def finish(self, deadline: float, marks: dict | None = None) -> dict:
        """MARKS: wall times of the swap's steps (`stop`, `ready`), for the lost lines' times."""
        self.stop.set()
        self.thread.join(timeout=30)
        end = f"END{self.base}"
        surface = resolve(self.daemon.socket, self.term["terminal_id"])["surface"]
        data(self.daemon.socket, {"cmd": "send", "surface": surface, "text": self.line(end)})
        wait_until("typist end line", deadline,
                   lambda: self.path.exists() and end in self.path.read_text().split())
        seen: dict[int, int] = {}
        order: list[int] = []
        for word in self.path.read_text().split():
            if word.isdigit() and int(word) > self.base and int(word) < self.base + 1_000_000:
                seen[int(word)] = seen.get(int(word), 0) + 1
                order.append(int(word))
        by = lambda st: [k for k, s in self.status.items() if s == st]
        lost = [k for k in by("acked") if seen.get(k, 0) != 1]
        doubled = [k for k, n in seen.items() if n > 1]
        ghost = [k for k in by("refused") + by("rejected") if k in seen]
        in_order = order == sorted(order)
        when: dict = {}
        if lost:
            runs = sum(1 for i, k in enumerate(lost) if i == 0 or k != lost[i - 1] + 1)
            when = {"lost_runs": runs, "lost_first_sent_wall": round(self.sent_at[lost[0]], 3),
                    "lost_last_sent_wall": round(self.sent_at[lost[-1]], 3)}
            for name, at in (marks or {}).items():
                when[f"lost_first_secs_after_{name}"] = round(self.sent_at[lost[0]] - at, 3)
                when[f"lost_last_secs_after_{name}"] = round(self.sent_at[lost[-1]] - at, 3)
        return {"kind": self.kind, "typed": len(self.status), "acked": len(by("acked")), "refused": len(by("refused")),
                "rejected": len(by("rejected")), "unknown": len(by("unknown")),
                "unknown_delivered": len([k for k in by("unknown") if k in seen]),
                "acked_lost": lost[:20], "acked_lost_count": len(lost), **when,
                "doubled": doubled[:20], "delivered_but_refused": ghost[:20],
                "in_order": in_order, "passed": not lost and not doubled and not ghost and in_order}


def terminal_phase(builds: list[Path], count: int, work: Path, scenarios: Scenarios, session: str) -> list[dict]:
    daemon = Daemon(work / "terminals", session)
    started: Owned = {}
    try:
        return terminal_swaps(daemon, builds, count, started, scenarios, work)
    finally:
        if daemon.proc is not None:
            claim_hosts(daemon.state, started)
            daemon.shutdown_with_terminals(started, builds[0])


def terminal_swaps(daemon: Daemon, builds: list[Path], count: int, started: Owned,
                   scenarios: Scenarios, work: Path) -> list[dict]:
    """Start BUILDS[0], open the work, then swap to each next build in turn
    (old -> new, and with --rollback new -> old), checking every terminal
    after each swap. Terminals opened by a build before a later swap (born
    under the new build, adopted back by the old one) are checked too."""
    daemon.start(builds[0])
    daemon.wait_ready(now() + 30)
    terms = open_work(daemon, count, scenarios, born=0)
    reports = []
    for step in range(1, len(builds)):
        if step > 1:
            # Terminals the build now running started: the next swap adopts its hosts.
            later = Scenarios.none()
            later.fullscreen = scenarios.fullscreen
            terms += open_work(daemon, min(2, count), later, born=step - 1)
        reports.append(one_swap(daemon, builds, step, terms, started, scenarios, work))
    return reports


def one_swap(daemon: Daemon, builds: list[Path], step: int, terms: list[dict], started: Owned,
             scenarios: Scenarios, work: Path) -> dict:
    old, new = builds[step - 1], builds[step]
    before_id = data(daemon.socket, {"cmd": "identify"})
    for t in terms:
        if t["kind"] in ("shell", "behind-a-tab", "front-tab", "fullscreen"):
            data(daemon.socket, {"cmd": "send", "surface": t["surface"], "text": f"echo {t['tag']}K$(({step}))\n"})
    for t in terms:
        if t["kind"] in ("shell", "behind-a-tab", "front-tab", "fullscreen"):
            wait_until(f"{t['tag']} marker before swap", now() + 15,
                       lambda t=t: printed(daemon.screen(t["surface"]), f"{t['tag']}K{step}"))
    extras: dict = {}
    for full in (t for t in terms if t["kind"] == "fullscreen"):
        data(daemon.socket, {"cmd": "send", "surface": full["surface"], "text": FULLSCREEN_ENTER.format(k=step)})
        wait_until("fullscreen program up", now() + 15, lambda full=full: (s := daemon.screen(full["surface"]))
                   and printed(s, f"ALT{step}") and not printed(s, f"{full['tag']}K{step}"))
    flood = next((t for t in terms if t["kind"] == "flood"), None)
    if flood:
        data(daemon.socket, {"cmd": "send", "surface": flood["surface"],
                             "text": FLOOD.format(secs=scenarios.flood_secs, k=step)})
        wait_until("flood running", now() + 15, lambda: any(
            re.fullmatch(rf"F{step}L\d+", r.strip()) for r in daemon.screen(flood["surface"]).splitlines()))
    hosts = wait_until("host records", now() + 15,
                       lambda: (h := host_pids(daemon.state)) and all(norm(t["terminal_id"]) in h for t in terms) and h)
    claim_hosts(daemon.state, started)
    old_pid = daemon.proc.pid
    typists = []
    for kind, term_kind, name in (("cat", "typist", "typed.txt"), ("shell", "typist-shell", "typed-shell.txt")):
        term = next((t for t in terms if t["kind"] == term_kind), None)
        if term:
            typists.append(Typist(daemon, term, work / name, step, kind))
    for typist in typists:
        typist.start()
    if typists:
        time.sleep(0.3)

    t0 = now()
    marks = {"stop": time.time()}
    if scenarios.control:
        # The same steps with no swap: the daemon keeps running for about as long as a swap takes.
        time.sleep(CONTROL_PAUSE_SECS)
        stop_secs = 0.0
        alive_after_stop = True
    else:
        stop_secs = stop(daemon.proc)
        alive_after_stop = (all(pid_alive(t["shell_pid"]) for t in terms)
                            and all(pid_alive(hosts[norm(t["terminal_id"])]) for t in terms))
        try:
            daemon.socket.unlink()
        except FileNotFoundError:
            pass
        daemon.start(new)
        daemon.wait_ready(t0 + 60)
    ready_secs = now() - t0
    marks["ready"] = time.time()
    after_id = data(daemon.socket, {"cmd": "identify"})

    checks = []
    deadline = t0 + 60
    for i, t in enumerate(terms):
        def adopted(t=t):
            r = resolve(daemon.socket, t["terminal_id"])
            ok = r.get("lifecycle") == "running" and r.get("terminal_incarnation") == t["incarnation"]
            return ok and r.get("surface")
        row = {"terminal": i, "kind": t["kind"], "born": t["born"]}
        try:
            surface = wait_until("adopted", deadline, adopted)
            t["surface"] = surface
            row["adopted"] = True
            if t["kind"] == "fullscreen":
                row["alt_screen_kept"] = printed(daemon.screen(surface), f"ALT{step}")
                data(daemon.socket, {"cmd": "send", "surface": surface, "text": "bye\n"})
                screen = wait_until("fullscreen program left", deadline, lambda: (s := daemon.screen(surface))
                                    and any(re.fullmatch(rf"LEFT{step}-.*", r.strip()) for r in s.splitlines()) and s)
                answer = next(r.strip() for r in screen.splitlines() if r.strip().startswith(f"LEFT{step}-"))
                row["typed_after_swap_reads_as"] = answer
                row["input_plain"] = answer == f"LEFT{step}-bye"
                row["primary_screen_kept"] = printed(screen, f"{t['tag']}K{step}")
                primary_ok = row["primary_screen_kept"]
                if not primary_ok and same_file_key(builds[t["born"]]) in scenarios.gap_hosts:
                    # A host makes its own snapshot: before the alternate-screen
                    # replay fix it carried no primary screen.
                    row["known_gap"] = f"primary screen under a program, host of {builds[t['born']]}"
                    primary_ok = True
                row["scrollback_kept"] = row["alt_screen_kept"] and primary_ok and row["input_plain"]
            elif t["kind"] in ("shell", "behind-a-tab", "front-tab"):
                row["scrollback_kept"] = printed(daemon.screen(surface), f"{t['tag']}K{step}")
            else:
                row["scrollback_kept"] = True  # flood and typists scroll their markers away; checked below
            if t["kind"] == "flood":
                screen = wait_until("flood done", deadline + scenarios.flood_secs, lambda: (s := daemon.screen(surface))
                                    and any(re.fullmatch(rf"F{step}DONE\d+", r.strip()) for r in s.splitlines()) and s)
                extras["flood"] = flood_report(screen, step)
            if not t["kind"].startswith("typist"):
                data(daemon.socket, {"cmd": "send", "surface": surface, "text": f"echo PIDA$(({step}))=$$\n"})
                screen = wait_until("echo after swap", deadline,
                                    lambda: (s := daemon.screen(surface)) and shell_pid(s, f"PIDA{step}") and s)
                row["same_shell_pid"] = shell_pid(screen, f"PIDA{step}") == t["shell_pid"]
            else:
                row["same_shell_pid"] = True  # the typist's file proves its shell; checked below
            row["input_echoes"] = True
        except TimeoutError as error:
            row.update(adopted=False, error=str(error))
        checks.append(row)
    swap_secs = now() - t0
    reported: dict = {}
    if typists:
        time.sleep(0.5)  # keep typing into the adopted terminals a little longer
    for typist in typists:
        # The cat typist passes or fails the swap; the shell typist is a reported count.
        into = extras if typist.kind == "cat" else reported
        key = "typist" if typist.kind == "cat" else "typist_shell"
        try:
            into[key] = typist.finish(now() + 30, marks)
        except (TimeoutError, OSError, RuntimeError) as error:
            into[key] = {"kind": typist.kind, "passed": False, "error": str(error)}
    hosts_after = host_pids(daemon.state)
    same_hosts = all(hosts_after.get(norm(t["terminal_id"])) == hosts[norm(t["terminal_id"])] for t in terms)
    claim_hosts(daemon.state, started)
    # The new build answers: its own process, not the old one (two unstamped
    # local builds report the same build_commit; main() refuses identical bytes).
    new_daemon = after_id.get("pid") == daemon.proc.pid != old_pid == before_id.get("pid")
    if scenarios.control:
        new_daemon = after_id.get("pid") == daemon.proc.pid == old_pid
    passed = alive_after_stop and same_hosts and new_daemon and all(
        c.get("adopted") and c.get("scrollback_kept") and c.get("same_shell_pid") for c in checks) and all(
        e.get("passed") for e in extras.values())
    return {
        "phase": "terminals" if step == 1 else f"terminals-swap-{step}",
        "passed": passed, "count": len(terms),
        "old_build": before_id.get("build_commit"), "new_build": after_id.get("build_commit"),
        "old_binary": str(old), "new_binary": str(new),
        "old_daemon_exit_secs": round(stop_secs, 3), "new_daemon_answers_secs": round(ready_secs, 3),
        "swap_secs": round(swap_secs, 3), "processes_alive_while_no_daemon": alive_after_stop,
        "same_host_pids": same_hosts, "terminals": checks, **extras, **reported,
        **({"control": True} if scenarios.control else {}),
        "marks_wall": {name: round(at, 3) for name, at in marks.items()},
    }


# ---------------------------------------------------------------- agents


def fake_agent() -> int:
    """A minimal ACP agent on stdio: answers every prompt with its pid and a
    turn count, so the check sees the same process and conversation."""
    turns = 0
    session = f"fake-{os.getpid()}"
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, mid = msg.get("method"), msg.get("id")

        def reply(result):
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
            sys.stdout.flush()

        if method == "initialize":
            reply({"protocolVersion": 1, "agentCapabilities": {"loadSession": False},
                   "authMethods": []})
        elif method == "session/new":
            reply({"sessionId": session})
        elif method == "session/prompt":
            turns += 1
            text = f"fake-agent pid={os.getpid()} turn={turns}"
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": session, "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}}}}) + "\n")
            sys.stdout.flush()
            reply({"stopReason": "end_turn"})
        elif mid is not None:
            reply({})
    return 0


class Acpmux:
    """An acpmux daemon on its own home and config dir: nothing reaches the
    host's daemon (every inherited ACPMUX_* and CMUX_* variable is dropped)."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        root.chmod(0o700)  # acpmux refuses a group-writable ancestor of its state
        self.home = root / "acpmux-home"
        self.xdg = root / "xdg"
        self.home.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.xdg.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.proc: subprocess.Popen | None = None

    def env(self) -> dict:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
        env.update(ACPMUX_HOME=str(self.home), XDG_CONFIG_HOME=str(self.xdg))
        return env

    def run(self, binary: Path, *args: str, timeout: float = 60) -> str:
        out = subprocess.run([str(binary), *args], env=self.env(), capture_output=True, text=True,
                             timeout=timeout)
        if out.returncode != 0:
            raise RuntimeError(f"acpmux {' '.join(args)}: {(out.stderr or out.stdout).strip()}")
        return out.stdout

    def status(self, binary: Path) -> dict:
        return json.loads(self.run(binary, "--json", "daemon", "status", timeout=10))

    def start(self, binary: Path) -> None:
        with open(self.root / f"acpmux-{int(time.time() * 1000)}.log", "wb") as log:
            self.proc = subprocess.Popen([str(binary), "daemon", "run"], env=self.env(), stdout=log,
                                         stderr=subprocess.STDOUT, start_new_session=True)

    def claim_hosts(self, owned: Owned) -> None:
        for path in (self.home / "hosts").glob("*.json"):
            try:
                record = json.loads(path.read_text())
                written = recorded_at(path)
            except (OSError, ValueError):
                continue
            for key in ("host_pid", "harness_pid"):
                if isinstance(record.get(key), int):
                    claim(owned, record[key], written, self.root)

    def host_records(self) -> list[dict]:
        records = []
        for path in (self.home / "hosts").glob("*.json"):
            try:
                records.append(json.loads(path.read_text()))
            except (OSError, ValueError):
                pass
        return records


def agent_phase(old: Path, new: Path, work: Path) -> dict:
    mux = Acpmux(work / "agents")
    wrapper = mux.root / "fake-agent"
    script = shlex.quote(str(Path(__file__).resolve()))
    wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} -I {script} --fake-agent\n")
    wrapper.chmod(0o755)
    mux.run(old, "harness", "add", "swapfake", "--command", str(wrapper))
    mux.start(old)
    owned: Owned = {}
    try:
        old_status = wait_until("acpmux daemon", now() + 30, lambda: (s := mux.status(old)).get("build") and s)
        mux.run(old, "new", "-m", "swapfake", "-n", "swap", "-d", "--cwd", str(mux.root), "hello")
        first = wait_until("first reply", now() + 30,
                           lambda: (r := mux.run(old, "last", "swap")) and "turn=1" in r and r)
        before_pid = _agent_pid(first)
        hosts = mux.host_records()
        pids = [p for r in hosts for p in (r.get("host_pid"), r.get("harness_pid")) if p]
        mux.claim_hosts(owned)
        # The harness that just answered (it runs now, so it started before now).
        claim(owned, before_pid, clock_now(), mux.root)

        t0 = now()
        stop_secs = stop(mux.proc)
        alive = bool(pids) and all(pid_alive(p) for p in pids)
        mux.start(new)
        new_status = wait_until("new acpmux daemon", t0 + 60,
                                lambda: (s := mux.status(new)).get("pid") == mux.proc.pid and s)
        ready_secs = now() - t0
        mux.run(new, "send", "swap", "again")
        second = wait_until("reply after swap", t0 + 60,
                            lambda: (r := mux.run(new, "last", "swap")) and "turn=2" in r and r)
        swap_secs = now() - t0
        after_pid = _agent_pid(second)
        same_host = [r.get("host_pid") for r in mux.host_records()] == [r.get("host_pid") for r in hosts]
        try:
            mux.run(new, "session", "stop", "swap", timeout=30)
        except RuntimeError:
            pass
    finally:
        # A CLI call can start its own daemon in this isolated home when the
        # one started here died: ask whichever answers there to shut down
        # with its agents (`daemon shutdown` never starts one).
        def shut_down() -> bool:
            for binary in (new, old):
                try:
                    mux.run(binary, "daemon", "shutdown", "--end-agents", timeout=20)
                    return True
                except (RuntimeError, subprocess.TimeoutExpired):
                    pass
            return False
        try:
            if not shut_down():
                # None answers (the new daemon never came up): the old build's
                # daemon adopts the agent hosts and ends them, with no signal by pid.
                if mux.proc and mux.proc.poll() is None:
                    stop(mux.proc)
                mux.start(old)
                try:
                    wait_until("acpmux daemon for cleanup", now() + 30, lambda: mux.status(old))
                    shut_down()
                except TimeoutError:
                    pass
            if mux.proc and mux.proc.poll() is None:
                stop(mux.proc)
        finally:
            # Only agent hosts and harnesses of this isolated home (its records,
            # read again here, so a failure before the swap leaves none), even
            # when starting or stopping a daemon raised.
            try:
                mux.claim_hosts(owned)
            finally:
                kill_owned(owned)
    same_conversation = "turn=2" in second
    return {
        "phase": "agents",
        "passed": alive and same_host and before_pid == after_pid and same_conversation,
        "old_build": old_status.get("build"), "new_build": new_status.get("build"),
        "old_daemon_exit_secs": round(stop_secs, 3), "new_daemon_answers_secs": round(ready_secs, 3),
        "swap_secs": round(swap_secs, 3), "agent_alive_while_no_daemon": alive,
        "same_agent_host_pid": same_host, "same_harness_pid": before_pid == after_pid,
        "same_conversation": same_conversation,
    }


def _agent_pid(reply: str) -> int | None:
    match = re.search(r"fake-agent pid=(\d+)", reply)
    return int(match.group(1)) if match else None


# ---------------------------------------------------------------- main


def main() -> int:
    if "--fake-agent" in sys.argv:
        return fake_agent()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--old", type=Path)
    parser.add_argument("--new", type=Path)
    parser.add_argument("--old-acpmux", type=Path)
    parser.add_argument("--new-acpmux", type=Path)
    parser.add_argument("--fetch", nargs="+", metavar="SHA", help="OLD_SHA NEW_SHA, or nightly")
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "cmux-daemon-swap-bins")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--terminals", type=int, default=4)
    parser.add_argument("--budget", type=float, default=10.0)
    parser.add_argument("--phases", default="terminals,agents")
    parser.add_argument("--keep", action="store_true", help="keep the work dir")
    parser.add_argument("--session", default="swap-check", help="the daemon's --session name")
    parser.add_argument("--work-root", type=Path, default=Path("/tmp"), help="where the work dir is made")
    parser.add_argument("--rollback", action="store_true",
                        help="after old -> new, swap back new -> old (adopting hosts both builds started)")
    parser.add_argument("--hidden", action="store_true", help="a shell behind a second tab in its pane")
    parser.add_argument("--fullscreen", action="store_true",
                        help="a program on the alternate screen with bracketed paste and mouse modes on")
    parser.add_argument("--flood", type=float, default=0.0, metavar="SECS",
                        help="a terminal printing numbered lines for SECS seconds across the swap")
    parser.add_argument("--typist", action="store_true",
                        help="input typed every 10 ms before, during and after the swap; each acked line once")
    parser.add_argument("--typist-shell", action="store_true",
                        help="a second typist into the interactive shell (`echo K >> FILE`): its lost lines "
                             "are reported with their times, not a failure")
    parser.add_argument("--typist-every", type=float, default=10.0, metavar="MS",
                        help="milliseconds between a typist's lines (default 10)")
    parser.add_argument("--control", action="store_true",
                        help="a control run: the same work, load and steps, with no swap (the daemon keeps "
                             "running); compares the typists' losses with and without a swap")
    parser.add_argument("--fullscreen-gap-host", type=Path, action="append", metavar="BINARY",
                        help="report, not fail, a lost primary screen under a full-screen program whose host "
                             "BINARY's daemon started (a build before the alternate-screen replay fix); repeatable")
    parser.add_argument("--drill", action="store_true",
                        help="the update drill: --rollback --hidden --fullscreen --flood 4 --typist --typist-shell, "
                             "24 terminals")
    args = parser.parse_args()
    global TYPIST_EVERY_SECS
    TYPIST_EVERY_SECS = args.typist_every / 1000
    if args.drill:
        args.rollback = args.hidden = args.fullscreen = args.typist = args.typist_shell = True
        args.flood = args.flood or 4.0
        if "--terminals" not in sys.argv:
            args.terminals = 24

    report: dict = {"budget_secs": args.budget}
    if args.fetch:
        if args.fetch == ["nightly"]:
            pair = nightly_pair(args.repo)
            report["nightly"] = pair
            old_sha, new_sha = pair["old_daemon_commit"], pair["new_daemon_commit"]
        elif len(args.fetch) == 2:
            old_sha, new_sha = args.fetch
        else:
            parser.error("--fetch takes OLD_SHA NEW_SHA or nightly")
        args.old, args.old_acpmux = fetch(old_sha, args.cache)
        args.new, args.new_acpmux = fetch(new_sha, args.cache)
    if not (args.old and args.new):
        parser.error("give --old and --new, or --fetch")
    report["old"] = version(args.old)
    report["new"] = version(args.new)
    # A restart of one build is not a swap: refuse identical bytes instead of
    # passing. Two local builds can report the same version and no commit.
    same = [name for name, a, b in (("cmux-tui", args.old, args.new),
                                    ("acpmux", args.old_acpmux, args.new_acpmux))
            if a and b and digest(a) == digest(b)]
    if same:
        report.update(passed=False, error=f"old and new {' and '.join(same)} are the same build")
        print(json.dumps(report, indent=2))
        return 1

    args.work_root.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="cmux-swap-", dir=str(args.work_root)))
    phases = []
    try:
        for phase in args.phases.split(","):
            try:
                if phase == "terminals":
                    builds = [args.old, args.new] + ([args.old] if args.rollback else [])
                    phases.extend(terminal_phase(builds, args.terminals, work, Scenarios(args), args.session))
                elif phase == "agents":
                    if not (args.old_acpmux and args.new_acpmux):
                        raise RuntimeError("the agents phase needs --old-acpmux and --new-acpmux (or --fetch)")
                    phases.append(agent_phase(args.old_acpmux, args.new_acpmux, work))
                else:
                    parser.error(f"unknown phase {phase}")
            except Exception as error:  # noqa: BLE001 - a failed phase is a red row, reported
                phases.append({"phase": phase, "passed": False, "error": f"{type(error).__name__}: {error}"})
    finally:
        if args.keep:
            report["work"] = str(work)
        else:
            subprocess.run(["rm", "-rf", str(work)], check=False)
    report["phases"] = phases
    shell = [p["typist_shell"] for p in phases if isinstance(p.get("typist_shell"), dict)]
    if shell:
        # Reported, not a failure: lines an interactive shell lost (its own typeahead limit or a cmux
        # loss; a --control run without a swap tells them apart).
        report["typist_shell_summary"] = {
            "phases": len(shell), "acked": sum(t.get("acked", 0) for t in shell),
            "lost": sum(t.get("acked_lost_count", 0) for t in shell),
            "phases_with_loss": sum(1 for t in shell if t.get("acked_lost_count")),
            "errors": sum(1 for t in shell if t.get("error"))}
        print(f"typist-shell (reported, not a failure): {json.dumps(report['typist_shell_summary'])}",
              file=sys.stderr, flush=True)
    report["passed"] = bool(phases) and all(
        p.get("passed") and p.get("swap_secs", 1e9) < args.budget for p in phases)
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
