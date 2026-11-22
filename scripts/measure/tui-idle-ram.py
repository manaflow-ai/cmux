#!/usr/bin/env python3
"""The idle cmux-tui daemon's memory on Linux (CMUX-571, goal ram-baseline).

Leo, 2026-11-12: "Infinite everything feels like nothing"; RAM, CPU and disk bounded over days. The app's idle
footprint counts the cmux-tui daemon; this says what that daemon holds at rest, and where.

It starts one headless daemon of the given binary on a scratch home, optionally opens WORKSPACES workspaces (one
terminal each, as the app's first window has), waits SETTLE seconds and samples the daemon and every process under
it: smaps_rollup (Rss, Pss, Pss_Anon, Pss_File, Private_Dirty, Anonymous), threads by name, and the daemon's
largest mappings by Pss, with anonymous regions sized like a glibc malloc arena (64 MB reserved) or a thread stack
counted apart. Then it ends the daemon through its own shutdown-daemon request (with CMUX_TUI_DHAT_OUT set, a
dhat-heap build writes its heap profile then).

Output: TUI-IDLE lines (one JSON object each) and, with --out, the same as one JSON file. Measurement only: it
signals only the processes it started.

  tui-idle-ram.py --tui BIN [--workspaces 0] [--settle 20] [--label NAME] [--out FILE]
"""

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROLLUP_KEYS = ("Rss", "Pss", "Pss_Anon", "Pss_File", "Pss_Shmem", "Private_Dirty", "Private_Clean", "Shared_Clean",
               "Anonymous", "Swap")


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


class Tui:
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
                    raise ConnectionError("socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "ok" in msg:
                if not msg.get("ok"):
                    raise RuntimeError(f"{cmd}: {msg.get('error')!r}")
                return msg.get("data") or {}


def children(pid):
    kids = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", "rb") as f:
                data = f.read()
            ppid = int(data[data.rindex(b")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        kids.setdefault(ppid, []).append(int(name))
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        out.append(p)
        todo.extend(kids.get(p, []))
    return out


def rollup(pid):
    vals = {}
    with open(f"/proc/{pid}/smaps_rollup") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[0].rstrip(":") in ROLLUP_KEYS:
                vals[parts[0].rstrip(":")] = int(parts[1])
    return vals


def threads(pid):
    names = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            with open(f"/proc/{pid}/task/{tid}/comm") as f:
                n = f.read().strip()
        except OSError:
            continue
        # Fold numbered workers (tokio-runtime-w, rayon-3) to one name.
        n = n.rstrip("0123456789-_") or n
        names[n] = names.get(n, 0) + 1
    return dict(sorted(names.items(), key=lambda kv: -kv[1]))


def mappings(pid):
    """The daemon's mappings: (name, size_kb, rss_kb, pss_kb, private_dirty_kb, anon_kb)."""
    maps, cur = [], None
    with open(f"/proc/{pid}/smaps") as f:
        for line in f:
            head = line.split()
            if head and "-" in head[0] and len(head) >= 5 and not head[0].endswith(":"):
                name = head[5] if len(head) > 5 else "[anon]"
                cur = {"name": name, "perms": head[1], "Size": 0, "Rss": 0, "Pss": 0, "Private_Dirty": 0, "Anonymous": 0}
                maps.append(cur)
            elif cur is not None and head and head[0].rstrip(":") in cur and len(head) >= 2:
                cur[head[0].rstrip(":")] = int(head[1])
    return maps


def mapping_summary(maps):
    """The largest mappings by name (Pss), and the largest anonymous regions by Rss with their size: a glibc arena
    is a region inside a 64 MB reservation, a thread stack a region of its stack size plus a guard page."""
    by_name = {}
    for m in maps:
        g = by_name.setdefault(m["name"], {"Size": 0, "Rss": 0, "Pss": 0, "Private_Dirty": 0})
        for k in g:
            g[k] += m[k]
    anon = [m for m in maps if m["name"] in ("[anon]", "[heap]")]
    reserved = sum(1 for m in anon if m["perms"].startswith("---") and m["Size"] >= 4096)
    top_anon = sorted(anon, key=lambda m: -m["Rss"])[:12]
    top = sorted(by_name.items(), key=lambda kv: -kv[1]["Pss"])[:15]
    return {"top_by_pss_kb": [{"name": n, **v} for n, v in top], "arena_like_regions": reserved,
            "top_anon_kb": [{"name": m["name"], "perms": m["perms"], "Size": m["Size"], "Rss": m["Rss"]} for m in top_anon]}


def sample(pid):
    tree = children(pid)
    roll = rollup(pid)
    kids = {}
    for p in tree[1:]:
        try:
            r = rollup(p)
            with open(f"/proc/{p}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace")[:120]
        except OSError:
            continue
        kids[p] = {"cmd": cmd, **r}
    with open(f"/proc/{pid}/status") as f:
        status = {ln.split(":")[0]: ln.split(":", 1)[1].strip() for ln in f if ":" in ln}
    maps = mappings(pid)
    return {"daemon": roll, "threads_total": int(status.get("Threads", "0")), "threads": threads(pid),
            "vm_data_kb": int(status.get("VmData", "0 kB").split()[0]), "vm_size_kb": int(status.get("VmSize", "0 kB").split()[0]),
            "maps": mapping_summary(maps), "children": kids,
            "children_pss_kb": sum(k.get("Pss", 0) for k in kids.values())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tui", required=True)
    ap.add_argument("--workspaces", type=int, default=0)
    ap.add_argument("--settle", type=float, default=20)
    ap.add_argument("--label", default="")
    ap.add_argument("--out")
    args = ap.parse_args()
    root = tempfile.mkdtemp(prefix="tui-idle-")
    home = os.path.join(root, "home")
    os.makedirs(home)
    sock = os.path.join(root, "t.sock")
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_STATE_HOME=os.path.join(home, ".local/state"), XDG_DATA_HOME=os.path.join(home, ".local/share"),
               XDG_CACHE_HOME=os.path.join(home, ".cache"), CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
               ACPMUX_SOCKET=os.path.join(root, "no-acpmux.sock"), SHELL="/bin/sh")
    env.pop("CMUX_TUI_TERMINAL_HOST_MODEL", None)
    log_path = os.path.join(root, "tui.log")
    with open(log_path, "w") as lf:
        proc = subprocess.Popen([args.tui, "--headless", "--session", f"idle{os.getpid()}", "--socket", sock,
                                 "--state", os.path.join(root, "state")],
                                stdout=lf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                                start_new_session=True)
    result = {"label": args.label, "workspaces": args.workspaces, "settle_s": args.settle}
    try:
        deadline = time.monotonic() + 60
        while True:
            if proc.poll() is not None:
                raise RuntimeError(f"daemon exited {proc.returncode}: {open(log_path).read()[-2000:]}")
            if os.path.exists(sock):
                try:
                    c = Tui(sock, timeout=5)
                    c.call("identify")
                    c.close()
                    break
                except (OSError, RuntimeError, ValueError):
                    pass
            if time.monotonic() > deadline:
                raise RuntimeError("daemon socket not up within 60 s")
            time.sleep(0.1)  # bench: waiting for the daemon it started to listen
        c = Tui(sock)
        for i in range(args.workspaces):
            c.call("new-workspace", name=f"w{i}", cols=80, rows=24)
        c.close()
        time.sleep(args.settle)  # bench: the idle window
        result.update(sample(proc.pid))
        d = result["daemon"]
        print("TUI-IDLE " + json.dumps({"label": args.label, "workspaces": args.workspaces,
                                        "daemon_rss_mb": round(d.get("Rss", 0) / 1024, 1),
                                        "daemon_pss_mb": round(d.get("Pss", 0) / 1024, 1),
                                        "daemon_pss_anon_mb": round(d.get("Pss_Anon", 0) / 1024, 1),
                                        "daemon_pss_file_mb": round(d.get("Pss_File", 0) / 1024, 1),
                                        "daemon_private_dirty_mb": round(d.get("Private_Dirty", 0) / 1024, 1),
                                        "threads": result["threads_total"],
                                        "arena_like_regions": result["maps"]["arena_like_regions"],
                                        "children": len(result["children"]),
                                        "children_pss_mb": round(result["children_pss_kb"] / 1024, 1)}), flush=True)
        print("TUI-IDLE-THREADS " + json.dumps({"label": args.label, "threads": result["threads"]}), flush=True)
        for m in result["maps"]["top_by_pss_kb"]:
            print(f"TUI-IDLE-MAP {args.label} pss {m['Pss'] / 1024:8.1f} MB rss {m['Rss'] / 1024:8.1f} MB "
                  f"dirty {m['Private_Dirty'] / 1024:8.1f} MB size {m['Size'] / 1024:9.1f} MB  {m['name']}", flush=True)
        for m in result["maps"]["top_anon_kb"]:
            print(f"TUI-IDLE-ANON {args.label} rss {m['Rss'] / 1024:8.1f} MB size {m['Size'] / 1024:9.1f} MB "
                  f"{m['perms']} {m['name']}", flush=True)
        for p, k in result["children"].items():
            print(f"TUI-IDLE-CHILD {args.label} pid {p} pss {k.get('Pss', 0) / 1024:.1f} MB  {k['cmd']}", flush=True)
    finally:
        try:
            c = Tui(sock, timeout=60)
            ident = c.call("identify")
            c.call("shutdown-daemon", pid=ident.get("pid"),
                   generation=ident.get("generation") or ident.get("boot_generation") or "", end_terminals=True)
            c.close()
        except (OSError, RuntimeError, ValueError) as exc:
            log(f"shutdown-daemon: {exc}")
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        if args.out:
            with open(args.out, "w") as f:
                json.dump(result, f, indent=1)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
