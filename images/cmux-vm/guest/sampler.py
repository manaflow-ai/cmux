#!/usr/bin/env python3
# cmux VM image idle sampler (images/cmux-vm/smoke.ts). `sampler.py snap <out.json>` records a snapshot of CPU and memory;
# `sampler.py diff <a.json> <b.json>` prints the window summary as JSON.
import json, os, sys, time

def proc_rows():
    rows = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                s = f.read()
            comm = s[s.index("(") + 1:s.rindex(")")]
            rest = s[s.rindex(")") + 2:].split()
            ppid = int(rest[1]); utime = int(rest[11]); stime = int(rest[12])
            kthread = ppid == 2 or int(pid) == 2
            user = None
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("Uid:"):
                        user = int(line.split()[1]); break
            pss = rss = 0
            if not kthread:
                try:
                    with open(f"/proc/{pid}/smaps_rollup") as f:
                        for line in f:
                            if line.startswith("Pss:"): pss = int(line.split()[1])
                            elif line.startswith("Rss:"): rss = int(line.split()[1])
                except OSError:
                    pass
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmd = f.read().replace(b"\0", b" ").decode(errors="replace")[:120]
            except OSError:
                cmd = ""
            rows[pid] = {"comm": comm, "ppid": ppid, "ticks": utime + stime, "kthread": kthread, "uid": user, "pss_kb": pss, "rss_kb": rss, "cmd": cmd}
        except (OSError, ValueError):
            continue
    return rows

def snap():
    with open("/proc/stat") as f:
        cpu = [int(x) for x in f.readline().split()[1:]]
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":"); mem[k] = int(v.split()[0])
    return {"t": time.time(), "uptime": float(open("/proc/uptime").read().split()[0]), "cpu": cpu, "mem": mem, "procs": proc_rows()}

def diff(a, b):
    el = b["t"] - a["t"]
    ca, cb = a["cpu"], b["cpu"]
    idle = lambda c: c[3] + c[4]
    busy = (sum(cb) - idle(cb)) - (sum(ca) - idle(ca))
    steal = cb[7] - ca[7] if len(cb) > 7 else 0
    hz = os.sysconf("SC_CLK_TCK")
    per = []
    for pid, r in b["procs"].items():
        t0 = a["procs"].get(pid, {}).get("ticks", 0) if a["procs"].get(pid, {}).get("comm") == r["comm"] else 0
        d = r["ticks"] - t0
        if d > 0:
            per.append((d, pid, r["comm"], r["cmd"][:80]))
    per.sort(reverse=True)
    user = [r for r in b["procs"].values() if not r["kthread"]]
    groups = {}
    for pid, r in b["procs"].items():
        if r["kthread"]: continue
        g = "postgres" if r["comm"].startswith("postgres") else ("desktop" if r["comm"] in ("Xtigervnc", "Xvnc", "openbox", "tint2", "vncconfig", "websockify", "at-spi-bus-laun", "at-spi2-registr", "dbus-daemon", "cmux-desktop-bo", "python3", "sleep") and r["uid"] == 1000 else ("cmux-tui" if r["comm"].startswith("cmux-tui") or r["comm"].startswith("__terminal") else None))
        if g:
            t0 = a["procs"].get(pid, {}).get("ticks", 0) if a["procs"].get(pid, {}).get("comm") == r["comm"] else 0
            x = groups.setdefault(g, {"procs": 0, "pss_kb": 0, "rss_kb": 0, "cpu_ticks": 0})
            x["procs"] += 1; x["pss_kb"] += r["pss_kb"]; x["rss_kb"] += r["rss_kb"]; x["cpu_ticks"] += r["ticks"] - t0
    for g in groups.values():
        g["cpu_s_per_min"] = round(g["cpu_ticks"] / hz / el * 60, 4)
    mb = b["mem"]
    return {
        "window_s": round(el, 1),
        "cpu_s_per_min_all_cpus": round(busy / hz / el * 60, 4),
        "steal_s_per_min": round(steal / hz / el * 60, 4),
        "mem_used_mb_total_minus_available": round((mb["MemTotal"] - mb["MemAvailable"]) / 1024, 1),
        "mem_anon_mb": round((mb.get("AnonPages", 0)) / 1024, 1),
        "mem_cached_mb": round(mb.get("Cached", 0) / 1024, 1),
        "sum_pss_mb_userland": round(sum(r["pss_kb"] for r in user) / 1024, 1),
        "sum_rss_mb_userland": round(sum(r["rss_kb"] for r in user) / 1024, 1),
        "procs_total": len(b["procs"]),
        "procs_userland": len(user),
        "top_cpu": [{"ticks": d, "pid": p, "comm": c, "cmd": m} for d, p, c, m in per[:12]],
        "top_pss": sorted(({"comm": r["comm"], "pss_mb": round(r["pss_kb"] / 1024, 1)} for r in user), key=lambda x: -x["pss_mb"])[:15],
        "groups": groups,
    }

if __name__ == "__main__":
    if sys.argv[1] == "snap":
        json.dump(snap(), open(sys.argv[2], "w"))
        print("snap-ok")
    else:
        print(json.dumps(diff(json.load(open(sys.argv[2])), json.load(open(sys.argv[3])))))
