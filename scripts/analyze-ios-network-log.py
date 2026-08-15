#!/usr/bin/env python3
"""Turn a cmux-network.log export into a repeatable connection verdict.

The iOS report is intentionally human-readable. This parser consumes the
English timeline without needing the app's private Swift types, then reports
the correlations that matter for a field run: usable latency, cancellation
ownership, recovery outcomes, duplicate physical sessions, and direct-path
stages. It accepts old exports too, where session fields were omitted.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


PIPE_EVENT_RE = re.compile(r"^(?P<stamp>.+?)\s+\|\s+(?P<body>.+)$")
# AppLog writes ISO-8601 timestamps followed directly by the rendered event,
# while older exported reports used `timestamp | event`. Accept both so the
# analyzer can consume the files users actually attach from the app.
ISO_EVENT_RE = re.compile(
    r"^(?P<stamp>\d{4}-\d{2}-\d{2}T\S+|\d{4}-\d{2}-\d{2}\s+\S+\s+UTC)\s+(?P<body>.+)$"
)
FIELD_RE = re.compile(r"(?P<key>[^:(),]+):\s*(?P<value>[^,()]+)")
NUMBER_RE = re.compile(r"-?\d+(?:\.\d+)?")
DURATION_RE = re.compile(
    r"^\s*(?P<number>-?\d+(?:\.\d+)?)\s*"
    r"(?P<unit>milliseconds?|ms|seconds?|secs?|s)?\s*$",
    re.IGNORECASE,
)


def parse_stamp(raw: str, fallback: int) -> float:
    """Return seconds from a UTC or relative report timestamp."""
    if raw.startswith("+"):
        match = NUMBER_RE.search(raw)
        return float(match.group()) if match else float(fallback)
    try:
        normalized = raw.strip().removesuffix(" UTC")
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        else:
            parsed = parsed.astimezone(timezone.utc)
        return parsed.timestamp()
    except ValueError:
        # Preserve a stable synthetic value for an unrecognized timestamp.
        return float(fallback)


def parse_line(line: str, ordinal: int) -> dict[str, object] | None:
    stripped = line.strip()
    match = PIPE_EVENT_RE.match(stripped) or ISO_EVENT_RE.match(stripped)
    if not match:
        return None
    body = match.group("body")
    title, _, payload = body.partition(" (")
    fields: dict[str, str] = {}
    if payload.endswith(")"):
        payload = payload[:-1]
        for field in FIELD_RE.finditer(payload):
            fields[field.group("key").strip().lower().replace(" ", "_")] = (
                field.group("value").strip()
            )
    return {
        "ordinal": ordinal,
        "stamp": parse_stamp(match.group("stamp"), ordinal),
        "title": title.strip().lower(),
        "fields": fields,
        "raw": body,
    }


def as_int(value: object | None) -> int | None:
    if value is None:
        return None
    match = re.search(r"-?\d+", str(value))
    return int(match.group()) if match else None


def as_seconds(value: object | None) -> float | None:
    if value is None:
        return None
    match = NUMBER_RE.search(str(value))
    return float(match.group()) if match else None


def as_milliseconds(value: object | None) -> float | None:
    """Parse a rendered duration whose unit may be milliseconds or seconds."""
    if value is None:
        return None
    text = str(value).lower()
    match = DURATION_RE.match(text)
    if match:
        parsed = float(match.group("number"))
        unit = (match.group("unit") or "ms").lower()
        if unit in {"s", "sec", "secs", "second", "seconds"}:
            return parsed * 1000
        return parsed
    parsed = as_seconds(text)
    return parsed * 1000 if parsed is not None and "second" in text else parsed


def normalized_failure(value: object | None) -> str | None:
    """Map localized-looking rendered labels to stable analyzer vocabulary."""
    if value is None:
        return None
    normalized = re.sub(r"[^a-z0-9]+", "_", str(value).lower()).strip("_")
    aliases = {
        "no_route_available": "no_route",
        "no_route": "no_route",
        "no_route_found": "no_route",
        "no_usable_route": "no_route",
        "no_usable_route_path": "no_route",
        "no_route_candidates": "no_route",
        "route_already_connecting": "route_gated",
        "route_gated": "route_gated",
        "timed_out": "timed_out",
        "transport_idle_timed_out": "transport_idle_timed_out",
        "connection_refused": "connection_refused",
        "network_unreachable": "host_unreachable",
        "no_route_to_host": "host_unreachable",
        "host_unreachable": "host_unreachable",
        "cancelled": "cancelled",
    }
    return aliases.get(normalized, normalized or None)


def field(event: dict[str, object], *names: str) -> str | None:
    fields = event["fields"]
    assert isinstance(fields, dict)
    for name in names:
        if name in fields:
            return str(fields[name])
    return None


def title_is(event: dict[str, object], *needles: str) -> bool:
    title = str(event["title"])
    return any(needle in title for needle in needles)


def analyze(lines: Iterable[str], expected_background_seconds: float = 0.0) -> dict:
    events = [
        parsed
        for ordinal, line in enumerate(lines)
        if (parsed := parse_line(line, ordinal)) is not None
    ]
    dials: dict[int, dict] = {}
    connected_latencies: list[float] = []
    usable_latencies: list[float] = []
    cancellations: Counter[str] = Counter()
    recovery_started: dict[str, dict] = {}
    recovery_outcomes: Counter[str] = Counter()
    sessions: dict[tuple[str, int], bool] = {}
    active_counts: Counter[str] = Counter()
    max_active: Counter[str] = Counter()
    direct_stages: Counter[str] = Counter()
    dial_failures: Counter[str] = Counter()
    failure_kinds: Counter[str] = Counter()
    phase_failures: Counter[str] = Counter()
    discovery_outcomes: Counter[str] = Counter()
    discovery_durations_ms: list[float] = []
    discovery_shapes: list[dict[str, int | None]] = []
    dial_plans: list[dict[str, int]] = []
    relay_policy_outcomes: Counter[str] = Counter()
    network_reachability: Counter[str] = Counter()
    recovery_coalesced = 0
    path_events: Counter[str] = Counter()
    background_at: float | None = None
    background_gaps: list[float] = []
    latest_dial_by_peer: dict[str, float] = {}
    latest_recovery_by_peer: dict[str, str] = {}
    liveness_count = 0

    for event in events:
        stamp = float(event["stamp"])
        peer = field(event, "peer", "surface") or "unknown"
        attempt = as_int(field(event, "attempt"))
        session = as_int(field(event, "session"))
        failure = normalized_failure(field(event, "failure"))
        if failure:
            failure_kinds[failure] += 1

        if title_is(event, "app lifecycle changed"):
            phase = (field(event, "phase") or "").lower()
            if "background" in phase:
                background_at = stamp
            elif "active" in phase and background_at is not None:
                background_gaps.append(max(0.0, stamp - background_at))
                background_at = None

        if title_is(event, "transport dial started"):
            if attempt is not None:
                dials[attempt] = {"stamp": stamp, "peer": peer}
                latest_dial_by_peer[peer] = stamp

        elif title_is(event, "transport connected"):
            if attempt in dials:
                connected_latencies.append(max(0.0, stamp - dials[attempt]["stamp"]))

        elif title_is(event, "rpc session ready"):
            if peer in latest_dial_by_peer:
                usable_latencies.append(max(0.0, stamp - latest_dial_by_peer[peer]))

        elif title_is(event, "transport dial cancelled"):
            cancellations[field(event, "cancellation", "reason") or "unknown"] += 1

        elif title_is(event, "transport dial failed"):
            if failure:
                dial_failures[failure] += 1

        elif title_is(event, "direct dial leg"):
            leg = field(event, "leg") or "unknown"
            direct_stages[leg] += 1
            if "failed" in str(event["title"]) and failure:
                phase_failures[f"{leg}/{failure}"] += 1

        elif title_is(event, "route discovery"):
            outcome = "failed" if "failed" in str(event["title"]) else (
                "succeeded" if "succeeded" in str(event["title"]) else "started"
            )
            discovery_outcomes[outcome] += 1
            duration = as_milliseconds(field(event, "duration"))
            if duration is not None:
                discovery_durations_ms.append(duration)
            bindings = as_int(field(event, "bindings"))
            relay_fleet = as_int(field(event, "relay_fleet"))
            if bindings is not None or relay_fleet is not None:
                discovery_shapes.append({
                    "bindings": bindings,
                    "relay_fleet": relay_fleet,
                })

        elif title_is(event, "direct dial plan assembled"):
            dial_plans.append({
                "public_paths": as_int(field(event, "public_paths")) or 0,
                "private_fallback_paths": as_int(field(event, "private_fallback_paths")) or 0,
                "public_relay_urls": as_int(field(event, "public_relay_urls")) or 0,
            })

        elif title_is(event, "relay policy refresh", "relay policy refreshed"):
            outcome = "failed" if "failed" in str(event["title"]) else (
                "succeeded" if "refreshed" in str(event["title"]) else "started"
            )
            relay_policy_outcomes[outcome] += 1

        elif title_is(event, "network reachability changed"):
            network_reachability[field(event, "network") or "Unknown"] += 1

        elif title_is(event, "recovery coalesced"):
            recovery_coalesced += 1

        elif title_is(event, "connection recovery started"):
            recovery_id = field(event, "recovery", "surface") or f"line-{event['ordinal']}"
            recovery_started[recovery_id] = {"stamp": stamp, "peer": peer}
            latest_recovery_by_peer[peer] = recovery_id

        elif title_is(event, "connection recovery succeeded", "connection recovery failed"):
            outcome = "succeeded" if "succeeded" in str(event["title"]) else "failed"
            recovery_id = field(event, "recovery", "surface")
            if recovery_id is None:
                recovery_id = latest_recovery_by_peer.get(peer)
            if recovery_id in recovery_started:
                recovery_outcomes[outcome] += 1

        elif title_is(event, "transport session state changed"):
            state = (field(event, "state") or "").lower()
            if session is not None:
                key = (peer, session)
                if "established" in state:
                    if not sessions.get(key):
                        sessions[key] = True
                        active_counts[peer] += 1
                        max_active[peer] = max(max_active[peer], active_counts[peer])
                elif any(word in state for word in ("closed", "released", "failed", "evicted")):
                    if sessions.get(key):
                        sessions[key] = False
                        active_counts[peer] = max(0, active_counts[peer] - 1)

        elif title_is(event, "transport session closed"):
            if session is not None:
                key = (peer, session)
                if sessions.get(key):
                    sessions[key] = False
                    active_counts[peer] = max(0, active_counts[peer] - 1)

        elif title_is(event, "selected network path", "transport path changed"):
            path_events[field(event, "path") or field(event, "operation") or "unknown"] += 1

        elif title_is(event, "silent event stream resubscribed"):
            liveness_count += 1

    duplicate_peers = {
        peer: count for peer, count in max_active.items() if count > 1
    }
    empty_plans = sum(
        1
        for plan in dial_plans
        if plan["public_paths"] == 0 and plan["private_fallback_paths"] == 0
    )
    plans_with_public_relay = sum(
        1 for plan in dial_plans if plan["public_relay_urls"] > 0
    )
    public_relay_urls_observed = sum(
        plan["public_relay_urls"] for plan in dial_plans
    )
    public_direct_paths_observed = sum(
        max(0, plan["public_paths"] - plan["public_relay_urls"])
        for plan in dial_plans
    )
    private_fallback_paths_observed = sum(
        plan["private_fallback_paths"] for plan in dial_plans
    )
    no_route_failure_observed = bool(dial_failures.get("no_route")) or any(
        key.endswith("/no_route") for key in phase_failures
    )
    if not no_route_failure_observed:
        route_policy_assessment = "no_no_route_failure"
    elif not dial_plans:
        route_policy_assessment = "plan_diagnostics_unavailable"
    elif empty_plans == len(dial_plans):
        route_policy_assessment = "empty_plan"
    elif plans_with_public_relay == 0:
        route_policy_assessment = "no_public_relay"
    else:
        route_policy_assessment = "public_relay_present"
    route_policy = {
        "assessment": route_policy_assessment,
        "empty_plans": empty_plans,
        "plans_observed": len(dial_plans),
        "plans_with_public_relay": plans_with_public_relay,
        "plans_without_public_relay": len(dial_plans) - plans_with_public_relay,
        "public_direct_paths_observed": public_direct_paths_observed,
        "public_relay_urls_observed": public_relay_urls_observed,
        "private_fallback_paths_observed": private_fallback_paths_observed,
    }
    failures: list[str] = []
    if not connected_latencies and not usable_latencies:
        failures.append("no successful transport or usable RPC connection")
    if dial_failures and not (connected_latencies or usable_latencies):
        failures.append(
            "dial failure kinds: "
            + ", ".join(f"{key}={dial_failures[key]}" for key in sorted(dial_failures))
        )
    if route_policy_assessment == "empty_plan":
        failures.append("recorded dial plans contained no usable route")
    elif route_policy_assessment == "no_public_relay":
        failures.append("no public relay URL was present in recorded dial plans")
    if duplicate_peers:
        failures.append(f"more than one active physical session for {sorted(duplicate_peers)}")
    if expected_background_seconds > 0 and background_gaps:
        if max(background_gaps) < expected_background_seconds:
            failures.append(
                f"background gap max {max(background_gaps):.1f}s is below "
                f"expected {expected_background_seconds:.1f}s"
            )

    return {
        "event_count": len(events),
        "connected_latency_ms": [round(value * 1000, 1) for value in connected_latencies],
        "usable_latency_ms": [round(value * 1000, 1) for value in usable_latencies],
        "usable_latency_ms_p50": round(sorted(usable_latencies)[len(usable_latencies) // 2] * 1000, 1)
        if usable_latencies
        else None,
        "cancellations": dict(cancellations),
        "failure_kinds": dict(failure_kinds),
        "dial_failures": dict(dial_failures),
        "phase_failures": dict(phase_failures),
        "recovery_outcomes": dict(recovery_outcomes),
        "recovery_coalesced": recovery_coalesced,
        "discovery_outcomes": dict(discovery_outcomes),
        "discovery_durations_ms": [round(value, 1) for value in discovery_durations_ms],
        "discovery_shapes": discovery_shapes,
        "dial_plans": dial_plans,
        "route_policy": route_policy,
        "relay_policy_outcomes": dict(relay_policy_outcomes),
        "network_reachability": dict(network_reachability),
        "background_gaps_seconds": [round(value, 1) for value in background_gaps],
        "direct_stages": dict(direct_stages),
        "path_events": dict(path_events),
        "liveness_resubscriptions": liveness_count,
        "max_active_sessions_by_peer": dict(max_active),
        "duplicate_active_session_peers": duplicate_peers,
        "pass": not failures,
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check a cmux-network.log export from a repeatable iOS run."
    )
    parser.add_argument("log", type=Path)
    parser.add_argument(
        "--expect-background-seconds",
        type=float,
        default=0.0,
        help="Require an observed background-to-active gap at least this long.",
    )
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()
    try:
        text = args.log.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"cannot read {args.log}: {error}", file=sys.stderr)
        return 2
    result = analyze(text.splitlines(), args.expect_background_seconds)
    if args.as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        verdict = "PASS" if result["pass"] else "FAIL"
        print(f"{verdict}: {result['event_count']} timeline events")
        print(f"usable latency ms: {result['usable_latency_ms']}")
        print(f"cancellations: {result['cancellations'] or 'none'}")
        print(f"dial failures: {result['dial_failures'] or 'none'}")
        print(f"failure kinds: {result['failure_kinds'] or 'none'}")
        print(f"phase failures: {result['phase_failures'] or 'none'}")
        print(f"recovery outcomes: {result['recovery_outcomes'] or 'none'}")
        print(f"recovery coalesced: {result['recovery_coalesced']}")
        print(f"discovery outcomes: {result['discovery_outcomes'] or 'none'}")
        print(f"discovery durations ms: {result['discovery_durations_ms'] or 'none'}")
        print(f"discovery shapes: {result['discovery_shapes'] or 'none'}")
        print(f"dial plans: {result['dial_plans'] or 'none'}")
        print(f"route policy: {result['route_policy']}")
        print(f"relay policy outcomes: {result['relay_policy_outcomes'] or 'none'}")
        print(f"network reachability: {result['network_reachability'] or 'none'}")
        print(f"background gaps s: {result['background_gaps_seconds'] or 'none'}")
        print(f"direct stages: {result['direct_stages'] or 'none'}")
        print(f"liveness resubscriptions: {result['liveness_resubscriptions']}")
        print(f"max active sessions: {result['max_active_sessions_by_peer'] or 'none'}")
        for failure in result["failures"]:
            print(f"failure: {failure}", file=sys.stderr)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
