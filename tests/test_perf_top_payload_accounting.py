#!/usr/bin/env python3
"""Behavioral contracts for accounting directly from ``system.top`` payloads."""

from __future__ import annotations

from copy import deepcopy
import importlib.util
import sys
from pathlib import Path
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf_top_payload.py"
spec = importlib.util.spec_from_file_location("perf_top_payload", SCRIPT)
assert spec is not None
perf_top_payload = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = perf_top_payload
spec.loader.exec_module(perf_top_payload)


FULL_PIDS = (100, 200, 201, 300, 301, 400, 401, 500, 501)
TERMINAL_PIDS = (200, 201, 300, 301, 400, 401, 500, 501)
WEBKIT_PIDS = (300, 301, 400, 401, 500, 501)
MISSING_PID = 999


def _field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value[name]
    return getattr(value, name)


def _summary(
    pids: tuple[int, ...],
    *,
    cpu_percent: float,
    resident_bytes: int,
    physical_footprint_bytes: int,
    missing_pids: tuple[int, ...] = (),
) -> dict[str, Any]:
    return {
        "cpu_percent": cpu_percent,
        # ``system.top`` calls physical footprint ``memory_bytes``.
        "memory_bytes": physical_footprint_bytes,
        "resident_bytes": resident_bytes,
        "process_count": len(pids),
        "pids": list(pids),
        "missing_pids": list(missing_pids),
    }


def _process(
    pid: int,
    ppid: int,
    name: str,
    path: str,
    *,
    cpu_percent: float,
    resident_bytes: int,
    physical_footprint_bytes: int,
    children: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "pid": pid,
        "ppid": ppid,
        "name": name,
        "path": path,
        "resources": _summary(
            (pid,),
            cpu_percent=cpu_percent,
            resident_bytes=resident_bytes,
            physical_footprint_bytes=physical_footprint_bytes,
        ),
        "children": children or [],
    }


def _webkit_content_tree() -> dict[str, Any]:
    return _process(
        300,
        201,
        "com.apple.WebKit.WebContent",
        "/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.WebContent",
        cpu_percent=3.0,
        resident_bytes=3_000,
        physical_footprint_bytes=30_000,
        children=[
            _process(
                301,
                300,
                "WebContent worker",
                "/System/Library/Frameworks/WebKit.framework/WebContentProcess",
                cpu_percent=3.1,
                resident_bytes=3_100,
                physical_footprint_bytes=31_000,
            )
        ],
    )


def _webkit_gpu_tree() -> dict[str, Any]:
    return _process(
        400,
        201,
        "com.apple.WebKit.GPU",
        "/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.GPU",
        cpu_percent=4.0,
        resident_bytes=4_000,
        physical_footprint_bytes=40_000,
        children=[
            _process(
                401,
                400,
                "GPUProcess worker",
                "/System/Library/Frameworks/WebKit.framework/GPUProcess",
                cpu_percent=4.1,
                resident_bytes=4_100,
                physical_footprint_bytes=41_000,
            )
        ],
    )


def _webkit_network_tree() -> dict[str, Any]:
    return _process(
        500,
        201,
        "com.apple.WebKit.Networking",
        "/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.Networking",
        cpu_percent=5.0,
        resident_bytes=5_000,
        physical_footprint_bytes=50_000,
        children=[
            _process(
                501,
                500,
                "NetworkProcess worker",
                "/System/Library/Frameworks/WebKit.framework/NetworkProcess",
                cpu_percent=5.1,
                resident_bytes=5_100,
                physical_footprint_bytes=51_000,
            )
        ],
    )


def _terminal_tree() -> dict[str, Any]:
    return _process(
        200,
        100,
        "cmux terminal host",
        "/Applications/cmux.app/Contents/MacOS/cmux",
        cpu_percent=2.0,
        resident_bytes=2_000,
        physical_footprint_bytes=20_000,
        children=[
            _process(
                201,
                200,
                "zsh",
                "/bin/zsh",
                cpu_percent=2.1,
                resident_bytes=2_100,
                physical_footprint_bytes=21_000,
                children=[
                    _webkit_content_tree(),
                    _webkit_gpu_tree(),
                    _webkit_network_tree(),
                ],
            )
        ],
    )


def _app_tree() -> dict[str, Any]:
    return _process(
        100,
        1,
        "cmux",
        "/Applications/cmux.app/Contents/MacOS/cmux",
        cpu_percent=1.0,
        resident_bytes=1_000,
        physical_footprint_bytes=10_000,
        children=[_terminal_tree()],
    )


def _payload() -> dict[str, Any]:
    """Return one realistic payload with intentional process-tree repetition."""

    terminal_summary = _summary(
        TERMINAL_PIDS,
        cpu_percent=28.4,
        resident_bytes=28_400,
        physical_footprint_bytes=284_000,
    )
    content_summary = _summary(
        (300, 301),
        cpu_percent=6.1,
        resident_bytes=6_100,
        physical_footprint_bytes=61_000,
    )
    gpu_summary = _summary(
        (400, 401),
        cpu_percent=8.1,
        resident_bytes=8_100,
        physical_footprint_bytes=81_000,
    )
    network_summary = _summary(
        (500, 501),
        cpu_percent=10.1,
        resident_bytes=10_100,
        physical_footprint_bytes=101_000,
    )
    totals = _summary(
        FULL_PIDS,
        cpu_percent=29.4,
        resident_bytes=29_400,
        physical_footprint_bytes=294_000,
        missing_pids=(MISSING_PID,),
    )

    surface = {
        "root_pids": [200, 300, 400, 500],
        "resources": deepcopy(terminal_summary),
        "processes": [_terminal_tree()],
        "webviews": [
            {
                "pid": 300,
                "root_pids": [300],
                "resources": content_summary,
                "processes": [_webkit_content_tree()],
            },
            {
                "pid": 400,
                "root_pids": [400],
                "resources": gpu_summary,
                "processes": [_webkit_gpu_tree()],
            },
            {
                "pid": 500,
                "root_pids": [500],
                "resources": network_summary,
                "processes": [_webkit_network_tree()],
            },
        ],
    }
    pane = {
        "resources": deepcopy(terminal_summary),
        "surfaces": [surface],
    }
    workspace = {
        "resources": deepcopy(terminal_summary),
        "panes": [pane],
    }
    window = {
        "app_process_pids": [100],
        "resources": deepcopy(totals),
        "processes": [_app_tree()],
        "workspaces": [workspace],
    }
    return {"windows": [window], "totals": totals}


def _pid_set(value: Any) -> set[int]:
    return set(_field(value, "pids"))


def _assert_resources(
    subtotal: Any,
    *,
    pids: set[int],
    cpu_percent: float,
    resident_bytes: int,
    physical_footprint_bytes: int,
) -> None:
    subtotal_pids = _field(subtotal, "pids")
    assert set(subtotal_pids) == pids
    assert len(subtotal_pids) == len(set(subtotal_pids))
    assert _field(subtotal, "cpu_percent") == pytest.approx(cpu_percent)
    assert _field(subtotal, "resident_bytes") == resident_bytes
    assert _field(subtotal, "physical_footprint_bytes") == physical_footprint_bytes


def test_parser_deduplicates_process_trees_and_derives_roots_and_webkit_roles() -> None:
    accounting = perf_top_payload.parse_system_top_payload(_payload())

    assert _field(accounting, "app_pid") == 100
    assert set(_field(accounting, "terminal_root_pids")) == {200}
    assert set(_field(accounting, "webkit_root_pids")) == {300, 400, 500}

    roles = _field(accounting, "webkit_role_pids")
    assert set(roles["content"]) == {300, 301}
    assert set(roles["gpu"]) == {400, 401}
    assert set(roles["network"]) == {500, 501}

    # Every terminal/WebKit process occurs in multiple nested ``processes``
    # arrays. Exact unique sums prove identical records were deduplicated.
    _assert_resources(
        _field(accounting, "terminal"),
        pids=set(TERMINAL_PIDS),
        cpu_percent=28.4,
        resident_bytes=28_400,
        physical_footprint_bytes=284_000,
    )
    _assert_resources(
        _field(accounting, "webkit"),
        pids=set(WEBKIT_PIDS),
        cpu_percent=24.3,
        resident_bytes=24_300,
        physical_footprint_bytes=243_000,
    )


def test_parser_rejects_conflicting_records_for_a_repeated_pid() -> None:
    payload = _payload()
    repeated_terminal = payload["windows"][0]["workspaces"][0]["panes"][0][
        "surfaces"
    ][0]["processes"][0]
    repeated_terminal["resources"]["resident_bytes"] = 999_999

    with pytest.raises(ValueError, match=r"conflicting records for PID 200"):
        perf_top_payload.parse_system_top_payload(payload)


def test_parser_reports_independent_resources_and_authoritative_full_totals() -> None:
    payload = _payload()
    accounting = perf_top_payload.parse_system_top_payload(payload)

    parent = _field(accounting, "parent_direct")
    terminal = _field(accounting, "terminal")
    webkit = _field(accounting, "webkit")
    full_tree = _field(accounting, "full_tree")

    _assert_resources(
        parent,
        pids={100},
        cpu_percent=1.0,
        resident_bytes=1_000,
        physical_footprint_bytes=10_000,
    )
    _assert_resources(
        terminal,
        pids=set(TERMINAL_PIDS),
        cpu_percent=28.4,
        resident_bytes=28_400,
        physical_footprint_bytes=284_000,
    )
    _assert_resources(
        webkit,
        pids=set(WEBKIT_PIDS),
        cpu_percent=24.3,
        resident_bytes=24_300,
        physical_footprint_bytes=243_000,
    )
    _assert_resources(
        full_tree,
        pids=set(FULL_PIDS),
        cpu_percent=payload["totals"]["cpu_percent"],
        resident_bytes=payload["totals"]["resident_bytes"],
        physical_footprint_bytes=payload["totals"]["memory_bytes"],
    )

    # Terminal contains the WebKit roots in this payload. Adding independently
    # useful subtotals would count those PIDs twice; top-level totals are the
    # sole authoritative full-tree aggregate.
    assert _field(full_tree, "cpu_percent") != pytest.approx(
        sum(_field(group, "cpu_percent") for group in (parent, terminal, webkit))
    )
    assert _field(full_tree, "resident_bytes") != sum(
        _field(group, "resident_bytes") for group in (parent, terminal, webkit)
    )
    assert _field(full_tree, "physical_footprint_bytes") != sum(
        _field(group, "physical_footprint_bytes")
        for group in (parent, terminal, webkit)
    )

    full_pids = _field(full_tree, "pids")
    assert list(full_pids) == list(FULL_PIDS)
    assert len(full_pids) == len(set(full_pids))

    coverage = _field(accounting, "coverage")
    discovered = set(FULL_PIDS) | {MISSING_PID}
    sampled = set(FULL_PIDS)
    assert set(_field(coverage, "discovered_pids")) == discovered
    assert set(_field(coverage, "sampled_pids")) == sampled
    assert set(_field(coverage, "missing_pids")) == {MISSING_PID}
    assert _field(coverage, "discovered_count") == len(discovered)
    assert _field(coverage, "sampled_count") == len(sampled)
    assert _field(coverage, "missing_count") == 1


def test_parser_reports_disappeared_webkit_roots_as_missing_instead_of_aborting() -> None:
    payload = _payload()

    def remove_content_tree(process: dict[str, Any]) -> None:
        process["children"] = [
            child for child in process["children"] if child["pid"] != 300
        ]
        for child in process["children"]:
            remove_content_tree(child)

    remove_content_tree(payload["windows"][0]["processes"][0])
    surface = payload["windows"][0]["workspaces"][0]["panes"][0]["surfaces"][0]
    remove_content_tree(surface["processes"][0])
    surface["webviews"][0]["processes"] = []
    payload["totals"]["process_count"] = len(FULL_PIDS) - 2
    payload["totals"]["missing_pids"] = []

    accounting = perf_top_payload.parse_system_top_payload(payload)

    assert set(accounting.webkit_root_pids) == {300, 400, 500}
    assert accounting.webkit_role_pids["content"] == ()
    assert set(accounting.full_tree.pids) == set(FULL_PIDS) - {300, 301}
    assert set(accounting.coverage.discovered_pids) == set(FULL_PIDS)
    assert set(accounting.coverage.sampled_pids) == set(FULL_PIDS) - {300, 301}
    assert set(accounting.coverage.missing_pids) == {300, 301}
