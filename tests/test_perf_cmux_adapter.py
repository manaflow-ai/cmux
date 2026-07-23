#!/usr/bin/env python3
"""Focused behavioral contracts for the tagged cmux runtime adapter."""

from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import re
import sys
import threading
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
SCRIPT = SCRIPTS / "perf_cmux_adapter.py"
spec = importlib.util.spec_from_file_location("perf_cmux_adapter", SCRIPT)
assert spec is not None and spec.loader is not None
adapter_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter_module
spec.loader.exec_module(adapter_module)

runtime_spec = importlib.util.spec_from_file_location(
    "perf_mixed_workload", SCRIPTS / "perf_mixed_workload.py"
)
assert runtime_spec is not None and runtime_spec.loader is not None
runtime = importlib.util.module_from_spec(runtime_spec)
sys.modules[runtime_spec.name] = runtime
runtime_spec.loader.exec_module(runtime)

SHA = "0123456789abcdef0123456789abcdef01234567"


def scenario(*, terminals: int = 2, browsers: int = 2, scrollback: int = 120) -> dict[str, Any]:
    return {
        "scenario_id": "mixed-test",
        "kind": "mixed" if terminals and browsers else ("terminal" if terminals else "browser"),
        "load": "light",
        "terminal_surfaces": terminals,
        "browser_surfaces": browsers,
        "aggregate_scrollback_chars": scrollback,
    }


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, duration: float) -> None:
        self.sleeps.append(duration)
        self.now += duration


class FakeRunner:
    """Stateful CmuxPerfRunner-shaped seam with no OS effects."""

    def __init__(self) -> None:
        self.events: list[Any] = []
        self.workspace = "workspace:9"
        self.workspaces = [self.workspace]
        self.pane = "pane:4"
        self.initial_terminal = "surface:initial"
        self.surfaces: list[dict[str, Any]] = [
            {"surface_id": self.initial_terminal, "type": "terminal", "title": "shell"}
        ]
        self.browser_state: dict[str, dict[str, str]] = {}
        self.snapshot_payload: dict[str, Any] | None = None
        self.top_payloads: list[dict[str, Any]] = []
        self.terminal_markers: dict[str, str] = {}
        self.stopped = False
        self.render_stats_calls = 0
        self.screenshot_path: str | None = None

    def check_paths(self) -> None:
        self.events.append("check_paths")

    def clean_persisted_state(self) -> None:
        self.events.append("clean_persisted_state")

    def launch(self, label: str) -> float:
        self.events.append(("launch", label))
        self.stopped = False
        return 12.5

    def stop_app(self) -> None:
        self.events.append("stop_app")
        self.stopped = True

    def cleanup_owned(self) -> dict[str, Any]:
        self.events.append("cleanup_owned")
        return {"owned_state_removed": True, "stopped": self.stopped}

    def json_cli(self, args: list[str], timeout: float = 60) -> dict[str, Any]:
        self.events.append(("json_cli", tuple(args), timeout))
        if args[0] == "list-workspaces":
            return {
                "workspaces": [
                    {"workspace_id": workspace} for workspace in self.workspaces
                ]
            }
        if args[:2] == ["workspace", "create"]:
            return {"workspace_id": self.workspace}
        if args[0] == "list-panes":
            return {
                "panes": [
                    {
                        "pane_id": self.pane,
                        "workspace_id": self.workspace,
                        "surface_ids": [surface["surface_id"] for surface in self.surfaces],
                    }
                ]
            }
        if args[0] == "list-pane-surfaces":
            return {
                "workspace_id": self.workspace,
                "pane_id": self.pane,
                "surfaces": deepcopy(self.surfaces),
            }
        if args[0] == "new-surface":
            kind = args[args.index("--type") + 1]
            ref = f"surface:{len(self.surfaces) + 1}"
            item = {"surface_id": ref, "type": kind, "title": kind}
            self.surfaces.append(item)
            if kind == "browser":
                url = args[args.index("--url") + 1]
                self.browser_state[ref] = {"url": url, "title": "", "content_marker": ""}
            return {"surface_id": ref, "pane_id": self.pane, "workspace_id": self.workspace}
        raise AssertionError(f"unexpected JSON CLI call: {args}")

    def run_cli(
        self,
        args: list[str],
        input_text: str | None = None,
        timeout: float = 60,
        check: bool = True,
    ) -> str:
        self.events.append(("run_cli", tuple(args), input_text, timeout, check))
        if args[0] == "close-surface":
            surface = args[args.index("--surface") + 1]
            self.surfaces = [item for item in self.surfaces if item["surface_id"] != surface]
            self.browser_state.pop(surface, None)
        if args[0] == "send":
            surface = args[args.index("--surface") + 1]
            match = re.search(r"CMUX_PERF_FINAL_COUNT=\d+:[A-Za-z0-9-]+", args[-1])
            if match is not None:
                self.terminal_markers[surface] = match.group(0)
        if args[0] == "capture-pane":
            surface = args[args.index("--surface") + 1]
            return self.terminal_markers.get(surface, "")
        return "OK"

    def rpc(
        self, method: str, params: dict[str, Any] | None = None, timeout: float = 60
    ) -> dict[str, Any]:
        params = deepcopy(params or {})
        self.events.append(("rpc", method, params, timeout))
        if method == "debug.session_snapshot_seed_scrollback":
            chars = params["characters_per_terminal"]
            terminals = sum(item["type"] == "terminal" for item in self.surfaces)
            return {
                "characters_per_terminal": chars,
                "workspaces": 1,
                "terminals": terminals,
                "scrollback_chars": chars * terminals,
            }
        if method == "debug.session_snapshot_benchmark":
            assert self.snapshot_payload is not None
            return deepcopy(self.snapshot_payload)
        if method == "debug.terminal.render_stats":
            self.render_stats_calls += 1
            return {
                "stats": {
                    "drawCount": 10,
                    "presentCount": 20,
                    "metalDrawableCount": 20 + 5 * self.render_stats_calls,
                }
            }
        if method == "system.top":
            if not self.top_payloads:
                raise AssertionError("missing fake top payload")
            return deepcopy(self.top_payloads.pop(0))
        if method == "browser.wait":
            return {"load_state": params["load_state"], "complete": True}
        if method == "browser.url.get":
            return {"url": self.browser_state[params["surface_id"]]["url"]}
        if method == "browser.get.title":
            return {"title": self.browser_state[params["surface_id"]]["title"]}
        if method == "browser.eval":
            return {"value": self.browser_state[params["surface_id"]]["content_marker"]}
        if method in {"browser.focus_webview", "browser.reload", "browser.snapshot"}:
            return {"ok": True, "surface_id": params["surface_id"]}
        if method == "browser.screenshot":
            result = {
                "surface_id": params["surface_id"],
                "png_base64": "iVBORw0KGgo=",
            }
            if self.screenshot_path is not None:
                result["path"] = self.screenshot_path
            return result
        if method == "surface.create":
            ref = "surface:temporary"
            self.surfaces.append({"surface_id": ref, "type": "browser", "title": "temporary"})
            return {"surface_id": ref, "pane_id": self.pane}
        if method == "surface.close":
            ref = params["surface_id"]
            self.surfaces = [item for item in self.surfaces if item["surface_id"] != ref]
            self.browser_state.pop(ref, None)
            return {"ok": True}
        raise AssertionError(f"unexpected RPC call: {method} {params}")

def config(tmp_path: Path, **overrides: Any) -> Any:
    values = {
        "sha": SHA,
        "tag": "cpu-adapter-test",
        "app_path": "/owned/cmux DEV cpu-adapter-test.app",
        "scenario": scenario(),
        "output_root": tmp_path / "owned-output",
        "warmup": False,
        "profile_enabled": False,
        "steady_duration_s": 1.0,
        "steady_interval_s": 0.5,
        "churn_duration_s": 1.0,
        "churn_interval_s": 0.5,
        "profile_duration_s": 1.0,
    }
    values.update(overrides)
    return adapter_module.AdapterConfig(**values)


def plan_for(cfg: Any) -> Any:
    return runtime.build_browser_fixture_plan(
        scenario_id=cfg.scenario["scenario_id"],
        terminal_count=cfg.scenario["terminal_surfaces"],
        browser_count=cfg.scenario["browser_surfaces"],
        owned_root=cfg.output_root,
    )


def top_payload() -> dict[str, Any]:
    def resources(pids: list[int], cpu: float) -> dict[str, Any]:
        return {
            "cpu_percent": cpu,
            "memory_bytes": len(pids) * 1000,
            "resident_bytes": len(pids) * 100,
            "process_count": len(pids),
            "pids": pids,
            "missing_pids": [],
        }

    webkit = {
        "pid": 300,
        "ppid": 200,
        "name": "com.apple.WebKit.WebContent",
        "path": "/System/WebKit/WebContent",
        "resources": resources([300], 3.0),
        "children": [],
    }
    terminal = {
        "pid": 200,
        "ppid": 100,
        "name": "zsh",
        "path": "/bin/zsh",
        "resources": resources([200], 2.0),
        "children": [deepcopy(webkit)],
    }
    app = {
        "pid": 100,
        "ppid": 1,
        "name": "cmux",
        "path": "/owned/cmux",
        "resources": resources([100], 1.0),
        "children": [deepcopy(terminal)],
    }
    surface = {
        "root_pids": [200, 300],
        "resources": resources([200, 300], 5.0),
        "processes": [deepcopy(terminal)],
        "webviews": [
            {
                "pid": 300,
                "root_pids": [300],
                "resources": resources([300], 3.0),
                "processes": [deepcopy(webkit)],
            }
        ],
    }
    return {
        "windows": [
            {
                "app_process_pids": [100],
                "resources": resources([100, 200, 300], 6.0),
                "processes": [app],
                "workspaces": [
                    {
                        "resources": resources([200, 300], 5.0),
                        "panes": [
                            {
                                "resources": resources([200, 300], 5.0),
                                "surfaces": [surface],
                            }
                        ],
                    }
                ],
            }
        ],
        "totals": resources([100, 200, 300], 6.0),
    }


def prepare_fixture(adapter: Any, runner: FakeRunner, cfg: Any) -> Any:
    plan = plan_for(cfg)
    adapter.create_fixture(plan)
    for planned, actual in zip(plan.browser_surfaces, adapter._browser_actual_ids.values(), strict=True):
        runner.browser_state[actual].update(
            url=planned.url, title=planned.title, content_marker=planned.content_marker
        )
    return plan


def test_config_is_immutable_and_rejects_non_exact_identity_and_unbounded_times(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    with pytest.raises(Exception):
        cfg.tag = "changed"
    with pytest.raises(ValueError, match="40 hexadecimal"):
        config(tmp_path, sha="abc")
    with pytest.raises(ValueError, match="bounded"):
        config(tmp_path, churn_duration_s=301.0)
    assert cfg.scenario["terminal_surfaces"] == 2


def test_fixture_uses_one_workspace_and_pane_exact_local_identity_and_scrollback(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    plan = prepare_fixture(adapter, runner, cfg)

    observation = adapter.observe_fixture()
    assert observation["shape"] == {"terminal_surfaces": 2, "browser_surfaces": 2}
    assert observation["browsers"] == [
        {
            "surface_id": item.surface_id,
            "url": item.url,
            "title": item.title,
            "content_marker": item.content_marker,
        }
        for item in plan.browser_surfaces
    ]
    assert all(item.url.startswith("file://") for item in plan.browser_surfaces)
    workspace_calls = [
        event
        for event in runner.events
        if event[0] == "json_cli" and event[1][:2] == ("workspace", "create")
    ]
    assert workspace_calls == []
    assert adapter.raw_details["fixture"]["workspace_id"] == runner.workspace
    pane_calls = [event for event in runner.events if event[0] == "json_cli" and event[1][0] == "new-surface"]
    assert pane_calls and all("--pane" in event[1] and event[1][event[1].index("--pane") + 1] == runner.pane for event in pane_calls)
    seed = next(event for event in runner.events if event[:2] == ("rpc", "debug.session_snapshot_seed_scrollback"))
    assert seed[2] == {"characters_per_terminal": 60}
    waits = [event for event in runner.events if event[:2] == ("rpc", "browser.wait")]
    assert {event[2]["surface_id"] for event in waits} == set(adapter._browser_actual_ids.values())
    assert all(event[2]["load_state"] == "complete" and event[2]["timeout_ms"] == 60_000 for event in waits)
    assert adapter.raw_details["fixture"]["planned_to_actual"] == {
        "terminal-001": "surface:initial",
        "terminal-002": "surface:2",
        "browser-mixed-test-001": "surface:3",
        "browser-mixed-test-002": "surface:4",
    }
    json.dumps(adapter.raw_details)

def test_fixture_rejects_nonunique_clean_startup_workspace(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    runner.workspaces.append("workspace:unexpected")
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())

    with pytest.raises(ValueError, match="exactly one clean startup workspace"):
        prepare_fixture(adapter, runner, cfg)

    assert not any(
        event[0] == "json_cli" and event[1][0] == "new-surface"
        for event in runner.events
    )


def test_browser_only_closes_initial_terminal_and_does_not_seed_scrollback(tmp_path: Path) -> None:
    cfg = config(tmp_path, scenario=scenario(terminals=0, browsers=2, scrollback=0))
    runner = FakeRunner()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    prepare_fixture(adapter, runner, cfg)

    close = next(event for event in runner.events if event[0] == "run_cli" and event[1][0] == "close-surface")
    assert runner.initial_terminal in close[1]
    assert not any(event[:2] == ("rpc", "debug.session_snapshot_seed_scrollback") for event in runner.events)
    assert [item["type"] for item in runner.surfaces] == ["browser", "browser"]


def test_steady_primes_system_top_and_parser_deduplicates_repeated_processes(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload(), top_payload()]
    clock = FakeClock()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=clock)

    samples = adapter.sample_steady()

    top_calls = [event for event in runner.events if event[:2] == ("rpc", "system.top")]
    assert len(top_calls) == 3  # one prime plus two retained interval samples
    assert all(event[2] == {"all_windows": True, "include_processes": True} for event in top_calls)
    assert clock.sleeps == [0.5, 0.5]
    assert len(samples) == 2
    assert samples[0]["process_attribution"]["full_tree"]["cpu_percent"] == 6.0
    assert samples[0]["process_attribution"]["webkit"]["cpu_percent"] == 3.0
    assert samples[0]["process_attribution"]["terminal"]["pids"] == [200, 300]
    assert samples[0]["coverage"] == {
        "discovered_count": 3,
        "sampled_count": 3,
        "missing_count": 0,
        "discovered_pids": [100, 200, 300],
        "sampled_pids": [100, 200, 300],
        "missing_pids": [],
    }


def test_churn_calls_every_planned_surface_and_records_real_metrics(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload()]
    clock = FakeClock()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=clock)
    plan = prepare_fixture(adapter, runner, cfg)

    result = adapter.run_churn([])

    terminal_sends = [event for event in runner.events if event[0] == "run_cli" and event[1][0] == "send"]
    assert {event[1][event[1].index("--surface") + 1] for event in terminal_sends} == set(adapter._terminal_actual_ids.values())
    assert all("\\033[" in event[1][-1] and "CMUX_PERF_FINAL_COUNT=" in event[1][-1] for event in terminal_sends)
    assert all("time.sleep(" in event[1][-1] for event in terminal_sends)
    capture_calls = [
        event
        for event in runner.events
        if event[0] == "run_cli" and event[1][0] == "capture-pane"
    ]
    assert {
        event[1][event[1].index("--surface") + 1] for event in capture_calls
    } == set(adapter._terminal_actual_ids.values())
    for method in (
        "browser.focus_webview",
        "browser.reload",
        "browser.snapshot",
        "browser.screenshot",
    ):
        actual = {
            event[2]["surface_id"]
            for event in runner.events
            if event[:2] == ("rpc", method)
        }
        assert actual == set(adapter._browser_actual_ids.values())
    screenshot_calls = [
        event for event in runner.events if event[:2] == ("rpc", "browser.screenshot")
    ]
    assert len(screenshot_calls) == len(adapter._browser_actual_ids)
    assert any(event[:2] == ("rpc", "surface.create") for event in runner.events)
    assert any(event[:2] == ("rpc", "surface.close") for event in runner.events)
    render_calls = [event for event in runner.events if event[:2] == ("rpc", "debug.terminal.render_stats")]
    assert len(render_calls) == 2 * len(adapter._terminal_actual_ids)
    assert {event[2]["surface_id"] for event in render_calls} == set(adapter._terminal_actual_ids.values())
    assert result["latencies_ms"] and all(set(item) == {"label", "surface_id", "milliseconds"} for item in result["latencies_ms"])
    assert result["throughput_ops_per_second"]["terminal"] > 0
    assert result["throughput_ops_per_second"]["browser"] > 0
    assert {item["measurement"] for item in result["render_observations"]} == {
        "debug.terminal.render_stats.metalDrawableCount_render_proxy",
        "completed_browser_screenshot_render_proxy",
    }
    assert all(
        item["render_delta"] > 0 for item in result["render_observations"]
    )
    assert {
        item["render_delta"]
        for item in result["render_observations"]
        if item["surface_kind"] == "browser"
    } == {1}
    browser_evidence = [
        item
        for item in adapter.raw_details["churn"]["surface_evidence"]
        if item["surface_kind"] == "browser"
    ]
    assert all("png_base64" not in item["screenshot"] for item in browser_evidence)
    assert {item["screenshot"]["png_base64_length"] for item in browser_evidence} == {12}
    assert all(
        "present_rate" not in item for item in result["render_observations"]
    )
    assert result["failures"] == []


@pytest.mark.parametrize(
    ("terminals", "browsers", "forbidden_prefixes"),
    [(0, 2, ("terminal_",)), (2, 0, ("browser_",))],
)
def test_extract_metrics_omits_absent_kind_metrics(
    tmp_path: Path, terminals: int, browsers: int, forbidden_prefixes: tuple[str, ...]
) -> None:
    result = {
        "steady_samples": [
            {
                "process_attribution": {
                    "parent_direct": {"cpu_percent": 1.0},
                    "terminal": {"cpu_percent": 2.0},
                    "webkit": {"cpu_percent": 3.0},
                    "full_tree": {"cpu_percent": 4.0},
                }
            }
        ],
        "churn_samples": [
            {
                "process_attribution": {
                    "parent_direct": {"cpu_percent": 5.0},
                    "terminal": {"cpu_percent": 6.0},
                    "webkit": {"cpu_percent": 7.0},
                    "full_tree": {"cpu_percent": 8.0},
                }
            }
        ],
        "latencies_ms": [{"label": "browser_reload", "surface_id": "b", "milliseconds": 9.0}],
        "throughput_ops_per_second": {"terminal": 10.0, "browser": 11.0},
        "render_observations": [
            {"surface_kind": "terminal", "render_rate": 12.0},
            {"surface_kind": "browser", "render_rate": 13.0},
        ],
    }
    details = {"scenario": scenario(terminals=terminals, browsers=browsers, scrollback=0)}
    metrics = adapter_module.extract_metrics(result, details)
    allowed = {
        "steady_parent_cpu_percent", "steady_full_tree_cpu_percent",
        "steady_terminal_cpu_percent", "steady_webkit_cpu_percent",
        "churn_parent_cpu_percent", "churn_full_tree_cpu_percent",
        "churn_terminal_cpu_percent", "churn_webkit_cpu_percent",
        "browser_latency_ms", "terminal_throughput_per_second",
        "browser_throughput_per_second", "terminal_render_rate", "browser_render_rate",
    }
    assert set(metrics) <= allowed
    assert not any(name.startswith(forbidden_prefixes) for name in metrics)
    if browsers == 0:
        assert "steady_webkit_cpu_percent" not in metrics
        assert "churn_webkit_cpu_percent" not in metrics


def test_snapshot_restore_relaunches_without_cleaning_and_strictly_verifies_shape_and_browser(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    plan = prepare_fixture(adapter, runner, cfg)
    expected = {
        "built": True,
        "include_scrollback": True,
        "persist": True,
        "saved": True,
        "elapsed_ms": 4.5,
        "build_ms": 3.0,
        "persist_ms": 1.5,
        "shape": {
            "windows": 1, "workspaces": 1, "panels": 4, "terminals": 2,
            "browsers": 2, "markdown": 0, "scrollback_chars": 120,
            "status_entries": 0, "log_entries": 0, "progress_entries": 0, "git_entries": 0,
        },
    }
    runner.snapshot_payload = deepcopy(expected)

    captured = adapter.snapshot()
    assert captured["elapsed_ms"] == 4.5
    before_restore = len(runner.events)
    adapter.restore(captured)
    restored_events = runner.events[before_restore:]

    assert restored_events[:2] == ["stop_app", ("launch", "restore")]
    assert "clean_persisted_state" not in restored_events
    assert adapter.observe_fixture()["browsers"][0]["content_marker"] == plan.browser_surfaces[0].content_marker
    runner.snapshot_payload["shape"]["browsers"] = 1
    with pytest.raises(ValueError, match="snapshot"):
        adapter.restore(captured)


def test_runtime_failure_still_stops_and_cleanup_removes_only_owned_state(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    runner.top_payloads = [top_payload(), top_payload(), top_payload()]
    runner.snapshot_payload = {
        "built": True, "include_scrollback": True, "persist": True, "saved": True,
        "shape": {"windows": 1, "workspaces": 1, "panels": 4, "terminals": 2, "browsers": 2,
                  "markdown": 0, "scrollback_chars": 120, "status_entries": 0, "log_entries": 0,
                  "progress_entries": 0, "git_entries": 0},
    }
    original_observe = adapter.observe_fixture
    calls = 0

    def fail_restored_observation() -> dict[str, Any]:
        nonlocal calls
        calls += 1
        value = original_observe()
        if calls == 2:
            value["browsers"][0]["title"] = "wrong"
        return value

    adapter.observe_fixture = fail_restored_observation
    with pytest.raises(ValueError):
        runtime.run_invocation(
            scenario_id="mixed-test", sha=SHA, order="AB", repetition=1,
            requested_shape={"terminal_surfaces": 2, "browser_surfaces": 2},
            owned_root=cfg.output_root, adapter=adapter,
        )
    assert runner.stopped is True
    assert runner.events[-2:] == ["stop_app", "cleanup_owned"]
    cleanup = adapter.raw_details["cleanup"]
    assert all(str(path).startswith(str(cfg.output_root)) or cfg.tag in str(path) for path in cleanup["owned_paths"])


def test_churn_rejects_missing_terminal_drawable_counter(tmp_path: Path) -> None:
    cfg = config(
        tmp_path,
        scenario=scenario(terminals=2, browsers=0, scrollback=120),
    )
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload()]
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    prepare_fixture(adapter, runner, cfg)
    original_rpc = runner.rpc

    def rpc_without_drawables(*args: Any, **kwargs: Any) -> dict[str, Any]:
        payload = original_rpc(*args, **kwargs)
        if args[0] == "debug.terminal.render_stats":
            payload["stats"].pop("metalDrawableCount")
        return payload

    runner.rpc = rpc_without_drawables

    with pytest.raises(ValueError, match="metalDrawableCount"):
        adapter.run_churn([])


def test_cleanup_never_unlinks_untrusted_screenshot_path(tmp_path: Path) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload()]
    untrusted_root = tmp_path / "outside" / "cmux-browser-screenshots"
    untrusted_root.mkdir(parents=True)
    untrusted_path = untrusted_root / "surface-untrusted.png"
    untrusted_path.write_bytes(b"not owned")
    runner.screenshot_path = str(untrusted_path)
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    prepare_fixture(adapter, runner, cfg)

    adapter.run_churn([])
    adapter.cleanup_owned()

    assert untrusted_path.read_bytes() == b"not owned"


def test_cleanup_unlinks_exact_owned_screenshot_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg = config(tmp_path)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload()]
    system_temp = tmp_path / "system-temp"
    monkeypatch.setattr(adapter_module.tempfile, "gettempdir", lambda: str(system_temp))
    screenshot_root = system_temp / "cmux-browser-screenshots"
    screenshot_root.mkdir(parents=True)
    screenshot_path = screenshot_root / "surface-owned.png"
    screenshot_path.write_bytes(b"owned")
    runner.screenshot_path = str(screenshot_path)
    adapter = adapter_module.CmuxRuntimeAdapter(cfg, runner=runner, clock=FakeClock())
    prepare_fixture(adapter, runner, cfg)

    adapter.run_churn([])
    cleanup = adapter.cleanup_owned()

    assert not screenshot_path.exists()
    assert str(screenshot_path) in cleanup["owned_paths"]


def test_enabled_profiles_overlap_churn_and_record_work_units(tmp_path: Path) -> None:
    cfg = config(tmp_path, profile_enabled=True)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload(), top_payload()]
    adapter = adapter_module.CmuxRuntimeAdapter(
        cfg, runner=runner, clock=FakeClock(), profiler=None
    )
    prepare_fixture(adapter, runner, cfg)
    profile_started = threading.Event()
    release_profiles = threading.Event()
    profile_calls: list[dict[str, Any]] = []

    def profiler(**kwargs: Any) -> dict[str, Any]:
        profile_calls.append(deepcopy(kwargs))
        profile_started.set()
        assert release_profiles.wait(timeout=1.0)
        Path(kwargs["path"]).write_text("overlapped", encoding="utf-8")
        return {"ok": True}

    adapter._profiler = profiler
    original_run_cli = runner.run_cli

    def run_cli_during_profile(*args: Any, **kwargs: Any) -> str:
        command = args[0]
        if command[0] == "send":
            assert profile_started.wait(timeout=1.0)
            release_profiles.set()
        return original_run_cli(*args, **kwargs)

    runner.run_cli = run_cli_during_profile
    result = adapter.run_churn([])

    assert result["failures"] == []
    assert len(profile_calls) == 2
    assert all(call["phase"] == "churn" for call in profile_calls)
    assert all(
        call["work_units"]
        == {
            "terminal_ansi_lines": 3_200,
            "browser_churn_rpc_operations": 14,
            "temporary_browser_open_close_operations": 2,
        }
        for call in profile_calls
    )
    assert all(Path(call["path"]).read_text(encoding="utf-8") == "overlapped" for call in profile_calls)


def test_profile_rejects_stale_output_not_recreated_by_current_sample(
    tmp_path: Path,
) -> None:
    cfg = config(tmp_path, profile_enabled=True)
    runner = FakeRunner()
    runner.top_payloads = [top_payload()]

    def profiler(**kwargs: Any) -> dict[str, Any]:
        return {
            "path": kwargs["path"],
            "returncode": 0,
            "stdout": "",
            "stderr": "",
        }

    adapter = adapter_module.CmuxRuntimeAdapter(
        cfg, runner=runner, clock=FakeClock(), profiler=profiler
    )
    metadata = adapter._profile_metadata(phase="manual", work_units={})[0]
    stale_path = Path(metadata["path"])
    stale_path.write_text("stale profile", encoding="utf-8")

    with pytest.raises(RuntimeError, match="empty output") as captured:
        adapter._run_profile(metadata)

    assert not stale_path.exists()
    assert captured.value.evidence["result"]["returncode"] == 0


@pytest.mark.parametrize(
    ("returncode", "profile_contents", "message"),
    [
        (1, "partial profile", "nonzero status"),
        (0, "", "empty output"),
    ],
)
def test_profile_failure_rejects_churn_and_retains_evidence(
    tmp_path: Path,
    returncode: int,
    profile_contents: str,
    message: str,
) -> None:
    cfg = config(tmp_path, profile_enabled=True)
    runner = FakeRunner()
    runner.top_payloads = [top_payload(), top_payload(), top_payload()]

    def profiler(**kwargs: Any) -> dict[str, Any]:
        Path(kwargs["path"]).write_text(profile_contents, encoding="utf-8")
        return {
            "path": kwargs["path"],
            "returncode": returncode,
            "stdout": "profile stdout",
            "stderr": "profile stderr",
        }

    adapter = adapter_module.CmuxRuntimeAdapter(
        cfg, runner=runner, clock=FakeClock(), profiler=profiler
    )
    prepare_fixture(adapter, runner, cfg)

    result = adapter.run_churn([])

    assert len(result["failures"]) == 2
    assert all(item["phase"] == "profile_churn" for item in result["failures"])
    assert all(message in item["message"] for item in result["failures"])
    assert all(item["evidence"]["result"]["returncode"] == returncode for item in result["failures"])
    assert all(item["evidence"]["result"]["stderr"] == "profile stderr" for item in result["failures"])


def test_profile_keeps_parent_and_each_discovered_webkit_role_separate(tmp_path: Path) -> None:
    cfg = config(tmp_path, profile_enabled=True)
    runner = FakeRunner()
    runner.top_payloads = [top_payload()]
    calls: list[dict[str, Any]] = []

    def profiler(**kwargs: Any) -> dict[str, Any]:
        calls.append(deepcopy(kwargs))
        Path(kwargs["path"]).write_text("profile evidence", encoding="utf-8")
        return {"path": kwargs["path"], "ok": True}

    adapter = adapter_module.CmuxRuntimeAdapter(
        cfg, runner=runner, clock=FakeClock(), profiler=profiler
    )
    profiles = adapter.collect_profiles()

    assert [(item["role"], item["pid"]) for item in calls] == [
        ("parent", 100), ("webkit-content", 300)
    ]
    assert len({item["path"] for item in calls}) == len(calls)
    assert all(item["duration_s"] == 1.0 and item["work_unit"] == "mixed-test" for item in calls)
    assert adapter.raw_details["profiles"] == [
        {**call, "result": {"path": call["path"], "ok": True}} for call in calls
    ]
    cleanup = adapter.cleanup_owned()
    assert cleanup["owned_state_removed"] is True
    assert cfg.output_root.is_dir()
    assert all(Path(profile["path"]).read_text(encoding="utf-8") == "profile evidence" for profile in profiles)
    assert not (cfg.output_root / "browser-fixtures").exists()


assert adapter_module.__all__ == ["AdapterConfig", "CmuxRuntimeAdapter", "extract_metrics"]
