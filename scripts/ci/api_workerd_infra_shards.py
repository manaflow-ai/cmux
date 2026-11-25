#!/usr/bin/env python3
"""Which api-workerd shards of this run died without a test verdict (cmux#56511).

backend.yml runs the API Worker suite in 12 matrix shards, and the `test` job (the check that deploys and
prod-promote read) fails when any shard is not green. Most reds on feat-cmux-next were not the tests': a pool
runner that went away mid-job (the job fails with no step finished and no log), a setup step that stalled past
its bound (setup-node, the Bun cache restore, bun install), or the 45 min job limit on a slow host, which GitHub
reports as cancelled. None of those ran the tests to an answer, so none of them is a test verdict.

Each shard job records its test step's outcome, `success` or `failure`, in a one-line file named after the shard
and uploads it as the artifact api-workerd-verdict-<shard>; a shard whose test step never answered records
nothing. The `test` job downloads them all into one directory, and this sorts every shard into one of three:

  pass    the shard recorded `success`
  fail    the shard recorded `failure`: the tests ran and failed, already after the shard's own rerun of its
          failed files, so that is the code's answer and nothing reruns it again
  infra   no verdict: the test step was cancelled, skipped or never started, or the job or its upload went away

The verdicts travel as artifacts rather than through a REST read of the run's jobs: the repository's GITHUB_TOKEN
hour runs dry when CI is busiest (scripts/ci/api_call_log/env.sh), and run 45614104889's gate got a 403 there.

It prints `infra=<shards space separated>` and `fail=<...>` lines on stdout (the gate step reads them) and one
line per shard on stderr. The `test` job reruns the infra shards itself; a fail shard fails the gate as before.

Usage:
  api_workerd_infra_shards.py --verdict-dir DIR [--shards 12]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SHARDS = 12
VERDICTS = {"success": "pass", "failure": "fail"}


def classify(verdict_dir: Path, shards: int = SHARDS) -> dict[int, str]:
    """Map each shard 1..shards to pass, fail or infra from the recorded verdict files."""
    out: dict[int, str] = {}
    for shard in range(1, shards + 1):
        try:
            recorded = (verdict_dir / str(shard)).read_text(encoding="utf-8").strip()
        except OSError:
            recorded = ""
        out[shard] = VERDICTS.get(recorded, "infra")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verdict-dir", required=True, type=Path)
    parser.add_argument("--shards", type=int, default=SHARDS)
    args = parser.parse_args(argv)

    verdicts = classify(args.verdict_dir, args.shards)
    for shard, verdict in verdicts.items():
        print(f"api-workerd shard {shard}/{args.shards}: {verdict}", file=sys.stderr)
    print("infra=" + " ".join(str(s) for s, v in verdicts.items() if v == "infra"))
    print("fail=" + " ".join(str(s) for s, v in verdicts.items() if v == "fail"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
