#!/usr/bin/env python3
"""braid-vs-fs-tunnel: one host, one Cloud VM, several paths to it, the same probes on each.

Measures, from the host it runs on, a Freestyle Cloud VM reached over each named path. A path is an ssh
ProxyCommand (or "" for a plain ssh name), so every path is driven the same way and nothing here dials a
transport of its own:

  fs-tunnel   the app's device tunnel:   cmux wg dial --hub SOCK %h %p   (Freestyle Tunnel, WireGuard)
  fs-ssh      the Freestyle ssh proxy:   ssh -W localhost:22 VMID+USER@<proxy>
  tailnet     the VM's tailnet name, no ProxyCommand (direct or DERP; the path tailscale reports is recorded)
  braid-*     a Braid route that ends in a byte stream (cmux-tui remote / carrier-pipe), one per rung

Per path it records, all from one process and one clock:
  cold_ms     N fresh `ssh true` runs, spawn to exit (connect + auth + one command)
  echo_ms     N one-line round trips through one held `ssh cat` (keystroke echo: a byte out, the byte back)
  bulk_mbps   BULK_MB of zeros up through `cat >/dev/null`, and the same down from `head -c`
  fails       runs that failed or timed out (a failed run counts, it is never dropped)

Network-change, NAT and cell-to-Wi-Fi rows are not timed here: they come from netlab (routes.sh, h2h.sh) for
the Braid rungs, and by hand on a phone for the tunnel (see the findings page). Prints one line
`BVT-RUN {...}` (schema braid-vs-fs-tunnel-run.v1) that `cmux-bench braid-vs-fs-tunnel --import LOG` reads.

Run (on the origin host, e.g. a Mac or a coordinator host; never prints a key or token):
  scripts/measure/braid-vs-fs-tunnel.py --target USER@VM --origin mac \\
      --path fs-tunnel='cmux wg dial --hub ~/.cmux/cmux-wg-TEAM.sock %h %p' \\
      --path tailnet= --path fs-ssh='ssh -W localhost:22 VMID+USER@PROXY' [--n 20] [--bulk-mb 64]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

SCHEMA = "braid-vs-fs-tunnel-run.v1"


def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))], 2)


def ssh_argv(target: str, proxy: str, extra: list[str]) -> list[str]:
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20"]
    if proxy:
        argv += ["-o", f"ProxyCommand={proxy}"]
    return argv + [target] + extra


def cold(target: str, proxy: str, n: int) -> tuple[list[float], int]:
    out, fails = [], 0
    for _ in range(n):
        t = time.monotonic()
        try:
            r = subprocess.run(ssh_argv(target, proxy, ["true"]), capture_output=True, timeout=60)
            ok = r.returncode == 0
        except subprocess.TimeoutExpired:
            ok = False
        if ok:
            out.append((time.monotonic() - t) * 1000)
        else:
            fails += 1
    return out, fails


def echo(target: str, proxy: str, n: int) -> tuple[list[float], int]:
    p = subprocess.Popen(ssh_argv(target, proxy, ["stty raw -echo 2>/dev/null; cat"]), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    out, fails = [], 0
    try:
        p.stdin.write(b"warm\n")
        p.stdout.readline()
        for i in range(n):
            line = f"k{i}\n".encode()
            t = time.monotonic()
            p.stdin.write(line)
            got = p.stdout.readline()
            if got == line:
                out.append((time.monotonic() - t) * 1000)
            else:
                fails += 1
            time.sleep(0.05)
    except (BrokenPipeError, OSError):
        fails += n - len(out)
    finally:
        p.kill()
    return out, fails


def bulk(target: str, proxy: str, mb: int) -> dict:
    res = {}
    for way, extra, stdin in (("up", ["cat >/dev/null"], True), ("down", [f"head -c {mb}M /dev/zero"], False)):
        t = time.monotonic()
        try:
            if stdin:
                src = subprocess.Popen(["head", "-c", f"{mb}M", "/dev/zero"], stdout=subprocess.PIPE)
                r = subprocess.run(ssh_argv(target, proxy, extra), stdin=src.stdout, capture_output=True, timeout=600)
                src.wait()
                ok = r.returncode == 0
            else:
                r = subprocess.run(ssh_argv(target, proxy, extra), stdout=subprocess.PIPE, timeout=600)
                ok = r.returncode == 0 and len(r.stdout) == mb * 1024 * 1024
        except subprocess.TimeoutExpired:
            ok = False
        dt = time.monotonic() - t
        res[way] = round(mb * 8 / dt, 2) if ok else None
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--target", required=True, help="USER@HOST as ssh sees it on every path")
    ap.add_argument("--origin", required=True, help="a label: mac, iphone-cell, lane-vm, coordinator")
    ap.add_argument("--path", action="append", default=[], help="NAME=PROXYCOMMAND ('' for none)")
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--bulk-mb", type=int, default=64)
    ap.add_argument("--out", help="also append the run line to this JSONL")
    a = ap.parse_args()
    if not a.path:
        ap.error("name at least one --path")
    run = {"schema": SCHEMA, "origin": a.origin, "n": a.n, "bulk_mb": a.bulk_mb,
           "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "paths": {}}
    for spec in a.path:
        name, _, proxy = spec.partition("=")
        proxy = os.path.expanduser(proxy)
        c, cf = cold(a.target, proxy, a.n)
        e, ef = echo(a.target, proxy, a.n)
        b = bulk(a.target, proxy, a.bulk_mb)
        run["paths"][name] = {
            "cold_ms": {"p50": pct(c, 50), "p95": pct(c, 95), "n": len(c), "fails": cf},
            "echo_ms": {"p50": pct(e, 50), "p95": pct(e, 95), "n": len(e), "fails": ef},
            "bulk_mbps": b,
        }
        print(f"{name}: cold {pct(c, 50)}/{pct(c, 95)} ms ({cf} failed), echo {pct(e, 50)}/{pct(e, 95)} ms"
              f" ({ef} failed), up {b['up']} down {b['down']} Mbit/s", file=sys.stderr)
    line = "BVT-RUN " + json.dumps(run, sort_keys=True)
    print(line)
    if a.out:
        with open(a.out, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    return 0 if all(p["cold_ms"]["fails"] == 0 for p in run["paths"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
