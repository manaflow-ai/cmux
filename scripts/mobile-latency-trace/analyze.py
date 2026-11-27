#!/usr/bin/env python3
"""Analyze cmux iOS↔Mac latency trace stamps."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


LINE_RE = re.compile(r"LAT\s+(?P<stage>\S+)\s+t=(?P<time>\d+)(?P<fields>.*)")
FIELD_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>\S+)")
BASE_METRICS = [
    "Input RTT",
    "Probe E2E echo",
    "iOS: ev.grid decode",
    "iOS: ev.grid → gate",
    "iOS: gate → ap.yield",
    "iOS: ap.yield → ap.done",
    "iOS: ap.done → rd.present",
    "Mac: host.in.recv → host.in.applied",
    "Mac: host.in.applied → host.grid",
    "Mac: host.grid → host.enq",
    "Mac: host.enq → host.write",
]
CROSS_CLOCK_METRICS = [
    "Same clock: host.write → ev.grid",
    "Same clock: state sync",
]
ECHO_HOPS = [
    "probe.send → host.in.recv",
    "host.in.recv → host.in.applied",
    "host.in.applied → host.grid",
    "host.grid → host.write",
    "host.write → ev.grid",
    "ev.grid → gate",
    "gate → ap.yield",
    "ap.yield → ap.done",
    "ap.done → rd.present",
]


@dataclass(frozen=True)
class Stamp:
    stage: str
    time_us: int
    fields: dict[str, str]
    source: str
    ordinal: int

    def integer(self, key: str) -> int | None:
        value = self.fields.get(key)
        try:
            return int(value) if value is not None else None
        except ValueError:
            return None


@dataclass
class Analysis:
    metrics_ms: dict[str, list[float]]
    echo_hops_ms: dict[str, list[float]]
    cross_clock_enabled: bool
    warning: str | None
    dropped_stamps_by_side: dict[str, int]


def parse_log(text: str, source: str) -> list[Stamp]:
    stamps: list[Stamp] = []
    for ordinal, line in enumerate(text.splitlines()):
        match = LINE_RE.search(line)
        if not match:
            continue
        fields = {
            field.group("key"): field.group("value")
            for field in FIELD_RE.finditer(match.group("fields"))
        }
        stamps.append(
            Stamp(
                stage=match.group("stage"),
                time_us=int(match.group("time")),
                fields=fields,
                source=source,
                ordinal=ordinal,
            )
        )
    return sorted(stamps, key=lambda stamp: (stamp.time_us, stamp.ordinal))


def by_stage(stamps: Iterable[Stamp]) -> dict[str, list[Stamp]]:
    grouped: dict[str, list[Stamp]] = {}
    for stamp in stamps:
        grouped.setdefault(stamp.stage, []).append(stamp)
    return grouped


def first_after(
    stamps: Iterable[Stamp],
    time_us: int,
    predicate: Callable[[Stamp], bool] = lambda _: True,
    maximum_time_us: int | None = None,
) -> Stamp | None:
    for stamp in stamps:
        if stamp.time_us < time_us:
            continue
        if maximum_time_us is not None and stamp.time_us > maximum_time_us:
            return None
        if predicate(stamp):
            return stamp
    return None


def surface_sequence(stamp: Stamp) -> tuple[str, int] | None:
    surface = stamp.fields.get("s")
    sequence = stamp.integer("seq")
    if surface is None or sequence is None:
        return None
    return surface, sequence


def pair_wire_events(
    writes: Iterable[Stamp],
    events: Iterable[Stamp],
) -> list[tuple[Stamp, Stamp]]:
    """Pair each grid receipt with one unmatched write in cohort FIFO order."""
    writes_by_identity: dict[tuple[str, int], list[Stamp]] = {}
    for stamp in writes:
        identity = surface_sequence(stamp)
        if identity is not None:
            writes_by_identity.setdefault(identity, []).append(stamp)
    write_indices: dict[tuple[str, int], int] = {}
    pairs: list[tuple[Stamp, Stamp]] = []
    for event in events:
        identity = surface_sequence(event)
        if identity is None:
            continue
        candidates = writes_by_identity.get(identity, [])
        index = write_indices.get(identity, 0)
        if index >= len(candidates) or candidates[index].time_us > event.time_us:
            continue
        pairs.append((candidates[index], event))
        write_indices[identity] = index + 1
    return pairs


def duration_ms(start: Stamp, end: Stamp) -> float | None:
    if end.time_us < start.time_us:
        return None
    return (end.time_us - start.time_us) / 1_000.0


def add_duration(
    metrics: dict[str, list[float]],
    name: str,
    start: Stamp,
    end: Stamp,
) -> None:
    value = duration_ms(start, end)
    if value is not None:
        metrics.setdefault(name, []).append(value)


def pair_input_batches(
    ios: dict[str, list[Stamp]],
) -> list[tuple[Stamp, Stamp, Stamp | None]]:
    settled_by_number = {
        stamp.integer("n"): stamp
        for stamp in ios.get("in.settled", [])
        if stamp.integer("n") is not None
    }
    responses = ios.get("in.resp", [])
    response_index = 0
    pairs: list[tuple[Stamp, Stamp, Stamp | None]] = []
    for sent in ios.get("in.send", []):
        number = sent.integer("n")
        settled = settled_by_number.get(number)
        sent_order = (sent.time_us, sent.ordinal)
        if settled is None or (settled.time_us, settled.ordinal) < sent_order:
            continue
        response = None
        if settled.integer("ok") == 1:
            while response_index < len(responses):
                candidate = responses[response_index]
                if (candidate.time_us, candidate.ordinal) < sent_order:
                    response_index += 1
                    continue
                response = candidate
                response_index += 1
                break
        pairs.append((sent, settled, response))
    return pairs


def pair_host_inputs(
    mac: dict[str, list[Stamp]],
) -> list[tuple[Stamp, Stamp | None]]:
    applied_by_surface: dict[str, list[Stamp]] = {}
    for stamp in mac.get("host.in.applied", []):
        surface = stamp.fields.get("s")
        if surface is not None:
            applied_by_surface.setdefault(surface, []).append(stamp)
    applied_indices: dict[str, int] = {}
    pairs: list[tuple[Stamp, Stamp | None]] = []
    for received in mac.get("host.in.recv", []):
        surface = received.fields.get("s")
        candidates = applied_by_surface.get(surface, []) if surface is not None else []
        applied_index = applied_indices.get(surface, 0) if surface is not None else 0
        while (
            applied_index < len(candidates)
            and candidates[applied_index].time_us < received.time_us
        ):
            applied_index += 1
        match = candidates[applied_index] if applied_index < len(candidates) else None
        if match is not None:
            applied_index += 1
        if surface is not None:
            applied_indices[surface] = applied_index
        pairs.append((received, match))
    return pairs


def first_presentation_for_done(
    done: Stamp,
    ios: dict[str, list[Stamp]],
) -> Stamp | None:
    surface = done.fields.get("s")
    if surface is None:
        return None
    done_order = (done.time_us, done.ordinal)
    for presented in ios.get("rd.present", []):
        if (presented.time_us, presented.ordinal) < done_order:
            continue
        if presented.fields.get("s") != surface:
            continue
        presented_order = (presented.time_us, presented.ordinal)
        latest_done = None
        for candidate in ios.get("ap.done", []):
            if (candidate.time_us, candidate.ordinal) > presented_order:
                break
            if candidate.fields.get("s") == surface:
                latest_done = candidate
        if latest_done is done:
            return presented
        if latest_done is not None and (
            latest_done.time_us,
            latest_done.ordinal,
        ) > done_order:
            return None
    return None


def frame_chain(
    surface: str,
    sequence: int,
    after_us: int,
    ios: dict[str, list[Stamp]],
) -> tuple[Stamp, Stamp, Stamp, Stamp] | None:
    gate = first_after(
        ios.get("gate", []),
        after_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.fields.get("out") == "delivered"
        and stamp.integer("seq") is not None
        and stamp.integer("seq") >= sequence,
    )
    if gate is None:
        return None
    frame_sequence = gate.integer("seq")
    yielded = first_after(
        ios.get("ap.yield", []),
        gate.time_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.integer("seq") == frame_sequence,
    )
    if yielded is None:
        return None
    done = first_after(
        ios.get("ap.done", []),
        yielded.time_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.integer("seq") == frame_sequence,
    )
    if done is None:
        return None
    presented = first_presentation_for_done(done, ios)
    if presented is None:
        return None
    return gate, yielded, done, presented


def mac_frame_chain(
    applied: Stamp,
    mac: dict[str, list[Stamp]],
) -> tuple[Stamp, Stamp, Stamp] | None:
    sequence = applied.integer("seq")
    surface = applied.fields.get("s")
    if sequence is None or surface is None:
        return None
    grid = first_after(
        mac.get("host.grid", []),
        applied.time_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.integer("seq") is not None
        and stamp.integer("seq") >= sequence,
    )
    if grid is None:
        return None
    grid_sequence = grid.integer("seq")
    written = first_after(
        mac.get("host.write", []),
        grid.time_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.integer("seq") == grid_sequence,
    )
    if written is None:
        return None
    connection = written.fields.get("conn")
    enqueued = first_after(
        mac.get("host.enq", []),
        grid.time_us,
        lambda stamp: stamp.fields.get("s") == surface
        and stamp.fields.get("conn") == connection
        and stamp.integer("seq") == grid_sequence,
        maximum_time_us=written.time_us,
    )
    if enqueued is None:
        return None
    return grid, enqueued, written


def analyze(mac_stamps: list[Stamp], ios_stamps: list[Stamp], same_clock: bool) -> Analysis:
    mac = by_stage(mac_stamps)
    ios = by_stage(ios_stamps)
    dropped_stamps_by_side: dict[str, int] = {}
    for stamp in mac.get("trace.dropped", []) + ios.get("trace.dropped", []):
        count = stamp.integer("n")
        if count is None or count <= 0:
            continue
        side = stamp.fields.get("side", stamp.source)
        dropped_stamps_by_side[side] = dropped_stamps_by_side.get(side, 0) + count
    metrics: dict[str, list[float]] = {name: [] for name in BASE_METRICS}
    echo_hops: dict[str, list[float]] = {}
    input_pairs = pair_input_batches(ios)
    host_input_pairs = pair_host_inputs(mac)

    for sent, settled, _ in input_pairs:
        add_duration(metrics, "Input RTT", sent, settled)
    for event in ios.get("ev.grid", []):
        decode_us = event.integer("dec_us")
        if decode_us is not None:
            metrics.setdefault("iOS: ev.grid decode", []).append(decode_us / 1_000.0)
        sequence = event.integer("seq")
        surface = event.fields.get("s")
        if sequence is None or surface is None:
            continue
        gate = first_after(
            ios.get("gate", []),
            event.time_us,
            lambda stamp: stamp.fields.get("s") == surface
            and stamp.integer("seq") == sequence,
        )
        if gate is None:
            continue
        add_duration(metrics, "iOS: ev.grid → gate", event, gate)
        if gate.fields.get("out") != "delivered":
            continue
        chain = frame_chain(surface, sequence, gate.time_us, ios)
        if chain is None:
            continue
        _, yielded, done, presented = chain
        add_duration(metrics, "iOS: gate → ap.yield", gate, yielded)
        add_duration(metrics, "iOS: ap.yield → ap.done", yielded, done)
        add_duration(metrics, "iOS: ap.done → rd.present", done, presented)

    for received, applied in host_input_pairs:
        if applied is None:
            continue
        add_duration(metrics, "Mac: host.in.recv → host.in.applied", received, applied)
        chain = mac_frame_chain(applied, mac)
        if chain is None:
            continue
        grid, enqueued, written = chain
        add_duration(metrics, "Mac: host.in.applied → host.grid", applied, grid)
        add_duration(metrics, "Mac: host.grid → host.enq", grid, enqueued)
        add_duration(metrics, "Mac: host.enq → host.write", enqueued, written)

    probe_bindings: list[tuple[Stamp, tuple[Stamp, Stamp, Stamp | None]]] = []
    input_index = 0
    for probe in ios.get("probe.send", []):
        while input_index < len(input_pairs) and input_pairs[input_index][0].time_us < probe.time_us:
            input_index += 1
        if input_index >= len(input_pairs):
            break
        binding = input_pairs[input_index]
        input_index += 1
        probe_bindings.append((probe, binding))
        response = binding[2]
        ack_sequence = response.integer("ack_seq") if response is not None else None
        surface = response.fields.get("s") if response is not None else None
        if response is None or ack_sequence is None or surface is None:
            continue
        chain = frame_chain(surface, ack_sequence, response.time_us, ios)
        if chain is not None:
            add_duration(metrics, "Probe E2E echo", probe, chain[3])

    cross_clock_enabled = same_clock
    warning = None
    host_by_input_index: dict[int, tuple[Stamp, Stamp | None]] = {}
    if same_clock:
        host_pairs_by_surface: dict[str, list[tuple[Stamp, Stamp | None]]] = {}
        for host_pair in host_input_pairs:
            surface = host_pair[0].fields.get("s")
            if surface is not None:
                host_pairs_by_surface.setdefault(surface, []).append(host_pair)
        host_pair_indices: dict[str, int] = {}
        joined_count = 0
        violations = 0
        for index, (sent, settled, response) in enumerate(input_pairs):
            surface = response.fields.get("s") if response is not None else None
            if surface is None:
                continue
            candidates = host_pairs_by_surface.get(surface, [])
            host_index = host_pair_indices.get(surface, 0)
            while (
                host_index < len(candidates)
                and candidates[host_index][0].time_us < sent.time_us
            ):
                host_index += 1
            if host_index >= len(candidates):
                continue
            host_pair = candidates[host_index]
            host_pair_indices[surface] = host_index + 1
            joined_count += 1
            received = host_pair[0]
            if sent.time_us <= received.time_us <= settled.time_us:
                host_by_input_index[index] = host_pair
            else:
                violations += 1
        if joined_count and violations / joined_count > 0.10:
            cross_clock_enabled = False
            warning = (
                "WARNING: host.in.recv fell outside in.send→in.settled for "
                f"{violations}/{joined_count} joins; dropping cross-clock metrics."
            )

    if cross_clock_enabled:
        for name in CROSS_CLOCK_METRICS:
            metrics.setdefault(name, [])
        for name in ECHO_HOPS:
            echo_hops.setdefault(name, [])
        for written, received_grid in pair_wire_events(
            mac.get("host.write", []),
            ios.get("ev.grid", []),
        ):
            add_duration(metrics, "Same clock: host.write → ev.grid", written, received_grid)

        for emitted in mac.get("host.sync.emit", []):
            collection = emitted.fields.get("coll")
            revision = emitted.integer("rev")
            applied = first_after(
                ios.get("sync.applied", []),
                emitted.time_us,
                lambda stamp: stamp.fields.get("coll") == collection
                and stamp.integer("rev") == revision,
            )
            if applied is not None:
                add_duration(metrics, "Same clock: state sync", emitted, applied)

        input_identity = {id(pair): index for index, pair in enumerate(input_pairs)}
        for probe, binding in probe_bindings:
            index = input_identity.get(id(binding))
            host_pair = host_by_input_index.get(index) if index is not None else None
            response = binding[2]
            if host_pair is None or response is None:
                continue
            received, applied = host_pair
            if applied is None:
                continue
            ack_sequence = response.integer("ack_seq")
            surface = response.fields.get("s")
            if ack_sequence is None or surface is None:
                continue
            ios_chain = frame_chain(surface, ack_sequence, response.time_us, ios)
            if ios_chain is None:
                continue
            gate, yielded, done, presented = ios_chain
            echo_sequence = gate.integer("seq")
            if echo_sequence is None:
                continue
            grid = first_after(
                mac.get("host.grid", []),
                applied.time_us,
                lambda stamp: stamp.fields.get("s") == surface
                and stamp.integer("seq") == echo_sequence,
            )
            if grid is None:
                continue
            written = first_after(
                mac.get("host.write", []),
                grid.time_us,
                lambda stamp: stamp.fields.get("s") == surface
                and stamp.integer("seq") == echo_sequence,
            )
            if written is None:
                continue
            connection = written.fields.get("conn")
            enqueued = first_after(
                mac.get("host.enq", []),
                grid.time_us,
                lambda stamp: stamp.fields.get("s") == surface
                and stamp.fields.get("conn") == connection
                and stamp.integer("seq") == echo_sequence,
                maximum_time_us=written.time_us,
            )
            if enqueued is None:
                continue
            ios_event = first_after(
                ios.get("ev.grid", []),
                written.time_us,
                lambda stamp: stamp.fields.get("s") == surface
                and stamp.integer("seq") == echo_sequence,
            )
            if ios_event is None:
                continue
            hops = [
                ("probe.send → host.in.recv", probe, received),
                ("host.in.recv → host.in.applied", received, applied),
                ("host.in.applied → host.grid", applied, grid),
                ("host.grid → host.write", grid, written),
                ("host.write → ev.grid", written, ios_event),
                ("ev.grid → gate", ios_event, gate),
                ("gate → ap.yield", gate, yielded),
                ("ap.yield → ap.done", yielded, done),
                ("ap.done → rd.present", done, presented),
            ]
            for name, start, end in hops:
                add_duration(echo_hops, name, start, end)

    return Analysis(
        metrics,
        echo_hops,
        cross_clock_enabled,
        warning,
        dropped_stamps_by_side,
    )


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def summary(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "p50": None, "p95": None, "max": None}
    return {
        "count": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def markdown_table(title: str, metrics: dict[str, list[float]]) -> str:
    lines = [
        f"## {title}",
        "",
        "| Metric | Count | p50 (ms) | p95 (ms) | Max (ms) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name, values in metrics.items():
        stats = summary(values)
        if stats["count"] == 0:
            lines.append(f"| {name} | 0 | — | — | — |")
        else:
            lines.append(
                f"| {name} | {stats['count']} | {stats['p50']:.1f} | "
                f"{stats['p95']:.1f} | {stats['max']:.1f} |"
            )
    if not metrics:
        lines.append("| No joined samples | 0 | — | — | — |")
    return "\n".join(lines)


def render_markdown(analysis: Analysis) -> str:
    sections: list[str] = []
    if analysis.dropped_stamps_by_side:
        counts = ", ".join(
            f"{side}={count}"
            for side, count in sorted(analysis.dropped_stamps_by_side.items())
        )
        sections.extend([
            (
                "WARNING: LATENCY TRACE DROPPED STAMPS "
                f"({counts}). Tables below use a partial sample."
            ),
            "",
        ])
    if analysis.warning:
        sections.extend([analysis.warning, ""])
    sections.append(markdown_table("Latency summary", analysis.metrics_ms))
    if analysis.cross_clock_enabled:
        sections.extend(["", markdown_table("Same-clock echo decomposition", analysis.echo_hops_ms)])
    return "\n".join(sections)


def run_selftest() -> None:
    ios_fixture = """
prefix LAT probe.send t=1000 i=0
LAT in.send t=1100 n=1 bytes=1
LAT in.settled t=1390 n=1 ok=1
LAT in.resp t=1400 s=aaaaaaaa ack_seq=10
LAT ev.grid t=1700 s=aaaaaaaa seq=10 bytes=100 dec_us=100
LAT gate t=1750 s=bbbbbbbb seq=10 out=delivered
LAT gate t=1800 s=aaaaaaaa seq=10 out=delivered
LAT ap.yield t=1850 s=bbbbbbbb seq=10
LAT ap.yield t=1900 s=aaaaaaaa seq=10
LAT ap.done t=2000 s=bbbbbbbb seq=10 path=legacy us=150
LAT rd.present t=2050 s=bbbbbbbb seq=10
LAT ap.done t=2200 s=aaaaaaaa seq=10 path=legacy us=300
LAT rd.present t=2500 s=aaaaaaaa seq=10
LAT sync.applied t=5000 coll=workspaces rev=2
LAT probe.send t=10000 i=1
LAT in.send t=10100 n=2 bytes=1
LAT in.settled t=10500 n=2 ok=1
LAT in.resp t=10500 s=aaaaaaaa ack_seq=20
LAT ev.grid t=11000 s=aaaaaaaa seq=20 bytes=120 dec_us=200
LAT gate t=11100 s=aaaaaaaa seq=20 out=delivered
LAT ap.yield t=11200 s=aaaaaaaa seq=20
LAT ap.done t=11600 s=aaaaaaaa seq=20 path=verified us=400
LAT rd.present t=12000 s=aaaaaaaa seq=20
LAT trace.dropped t=12100 n=7 side=ios
"""
    mac_fixture = """
LAT host.in.recv t=1200 s=aaaaaaaa bytes=1
LAT host.in.applied t=1250 s=bbbbbbbb seq=10
LAT host.in.applied t=1300 s=aaaaaaaa seq=10
LAT host.grid t=1500 s=bbbbbbbb seq=10 exp_us=100 bytes=80 kind=delta
LAT host.grid t=1600 s=aaaaaaaa seq=10 exp_us=200 bytes=100 kind=delta
LAT host.enq t=1650 s=aaaaaaaa conn=11111111 seq=10 depth=1
LAT host.enq t=1660 s=aaaaaaaa conn=22222222 seq=10 depth=1
LAT host.write t=1680 s=aaaaaaaa conn=11111111 seq=10 us=30
LAT host.write t=1690 s=aaaaaaaa conn=22222222 seq=10 us=30
LAT host.sync.emit t=4800 coll=workspaces rev=2 rows=1
LAT host.in.recv t=10200 s=aaaaaaaa bytes=1
LAT host.in.applied t=10300 s=aaaaaaaa seq=20
LAT host.grid t=10600 s=aaaaaaaa seq=20 exp_us=250 bytes=120 kind=delta
LAT host.enq t=10700 s=aaaaaaaa conn=11111111 seq=20 depth=1
LAT host.write t=10900 s=aaaaaaaa conn=11111111 seq=20 us=200
LAT trace.dropped t=11000 n=3 side=mac
"""
    result = analyze(
        parse_log(mac_fixture, "mac"),
        parse_log(ios_fixture, "ios"),
        same_clock=True,
    )
    assert result.cross_clock_enabled
    assert result.dropped_stamps_by_side == {"mac": 3, "ios": 7}
    drop_warning = render_markdown(result)
    assert "WARNING: LATENCY TRACE DROPPED STAMPS" in drop_warning
    assert "ios=7" in drop_warning
    assert "mac=3" in drop_warning
    assert len(parse_log("noise LAT gate t=7 s=aaaaaaaa seq=1 out=delivered", "ios")) == 1
    assert summary(result.metrics_ms["Input RTT"])["p50"] == 0.345
    assert summary(result.metrics_ms["Probe E2E echo"])["p50"] == 1.75
    assert summary(result.metrics_ms["Same clock: state sync"])["p50"] == 0.2
    assert summary(result.metrics_ms["Mac: host.in.recv → host.in.applied"])[
        "p50"
    ] == 0.1
    assert len(result.metrics_ms["Same clock: host.write → ev.grid"]) == 2
    assert math.isclose(
        summary(result.echo_hops_ms["host.write → ev.grid"])["p50"],
        0.06,
    )
    input_pairs = pair_input_batches(by_stage(parse_log(ios_fixture, "ios")))
    assert input_pairs[0][2] is not None
    assert input_pairs[0][2].time_us > input_pairs[0][1].time_us
    failed_then_successful_fixture = by_stage(parse_log(
        """
LAT in.send t=10 n=1 bytes=1
LAT in.settled t=20 n=1 ok=0
LAT in.send t=30 n=2 bytes=1
LAT in.settled t=40 n=2 ok=1
LAT in.resp t=50 s=aaaaaaaa ack_seq=2
""",
        "ios",
    ))
    failed_then_successful_pairs = pair_input_batches(failed_then_successful_fixture)
    assert failed_then_successful_pairs[0][2] is None
    assert failed_then_successful_pairs[1][2] is not None
    assert failed_then_successful_pairs[1][2].integer("ack_seq") == 2
    presentation_fixture = by_stage(parse_log(
        """
LAT ap.done t=10 s=aaaaaaaa seq=1
LAT ap.done t=20 s=aaaaaaaa seq=2
LAT rd.present t=30 s=aaaaaaaa seq=2
""",
        "ios",
    ))
    earlier_done, latest_done = presentation_fixture["ap.done"]
    assert first_presentation_for_done(earlier_done, presentation_fixture) is None
    assert first_presentation_for_done(latest_done, presentation_fixture) is not None
    repeated_wire_fixture = by_stage(parse_log(
        """
LAT host.write t=10 s=aaaaaaaa conn=11111111 seq=7
LAT host.write t=11 s=aaaaaaaa conn=22222222 seq=7
LAT host.write t=12 s=bbbbbbbb conn=33333333 seq=7
LAT ev.grid t=19 s=bbbbbbbb seq=7
LAT ev.grid t=20 s=aaaaaaaa seq=7
LAT host.write t=30 s=aaaaaaaa conn=11111111 seq=7
LAT host.write t=31 s=aaaaaaaa conn=22222222 seq=7
LAT ev.grid t=40 s=aaaaaaaa seq=7
""",
        "shared",
    ))
    repeated_wire_pairs = pair_wire_events(
        repeated_wire_fixture["host.write"],
        repeated_wire_fixture["ev.grid"],
    )
    assert [
        (pair[0].fields["s"], pair[0].time_us)
        for pair in repeated_wire_pairs
    ] == [("bbbbbbbb", 12), ("aaaaaaaa", 10), ("aaaaaaaa", 11)]
    overlapping_wire_fixture = by_stage(parse_log(
        """
LAT host.write t=10 s=aaaaaaaa conn=11111111 seq=7
LAT host.write t=30 s=aaaaaaaa conn=11111111 seq=7
LAT ev.grid t=20 s=aaaaaaaa seq=7
LAT ev.grid t=50 s=aaaaaaaa seq=7
""",
        "shared",
    ))
    overlapping_wire_pairs = pair_wire_events(
        overlapping_wire_fixture["host.write"],
        overlapping_wire_fixture["ev.grid"],
    )
    assert [
        (written.time_us, received.time_us)
        for written, received in overlapping_wire_pairs
    ] == [(10, 20), (30, 50)]
    assert [
        duration_ms(written, received)
        for written, received in overlapping_wire_pairs
    ] == [0.01, 0.02]
    mismatched = analyze(
        parse_log(
            mac_fixture.replace(
                "t=1200 s=aaaaaaaa bytes=1",
                "t=900 s=aaaaaaaa bytes=1",
            ),
            "mac",
        ),
        parse_log(ios_fixture, "ios"),
        same_clock=True,
    )
    assert not mismatched.cross_clock_enabled
    assert mismatched.warning is not None
    print("selftest passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-log", type=Path)
    parser.add_argument("--ios-log", type=Path)
    parser.add_argument("--same-clock", action="store_true")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        run_selftest()
        return 0
    if args.mac_log is None or args.ios_log is None:
        parser.error("--mac-log and --ios-log are required unless --selftest is used")
    analysis = analyze(
        parse_log(args.mac_log.read_text(errors="replace"), "mac"),
        parse_log(args.ios_log.read_text(errors="replace"), "ios"),
        same_clock=args.same_clock,
    )
    if args.as_json:
        print(
            json.dumps(
                {
                    "cross_clock_enabled": analysis.cross_clock_enabled,
                    "warning": analysis.warning,
                    "dropped_stamps_by_side": analysis.dropped_stamps_by_side,
                    "metrics_ms": analysis.metrics_ms,
                    "echo_hops_ms": analysis.echo_hops_ms,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print(render_markdown(analysis))
    return 0


if __name__ == "__main__":
    sys.exit(main())
