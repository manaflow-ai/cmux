#!/usr/bin/env python3
"""The daemon-only half of the agent connection chaos suite, for a machine with no app (Linux): a real acpmux daemon
in a private home, the scripted agent (chaos_agent.py), and the acpmux CLI as the only client. It proves the part
of CONTRACT.md that does not need a page: after each fault a client is served again by itself within the bound, and
no turn is lost or doubled. It does NOT judge the page (the forbidden strings, the status dot, the composer): that is
suite.py on a Mac with the app, and nothing here stands in for it.

Each case starts a counted reply in its own chat, injects one fault mid-turn, sends one prompt while the daemon is
down or away (the CLI, as a person's send), and judges:

  - a client is served again within the case's bound, with nothing done by this script to bring the daemon back
    (the CLI's own start of a missing daemon is the product's recovery here; the app's is suite.py's subject);
  - the agent was given the stream prompt and the down-time prompt exactly once each;
  - the agent's turn ran to its end (COUNT words), and the store holds TAG-0 .. TAG-<COUNT-1>, each once, in order;
  - the down-time prompt's answer is in the store exactly once.

Cases (--cases, default all):
  daemon-sigterm   SIGTERM the daemon mid-turn.
  daemon-sigkill   SIGKILL the daemon mid-turn.
  daemon-hung      SIGSTOP the daemon and leave it stopped for the whole case (it holds its lock and socket and
                   answers nothing); SIGCONT at the end.
  sleep-wake-sim   SIMULATION: SIGSTOP the daemon, its agent hosts and the agent for --sleep seconds, then SIGCONT.
  socket-gone      The daemon's socket file moved away for 20 s, then put back.
  update-swap      The acpmux binary replaced mid-turn (a new file renamed over the path the daemon runs from, as an
                   update's swap) and nothing else: the daemon must hand over to a daemon of the new file by itself,
                   and no daemon may die in the hand-over. No download and no signature check.

Not here: app-sigkill, update-midturn (the app's relaunch), ws-port-block (no WebSocket client without the app).
The run's daemon, home, config and binary copy are all under one temporary folder; this script signals only
processes whose ACPMUX_HOME is that folder's. Exit status 0 only when every case passed; result JSON to --out.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.join(HERE, "chaos_agent.py")
CASES = ["daemon-sigterm", "daemon-sigkill", "daemon-hung", "sleep-wake-sim", "socket-gone", "update-swap"]
# The same bounds as suite.py's (CONTRACT.md "Bounds"); update-swap has update-midturn's.
BOUND = {"daemon-sigterm": 30, "daemon-sigkill": 30, "daemon-hung": 45, "sleep-wake-sim": 30, "socket-gone": 30,
         "update-swap": 60}
FAULT_AT_S = 8.0
COUNT, RATE = 240, 4.0  # a 60 s reply: every fault lands mid-turn and the turn outlives it
HARNESS = "conn-chaos"
LATE_S = 90  # how long past its bound the hung case still watches, to report a late recovery's time


def log(msg: str):
    print(f"conn-chaos-linux: {msg}", file=sys.stderr, flush=True)


def words_of(text: str, tag: str) -> list[int]:
    return [int(m) for m in re.findall(rf"\b{re.escape(tag)}-(\d+)\b", text or "")]


def whole(numbers: list[int], count: int) -> str | None:
    if numbers == list(range(count)):
        return None
    dup = sorted({n for n in numbers if numbers.count(n) > 1})
    missing = sorted(set(range(count)) - set(numbers))
    return f"{len(numbers)} words; missing {missing[:10]}{'...' if len(missing) > 10 else ''}; duplicated {dup[:10]}"


class Run:
    def __init__(self, args):
        self.args = args
        # Short: the daemon's socket is `<home>/acpmux.sock` only when that path fits a sockaddr.
        self.root = tempfile.mkdtemp(prefix="acc-", dir=args.tmp)
        self.home = os.path.join(self.root, "acpmux")
        self.agent_log = os.path.join(self.root, "agent.ndjson")
        self.binary = os.path.join(self.root, "bin", "acpmux")
        os.makedirs(os.path.dirname(self.binary))
        shutil.copy2(os.path.realpath(args.acpmux), self.binary)
        self.generation = 0
        # Nothing of the caller's session: an agent's environment makes the CLI send as that agent (held in the
        # receiver's inbox), and its ACPMUX_* would point the CLI at the machine's own daemon.
        self.env = {"PATH": "/usr/bin:/bin", "HOME": self.root, "ACPMUX_HOME": self.home,
                    "XDG_CONFIG_HOME": os.path.join(self.root, ".config"), "LANG": "C.UTF-8"}
        profiles = os.path.join(self.env["XDG_CONFIG_HOME"], "cmux", "harnesses")
        os.makedirs(profiles)
        # 0600: acpmux refuses a profile another user could change (it runs a program with this user's rights).
        with open(os.open(os.path.join(profiles, f"{HARNESS}.toml"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
            handle.write(f'schema = 1\nid = "{HARNESS}"\nname = "Conn chaos"\nprotocol = "acp"\n'
                         f'command = {json.dumps(sys.executable)}\nargs = [{json.dumps(AGENT)}, {json.dumps(self.agent_log)}]\n')
        self.daemon_log = open(os.path.join(self.root, "daemon.out"), "ab")
        subprocess.Popen([self.binary, "daemon", "run"], env=self.env, stdout=self.daemon_log, stderr=self.daemon_log,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 60
        while not self.status() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the daemon is starting
        if not self.status():
            raise SystemExit("conn-chaos-linux: the daemon did not start in 60 s")

    def cli(self, *argv: str, timeout: float = 60) -> subprocess.CompletedProcess:
        try:
            return subprocess.run([self.binary, *argv], env=self.env, capture_output=True, text=True, timeout=timeout,
                                  stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired as error:
            out = error.stdout.decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
            return subprocess.CompletedProcess(error.cmd, 124, out, f"(no answer in {timeout:.0f} s)")

    def status(self, timeout: float = 5) -> dict | None:
        """The serving daemon's status, or None: `daemon status` asks and never starts one."""
        got = self.cli("daemon", "status", "--json", timeout=timeout)
        try:
            status = json.loads(got.stdout)
        except ValueError:
            return None
        return status if isinstance(status, dict) and status.get("pid") else None

    def procs(self) -> dict[int, str]:
        """This run's processes: every process whose ACPMUX_HOME is this run's home, or whose command line names a
        file of this run's folder (an agent host started after a swap carries no ACPMUX_HOME). pid -> command line."""
        mine, needle, under = {}, f"ACPMUX_HOME={self.home}".encode(), f"{self.root}/".encode()
        for name in os.listdir("/proc"):
            if not name.isdigit() or int(name) == os.getpid():
                continue
            try:
                with open(f"/proc/{name}/cmdline", "rb") as handle:
                    words = handle.read().split(b"\0")
                if not any(word.startswith(under) for word in words):
                    with open(f"/proc/{name}/environ", "rb") as handle:
                        if needle not in handle.read().split(b"\0"):
                            continue
                mine[int(name)] = b" ".join(words).decode("utf-8", "replace").strip()
            except OSError:
                continue
        return mine

    def daemon_pids(self) -> set[int]:
        return {pid for pid, cmd in self.procs().items() if " daemon run" in cmd}

    def agent_entries(self) -> list[dict]:
        try:
            with open(self.agent_log) as handle:
                return [json.loads(line) for line in handle if line.strip()]
        except OSError:
            return []

    def stops(self) -> list[dict]:
        """Every daemon stop this home recorded today, oldest first (`daemon.stops.json`, the daemon's own record)."""
        try:
            with open(os.path.join(self.home, "daemon.stops.json")) as handle:
                return list(json.load(handle).get("recent") or [])
        except (OSError, ValueError):
            return []

    def store_text(self, session: str) -> str:
        folder = os.path.join(self.home, "sessions", session, "events")
        try:
            names = sorted(n for n in os.listdir(folder) if n.endswith(".ndjson"))
        except OSError as error:
            return f"(no store: {error})"
        text = []
        for name in names:
            with open(os.path.join(folder, name), "rb") as handle:
                text.append(handle.read().decode("utf-8", "replace"))
        return "".join(text)

    def close(self):
        self.cli("daemon", "shutdown", timeout=30)
        signal_all(self.procs(), signal.SIGCONT)
        signal_all(self.procs(), signal.SIGTERM)
        deadline = time.monotonic() + 10
        while self.procs() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: this run's processes are ending
        signal_all(self.procs(), signal.SIGKILL)
        self.daemon_log.close()
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)


def signal_all(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)  # this run's own processes only (Run.procs)
        except ProcessLookupError:
            pass


def agent_reply_chunks(store: str, needle: str) -> int:
    """How many stored agent message chunks carry `needle` (a prompt's own echo in the log is not one)."""
    count = 0
    for line in store.splitlines():
        if needle in line and '"agent_message_chunk"' in line:
            count += 1
    return count


def inject(run: Run, case: str, session: str, ping: str) -> dict:
    """The fault and the down-time prompt. Returns {fault_end, served_at, ping, note?, cleanup?}."""
    info: dict = {}

    def send_ping(timeout: float):
        sent = run.cli("send", "--no-wait", session, ping, timeout=timeout)
        info["ping"] = {"exit": sent.returncode, "at": time.monotonic(), "out": (sent.stdout + sent.stderr).strip()[:300]}

    before = run.daemon_pids()
    info["daemon_before"] = sorted(before)
    if case in ("daemon-sigterm", "daemon-sigkill"):
        signal_all(before, signal.SIGTERM if case == "daemon-sigterm" else signal.SIGKILL)
        if case == "daemon-sigterm":
            deadline = time.monotonic() + 15
            while before & set(run.procs()) and time.monotonic() < deadline:
                time.sleep(0.2)  # test script: the daemon is shutting down as asked
        info["fault_end"] = time.monotonic()
        send_ping(BOUND[case])
    elif case == "daemon-hung":
        signal_all(before, signal.SIGSTOP)
        info["fault_end"] = time.monotonic()  # the daemon stays stopped: recovery is counted from the stop
        info["note"] = f"daemon {sorted(before)} SIGSTOPped for the whole case, SIGCONT at its end"
        info["cleanup"] = lambda: signal_all(before, signal.SIGCONT)
        # The send may outlive the bound so a late recovery is reported with its real time; late is still a failure.
        send_ping(BOUND[case] + LATE_S)
    elif case == "sleep-wake-sim":
        stopped = set(run.procs())
        signal_all(stopped, signal.SIGSTOP)
        time.sleep(run.args.sleep)  # test script: the simulated sleep
        signal_all(stopped, signal.SIGCONT)
        info["fault_end"] = time.monotonic()
        info["note"] = (f"SIGSTOP/SIGCONT {run.args.sleep:.0f} s simulation of {len(stopped)} processes (daemon, agent "
                        "hosts, agent); no wake notification, no network drop, the clock did not jump")
        send_ping(BOUND[case])
    elif case == "socket-gone":
        path = (run.status() or {}).get("socket")
        if not path or not os.path.exists(path):
            return {"not_run": f"the daemon's socket file was not found ({path})"}
        away = path + ".chaos-away"
        os.rename(path, away)
        sender = threading.Thread(target=send_ping, args=(20 + BOUND[case],), daemon=True)
        sender.start()
        time.sleep(20)  # test script: the socket stays gone this long
        if os.path.exists(path):
            info["note"] = "a new socket was made at the path while the old one was away"
            os.remove(away)
        else:
            os.rename(away, path)
        info["fault_end"] = time.monotonic()
        sender.join(BOUND[case] + 5)
    elif case == "update-swap":
        run.generation += 1
        staged = run.binary + f".staged-{run.generation}"
        shutil.copy2(run.binary, staged)
        with open(staged, "ab") as handle:  # a new version's bytes: the same program with a trailer, so a new file
            handle.write(f"\nagent-conn-chaos generation {run.generation}\n".encode())
        os.rename(staged, run.binary)  # the swap: the path never goes missing, the running daemon's file is gone
        info["new_inode"] = os.stat(run.binary).st_ino
        info["stops_before"] = len(run.stops())
        # Nothing more: the daemon sees its own file replaced and hands over to a daemon of the new file by itself.
        info["fault_end"] = time.monotonic()
        send_ping(BOUND[case])
    else:
        raise SystemExit(f"conn-chaos-linux: unknown case {case}")
    return info


def run_case(run: Run, case: str) -> dict:
    tag = re.sub(r"[^a-z]", "", case)[:10] + uuid.uuid4().hex[:4]
    nonce = uuid.uuid4().hex[:10]
    ping = f"chaos-ping: {nonce}"
    result: dict = {"case": case, "bound_s": BOUND[case], "failures": []}
    made = run.cli("new", "--json", "-d", "-m", HARNESS, f"chaos {case}", timeout=120)
    try:
        session = json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        result["failures"].append(f"harness: could not open a chat on the test agent: {(made.stdout + made.stderr).strip()[:300]}")
        return result
    result["session"] = session
    sent = run.cli("send", "--no-wait", session, f"chaos-stream: {tag} {COUNT} {RATE}")
    if sent.returncode != 0:
        result["failures"].append(f"harness: stream send: {(sent.stdout + sent.stderr).strip()[:300]}")
        return result
    time.sleep(FAULT_AT_S)  # test script: the turn streams before the fault
    if not any(str(e.get("text", "")).startswith(f"chaos-stream: {tag} ") for e in run.agent_entries()):
        result["failures"].append("harness: the stream's turn had not started when the fault was due")
        return result
    fault_start = time.monotonic()
    info = inject(run, case, session, ping)
    cleanup = info.pop("cleanup", None)
    if info.get("not_run"):
        result.update(status="not-run", not_run=info["not_run"])
        return result
    fault_end = info.pop("fault_end")
    ping_sent = info.pop("ping", None) or {"exit": None, "at": None, "out": "(the send had not returned)"}
    result.update(info)
    result["fault_s"] = round(fault_end - fault_start, 1)
    # Served again: the down-time send was taken (exit 0) and a daemon answers status. Counted from the fault's end.
    served = None
    if ping_sent["exit"] == 0:
        deadline = max(fault_end + BOUND[case], ping_sent["at"]) + 5
        while time.monotonic() < deadline:
            status = run.status(timeout=5)
            if status:
                served = max(time.monotonic(), ping_sent["at"])
                result["daemon_after"] = status.get("pid")
                break
            time.sleep(0.5)  # test script: waiting for a daemon that answers
    result["recovery_s"] = None if served is None else round(max(served - fault_end, 0.0), 1)
    if served is None or served - fault_end > BOUND[case]:
        result["failures"].append(f"no client served within {BOUND[case]} s (served after {result['recovery_s']}); "
                                  f"down-time send exit {ping_sent['exit']}: {ping_sent['out']}")
    # Then the turn and the down-time prompt run to their ends.
    deadline = time.monotonic() + COUNT / RATE + BOUND[case] + 30
    while time.monotonic() < deadline:
        entries = run.agent_entries()
        ended = any(e.get("tag") == tag and "end" in e for e in entries)
        if ended and agent_reply_chunks(run.store_text(session), f"pong {nonce}"):
            break
        time.sleep(1)  # test script: waiting for the turn and the down-time prompt to finish
    if cleanup:
        cleanup()
    time.sleep(2)  # test script: the store's last write
    entries = run.agent_entries()
    streams = [e for e in entries if str(e.get("text", "")).startswith(f"chaos-stream: {tag} ")]
    pings = [e for e in entries if e.get("text") == ping]
    ends = [e for e in entries if e.get("tag") == tag and "end" in e]
    result["deliveries"] = {"stream": len(streams), "ping": len(pings)}
    if len(streams) != 1:
        result["failures"].append(f"stream prompt given to the agent {len(streams)} times (want 1)")
    if len(pings) != 1:
        result["failures"].append(f"down-time prompt given to the agent {len(pings)} times (want 1)")
    result["agent_words"] = ends[-1]["sent"] if ends else None
    if not ends or ends[-1]["end"] != "end_turn" or ends[-1]["sent"] != COUNT:
        result["failures"].append(f"the agent's turn did not run to its end ({ends[-1] if ends else 'no end'})")
    store = run.store_text(session)
    replies = "\n".join(line for line in store.splitlines() if '"agent_message_chunk"' in line)
    gap = whole(words_of(replies, tag), COUNT)
    if gap:
        result["failures"].append(f"store reply not whole: {gap}")
    pongs = agent_reply_chunks(store, f"pong {nonce}")
    if pongs != 1:
        result["failures"].append(f"the down-time prompt's answer is in the store {pongs} times (want 1)")
    if case == "update-swap":
        deadline = fault_end + BOUND[case]
        while run.daemon_pids() & set(result["daemon_before"]) and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the old daemon is handing over
        stops = run.stops()[result.pop("stops_before"):]
        result["stops"] = [stop.get("cause") for stop in stops]
        died = [stop for stop in stops if (stop.get("cause") or {}).get("kind") == "died"]
        if died:  # the swap is a hand-over; a daemon that died in it (and was started again by a client) is a fault
            result["failures"].append(f"a daemon died during the swap's hand-over: {died[0].get('cause')}")
        running = sorted(run.daemon_pids())
        exes = {}
        for pid in running:
            try:
                exes[pid] = os.stat(f"/proc/{pid}/exe").st_ino
            except OSError:
                exes[pid] = None
        result["daemon_exe_inodes"] = exes
        if not running or any(inode != result["new_inode"] for inode in exes.values()):
            result["failures"].append(f"the daemon after the swap does not run the new file (inode {result['new_inode']}): {exes}")
        if set(running) & set(result.get("daemon_before", [])):
            result["failures"].append("the old daemon is still running after the swap")
    daemons = run.daemon_pids()
    if len(daemons) != 1:
        result["failures"].append(f"{len(daemons)} daemons on this home after the case (want 1): {sorted(daemons)}")
    return result


def verdict(result: dict) -> str:
    if result.get("status") == "not-run":
        return "not-run"
    return "fail" if result["failures"] else "pass"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--acpmux", required=True, help="the acpmux binary to test (copied into the run's folder)")
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--sleep", type=float, default=35)
    parser.add_argument("--tmp", default="/tmp", help="where the run's folder is made (short: socket path length)")
    parser.add_argument("--keep", action="store_true", help="keep the run's folder (daemon log, store)")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    if not sys.platform.startswith("linux"):
        raise SystemExit("conn-chaos-linux: Linux only (it reads /proc); on a Mac run suite.py through cmux-ci")
    cases = [c for c in args.cases.split(",") if c]
    for case in cases:
        if case not in CASES:
            raise SystemExit(f"conn-chaos-linux: unknown case {case} (known: {', '.join(CASES)})")
    run = Run(args)
    version = run.cli("--version").stdout.strip()
    print(f"AGENT-CONN-CHAOS-LINUX acpmux={version!r} platform={sys.platform} app=none page=not-judged", flush=True)
    results = []
    try:
        for case in cases:
            log(f"case {case}")
            try:
                result = run_case(run, case)
            except Exception as error:  # a case the harness could not drive judged nothing: a failure, said as one
                result = {"case": case, "bound_s": BOUND[case], "failures": [f"harness: {error!r}"[:400]]}
            result["verdict"] = verdict(result)
            results.append(result)
            print(f"AGENT-CONN-CHAOS-LINUX case={case} verdict={result['verdict'].upper()} recovery_s={result.get('recovery_s')} "
                  f"bound_s={result.get('bound_s')} deliveries={json.dumps(result.get('deliveries'))} "
                  f"agent_words={result.get('agent_words')} failures={json.dumps(result['failures'] or result.get('not_run') or [])}",
                  flush=True)
            if not run.status(timeout=10):  # a case that left no daemon: the next case gets one, and says so
                log("no daemon answers after the case; the next client command starts one")
    finally:
        run.close()
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"acpmux": version, "results": results}, handle, indent=1, default=str)
    return 1 if not results or any(r["verdict"] != "pass" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
