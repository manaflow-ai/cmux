#!/usr/bin/env python3
"""Hill-climb the projection's transport knobs on one tree and one link profile.

    hillclimb.py TREE --profile store-v6-1-low [--steps rg,gitstatus] [--rounds 3] --out out

It starts at the shipped defaults and, one knob at a time, tries the next value up and down that
knob's ladder (cmux-projection `src/tune.rs`):

    CMUX_PROJECTION_ZSTD_LEVEL       0 (raw), -1, 1, 3, 6, 9, 19
    CMUX_PROJECTION_READAHEAD_FILES  1 (off), 16, 64, 256, 1024
    CMUX_PROJECTION_READAHEAD_BYTES  1, 4, 16, 32 MiB

Each try is one `measure.py projection` run with that setting (serve and mount both inherit it),
on the link held at the profile's rate and RTT. The score is the sum of the cold steps' wall
seconds. A move is kept only when it beats the best so far by more than --min-gain (default 3%,
so noise on a busy host does not walk the climb). It stops when a round makes no move, or after
--rounds.

Every try appends to OUT/climb.jsonl ({setting, score, steps}), and the run's rows to
OUT/tries/N/rows.jsonl. The last line printed is the best setting, its score and the gain over
the defaults. A winner becomes a new default only in its own PR, carrying these numbers.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MEASURE = HERE / "measure.py"

MIB = 1024 * 1024
LADDERS: dict[str, list[int]] = {
    "CMUX_PROJECTION_ZSTD_LEVEL": [0, -1, 1, 3, 6, 9, 19],
    "CMUX_PROJECTION_READAHEAD_FILES": [1, 16, 64, 256, 1024],
    "CMUX_PROJECTION_READAHEAD_BYTES": [1 * MIB, 4 * MIB, 16 * MIB, 32 * MIB],
}
DEFAULTS = {
    "CMUX_PROJECTION_ZSTD_LEVEL": 3,
    "CMUX_PROJECTION_READAHEAD_FILES": 256,
    "CMUX_PROJECTION_READAHEAD_BYTES": 16 * MIB,
}


def neighbours(knob: str, value: int) -> list[int]:
    ladder = LADDERS[knob]
    at = ladder.index(value)
    return [ladder[i] for i in (at - 1, at + 1) if 0 <= i < len(ladder)]


def score(rows: list[dict], steps: list[str]) -> tuple[float | None, dict]:
    """Sum of the cold steps' wall seconds; None when a step is missing or failed."""
    by_phase = {r.get("phase"): r for r in rows}
    per: dict[str, float] = {}
    for step in steps:
        row = by_phase.get(f"{step}_cold")
        if not row or row.get("rc") or row.get("wall_s") is None:
            return None, per
        per[step] = row["wall_s"]
        per[f"{step}_down_bytes"] = row.get("down_bytes", 0)
    return round(sum(v for k, v in per.items() if not k.endswith("_down_bytes")), 3), per


class Climb:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.log = self.out / "climb.jsonl"
        self.tries = 0
        self.seen: dict[tuple, float | None] = {}

    def run(self, setting: dict) -> float | None:
        key = tuple(sorted(setting.items()))
        if key in self.seen:
            return self.seen[key]
        self.tries += 1
        dest = self.out / "tries" / str(self.tries)
        cmd = [sys.executable, "-I", str(MEASURE), "projection", self.args.tree, "--steps", self.args.steps,
               "--profile", self.args.profile, "--out", str(dest), "--label", f"try{self.tries}"]
        if self.args.bin:
            cmd += ["--bin", self.args.bin]
        if self.args.scratch:
            cmd += ["--scratch", self.args.scratch]
        env = {**os.environ, **{k: str(v) for k, v in setting.items()}}
        got = subprocess.run(cmd, env=env, capture_output=True, text=True)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "measure.log").write_text(got.stdout + got.stderr)
        rows_path = dest / "rows.jsonl"
        rows = [json.loads(line) for line in rows_path.read_text().splitlines() if line.strip()] \
            if rows_path.exists() else []
        value, per = score(rows, self.args.steps.split(","))
        if got.returncode:
            value = None
        entry = {"try": self.tries, "setting": setting, "score_s": value, "steps": per,
                 "profile": self.args.profile, "rc": got.returncode}
        with self.log.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        print(f"[climb] try {self.tries} {setting} -> {value}", file=sys.stderr)
        self.seen[key] = value
        return value

    def climb(self) -> dict:
        best = dict(DEFAULTS)
        base = self.run(best)
        if base is None:
            log = (self.out / "tries" / "1" / "measure.log").read_text().splitlines()[-30:]
            raise SystemExit("the defaults' run failed:\n" + "\n".join(log))
        best_score = base
        for _round in range(self.args.rounds):
            moved = False
            for knob in LADDERS:
                for value in neighbours(knob, best[knob]):
                    trial = {**best, knob: value}
                    got = self.run(trial)
                    if got is not None and got < best_score * (1 - self.args.min_gain):
                        best, best_score, moved = trial, got, True
            if not moved:
                break
        return {"best": best, "best_score_s": best_score, "default_score_s": base,
                "gain": round(1 - best_score / base, 3) if base else 0.0, "tries": self.tries,
                "profile": self.args.profile, "steps": self.args.steps}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tree")
    ap.add_argument("--profile", required=True, help="measure.py profiles lists them")
    ap.add_argument("--steps", default="rg,gitstatus")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--min-gain", type=float, default=0.03)
    ap.add_argument("--out", default="climb-out")
    ap.add_argument("--bin", help="slice_bench binary (measure.py builds it when missing)")
    ap.add_argument("--scratch")
    args = ap.parse_args()
    result = Climb(args).climb()
    (Path(args.out) / "best.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
