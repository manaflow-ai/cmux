#!/usr/bin/env python3
"""New-terminal latency on a headless cmux-tui daemon (new-terminal-100x).

Starts one isolated daemon (temp HOME and state), makes one base workspace,
then for --rounds rounds times each way a user makes a terminal:

  new-tab        (Cmd+T / Ctrl+` new surface in a pane)
  split right    (Cmd+D)
  new-workspace  (Cmd+N)

For each it records two numbers, in ms:

  reply  send -> the daemon's reply (what a client waits on before it can
         draw the new tab)
  exec   send -> the terminal's shell process is running (the marker shell
         writes one line to a FIFO the bench holds open, then execs
         `sleep`; so this is the daemon + host + PTY + exec chain and no
         shell rc file)
  first-text  request arrival -> the daemon reads the terminal's first
         printable output (the marker shell's "up"; debug span follow mark
         first_printable_output, so it needs --spans): the keypress-to-first-
         text cost the app waits on, minus the app's own frame

and, per live terminal, the processes and footprint it costs (terminal
processes the daemon started and their RSS, and the daemon's own RSS).
--host-model holder runs every terminal on the install's one holder
(CMUX_TUI_TERMINAL_HOST_MODEL=holder) instead of a host process each; its
first-text comes from the same mark. Prints one CREATE line per op and
metric, and writes JSON with every sample to --out. --max-p50-ms makes it a gate: exit 1 when any
`exec` p50 is above it (the failing-first perf test of new-terminal-100x).

  bench-terminal-create.py --bin target/release/cmux-tui --rounds 40
"""

import argparse
import json
import os
import platform
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class Conn:
    def __init__(self, path, timeout=60):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("control socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "ok" in msg:
                return msg


def must(resp, what):
    if not resp.get("ok"):
        raise RuntimeError(f"{what} failed: {resp.get('error')!r} {resp.get('error_code', '')}")
    return resp.get("data") or {}


def tab_ids(tab):
    if isinstance(tab, dict):
        return {tab.get("id"), tab.get("surface")}
    return {tab}


def pane_of(conn, surface):
    tree = must(conn.call("list-workspaces"), "list-workspaces")
    for ws in tree.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    if surface in tab_ids(tab):
                        return pane["id"], ws["id"]
    raise RuntimeError(f"surface {surface} is in no pane")


def summary(samples):
    if not samples:
        return {"n": 0}
    s = sorted(samples)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]  # noqa: E731
    return {"n": len(s), "p50": round(q(0.50), 3), "p95": round(q(0.95), 3), "max": round(s[-1], 3)}


class Marker:
    """A FIFO the marker shell writes one line to when it starts; a reader
    thread stamps each line as it arrives, so the stamp is not delayed by the
    control request still waiting for its reply."""

    def __init__(self, root):
        self.path = os.path.join(root, "marker.fifo")
        os.mkfifo(self.path)
        # O_RDWR: a writer never blocks and the read end never sees EOF.
        self.fd = os.open(self.path, os.O_RDWR)
        self.stamps = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            now = time.perf_counter()
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                _, buf = buf.split(b"\n", 1)
                self.stamps.put(now)

    def drain(self):
        while True:
            try:
                self.stamps.get_nowait()
            except queue.Empty:
                return

    def wait(self, t0, timeout=20.0):
        try:
            return (self.stamps.get(timeout=timeout) - t0) * 1000.0
        except queue.Empty:
            raise TimeoutError("marker shell never started") from None


def disk_load(root, writers, stop):
    """Background disk churn like the agents and daemons on a busy Mac: each
    writer appends 256 KiB and flushes it (F_FULLFSYNC on macOS) in a loop."""
    import fcntl
    full = getattr(fcntl, "F_FULLFSYNC", None)
    chunk = os.urandom(256 * 1024)

    def run(k):
        path = os.path.join(root, f"load-{k}.bin")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        written = 0
        try:
            while not stop.is_set():
                os.write(fd, chunk)
                written += len(chunk)
                if full is not None:
                    fcntl.fcntl(fd, full)
                else:
                    os.fsync(fd)
                if written > 64 * 1024 * 1024:
                    os.ftruncate(fd, 0)
                    os.lseek(fd, 0, os.SEEK_SET)
                    written = 0
        finally:
            os.close(fd)

    threads = [threading.Thread(target=run, args=(k,), daemon=True) for k in range(writers)]
    for t in threads:
        t.start()
    return threads


def host_pids(daemon_pid):
    """The terminal processes the daemon started: a host per terminal, or the holder."""
    out = subprocess.run(["pgrep", "-P", str(daemon_pid), "-f", "__terminal-host|__holder|cmux-holder"],
                         capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def rss_kb(pids):
    if not pids:
        return 0
    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return sum(int(x) for x in out.split())


def first_text_marks(path):
    """terminal hex -> ms from its request's arrival to its first printable output."""
    out = {}
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return out
    for line in lines:
        try:
            t = json.loads(line)
        except ValueError:
            continue
        if not str(t.get("label", "")).endswith(".follow") or not t.get("terminal"):
            continue
        for m in t.get("marks") or []:
            if m[0] == "first_printable_output":
                out[t["terminal"]] = m[1] / 1000.0
    return out


def print_marks(label, path):
    """p50/p95 of each debug-span mark (ms from the request's arrival), per trace label."""
    marks = {}
    for line in open(path):
        try:
            t = json.loads(line)
        except ValueError:
            continue
        for m in t.get("marks") or []:
            if isinstance(m, list) and len(m) >= 2 and isinstance(m[1], (int, float)):
                marks.setdefault((t.get("label"), m[0]), []).append(m[1] / 1000.0)
    for (tl, name), v in sorted(marks.items(), key=lambda kv: (str(kv[0][0]), summary(kv[1]).get("p50", 0))):
        sm = summary(v)
        print(f"CREATE-MARK {label} trace=\"{tl}\" mark=\"{name}\" n={sm['n']} p50={sm['p50']} p95={sm['p95']}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--rounds", type=int, default=40)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--root-dir", default=None)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default=None)
    ap.add_argument("--live", type=int, default=20, help="terminals kept open for the per-terminal cost")
    ap.add_argument("--max-p50-ms", type=float, default=None,
                    help="gate: exit 1 when any exec p50 is above this many ms")
    ap.add_argument("--spans", action="store_true", help="set CMUX_TUI_DEBUG_SPANS and keep the file")
    ap.add_argument("--gate-metric", default=" first-text",
                    help="the metric --max-p50-ms gates (suffix of the op name)")
    ap.add_argument("--login", action="store_true",
                    help="as the app: a frontend client (terminal-frontend-shell-integration-v1) and the "
                         "account's HOME, so each shell starts through login(1)")
    ap.add_argument("--disk-load", type=int, default=0,
                    help="background writers that write and F_FULLFSYNC in a loop (a busy Mac's disk)")
    ap.add_argument("--host-model", choices=("hosts", "holder"), default="hosts",
                    help="hosts: a terminal host process per terminal; holder: the install's one holder")
    args = ap.parse_args()

    root = tempfile.mkdtemp(prefix="tc-", dir=args.root_dir)
    stop_load = threading.Event()
    sock = os.path.join(root, "s.sock")
    home = os.path.join(root, "home")
    state = os.path.join(root, "state")
    os.makedirs(home)
    os.makedirs(state)
    marker = Marker(root)
    shell = os.path.join(root, "marker-shell")
    with open(shell, "w") as f:
        # "up" on the terminal is its first text; the FIFO line stamps exec.
        f.write(f"#!/bin/sh\necho up\necho up > '{marker.path}'\nexec sleep 3600\n")
    os.chmod(shell, 0o755)
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("CMUX_"):
            del env[k]
    env.update(
        HOME=os.environ["HOME"] if args.login else home,
        XDG_CONFIG_HOME=os.path.join(home, ".config"),
        XDG_STATE_HOME=os.path.join(home, ".local/state"),
        XDG_DATA_HOME=os.path.join(home, ".local/share"),
        XDG_CACHE_HOME=os.path.join(home, ".cache"),
        CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
        SHELL=shell,
    )
    if args.host_model == "holder":
        env["CMUX_TUI_TERMINAL_HOST_MODEL"] = "holder"
    spans_path = os.path.join(root, "spans.ndjson")
    if args.spans:
        env["CMUX_TUI_DEBUG_SPANS"] = spans_path
    log = open(os.path.join(root, "daemon.log"), "a")
    daemon = subprocess.Popen(
        [args.bin, "--headless", "--session", f"tc{os.getpid()}", "--socket", sock, "--state", state],
        stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True,
    )
    result = {"label": args.label, "platform": platform.platform(), "rounds": args.rounds,
              "host_model": args.host_model, "ops": {}}
    failed = False
    try:
        deadline = time.time() + 30
        while True:
            if daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {daemon.returncode}")
            if os.path.exists(sock):
                try:
                    c = Conn(sock)
                    result["identify"] = must(c.call("identify"), "identify")
                    if args.login:
                        must(c.call("set-client-info", name="bench", kind="bench",
                                    capabilities=["terminal-frontend-shell-integration-v1"]),
                             "set-client-info")
                    break
                except OSError:
                    pass
            if time.time() > deadline:
                raise RuntimeError("daemon socket never appeared")
            time.sleep(0.1)

        if args.disk_load:
            disk_load(root, args.disk_load, stop_load)
            result["disk_load"] = args.disk_load
        base = must(c.call("new-workspace", name="base", cols=120, rows=40), "new-workspace")
        base_pane, _ = pane_of(c, base["surface"])
        marker.wait(time.perf_counter())
        sized = {"cols": 80, "rows": 24}
        # The app names the shell in each new tab's env; with the frontend
        # capability that shell starts through login(1).
        tab = dict(sized, env={"SHELL": shell}) if args.login else sized
        samples = {}
        followed = {}

        def rec(name, metric, ms, counted):
            if counted:
                samples.setdefault(f"{name} {metric}", []).append(ms)

        def create(label, cmd, counted, **params):
            marker.drain()
            t0 = time.perf_counter()
            data = must(c.call(cmd, **params), cmd)
            rec(label, "reply", (time.perf_counter() - t0) * 1000.0, counted)
            rec(label, "exec", marker.wait(t0), counted)
            terminal = params.get("terminal_id") or data.get("terminal_id")
            if counted and terminal:
                followed.setdefault(label, []).append(terminal)
            return data

        for i in range(args.warmup + args.rounds):
            counted = i >= args.warmup
            data = create("new-tab", "new-tab", counted, pane=base_pane, terminal_id=uuid.uuid4().hex, **tab)
            c.call("close-surface", surface=data["surface"])
            data = create("split right", "split", counted, pane=base_pane, dir="right",
                          terminal_id=uuid.uuid4().hex, **tab)
            pane = data.get("pane") or pane_of(c, data["surface"])[0]
            c.call("close-pane", pane=pane, end_terminals=True)
            data = create("new-workspace", "new-workspace", counted, name=f"w{i}", **sized)
            _, ws = pane_of(c, data["surface"])
            c.call("close-workspace", workspace=ws, end_terminals=True)

        # First text: the daemon's first printable output of each terminal
        # (debug span follow marks), from its request's arrival.
        if args.spans:
            deadline = time.time() + 12
            want = {t for ids in followed.values() for t in ids}
            first = {}
            while time.time() < deadline:
                first = first_text_marks(spans_path)
                if want <= set(first):
                    break
                time.sleep(0.25)
            for label, ids in followed.items():
                got = [first[t] for t in ids if t in first]
                if got:
                    samples[f"{label} first-text"] = got
        for name, s in samples.items():
            sm = summary(s)
            result["ops"][name] = {"summary": sm, "samples_ms": [round(x, 3) for x in s]}
            print(f"CREATE {args.label} op=\"{name}\" n={sm['n']} p50={sm['p50']} p95={sm['p95']} max={sm['max']}", flush=True)
            if args.max_p50_ms is not None and name.endswith(args.gate_metric) and sm["p50"] > args.max_p50_ms:
                failed = True

        # Per-terminal cost: processes and RSS added by --live open terminals
        # (a host each, or the growth of the one holder), and the daemon's.
        time.sleep(0.5)
        before = host_pids(daemon.pid)
        before_rss = rss_kb(before)
        before_daemon = rss_kb([daemon.pid])
        live = []
        for _ in range(args.live):
            live.append(create("live", "new-tab", False, pane=base_pane, **sized))
        time.sleep(0.5)
        after = host_pids(daemon.pid)
        added = [p for p in after if p not in before]
        cost = {
            "terminals": args.live,
            "host_processes_added": len(added),
            "host_rss_kb_added": rss_kb(after) - before_rss,
            "daemon_rss_kb_added": rss_kb([daemon.pid]) - before_daemon,
            "terminal_processes": len(after),
        }
        result["per_terminal"] = cost
        n = max(1, args.live)
        print(f"CREATE {args.label} per_terminal hosts={len(added)/n:.2f} "
              f"rss_kb={cost['host_rss_kb_added']/n:.0f} daemon_rss_kb={cost['daemon_rss_kb_added']/n:.0f} "
              f"terminal_processes={len(after)}", flush=True)
        for d in live:
            c.call("close-surface", surface=d["surface"])
        c.close()
    finally:
        stop_load.set()
        # Hosts outlive a SIGTERM; end them with the daemon, also on errors.
        try:
            ident = result["identify"]
            sc = Conn(sock, timeout=30)
            sc.call("shutdown-daemon", pid=ident["pid"],
                    generation=ident.get("generation") or ident.get("boot_generation") or "",
                    end_terminals=True)
            sc.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            daemon.wait(timeout=20)
        except Exception:  # noqa: BLE001
            pass
        try:
            os.killpg(daemon.pid, signal.SIGTERM)
            daemon.wait(timeout=20)
        except Exception:  # noqa: BLE001
            try:
                os.killpg(daemon.pid, signal.SIGKILL)
            except Exception:  # noqa: BLE001
                pass
        if args.spans and os.path.exists(spans_path):
            print_marks(args.label, spans_path)
            if args.out:
                shutil.copy(spans_path, args.out + ".spans.ndjson")
        log.close()
        if args.out:
            shutil.copy(os.path.join(root, "daemon.log"), args.out + ".daemon.log")
        # No close(marker.fd): on macOS close() of a FIFO waits for the
        # reader thread's read(), which never returns; the fd ends with us.
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
    if failed:
        print(f"CREATE {args.label} FAIL: a {args.gate_metric.strip()} p50 is above {args.max_p50_ms} ms", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
