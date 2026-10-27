#!/usr/bin/env python3
"""The one parser of `footprint -j` JSON, shared by memory-report.py and cold_scrollback.py (bench_memory.py).

A process object is any JSON object with a numeric `pid`; its categories are the first member that is either a map
of category name to counts or a list of named counts, each with a `dirty` count. A `TOTAL` row is dropped.
phys_footprint is resident dirty plus compressed bytes; footprint may list compressed (swapped) bytes apart from
`dirty` or inside it, so the reading whose sum matches the process's footprint is taken (without a footprint,
apart). Key names come from fixtures until a real capture from a fleet Mac is checked in; a capture with no category
rows parses to `rows == 0`, which callers treat as no measurement.
"""
from __future__ import annotations

NAME_KEYS = ("category", "name", "tag", "type")


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def processes(document) -> list[dict]:
    """Every process object in `document`, in document order (a bare process object is itself one)."""
    found: list[dict] = []

    def walk(node):
        if isinstance(node, dict):
            if _number(node.get("pid")):
                found.append(node)
                return
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(document)
    return found


def _counts(entry: dict) -> dict:
    return {str(k).lower(): v for k, v in entry.items() if _number(v)}


def category_rows(proc: dict) -> list[tuple[str | None, dict]]:
    """[(category name or None, lower-cased numeric counts)] of the rows with a `dirty` count, TOTAL dropped."""
    for value in proc.values():
        if isinstance(value, dict) and value and all(isinstance(v, dict) for v in value.values()):
            named = [(str(name), entry) for name, entry in value.items()]
        elif isinstance(value, list) and value and all(isinstance(v, dict) for v in value):
            named = [(next((entry[k] for k in NAME_KEYS if isinstance(entry.get(k), str)), None), entry)
                     for entry in value]
        else:
            continue
        rows = [(name, _counts(entry)) for name, entry in named if str(name).upper() != "TOTAL"]
        rows = [(name, counts) for name, counts in rows if "dirty" in counts]
        if rows:
            return rows
    return []


def _compressed(counts: dict) -> float:
    return sum(v for k, v in counts.items() if "swap" in k or "compress" in k)


def process_footprint(proc: dict) -> int | None:
    """The process's footprint (the shortest `*footprint*` key that is not a peak), or None."""
    totals = sorted((k for k, v in proc.items() if "footprint" in str(k).lower() and "peak" not in str(k).lower()
                     and _number(v)), key=len)
    return int(proc[totals[0]]) if totals else None


def columns(proc: dict) -> dict:
    """{"dirty" (resident), "compressed", "footprint", "rows", "categories": {name: resident dirty + compressed}}."""
    rows = category_rows(proc)
    dirty = sum(counts["dirty"] for _, counts in rows)
    compressed = sum(_compressed(counts) for _, counts in rows)
    footprint = process_footprint(proc)
    inside = bool(footprint is not None and compressed
                  and abs(dirty - footprint) < abs(dirty + compressed - footprint))
    categories: dict[str, int] = {}
    for name, counts in rows:
        if name is None:
            continue
        held = counts["dirty"] if inside else counts["dirty"] + _compressed(counts)
        categories[name] = categories.get(name, 0) + int(held)
    resident = dirty - compressed if inside else dirty
    return {"dirty": int(max(0, resident)), "compressed": int(compressed),
            "footprint": footprint if footprint is not None else int(max(0, resident) + compressed),
            "rows": len(rows), "categories": categories}


def parse(document) -> dict[int, dict]:
    """{pid: columns(...)} of every process in `document`."""
    return {int(proc["pid"]): columns(proc) for proc in processes(document)}
