#!/usr/bin/env python3
"""What the ci-guards head pass costs a small pull request: the CI seconds of the steps guard_step_inputs.py selects.

Measures: for each of the last N first-parent commits on a branch that change 2 to 4 files (a typical small pull
request), the steps scripts/ci/guard_step_inputs.py's select() runs for that diff, summed with each step's seconds
from a CI log (one harness: the same seconds table and the same diffs for every tree measured). Pass --tree for each
checkout to compare (the base and a change to the selection); each is measured with its own selection code.

    python3 scripts/measure/guard_head_pass_seconds.py --seconds SECONDS.json --tree BASE_CHECKOUT --tree HEAD_CHECKOUT \
        [--branch origin/feat-cmux-next] [--commits 60]

SECONDS.json maps a ci-guards step name to its seconds (from a ci-guards run's `  PASS  12.3s  group / ci: NAME`
lines). Prints each tree's mean selected seconds, always-run seconds and steps.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

PROBE = r'''
import json, sys
sys.path.insert(0, "scripts/ci")
import guard_step_inputs as g
seconds = json.load(open(sys.argv[1]))
diffs = json.load(open(sys.argv[2]))
tree, steps = g.Tree(), g.guard_steps()
always = [s[0] for s in steps if g.inputs_of(tree, s).whole]
out = {"always_seconds": sum(seconds.get(n, 0) for n in always), "always_steps": len(always), "per_diff": []}
for changed in diffs:
    reason = g.everything_reason(changed)
    picked = [s[0] for s in steps] if reason else list(g.select(tree, steps, changed))
    out["per_diff"].append(sum(seconds.get(n, 0) for n in picked))
print(json.dumps(out))
'''


def small_diffs(repo: Path, branch: str, commits: int) -> list[list[str]]:
    shas = subprocess.run(["git", "-C", str(repo), "rev-list", "--first-parent", f"-{commits * 4}", branch],
                          capture_output=True, text=True, check=True).stdout.split()
    diffs = []
    for sha in shas:
        names = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", "--no-renames", f"{sha}^", sha],
                               capture_output=True, text=True).stdout.split()
        if 2 <= len(names) <= 4:
            diffs.append(names)
        if len(diffs) == commits:
            break
    return diffs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=Path, required=True)
    parser.add_argument("--tree", type=Path, action="append", required=True)
    parser.add_argument("--branch", default="origin/feat-cmux-next")
    parser.add_argument("--commits", type=int, default=60)
    args = parser.parse_args()
    diffs = small_diffs(args.tree[0], args.branch, args.commits)
    scratch = args.seconds.with_suffix(".diffs.json")
    scratch.write_text(json.dumps(diffs))
    for tree in args.tree:
        done = subprocess.run([sys.executable, "-c", PROBE, str(args.seconds.resolve()), str(scratch.resolve())],
                              cwd=tree, capture_output=True, text=True, check=True)
        result = json.loads(done.stdout)
        mean = sum(result["per_diff"]) / max(1, len(result["per_diff"]))
        print(f"{tree}: {len(diffs)} small diffs, mean selected {mean:.0f}s, always {result['always_seconds']:.0f}s "
              f"in {result['always_steps']} steps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
