#!/usr/bin/env python3
"""How much of a pull request's base re-run the guard group's ancestor reuse would skip.

Usage: guard_base_reuse.py --runs RUNS.json JOB.log [JOB.log ...]

Each JOB.log is a feat-cmux-next pull request's guard group job log (gh run view --job ID --log) whose base re-ran
the head's red steps. RUNS.json lists the finished (success or failure) feat-cmux-next push runs of
cmux-next-guards.yml as [{id, head_sha, conclusion, created_at}] (gh api .../runs?status=success|failure).

For each log it reads the base SHA, the red steps and the base re-run's seconds. It takes the nearest first-parent
ancestor of the base, within guard_base_verdicts.MAX_BEHIND, that has a finished push run. On a throwaway worktree
of the base it asks guard_base_verdicts.unreachable_steps (the selection the workflow runs) which red steps that
run's verdict stands for. Prints one JSON row per log and a total. Seconds saved are the re-run's seconds times the
reused share of its steps, an estimate: steps differ in cost.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import guard_base_verdicts as gbv  # noqa: E402

STAMP = r"^\S+Z "


def parse(log: str) -> dict | None:
    base = re.search(r"BASE_SHA: ([0-9a-f]{40})", log)
    rerun = re.search(STAMP + r"re-running (\d+) of the head's \d+ red steps on the base", log, re.M)
    if not base or not rerun:
        return None
    after = log[rerun.end():]
    took = re.search(STAMP + r"cmux guards: \d+ steps passed, \d+ failed, \d+ skipped .* in ([\d.]+)s", after, re.M)
    steps: list[str] = []
    for m in re.finditer(STAMP + r"##\[warning\](.+)$", after, re.M):
        name = m.group(1).split(gbv.CHECK_SEPARATOR, 1)[0].strip()
        if name not in steps:
            steps.append(name)
    steps = steps[: int(rerun.group(1))]
    return {"base": base.group(1), "steps": steps, "rerun_s": float(took.group(1)) if took else None}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--runs", required=True)
    ap.add_argument("logs", nargs="+")
    args = ap.parse_args()
    finished = {r["head_sha"]: r for r in json.loads(Path(args.runs).read_text())}
    total = {"jobs": 0, "steps": 0, "reused": 0, "rerun_s": 0.0, "saved_s": 0.0}
    for path in args.logs:
        row = parse(Path(path).read_text(errors="replace"))
        if row is None:
            print(json.dumps({"log": path, "skip": "no base re-run"}))
            continue
        line = gbv.ancestors(ROOT, row["base"])
        hit = next(((i, sha) for i, sha in enumerate(line) if sha in finished), None)
        out = {"log": Path(path).name, "base": row["base"][:12], "red": len(row["steps"]), "rerun_s": row["rerun_s"]}
        reused: set[str] = set()
        if hit:
            behind, sha = hit
            out |= {"source_run": finished[sha]["id"], "behind": behind}
            changed = [] if behind == 0 else gbv.changed_between(ROOT, sha, row["base"]) or []
            out["changed_paths"] = len(changed)
            with tempfile.TemporaryDirectory() as scratch:
                tree = Path(scratch) / "base"
                git("worktree", "add", "-q", "--detach", str(tree), row["base"])
                try:
                    reused = set(row["steps"]) if behind == 0 else gbv.unreachable_steps(tree, row["steps"], changed, ROOT, sha)
                finally:
                    git("worktree", "remove", "--force", str(tree))
        share = len(reused) / len(row["steps"]) if row["steps"] else 0.0
        out |= {"reused": len(reused), "saved_s": round((row["rerun_s"] or 0) * share, 1)}
        print(json.dumps(out), flush=True)
        total["jobs"] += 1
        total["steps"] += len(row["steps"])
        total["reused"] += len(reused)
        total["rerun_s"] += row["rerun_s"] or 0
        total["saved_s"] += out["saved_s"]
    print(json.dumps({"total": total}))


if __name__ == "__main__":
    main()
