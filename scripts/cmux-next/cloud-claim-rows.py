#!/usr/bin/env python3
"""cmux Cloud claim-to-ready, p50 and p95 over the newest production claims, as perf cron rows.

    GH_TOKEN=... python3 scripts/cmux-next/cloud-claim-rows.py [--samples 24] [--window-hours 72]

No machine is made here. The hourly production Cloud journey (.github/workflows/cloud-journey-prod.yml,
scripts/cmux-next/cloud-journey.ts) already claims a machine the way the app does every hour, and its probe.json
artifact carries ready_ms: create (the claim: a warm spare when the platform has one, else a cold create) to the
agent running, the sum of cloud-journey.ts READY_STEPS (create machine, running, first exec, the login, start agent).
This reads the newest --samples of those rows within --window-hours (the artifacts keep 3 days) through `gh api` (two
artifact lists by name, then one download per row), and
prints PERF_ROW lines, then {"rows": [...]} on a line of its own: the report perf-cron.py's cloud-claim part reads
(its rows are cloud.claim_to_ready*).

Targets: cmuxterm-hq plans/cloud/ARCHITECTURE-2026-11.md, T3 "Click to agent ready": <= 8 s p50 and <= 15 s p95 cold,
<= 1 s warm. Every claim is held to the cold bound (a claim that took a spare should beat it), and the claims that took
a spare also to the warm one.
"""
import argparse
import datetime
import io
import json
import os
import subprocess
import sys
import time
import zipfile

ROW_VERSION = 1
PERF_ROW_MARK = "PERF_ROW "
ARTIFACT_PREFIX = "cloud-journey-prod-"
MODELS = ("stub", "real")
P50_TARGET_MS = 8000
P95_TARGET_MS = 15000
WARM_TARGET_MS = 1000
MIN_SAMPLES = 5
# The part's own bound on reading artifacts, well under the Linux part's 1800 s run cap: a clean run read 24 claims'
# artifacts in 101 s (2026-11-19, a lane VM).
DEADLINE_S = 240
# The steps before ready (cloud-journey.ts READY_STEPS): a probe row that failed at one of them is a claim that never
# got ready; a later failure (the chat) still had its ready_ms.
READY_STEP_PREFIXES = ("create machine", "running (status)", "first exec", "pass Claude login", "pass Codex login",
                       "start agent (")


def quantile(values, q):
    """Nearest rank, as cloud-start-bench.ts quantile (pure). None with no values."""
    if not values:
        return None
    ordered = sorted(values)
    k = -(-len(ordered) * q // 1)  # ceil
    return ordered[min(len(ordered) - 1, max(0, int(k) - 1))]


def parse_iso(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def claim_of(probe):
    """One probe.json row as a claim (pure): {"ready_ms", "spare", "at"}, {"failed": step} when it failed before
    ready, or None when it says nothing about a claim (another probe, another backend, a failure after ready with no
    ready_ms, a row written before the run began)."""
    if not isinstance(probe, dict) or probe.get("backend") != "prod":
        return None
    if not str(probe.get("probe") or "").startswith("cloud-chat-replies-production"):
        return None
    ready = probe.get("ready_ms")
    if isinstance(ready, (int, float)) and not isinstance(ready, bool) and ready > 0:
        return {"ready_ms": float(ready), "spare": probe.get("claimed_spare") is True, "at": probe.get("at")}
    error = str(probe.get("error") or "")
    step = next((p for p in READY_STEP_PREFIXES if error.startswith(p)), None)
    return {"failed": step.rstrip(" ("), "at": probe.get("at")} if step else None


def claim_rows(claims, samples=24):
    """The rows of the newest `samples` claims that reached ready (pure; claims newest first), and the claims that
    failed before ready among the claims scanned to collect them. Fewer than MIN_SAMPLES ready claims: no rows."""
    ready, failed = [], 0
    for c in claims:
        if len(ready) >= samples:
            break
        if "failed" in c:
            failed += 1
        else:
            ready.append(c)
    if len(ready) < MIN_SAMPLES:
        return []
    values = [c["ready_ms"] for c in ready]
    p50, p95 = quantile(values, 0.5), quantile(values, 0.95)
    rows = [
        {"name": "claim_to_ready", "p50": p50, "p95": p95, "unit": "ms", "target": P95_TARGET_MS, "samples": len(values),
         "version": ROW_VERSION},
        {"name": "claim_to_ready.p50", "p50": p50, "p95": p50, "unit": "ms", "target": P50_TARGET_MS,
         "samples": len(values), "version": ROW_VERSION},
        {"name": "claim_to_ready.failed_claims", "p50": failed, "p95": failed, "unit": "claims", "target": 0,
         "floor": 0.5, "samples": len(values) + failed, "version": ROW_VERSION},
    ]
    spare = [c["ready_ms"] for c in ready if c["spare"]]
    if spare:
        rows.append({"name": "claim_to_ready.spare", "p50": quantile(spare, 0.5), "p95": quantile(spare, 0.95),
                     "unit": "ms", "target": WARM_TARGET_MS, "samples": len(spare), "version": ROW_VERSION})
    return rows


def gh_json(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path.split('?')[0]}: exit {out.returncode}: {out.stderr.strip()[:300]}")
    return json.loads(out.stdout)


def gh_bytes(path):
    out = subprocess.run(["gh", "api", path], capture_output=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path}: exit {out.returncode}: {out.stderr.decode(errors='replace').strip()[:300]}")
    return out.stdout


def fetch_claims(repo, since, limit, deadline_s=DEADLINE_S, clock=time.monotonic):
    """(claims, unread): the claims of the journey's artifacts made since `since`, newest first, downloading until
    `limit` reached ready or `deadline_s` passed, and how many artifacts could not be read. The artifacts are listed by
    name across the repository (one call per model, not one per run)."""
    started = clock()
    arts = []
    for model in MODELS:
        listed = gh_json(f"repos/{repo}/actions/artifacts?name={ARTIFACT_PREFIX}{model}&per_page=100")
        arts += [a for a in listed.get("artifacts") or [] if not a.get("expired")
                 and parse_iso(a["created_at"]) >= since]
    arts.sort(key=lambda a: a["created_at"], reverse=True)
    claims, ready, unread = [], 0, 0
    for art in arts:
        if ready >= limit:
            break
        if clock() - started > deadline_s:
            print(f"cloud-claim: stopped reading at the {deadline_s} s deadline", file=sys.stderr)
            break
        try:
            with zipfile.ZipFile(io.BytesIO(gh_bytes(f"repos/{repo}/actions/artifacts/{art['id']}/zip"))) as z:
                probe = json.loads(z.read("probe.json").decode())
        except (KeyError, ValueError, zipfile.BadZipFile, RuntimeError) as e:
            print(f"cloud-claim: artifact {art['id']} {art.get('name')}: no probe.json ({e})", file=sys.stderr)
            unread += 1
            continue
        c = claim_of(probe)
        if c:
            claims.append(c)
            ready += "ready_ms" in c
    return claims, unread


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or "manaflow-ai/cmux")
    ap.add_argument("--samples", type=int, default=24)
    ap.add_argument("--window-hours", type=float, default=72)
    o = ap.parse_args(argv)
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=o.window_hours)
    claims, unread = fetch_claims(o.repo, since, o.samples)
    claims.sort(key=lambda c: str(c.get("at") or ""), reverse=True)
    rows = claim_rows(claims, o.samples)
    ready = [c for c in claims if "ready_ms" in c]
    print(f"cloud-claim: {len(ready)} claims reached ready, {len(claims) - len(ready)} failed before ready, "
          f"since {since.strftime('%Y-%m-%dT%H:%MZ')}", file=sys.stderr)
    if not rows:
        print(f"cloud-claim: fewer than {MIN_SAMPLES} production claims reached ready in {o.window_hours:g} h: no rows",
              file=sys.stderr)
    for r in rows:
        print(PERF_ROW_MARK + json.dumps(r))
    report = {"rows": rows}
    if unread and len(ready) < o.samples:
        # Fewer claims than asked because artifacts could not be read: the rows count, the report is incomplete.
        report["failed"] = [{"bench": "cloud-claim", "why": f"{unread} journey artifact(s) not read"}]
    print(json.dumps(report))
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
