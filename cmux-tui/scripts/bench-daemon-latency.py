#!/usr/bin/env python3
"""Request latency of one headless cmux-tui daemon (perf-10x daemon area).

Starts an isolated headless daemon (durable state on the local disk), then
measures, per scenario, the client-side round trip of control requests on
one JSON-lines connection:

- ping, identify, list-workspaces, send (terminal write), new-tab
  (each new tab is closed again outside the timed window);
- the `cmux` CLI end to end (process start -> exit) for a session ping, the
  workspace list and a terminal write, through CMUX_TUI_SOCKET;
- the same raw requests from 10 concurrent clients.

Scenarios: "small" (1 workspace, 1 terminal) and "scale" (50 workspaces,
200 terminals, 5% of them printing steadily). Output: one PERF-DAEMON line
per (scenario, metric) and a JSON file.

Usage:
  bench-daemon-latency.py --bin target/release/cmux-tui --out result.json
"""

import argparse
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


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

    def read_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("control socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            msg = self.read_line()
            if msg.get("id") == rid and "ok" in msg:
                return msg


def must(resp, what):
    if not resp.get("ok"):
        raise RuntimeError(f"{what} failed: {resp.get('error')!r}")
    return resp.get("data") or {}


def stats(vals):
    if not vals:
        return {"n": 0}
    s = sorted(vals)
    pick = lambda q: s[min(len(s) - 1, int(round(q * (len(s) - 1))))]  # noqa: E731
    return {
        "n": len(s),
        "p50_ms": round(pick(0.5), 3),
        "p95_ms": round(pick(0.95), 3),
        "p99_ms": round(pick(0.99), 3),
        "max_ms": round(s[-1], 3),
        "mean_ms": round(statistics.fmean(s), 3),
    }


class Bench:
    def __init__(self, args):
        self.args = args
        self.root = tempfile.mkdtemp(prefix="pd.", dir="/private/tmp" if sys.platform == "darwin" else None)
        self.sock_path = os.path.join(self.root, "s.sock")
        self.session = f"perfd{os.getpid()}"
        self.daemon = None
        self.env = None
        self.result = {"scenarios": {}}

    def start(self):
        home = os.path.join(self.root, "home")
        os.makedirs(home, exist_ok=True)
        env = dict(os.environ)
        for k in [k for k in env if k.startswith("CMUX")]:
            del env[k]
        env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            CMUX_TUI_CONFIG=os.path.join(self.root, "config.json"),
            SHELL="/bin/sh",
        )
        self.env = env
        argv = [self.args.bin, "--headless", "--session", self.session, "--socket", self.sock_path,
                "--state", os.path.join(self.root, "state")]
        self.daemon_log = open(os.path.join(self.root, "daemon.log"), "a")
        self.daemon = subprocess.Popen(argv, stdout=self.daemon_log, stderr=subprocess.STDOUT, env=env,
                                       start_new_session=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {self.daemon.returncode}: {self.tail()}")
            if os.path.exists(self.sock_path):
                try:
                    c = Conn(self.sock_path)
                    self.ident = must(c.call("identify"), "identify")
                    c.close()
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            raise RuntimeError("daemon socket never appeared: " + self.tail())
        self.result["daemon"] = {"version": self.ident.get("version"), "protocol": self.ident.get("protocol")}
        log("daemon up", self.daemon.pid, self.ident.get("version"))

    def tail(self):
        try:
            with open(os.path.join(self.root, "daemon.log")) as f:
                return f.read()[-3000:]
        except OSError:
            return ""

    def stop(self):
        if not self.daemon:
            return
        try:
            c = Conn(self.sock_path, timeout=300)
            ident = must(c.call("identify"), "identify")
            c.call("shutdown-daemon", pid=ident["pid"],
                   generation=ident.get("generation") or ident.get("boot_generation") or "",
                   end_terminals=True)
            c.close()
        except Exception as e:  # noqa: BLE001
            log("shutdown failed", repr(e))
        try:
            self.daemon.wait(timeout=180)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    # -- topology

    def grow(self, workspaces, terminals, busy_fraction):
        c = Conn(self.sock_path, timeout=120)
        tree = must(c.call("list-workspaces"), "list-workspaces")
        have = len(tree.get("workspaces") or [])
        for i in range(have, workspaces):
            must(c.call("new-workspace", name=f"w{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        count = sum(1 for _ in self.surfaces(tree))
        busy_every = int(1 / busy_fraction) if busy_fraction > 0 else 0
        i = 0
        while count < terminals:
            busy = busy_every and i % busy_every == 0
            argv = (["perl", "-e", '$|=1; my $n=0; while (1) { print "busy ", $n++, " ", "x" x 60, "\\n"; select(undef,undef,undef,0.05); }']
                    if busy else ["/bin/sh"])
            must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=argv, cols=80, rows=24),
                 "create-terminal")
            count += 1
            i += 1
        c.close()

    def surfaces(self, tree):
        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k in ("surface", "surface_id") and isinstance(v, (int, str)):
                        yield v
                    else:
                        yield from walk(v)
            elif isinstance(node, list):
                for v in node:
                    yield from walk(v)
        seen = set()
        for s in walk(tree):
            if s not in seen:
                seen.add(s)
                yield s

    def first_surface(self, c):
        tree = must(c.call("list-workspaces"), "list-workspaces")
        return next(iter(self.surfaces(tree)))

    # -- measurement

    def raw(self, n):
        out = {}
        c = Conn(self.sock_path)
        surface = self.first_surface(c)
        plans = {
            "ping": lambda: c.call("ping"),
            "identify": lambda: c.call("identify"),
            "list-workspaces": lambda: c.call("list-workspaces"),
            "send": lambda: c.call("send", surface=surface, text=":\r"),
        }
        for name, fn in plans.items():
            for _ in range(5):
                fn()
            vals = []
            for _ in range(n):
                t = time.perf_counter()
                r = fn()
                vals.append((time.perf_counter() - t) * 1000)
                if not r.get("ok"):
                    raise RuntimeError(f"{name}: {r.get('error')!r}")
            out[name] = stats(vals)
        vals = []
        for _ in range(max(10, n // 10)):
            t = time.perf_counter()
            d = must(c.call("new-tab", cols=80, rows=24), "new-tab")
            vals.append((time.perf_counter() - t) * 1000)
            tab_surface = d.get("surface")
            if tab_surface is not None:
                c.call("close-surface", surface=tab_surface)
        out["new-tab"] = stats(vals)
        c.close()
        return out

    def concurrent(self, clients, n):
        vals = {"ping": [], "identify": [], "list-workspaces": []}
        errors = []
        lock = threading.Lock()
        barrier = threading.Barrier(clients)

        def worker():
            try:
                c = Conn(self.sock_path)
                local = {k: [] for k in vals}
                barrier.wait()
                for _ in range(n):
                    for name in vals:
                        t = time.perf_counter()
                        r = c.call(name)
                        local[name].append((time.perf_counter() - t) * 1000)
                        if not r.get("ok"):
                            raise RuntimeError(f"{name}: {r.get('error')!r}")
                c.close()
                with lock:
                    for k in vals:
                        vals[k].extend(local[k])
            except Exception as e:  # noqa: BLE001
                errors.append(repr(e))

        ts = [threading.Thread(target=worker) for _ in range(clients)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        out = {f"c{clients}-{k}": stats(v) for k, v in vals.items()}
        if errors:
            out["errors"] = errors[:5]
        return out

    def cli(self, n):
        env = dict(self.env)
        env["CMUX_TUI_SOCKET"] = self.sock_path
        c = Conn(self.sock_path)
        surface = self.first_surface(c)
        c.close()
        cmds = {
            "cli-ping": [["session", "current", "ping"], ["ping"]],
            "cli-workspace-list": [["workspace", "list"]],
            "cli-terminal-write": [["terminal", str(surface), "write", "--text", ":\r"],
                                   ["terminal", "current", "write", "--text", ":\r"]],
        }
        out = {}
        for name, candidates in cmds.items():
            chosen = None
            for argv in candidates:
                p = subprocess.run([self.args.bin, *argv], env=env, capture_output=True, timeout=30)
                if p.returncode == 0:
                    chosen = argv
                    break
                log(name, argv, "exit", p.returncode, p.stderr.decode(errors="replace")[-300:])
            if not chosen:
                out[name] = {"n": 0, "error": "no working CLI form"}
                continue
            vals = []
            for _ in range(n):
                t = time.perf_counter()
                p = subprocess.run([self.args.bin, *chosen], env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=30)
                vals.append((time.perf_counter() - t) * 1000)
            out[name] = {**stats(vals), "argv": " ".join(chosen)}
        vals = []
        for _ in range(n):
            t = time.perf_counter()
            subprocess.run([self.args.bin, "--version"], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
            vals.append((time.perf_counter() - t) * 1000)
        out["cli-version-no-socket"] = stats(vals)
        return out

    def scenario(self, name, workspaces, terminals, busy):
        log("scenario", name, workspaces, terminals)
        self.grow(workspaces, terminals, busy)
        time.sleep(self.args.settle)
        res = {}
        res.update(self.raw(self.args.n))
        res.update(self.concurrent(10, max(20, self.args.n // 5)))
        res.update(self.cli(self.args.cli_n))
        self.result["scenarios"][name] = res
        for metric, s in res.items():
            if isinstance(s, dict) and "n" in s:
                print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                      f"p99={s.get('p99_ms')} max={s.get('max_ms')}" + (f" argv=\"{s['argv']}\"" if "argv" in s else ""),
                      flush=True)
            elif metric == "errors":
                print(f"PERF-DAEMON {name} errors {s}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--cli-n", type=int, default=40)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--scenarios", default="small,scale")
    args = ap.parse_args()
    b = Bench(args)
    status = 0
    try:
        b.start()
        wanted = args.scenarios.split(",")
        if "small" in wanted:
            b.scenario("small", 1, 1, 0)
        if "scale" in wanted:
            b.scenario("scale", 50, 200, 0.05)
    except Exception as e:  # noqa: BLE001
        log("FAILED", repr(e), b.tail()[-1500:])
        b.result["error"] = repr(e)
        status = 1
    finally:
        b.stop()
        with open(args.out, "w") as f:
            json.dump(b.result, f, indent=1)
    return status


if __name__ == "__main__":
    sys.exit(main())
