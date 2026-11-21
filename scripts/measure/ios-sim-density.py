#!/usr/bin/env python3
"""Driver for ios-sim-density.sh: N cloned simulators at once, per count N.

One base iPhone is created and booted once (its first boot does the data
migration every fresh device pays), then shut down. For each count N:
clone N devices from it, boot them together, then run the suites on all N at
once `rounds` times (xcodebuild test-without-building on the booted clones, as
a pool of pre-booted devices reused across jobs would), then delete them. A
sampler reads the host every 5 s.

Prints, one line each (ingested by a bench; field names are stable):

  IOS-SIM-DENSITY-MACHINE host=.. chip=.. cores=.. mem_gib=.. macos=.. xcode=.. runtime=..
  IOS-SIM-DENSITY-BOOT how=create|clone n=N seconds=..        (create+boot vs clone+boot, to booted)
  IOS-SIM-DENSITY-JOB n=N round=R sim=I seconds=.. exit=.. tests=.. failures=..
  IOS-SIM-DENSITY n=N jobs=.. wall_p50_s=.. wall_max_s=.. jobs_per_hour=.. failed_jobs=..
      failed_tests=.. mem_used_gib_p50=.. mem_used_gib_max=.. mem_per_sim_gib=.. cpu_pct_p50=..
      cpu_pct_max=.. swap_growth_gib=.. pressure_max=.. disk_mb_s_p50=.. sim_rss_gib_max=..
  IOS-SIM-DENSITY-STOP n=N why=..                              (the sweep stopped before this count)

mem_per_sim_gib is the host's peak memory in use above its idle reading, per simulator job (the simulator,
its app and its xcodebuild together): what an admission rule charges one more job.

and writes report.json with every sample, job and failed test name.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import threading
import time
from pathlib import Path

EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
FAILED_CASE = re.compile(r"Test [Cc]ase '-\[(\S+) (\S+)\]' failed|Test case '(\S+?)\(\)' failed")


def sh(*cmd: str, check: bool = True, timeout: float | None = None) -> str:
    return subprocess.run(cmd, check=check, text=True, capture_output=True, timeout=timeout).stdout.strip()


def sysctl(name: str) -> str:
    return sh("sysctl", "-n", name, check=False)


def mem_used_gib() -> float:
    """Active + wired + compressed pages, as the fleet worker's telemetry counts used memory."""
    text = sh("vm_stat", check=False)
    page = int(re.search(r"page size of (\d+)", text).group(1)) if "page size of" in text else 16384
    def pages(label: str) -> int:
        m = re.search(rf"{label}:\s+(\d+)", text)
        return int(m.group(1)) if m else 0
    used = pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")
    return used * page / 2**30


def swap_used_gib() -> float:
    m = re.search(r"used = ([\d.]+)M", sysctl("vm.swapusage"))
    return float(m.group(1)) / 1024 if m else 0.0


def disk_mb() -> float:
    """Cumulative MB transferred on every disk (iostat -I), for a rate between two samples."""
    lines = sh("iostat", "-Id", "-c", "1", check=False).splitlines()
    if len(lines) < 3:
        return 0.0
    vals = lines[-1].split()
    return sum(float(v) for v in vals[2::3]) if vals else 0.0  # KB/t tps MB per disk


def sim_rss_gib(udids: list[str]) -> float:
    """Resident memory of every process under the given simulators' launchd_sim (their data dirs name the UDID)."""
    rows = sh("ps", "-axo", "pid=,ppid=,rss=,command=", check=False).splitlines()
    procs = {}
    for r in rows:
        parts = r.split(None, 3)
        if len(parts) == 4:
            procs[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    roots = {pid for pid, (_, _, cmd) in procs.items() if "launchd_sim" in cmd and any(u in cmd for u in udids)}
    total, seen, stack = 0, set(), list(roots)
    children: dict[int, list[int]] = {}
    for pid, (ppid, _, _) in procs.items():
        children.setdefault(ppid, []).append(pid)
    while stack:
        pid = stack.pop()
        if pid in seen or pid not in procs:
            continue
        seen.add(pid)
        total += procs[pid][1]
        stack.extend(children.get(pid, []))
    return total / 2**20


class Sampler(threading.Thread):
    def __init__(self, every: float = 5.0):
        super().__init__(daemon=True)
        self.every, self.samples, self.stop_at = every, [], threading.Event()
        self.n, self.udids = 0, []
        self.cores = os.cpu_count() or 1

    def run(self) -> None:
        last_disk, last_t = disk_mb(), time.time()
        while not self.stop_at.wait(self.every):
            cpu = sum(float(x) for x in sh("ps", "-A", "-o", "%cpu=", check=False).split() if x.replace(".", "", 1).isdigit())
            d, t = disk_mb(), time.time()
            self.samples.append({
                "t": round(t, 1), "n": self.n,
                "mem_used_gib": round(mem_used_gib(), 2), "swap_gib": round(swap_used_gib(), 2),
                "pressure": int(sysctl("kern.memorystatus_vm_pressure_level") or 0),
                "cpu_pct": round(min(100.0, cpu / self.cores), 1),
                "disk_mb_s": round(max(0.0, d - last_disk) / max(t - last_t, 0.1), 1),
                "sim_rss_gib": round(sim_rss_gib(self.udids), 2) if self.udids else 0.0,
            })
            last_disk, last_t = d, t


def boot(udids: list[str]) -> float:
    t = time.time()
    for u in udids:
        sh("xcrun", "simctl", "boot", u)
    procs = [subprocess.Popen(["xcrun", "simctl", "bootstatus", u, "-b"], stdout=subprocess.DEVNULL) for u in udids]
    for p in procs:
        p.wait(timeout=600)
    return time.time() - t


def delete(udids: list[str]) -> None:
    for u in udids:
        subprocess.run(["xcrun", "simctl", "shutdown", u], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", u], capture_output=True)


def q(xs: list[float], p: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--xctestrun", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--device-type", required=True)
    ap.add_argument("--counts", required=True)
    ap.add_argument("--rounds", type=int, required=True)
    ap.add_argument("--suites", required=True)
    ap.add_argument("--stop-on-pressure", type=int, default=1)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    only = [f"-only-testing:CmuxMobileAppUITests/{s}" for s in a.suites.split(",")]
    counts = [int(c) for c in a.counts.split(",")]
    machine = {
        "host": sh("hostname", "-s"), "chip": sysctl("machdep.cpu.brand_string").replace(" ", "_"),
        "cores": os.cpu_count(), "mem_gib": round(int(sysctl("hw.memsize")) / 2**30),
        "macos": sh("sw_vers", "-productVersion"), "xcode": sh("xcodebuild", "-version").splitlines()[0].replace(" ", "_"),
        "runtime": a.runtime.rsplit(".", 1)[-1], "device": a.device_type.rsplit(".", 1)[-1],
    }
    print("IOS-SIM-DENSITY-MACHINE " + " ".join(f"{k}={v}" for k, v in machine.items()), flush=True)
    report = {"machine": machine, "suites": a.suites, "rounds": a.rounds, "boots": [], "counts": [], "jobs": [], "samples": []}
    made: list[str] = []
    sampler = Sampler()
    sampler.start()
    try:
        idle = mem_used_gib()
        report["idle_mem_used_gib"] = round(idle, 2)
        # The control: a fresh device to booted, as every simulator step pays today.
        t = time.time()
        base = sh("xcrun", "simctl", "create", f"{a.prefix}-base", a.device_type, a.runtime)
        made.append(base)
        create_boot = time.time() - t + boot([base])
        print(f"IOS-SIM-DENSITY-BOOT how=create n=1 seconds={create_boot:.1f}", flush=True)
        report["boots"].append({"how": "create", "n": 1, "seconds": round(create_boot, 1)})
        sh("xcrun", "simctl", "shutdown", base)
        for n in counts:
            t = time.time()
            clones = [sh("xcrun", "simctl", "clone", base, f"{a.prefix}-{n}-{i}") for i in range(n)]
            made.extend(clones)
            clone_boot = time.time() - t + boot(clones)
            print(f"IOS-SIM-DENSITY-BOOT how=clone n={n} seconds={clone_boot:.1f}", flush=True)
            report["boots"].append({"how": "clone", "n": n, "seconds": round(clone_boot, 1)})
            sampler.n, sampler.udids = n, clones
            first = len(sampler.samples)
            swap0 = swap_used_gib()
            walls, failed_jobs, failed_tests, round_secs = [], 0, [], []
            for r in range(1, a.rounds + 1):
                procs, starts = [], time.time()
                for i, u in enumerate(clones):
                    log = out / f"job-{n}-{r}-{i}.log"
                    cmd = ["xcodebuild", "test-without-building", "-xctestrun", a.xctestrun,
                           "-destination", f"id={u}", "-resultBundlePath", str(out / "work" / f"r-{n}-{r}-{i}.xcresult"),
                           "-parallel-testing-enabled", "NO", *only]
                    procs.append((i, time.time(), log, subprocess.Popen(cmd, stdout=log.open("w"), stderr=subprocess.STDOUT)))
                for i, t0, log, p in procs:
                    rc = p.wait()
                    secs = time.time() - t0
                    text = log.read_text(errors="replace")
                    ex = EXECUTED.findall(text)
                    tests, fails = (int(ex[-1][0]), int(ex[-1][1])) if ex else (0, 0)
                    names = sorted({(m[0] + "." + m[1]) if m[0] else m[2] for m in FAILED_CASE.findall(text)})
                    walls.append(secs)
                    failed_jobs += rc != 0
                    failed_tests += names
                    job = {"n": n, "round": r, "sim": i, "seconds": round(secs, 1), "exit": rc, "tests": tests,
                           "failures": fails, "failed": names}
                    report["jobs"].append(job)
                    print(f"IOS-SIM-DENSITY-JOB n={n} round={r} sim={i} seconds={secs:.1f} exit={rc} tests={tests} failures={fails}", flush=True)
                round_secs.append(time.time() - starts)
            s = [x for x in sampler.samples[first:] if x["n"] == n]
            row = {
                "n": n, "jobs": len(walls), "wall_p50_s": round(q(walls, .5), 1), "wall_max_s": round(max(walls), 1),
                "jobs_per_hour": round(len(walls) / sum(round_secs) * 3600, 1),
                "failed_jobs": failed_jobs, "failed_tests": len(failed_tests),
                "mem_used_gib_p50": round(q([x["mem_used_gib"] for x in s], .5), 1),
                "mem_used_gib_max": round(max((x["mem_used_gib"] for x in s), default=0), 1),
                "mem_per_sim_gib": round((max((x["mem_used_gib"] for x in s), default=idle) - idle) / n, 2),
                "cpu_pct_p50": round(q([x["cpu_pct"] for x in s], .5)), "cpu_pct_max": round(max((x["cpu_pct"] for x in s), default=0)),
                "swap_growth_gib": round(swap_used_gib() - swap0, 2),
                "pressure_max": max((x["pressure"] for x in s), default=0),
                "disk_mb_s_p50": round(q([x["disk_mb_s"] for x in s], .5), 1),
                "sim_rss_gib_max": round(max((x["sim_rss_gib"] for x in s), default=0), 2),
            }
            row["failed_test_names"] = sorted(set(failed_tests))
            report["counts"].append(row)
            print("IOS-SIM-DENSITY " + " ".join(f"{k}={v}" for k, v in row.items() if k != "failed_test_names"), flush=True)
            sampler.n, sampler.udids = 0, []
            delete(clones)
            made = [u for u in made if u not in clones]
            (out / "report.json").write_text(json.dumps(report | {"samples": sampler.samples}, indent=1))
            # The same rule as the fleet worker's memory pressure guard (hq build-fleet cmd/worker
            # mem_pressure.go): macOS says warn or critical, or swap grew by 1 GiB.
            nxt = [c for c in counts if c > n]
            if a.stop_on_pressure and nxt and (row["pressure_max"] >= 2 or row["swap_growth_gib"] > 1.0):
                why = f"pressure_{row['pressure_max']}_swap_growth_{row['swap_growth_gib']}GiB_at_n{n}"
                print(f"IOS-SIM-DENSITY-STOP n={nxt[0]} why={why}", flush=True)
                report["stopped"] = {"before": nxt[0], "why": why}
                break
    finally:
        sampler.stop_at.set()
        delete(made)
        report["samples"] = sampler.samples
        (out / "report.json").write_text(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
