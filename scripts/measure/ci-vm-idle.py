#!/usr/bin/env python3
"""Measure running time when no CI job occupied a VM, at regional list prices.

    cmux-ci run --class exclusive --ref SHA --script scripts/measure/ci-vm-idle.sh --arg /path/to/capture

The worker needs a captured input directory. snapshots/*.json[.gz] are full
fleet GCE inventories (generated_at, instances, others), or {generated_at,
rows} with the same VM fields. Bracket a full day ending at the last snapshot.
prices.json maps machine_type/region to on-demand USD per hour. jobs.jsonl[.gz]
contains deduplicated job timing records (runner_name, completion at, seconds)
or [runner_name, start_unix, end_unix, ...] intervals. Include jobs that crossed
either boundary and censor unfinished jobs at the window end. Only job activity
in the supplied feed is visible. Short VM lifetimes between snapshots can be
missed. Untimed power transitions are estimated halfway between observations.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
import gzip
import json
from pathlib import Path
import re


POOL = "cmux-runner-pool-"
JIT = "cmux-gha-runner"
ONESHOT = "cmux-oneshot-"


def stamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def open_text(path):
    return gzip.open(path, "rt", encoding="utf-8") if path.suffix == ".gz" else path.open(encoding="utf-8")


def runner_vm(name, vm_names):
    if name.startswith(ONESHOT):
        short, _, tag = name[len(ONESHOT):].rpartition("-")
        if short and re.fullmatch("[0-9a-f]{4}", tag):
            name = POOL + short
    if name in vm_names:
        return name
    if name.startswith(POOL):
        parent, _, slot = name.rpartition("-")
        if slot.isdecimal() and parent in vm_names:
            return parent
    return None


def busy_intervals(path, begin, end, vm_names):
    jobs = defaultdict(list)
    with open_text(path) as stream:
        for line in stream:
            if isinstance(row := json.loads(line), dict):
                name = row["runner_name"]
                stop = stamp(row["at"])
                start = stop - row["seconds"]
            else:
                name, start, stop = row[:3]
            vm = runner_vm(name or "", vm_names)
            if vm is not None and max(start, begin) < min(stop, end):
                jobs[vm].append((max(start, begin), min(stop, end)))
    for vm, intervals in jobs.items():
        merged = []
        for start, stop in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], stop)
            else:
                merged.append([start, stop])
        jobs[vm] = merged
    return jobs


def read_snapshots(directory):
    snapshots = []
    for path in directory.iterdir():
        if not path.name.endswith((".json", ".json.gz")):
            continue
        with open_text(path) as stream:
            data = json.load(stream)
        rows = data.get("rows")
        if rows is None:
            rows = [*data["instances"].values(), *data["others"].values()]
        snapshots.append((stamp(data["generated_at"]), data["generated_at"],
                          [r for r in rows if r["name"].startswith((POOL, JIT))]))
    return sorted(snapshots, key=lambda snapshot: snapshot[0])


def power_events(snapshots):
    events = defaultdict(dict)
    shapes = defaultdict(list)
    previous_time, previous = None, set()
    for t, _, rows in snapshots:
        current = set()
        for r in rows:
            key = (r["name"], r["zone"], r["created"])
            current.add(key)
            events_vm = events[key]
            if previous_time is not None and key not in previous:
                events_vm[previous_time] = (False, False)
            for field in ("last_stop", "last_suspended", "last_start"):
                if r.get(field):
                    events_vm[stamp(r[field])] = (field == "last_start", True)
            observed_on = r["status"] == "RUNNING"
            events_vm[t] = (observed_on, events_vm.get(t) == (observed_on, True))
            history = shapes[key]
            if not history:
                history.append((stamp(r["created"]), r["machine_type"]))
            elif history[-1][1] != r["machine_type"]:
                # Resizing requires a stopped VM. Charge a new run at its new
                # rate, without replaying any of the old shape's power events.
                transition = (previous_time + t) / 2
                for field in ("last_start", "last_stop", "last_suspended"):
                    edge = stamp(r[field]) if r.get(field) else None
                    if edge is not None and previous_time < edge <= t:
                        transition = edge
                        break
                history.append((transition, r["machine_type"]))
        for key in previous - current:
            events[key][t] = (False, False)
        previous, previous_time = current, t
    return events, shapes


def running_spans(events, created, begin, end):
    last, on, start = created, False, None
    for t, (is_running, exact) in sorted(events.items()):
        if is_running != on:
            cut = t if exact else (max(created, last) + t) / 2
            if is_running:
                start = max(begin, cut)
            elif start < min(end, cut):
                yield start, min(end, cut)
            on = is_running
        last = t
    if on and start < end:
        yield start, end


def priced_spans(spans, shapes):
    i = 0
    for start, stop in spans:
        while i + 1 < len(shapes) and shapes[i + 1][0] <= stop:
            edge = shapes[i + 1][0]
            if start < edge:
                yield start, edge, shapes[i][1]
            start = max(start, edge)
            i += 1
        if start < stop:
            yield start, stop, shapes[i][1]


def occupancy(spans, intervals):
    # Both streams are sorted. A job may extend across an inferred power edge.
    i = 0
    for start, stop, shape in spans:
        busy = 0
        while i < len(intervals):
            a, b = intervals[i]
            if a >= stop:
                break
            busy += max(0, min(stop, b) - max(start, a))
            if b > stop:
                break
            i += 1
        yield shape, (stop - start) / 3600, (stop - start - busy) / 3600


def measure(directory):
    snapshots = read_snapshots(directory / "snapshots")
    if not snapshots or snapshots[-1][0] - snapshots[0][0] < 86400:
        raise ValueError("inventory snapshots must bracket the full 24-hour window")
    end, end_iso, _ = snapshots[-1]
    begin = end - 86400
    with (directory / "prices.json").open() as f:
        prices = json.load(f)
    job_files = [p for p in (directory / "jobs.jsonl", directory / "jobs.jsonl.gz") if p.is_file()]
    if len(job_files) != 1:
        raise ValueError("supply one jobs.jsonl or jobs.jsonl.gz")
    histories, shapes = power_events(snapshots)
    jobs = busy_intervals(job_files[0], begin, end, {key[0] for key in histories})
    totals = {"persistent": Counter(), "jit": Counter()}
    for key, events in histories.items():
        name, zone, created = key
        group = totals["persistent" if name.startswith(POOL) else "jit"]
        spans = running_spans(events, stamp(created), begin, end)
        for shape, running, idle in occupancy(priced_spans(spans, shapes[key]), jobs.get(name, ())):
            group["running_vm_hours"] += running
            group["idle_vm_hours"] += idle
            group["idle_list_usd"] += idle * prices[f"{shape}/{zone.rsplit('-', 1)[0]}"]
    metrics = ("running_vm_hours", "idle_vm_hours", "idle_list_usd")
    return {"window_end": end_iso, "snapshot_count": len(snapshots),
            "pools": {g: {k: round(v[k], 3) for k in metrics} for g, v in totals.items()}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    print(json.dumps(measure(parser.parse_args().input), indent=2))
