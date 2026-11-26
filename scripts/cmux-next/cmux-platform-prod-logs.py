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
- The id `window` reads no one's lines: it counts the whole window's events by minute, kind, entrypoint, outcome,
  method, route, status, script version (hashed) and allowlisted msg with its typed token fields, every id dropped.
  An id-scoped read keeps nothing when the platform's own request events name no id (most do not): cmux-platform#1442,
  2026-11-16, ten scoped reads kept 0 of 105-208 events while journeys failed with 503 owner.unreachable, 502
  vm_unavailable and ECONNRESET, and only the window's outcomes could say which side failed.

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

# cmux-vm's Workers (workers/cmux-vm, the VM API in front of the VM provider) live in the same account: the platform
# binds cmux-vm-staging by script name. cmux-platform#1442: the platform logged `cloud provider call failed` in bursts
# and only cmux-vm's own lines say which provider operation failed with which status. Its lines name no machine or
# team, so a cmux-vm service reads only `window`.
VM_SERVICES = ("cmux-vm-production", "cmux-vm-staging")
# cmux-platform-development lives in the same account: its never_bound and bind_late lines (bind_probe) are the guest
# facts a Cloud lane reads after a fresh create, and cmux-platform's worker-log-read.yml gets 403 on it too.
SERVICES = ("cmux-platform-production", "cmux-platform-staging", "cmux-platform-development") + VM_SERVICES
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
    # One line per create or start pass (cmux-platform src/server/cloud/CloudCore.ts createTrace): the ms at which each
    # step ended. Kept as TRACE_STEPS only (trace_fields), so a never_bound create says which step it last reached.
    "cloud.create.submit",
    "cloud.create.trace",
    "cloud.create.trace_unsent",
    "cloud.start.submit",
    "cloud.start.trace",
    "cloud.entitlement.profile_heal_failed",
    "cloud.entitlement.read_failed",
    "cloud.fork_snapshot_delete_failed",
    # Why an overdue running machine was not paused, once per machine per change (cmux-platform src/server/cloud
    # IdleKept.ts). Kept only as its idle_kept() projection: cmux#54889's timer-only `workload` lines.
    "cloud.idle.kept",
    "cloud.image.cache.failed",
    "cloud.image.follow",
    "cloud.image.follow.read_failed",
    "cloud.image.follow.seeded",
    "cloud.machine.bind",
    # The edge name check after a bind or claim (cmux-platform CloudCore.ts checkEdgeDns): resolved, flushed, kicked,
    # unresolved, no_answer, failed or no_route, its exit and why (bind or claim); dns_upstream is dropped.
    "cloud.machine.edge_dns",
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
    "cloud.spare.gateway_read",
    "cloud.spare.ready_failed",
    "cloud.spare.ready_told",
    "cloud.spare.restarting",
    "cloud.spend_cap.cleared",
    "cloud.spend_cap.paused",
    "cloud.spend_cap.read_failed",
    "cloud.spend_cap.record_failed",
    "cloud.spend_cap.warning",
    # A submit answer cut off with its intent still pending (cmux-platform CloudCore, retro r2b92b756): op and ms waited.
    "cloud.submit.cut_off",
    # A chat's work VM (cmux-platform src/server/cloud/WorkMachine.ts workMachineLog, CloudDO.ts): whether one started,
    # its size and pause policy, and why not. Kept only as work_machine()'s typed projection (RFD agent-work-placement).
    "cloud.work_machine.failed",
    "cloud.work_machine.not_ready",
    "cloud.work_machine.ready",
    "cloud.work_machine.skipped",
    "cloud.work_machine.started",
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
    # A team hub call that threw before answering 503 mesh.unavailable: its kind and error type (cmux-platform#1660).
    "mesh.hub.unavailable",
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
                 "spares": INT, "wanted": INT, "live": INT, "total": INT, "failure": TOKEN, "reason": TOKEN,
                 "mode": TOKEN, "attempt": INT, "total_ms": INT, "path": TOKEN, "fallback": TOKEN, "behind": INT,
                 "paused_for_ms": INT}
# Booleans a kept line may keep, only as true or false (cloud.spare.gateway_read, cmux-platform#1629: what a spare
# claim's gateway check read: the shared route, a gateway host here, and whether the team's creates lack a rule;
# cloud.machine.start_overdue and power_overdue: whether the machine's create or call was still running).
PUBLIC_BOOLS = ("lacks", "shared", "host", "create_running", "call_running")

# The step names a create or start trace marks (cmux-platform CloudCore.ts `trace.mark("...")`), each kept with its
# ms. Any other name is dropped, so a step a newer platform adds prints nothing until it is listed here.
TRACE_MSGS = frozenset({"cloud.create.submit", "cloud.create.trace", "cloud.start.submit", "cloud.start.trace"})
TRACE_STEPS = frozenset({
    "adopt", "answer", "attach_network", "bind_committed", "bind_file", "bind_wait", "budget", "carrier", "claim_prep",
    "driver", "edge", "ensure", "entitlements", "images", "needs_rule", "network", "plan_read", "power",
    "prepare_network", "principal", "rate_limit", "real_state", "resources", "scaler", "setup", "spare_claim",
    "stale_submit", "submit",
})


# machines.spare.claim and machines.spare.finish (cmux-platform Scaler.ts claimSpare): `skipped`, each fixed reason a
# claim passed a spare over for (warming, paused, gateway_rule, generation, lost_*, ...) with its count, and `ms`, the
# cumulative ms per fixed step. Without them a claim that saw a spare and still created reads only `spares: 1`
# (production 2026-11-26 16:09Z and 16:46Z, hq#29939, hq#29940). A key that is not a plain token, or a count that is
# not an int, is dropped; an id-like key is hashed (base.typed TOKEN).
SPARE_COUNT_MSGS = frozenset({"machines.spare.claim", "machines.spare.finish"})
SPARE_COUNTS_MAX = 24


def token_counts(counts):
    """{token: int} from a dict of fixed words to counts or ms; anything else is dropped. None when nothing is left."""
    if not isinstance(counts, dict):
        return None
    out = {}
    for k, v in counts.items():
        key, n = base.typed(TOKEN, k), base.typed(INT, v)
        if key is not None and n is not None and len(out) < SPARE_COUNTS_MAX:
            out[key] = n
    return dict(sorted(out.items())) or None


def trace_steps(steps):
    """A trace's steps as {listed step: ms}; a non-int or unlisted step is dropped."""
    if not isinstance(steps, dict):
        return None
    out = {k: v for k, v in steps.items() if k in TRACE_STEPS and base.typed(INT, v) is not None}
    return dict(sorted(out.items(), key=lambda kv: kv[1]))


# cloud.machine.start_overdue's bind_probe (cmux-platform NeverBoundProbe.ts): the guest's own read of why it never
# bound. Its `out` holds addresses, hosts and curl's words, so only typed facts leave: whether the bind file is there,
# an uptime band, whether the API host and the coderouter edge resolved, and each HTTPS try's status or curl error.
BIND_PROBE_OUTCOMES = frozenset({"ran", "failed", "bound", "no_route"})
UPTIME_BANDS = ((60, "lt60s"), (300, "60s-300s"), (900, "300s-900s"))
CURL_ERROR = re.compile(r"curl: \((\d{1,3})\)")
HTTP_CODE = re.compile(r"(?:^|\s)http=(\d{3})(?:\s|$)")


def probe_facts(out):
    """The typed facts of a bind probe's out text, in NeverBoundProbe.ts's order: dns api then edge, https api then
    edge. Every value is a fixed word, a band or a small int."""
    facts = {}
    dns, https = [], []
    for raw in out.splitlines():
        ln = raw.strip()
        if ln in ("bind_file=present", "bind_file=missing"):
            facts["bind_file"] = ln.split("=", 1)[1]
        elif ln.startswith("uptime_s="):
            try:
                up = float(ln.split("=", 1)[1])
            except ValueError:
                continue
            if up >= 0:
                facts["uptime"] = next((band for limit, band in UPTIME_BANDS if up < limit), "ge900s")
        elif ln.startswith("nameservers="):
            facts["nameservers"] = len([n for n in ln.split("=", 1)[1].split(",") if n])
        elif ln.startswith("route="):
            facts["route"] = "default" if ln.split("=", 1)[1].strip() else "none"
        elif ln.startswith("dns ") and "=" in ln:
            dns.append("unresolved" if ln.rsplit("=", 1)[1].strip() in ("", "unresolved") else "resolved")
        elif ln.startswith("https "):
            err = CURL_ERROR.search(ln)
            code = HTTP_CODE.search(ln)
            if err:
                https.append(f"curl_{int(err.group(1))}")
            elif code and code.group(1) != "000":
                https.append(int(code.group(1)))
            else:
                https.append("no_answer")
        elif ln == "curl=absent":
            https = ["curl_absent", "curl_absent"]
    for name, got in (("dns", dns), ("https", https)):
        for target, v in zip(("api", "edge"), got):
            facts[f"{name}_{target}"] = v
    return facts


def bind_probe(p):
    """bind_probe's typed projection: outcome, ms, exit, truncated, the provider error code and probe_facts."""
    if not isinstance(p, dict):
        return None
    out = {"outcome": p.get("outcome") if p.get("outcome") in BIND_PROBE_OUTCOMES else "other"}
    for k in ("ms", "exit"):
        v = base.typed(INT, p.get(k))
        if v is not None:
            out[k] = v
    if isinstance(p.get("truncated"), bool):
        out["truncated"] = p["truncated"]
    if "error" in p:
        out["error"] = base.typed(TOKEN, p["error"]) or True
    if isinstance(p.get("out"), str):
        out.update(probe_facts(p["out"]))
    return out


# cloud.idle.kept's reasons (IdleKept.ts idleKept, first match); anything else prints as "other".
IDLE_KEPT_WHY = frozenset({"not_allowed", "changing", "no_report", "no_activity", "held", "sessions", "workload",
                           "no_turns", "recent"})
# cmux#54889: every image since cmux#50074 (2026-11-22) installs cmux-chief-update.timer disabled, and the guest's
# workload reader counted it as the person's work, so a machine whose only workload was that timer never paused idle.
CHIEF_UPDATE_TIMERS = frozenset({"systemd:cmux-chief-update.timer", "cmux-chief-update.timer"})
# A daemon version: digits first, then version characters. Anything hex-like prints hashed, as a token does.
DAEMON_VERSION = re.compile(r"^[0-9][0-9A-Za-z.+_-]{0,47}$")
# How long the machine had run since its last power when the line was written: a coarse band, never the number.
RUNNING_BANDS = ((3600, "lt1h"), (6 * 3600, "1h-6h"), (24 * 3600, "6h-24h"))


def idle_kept(j):
    """cloud.idle.kept's typed projection: why, a timer_only flag for `workload`, the daemon version and a running
    band. The line's team and machine are ids and its process, port and timer names are the guest's own words: only
    whether the names were exactly cmux-chief-update.timer leaves the line."""
    why = j.get("why")
    out = {"msg": "cloud.idle.kept", "why": why if why in IDLE_KEPT_WHY else "other"}
    for k in ("team", "machine"):
        v = base.typed(ID, j.get(k))
        if v is not None:
            out[k] = v
    w = j.get("workload")
    if why == "workload" and isinstance(w, dict):
        names = w.get("timer_names")
        quiet = all(not w.get(k) for k in ("busy", "listening", "process_names", "ports"))
        out["timer_only"] = bool(quiet and isinstance(names, list) and names
                                 and all(isinstance(n, str) and n in CHIEF_UPDATE_TIMERS for n in names))
    d = j.get("daemon")
    if isinstance(d, str) and DAEMON_VERSION.match(d):
        out["daemon"] = base.tag(d) if base.ID_LIKE.search(d) else d
    elif d is None and "daemon" in j:
        out["daemon"] = "null"
    s = j.get("running_s")
    if isinstance(s, int) and not isinstance(s, bool) and s >= 0:
        out["running"] = next((band for limit, band in RUNNING_BANDS if s < limit), "ge24h")
    return out


# cloud.work_machine.*'s typed fields (CloudDO.ts): `work` is the work VM's id; the rest are sizes and timings.
WORK_MACHINE_FIELDS = {"team": ID, "machine": ID, "work": ID, "cpu": INT, "memory_mb": INT, "ms": INT,
                       "create_ms": INT, "history": INT}
# A skip's reasons; a failure's `why` is the create answer's code, kept as a token. Anything else prints as "other".
WORK_MACHINE_SKIPPED = frozenset({"no_plan", "agent_is_enough", "max_active", "max_machines", "rate", "budget"})
# PausePolicy.ts PAUSE_POLICY_NAMES, plus "deployment" when the policy write was refused.
WORK_MACHINE_POLICIES = frozenset({"current", "aggressive", "turn_end", "deployment"})


def work_machine(j):
    """cloud.work_machine.*'s typed projection: ids hashed, sizes and timings as ints, a fixed why and pause policy."""
    msg = j["msg"]
    out = {"msg": msg}
    for k, kind in WORK_MACHINE_FIELDS.items():
        v = base.typed(kind, j.get(k)) if k in j else None
        if v is not None:
            out[k] = v
    why = j.get("why")
    if isinstance(why, str):
        if msg == "cloud.work_machine.skipped":
            out["why"] = why if why in WORK_MACHINE_SKIPPED else "other"
        else:
            out["why"] = base.typed(TOKEN, why) or "other"
    p = j.get("pause_policy")
    if isinstance(p, str):
        out["pause_policy"] = p if p in WORK_MACHINE_POLICIES else "other"
    return out


def public_log(j):
    """(fields, why): fields only for an allowlisted platform msg, else None and the drop reason."""
    if any(k in j for k in base.TENANT_KEYS):
        return None, "tenant"
    msg = j.get("msg")
    if not isinstance(msg, str) or msg not in PLATFORM_MSGS:
        return None, "unlisted"
    if msg == "cloud.idle.kept":
        return idle_kept(j), None
    if msg.startswith("cloud.work_machine."):
        return work_machine(j), None
    out = {"msg": msg}
    for k, kind in PUBLIC_FIELDS.items():
        if k in j:
            v = base.typed(kind, j[k])
            if v is not None:
                out[k] = v
    for k in PUBLIC_BOOLS:
        if isinstance(j.get(k), bool):
            out[k] = j[k]
    # A gateway mode the claim could not read is null on the line; kept as "null", told apart from no field.
    if msg == "cloud.spare.gateway_read" and "mode" in j and j["mode"] is None:
        out["mode"] = "null"
    if msg in TRACE_MSGS:
        steps = trace_steps(j.get("steps"))
        if steps is not None:
            out["steps"] = steps
    if msg in SPARE_COUNT_MSGS:
        for k in ("skipped", "ms"):
            counts = token_counts(j.get(k))
            if counts is not None:
                out[k] = counts
    if msg == "cloud.machine.start_overdue" and "bind_probe" in j:
        probe = bind_probe(j["bind_probe"])
        if probe is not None:
            out["bind_probe"] = probe
    if msg == "cloud.machine.edge_dns":
        if isinstance(j.get("exit"), int) and not isinstance(j.get("exit"), bool):
            out["exit"] = j["exit"]
        if j.get("why") in ("bind", "claim"):
            out["why"] = j["why"]
    if "error" in j:
        out["error"] = True
    return out, None


# cmux-vm logs through Effect's default logger, one text line per call (workers/cmux-vm src/upstream/live.ts):
#   timestamp=2026-11-16T13:55:01.000Z level=WARN fiber=#12 message="cmux-vm upstream call failed" operation=startVm status=503
# VM_MSGS are its exact `Effect.logWarning("...")` literals in workers/cmux-vm/src. A kept line keeps only its msg,
# level, operation (a code-defined camelCase name), status (an HTTP status, or `none`: no answer, a timeout or a
# dropped connection) and code; every other key, a cause included, is dropped.
VM_MSGS = frozenset({
    "cmux-vm dependency unavailable",
    "cmux-vm store query failed",
    "cmux-vm upstream call failed",
    "cmux-vm upstream response unreadable",
})
VM_LEVELS = frozenset({"DEBUG", "INFO", "WARN", "ERROR", "FATAL"})
VM_OPERATION = re.compile(r"^[A-Za-z][A-Za-z0-9_.]{0,47}$")
VM_STATUS = re.compile(r"^[1-5][0-9]{2}$")
LOGFMT_PAIR = re.compile(r'(?:^|\s)([A-Za-z][A-Za-z0-9_]{0,31})=("(?:[^"\\]|\\.)*"|[^\s"=]*)')
# Fixed route words of cmux-vm's paths (workers/cmux-vm/openapi.json) that base.ROUTE_SEGMENTS lacks, so
# `/v1/vms/*/pause` counts as that route and not as `/v1/vms/*/*`. Any other segment still prints hashed.
VM_ROUTE_SEGMENTS = frozenset({
    "acl", "address", "agent-keys", "api-keys", "cancel", "client-sessions", "device-enrollments", "device-intents",
    "enrollment-codes", "fork", "healthz", "https-proxies", "mesh-creations", "overlay-server-enrollments", "pause",
    "peers", "public-egress", "receiver-policy", "resize", "resume", "revoke", "rotate-key", "snapshot-creations",
    "snapshots", "stop", "terminal", "terminals", "tunnel", "tunnels", "vm-images",
})


def public_path(url):
    """base.public_path, with VM_ROUTE_SEGMENTS printed as route words too."""
    p = base.public_path(url)
    if p is None:
        return None
    raw = re.match(r"^[a-z]+://[^/?#]+(/[^?#]*)", url) if isinstance(url, str) else None
    raw_segs = (raw.group(1) if raw else url.split("?")[0].split("#")[0]).split("/")[1:][:12]
    segs = p.split("/")[1:]
    return "/" + "/".join(r if r in VM_ROUTE_SEGMENTS else s for s, r in zip(segs, raw_segs))


def vm_text_line(e):
    """The event's Effect text line (`... message=...`), if it has one."""
    for cand in (base.dig(e, "$metadata", "message"), base.dig(e, "message"), base.dig(e, "source", "message"),
                 base.dig(e, "source")):
        if isinstance(cand, str) and " message=" in cand:
            return cand
    return None


def vm_log(text):
    """(fields, why) for a cmux-vm Effect text line: fields only for a VM_MSGS msg, else None and the drop reason."""
    pairs = {}
    for key, value in LOGFMT_PAIR.findall(text):
        if key in pairs:
            return None, "ambiguous"
        pairs[key] = re.sub(r"\\(.)", r"\1", value[1:-1]) if value.startswith('"') else value
    msg = pairs.get("message")
    if msg not in VM_MSGS:
        return None, "unlisted"
    out = {"msg": msg}
    if pairs.get("level") in VM_LEVELS:
        out["level"] = pairs["level"].lower()
    operation = pairs.get("operation")
    if operation is not None and VM_OPERATION.match(operation) and not base.ID_LIKE.search(operation):
        out["operation"] = operation
    status = pairs.get("status")
    if status == "none":
        out["status"] = "none"
    elif status is not None and VM_STATUS.match(status):
        out["status"] = int(status)
    code = base.typed(TOKEN, pairs.get("code"))
    if code is not None:
        out["code"] = code
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
        p = public_path(req.get("url"))
        if p:
            rec["path"] = p
    status = base.typed(INT, dig(ev, "response", "status"))
    if status is not None:
        rec["status"] = status
    j = base.console_line(e)
    text = vm_text_line(e) if j is None else None
    if j is not None or text is not None:
        log, why = public_log(j) if j is not None else vm_log(text)
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
            except json.JSONDecodeError:
                # Workers Logs puts a JSON line's msg text in $metadata.message and the parsed line in source: plain
                # text names no identity, as console_line skips it. Before this every production id read kept 0.
                continue
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
    # events_scanned: the events the query returned for the id (its needle) before the exact id filter;
    # events_in_window: the ones this id owns.
    head = {"needles": [base.tag(n) for n in needles], "events_scanned": scanned, "events_in_window": len(events),
            "kept_any": bool(rows),
            "rows_cut": len(rows) > MAX_ROWS, **counts}
    return head, rows[:MAX_ROWS]


WINDOW = "window"
# The fields a window total groups by: no id, no time finer than a minute, no free text.
TOTAL_KEYS = ("kind", "entry", "outcome", "method", "path", "status")


def window_totals(events, needles):
    """(header, rows) for the private store: counts of the window's events by minute and typed shape, ids dropped."""
    if not needles:
        raise ValueError("needles: at least one search term is required")
    counts = {}
    totals = {}
    for e in events:
        rec = line(e, counts)
        when = rec.get("t", "?")
        key = {"m": when[:5] if when != "?" else "?"}
        for k in TOTAL_KEYS:
            if k in rec:
                key[k] = rec[k]
        if "path" in key:
            # A hashed segment (an id) groups as `*`: the route counts, never whose it was.
            key["path"] = "/".join("*" if seg.startswith("h:") else seg for seg in key["path"].split("/"))
        version = base.dig(e, "$workers", "scriptVersion", "id")
        if isinstance(version, str) and version:
            key["version"] = base.tag(version)
        log = rec.get("log")
        if log is not None:
            key["log"] = {k: v for k, v in log.items()
                          if PUBLIC_FIELDS.get(k) != ID and WORK_MACHINE_FIELDS.get(k) != ID}
        k = json.dumps(key, sort_keys=True)
        totals[k] = totals.get(k, 0) + 1
    rows = [{**json.loads(k), "n": n} for k, n in sorted(totals.items())]
    rows = [r for r in rows if base.matches(r, needles)]
    head = {"needles": [base.tag(n) for n in needles], "events_scanned": len(events), "kept_any": bool(rows),
            "rows_cut": len(rows) > MAX_ROWS, **counts}
    return head, rows[:MAX_ROWS]


def window_needle(needles):
    """A window read asks the query for one msg's events when its only needle is an allowlisted platform msg literal:
    a busy production hour holds more events than PAGES pages, and cloud.idle.kept is a few of them (cmux#54889).
    The literal is our own constant, never a tenant's word; any other needle filters only the rows, as before."""
    return needles[0] if len(needles) == 1 and needles[0] in PLATFORM_MSGS else None


def query(token, service, frm, to, offset=None, needle=None):
    body = {"queryId": f"cmux-platform-prod-logs-{int(time.time())}", "timeframe": {"from": frm, "to": to},
            "view": "events", "limit": 1000,
            "parameters": {"filters": [{"key": "$metadata.service", "operation": "eq", "type": "string", "value": service}]}}
    if needle:
        # The id itself, matched server-side: a service-only read of a busy hour fills PAGES pages with other
        # ids' lines and never reaches this one's (hq#13055, hq#13057: 20000 scanned, 0 in window).
        body["parameters"]["needle"] = {"value": needle, "isRegex": False, "matchCase": True}
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
    kind = WINDOW if ident == WINDOW else id_kind(ident)
    if service in VM_SERVICES and kind != WINDOW:
        sys.exit("id: cmux-vm's lines name no machine or team; read it with `window`")
    if kind is None:
        sys.exit("id: an exact vm_ or team_ id, or `window`, is required")
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
        got = base.dig(query(token, service, frm, to, offset, needle=window_needle(needles) if kind == WINDOW else ident),
                       "result", "events", "events") or []
        events += got
        pages += 1
        if len(got) < 1000:
            complete = True
            break
        offset = base.dig(got[-1], "$metadata", "id")
        if not offset:
            complete = True
            break
    head, rows = window_totals(events, needles) if kind == WINDOW else publish(events, needles, ident)
    pointer = base.private_upload(private_token, {
        "service": service, "id_kind": kind, "id": WINDOW if kind == WINDOW else base.tag(ident), "window_utc": [args.frm, minutes],
        "truncated": not complete, **head}, rows)
    print(json.dumps({"row_count": len(rows), "pointer": pointer}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
