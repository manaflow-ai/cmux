#!/usr/bin/env python3
"""Parse ``system.top`` payloads into benchmark process-accounting groups.

The socket payload repeats process trees at several topology levels.  This
module normalizes those repetitions into one immutable process snapshot, then
uses :mod:`perf_process_tree` for the independent parent, terminal, and WebKit
subtotals.  The payload's top-level totals remain authoritative for the full
snapshot because the independent groups can intentionally overlap.
"""

from __future__ import annotations

from dataclasses import dataclass
import importlib.util
from math import isfinite
from pathlib import Path
import sys
from types import MappingProxyType
from typing import Any, Mapping


def _load_process_tree() -> Any:
    existing = sys.modules.get("perf_process_tree")
    if existing is not None:
        return existing
    path = Path(__file__).with_name("perf_process_tree.py")
    spec = importlib.util.spec_from_file_location("perf_process_tree", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load perf_process_tree from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_process_tree = _load_process_tree()
ProcessCoverage = _process_tree.ProcessCoverage
ProcessRecord = _process_tree.ProcessRecord
ProcessSubtotal = _process_tree.ProcessSubtotal
analyze_process_tree = _process_tree.analyze_process_tree
classify_webkit_role = _process_tree.classify_webkit_role
expand_descendants = _process_tree.expand_descendants

_WEBKIT_ROLES = ("content", "gpu", "network")
_TOPOLOGY_CHILDREN = ("workspaces", "panes", "surfaces", "webviews")


@dataclass(frozen=True)
class TopPayloadAccounting:
    """Immutable accounting derived from one complete ``system.top`` payload."""

    app_pid: int
    terminal_root_pids: tuple[int, ...]
    webkit_root_pids: tuple[int, ...]
    webkit_role_pids: Mapping[str, tuple[int, ...]]
    parent_direct: Any
    terminal: Any
    webkit: Any
    full_tree: Any
    coverage: Any

    def __post_init__(self) -> None:
        object.__setattr__(
            self, "terminal_root_pids", tuple(sorted(set(self.terminal_root_pids)))
        )
        object.__setattr__(
            self, "webkit_root_pids", tuple(sorted(set(self.webkit_root_pids)))
        )
        canonical_roles = {
            role: tuple(sorted(set(self.webkit_role_pids.get(role, ()))))
            for role in _WEBKIT_ROLES
        }
        object.__setattr__(
            self, "webkit_role_pids", MappingProxyType(canonical_roles)
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "app_pid": self.app_pid,
            "terminal_root_pids": list(self.terminal_root_pids),
            "webkit_root_pids": list(self.webkit_root_pids),
            "webkit_role_pids": {
                role: list(self.webkit_role_pids[role]) for role in _WEBKIT_ROLES
            },
            "parent_direct": self.parent_direct.to_dict(),
            "terminal": self.terminal.to_dict(),
            "webkit": self.webkit.to_dict(),
            "full_tree": self.full_tree.to_dict(),
            "coverage": self.coverage.to_dict(),
        }


def _mapping(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ValueError(f"{name} must be a mapping")
    return value


def _array(value: Any, name: str) -> list[Any] | tuple[Any, ...]:
    if not isinstance(value, (list, tuple)):
        raise ValueError(f"{name} must be an array")
    return value


def _integer(value: Any, name: str, *, positive: bool = False) -> int:
    minimum = 1 if positive else 0
    if type(value) is not int or value < minimum:
        qualifier = "positive" if positive else "nonnegative"
        raise ValueError(f"{name} must be a {qualifier} integer")
    return value


def _pid_array(value: Any, name: str) -> tuple[int, ...]:
    values = _array(value, name)
    pids = tuple(
        _integer(item, f"{name}[{index}]", positive=True)
        for index, item in enumerate(values)
    )
    if len(pids) != len(set(pids)):
        raise ValueError(f"{name} must not contain duplicate process IDs")
    return pids


def _resource_number(value: Any, name: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not isfinite(value)
        or value < 0
    ):
        raise ValueError(f"{name} must be a nonnegative finite number")
    return float(value)


def _resource_bytes(value: Any, name: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")
    return value


def _resource_fields(resources: Any, name: str) -> tuple[float, int, int]:
    summary = _mapping(resources, name)
    try:
        cpu_raw = summary["cpu_percent"]
        resident_raw = summary["resident_bytes"]
        footprint_raw = summary["memory_bytes"]
    except KeyError as error:
        raise ValueError(f"{name} is missing {error.args[0]}") from None
    return (
        _resource_number(cpu_raw, f"{name}.cpu_percent"),
        _resource_bytes(resident_raw, f"{name}.resident_bytes"),
        _resource_bytes(footprint_raw, f"{name}.memory_bytes"),
    )


def _process_command(node: Mapping[str, Any], name: str) -> str:
    process_name = node.get("name")
    if not isinstance(process_name, str):
        raise ValueError(f"{name}.name must be a string")
    path = node.get("path")
    if path is not None and not isinstance(path, str):
        raise ValueError(f"{name}.path must be a string or null")
    return process_name if not path else f"{process_name} {path}"


def _walk_process_node(
    raw_node: Any,
    name: str,
    records_by_pid: dict[int, Any],
) -> None:
    node = _mapping(raw_node, name)
    try:
        pid_raw = node["pid"]
        parent_raw = node["ppid"]
        resources_raw = node["resources"]
        children_raw = node["children"]
    except KeyError as error:
        raise ValueError(f"{name} is missing {error.args[0]}") from None

    pid = _integer(pid_raw, f"{name}.pid", positive=True)
    parent_pid = _integer(parent_raw, f"{name}.ppid")
    cpu_percent, resident_bytes, physical_footprint_bytes = _resource_fields(
        resources_raw, f"{name}.resources"
    )
    record = ProcessRecord(
        pid=pid,
        parent_pid=parent_pid,
        command=_process_command(node, name),
        cpu_percent=cpu_percent,
        resident_bytes=resident_bytes,
        physical_footprint_bytes=physical_footprint_bytes,
    )
    previous = records_by_pid.get(pid)
    if previous is not None and previous != record:
        raise ValueError(f"conflicting records for PID {pid}")
    records_by_pid[pid] = record

    children = _array(children_raw, f"{name}.children")
    for index, child in enumerate(children):
        _walk_process_node(child, f"{name}.children[{index}]", records_by_pid)


def _walk_topology_node(
    raw_node: Any,
    name: str,
    *,
    node_kind: str,
    records_by_pid: dict[int, Any],
    app_pid_candidates: set[int],
    surface_root_pids: set[int],
    webkit_root_pids: set[int],
) -> None:
    node = _mapping(raw_node, name)

    if node_kind == "windows":
        app_pids = _pid_array(
            node.get("app_process_pids", []), f"{name}.app_process_pids"
        )
        app_pid_candidates.update(app_pids)
    elif node_kind == "surfaces":
        roots = _pid_array(node.get("root_pids", []), f"{name}.root_pids")
        surface_root_pids.update(roots)
    elif node_kind == "webviews":
        roots = _pid_array(node.get("root_pids", []), f"{name}.root_pids")
        webkit_root_pids.update(roots)

    if "processes" in node:
        processes = _array(node["processes"], f"{name}.processes")
        for index, process in enumerate(processes):
            _walk_process_node(
                process, f"{name}.processes[{index}]", records_by_pid
            )

    for child_kind in _TOPOLOGY_CHILDREN:
        if child_kind not in node:
            continue
        children = _array(node[child_kind], f"{name}.{child_kind}")
        for index, child in enumerate(children):
            _walk_topology_node(
                child,
                f"{name}.{child_kind}[{index}]",
                node_kind=child_kind,
                records_by_pid=records_by_pid,
                app_pid_candidates=app_pid_candidates,
                surface_root_pids=surface_root_pids,
                webkit_root_pids=webkit_root_pids,
            )


def _authoritative_totals(totals_raw: Any) -> tuple[Any, Any]:
    totals = _mapping(totals_raw, "payload.totals")
    cpu_percent, resident_bytes, physical_footprint_bytes = _resource_fields(
        totals, "payload.totals"
    )
    try:
        pids = _pid_array(totals["pids"], "payload.totals.pids")
        missing_pids = _pid_array(
            totals["missing_pids"], "payload.totals.missing_pids"
        )
        process_count = _integer(
            totals["process_count"], "payload.totals.process_count"
        )
    except KeyError as error:
        raise ValueError(f"payload.totals is missing {error.args[0]}") from None

    if process_count != len(pids):
        raise ValueError("payload.totals.process_count must equal the number of pids")
    if set(pids) & set(missing_pids):
        raise ValueError("payload.totals.pids and missing_pids must be disjoint")

    full_tree = ProcessSubtotal(
        pids=pids,
        cpu_percent=cpu_percent,
        resident_bytes=resident_bytes,
        physical_footprint_bytes=physical_footprint_bytes,
    )
    coverage = ProcessCoverage(
        discovered_pids=tuple(set(pids) | set(missing_pids)),
        sampled_pids=pids,
        missing_pids=missing_pids,
    )
    return full_tree, coverage


def _webkit_roles(
    records: tuple[Any, ...], webkit_root_pids: set[int]
) -> Mapping[str, tuple[int, ...]]:
    records_by_pid = {record.pid: record for record in records}
    role_pids: dict[str, set[int]] = {role: set() for role in _WEBKIT_ROLES}
    assigned_roles: dict[int, str] = {}

    for root_pid in sorted(webkit_root_pids):
        descendants = set(expand_descendants(records, (root_pid,)))
        classified = {
            role
            for pid in descendants
            if (role := classify_webkit_role(records_by_pid[pid])) is not None
        }
        if not classified:
            raise ValueError(f"cannot classify WebKit root PID {root_pid}")
        if len(classified) != 1:
            raise ValueError(f"ambiguous WebKit role for root PID {root_pid}")
        role = classified.pop()
        for pid in descendants:
            previous = assigned_roles.get(pid)
            if previous is not None and previous != role:
                raise ValueError(f"ambiguous WebKit role for PID {pid}")
            assigned_roles[pid] = role
            role_pids[role].add(pid)

    return MappingProxyType(
        {role: tuple(sorted(role_pids[role])) for role in _WEBKIT_ROLES}
    )


def parse_system_top_payload(
    payload: Mapping[str, Any], app_pid: int | None = None
) -> TopPayloadAccounting:
    """Normalize and account for one process-detailed ``system.top`` payload.

    ``app_pid`` overrides window-derived application PID selection, which is
    useful when a multi-window payload contains more than one application root.
    All other roots and records are always derived from the payload itself.
    """

    top = _mapping(payload, "payload")
    try:
        windows = _array(top["windows"], "payload.windows")
        totals_raw = top["totals"]
    except KeyError as error:
        raise ValueError(f"payload is missing {error.args[0]}") from None

    records_by_pid: dict[int, Any] = {}
    app_pid_candidates: set[int] = set()
    surface_root_pids: set[int] = set()
    webkit_root_pids: set[int] = set()
    for index, window in enumerate(windows):
        _walk_topology_node(
            window,
            f"payload.windows[{index}]",
            node_kind="windows",
            records_by_pid=records_by_pid,
            app_pid_candidates=app_pid_candidates,
            surface_root_pids=surface_root_pids,
            webkit_root_pids=webkit_root_pids,
        )

    if app_pid is None:
        if len(app_pid_candidates) != 1:
            raise ValueError(
                "payload must identify exactly one app PID in app_process_pids"
            )
        resolved_app_pid = next(iter(app_pid_candidates))
    else:
        resolved_app_pid = _integer(app_pid, "app_pid", positive=True)

    records = tuple(records_by_pid[pid] for pid in sorted(records_by_pid))
    if resolved_app_pid not in records_by_pid:
        raise ValueError(f"app PID {resolved_app_pid} has no process record")
    if not webkit_root_pids.issubset(surface_root_pids):
        raise ValueError("WebKit root PIDs must also be surface root PIDs")

    terminal_root_pids = surface_root_pids - webkit_root_pids
    report = analyze_process_tree(
        records,
        app_pid=resolved_app_pid,
        terminal_root_pids=terminal_root_pids,
        webkit_root_pids=webkit_root_pids,
    )
    role_pids = _webkit_roles(records, webkit_root_pids)
    full_tree, coverage = _authoritative_totals(totals_raw)

    return TopPayloadAccounting(
        app_pid=resolved_app_pid,
        terminal_root_pids=tuple(terminal_root_pids),
        webkit_root_pids=tuple(webkit_root_pids),
        webkit_role_pids=role_pids,
        parent_direct=report.parent_direct,
        terminal=report.terminal,
        webkit=report.webkit,
        full_tree=full_tree,
        coverage=coverage,
    )


__all__ = ["TopPayloadAccounting", "parse_system_top_payload"]
