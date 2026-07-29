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
        if settled is None or settled.time_us < sent.time_us:
            continue
        response = None
        while response_index < len(responses):
            candidate = responses[response_index]
            if candidate.time_us < sent.time_us:
                response_index += 1
                continue
            if candidate.time_us <= settled.time_us:
                response = candidate
                response_index += 1
            break
        pairs.append((sent, settled, response))
    return pairs


def pair_host_inputs(
    mac: dict[str, list[Stamp]],
) -> list[tuple[Stamp, Stamp | None]]:
    applied = mac.get("host.in.applied", [])
    applied_index = 0
    pairs: list[tuple[Stamp, Stamp | None]] = []
    for received in mac.get("host.in.recv", []):
        while applied_index < len(applied) and applied[applied_index].time_us < received.time_us:
            applied_index += 1
        match = applied[applied_index] if applied_index < len(applied) else None
        if match is not None:
            applied_index += 1
        pairs.append((received, match))
    return pairs


def frame_chain(
    sequence: int,
    after_us: int,
    ios: dict[str, list[Stamp]],
) -> tuple[Stamp, Stamp, Stamp, Stamp] | None:
    gate = first_after(
        ios.get("gate", []),
        after_us,
        lambda stamp: stamp.fields.get("out") == "delivered"
        and stamp.integer("seq") is not None
        and stamp.integer("seq") >= sequence,
    )
    if gate is None:
        return None
    frame_sequence = gate.integer("seq")
    yielded = first_after(
        ios.get("ap.yield", []),
        gate.time_us,
        lambda stamp: stamp.integer("seq") == frame_sequence,
    )
    if yielded is None:
        return None
    done = first_after(
        ios.get("ap.done", []),
        yielded.time_us,
        lambda stamp: stamp.integer("seq") == frame_sequence,
    )
    if done is None:
        return None
    presented = first_after(
        ios.get("rd.present", []),
        done.time_us,
        lambda stamp: stamp.integer("seq") in (None, frame_sequence),
    )
    if presented is None:
        return None
    return gate, yielded, done, presented


def mac_frame_chain(
    applied: Stamp,
    mac: dict[str, list[Stamp]],
) -> tuple[Stamp, Stamp, Stamp] | None:
    sequence = applied.integer("seq")
    if sequence is None:
        return None
    grid = first_after(
        mac.get("host.grid", []),
        applied.time_us,
        lambda stamp: stamp.integer("seq") is not None
        and stamp.integer("seq") >= sequence,
    )
    if grid is None:
        return None
    grid_sequence = grid.integer("seq")
    enqueued = first_after(
        mac.get("host.enq", []),
        grid.time_us,
        lambda stamp: stamp.integer("seq") == grid_sequence,
    )
    if enqueued is None:
        return None
    written = first_after(
        mac.get("host.write", []),
        enqueued.time_us,
        lambda stamp: stamp.integer("seq") == grid_sequence,
    )
    if written is None:
        return None
    return grid, enqueued, written


def analyze(mac_stamps: list[Stamp], ios_stamps: list[Stamp], same_clock: bool) -> Analysis:
    mac = by_stage(mac_stamps)
    ios = by_stage(ios_stamps)
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
        if sequence is None:
            continue
        gate = first_after(
            ios.get("gate", []),
            event.time_us,
            lambda stamp: stamp.integer("seq") == sequence,
        )
        if gate is None:
            continue
        add_duration(metrics, "iOS: ev.grid → gate", event, gate)
        if gate.fields.get("out") != "delivered":
            continue
        chain = frame_chain(sequence, gate.time_us, ios)
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
        if response is None or ack_sequence is None:
            continue
        chain = frame_chain(ack_sequence, response.time_us, ios)
        if chain is not None:
            add_duration(metrics, "Probe E2E echo", probe, chain[3])

    cross_clock_enabled = same_clock
    warning = None
    joined_count = min(len(input_pairs), len(host_input_pairs))
    host_by_input_index: dict[int, tuple[Stamp, Stamp | None]] = {}
    if same_clock and joined_count:
        violations = 0
        for index in range(joined_count):
            sent, settled, _ = input_pairs[index]
            host_pair = host_input_pairs[index]
            received = host_pair[0]
            if sent.time_us <= received.time_us <= settled.time_us:
                host_by_input_index[index] = host_pair
            else:
                violations += 1
        if violations / joined_count > 0.10:
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
        for written in mac.get("host.write", []):
            sequence = written.integer("seq")
            if sequence is None:
                continue
            received_grid = first_after(
                ios.get("ev.grid", []),
                written.time_us,
                lambda stamp: stamp.integer("seq") == sequence,
            )
            if received_grid is not None:
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
            if ack_sequence is None:
                continue
            ios_chain = frame_chain(ack_sequence, response.time_us, ios)
            if ios_chain is None:
                continue
            gate, yielded, done, presented = ios_chain
            echo_sequence = gate.integer("seq")
            grid = first_after(
                mac.get("host.grid", []),
                applied.time_us,
                lambda stamp: stamp.integer("seq") == echo_sequence,
            )
            if grid is None:
                continue
            enqueued = first_after(
                mac.get("host.enq", []),
                grid.time_us,
                lambda stamp: stamp.integer("seq") == echo_sequence,
            )
            if enqueued is None:
                continue
            written = first_after(
                mac.get("host.write", []),
                enqueued.time_us,
                lambda stamp: stamp.integer("seq") == echo_sequence,
            )
            if written is None:
                continue
            ios_event = first_after(
                ios.get("ev.grid", []),
                written.time_us,
                lambda stamp: stamp.integer("seq") == echo_sequence,
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

    return Analysis(metrics, echo_hops, cross_clock_enabled, warning)


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
LAT in.resp t=1400 ack_seq=10
LAT in.settled t=1500 n=1
LAT ev.grid t=1700 seq=10 bytes=100 dec_us=100
LAT gate t=1800 seq=10 out=delivered
LAT ap.yield t=1900 seq=10
LAT ap.done t=2200 seq=10 path=legacy us=300
LAT rd.present t=2500 seq=10
LAT sync.applied t=5000 coll=workspaces rev=2
LAT probe.send t=10000 i=1
LAT in.send t=10100 n=2 bytes=1
LAT in.resp t=10400 ack_seq=20
LAT in.settled t=10500 n=2
LAT ev.grid t=11000 seq=20 bytes=120 dec_us=200
LAT gate t=11100 seq=20 out=delivered
LAT ap.yield t=11200 seq=20
LAT ap.done t=11600 seq=20 path=verified us=400
LAT rd.present t=12000 seq=20
"""
    mac_fixture = """
LAT host.in.recv t=1200 bytes=1
LAT host.in.applied t=1300 seq=10
LAT host.grid t=1600 seq=10 exp_us=200 bytes=100 kind=delta
LAT host.enq t=1650 seq=10 depth=1
LAT host.write t=1680 seq=10 us=30
LAT host.sync.emit t=4800 coll=workspaces rev=2 rows=1
LAT host.in.recv t=10200 bytes=1
LAT host.in.applied t=10300 seq=20
LAT host.grid t=10600 seq=20 exp_us=250 bytes=120 kind=delta
LAT host.enq t=10700 seq=20 depth=1
LAT host.write t=10900 seq=20 us=200
"""
    result = analyze(
        parse_log(mac_fixture, "mac"),
        parse_log(ios_fixture, "ios"),
        same_clock=True,
    )
    assert result.cross_clock_enabled
    assert len(parse_log("noise LAT gate t=7 seq=1 out=delivered", "ios")) == 1
    assert summary(result.metrics_ms["Input RTT"])["p50"] == 0.4
    assert summary(result.metrics_ms["Probe E2E echo"])["p50"] == 1.75
    assert summary(result.metrics_ms["Same clock: state sync"])["p50"] == 0.2
    assert math.isclose(
        summary(result.echo_hops_ms["host.write → ev.grid"])["p50"],
        0.06,
    )
    mismatched = analyze(
        parse_log(mac_fixture.replace("t=1200 bytes=1", "t=900 bytes=1"), "mac"),
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
