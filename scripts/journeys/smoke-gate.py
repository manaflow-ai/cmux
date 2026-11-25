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
  - NOT JUDGED when no round failed but some did not run (no lease, a known gap, no memory pressure): no .pass
    file. A round whose type-at-once step could not make the window key (`known gap: ...`) is never a pass, and
    a passed journey counts only when the round's hog log shows memory pressure (pressure() below).
  - TRIAL PASS: every round passed, but with fewer than 10 rounds or less than +15 GB asked of the hog: no .pass.
Each round must write its own results (a new --out folder; results of this build, newer than the round).
  - DIAGNOSTIC (NOT JUDGED), with --diagnostic: where the slot has no key window, the lines are typed after the
    creation hold, not at once; every other step is checked and each check's pass count is reported. Never a .pass
    file (exit 1 when a round failed, else 75).
Writes OUT/summary.json and OUT/summary.txt. Exit 0 PASS, 1 FAIL, 75 NOT JUDGED, 2 usage.
Never run it on a person's Mac: the hog fills the memory up to swap.
"""
import argparse
import json
import re
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
JOURNEY = "smoke-dogfood"
HANDOFF = Path("/Users/lawrence/fun/wt/handoff/dogfood-smoke")
# The perf minis' owner-only pool (hq fleet.json owner_only_hosts): the owner's opt-in for their exclusive lease.
OWNER_POOL = "perf-lead"
# Everything run.py ships to the mini: a change in any of them means the gate is not its commit.
GATE_PATHS = ("scripts/journeys", "scripts/cmux-next/build_names.py", "scripts/ci/pr_media_ocr.swift")
# The gate cmux-ad set (2026-10-30): a .pass file needs at least this many rounds under at least this much hog.
GATE_ROUNDS = 10
GATE_SWAP_GB = 15.0
# A round counts only when its hog log shows memory pressure during the round: the hog held at least
# PRESSURE_HELD_GB, and swap grew by the hog's target or the free-memory level reached the hog's resume band
# (kern.memorystatus_level <= PRESSURE_LEVEL: the hog is at the mini's edge, where it gives memory back).
PRESSURE_HELD_GB = 4.0
PRESSURE_LEVEL = 20
PRESSURE_SAMPLES = 30


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def round_result(out, build, exit_code, started):
    """The smoke journey's line of this round's results.jsonl, or a not-run record: a results file of this
    run.py (written after the round started), for this build, from a run.py that exited 0, 1 or 75."""
    path = out / "results.jsonl"
    if exit_code not in (0, 1, 75):
        return {"status": "not run", "reason": f"run.py exited {exit_code}"}
    if not path.is_file():
        return {"status": "not run", "reason": "run.py wrote no results.jsonl"}
    if path.stat().st_mtime < started:
        return {"status": "not run", "reason": "results.jsonl is older than the round"}
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == JOURNEY:
            if row.get("build_job") != build:
                return {"status": "not run", "reason": f"results.jsonl is for build {row.get('build_job')}, not {build}"}
            return row
    return {"status": "not run", "reason": "results.jsonl has no smoke-dogfood line"}


def idle_first(hosts):
    """Only the hosts with no running fleet step (the controller's `cmux-ci drain` read, no command on a mini), so
    an exclusive acquire does not drain a mini whose step runs for hours while another is idle. All the given
    hosts when the read fails or no mini is idle (then the drain waits, within its budget)."""
    names = hosts.split()
    try:
        done = subprocess.run([os.environ.get("SMOKE_GATE_CMUX_CI", "cmux-ci"), "drain", "--hosts", ",".join(names)], capture_output=True, text=True, timeout=60)
        state = json.loads(done.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return hosts
    idle = [h for h in names if isinstance(state.get(h), dict) and state[h].get("idle") is True]
    return " ".join(idle) if idle else hosts


def exclusive_line(out):
    """capture-host's own word that the round's mini was exclusive ("<host> is exclusive until ...: the fleet
    controller places no step on its workers"), from the acquire's lines run.py keeps; None when it is missing."""
    path = out / "acquire.log"
    if not path.is_file():
        return None
    return next((l.strip() for l in path.read_text(errors="replace").splitlines()
                 if " is exclusive until " in l and "places no step" in l), None)


def pressure(out, swap_gb):
    """What the round's hog logs show: samples, the most it held, swap growth and the lowest free level."""
    rows = []
    for path in sorted(out.glob("hog-*.jsonl")):
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and "held_mb" in row:
                rows.append(row)
    if not rows:
        return {"ok": False, "samples": 0, "why": "no hog log lines"}
    swaps = [float(r.get("swap_used_mb") or 0) for r in rows]
    levels = [int(r["level"]) for r in rows if isinstance(r.get("level"), (int, float))]
    held = max(float(r.get("held_mb") or 0) for r in rows) / 1024
    grown = (max(swaps) - swaps[0]) / 1024
    low = min(levels) if levels else None
    ok = (len(rows) >= PRESSURE_SAMPLES and held >= PRESSURE_HELD_GB
          and (grown >= swap_gb * 0.95 or (low is not None and low <= PRESSURE_LEVEL)))
    return {"ok": ok, "samples": len(rows), "held_gb_max": round(held, 2), "swap_growth_gb": round(grown, 2),
            "level_min": low, "swap_target_reached": grown >= swap_gb * 0.95}


def failing_step(out):
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return None
    result = json.loads(path.read_text())
    for step in result.get("steps", []):
        if step.get("ok") is False:
            return {"do": step.get("do"), "title": step.get("title"), "error": (step.get("error") or "")[:400]}
    return None


def typed_steps(out):
    """The results of the round's smoke_type_now steps (each says `at_once`)."""
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return []
    try:
        steps = json.loads(path.read_text()).get("steps", [])
    except ValueError:
        return []
    return [st.get("result") or {} for st in steps if st.get("do") == "smoke_type_now" and st.get("ok")]


def step_results(out):
    """Each step of the round's journey: index, do, title, ok, error (short), for the per-step report."""
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return []
    try:
        steps = json.loads(path.read_text()).get("steps", [])
    except ValueError:
        return []
    return [{"index": st.get("index"), "do": st.get("do"), "title": st.get("title"), "ok": st.get("ok"),
             "finally": bool(st.get("finally")), "error": (st.get("error") or "")[:300]} for st in steps]


def frames(out):
    return sorted(str(p.relative_to(out)) for p in (out / JOURNEY).glob("check-*.png")) if (out / JOURNEY).is_dir() else []


def expect_table(rounds):
    """For each expect step (by its title): in how many rounds it was reached, passed and failed."""
    table = {}
    for r in rounds:
        for st in r["steps"]:
            if st["do"] != "expect" or st["finally"]:
                continue
            row = table.setdefault(st["title"] or f"step {st['index']}", {"reached": 0, "passed": 0, "failed": 0, "errors": []})
            row["reached"] += 1
            row["passed" if st["ok"] else "failed"] += 1
            if not st["ok"] and len(row["errors"]) < 3:
                row["errors"].append(f"round {r['round']}: {st['error'][:200]}")
    return table


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--build", required=True, help="the fleet build job id of the app under test")
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--swap-gb", type=float, default=15.0)
    ap.add_argument("--hosts", default="cmux17 cmux18 cmux19 cmux20 cmux21 cmux22 cmux23 cmux24")
    ap.add_argument("--out")
    ap.add_argument("--whole-host", metavar="HOST",
                    help="lease this whole mini (exclusive) and launch the app active (--activate), so its window is "
                         "key and every line is typed at once; needs CuaDriver's console grant on HOST")
    ap.add_argument("--diagnostic", action="store_true",
                    help="no type-at-once where the slot has no key window (type after the creation hold); every "
                         "other step is still checked and reported. Verdict DIAGNOSTIC: never a .pass file")
    ap.add_argument("--handoff", default=str(HANDOFF))
    ap.add_argument("--runner", default=str(HERE / "run.py"), help=argparse.SUPPRESS)  # tests: a stand-in for run.py
    opts = ap.parse_args(argv)
    if opts.whole_host and opts.whole_host not in opts.hosts.split():
        ap.error(f"--whole-host {opts.whole_host} is not one of --hosts ({opts.hosts})")
    if opts.rounds < 1:
        ap.error("--rounds must be at least 1")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(opts.out) if opts.out else ROOT / "artifacts" / "smoke-gate" / f"{opts.build[:12]}-{stamp}"
    if out.exists() and any(out.iterdir()):
        ap.error(f"--out {out} is not empty: each gate run needs a new folder (old rounds must never count)")
    out.mkdir(parents=True, exist_ok=True)
    gate_run = opts.rounds >= GATE_ROUNDS and opts.swap_gb >= GATE_SWAP_GB and not opts.diagnostic
    gate_sha = git("rev-parse", "HEAD").stdout.strip()
    dirty = bool(git("status", "--porcelain", "--", *GATE_PATHS).stdout.strip())

    rounds = []
    for n in range(1, opts.rounds + 1):
        round_out = out / f"round-{n:02d}"
        started = time.time() - 1
        # An exclusive lease waits for the mini's running fleet steps (the drain): give it the room the fleet
        # rules set (capture-host's default acquire timeout, 120 s, ends the drain first on a busy fleet).
        # The drain budget is bounded too (capture-host's default is an hour per acquire), so a round on a fleet
        # whose minis run hours-long steps ends as not run instead of waiting for them.
        env = {**os.environ, "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": os.environ.get("CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", "600"),
               "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": os.environ.get("CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS", "900"),
               # The perf minis are owner-only for pool perf-lead (hq fleet.json owner_only_hosts): the controller
               # refuses an exclusive lease there unless it names that owner pool (HTTP 409, trial 4, 2026-10-31).
               # capture-host passes it as `cmux-ci reserve --owner-pool` (hq #5153; refresh an older install).
               "CAPTURE_HOST_POOL": os.environ.get("CAPTURE_HOST_POOL", OWNER_POOL)}
        hosts = opts.whole_host or idle_first(opts.hosts)
        env["CAPTURE_HOST_HOSTS"] = env["CAPTURE_HOST_SLOT_HOSTS"] = hosts
        done = subprocess.run([sys.executable, opts.runner, "--build", opts.build, "--journey", JOURNEY,
                               "--exclusive", "--hog-swap-gb", str(opts.swap_gb), "--hosts", hosts,
                               "--out", str(round_out), *(["--journey-option", "smoke_mode=diagnostic"] if opts.diagnostic else []),
                               *(["--whole-host"] if opts.whole_host else [])],
                              capture_output=True, text=True, env=env)
        (round_out / "run.log").parent.mkdir(parents=True, exist_ok=True)
        (round_out / "run.log").write_text(done.stdout + done.stderr)
        row = round_result(round_out, opts.build, done.returncode, started)
        hog = pressure(round_out, opts.swap_gb)
        if row.get("status") == "pass" and not hog["ok"]:
            row = dict(row, status="not run", reason=f"no memory pressure shown by the hog log: {json.dumps(hog)}")
        typed = typed_steps(round_out)
        late = [st for st in typed if st.get("at_once") is not True] or ([] if typed else [{"none": True}])
        if row.get("status") == "pass" and not opts.diagnostic and late:
            row = dict(row, status="not run", reason=f"{len(late)} smoke_type_now steps were not typed at once "
                                                      "(a diagnostic round is never a gate pass)")
        exclusive = exclusive_line(round_out)
        if row.get("status") == "pass" and not exclusive:
            row = dict(row, status="not run", reason="capture-host did not say the lease's mini was exclusive (acquire.log)")
        # run.py logs "leased <lease>": a slot lease (slot-<host>-<token>) or a whole-host lease (the host alias).
        leases = sorted(set(re.findall(r"\bleased (\S+)", done.stdout + done.stderr)))
        record = {"round": n, "steps": step_results(round_out), "status": row.get("status"), "reason": row.get("reason"), "host": row.get("host"),
                  "seconds": round(time.time() - started), "failing_step": failing_step(round_out),
                  "frames": frames(round_out), "hog_logs": sorted(p.name for p in round_out.glob("hog-*.jsonl")), "pressure": hog, "hosts_offered": hosts, "exclusive": exclusive,
                  "known_gap": "known gap" in str(row.get("reason") or ""), "leases": leases}
        rounds.append(record)
        print(f"round {n}: {record['status']}" + (f" ({record['reason'][:160]})" if record.get("reason") else "")
              + (f" step {record['failing_step']['do']}: {record['failing_step']['error'][:160]}" if record["failing_step"] else ""),
              flush=True)

    passed = sum(1 for r in rounds if r["status"] == "pass")
    failed = [r for r in rounds if r["status"] == "fail"]
    not_run = [r for r in rounds if r["status"] not in ("pass", "fail")]
    verdict = ("PASS" if gate_run else "TRIAL PASS") if passed == opts.rounds else ("FAIL" if failed else "NOT JUDGED")
    if opts.diagnostic:
        # Diagnostic rounds judge nothing: their findings are in the per-step report.
        verdict = "DIAGNOSTIC (NOT JUDGED)"
    summary = {"build": opts.build, "journey": JOURNEY, "rounds": opts.rounds, "passed": passed,
               "failed": len(failed), "not_run": len(not_run), "verdict": verdict, "swap_gb": opts.swap_gb,
               "gate_commit": gate_sha, "gate_dirty": dirty, "gate_run": gate_run, "diagnostic": opts.diagnostic,
               "whole_host": opts.whole_host,
               "expects": expect_table(rounds), "known_gap_rounds": [r["round"] for r in rounds if r["known_gap"]],
               "rounds_detail": rounds, "out": str(out)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    ran = ("journeys completed" if opts.diagnostic else "rounds passed")
    lines = [f"dogfood smoke gate for build {opts.build}: {verdict} ({passed} of {opts.rounds} {ran}; "
             f"{len(failed)} failed, {len(not_run)} not run; memory hog +{opts.swap_gb} GB swap; gate {gate_sha[:11]}"
             + (" with uncommitted changes" if dirty else "") + ")"
             + ("; diagnostic rounds judge nothing, so no .pass file" if opts.diagnostic else
                "" if gate_run else f"; a trial: the gate needs {GATE_ROUNDS} rounds at +{GATE_SWAP_GB:g} GB, so no .pass file")]
    if summary["known_gap_rounds"]:
        lines.append(f"KNOWN GAP in rounds {summary['known_gap_rounds']}: the capture lease could not make the window key, "
                     "so keys typed into a new terminal while it is made were not checked; not a pass")
    if opts.diagnostic:
        lines.append("DIAGNOSTIC: no type-at-once where the slot has no key window; no .pass file. Each check:")
        for title, row in summary["expects"].items():
            lines.append(f"  {row['passed']}/{row['reached']} passed (of {opts.rounds} rounds): {title}"
                         + (f" -- {row['errors'][0]}" if row["errors"] else ""))
    for r in rounds:
        detail = r["failing_step"] and f"{r['failing_step']['do']}: {r['failing_step']['error'][:200]}"
        hog = r["pressure"]
        lines.append(f"  round {r['round']:2d} on {r['host']}: {r['status']}" + (f" -- {detail}" if detail else "")
                     + f" [hog held {hog.get('held_gb_max')} GB, swap +{hog.get('swap_growth_gb')} GB, level min {hog.get('level_min')}]"
                     + (f" -- {(r['reason'] or '')[:200]}" if r["status"] != "pass" and not detail else ""))
    text = "\n".join(lines)
    (out / "summary.txt").write_text(text + "\n")
    print(text)
    if verdict in ("PASS", "TRIAL PASS"):
        if dirty or git("status", "--porcelain", "--", *GATE_PATHS).stdout.strip() \
                or git("rev-parse", "HEAD").stdout.strip() != gate_sha:
            print("smoke-gate: PASS, but the gate has (or got) uncommitted changes: no .pass file written", file=sys.stderr)
            return 75
        if not gate_run:
            print(f"smoke-gate: a trial PASS (--rounds {opts.rounds}, --swap-gb {opts.swap_gb:g}): no .pass file", file=sys.stderr)
            return 75
        handoff = Path(opts.handoff)
        handoff.mkdir(parents=True, exist_ok=True)
        (handoff / f"{opts.build}.pass").write_text(json.dumps(summary, indent=1) + "\n")
        print(f"wrote {handoff / (opts.build + '.pass')}")
        return 0
    return 1 if verdict == "FAIL" or (opts.diagnostic and failed) else 75


if __name__ == "__main__":
    sys.exit(main())
