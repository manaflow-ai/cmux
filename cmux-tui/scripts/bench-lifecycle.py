#!/usr/bin/env python3
"""Tab, pane and workspace lifecycle latency on a headless cmux-tui daemon.

Starts one durable daemon (state on the local disk, so fsync costs what it
costs), makes one base workspace, then for --rounds rounds times each
create/close command from send to reply on one control connection:

  new-tab (terminal, sized)      -> close-surface
  new-browser-tab                -> close-surface
  split right (sized)            -> close-pane end_terminals
  split down (sized)             -> close-pane end_terminals
  split right (no size)          -> close-pane end_terminals
  new-workspace (sized)          -> close-workspace end_terminals

Prints one LIFECYCLE line per operation (p50/p95/max/N, ms) and writes JSON
with every sample to --out.
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


def timed(conn, cmd, **params):
    t0 = time.perf_counter()
    resp = conn.call(cmd, **params)
    ms = (time.perf_counter() - t0) * 1000.0
    return must(resp, cmd), ms


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


def daemon_threads(pid):
    """Threads of the bench's own daemon (ps -M lists one line per thread)."""
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.strip().splitlines()) - 1)


def summary(samples):
    if not samples:
        return {"n": 0}
    s = sorted(samples)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]  # noqa: E731
    return {"n": len(s), "p50": round(q(0.50), 3), "p95": round(q(0.95), 3), "max": round(s[-1], 3)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--rounds", type=int, default=40)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--root-dir", default=None)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default=None)
    ap.add_argument("--background", type=int, default=0,
                    help="extra idle workspaces (one terminal each) that make the session larger")
    ap.add_argument("--spans", action="store_true", help="set CMUX_TUI_DEBUG_SPANS and keep the file")
    args = ap.parse_args()

    root = tempfile.mkdtemp(prefix="lc-", dir=args.root_dir)
    sock = os.path.join(root, "s.sock")
    home = os.path.join(root, "home")
    state = os.path.join(root, "state")
    os.makedirs(home)
    os.makedirs(state)
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
    spans_path = os.path.join(root, "spans.ndjson")
    if args.spans:
        env["CMUX_TUI_DEBUG_SPANS"] = spans_path
    log = open(os.path.join(root, "daemon.log"), "a")
    daemon = subprocess.Popen(
        [args.bin, "--headless", "--session", f"lc{os.getpid()}", "--socket", sock, "--state", state],
        stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True,
    )
    result = {"label": args.label, "platform": platform.platform(), "rounds": args.rounds,
              "background": args.background, "ops": {}}
    try:
        deadline = time.time() + 30
        while True:
            if daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {daemon.returncode}")
            if os.path.exists(sock):
                try:
                    c = Conn(sock)
                    result["identify"] = must(c.call("identify"), "identify")
                    break
                except OSError:
                    pass
            if time.time() > deadline:
                raise RuntimeError("daemon socket never appeared")
            time.sleep(0.1)

        threads_before = daemon_threads(daemon.pid)
        for k in range(args.background):
            must(c.call("new-workspace", name=f"bg{k}", cols=80, rows=24), "new-workspace")
        if args.background:
            # Daemon threads each idle terminal adds (PL-daemon: one producer
            # thread for all terminals, not one per terminal).
            time.sleep(1.0)
            added = daemon_threads(daemon.pid) - threads_before
            result["daemon_threads_per_terminal"] = round(added / args.background, 2)
            print(f"LIFECYCLE {args.label} daemon_threads_per_terminal={added / args.background:.2f}", flush=True)
        base = must(c.call("new-workspace", name="base", cols=120, rows=40), "new-workspace")
        base_pane, _ = pane_of(c, base["surface"])
        sized = {"cols": 80, "rows": 24}
        samples = {}

        def rec(name, ms, counted):
            if counted:
                samples.setdefault(name, []).append(ms)

        for i in range(args.warmup + args.rounds):
            counted = i >= args.warmup
            data, ms = timed(c, "new-tab", pane=base_pane, **sized)
            rec("new-tab terminal", ms, counted)
            _, ms = timed(c, "close-surface", surface=data["surface"])
            rec("close-surface terminal", ms, counted)

            data, ms = timed(c, "new-browser-tab", url="about:blank", pane=base_pane, **sized)
            rec("new-tab browser", ms, counted)
            _, ms = timed(c, "close-surface", surface=data["surface"])
            rec("close-surface browser", ms, counted)

            for name, params in (
                ("split right", {"dir": "right", **sized}),
                ("split down", {"dir": "down", **sized}),
                ("split right unsized", {"dir": "right"}),
            ):
                data, ms = timed(c, "split", pane=base_pane, **params)
                rec(name, ms, counted)
                pane = data.get("pane") or pane_of(c, data["surface"])[0]
                _, ms = timed(c, "close-pane", pane=pane, end_terminals=True)
                rec("close-pane (" + name + ")", ms, counted)

            data, ms = timed(c, "new-workspace", name=f"w{i}", **sized)
            rec("new-workspace", ms, counted)
            _, ws = pane_of(c, data["surface"])
            _, ms = timed(c, "close-workspace", workspace=ws, end_terminals=True)
            rec("close-workspace", ms, counted)

        for name, s in samples.items():
            result["ops"][name] = {"summary": summary(s), "samples_ms": [round(x, 3) for x in s]}
            sm = summary(s)
            print(f"LIFECYCLE {args.label} op=\"{name}\" n={sm['n']} p50={sm['p50']} p95={sm['p95']} max={sm['max']}", flush=True)
        _, base_ws = pane_of(c, base["surface"])
        c.call("close-workspace", workspace=base_ws, end_terminals=True)
        try:
            st = c.call("server-stats", include=["write_path", "resource_projection"])
            result["server_stats"] = st.get("data")
        except Exception:  # noqa: BLE001
            pass
        c.close()
    finally:
        try:
            os.killpg(daemon.pid, signal.SIGTERM)
            daemon.wait(timeout=20)
        except Exception:  # noqa: BLE001
            try:
                os.killpg(daemon.pid, signal.SIGKILL)
            except Exception:  # noqa: BLE001
                pass
        if args.spans and os.path.exists(spans_path) and args.out:
            shutil.copy(spans_path, args.out + ".spans.ndjson")
        log.close()
        if os.path.exists(os.path.join(root, "daemon.log")) and args.out:
            shutil.copy(os.path.join(root, "daemon.log"), args.out + ".daemon.log")
        shutil.rmtree(root, ignore_errors=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)


if __name__ == "__main__":
    sys.exit(main())
