#!/usr/bin/env python3
"""Inventory completed CI job minutes by workflow, job and observed runner OS.

Run: cmux-ci run --class light --ref SHA --script scripts/measure/ci-mac-minutes.sh --arg=/path/to/timing.jsonl --arg=1795563381 --arg=1795649781

Input is the controller /v1/github/timing/records JSONL export, with step
timings retained. Arguments are capture path and inclusive/exclusive Unix
completion timestamps. Export every historical page (deduplicate id/attempt,
advance since to the last timestamp; fail on a stalled cursor). This tool
does not infer capture completeness: pass the exporter's completion manifest
with --manifest to verify its window and record count. Without it, coverage
is unknown. Minutes are full durations of jobs completed in the window, not
wall-clock utilization, queue time, or proven post-migration savings. Unknown
runner OS and missing durations remain explicit. Step totals allow mixed Mac
jobs to be evaluated without claiming their native build time as portable.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
import math
from pathlib import Path


def runner_os(row):
    kind = str(row.get("runner") or "").lower()
    name = str(row.get("runner_name") or "").lower()
    if kind in {"mini", "macos", "mac"} or "macos" in name or "mac mini" in name:
        return "macos"
    if kind in {"linux", "ubuntu"} or name.startswith(("cmux-linux-", "cmux-runner-pool-")):
        return "linux"
    return "unknown"


def duration(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0:
        return value
    return None


def summarize(rows, since, until, repo="manaflow-ai/cmux"):
    seen, groups, labels = set(), {}, Counter()
    duplicates = outside = 0
    for row in rows:
        if row.get("repo") != repo:
            continue
        stamp = datetime.fromisoformat(row["at"].replace("Z", "+00:00")).timestamp()
        if not since <= stamp < until:
            outside += 1
            continue
        key = (row["id"], row.get("attempt", 1))
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        os_name = runner_os(row)
        labels[(str(row.get("runner") or ""), os_name)] += 1
        group_key = (row.get("workflow_path", ""), row.get("job", ""), os_name)
        group = groups.setdefault(group_key, {"jobs": 0, "seconds": 0, "untimed_jobs": 0,
            "conclusions": Counter(), "runners": Counter(), "steps": {}})
        group["jobs"] += 1
        seconds = duration(row.get("seconds"))
        if seconds is None:
            group["untimed_jobs"] += 1
        else:
            group["seconds"] += seconds
        group["conclusions"][str(row.get("conclusion") or "unknown")] += 1
        group["runners"][str(row.get("runner_name") or "unknown")] += 1
        for step in row.get("steps") or []:
            item = group["steps"].setdefault(step["n"], {"observations": 0, "seconds": 0, "untimed": 0})
            item["observations"] += 1
            seconds = duration(step.get("s"))
            if seconds is None:
                item["untimed"] += 1
            else:
                item["seconds"] += seconds
    inventory = []
    for (workflow, job, os_name), group in sorted(groups.items()):
        inventory.append({"workflow": workflow, "job": job, "os": os_name,
                          "minutes": group["seconds"] / 60, **group})
    return {"repo": repo, "since": since, "until": until, "unique_records": len(seen),
            "duplicate_records": duplicates, "outside_window": outside,
            "coverage": "unknown", "runner_labels": [
                {"label": label, "os": os_name, "jobs": count}
                for (label, os_name), count in sorted(labels.items())], "inventory": inventory}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("since", type=int)
    parser.add_argument("until", type=int)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.until <= args.since:
        parser.error("until must be after since")
    with args.input.open() as stream:
        result = summarize((json.loads(line) for line in stream if line.strip()), args.since, args.until)
    if args.manifest:
        manifest = json.loads(args.manifest.read_text())
        expected = {"since": args.since, "until": args.until, "records": result["unique_records"], "complete": True}
        if any(manifest.get(key) != value for key, value in expected.items()):
            parser.error("completion manifest does not match the capture")
        result["coverage"] = "exporter reports complete; window and count verified"
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
