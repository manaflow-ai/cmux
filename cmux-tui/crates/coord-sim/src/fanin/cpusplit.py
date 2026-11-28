#!/usr/bin/env python3
"""The fan-in box's CPU by role, once a second (ci.sh with FANIN_CPUSPLIT=1).

usage: cpusplit.py ACPMUX_BIN SIM_BIN TOP_N OUT_NDJSON SECONDS

Every process on the box is put in one role: `controller` (acpmux whose environment names the
`nTOP/controller` home), `host` (any other acpmux daemon), `agent` (`coord-sim fanin agent`),
`driver` (the other coord-sim), or `other`. Each second it writes one line: the jiffies each role
spent in user and kernel mode, the processes in it, and the box's own idle/total jiffies from
/proc/stat. At the end it prints the role shares over the whole run and over the 10 busiest
seconds (a fan-out round saturates the box for ~2 s at n=2000; which role burns it is the
question: cmux#51785, goal sessions-2000-attached).
"""
import json
import os
import sys
import time

BIN, SIM, TOP, OUT, SECONDS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
ROLES = ("controller", "host", "agent", "driver", "other")
roles = {}  # pid -> role (a pid's role does not change while it lives)


def role_of(pid):
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
    except OSError:
        return None
    exe = cmd[0].decode(errors="replace") if cmd else ""
    if exe == BIN:
        try:
            env = open(f"/proc/{pid}/environ", "rb").read()
        except OSError:
            return "host"
        return "controller" if f"n{TOP}/controller".encode() in env else "host"
    if exe == SIM:
        return "agent" if b"agent" in cmd[1:3] else "driver"
    return "other"


def box():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    return v[3] + v[4], sum(v)  # idle + iowait, total


def sample():
    per = {r: [0, 0, 0] for r in ROLES}  # utime, stime, procs
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        r = roles.get(pid)
        if r is None:
            r = role_of(pid)
            if r is None:
                continue
            roles[pid] = r
        try:
            s = open(f"/proc/{pid}/stat").read()
        except OSError:
            continue
        f = s[s.rindex(")") + 2:].split()
        per[r][0] += int(f[11])
        per[r][1] += int(f[12])
        per[r][2] += 1
    return per


def main():
    rows = []
    prev, prev_box = sample(), box()
    with open(OUT, "w") as out:
        try:
            loop(out, rows, prev, prev_box)
        except KeyboardInterrupt:  # ci.sh stops it with SIGINT once the ramps end
            pass
    # Only the seconds the largest ramp's controller ran (earlier ramps share the agent binary).
    report([r for r in rows if r["controller"]["procs"]])


def loop(out, rows, prev, prev_box):
    for _ in range(SECONDS):
        time.sleep(1)
        cur, cur_box = sample(), box()
        idle, total = cur_box[0] - prev_box[0], cur_box[1] - prev_box[1]
        # A role's delta can go negative when a process exits; clamp (exits are rare mid-window).
        row = {"t": round(time.time(), 1), "box_total": total, "box_idle": idle,
               **{r: {"u": max(0, cur[r][0] - prev[r][0]), "s": max(0, cur[r][1] - prev[r][1]),
                      "procs": cur[r][2]} for r in ROLES}}
        out.write(json.dumps(row) + "\n")
        out.flush()
        rows.append(row)
        prev, prev_box = cur, cur_box


def report(rows):
    rows = [r for r in rows if r["box_total"] > 0]
    if not rows:
        print("FANIN cpusplit: no samples")
        return

    def share(sel, label):
        tot = sum(r["box_total"] for r in sel) or 1
        idle = sum(r["box_idle"] for r in sel)
        parts = ", ".join(
            "%s %.0f%% (u %.0f s %.0f)" % (
                k, 100 * sum(r[k]["u"] + r[k]["s"] for r in sel) / tot,
                100 * sum(r[k]["u"] for r in sel) / tot, 100 * sum(r[k]["s"] for r in sel) / tot)
            for k in ROLES)
        print("FANIN cpusplit %s (%d s): idle %.0f%%; %s" % (label, len(sel), 100 * idle / tot, parts))

    share(rows, "all")
    busy = sorted(rows, key=lambda r: r["box_idle"] / r["box_total"])[:10]
    share(busy, "busiest")
    procs = {k: max(r[k]["procs"] for r in rows) for k in ROLES}
    print("FANIN cpusplit procs (max): %s" % json.dumps(procs))


if __name__ == "__main__":
    main()
