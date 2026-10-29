#!/usr/bin/env python3
"""Shard and order the webviews test files by recorded duration (run-webviews-tests.sh).

    webviews_test_shards.py assign FILES SERIAL DURATIONS SHARD COUNT   # print this shard's files, NUL-separated
    webviews_test_shards.py order FILE_LIST DURATIONS asc|desc          # a NUL list, shortest or longest first
    webviews_test_shards.py order-triples TRIPLES DURATIONS desc         # xargs -n 3 triples, by their first item
    webviews_test_shards.py record LINES OUT                            # the runner's `SECONDS FILE` lines as JSON
    webviews_test_shards.py merge OUT PRIOR MEASURED...                 # the next duration manifest

The shards used to take files by index mod 4: one new file moved every file after it, and the
heavy dev-server files fell together by chance (run 40815704587 on 32 vCPU: shards of 18.6, 9.9,
12.1 and 7.7 min). Now a file with a recorded duration goes to the shard with the least load so
far, longest first (greedy longest-processing-time). A file with no recorded duration (a new one)
goes by a stable hash of its path, after the others, so it moves only itself.

Load is wall time on a shard, not CPU time: the plain files run 32 at a time, the dev-server files
(SERIAL) 8 at a time, and a `// cmux-web-test-alone` file alone (ShardPlan). The widths are fixed,
not read from this runner, so every shard job computes the same split even when one lands on a
smaller runner. Each shard job must get the same FILES, SERIAL and DURATIONS: the workflow reads the
manifest once (web-subarea-scope) and hands every shard that copy.

DURATIONS is a JSON object {file: seconds}; a missing or unreadable file is no durations. The
runner writes each file's first-run seconds (CMUX_WEB_TEST_DURATIONS_OUT); `merge` averages them
with the prior manifest, so one noisy run moves a file's weight by half.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

# Files at once on the 32 vCPU shard: plain files (jobs), dev-server files (jobs / 4), alone files.
PLAIN_AT_ONCE, DEV_AT_ONCE = 32, 8
ALONE_MARK = "// cmux-web-test-alone"


def load_durations(path: str) -> dict[str, float]:
    try:
        found = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(found, dict):
        return {}
    clean = {}
    for name, seconds in found.items():
        if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and 0 <= seconds < 86400:
            clean[str(name)] = float(seconds)
    return clean


def read_nul(path: str) -> list[str]:
    return [item.decode() for item in Path(path).read_bytes().split(b"\0") if item]


def write_nul(names: list[str]) -> None:
    sys.stdout.buffer.write(b"".join(name.encode() + b"\0" for name in names))


def runs_alone(name: str) -> bool:
    try:
        with open(name, encoding="utf-8", errors="replace") as stream:
            return any(line.rstrip("\n") == ALONE_MARK for _, line in zip(range(20), stream))
    except OSError:
        return False


def stable_shard(name: str, count: int) -> int:
    return int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "big") % count


class ShardPlan:
    """One shard's estimated wall time in integer milliseconds: its plain files on PLAIN_AT_ONCE lanes,
    then its dev-server files on DEV_AT_ONCE lanes, then its alone files one after another, which is
    how run-webviews-tests.sh runs them. A lane model, not seconds divided by width: a 549 s file in an
    8-wide pool still takes 549 s (accent-glass-invariants), so its shard needs little else."""

    def __init__(self) -> None:
        self.plain = [0] * PLAIN_AT_ONCE
        self.dev = [0] * DEV_AT_ONCE
        self.alone = 0
        self.total = 0

    def wall(self, kind: str = "", cost: int = 0) -> int:
        plain, dev, alone = max(self.plain), max(self.dev), self.alone
        if kind == "plain":
            plain = max(plain, min(self.plain) + cost)
        elif kind == "dev":
            dev = max(dev, min(self.dev) + cost)
        elif kind == "alone":
            alone += cost
        return plain + dev + alone

    def add(self, kind: str, cost: int) -> None:
        self.total += cost
        if kind == "alone":
            self.alone += cost
            return
        lanes = self.plain if kind == "plain" else self.dev
        lanes[lanes.index(min(lanes))] += cost


def assign(files: list[str], serial: set[str], durations: dict[str, float], count: int) -> list[int]:
    """Each file's zero-based shard, the same for the same inputs on every runner. Known files go
    longest first to the shard whose estimated wall time grows least (ties: less work, then the
    lower shard); unknown files by path hash, after, so they never move a known one."""
    shards = [0] * len(files)
    plans = [ShardPlan() for _ in range(count)]
    known = []
    for index, name in enumerate(files):
        if name not in durations:
            shards[index] = stable_shard(name, count)
            continue
        kind = ("alone" if runs_alone(name) else "dev") if name in serial else "plain"
        known.append((round(durations[name] * 1000), name, kind, index))
    for cost, _, kind, index in sorted(known, key=lambda item: (-item[0], item[1])):
        target = min(range(count), key=lambda shard: (plans[shard].wall(kind, cost), plans[shard].total, shard))
        plans[target].add(kind, cost)
        shards[index] = target
    return shards


def order(names: list[str], durations: dict[str, float], direction: str) -> list[str]:
    """asc: known files shortest first, then unknown ones, then alone files (the warming pick).
    desc: known files longest first, then unknown ones (the order a pool should start them)."""
    def key(name: str):
        if direction == "asc":
            return (runs_alone(name), name not in durations, durations.get(name, 0.0))
        return (name not in durations, -durations.get(name, 0.0))
    return sorted(names, key=key)  # stable: equal keys keep the git index order


def record(lines: str) -> dict[str, float]:
    """Each file's first run: a retry runs alone and says nothing about the file among the others."""
    found: dict[str, float] = {}
    for line in lines.splitlines():
        seconds, _, name = line.partition(" ")
        if name and seconds.isdigit():
            found.setdefault(name, float(seconds))
    return found


def merge(prior: dict[str, float], measured: list[dict[str, float]]) -> dict[str, float]:
    latest: dict[str, float] = {}
    for found in measured:
        latest.update(found)
    merged = dict(prior)
    for name, seconds in latest.items():
        merged[name] = round((prior[name] + seconds) / 2 if name in prior else seconds, 1)
    return dict(sorted(merged.items()))


def main(argv: list[str]) -> int:
    if len(argv) == 6 and argv[0] == "assign":
        files, serial = read_nul(argv[1]), set(read_nul(argv[2]))
        shard, count = int(argv[4]), int(argv[5])
        if not 1 <= shard <= count:
            print(f"error: shard {shard} is not in 1..{count}", file=sys.stderr)
            return 2
        shards = assign(files, serial, load_durations(argv[3]), count)
        write_nul([name for name, target in zip(files, shards) if target == shard - 1])
        return 0
    if len(argv) == 4 and argv[0] == "order" and argv[3] in ("asc", "desc"):
        write_nul(order(read_nul(argv[1]), load_durations(argv[2]), argv[3]))
        return 0
    if len(argv) == 4 and argv[0] == "order-triples" and argv[3] == "desc":
        items = read_nul(argv[1])
        triples = [items[index:index + 3] for index in range(0, len(items), 3)]
        durations = load_durations(argv[2])
        ranked = order([triple[0] for triple in triples], durations, "desc")
        by_file = {}
        for triple in triples:
            by_file.setdefault(triple[0], []).append(triple)
        write_nul([item for name in ranked for item in by_file[name].pop(0)])
        return 0
    if len(argv) == 3 and argv[0] == "record":
        try:
            lines = Path(argv[1]).read_text(encoding="utf-8")
        except OSError:
            lines = ""
        Path(argv[2]).write_text(json.dumps(record(lines), indent=0, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    if len(argv) >= 3 and argv[0] == "merge":
        merged = merge(load_durations(argv[2]), [load_durations(path) for path in argv[3:]])
        Path(argv[1]).parent.mkdir(parents=True, exist_ok=True)
        Path(argv[1]).write_text(json.dumps(merged, indent=0, sort_keys=True) + "\n", encoding="utf-8")
        print(f"duration manifest: {len(merged)} files")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
