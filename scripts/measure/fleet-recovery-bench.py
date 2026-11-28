#!/usr/bin/env python3
"""Fleet recovery bench: kill a host under N live chats, count the chats that resume on a survivor
with their transcript and a working agent within the budget (RFD 0167 row 4, goal
competitive-fleet-recovery-99; metric `fleet.recovery.resumed_within_30s_pct`).

Leo, 2026-11-24 12:50Z: "if you havent already you guys can also look at chatgpt's rfd 162 and go
even further beyond".

Two real acpmux daemons, each its own home, each a machine:
  host   the machine that dies. N chats on the stand-in agent (`tests/fake_agent.py`), each with
         TURNS finished turns.
  spare  the survivor. It peers the host as a fleet tool writes a lane VM (`vmBoundary`), so it
         keeps a copy of the host's chats (`hub/peer_snapshot/warm.rs` `keeps_copies`), and the
         chats start there (`--machine local`). A copy move's target is this machine or an ssh
         peer (`cli/run/session_move_snapshot.rs`), so the machine that holds the copy is the
         survivor here.

The kill: every process of the host's home (daemon, agent hosts, agents) is frozen with SIGSTOP
at t0, so its sockets go silent as a powered-off machine's do (no FIN, no RST), and killed with
SIGKILL when the run ends. From t0 the spare does what the fleet's death router does
(`acpmux session route` -> `move_from_copy`, cmux#52791): it waits until its link to the host
reads down, then runs `acpmux session move host/CHAT --machine local --from-snapshot` for each
chat, PARALLEL at a time.

A chat counts as resumed at the moment, measured from t0, that all of these hold on the spare:
  - transcript: every user message and every reply the host had journaled before t0 is in the
    moved chat, in order;
  - process: a probe prompt sent to the moved chat is answered by its agent (a live process
    there, started from the moved row).
`resumed_within_budget_pct` is the share resumed within --budget seconds (30).

Runs anywhere acpmux runs, by default with every machine on this computer (loopback
WebSockets). Nothing here touches the caller's own daemon: each home is a fresh directory under
--root, and only processes of those homes are signalled.

  python3 scripts/measure/fleet-recovery-bench.py --bin target/release/acpmux --n 20
  python3 scripts/measure/fleet-recovery-bench.py --bin ~/.local/bin/acpmux --n 100 --json out.json
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[2]
FAKE_AGENT = REPO / "cmux-tui/crates/acpmux/tests/fake_agent.py"
METRIC = "fleet.recovery.resumed_within_30s_pct"


class Rpc:
    """Newline-delimited JSON-RPC over a daemon's unix socket."""

    def __init__(self, path: Path, timeout: float = 30.0):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.s.connect(str(path))
        self.f = self.s.makefile("rwb")
        self.i = 0

    def call(self, method: str, params: dict):
        self.i += 1
        line = json.dumps({"jsonrpc": "2.0", "id": self.i, "method": method, "params": params})
        self.f.write((line + "\n").encode())
        self.f.flush()
        while True:
            raw = self.f.readline()
            if not raw:
                raise EOFError(f"{method}: daemon closed the socket")
            v = json.loads(raw)
            if v.get("id") == self.i:
                if "error" in v:
                    raise RuntimeError(f"{method}: {v['error']}")
                return v["result"]

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class Machine:
    def __init__(self, root: Path, name: str, binary: Path, port: int | None):
        self.name, self.binary, self.port = name, binary, port
        self.home = root / name
        self.home.mkdir(mode=0o700)
        self.sock = self.home / "acpmux.sock"
        self.token = f"bench-{name}-{os.urandom(6).hex()}"
        self.proc: subprocess.Popen | None = None

    def env(self) -> dict:
        e = dict(os.environ)
        e.update(ACPMUX_HOME=str(self.home), ACPMUX_SOCKET=str(self.sock), ACPMUX_PEER_POLICY="0")
        for k in ("ACPMUX_SESSION_ID", "ACPMUX_SESSION_TOKEN_SOCKET"):
            e.pop(k, None)
        return e

    def write_config(self, extra: dict):
        cfg = {
            "harnesses": {"fake": {"argv": [sys.executable, str(FAKE_AGENT)]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        }
        cfg.update(extra)
        path = self.home / "config.json"
        path.write_text(json.dumps(cfg, indent=1))
        path.chmod(0o600)

    def start(self):
        argv = [str(self.binary), "daemon", "run"]
        if self.port:
            argv += ["--listen", f"127.0.0.1:{self.port}", "--token", self.token]
        log = open(self.home / "bench-daemon.log", "wb")
        self.proc = subprocess.Popen(
            argv, env=self.env(), stdout=log, stderr=subprocess.STDOUT, start_new_session=True
        )
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.sock.exists():
                try:
                    Rpc(self.sock, 5).call("_acpmux/sessions", {})
                    return
                except (OSError, RuntimeError, EOFError):
                    pass
            if self.proc.poll() is not None:
                break
            time.sleep(0.2)
        raise SystemExit(f"{self.name}: daemon did not start; see {self.home / 'bench-daemon.log'}")

    def cli(self, *args: str, timeout: float = 120) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.binary), *args], env=self.env(), capture_output=True, text=True, timeout=timeout
        )

    def rpc(self, timeout: float = 30.0) -> Rpc:
        return Rpc(self.sock, timeout)

    def pids(self) -> list[int]:
        """Every process of this home: by its environment, its command line, or descent from the
        daemon. Only processes this bench started carry this home's path."""
        mark = str(self.home).encode()
        found: set[int] = set()
        parents: dict[int, int] = {}
        for d in Path("/proc").iterdir():
            if not d.name.isdigit():
                continue
            pid = int(d.name)
            try:
                stat = (d / "stat").read_text()
                parents[pid] = int(stat.rsplit(")", 1)[1].split()[1])
                if mark in (d / "environ").read_bytes() or mark in (d / "cmdline").read_bytes():
                    found.add(pid)
            except (OSError, ValueError, IndexError):
                continue
        if self.proc:
            found.add(self.proc.pid)
        grew = True
        while grew:
            grew = False
            for pid, ppid in parents.items():
                if ppid in found and pid not in found:
                    found.add(pid)
                    grew = True
        found.discard(os.getpid())
        return sorted(found)

    def signal_all(self, sig: int) -> int:
        n = 0
        for pid in self.pids():
            try:
                os.kill(pid, sig)
                n += 1
            except ProcessLookupError:
                pass
        return n

    def stop(self):
        try:
            self.cli("daemon", "shutdown", "--end-agents", timeout=30)
        except subprocess.TimeoutExpired:
            pass
        self.signal_all(signal.SIGKILL)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def conversation(events: list[dict]) -> list[tuple[str, str]]:
    """The chat as a person reads it: each user message and each reply, in order."""
    out: list[tuple[str, str]] = []
    for e in events:
        kind, msg = e.get("kind"), e.get("msg") or {}
        if kind == "user_message":
            text = msg.get("text")
            if not isinstance(text, str):
                text = "".join(b.get("text", "") for b in (msg.get("prompt") or []) if isinstance(b, dict))
            out.append(("user", text))
        elif kind == "agent_message_chunk":
            upd = (msg.get("params") or {}).get("update") or {}
            text = (upd.get("content") or {}).get("text", "")
            if out and out[-1][0] == "agent":
                out[-1] = ("agent", out[-1][1] + text)
            else:
                out.append(("agent", text))
    return out


def prompt(m: Machine, sid: str, text: str, timeout: float = 120.0) -> dict:
    """One user turn, as a client sends it (`session/prompt`): the reply comes when the turn ends.
    Not `acpmux send`: run from inside an agent session that is an agent's message to the chat
    (an inbox record), not a person's turn."""
    r = m.rpc(timeout)
    try:
        r.call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "fleet-recovery-bench"}})
        return r.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}],
                                         "_meta": {"acpmux": {"promptId": f"bench-{os.urandom(8).hex()}"}}})
    finally:
        r.close()


def all_events(m: Machine, sid: str) -> list[dict]:
    r = m.rpc(60)
    try:
        events, after = [], 0
        while True:
            page = r.call("_acpmux/events", {"sessionId": sid, "afterSeq": after, "limit": 5000})
            events += page["events"]
            if not page.get("hasMore") or not page["events"]:
                return events
            after = max(e["seq"] for e in page["events"])
    finally:
        r.close()


def contains_in_order(whole: list, part: list) -> bool:
    it = iter(whole)
    return all(any(x == y for y in it) for x in part)


def sessions(m: Machine) -> list[dict]:
    r = m.rpc()
    try:
        out = r.call("_acpmux/sessions", {})
    finally:
        r.close()
    return out["sessions"] if isinstance(out, dict) else out


def peer_up(owner: Machine, peer: str) -> bool | None:
    """Whether `owner`'s link to `peer` reads connected (`_acpmux/peers`)."""
    try:
        r = owner.rpc(3)
        try:
            st = r.call("_acpmux/peers", {})
        finally:
            r.close()
    except (OSError, RuntimeError, EOFError, TimeoutError):
        return None
    for p in st.get("peers") or []:
        if p.get("name") == peer:
            return bool(p.get("connected"))
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=shutil.which("acpmux") or "acpmux", help="acpmux binary for every machine")
    ap.add_argument("--n", type=int, default=20, help="chats on the host that dies")
    ap.add_argument("--turns", type=int, default=3, help="finished turns per chat before the kill")
    ap.add_argument("--settle", type=float, default=35.0,
                    help="seconds between the last turn and the kill (one owner read-ahead round is 30 s)")
    ap.add_argument("--budget", type=float, default=30.0)
    ap.add_argument("--parallel", type=int, default=32, help="moves run at once: the executor's concurrency (`session move A B ...` runs its chats one at a time; at 8, N=100 queued past 30 s: 69%%; at 32, 100%%)")
    ap.add_argument("--deadline", type=float, default=180.0, help="give up on a chat this long after t0")
    ap.add_argument("--root", help="directory for the three homes (default: a new private temp dir)")
    ap.add_argument("--keep", action="store_true", help="leave the homes for inspection")
    ap.add_argument("--json", help="write the result here")
    a = ap.parse_args()

    binary = Path(os.path.expanduser(a.bin)).resolve()
    (Path.home() / ".cache").mkdir(parents=True, exist_ok=True)  # a fresh CI runner has none
    root = Path(a.root) if a.root else Path(tempfile.mkdtemp(prefix="fleet-recovery-", dir=Path.home() / ".cache"))
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    host = Machine(root, "host", binary, free_port())
    spare = Machine(root, "spare", binary, None)
    owner = spare
    t_start = time.time()
    # `mode` says what died: two daemons on this one machine (the first baseline), not two VMs.
    result: dict = {"schema": "fleet-recovery-bench.v1", "metric": METRIC, "mode": "local-two-daemons",
                    "host": socket.gethostname().split(".")[0],
                    "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "n": a.n, "turns": a.turns, "budget_s": a.budget, "binary": str(binary), "version": None}
    try:
        result["version"] = subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout.strip()
        host.write_config({})
        host.start()
        tok = (host.home / "run" / "peer.token").read_text().strip()
        spare.write_config({"peers": {"host": {"url": f"ws://127.0.0.1:{host.port}", "token": host.token,
                                               "peerToken": tok, "vmBoundary": True}}})
        spare.start()

        # N chats on the host, TURNS turns each.
        work = root / "work"

        def make(i: int) -> dict:
            cwd = work / f"c{i:03d}"
            cwd.mkdir(parents=True)
            name = f"bench-{i:03d}"
            r = host.cli("run", "-m", "fake", "-n", name, "--cwd", str(cwd), f"turn 0 of chat {i}", timeout=180)
            if r.returncode != 0:
                raise RuntimeError(f"{name}: {r.stderr.strip()[-300:]}")
            sid = next(x["sessionId"] for x in sessions(host) if x["name"] == name)
            for t in range(1, a.turns):
                prompt(host, sid, f"turn {t} of chat {i}", timeout=180)
            return {"i": i, "name": name, "cwd": str(cwd), "id": sid}

        t0 = time.monotonic()
        with cf.ThreadPoolExecutor(16) as ex:
            chats = list(ex.map(make, range(a.n)))
        result["setup_s"] = round(time.monotonic() - t0, 1)
        time.sleep(a.settle)

        # The truth at the kill: what the host journaled.
        for c in chats:
            c["truth"] = conversation(all_events(host, c["id"]))
            c["truth_turns"] = sum(1 for k, _ in c["truth"] if k == "user")
        snap_have = 0
        r = owner.rpc(30)
        try:
            for c in chats:
                try:
                    snap = r.call("_acpmux/peer_snapshot", {"sessionId": f"host/{c['id']}", "limit": 5000})
                    c["copy_records"] = len(snap.get("events") or [])
                except RuntimeError as e:
                    c["copy_records"] = 0
                    c["copy_error"] = str(e)[:200]
                snap_have += 1 if c["copy_records"] else 0
        finally:
            r.close()
        result["copies_at_kill"] = snap_have
        result["truth_turns_min"] = min(c["truth_turns"] for c in chats)
        result["copy_records_min"] = min(c["copy_records"] for c in chats)

        # A survivor whose link to the host was never up holds no copy (a lazily dialed peer,
        # cmux#61550): say so, instead of reading as a 0 s detection.
        result["link_up_at_kill"] = peer_up(owner, "host")

        # Kill: freeze every process of the host's home.
        frozen = host.signal_all(signal.SIGSTOP)
        t_kill = time.monotonic()
        result["frozen_processes"] = frozen

        # Detection: the owner's link to the host reads down.
        detect = None
        while time.monotonic() - t_kill < a.deadline:
            up = peer_up(owner, "host")
            if up is False:
                detect = time.monotonic() - t_kill
                break
            time.sleep(0.05)
        result["detect_s"] = round(detect, 2) if detect is not None else None

        def ms(t: float) -> int:
            return round(t * 1000)

        def recover(c: dict) -> dict:
            out = {"name": c["name"], "copy_records": c["copy_records"], "truth_turns": c["truth_turns"]}
            # Phases, each from the end of the one before (ms): detect (t0 to the link reading
            # down, shared), queue (waiting for a move slot), choose (the death router's
            # `--dry-run`: read the copy, pick the target), restore (the move itself: bundle,
            # import, start), first_turn (a probe prompt to its reply in the moved journal).
            t = time.monotonic()
            out["queue_ms"] = ms(t - t_kill - (detect or 0))
            r = owner.cli("--json", "session", "move", f"host/{c['id']}", "--machine", "local", "--from-snapshot",
                          "--dry-run", timeout=max(5, a.deadline - (time.monotonic() - t_kill)))
            out["choose_ms"] = ms(time.monotonic() - t)
            if r.returncode != 0:
                out["error"] = f"dry-run: {(r.stderr or r.stdout).strip()[-400:]}"
                return out
            t = time.monotonic()
            r = owner.cli("--json", "session", "move", f"host/{c['id']}", "--machine", "local", "--from-snapshot",
                          timeout=max(5, a.deadline - (time.monotonic() - t_kill)))
            out["restore_ms"] = ms(time.monotonic() - t)
            out["move_s"] = round(time.monotonic() - t_kill, 2)
            if r.returncode != 0:
                # The row's own reason is on stdout (`--json`); stderr only says how many failed.
                why = ""
                try:
                    why = "; ".join(str(x.get("error")) for x in json.loads(r.stdout).get("moves") or []
                                    if x.get("error"))
                except (json.JSONDecodeError, AttributeError):
                    pass
                out["error"] = f"move: {(why or r.stderr or r.stdout).strip()[-400:]}"
                return out
            try:
                moved = json.loads(r.stdout)
            except json.JSONDecodeError:
                moved = {}
            text = r.stdout
            new = None
            for row in moved.get("moves") or []:
                new = row.get("targetSessionId") or new
            if not new:
                out["error"] = f"move: no target session in {text[-300:]}"
                return out
            out["new"] = new
            probe = f"probe after kill of chat {c['i']}"
            t = time.monotonic()
            try:
                prompt(spare, new, probe, timeout=max(5, a.deadline - (time.monotonic() - t_kill)))
            except (OSError, RuntimeError, EOFError) as e:
                out["error"] = f"probe: {e} (move said: {text[-300:]})"
                return out
            # The probe's reply is in the moved chat's journal.
            while time.monotonic() - t_kill < a.deadline:
                conv = conversation(all_events(spare, new))
                if any(k == "agent" and probe in v for k, v in conv):
                    out["first_turn_ms"] = ms(time.monotonic() - t)
                    out["resumed_s"] = round(time.monotonic() - t_kill, 2)
                    out["resumed_ms"] = ms(time.monotonic() - t_kill)
                    out["transcript_intact"] = contains_in_order(conv, c["truth"])
                    if not out["transcript_intact"]:
                        out["transcript_missing"] = [x for x in c["truth"] if x not in conv][:4]
                    return out
                time.sleep(0.05)
            out["error"] = "probe: no reply before the deadline"
            return out

        with cf.ThreadPoolExecutor(a.parallel) as ex:
            rows = list(ex.map(recover, chats))
        ok = [x for x in rows if x.get("resumed_s") is not None and x.get("transcript_intact")
              and x["resumed_s"] <= a.budget]
        times = sorted(x["resumed_s"] for x in rows if x.get("resumed_s") is not None)
        result.update(
            resumed_within_budget=len(ok),
            resumed_within_30s_pct=round(100.0 * len(ok) / a.n, 1),
            resumed_any=len(times),
            transcript_intact=sum(1 for x in rows if x.get("transcript_intact")),
            p50_s=times[len(times) // 2] if times else None,
            p95_s=times[min(len(times) - 1, int(len(times) * 0.95))] if times else None,
            max_s=times[-1] if times else None,
            mean_s=round(statistics.mean(times), 2) if times else None,
            failures=[x for x in rows if x not in ok][:20],
            failure_count=a.n - len(ok),
            wall_s=round(time.time() - t_start, 1),
        )

        def pct(xs: list, q: float):
            xs = sorted(xs)
            return xs[min(len(xs) - 1, int(len(xs) * q))] if xs else None

        # One report: the pass rate next to resume p50/p95/max in ms, and where the time goes.
        resumed = [x["resumed_ms"] for x in rows if "resumed_ms" in x]
        phases = {"detect": [ms(detect)] * len(rows) if detect is not None else []}
        for k in ("queue", "choose", "restore", "first_turn"):
            phases[k] = [x[f"{k}_ms"] for x in rows if f"{k}_ms" in x]
        result["resume_ms"] = {"p50": pct(resumed, 0.5), "p95": pct(resumed, 0.95),
                               "max": max(resumed) if resumed else None}
        result["phase_ms"] = {k: {"p50": pct(v, 0.5), "p95": pct(v, 0.95), "max": max(v) if v else None}
                              for k, v in phases.items()}
        split = "  ".join(f"{k} {v['p50']}/{v['p95']}" for k, v in result["phase_ms"].items())
        result["report"] = (f"N={a.n}: {result['resumed_within_30s_pct']}% resumed within {a.budget:g} s; "
                            f"resume p50 {result['resume_ms']['p50']} ms, p95 {result['resume_ms']['p95']} ms, "
                            f"max {result['resume_ms']['max']} ms; phases p50/p95 ms: {split}")
    finally:
        for m in (spare, host):
            try:
                m.stop()
            except Exception as e:  # noqa: BLE001 - clean up the rest regardless
                print(f"stop {m.name}: {e}", file=sys.stderr)
        if not a.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            result["root"] = str(root)
    text = json.dumps(result, indent=1)
    print(text)
    if result.get("report"):
        print(result["report"], file=sys.stderr)
    if a.json:
        Path(a.json).write_text(text + "\n")
    return 0 if result.get("resumed_within_30s_pct", 0) >= 99 else 1


if __name__ == "__main__":
    sys.exit(main())
