#!/usr/bin/env python3
"""Queue the idle CPU measure of one fleet build on one perf mini, through the mini scheduler.

    idle-cpu-run.py --build JOB|--tag TAG [--mini cmux21] [--minutes 10] [--chats 0] [--windows 3]
                    [--window 60] [--ref SHA] [--agent-id HEX17] [--label NAME] [--wait]

It measures "idle CPU and wakeups of the app, its acpmux and its cmux-tui after MINUTES idle"
(scripts/measure/idle-cpu.sh, scripts/cmux-next/idle_cpu.py): a fresh-home launch of the build's exact app,
Home in its first window, CHATS agent chats with a finished turn (0 = none), MINUTES with no user action,
then WINDOWS windows of WINDOW seconds: CPU % and wakeups/s per process, `sample` of every acpmux and
cmux-tui daemon. Run on the fleet host that runs the mini scheduler (cmux-orchestrator-1), never on a
person's Mac. It writes one "once" bench spec to mini-queue/specs/ (the scheduler places it on MINI when
the mini is free; never cmux16 or cmux20) and prints the spec id. --wait follows mini-queue/results.jsonl
and prints the job's IDLE-CPU lines when it ends.

--ref is the commit whose scripts/measure/idle-cpu.sh the step runs (default: the newest
origin/feat-cmux-next that has it, else this checkout's HEAD; it must be pushed). The build under test is
--build/--tag, whatever --ref is.
Exit 0: queued (with --wait: the measure passed). 1: with --wait, over budget. 2: usage. 3: could not queue
or the job gave no verdict.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

QUEUE = Path(os.environ.get("MSCHED_DIR", "/work/wt/chrome-parity-design/mini-queue"))
BUILDER_LOG = Path(os.environ.get("IDLE_CPU_BUILDER_LOG", "/work/wt/chrome-parity-design/feat-dogfood-builder.log"))
CI = os.path.expanduser("~/.local/bin/cmux-ci")
MINIS = ("cmux18", "cmux19", "cmux21", "cmux22", "cmux23", "cmux24")
SCRIPT = "scripts/measure/idle-cpu.sh"
VERDICT = Path(__file__).resolve().parent / "idle_cpu_verdict.py"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False,
                          cwd=Path(__file__).resolve().parent).stdout.strip()


def resolve_build(build: str | None, tag: str | None) -> dict:
    if tag:
        found = None
        if BUILDER_LOG.exists():
            for line in BUILDER_LOG.read_text(errors="replace").splitlines():
                m = re.search(r"built (\S+) job ([0-9a-f]{24})", line)
                if m and m.group(1) == tag:
                    found = m.group(2)
        if not found:
            raise SystemExit(f"idle-cpu-run: no build job for tag {tag} in {BUILDER_LOG}; pass --build JOB")
        build = found
    if not build or not re.fullmatch(r"[0-9a-f]{6,24}", build):
        raise SystemExit("idle-cpu-run: --build must be a job id (hex)")
    out = subprocess.run([CI, "status", build], capture_output=True, text=True, timeout=120)
    try:
        job = json.loads(out.stdout)
    except ValueError:
        raise SystemExit(f"idle-cpu-run: cmux-ci status {build}: {(out.stdout + out.stderr).strip()[:300]}")
    if job.get("state") != "done" or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(job.get("artifact") or "")):
        raise SystemExit(f"idle-cpu-run: build {job.get('id')} is {job.get('state')} with artifact {job.get('artifact')}")
    return {"id": job["id"], "artifact": job["artifact"], "tag": job.get("tag") or "", "ref": job.get("ref") or ""}


def default_ref() -> str:
    """The newest origin/feat-cmux-next when it has the measure script, else this checkout's HEAD."""
    git("fetch", "-q", "origin", "feat-cmux-next")
    tip = git("rev-parse", "origin/feat-cmux-next")
    has = subprocess.run(["git", "cat-file", "-e", f"{tip}:{SCRIPT}"], cwd=Path(__file__).resolve().parent,
                         capture_output=True).returncode == 0
    return tip if tip and has else git("rev-parse", "HEAD")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    which = ap.add_mutually_exclusive_group(required=True)
    which.add_argument("--build")
    which.add_argument("--tag")
    ap.add_argument("--mini", default="", help="one of " + ", ".join(MINIS) + " (default: any of them)")
    ap.add_argument("--minutes", type=float, default=10.0)
    ap.add_argument("--chats", type=int, default=0)
    ap.add_argument("--history", type=int, default=0, help="Claude and Codex chats seeded in the fresh home")
    ap.add_argument("--history-prompt-kb", type=int, default=0, help="each seeded Codex row's prompt size in KB")
    ap.add_argument("--writers", type=float, default=0.0,
                    help="outside agents: one Codex DB write and one Claude line every this many seconds (0: none)")
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--window", type=float, default=60.0)
    ap.add_argument("--sample-each-window", action="store_true", help="`sample` the busiest process after each window")
    ap.add_argument("--ref", default="")
    ap.add_argument("--agent-id", default=os.environ.get("CMUX_AGENT_ID", ""))
    ap.add_argument("--label", default="")
    ap.add_argument("--wait", action="store_true")
    ap.add_argument("--wait-hours", type=float, default=6.0,
                    help="with --wait: give up after this long; a spec not started by then is withdrawn")
    ap.add_argument("--json", action="store_true",
                    help="with --wait: the last stdout line is the step's IDLE-CPU-JSON object (or a one-line reason)")
    a = ap.parse_args(argv)
    if (a.windows < 1 or a.window <= 0 or a.minutes < 0 or a.chats < 0 or a.history < 0 or a.history_prompt_kb < 0
            or a.writers < 0 or not all(math.isfinite(x) for x in (a.window, a.minutes, a.writers))
            or (a.writers > 0 and a.history <= 0)):
        print("idle-cpu-run: --windows >= 1, --window > 0; --minutes, --chats, --history, --history-prompt-kb and "
              "--writers >= 0 and finite; --writers needs --history", file=sys.stderr)
        return 2
    if a.mini and a.mini not in MINIS:
        print(f"idle-cpu-run: --mini must be one of {', '.join(MINIS)}", file=sys.stderr)
        return 2
    try:
        build = resolve_build(a.build, a.tag)
    except SystemExit as error:
        print(f"idle CPU not measured: {error}" if a.json else error, file=sys.stdout if a.json else sys.stderr)
        return 3
    ref = a.ref or default_ref()
    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        print(f"idle-cpu-run: --ref must be a 40-hex pushed commit (got {ref!r})", file=sys.stderr)
        return 2
    label = a.label or f"{build['id'][:8]}-{int(a.minutes)}m-c{a.chats}"
    sid = re.sub(r"[^A-Za-z0-9_.-]", "-", f"idle-cpu-{label}-{int(time.time())}")
    minutes_total = int(a.minutes + a.windows * a.window / 60 + 25 + 4 * a.chats)  # each chat: up to 240 s to make
    spec = {
        "name": f"IDLE CPU: build {build['id'][:8]} ({build['tag']}) idle {a.minutes:g} min, {a.chats} finished chats",
        "owner": "IDLE CPU" + (f" agent {a.agent_id}" if a.agent_id else ""),
        "kind": "bench", "recur": "once", "priority": 6, "minutes": minutes_total, "ref": ref,
        "minis": [a.mini] if a.mini else list(MINIS),
        "cmux_ci_args": ["--measurement", "--label", "measure", "--label", "gui-session-v1",
                         "--script", SCRIPT, f"--arg=artifact={build['artifact']}", f"--arg=minutes={a.minutes:g}",
                         f"--arg=chats={a.chats}", f"--arg=history={a.history}", f"--arg=prompt_kb={a.history_prompt_kb}", f"--arg=writers={a.writers:g}", f"--arg=windows={a.windows}", f"--arg=window={a.window:g}", f"--arg=sample={'each' if a.sample_each_window else 1}",
                         "--artifact", ".build/idle-cpu/report.tgz", "--timeout", str(minutes_total * 60)],
        "verdict": str(VERDICT),
        "note": f"build {build['id']} commit {build['ref']}; scripts/cmux-next/idle-cpu-run.py",
    }
    if re.fullmatch(r"[0-9a-f]{17}", a.agent_id):
        spec["agent_id"] = a.agent_id
        spec["fleet_wait"] = f"IDLE CPU: {label}"
    path = QUEUE / "specs" / f"{sid}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(spec, indent=1) + "\n")
    os.replace(tmp, path)
    print(f"idle-cpu-run: queued spec {sid} (build {build['id']}, ref {ref[:12]}, "
          f"{'mini ' + a.mini if a.mini else 'any perf mini'}); results: {QUEUE / 'results.jsonl'}")
    if not a.wait:
        return 0
    results = QUEUE / "results.jsonl"
    seen = results.stat().st_size if results.exists() else 0

    def withdraw(why: str) -> int:
        """Gives up the wait: a spec the scheduler has not started is removed (its mini is not spent for nobody);
        a job already started runs to its end (cancelling a measurement mid-way frees nothing)."""
        try:
            state = json.loads((QUEUE / "state.json").read_text())
        except (OSError, ValueError):
            state = {}
        # Started: the scheduler submitted it (an entry in "running") or it already ran once ("runs").
        started = any(r.get("spec") == sid for r in (state.get("running") or {}).values()) \
            or bool(((state.get("specs") or {}).get(sid) or {}).get("runs"))
        if not started:
            try:
                path.unlink()
                why += "; the spec was withdrawn before it started"
            except OSError:
                pass
        print(f"idle CPU not measured: {why} (spec {sid})")
        return 3

    def stop(signum, _frame):
        raise SystemExit(withdraw(f"the wait was stopped (signal {signum})"))

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    deadline = time.time() + a.wait_hours * 3600
    while time.time() < deadline:
        time.sleep(30)  # a fleet-host wrapper: the scheduler appends the result when the job ends
        if not results.exists():
            continue
        with open(results, encoding="utf-8") as handle:
            handle.seek(seen)
            for line in handle:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("spec") != sid:
                    continue
                print(json.dumps(rec))
                job = rec.get("job") or ""
                verdict = str(rec.get("verdict") or "")
                payload = None
                if job:
                    log = subprocess.run([CI, "log", job], capture_output=True, text=True, timeout=300).stdout
                    print("\n".join(l for l in log.splitlines() if "IDLE-CPU" in l and "IDLE-CPU-JSON" not in l))
                    found = re.findall(r"IDLE-CPU-JSON (\{.*\})\s*$", log, re.M)
                    payload = found[-1] if found else None
                measured = verdict.startswith(("PASS", "FAIL"))
                if a.json:
                    # Numbers only from a run that measured the daemons (PASS or FAIL); else the reason.
                    if payload and measured:
                        obj = json.loads(payload)
                        obj.update(verdict=verdict.split(" ", 1)[0], build=build["id"], job=job, mini=rec.get("mini"))
                        print(json.dumps(obj, sort_keys=True))
                    else:
                        print(f"idle CPU not measured: {verdict or 'no verdict'} (job {job or 'none'})"[:400])
                return 0 if verdict.startswith("PASS") else 1 if verdict.startswith("FAIL") else 3
            seen = handle.tell()
    return withdraw(f"no result in {a.wait_hours:g} h")


if __name__ == "__main__":
    sys.exit(main())
