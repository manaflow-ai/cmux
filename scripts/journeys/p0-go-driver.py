#!/usr/bin/env python3
"""One P0 journey round per mini-scheduler GO (P0 STATUS 1584, owner acab353f2b81d32f6; adapted from the close-then-type
owner's /work/tmp/p0ct/go-driver.py).

    p0-go-driver.py SPEC BUILD ARM JOURNEY [--judged N] [--max M]

For each GO of SPEC (mini-queue/rounds/SPEC.go {"host","until","go"}) it runs ONE round of JOURNEY on that host (run.py
--whole-host --exclusive: the whole mini, the app launched active) from THIS checkout, then writes rounds/SPEC.done.

Pinned and reviewed checkout only (coordinator 2026-10-31 16:2xZ): the driver refuses to start when this checkout has
uncommitted changes under scripts/journeys or HEAD is not detached, or when /work/tmp/p0csf/reviews/<HEAD sha>.md does not
start with "Review (<reviewer>): SHIP at <HEAD sha>". So no round of an unreviewed kit can be counted.

Symmetric counting: EVERY attempt is one line in /work/tmp/p0csf/attempts.log: pass, fail or not run. A "not run"
attempt is listed and counted as an attempt, never as a pass or a fail. The driver stops after N judged rounds (pass or
fail, default 5) or M attempts (default 8), whichever comes first, or when SPEC's spec file is removed."""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

MQ = Path("/work/wt/chrome-parity-design/mini-queue")
ROUNDS = MQ / "rounds"
WORK = Path("/work/tmp/p0csf")
LOG = WORK / "attempts.log"
KIT = Path(__file__).resolve().parents[2]
RUN = KIT / "scripts" / "journeys" / "run.py"
AGENT = "acab353f2b81d32f6"


def note(line):
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%H:%M:%SZ', time.gmtime())} {line}\n")


def git(*args):
    return subprocess.run(["git", "-C", str(KIT), *args], capture_output=True, text=True, check=True).stdout.strip()


def reviewed_head():
    """The checkout's HEAD sha when it is detached, clean under scripts/journeys and has a SHIP receipt; else exits."""
    head = git("rev-parse", "HEAD")
    if git("status", "--porcelain", "--", "scripts/journeys"):
        sys.exit(f"refused: uncommitted changes under scripts/journeys in {KIT}")
    if subprocess.run(["git", "-C", str(KIT), "symbolic-ref", "-q", "HEAD"], capture_output=True).returncode == 0:
        sys.exit(f"refused: {KIT} is on a branch; run from a detached checkout at the reviewed sha")
    receipt = WORK / "reviews" / f"{head}.md"
    first = receipt.read_text().splitlines()[0].strip() if receipt.exists() else ""
    if not (first.startswith("Review (") and first.endswith(f"): SHIP at {head}")):
        sys.exit(f"refused: no SHIP receipt for {head} at {receipt} (first line: {first!r})")
    return head


def main():
    p = argparse.ArgumentParser()
    p.add_argument("spec"); p.add_argument("build"); p.add_argument("arm"); p.add_argument("journey")
    p.add_argument("--judged", type=int, default=5); p.add_argument("--max", type=int, default=8)
    a = p.parse_args()
    head = reviewed_head()
    note(f"{a.spec} driver start: kit {head} (reviewed), build {a.build}, arm {a.arm}, journey {a.journey}")
    judged = attempts = 0
    while judged < a.judged and attempts < a.max:
        if not (MQ / "specs" / f"{a.spec}.json").exists():
            note(f"{a.spec} spec removed; driver stops")
            break
        go = ROUNDS / f"{a.spec}.go"
        if not go.exists():
            time.sleep(10); continue
        try:
            g = json.loads(go.read_text())
        except (OSError, ValueError):
            time.sleep(5); continue
        host = g.get("host")
        if not host or host in ("cmux16", "cmux17"):
            time.sleep(10); continue
        done_file = ROUNDS / f"{a.spec}.done"
        if done_file.exists() and done_file.stat().st_mtime >= go.stat().st_mtime:
            time.sleep(10); continue  # this GO already had its round
        if git("rev-parse", "HEAD") != head:
            note(f"{a.spec} refused: the kit's HEAD moved from {head}; driver stops"); break
        attempts += 1
        out = WORK / "rounds" / a.spec / f"a{attempts}-{time.strftime('%H%M%S', time.gmtime())}"
        out.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, CMUX_AGENT_ID=AGENT, CAPTURE_HOST_POOL="perf-lead", CAPTURE_HOST_HOSTS=host,
                   CAPTURE_HOST_SLOT_HOSTS=host, CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS="600",
                   JOURNEYS_EXCLUDE_HOSTS="cmux16 cmux17")
        cmd = ["python3", str(RUN), "--build", a.build, "--journey", a.journey, "--exclusive", "--whole-host",
               "--hosts", host, "--out", str(out)]
        with open(f"{out}.run.log", "w") as log:
            code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, cwd=str(WORK)).returncode
        status, reason = "no result", ""
        try:
            row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
            status, reason = row["status"], row.get("reason", "")
        except (OSError, ValueError, KeyError, IndexError):
            pass
        done = status if status in ("pass", "fail") else "not run"
        done_file.write_text(json.dumps({"at": int(time.time()), "status": done, "go": g.get("go"), "host": host}))
        if done in ("pass", "fail"):
            judged += 1
        note(f"{a.spec} {a.arm} a{attempts} {host} exit={code} {status} {reason[:300]} "
             f"(attempt {attempts}, judged {judged}/{a.judged}, kit {head[:12]}, out {out})")
    note(f"{a.spec} driver done: {attempts} attempts, {judged} judged, kit {head[:12]}")


if __name__ == "__main__":
    main()
