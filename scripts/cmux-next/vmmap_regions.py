#!/usr/bin/env python3
"""What a process's phys_footprint is made of: `vmmap --summary PID`, parsed (goal ram-baseline).

bench_memory's samples give one phys_footprint per process. The idle A/Bs of goal ram-baseline then read
"the main renderer is 122-216 MB" or "the app is a steady 233-268 MB" and nothing about which part:
MALLOC zones, IOSurface, CoreAnimation, JIT, mapped files, V8's heap (Memory Tag 255 and friends). Each
cut that follows needs that, and each A/B is hours in the measure queue, so the bench records it in the
same run: `breakdown(pid)` runs vmmap (bounded, after the sample's window) and keeps, per region type,
its dirty and swapped MB (the part a footprint counts), and per malloc zone its dirty+swap, allocated
and fragmented MB.

`targets(rows)` picks the processes worth it from a sample's rows (largest first): the app, the two
largest CEF renderers, every acpmux daemon (the Chief's second one), `cmux mcp serve` and the Chief's
brain (optchat-chief). Pure Python, no macOS call except the one vmmap subprocess, so the parser's test
runs anywhere (scripts/cmux-next/tests/test_vmmap_regions.py).
"""

from __future__ import annotations

import re
import shutil
import subprocess

MB = 1024 * 1024
UNITS = {"": 1, "B": 1, "K": 1024, "M": MB, "G": 1024 * MB, "T": 1024 * 1024 * MB}
SIZE = re.compile(r"^(\d+(?:\.\d+)?)([BKMGT]?)$")
NUMBER = re.compile(r"^\d+(?:\.\d+)?[BKMGT]?%?$")
# A region kept in the record: at least this much dirty+swapped (the rest is noise in a 200 MB process).
KEEP_MB = 0.1
# The bound on one vmmap: a wedged one must not stall the bench (it suspends its target while it reads).
TIMEOUT_S = 20
# The most processes one sample breaks down: each vmmap suspends its process about a second.
MAX_TARGETS = 8


def size_mb(token: str) -> float | None:
    """`236.9M`, `40K`, `1.2G`, `0K` -> MB; None when the token is no size."""
    m = SIZE.match(token.strip())
    if not m:
        return None
    return float(m.group(1)) * UNITS[m.group(2)] / MB


def split_row(line: str, columns: int) -> tuple[str, list[str]] | None:
    """A table row -> (name, its `columns` numeric columns). The name may hold spaces, parentheses and a
    number of its own (`Memory Tag 255`, `MALLOC_SMALL (empty)`), and a row may end in a note (`see MALLOC
    ZONE table below`), so the columns are the first run of exactly `columns` numbers that the line's end
    or a word (not a number) follows; the count comes from the table's `=====` line."""
    tokens = line.split()
    for i in range(1, len(tokens) - columns + 1):
        cols, rest = tokens[i:i + columns], tokens[i + columns:]
        if all(NUMBER.match(t) for t in cols) and (not rest or not NUMBER.match(rest[0])):
            return " ".join(tokens[:i]), cols
    return None


def parse_summary(text: str) -> dict:
    """`vmmap --summary` output -> {physical_footprint_mb, physical_footprint_peak_mb, regions, malloc_zones}.

    regions[name] = {virtual_mb, resident_mb, dirty_mb, swapped_mb, dirty_swapped_mb} for each region type
    with at least KEEP_MB dirty+swapped; malloc_zones[name] = {dirty_swapped_mb, allocated_mb, frag_mb,
    frag_pct}. The first four columns of the region table are VIRTUAL, RESIDENT, DIRTY and SWAPPED in every
    vmmap the fleet runs (the newer ones add VOLATILE, NONVOL, EMPTY before the count)."""
    out: dict = {"physical_footprint_mb": None, "physical_footprint_peak_mb": None, "regions": {}, "malloc_zones": {}}
    section = None
    columns = 0  # numeric columns of the current table: its `=====` line's groups, less the name's
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if stripped.startswith("Physical footprint (peak):"):
            out["physical_footprint_peak_mb"] = _round(size_mb(stripped.split(":", 1)[1]))
            continue
        if stripped.startswith("Physical footprint:"):
            out["physical_footprint_mb"] = _round(size_mb(stripped.split(":", 1)[1]))
            continue
        if stripped.startswith("REGION TYPE"):
            section, columns = "regions", 0
            continue
        if stripped.startswith("MALLOC ZONE"):
            section, columns = "zones", 0
            continue
        if stripped.startswith("=") and section in ("regions", "zones"):
            columns = columns or len(stripped.split()) - 1
            continue
        if not stripped or stripped.startswith("=") or section is None or columns <= 0:
            continue
        if stripped.startswith("TOTAL"):
            if section == "regions":
                section = "after-regions"  # TOTAL and TOTAL, minus reserved: the end of the region table
            elif section == "zones":
                section = None
            continue
        row = split_row(stripped, columns)
        if row is None:
            continue
        name, nums = row
        if section == "regions" and len(nums) >= 5:
            sizes = [size_mb(n) for n in nums[:4]]
            if None in sizes:
                continue
            virtual, resident, dirty, swapped = sizes
            if dirty + swapped < KEEP_MB:
                continue
            region = out["regions"].setdefault(name, {"virtual_mb": 0.0, "resident_mb": 0.0, "dirty_mb": 0.0,
                                                      "swapped_mb": 0.0, "dirty_swapped_mb": 0.0})
            for key, value in (("virtual_mb", virtual), ("resident_mb", resident), ("dirty_mb", dirty),
                               ("swapped_mb", swapped), ("dirty_swapped_mb", dirty + swapped)):
                region[key] = _round(region[key] + value)
        elif section == "zones" and len(nums) >= 8:
            # VIRTUAL RESIDENT DIRTY SWAPPED ALLOCATION-COUNT BYTES-ALLOCATED DIRTY+SWAP-FRAG %FRAG COUNT
            dirty, swapped, allocated, frag = (size_mb(nums[i]) for i in (2, 3, 5, 6))
            if None in (dirty, swapped, allocated, frag):
                continue
            pct = nums[7].rstrip("%")
            out["malloc_zones"][name] = {"dirty_swapped_mb": _round(dirty + swapped), "allocated_mb": _round(allocated),
                                         "frag_mb": _round(frag), "frag_pct": float(pct) if SIZE.match(pct) else None}
    out["regions"] = dict(sorted(out["regions"].items(), key=lambda item: -item[1]["dirty_swapped_mb"]))
    return out


def _round(value: float | None) -> float | None:
    return None if value is None else round(value, 1)


def label_of(row: dict) -> str | None:
    """Why a sample row is broken down, or None: its kind, or the command it was picked by."""
    command = row.get("command") or ""
    if "optchat-chief" in command:
        return "optchat-chief"
    if re.search(r"(^|[\s/])cmux mcp serve\b|\bmcp serve\b", command):
        return "mcp-serve"
    if row.get("kind") in ("app", "acpmux-daemon"):
        return row["kind"]
    return None


def targets(rows: list[dict], renderers: int = 2) -> list[tuple[dict, str]]:
    """The rows to break down, as (row, why): the app, the `renderers` largest cef-renderers, every acpmux
    daemon, `cmux mcp serve` and optchat-chief; at most MAX_TARGETS, largest footprint first."""
    picked: list[tuple[dict, str]] = []
    shown = 0
    for row in sorted(rows, key=lambda r: -(r.get("footprint_mb") or 0)):
        why = label_of(row)
        if why is None and row.get("kind") == "cef-renderer" and shown < renderers:
            why = f"cef-renderer-{shown + 1}"
        if why is None:
            continue
        if row.get("kind") == "cef-renderer":
            shown += 1
        picked.append((row, why))
    return picked[:MAX_TARGETS]


def breakdown(pid: int, timeout: float = TIMEOUT_S, run=subprocess.run) -> dict:
    """`vmmap --summary pid`, parsed; {"error": ...} when vmmap is missing, times out or fails."""
    if run is subprocess.run and not shutil.which("vmmap"):
        return {"error": "no vmmap"}
    try:
        got = run(["vmmap", "--summary", str(pid)], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": f"vmmap timed out after {timeout:g} s"}
    except OSError as e:
        return {"error": str(e)[:200]}
    parsed = parse_summary(got.stdout or "")
    if not parsed["regions"]:
        return {"error": f"vmmap rc={got.returncode}: {(got.stderr or '').strip()[:200] or 'no region table'}"}
    return parsed
