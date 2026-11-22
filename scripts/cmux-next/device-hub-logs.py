#!/usr/bin/env python3
"""The device hub's `relay entitlement` lines, from its persisted Workers Logs.

workers/device-hub/src/billing.ts logs one line per relay lookup (every ticket, `/ice` refresh and `/v1/me`):
`relay entitlement: <paid|free|error>[ (<reason>)]`. A share that times out because neither side got STUN/TURN
starts here: was the caller seen as paid, free, or did billing fail? This reads one UTC window (at most 60
minutes) of cmux-device-hub (or -dev) and prints each such line with its time, request path, outcome and colo,
then the counts per line. The lines carry no user, device, token or address; anything that does not match the
exact line shape is counted and never printed.

  python3 -I scripts/cmux-next/device-hub-logs.py --from 2026-11-22T08:40:00Z --minutes 10 < token
  python3 -I scripts/cmux-next/device-hub-logs.py --events dump.json      # offline: a saved query result

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
"""
import argparse
import collections
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
SERVICES = {"prod": "cmux-device-hub", "dev": "cmux-device-hub-dev"}
PAGES = 50
PAGE = 1000
MAX_MINUTES = 60

LINE = re.compile(r"^relay entitlement: (paid|free|error)(?: \(([a-z0-9' ]{1,40})\))?$")
PATH = re.compile(r"^/[A-Za-z0-9/_.-]{0,80}$")
OUTCOME = re.compile(r"^[a-zA-Z]{1,30}$")
COLO = re.compile(r"^[A-Z]{3,4}$")


def dig(o, *path):
    for k in path:
        if not isinstance(o, dict):
            return None
        o = o.get(k)
    return o


def messages(event):
    """Every message string an event carries (metadata message and source)."""
    out = []
    for v in (dig(event, "$metadata", "message"), dig(event, "source", "message"), dig(event, "source")):
        if isinstance(v, str):
            out.append(v.strip())
        elif isinstance(v, list):
            out.extend(x.strip() for x in v if isinstance(x, str))
    return out


def safe(rx, v):
    return v if isinstance(v, str) and rx.match(v) else "-"


def row_of(event):
    """(time, line, path, outcome, colo) of one entitlement line, validated; else None."""
    line = next((m for m in messages(event) if LINE.match(m)), None)
    if not line:
        return None
    ts = dig(event, "timestamp")
    when = (datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            if isinstance(ts, (int, float)) else "-")
    url = dig(event, "$workers", "event", "request", "url") or dig(event, "$metadata", "url")
    path = urllib.parse.urlsplit(url).path if isinstance(url, str) else None
    outcome = dig(event, "$workers", "outcome")
    colo = dig(event, "$workers", "event", "request", "cf", "colo") or dig(event, "$metadata", "coloCode")
    return when, line, safe(PATH, path), safe(OUTCOME, outcome), safe(COLO, colo)


def query(token, service, frm, to, offset=None):
    body = {"queryId": f"device-hub-logs-{int(time.time())}", "timeframe": {"from": frm, "to": to}, "view": "events", "limit": PAGE,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": service}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/observability/telemetry/query",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json", "user-agent": "cmux-device-hub-logs/1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"telemetry query refused: HTTP {e.code}")


def fetch(token, service, frm, to):
    events, offset = [], None
    for _ in range(PAGES):
        got = dig(query(token, service, frm, to, offset), "result", "events", "events") or []
        events += got
        if len(got) < PAGE:
            return events, True
        offset = dig(got[-1], "$metadata", "id")
        if not offset:
            return events, True
    return events, False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--from", dest="frm", help="UTC start, e.g. 2026-11-22T08:40:00Z (default: --minutes ago)")
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--env", choices=sorted(SERVICES), default="prod")
    ap.add_argument("--events", default="", help="read a saved telemetry query result (or a JSON list of events)")
    args = ap.parse_args(argv)
    minutes = max(1, min(MAX_MINUTES, args.minutes))
    complete = True
    if args.events:
        with open(args.events) as f:
            data = json.load(f)
        events = data if isinstance(data, list) else (dig(data, "result", "events", "events") or [])
        window = "file"
    else:
        if args.frm:
            start = datetime.datetime.strptime(args.frm, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        else:
            start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)
        frm = int(start.timestamp() * 1000)
        to = frm + minutes * 60_000
        token = sys.stdin.readline().strip()
        if not token:
            sys.exit("stdin: a Cloudflare API token is required")
        events, complete = fetch(token, SERVICES[args.env], frm, to)
        window = f"{start.strftime('%Y-%m-%dT%H:%M:%SZ')} +{minutes}m"
    rows = sorted(r for r in map(row_of, events) if r)
    counts = collections.Counter(r[1] for r in rows)
    print(json.dumps({"window": window, "env": args.env, "events": len(events), "entitlement_lines": len(rows), "complete": complete}))
    print("| time (UTC) | line | path | outcome | colo |")
    print("|---|---|---|---|---|")
    for r in rows:
        print("| " + " | ".join(r) + " |")
    print()
    for line, n in counts.most_common():
        print(f"{n}\t{line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
