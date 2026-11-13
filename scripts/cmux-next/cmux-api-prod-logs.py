#!/usr/bin/env python3
"""cmux-api production Workers Logs for one UTC window, published default-deny.

An agent asking why production refused something (prod 2026-11-11: `cmux auth token` refused the app's own
team as "not a member") reads the Worker's own diagnostic lines here instead of asking a person for a dashboard.

The run log is PUBLIC (the repo is public), so nothing is printed unless it is known safe:
- A Worker console line is printed only when its `msg` is, exactly, one of PUBLIC_MSGS: constant diagnostic
  ids the Worker itself writes. Any other msg is dropped and only counted. That drops every tenant-written line
  (automation `ctx.log`, automation tail logs and exceptions, which carry `source`/`run`/`automation`) and every
  serialized object, whatever it holds.
- Only typed fields of a printed line survive (PUBLIC_FIELDS): small ints, short lowercase tokens, and ids.
  Ids (team, user, an id-like token or path segment) print only as `h:` plus a sha256 prefix, for correlation.
- Per request: time, kind, outcome, method, status, and the path; a segment prints as is only when it is a fixed
  route word (ROUTE_SEGMENTS), every other segment prints hashed.
- Never a header, body, query string, free-text error, email, IP, token, or the event's own key names.
- Needles are read from the dispatch event file, never from the environment (step env is echoed in the log),
  and print hashed. They filter the public rows only (never raw event text), and the header says only whether
  any row was kept (`kept_any`), so a dispatcher can't use the run to probe for text.

  python3 -I cmux-api-prod-logs.py --from 2026-11-11T13:20:00Z --minutes 30 [--needles "team_x,/auth/"] < token

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
SERVICE = "cmux-api"
PAGES = 20
MAX_ROWS = 2000
NEEDLE_OK = re.compile(r"^[A-Za-z0-9_./ :-]{3,80}$")

# Exact msg ids, constant strings the cmux-api Worker writes in backend/apps/api/src. Add one only when it is a
# literal written by our code (never an interpolated or tenant string). Anything not here is never printed.
PUBLIC_MSGS = frozenset({
    "account index remove failed",
    "alarm time not finite",
    "approval answer ignored",
    "approval post failed",
    "attachment drop failed",
    "attachment multipart abort failed",
    "bedrock_body.view_mark_skipped",
    "billing.levels.meter_failed",
    "billing.team_mode.read",
    "billing.usage_sync",
    "billing.usage_sync.failed",
    "billing.usage_sync.refused",
    "billing.usage_sync.run_failed",
    "billing.usage_sync.skipped",
    "billing.usage_sync.truncated",
    "chief job not delivered",
    "chief job schedule not deleted",
    "chief jobs event not delivered",
    "chief.slack.automation_delivery_failed",
    "chief.slack.outbound_failed",
    "chief_brain.compact_call",
    "chief_brain.compactor_failed",
    "chief_brain.drain_failed",
    "chief_brain.memory_resume_failed",
    "chief_brain.paid_model_refused",
    "chief_brain.pi_pruned",
    "chief_brain.pi_report",
    "chief_brain.settle_timeout",
    "chief_brain.spawn_child_deleted",
    "chief_brain.spawn_child_failed",
    "chief_brain.spawn_report_refused",
    "chief_brain.spawn_report_retry",
    "chief_brain.spawn_start_failed",
    "chief_brain.steer_failed",
    "chief_brain.thinking_open_turn_mismatch",
    "chief_brain.thinking_stripped",
    "chief_brain.turn_failed",
    "chief_brain.turn_refused",
    "chief_brain.wake_dropped",
    "chief_brain.wake_failed",
    "chief_brain.wake_retry",
    "chief_cc.model_retry",
    "chief_cc.start_failed",
    "chief_cc.turn_ended_early",
    "chief_d.compact_call",
    "chief_d.compactor_failed",
    "chief_d.intent_failed",
    "chief_d.memory_imported",
    "chief_d.paid_model_refused",
    "chief_d.pi_report",
    "chief_d.post_refused",
    "chief_d.watch_failed",
    "chief_opencode.drain_failed",
    "chief_opencode.wake_failed",
    "chief_slack.delivery_failed",
    "chief_slack.delivery_unconfigured",
    "cloud grant carry failed",
    "cloud grant of a deleted team carried",
    "cloud.vm_plan.paid_read_failed",
    "cloud.vm_plan.read_failed",
    "connection system op refused",
    "conversation wake step failed",
    "credits.autoreload",
    "credits.autoreload_failed",
    "credits.billing_unavailable",
    "credits.checkout_failed",
    "credits.dogfood_entry_invalid",
    "credits.mirror",
    "credits.mirror_customer_conflict",
    "credits.mirror_failed",
    "credits.mirror_opening",
    "credits.return_not_granted",
    "credits.topup",
    "credits.webhook_live_refused",
    "deferred delivery dropped: too many waiting",
    "domain re-check failed",
    "egress count lost",
    "external op failed",
    "feed.push.failed",
    "feed.push.sent",
    "feed.push.skipped",
    "feed.sweep",
    "github disconnect token revoke failed",
    "github token revocation drain failed",
    "github token revoke: the ledger row does not open",
    "github.token.minted",
    "gmail fallback read failed",
    "gmail push pull failed",
    "gmail watch renewal failed",
    "gmail watch start failed",
    "gmail watch stop failed for good",
    "google pubsub: undecodable notification",
    "grant check",
    "hand.agent_outcome_dropped",
    "hand.sandbox_provider_unknown",
    "hand.sandbox_sweep",
    "hand.sandbox_sweep.failed",
    "handoffs.index_put_failed",
    "handoffs.route_failed",
    "home address link failed",
    "home invite send",
    "home.health.check_in_failed",
    "home.push.failed",
    "home.push.presence_failed",
    "host replica drop failed",
    "inference.budget.alert",
    "inference.cost_over_bound",
    "inference.free.attest_refused",
    "inference.free.granted",
    "inference.plan.read_failed",
    "inference.request",
    "inference.reservation.expired",
    "inference.settle_failed",
    "inference.workers_ai.error",
    "install certificate revocation refused",
    "lock notice to TeamDO failed",
    "member cleanup failed",
    "member_left ignored",
    "model_gateway.compactor_settle_failed",
    "model_gateway.dropped",
    "model_gateway.settle_failed",
    "model_gateway.upstream_refused",
    "outbox dead letters replayed",
    "outbox delivery failed",
    "outbox row dead-lettered",
    "outbox row skipped: no projection",
    "owner wake failed",
    "pair.machine_join.mint_failed",
    "pair.machine_join.refused",
    "pair.machine_revoke.failed",
    "personal vm api tenant not ready",
    "plan.checkout_failed",
    "platform.forward.failed",
    "platform.forward.unbound",
    "projection.read.probe_failed",
    "provider revocation failed",
    "provider revocation gave up",
    "provider revocation skipped: no INTEGRATIONS_KEK",
    "provider revocation skipped: the grant is still used by another connection",
    "revocation drain failed",
    "run policy pull failed",
    "run policy push to SchedulerDO failed",
    "scheduler step failed",
    "security mail dropped",
    "server install revocation failed",
    "server install revocation refused",
    "server machine revocation failed",
    "sign-in policy unreachable",
    "socket frame failed",
    "socket registry refused an owner",
    "ssh ca op failed",
    "sso gate unreachable",
    "sso sign-in audit refused",
    "sso sign-in failed at Stack",
    "stack member removal failed",
    "stack team sync abandoned",
    "stack webhook",
    "stack webhook lookup failed",
    "stop claim finish failed",
    "synced a stack team",
    "stack teams unreadable",
    "stack team sync failed",
    "stack team sync rejected; ended",
    "stack team still missing after re-checks; dropped",
    "team list membership unreachable",
    "system op refused",
    "team journal full",
    "team selection unreachable",
    "team ssh krl notice failed",
    "team vm bind pass failed",
    "team vm deleted",
    "team vm export stream failed",
    "team vm ledger name held by another VM",
    "team vm ledger name holds another id",
    "team vm prefix report",
    "team vm provider call failed",
    "team vm retire sync failed",
    "team vm retired pause failed",
    "team vm taint audit refused",
    "terminate refused",
    "text chief inbound",
    "text chief reply",
    "text chief route",
    "text chief send",
    "usage records refused",
    "user wake step failed",
})

INT = "int"
TOKEN = "token"
ID = "id"
# Typed fields a printed line may keep; everything else on the line is dropped.
PUBLIC_FIELDS = {"team": ID, "user": ID, "outcome": TOKEN, "code": TOKEN, "type": TOKEN, "step": TOKEN, "op": TOKEN,
                 "fails": INT, "attempts": INT, "status": INT}
# Keys only tenant-written lines carry (automation-caps.ts log, automation-tail.ts): such a line is dropped whole.
TENANT_KEYS = ("source", "run", "automation", "attrs")
TOKEN_OK = re.compile(r"^[a-z][a-z0-9_.:-]{0,47}$")
ID_OK = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# A token that is really an id: a known id prefix, or a run of 8+ digits/hex.
ID_LIKE = re.compile(r"^(?:team|user|usr|org|member|inv|run|vm|ws|tok|key|sess)_|[0-9a-f]{8,}|\d{6,}", re.I)
# Fixed route words: static segments of the path literals in backend/apps/api/src. A path segment prints as is
# only when it is one of these (or v1, v2, ...); any other segment, a request's own words included, prints hashed.
ROUTE_SEGMENTS = frozenset({
    "abandoned", "acpmux", "admin", "api", "attachments", "attest", "auth", "automation", "begin", "billing", "bind",
    "brain-impl", "by-key", "callback", "card", "carrier", "challenge", "chat", "checkout", "chief-cc", "chief-job",
    "chief-opencode", "chiefs", "claude-david", "clear", "client-config", "client-session", "cloud", "cmux.vcf",
    "commit", "complete", "completions", "content", "conv", "count_tokens", "credits", "customers", "defaults",
    "devices", "discover", "entries", "exec", "export", "fault", "files", "free", "github", "github-actions",
    "google", "grants", "hands", "harness-login-copy", "home", "hooks", "host", "identity", "inference",
    "integrations", "intent", "internal", "invite", "invites", "keyset", "levels", "machines", "meshes", "messages",
    "meter_events", "model-gateway", "models", "multipart", "mux", "network", "notes", "openapi.json", "ops",
    "outbox", "overlay-policy", "overlay-server-codes", "overlay-servers", "pair", "pair-codes", "payment_intents",
    "plan", "policy", "prefix-report", "presence-key", "preview", "pubsub", "read", "reconcile", "redeem",
    "registry", "replay", "retire", "sandboxes", "sendblue", "sessions", "signed", "socket", "sso", "stack", "start",
    "stat", "status", "stripe", "subscription_items", "subscriptions", "summary", "sync", "target", "team-mode",
    "team-vm", "ticket", "token", "topup", "trajectories", "upload", "upstash", "url", "v1", "vm-creations", "vms",
    "wait", "wire",
})
VERSION_SEGMENT = re.compile(r"^v\d{1,2}$")
METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})


def tag(value):
    """A short sha256 prefix: the same id gives the same tag, so rows correlate without printing the id."""
    return "h:" + hashlib.sha256(str(value).encode()).hexdigest()[:12]


def typed(kind, v):
    if kind == INT:
        return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v < 1_000_000 else None
    if not isinstance(v, str):
        return None
    if kind == ID:
        return tag(v) if ID_OK.match(v) else None
    if not TOKEN_OK.match(v):
        return None
    return tag(v) if ID_LIKE.search(v) else v


def public_path(url):
    if not isinstance(url, str):
        return None
    m = re.match(r"^[a-z]+://[^/?#]+(/[^?#]*)", url)
    path = m.group(1) if m else url.split("?")[0].split("#")[0]
    if not path.startswith("/"):
        return None
    segs = path.split("/")[1:][:12]
    return "/" + "/".join(s if not s or s in ROUTE_SEGMENTS or VERSION_SEGMENT.match(s) else tag(s) for s in segs)


def dig(o, *path):
    for k in path:
        if not isinstance(o, dict):
            return None
        o = o.get(k)
    return o


def console_line(e):
    """The event's Worker JSON console line, if it has one."""
    for cand in (dig(e, "$metadata", "message"), dig(e, "message"), dig(e, "source")):
        j = cand
        if isinstance(cand, str):
            try:
                j = json.loads(cand)
            except ValueError:
                continue
        if isinstance(j, dict) and "msg" in j:
            return j
    return None


# A field whose value is a reply's outcome or reason (free text in principle) prints only as one of these fixed
# literals, or "reject" for a `reject:<code>`, else "other": "synced a stack team" logs reply.outcome or reply.reason
# (stack-team-heal.ts, from team-stack-sync.ts).
STACK_SYNC_OUTCOMES = frozenset({
    "duplicate", "queued", "stack_server_not_configured", "team_deleted", "team_delete_pending",
    "team_delete_unconfirmed",
    "team_missing_recheck", "team_missing_dropped", "vm_personal_tenant_ignored", "vm_personal_tenant_marked",
    "anonymous_team_ignored",
    "team_mirrored", "member_present", "member_absent", "member_anonymous", "member_anonymous_removed",
})
ENUM_FIELDS = {("synced a stack team", "outcome"): STACK_SYNC_OUTCOMES}


def enum_value(allowed, v):
    if isinstance(v, str) and v in allowed:
        return v
    if isinstance(v, str) and v.startswith("reject:"):
        return "reject"
    return "other"


def public_log(j):
    """(fields, why) for a console line: fields only for an allowlisted Worker msg, else None and the drop reason."""
    if any(k in j for k in TENANT_KEYS):
        return None, "tenant"
    msg = j.get("msg")
    if not isinstance(msg, str) or msg not in PUBLIC_MSGS:
        return None, "unlisted"
    out = {"msg": msg}
    for k, kind in PUBLIC_FIELDS.items():
        if k in j:
            allowed = ENUM_FIELDS.get((msg, k))
            v = enum_value(allowed, j[k]) if allowed is not None else typed(kind, j[k])
            if v is not None:
                out[k] = v
    if "error" in j:
        out["error"] = True
    return out, None


def line(e, counts=None):
    """One public row for an event. Only typed, allowlisted values; never raw event text."""
    counts = counts if counts is not None else {}
    ts = dig(e, "timestamp") or dig(e, "$metadata", "timestamp")
    ts = ts if isinstance(ts, (int, float)) and not isinstance(ts, bool) else 0
    when = datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc).strftime("%H:%M:%S.%f")[:-4] + "Z" if ts else "?"
    rec = {"_ts": ts, "t": when}
    for k, v in (("kind", dig(e, "$metadata", "type") or dig(e, "$workers", "eventType")),
                 ("outcome", dig(e, "$workers", "outcome")), ("entry", dig(e, "$workers", "entrypoint"))):
        v = typed(TOKEN, v)
        if v is not None:
            rec[k] = v
    ev = dig(e, "$workers", "event")
    req = dig(ev, "request")
    if isinstance(req, dict):
        if req.get("method") in METHODS:
            rec["method"] = req["method"]
        p = public_path(req.get("url"))
        if p:
            rec["path"] = p
    status = typed(INT, dig(ev, "response", "status"))
    if status is not None:
        rec["status"] = status
    j = console_line(e)
    if j is not None:
        log, why = public_log(j)
        if log is not None:
            rec["log"] = log
        else:
            counts[f"logs_dropped_{why}"] = counts.get(f"logs_dropped_{why}", 0) + 1
    return rec


def matches(row, needles):
    """A needle matches only what is published: the row's text, or the hash tag the row prints for an id."""
    text = json.dumps(row)
    return any(n in text or tag(n) in text for n in needles)


def publish(events, needles):
    """(header, rows) for the public log. Needles filter the public rows, never raw event text, so a dispatcher can't
    probe for tenant text; and the header says only whether any row was kept, not how many."""
    counts = {}
    rows = [line(e, counts) for e in events]
    rows.sort(key=lambda r: r.pop("_ts", 0))
    if needles:
        rows = [r for r in rows if matches(r, needles)]
    head = {"needles": [tag(n) for n in needles], "events_in_window": len(events), "kept_any": bool(rows),
            "rows_cut": len(rows) > MAX_ROWS, **counts}
    return head, rows[:MAX_ROWS]


def query(token, frm, to, offset=None):
    body = {"queryId": f"cmux-api-prod-logs-{int(time.time())}", "timeframe": {"from": frm, "to": to}, "view": "events", "limit": 1000,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": SERVICE}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/observability/telemetry/query",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json", "user-agent": "cmux-api-prod-logs/2"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # The refusal body is not printed: only the status.
        sys.exit(f"telemetry query refused: HTTP {e.code}")


def event_needles(path):
    try:
        with open(path) as f:
            v = dig(json.load(f), "inputs", "needles")
    except (OSError, ValueError):
        return ""
    return v if isinstance(v, str) else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", required=True, help="UTC start, e.g. 2026-11-11T13:20:00Z")
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--needles", default="")
    ap.add_argument("--needles-from-event", default="", help="read inputs.needles from this workflow event file")
    args = ap.parse_args()
    raw = args.needles or (event_needles(args.needles_from_event) if args.needles_from_event else "")
    needles = [n.strip() for n in raw.split(",") if n.strip()]
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
    head, rows = publish(events, needles)
    print(json.dumps({"service": SERVICE, "window_utc": [args.frm, minutes], "pages": pages, "truncated": not complete, **head},
                     indent=1))
    for r in rows:
        print(json.dumps(r, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
