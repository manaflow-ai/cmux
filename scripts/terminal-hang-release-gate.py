#!/usr/bin/env python3
"""Compare exact macOS releases in Sentry; iOS crash consent excludes session tracking."""

import argparse
import datetime as dt
import json
import math
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlencode


PLATFORMS = {
    "macos": ("4510796264636416", "production"),
}


def api(resource, params):
    result = subprocess.run(
        ["sentry", "api", "organizations/manaflow/" + resource + "?" + urlencode(params, doseq=True)],
        check=True, capture_output=True, text=True, timeout=90,
    )
    return json.loads(result.stdout)


def collect(platform, release, start, end):
    if platform not in PLATFORMS:
        raise ValueError("Session-rate gate supports macOS only; iOS needs a consent-compatible exposure source")
    project, environment = PLATFORMS[platform]
    # Release strings are exact matches; do not mix nightly, forks, or dev tags.
    query = "release:" + json.dumps(release)
    common = dict(project=project, environment=environment, start=start, end=end)
    sessions = api("sessions/", dict(common, field="sum(session)", query=query))
    if (timestamp(sessions["start"]), timestamp(sessions["end"])) != (start, end):
        raise ValueError("Sentry rounded the session window; use whole UTC-hour boundaries")
    groups = sessions.get("groups", [])
    denominator = sum(group["totals"]["sum(session)"] for group in groups)
    # SDK exception types and mechanisms include fatal hangs and MetricKit.
    # Use the same predicate for the total and every attributed segment.
    hang_query = query + (
        ' (error.type:"App Hang*" OR error.type:"Fatal App Hang*"'
        ' OR error.type:WatchdogTermination OR error.type:MXHangDiagnostic'
        ' OR error.mechanism:AppHang OR error.mechanism:watchdog_termination'
        ' OR error.mechanism:mx_hang_diagnostic)'
    )
    events = api("events/", dict(common, field=["count()"], query=hang_query))
    count = sum(row["count()"] for row in events["data"])
    segments = []
    cursor = None
    while True:
        params = dict(common, field=["terminal.transition", "terminal.phase", "terminal.evidence", "count()"],
                      query=hang_query, per_page=100, sort="-count()")
        if cursor:
            params["cursor"] = cursor
        response = api("events/", params)
        page = response["data"]
        segments.extend(page)
        if len(page) < 100:
            break
        # Offset pagination is supported by the events API. Never silently
        # publish a truncated sum when a new vocabulary produces more rows.
        cursor = "0:" + str(len(segments)) + ":0"
        if len(segments) >= 10000:
            raise ValueError("Phase query exceeded pagination bound")
    return {
        "platform": platform, "release": release, "environment": environment,
        "start": start, "end": end, "hang_events": count, "sessions": denominator,
        "events_per_1000_sessions": count * 1000 / denominator if denominator else None,
        "segments": segments,
    }


def evaluate(baseline, candidate, min_sessions=1000, max_ratio=1.25):
    reasons = []
    for label, sample in (("baseline", baseline), ("candidate", candidate)):
        if sample["platform"] not in PLATFORMS:
            reasons.append(label + " has no supported session exposure source; gate supports macOS only")
        sessions = sample["sessions"]
        events = sample["hang_events"]
        if not isinstance(sessions, int) or sessions < min_sessions:
            reasons.append(label + " has insufficient session exposure")
        if not isinstance(events, int) or events < 0:
            raise ValueError("Invalid event count")
        if sum(row["count()"] for row in sample["segments"]) != events:
            reasons.append(label + " segment total differs from event total")
    if (baseline["platform"], baseline["environment"], baseline["start"], baseline["end"]) != (
        candidate["platform"], candidate["environment"], candidate["start"], candidate["end"]
    ):
        reasons.append("Samples must use the same platform, environment, and time window")
    candidate_unknown = sum(row["count()"] for row in candidate["segments"]
                            if row.get("terminal.evidence") != "no_active_main_phase"
                            and (row.get("terminal.transition") not in {"split", "restore", "reveal", "resize"}
                                 or row.get("terminal.phase") in (None, "", "unknown")))
    if candidate_unknown:
        reasons.append(f"{candidate_unknown} candidate hang events have no attributable geometry phase")
    ratio = None
    if baseline["sessions"] > 0 and candidate["sessions"] > 0:
        old = baseline["hang_events"] / baseline["sessions"]
        new = candidate["hang_events"] / candidate["sessions"]
        ratio = new / old if old else (0 if new == 0 else None)
        if (old == 0 and new > 0) or (ratio is not None and ratio > max_ratio):
            reasons.append("Candidate hang-event rate exceeds the release threshold")
        # A clean but barely exercised candidate is not evidence of safety.
        # The Poisson zero-event upper bound is about three events at 95%.
        if candidate["hang_events"] == 0 and (old == 0 or 3 / candidate["sessions"] > old * max_ratio):
            reasons.append("Zero-event candidate has insufficient exposure to bound a regression")
    return {"passed": not reasons, "reasons": reasons, "rate_ratio": ratio,
            "candidate_unattributed_events": candidate_unknown,
            "metric": "hang events per session; not the fraction of sessions that hung"}


def timestamp(raw):
    value = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if value.tzinfo is None:
        raise argparse.ArgumentTypeError("Use an explicit UTC offset or Z")
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--baseline-release", required=True)
    parser.add_argument("--candidate-release", required=True)
    parser.add_argument("--start", type=timestamp, required=True)
    parser.add_argument("--end", type=timestamp, required=True)
    parser.add_argument("--min-sessions", type=int, default=1000)
    parser.add_argument("--max-rate-ratio", type=float, default=1.25)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.start >= args.end or args.min_sessions < 1 or not math.isfinite(args.max_rate_ratio) or args.max_rate_ratio <= 0:
        parser.error("Require start < end, positive exposure, and a finite positive rate threshold")
    try:
        baseline = collect(args.platform, args.baseline_release, args.start, args.end)
        candidate = collect(args.platform, args.candidate_release, args.start, args.end)
        verdict = evaluate(baseline, candidate, args.min_sessions, args.max_rate_ratio)
        report = dict(baseline=baseline, candidate=candidate, verdict=verdict)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(verdict, indent=2))
        return 0 if verdict["passed"] else 1
    except (subprocess.SubprocessError, KeyError, ValueError) as error:
        print("Release gate unavailable: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
