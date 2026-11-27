#!/usr/bin/env python3
"""Where cmux-required-checks spends fleet machine minutes per merged PR (goal ci-min-per-pr-140).

cmux-required-checks submits two fleet ci-steps per PR head, both `scripts/ci/feat-parity-check.sh`:
`clippy-changed BASE` and `react-doctor BASE` (step_key `rc-<PR>-<sha12>-<mode>`). This script ranks their
minutes and, from a sample of step logs, says why a clippy-changed step costs what it does.

Jobs part (needs only the controller's job rows):
  - minutes per merged PR by mode, worker pool (cmux-linux-pool VM, pool-step-overflow, fss) and end state;
  - runs per PR head and per PR, and minutes on a (mode, source tree) that already had a green run;
  - minutes in cancelled runs and in runs over 60 min;
  - for clippy-changed on pool VMs, which run on its VM each one was (a pool VM is new for a few jobs, and each of
    its two warm cargo slots starts empty), the share that can have started from a kept slot.
Logs part (`--logs DIR`, files `<job id>.log`, the controller's `/v1/jobs/log?id=ID` text):
  - warm slot created or reused, and its size before and after the step;
  - sccache hits, misses and not-cacheable requests;
  - the three cargo passes (clippy --all-targets, panic ratchet on HEAD, panic ratchet on the base) and their
    times, and how often the base pass ran ("HEAD is over the baseline") with how many base-red rows.

Usage:
  fleet_required.py --jobs jobs.jsonl[.gz] --since 2026-11-26T22:00Z --until 2026-11-27T05:00Z --merged 783 \
      [--logs DIR] [--json]
Rows are the controller's /v1/jobs?all=1 objects, one per line (cmuxterm-hq build-fleet/data/ci_per_pr.py
fetch_fleet reads them). --merged is the merged-PR count of the window (ci_per_pr.py prints it).
"""
import argparse
import collections
import datetime
import gzip
import json
import os
import re
import statistics
import sys

SUBMITTER = "cmux-required-checks"
CARGO_FINISHED = re.compile(r"Finished `[^`]+` profile \[[^]]*\] target\(s\) in (?:(\d+)m )?([\d.]+)s")
SLOT = re.compile(r"warm checkout step-warm-cargo/slot-\d+: (created|reused) at \S+ in [\d.]+s, ([\d.]+) GiB kept")
SLOT_AFTER = re.compile(r"warm checkout step-warm-cargo/slot-\d+: ([\d.]+) GiB after the step")
SCCACHE = re.compile(r"shared rust cache: (\d+) hits, (\d+) misses, (\d+) not cacheable")


def ts(value):
    if not value or value.startswith("0001"):
        return None
    m = re.match(r"^(.*T\d\d:\d\d(?::\d\d)?)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", value)
    if not m:
        return None
    base = m.group(1) if m.group(1).count(":") == 2 else m.group(1) + ":00"
    frac = (m.group(2) or "")[:7]
    zone = m.group(3) or "Z"
    return datetime.datetime.fromisoformat(base + frac + ("+00:00" if zone == "Z" else zone)).timestamp()


def minutes(job):
    a, b = ts(job.get("started_at")), ts(job.get("updated_at"))
    return (b - a) / 60 if a and b and b > a else 0.0


def mode(job):
    return (job.get("args") or ["?"])[0]


def pool(job):
    worker = job.get("worker") or ""
    if worker.startswith("cmux-linux-pool-"):
        return "pool-vm"
    if worker == "pool-step-overflow":
        return "overflow"
    if worker.startswith("fss-"):
        return "fss"
    return worker or "?"


def read_jobs(path):
    opener = gzip.open if path.endswith(".gz") else open
    rows = {}
    with opener(path, "rt") as handle:
        for line in handle:
            if line.strip():
                job = json.loads(line)
                rows[job["id"]] = job
    return list(rows.values())


def jobs_part(jobs, since, until, merged):
    rc = [j for j in jobs if j.get("submitter") == SUBMITTER and j.get("state") in ("done", "failed", "cancelled")
          and (t := ts(j.get("updated_at"))) and since <= t < until]
    out = {"jobs": len(rc), "merged": merged}
    total = sum(minutes(j) for j in rc)
    out["min_per_merged_pr"] = round(total / merged, 1)
    buckets = collections.Counter()
    counts = collections.Counter()
    for j in rc:
        key = (mode(j), pool(j), j["state"])
        buckets[key] += minutes(j)
        counts[key] += 1
    out["ranked"] = [{"mode": k[0], "pool": k[1], "state": k[2], "runs": counts[k],
                      "min_per_merged_pr": round(v / merged, 2), "avg_min": round(v / counts[k], 1)}
                     for k, v in buckets.most_common()]
    out["cancelled_min_per_merged_pr"] = round(sum(minutes(j) for j in rc if j["state"] == "cancelled") / merged, 2)
    out["over_60_min_per_merged_pr"] = round(sum(minutes(j) for j in rc if minutes(j) > 60) / merged, 2)
    prs = collections.Counter(j.get("workspace") for j in rc)
    heads = collections.Counter((j.get("workspace"), j.get("ref")) for j in rc)
    out["prs"], out["heads"] = len(prs), len(heads)
    out["heads_per_pr"] = round(len(heads) / max(len(prs), 1), 2)
    per_pr = collections.Counter(j.get("workspace") for j in rc if mode(j) == "clippy-changed")
    out["clippy_runs_per_pr_histogram"] = dict(sorted(collections.Counter(min(v, 6) for v in per_pr.values()).items()))
    # The same (mode, source tree) as an earlier green run: a run its result could have been reused for.
    green, again = {}, collections.Counter()
    for j in sorted(rc, key=lambda x: ts(x.get("started_at")) or 0):
        tree = j.get("source_tree")
        if not tree:
            continue
        key = (mode(j), tree)
        if key in green and (ts(j.get("started_at")) or 0) > green[key]:
            again[mode(j)] += minutes(j)
        if j["state"] == "done" and j.get("exit_code", 0) == 0 and key not in green:
            green[key] = ts(j.get("updated_at")) or 0
    out["after_green_same_tree_min_per_merged_pr"] = {k: round(v / merged, 2) for k, v in again.items()}
    # Pool VMs are made for a few jobs; each of a VM's two cargo slots starts empty, so a VM's first two
    # clippy-changed steps can never find a kept target.
    by_vm = collections.defaultdict(list)
    for j in jobs:
        if j.get("submitter") == SUBMITTER and mode(j) == "clippy-changed" and pool(j) == "pool-vm":
            by_vm[j["worker"]].append(ts(j.get("started_at")) or 0)
    order = collections.Counter()
    for starts in by_vm.values():
        for i, _ in enumerate(sorted(starts)):
            order[min(i, 2)] += 1
    n = sum(order.values())
    out["pool_vm_clippy"] = {"vms": len(by_vm), "steps": n,
                             "first_or_second_on_vm": round((order[0] + order[1]) / max(n, 1), 3)}
    hourly = collections.defaultdict(list)
    for j in rc:
        if mode(j) == "clippy-changed" and pool(j) == "pool-vm" and j["state"] == "done":
            hourly[datetime.datetime.fromtimestamp(ts(j["started_at"]), datetime.timezone.utc).strftime("%dT%H")].append(minutes(j))
    out["pool_vm_clippy_done_median_by_hour"] = {k: round(statistics.median(v), 1) for k, v in sorted(hourly.items())}
    return out


def logs_part(directory):
    rows = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".log"):
            continue
        text = open(os.path.join(directory, name), encoding="utf-8", errors="replace").read()
        if "cargo clippy" not in text:
            continue
        row = {"id": name[:-4]}
        if m := SLOT.search(text):
            row["slot"], row["kept_gib"] = m.group(1), float(m.group(2))
        if m := SLOT_AFTER.search(text):
            row["after_gib"] = float(m.group(1))
        if m := SCCACHE.search(text):
            row["sccache"] = [int(x) for x in m.groups()]
        row["passes_s"] = [int(a or 0) * 60 + float(b) for a, b in CARGO_FINISHED.findall(text)]
        row["base_pass"] = "HEAD is over the baseline" in text
        row["base_red_rows"] = text.count("rust panic ratchet (base red)::")
        rows.append(row)
    summary = {"logs": len(rows),
               "slot_created": sum(r.get("slot") == "created" for r in rows),
               "slot_reused": sum(r.get("slot") == "reused" for r in rows),
               "base_pass_ran": sum(r["base_pass"] for r in rows)}
    for i, label in enumerate(["clippy_all_targets", "ratchet_head", "ratchet_base"]):
        xs = [r["passes_s"][i] for r in rows if len(r["passes_s"]) > i]
        if xs:
            summary[f"{label}_median_s"] = round(statistics.median(xs))
    reds = [r["base_red_rows"] for r in rows if r["base_pass"]]
    if reds:
        summary["base_red_rows_median"] = statistics.median(reds)
    return {"summary": summary, "rows": rows}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--merged", type=int, required=True)
    ap.add_argument("--logs")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    result = {"window": [args.since, args.until],
              **jobs_part(read_jobs(args.jobs), ts(args.since), ts(args.until), args.merged)}
    if args.logs:
        result["logs"] = logs_part(args.logs)
    if args.json:
        json.dump(result, sys.stdout, indent=1)
        print()
        return 0
    print(f"{result['jobs']} jobs, {result['merged']} merged PRs: {result['min_per_merged_pr']} min per merged PR")
    print(f"{'mode':16} {'pool':9} {'state':9} {'runs':>5} {'min/PR':>7} {'avg':>6}")
    for row in result["ranked"]:
        print(f"{row['mode']:16} {row['pool']:9} {row['state']:9} {row['runs']:5} {row['min_per_merged_pr']:7.2f} {row['avg_min']:6.1f}")
    for key in ("cancelled_min_per_merged_pr", "over_60_min_per_merged_pr", "heads_per_pr",
                "clippy_runs_per_pr_histogram", "after_green_same_tree_min_per_merged_pr", "pool_vm_clippy",
                "pool_vm_clippy_done_median_by_hour"):
        print(f"{key}: {result[key]}")
    if "logs" in result:
        print("logs:", result["logs"]["summary"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
