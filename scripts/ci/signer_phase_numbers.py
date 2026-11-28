#!/usr/bin/env python3
"""Per-phase numbers for the signer service (docs/design/signer-service.md in cmuxterm-hq).

The design's measurement plan asks for these phases: upload and download of the
handoff, admit, the Linux sign pass, notary rounds (count and minutes), verify
and smoke, and publish. This prints them from step timings in the GitHub API,
one harness for before and after:

  --profile linux-signer   cmux-next-dev-daily.yml publish runs. They are the
                           design's option R today: a Mac builds unsigned, an
                           ephemeral Linux job admits and signs, Linux notarizes,
                           a Mac without secrets verifies, Linux publishes.
  --profile nightly-next-one  nightly.yml runs on nightly-next: the one job that
                           builds, signs, notarizes, verifies and publishes on the
                           signing Mac (the design's baseline). Its handoff
                           phases are the migration step 1 shadow upload, read
                           when vars.NIGHTLY_SIGNER_SHADOW is on.

Reads only (gh api). Output: a markdown table, plus --json for the raw rows.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = "manaflow-ai/cmux"
# A finished run's jobs and logs never change: kept here, so a rerun reads nothing again.
CACHE = Path(os.environ.get("SIGNER_PHASE_CACHE", Path.home() / ".cache" / "signer-phase-numbers"))
# The shared broker counts reads of a run's jobs (30 runs per 10 min); stay under it.
PACE_SECONDS = float(os.environ.get("SIGNER_PHASE_PACE", "21"))
_last_read = [0.0]


def gh(path: str, raw: bool = False):
    for attempt in range(4):
        out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
        if out.returncode == 0 or "retry after" not in out.stderr:
            break
        # The broker's read pool asks for a short back-off; honor it.
        time.sleep(30 * (attempt + 1))
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path}: {out.stderr.strip()[:300]}")
    return out.stdout if raw else json.loads(out.stdout)


def ts(value: str | None) -> float | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def dur(start: str | None, end: str | None) -> float | None:
    a, b = ts(start), ts(end)
    return None if a is None or b is None else b - a


def job_named(jobs, pattern):
    for job in jobs:
        if re.search(pattern, job["name"]) and job.get("conclusion") == "success":
            return job
    return None


def steps_sum(job, pattern):
    """Seconds spent in the steps whose name matches; None when none ran."""
    if not job:
        return None
    total, hit = 0.0, False
    for step in job.get("steps", []):
        if step.get("conclusion") in (None, "skipped") or not re.search(pattern, step["name"]):
            continue
        d = dur(step.get("started_at"), step.get("completed_at"))
        if d is not None:
            total += d
            hit = True
    return total if hit else None


def queue(job):
    return dur(job["created_at"], job["started_at"]) if job else None


def span(job):
    return dur(job["started_at"], job["completed_at"]) if job else None


def add(*parts):
    vals = [p for p in parts if p is not None]
    return sum(vals) if vals else None


def cached(name, fetch, raw=False):
    path = CACHE / name
    if path.exists():
        text = path.read_text()
        return text if raw else json.loads(text)
    wait = _last_read[0] + PACE_SECONDS - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    value = fetch()
    _last_read[0] = time.monotonic()
    CACHE.mkdir(parents=True, exist_ok=True)
    path.write_text(value if raw else json.dumps(value))
    return value


def jobs_of(run_id):
    return cached(f"jobs-{run_id}.json", lambda: gh(f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100")["jobs"])


def notary_rounds(job_id):
    """Rounds and Apple-side minutes from the rcodesign notary log lines."""
    try:
        log = cached(f"log-{job_id}.txt", lambda: gh(f"repos/{REPO}/actions/jobs/{job_id}/logs", raw=True), raw=True)
    except RuntimeError as err:
        print(f"notary log of job {job_id} not read: {err}", file=sys.stderr)
        return None, None
    rounds = len(re.findall(r"created submission ID: ", log))
    polls = [int(s) for s in re.findall(r"poll state after (\d+)s: Accepted", log)]
    return rounds, (sum(polls) if polls else None)


def linux_signer_row(run):
    jobs = jobs_of(run["id"])
    sign = job_named(jobs, r"^Sign cmux NEXT DEV$")
    verify = job_named(jobs, r"^Verify signed cmux NEXT DEV$")
    publish = job_named(jobs, r"^Publish cmux NEXT DEV$")
    tip_sign = job_named(jobs, r"^Sign, notarize and staple")
    tip_feed = job_named(jobs, r"^Publish the cmux NEXT DEV tip feed$")
    build_signer = job_named(jobs, r"^Build the signer$")
    row = {"run": run["id"], "created": run["created_at"]}
    m = re.search(r"publish (\d+)", run.get("display_title") or "")
    if m:
        src_jobs = jobs_of(m.group(1))
        compile_job = job_named(src_jobs, r"^cmux NEXT DEV Release compile$")
        request = job_named(src_jobs, r"^Request cmux NEXT DEV publication$")
        row["handoff_upload"] = steps_sum(compile_job, r"^Upload the cmux NEXT DEV Release app$")
        row["sign_run_creation_delay"] = dur(request["completed_at"], run["created_at"]) if request else None
    row["build_signer"] = span(build_signer)
    row["signer_queue"] = queue(sign)
    row["handoff_download"] = steps_sum(sign, r"^Download the exact Release app artifact$")
    row["admit"] = steps_sum(sign, r"^(Resolve the source run|Require a successful app-producing job|Unpack and verify channel identity)$")
    row["linux_sign"] = steps_sum(sign, r"^(Sign and verify cmux NEXT DEV|Package the signed app|Upload the signed app)$")
    row["sign_job"] = span(sign)
    if tip_sign:
        row["notary_step"] = steps_sum(tip_sign, r"notarize")
        row["notary_rounds"], row["notary_apple_wait"] = notary_rounds(tip_sign["id"])
    row["verify_smoke"] = add(queue(verify), span(verify))
    row["publish"] = add(queue(publish), span(publish), queue(tip_feed), span(tip_feed))
    ends = [ts(j["completed_at"]) for j in jobs if j.get("conclusion") == "success" and not j["name"].startswith("Delete ")]
    row["run_wall"] = (max(ends) - ts(run["created_at"])) if ends else None
    return row


def nightly_row(run):
    jobs = jobs_of(run["id"])
    one = job_named(jobs, r"^nightly-next-one$")
    if not one:
        return None
    return {
        "run": run["id"],
        "created": run["created_at"],
        "job_queue": queue(one),
        "job_wall": span(one),
        "handoff_upload": steps_sum(one, r"for signer shadow$"),
        "compile": steps_sum(one, r"^Build nightly app \(Release\)$"),
        "sign": steps_sum(one, r"^(Import signing cert|Embed channel provisioning profile|Codesign apps|Delete signing keychain before runtime checks)$"),
        "notary_step": steps_sum(one, r"^Notarize app ticket through final DMG$"),
        # notarize-nightly-dmg.sh with CMUX_STAPLE_APP_IN_DMG=false makes one DMG submission.
        "notary_rounds": 1,
        "verify_smoke": steps_sum(one, r"^(Gate distribution with syspolicy_check|Restore signed app|Verify |Run bundled Ghostty|Launch smoke from a fresh home)"),
        "publish": steps_sum(one, r"^(Generate Sparkle appcasts|Prepare nightly release notes|Final publication gate|Publish the nightly-next download to R2|Upload nightly-next appcasts to R2|Upload the published feed|Read the live nightly-next feed|Take the nightly-next publish lease|Release the nightly-next publish lease|Require every DMG to match)"),
    }


def list_runs(profile, count):
    if profile == "linux-signer":
        path = f"repos/{REPO}/actions/workflows/cmux-next-dev-daily.yml/runs?status=success&per_page={min(100, count * 3)}"
        runs = [r for r in gh(path)["workflow_runs"] if "publish" in (r.get("display_title") or "")]
    else:
        path = f"repos/{REPO}/actions/workflows/nightly.yml/runs?branch=nightly-next&status=success&per_page={min(100, count * 2)}"
        runs = gh(path)["workflow_runs"]
    return runs[: count * 2]


def pct(values, p):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def summarize(rows):
    keys = [k for k in rows[0] if k not in ("run", "created")] if rows else []
    out = []
    for key in keys:
        vals = [r[key] for r in rows if r.get(key) is not None]
        if not vals:
            out.append((key, 0, None, None, None))
            continue
        out.append((key, len(vals), pct(vals, 50), pct(vals, 90), statistics.fmean(vals)))
    return out


def fmt(v, key):
    if v is None:
        return "not measured"
    return f"{v:.1f}" if key == "notary_rounds" else f"{v:.0f} s"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", choices=["linux-signer", "nightly-next-one"], required=True)
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    rows = []
    for run in list_runs(args.profile, args.count):
        if len(rows) >= args.count:
            break
        row = linux_signer_row(run) if args.profile == "linux-signer" else nightly_row(run)
        if row:
            rows.append(row)
    if args.json:
        json.dump(rows, sys.stdout, indent=1)
        print()
        return 0
    first = min((r["created"] for r in rows), default="-")
    last = max((r["created"] for r in rows), default="-")
    print(f"profile {args.profile}: n={len(rows)} successful runs, {first} to {last}\n")
    print("| phase | n | p50 | p90 | mean |\n|---|---|---|---|---|")
    for key, n, p50, p90, mean in summarize(rows):
        print(f"| {key} | {n} | {fmt(p50, key)} | {fmt(p90, key)} | {fmt(mean, key)} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
