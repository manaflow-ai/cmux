#!/usr/bin/env python3
"""The dogfood smoke gate: a build goes to Lawrence only when the smoke journey passes 10 of 10 rounds.

    scripts/journeys/smoke-gate.py --build JOB [--rounds 10] [--swap-gb 15] [--hosts "cmux17 ..."] [--out DIR]

cmux-ad 2026-10-30 (stop the line, item 2). Runs journeys/dogfood/smoke-dogfood.json once per round through
run.py, each round on its own exclusive capture-host lease (`--exclusive`: no fleet step runs on the mini) with
the Austin's-day memory hog pushing swap toward --swap-gb above the start (`--hog-swap-gb`). Each step of the
journey is checked by the app's own state (socket and CLI reads) and, where the step shows text, a window frame
read by text recognition (run.py keeps each checked frame as <round>/smoke-dogfood/check-NN.png).

Verdict:
  - PASS only when every round's journey status is `pass` (10 of 10 by default). Then it writes
    HANDOFF/<JOB>.pass (default /Users/lawrence/fun/wt/handoff/dogfood-smoke): the summary, the build, every
    round's lease and results, and this gate's own git commit. A gate with uncommitted changes never writes it.
  - FAIL when any round failed: the summary names each failing round, its step and the reason.
  - NOT JUDGED when no round failed but some did not run (no lease, a known gap): no .pass file. A round whose
    type-at-once step could not make the window key (`known gap: ...`) is never a pass.
Writes OUT/summary.json and OUT/summary.txt. Exit 0 PASS, 1 FAIL, 75 NOT JUDGED, 2 usage.
Never run it on a person's Mac: the hog fills the memory up to swap.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
JOURNEY = "smoke-dogfood"
HANDOFF = Path("/Users/lawrence/fun/wt/handoff/dogfood-smoke")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def round_result(out):
    """The smoke journey's line of one round's results.jsonl, or a not-run record."""
    path = out / "results.jsonl"
    if not path.is_file():
        return {"status": "not run", "reason": "run.py wrote no results.jsonl"}
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == JOURNEY:
            return row
    return {"status": "not run", "reason": "results.jsonl has no smoke-dogfood line"}


def failing_step(out):
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return None
    result = json.loads(path.read_text())
    for step in result.get("steps", []):
        if step.get("ok") is False:
            return {"do": step.get("do"), "title": step.get("title"), "error": (step.get("error") or "")[:400]}
    return None


def frames(out):
    return sorted(str(p.relative_to(out)) for p in (out / JOURNEY).glob("check-*.png")) if (out / JOURNEY).is_dir() else []


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--build", required=True, help="the fleet build job id of the app under test")
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--swap-gb", type=float, default=15.0)
    ap.add_argument("--hosts", default="cmux17 cmux18 cmux19 cmux20 cmux21 cmux22 cmux23 cmux24")
    ap.add_argument("--out")
    ap.add_argument("--handoff", default=str(HANDOFF))
    ap.add_argument("--runner", default=str(HERE / "run.py"), help=argparse.SUPPRESS)  # tests: a stand-in for run.py
    opts = ap.parse_args(argv)
    if opts.rounds < 1:
        ap.error("--rounds must be at least 1")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(opts.out) if opts.out else ROOT / "artifacts" / "smoke-gate" / f"{opts.build[:12]}-{stamp}"
    out.mkdir(parents=True, exist_ok=True)
    gate_sha = git("rev-parse", "HEAD").stdout.strip()
    dirty = bool(git("status", "--porcelain", "--", "scripts/journeys").stdout.strip())

    rounds = []
    for n in range(1, opts.rounds + 1):
        round_out = out / f"round-{n:02d}"
        started = time.time()
        done = subprocess.run([sys.executable, opts.runner, "--build", opts.build, "--journey", JOURNEY,
                               "--exclusive", "--hog-swap-gb", str(opts.swap_gb), "--hosts", opts.hosts,
                               "--out", str(round_out)], capture_output=True, text=True)
        (round_out / "run.log").parent.mkdir(parents=True, exist_ok=True)
        (round_out / "run.log").write_text(done.stdout + done.stderr)
        row = round_result(round_out)
        leases = sorted({w for w in (done.stdout + done.stderr).split() if w.startswith("slot-")})
        record = {"round": n, "status": row.get("status"), "reason": row.get("reason"), "host": row.get("host"),
                  "seconds": round(time.time() - started), "failing_step": failing_step(round_out),
                  "frames": frames(round_out), "hog_logs": sorted(p.name for p in round_out.glob("hog-*.jsonl")),
                  "known_gap": "known gap" in str(row.get("reason") or ""), "leases": leases}
        rounds.append(record)
        print(f"round {n}: {record['status']}" + (f" ({record['reason'][:160]})" if record.get("reason") else "")
              + (f" step {record['failing_step']['do']}: {record['failing_step']['error'][:160]}" if record["failing_step"] else ""),
              flush=True)

    passed = sum(1 for r in rounds if r["status"] == "pass")
    failed = [r for r in rounds if r["status"] == "fail"]
    not_run = [r for r in rounds if r["status"] not in ("pass", "fail")]
    verdict = "PASS" if passed == opts.rounds else ("FAIL" if failed else "NOT JUDGED")
    summary = {"build": opts.build, "journey": JOURNEY, "rounds": opts.rounds, "passed": passed,
               "failed": len(failed), "not_run": len(not_run), "verdict": verdict, "swap_gb": opts.swap_gb,
               "gate_commit": gate_sha, "gate_dirty": dirty, "known_gap_rounds": [r["round"] for r in rounds if r["known_gap"]],
               "rounds_detail": rounds, "out": str(out)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    lines = [f"dogfood smoke gate for build {opts.build}: {verdict} ({passed} of {opts.rounds} rounds passed; "
             f"{len(failed)} failed, {len(not_run)} not run; memory hog +{opts.swap_gb} GB swap; gate {gate_sha[:11]}"
             + (" with uncommitted changes" if dirty else "") + ")"]
    if summary["known_gap_rounds"]:
        lines.append(f"KNOWN GAP in rounds {summary['known_gap_rounds']}: the capture slot could not make the window key, "
                     "so keys typed into a new terminal while it is made were not checked; not a pass")
    for r in rounds:
        detail = r["failing_step"] and f"{r['failing_step']['do']}: {r['failing_step']['error'][:200]}"
        lines.append(f"  round {r['round']:2d} on {r['host']}: {r['status']}" + (f" -- {detail}" if detail else "")
                     + (f" -- {(r['reason'] or '')[:200]}" if r["status"] != "pass" and not detail else ""))
    text = "\n".join(lines)
    (out / "summary.txt").write_text(text + "\n")
    print(text)
    if verdict == "PASS":
        if dirty:
            print("smoke-gate: PASS, but the gate has uncommitted changes: no .pass file written", file=sys.stderr)
            return 75
        handoff = Path(opts.handoff)
        handoff.mkdir(parents=True, exist_ok=True)
        (handoff / f"{opts.build}.pass").write_text(json.dumps(summary, indent=1) + "\n")
        print(f"wrote {handoff / (opts.build + '.pass')}")
        return 0
    return 1 if verdict == "FAIL" else 75


if __name__ == "__main__":
    sys.exit(main())
