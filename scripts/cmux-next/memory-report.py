#!/usr/bin/env python3
"""Where the cmux app's physical footprint goes (p07-memory task 014, DC15, MQ-UNATTRIBUTED).

Reads the app process with `footprint -j` (VM categories that sum to phys_footprint) and
`vmmap -summary` (the malloc zone table, and the categories when footprint fails), groups the
categories (PartitionAlloc, DefaultMallocZone, other malloc zones, IOSurface, IOAccelerator, CG image,
stacks, __DATA, framework pages, ...), and joins them with the app's memory consumers from
`debug.memory`. Each consumer's footprint bytes explain bytes of the groups its storage lives in; the
rest of a group is unexplained. Stacks, __DATA, framework pages and page tables have a fixed owner
(threads, binaries, the kernel). The design is Chrome's memory-infra: every subsystem reports its own
bytes (base/trace_event/memory_dump_provider.h) and what malloc holds beyond them shows as
`<unspecified>` (docs/memory-infra/README.md); Chromium's VM tags name the PartitionAlloc, V8 and
Blink GC regions (partition_alloc/page_allocator_constants.h, PageTag); vmmap is the Darwin
reference (docs/memory/key_concepts.md).

Prints, per phase:
  * one table: group, MB, share of the app footprint, explained MB, owner;
  * `MEMORY-REPORT phase=... footprint_mb=... unattributed_mb=... unattributed_pct=...`;
  * `MQ-UNATTRIBUTED phase=... group=... unexplained_mb=...` for each group with more than 5 MB no
    consumer or fixed owner explains (each line is one task, p07-memory.md section 6);
and once, `MQ-CACHE rank=... file=... bytes=...`: the files of `memory-queues.sh caches`, largest
measured heap bytes first (bytes of heap objects whose type, or element type, the file declares;
needs --heap; `unknown` sorts last). The JSON file (--out) has all of it plus the raw tool outputs
next to it, which --*-file re-reads offline.

A build without debug.memory (or an attach without --socket) still gets the table: every group
without a fixed owner is then unexplained.

Usage:
  memory-report.py --app BUNDLE [--phases home,stress] [--settle 30] [--heap] [--out FILE.json]
      Launch a tagged DEV app (the STRESS launcher of perf-stress-session.py), measure Home idle,
      then build STRESS in it and measure again. Fleet only (scripts/measure/memory-report.sh).
  memory-report.py --pid PID [--socket PATH] [--heap] [--out FILE.json]
      A running app. `--heap` walks its heap (it stalls the process for seconds: never on a person's
      cmux).
  memory-report.py --footprint-file F.json [--vmmap-file V.txt] [--heap-file H.txt]
      [--debug-memory-file D.json] [--phys-footprint-bytes N] [--out FILE.json]
      Re-read saved outputs (any platform).

Exit 0 when every phase measured; 1 when a phase had no category source or STRESS did not build;
2 on bad arguments. Read-only and local: never wire it into CI or a hook (CLAUDE.md).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MB = 1048576.0
UNATTRIBUTED_LINE_BYTES = 5 * 1048576  # MQ-UNATTRIBUTED: a group with more unexplained bytes is a task

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

# Where each consumer storage lives, in fill order. A heap consumer's bytes are in whichever malloc
# the process has: PartitionAlloc while CEF is in-process (CmuxNextMallocZone/early_zone.c), else the
# default zone.
HEAP_GROUPS = ["PartitionAlloc", "DefaultMallocZone", "malloc (zones unknown)", "malloc zones (other)",
               "WebKit Malloc", "VM_ALLOCATE (untagged)"]
STORAGE_GROUPS = {
    "heap": HEAP_GROUPS,
    "image": ["CG image", "CoreAnimation"] + HEAP_GROUPS,
    "iosurface": ["IOSurface", "owned unmapped memory"],
    "gpu": ["IOAccelerator", "owned unmapped memory", "IOSurface"],
}
IMAGE_NAME = re.compile(r"image|bitmap|thumbnail|snapshot|picture|favicon|icon|tile|glyph|raster", re.I)
SURFACE_NAME = re.compile(r"iosurface", re.I)

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
    """({category: dirty bytes}, process footprint or None) from `footprint -j` JSON: the first
    process object, its categories either a map of name to counts or a list of named counts."""
    def numbers(entry: dict) -> int | None:
        # `dirty` itself before longer keys such as `dirty_compressed`.
        keys = sorted((k for k, v in entry.items() if "dirty" in k.lower() and isinstance(v, (int, float))),
                      key=lambda k: (k.lower() != "dirty", len(k)))
        return int(entry[keys[0]]) if keys else None

    def process(node):
        if isinstance(node, dict):
            if "pid" in node:
                return node
            for value in node.values():
                found = process(value)
                if found is not None:
                    return found
        elif isinstance(node, list):
            for value in node:
                found = process(value)
                if found is not None:
                    return found
        return None

    proc = process(document) or (document if isinstance(document, dict) else {})
    categories: dict[str, int] = {}
    for value in proc.values():
        if isinstance(value, dict) and value and all(isinstance(v, dict) for v in value.values()):
            for name, entry in value.items():
                dirty = numbers(entry)
                if dirty is not None:
                    categories[name] = categories.get(name, 0) + dirty
        elif isinstance(value, list) and value and all(isinstance(v, dict) for v in value):
            for entry in value:
                name = next((entry[k] for k in ("category", "name", "tag", "type") if isinstance(entry.get(k), str)), None)
                dirty = numbers(entry)
                if name and dirty is not None:
                    categories[name] = categories.get(name, 0) + dirty
        if categories:
            break
    categories.pop("TOTAL", None)
    totals = sorted((k for k, v in proc.items() if "footprint" in k.lower() and "peak" not in k.lower()
                     and isinstance(v, (int, float))), key=len)
    return categories, int(proc[totals[0]]) if totals else None


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
HEAP_SECTION = re.compile(r"^(All zones|Zone\s+\S+?)\s*:\s*\d+\s+nodes")


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


# The join.


def consumers_of(debug_memory: dict | None) -> list[dict]:
    """[{name, bytes, storage}] of debug.memory's consumers with known footprint bytes. A consumer's
    `storage` (heap, image, iosurface, gpu) comes from its own field when it has one, else its name."""
    if not isinstance(debug_memory, dict):
        return []
    report = debug_memory.get("report") if isinstance(debug_memory.get("report"), dict) else debug_memory
    rows = []
    for entry in report.get("consumers") or []:
        if not isinstance(entry, dict):
            continue
        usage = entry.get("usage") if isinstance(entry.get("usage"), dict) else entry
        value = next((usage[k] for k in ("footprint_bytes", "footprintBytes", "bytes") if k in usage), None)
        if not isinstance(value, (int, float)):
            continue  # nil bytes: unknown, never 0
        name = str(entry.get("name") or entry.get("id") or "consumer")
        storage = entry.get("storage")
        if storage not in STORAGE_GROUPS:
            storage = "iosurface" if SURFACE_NAME.search(name) else "image" if IMAGE_NAME.search(name) else "heap"
        rows.append({"name": name, "bytes": int(value), "storage": storage})
    terminal = report.get("terminal") if isinstance(report.get("terminal"), dict) else {}
    surfaces = [v for k, v in terminal.items() if "iosurface" in k and k.endswith("bytes") and isinstance(v, (int, float))]
    if surfaces:
        # The terminal fields are nested counts (hidden non-volatile is part of all): the largest.
        rows.append({"name": "terminal IOSurfaces", "bytes": int(max(surfaces)), "storage": "iosurface"})
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


def attribute(groups: dict[str, int], consumers: list[dict]) -> tuple[dict[str, list[dict]], list[dict]]:
    """({group: [{name, bytes}]}, [consumer bytes beyond their storage's groups]): each consumer, largest
    first, fills its storage's groups in order."""
    left = dict(groups)
    owners: dict[str, list[dict]] = {}
    beyond = []
    for consumer in sorted(consumers, key=lambda c: -c["bytes"]):
        need = consumer["bytes"]
        for group in STORAGE_GROUPS[consumer["storage"]]:
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
    owners, beyond = attribute(groups, consumers)
    total = sum(groups.values())
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
            "debug_memory": {"available": available, "error": None if available else debug_error or "not asked",
                             "consumers": len(consumers)}}


def mq_cache_order(files: list[str], classes: dict[str, int] | None, root: str = ROOT) -> list[dict]:
    """MQ-CACHE files, largest first: the heap bytes of objects whose type, or a generic argument,
    is a type the file declares in its module (`Sources/<Module>/`); None (unknown) without a heap."""
    rows = []
    for path in files:
        module_match = re.search(r"Sources/([^/]+)/", path)
        module = module_match.group(1) if module_match else None
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as handle:
                declared = set(re.findall(r"\b(?:class|struct|actor|enum)\s+(\w+)", handle.read()))
        except OSError:
            declared = set()
        value = None
        if classes is not None and module:
            pattern = re.compile(r"\b" + re.escape(module) + r"\.(?:\w+\.)*(" + "|".join(map(re.escape, sorted(declared))) + r")\b") \
                if declared else None
            value = sum(v for name, v in classes.items() if pattern and pattern.search(name))
        rows.append({"file": path, "module": module, "bytes": value, "types": len(declared)})
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
    for row in phase["consumer_bytes_beyond_regions"]:
        print(f"   note: consumer {row['name']} reports {mb(row['bytes'])} MB more than its regions hold")
    sys.stdout.flush()


# Live measurement (macOS).


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


def measure(label: str, pid: int, socket_path: str | None, heap: bool, raw_stem: str) -> tuple[dict, dict | None]:
    """(phase report, heap classes or None) of process `pid` now; raw outputs go to `raw_stem`-*."""
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
    classes = None
    if heap:
        heap_text, heap_error = run_tool(["heap", "-sortBySize", str(pid)], timeout=600)
        write(raw_stem + "-heap.txt", heap_text)
        classes = heap_classes(heap_text) if heap_text else None
        if heap_error:
            phase["tool_errors"].append(heap_error)
        phase["heap_bytes"] = sum(classes.values()) if classes else None
    return phase, classes


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
    parser.add_argument("--phases", default="home", help="with --app: home, stress, or home,stress (default home)")
    parser.add_argument("--settle", type=float, default=30, help="seconds idle before each measurement (default 30)")
    parser.add_argument("--heap", action="store_true", help="walk the heap for the MQ-CACHE order (stalls the app)")
    parser.add_argument("--vmmap-file", help="offline: saved `vmmap -summary` output")
    parser.add_argument("--heap-file", help="offline: saved `heap` output")
    parser.add_argument("--debug-memory-file", help="offline: saved debug.memory reply")
    parser.add_argument("--phys-footprint-bytes", type=int, help="offline: the app's phys_footprint")
    parser.add_argument("--label", default="saved", help="offline: the phase label")
    parser.add_argument("--no-cache-queue", action="store_true", help="skip the MQ-CACHE order")
    parser.add_argument("--out", help="the JSON report (default memory-report-<pid or label>.json)")
    args = parser.parse_args(argv)
    phases_asked = [p for p in args.phases.split(",") if p]
    if any(p not in ("home", "stress") for p in phases_asked):
        parser.error(f"--phases takes home and stress, got {args.phases!r}")

    report: dict = {"tool": "memory-report", "time": round(time.time()), "phases": []}
    heaps: list[dict] = []
    failed = False
    if args.footprint_file:
        text = read(args.footprint_file)
        try:
            categories, total = footprint_categories(json.loads(text))
            source = "footprint -j"
        except ValueError:
            categories, total = footprint_text_categories(text)
            source = "footprint (text)"
        zones: dict[str, int] = {}
        if args.vmmap_file:
            regions, zones = vmmap_tables(read(args.vmmap_file))
            if not categories:
                categories, source = regions, "vmmap -summary"
        debug_memory = json.loads(read(args.debug_memory_file)) if args.debug_memory_file else None
        phase = analyze(args.label, categories, zones, args.phys_footprint_bytes or total, debug_memory,
                        None if debug_memory else "no --debug-memory-file")
        phase["source"] = source if categories else "none"
        report["phases"].append(phase)
        failed = not categories
        if args.heap_file:
            heaps.append(heap_classes(read(args.heap_file)))
        out = args.out or f"memory-report-{args.label}.json"
    else:
        out = os.path.abspath(args.out or f"memory-report-{args.pid or 'app'}.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        stem = os.path.splitext(out)[0]
        if args.pid:
            phase, classes = measure("attach", args.pid, args.socket, args.heap, stem + "-attach")
            report["pid"] = args.pid
            report["phases"].append(phase)
            failed = phase["source"] == "none"
            if classes:
                heaps.append(classes)
        else:
            failed = run_launched(args, phases_asked, report, heaps, stem)
    for phase in report["phases"]:
        if "skipped" in phase:
            print(f"MEMORY-REPORT phase={phase['label']} skipped: {phase['skipped']}")
        else:
            print_phase(phase)
    if not args.no_cache_queue:
        files, why = queue_files()
        rows = mq_cache_order(files, heaps[-1] if heaps else None)
        report["mq_cache"] = {"files": rows, "error": why, "heap": bool(heaps)}
        if why:
            print(f"MQ-CACHE error: {why}")
        for row in rows:
            print(f"MQ-CACHE rank={row['rank']} bytes={'unknown' if row['bytes'] is None else row['bytes']} file={row['file']}")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"memory-report: wrote {out}")
    return 1 if failed else 0


def run_launched(args, phases: list[str], report: dict, heaps: list[dict], stem: str) -> bool:
    """Launches --app as perf-stress-session.py does, measures each phase; True when one failed."""
    stress_module = load_module("perf_stress_session", "perf-stress-session.py")
    scratch = tempfile.mkdtemp(prefix="memory-report-")
    app = stress_module.load_activation_app()(os.path.abspath(args.app), scratch, 50)
    builder = None
    failed = False
    # A fleet cancel or timeout sends SIGTERM: leave through the finally, so the app ends with the run.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        app.launch()
        report["pid"] = app.process.pid
        for label in phases:
            if label == "stress":
                builder = stress_module.Stress(app.rpc)
                try:
                    report["stress_session"] = builder.build()
                except stress_module.StressShapeError as error:
                    report["phases"].append({"label": label, "skipped": str(error)[:600]})
                    failed = True
                    continue
            time.sleep(args.settle)  # test script: the idle window before a measurement
            phase, classes = measure(label, app.process.pid, app.socket, args.heap, f"{stem}-{label}")
            report["phases"].append(phase)
            failed = failed or phase["source"] == "none"
            if classes:
                heaps.append(classes)
    finally:
        if builder:
            builder.close()
        app.stop()
        shutil.rmtree(scratch, ignore_errors=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
