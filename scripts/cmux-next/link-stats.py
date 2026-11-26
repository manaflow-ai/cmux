#!/usr/bin/env python3
"""Phone-to-Mac link paths and their RTT, loss and setup time, from the mobile Worker's Workers Logs.

Each phone sends a `link_stat` frame on its signaling socket (cmux-next-ios/PROTOCOL.md "Link stats"); its
hub writes one `{"event":"link_stat",...}` log line with where the phone entered Cloudflare (ingressColo,
country, continent) and where its hub runs (hubColo). This reads one UTC window of those lines and prints,
per (transport, path, continent, country, hub colo) and per path overall:

- stats: lines in the group; links: first stats (one per link that came up); share: the group's share of
  all stats (each up link sends one a minute, so this is about its share of link time);
- rtt p50/p95/p99: percentiles of the per-stat median RTT, weighted by its sample count; tail p95: the p95
  of the per-stat p95;
- loss: lost pings / pings sent;
- setup p50/p95: ms from connect to the first pong, over first stats.

A direct link whose route is the Mac's NAT-mapped endpoint (PCP, NAT-PMP or UPnP-IGD; PROTOCOL.md "Mapped
endpoints") counts as path `direct-mapped`, so its share of direct links shows.

The lines carry no user, device or address; still, rows are per continent unless --by-country, and a group
fewer than --min-group links came up in folds its country (then its continent) into "*" and prints no row
of its own, so the output never singles out one person's location.

  python3 -I scripts/cmux-next/link-stats.py --from 2026-11-21T00:00:00Z --minutes 1440 < token
  python3 -I scripts/cmux-next/link-stats.py --events dump.json      # offline: a saved query result

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
"""
import argparse
import datetime
import json
import sys
import time
import urllib.error
import urllib.request

ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
SERVICES = {"prod": "cmux-mobile-api-prod", "dev": "cmux-mobile-api-dev"}
PAGES = 50
PAGE = 1000
MAX_MINUTES = 7 * 1440

TRANSPORTS = {"wireguard", "webrtc"}
PATHS = {"direct", "turn", "turn-tls", "none"}
REASONS = {"first", "periodic", "path", "end"}


def dig(o, *path):
    for k in path:
        if not isinstance(o, dict):
            return None
        o = o.get(k)
    return o


def num(v, hi=600_000):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v < 0:
        return None
    return min(v, hi)


def code(v):
    return v if isinstance(v, str) and 1 < len(v) <= 4 and v.isalnum() and v.isupper() else None


def stat_of(event):
    """The link_stat line of one telemetry event (parsed `source`, or the message JSON), validated; else None."""
    for cand in (dig(event, "source"), dig(event, "$metadata", "message"), dig(event, "message")):
        j = cand
        if isinstance(cand, str):
            try:
                j = json.loads(cand)
            except ValueError:
                continue
        if not isinstance(j, dict) or j.get("event") != "link_stat":
            continue
        if j.get("transport") not in TRANSPORTS or j.get("path") not in PATHS or j.get("reason") not in REASONS:
            return None
        pings, lost = num(j.get("pings"), 100_000), num(j.get("lost"), 100_000)
        if pings is None or lost is None:
            return None
        path = "direct-mapped" if j["path"] == "direct" and j.get("portmapUsed") is True else j["path"]
        return {
            "transport": j["transport"], "path": path, "reason": j["reason"], "pings": pings, "lost": lost,
            "rttN": num(j.get("rttN"), 100_000) or 0, "rttP50": num(j.get("rttP50")), "rttP95": num(j.get("rttP95")),
            "setupMs": num(j.get("setupMs")) if j["reason"] == "first" or "marks" in j else None,
            "continent": code(j.get("continent")) or "?", "country": code(j.get("country")) or "?",
            "hubColo": code(j.get("hubColo")) or "?",
            # Keystroke round trips (PROTOCOL.md "Link stats", `echo`, `ack`): absent with no key typed.
            **{f"{k}{f}": num(j.get(f"{k}{f}"), 100_000 if f == "N" else 600_000)
               for k in ("echo", "ack") for f in ("N", "P50", "P95", "P99")},
            "spikeCount": num(j.get("spikeCount"), 100_000) or 0,
        }
    return None


def percentile(pairs, p):
    """Weighted nearest-rank percentile of (value, weight) pairs; None when empty."""
    pairs = sorted((v, w) for v, w in pairs if v is not None and w > 0)
    total = sum(w for _, w in pairs)
    if not total:
        return None
    need, seen = total * p / 100, 0
    for v, w in pairs:
        seen += w
        if seen >= need:
            return v
    return pairs[-1][0]


def summarize(stats, total):
    rtt = [(s["rttP50"], s["rttN"]) for s in stats if s["rttN"]]
    tail = [(s["rttP95"], 1) for s in stats if s["rttN"]]
    setup = [(s["setupMs"], 1) for s in stats if s["setupMs"] is not None]
    pings = sum(s["pings"] for s in stats)
    out = {
        "stats": len(stats), "links": sum(1 for s in stats if s["reason"] == "first"),
        "share": round(len(stats) / total, 4) if total else 0.0,
        "rtt_p50": percentile(rtt, 50), "rtt_p95": percentile(rtt, 95), "rtt_p99": percentile(rtt, 99),
        "rtt_tail_p95": percentile(tail, 95),
        "loss": round(sum(s["lost"] for s in stats) / pings, 4) if pings else None,
        "setup_p50": percentile(setup, 50), "setup_p95": percentile(setup, 95),
    }
    keys = sum(s["echoN"] or 0 for s in stats)
    for k in ("echo", "ack"):
        # A window's p50 weighted by its keys; its p99 once per window (each window's own tail).
        out[f"{k}_p50"] = percentile([(s[f"{k}P50"], s[f"{k}N"]) for s in stats if s[f"{k}N"]], 50)
        out[f"{k}_tail_p99"] = percentile([(s[f"{k}P99"], 1) for s in stats if s[f"{k}N"]], 99)
    out["keys"] = keys
    out["spikes_per_1k_keys"] = round(1000 * sum(s["spikeCount"] for s in stats) / keys, 1) if keys else None
    return out


def fold(stats, min_group):
    """Fold the country, then the continent, of each group that fewer than min_group links came up in.

    A group is (transport, path, continent, country, hub colo); its size is its first stats (links), not its
    lines, since one long link writes a line a minute."""
    def key(s):
        return (s["transport"], s["path"], s["continent"], s["country"], s["hubColo"])

    def small(rows):
        links = {}
        for s in rows:
            links[key(s)] = links.get(key(s), 0) + (s["reason"] == "first")
        return lambda s: links[key(s)] < min_group

    under = small(stats)
    out = [{**s, "country": "*"} if under(s) else s for s in stats]
    under = small(out)
    return [{**s, "continent": "*"} if under(s) else s for s in out]


def aggregate(stats, min_group=5, by_country=False):
    """Rows per (transport, path) overall, then per (transport, path, continent[, country], hub colo)."""
    if not by_country:
        stats = [{**s, "country": "*"} for s in stats]
    stats = fold(stats, min_group)
    total = len(stats)
    groups, paths = {}, {}
    for s in stats:
        groups.setdefault((s["transport"], s["path"], s["continent"], s["country"], s["hubColo"]), []).append(s)
        paths.setdefault((s["transport"], s["path"]), []).append(s)
    rows = []
    for (transport, path), members in sorted(paths.items()):
        rows.append({"transport": transport, "path": path, "continent": "all", "country": "all", "hubColo": "all",
                     **summarize(members, total)})
    for (transport, path, continent, country, hub), members in sorted(groups.items()):
        if sum(1 for s in members if s["reason"] == "first") < min_group:
            continue
        rows.append({"transport": transport, "path": path, "continent": continent, "country": country, "hubColo": hub,
                     **summarize(members, total)})
    return rows


COLUMNS = ["transport", "path", "continent", "country", "hubColo", "stats", "links", "share", "rtt_p50", "rtt_p95",
           "rtt_p99", "rtt_tail_p95", "loss", "setup_p50", "setup_p95",
           "keys", "echo_p50", "echo_tail_p99", "ack_p50", "ack_tail_p99", "spikes_per_1k_keys"]


def render(rows):
    def cell(c, v):
        if v is None:
            return "-"
        return f"{v:.2%}" if c in ("share", "loss") else str(round(v) if isinstance(v, float) else v)

    lines = ["| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS)]
    for r in rows:
        lines.append("| " + " | ".join(cell(c, r[c]) for c in COLUMNS) + " |")
    return "\n".join(lines)


def query(token, service, frm, to, offset=None):
    body = {"queryId": f"link-stats-{int(time.time())}", "timeframe": {"from": frm, "to": to}, "view": "events", "limit": PAGE,
            "parameters": {"filters": [
                {"key": "$metadata.service", "operation": "eq", "type": "string", "value": service},
                {"key": "event", "operation": "eq", "type": "string", "value": "link_stat"}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/observability/telemetry/query",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json", "user-agent": "cmux-link-stats/1"})
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
    ap.add_argument("--from", dest="frm", help="UTC start, e.g. 2026-11-21T00:00:00Z (default: --minutes ago)")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--env", choices=sorted(SERVICES), default="prod")
    ap.add_argument("--min-group", type=int, default=5, help="fewest links a printed group may have")
    ap.add_argument("--by-country", action="store_true", help="split continents by country (not for public logs)")
    ap.add_argument("--json", action="store_true", help="print rows as JSON lines instead of a table")
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
    stats = [s for s in map(stat_of, events) if s]
    rows = aggregate(stats, max(1, args.min_group), args.by_country)
    head = {"window": window, "env": args.env, "events": len(events), "link_stats": len(stats), "complete": complete}
    print(json.dumps(head))
    if args.json:
        for r in rows:
            print(json.dumps(r))
    else:
        print(render(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
