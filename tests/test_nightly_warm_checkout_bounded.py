#!/usr/bin/env python3
"""The warm nightly-next builder's checkout step ends within a step bound, not the job's 300 min.

Run 45782377330 (2026-11-26, ultra1-glaeda-1): "Checkout build ref (warm nightly-next builder)"
started at 08:25:22Z and was still running at 09:05Z. The step usually takes 10 to 40 s (a cold
slot's whole-history fetch took 267 s). With no step timeout only the job's 300 min ended it, and
the one signing Mac sat idle for that long while no nightly published.

Every step named "Checkout build ref (warm nightly-next builder)" in nightly.yml needs a
timeout-minutes of at most 20. Run: python3 tests/test_nightly_warm_checkout_bounded.py (under 1 s).
"""
from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Checkout build ref (warm nightly-next builder)"
MAX_MINUTES = 20


def main() -> int:
    workflow = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
    found = 0
    bad = []
    for job_name, job in workflow["jobs"].items():
        for step in job.get("steps") or []:
            if step.get("name") != STEP:
                continue
            found += 1
            minutes = step.get("timeout-minutes")
            if not isinstance(minutes, int) or minutes > MAX_MINUTES:
                bad.append(f"{job_name}: timeout-minutes={minutes!r}")
    if not found:
        print(f"FAIL: no step named {STEP!r} in nightly.yml")
        return 1
    if bad:
        print(f"FAIL: {STEP!r} needs timeout-minutes <= {MAX_MINUTES}: " + "; ".join(bad))
        return 1
    print(f"ok: {found} warm checkout step(s) bounded at <= {MAX_MINUTES} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
