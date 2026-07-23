"""Pure process-tree CPU accounting for performance benchmarks.

This module deliberately contains no process sampling.  Callers provide one
snapshot of process records and explicit roots, which keeps accounting
repeatable and platform independent.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import fsum, isfinite
from typing import Iterable, Literal


WebKitRole = Literal["content", "gpu", "network"]


@dataclass(frozen=True)
class ProcessRecord:
    """One process from a caller-supplied snapshot."""

    pid: int
    parent_pid: int
    command: str
    cpu_percent: float | None
    resident_bytes: int = 0
    physical_footprint_bytes: int = 0

    def __post_init__(self) -> None:
        for name, value in (("pid", self.pid), ("parent_pid", self.parent_pid)):
            if type(value) is not int or value < 0:
                raise ValueError(f"{name} must be a nonnegative integer")
        if type(self.command) is not str:
            raise ValueError("command must be a string")
        if self.cpu_percent is not None and (
            isinstance(self.cpu_percent, bool)
            or not isinstance(self.cpu_percent, (int, float))
            or not isfinite(self.cpu_percent)
            or self.cpu_percent < 0
        ):
            raise ValueError("cpu_percent must be None or a nonnegative finite number")
        for name, value in (
            ("resident_bytes", self.resident_bytes),
            ("physical_footprint_bytes", self.physical_footprint_bytes),
        ):
            if type(value) is not int or value < 0:
                raise ValueError(f"{name} must be a nonnegative integer")

    def to_dict(self) -> dict[str, int | str | float | None]:
        return {
            "pid": self.pid,
            "parent_pid": self.parent_pid,
            "command": self.command,
            "cpu_percent": self.cpu_percent,
            "resident_bytes": self.resident_bytes,
            "physical_footprint_bytes": self.physical_footprint_bytes,
        }


@dataclass(frozen=True)
class ProcessSubtotal:
    """Resource subtotal for a unique, deterministic collection of process IDs."""

    pids: tuple[int, ...]
    cpu_percent: float
    resident_bytes: int = 0
    physical_footprint_bytes: int = 0

    def __post_init__(self) -> None:
        object.__setattr__(self, "pids", tuple(sorted(set(self.pids))))

    def to_dict(self) -> dict[str, list[int] | float | int]:
        return {
            "pids": list(self.pids),
            "cpu_percent": self.cpu_percent,
            "resident_bytes": self.resident_bytes,
            "physical_footprint_bytes": self.physical_footprint_bytes,
        }


@dataclass(frozen=True)
class ProcessCoverage:
    """Sampling coverage for every process discovered in the app tree."""

    discovered_pids: tuple[int, ...]
    sampled_pids: tuple[int, ...]
    missing_pids: tuple[int, ...]

    def __post_init__(self) -> None:
        discovered = tuple(sorted(set(self.discovered_pids)))
        sampled = tuple(sorted(set(self.sampled_pids)))
        missing = tuple(sorted(set(self.missing_pids)))

        discovered_set = set(discovered)
        sampled_set = set(sampled)
        missing_set = set(missing)
        if sampled_set & missing_set:
            raise ValueError("sampled and missing process IDs must be disjoint")
        if sampled_set | missing_set != discovered_set:
            raise ValueError(
                "sampled and missing process IDs must partition discovered IDs"
            )

        object.__setattr__(self, "discovered_pids", discovered)
        object.__setattr__(self, "sampled_pids", sampled)
        object.__setattr__(self, "missing_pids", missing)

    @property
    def discovered_count(self) -> int:
        return len(self.discovered_pids)

    @property
    def sampled_count(self) -> int:
        return len(self.sampled_pids)

    @property
    def missing_count(self) -> int:
        return len(self.missing_pids)

    def to_dict(self) -> dict[str, list[int] | int]:
        return {
            "discovered_pids": list(self.discovered_pids),
            "sampled_pids": list(self.sampled_pids),
            "missing_pids": list(self.missing_pids),
            "discovered_count": self.discovered_count,
            "sampled_count": self.sampled_count,
            "missing_count": self.missing_count,
        }


@dataclass(frozen=True)
class ProcessTreeReport:
    """Independent category subtotals and the unique app-tree aggregate."""

    parent_direct: ProcessSubtotal
    terminal: ProcessSubtotal
    webkit: ProcessSubtotal
    full_tree: ProcessSubtotal
    coverage: ProcessCoverage

    def to_dict(self) -> dict[str, dict[str, object]]:
        return {
            "parent_direct": self.parent_direct.to_dict(),
            "terminal": self.terminal.to_dict(),
            "webkit": self.webkit.to_dict(),
            "full_tree": self.full_tree.to_dict(),
            "coverage": self.coverage.to_dict(),
        }


def classify_webkit_role(record: ProcessRecord) -> WebKitRole | None:
    """Classify a known WebKit service role from its command text."""

    command = record.command.casefold()
    if "webkit.networking" in command or "networkprocess" in command:
        return "network"
    if "webkit.gpu" in command or "gpuprocess" in command:
        return "gpu"
    if "webkit.webcontent" in command or "webcontentprocess" in command:
        return "content"
    return None


def _index_records(
    records: Iterable[ProcessRecord],
) -> tuple[dict[int, ProcessRecord], dict[int, set[int]]]:
    records_by_pid: dict[int, ProcessRecord] = {}
    children_by_parent: dict[int, set[int]] = {}

    for record in records:
        previous = records_by_pid.get(record.pid)
        if previous is not None:
            if previous != record:
                raise ValueError(f"conflicting records for PID {record.pid}")
            continue
        records_by_pid[record.pid] = record
        children_by_parent.setdefault(record.parent_pid, set()).add(record.pid)

    return records_by_pid, children_by_parent


def _expand_from_roots(
    records_by_pid: dict[int, ProcessRecord],
    children_by_parent: dict[int, set[int]],
    root_pids: Iterable[int],
) -> frozenset[int]:
    """Return recorded roots and all recorded transitive descendants."""

    pending = list(set(root_pids))
    visited: set[int] = set()
    expanded: set[int] = set()

    while pending:
        pid = pending.pop()
        if pid in visited:
            continue
        visited.add(pid)
        if pid in records_by_pid:
            expanded.add(pid)
        pending.extend(children_by_parent.get(pid, ()))

    return frozenset(expanded)


def expand_descendants(
    records: Iterable[ProcessRecord], root_pids: Iterable[int]
) -> frozenset[int]:
    """Expand roots transitively, returning only PIDs present in ``records``.

    Roots are included when they have a record.  Descendants can still be
    discovered beneath a root whose own sample is absent.
    """

    records_by_pid, children_by_parent = _index_records(records)
    return _expand_from_roots(records_by_pid, children_by_parent, root_pids)


def _subtotal(
    records_by_pid: dict[int, ProcessRecord], pids: Iterable[int]
) -> ProcessSubtotal:
    unique_pids = tuple(sorted(set(pids) & records_by_pid.keys()))
    unique_records = tuple(records_by_pid[pid] for pid in unique_pids)
    return ProcessSubtotal(
        pids=unique_pids,
        cpu_percent=fsum(record.cpu_percent or 0.0 for record in unique_records),
        resident_bytes=sum(record.resident_bytes for record in unique_records),
        physical_footprint_bytes=sum(
            record.physical_footprint_bytes for record in unique_records
        ),
    )


def analyze_process_tree(
    records: Iterable[ProcessRecord],
    *,
    app_pid: int,
    terminal_root_pids: Iterable[int],
    webkit_root_pids: Iterable[int],
) -> ProcessTreeReport:
    """Account for one app process tree without double-counting any subtotal.

    Terminal and WebKit categories remain independent and may overlap.  Their
    expanded roots are intersected with the app tree so unrelated supplied
    roots cannot enter the report.  The full-tree subtotal is calculated
    directly from its unique PID set rather than by adding category totals.
    """

    records_by_pid, children_by_parent = _index_records(records)
    full_tree_pids = _expand_from_roots(
        records_by_pid, children_by_parent, {app_pid}
    )
    terminal_pids = _expand_from_roots(
        records_by_pid, children_by_parent, terminal_root_pids
    ) & full_tree_pids
    webkit_pids = _expand_from_roots(
        records_by_pid, children_by_parent, webkit_root_pids
    ) & full_tree_pids
    parent_pids = {app_pid} & full_tree_pids

    sampled_pids = {
        pid
        for pid in full_tree_pids
        if records_by_pid[pid].cpu_percent is not None
    }
    missing_pids = set(full_tree_pids) - sampled_pids
    coverage = ProcessCoverage(
        discovered_pids=tuple(full_tree_pids),
        sampled_pids=tuple(sampled_pids),
        missing_pids=tuple(missing_pids),
    )

    return ProcessTreeReport(
        parent_direct=_subtotal(records_by_pid, parent_pids),
        terminal=_subtotal(records_by_pid, terminal_pids),
        webkit=_subtotal(records_by_pid, webkit_pids),
        full_tree=_subtotal(records_by_pid, full_tree_pids),
        coverage=coverage,
    )


__all__ = [
    "ProcessCoverage",
    "ProcessRecord",
    "ProcessSubtotal",
    "ProcessTreeReport",
    "WebKitRole",
    "analyze_process_tree",
    "classify_webkit_role",
    "expand_descendants",
]
