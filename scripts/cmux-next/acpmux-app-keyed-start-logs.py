#!/usr/bin/env python3
"""T1 log check of cx-kvmz: the development API Worker's invocation logs (Workers Logs) for the
acpmux requests of one T1 run hold no key. Reads <out>/requests.tsv of acpmux-app-keyed-start-e2e.py
and queries every log event of cmux-api-development in the run's time window (the Worker's
invocations and its CloudDO's). The key itself is not here (T1 never writes it down): T1 writes
only the length and sha256 of each form of K (hex, upper hex, the base64 forms), and this check
hashes every window of that length in every log event. Pass: no window matches, and every acpmux
request of the run has its invocation event. Fields that hold other 64-hex runs (the Durable
Object id, TLS authenticators) are listed for the record.

  python3 -I acpmux-app-keyed-start-logs.py --out <t1 out dir> < cloudflare-api-token

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
SERVICE = "cmux-api-development"
HEX64 = re.compile(rb"[0-9a-fA-F]{64}")
B64 = re.compile(rb"[A-Za-z0-9+/]{84,}={0,2}")


def query(token, frm, to, offset=None):
    body = {"queryId": f"kvmz-t1-{int(time.time())}", "timeframe": {"from": frm, "to": to}, "view": "events", "limit": 1000,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": SERVICE}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/observability/telemetry/query",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json", "user-agent": "cmux-kvmz-t1/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    token = sys.stdin.readline().strip()
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(args.out, "requests.tsv")) if l.strip()]
    machine = next((l.split("\t")[0] for l in open(os.path.join(args.out, "machines.tsv")) if l.strip()), "")
    frm, to = min(int(r[1]) for r in rows) - 5_000, max(int(r[2]) for r in rows) + 5_000
    events = query(token, frm, to).get("result", {}).get("events", {}).get("events", [])
    raw = [json.dumps(e).encode() for e in events]
    with open(os.path.join(args.out, "worker-logs.jsonl"), "wb") as f:
        f.write(b"\n".join(raw))
    ours = [e for e in events if f"/v1/cloud/machines/{machine}/acpmux/" in json.dumps(e)]
    digests = json.load(open(os.path.join(args.out, "needle-digests.json")))
    text = b"\n".join(raw)
    key_hits = sorted({form for form, d in digests.items() for i in range(0, max(0, len(text) - d["len"] + 1)) if hashlib.sha256(text[i:i + d["len"]]).hexdigest() == d["sha256"]})

    def fields(o, p=""):
        if isinstance(o, dict):
            for k, v in o.items():
                yield from fields(v, f"{p}.{k}")
        elif isinstance(o, list):
            for v in o:
                yield from fields(v, f"{p}[]")
        elif isinstance(o, str) and (HEX64.search(o.encode()) or B64.search(o.encode())):
            yield p
    long_runs = sorted({f for e in events for f in fields(e)})
    rays = sorted({e.get("$workers", {}).get("event", {}).get("rayId") or e.get("$metadata", {}).get("requestId") for e in ours} - {None})
    acpmux_lines = [e.get("$metadata", {}).get("message") for e in events if "cloud acpmux" in json.dumps(e)]
    ok = len(ours) >= len(rows) and not key_hits
    print(json.dumps({"ok": ok, "window_ms": [frm, to], "events_in_window": len(events), "bytes_searched": len(text), "acpmux_request_events": len(ours), "t1_requests": len(rows),
                      "key_hits": key_hits, "forms_checked": sorted(digests), "fields_with_long_hex_or_base64_runs": long_runs,
                      "request_ids": rays[:40], "acpmux_console_lines": acpmux_lines[:40]}, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
