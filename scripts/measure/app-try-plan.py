#!/usr/bin/env python3
"""app-try-plan: what `cmux app try dir:CHECKOUT` spends in its plan phase on a repeat try of an unchanged tree.

Leo: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet wide pauses, esp when
this is stuff that materially improves the app". team-dev-build-swap's 18:50Z 2026-11-28 row (cmux24) was 7.6 s
over its 5 s bound, 4.0 s of it the second try's plan of the tree the first try had just planned.

Times hot-verify.py's plan(REPO, dir:REPO, no app) in this process, ROUNDS times per arm, the arms alternated:
  before  CMUX_HOT_VERIFY_KEEP_INDEX=0: each snapshot through a throwaway copy of the index (as until this change)
  after   the kept index copy (hot-verify.py kept_index), made once before the rounds (its first-use cost is the
          `first` sample)
Each arm has its own scratch CMUX_HOT_VERIFY_CACHE. Nothing in REPO changes. Prints one JSON document; with OUT,
writes it there too.

  python3 scripts/measure/app-try-plan.py [--repo DIR] [--rounds 5] [--out FILE]
  Fleet: scripts/bench/cmux-bench app-try-plan --host fleet   (cmux-ci run --class exclusive --measurement)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import platform
import statistics
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent / "cmux-next" / "hot-verify.py"


def load():
    spec = importlib.util.spec_from_file_location("hot_verify", ENGINE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["hot_verify"] = module
    spec.loader.exec_module(module)
    return module


def timed(hv, repo: Path, cache: Path, keep: bool) -> float:
    os.environ["CMUX_HOT_VERIFY_CACHE"] = str(cache)
    os.environ["CMUX_HOT_VERIFY_KEEP_INDEX"] = "1" if keep else "0"
    began = time.monotonic()
    hv.plan(repo, f"dir:{repo}", hv.NO_APP, None)
    return round((time.monotonic() - began) * 1000, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default=str(HERE.parents[1]))
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--out")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    hv = load()
    hv.hot()  # its import is not the plan phase's
    with tempfile.TemporaryDirectory(prefix="app-try-plan-") as scratch:
        caches = {arm: Path(scratch) / arm for arm in ("before", "after")}
        hv.base_tip(repo)  # a clone with no origin/feat-cmux-next fetches it once, outside the rounds
        first = timed(hv, repo, caches["after"], True)
        samples: dict[str, list[float]] = {"before": [], "after": []}
        for _ in range(args.rounds):
            for arm in ("before", "after"):
                samples[arm].append(timed(hv, repo, caches[arm], arm == "after"))
    report = {"schema": 1, "repo": str(repo), "files": len(hv.git(repo, "ls-files", "-z").split("\0")),
              "host": platform.node(), "os": platform.platform(), "rounds": args.rounds, "first_ms": first,
              "samples_ms": samples, "p50_ms": {arm: statistics.median(v) for arm, v in samples.items()}}
    text = json.dumps(report)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
