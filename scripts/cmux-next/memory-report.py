#!/usr/bin/env python3
"""Where the cmux app's physical footprint goes (p07-memory task 014, DC15, MQ-UNATTRIBUTED).

Reads the app process with `footprint -j` (VM categories that sum to phys_footprint) and
`vmmap -summary` (the malloc zone table, and the categories when footprint fails), groups the
categories (PartitionAlloc, DefaultMallocZone, other malloc zones, IOSurface, IOAccelerator, CG image,
stacks, __DATA, framework pages, ...), and joins them with the app's memory consumers from
`debug.memory` (task 010). A consumer explains bytes only of the allocator its storage lives in, as a
Chrome memory-infra sub-dump claims bytes only inside the allocator dump it is a suballocation of
(ProcessMemoryDump::AddSuballocation, base/trace_event/process_memory_dump.h): heap storage in the
process's malloc (PartitionAlloc while CEF is in-process, CmuxNextMallocZone/early_zone.c, else the
default zone), image storage in CG image, IOSurface storage in IOSurface, GPU storage in IOAccelerator
(both also in owned unmapped memory). What a consumer reports beyond its allocator's bytes is listed,
never spilled into another group. A consumer that does not say where its storage lives (debug.memory's
`traits.storage`: heap, image, iosurface or gpu) explains nothing. Stacks, __DATA, framework pages and
page tables have a fixed owner (threads, binaries, the kernel). The rest of a group is unexplained, as
Chrome shows what malloc holds beyond its providers as `<unspecified>` (docs/memory-infra/README.md);
Chromium's VM tags name the PartitionAlloc, V8 and Blink GC regions
(partition_alloc/page_allocator_constants.h, PageTag); vmmap is the Darwin reference
(docs/memory/key_concepts.md).

Prints, per phase:
  * one table: group, MB, share of the app footprint, explained MB, owner;
  * `MEMORY-REPORT phase=... footprint_mb=... unattributed_mb=... unattributed_pct=...`;
  * `MQ-UNATTRIBUTED phase=... group=... unexplained_mb=...` for each group with more than 5 MB no
    consumer or fixed owner explains (each line is one task, p07-memory.md section 6);
and once, `MQ-CACHE rank=... bytes=... source=... file=...`: the files of `memory-queues.sh caches`,
largest first. A file's bytes are its registered consumers' footprint bytes (source debug.memory),
else, with --heap, the heap bytes of objects whose type, or element type, the file declares (source
heap: object and collection storage only, a lower bound that misses image, IOSurface and Data
payloads), else unknown. Heap bytes are unknown when the walk did not enumerate the process's malloc
(PartitionAlloc's zone has no introspection enumerator: allocator_shim_override_apple_default_zone.h).
Unknown sorts last. The JSON file (--out) has all of it plus the raw tool outputs and app.log next to
it, written even when a phase fails; --*-file re-reads the run offline.

A build without debug.memory (or an attach without --socket) still gets the table: every group
without a fixed owner is then unexplained.

The atlas phase (p07-memory task 039) asks whether the terminals share one glyph atlas texture. In a new
workspace on the STRESS window it samples the GPU groups (IOAccelerator, IOSurface, owned unmapped memory)
at 1..N visible terminals tiling the window in two columns, has every terminal show a sheet of CJK
glyphs sized for the window's backing scale (about 6,200 at 1x, the STRESS virtual display's scale: the
grayscale atlas grows from 512 x 512 past 1024 x 1024 to 2048 x 2048 R8), and samples again while the
panes close back to one. It prints `ATLAS ... atlas_bytes_per_extra_terminal=...
verdict=shared|per_surface|unmeasured`: the change in GPU bytes per extra terminal that the atlas growth
caused. Shared is 0; per surface is about the growth one terminal saw (each surface keeping its own
texture copies); unmeasured prints it as unknown. The atlas phase leaves the shared CPU atlas grown, so
it does not run in the same launch as the stress phase.

Usage:
  memory-report.py --app BUNDLE [--phases home,stress | home,atlas] [--settle 30] [--heap] [--vdisplay HZ]
      [--atlas-terminals 4] [--atlas-settle 5] [--out FILE.json]
      Launch a tagged DEV app (the STRESS launcher of perf-stress-session.py), measure Home idle,
      then build STRESS in it and measure again, or (atlas, its own launch: the grown atlas would
      inflate STRESS) the GPU bytes per extra visible terminal.
      STRESS and the atlas window need a 1920 x 1200 virtual main display (perf-stress-session.py
      start_vdisplay): with either phase it starts one at 120 Hz before the launch unless --vdisplay 0.
      Fleet only (scripts/measure/memory-report.sh).
  memory-report.py --pid PID [--socket PATH] [--heap] [--out FILE.json]
      A running app. `--heap` walks its heap (it stalls the process for seconds: never on a person's
      cmux).
  memory-report.py --footprint-file F.json [--vmmap-file V.txt] [--heap-file H.txt]
      [--debug-memory-file D.json] [--phys-footprint-bytes N] [--out FILE.json]
      Re-read saved outputs (any platform).

Exit 0 when every phase measured; 1 when a phase had no category source, the app did not launch,
STRESS did not build or the atlas phase failed or saw no atlas growth; 2 on bad arguments. Read-only
and local: never wire it into CI or a hook (CLAUDE.md).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)  # python -I leaves the script folder out
import footprint_json  # noqa: E402
MB = 1048576.0
UNATTRIBUTED_LINE_BYTES = 5 * 1048576  # MQ-UNATTRIBUTED: a group with more unexplained bytes is a task
VDISPLAY_HZ = 120.0  # the STRESS display of perf-stress-session.py (split-spring.sh --vdisplay=120)

# Chromium's VM tags (partition_alloc/page_allocator_constants.h, PageTag): vmmap and footprint name
# them "Memory Tag N".
CHROMIUM_PAGE_TAGS = {251: "Chromium (other)", 252: "Blink GC", 253: "PartitionAlloc", 254: "Chromium (other)",
                      255: "V8"}
# Also the names a newer vmmap gives those tags.
CHROMIUM_TAG_NAMES = {"partitionalloc": "PartitionAlloc", "blink gc": "Blink GC", "v8": "V8"}

# Groups explained by a fixed owner, not by consumers.
FIXED_OWNERS = {
    "stacks": "threads",
    "__DATA": "binaries (dyld images)",
    "framework pages": "binaries (dyld images)",
    "page tables": "kernel (page tables)",
    "performance tool data": "the measuring tools",
}

# The groups each consumer storage lives in (heap: the process's malloc group, malloc_group()).
STORAGE_GROUPS = {
    "image": ["CG image"],
    "iosurface": ["IOSurface", "owned unmapped memory"],
    "gpu": ["IOAccelerator", "owned unmapped memory"],
}
STORAGES = ("heap", *STORAGE_GROUPS)
# The terminal row of debug.memory reports the hidden non-volatile IOSurfaces, not the visible ones.
TERMINAL_IOSURFACE_KEY = "hidden_nonvolatile_iosurface_bytes"

# The atlas phase (task 039). GPU memory is in these groups (Metal textures and buffers, drawables).
GPU_GROUPS = ("IOAccelerator", "IOSurface", "owned unmapped memory")
ATLAS_TERMINALS = 4  # visible terminals the phase tiles the window into, one at a time
ATLAS_SETTLE = 5.0  # seconds after each change before a GPU sample
# The glyph sheet: CJK ideographs from U+4E00 (fallback font, grayscale atlas), each two cells wide. At 1x
# and the default font a glyph takes about 16 x 17 px with its padding (ATLAS_GLYPH_PIXELS_1X), 4x that at
# 2x. The sheet holds ATLAS_SHEET_PIXELS of glyphs at the window's backing scale: past a 1024 x 1024 atlas
# (1 M px) and well inside 2048 x 2048 (4 M px), so the atlas doubles twice, 512 -> 1024 -> 2048 R8
# (SharedGrid grows by doubling), whatever the scale.
ATLAS_GLYPH_PIXELS_1X = 340
ATLAS_SHEET_PIXELS = 2 * 1048576
ATLAS_FIRST_CODEPOINT = 0x4E00
ATLAS_LAST_CODEPOINT = 0x9FFF  # CJK Unified Ideographs: 20,992 glyphs at most
ATLAS_LINE_GLYPHS = 20  # 40 columns
ATLAS_PAGE_LINES = 10  # a page fits a quarter of the 1600 x 1000 pt STRESS window at the default font
ATLAS_PAGE_SECONDS = 0.3  # each page stays on screen this long, several frames
ATLAS_START_BYTES = 512 * 512  # the grayscale atlas at launch (SharedGrid.zig:92), R8
ATLAS_EXPECTED_BYTES = 2048 * 2048  # one shared atlas after the sheet (the expectation in p07-memory.md task 039)
# The smallest real growth one terminal can see is one shared texture doubling once: 1024 x 1024 - 512 x 512
# R8 = 768 KiB. Less than two thirds of that on one terminal: the atlas did not grow.
ATLAS_MIN_GROWTH_BYTES = (1024 * 1024 - ATLAS_START_BYTES) * 2 // 3
ATLAS_PER_SURFACE_SHARE = 0.5  # an extra terminal paying this share of the growth or more: per surface

SIZE = re.compile(r"^(\d+(?:\.\d+)?)([KMGT]?)B?$", re.I)
UNITS = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}


def size_bytes(token: str) -> int | None:
    """`16K`, `1.5M`, `2G`, `123` (vmmap) in bytes; None when `token` is no size."""
    match = SIZE.match(token.strip())
    if not match:
        return None
    return int(float(match.group(1)) * UNITS[match.group(2).upper()])


def group_of(category: str) -> str:
    """The report group of a footprint or vmmap category (region type)."""
    name = category.strip()
    lower = name.lower()
    tag = re.search(r"\btag\s*(\d+)\b", lower)
    if tag:
        return CHROMIUM_PAGE_TAGS.get(int(tag.group(1)), name)
    for prefix, group in CHROMIUM_TAG_NAMES.items():
        if lower == prefix or lower.startswith(prefix + " "):
            return group
    if lower.startswith("malloc"):
        return "malloc"
    if lower.startswith("iosurface"):
        return "IOSurface"
    if lower.startswith("ioaccelerator"):
        return "IOAccelerator"
    if lower.startswith("owned"):
        return "owned unmapped memory"
    if lower.startswith(("cg image", "cg raster", "cg backing", "image io", "coreui image", "coreimage")):
        return "CG image"
    if lower.startswith(("coreanimation", "ca layer")):
        return "CoreAnimation"
    if lower.startswith("stack"):
        return "stacks"
    if lower.startswith(("__data", "__auth", "__objc_rw", "__bss", "__common")) or "shlib __data" in lower:
        return "__DATA"
    if lower.startswith(("__text", "__linkedit", "__objc_ro", "__ctf", "__font_data", "__info_filter",
                         "dyld private memory", "kernel alloc once")):
        return "framework pages"
    if lower.startswith("page table"):
        return "page tables"
    if lower.startswith(("js ", "javascriptcore", "webassembly")):
        return "JavaScriptCore"
    if lower.startswith("webkit malloc"):
        return "WebKit Malloc"
    if "vm_allocate" in lower:
        return "VM_ALLOCATE (untagged)"
    if lower.startswith("performance tool data"):
        return "performance tool data"
    return name


# Parsers. Each takes a tool's output and returns plain data; none runs a tool.


def footprint_categories(document) -> tuple[dict[str, int], int | None]:
    """({category: dirty + compressed bytes}, process footprint or None) from `footprint -j` JSON: the
    first process object (footprint_json.py, the parser bench_memory.py's cold-scrollback run shares).
    phys_footprint is resident dirty plus compressed, so a category's swapped or compressed count, when
    footprint reports it apart from `dirty`, is added as vmmap_tables adds SWAPPED."""
    found = footprint_json.processes(document)
    proc = found[0] if found else (document if isinstance(document, dict) else {})
    return footprint_json.columns(proc)["categories"], footprint_json.process_footprint(proc)


FOOTPRINT_ROW = re.compile(r"^\s*([\d.]+)\s*([KMGT]?B)\s+([\d.]+)\s*([KMGT]?B)\s+([\d.]+)\s*([KMGT]?B)\s+(\d+)\s+(.+?)\s*$")


def footprint_text_categories(text: str) -> tuple[dict[str, int], int | None]:
    """The same from footprint's text table (Dirty, Clean, Reclaimable, Regions, Category)."""
    categories: dict[str, int] = {}
    total = None
    for line in text.splitlines():
        found = re.search(r"Footprint:\s*([\d.]+)\s*([KMGT]?B)", line)
        if found and total is None:
            total = size_bytes(found.group(1) + found.group(2)[:-1])
        row = FOOTPRINT_ROW.match(line)
        if row and row.group(8) != "TOTAL":
            categories[row.group(8)] = categories.get(row.group(8), 0) + (size_bytes(row.group(1) + row.group(2)[:-1]) or 0)
    return categories, total


def _trailing_values(line: str, count: int | None) -> tuple[str, list[int]] | None:
    """(name, values) of a vmmap row: `count` trailing sizes (or every trailing size), after any
    trailing words such as `see MALLOC ZONE table below`."""
    tokens = line.split()
    while tokens and size_bytes(tokens[-1].rstrip("%")) is None:
        tokens.pop()
    values: list[int] = []
    while tokens and (count is None or len(values) < count):
        value = size_bytes(tokens[-1].rstrip("%"))
        if value is None:
            break
        values.insert(0, value)
        tokens.pop()
    if not tokens or (count is not None and len(values) < count):
        return None
    return " ".join(tokens), values


def vmmap_tables(text: str) -> tuple[dict[str, int], dict[str, int]]:
    """({region type: dirty + swapped bytes}, {malloc zone: dirty + swapped bytes}) from
    `vmmap -summary`. Columns are found by their header; a zone's name loses its `_0x...` suffix."""
    regions: dict[str, int] = {}
    zones: dict[str, int] = {}
    lines = text.splitlines()
    for index, line in enumerate(lines):
        label = line.strip()
        if not (label.startswith("REGION TYPE") or label.startswith("MALLOC ZONE")) or index == 0:
            continue
        heads = lines[index - 1].split()
        if "DIRTY" not in heads:
            continue
        dirty, swapped = heads.index("DIRTY"), heads.index("SWAPPED") if "SWAPPED" in heads else None
        table = regions if label.startswith("REGION TYPE") else zones
        # The zone table has more value columns than header words (FRAG SIZE, % FRAG): take every
        # trailing value there; zone names end in `_0x...`, never in a number.
        count = len(heads) if table is regions else None
        for row in lines[index + 1:]:
            stripped = row.strip()
            if not stripped:
                break
            if stripped.startswith("=") or stripped.startswith("TOTAL"):
                if stripped.startswith("TOTAL"):
                    break
                continue
            parsed = _trailing_values(row, count)
            if not parsed or len(parsed[1]) <= dirty:
                continue
            name, values = parsed
            if table is zones:
                name = re.sub(r"_0x[0-9a-fA-F]+$", "", name)
            value = values[dirty] + (values[swapped] if swapped is not None and swapped < len(values) else 0)
            table[name] = table.get(name, 0) + value
    return regions, zones


def vmmap_footprint(text: str) -> int | None:
    """The `Physical footprint:` line of vmmap's header."""
    found = re.search(r"^Physical footprint:\s*(\S+)", text, re.M)
    return size_bytes(found.group(1)) if found else None


HEAP_ROW = re.compile(r"^\s*(\d+)\s+(\d+(?:\.\d+)?[KMG]?)\s+[\d.]+[KMG]?\s+(.+?)(?:\s{2,}\S.*)?$")
HEAP_SECTION = re.compile(r"^(All zones|Zone\s+\S+?)\s*:\s*(\d+)\s+nodes")


def heap_classes(text: str) -> dict[str, int]:
    """{class name: bytes} from `heap`: the "All zones" table when it prints one, else every zone's."""
    sections: list[tuple[bool, dict[str, int]]] = []
    current: dict[str, int] | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if HEAP_SECTION.match(stripped):
            current = {}
            sections.append((stripped.lower().startswith("all zones"), current))
            continue
        if current is None:
            if stripped.startswith("COUNT") and "BYTES" in stripped:
                current = {}
                sections.append((False, current))
            continue
        row = HEAP_ROW.match(line)
        if row:
            name = row.group(3).strip()
            current[name] = current.get(name, 0) + (size_bytes(row.group(2)) or 0)
    chosen = [table for every, table in sections if every] or [table for _, table in sections]
    out: dict[str, int] = {}
    for table in chosen:
        for name, value in table.items():
            out[name] = out.get(name, 0) + value
    return out


def heap_zone_nodes(text: str) -> dict[str, int]:
    """{malloc zone: nodes the walk enumerated} from `heap`'s `Zone NAME_0x...: N nodes` lines."""
    zones: dict[str, int] = {}
    for line in text.splitlines():
        found = HEAP_SECTION.match(line.strip())
        if found and found.group(1).startswith("Zone"):
            name = re.sub(r"_0x[0-9a-fA-F]+$", "", found.group(1).split(None, 1)[1])
            zones[name] = zones.get(name, 0) + int(found.group(2))
    return zones


def heap_walk(text: str, zones: dict[str, int]) -> dict:
    """{classes, enumerated, why}: the walk's classes, and whether it saw the process's malloc. With
    PartitionAlloc as the malloc (a PartitionAlloc zone in vmmap's table) the app's objects are there,
    and that zone has no introspection enumerator (Chromium's allocator_shim_override_apple_default_zone.h
    returns KERN_FAILURE): no nodes there is unknown, not 0."""
    classes = heap_classes(text)
    if malloc_group(zones) == "PartitionAlloc" and not any(
            v for k, v in heap_zone_nodes(text).items() if "PartitionAlloc" in k):
        return {"classes": classes, "enumerated": False,
                "why": "PartitionAlloc is the malloc and the heap walk enumerated none of its zone"}
    return {"classes": classes, "enumerated": bool(classes), "why": None if classes else "no heap classes"}


# The join.


def malloc_group(zones: dict[str, int]) -> str:
    """The group a heap consumer's bytes are in: PartitionAlloc while it is the malloc (CEF in-process,
    CmuxNextMallocZone/early_zone.c registers its zone), else the default zone."""
    if any("PartitionAlloc" in zone for zone in zones):
        return "PartitionAlloc"
    return "DefaultMallocZone" if zones else "malloc (zones unknown)"


def byte_count(value) -> int | None:
    """A debug.memory byte count: an integer, or None for null (unknown, never 0)."""
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def debug_memory_consumers(debug_memory: dict | None) -> list[dict]:
    """[{name, bytes (None when unknown), storage (None when not reported)}] of debug.memory's
    consumers (task 010's keys: name, traits, footprint_bytes)."""
    if not isinstance(debug_memory, dict):
        return []
    rows = []
    for entry in debug_memory.get("consumers") or []:
        if not isinstance(entry, dict):
            continue
        traits = entry.get("traits") if isinstance(entry.get("traits"), dict) else {}
        storage = traits.get("storage")
        rows.append({"name": str(entry.get("name") or "consumer"), "bytes": byte_count(entry.get("footprint_bytes")),
                     "storage": storage if storage in STORAGES else None})
    return rows


def consumers_of(debug_memory: dict | None) -> list[dict]:
    """The consumers with known bytes, plus the terminal's hidden non-volatile IOSurfaces."""
    rows = [row for row in debug_memory_consumers(debug_memory) if row["bytes"] is not None]
    terminal = debug_memory.get("terminal") if isinstance(debug_memory, dict) else None
    surfaces = byte_count(terminal.get(TERMINAL_IOSURFACE_KEY)) if isinstance(terminal, dict) else None
    if surfaces:
        rows.append({"name": "terminal hidden non-volatile IOSurfaces", "bytes": surfaces, "storage": "iosurface"})
    return rows


def groups_from(categories: dict[str, int], zones: dict[str, int]) -> tuple[dict[str, int], dict[str, list[str]]]:
    """({group: bytes}, {group: its categories}); malloc categories split by the zone table."""
    groups: dict[str, int] = {}
    members: dict[str, list[str]] = {}
    for category, value in categories.items():
        group = group_of(category)
        groups[group] = groups.get(group, 0) + value
        members.setdefault(group, []).append(category)
    malloc = groups.pop("malloc", 0)
    malloc_members = members.pop("malloc", [])
    # PartitionAlloc maps its pages under its own VM tag (its own group already), and cmux's
    # delegating default zone forwards to the system zone listed beside it: only the other zones
    # share the MALLOC_* regions.
    split = {zone: value for zone, value in zones.items() if "PartitionAlloc" not in zone and value > 0}
    if malloc:
        zone_total = sum(split.values())
        if zone_total <= 0:
            groups["malloc (zones unknown)"] = malloc
            members["malloc (zones unknown)"] = malloc_members
        else:
            left = malloc
            parts = sorted(split.items(), key=lambda item: -item[1])
            for index, (zone, value) in enumerate(parts):
                group = "DefaultMallocZone" if zone.startswith(("DefaultMallocZone", "MallocHelperZone", "DefaultPurgeableMallocZone")) \
                    else "malloc zones (other)"
                share = left if index == len(parts) - 1 else round(malloc * value / zone_total)
                left -= share
                groups[group] = groups.get(group, 0) + share
                members.setdefault(group, [])
                for item in malloc_members + [f"zone {zone}"]:
                    if item not in members[group]:
                        members[group].append(item)
    return groups, members


def attribute(groups: dict[str, int], consumers: list[dict], heap_group: str) -> tuple[dict[str, list[dict]], list[dict]]:
    """({group: [{name, bytes}]}, [consumer bytes beyond its allocator's groups]): each consumer with a
    storage, largest first, claims bytes only in its storage's groups."""
    left = dict(groups)
    owners: dict[str, list[dict]] = {}
    beyond = []
    for consumer in sorted((c for c in consumers if c["storage"]), key=lambda c: -c["bytes"]):
        need = consumer["bytes"]
        for group in [heap_group] if consumer["storage"] == "heap" else STORAGE_GROUPS[consumer["storage"]]:
            take = min(need, left.get(group, 0))
            if take > 0:
                left[group] -= take
                need -= take
                owners.setdefault(group, []).append({"name": consumer["name"], "bytes": take})
            if need == 0:
                break
        if need > 0:
            beyond.append({"name": consumer["name"], "bytes": need})
    return owners, beyond


def analyze(label: str, categories: dict[str, int], zones: dict[str, int], phys: int | None,
            debug_memory: dict | None, debug_error: str | None = None) -> dict:
    """The phase's report: groups with explained bytes, unattributed bytes and MQ-UNATTRIBUTED rows."""
    groups, members = groups_from(categories, zones)
    consumers = consumers_of(debug_memory)
    owners, beyond = attribute(groups, consumers, malloc_group(zones))
    total = sum(groups.values())
    notes = []
    if phys and total > phys * 1.01:
        notes.append(f"the categories sum to {mb(total)} MB, more than the {mb(phys)} MB footprint: "
                     "the category source counts bytes twice")
    phys = phys if phys else total
    outside = max(0, phys - total)
    rows = []
    for group, value in sorted(groups.items(), key=lambda item: -item[1]):
        fixed = FIXED_OWNERS.get(group)
        explained = value if fixed else sum(o["bytes"] for o in owners.get(group, []))
        rows.append({"group": group, "bytes": value, "explained_bytes": explained,
                     "unexplained_bytes": value - explained, "owner": fixed,
                     "consumers": owners.get(group, []), "categories": sorted(members.get(group, []))})
    if outside:
        rows.append({"group": "outside footprint categories", "bytes": outside, "explained_bytes": 0,
                     "unexplained_bytes": outside, "owner": None, "consumers": [], "categories": []})
    unattributed = sum(r["unexplained_bytes"] for r in rows)
    queue = [{"group": r["group"], "unexplained_bytes": r["unexplained_bytes"], "bytes": r["bytes"],
              "owned_by": [c["name"] for c in r["consumers"]]}
             for r in rows if r["unexplained_bytes"] > UNATTRIBUTED_LINE_BYTES]
    available = isinstance(debug_memory, dict)
    return {"label": label, "phys_footprint_bytes": phys, "categories_bytes": total, "groups": rows,
            "unattributed_bytes": unattributed,
            "unattributed_pct": round(100 * unattributed / phys, 1) if phys else None,
            "mq_unattributed": queue, "consumers": consumers, "consumer_bytes_beyond_regions": beyond,
            "consumers_without_storage": [c["name"] for c in consumers if not c["storage"]], "notes": notes,
            "debug_memory": {"available": available, "error": None if available else debug_error or "not asked",
                             "consumers": len(consumers)}}


def mq_cache_order(files: list[str], debug_memory: dict | None, heap: dict | None, root: str = ROOT) -> list[dict]:
    """MQ-CACHE files, largest first. A file's bytes: the footprint bytes of the debug.memory
    consumers whose name it spells as a string literal (unknown when one of them reports null); else
    the heap bytes of objects whose type, or a generic argument, is a type the file declares in its
    module (`Sources/<Module>/`), when the walk enumerated the process's malloc; else unknown."""
    by_name: dict[str, list[int | None]] = {}
    for consumer in debug_memory_consumers(debug_memory):
        by_name.setdefault(consumer["name"], []).append(consumer["bytes"])
    classes = heap["classes"] if heap and heap["enumerated"] else None
    rows = []
    for path in files:
        module_match = re.search(r"Sources/([^/]+)/", path)
        module = module_match.group(1) if module_match else None
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            text = ""
        declared = set(re.findall(r"\b(?:class|struct|actor|enum)\s+(\w+)", text))
        names = sorted(name for name in by_name if f'"{name}"' in text)
        value, source = None, None
        if names:
            counts = [v for name in names for v in by_name[name]]
            value, source = (None if None in counts else sum(counts)), "debug.memory"
        elif classes is not None and module and declared:
            pattern = re.compile(r"\b" + re.escape(module) + r"\.(?:\w+\.)*(" + "|".join(map(re.escape, sorted(declared))) + r")\b")
            value, source = sum(v for name, v in classes.items() if pattern.search(name)), "heap"
        rows.append({"file": path, "module": module, "bytes": value, "source": source, "consumers": names,
                     "types": len(declared)})
    rows.sort(key=lambda r: (r["bytes"] is None, -(r["bytes"] or 0), r["file"]))
    for rank, row in enumerate(rows, 1):
        row["rank"] = rank
    return rows


def queue_files(root: str = ROOT) -> tuple[list[str], str | None]:
    """The MQ-CACHE files (memory-queues.sh caches), or ([], why not)."""
    script = os.path.join(root, "scripts", "cmux-next", "memory-queues.sh")
    try:
        out = subprocess.run(["bash", script, "caches"], capture_output=True, text=True, timeout=300, cwd=root)
    except (OSError, subprocess.TimeoutExpired) as error:
        return [], str(error)
    if out.returncode != 0:
        return [], (out.stderr.strip() or f"exit {out.returncode}")[:300]
    return [line for line in out.stdout.splitlines() if line and not line.startswith("==") and " count: " not in line], None


# The glyph atlas phase (task 039): what one more visible terminal costs in GPU memory, and whether
# the glyph atlas texture is shared by every surface or copied into each.


def gpu_bytes(categories: dict[str, int]) -> int:
    """The bytes of footprint categories in the GPU groups (IOAccelerator, IOSurface, owned unmapped memory)."""
    return sum(value for category, value in categories.items() if group_of(category) in GPU_GROUPS)


def atlas_glyph_count(scale: float) -> int:
    """The glyphs whose rasterized area at backing `scale` is ATLAS_SHEET_PIXELS (at most the CJK block)."""
    return min(-(-ATLAS_SHEET_PIXELS // round(ATLAS_GLYPH_PIXELS_1X * scale * scale)),
               ATLAS_LAST_CODEPOINT - ATLAS_FIRST_CODEPOINT + 1)


def backing_scale(rpc) -> float | None:
    """The app windows' backing scale (`debug.pane_chrome` windows[].scale; the largest when they differ), or None."""
    reply = rpc("debug.pane_chrome")
    windows = reply.get("windows") if isinstance(reply, dict) else None
    scales = [w["scale"] for w in windows or [] if isinstance(w, dict) and isinstance(w.get("scale"), (int, float)) and w["scale"] > 0]
    return max(scales) if scales else None


def glyph_pages(count: int) -> list[str]:
    """`count` distinct CJK ideographs in pages that each fit a quarter of the STRESS window, so every
    glyph is on screen in some frame (a glyph that scrolls away before a frame is never rasterized)."""
    glyphs = [chr(ATLAS_FIRST_CODEPOINT + index) for index in range(count)]
    per_page = ATLAS_LINE_GLYPHS * ATLAS_PAGE_LINES
    pages = []
    for start in range(0, count, per_page):
        page = glyphs[start:start + per_page]
        pages.append("".join("".join(page[i:i + ATLAS_LINE_GLYPHS]) + "\n" for i in range(0, len(page), ATLAS_LINE_GLYPHS)))
    return pages


def slope(points: list[tuple[int, int]]) -> float | None:
    """Least-squares bytes per terminal over (terminals, bytes); None below two distinct counts."""
    if len({k for k, _ in points}) < 2:
        return None
    mean_k = sum(k for k, _ in points) / len(points)
    mean_b = sum(b for _, b in points) / len(points)
    return sum((k - mean_k) * (b - mean_b) for k, b in points) / sum((k - mean_k) ** 2 for k, _ in points)


def atlas_summary(start: list[tuple[int, int]], grown: list[tuple[int, int]]) -> dict:
    """The atlas verdict from GPU bytes at 1..K visible terminals tiling one window, first with the
    atlas at its start size (`start`), then after the glyph sheet grew it (`grown`).

    Tiling keeps the panes' total area, so drawables, render targets and cell buffers add up to about
    the same bytes at every count: the slope over the count is what each surface holds whatever its
    size. The atlas growth moves that slope by the bytes each surface keeps of the grown atlas
    (`atlas_bytes_per_extra_terminal`): 0 when one atlas texture serves every surface (Chrome's GPU
    process keeps one glyph atlas for every renderer: Skia's GrDrawOpAtlas,
    third_party/skia/src/gpu/ganesh/GrDrawOpAtlas.cpp), the growth one terminal saw
    (`atlas_growth_one_terminal_bytes`) when every surface keeps its own copies."""
    before, after = slope(start), slope(grown)
    one_before = next((b for k, b in start if k == 1), None)
    one_after = next((b for k, b in grown if k == 1), None)
    summary = {"terminals": max((k for k, _ in start + grown), default=0),
               "gpu_bytes_per_extra_terminal_start": None if before is None else round(before),
               "gpu_bytes_per_extra_terminal_grown": None if after is None else round(after),
               "atlas_bytes_per_extra_terminal": None, "gpu_slope_change_bytes": None,
               "atlas_growth_one_terminal_bytes": None,
               "per_surface_share": None, "verdict": "unmeasured", "expected_shared_atlas_bytes": ATLAS_EXPECTED_BYTES,
               "start": [{"terminals": k, "gpu_bytes": b} for k, b in start],
               "grown": [{"terminals": k, "gpu_bytes": b} for k, b in grown]}
    if before is None or after is None or one_before is None or one_after is None:
        summary["why"] = "fewer than two terminal counts measured in each series, or no one-terminal step"
        return summary
    per_extra, growth = round(after - before), one_after - one_before
    # The raw slope change is kept in its own field: atlas_bytes_per_extra_terminal is the recorded number
    # (memory-DESIGN.md), so it stays unknown unless the verdict is measured.
    summary.update(gpu_slope_change_bytes=per_extra, atlas_growth_one_terminal_bytes=growth)
    if growth < ATLAS_MIN_GROWTH_BYTES:
        summary["why"] = f"the glyph sheet grew one terminal's GPU bytes by {mb(growth)} MB only: the atlas did not grow"
        return summary
    share = per_extra / growth
    summary.update(atlas_bytes_per_extra_terminal=per_extra, per_surface_share=round(share, 2),
                   verdict="per_surface" if share >= ATLAS_PER_SURFACE_SHARE else "shared")
    return summary


def print_atlas(summary: dict):
    print(f"ATLAS terminals={summary['terminals']} atlas_bytes_per_extra_terminal="
          f"{'unknown' if summary['atlas_bytes_per_extra_terminal'] is None else summary['atlas_bytes_per_extra_terminal']} "
          f"gpu_per_extra_start_mb={mb(summary['gpu_bytes_per_extra_terminal_start'])} "
          f"gpu_per_extra_grown_mb={mb(summary['gpu_bytes_per_extra_terminal_grown'])} "
          f"slope_change_mb={mb(summary['gpu_slope_change_bytes'])} "
          f"growth_one_terminal_mb={mb(summary['atlas_growth_one_terminal_bytes'])} "
          f"share={summary['per_surface_share']} verdict={summary['verdict']} "
          f"expected_shared_atlas_mb={mb(summary['expected_shared_atlas_bytes'])} "
          f"scale={summary.get('backing_scale')} glyphs={summary.get('glyphs')}"
          + (f" why={summary['why']!r}" if summary.get("why") else ""))
    sys.stdout.flush()


# Output.


def mb(value: int | None) -> str:
    return "unknown" if value is None else f"{value / MB:.1f}"


def print_phase(phase: dict):
    phys = phase["phys_footprint_bytes"] or 1
    print(f"== {phase['label']}: app footprint {mb(phase['phys_footprint_bytes'])} MB "
          f"(categories {mb(phase['categories_bytes'])} MB, source {phase.get('source', '?')}); "
          f"debug.memory {'with ' + str(phase['debug_memory']['consumers']) + ' consumers' if phase['debug_memory']['available'] else 'unavailable: ' + str(phase['debug_memory']['error'])}")
    print(f"   {'group':<32}{'MB':>9}{'%':>7}{'explained MB':>14}  owner")
    for row in phase["groups"]:
        owner = row["owner"] or ", ".join(f"{c['name']} {mb(c['bytes'])}" for c in row["consumers"][:3]) or "-"
        print(f"   {row['group'][:31]:<32}{row['bytes'] / MB:>9.1f}{100 * row['bytes'] / phys:>7.1f}"
              f"{row['explained_bytes'] / MB:>14.1f}  {owner}")
    print(f"MEMORY-REPORT phase={phase['label']} footprint_mb={mb(phase['phys_footprint_bytes'])} "
          f"unattributed_mb={mb(phase['unattributed_bytes'])} unattributed_pct={phase['unattributed_pct']} "
          f"debug_memory={'yes' if phase['debug_memory']['available'] else 'no'}")
    for row in phase["mq_unattributed"]:
        print(f"MQ-UNATTRIBUTED phase={phase['label']} group={row['group']!r} unexplained_mb={mb(row['unexplained_bytes'])} "
              f"of_mb={mb(row['bytes'])} owned_by={','.join(row['owned_by']) or 'none'}")
    for error in phase.get("tool_errors") or []:
        print(f"   tool: {error}")
    for note in phase.get("notes") or []:
        print(f"   note: {note}")
    for row in phase["consumer_bytes_beyond_regions"]:
        print(f"   note: consumer {row['name']} reports {mb(row['bytes'])} MB more than its allocator's regions hold")
    if phase.get("consumers_without_storage"):
        print(f"   note: {len(phase['consumers_without_storage'])} consumers report no traits.storage and explain "
              f"nothing: {', '.join(phase['consumers_without_storage'][:8])}")
    sys.stdout.flush()


# Live measurement (macOS).


class RunCancelled(BaseException):
    """A fleet cancel or timeout (SIGTERM, SIGHUP): the run leaves through its finally blocks, so the app
    and the virtual display end with it and the JSON keeps the phases already measured."""

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


def run_tool(argv: list[str], timeout: float = 300) -> tuple[str, str | None]:
    """(stdout, error or None)."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return "", f"{argv[0]}: {error}"
    if out.returncode != 0:
        return out.stdout, f"{argv[0]} exit {out.returncode}: {(out.stderr or out.stdout).strip()[:300]}"
    return out.stdout, None


def rpc(path: str, method: str, params: dict | None = None, timeout: float = 60) -> dict:
    """One control-socket call: its result, or {"error": ...}."""
    reply = b""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(timeout)
            stream.connect(path)
            stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            while not reply.endswith(b"\n"):
                chunk = stream.recv(1 << 22)
                if not chunk:
                    break
                reply += chunk
        answer = json.loads(reply or b"{}")
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if answer.get("error") or answer.get("ok") is False:
        return {"error": answer.get("error") or "refused"}
    result = answer.get("result")
    return result if isinstance(result, dict) else {"error": f"no result object: {str(result)[:200]}"}


def load_module(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    if HERE not in sys.path:
        sys.path.insert(0, HERE)  # python -I leaves the script folder out
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def heap_summary(walk: dict) -> dict:
    """What the phase JSON keeps of a heap walk."""
    return {"enumerated": walk["enumerated"], "why": walk["why"],
            "bytes": sum(walk["classes"].values()) if walk["enumerated"] else None}


def measure(label: str, pid: int, socket_path: str | None, heap: bool, raw_stem: str) -> tuple[dict, dict | None, dict | None]:
    """(phase report, debug.memory reply or None, heap walk or None) of process `pid` now; raw outputs
    go to `raw_stem`-*."""
    debug_memory, debug_error = None, "no --socket"
    if socket_path:
        reply = rpc(socket_path, "debug.memory")
        if "error" in reply:
            debug_error = json.dumps(reply["error"])[:300]
        else:
            debug_memory = reply
            write(raw_stem + "-debug-memory.json", json.dumps(reply, indent=1))
    json_path = raw_stem + "-footprint.json"
    text, footprint_error = run_tool(["footprint", "-j", json_path, str(pid)])
    write(raw_stem + "-footprint.txt", text)
    categories, source = {}, None
    phys = None
    try:
        with open(json_path) as handle:
            categories, phys = footprint_categories(json.load(handle))
            source = "footprint -j" if categories else None
    except (OSError, ValueError):
        pass
    if not categories:
        categories, phys = footprint_text_categories(text)
        source = "footprint (text)" if categories else None
    vmmap_text, vmmap_error = run_tool(["vmmap", "-summary", str(pid)])
    write(raw_stem + "-vmmap.txt", vmmap_text)
    regions, zones = vmmap_tables(vmmap_text)
    phys = phys or vmmap_footprint(vmmap_text)
    if not categories and regions:
        categories, source = regions, "vmmap -summary"
    phase = analyze(label, categories, zones, phys, debug_memory, debug_error)
    phase["source"] = source or "none"
    phase["tool_errors"] = [e for e in (footprint_error if not categories else None, vmmap_error) if e]
    walk = None
    if heap:
        heap_text, heap_error = run_tool(["heap", "-sortBySize", str(pid)], timeout=600)
        write(raw_stem + "-heap.txt", heap_text)
        walk = heap_walk(heap_text, zones)
        if heap_error:
            phase["tool_errors"].append(heap_error)
        phase["heap"] = heap_summary(walk)
    return phase, debug_memory, walk


def gpu_sample(pid: int, raw_stem: str) -> int | None:
    """The GPU groups' bytes of process `pid` now (`footprint -j`, its JSON beside `raw_stem`), or None."""
    json_path = raw_stem + "-footprint.json"
    _, error = run_tool(["footprint", "-j", json_path, str(pid)])
    try:
        with open(json_path) as handle:
            categories, _ = footprint_categories(json.load(handle))
    except (OSError, ValueError):
        return None
    if error and not categories:
        return None
    return gpu_bytes(categories)


def measure_atlas(builder, stem: str, terminals: int, settle: float, sample, wait) -> dict:
    """The atlas phase: in a new workspace on the placed STRESS window, GPU bytes (`sample(raw_stem)`) at
    1..`terminals` visible terminals tiling the window in two columns; then every terminal shows the
    glyph sheet (sized for the window's backing scale), which grows the shared CPU atlas; then GPU bytes
    again while the panes close back to one. `builder` is a perf-stress-session Stress and `wait` its
    bounded poll (`wait(predicate, seconds, step)`). The workspace closes even when a step fails, so
    no later phase measures its terminals. Returns atlas_summary's dict with the scale and glyph count."""
    builder.size_window()
    workspace = builder.new_workspace()
    if not workspace:
        raise RuntimeError("the atlas workspace did not appear")
    try:
        return measure_atlas_in(builder, workspace, stem, terminals, settle, sample, wait)
    finally:
        builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)


def measure_atlas_in(builder, workspace: str, stem: str, terminals: int, settle: float, sample, wait) -> dict:
    """measure_atlas's steps in its new `workspace`."""
    builder.show(workspace)  # splits size evenly only in a shown workspace (Stress.build_measured)
    scale = backing_scale(builder.rpc)
    if scale is None:
        raise RuntimeError("no window backing scale (debug.pane_chrome): the glyph sheet cannot be sized")
    glyphs = atlas_glyph_count(scale)

    def pane_ids() -> list[str]:
        return [p["id"] for p in builder.panes(builder.workspace(workspace))]

    panes = pane_ids()[:1]
    if not panes:
        raise RuntimeError(f"the atlas workspace {workspace} has no pane")
    builder.record_first(workspace, panes[0])

    def take(series: list, label: str):
        time.sleep(settle)  # test script: drawables and buffers settle after the change
        value = sample(f"{stem}-{label}-{len(panes)}")
        if value is None:
            raise RuntimeError(f"no GPU sample at {len(panes)} terminals ({label})")
        series.append((len(panes), value))

    start: list[tuple[int, int]] = []
    take(start, "start")
    while len(panes) < terminals:
        # Two columns: the first split goes right, then each new pane goes under the pane two before it
        # (p0 | p1, then p2 under p0, p3 under p1, ...), so 4 terminals are a 2 x 2 grid.
        target, verb = (panes[0], "splitRight") if len(panes) == 1 else (panes[-2], "splitDown")
        made = builder.split(workspace, target, verb)
        if not made:
            raise RuntimeError(f"split {len(panes) + 1} made no pane (refusals: {builder.refusals[-3:]})")
        panes.append(made)
        builder.action("equalizeSplits", target=f"pane:{panes[0]}")
        take(start, "start")

    folder = f"{stem}-glyphs"  # kept beside the report with the raw samples
    os.makedirs(folder, exist_ok=True)
    pages = glyph_pages(glyphs)
    for index, page in enumerate(pages):
        write(os.path.join(folder, f"page-{index:03d}.txt"), page)
    show = f"for f in {shlex.quote(folder)}/page-*.txt; do clear; cat \"$f\"; sleep {ATLAS_PAGE_SECONDS}; done\r"
    for pane in panes:
        terminal = next((t for t in builder.tabs(workspace, pane) if t.get("kind") == "terminal"), None)
        if not terminal:
            raise RuntimeError(f"pane {pane} has no terminal for the glyph sheet")
        builder.send(terminal["id"], show)
    time.sleep(len(pages) * ATLAS_PAGE_SECONDS + 2)  # test script: every page shown in every terminal

    grown: list[tuple[int, int]] = []
    take(grown, "grown")
    while len(panes) > 1:
        closed = panes.pop()
        builder.action("closePane", target=f"pane:{closed}", focus=False)
        if not wait(lambda: closed not in pane_ids(), 15, 0.1):
            raise RuntimeError(f"closePane left pane {closed} open (refusals: {builder.refusals[-3:]})")
        builder.action("equalizeSplits", target=f"pane:{panes[0]}")
        take(grown, "grown")
    return {**atlas_summary(start, grown), "backing_scale": scale, "glyphs": glyphs}


def write(path: str, text: str):
    with open(path, "w") as handle:
        handle.write(text)


def read(path: str) -> str:
    with open(path, errors="replace") as handle:
        return handle.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a tagged `cmux DEV <tag>.app` to launch (Debug or --config bench)")
    where.add_argument("--pid", type=int, help="a running app's pid")
    where.add_argument("--footprint-file", help="offline: saved `footprint -j` JSON (or its text output)")
    parser.add_argument("--socket", help="with --pid: the app's control socket, for debug.memory")
    parser.add_argument("--phases", default="home",
                        help="with --app: a comma list of home, atlas and stress, run in that order as given; atlas and stress "
                             "need separate launches (default home)")
    parser.add_argument("--settle", type=float, default=30, help="seconds idle before each measurement (default 30)")
    parser.add_argument("--heap", action="store_true", help="walk the heap for the MQ-CACHE order (stalls the app)")
    parser.add_argument("--vdisplay", type=float, default=None,
                        help=f"with --app: a 1920 x 1200 virtual main display at this refresh (Hz) before the launch "
                             f"(default {VDISPLAY_HZ:g} with the atlas or stress phase, else none; 0 turns it off)")
    parser.add_argument("--atlas-terminals", type=int, default=ATLAS_TERMINALS,
                        help=f"the atlas phase: visible terminals at the end of the series (default {ATLAS_TERMINALS})")
    parser.add_argument("--atlas-settle", type=float, default=ATLAS_SETTLE,
                        help=f"the atlas phase: seconds after each change before a GPU sample (default {ATLAS_SETTLE:g})")
    parser.add_argument("--vdisplay-hold", type=float, default=1800,
                        help="the virtual display helper's own lifetime in seconds (default 1800): it ends by itself "
                             "when this script is killed and cannot clean up")
    parser.add_argument("--vmmap-file", help="offline: saved `vmmap -summary` output")
    parser.add_argument("--heap-file", help="offline: saved `heap` output")
    parser.add_argument("--debug-memory-file", help="offline: saved debug.memory reply")
    parser.add_argument("--phys-footprint-bytes", type=int, help="offline: the app's phys_footprint")
    parser.add_argument("--label", default="saved", help="offline: the phase label")
    parser.add_argument("--no-cache-queue", action="store_true", help="skip the MQ-CACHE order")
    parser.add_argument("--out", help="the JSON report (default memory-report-<pid or label>.json)")
    args = parser.parse_args(argv)
    phases_asked = [p for p in args.phases.split(",") if p]
    if any(p not in ("home", "atlas", "stress") for p in phases_asked):
        parser.error(f"--phases takes home, atlas and stress, got {args.phases!r}")
    if "atlas" in phases_asked and "stress" in phases_asked:
        # The atlas phase leaves the shared CPU atlas grown, so every STRESS terminal would sync its frame
        # textures to the grown size: that STRESS footprint is not comparable with a home,stress run.
        parser.error("--phases cannot hold both atlas and stress: the grown atlas inflates STRESS; launch them separately")
    if args.atlas_terminals < 2:
        parser.error("--atlas-terminals needs at least 2 (the slope is over the terminal count)")

    report: dict = {"tool": "memory-report", "time": round(time.time()), "phases": []}
    samples: list[tuple[dict | None, dict | None]] = []  # (debug.memory reply, heap walk) per measured phase
    out = os.path.abspath(args.out or f"memory-report-{args.label if args.footprint_file else args.pid or 'app'}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    failed = True
    try:
        if args.footprint_file:
            failed = read_saved(args, report, samples)
        elif args.pid:
            phase, debug_memory, walk = measure("attach", args.pid, args.socket, args.heap, os.path.splitext(out)[0] + "-attach")
            report["pid"] = args.pid
            report["phases"].append(phase)
            samples.append((debug_memory, walk))
            failed = phase["source"] == "none"
        else:
            failed = run_launched(args, phases_asked, report, samples, out)
    finally:
        # Also on a launch failure or a cancel: the phases measured so far are the evidence.
        emit(args, report, samples, out)
    return 1 if failed else 0


def read_saved(args, report: dict, samples: list) -> bool:
    """The offline phase from --footprint-file and the other saved outputs; True when it had no categories."""
    text = read(args.footprint_file)
    try:
        categories, total = footprint_categories(json.loads(text))
        source = "footprint -j"
    except ValueError:
        categories, total = footprint_text_categories(text)
        source = "footprint (text)"
    zones: dict[str, int] = {}
    if args.vmmap_file:
        vmmap_text = read(args.vmmap_file)
        regions, zones = vmmap_tables(vmmap_text)
        total = total or vmmap_footprint(vmmap_text)  # as measure() falls back
        if not categories:
            categories, source = regions, "vmmap -summary"
    debug_memory = json.loads(read(args.debug_memory_file)) if args.debug_memory_file else None
    phase = analyze(args.label, categories, zones, args.phys_footprint_bytes or total, debug_memory,
                    None if debug_memory else "no --debug-memory-file")
    phase["source"] = source if categories else "none"
    walk = heap_walk(read(args.heap_file), zones) if args.heap_file else None
    if walk:
        phase["heap"] = heap_summary(walk)
    report["phases"].append(phase)
    samples.append((debug_memory, walk))
    return not categories


def emit(args, report: dict, samples: list, out: str):
    """Prints every phase and the MQ-CACHE order, and writes the JSON."""
    if report.get("vdisplay_error"):
        print(f"memory-report: no virtual display: {report['vdisplay_error']}")
    if "atlas" in report:
        if report["atlas"].get("error"):
            print(f"ATLAS error: {report['atlas']['error']}")
        else:
            print_atlas(report["atlas"])
    for phase in report["phases"]:
        if "skipped" in phase:
            print(f"MEMORY-REPORT phase={phase['label']} skipped: {phase['skipped']}")
        else:
            print_phase(phase)
    if not args.no_cache_queue:
        files, why = queue_files()
        debug_memory = next((d for d, _ in reversed(samples) if d is not None), None)
        walks = [w for _, w in samples if w]
        heap = next((w for w in reversed(walks) if w["enumerated"]), None)
        heap_why = None if heap else walks[-1]["why"] if walks else "no --heap"
        rows = mq_cache_order(files, debug_memory, heap)
        report["mq_cache"] = {"files": rows, "error": why, "debug_memory": debug_memory is not None,
                              "heap": heap is not None, "heap_why": heap_why}
        if why:
            print(f"MQ-CACHE error: {why}")
        if heap_why:
            print(f"MQ-CACHE heap bytes unknown: {heap_why}")
        for row in rows:
            print(f"MQ-CACHE rank={row['rank']} bytes={'unknown' if row['bytes'] is None else row['bytes']} "
                  f"source={row['source'] or 'none'} file={row['file']}")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"memory-report: wrote {out}")
    sys.stdout.flush()


def run_launched(args, phases: list[str], report: dict, samples: list, out: str) -> bool:
    """Launches --app as perf-stress-session.py does, on its virtual display when STRESS is asked, and
    measures each phase; True when one failed. app.log and the display's log stay beside `out`."""
    stress_module = load_module("perf_stress_session", "perf-stress-session.py")
    folder, stem = os.path.dirname(out), os.path.splitext(out)[0]
    report["app_log"] = os.path.join(folder, "app.log")
    display = app = builder = None
    failed = False

    def cancel(signum, _frame):
        raise RunCancelled(signum)

    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, cancel)
    try:
        hz = args.vdisplay if args.vdisplay is not None else VDISPLAY_HZ if {"atlas", "stress"} & set(phases) else 0
        if hz:
            try:
                display = stress_module.start_vdisplay(hz, folder, args.vdisplay_hold)
                report["vdisplay_hz"] = hz
            except stress_module.StressShapeError as error:
                report["vdisplay_error"] = str(error)[:600]  # STRESS then says why it does not fit
        app = stress_module.load_activation_app()(os.path.abspath(args.app), folder, 50)
        try:
            app.launch()
        except (SystemExit, Exception) as error:  # App.launch exits when the debug socket never answers
            for label in phases:
                report["phases"].append({"label": label, "skipped": f"the app did not launch: {error} "
                                                                    f"(see {report['app_log']})"[:600]})
            return True
        report["pid"] = app.process.pid
        for label in phases:
            if label == "atlas":
                atlas_builder = stress_module.Stress(app.rpc)
                pid = app.process.pid
                try:
                    report["atlas"] = measure_atlas(atlas_builder, f"{stem}-atlas", args.atlas_terminals,
                                                    args.atlas_settle, lambda raw: gpu_sample(pid, raw),
                                                    stress_module.wait)
                except Exception as error:  # a refused split, a missing display, a reply the steps did not expect
                    report["atlas"] = {"error": f"{type(error).__name__}: {error}"[:600]}
                finally:
                    atlas_builder.close()
                failed = failed or "error" in report["atlas"] or report["atlas"]["verdict"] == "unmeasured"
                continue
            if label == "stress":
                try:
                    builder = stress_module.Stress(app.rpc)
                    report["stress_session"] = builder.build()
                except Exception as error:  # the shape check, or a reply the builder did not expect
                    report["phases"].append({"label": label, "skipped": f"{type(error).__name__}: {error}"[:600]})
                    failed = True
                    continue
            time.sleep(args.settle)  # test script: the idle window before a measurement
            phase, debug_memory, walk = measure(label, app.process.pid, app.socket, args.heap, f"{stem}-{label}")
            report["phases"].append(phase)
            samples.append((debug_memory, walk))
            failed = failed or phase["source"] == "none"
    finally:
        try:
            if builder:
                builder.close()
        finally:
            if app:
                app.stop()
            if display:
                display.terminate()  # the helper this script started, by its process
    return failed


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RunCancelled as cancelled:
        sys.exit(128 + cancelled.signum)
