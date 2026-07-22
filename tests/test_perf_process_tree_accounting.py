#!/usr/bin/env python3
"""Behavioral contracts for deterministic process-tree CPU accounting."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_process_tree.py"
spec = importlib.util.spec_from_file_location("perf_process_tree", SCRIPT)
assert spec is not None
perf_process_tree = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = perf_process_tree
spec.loader.exec_module(perf_process_tree)


def _field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value[name]
    return getattr(value, name)


def _records() -> list[Any]:
    record = perf_process_tree.ProcessRecord
    # Deliberately unordered: discovery must follow parent relationships rather
    # than rely on parents appearing before children in the input.
    return [
        record(pid=112, parent_pid=111, command="python benchmark.py", cpu_percent=30.0),
        record(pid=121, parent_pid=120, command="com.apple.WebKit.GPU", cpu_percent=50.0),
        record(pid=100, parent_pid=1, command="/Applications/cmux.app/Contents/MacOS/cmux", cpu_percent=10.0),
        record(pid=131, parent_pid=130, command="cmux helper worker", cpu_percent=70.0),
        record(pid=111, parent_pid=110, command="zsh", cpu_percent=None),
        record(pid=122, parent_pid=100, command="com.apple.WebKit.Networking", cpu_percent=None),
        record(pid=999, parent_pid=1, command="unrelated process", cpu_percent=999.0),
        record(pid=110, parent_pid=100, command="cmux terminal host", cpu_percent=20.0),
        record(pid=125, parent_pid=112, command="com.apple.WebKit.WebContent", cpu_percent=5.0),
        record(pid=130, parent_pid=100, command="cmux helper", cpu_percent=60.0),
        record(pid=120, parent_pid=100, command="com.apple.WebKit.WebContent", cpu_percent=40.0),
    ]


def _report(records: list[Any] | None = None) -> Any:
    return perf_process_tree.analyze_process_tree(
        records if records is not None else _records(),
        app_pid=100,
        # 111 is already below 110. Supplying both proves overlapping roots do
        # not cause the shell or its descendants to be counted twice.
        terminal_root_pids={110, 111},
        # 121 is below 120, while 125 is also in the terminal tree. Both kinds
        # of overlap are intentional.
        webkit_root_pids={120, 121, 122, 125},
    )


def _pids(subtotal: Any) -> list[int] | set[int] | tuple[int, ...]:
    return _field(subtotal, "pids")


def _assert_unique_pids(subtotal: Any, expected: set[int]) -> None:
    pids = _pids(subtotal)
    assert set(pids) == expected
    assert len(pids) == len(set(pids))


def test_descendants_are_discovered_transitively_and_once_across_overlapping_roots() -> None:
    report = _report()

    _assert_unique_pids(_field(report, "terminal"), {110, 111, 112, 125})
    _assert_unique_pids(_field(report, "webkit"), {120, 121, 122, 125})
    _assert_unique_pids(
        _field(report, "full_tree"),
        {100, 110, 111, 112, 120, 121, 122, 125, 130, 131},
    )

    # These are several generations below their respective roots.
    assert 112 in _pids(_field(report, "terminal"))
    assert 131 in _pids(_field(report, "full_tree"))
    # A process may belong to two useful subtotals, but remains one member of
    # the unique full tree.
    assert 125 in _pids(_field(report, "terminal"))
    assert 125 in _pids(_field(report, "webkit"))


def test_webkit_process_roles_are_classified_from_command_text() -> None:
    record = perf_process_tree.ProcessRecord

    assert perf_process_tree.classify_webkit_role(
        record(
            pid=201,
            parent_pid=100,
            command=(
                "/System/Library/Frameworks/WebKit.framework/XPCServices/"
                "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
            ),
            cpu_percent=1.0,
        )
    ) == "content"
    assert perf_process_tree.classify_webkit_role(
        record(
            pid=202,
            parent_pid=100,
            command="/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.GPU",
            cpu_percent=2.0,
        )
    ) == "gpu"
    assert perf_process_tree.classify_webkit_role(
        record(
            pid=203,
            parent_pid=100,
            command="/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.Networking",
            cpu_percent=3.0,
        )
    ) == "network"


def test_report_has_independent_parent_terminal_webkit_and_unique_tree_totals() -> None:
    report = _report()
    parent = _field(report, "parent_direct")
    terminal = _field(report, "terminal")
    webkit = _field(report, "webkit")
    full_tree = _field(report, "full_tree")

    _assert_unique_pids(parent, {100})
    assert _field(parent, "cpu_percent") == 10.0
    assert _field(terminal, "cpu_percent") == 55.0
    assert _field(webkit, "cpu_percent") == 95.0
    # Assert the unique-tree aggregate independently. Summing the category
    # subtotals would double count PID 125 and the app is not a category root.
    assert _field(full_tree, "cpu_percent") == 285.0


def test_coverage_names_every_discovered_sampled_and_missing_pid() -> None:
    coverage = _field(_report(), "coverage")
    discovered = {100, 110, 111, 112, 120, 121, 122, 125, 130, 131}
    sampled = {100, 110, 112, 120, 121, 125, 130, 131}
    missing = {111, 122}

    assert set(_field(coverage, "discovered_pids")) == discovered
    assert set(_field(coverage, "sampled_pids")) == sampled
    assert set(_field(coverage, "missing_pids")) == missing
    assert _field(coverage, "discovered_count") == len(discovered)
    assert _field(coverage, "sampled_count") == len(sampled)
    assert _field(coverage, "missing_count") == len(missing)


def test_missing_samples_do_not_fabricate_cpu_usage() -> None:
    record = perf_process_tree.ProcessRecord
    report = perf_process_tree.analyze_process_tree(
        [
            record(pid=300, parent_pid=1, command="cmux", cpu_percent=None),
            record(pid=301, parent_pid=300, command="zsh", cpu_percent=None),
        ],
        app_pid=300,
        terminal_root_pids={301},
        webkit_root_pids=set(),
    )

    assert _field(_field(report, "parent_direct"), "cpu_percent") == 0.0
    assert _field(_field(report, "terminal"), "cpu_percent") == 0.0
    assert _field(_field(report, "full_tree"), "cpu_percent") == 0.0

    coverage = _field(report, "coverage")
    assert set(_field(coverage, "discovered_pids")) == {300, 301}
    assert set(_field(coverage, "sampled_pids")) == set()
    assert set(_field(coverage, "missing_pids")) == {300, 301}
    assert _field(coverage, "discovered_count") == 2
    assert _field(coverage, "sampled_count") == 0
    assert _field(coverage, "missing_count") == 2


def test_report_sums_unique_memory_in_every_independent_subtotal() -> None:
    record = perf_process_tree.ProcessRecord
    report = perf_process_tree.analyze_process_tree(
        [
            record(
                pid=600,
                parent_pid=1,
                command="cmux",
                cpu_percent=1.0,
                resident_bytes=100,
                physical_footprint_bytes=1_000,
            ),
            record(
                pid=610,
                parent_pid=600,
                command="cmux terminal host",
                cpu_percent=2.0,
                resident_bytes=200,
                physical_footprint_bytes=2_000,
            ),
            record(
                pid=611,
                parent_pid=610,
                command="com.apple.WebKit.WebContent",
                cpu_percent=3.0,
                resident_bytes=300,
                physical_footprint_bytes=3_000,
            ),
            record(
                pid=612,
                parent_pid=611,
                command="com.apple.WebKit.GPU",
                cpu_percent=4.0,
                resident_bytes=400,
                physical_footprint_bytes=4_000,
            ),
            record(
                pid=620,
                parent_pid=600,
                command="cmux helper outside named groups",
                cpu_percent=5.0,
                resident_bytes=500,
                physical_footprint_bytes=5_000,
            ),
        ],
        app_pid=600,
        terminal_root_pids={610},
        webkit_root_pids={611},
    )

    parent = _field(report, "parent_direct")
    terminal = _field(report, "terminal")
    webkit = _field(report, "webkit")
    full_tree = _field(report, "full_tree")

    _assert_unique_pids(parent, {600})
    assert _field(parent, "resident_bytes") == 100
    assert _field(parent, "physical_footprint_bytes") == 1_000

    _assert_unique_pids(terminal, {610, 611, 612})
    assert _field(terminal, "resident_bytes") == 900
    assert _field(terminal, "physical_footprint_bytes") == 9_000

    _assert_unique_pids(webkit, {611, 612})
    assert _field(webkit, "resident_bytes") == 700
    assert _field(webkit, "physical_footprint_bytes") == 7_000

    _assert_unique_pids(full_tree, {600, 610, 611, 612, 620})
    assert _field(full_tree, "resident_bytes") == 1_500
    assert _field(full_tree, "physical_footprint_bytes") == 15_000
