"""remote_cocoa view parity for the Chromium Host (gen-chromium-host-wire.py --check-view-parity).

Chrome draws an out-of-process NSView through two mojo interfaces in
content/common/render_widget_host_ns_view.mojom: RenderWidgetHostNSView (the
browser process tells the view what to show) and RenderWidgetHostNSViewHost
(the view sends input and geometry back), plus PopupMenuRunner. In cmux the
Chromium Host is the browser process and cmux's ChromiumHostPageView is the
view, so every method of those interfaces must have a cmux answer:

  ops     cmux -> host: a cmux_shim_* export, a planned export from the
          "exports" catalog, a wire kind of chromium_host_wire.h, or a
          planned wire op from the "wire" catalog
  events  host -> cmux: a CMUX_SHIM_* event kind, a wire kind, or a planned
          wire event from the catalog
  cmux    what cmux does in its own process for the method (a description;
          it maps nothing, so a mapped row names at least one op or event)
  not_needed  why cmux has no counterpart

A planned name carries the task that adds it, so --list-unmapped shows the row
as open work; once the export or wire kind exists the catalog entry is refused.

The method list is parsed from the mojom texts vendored in
plans/cmux-next/remote_cocoa_mojom/ (sha256 recorded in the parity JSON, so an
upstream change shows as drift), never from constants. Chrome allows [Sync]
calls on the view-to-browser interface; cmux allows none, so a [Sync] method
must be answered from state the host pushes ahead (an event) or not be needed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

PARITY_JSON = "plans/cmux-next/chromium-host-view-parity.json"
SHIM_HEADER = "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h"
# Task p01-process-001 moves the wire header from CEFShim/src to ChromiumHost/src.
WIRE_HEADERS = (
    "Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h",
    "Packages/macOS/CmuxNext/CEFShim/src/chromium_host_wire.h",
)

DIRECTIONS = ("host_to_cmux", "cmux_to_host")
ROW_KEYS = {"ops", "events", "cmux", "not_needed", "task"}
TASK_RE = re.compile(r"^p\d\d-[a-z-]+-\d{3}[a-z]?$")
WIRE_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
EXPORT_NAME_RE = re.compile(r"^cmux_shim_[a-z0-9_]+$")


class ParityError(Exception):
    """The parity JSON or an input it names cannot be read."""


@dataclass(frozen=True)
class MojomMethod:
    interface: str
    name: str
    sync: bool
    has_reply: bool

    @property
    def key(self) -> str:
        return f"{self.interface}.{self.name}"


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def parse_mojom(text: str) -> dict[str, list[MojomMethod]]:
    """Return {interface: [methods in file order]}."""
    text = _strip_comments(text)
    interfaces: dict[str, list[MojomMethod]] = {}
    for match in re.finditer(r"\binterface\s+([A-Za-z_]\w*)\s*\{", text):
        name = match.group(1)
        depth, pos = 1, match.end()
        while depth and pos < len(text):
            depth += {"{": 1, "}": -1}.get(text[pos], 0)
            pos += 1
        if depth:
            raise ParityError(f"interface {name}: no closing brace")
        body = text[match.end() : pos - 1]
        methods = []
        for statement in body.split(";"):
            head = re.match(r"\s*((?:\[[^\]]*\]\s*)*)([A-Za-z_]\w*)\s*\(", statement)
            if not head:
                if statement.strip():
                    raise ParityError(f"interface {name}: cannot parse {statement.strip()[:60]!r}")
                continue
            attributes = re.findall(r"\[([^\]]*)\]", head.group(1))
            sync = any(re.search(r"\bSync\b", attr) for attr in attributes)
            methods.append(MojomMethod(name, head.group(2), sync, "=>" in statement))
        interfaces[name] = methods
    return interfaces


def shim_exports(header: str) -> set[str]:
    names = set()
    for line in header.splitlines():
        if line.lstrip().startswith("#"):
            continue
        match = re.search(r"\bCMUX_SHIM_EXPORT\b[^(]*\b(cmux_shim_[a-z0-9_]+)\s*\(", line)
        if match:
            names.add(match.group(1))
    return names


def shim_event_kinds(header: str) -> set[str]:
    match = re.search(r"typedef\s+enum\s*\{([^}]*)\}\s*cmux_shim_event_kind_t\s*;", _strip_comments(header))
    if not match:
        raise ParityError("cmux_cef_shim.h: no cmux_shim_event_kind_t enum")
    return set(re.findall(r"\b(CMUX_SHIM_[A-Z0-9_]+)\s*=", match.group(1)))


def wire_kinds(header: str) -> dict[str, str]:
    """{UPPER_SNAKE kind: "op" | "event"} from chromium_host_wire.h's enum Kind."""
    match = re.search(r"enum\s+Kind\b[^{]*\{(.*?)\};", header, flags=re.S)
    if not match:
        raise ParityError("chromium_host_wire.h: no enum Kind")
    kinds: dict[str, str] = {}
    direction = None
    for line in match.group(1).splitlines():
        marker = re.match(r"\s*//\s*(cmux|host)\s*->\s*(cmux|host)\s*$", line)
        if marker:
            direction = "op" if marker.group(1) == "cmux" else "event"
            continue
        kind = re.match(r"\s*k([A-Z]\w*)\s*=", line)
        if kind:
            if direction is None:
                raise ParityError(f"chromium_host_wire.h: k{kind.group(1)} before a direction comment")
            kinds[re.sub(r"(?<!^)(?=[A-Z])", "_", kind.group(1)).upper()] = direction
    return kinds


@dataclass
class Report:
    errors: list[str]
    unmapped: list[str]
    planned: list[tuple[str, str, list[str]]]
    counts: dict[str, int]
    sync_methods: int


def _read(root: Path, rel: str) -> str:
    path = root / rel
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ParityError(f"{rel}: {error.strerror}") from error


def check(root: Path, parity_rel: str = PARITY_JSON) -> Report:
    try:
        parity = json.loads(_read(root, parity_rel))
    except json.JSONDecodeError as error:
        raise ParityError(f"{parity_rel}: {error}") from error
    errors: list[str] = []

    header = _read(root, SHIM_HEADER)
    exports, events = shim_exports(header), shim_event_kinds(header)
    wire_rel = next((rel for rel in WIRE_HEADERS if (root / rel).is_file()), None)
    if wire_rel is None:
        raise ParityError("no chromium_host_wire.h at " + " or ".join(WIRE_HEADERS))
    wired = wire_kinds(_read(root, wire_rel))

    methods: dict[str, MojomMethod] = {}
    directions: dict[str, str] = {}
    counts: dict[str, int] = {}
    for mojom in parity.get("mojoms", []):
        rel = mojom.get("path", "")
        raw = (root / rel).read_bytes() if (root / rel).is_file() else None
        if raw is None:
            errors.append(f"{rel}: vendored mojom missing")
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if digest != mojom.get("sha256"):
            errors.append(f"{rel}: sha256 {digest} differs from the parity JSON's {mojom.get('sha256')} (re-vendor and re-map)")
        declared = mojom.get("interfaces", {})
        for interface, parsed in parse_mojom(raw.decode("utf-8")).items():
            direction = declared.get(interface, {}).get("direction")
            if direction not in DIRECTIONS:
                errors.append(f"{rel}: interface {interface} needs a direction ({' or '.join(DIRECTIONS)})")
            directions[interface] = direction or ""
            counts[interface] = len(parsed)
            for method in parsed:
                methods[method.key] = method
        for interface in sorted(set(declared) - set(counts)):
            errors.append(f"{rel}: interface {interface} is declared but not in the mojom")
    if not methods:
        errors.append("no mojom methods: the parity JSON names no vendored mojom")

    catalog = parity.get("wire", {})
    for name, entry in sorted(catalog.items()):
        if not WIRE_NAME_RE.match(name) or name.startswith("CMUX_SHIM_"):
            errors.append(f"wire {name}: planned names are UPPER_SNAKE and not CMUX_SHIM_*")
        if name in wired:
            errors.append(f"wire {name}: already a kind in {wire_rel}; drop it from the catalog")
        if entry.get("dir") not in ("op", "event"):
            errors.append(f"wire {name}: dir must be op or event")
        if not TASK_RE.match(str(entry.get("task", ""))):
            errors.append(f"wire {name}: needs the task id that adds it")
        if not str(entry.get("fields", "")).strip():
            errors.append(f"wire {name}: needs its fields")

    planned_exports = parity.get("exports", {})
    for name, entry in sorted(planned_exports.items()):
        if not EXPORT_NAME_RE.match(name):
            errors.append(f"export {name}: planned exports are cmux_shim_[a-z0-9_]+")
        if name in exports:
            errors.append(f"export {name}: already exported by cmux_cef_shim.h; drop it from the catalog")
        if not TASK_RE.match(str(entry.get("task", ""))):
            errors.append(f"export {name}: needs the task id that adds it")
        if not str(entry.get("args", "")).strip():
            errors.append(f"export {name}: needs its arguments")

    rows = parity.get("methods", {})
    used_wire: set[str] = set()
    used_exports: set[str] = set()
    unmapped: list[str] = []
    planned: list[tuple[str, str, list[str]]] = []
    for key in sorted(set(rows) - set(methods)):
        errors.append(f"{key}: row names no method of the vendored mojoms")
    for key, method in methods.items():
        row = rows.get(key)
        if row is None:
            unmapped.append(key)
            errors.append(f"{key}: unmapped")
            continue
        for extra in sorted(set(row) - ROW_KEYS):
            errors.append(f"{key}: unknown field {extra!r}")
        ops, evs = row.get("ops", []), row.get("events", [])
        local = str(row.get("cmux", "")).strip()
        reason = str(row.get("not_needed", "")).strip()
        if "not_needed" in row:
            if not reason:
                errors.append(f"{key}: not_needed needs a written reason")
            if ops or evs or local or "task" in row:
                errors.append(f"{key}: a not_needed row maps nothing")
            continue
        if not (ops or evs):
            unmapped.append(key)
            errors.append(f"{key}: no op or event (cmux text only describes) and no not_needed reason")
            continue
        if not TASK_RE.match(str(row.get("task", ""))):
            errors.append(f"{key}: needs the task id that implements it")
        pending: list[str] = []
        for side, names in (("op", ops), ("event", evs)):
            for name in names:
                if name.startswith("cmux_shim_"):
                    if side != "op":
                        errors.append(f"{key}: export {name} is cmux -> host, not an event")
                    elif name in planned_exports:
                        used_exports.add(name)
                        pending.append(f"{name}({planned_exports[name].get('task')})")
                    elif name not in exports:
                        errors.append(f"{key}: {name} is not exported by cmux_cef_shim.h nor a planned export")
                elif name.startswith("CMUX_SHIM_"):
                    if side != "event":
                        errors.append(f"{key}: event kind {name} is host -> cmux, not an op")
                    elif name not in events:
                        errors.append(f"{key}: {name} is not a cmux_shim_event_kind_t")
                elif name in wired:
                    if wired[name] != side:
                        errors.append(f"{key}: wire kind {name} is an {wired[name]}, listed as an {side}")
                elif name in catalog:
                    used_wire.add(name)
                    pending.append(f"{name}({catalog[name].get('task')})")
                    if catalog[name].get("dir") != side:
                        errors.append(f"{key}: planned wire {name} is an {catalog[name].get('dir')}, listed as an {side}")
                else:
                    errors.append(f"{key}: {name} is no export, event kind, wire kind or catalog entry")
        direction = directions.get(method.interface)
        if method.sync and not evs:
            errors.append(f"{key}: [Sync] in Chrome; cmux answers it only from pushed state (an event) or not at all")
        if direction == "host_to_cmux" and not (evs or local):
            errors.append(f"{key}: host -> cmux method needs an event or cmux handling")
        if direction == "host_to_cmux" and method.has_reply and not ops:
            errors.append(f"{key}: has a reply in Chrome; needs the op that answers it")
        if direction == "cmux_to_host" and not method.sync and not (ops or local):
            errors.append(f"{key}: cmux -> host method needs an op or cmux handling")
        if pending:
            planned.append((key, str(row.get("task", "")), pending))
    for name in sorted(set(catalog) - used_wire):
        errors.append(f"wire {name}: no method uses it")
    for name in sorted(set(planned_exports) - used_exports):
        errors.append(f"export {name}: no method uses it")

    return Report(errors, unmapped, planned, counts, sum(m.sync for m in methods.values()))


def summary(report: Report) -> str:
    total = sum(report.counts.values())
    mapped = total - len(report.unmapped)
    per = ", ".join(f"{name} {count}" for name, count in report.counts.items())
    return (
        f"view parity: {mapped}/{total} methods mapped ({per}); "
        f"{report.sync_methods} [Sync] answered from pushed state; "
        f"{len(report.planned)} rows wait on planned wire kinds or exports"
    )


def unmapped_lines(report: Report) -> list[str]:
    lines = [f"unmapped\t-\t{key}" for key in report.unmapped]
    lines += [f"planned\t{task}\t{key}\t{','.join(names)}" for key, task, names in sorted(report.planned, key=lambda p: (p[1], p[0]))]
    return lines


def add_arguments(parser: argparse.ArgumentParser) -> None:
    """The view-parity flags; gen-chromium-host-wire.py's parser adds them beside its own."""
    parser.add_argument("--check-view-parity", action="store_true", help="every vendored mojom method is mapped")
    parser.add_argument("--list-unmapped", action="store_true", help="with the check, print the remote_cocoa parity queue")
    parser.add_argument("--parity", default=PARITY_JSON, help="parity JSON, relative to --repo")


def wants_run(args: argparse.Namespace) -> bool:
    return bool(args.check_view_parity or args.list_unmapped)


def run(args: argparse.Namespace) -> int:
    """Exit status: 0 mapped, 1 a parity error, 2 an input cannot be read. Needs args.repo."""
    try:
        report = check(args.repo, args.parity)
    except ParityError as error:
        print(f"view parity: {error}", file=sys.stderr)
        return 2
    if args.list_unmapped:
        for line in unmapped_lines(report):
            print(line)
    for error in report.errors:
        print(f"view parity: {error}", file=sys.stderr)
    print(summary(report), file=sys.stderr if args.list_unmapped else sys.stdout)
    return 1 if report.errors else 0
