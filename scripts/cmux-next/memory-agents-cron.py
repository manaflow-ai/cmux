#!/usr/bin/env python3
"""The perf cron's memory-agents part (split-spring-terminal.py --suite=memory-agents): the app's idle memory, empty and
with idle agent chats open, as perf-cron rows (CMUX-571).

Leo, 2026-11-14: "all those perf things shouldve merged and been in a while ago... the other related goals should also
have been started and raised too". Goal ram-baseline checks the empty app's footprint, and goal memory-per-chat checks
what open chats cost against it. Until now the numbers came only from hand runs of scripts/measure/perf-10x-idle.sh
(its PERF-IDLE app-agents lines), which nothing stored.

This runs the same measurement perf-10x-idle.sh's agents step runs: scripts/cmux-next/bench_memory.py on the cron's
app, one idle chat per workspace on the acpmux test agent (its first turn answered). It writes report.json's `rows`
(perf-cron.py's budgets kind), each phys_footprint summed over every process of the app:
- memory.app_agents.empty.total_footprint_mb: the launch sample (bench_memory's idle-launch, no chat open);
- memory.app_agents.<N>.total_footprint_mb: N chats open and idle;
- memory.app_agents.ratio_vs_empty: the highest N's total / the empty total, both from this one run.
- memory.app_agents.idle_gpu_device_pct and .idle_disk_write_mb_per_h (goal idle-gpu-disk, idle_rows): the worst idle
  window's GPU Device Utilization % over the same Mac with no app open, and its disk bytes written per hour.
A count whose chats did not all open (fewer workspaces than asked, or a pane failure) gets no row and no ratio: a
partial sample is not that count's cost.

What the total counts (bench_memory.owned): every process whose command lies in the app bundle (the app, its Chromium
helpers, cmux-tui daemons and terminal hosts, acpmux and its helpers) and the WebKit processes the app is responsible
for. The chats' agent (fake_agent.py under the bench's own python, outside the bundle) is not in it, nor would a real
Claude Code or Codex CLI be. N counts the launch workspace: N=10 is 9 chat workspaces, each a chat and a terminal.

So every run also says where the memory is (report.json `breakdown`, and report-only rows under
memory.app_agents.breakdown., perf-cron.py REPORT_ONLY_ROW_RE): the footprint per process kind empty and at each full
count, each kind's cost per chat workspace ((N - empty) / (N - 1)), the largest processes, and the V8 heap of the renderers
that host cmux's pages, each renderer once, and the pages' live DOM nodes and decoded images per chat (bench_memory
--js-heap).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = "cmux-tui/crates/acpmux/tests/fake_agent.py"
TOTAL_FLOOR_MB = 50.0  # the empty app's launch-to-launch spread was 849-941 MB (ram-baseline, 2026-11-08)


def rows_from(report: dict) -> list[dict]:
    """perf-cron rows from bench_memory.py's report (pure)."""
    samples = [s for s in report.get("samples") or [] if isinstance(s, dict)]
    empty = next((s for s in samples if s.get("label") == "idle-launch"), None)
    total = (empty or {}).get("total_footprint_mb")
    if not isinstance(total, (int, float)) or total <= 0:
        return []
    rows = [{"name": "memory.app_agents.empty.total_footprint_mb", "p50": total, "p95": total, "unit": "MB",
             "floor": TOTAL_FLOOR_MB}]
    full = []
    for s in samples:
        label = str(s.get("label") or "")
        if not label.startswith("idle-") or label == "idle-launch":
            continue
        try:
            asked = int(label.split("-", 1)[1])
        except ValueError:
            continue
        value = s.get("total_footprint_mb")
        if s.get("workspaces") != asked or s.get("pane_failures") or not isinstance(value, (int, float)):
            continue
        rows.append({"name": f"memory.app_agents.{asked}.total_footprint_mb", "p50": value, "p95": value, "unit": "MB",
                     "floor": TOTAL_FLOOR_MB})
        full.append((asked, value))
    if full:
        asked, value = max(full)
        ratio = round(value / total, 3)
        rows.append({"name": "memory.app_agents.ratio_vs_empty", "p50": ratio, "p95": ratio, "unit": "x", "floor": 0.1,
                     "agents": asked})
    return rows


BREAKDOWN_PREFIX = "memory.app_agents.breakdown."
# Goal idle-gpu-disk (cmuxterm-hq goals/idle-gpu-disk.md): the same idle windows' GPU and disk writes.
GPU_ROW = "memory.app_agents.idle_gpu_device_pct"
DISK_ROW = "memory.app_agents.idle_disk_write_mb_per_h"
GPU_FLOOR_PCT = 1.0  # ioreg's Device Utilization % is a whole number: one step of it is noise, not a regression
DISK_FLOOR_MB_PER_H = 1.0  # the goal's own line: below it a change is not one a person's disk sees


def idle_rows(report: dict) -> list[dict]:
    """Goal idle-gpu-disk's rows from bench_memory.py's report (pure), the worst idle window of the run (the empty
    app and each count whose chats all opened):
    - GPU_ROW: the Mac's GPU Device Utilization % over the window (ioreg, whole Mac) minus the same Mac's with no app
      open (bench_memory's gpu_no_app, measured just before the launch), at least 0. No baseline, no row: a whole-Mac
      reading alone would count whatever else the Mac draws.
    - DISK_ROW: bytes the app's processes wrote to the storage device (proc_pid_rusage ri_diskio_byteswritten, every
      process bench_memory.owned counts) over the window, as MB per hour.
    The raw GPU reading and the baseline are report-only breakdown rows beside them."""
    samples = [s for s in report.get("samples") or [] if isinstance(s, dict) and s.get("measure_s")]
    windows = []
    for s in samples:
        label = str(s.get("label") or "")
        if label == "idle-launch":
            windows.append(s)
            continue
        try:
            asked = int(label.split("-", 1)[1]) if label.startswith("idle-") else None
        except ValueError:
            asked = None
        if asked is not None and s.get("workspaces") == asked and not s.get("pane_failures"):
            windows.append(s)
    rows = []
    disks = []
    for s in windows:
        values = [k.get("disk_write_mb_per_h") for k in (s.get("kinds") or {}).values() if isinstance(k, dict)]
        values = [v for v in values if isinstance(v, (int, float))]
        if values:
            disks.append((round(sum(values), 2), s["label"]))
    if disks:
        value, label = max(disks)
        rows.append({"name": DISK_ROW, "p50": value, "p95": value, "unit": "MB/h", "floor": DISK_FLOOR_MB_PER_H,
                     "window": label})
    base = (report.get("gpu_no_app") or {}).get("device_utilization_pct")
    gpus = [((s.get("gpu") or {}).get("device_utilization_pct"), s["label"]) for s in windows]
    gpus = [(v, label) for v, label in gpus if isinstance(v, (int, float))]
    if gpus:
        raw, label = max(gpus)
        rows.append({"name": BREAKDOWN_PREFIX + "gpu_device_pct_raw", "p50": raw, "p95": raw, "unit": "pct",
                     "floor": GPU_FLOOR_PCT, "window": label})
        if isinstance(base, (int, float)):
            rows.append({"name": BREAKDOWN_PREFIX + "gpu_no_app_pct", "p50": base, "p95": base, "unit": "pct",
                         "floor": GPU_FLOOR_PCT})
            value = round(max(raw - base, 0.0), 2)
            rows.append({"name": GPU_ROW, "p50": value, "p95": value, "unit": "pct", "floor": GPU_FLOOR_PCT,
                         "window": label})
    return rows
KIND_FLOOR_MB = 1.0  # kinds under this at every sample fold into "other": a row each would only be noise


def row_key(name: str) -> str:
    """A process kind as a row name part: lowercase, [a-z0-9_-] only."""
    out = re.sub(r"[^a-z0-9_-]+", "_", str(name).lower()).strip("_")
    return out or "unknown"


def full_samples(report: dict) -> tuple[dict | None, list[tuple[int, dict]]]:
    """(the empty sample, [(N, sample)] for each count whose chats all opened), from bench_memory's report (pure)."""
    samples = [s for s in report.get("samples") or [] if isinstance(s, dict)]
    empty = next((s for s in samples if s.get("label") == "idle-launch"), None)
    full = []
    for s in samples:
        label = str(s.get("label") or "")
        if not label.startswith("idle-") or label == "idle-launch":
            continue
        try:
            asked = int(label.split("-", 1)[1])
        except ValueError:
            continue
        if s.get("workspaces") != asked or s.get("pane_failures") or not isinstance(s.get("total_footprint_mb"), (int, float)):
            continue
        full.append((asked, s))
    return empty, full


def kind_mb(sample: dict) -> dict[str, float]:
    out: dict[str, float] = {}
    for kind, entry in (sample.get("kinds") or {}).items():
        value = (entry or {}).get("footprint_mb") if isinstance(entry, dict) else None
        if isinstance(value, (int, float)):
            out[row_key(kind)] = round(out.get(row_key(kind), 0.0) + value, 1)
    return out


def folded(kinds: dict[str, float], keep: set[str]) -> dict[str, float]:
    out = {k: v for k, v in kinds.items() if k in keep}
    rest = round(sum(v for k, v in kinds.items() if k not in keep), 1)
    if rest:
        out["other"] = round(out.get("other", 0.0) + rest, 1)
    return out


def sample_view(sample: dict, keep: set[str], top: int = 8) -> dict:
    view = {"total_footprint_mb": sample.get("total_footprint_mb"), "kinds": folded(kind_mb(sample), keep),
            "counts": {row_key(k): (e or {}).get("count") for k, e in (sample.get("kinds") or {}).items() if isinstance(e, dict)},
            "top": [{"kind": p.get("kind"), "pid": p.get("pid"), "footprint_mb": p.get("footprint_mb")}
                    for p in (sample.get("processes") or [])[:top] if isinstance(p, dict)]}
    heap = sample.get("js_heap")
    if isinstance(heap, dict):
        view["js_heap"] = {k: heap[k] for k in ("pages", "hidden_pages", "renderers", "used_mb", "total_mb", "by_renderer", "by_path", "error", "error_count") if k in heap}
        dom = heap.get("dom")
        if isinstance(dom, dict):
            view["js_heap"]["dom"] = {k: dom[k] for k in ("pages", "hidden_pages", "nodes", "images", "decoded_images", "decoded_mb",
                                                          "per_hidden_page", "by_renderer", "error_count") if k in dom}
    return view


def breakdown_from(report: dict) -> tuple[dict, list[dict]]:
    """Where the memory is (pure): report.json's `breakdown` and its report-only rows. Per chat is each kind's growth
    from the empty app to the highest full count over that count's chat workspaces (N - 1: the launch workspace
    counts in N)."""
    empty, full = full_samples(report)
    if empty is None or not isinstance(empty.get("total_footprint_mb"), (int, float)):
        return {}, []
    samples = [empty] + [s for _, s in full]
    keep = {k for s in samples for k, v in kind_mb(s).items() if v >= KIND_FLOOR_MB}
    out = {"empty": sample_view(empty, keep)}
    rows = []

    def row(name, value, unit="MB"):
        rows.append({"name": BREAKDOWN_PREFIX + name, "p50": value, "p95": value, "unit": unit, "floor": TOTAL_FLOOR_MB})

    for kind, value in sorted(out["empty"]["kinds"].items()):
        row(f"empty.{kind}.footprint_mb", value)
    heap = out["empty"].get("js_heap") or {}
    if isinstance(heap.get("total_mb"), (int, float)) and heap.get("pages"):
        row("empty.js_heap_total_mb", heap["total_mb"])
    for asked, sample in full:
        view = out[str(asked)] = sample_view(sample, keep)
        for kind, value in sorted(view["kinds"].items()):
            row(f"{asked}.{kind}.footprint_mb", value)
        heap = view.get("js_heap") or {}
        if isinstance(heap.get("total_mb"), (int, float)) and heap.get("pages"):
            row(f"{asked}.js_heap_total_mb", heap["total_mb"])
    if full:
        asked, _ = max(full, key=lambda item: item[0])
        chats = asked - 1
        if chats > 0:
            high, low = out[str(asked)], out["empty"]
            per_chat = {k: round((high["kinds"].get(k, 0.0) - low["kinds"].get(k, 0.0)) / chats, 1)
                        for k in set(high["kinds"]) | set(low["kinds"])}
            per_chat = dict(sorted(per_chat.items(), key=lambda item: -item[1]))
            total = round((high["total_footprint_mb"] - low["total_footprint_mb"]) / chats, 1)
            out["per_chat"] = {"chats": chats, "total_mb": total, "kinds": per_chat}
            row("per_chat.total_mb", total)
            for kind, value in per_chat.items():
                row(f"per_chat.{kind}.footprint_mb", value)
            heaps = (high.get("js_heap") or {}, low.get("js_heap") or {})
            if all(isinstance(h.get("total_mb"), (int, float)) and h.get("pages") for h in heaps):
                value = round((heaps[0]["total_mb"] - heaps[1]["total_mb"]) / chats, 1)
                out["per_chat"]["js_heap_total_mb"] = value
                row("per_chat.js_heap_total_mb", value)
            # DOM per idle chat: the growth of every cmux page's live DOM nodes and decoded images (bench_memory
            # js_heap.dom), only when both samples read every page.
            doms = [(h.get("js_heap") or {}).get("dom") or {} for h in (high, low)]
            if all(d.get("pages") and not d.get("error_count") for d in doms):
                for key, unit in (("nodes", "count"), ("decoded_images", "count"), ("decoded_mb", "MB")):
                    value = round((doms[0].get(key, 0) - doms[1].get(key, 0)) / chats, 1)
                    out["per_chat"][f"dom_{key}"] = value
                    row(f"per_chat.dom_{key}", value, unit)
    return out, rows


def bench_cmd(args: argparse.Namespace, raw: str) -> list[str]:
    """bench_memory.py's command for this part (pure). The empty app process's own split (--app-vm) is on unless
    --no-app-vm: the app process is the largest kind of the empty app (ram-baseline, CMUX-571), and only a stored
    vmmap says which of its regions grew."""
    cmd = [sys.executable, os.path.join(HERE, "bench_memory.py"), "--app", args.app, "--workspaces", args.agents,
           "--mix", "terminal+chat", "--fake-agent", os.path.join(ROOT, FAKE_AGENT), "--settle", args.settle,
           "--measure", args.measure, "--top", "8", "--js-heap", "--gpu", "--out", raw]
    if not args.no_app_vm or args.app_vm_stacks:
        cmd.append("--app-vm")
    if args.app_vm_stacks:
        cmd += ["--app-vm-stacks", args.app_vm_stacks]
    return cmd


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder (bench_memory's own report goes there)")
    parser.add_argument("--agents", default="10", help="agent chat counts, e.g. 10 or 10,20")
    parser.add_argument("--settle", default="20")
    parser.add_argument("--measure", default="30")
    parser.add_argument("--no-app-vm", action="store_true",
                        help="skip bench_memory --app-vm (by default every run stores the empty app process's vmmap "
                             "summary, footprint and heap in report.json app_vm)")
    parser.add_argument("--app-vm-stacks", metavar="PATTERN", help="bench_memory --app-vm-stacks (a diagnostic run)")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    out_dir = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out_dir, exist_ok=True)
    raw = os.path.join(out_dir, "memory-agents.json")
    cmd = bench_cmd(args, raw)
    status = subprocess.run(cmd, cwd=ROOT).returncode
    try:
        with open(raw) as f:
            report = json.load(f)
    except (OSError, ValueError):
        report = {}
    rows = rows_from(report)
    breakdown, breakdown_rows = breakdown_from(report)
    rows += idle_rows(report)
    out = {"rows": rows + breakdown_rows, "agents": args.agents, "bench_status": status}
    if report.get("gpu_no_app"):
        out["gpu_no_app"] = report["gpu_no_app"]
    if breakdown:
        out["breakdown"] = breakdown
    empty = next((s for s in report.get("samples") or [] if isinstance(s, dict) and s.get("label") == "idle-launch"), {})
    if empty.get("app_vm"):
        out["app_vm"] = empty["app_vm"]
    # perf-cron.py: an incomplete report keeps its rows for diagnostics but is no done part (incomplete_why names it).
    missing = [] if any(r["name"].endswith(".empty.total_footprint_mb") for r in rows) else \
        [f"no empty-app sample (bench_memory.py exit {status})"]
    for n in sorted({int(x) for x in args.agents.split(",") if x.strip().isdigit()}):
        if not any(r["name"] == f"memory.app_agents.{n}.total_footprint_mb" for r in rows):
            missing.append(f"agents {n}: not every chat opened (or no sample)")
    if missing:
        out["incomplete"] = missing
    with open(args.json, "w") as f:
        json.dump(out, f, indent=1)
    for r in rows:
        print(f"memory-agents: {r['name']} = {r['p95']} {r['unit']}")
    per_chat = breakdown.get("per_chat") or {}
    if per_chat:
        print(f"memory-agents: per chat workspace ({per_chat['chats']} chats) {per_chat['total_mb']} MB: "
              + ", ".join(f"{k} {v}" for k, v in per_chat["kinds"].items()))
    return status or (1 if missing else 0)


if __name__ == "__main__":
    raise SystemExit(main())
