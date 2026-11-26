#!/usr/bin/env python3
"""Owned-Mac job-hours per day and queue wait, for one job (by its GitHub name) and for every Mac job.

measure: what a job costs the owned Macs and how long Mac jobs wait, before and after a job moves off the Mac
(Leo, 2026-11-25: "if we can build on linux for the mac and ios related things ... can't we nearly 100x reduce the
amount we need to wait on mac fleet?"). The data is ci-dash's owned-Mac job log, one gzip CSV a day, in cmuxterm-hq
at build-fleet/data/YYYY/MM/DD/jobs.csv.gz (the source of RFD 0162's numbers). Fetch a day with
  gh api repos/manaflow-ai/cmuxterm-hq/contents/build-fleet/data/2026/11/24/jobs.csv.gz \
    -H "Accept: application/vnd.github.raw" > DIR/2026/11/24/jobs.csv.gz
then run
  python3 -I scripts/measure/mac-job-hours.py --data DIR --job "cmux-next generated files" 2026-11-23 2026-11-24
It prints JSON: per day and in all, the job's runs, job-h/day and queue p50/p95 (minutes), and every Mac job's
queue p50/p95. A name matches exactly or as "NAME (...)" (the Mac fallback is "cmux-next generated files (Mac
fallback)"), so the shared-build verdict job, which runs on Linux, is never counted.
"""
import argparse, csv, gzip, json, os, sys


def pct(values, q):
    values = sorted(values)
    return round(values[min(len(values) - 1, int(q * len(values)))] / 60, 1) if values else None


def matches(name, job):
    return name == job or (name.startswith(job + " (") and not name.startswith(job + " (shared build)"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="the directory holding YYYY/MM/DD/jobs.csv.gz")
    ap.add_argument("--job", required=True, help="the job's GitHub name")
    ap.add_argument("days", nargs="+", help="YYYY-MM-DD")
    a = ap.parse_args()
    out = {"job": a.job, "days": {}}
    tot_s = tot_n = 0
    all_q, job_q = [], []
    for day in a.days:
        y, m, d = day.split("-")
        path = os.path.join(a.data, y, m, d, "jobs.csv.gz")
        try:
            rows = list(csv.DictReader(gzip.open(path, "rt")))
        except (OSError, EOFError) as e:
            print(f"{path}: {e}", file=sys.stderr)
            continue
        s = n = 0
        dq, dj = [], []
        for r in rows:
            if r.get("event") != "completed":
                continue
            q = float(r["queued_s"]) if r.get("queued_s") else None
            if q is not None:
                dq.append(q)
            if matches(r.get("gh_name") or r.get("job") or "", a.job):
                try:
                    s += float(r["seconds"] or 0)
                except ValueError:
                    continue
                n += 1
                if q is not None:
                    dj.append(q)
        out["days"][day] = {"runs": n, "job_h": round(s / 3600, 1), "job_queue_p50_min": pct(dj, .5),
                            "job_queue_p95_min": pct(dj, .95), "mac_queue_p50_min": pct(dq, .5),
                            "mac_queue_p95_min": pct(dq, .95), "mac_jobs": len(dq)}
        tot_s += s; tot_n += n; all_q += dq; job_q += dj
    k = max(len(out["days"]), 1)
    out["all"] = {"runs_per_day": round(tot_n / k, 1), "job_h_per_day": round(tot_s / 3600 / k, 1),
                  "job_queue_p50_min": pct(job_q, .5), "job_queue_p95_min": pct(job_q, .95),
                  "mac_queue_p50_min": pct(all_q, .5), "mac_queue_p95_min": pct(all_q, .95)}
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
