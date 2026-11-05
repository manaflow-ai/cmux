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

Cleanup SIGKILLs only host processes this check claimed from their records:
a process that started after its record was written, or whose start time
has changed since, holds a reused pid and is left alone.

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
APPCAST = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
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


def process_start(pid: int) -> float | None:
    """When a process started, in seconds since the epoch; None once it is gone."""
    if Path("/proc/self/stat").exists():
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            return None
        boot = next(float(line.split()[1]) for line in Path("/proc/stat").read_text().splitlines()
                    if line.startswith("btime "))
        return boot + int(fields[19]) / os.sysconf("SC_CLK_TCK")
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    try:
        return time.mktime(time.strptime(out.stdout.strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def claim(owned: dict[int, float], pid: int | None, recorded_at: float) -> None:
    """Remember a recorded host process with its start time. A process that
    started after its record was written is a reused pid, not ours."""
    if not pid or pid in owned:
        return
    start = process_start(pid)
    if start is not None and start <= recorded_at + 1:
        owned[pid] = start


def kill_owned(owned: dict[int, float]) -> None:
    """SIGKILL each claimed process that is still the same process (its start
    time unchanged); a pid the system has since given to another process is left alone."""
    for pid, start in owned.items():
        pidfd = None
        if hasattr(os, "pidfd_open"):
            try:
                pidfd = os.pidfd_open(pid)  # pins this process: the pid can't be reused while open
            except OSError:
                continue
        try:
            if process_start(pid) != start:
                print(f"daemon-swap-check: left pid {pid}: not the recorded process", file=sys.stderr)
                continue
            if pidfd is not None:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            else:
                kill(pid)
        except ProcessLookupError:
            pass
        finally:
            if pidfd is not None:
                os.close(pidfd)


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
    xml = subprocess.run(["curl", "-sf", APPCAST], capture_output=True, text=True, timeout=60).stdout
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
    def __init__(self, root: Path):
        self.root = root
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
                [str(binary), "--headless", "--session", "swap-check", "--socket", str(self.socket),
                 "--state", str(self.state)],
                env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )

    def wait_ready(self, deadline: float) -> None:
        wait_until("daemon socket", deadline, lambda: data(self.socket, {"cmd": "identify"}))

    def screen(self, surface: int) -> str:
        return data(self.socket, {"cmd": "read-screen", "surface": surface}).get("text") or ""

    def shutdown_with_terminals(self, hosts: dict[int, float]) -> None:
        """End the daemon and every terminal this check started."""
        try:
            ident = data(self.socket, {"cmd": "identify"})
            data(self.socket, {"cmd": "shutdown-daemon", "pid": ident.get("pid"),
                               "generation": ident.get("generation"), "end_terminals": True})
            if self.proc.poll() is None:
                self.proc.wait(timeout=20)
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
            stop(self.proc)
        # Only the hosts this check started (claimed from their records above).
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
            key = str(record.get("terminal_id") or record.get("id") or path.stem)
            found[key] = int(record["host_pid"])
    return found


def claim_hosts(state: Path, owned: dict[int, float]) -> None:
    for path in state.rglob("*.json"):
        try:
            record = json.loads(path.read_text())
            if isinstance(record, dict) and "host_pid" in record:
                claim(owned, int(record["host_pid"]), path.stat().st_mtime)
        except (OSError, ValueError, TypeError):
            continue


def shell_pid(screen: str, tag: str) -> int | None:
    for line in reversed(screen.splitlines()):
        line = line.strip()
        if line.startswith(f"{tag}=") and line[len(tag) + 1:].isdigit():
            return int(line[len(tag) + 1:])
    return None


def terminal_phase(old: Path, new: Path, count: int, work: Path) -> dict:
    daemon = Daemon(work / "terminals")
    started: dict[int, float] = {}
    try:
        return terminal_swap(daemon, old, new, count, started)
    finally:
        if daemon.proc is not None:
            claim_hosts(daemon.state, started)
            daemon.shutdown_with_terminals(started)


def terminal_swap(daemon: Daemon, old: Path, new: Path, count: int, started: dict[int, float]) -> dict:
    daemon.start(old)
    daemon.wait_ready(now() + 30)
    before_id = data(daemon.socket, {"cmd": "identify"})
    terms = []
    for i in range(count):
        created = data(daemon.socket, {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
        terms.append({
            "surface": created["surface"],
            "terminal_id": created["terminal_id"],
            "incarnation": created["terminal_incarnation"],
            "marker": f"swap-before-{os.getpid()}-{i}",
        })
    for t in terms:
        data(daemon.socket, {"cmd": "send", "surface": t["surface"],
                             "text": f"echo {t['marker']}; echo PID$((0))=$$\n"})
    for t in terms:
        screen = wait_until("marker before swap", now() + 15,
                            lambda t=t: (s := daemon.screen(t["surface"])) and t["marker"] in s and shell_pid(s, "PID0") and s)
        t["shell_pid"] = shell_pid(screen, "PID0")
    hosts = wait_until("host records", now() + 15, lambda: (h := host_pids(daemon.state)) and len(h) >= count and h)
    claim_hosts(daemon.state, started)
    old_pid = daemon.proc.pid

    t0 = now()
    stop_secs = stop(daemon.proc)
    alive_after_stop = all(pid_alive(t["shell_pid"]) for t in terms) and all(pid_alive(p) for p in hosts.values())
    try:
        daemon.socket.unlink()
    except FileNotFoundError:
        pass
    daemon.start(new)
    daemon.wait_ready(t0 + 60)
    ready_secs = now() - t0
    after_id = data(daemon.socket, {"cmd": "identify"})

    checks = []
    deadline = t0 + 60
    for i, t in enumerate(terms):
        def adopted(t=t):
            r = data(daemon.socket, {"cmd": "resolve-terminal", "terminal_id": t["terminal_id"]})
            ok = r.get("lifecycle") == "running" and r.get("terminal_incarnation") == t["incarnation"]
            return ok and r.get("surface")
        try:
            surface = wait_until("adopted", deadline, adopted)
            scrollback = t["marker"] in daemon.screen(surface)
            data(daemon.socket, {"cmd": "send", "surface": surface, "text": f"echo PID$((1))=$$\n"})
            screen = wait_until("echo after swap", deadline,
                                lambda: (s := daemon.screen(surface)) and shell_pid(s, "PID1") and s)
            same_shell = shell_pid(screen, "PID1") == t["shell_pid"]
            checks.append({"terminal": i, "adopted": True, "scrollback_kept": scrollback,
                           "same_shell_pid": same_shell, "input_echoes": True})
        except TimeoutError as error:
            checks.append({"terminal": i, "adopted": False, "error": str(error)})
    swap_secs = now() - t0
    hosts_after = host_pids(daemon.state)
    same_hosts = all(hosts_after.get(k) == v for k, v in hosts.items())
    claim_hosts(daemon.state, started)
    # The new build answers: its own process, not the old one (two unstamped
    # local builds report the same build_commit; main() refuses identical bytes).
    new_daemon = after_id.get("pid") == daemon.proc.pid != old_pid == before_id.get("pid")
    passed = alive_after_stop and same_hosts and new_daemon and all(
        c.get("adopted") and c.get("scrollback_kept") and c.get("same_shell_pid") for c in checks)
    return {
        "phase": "terminals", "passed": passed, "count": count,
        "old_build": before_id.get("build_commit"), "new_build": after_id.get("build_commit"),
        "old_daemon_exit_secs": round(stop_secs, 3), "new_daemon_answers_secs": round(ready_secs, 3),
        "swap_secs": round(swap_secs, 3), "processes_alive_while_no_daemon": alive_after_stop,
        "same_host_pids": same_hosts, "terminals": checks,
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

    def claim_hosts(self, owned: dict[int, float]) -> None:
        for path in (self.home / "hosts").glob("*.json"):
            try:
                record = json.loads(path.read_text())
                recorded_at = path.stat().st_mtime
            except (OSError, ValueError):
                continue
            for key in ("host_pid", "harness_pid"):
                if isinstance(record.get(key), int):
                    claim(owned, record[key], recorded_at)

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
    owned: dict[int, float] = {}
    try:
        old_status = wait_until("acpmux daemon", now() + 30, lambda: (s := mux.status(old)).get("build") and s)
        mux.run(old, "new", "-m", "swapfake", "-n", "swap", "-d", "--cwd", str(mux.root), "hello")
        first = wait_until("first reply", now() + 30,
                           lambda: (r := mux.run(old, "last", "swap")) and "turn=1" in r and r)
        before_pid = _agent_pid(first)
        hosts = mux.host_records()
        pids = [p for r in hosts for p in (r.get("host_pid"), r.get("harness_pid")) if p]
        mux.claim_hosts(owned)
        claim(owned, before_pid, now())  # the harness that just answered

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
        for binary in (new, old):
            try:
                mux.run(binary, "daemon", "shutdown", "--end-agents", timeout=20)
                break
            except (RuntimeError, subprocess.TimeoutExpired):
                pass
        if mux.proc and mux.proc.poll() is None:
            stop(mux.proc)
        # Only agent hosts and harnesses of this isolated home (its records,
        # read again here, so a failure before the swap leaves none).
        mux.claim_hosts(owned)
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
    args = parser.parse_args()

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

    work = Path(tempfile.mkdtemp(prefix="cmux-swap-", dir="/tmp"))
    phases = []
    try:
        for phase in args.phases.split(","):
            try:
                if phase == "terminals":
                    phases.append(terminal_phase(args.old, args.new, args.terminals, work))
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
    report["passed"] = bool(phases) and all(
        p.get("passed") and p.get("swap_secs", 1e9) < args.budget for p in phases)
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
