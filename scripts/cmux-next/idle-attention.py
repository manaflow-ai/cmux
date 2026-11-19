#!/usr/bin/env python3
"""Idle cost of how waiting tabs and sidebar rows look (`notifications.attention.mark`: badge or glow; Leo
2026-11-19 asked for idle CPU and GPU numbers for the glow), on one fleet Mac, one app build, in one run
(split-spring-terminal.py --suite=idle-attention; registered as `cmux-bench idle_attention`).

Each arm launches the app fresh with a scratch HOME (scripts/cmux-next/bench_memory.py --waiting): --waiting
workspaces, every one but the launch one a terminal that posted a notification (unread, waiting), plus
--waiting-tabs unselected unread tabs in the launch workspace, the launch workspace shown, the window idle. Then
--measure seconds of: the app's processes' CPU % and wakeups/s (proc_pid_rusage), WindowServer's CPU % (Core
Animation composites the glow's render-server animation there), and the GPU's device, renderer and tiler
utilization (ioreg IOAccelerator, whole Mac). Arms:
  badge      the default look;
  glow       notifications.attention.mark = glow, then the same window minimized (minimized-N: the breath stops);
  base       with --base-sha: that commit's app (built here with scripts/measure/app-at-commit.sh), default look.
Arms interleave (badge, glow, base, badge, glow, base, ...) for --reps rounds; the summary is each arm's median.

Prints one IDLE-ATTN line per arm, round and sample, and IDLE-ATTN-MEDIAN lines; writes --json (report.json:
runs, medians, host) and packs it with every bench_memory log and window image into <out>/idle-attention.tgz.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
GLOW = {"notifications": {"attention": {"mark": "glow"}}}
METRICS = ("app_cpu_pct", "app_wakeups_per_s", "total_cpu_pct", "windowserver_cpu_pct", "gpu_device_pct",
           "gpu_renderer_pct", "gpu_tiler_pct")


def metrics_of(sample: dict) -> dict:
    """One bench_memory sample's numbers for the table (pure)."""
    kinds = sample.get("kinds") or {}
    app = kinds.get("app") or {}
    gpu = sample.get("gpu") or {}
    server = sample.get("windowserver") or {}
    return {"app_cpu_pct": app.get("cpu_pct"), "app_wakeups_per_s": app.get("wakeups_per_s"),
            "total_cpu_pct": round(sum((k or {}).get("cpu_pct") or 0 for k in kinds.values()), 3),
            "windowserver_cpu_pct": server.get("cpu_pct"),
            "gpu_device_pct": gpu.get("device_utilization_pct"), "gpu_renderer_pct": gpu.get("renderer_utilization_pct"),
            "gpu_tiler_pct": gpu.get("tiler_utilization_pct")}


def medians(runs: list[dict]) -> dict:
    """{arm/sample: {metric: median}} over every round (pure)."""
    groups: dict[str, list[dict]] = {}
    for run in runs:
        groups.setdefault(f"{run['arm']}/{run['sample']}", []).append(run["metrics"])
    out = {}
    for key, rows in groups.items():
        out[key] = {"n": len(rows)}
        for metric in METRICS:
            values = [r[metric] for r in rows if isinstance(r.get(metric), (int, float))]
            out[key][metric] = round(statistics.median(values), 3) if values else None
    return out


def build_base(sha: str, out: str) -> str:
    """The app of `sha` (bench config), through app-at-commit.sh's measure_app_at_commit."""
    tree = os.path.join(out, "base-tree")
    script = (f'source scripts/measure/app-at-commit.sh && measure_app_at_commit "$1" idleattnbase "$2" --config bench')
    got = subprocess.run(["bash", "-c", script, "build-base", sha, tree], cwd=ROOT, capture_output=True, text=True)
    with open(os.path.join(out, "base-build.log"), "w") as handle:
        handle.write(got.stderr[-200000:])
    app = got.stdout.strip().splitlines()[-1] if got.stdout.strip() else ""
    if got.returncode != 0 or not os.path.isdir(app):
        sys.stderr.write(got.stderr[-4000:])
        raise SystemExit(f"idle-attention: the base app at {sha} did not build (exit {got.returncode})")
    return app


def run_arm(app: str, arm: str, round_index: int, args, out: str) -> list[dict]:
    raw = os.path.join(out, f"{arm}-{round_index}.json")
    log = os.path.join(out, f"{arm}-{round_index}.log")
    cmd = [sys.executable, os.path.join(HERE, "bench_memory.py"), "--app", app, "--waiting", str(args.waiting),
           "--waiting-tabs", str(args.waiting_tabs), "--settle", str(args.settle), "--measure", str(args.measure),
           "--gpu", "--windowserver", "--top", "6", "--snapshot-dir", os.path.join(out, f"shots-{arm}-{round_index}"),
           "--config", json.dumps(GLOW if arm == "glow" else {}), "--out", raw]
    if arm == "glow":
        cmd.append("--waiting-minimize")
    with open(log, "w") as handle:
        status = subprocess.run(cmd, stdout=handle, stderr=subprocess.STDOUT).returncode
    if status != 0 or not os.path.exists(raw):
        print(f"IDLE-ATTN-FAIL arm={arm} round={round_index} exit={status} log={os.path.basename(log)}", flush=True)
        with open(log) as handle:
            print("".join(handle.readlines()[-30:]), flush=True)
        return []
    with open(raw) as handle:
        report = json.load(handle)
    runs = []
    for sample in report.get("samples") or []:
        row = {"arm": arm, "round": round_index, "sample": str(sample.get("label", "?")).split("-")[0],
               "metrics": metrics_of(sample), "window": (sample.get("waiting_state") or {}).get("window"),
               "unread": (sample.get("waiting_state") or {}).get("unread"), "waiting": report.get("waiting")}
        runs.append(row)
        print(f"IDLE-ATTN arm={arm} round={round_index} sample={row['sample']} "
              + " ".join(f"{k}={v}" for k, v in row["metrics"].items())
              + f" window={json.dumps(row['window'], separators=(',', ':'))} unread={json.dumps(row['unread'], separators=(',', ':'))}",
              flush=True)
    return runs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--tag", default="")
    parser.add_argument("--waiting", type=int, default=10)
    parser.add_argument("--waiting-tabs", type=int, default=3)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--reps", type=int, default=2)
    parser.add_argument("--arms", default="badge,glow")
    parser.add_argument("--base-sha", default="", help="also the base arm: this commit's app, default look")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    arms = [a for a in args.arms.split(",") if a]
    apps = {arm: args.app for arm in arms}
    if args.base_sha:
        try:
            apps["base"] = build_base(args.base_sha, args.out)
            arms.append("base")
        except SystemExit as error:  # the head's arms still measure; the base arm is reported as missing
            print(f"IDLE-ATTN-FAIL arm=base {error}", flush=True)
    host = {"host": platform.node(), "macos": platform.mac_ver()[0],
            "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
            "chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
            "sha": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()}
    print(f"IDLE-ATTN-MACHINE {json.dumps(host)}", flush=True)
    runs = []
    for round_index in range(1, args.reps + 1):
        for arm in arms:
            runs += run_arm(apps[arm], arm, round_index, args, args.out)
    summary = medians(runs)
    for key, row in sorted(summary.items()):
        print(f"IDLE-ATTN-MEDIAN {key} " + " ".join(f"{k}={v}" for k, v in row.items()), flush=True)
    report = {"host": host, "args": vars(args), "runs": runs, "medians": summary}
    with open(args.json, "w") as handle:
        json.dump(report, handle, indent=2)
    with tarfile.open(os.path.join(args.out, "idle-attention.tgz"), "w:gz") as tar:
        tar.add(args.json, arcname="report.json")
        for name in sorted(os.listdir(args.out)):
            path = os.path.join(args.out, name)
            if name.endswith((".log", ".json")) or name.startswith("shots-"):
                tar.add(path, arcname=name)
    expected = {f"{a}/waiting" for a in arms}
    return 0 if expected <= set(summary) else 1


if __name__ == "__main__":
    sys.exit(main())
