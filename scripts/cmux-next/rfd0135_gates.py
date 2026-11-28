#!/usr/bin/env python3
"""RFD 0135 gates 2 to 4 ("What to build next"), each as a number: PASS or NO and the count.

  python3 scripts/cmux-next/rfd0135_gates.py lid-close [--runs 10 --secs 1800]
  python3 scripts/cmux-next/rfd0135_gates.py move [--matrix-log FILE]
  python3 scripts/cmux-next/rfd0135_gates.py phone
  python3 scripts/cmux-next/rfd0135_gates.py all [--out DIR]
  python3 scripts/cmux-next/rfd0135_gates.py summary DIR...   (the nightly's last job: lid-close runs
      from parallel jobs, each DIR/lid-close.json, added into one 10-of-10 number; the other gates as they are)

Gate 2, lid-close: "turn the switch on, close the lid for 30 minutes mid-task, open it: the work
continued and the chat shows it. 10 of 10, re-run nightly." Runs cmux-tui's `lid_close_gate` test
(a Mac daemon's chat moved to a Cloud-shaped daemon, every Mac process stopped for the window, see
its header) and reads its `GATE lid-close {json}` line. Not covered here: a real Mac's network going
down with it and a real Cloud VM's own idle policy.

Gate 3, move: "cmux#51824 landed, p95 under 10 s each way, 56 of 56 in the kill matrix." Checks
that cmux#51824's code is in the tree (it landed through cmux#52230), runs cmux-tui's `move_kill_drill_matrix` (8 steps x 7 kills, owned by the
kill-mid-move-drills lane) and counts its cells with nothing lost and no wrong answer (a cell KNOWN
lists still counts as not clean), and times each direction with cmux-tui's `move_times` test
(`--move-runs` round trips of a running chat to a VM and back; MOVE_TIMES, a JSON file of
{"to_cloud_ms": [...], "back_ms": [...]}, replaces the run). A replay (`--matrix-log`) times nothing
and leaves the p95 unmeasured: NO.

Gate 4, phone: "read and reply to a kept-running chat from the phone with the Mac powered down."
The phone reaches a Cloud chat only through the signed-in Mac today (docs/design/cloud-phone-pipe.md
in cmuxterm-hq, item 1, "phone-direct carrier", not built), so the gate is NO until a check for that
path exists; PHONE_GATE_CMD names it (a command that exits 0 when a phone-shaped client, with no Mac
process running, read a Cloud chat and got a reply to a prompt it sent).

Each gate prints one line `GATE <name> PASS|NO <number> <json>`; `--out DIR` also writes
DIR/<name>.json and DIR/summary.md. Exit 0 when every gate asked for ran (PASS or NO), 2 when one
could not run.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"
MATRIX_CELLS = 56
P95_BUDGET_MS = 10_000


def cargo_test(name: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # cmux-tui's tests are modules of one binary, `it` (cmux#56677): a test's name starts with its file's.
    cmd = ["cargo", "test", "-p", "cmux-tui", "--test", "it", "--", "--ignored", "--nocapture",
           "--test-threads", "1", name]
    return subprocess.run(cmd, cwd=TUI, env={**os.environ, **env}, text=True, capture_output=True)


def gate_lid_close(args: argparse.Namespace) -> dict:
    run = cargo_test("lid_close_gate::",
                     {"LID_CLOSE_RUNS": str(args.runs), "LID_CLOSE_SECS": str(args.secs)})
    sys.stderr.write(run.stderr[-20_000:])
    data = gate_line(run.stdout + "\n" + run.stderr, "lid-close")
    if data is None:
        return {"gate": "lid-close", "ran": False, "why": f"no GATE line (cargo exit {run.returncode})"}
    data.update(ran=True, ok=data["passed"] == data["runs"] and data["lid_s"] >= 1800 and data["runs"] >= 10,
                number=f'{data["passed"]}/{data["runs"]} at {data["lid_s"]} s')
    return data


def gate_line(text: str, name: str) -> dict | None:
    """The last `GATE <name> {json}` anywhere in a line: the test harness prints `test NAME ... `
    with no newline before a single test's own output, so the line rarely starts with it."""
    found = None
    for line in text.splitlines():
        at = line.find(f"GATE {name} {{")
        if at >= 0:
            found = json.loads(line[at + len(f"GATE {name} "):])
    return found


ROW = re.compile(r"^\| (local->cloud|cloud->local) \| (\S+) \| (\S+) \| (\d+) \| (.*?) \| (.*?) \| (.*?) \|")


def matrix_cells(log: str) -> list[dict]:
    """The matrix's summary table (the block after its header), one dict per cell."""
    _, _, tail = log.rpartition("| direction | step | kill | seed |")
    cells = []
    for line in tail.splitlines():
        m = ROW.match(line)
        if m:
            cells.append({"step": m[2], "kill": m[3], "seed": int(m[4]), "lost": m[5], "frozen": m[6],
                          "wrong": m[7], "clean": m[5] == "nothing lost" and m[7] == "-"})
    return cells


def p95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


# cmux#51824 (the move's controls and driver) closed unmerged: its commits landed through cmux#52230. A PR's
# state is the wrong question (and the gate job holds no GitHub token to ask it); the files it added are the
# answer, read from the checked-out tree.
MOVE_CODE = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextCloudPlace/CloudPlaceDriver.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextCloudPlace/CloudPlaceEvacuation.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/CloudHandlers+Move.swift",
)


def move_code_landed(root: Path = ROOT) -> bool:
    return all((root / path).is_file() for path in MOVE_CODE)


def move_times(args: argparse.Namespace) -> dict:
    """The round-trip move times: the `MOVE_TIMES` file when set, else a run of tests/move_times.rs."""
    if os.environ.get("MOVE_TIMES"):
        return json.loads(Path(os.environ["MOVE_TIMES"]).read_text())
    if args.matrix_log:  # a replay of a saved matrix log runs nothing
        return {}
    out = Path(tempfile.mkdtemp(prefix="rfd0135-move-times-")) / "move-times.json"
    run = cargo_test("move_times::", {"MOVE_TIMES_OUT": str(out), "MOVE_TIMES_RUNS": str(args.move_runs)})
    sys.stderr.write(run.stderr[-20_000:])
    return json.loads(out.read_text()) if out.is_file() else {}


def gate_move(args: argparse.Namespace) -> dict:
    landed = move_code_landed()
    if args.matrix_log:
        log = Path(args.matrix_log).read_text()
    else:
        run = cargo_test("move_kill_drill::move_kill_drill_matrix", {})
        log = run.stderr
        sys.stderr.write(log[-20_000:])
    cells = matrix_cells(log)
    clean = sum(c["clean"] for c in cells)
    # The matrix's own count line (kill-mid-move-drills, cmux#51760), when the build has it, wins over the table.
    counted = [json.loads(l.split(" ", 1)[1]) for l in log.splitlines() if l.startswith("MOVE_KILL_MATRIX {")]
    n_cells = counted[-1]["cells"] if counted else len(cells)
    if counted:
        clean = counted[-1]["clean"]
    times = move_times(args)
    to_cloud, back = p95(times.get("to_cloud_ms", [])), p95(times.get("back_ms", []))
    ok = (landed and n_cells == MATRIX_CELLS and clean == MATRIX_CELLS and to_cloud is not None
          and back is not None and to_cloud < P95_BUDGET_MS and back < P95_BUDGET_MS)
    return {"gate": "move", "ran": bool(n_cells), "ok": ok, "move_code_landed": landed, "cells": n_cells,
            "clean": clean, "not_clean": [f'{c["step"]}:{c["kill"]}' for c in cells if not c["clean"]],
            "p95_to_cloud_ms": to_cloud, "p95_back_ms": back,
            "number": f"{clean}/{MATRIX_CELLS} clean, p95 {to_cloud} / {back} ms, move code "
                      + ("landed" if landed else "missing"),
            "why": None if n_cells else "the matrix printed no table"}


def gate_phone(_args: argparse.Namespace) -> dict:
    cmd = os.environ.get("PHONE_GATE_CMD")
    if not cmd:
        return {"gate": "phone", "ran": True, "ok": False, "number": "0/1",
                "why": "phone-direct carrier not built: a phone reaches a Cloud chat only through the Mac "
                       "(cmuxterm-hq docs/design/cloud-phone-pipe.md item 1; owner gcp-agent-lane-4/cloud-phone-pipe)"}
    run = subprocess.run(cmd, shell=True, text=True, capture_output=True)
    sys.stderr.write(run.stderr[-20_000:])
    return {"gate": "phone", "ran": True, "ok": run.returncode == 0, "number": f"{int(run.returncode == 0)}/1",
            "why": None if run.returncode == 0 else run.stdout[-2000:]}


def merge(results: list[dict]) -> list[dict]:
    """Lid-close results of parallel jobs added into one; every other gate's last result kept."""
    lid = [r for r in results if r.get("gate") == "lid-close" and r.get("ran")]
    merged = {r["gate"]: r for r in results if r.get("gate") != "lid-close"}
    if lid:
        runs, passed = sum(r["runs"] for r in lid), sum(r["passed"] for r in lid)
        lid_s = min(r["lid_s"] for r in lid)
        merged["lid-close"] = {"gate": "lid-close", "ran": True, "runs": runs, "passed": passed, "lid_s": lid_s,
                               "each": [e for r in lid for e in r.get("each", [])],
                               "ok": passed == runs and runs >= 10 and lid_s >= 1800,
                               "number": f"{passed}/{runs} at {lid_s} s"}
    elif any(r.get("gate") == "lid-close" for r in results):
        merged["lid-close"] = {"gate": "lid-close", "ran": False, "why": "no lid-close job produced a result"}
    return [merged[g] for g in GATES if g in merged]


GATES = {"lid-close": gate_lid_close, "move": gate_move, "phone": gate_phone}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gate", choices=[*GATES, "all", "summary"])
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--secs", type=int, default=1800)
    ap.add_argument("--matrix-log")
    ap.add_argument("--move-runs", type=int, default=20, help="round trips tests/move_times.rs times")
    ap.add_argument("--out")
    args = ap.parse_args()
    names = list(GATES) if args.gate == "all" else [args.gate]
    results, status = [], 0
    if args.gate == "summary":
        found = [json.loads(p.read_text()) for d in args.dirs for p in sorted(Path(d).glob("*.json"))]
        names, results = [], merge(found)
    for name in names:
        results.append(GATES[name](args))
    for result in results:
        name = result["gate"]
        verdict = "PASS" if result.get("ok") else "NO"
        if not result.get("ran"):
            verdict, status = "NOT-RUN", 2
        print(f"GATE {name} {verdict} {result.get('number', '-')} {json.dumps(result)}", flush=True)
    if args.out:
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        rows = ["| gate | verdict | number | why |", "|---|---|---|---|"]
        for r in results:
            (out / f"{r['gate']}.json").write_text(json.dumps(r, indent=2) + "\n")
            verdict = "PASS" if r.get("ok") else ("NO" if r.get("ran") else "NOT-RUN")
            rows.append(f"| {r['gate']} | {verdict} | {r.get('number', '-')} | {r.get('why') or ''} |")
        (out / "summary.md").write_text("\n".join(rows) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
