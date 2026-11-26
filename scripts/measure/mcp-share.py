#!/usr/bin/env python3
"""Shared user MCP servers (ACPMUX_MCP_SHARE) against one server per chat, at the protocol level.

Driver of scripts/measure/mcp-share.sh. For each N, N chats each open the person's stdio MCP server
the way a harness does (`initialize`, `notifications/initialized`, `tools/list`), all at once:
  off   each chat starts its own server (what a harness does without the pool)
  on    each chat starts `acpmux mcp-shim` against one isolated acpmux daemon, whose pool starts
        one server for every chat (the spec is written where the daemon's registry keeps it)
  warm  N more shims while that server still runs (a chat opened after the first)
Then reads the RSS of every process each mode started (servers, shims; not the daemon) and ends
them by pid. No harness, no model, no credential.

Lines (stdout):
  MCP-SHARE mode=M n=N servers=S procs=P rss_mb=R connect_p50_ms=.. connect_max_ms=.. failed=F
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def spec_key(spec: dict) -> str:
    # mcp_pool::Spec::key: sha256 of serde_json's bytes (field order command, args, env, cwd), 16 bytes hex.
    raw = json.dumps(spec, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()[:32]


def tree_rss_kb(roots: list[int]) -> tuple[int, int, set[int]]:
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    kids: dict[int, list[int]] = {}
    rss: dict[int, int] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        pid, ppid, kb = map(int, parts)
        kids.setdefault(ppid, []).append(pid)
        rss[pid] = kb
    seen: set[int] = set()
    stack = list(roots)
    while stack:
        p = stack.pop()
        if p in seen or p not in rss:
            continue
        seen.add(p)
        stack.extend(kids.get(p, []))
    return sum(rss[p] for p in seen), len(seen), seen


def handshake(proc: subprocess.Popen, results: list, i: int, t0: float) -> None:
    try:
        w, r = proc.stdin, proc.stdout
        send = lambda m: (w.write((json.dumps(m) + "\n").encode()), w.flush())  # noqa: E731
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "mcp-share-bench", "version": "1"}}})
        want = {1}
        while want:
            m = json.loads(r.readline() or "null")
            if m is None:
                raise RuntimeError("closed")
            if m.get("id") in want and "method" not in m:
                want.discard(m["id"])
                if m["id"] == 1:
                    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
                    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                    want.add(2)
            elif "method" in m and "id" in m:
                # A server request (roots/list): answer with no roots.
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"roots": []}})
        results[i] = (time.monotonic() - t0) * 1000
    except Exception as e:  # noqa: BLE001
        results[i] = e


def open_chats(argvs: list[list[str]], env: dict) -> tuple[list[subprocess.Popen], list]:
    t0 = time.monotonic()
    procs = [subprocess.Popen(a, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=env) for a in argvs]
    results: list = [None] * len(procs)
    threads = [threading.Thread(target=handshake, args=(p, results, i, t0)) for i, p in enumerate(procs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(120)
    return procs, results


def end(pids: set[int]) -> None:
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass


def row(mode: str, n: int, results: list, rss_kb: int, procs: int, servers: int) -> None:
    ok = sorted(r for r in results if isinstance(r, float))
    failed = len(results) - len(ok)
    p50 = ok[len(ok) // 2] if ok else -1
    mx = ok[-1] if ok else -1
    print(f"MCP-SHARE mode={mode} n={n} servers={servers} procs={procs} rss_mb={rss_kb // 1024} "
          f"connect_p50_ms={p50:.0f} connect_max_ms={mx:.0f} failed={failed}", flush=True)
    for r in results:
        if not isinstance(r, float):
            print(f"MCP-SHARE-ERR mode={mode} n={n} {r!r}", flush=True)


def count_servers(pids: set[int], marker: str) -> int:
    n = 0
    for p in pids:
        out = subprocess.run(["ps", "-o", "command=", "-p", str(p)], capture_output=True, text=True).stdout
        # The server itself, not npx's `npm exec` and `sh -c` wrappers or a shim.
        if marker in out and out.lstrip().startswith("node "):
            n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--acpmux", required=True)
    ap.add_argument("--counts", default="5,20")
    ap.add_argument("--server", required=True, help="the server's command line (shell words)")
    ap.add_argument("--marker", required=True, help="a word the server's own `node` process carries")
    ap.add_argument("--settle", type=float, default=3)
    a = ap.parse_args()
    argv = shlex.split(a.server)
    spec = {"command": argv[0], "args": argv[1:], "env": {}, "cwd": None}
    key = spec_key(spec)
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}

    for n in [int(c) for c in a.counts.split(",")]:
        # off: one server per chat.
        procs, results = open_chats([argv] * n, env)
        time.sleep(a.settle)
        kb, cnt, pids = tree_rss_kb([p.pid for p in procs])
        row("off", n, results, kb, cnt, count_servers(pids, a.marker))
        end(pids)
        time.sleep(2)

        # on: one isolated daemon with the pool; every chat through a shim.
        home = Path(tempfile.mkdtemp(prefix="mcp-share-"))
        os.chmod(home, 0o700)
        spec_dir = home / "run" / "mcp-pool"
        spec_dir.mkdir(parents=True, mode=0o700)
        (spec_dir / f"{key}.json").write_text(json.dumps(spec, separators=(",", ":")))
        os.chmod(spec_dir / f"{key}.json", 0o600)
        denv = dict(env, ACPMUX_HOME=str(home), ACPMUX_MCP_SHARE="*")
        log = open(home / "daemon.log", "wb")
        daemon = subprocess.Popen([a.acpmux, "daemon", "run"], env=denv, stdout=log, stderr=log,
                                  stdin=subprocess.DEVNULL)
        sock = home / "acpmux.mcp.sock"
        for _ in range(600):
            if sock.exists():
                break
            time.sleep(0.1)
        if not sock.exists():
            print(f"MCP-SHARE-ERR mode=on n={n} the daemon's pool socket never appeared", flush=True)
            daemon.terminate()
            return 1
        shim = [a.acpmux, "mcp-shim", str(sock), key]
        procs, results = open_chats([shim] * n, denv)
        time.sleep(a.settle)
        shim_pids = [p.pid for p in procs]
        _, _, dpids = tree_rss_kb([daemon.pid])
        servers = {p for p in dpids if p != daemon.pid}
        kb, cnt, pids = tree_rss_kb(shim_pids + [s for s in servers])
        row("on", n, results, kb, cnt, count_servers(pids, a.marker))

        warm, wres = open_chats([shim] * n, denv)
        time.sleep(a.settle)
        kb2, cnt2, pids2 = tree_rss_kb(shim_pids + [p.pid for p in warm] + list(servers))
        row("warm", n, wres, kb2, cnt2, count_servers(pids2, a.marker))
        end(set(shim_pids) | {p.pid for p in warm})
        subprocess.run([a.acpmux, "daemon", "shutdown"], env=denv, capture_output=True, timeout=30)
        try:
            daemon.wait(15)
        except subprocess.TimeoutExpired:
            daemon.terminate()
        end(servers)
        time.sleep(2)
        shutil.rmtree(home, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
