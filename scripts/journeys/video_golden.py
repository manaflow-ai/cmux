#!/usr/bin/env python3
"""Judges one video case run against its golden and appends the verdict to the golden ledger (VIDEO EXTRA item 9).

    video_golden.py --case ID --run RUN_DIR [--golden DIR] [--ledger DIR] [--dry-run]

The dogfood smoke gate (smoke-gate.py golden_blockers) refuses a .pass while a case listed in
handoff/video-goldens.txt has no PASS, or has a FAIL, on the build in the ledger (<ledger>/<JOB>.jsonl). This script
writes those rows. A golden is the clean run of the case on the build that fixed the finding: its folder holds the
journey's result.json, the movie files (<name>.mov, .frames.json, .trace.json, .meta.json) and, for a typing case,
the judge output (<name>.judge.json).

Verdict of a run (status pass or fail; "not run" rows are not written: they decide nothing):
  - the journey's own status must be pass (results.jsonl);
  - routing-*: every routing_marker attempt is `right` (ext_routing.py);
  - typing-*: typing/judge.py on the run's movie: no shrink or blank defect, no key missing, and p95 and max at most
    one refresh worse than the golden's (or than 1 refresh, with no golden);
  - every case with a golden trace: the last trace sample's pane rects equal the golden's within 1 point each (the
    end layout; the typed text has a new nonce each run, so content is judged by the case's judge, not by pixels).
Each row: case, status, reason, build_job, commit, kit, kit_dirty, out, golden, metrics.
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEDGER = Path("/Users/lawrence/fun/wt/handoff/video-golden-results")
VENV_PY = "/work/tmp/video-extra/venv/bin/python"


def journey_row(run, case):
    for line in (run / "results.jsonl").read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == case:
            return row
    return None


def routing_verdict(run, case):
    sys.path.insert(0, str(HERE / "routing"))
    import tally
    rows = list(tally.attempts(run))
    bad = [r for r in rows if r.get("verdict") != "right"]
    return (not bad and bool(rows)), {"attempts": len(rows), "not_right": [(r["attempt"], r["verdict"]) for r in bad]}


def typing_verdict(run, case, golden):
    video = next((run / case / "video").glob("*.mov"), None)
    if video is None:
        return False, {"error": "no movie"}
    out = video.with_suffix(".judge.json")
    done = subprocess.run([VENV_PY, str(HERE / "typing" / "judge.py"), "--video", str(video),
                           "--frames", f"{video}.frames.json", "--keys", str(run / case / "result.json"),
                           "--out", str(out)], capture_output=True, text=True)
    if done.returncode != 0 or not out.is_file():
        return False, {"error": f"judge exit {done.returncode}: {done.stderr[-300:]}"}
    rep = json.loads(out.read_text())
    if "summary" not in rep:
        return False, {"error": rep.get("error"), "band": rep.get("band")}
    s = rep["summary"]
    base = {"p95": 1, "max": 1}
    if golden:
        g = next(Path(golden).glob("*.judge.json"), None)
        if g:
            base = json.loads(g.read_text()).get("summary") or base
    kinds = sorted({d["kind"] for d in rep.get("defects", []) if d["kind"] in ("shrink", "blank")})
    problems = []
    if kinds:
        problems.append(f"defects {kinds}")
    if s.get("missing"):
        problems.append(f"{s['missing']} keys never shown")
    for key in ("p95", "max"):
        if s.get(key) is None or s[key] > (base.get(key) or 1) + 1:
            problems.append(f"{key} {s.get(key)} refreshes > golden {base.get(key)} + 1")
    return not problems, {"summary": s, "golden": base, "problems": problems}


def end_layout(run, case, golden):
    """(ok, detail): the last trace sample's pane rects against the golden's, 1 point each."""
    if not golden:
        return True, {"skipped": "no golden"}
    mine = sorted((run / case / "video").glob("*.trace.json"))
    theirs = sorted(Path(golden).glob("*.trace.json"))
    if not mine or not theirs:
        return True, {"skipped": "no trace"}
    problems = []
    for a, b in zip(mine, theirs):
        sa = (json.loads(a.read_text()).get("samples") or [{}])[-1]
        sb = (json.loads(b.read_text()).get("samples") or [{}])[-1]
        ra = sorted([round(v, 1) for v in p[1:5]] for p in sa.get("panes") or [])
        rb = sorted([round(v, 1) for v in p[1:5]] for p in sb.get("panes") or [])
        if len(ra) != len(rb) or any(abs(x - y) > 1.0 for pa, pb in zip(ra, rb) for x, y in zip(pa, pb)):
            problems.append(f"{a.name}: end panes {ra} != golden {rb}")
    return not problems, {"problems": problems}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--case", required=True)
    ap.add_argument("--run", required=True)
    ap.add_argument("--golden")
    ap.add_argument("--ledger", default=str(LEDGER))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    run = Path(a.run)
    row = journey_row(run, a.case)
    try:
        steps = json.loads((run / a.case / "result.json").read_text()).get("steps", [])
    except (OSError, ValueError):
        steps = []
    envs = [st.get("result") for st in steps if st.get("do") == "env_windows" and isinstance(st.get("result"), dict)]
    if not envs or any(e.get("smoke_env") for e in envs):
        # cmux-ad 01:30Z: a round with a host dialog open (or no record of the host) is SMOKE ENV, not a result.
        print(f"{a.case}: SMOKE ENV ({'no env record' if not envs else 'a host dialog was open'}): no ledger row")
        return 75
    if row is None or row.get("status") not in ("pass", "fail"):
        print(f"{a.case}: not run ({(row or {}).get('reason', 'no result')}): no ledger row")
        return 75
    if row["status"] == "fail":
        ok, metrics = False, {"journey": row.get("reason")}
    elif a.case.startswith("routing-"):
        ok, metrics = routing_verdict(run, a.case)
    elif a.case.startswith("typing-"):
        ok, metrics = typing_verdict(run, a.case, a.golden)
    else:
        ok, metrics = True, {}
    lay_ok, lay = end_layout(run, a.case, a.golden)
    status = "pass" if ok and lay_ok else "fail"
    out = {"case": a.case, "status": status, "build_job": row.get("build_job"), "commit": row.get("commit"),
           "kit": row.get("kit"), "kit_dirty": row.get("kit_dirty"), "out": str(run), "golden": a.golden,
           "reason": "" if status == "pass" else json.dumps({"case": metrics, "layout": lay})[:400],
           "metrics": metrics, "layout": lay, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    print(json.dumps(out))
    if not a.dry_run and row.get("build_job"):
        ledger = Path(a.ledger)
        ledger.mkdir(parents=True, exist_ok=True)
        with open(ledger / f"{row['build_job']}.jsonl", "a") as f:
            f.write(json.dumps(out) + "\n")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
