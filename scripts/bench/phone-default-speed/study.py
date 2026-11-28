#!/usr/bin/env python3
"""Explicit developer study: fresh target, baseline capture and mutation checks.

Uses the PR step's exact tool setup; never called by the PR gate or cache producer.
Run through cmux-ci test and fetch /tmp/phone-default-speed-receipt as an artifact.
"""
from dataclasses import replace
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import ci_steps


def main():
    table = ci_steps.load()
    name = "phone-default-speed-icount"
    step = table.steps[name]
    study = step.run.replace("scripts/ci/cmux-tui-test-target.sh restore\n", "")
    study = study.replace("measure.py\n", "measure.py --study\n")
    study = study.replace("python3 scripts/bench/tests/test_phone_default_speed.py\n", "")
    assert study != step.run
    table.steps[name] = replace(step, run=study, timeout=3900)
    return ci_steps.run_job(table, "linux", None, only=[name])


if __name__ == "__main__":
    raise SystemExit(main())
