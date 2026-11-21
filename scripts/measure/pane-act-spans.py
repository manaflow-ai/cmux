#!/usr/bin/env python3
"""Reads the parts of ONE pane act (a zoom, an unzoom) from what scripts/cmux-next/pane-zoom-terminal.py keeps of it.

The app writes 5 spans for an act when the trace is on: `layout.act.arm`, `layout.act.sizes`, `layout.act.pass` and
`layout.act.place` one time each, and `layout.act.report` at EACH report of presence (also with no act). The tool
records ONE act in ONE record and keeps, for each round, the record's `spans_full`, the raw list of the `layout.act.`
spans and the count of the frames in which panes moved. This reader gives a number only when the round can carry it:

- a pane moved in the record: 1 or more `layout.commit` samples above 0. A record with each span and no pane that
  moved is not the act that the numbers are for (the key did nothing, or the panes' move is off).
- `spans_full` must be there and false: a full list dropped the spans that ended later.
- each of the 4 one-time spans is there exactly one time. None: a begin with no end, or no act in the record. Two or
  more: 2 acts in one record, or a second change before the pass.
- the 4 are in their order (arm, sizes, pass, place), and the pass ends where the place begins: a span that came from
  an older begin starts before its act's arm and fails here.
- a report span is the act's own only when it starts in the act's window (from the arm's start to the place's end).
  Each other report span is printed with its time and is in no number of the act.

Each number of `layout.act.report` is a LOWER bound, and the table says `at least`: a report that starts in a report
gives ONE span, from the outer begin to the inner end, and nothing in the answer tells it from a short report.

A group (a layout and an act) with fewer than 3 valid rounds is NOT MEASURED and has no median.

Two inputs that give the same table: the tool's report.json, and the step's log (`--log`), in which the tool prints
one `ACT-ROW` line for each round. The log is the way to the numbers when a row of the tool fails: the step then ends
with exit 1 and its artifact does not come back.

Use: python3 scripts/measure/pane-act-spans.py REPORT_JSON [zoom|unzoom]
     python3 scripts/measure/pane-act-spans.py --log STEP_LOG [zoom|unzoom]
Exit 0: each round of each group gave its numbers. Exit 1: a round is INVALID, a group is NOT MEASURED, or no row.
"""
import json
import math
import sys

PREFIX = "layout.act."
ARM, SIZES, PASS, PLACE, REPORT = (PREFIX + part for part in ("arm", "sizes", "pass", "place", "report"))
ONCE = (ARM, SIZES, PASS, PLACE)
# The samples of a record that say that the layout moved in a frame: `layout.travel` (the points that the layout's
# springs have left) and `layout.commit` (the panes that a move at a commit moved in this frame).
TRAVEL, COMMIT = "layout.travel", "layout.commit"
# The answer rounds each time to 0.1 ms: 2 rounded times and 1 rounded length can be 0.15 ms off together.
TOLERANCE_MS = 0.25
MIN_VALID = 3
MARK = "ACT-ROW "
KEPT = ("layout", "direction", "round", "spans_full", "act_spans", "travel_frames", "commit_frames")
HEAD = "layout | act | round | arm ms | sizes ms | pass ms | place ms | report in the act's window ms (at least)"


def number(value):
    """Whether `value` is a time the answer can give: a finite number, not below 0, and not a Bool."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def frames(answer, name):
    """How many samples `name` of a `debug.motion` answer are above 0: the frames in which that part moved."""
    samples = answer.get("samples") if isinstance(answer, dict) else None
    return sum(1 for sample in samples if isinstance(sample, dict) and sample.get("name") == name
               and number(sample.get("v")) and sample["v"] > 0) if isinstance(samples, list) else 0


def kept(answer):
    """What the tool keeps of one record's `debug.motion` answer: `spans_full`, the raw `layout.act.` spans (None
    when the answer has no list of spans), and the frames that each kind of sample says moved."""
    spans = answer.get("spans") if isinstance(answer, dict) else None
    own = [span for span in spans if isinstance(span, dict) and isinstance(span.get("name"), str)
           and span["name"].startswith(PREFIX)] if isinstance(spans, list) else None
    return {"spans_full": answer.get("spans_full") if isinstance(answer, dict) else None, "act_spans": own,
            "travel_frames": frames(answer, TRAVEL), "commit_frames": frames(answer, COMMIT)}


def invalid(why, **more):
    return {"valid": False, "why": why, "parts": {}, "report": {"in_act": [], "other": [], "in_act_ms": None}, **more}


def read_act(answer):
    """The parts of the one act in `answer` (the `debug.motion` answer of a record with one act).

    Returns {valid, why (a list of each fault, empty when valid), parts: {name: {ms, at_ms}} for the 4 one-time spans,
    report: {in_act: [span], other: [span], in_act_ms: the sum of `in_act`, None with none}, order: the names of the
    act's spans by their start}. With a fault no number is a result: `parts` is empty.
    """
    if not isinstance(answer, dict) or not isinstance(answer.get("spans"), list):
        return invalid(["the answer has no list `spans`"])
    full = answer.get("spans_full")
    if not isinstance(full, bool):
        return invalid(["the answer has no `spans_full`: an app without the field, NOT MEASURED"])
    if full:
        return invalid(["`spans_full` is true: the list was full and dropped later spans, NOT MEASURED"])
    why, found, reports = [], {name: [] for name in ONCE}, []
    for span in answer["spans"]:
        name = span.get("name") if isinstance(span, dict) else None
        if not isinstance(name, str) or not name.startswith(PREFIX):
            continue
        if not (number(span.get("ms")) and number(span.get("at_ms"))):
            why.append(f"{name}: a span with no time ({span.get('ms')!r} ms at {span.get('at_ms')!r} ms)")
        elif name in found:
            found[name].append(span)
        elif name == REPORT:
            reports.append(span)
        else:
            why.append(f"{name}: a span that this reader does not know")
    for name in ONCE:
        if len(found[name]) != 1:
            why.append(f"{name}: {len(found[name])} spans, not 1")
    if why:
        return invalid(why)
    arm, sizes, passed, place = (found[name][0] for name in ONCE)
    for before, after in ((arm, sizes), (sizes, passed), (passed, place)):
        if before["at_ms"] > after["at_ms"] + TOLERANCE_MS:
            why.append(f"{after['name']} starts at {after['at_ms']} ms, before {before['name']} at {before['at_ms']} ms")
    if abs(passed["at_ms"] + passed["ms"] - place["at_ms"]) > TOLERANCE_MS:
        why.append(f"{PASS} ends at {round(passed['at_ms'] + passed['ms'], 1)} ms and {PLACE} starts at {place['at_ms']} ms")
    if why:
        return invalid(why)
    first, last = arm["at_ms"] - TOLERANCE_MS, place["at_ms"] + place["ms"] + TOLERANCE_MS
    own = [span for span in reports if first <= span["at_ms"] <= last]
    other = [span for span in reports if not first <= span["at_ms"] <= last]
    order = [span["name"] for span in sorted([arm, sizes, passed, place] + own, key=lambda span: span["at_ms"])]
    return {"valid": True, "why": [],
            "parts": {span["name"]: {"ms": span["ms"], "at_ms": span["at_ms"]} for span in (arm, sizes, passed, place)},
            "report": {"in_act": own, "other": other,
                       "in_act_ms": round(sum(span["ms"] for span in own), 1) if own else None},
            "order": order}


def read_row(row):
    """The parts of the act of one round that the tool kept (a row of its report.json, or an `ACT-ROW` line)."""
    if not isinstance(row, dict):
        return invalid(["the row is no object"])
    if row.get("log_fault"):
        return invalid([str(row["log_fault"])])
    moved = row.get("commit_frames")
    if not isinstance(moved, int) or isinstance(moved, bool):
        return invalid(["the row has no count `commit_frames`: it does not say if a pane moved, NOT MEASURED"])
    if moved < 1:
        return invalid([f"no pane moved: 0 `{COMMIT}` samples above 0 in the record"])
    if not isinstance(row.get("act_spans"), list):
        return invalid(["the row has no list `act_spans`: a tool or an app without the spans, NOT MEASURED"])
    return read_act({"spans": row["act_spans"], "spans_full": row.get("spans_full")})


def log_line(row):
    """The line that the tool prints in the step's log for one round: what this reader needs of the row, as JSON."""
    return MARK + json.dumps({key: row.get(key) for key in KEPT}, sort_keys=True, separators=(",", ":"))


def rows_of_log(text):
    """The rounds of a step's log, in the log's order. A line can have text before the mark (a time, a stream's
    name). A marked line that is no JSON object (a line that the log cut) is a row with a fault, never no row."""
    rows = []
    for at, line in enumerate(text.splitlines(), 1):
        start = line.find(MARK)
        if start < 0:
            continue
        try:
            row = json.loads(line[start + len(MARK):])
        except ValueError:
            row = None
        rows.append(row if isinstance(row, dict) else {"log_fault": f"line {at} of the log has the mark and no JSON object"})
    return rows


def median(values):
    values = sorted(values)
    return values[len(values) // 2] if values else None


def report_cell(value):
    """The words for a number of `layout.act.report`: a lower bound, never a plain number."""
    return "none" if value is None else f"at least {value}"


def table(rows, wanted=None):
    """The table of `rows` (each act `wanted`, or each act) as lines, and how many faults it has: each INVALID round
    and each group that is NOT MEASURED."""
    groups = {}
    for row in rows:
        act = row.get("direction") if isinstance(row, dict) else None
        if wanted and act != wanted:
            continue
        groups.setdefault((str(row.get("layout") if isinstance(row, dict) else None), str(act)), []).append(row)
    lines, faults = [HEAD], 0
    for (layout, act), members in sorted(groups.items()):
        results = [(row.get("round") if isinstance(row, dict) else None, read_row(row)) for row in members]
        good = [result for _, result in results if result["valid"]]
        for at, result in results:
            if result["valid"]:
                cells = [str(result["parts"][name]["ms"]) for name in ONCE] + [report_cell(result["report"]["in_act_ms"])]
                lines.append(" | ".join([layout, act, str(at)] + cells))
            else:
                faults += 1
                lines.append(f"{layout} | {act} | {at} | INVALID: " + "; ".join(result["why"]))
        if len(good) < MIN_VALID:
            faults += 1
            lines.append(f"{layout} | {act} | NOT MEASURED: {len(good)} valid rounds of {len(results)}, {MIN_VALID} needed")
        else:
            known = [result["report"]["in_act_ms"] for result in good if result["report"]["in_act_ms"] is not None]
            cells = [str(median([result["parts"][name]["ms"] for result in good])) for name in ONCE]
            lines.append(" | ".join([layout, act, f"median of {len(good)} valid rounds of {len(results)}"] + cells
                                    + [report_cell(median(known))]))
        for at, result in results:
            for span in result["report"]["other"]:
                lines.append(f"{layout} | {act} | {at} | a report outside the act's window, in no number: "
                             f"{report_cell(span['ms'])} ms at {span['at_ms']} ms")
    return lines, faults


def main(arguments):
    log = arguments[:1] == ["--log"]
    rest = arguments[1:] if log else arguments
    if not 1 <= len(rest) <= 2:
        print("use: pane-act-spans.py REPORT_JSON [zoom|unzoom]  or  pane-act-spans.py --log STEP_LOG [zoom|unzoom]")
        return 2
    text = open(rest[0], errors="replace").read()
    if log:
        rows = rows_of_log(text)
    else:
        report = json.loads(text)
        rows = report.get("runs") if isinstance(report, dict) else None
    lines, faults = table(rows if isinstance(rows, list) else [], rest[1] if len(rest) == 2 else None)
    print("\n".join(lines))
    if len(lines) == 1:
        print("NOT MEASURED: no row")
        return 1
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
