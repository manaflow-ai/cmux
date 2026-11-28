"""The matrix acp-registry-conformance.sh writes: one row per (agent, agent version, case) at one cmux commit.

    python3 -I acp_registry_matrix.py OUT REGISTRY COMMIT ID...

Reads OUT/ID.log for each id (the `acp-agent` and `acp-case` lines hub/acp_registry_live_tests.rs prints) and prints
acp-registry-matrix/v1 JSON. Every agent gets every case: a case its run printed no line for (the build failed, the
run timed out or crashed before it) is a fail with that reason, never a missing row, so failed_cases counts it.
"""
from __future__ import annotations

import datetime
import json
import re
import sys
from pathlib import Path

SCHEMA = "acp-registry-matrix/v1"
CASES = ("launch", "initialize_v1", "session_new", "v2_offer")


def rows_for(log: str, agent_id: str, version: str) -> list[dict]:
    seen: dict[str, tuple[str, str]] = {}
    for line in log.splitlines():
        parts = line.split("\t")
        if parts[0] == "acp-agent" and len(parts) >= 3:
            version = parts[2]
        elif parts[0] == "acp-case" and len(parts) >= 4 and parts[1] in CASES and parts[2] in ("pass", "fail"):
            seen[parts[1]] = (parts[2], parts[3])
    if "acp-build-failed" in log:
        why = "the cmux build failed"
    elif m := re.search(r"^acp-exit (\d+)$", log, re.M):
        why = "timed out" if m.group(1) in ("124", "137") else f"the run ended (exit {m.group(1)}) before this case"
    else:
        why = "no run"
    # A failed launch ends that agent's test (the other agents run on): its later cases were never tried.
    if seen.get("launch", ("pass",))[0] == "fail":
        why = "not run: the launch failed"
    return [{"agent": agent_id, "version": version, "case": case,
             "result": seen.get(case, ("fail", why))[0], "detail": seen.get(case, ("fail", why))[1]}
            for case in CASES]


def main(out: str, registry: str, commit: str, *ids: str) -> None:
    versions = {a.get("id"): a.get("version", "?") for a in json.loads(Path(registry).read_text()).get("agents", [])}
    rows = []
    for agent_id in ids:
        log = Path(out, f"{agent_id}.log")
        rows += rows_for(log.read_text(errors="replace") if log.exists() else "", agent_id, versions.get(agent_id, "?"))
    failed = [r for r in rows if r["result"] != "pass"]
    print(json.dumps({
        "schema": SCHEMA,
        "commit": commit,
        "measured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agents": sorted(ids),
        "cases_per_agent": list(CASES),
        "rows": rows,
        "failed_cases": len(failed),
    }, indent=2))


if __name__ == "__main__":
    main(*sys.argv[1:])
