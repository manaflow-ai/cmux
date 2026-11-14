#!/usr/bin/env python3
"""Daemon restart (update handoff) time on a headless cmux-tui daemon.

Starts one durable daemon (`--first-bin`, state on the local disk), makes
--workspaces workspaces with --tabs terminals each, prints --lines lines in
every terminal and puts --hooks agent hook events in the journal. Then it
restarts the daemon --restarts times the way an update does: SIGTERM (the
daemon hands off; every terminal host stays alive) and exec of `--bin`. For
each restart it times, from the exec:

  listen      the control socket accepts a connection
  first       the first `ping` answer
  listed      the first `list-workspaces` answer that shows every workspace
  adopted     every terminal answers `read-screen` with its marker line

and the old daemon's SIGTERM-to-exit time (`stop`). Prints one RESTART line
per restart and one RESTART summary line per measure (p50/max, ms).
Everything it starts lives under a private temp root and is ended at exit.
"""

import argparse
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


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


def terminals_of(tree):
    """{terminal resource id: surface} of every PTY tab (surface numbers can change at a restart)."""
    out = {}
    for ws in tree.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    if isinstance(tab, dict) and tab.get("kind") == "pty" and not tab.get("dead"):
                        out[tab["content_resource_id"]] = tab.get("surface", tab.get("id"))
    return out


def pane_of(tree, surface):
    for ws in tree.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    ids = {tab.get("id"), tab.get("surface")} if isinstance(tab, dict) else {tab}
                    if surface in ids:
                        return pane["id"]
    raise RuntimeError(f"surface {surface} is in no pane")


class Daemon:
    def __init__(self, args, root, env):
        self.args = args
        self.root = root
        self.env = env
        self.sock = os.path.join(root, "s.sock")
        self.state = os.path.join(root, "state")
        self.session = f"rs{os.getpid()}"
        self.log = open(os.path.join(root, "daemon.log"), "a")
        self.proc = None

    def start(self, binary):
        self.proc = subprocess.Popen(
            [binary, "--headless", "--session", self.session, "--socket", self.sock,
             "--state", self.state],
            stdout=self.log, stderr=subprocess.STDOUT, env=self.env, start_new_session=True,
        )
        return time.perf_counter()

    def connect(self, deadline_s=600):
        deadline = time.time() + deadline_s
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError(f"daemon exited {self.proc.returncode}")
            try:
                return Conn(self.sock)
            except OSError:
                pass
            if time.time() > deadline:
                raise RuntimeError("daemon socket never accepted")
            time.sleep(0.002)

    def stop(self):
        t0 = time.perf_counter()
        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(timeout=120)
        return (time.perf_counter() - t0) * 1000.0


def summary(samples):
    s = sorted(samples)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]  # noqa: E731
    return f"n={len(s)} p50={q(0.5):.1f} max={s[-1]:.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, help="the daemon each restart execs")
    ap.add_argument("--first-bin", default=None, help="the daemon that makes the session (default --bin)")
    ap.add_argument("--workspaces", type=int, default=20)
    ap.add_argument("--tabs", type=int, default=5)
    ap.add_argument("--lines", type=int, default=2000)
    ap.add_argument("--hooks", type=int, default=0, help="agent hook events journaled before the restarts")
    ap.add_argument("--restarts", type=int, default=5)
    ap.add_argument("--root-dir", default=None)
    ap.add_argument("--label", default="run")
    ap.add_argument("--keep", action="store_true", help="keep the temp root")
    ap.add_argument("--verbose", action="store_true",
                    help="print each terminal's adoption time and its last read-screen error")
    ap.add_argument("--sample", default=None,
                    help="macOS: write a `sample` profile of each restart's first 2 s to <this>.<n>")
    args = ap.parse_args()

    root = tempfile.mkdtemp(prefix="rs-", dir=args.root_dir)
    home = os.path.join(root, "home")
    os.makedirs(home)
    os.makedirs(os.path.join(root, "state"))
    env = dict(os.environ)
    env.update(
        HOME=home,
        XDG_CONFIG_HOME=os.path.join(home, ".config"),
        XDG_STATE_HOME=os.path.join(home, ".local/state"),
        XDG_DATA_HOME=os.path.join(home, ".local/share"),
        XDG_CACHE_HOME=os.path.join(home, ".cache"),
        CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
        SHELL="/bin/sh",
    )
    daemon = Daemon(args, root, env)
    host_pids = set()
    results = {"label": args.label, "platform": platform.platform(), "restarts": []}
    try:
        daemon.start(args.first_bin or args.bin)
        c = daemon.connect(60)
        must(c.call("identify"), "identify")
        markers = {}
        for w in range(args.workspaces):
            ws = must(c.call("new-workspace", name=f"w{w}", cols=100, rows=30), "new-workspace")
            pane = pane_of(must(c.call("list-workspaces"), "list-workspaces"), ws["surface"])
            for _ in range(args.tabs - 1):
                must(c.call("new-tab", pane=pane, cols=100, rows=30), "new-tab")
        terminals = terminals_of(must(c.call("list-workspaces"), "list-workspaces"))
        first_term = next(iter(terminals))

        def echo_marker(surface, marker):
            # The quotes keep the typed command line from matching the marker.
            return f"echo {marker[:1]}''{marker[1:]}"

        for i, (term, surface) in enumerate(terminals.items()):
            markers[term] = f"M{i}X"
            must(c.call("send", surface=surface,
                        text=f"seq 1 {args.lines}; {echo_marker(surface, markers[term])}\n"),
                 "send")
        if args.hooks:
            # The real hook helper, run in the first terminal (its environment names the daemon).
            bin_q = "'" + (args.first_bin or args.bin).replace("'", "'\\''") + "'"
            payload = ('{"session_id":"bench-agent-0","hook_event_name":"PreToolUse",'
                       '"tool_name":"Bash","prompt":"bench turn"}')
            surface = terminals[first_term]
            must(c.call("send", surface=surface, text=(
                f"i=0; while [ $i -lt {args.hooks} ]; do printf '%s' '{payload}' | "
                f"{bin_q} __agent-hook claude PreToolUse >/dev/null 2>&1; i=$((i+1)); done; "
                f"clear; {echo_marker(surface, 'HOOKSDONE')}\n")), "send")
            deadline = time.time() + 30 + args.hooks * 0.1
            while "HOOKSDONE" not in must(c.call("read-screen", surface=surface),
                                          "read-screen").get("text", ""):
                if time.time() > deadline:
                    raise RuntimeError("hook helpers did not finish")
                time.sleep(0.2)
            must(c.call("send", surface=surface,
                        text=f"{echo_marker(surface, markers[first_term])}\n"), "send")
        deadline = time.time() + 120
        pending = set(terminals)
        while pending and time.time() < deadline:
            for term in list(pending):
                text = must(c.call("read-screen", surface=terminals[term]),
                            "read-screen").get("text", "")
                if markers[term] in text:
                    pending.discard(term)
            time.sleep(0.05)
        if pending:
            raise RuntimeError(f"{len(pending)} terminals never printed their marker")
        c.close()
        print(f"RESTART {args.label} setup workspaces={args.workspaces} terminals={len(terminals)} "
              f"lines={args.lines} hooks={args.hooks}", flush=True)

        measures = {"stop": [], "listen": [], "first": [], "listed": [], "adopted": []}
        for r in range(args.restarts):
            stop_ms = daemon.stop()
            t0 = daemon.start(args.bin)
            profiler = None
            if args.sample:
                profiler = subprocess.Popen(["sample", str(daemon.proc.pid), "2", "1", "-mayDie",
                                             "-file", f"{args.sample}.{r}"],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            c = daemon.connect()
            listen = (time.perf_counter() - t0) * 1000.0
            must(c.call("ping"), "ping")
            first = (time.perf_counter() - t0) * 1000.0
            while True:
                surfaces = terminals_of(must(c.call("list-workspaces"), "list-workspaces"))
                if all(term in surfaces for term in terminals):
                    break
                time.sleep(0.002)
            listed = (time.perf_counter() - t0) * 1000.0
            pending = set(terminals)
            done_at, last_error = {}, {}
            while pending:
                for term in list(pending):
                    resp = c.call("read-screen", surface=surfaces[term])
                    if resp.get("ok") and markers[term] in (resp.get("data") or {}).get("text", ""):
                        pending.discard(term)
                        done_at[term] = (time.perf_counter() - t0) * 1000.0
                    elif not resp.get("ok"):
                        last_error[term] = f"{resp.get('error_code', '')} {resp.get('error', '')}"[:120]
                    else:
                        last_error[term] = "marker not on screen"
                if pending:
                    if (time.perf_counter() - t0) > 600:
                        raise RuntimeError(f"{len(pending)} terminals not adopted after 600 s")
                    time.sleep(0.002)
            adopted = (time.perf_counter() - t0) * 1000.0
            if args.verbose:
                for term in sorted(done_at, key=done_at.get):
                    print(f"RESTART {args.label} restart={r} {term} at={done_at[term]:.1f} "
                          f"last_error={last_error.get(term)!r}", flush=True)
            c.close()
            if profiler:
                profiler.wait(timeout=60)
            row = {"stop": stop_ms, "listen": listen, "first": first, "listed": listed,
                   "adopted": adopted}
            for k, v in row.items():
                measures[k].append(v)
            results["restarts"].append(row)
            print(f"RESTART {args.label} restart={r} " +
                  " ".join(f"{k}={v:.1f}" for k, v in row.items()), flush=True)
        for k, v in measures.items():
            print(f"RESTART {args.label} {k} {summary(v)}", flush=True)
        with open(os.path.join(root, "result.json"), "w") as f:
            json.dump(results, f)
    finally:
        try:
            c = daemon.connect(30)
            tree = must(c.call("list-workspaces"), "list-workspaces")
            for ws in tree.get("workspaces", []):
                c.call("close-workspace", workspace=ws["id"], end_terminals=True)
            c.close()
            daemon.stop()
        except Exception as error:  # noqa: BLE001
            print(f"RESTART {args.label} cleanup: {error}", file=sys.stderr)
            if daemon.proc and daemon.proc.poll() is None:
                daemon.proc.kill()
        # Hosts this run started: their command line names this root's socket or state.
        out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, _, command = line.strip().partition(" ")
            if root in command and int(pid) != os.getpid():
                host_pids.add(int(pid))
        for pid in host_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print(f"RESTART {args.label} root={root}")


if __name__ == "__main__":
    main()
