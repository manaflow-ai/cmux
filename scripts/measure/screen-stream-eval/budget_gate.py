#!/usr/bin/env python3
"""The nightly screen-share budget gate, at its old path: a shim over the shared runner,
scripts/measure/budget_gate/budget_gate.py, with --probe screen-share
(scripts/measure/budget_gate/probes/screen_share.py holds the budgets and the stage mapping).

  budget_gate.py check SOURCE [--out GATE.json] [--summary FILE] [--budget STAGE=MS ...]
  budget_gate.py init --out GATE.json [--budget STAGE=MS ...]
  budget_gate.py mark-stage STAGE --out GATE.json
  budget_gate.py follow LOG --out GATE.json [--once] [--stop-file FILE]

check exits 0 when every measured stage is within its budget, 1 when one or more is over (each is
named), 2 when nothing could be judged: a gate that measured nothing never passes. init writes the
fail-by-default record (verdict "fail", stage "unknown") a run starts with, so a run that crashes,
hangs or is killed leaves a gate.json naming the last stage it reached instead of none.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SHARED = Path(__file__).resolve().parents[1] / "budget_gate" / "budget_gate.py"
_spec = importlib.util.spec_from_file_location("budget_gate_shared", _SHARED)
shared = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shared)
probe = shared.load_probe("screen-share")

BUDGET_SCHEMA = probe.BUDGET_SCHEMA
RESULTS_SCHEMA = probe.RESULTS_SCHEMA
GATE_SCHEMA = probe.SCHEMA
BUDGETS = probe.BUDGETS
TRANSPORT = probe.TRANSPORT
NothingToJudge = probe.NothingToJudge
stages_from_budget = probe.stages_from_budget
stages_from_results = probe.stages_from_results
load_source = probe.load_source
judge = shared.judge


def parse_overrides(pairs):
    return shared.parse_overrides(pairs, BUDGETS)


def main(argv=None):
    return shared.main(argv, default_probe="screen-share")


if __name__ == "__main__":
    sys.exit(main())
