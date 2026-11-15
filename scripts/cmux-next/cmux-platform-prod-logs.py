#!/usr/bin/env python3
"""cmux-platform Workers Logs for one UTC window and one exact machine or team, stored only in private HQ.

Nobody could read cmux-platform production logs: cmux-platform's own worker-log-read.yml got HTTP 403 on every
Workers Logs query against cmux-platform-production (its deploy credential has no observability read). The
cmux-platform Workers live in the same account as cmux-api (cmux-platform-production binds cmux-api's Durable
Objects by script name), so this reads them with cmux-api-prod-logs.yml's credential and its private store.

The run log is PUBLIC: stdout contains only row_count and a private HQ issue pointer, as in cmux-api-prod-logs.py,
whose private-store writer, hashing and typed projection this reuses. On top of it:
- The service is one of SERVICES, exactly. Anything else refuses before a credential is read.
- The id is one exact `vm_...` (a machine) or `team_...` (a team), else nothing is queried. An event belongs to it
  only when its parsed log line names that id in every identity field of that kind (ID_KEYS) and names it at
  least once: a missing, duplicate, non-string or conflicting identity drops the event, before counting. A URL or
  search term never proves ownership.
- Needles are required and only refine the kept rows; the private header says only whether any row was kept.
- A Worker console line keeps its fields only when its `msg` is exactly one of PLATFORM_MSGS, the constant msg
  literals of cmux-platform's src/server; ids print as `h:` plus a sha256 prefix.
- Service, id and needles come from the dispatch event file, never from step env (echoed in the public log).

  python3 -I cmux-platform-prod-logs.py --from 2026-11-11T13:20:00Z --minutes 30 --from-event "$GITHUB_EVENT_PATH" < token
  python3 -I cmux-platform-prod-logs.py --from ... --service cmux-platform-production --id vm_x --needles "spare" < token

stdin: one line, a Cloudflare API token that may read Workers observability. Never printed.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

_spec = importlib.util.spec_from_file_location(
    "cmux_api_prod_logs", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmux-api-prod-logs.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

SERVICES = ("cmux-platform-production", "cmux-platform-staging")
PAGES = base.PAGES
MAX_ROWS = base.MAX_ROWS
ID_INPUT = re.compile(r"^(vm|team)_[A-Za-z0-9_-]{1,64}$")
# The parsed fields that name a machine or a team on a cmux-platform log line (src/server writes `machine` and
# `team` most, and machineId / vmId / teamId on some lines). Every one present must equal the id.
ID_KEYS = {"vm": ("machine", "machineId", "machine_id", "vm", "vmId", "vm_id"),
           "team": ("team", "teamId", "team_id")}
ALL_ID_KEYS = frozenset(k for keys in ID_KEYS.values() for k in keys)

# Exact msg literals in cmux-platform src/server (non-test .ts, `msg: "..."`), as of main dbba2c7 (2026-11-15).
# A template or computed msg is never here; add one only when it is a literal written by our code.
PLATFORM_MSGS = frozenset({
    "after-response work failed",
    "alarm time not finite",
    "approval post failed",
    "billing.margin.stripe_failed",
    "billing.margin.stripe_live_key_refused",
    "cloud acpmux",
    "cloud approval answer ignored",
    "cloud approval redelivery not admitted",
    "cloud approval run past its in-flight bound",
    "cloud approval settle pending",
    "cloud coderouter edge",
    "cloud environment build failed",
    "cloud environment setup did not start",
    "cloud guest exec failed",
    "cloud late-VM lookup failed",
    "cloud legacy seed capture not deleted",
    "cloud machine guest rpc failed",
    "cloud mesh acl",
    "cloud mesh attach",
    "cloud mesh creation",
    "cloud mesh maintenance",
    "cloud mesh read",
    "cloud platform edge",
    "cloud provider call failed",
    "cloud provider route",
    "cloud router route",
    "cloud slow call failed",
    "cloud usage ledger fact refused",
    "cloud usage ledger refused a whole batch",
    "cloud vm api capture unconfirmed at its deadline",
    "cloud vm api snapshot capture refused",
    "cloud vm api snapshot capture unconfirmed",
    "cloud.approval.gate",
    "cloud.approval.run",
    "cloud.bind.rpc",
    "cloud.call.abandoned",
    "cloud.census.put_failed",
    "cloud.census.settle_failed",
    "cloud.census.sweep_failed",
    "cloud.claim_fence_failed",
    "cloud.claim_fence_retry_alarm_failed",
    "cloud.claim_fence_retry_read_failed",
    "cloud.claim_fence_retry_reset_failed",
    "cloud.claim_fence_retry_write_failed",
    "cloud.connect.read",
    "cloud.create.attach_after_bind",
    "cloud.create.trace_unsent",
    "cloud.entitlement.profile_heal_failed",
    "cloud.entitlement.read_failed",
    "cloud.fork_snapshot_delete_failed",
    "cloud.image.cache.failed",
    "cloud.image.follow",
    "cloud.image.follow.read_failed",
    "cloud.image.follow.seeded",
    "cloud.machine.bind",
    "cloud.machine.ledger_wake",
    "cloud.machine.power_overdue",
    "cloud.machine.scaler_pause_held",
    "cloud.machine.size_read_failed",
    "cloud.machine.start_overdue",
    "cloud.machine.turn_cancelled",
    "cloud.machine.turn_release_failed",
    "cloud.machine.turn_sleep",
    "cloud.machine.turn_sleep_breaker",
    "cloud.machine.turn_sleep_guard",
    "cloud.machine.turn_wake_gave_up",
    "cloud.machine.verify_failed",
    "cloud.machine.woken_behind_ledger",
    "cloud.migration.classic_admitted",
    "cloud.mutations.orphan_resolved",
    "cloud.mutations.pre_fence",
    "cloud.ops.create",
    "cloud.pass.abandoned",
    "cloud.platform_stop_allocations_failed",
    "cloud.record.reconcile_failed",
    "cloud.record.stale",
    "cloud.record.unknown",
    "cloud.room.failed",
    "cloud.spare.claimed",
    "cloud.spare.ready_failed",
    "cloud.spare.ready_told",
    "cloud.spare.restarting",
    "cloud.spend_cap.cleared",
    "cloud.spend_cap.paused",
    "cloud.spend_cap.read_failed",
    "cloud.spend_cap.record_failed",
    "cloud.spend_cap.warning",
    "cloud_environment.vault_edge_grants",
    "config.team_id_kind",
    "connector.repo_token.requested",
    "dep_cache.read",
    "dep_cache.write",
    "environment builder lookup gave up",
    "environment builder not deleted yet",
    "environment encryption configuration is invalid; secrets are refused",
    "environment.activity.failed",
    "grant check",
    "inference.call_ledger",
    "inference.finish_failed",
    "inference.request",
    "install_counts.upload",
    "install_keys.jwks_load_failed",
    "late environment builder not deleted",
    "machine autosize",
    "machine autosize arm failed",
    "machine autosize tick failed",
    "machine create refused, falling back",
    "machine legacy provider",
    "machine placement",
    "machine placement unavailable",
    "machine provider census",
    "machine reservation release failed",
    "machine state put failed",
    "machine turn standby not deleted",
    "machine.access_copy_failed",
    "machine.device_delete_pending",
    "machine.egress_mismatch_destroy_failed",
    "machine.join_minted_for_pairing",
    "machine.mesh_purge_failed",
    "machine.mesh_retire_failed",
    "machine.node_fence_failed",
    "machine.phantom_check_failed",
    "machine.phantom_dropped",
    "machine.reap_deferred",
    "machine.reap_protected",
    "machine.reaped",
    "machine.rejoin_retire_failed",
    "machine.revoked_with_server",
    "machine.rotation_retire_failed",
    "machine.self_capabilities",
    "machine.self_capabilities_refused",
    "machine.self_revoked",
    "machine.vault_edges_kept",
    "machine.vault_edges_retry_stopped",
    "machine.vault_edges_retry_unarmed",
    "machine.vault_grant",
    "machine.wg_key_rotate",
    "machines.admission.leak_settled",
    "machines.create.write_back_refused",
    "machines.lease.ended",
    "machines.lease.idle_pause",
    "machines.lease.side_state_pruned",
    "machines.lease.wake",
    "machines.outbox.unknown_op",
    "machines.parked_prune_failed",
    "machines.spare.claim",
    "machines.spare.fill",
    "machines.spare.fill_diagnostic_unavailable",
    "machines.spare.finish",
    "machines.spare.ledger_failed",
    "machines.spare.refill_put_failed",
    "machines.spare.refresh",
    "machines.spare.running",
    "machines.spare.settle",
    "machines.spare.warm",
    "mcp connector install untracked",
    "mcp connector revoke pending",
    "mcp_servers.added",
    "mcp_servers.removed",
    "mesh.device.delete_pending",
    "mesh.device.delete_refused",
    "mesh.device.enrolled",
    "mesh.device.intent_pending",
    "mesh.device.mesh_unknown",
    "mesh.device.unavailable",
    "mesh.node.detached",
    "native network target",
    "outbox dead letters replayed",
    "outbox delivery failed",
    "outbox projection dropped",
    "outbox row dead-lettered",
    "owner state full",
    "owner wake failed",
    "owner_tokens.jwks_load_failed",
    "platform machine call",
    "platform machine operation waiting",
    "security mail dropped",
    "sign-in policy unreachable",
    "socket frame failed",
    "system op refused",
    "team machine audit write failed",
    "team selection unreachable",
    "turn checkpoints pruned",
    "turn machine deleted",
    "turn rewind",
    "turn rewind restores again at the machine limit",
    "turn rewind source cleanup failed",
    "turn standby alarm",
    "turn standby alarm pass failed",
    "turn standby delete failed",
    "turn standby evicted",
    "turn standby not cooled",
    "turn standby resumed",
    "turn standby skipped",
    "usage.audit",
    "usage.delete",
    "usage.upload",
    "vault.alert_feed_failed",
    "vault.edge_rule_untracked",
    "vault.env_deleted",
    "vault.env_migrated",
    "vault.env_policy",
    "vault.env_written",
    "vault.erased",
    "vault.grant_expired",
    "vault.grant_removed",
    "vault.grant_written",
    "vault.machine_read",
    "vault.migrate_failed",
    "vault.open_failed",
    "vault.read_alert",
    "vault.save_undo_failed",
    "vault.upstream_read",
    "vault.user_key_created",
    "vault.user_key_open_failed",
    "vault.user_key_rewrapped",
    "vm api tenant not ready",
    "vm install revoke failed",
    "workspace environment watch failed",
    "workspace machine: carrier workspace mark not written",
    "workspace machine: extra machine not deleted",
    "workspace machine: machine with internet for an offline chat not deleted",
    "workspace machine: platform scope not written",
})

INT, TOKEN, ID = base.INT, base.TOKEN, base.ID
# Typed fields a kept line may keep; everything else on the line is dropped.
PUBLIC_FIELDS = {"team": ID, "teamId": ID, "machine": ID, "machineId": ID, "vm": ID, "vmId": ID, "user": ID,
                 "outcome": TOKEN, "code": TOKEN, "type": TOKEN, "step": TOKEN, "op": TOKEN, "kind": TOKEN,
                 "site": TOKEN, "phase": TOKEN, "status": INT, "attempts": INT, "fails": INT, "ms": INT,
                 "spares": INT, "wanted": INT, "live": INT, "total": INT}


def public_log(j):
    """(fields, why): fields only for an allowlisted platform msg, else None and the drop reason."""
    if any(k in j for k in base.TENANT_KEYS):
        return None, "tenant"
    msg = j.get("msg")
    if not isinstance(msg, str) or msg not in PLATFORM_MSGS:
        return None, "unlisted"
    out = {"msg": msg}
    for k, kind in PUBLIC_FIELDS.items():
        if k in j:
            v = base.typed(kind, j[k])
            if v is not None:
                out[k] = v
    if "error" in j:
        out["error"] = True
    return out, None


def line(e, counts=None):
    """One private row for an event: only typed, allowlisted values; never raw event text."""
    counts = counts if counts is not None else {}
    dig = base.dig
    ts = dig(e, "timestamp") or dig(e, "$metadata", "timestamp")
    ts = ts if isinstance(ts, (int, float)) and not isinstance(ts, bool) else 0
    when = datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc).strftime("%H:%M:%S.%f")[:-4] + "Z" if ts else "?"
    rec = {"_ts": ts, "t": when}
    for k, v in (("kind", dig(e, "$metadata", "type") or dig(e, "$workers", "eventType")),
                 ("outcome", dig(e, "$workers", "outcome")), ("entry", dig(e, "$workers", "entrypoint"))):
        v = base.typed(TOKEN, v)
        if v is not None:
            rec[k] = v
    ev = dig(e, "$workers", "event")
    req = dig(ev, "request")
    if isinstance(req, dict):
        if req.get("method") in base.METHODS:
            rec["method"] = req["method"]
        p = base.public_path(req.get("url"))
        if p:
            rec["path"] = p
    status = base.typed(INT, dig(ev, "response", "status"))
    if status is not None:
        rec["status"] = status
    j = base.console_line(e)
    if j is not None:
        log, why = public_log(j)
        if log is not None:
            rec["log"] = log
        else:
            counts[f"logs_dropped_{why}"] = counts.get(f"logs_dropped_{why}", 0) + 1
    return rec


def unique_identity_fields(pairs):
    """A JSON object naming any identity field twice is ambiguous: refuse it instead of keeping the last copy."""
    result = {}
    for key, value in pairs:
        if key in ALL_ID_KEYS and key in result:
            raise ValueError("duplicate identity")
        result[key] = value
    return result


def id_kind(ident):
    m = ID_INPUT.fullmatch(ident) if isinstance(ident, str) else None
    return m.group(1) if m else None


def belongs_to(event, ident):
    """True only when every parsed source names `ident` in each identity field of its kind, at least once."""
    kind = id_kind(ident)
    if kind is None:
        return False
    keys = ID_KEYS[kind]
    found = []
    for candidate in (event, base.dig(event, "$metadata", "message"), base.dig(event, "message"), base.dig(event, "source")):
        if isinstance(candidate, str):
            try:
                candidate = json.loads(candidate, object_pairs_hook=unique_identity_fields)
            except ValueError:
                return False
        if isinstance(candidate, dict):
            found.extend(candidate[k] for k in keys if k in candidate)
    return bool(found) and all(isinstance(v, str) and v == ident for v in found)


def publish(events, needles, ident):
    """(header, rows) for the private store: scope first, then projection, then needles over the projected rows."""
    if not needles:
        raise ValueError("needles: at least one search term is required")
    scanned = len(events)
    events = [e for e in events if belongs_to(e, ident)]
    counts = {}
    rows = [line(e, counts) for e in events]
    rows.sort(key=lambda r: r.pop("_ts", 0))
    rows = [r for r in rows if base.matches(r, needles)]
    # events_scanned: the window's events before the id filter; events_in_window: the ones this id owns.
    head = {"needles": [base.tag(n) for n in needles], "events_scanned": scanned, "events_in_window": len(events),
            "kept_any": bool(rows),
            "rows_cut": len(rows) > MAX_ROWS, **counts}
    return head, rows[:MAX_ROWS]


def query(token, service, frm, to, offset=None):
    body = {"queryId": f"cmux-platform-prod-logs-{int(time.time())}", "timeframe": {"from": frm, "to": to},
            "view": "events", "limit": 1000,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": service}]}}
    if offset:
        body["offset"] = offset
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{base.ACCOUNT}/workers/observability/telemetry/query",
        data=json.dumps(body).encode(), method="POST",
        headers={"authorization": f"Bearer {token}", "content-type": "application/json",
                 "user-agent": "cmux-platform-prod-logs/1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # The refusal body is not printed: only the status.
        sys.exit(f"telemetry query refused: HTTP {e.code}")


def main():
    if os.environ.get("GITHUB_EVENT_NAME") not in (None, "workflow_dispatch"):
        sys.exit("logs: only workflow_dispatch may query")
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", default="", help="UTC start, e.g. 2026-11-11T13:20:00Z")
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--from-event", default="", help="read inputs.service, inputs.id and inputs.needles from this event file")
    ap.add_argument("--service", default=None)
    ap.add_argument("--id", dest="ident", default=None)
    ap.add_argument("--needles", default=None)
    args = ap.parse_args()

    def given(value, key):
        if value is not None:
            return value
        return base.event_input(args.from_event, key) if args.from_event else ""

    service = given(args.service, "service")
    if service not in SERVICES:
        sys.exit("service: one of " + ", ".join(SERVICES))
    ident = given(args.ident, "id")
    kind = id_kind(ident)
    if kind is None:
        sys.exit("id: an exact vm_ or team_ id is required")
    needles = [n.strip() for n in given(args.needles, "needles").split(",") if n.strip()]
    if not needles:
        sys.exit("needles: at least one search term is required")
    if any(not base.NEEDLE_OK.match(n) for n in needles):
        sys.exit("needles: each 3-80 chars of letters, digits, _ . / : - and space")
    if not args.frm:
        sys.exit("logs: --from is required")
    start = datetime.datetime.strptime(args.frm, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    minutes = max(1, min(60, args.minutes))
    frm = int(start.timestamp() * 1000)
    to = frm + minutes * 60_000
    private_token = base.private_destination()
    token = sys.stdin.readline().strip()
    events, offset, pages, complete = [], None, 0, False
    while pages < PAGES:
        got = base.dig(query(token, service, frm, to, offset), "result", "events", "events") or []
        events += got
        pages += 1
        if len(got) < 1000:
            complete = True
            break
        offset = base.dig(got[-1], "$metadata", "id")
        if not offset:
            complete = True
            break
    head, rows = publish(events, needles, ident)
    pointer = base.private_upload(private_token, {
        "service": service, "id_kind": kind, "id": base.tag(ident), "window_utc": [args.frm, minutes],
        "truncated": not complete, **head}, rows)
    print(json.dumps({"row_count": len(rows), "pointer": pointer}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
