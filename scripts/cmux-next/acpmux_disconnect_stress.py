#!/usr/bin/env python3
"""Disconnect and reconnect stress on a real acpmux daemon, counting lost and duplicated messages.

The lane gui-coord-disconnect wants "zero lost messages under repeated disconnect and reconnect under
load". This runs a built acpmux daemon (its own HOME, ACPMUX_HOME and socket; nothing touches this
host's daemon) with stand-in agents (`cmux-tui/crates/acpmux/tests/fake_agent.py`, behind a wrapper
that logs every prompt it is given) and a fake mesh hub on loopback (`meshRelay` in config.json, the
`/v1/mesh` routes `mesh_http.rs` calls). It mirrors `acpmux_429_storm.py`: a clean environment, one
daemon log per daemon, and a tally read back from the run's own files (`--recount`).

Load, for `--duration` seconds:

- hub path: the fake hub queues uniquely numbered prompts (`HUB-<n>`, message id `hub-<n>`) for the
  receiver sessions `recv-<k>`, as a sender on another machine would; the daemon's relay leases them
  from its inbox, delivers each (prompt id = message id, `resend`), and acks. A lease that ends unacked
  brings the message back (attempt + 1), as the platform hub does;
- direct path: `acpmux send recv-<k> --no-wait --no-steer --prompt-id direct-<n> "DIRECT-<n> ..."`,
  retried with the same prompt id until the daemon takes it (the daemon runs a prompt id once);
- some `slow` prompts (unnumbered) keep the receivers busy, so numbered ones queue behind turns;
- one attached client per receiver (`acpmux session tail recv-<k> -f`), as the app's chat pane.

Disconnects, on a randomized schedule (`--seed`, gaps `--gap-min`..`--gap-max` seconds):

- refuse: the hub answers every call 401 `mesh.unauthorized` or 403 `mesh.forbidden` for a while
  (the relay pauses and retries every `refused_retry`, cmux#47240);
- outage: the hub drops every connection, the waiting inbox polls too, with no answer;
- ack-drop: the hub drops the connection of acks (half after applying the ack, half before), so
  messages it already delivered come back on a new lease;
- detach: SIGKILL one attached client and attach a new one;
- send-kill: for a while, direct sends are SIGKILLed mid-call (their socket dropped) and sent again
  with the same prompt id;
- take-over: a new `acpmux daemon run --take-over` takes the home from the running daemon (its
  agents keep running) — the systemd unit's restart path.

An attached client that ends on its own (a take-over drops its connection) is attached again, as the
app's chat pane reconnects, and counted (`clients_ended`).

Then it lifts every fault, waits for the messages to arrive (`--settle`), and counts per message id
from the agents' own prompt log: delivered exactly once, lost (never given to an agent), duplicated
(given in more than one prompt). One summary line, `result.json` and the evidence around each lost or
duplicated message go to `--out`.

    scripts/cmux-next/acpmux_disconnect_stress.py --acpmux PATH --out DIR              # short, ~2 min
    scripts/cmux-next/acpmux_disconnect_stress.py --acpmux PATH --out DIR --duration 7200
    scripts/cmux-next/acpmux_disconnect_stress.py --recount DIR

Exit: 0 clean; 1 a message was lost; 3 none lost but some duplicated; 4 the harness could not run
(no daemon, no session) or a direct send never got through.

Needs: python3 and a built acpmux. No agent CLI and no login: the agents are the stand-in.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from state_wait import wait_stable  # noqa: E402
FAKE_AGENT = HERE.parent.parent / "cmux-tui" / "crates" / "acpmux" / "tests" / "fake_agent.py"
MARK = re.compile(r"\b(HUB|DIRECT)-(\d+)\b")
LEASE_S = 15.0
# The faults and how often each is picked.
FAULTS = {"refuse": 2, "outage": 2, "ack-drop": 2, "detach": 2, "send-kill": 2, "take-over": 1.5}
TTL_S = 9

# The stand-in agent behind a wrapper that logs each prompt it is given, then passes every line on.
WRAPPER = r'''
import json, os, re, subprocess, sys, time, threading
log = os.environ["STRESS_PROMPT_LOG"]
# Every marker of the whole prompt: a batch of held messages is one long prompt, and a cut text
# would drop the markers past the cut (or cut one mid-number).
MARK = re.compile(r"\b(?:HUB|DIRECT)-\d+\b")
child = subprocess.Popen([sys.executable, os.environ["STRESS_FAKE_AGENT"]], stdin=subprocess.PIPE)
lock = threading.Lock()
for line in sys.stdin.buffer:
    try:
        msg = json.loads(line)
    except ValueError:
        msg = None
    if isinstance(msg, dict) and msg.get("method") == "session/prompt":
        p = msg.get("params") or {}
        text = "\n".join(b.get("text", "") for b in p.get("prompt") or [] if isinstance(b, dict))
        row = {"at": time.time(), "pid": os.getpid(), "rpc": msg.get("id"), "session": p.get("sessionId"),
               "promptId": ((p.get("_meta") or {}).get("acpmux") or {}).get("promptId"),
               "markers": MARK.findall(text), "text": text[:500]}
        with lock, open(log, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    try:
        child.stdin.write(line)
        child.stdin.flush()
    except (BrokenPipeError, OSError):
        break
try:
    child.stdin.close()
except OSError:
    pass
sys.exit(child.wait())
'''


def now() -> float:
    return time.time()


class FakeHub:
    """The mesh hub: an inbox with leases, acks, receipts, and the faults the schedule turns on."""

    def __init__(self, log: Path, rng: random.Random):
        self.log_path = log
        self.rng = rng
        self.cond = threading.Condition()
        self.queue: list[dict] = []          # messages waiting for a lease
        self.leased: dict[str, tuple[dict, float]] = {}
        self.acked: dict[str, dict] = {}     # message id -> the first ack the hub applied
        self.ack_count: dict[str, int] = {}
        self.attempts: dict[str, int] = {}
        self.refuse_until = 0.0
        self.refuse_status = 401
        self.outage_until = 0.0
        self.ack_drop_until = 0.0
        self.leaving_gen = 0
        self.counts = {"heartbeats": 0, "inbox_calls": 0, "refused_calls": 0, "dropped_calls": 0,
                       "acks_dropped_before": 0, "acks_dropped_after": 0, "leases": 0, "lease_expired": 0,
                       "leaving_heartbeats": 0, "posted_by_daemon": 0}
        self.lock = threading.Lock()

    def event(self, **row) -> None:
        row["at"] = now()
        with self.lock, self.log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")

    def enqueue(self, msg: dict) -> None:
        with self.cond:
            self.attempts[msg["messageId"]] = 0
            self.queue.append(msg)
            self.cond.notify_all()
        self.event(ev="queued", id=msg["messageId"], to=msg["to"]["name"])

    def refusing(self) -> bool:
        return now() < self.refuse_until

    def out(self) -> bool:
        return now() < self.outage_until

    def reap(self) -> None:
        """Leases that ended unacked: the message goes back to the queue."""
        with self.cond:
            t = now()
            for mid, (msg, until) in list(self.leased.items()):
                if mid in self.acked:
                    del self.leased[mid]
                elif until <= t:
                    del self.leased[mid]
                    self.queue.insert(0, msg)
                    self.counts["lease_expired"] += 1
                    self.event(ev="lease_expired", id=mid, attempt=self.attempts.get(mid))
            self.cond.notify_all()

    def lease(self, wait: float, max_n: int, gen: int, conn_ok) -> tuple[str, list[dict]]:
        """('ok', messages) | ('refused', []) | ('drop', [])."""
        deadline = now() + wait
        with self.cond:
            while True:
                if self.out():
                    return "drop", []
                if self.refusing():
                    return "refused", []
                if self.queue:
                    take, self.queue = self.queue[:max_n], self.queue[max_n:]
                    out = []
                    for msg in take:
                        mid = msg["messageId"]
                        if mid in self.acked:
                            continue
                        self.attempts[mid] = self.attempts.get(mid, 0) + 1
                        m = dict(msg, attempt=self.attempts[mid])
                        self.leased[mid] = (msg, now() + LEASE_S)
                        self.counts["leases"] += 1
                        out.append(m)
                    if out:
                        self.event(ev="leased", ids=[m["messageId"] for m in out],
                                   attempts=[m["attempt"] for m in out])
                        return "ok", out
                if self.leaving_gen != gen or now() >= deadline or not conn_ok():
                    return "ok", []
                self.cond.wait(min(0.5, max(0.01, deadline - now())))


def make_handler(hub: FakeHub):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _read(self) -> bytes:
            n = int(self.headers.get("content-length") or 0)
            return self.rfile.read(n) if n else b""

        def _json(self, status: int, obj) -> None:
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _drop(self) -> None:
            """The connection ends with no answer, as a network drop or a hub restart does."""
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        def _fault(self) -> bool:
            if hub.out():
                with hub.lock:
                    hub.counts["dropped_calls"] += 1
                self._drop()
                return True
            if hub.refusing():
                with hub.lock:
                    hub.counts["refused_calls"] += 1
                code = "mesh.unauthorized" if hub.refuse_status == 401 else "mesh.forbidden"
                self._json(hub.refuse_status, {"code": code, "message": "refused by the stress hub"})
                return True
            return False

        def _alive(self) -> bool:
            # A waiting poll whose daemon went away (its connection closed) ends.
            try:
                import select
                r, _, _ = select.select([self.connection], [], [], 0)
                if r and not self.connection.recv(1, socket.MSG_PEEK):
                    return False
            except OSError:
                return False
            return True

        def do_GET(self):
            self._read()
            path, _, query = self.path.partition("?")
            q = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv)
            if self._fault():
                return
            if path == "/v1/mesh/inbox":
                with hub.lock:
                    hub.counts["inbox_calls"] += 1
                gen = hub.leaving_gen
                state, msgs = hub.lease(float(q.get("waitSeconds", "25")), int(q.get("max", "50")), gen,
                                        self._alive)
                if state == "drop":
                    with hub.lock:
                        hub.counts["dropped_calls"] += 1
                    self._drop()
                elif state == "refused":
                    self._fault()
                else:
                    self._json(200, {"messages": msgs})
                return
            if path == "/v1/mesh/sessions":
                self._json(200, {"daemons": [], "sessions": []})
                return
            if path == "/v1/mesh/messages":
                self._json(200, {"messages": []})
                return
            m = re.fullmatch(r"/v1/mesh/messages/([^/]+)", path)
            if m:
                mid = m.group(1)
                ack = hub.acked.get(mid)
                if mid not in hub.attempts:
                    self._json(404, {"code": "mesh.not_found"})
                    return
                self._json(200, {"messageId": mid, "state": (ack or {}).get("state", "queued"),
                                 "attempt": hub.attempts.get(mid, 0), "promptId": (ack or {}).get("promptId"),
                                 "createdAt": 1000})
                return
            self._json(404, {"code": "mesh.not_found"})

        def do_POST(self):
            raw = self._read()
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            path = self.path.split("?")[0]
            if self._fault():
                return
            if path == "/v1/mesh/heartbeat":
                with hub.lock:
                    hub.counts["heartbeats"] += 1
                if body.get("leaving"):
                    with hub.cond:
                        hub.leaving_gen += 1
                        hub.counts["leaving_heartbeats"] += 1
                        hub.cond.notify_all()
                    hub.event(ev="leaving_heartbeat")
                self._json(200, {"daemonId": "inst_stress", "ttlSeconds": TTL_S})
                return
            m = re.fullmatch(r"/v1/mesh/messages/([^/]+)/ack", path)
            if m:
                mid = m.group(1)
                drop = now() < hub.ack_drop_until and hub.rng.random() < 0.6
                after = drop and hub.rng.random() < 0.5
                if drop and not after:
                    with hub.lock:
                        hub.counts["acks_dropped_before"] += 1
                    hub.event(ev="ack_dropped_before", id=mid, ack=body)
                    self._drop()
                    return
                with hub.cond:
                    hub.ack_count[mid] = hub.ack_count.get(mid, 0) + 1
                    hub.acked.setdefault(mid, body)
                    hub.leased.pop(mid, None)
                hub.event(ev="acked", id=mid, ack=body)
                if after:
                    with hub.lock:
                        hub.counts["acks_dropped_after"] += 1
                    hub.event(ev="ack_dropped_after", id=mid)
                    self._drop()
                    return
                self._json(200, {})
                return
            if path == "/v1/mesh/messages":
                with hub.lock:
                    hub.counts["posted_by_daemon"] += 1
                hub.event(ev="posted_by_daemon", body=body)
                self._json(404, {"code": "mesh.unknown_recipient"})
                return
            self._json(404, {"code": "mesh.not_found"})

    return Handler


def proc_start(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
        return raw.rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def clean_env(out: Path, state: Path, acpmux: str) -> dict:
    """Nothing of this host's acpmux, agents or session: a private PATH (acpmux, python3, system
    directories), HOME, ACPMUX_HOME and socket, as tests/support/daemon_env.rs gives a test. The
    daemon's state is in STATE, a private temporary folder: the daemon refuses a state directory
    with a group- or world-writable ancestor, which --out (a CI output folder) may have."""
    env = {k: os.environ[k] for k in ("LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "TZ") if k in os.environ}
    shim = out / "bin"
    shim.mkdir(parents=True, exist_ok=True)
    (shim / "acpmux").symlink_to(acpmux)
    (shim / "python3").symlink_to(sys.executable)
    home = state / "home"
    start = proc_start(os.getpid())
    env.update({
        "PATH": f"{shim}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"), "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_RUNTIME_DIR": str(state / "run"), "TMPDIR": str(state / "tmp"),
        "ACPMUX_HOME": str(state / "acpmux-home"), "ACPMUX_SOCKET": str(state / "run" / "acpmux.sock"),
        "ACPMUX_SESSION_CPU_CLASS": "normal", "ACPMUX_SPARE_HARNESS": "0",
        "ACPMUX_TEST_SESSION_TMP_BASE": str(state / "session-tmp"),
        # Debug builds end their daemons and agent hosts when this process exits, even on a SIGKILL.
        "ACPMUX_TEST_OWNER_PID": f"{os.getpid()}:{start}" if start else str(os.getpid()),
        "STRESS_PROMPT_LOG": str(out / "prompts.ndjson"), "STRESS_FAKE_AGENT": str(FAKE_AGENT),
    })
    for d in ("home", "run", "tmp", "acpmux-home", "work", "session-tmp"):
        (state / d).mkdir(parents=True, exist_ok=True)
    os.chmod(state / "run", 0o700)
    os.chmod(state / "acpmux-home", 0o700)
    return env


def run(cmd: list[str], env: dict, timeout: float = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)


class Stress:
    def __init__(self, a: argparse.Namespace, out: Path):
        self.a = a
        self.out = out
        self.rng = random.Random(a.seed)
        self.acpmux = str(Path(a.acpmux).resolve())
        self.state = Path(tempfile.mkdtemp(prefix="acpmux-dstress-"))
        self.env = clean_env(out, self.state, self.acpmux)
        self.hub = FakeHub(out / "hub.ndjson", random.Random(a.seed + 1))
        self.procs: list[subprocess.Popen] = []
        self.daemons: list[subprocess.Popen] = []
        self.tails: dict[int, subprocess.Popen] = {}
        self.attaches: dict[int, int] = {}
        self.sent: list[dict] = []
        self.sent_lock = threading.Lock()
        self.chaos: list[dict] = []
        self.stop_load = threading.Event()
        self.send_kill_until = 0.0
        self.n = 0
        self.n_lock = threading.Lock()
        self.t0 = now()

    def log(self, *x) -> None:
        print(f"[{time.strftime('%H:%M:%S')}] [{now() - self.t0:7.1f}s]", *x, flush=True)

    def next_n(self) -> int:
        with self.n_lock:
            self.n += 1
            return self.n

    def chaos_row(self, kind: str, **kw) -> None:
        row = {"at": now(), "kind": kind, **kw}
        self.chaos.append(row)
        self.log("chaos", kind, json.dumps(kw) if kw else "")

    # The daemon --------------------------------------------------------------------------------

    def start_daemon(self) -> bool:
        i = len(self.daemons)
        r, w = os.pipe()
        log = (self.out / f"daemon-{i}.log").open("w")
        d = subprocess.Popen([self.acpmux, "daemon", "run", "--take-over", "--ready-fd", str(w), "--log", self.a.log],
                             env=self.env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             pass_fds=(w,), start_new_session=True)
        os.close(w)
        self.procs.append(d)
        ready = {"line": ""}

        def read():
            with os.fdopen(r) as f:
                ready["line"] = f.readline()

        t = threading.Thread(target=read, daemon=True)
        t.start()
        t.join(60)
        if not ready["line"].strip():
            self.log(f"daemon {i} (pid {d.pid}) did not report ready; see daemon-{i}.log")
            return False
        self.daemons.append(d)
        self.log(f"daemon {i} pid {d.pid} ready: {ready['line'].strip()}")
        return True

    def take_over(self) -> None:
        old = self.daemons[-1] if self.daemons else None
        t = now()
        ok = self.start_daemon()
        old_exit = None
        if ok and old is not None:
            try:
                old_exit = old.wait(timeout=30)
            except subprocess.TimeoutExpired:
                old_exit = "still running after 30 s"
        self.chaos_row("take-over", ok=ok, old_pid=old.pid if old else None,
                       new_pid=self.daemons[-1].pid if ok else None, old_exit=old_exit,
                       took_s=round(now() - t, 2))

    # Sessions and attached clients ---------------------------------------------------------------

    def new_session(self, k: int) -> bool:
        name = f"recv-{k}"
        p = subprocess.Popen([self.acpmux, "new", "-n", name, "-m", "fake", "--policy", "approve-all", "-d",
                              "--cwd", str(self.state / "work"), "hello"],
                             env=self.env, stdout=(self.out / f"new-{name}.log").open("w"), stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        self.procs.append(p)
        for _ in range(120):
            r = run([self.acpmux, "--json", "session", "info", name], self.env, 20)
            if r.returncode == 0 and r.stdout.strip():
                return True
            time.sleep(0.5)
        return False

    def attach(self, k: int) -> None:
        i = self.attaches.get(k, 0)
        self.attaches[k] = i + 1
        tail = subprocess.Popen([self.acpmux, "session", "tail", f"recv-{k}", "-f"], env=self.env,
                                stdout=(self.out / f"attached-{k}-{i}.ndjson").open("w"),
                                stderr=(self.out / f"attached-{k}-{i}.err").open("w"), stdin=subprocess.DEVNULL,
                                start_new_session=True)
        self.procs.append(tail)
        self.tails[k] = tail

    def reattach_exited(self) -> None:
        """An attached client that ended on its own (its daemon was taken over, or dropped it) is
        attached again, as the app's chat pane reconnects; each such end is counted."""
        for k, t in list(self.tails.items()):
            if t.poll() is not None:
                err = self.out / f"attached-{k}-{self.attaches.get(k, 1) - 1}.err"
                why = err.read_text(errors="replace").strip()[-300:] if err.exists() else ""
                self.chaos_row("client-ended", session=k, exit=t.returncode, why=why)
                self.attach(k)

    # Load ----------------------------------------------------------------------------------------

    def hub_sender(self) -> None:
        gap = 1.0 / max(0.01, self.a.hub_rate)
        nxt = now()
        while not self.stop_load.is_set():
            time.sleep(max(0, nxt - now()))
            n = self.next_n()
            k = self.rng.randrange(self.a.sessions)
            mid = f"hub-{n}"
            msg = {"messageId": mid, "kind": "prompt", "mode": "turn-end", "to": {"name": f"recv-{k}"},
                   "from": {"name": "stress-remote", "host": "stress-remote-host", "daemonId": "inst_remote"},
                   "body": f"HUB-{n} stress message for recv-{k}", "attempt": 1}
            self.hub.enqueue(msg)
            with self.sent_lock:
                self.sent.append({"marker": f"HUB-{n}", "path": "hub", "to": k, "at": now(), "ok": True})
            nxt += gap

    def direct_send(self, n: int, k: int) -> dict:
        marker = f"DIRECT-{n}"
        row = {"marker": marker, "path": "direct", "to": k, "at": now(), "attempts": 0, "killed": 0, "ok": False,
               "errors": []}
        deadline = now() + self.a.send_deadline
        while now() < deadline:
            row["attempts"] += 1
            p = subprocess.Popen([self.acpmux, "--json", "send", f"recv-{k}", "--no-wait", "--no-steer",
                                  "--prompt-id", f"direct-{n}", f"{marker} stress message for recv-{k}"],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
            if now() < self.send_kill_until and self.rng.random() < 0.5:
                time.sleep(self.rng.uniform(0, 0.15))
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGKILL)
                    row["killed"] += 1
                p.communicate()
                continue  # the sender saw no answer: it sends again with the same prompt id
            try:
                o, e = p.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.communicate()
                row["errors"].append("timeout")
                continue
            if p.returncode == 0:
                row["ok"] = True
                row["out"] = o.strip()[-200:]
                break
            row["errors"].append(f"rc={p.returncode} {e.strip()[-200:]}")
            time.sleep(0.5)
        row["errors"] = row["errors"][-5:]
        return row

    def direct_sender(self, j: int) -> None:
        gap = self.a.direct_senders / max(0.01, self.a.direct_rate)
        nxt = now() + j * gap / self.a.direct_senders
        while not self.stop_load.is_set():
            time.sleep(max(0, nxt - now()))
            nxt += gap
            k = self.rng.randrange(self.a.sessions)
            if self.rng.random() < self.a.slow_share:
                # Unnumbered: keeps the receiver in a turn so numbered prompts queue behind it.
                try:
                    run([self.acpmux, "send", f"recv-{k}", "--no-wait", "--no-steer", "slow"], self.env, 60)
                except subprocess.TimeoutExpired:
                    pass
                continue
            row = self.direct_send(self.next_n(), k)
            with self.sent_lock:
                self.sent.append(row)

    # Faults --------------------------------------------------------------------------------------

    def fault(self) -> None:
        kinds = [k for k in FAULTS if k in self.a.faults.split(",")]
        kind = self.rng.choices(kinds, [FAULTS[k] for k in kinds])[0]
        if kind == "refuse":
            d = self.rng.uniform(3, 15)
            self.hub.refuse_status = self.rng.choice([401, 403])
            self.hub.refuse_until = now() + d
            with self.hub.cond:
                self.hub.cond.notify_all()
            self.chaos_row("refuse", status=self.hub.refuse_status, seconds=round(d, 1))
        elif kind == "outage":
            d = self.rng.uniform(2, 12)
            self.hub.outage_until = now() + d
            with self.hub.cond:
                self.hub.cond.notify_all()
            self.chaos_row("outage", seconds=round(d, 1))
        elif kind == "ack-drop":
            d = self.rng.uniform(5, 20)
            self.hub.ack_drop_until = now() + d
            self.chaos_row("ack-drop", seconds=round(d, 1))
        elif kind == "detach":
            k = self.rng.randrange(self.a.sessions)
            old = self.tails.get(k)
            alive = old is not None and old.poll() is None
            if old is not None and alive:
                os.killpg(old.pid, signal.SIGKILL)
                old.wait()
            self.chaos_row("detach", session=k, was_attached=alive)
            self.attach(k)
        elif kind == "send-kill":
            d = self.rng.uniform(5, 20)
            self.send_kill_until = now() + d
            self.chaos_row("send-kill", seconds=round(d, 1))
        elif kind == "take-over":
            self.take_over()

    # The run -------------------------------------------------------------------------------------

    def delivered(self) -> dict[str, list[dict]]:
        out: dict[str, list[dict]] = {}
        path = self.out / "prompts.ndjson"
        if not path.exists():
            return out
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            for m in row_markers(row):
                out.setdefault(m, []).append(row)
        return out

    def go(self) -> int:
        a = self.a
        cfg = {
            "harnesses": {"fake": {"argv": ["python3", str(self.out / "agent-wrapper.py")], "family": "codex"}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
            "meshRelay": {"url": f"http://127.0.0.1:{self.port}", "tokenCommand": [shutil.which("echo") or "/bin/echo",
                                                                                     "stress-token"]},
        }
        (self.out / "agent-wrapper.py").write_text(WRAPPER)
        (self.state / "acpmux-home" / "config.json").write_text(json.dumps(cfg, indent=1))
        version = run([self.acpmux, "--version"], self.env).stdout.strip()
        self.log("acpmux", version, "hub", f"http://127.0.0.1:{self.port}", "seed", a.seed)
        if not self.start_daemon():
            return 4
        for k in range(a.sessions):
            if not self.new_session(k):
                self.log(f"session recv-{k} did not start; see new-recv-{k}.log")
                return 4
            self.attach(k)
        # The relay lists the sessions at its next heartbeat; the hub load starts once it polls.
        deadline = now() + 60
        while now() < deadline and self.hub.counts["inbox_calls"] == 0:
            time.sleep(0.5)
        self.log(f"{a.sessions} sessions up, relay polling: {self.hub.counts['inbox_calls'] > 0}")

        reaper_stop = threading.Event()

        def reaper():
            while not reaper_stop.wait(0.5):
                self.hub.reap()

        threading.Thread(target=reaper, daemon=True).start()
        load = [threading.Thread(target=self.hub_sender)]
        load += [threading.Thread(target=self.direct_sender, args=(j,)) for j in range(a.direct_senders)]
        self.load_t0 = now()
        for t in load:
            t.start()
        end = self.load_t0 + a.duration
        nxt = self.load_t0 + self.rng.uniform(a.gap_min, a.gap_max)
        last_report = now()
        while now() < end:
            time.sleep(max(0, min(nxt, end, now() + 1) - now()))
            self.reattach_exited()
            if now() >= end:
                break
            if now() < nxt:
                continue
            self.fault()
            nxt = now() + self.rng.uniform(a.gap_min, a.gap_max)
            if now() - last_report > 300:
                last_report = now()
                got = self.delivered()
                self.log(f"progress: {len(self.sent)} sent, {len(got)} delivered so far, hub {self.hub.counts}")
        self.stop_load.set()
        for t in load:
            t.join(timeout=a.send_deadline + 70)
        # Every fault lifts; then the messages get --settle seconds to arrive.
        self.hub.refuse_until = self.hub.outage_until = self.hub.ack_drop_until = self.send_kill_until = 0
        self.lifted = now()
        markers = {s["marker"] for s in self.sent}
        self.log(f"load done: {len(self.sent)} sent; faults lifted; settling up to {a.settle:.0f} s")
        deadline = self.lifted + a.settle
        while now() < deadline:
            self.reattach_exited()
            got = self.delivered()
            if markers <= set(got) and not self.hub.queue and not self.hub.leased:
                break
            time.sleep(2)
        # Late duplicates: a lease that ends unacked comes back after LEASE_S.
        # sleep-ok: an observation window a lease must outlive for a late duplicate to show up.
        time.sleep(LEASE_S + 5)
        reaper_stop.set()
        self.reattach_exited()

        def tails_now():
            alive = {k: t.poll() is None for k, t in self.tails.items()}
            events = {}
            for k in self.tails:
                files = sorted(self.out.glob(f"attached-{k}-*.ndjson"), key=lambda p: p.stat().st_mtime)
                events[k] = sum(1 for _ in files[-1].open(errors="replace")) if files else 0
            return alive, events

        # The attached clients (some just reattached) until their liveness and event counts hold still.
        settled = wait_stable(tails_now, "the attached clients' event counts", timeout=10, interval=0.25,
                              raise_on_timeout=False)
        tails_alive, tail_events = settled if settled is not None else tails_now()
        meta = {"acpmux": version, "seed": a.seed, "duration_s": a.duration, "sessions": a.sessions,
                "t0": self.t0, "load_t0": self.load_t0, "lifted": self.lifted, "end": now(),
                "hub_counts": self.hub.counts, "hub_left_queued": len(self.hub.queue),
                "hub_left_leased": len(self.hub.leased), "daemons": [d.pid for d in self.daemons],
                "daemon_alive": self.daemons[-1].poll() is None if self.daemons else False,
                "attached_alive": tails_alive, "attached_events_last_client": tail_events}
        (self.out / "sent.json").write_text(json.dumps(self.sent, indent=1))
        (self.out / "chaos.json").write_text(json.dumps(self.chaos, indent=1))
        (self.out / "meta.json").write_text(json.dumps(meta, indent=1))
        self.collect_logs()
        return verdict(tally(self.out), self.out)

    def cleanup(self) -> None:
        try:
            run([self.acpmux, "daemon", "shutdown"], self.env, 30)
        except Exception:  # noqa: BLE001
            pass
        # Agent hosts outlive a daemon on purpose: this run's alone, by the ACPMUX_HOME only it uses.
        mine = f"ACPMUX_HOME={self.state / 'acpmux-home'}".encode()
        for pid_dir in Path("/proc").iterdir():
            if not pid_dir.name.isdigit() or int(pid_dir.name) == os.getpid():
                continue
            try:
                if mine in (pid_dir / "environ").read_bytes().split(b"\0"):
                    os.kill(int(pid_dir.name), signal.SIGTERM)
            except (OSError, ValueError):
                pass
        for p in reversed(self.procs):
            if p.poll() is None:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        for p in self.procs:
            try:
                p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        self.collect_logs()
        shutil.rmtree(self.state, ignore_errors=True)

    def collect_logs(self) -> None:
        """The daemon's own logs come along; the rest of the state folder (this run's alone) goes."""
        logs = self.out / "acpmux-home-logs"
        for i, f in enumerate(sorted((self.state / "acpmux-home").glob("**/*.log"))):
            logs.mkdir(exist_ok=True)
            try:
                shutil.copy2(f, logs / f"{i}-{f.name}")
            except OSError:
                pass


def grep_logs(out: Path, needle: str, limit: int = 12) -> list[str]:
    rows = []
    for f in sorted(out.glob("daemon-*.log")) + sorted((out / "acpmux-home-logs").glob("*.log")):
        try:
            for line in f.read_text(errors="replace").splitlines():
                if needle in line:
                    rows.append(f"{f.name}: {line[:400]}")
        except OSError:
            pass
    return rows[-limit:]


def row_markers(row: dict) -> set[str]:
    """The markers one logged prompt gave its agent: the wrapper's full list, else (an older log) its text."""
    if "markers" in row:
        return set(row["markers"])
    return {m.group(0) for m in MARK.finditer(row.get("text", ""))}


def tally(out: Path) -> dict:
    """The counts, from the run's files alone (`--recount DIR` gives the same result again)."""
    meta = json.loads((out / "meta.json").read_text())
    sent = json.loads((out / "sent.json").read_text())
    chaos = json.loads((out / "chaos.json").read_text())
    got: dict[str, list[dict]] = {}
    for line in (out / "prompts.ndjson").read_text(errors="replace").splitlines() if (out / "prompts.ndjson").exists() else []:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        for m in row_markers(row):
            got.setdefault(m, []).append(row)
    hub_rows = [json.loads(x) for x in (out / "hub.ndjson").read_text().splitlines() if x.strip()] \
        if (out / "hub.ndjson").exists() else []
    by_id: dict[str, list[dict]] = {}
    for r in hub_rows:
        for mid in ([r["id"]] if "id" in r else r.get("ids", [])):
            by_id.setdefault(mid, []).append(r)

    def near(at: float) -> list[dict]:
        return [c for c in chaos if abs(c["at"] - at) < 60]

    res: dict = {"sent": 0, "delivered_once": 0, "lost": 0, "duplicated": 0, "unsent": 0, "paths": {}}
    lost, dups, unsent = [], [], []
    for s in sent:
        p = res["paths"].setdefault(s["path"], {"sent": 0, "delivered_once": 0, "lost": 0, "duplicated": 0,
                                                "unsent": 0})
        if not s.get("ok"):
            # The daemon never took it (every attempt failed): not a lost message, a failed send.
            p["unsent"] += 1
            res["unsent"] += 1
            unsent.append(s)
            continue
        p["sent"] += 1
        res["sent"] += 1
        n = len(got.get(s["marker"], []))
        if n == 1:
            p["delivered_once"] += 1
            res["delivered_once"] += 1
        elif n == 0:
            p["lost"] += 1
            res["lost"] += 1
            mid = s["marker"].lower()
            lost.append({"marker": s["marker"], "sent_at": s["at"], "to": s["to"], "send": s,
                         "hub": by_id.get(mid, [])[-10:], "daemon_log": grep_logs(out, mid),
                         "faults_within_60s": near(s["at"])})
        else:
            p["duplicated"] += 1
            res["duplicated"] += 1
            mid = s["marker"].lower()
            dups.append({"marker": s["marker"], "sent_at": s["at"], "to": s["to"], "send": s,
                         "given": got[s["marker"]], "hub": by_id.get(mid, [])[-10:],
                         "daemon_log": grep_logs(out, mid),
                         "faults_within_60s": near(s["at"])})
    kinds: dict[str, int] = {}
    for c in chaos:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    res.update({
        "faults": {k: v for k, v in kinds.items() if k != "client-ended"},
        "attached_clients_ended_on_their_own": kinds.get("client-ended", 0), "take_overs_failed": sum(1 for c in chaos if c["kind"] == "take-over" and not c.get("ok")),
        "direct_sends_killed": sum(s.get("killed", 0) for s in sent),
        "direct_send_attempts": sum(s.get("attempts", 0) for s in sent if s["path"] == "direct"),
        "hub": meta["hub_counts"], "hub_left_queued": meta["hub_left_queued"],
        "hub_left_leased": meta["hub_left_leased"], "daemons": len(meta["daemons"]),
        "daemon_alive": meta["daemon_alive"], "attached_alive": meta["attached_alive"],
        "attached_events_last_client": meta["attached_events_last_client"],
        "acpmux": meta["acpmux"], "seed": meta["seed"], "duration_s": meta["duration_s"],
        "wall_s": round(meta["end"] - meta["t0"], 1), "settle_s": round(meta["end"] - meta["lifted"], 1),
    })
    (out / "result.json").write_text(json.dumps(res, indent=2))
    (out / "evidence.json").write_text(json.dumps({"lost": lost, "duplicated": dups, "unsent": unsent}, indent=1))
    res["_lost"], res["_dups"], res["_unsent"] = lost, dups, unsent
    return res


def verdict(res: dict, out: Path) -> int:
    paths = " ".join(f"{k}:{v['sent']}/{v['delivered_once']}/{v['lost']}/{v['duplicated']}"
                     for k, v in sorted(res["paths"].items()))
    faults = ",".join(f"{k}={v}" for k, v in sorted(res["faults"].items()))
    line = (f"disconnect-stress: sent={res['sent']} delivered_once={res['delivered_once']} lost={res['lost']} "
            f"duplicated={res['duplicated']} unsent={res['unsent']} [{paths} sent/once/lost/dup] "
            f"faults[{faults}] daemons={res['daemons']} take_overs_failed={res['take_overs_failed']} "
            f"sends_killed={res['direct_sends_killed']} clients_ended={res['attached_clients_ended_on_their_own']} attached_alive={sum(res['attached_alive'].values())}/"
            f"{len(res['attached_alive'])} daemon_alive={res['daemon_alive']} duration={res['duration_s']}s "
            f"wall={res['wall_s']}s seed={res['seed']}")
    print(json.dumps({k: v for k, v in res.items() if not k.startswith("_")}, indent=1))
    for kind, rows in (("LOST", res["_lost"]), ("DUPLICATED", res["_dups"]), ("UNSENT", res["_unsent"])):
        for r in rows[:15]:
            print(f"{kind} {json.dumps(r)[:4000]}")
        if len(rows) > 15:
            print(f"{kind}: {len(rows) - 15} more in {out / 'evidence.json'}")
    print(line, flush=True)
    if res["lost"]:
        return 1
    if res["duplicated"]:
        return 3
    if res["unsent"] or res["take_overs_failed"]:
        return 4
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", help="the acpmux binary to run")
    ap.add_argument("--out", help="a new directory for this run's logs and result")
    ap.add_argument("--duration", type=float, default=120, help="seconds of load and faults (long mode: 7200)")
    ap.add_argument("--sessions", type=int, default=3, help="receiver sessions")
    ap.add_argument("--hub-rate", type=float, default=2.0, help="hub-path messages per second")
    ap.add_argument("--direct-rate", type=float, default=2.0, help="direct sends per second, all senders")
    ap.add_argument("--direct-senders", type=int, default=2)
    ap.add_argument("--slow-share", type=float, default=0.1, help="share of direct sends that are unnumbered `slow` turns")
    ap.add_argument("--gap-min", type=float, default=6, help="least seconds between two faults")
    ap.add_argument("--gap-max", type=float, default=18, help="most seconds between two faults")
    ap.add_argument("--send-deadline", type=float, default=180, help="how long one direct send keeps trying")
    ap.add_argument("--settle", type=float, default=300, help="longest wait for delivery after the faults lift")
    ap.add_argument("--faults", default=",".join(FAULTS), help="the faults to inject, comma-separated: " + ", ".join(FAULTS))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--log", default="info", help="the daemon's log filter")
    ap.add_argument("--recount", nargs="+", metavar="RUN_DIR", help="count finished runs again from their files")
    a = ap.parse_args()
    if a.recount:
        code = 0
        for d in a.recount:
            code = max(code, verdict(tally(Path(d)), Path(d)))
        return code
    if not (a.acpmux and a.out):
        ap.error("--acpmux and --out are required for a run")
    if not [k for k in a.faults.split(",") if k in FAULTS] or set(a.faults.split(",")) - set(FAULTS):
        ap.error(f"--faults takes some of {', '.join(FAULTS)}")
    if a.seed is None:
        a.seed = random.randrange(1 << 30)
    os.umask(0o022)  # the daemon refuses a state directory under a group- or world-writable folder
    out = Path(a.out).resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        print(f"acpmux_disconnect_stress: --out {out} exists and is not empty; give a new directory", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)
    if not FAKE_AGENT.exists():
        print(f"acpmux_disconnect_stress: no stand-in agent at {FAKE_AGENT}", file=sys.stderr)
        return 4
    s = Stress(a, out)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(s.hub))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    s.port = server.server_address[1]
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        return s.go()
    finally:
        s.cleanup()
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
