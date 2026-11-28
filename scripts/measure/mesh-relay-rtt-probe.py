#!/usr/bin/env python3
"""Round trip to a mesh-hop relay's /healthz, from this host (RFD 0060 slice 3; companion of relay-path-probe.sh).

  scripts/measure/mesh-relay-rtt-probe.py https://RELAY_HOST/healthz [WARM_N] [NEW_N]
  (the URL may come from MESH_RELAY_URL instead; any host with curl; on a fleet host: `cmux-ci run`)

Two numbers, in ms, as n, p50, p95 and max:
  warm: the request's own time (time_starttransfer - time_pretransfer) over ONE kept-alive connection, which is the
    relay round trip a mesh client sees once its link is up (RFD target: p95 < 100 ms; 1,056 ms through the home relay).
  new-connection: TCP + TLS + request on a fresh connection each time.
This is curl to /healthz, not a mesh client: no tool times a real client's hop yet. Prints MESH-RELAY-RTT lines.
"""
import os
import statistics
import subprocess
import sys

URL = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MESH_RELAY_URL", "")
if not URL:
    sys.exit("usage: mesh-relay-rtt-probe.py https://RELAY_HOST/healthz [WARM_N] [NEW_N]  (or MESH_RELAY_URL)")
WARM_N = int(sys.argv[2]) if len(sys.argv) > 2 else 60
NEW_N = int(sys.argv[3]) if len(sys.argv) > 3 else 50


def warm(n):
    # One curl process, n+1 transfers on one connection; the first pays the handshake and is dropped.
    args = ["curl", "-sS", "-m", "60"]
    fmt = "%{time_starttransfer} %{time_appconnect} %{time_pretransfer} %{http_code}\n"
    for _ in range(n + 1):
        args += ["-o", "/dev/null", "-w", fmt, URL]
    out = subprocess.run(args, capture_output=True, text=True).stdout.split("\n")
    vals = []
    for line in out[1 : n + 1]:
        f = line.split()
        if len(f) == 4 and f[3] == "200":
            vals.append((float(f[0]) - float(f[2])) * 1000)
    return vals


def fresh(n):
    vals = []
    for _ in range(n):
        f = subprocess.run(
            ["curl", "-sS", "-m", "10", "-o", "/dev/null", "-w", "%{time_starttransfer} %{http_code}", URL],
            capture_output=True,
            text=True,
        ).stdout.split()
        if len(f) == 2 and f[1] == "200":
            vals.append(float(f[0]) * 1000)
    return vals


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(q * (len(v) - 1))))]


for name, vals in (("warm", warm(WARM_N)), ("new-connection", fresh(NEW_N))):
    if not vals:
        print(f"MESH-RELAY-RTT {name}: no 200 answers")
        sys.exit(1)
    print(
        f"MESH-RELAY-RTT {name}: n={len(vals)} p50={statistics.median(vals):.1f}ms "
        f"p95={pct(vals, .95):.1f}ms max={max(vals):.1f}ms"
    )
