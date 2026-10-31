#!/usr/bin/env python3
"""PTYs held by workspaces nobody has shown, on a headless cmux-tui daemon.

macOS gives the whole machine kern.tty.ptmx_max PTYs (511). Each terminal
host holds one for its life, so a session with hundreds of workspaces that
nobody opens can use them all (a913, Lawrence 2026-10-30). This counts the
/dev/ptmx masters held on the machine (lsof) before and after each step:

  subagent-old    --count workspaces as the Chief made them before #27549:
                  create-workspace, create-terminal (a shell), new-conversation-tab
  subagent-new    --count workspaces as the Chief makes them now:
                  create-workspace, new-conversation-tab (no shell)
  keep-layout     --count one-shell workspaces, shutdown-daemon end_terminals
                  keep_layout, a new daemon, then what the app does on connect
                  (relaunchKeptTabs: restart-tab of every kept tab without
                  relaunch.on_show), then the show of one workspace
                  (wakeParkedTabs: restart-tab of its on_show tabs)

Run it on an otherwise idle machine (cmux-ci --class exclusive): the count is
machine-wide. Prints PTYS lines and writes JSON to --out.
"""

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
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


def ptys():
    """/dev/ptmx masters open on the machine (one per PTY in use)."""
    out = subprocess.run(["lsof", "-n", "-w", "-F", "f", "/dev/ptmx"], capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if line.startswith("f"))


def settle(want=None, timeout=20.0):
    """The PTY count once it holds still for 1 s (or reaches `want`)."""
    deadline = time.time() + timeout
    last, since = ptys(), time.time()
    while time.time() < deadline:
        time.sleep(0.2)
        now = ptys()
        if want is not None and now == want:
            return now
        if now != last:
            last, since = now, time.time()
        elif time.time() - since >= 1.0:
            return now
    return last


class Daemon:
    def __init__(self, binary, root):
        self.binary, self.root = binary, root
        self.sock = os.path.join(root, "s.sock")
        self.state = os.path.join(root, "state")
        home = os.path.join(root, "home")
        os.makedirs(home, exist_ok=True)
        os.makedirs(self.state, exist_ok=True)
        self.env = dict(os.environ)
        self.env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
            SHELL="/bin/sh",
        )
        self.session = f"up{os.getpid()}"
        self.proc = None
        self.conn = None

    def start(self):
        log = open(os.path.join(self.root, "daemon.log"), "a")
        self.proc = subprocess.Popen(
            [self.binary, "--headless", "--session", self.session, "--socket", self.sock, "--state", self.state],
            stdout=log, stderr=subprocess.STDOUT, env=self.env, start_new_session=True,
        )
        deadline = time.time() + 30
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError(f"daemon exited {self.proc.returncode}")
            if os.path.exists(self.sock):
                try:
                    self.conn = Conn(self.sock)
                    self.identify = must(self.conn.call("identify"), "identify")
                    return self
                except OSError:
                    pass
            if time.time() > deadline:
                raise RuntimeError("daemon socket never appeared")
            time.sleep(0.1)

    def shutdown_keep_layout(self):
        data = must(self.conn.call("shutdown-daemon", pid=self.identify["pid"],
                                   generation=self.identify["generation"],
                                   end_terminals=True, keep_layout=True), "shutdown-daemon")
        self.conn.close()
        self.proc.wait(timeout=30)
        return data

    def stop(self):
        if self.conn:
            try:
                must(self.conn.call("shutdown-daemon", pid=self.identify["pid"],
                                    generation=self.identify["generation"], end_terminals=True), "shutdown-daemon")
            except Exception:  # noqa: BLE001 - teardown
                pass
            self.conn.close()
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=10)
            except Exception:  # noqa: BLE001 - teardown
                pass


def tabs(conn):
    tree = must(conn.call("list-workspaces"), "list-workspaces")
    for ws in tree.get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    yield ws, tab


def subagent_workspaces(daemon, count, with_shell, cwd):
    c = daemon.conn
    for k in range(count):
        ws = must(c.call("create-workspace", name=f"sub{k}"), "create-workspace")["workspace"]
        if with_shell:
            must(c.call("create-terminal", workspace=ws, cwd=cwd), "create-terminal")
        must(c.call("new-conversation-tab", workspace=ws,
                    agent_session={"host": "install:bench", "session": f"s{k}", "harness": "claude"}),
             "new-conversation-tab")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--label", default="run")
    ap.add_argument("--root-dir", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    result = {"label": args.label, "count": args.count}

    def line(step, value, base):
        result[step] = value - base
        print(f"PTYS {args.label} step={step} held={value - base} machine={value}", flush=True)

    for scenario, with_shell in (("subagent-old", True), ("subagent-new", False)):
        root = tempfile.mkdtemp(prefix="up-", dir=args.root_dir)
        base = settle()
        d = Daemon(args.bin, root).start()
        try:
            subagent_workspaces(d, args.count, with_shell, root)
            line(scenario, settle(), base)
        finally:
            d.stop()
            shutil.rmtree(root, ignore_errors=True)

    root = tempfile.mkdtemp(prefix="up-", dir=args.root_dir)
    base = settle()
    d = Daemon(args.bin, root).start()
    try:
        for k in range(args.count):
            must(d.conn.call("new-workspace", name=f"kept{k}", cols=80, rows=24), "new-workspace")
        line("keep-layout-before-quit", settle(base + args.count), base)
        d.shutdown_keep_layout()
        line("keep-layout-after-quit", settle(base), base)
        d = Daemon(args.bin, root).start()
        line("keep-layout-new-daemon", settle(), base)
        kept = [(ws, tab) for ws, tab in tabs(d.conn) if tab.get("dead") and tab.get("relaunch")]
        on_show = [(ws, tab) for ws, tab in kept if (tab.get("relaunch") or {}).get("on_show") is True]
        result["kept_tabs"], result["kept_on_show"] = len(kept), len(on_show)
        print(f"PTYS {args.label} kept_tabs={len(kept)} on_show={len(on_show)}", flush=True)
        # The app's connect (DaemonConnection.relaunchKeptTabs).
        for _, tab in kept:
            if (tab.get("relaunch") or {}).get("on_show") is not True:
                must(d.conn.call("restart-tab", surface=tab["surface"]), "restart-tab")
        line("keep-layout-app-connect", settle(), base)
        # The show of one workspace (DaemonService.wakeParkedTabs).
        if on_show:
            shown = on_show[0][0]["id"]
            for ws, tab in on_show:
                if ws["id"] == shown:
                    must(d.conn.call("restart-tab", surface=tab["surface"]), "restart-tab")
        line("keep-layout-one-shown", settle(), base)
    finally:
        d.stop()
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=2)


if __name__ == "__main__":
    main()
