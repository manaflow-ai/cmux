#!/usr/bin/env python3
"""Count render-server hitches per `springs` interval of spike p03-rendering-016.

RenderMotionSpikeTests.twelveMaskedPanesSpring marks each spring round as a Points of Interest interval
(subsystem com.cmuxterm.render-motion-spike, name `springs`, message the layer: backingLayer or
motionContainer). Record the run with the xctrace Animation Hitches template, then:

    render-motion-spike-hitches.py RUN.trace [--pid PID]

It exports the trace's hitch table and its signpost interval table (`xcrun xctrace export`), puts each hitch
in the interval it starts in, and prints one line per layer: intervals, hitches, hitches per interval, and the
hitch time in ms (sum and max). `--hitches FILE --intervals FILE` reads tables already exported instead.
`--self-test` checks the parser on a built-in export. Run it on the Mac that recorded the trace (xctrace).
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

LAYERS = ("backingLayer", "motionContainer")
SUBSYSTEM = "com.cmuxterm.render-motion-spike"
INTERVAL_NAME = "springs"
HITCH_SCHEMAS = ("hitches",)
INTERVAL_SCHEMAS = ("os-signpost-interval",)


@dataclass
class Row:
    """One exported row: each column's mnemonic to its value (raw text) and its display text."""

    raw: dict[str, str]
    shown: dict[str, str]

    def text(self) -> str:
        return " ".join(list(self.raw.values()) + list(self.shown.values()))


@dataclass
class Interval:
    layer: str
    start: int
    end: int
    hitches: list[int] = field(default_factory=list)


def parse_table(xml_text: str) -> list[Row]:
    """Rows of an `xctrace export --xpath` table, with `ref` values resolved to the element they point at."""
    root = ET.fromstring(xml_text)
    schema = root.find(".//schema")
    if schema is None:
        return []
    mnemonics = [col.findtext("mnemonic") or "" for col in schema.findall("col")]
    by_id: dict[str, ET.Element] = {}
    for element in root.iter():
        if "id" in element.attrib:
            by_id[element.attrib["id"]] = element

    def resolve(element: ET.Element) -> ET.Element:
        ref = element.attrib.get("ref")
        return by_id.get(ref, element) if ref else element

    def flatten(element: ET.Element) -> str:
        element = resolve(element)
        parts = [element.text.strip()] if element.text and element.text.strip() else []
        parts += [flatten(child) for child in element]
        return " ".join(part for part in parts if part)

    rows = []
    for row in root.iter("row"):
        raw, shown = {}, {}
        for mnemonic, cell in zip(mnemonics, list(row)):
            cell = resolve(cell)
            raw[mnemonic] = flatten(cell)
            shown[mnemonic] = cell.attrib.get("fmt", "")
        rows.append(Row(raw, shown))
    return rows


def first_int(row: Row, *names: str) -> int | None:
    for name in names:
        value = row.raw.get(name, "").split(" ")[0]
        if value.isdigit():
            return int(value)
    return None


def intervals_from(rows: list[Row]) -> list[Interval]:
    found = []
    for row in rows:
        text = row.text()
        if SUBSYSTEM not in text or INTERVAL_NAME not in text:
            continue
        layer = next((name for name in LAYERS if name in text), None)
        start, duration = first_int(row, "start"), first_int(row, "duration")
        if layer and start is not None and duration is not None:
            found.append(Interval(layer, start, start + duration))
    return sorted(found, key=lambda interval: interval.start)


def hitches_from(rows: list[Row], pid: str | None) -> list[tuple[int, int]]:
    """(start, duration) in ns of each hitch, of process `pid` when given."""
    found = []
    for row in rows:
        if pid and pid not in row.raw.get("process", "") + row.shown.get("process", ""):
            continue
        start, duration = first_int(row, "start"), first_int(row, "duration")
        if start is not None and duration is not None:
            found.append((start, duration))
    return found


def summarize(intervals: list[Interval], hitches: list[tuple[int, int]]) -> list[str]:
    for start, duration in hitches:
        for interval in intervals:
            if interval.start <= start < interval.end:
                interval.hitches.append(duration)
                break
    lines = []
    for layer in LAYERS:
        mine = [interval for interval in intervals if interval.layer == layer]
        durations = [duration for interval in mine for duration in interval.hitches]
        per = len(durations) / len(mine) if mine else 0.0
        lines.append(
            f"render-motion-spike hitches layer={layer} intervals={len(mine)} hitches={len(durations)} "
            f"per_interval={per:.2f} hitch_ms_sum={sum(durations) / 1e6:.1f} "
            f"hitch_ms_max={(max(durations) if durations else 0) / 1e6:.1f}"
        )
    return lines


def export(trace: str, *args: str) -> str:
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, *args],
                          check=True, capture_output=True, text=True).stdout


def export_table(trace: str, toc: ET.Element, schemas: tuple[str, ...]) -> str:
    for run in toc.findall("run"):
        number = run.attrib.get("number", "1")
        for table in run.iter("table"):
            if table.attrib.get("schema") in schemas:
                schema = table.attrib["schema"]
                return export(trace, "--xpath", f'/trace-toc/run[@number="{number}"]/data/table[@schema="{schema}"]')
    names = sorted({table.attrib.get("schema", "") for table in toc.iter("table")})
    raise SystemExit(f"no table with schema {' or '.join(schemas)} in the trace; it has: {', '.join(names)}")


SELF_TEST_INTERVALS = """<?xml version="1.0"?>
<trace-query-result><node><schema name="os-signpost-interval">
<col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>name</mnemonic></col>
<col><mnemonic>subsystem</mnemonic></col><col><mnemonic>message</mnemonic></col></schema>
<row><start-time id="1" fmt="00:01.000">1000000000</start-time><duration id="2" fmt="500 ms">500000000</duration>
<string id="3" fmt="springs">springs</string><subsystem id="4" fmt="com.cmuxterm.render-motion-spike">com.cmuxterm.render-motion-spike</subsystem>
<string id="5" fmt="backingLayer">backingLayer</string></row>
<row><start-time id="6" fmt="00:02.000">2000000000</start-time><duration ref="2"/><string ref="3"/><subsystem ref="4"/>
<string id="7" fmt="motionContainer">motionContainer</string></row>
<row><start-time id="8" fmt="00:03.000">3000000000</start-time><duration ref="2"/><string id="9" fmt="other">other</string><subsystem ref="4"/>
<string ref="7"/></row>
</node></trace-query-result>"""

SELF_TEST_HITCHES = """<?xml version="1.0"?>
<trace-query-result><node><schema name="hitches">
<col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>process</mnemonic></col></schema>
<row><start-time id="1" fmt="00:01.100">1100000000</start-time><duration id="2" fmt="16 ms">16000000</duration>
<process id="3" fmt="swiftpm-testing-helper (4242)"><pid id="4" fmt="4242">4242</pid></process></row>
<row><start-time id="5" fmt="00:01.200">1200000000</start-time><duration id="6" fmt="33 ms">33000000</duration><process ref="3"/></row>
<row><start-time id="7" fmt="00:02.100">2100000000</start-time><duration ref="2"/><process ref="3"/></row>
<row><start-time id="8" fmt="00:02.200">2200000000</start-time><duration ref="2"/>
<process id="9" fmt="WindowServer (100)"><pid id="10" fmt="100">100</pid></process></row>
<row><start-time id="11" fmt="00:03.100">3100000000</start-time><duration ref="2"/><process ref="3"/></row>
</node></trace-query-result>"""


def self_test() -> int:
    lines = summarize(intervals_from(parse_table(SELF_TEST_INTERVALS)), hitches_from(parse_table(SELF_TEST_HITCHES), "4242"))
    expected = [
        "render-motion-spike hitches layer=backingLayer intervals=1 hitches=2 per_interval=2.00 hitch_ms_sum=49.0 hitch_ms_max=33.0",
        "render-motion-spike hitches layer=motionContainer intervals=1 hitches=1 per_interval=1.00 hitch_ms_sum=16.0 hitch_ms_max=16.0",
    ]
    if lines != expected:
        print("self-test FAIL:\n  got      " + "\n  got      ".join(lines) + "\n  expected " + "\n  expected ".join(expected))
        return 1
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("trace", nargs="?", help="an xctrace Animation Hitches recording of the spike")
    parser.add_argument("--pid", help="count only the hitches of this process (the hitch-scenario line prints it)")
    parser.add_argument("--hitches", help="an exported hitches table, instead of the trace")
    parser.add_argument("--intervals", help="an exported os-signpost-interval table, instead of the trace")
    parser.add_argument("--self-test", action="store_true", help="check the parser on a built-in export")
    options = parser.parse_args()
    if options.self_test:
        return self_test()
    if options.hitches and options.intervals:
        with open(options.hitches, encoding="utf-8") as hitches, open(options.intervals, encoding="utf-8") as intervals:
            hitch_xml, interval_xml = hitches.read(), intervals.read()
    elif options.trace:
        toc = ET.fromstring(export(options.trace, "--toc"))
        hitch_xml = export_table(options.trace, toc, HITCH_SCHEMAS)
        interval_xml = export_table(options.trace, toc, INTERVAL_SCHEMAS)
    else:
        parser.error("give a trace, or --hitches and --intervals")
    intervals = intervals_from(parse_table(interval_xml))
    if not intervals:
        print(f"no `{INTERVAL_NAME}` intervals of {SUBSYSTEM} in the trace", file=sys.stderr)
        return 2
    for line in summarize(intervals, hitches_from(parse_table(hitch_xml), options.pid)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
