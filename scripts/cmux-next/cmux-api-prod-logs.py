#!/usr/bin/env python3
"""cmux-api production Workers Logs for one UTC window, printed through an allowlist.

An agent asking why production refused something (prod 2026-11-11: `cmux auth token` refused the app's own
team as "not a member") reads the Worker's own log lines here instead of asking a person for a dashboard.
Prints, per event, only: time, outcome, request method, path (never the query), response status, and the
allowlisted fields of a JSON console line (msg, team, outcome, code, type, fails, step, attempts; for error,
only that one was there). Every printed value also loses any ?query, email, IP and long token run. Never a header, body, query string, token, email or IP.

  python3 -I cmux-api-prod-logs.py --from 2026-11-11T13:20:00Z --minutes 30 [--needles "team_d4390fb0a0f47a8e135a,/auth/"] < token

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
--needles (comma-separated) keeps only events whose text holds one of them (a team id, a msg, a path part).
"""
import argparse
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.request

ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
SERVICE = "cmux-api"
LOG_FIELDS = ("msg", "team", "outcome", "code", "type", "fails", "step", "attempts", "status", "op")
NEEDLE_OK = re.compile(r"^[A-Za-z0-9_./ :-]{3,80}$")
PAGES = 20
MAX_ROWS = 2000
# Printed values are scrubbed as well as allowlisted: a free-text msg, error or path may hold one (run logs are public).
SCRUB = [(re.compile(r"\?\S*"), "?<query>"),
         (re.compile(r"(?i)\b(bearer|basic)\s+\S+"), r"\1 <redacted>"),
         (re.compile(r"(?i)\b([a-z_-]*(?:token|secret|key|password|passwd|code|nonce|signature|auth|cookie|session)[a-z_-]*)\s*[=:]\s*[^\s,;&}]+"), r"\1=<redacted>"),
         # A path segment that is itself a secret (an invite code: /v1/invites/card/<code>).
         (re.compile(r"(/invites/card/)[^/\s]+"), r"\1<code>"),
         (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<email>"),
         (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b|\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){4,7}\b"), "<ip>"),
         (re.compile(r"[A-Za-z0-9+=-]{32,}"), "<long>")]


def scrub(v):
    if not isinstance(v, str):
        return v
    for rx, to in SCRUB:
        v = rx.sub(to, v)
    return v


def query(token, frm, to, offset=None):
    body = {"queryId": f"cmux-api-prod-logs-{int(time.time())}", "timeframe": {"from": frm, "to": to}, "view": "events", "limit": 1000,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": SERVICE}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/observability/telemetry/query",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json", "user-agent": "cmux-api-prod-logs/1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode("utf-8", "replace")
        sys.exit(f"telemetry query refused: HTTP {e.code}: {detail}")


def dig(o, *path):
    for k in path:
        if not isinstance(o, dict):
            return None
        o = o.get(k)
    return o


def path_only(url):
    if not isinstance(url, str):
        return None
    m = re.match(r"^[a-z]+://[^/]+(/[^?#]*)", url)
    return m.group(1) if m else url.split("?")[0][:120]


def console_fields(e):
    out = []
    for cand in (dig(e, "$metadata", "message"), dig(e, "message"), dig(e, "source")):
        j = cand
        if isinstance(cand, str):
            try:
                j = json.loads(cand)
            except ValueError:
                continue
        if isinstance(j, dict) and isinstance(j.get("msg"), str):
            f = {k: j[k] for k in LOG_FIELDS if k in j and isinstance(j[k], (str, int, float, bool))}
            # Free-text `error` is never printed (it can carry an upstream URL or credential); only that one was there.
            if "error" in j:
                f["error"] = "<present>"
            out.append(f)
            break
    return out


def line(e):
    ts = dig(e, "timestamp") or dig(e, "$metadata", "timestamp")
    when = datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc).strftime("%H:%M:%S.%fZ")[:-4] + "Z" if isinstance(ts, (int, float)) else "?"
    ev = dig(e, "$workers", "event") or {}
    req = ev.get("request") if isinstance(ev, dict) else None
    rec = {"_ts": ts if isinstance(ts, (int, float)) else 0, "t": when, "kind": dig(e, "$metadata", "type") or dig(e, "$workers", "eventType"), "outcome": dig(e, "$workers", "outcome"),
           "entry": dig(e, "$workers", "entrypoint")}
    if isinstance(req, dict):
        rec["method"] = req.get("method")
        rec["path"] = path_only(req.get("url"))
    status = dig(ev, "response", "status") if isinstance(ev, dict) else None
    if status is not None:
        rec["status"] = status
    for f in console_fields(e):
        rec["log"] = f
    if "log" in rec:
        rec["log"] = {k: scrub(v) for k, v in rec["log"].items()}
    return {k: scrub(v) for k, v in rec.items() if v not in (None, "", False)}


def key_paths(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from key_paths(v, f"{p}.{k}")
    elif isinstance(o, list):
        for v in o[:3]:
            yield from key_paths(v, f"{p}[]")
    else:
        yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", required=True, help="UTC start, e.g. 2026-11-11T13:20:00Z")
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--needles", default="")
    args = ap.parse_args()
    needles = [n.strip() for n in args.needles.split(",") if n.strip()]
    if any(not NEEDLE_OK.match(n) for n in needles):
        sys.exit("needles: each 3-80 chars of letters, digits, _ . / : - and space")
    start = datetime.datetime.strptime(args.frm, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    minutes = max(1, min(60, args.minutes))
    frm = int(start.timestamp() * 1000)
    to = frm + minutes * 60_000
    token = sys.stdin.readline().strip()
    events, offset, pages, complete = [], None, 0, False
    while pages < PAGES:
        got = dig(query(token, frm, to, offset), "result", "events", "events") or []
        events += got
        pages += 1
        if len(got) < 1000:
            complete = True
            break
        offset = dig(got[-1], "$metadata", "id")
        if not offset:
            complete = True
            break
    keys = sorted({k for e in events[:50] for k in key_paths(e)})
    kept = [e for e in events if not needles or any(n in json.dumps(e) for n in needles)]
    rows = [line(e) for e in kept]
    rows.sort(key=lambda r: r.pop("_ts", 0))
    print(json.dumps({"service": SERVICE, "window_utc": [args.frm, minutes], "needles": needles, "events_in_window": len(events),
                      "pages": pages, "truncated": not complete, "kept": len(rows), "printed": min(len(rows), MAX_ROWS), "rows_cut": len(rows) > MAX_ROWS, "event_key_paths": keys}, indent=1))
    for r in rows[:MAX_ROWS]:
        print(json.dumps(r, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
