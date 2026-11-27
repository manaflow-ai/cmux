#!/usr/bin/env python3
"""The always-present cmux/ios-gate check: immediate no-op, or event-driven iOS/connection verdict.

Exactly one of the router's two jobs takes the canonical name for this path plan. The completion
job consumes workflow outputs at that same head, including ios-fast's proof verdict. No status polling,
simulator boot, test dispatch, or previous-head result lookup happens in this aggregator.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ios_app_package_paths
import ios_fast_verdict
import workflow_paths_cover_inputs as filters

CONTEXT = "cmux/ios-gate"


def plan(paths: list[str] | None, manifest: dict | None = None) -> dict[str, bool]:
    if paths is None:
        return {"ios": True, "pair": True}
    try:
        # Include every fast-verdict input, including host-side screen-sharing paths outside
        # the app's package closure. A new fast-verdict input must never get a gate no-op.
        ios = ios_fast_verdict.affects(paths)
        manifest = manifest if manifest is not None else json.loads((HERE / "pr_router.json").read_text())
        route = manifest["callees"]["ios-link-ffi-linux.yml"]
        pair = all(any(filters.admits("paths", route[key], p) for p in paths)
                   for key in ("paths", "affects"))
        return {"ios": ios, "pair": pair}
    except (OSError, ValueError, KeyError, TypeError):
        # An unread path table cannot prove that this change is unrelated.
        return {"ios": True, "pair": True}


def verdict(ios: bool, pair: bool, ios_state: str = "", ios_job: str = "",
            pair_state: str = "") -> tuple[str, str]:
    if not (ios or pair):
        return "success", "No iOS or connection inputs changed"
    states = []
    if ios:
        states.append(ios_state if ios_job == "success" else "error")
    if pair:
        states.append(pair_state)
    if "failure" in states:
        return "failure", "iOS fast or simulated connection assertions failed"
    if any(s != "success" for s in states):
        return "error", "Missing iOS fast/proof or simulated connection verdict at this head"
    return "success", "Changed iOS targets and applicable simulated connection matrix passed"


def main() -> int:
    ios = os.environ.get("IOS_REQUIRED") != "false"
    pair = os.environ.get("PAIR_REQUIRED") != "false"
    if os.environ.get("CANCELLED") == "true" or os.environ.get("ROUTE_JOB") != "success":
        state, desc = "error", "Workflow cancelled or changed paths unavailable"
    else:
        state, desc = verdict(ios, pair, os.environ.get("IOS_STATE", ""),
                              os.environ.get("IOS_JOB", ""), os.environ.get("PAIR_STATE", ""))
    print(f"{CONTEXT}: {state}: {desc}")
    return 0 if state == "success" else 1


if __name__ == "__main__":
    raise SystemExit(main())
