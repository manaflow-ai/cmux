#!/usr/bin/env python3
"""Tagged macOS runtime adapter for the deterministic mixed-workload harness.

All platform effects are routed through a ``CmuxPerfRunner``-shaped seam.  The
adapter itself is therefore importable and testable on non-macOS hosts.
"""

from __future__ import annotations

from argparse import Namespace
from concurrent.futures import ThreadPoolExecutor, as_completed
from copy import deepcopy
from dataclasses import dataclass
import importlib.util
import json
import math
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from types import MappingProxyType
from typing import Any, Callable, Mapping
from urllib.parse import unquote, urlparse


_SHA_RE = re.compile(r"[0-9a-fA-F]{40}\Z")
_MAX_TIMING_SECONDS = 300.0
_PROCESS_GROUPS = ("parent_direct", "terminal", "webkit", "full_tree")


def _load_sibling(module_name: str, filename: str | None = None) -> Any:
    existing = sys.modules.get(module_name)
    if existing is not None:
        return existing
    path = Path(__file__).with_name(filename or f"{module_name}.py")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {module_name} from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


_contract = _load_sibling("perf_mixed_workload_contract")
_top_payload = _load_sibling("perf_top_payload")


def _scenario_dict(value: Any) -> dict[str, Any]:
    if hasattr(value, "to_dict"):
        value = value.to_dict()
    if not isinstance(value, Mapping):
        raise ValueError("scenario must be a Scenario or mapping")
    required = {
        "scenario_id",
        "kind",
        "load",
        "terminal_surfaces",
        "browser_surfaces",
        "aggregate_scrollback_chars",
    }
    if set(value) != required:
        raise ValueError("scenario fields do not match the mixed-workload contract")
    result = {key: value[key] for key in required}
    if not isinstance(result["scenario_id"], str) or not result["scenario_id"]:
        raise ValueError("scenario_id must be a nonempty string")
    for name in (
        "terminal_surfaces",
        "browser_surfaces",
        "aggregate_scrollback_chars",
    ):
        if type(result[name]) is not int or result[name] < 0:
            raise ValueError(f"scenario {name} must be a nonnegative integer")
    terminals = result["terminal_surfaces"]
    browsers = result["browser_surfaces"]
    scrollback = result["aggregate_scrollback_chars"]
    if terminals + browsers == 0:
        raise ValueError("scenario must contain at least one surface")
    if terminals == 0 and scrollback != 0:
        raise ValueError("browser-only scenarios cannot request scrollback")
    if terminals and scrollback % terminals:
        raise ValueError(
            "aggregate_scrollback_chars must divide exactly across terminal surfaces"
        )
    return result


def _bounded_seconds(value: Any, name: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or not 0.0 < float(value) <= _MAX_TIMING_SECONDS
    ):
        raise ValueError(f"{name} must be a positive bounded timing setting")
    return float(value)


@dataclass(frozen=True, slots=True)
class AdapterConfig:
    """Immutable identity, fixture, ownership, and bounded timing configuration."""

    sha: str
    tag: str
    app_path: str
    scenario: Any
    output_root: Path
    warmup: bool
    profile_enabled: bool
    launch_timeout_s: float = 45.0
    rpc_timeout_s: float = 60.0
    steady_duration_s: float = 5.0
    steady_interval_s: float = 1.0
    churn_duration_s: float = 5.0
    churn_interval_s: float = 1.0
    profile_duration_s: float = 5.0

    def __post_init__(self) -> None:
        if not isinstance(self.sha, str) or _SHA_RE.fullmatch(self.sha) is None:
            raise ValueError("sha must be exactly 40 hexadecimal characters")
        if not isinstance(self.tag, str) or not self.tag or "/" in self.tag or "\\" in self.tag:
            raise ValueError("tag must be a nonempty path-safe string")
        if not isinstance(self.app_path, str) or not self.app_path:
            raise ValueError("app_path must be a nonempty string")
        if type(self.warmup) is not bool or type(self.profile_enabled) is not bool:
            raise ValueError("warmup and profile_enabled must be booleans")
        scenario = _scenario_dict(self.scenario)
        object.__setattr__(self, "scenario", MappingProxyType(scenario))
        root = Path(self.output_root).expanduser().resolve()
        object.__setattr__(self, "output_root", root)
        for name in (
            "launch_timeout_s",
            "rpc_timeout_s",
            "steady_duration_s",
            "steady_interval_s",
            "churn_duration_s",
            "churn_interval_s",
            "profile_duration_s",
        ):
            object.__setattr__(self, name, _bounded_seconds(getattr(self, name), name))
        if self.steady_interval_s > self.steady_duration_s:
            raise ValueError("steady_interval_s cannot exceed steady_duration_s")
        if self.churn_interval_s > self.churn_duration_s:
            raise ValueError("churn_interval_s cannot exceed churn_duration_s")


class _SystemClock:
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)


def _plain(value: Any) -> Any:
    if hasattr(value, "to_dict"):
        return _plain(value.to_dict())
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    if isinstance(value, Path):
        return str(value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ValueError(f"value is not JSON-friendly: {type(value).__name__}")

class _ProfileCollectionError(RuntimeError):
    def __init__(self, message: str, evidence: Mapping[str, Any]) -> None:
        super().__init__(message)
        self.evidence = evidence




def _make_default_runner(config: AdapterConfig) -> Any:
    runner_module = _load_sibling(
        "perf_activation_session", "perf-activation-session.py"
    )
    args = Namespace(
        tag=config.tag,
        app_path=config.app_path,
        fixture_root=str(config.output_root),
        launch_timeout=config.launch_timeout_s,
        snapshot_timeout=config.rpc_timeout_s,
    )
    return runner_module.CmuxPerfRunner(args)


def _extract_ref(payload: Mapping[str, Any], kind: str) -> str:
    for key in (f"{kind}_id", f"{kind}_ref", "id", "ref"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    raise ValueError(f"missing {kind} identity in {payload!r}")


def _required_counter(stats: Mapping[str, Any], camel: str, snake: str) -> float:
    if camel in stats:
        value = stats[camel]
    elif snake in stats:
        value = stats[snake]
    else:
        raise ValueError(f"terminal render stats missing {camel}")
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) < 0.0
    ):
        raise ValueError(f"terminal render stats {camel} must be nonnegative and finite")
    return float(value)


def _surface_type(item: Mapping[str, Any]) -> str:
    value = item.get("type") or item.get("kind")
    if not isinstance(value, str):
        raise ValueError("surface observation is missing its type")
    return value


class CmuxRuntimeAdapter:
    """RuntimeAdapter implementation scoped to one exact tagged app invocation."""

    def __init__(
        self,
        config: AdapterConfig,
        *,
        runner: Any | None = None,
        clock: Any | None = None,
        sampler: Any | None = None,
        profiler: Callable[..., Any] | Any | None = None,
    ) -> None:
        if not isinstance(config, AdapterConfig):
            raise TypeError("config must be an AdapterConfig")
        self.config = config
        self._runner = runner if runner is not None else _make_default_runner(config)
        self._clock = clock if clock is not None else _SystemClock()
        self._sampler = sampler
        self._profiler = profiler
        self._plan: Any | None = None
        self._workspace_id: str | None = None
        self._pane_id: str | None = None
        self._terminal_actual_ids: dict[str, str] = {}
        self._browser_actual_ids: dict[str, str] = {}
        self._last_accounting: Any | None = None
        self._launched = False
        self._owned_browser_screenshot_paths: set[Path] = set()
        self._details: dict[str, Any] = {
            "invocation": {
                "sha": config.sha,
                "tag": config.tag,
                "app_path": config.app_path,
                "warmup": config.warmup,
                "profile_enabled": config.profile_enabled,
                "timings": {
                    "launch_timeout_s": config.launch_timeout_s,
                    "rpc_timeout_s": config.rpc_timeout_s,
                    "steady_duration_s": config.steady_duration_s,
                    "steady_interval_s": config.steady_interval_s,
                    "churn_duration_s": config.churn_duration_s,
                    "churn_interval_s": config.churn_interval_s,
                    "profile_duration_s": config.profile_duration_s,
                },
            },
            "scenario": dict(config.scenario),
            "fixture": {},
            "observations": [],
            "steady": {},
            "churn": {},
            "snapshot": {},
            "profiles": [],
            "cleanup": {},
        }

    @property
    def raw_details(self) -> dict[str, Any]:
        """Return an isolated, JSON-friendly copy of all raw invocation evidence."""

        value = _plain(self._details)
        json.dumps(value, allow_nan=False)
        return value

    def clean_state(self) -> None:
        self._runner.stop_app()
        self._runner.clean_persisted_state()
        browser_fixture_root = self.config.output_root / "browser-fixtures"
        if browser_fixture_root.exists():
            shutil.rmtree(browser_fixture_root)
        self.config.output_root.mkdir(parents=True, exist_ok=True)
        self._details["cleanup"] = {"prelaunch_cleaned": True}

    def launch(self, sha: str) -> None:
        if sha != self.config.sha:
            raise ValueError("launch SHA does not match the configured exact build identity")
        runner_app = getattr(self._runner, "app_path", None)
        if runner_app is not None and Path(runner_app).expanduser() != Path(self.config.app_path).expanduser():
            raise ValueError("runner app path does not match the configured app path")
        self._runner.check_paths()
        elapsed = self._runner.launch("launch")
        self._launched = True
        self._details["invocation"]["launch_socket_ready_ms"] = elapsed


    def _new_surface(self, kind: str, *, url: str | None = None) -> str:
        if self._workspace_id is None or self._pane_id is None:
            raise RuntimeError("fixture pane is not initialized")
        args = [
            "new-surface",
            "--workspace",
            self._workspace_id,
            "--pane",
            self._pane_id,
            "--type",
            kind,
        ]
        if kind == "terminal":
            args.extend(("--working-directory", str(self.config.output_root)))
        if url is not None:
            if not url.startswith("file://"):
                raise ValueError("browser fixture URLs must be local file URLs")
            args.extend(("--url", url))
        args.extend(("--focus", "false"))
        payload = self._runner.json_cli(args, timeout=self.config.rpc_timeout_s)
        if _extract_ref(payload, "pane") != self._pane_id:
            raise ValueError("surface was created outside the owned fixture pane")
        return _extract_ref(payload, "surface")

    def create_fixture(self, plan: Any) -> None:
        expected = self.config.scenario
        if (
            getattr(plan, "scenario_id", None) != expected["scenario_id"]
            or getattr(plan, "terminal_count", None) != expected["terminal_surfaces"]
            or getattr(plan, "browser_count", None) != expected["browser_surfaces"]
        ):
            raise ValueError("fixture plan does not match adapter configuration")
        for browser in plan.browser_surfaces:
            parsed_url = urlparse(browser.url)
            if (
                parsed_url.scheme != "file"
                or parsed_url.netloc
                or parsed_url.query
                or parsed_url.fragment
            ):
                raise ValueError("browser fixture plan contains a non-local URL")
            fixture_path = Path(unquote(parsed_url.path))
            if not fixture_path.resolve().is_relative_to(self.config.output_root):
                raise ValueError("browser fixture is outside the owned output root")

        before = self._runner.json_cli(
            ["list-workspaces"], timeout=self.config.rpc_timeout_s
        ).get("workspaces", [])
        if not isinstance(before, list) or len(before) != 1 or not isinstance(before[0], Mapping):
            raise ValueError("fixture requires exactly one clean startup workspace")
        self._workspace_id = _extract_ref(before[0], "workspace")
        panes_payload = self._runner.json_cli(
            ["list-panes", "--workspace", self._workspace_id],
            timeout=self.config.rpc_timeout_s,
        )
        panes = panes_payload.get("panes", [])
        if not isinstance(panes, list) or len(panes) != 1:
            raise ValueError("clean startup workspace must contain exactly one pane")
        self._pane_id = _extract_ref(panes[0], "pane")
        initial_refs = panes[0].get("surface_ids") or panes[0].get("surface_refs") or []
        if not isinstance(initial_refs, list) or len(initial_refs) != 1:
            raise ValueError("clean startup workspace must contain one initial terminal")
        initial_terminal = initial_refs[0]
        if not isinstance(initial_terminal, str):
            raise ValueError("initial terminal reference is invalid")
        startup_surfaces = self._surfaces()
        if len(startup_surfaces) != 1 or not isinstance(startup_surfaces[0], Mapping):
            raise ValueError("clean startup workspace must contain one observable surface")
        startup_surface = startup_surfaces[0]
        if _extract_ref(startup_surface, "surface") != initial_terminal:
            raise ValueError("startup surface identity changed before fixture creation")
        if _surface_type(startup_surface) != "terminal":
            raise ValueError("startup surface must be a terminal")

        self._plan = plan
        self._terminal_actual_ids.clear()
        self._browser_actual_ids.clear()
        terminals = expected["terminal_surfaces"]
        if terminals:
            respawned = self._runner.rpc(
                "surface.respawn",
                {
                    "workspace_id": self._workspace_id,
                    "surface_id": initial_terminal,
                    "working_directory": str(self.config.output_root),
                    "focus": False,
                },
                timeout=self.config.rpc_timeout_s,
            )
            if _extract_ref(respawned, "surface") != initial_terminal:
                raise ValueError("startup terminal identity changed while setting fixture cwd")
            self._terminal_actual_ids["terminal-001"] = initial_terminal
            for index in range(2, terminals + 1):
                self._terminal_actual_ids[f"terminal-{index:03d}"] = self._new_surface(
                    "terminal"
                )
        for browser in plan.browser_surfaces:
            self._browser_actual_ids[browser.surface_id] = self._new_surface(
                "browser", url=browser.url
            )
        if terminals == 0:
            self._runner.run_cli(
                [
                    "close-surface",
                    "--workspace",
                    self._workspace_id,
                    "--surface",
                    initial_terminal,
                ],
                timeout=self.config.rpc_timeout_s,
            )

        self._runner.run_cli(
            ["select-workspace", "--workspace", self._workspace_id],
            timeout=self.config.rpc_timeout_s,
            check=False,
        )

        scrollback = expected["aggregate_scrollback_chars"]
        seed_evidence: dict[str, Any] | None = None
        if terminals:
            per_terminal = scrollback // terminals
            seed_evidence = self._runner.rpc(
                "debug.session_snapshot_seed_scrollback",
                {"characters_per_terminal": per_terminal},
                timeout=self.config.rpc_timeout_s,
            )
            required = {
                "characters_per_terminal": per_terminal,
                "workspaces": 1,
                "terminals": terminals,
                "scrollback_chars": scrollback,
            }
            if any(seed_evidence.get(key) != value for key, value in required.items()):
                raise ValueError("synthetic scrollback seed did not produce the exact aggregate")

        mapping = dict(self._terminal_actual_ids)
        mapping.update(self._browser_actual_ids)
        self._details["fixture"] = {
            "workspace_id": self._workspace_id,
            "pane_id": self._pane_id,
            "planned_to_actual": mapping,
            "terminal_ids": list(self._terminal_actual_ids),
            "browser_ids": list(self._browser_actual_ids),
            "scrollback_request": {
                "aggregate_characters": scrollback,
                "characters_per_terminal": scrollback // terminals if terminals else 0,
            },
            "scrollback_evidence": seed_evidence,
        }

    def _surfaces(self) -> list[Mapping[str, Any]]:
        if self._workspace_id is None or self._pane_id is None:
            raise RuntimeError("fixture has not been created")
        workspaces = self._runner.json_cli(
            ["list-workspaces"], timeout=self.config.rpc_timeout_s
        ).get("workspaces", [])
        workspace_ids = {
            _extract_ref(item, "workspace")
            for item in workspaces
            if isinstance(item, Mapping)
        }
        if workspace_ids != {self._workspace_id}:
            raise ValueError("fixture must occupy exactly one owned workspace")
        panes = self._runner.json_cli(
            ["list-panes", "--workspace", self._workspace_id],
            timeout=self.config.rpc_timeout_s,
        ).get("panes", [])
        if not isinstance(panes, list) or len(panes) != 1:
            raise ValueError("fixture workspace must contain exactly one pane")
        if _extract_ref(panes[0], "pane") != self._pane_id:
            raise ValueError("fixture pane identity changed")
        payload = self._runner.json_cli(
            [
                "list-pane-surfaces",
                "--workspace",
                self._workspace_id,
                "--pane",
                self._pane_id,
            ],
            timeout=self.config.rpc_timeout_s,
        )
        if any(key in payload for key in ("pane_id", "pane_ref")) and _extract_ref(payload, "pane") != self._pane_id:
            raise ValueError("surface listing came from the wrong pane")
        surfaces = payload.get("surfaces", [])
        if not isinstance(surfaces, list):
            raise ValueError("surface listing must be an array")
        return surfaces

    def observe_fixture(self) -> dict[str, Any]:
        if self._plan is None:
            raise RuntimeError("fixture has not been created")
        surfaces = self._surfaces()
        actual_types = {
            _extract_ref(item, "surface"): _surface_type(item) for item in surfaces
        }
        expected_actual = set(self._terminal_actual_ids.values()) | set(
            self._browser_actual_ids.values()
        )
        if set(actual_types) != expected_actual:
            raise ValueError("observed surface identities do not match the fixture plan")
        if any(actual_types[actual] != "terminal" for actual in self._terminal_actual_ids.values()):
            raise ValueError("planned terminal identity resolved to another surface kind")
        if any(actual_types[actual] != "browser" for actual in self._browser_actual_ids.values()):
            raise ValueError("planned browser identity resolved to another surface kind")

        planned_by_id = {item.surface_id: item for item in self._plan.browser_surfaces}
        browsers: list[dict[str, str]] = []
        browser_evidence: list[dict[str, Any]] = []
        for planned_id, actual_id in self._browser_actual_ids.items():
            planned = planned_by_id[planned_id]
            wait_payload = self._runner.rpc(
                "browser.wait",
                {
                    "workspace_id": self._workspace_id,
                    "surface_id": actual_id,
                    "load_state": "complete",
                    "timeout_ms": int(self.config.rpc_timeout_s * 1000),
                },
                timeout=self.config.rpc_timeout_s,
            )
            url_payload = self._runner.rpc(
                "browser.url.get",
                {"workspace_id": self._workspace_id, "surface_id": actual_id},
                timeout=self.config.rpc_timeout_s,
            )
            title_payload = self._runner.rpc(
                "browser.get.title",
                {"workspace_id": self._workspace_id, "surface_id": actual_id},
                timeout=self.config.rpc_timeout_s,
            )
            content_payload = self._runner.rpc(
                "browser.eval",
                {
                    "workspace_id": self._workspace_id,
                    "surface_id": actual_id,
                    "script": "document.querySelector('main')?.textContent?.trim() ?? ''",
                },
                timeout=self.config.rpc_timeout_s,
            )
            observed = {
                "surface_id": planned_id,
                "url": url_payload.get("url"),
                "title": title_payload.get("title"),
                "content_marker": content_payload.get("value"),
            }
            expected = {
                "surface_id": planned.surface_id,
                "url": planned.url,
                "title": planned.title,
                "content_marker": planned.content_marker,
            }
            if observed != expected:
                raise ValueError(f"browser identity mismatch for {planned_id}")
            browsers.append(observed)
            browser_evidence.append(
                {
                    "planned_surface_id": planned_id,
                    "actual_surface_id": actual_id,
                    "load_wait": _plain(wait_payload),
                    **observed,
                }
            )

        observation = {
            "shape": {
                "terminal_surfaces": len(self._terminal_actual_ids),
                "browser_surfaces": len(self._browser_actual_ids),
            },
            "browsers": browsers,
        }
        self._details["observations"].append(
            {**deepcopy(observation), "browser_evidence": browser_evidence}
        )
        return observation

    def _raw_top(self) -> Mapping[str, Any]:
        if self._sampler is None:
            payload = self._runner.rpc(
                "system.top",
                {"all_windows": True, "include_processes": True},
                timeout=self.config.rpc_timeout_s,
            )
        elif callable(self._sampler):
            payload = self._sampler()
        elif hasattr(self._sampler, "sample"):
            payload = self._sampler.sample()
        else:
            raise TypeError("sampler must be callable or expose sample()")
        if not isinstance(payload, Mapping):
            raise ValueError("system.top sampler must return a mapping")
        return payload

    @staticmethod
    def _host_evidence(payload: Mapping[str, Any]) -> dict[str, Any]:
        names = (
            "host",
            "foreground",
            "background",
            "load",
            "load_average",
            "app_is_active",
            "window_visible",
        )
        return {name: _plain(payload[name]) for name in names if name in payload}

    def _parsed_sample(
        self, payload: Mapping[str, Any], *, index: int, elapsed_seconds: float
    ) -> dict[str, Any]:
        accounting = _top_payload.parse_system_top_payload(payload)
        self._last_accounting = accounting
        plain = accounting.to_dict()
        return {
            "sample_index": index,
            "elapsed_seconds": round(elapsed_seconds, 6),
            "process_attribution": {
                group: plain[group] for group in _PROCESS_GROUPS
            },
            "coverage": plain["coverage"],
            "process_roots": {
                "app_pid": plain["app_pid"],
                "terminal_root_pids": plain["terminal_root_pids"],
                "webkit_root_pids": plain["webkit_root_pids"],
                "webkit_role_pids": plain["webkit_role_pids"],
            },
            "host_evidence": self._host_evidence(payload),
            "raw_payload": _plain(payload),
        }

    def sample_steady(self) -> list[dict[str, Any]]:
        prime = self._raw_top()
        count = max(
            1,
            math.ceil(
                self.config.steady_duration_s / self.config.steady_interval_s
            ),
        )
        start = self._clock.monotonic()
        samples: list[dict[str, Any]] = []
        for index in range(count):
            self._clock.sleep(self.config.steady_interval_s)
            raw = self._raw_top()
            samples.append(
                self._parsed_sample(
                    raw,
                    index=index,
                    elapsed_seconds=self._clock.monotonic() - start,
                )
            )
        self._details["steady"] = {
            "prime_raw_payload": _plain(prime),
            "sample_interval_s": self.config.steady_interval_s,
            "samples": samples,
        }
        return deepcopy(samples)

    def _timed_rpc(
        self, label: str, planned_id: str, method: str, params: dict[str, Any]
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        start = self._clock.monotonic()
        payload = self._runner.rpc(
            method, params, timeout=self.config.rpc_timeout_s
        )
        elapsed = max(0.0, (self._clock.monotonic() - start) * 1000.0)
        return (
            {
                "label": label,
                "surface_id": planned_id,
                "milliseconds": round(elapsed, 6),
            },
            _plain(payload),
        )

    def _terminal_ansi_line_target(self) -> int:
        return max(256, math.ceil(self.config.churn_duration_s * 1_600))

    def _terminal_churn(self, planned_id: str, actual_id: str, cycles: int) -> dict[str, Any]:
        del cycles
        ansi_lines = self._terminal_ansi_line_target()
        batch_size = 32
        batch_count = math.ceil(ansi_lines / batch_size)
        batch_interval = self.config.churn_duration_s / batch_count
        marker = f"CMUX_PERF_FINAL_COUNT={ansi_lines}:{planned_id}"
        script = (
            "import sys,time\n"
            "line='\\033[31m\\033[1mCMUX_ANSI_################"
            "\\033[0m\\033[1G\\033[2K\\n'\n"
            f"remaining={ansi_lines}\n"
            f"batch_size={batch_size}\n"
            "while remaining:\n"
            "    count=min(batch_size,remaining)\n"
            "    sys.stdout.write(line*count)\n"
            "    sys.stdout.flush()\n"
            "    remaining-=count\n"
            f"    time.sleep({batch_interval!r})\n"
            f"print({marker!r},flush=True)\n"
        )
        command = f"python3 -c {shlex.quote(script)}\n"
        start = self._clock.monotonic()
        self._runner.run_cli(
            [
                "send",
                "--workspace",
                self._workspace_id,
                "--surface",
                actual_id,
                command,
            ],
            timeout=self.config.rpc_timeout_s,
        )
        self._clock.sleep(self.config.churn_duration_s)
        deadline = self._clock.monotonic() + self.config.rpc_timeout_s
        while True:
            captured = self._runner.run_cli(
                [
                    "capture-pane",
                    "--workspace",
                    self._workspace_id,
                    "--surface",
                    actual_id,
                ],
                timeout=self.config.rpc_timeout_s,
            )
            if marker in captured:
                break
            if self._clock.monotonic() >= deadline:
                raise TimeoutError(f"terminal churn marker not observed for {planned_id}")
            self._clock.sleep(min(0.25, self.config.churn_interval_s))
        elapsed = max(0.0, (self._clock.monotonic() - start) * 1000.0)
        return {
            "operations": ansi_lines,
            "latencies": [
                {
                    "label": "terminal_ansi_completion",
                    "surface_id": planned_id,
                    "milliseconds": round(elapsed, 6),
                }
            ],
            "evidence": {
                "actual_surface_id": actual_id,
                "final_marker": marker,
                "batch_size": batch_size,
                "target_duration_s": self.config.churn_duration_s,
            },
        }

    def _browser_churn(self, planned_id: str, actual_id: str, cycles: int) -> dict[str, Any]:
        latencies: list[dict[str, Any]] = []
        evidence: list[dict[str, Any]] = []
        methods = (
            ("browser_focus", "browser.focus_webview"),
            ("browser_reload", "browser.reload"),
            ("browser_snapshot", "browser.snapshot"),
        )
        for _ in range(cycles):
            for label, method in methods:
                latency, payload = self._timed_rpc(
                    label,
                    planned_id,
                    method,
                    {"workspace_id": self._workspace_id, "surface_id": actual_id},
                )
                latencies.append(latency)
                evidence.append({"label": label, "payload": payload})

        screenshot_latency, screenshot = self._timed_rpc(
            "browser_screenshot",
            planned_id,
            "browser.screenshot",
            {"workspace_id": self._workspace_id, "surface_id": actual_id},
        )
        encoded_png = screenshot.get("png_base64")
        if not isinstance(encoded_png, str) or not encoded_png:
            raise ValueError(f"browser screenshot returned no PNG for {planned_id}")
        latencies.append(screenshot_latency)
        screenshot_evidence = {
            key: value for key, value in screenshot.items() if key != "png_base64"
        }
        screenshot_evidence["png_base64_length"] = len(encoded_png)
        return {
            "operations": cycles * len(methods) + 1,
            "latencies": latencies,
            "render_observations": 1,
            "owned_screenshot_path": screenshot.get("path"),
            "evidence": {
                "actual_surface_id": actual_id,
                "cycles": evidence,
                "screenshot": screenshot_evidence,
            },
        }

    def _temporary_browser_cycle(self) -> dict[str, Any] | None:
        if not self._browser_actual_ids or self._plan is None:
            return None
        url = self._plan.browser_surfaces[0].url
        opened = self._runner.rpc(
            "surface.create",
            {
                "workspace_id": self._workspace_id,
                "pane_id": self._pane_id,
                "type": "browser",
                "url": url,
                "focus": False,
            },
            timeout=self.config.rpc_timeout_s,
        )
        temporary_id = _extract_ref(opened, "surface")
        closed = self._runner.rpc(
            "surface.close",
            {"workspace_id": self._workspace_id, "surface_id": temporary_id},
            timeout=self.config.rpc_timeout_s,
        )
        return {
            "url": url,
            "surface_id": temporary_id,
            "open": _plain(opened),
            "close": _plain(closed),
        }

    def _render_stats(self) -> dict[str, Any]:
        capture = getattr(self._runner, "capture_render_stats", None)
        if capture is not None:
            value = capture()
            if not isinstance(value, Mapping):
                raise ValueError("render stats capture must return a mapping")
            return _plain(value)
        stats: dict[str, Any] = {}
        for actual_id in self._terminal_actual_ids.values():
            payload = self._runner.rpc(
                "debug.terminal.render_stats",
                {"surface_id": actual_id},
                timeout=self.config.rpc_timeout_s,
            )
            value = payload.get("stats")
            if not isinstance(value, Mapping):
                raise ValueError(
                    f"terminal render stats missing for surface {actual_id}"
                )
            stats[actual_id] = _plain(value)
        return stats

    def run_churn(self, operations: list[dict[str, Any]]) -> dict[str, Any]:
        cycles = max(
            1,
            math.ceil(self.config.churn_duration_s / self.config.churn_interval_s),
        )
        before_render = self._render_stats()
        churn_start = self._clock.monotonic()
        failures: list[dict[str, Any]] = []
        latencies: list[dict[str, Any]] = []
        evidence: list[dict[str, Any]] = []
        operation_counts = {"terminal": 0, "browser": 0}
        browser_render_counts: dict[str, int] = {}
        profile_pool: ThreadPoolExecutor | None = None
        profile_futures: dict[Any, dict[str, Any]] = {}
        if self.config.profile_enabled:
            try:
                work_units = {
                    "terminal_ansi_lines": len(self._terminal_actual_ids)
                    * self._terminal_ansi_line_target(),
                    "browser_churn_rpc_operations": len(self._browser_actual_ids)
                    * (cycles * 3 + 1),
                    "temporary_browser_open_close_operations": 2
                    if self._browser_actual_ids
                    else 0,
                }
                metadata = self._profile_metadata(
                    phase="churn", work_units=work_units
                )
                profile_pool = ThreadPoolExecutor(
                    max_workers=max(1, len(metadata))
                )
                profile_futures = {
                    profile_pool.submit(self._run_profile, item): item
                    for item in metadata
                }
            except BaseException as error:
                failures.append({"phase": "profile_setup", "message": str(error)})
        futures: dict[Any, tuple[str, str]] = {}
        worker_count = len(self._terminal_actual_ids) + len(self._browser_actual_ids)
        with ThreadPoolExecutor(max_workers=max(1, worker_count)) as pool:
            for planned, actual in self._terminal_actual_ids.items():
                future = pool.submit(self._terminal_churn, planned, actual, cycles)
                futures[future] = ("terminal", planned)
            for planned, actual in self._browser_actual_ids.items():
                future = pool.submit(self._browser_churn, planned, actual, cycles)
                futures[future] = ("browser", planned)

            sample_count = max(1, cycles)
            samples: list[dict[str, Any]] = []
            for index in range(sample_count):
                self._clock.sleep(self.config.churn_interval_s)
                try:
                    raw = self._raw_top()
                    samples.append(
                        self._parsed_sample(
                            raw,
                            index=index,
                            elapsed_seconds=self._clock.monotonic() - churn_start,
                        )
                    )
                except BaseException as error:
                    failures.append(
                        {
                            "phase": "churn_sampling",
                            "operation_index": index,
                            "message": str(error),
                        }
                    )

            for future in as_completed(futures):
                kind, planned = futures[future]
                try:
                    result = future.result()
                except BaseException as error:
                    failures.append(
                        {
                            "phase": "churn",
                            "surface_id": planned,
                            "message": str(error),
                        }
                    )
                    continue
                operation_counts[kind] += result["operations"]
                if kind == "browser":
                    browser_render_counts[planned] = result["render_observations"]
                    screenshot_path = result.get("owned_screenshot_path")
                    if isinstance(screenshot_path, str) and screenshot_path:
                        candidate = Path(screenshot_path).absolute()
                        expected_root = (
                            Path(tempfile.gettempdir()) / "cmux-browser-screenshots"
                        ).resolve()
                        if (
                            candidate.parent.resolve() == expected_root
                            and candidate.name.startswith("surface-")
                            and candidate.suffix == ".png"
                            and candidate.is_file()
                            and not candidate.is_symlink()
                        ):
                            self._owned_browser_screenshot_paths.add(candidate)
                latencies.extend(result["latencies"])
                evidence.append(
                    {
                        "surface_kind": kind,
                        "surface_id": planned,
                        **result["evidence"],
                    }
                )

        temporary: dict[str, Any] | None = None
        try:
            temporary = self._temporary_browser_cycle()
            if temporary is not None:
                operation_counts["browser"] += 2
        except BaseException as error:
            failures.append(
                {"phase": "temporary_browser_cycle", "message": str(error)}
            )
        churn_elapsed_s = max(
            1e-9, self._clock.monotonic() - churn_start
        )

        profile_records: list[dict[str, Any]] = []
        for future in as_completed(profile_futures):
            metadata = profile_futures[future]
            try:
                profile_records.append(future.result())
            except BaseException as error:
                failure = {
                    "phase": "profile_churn",
                    "role": metadata["role"],
                    "pid": metadata["pid"],
                    "message": str(error),
                }
                profile_evidence = getattr(error, "evidence", None)
                if profile_evidence is not None:
                    failure["evidence"] = _plain(profile_evidence)
                failures.append(failure)
        if profile_pool is not None:
            profile_pool.shutdown(wait=True)
        if profile_records:
            self._details["profiles"] = sorted(
                profile_records, key=lambda item: (item["role"], item["pid"])
            )

        after_render = self._render_stats()
        render_observations: list[dict[str, Any]] = []
        for planned, actual in self._terminal_actual_ids.items():
            before = before_render.get(actual)
            after = after_render.get(actual)
            if not isinstance(before, Mapping) or not isinstance(after, Mapping):
                raise ValueError(f"terminal render stats missing for {planned}")
            drawable_delta = _required_counter(
                after, "metalDrawableCount", "metal_drawable_count"
            ) - _required_counter(
                before, "metalDrawableCount", "metal_drawable_count"
            )
            draw_delta = _required_counter(
                after, "drawCount", "draw_count"
            ) - _required_counter(before, "drawCount", "draw_count")
            observed_final_key_change_delta = _required_counter(
                after, "presentCount", "present_count"
            ) - _required_counter(before, "presentCount", "present_count")
            render_observations.append(
                {
                    "surface_kind": "terminal",
                    "surface_id": planned,
                    "measurement": "debug.terminal.render_stats.metalDrawableCount_render_proxy",
                    "render_delta": max(0.0, drawable_delta),
                    "draw_delta": max(0.0, draw_delta),
                    "observed_final_key_change_delta": max(
                        0.0, observed_final_key_change_delta
                    ),
                    "render_rate": max(0.0, drawable_delta) / churn_elapsed_s,
                }
            )
        for planned in self._browser_actual_ids:
            completed_screenshots = browser_render_counts.get(planned, 0)
            render_observations.append(
                {
                    "surface_kind": "browser",
                    "surface_id": planned,
                    "measurement": "completed_browser_screenshot_render_proxy",
                    "render_delta": completed_screenshots,
                    "draw_delta": None,
                    "render_rate": completed_screenshots / churn_elapsed_s,
                }
            )

        throughput = {
            kind: count / churn_elapsed_s
            for kind, count in operation_counts.items()
            if (kind == "terminal" and self._terminal_actual_ids)
            or (kind == "browser" and self._browser_actual_ids)
        }
        result = {
            "samples": samples,
            "latencies_ms": sorted(
                latencies, key=lambda item: (item["surface_id"], item["label"])
            ),
            "throughput_ops_per_second": throughput,
            "render_observations": render_observations,
            "failures": failures,
        }
        self._details["churn"] = {
            "requested_operations": _plain(operations),
            "fixed_duration_s": self.config.churn_duration_s,
            "measured_elapsed_s": churn_elapsed_s,
            "cycles_per_surface": cycles,
            "surface_evidence": sorted(
                evidence, key=lambda item: (item["surface_kind"], item["surface_id"])
            ),
            "temporary_browser_cycle": temporary,
            "render_stats_before": before_render,
            "render_stats_after": after_render,
            **deepcopy(result),
        }
        return result

    @staticmethod
    def _snapshot_contract(payload: Any) -> dict[str, Any]:
        if not isinstance(payload, Mapping):
            raise ValueError("snapshot benchmark payload must be a mapping")
        fields = ("built", "include_scrollback", "persist", "saved", "shape")
        try:
            return {field: payload[field] for field in fields}
        except KeyError as error:
            raise ValueError(f"snapshot benchmark is missing {error.args[0]}") from None

    def snapshot(self) -> dict[str, Any]:
        payload = self._runner.rpc(
            "debug.session_snapshot_benchmark",
            {"include_scrollback": True, "persist": True},
            timeout=self.config.rpc_timeout_s,
        )
        _contract.validate_snapshot(
            self.config.scenario, self._snapshot_contract(payload)
        )
        captured = _plain(payload)
        self._details["snapshot"]["captured"] = captured
        return captured

    def restore(self, snapshot: Any) -> None:
        _contract.validate_snapshot(
            self.config.scenario, self._snapshot_contract(snapshot)
        )
        self._runner.stop_app()
        self._launched = False
        elapsed = self._runner.launch("restore")
        self._launched = True
        restored = self._runner.rpc(
            "debug.session_snapshot_benchmark",
            {"include_scrollback": True, "persist": True},
            timeout=self.config.rpc_timeout_s,
        )
        _contract.validate_snapshot(
            self.config.scenario, self._snapshot_contract(restored)
        )
        identity = self.observe_fixture()
        self._details["snapshot"]["restored"] = {
            "launch_socket_ready_ms": elapsed,
            "snapshot": _plain(restored),
            "identity": identity,
        }

    def stop(self) -> None:
        self._runner.stop_app()
        self._launched = False

    def cleanup_owned(self) -> dict[str, Any]:
        browser_fixture_root = self.config.output_root / "browser-fixtures"
        runtime_paths = [browser_fixture_root, *self._owned_browser_screenshot_paths]
        runner_cleanup = getattr(self._runner, "cleanup_owned", None)
        if runner_cleanup is not None:
            runner_evidence = runner_cleanup()
        else:
            for name in (
                "socket_path",
                "cmuxd_socket_path",
                "debug_log_path",
                "stdout_path",
                "fixture_root",
            ):
                value = getattr(self._runner, name, None)
                if value is not None:
                    runtime_paths.append(Path(value))
            self._runner.clean_persisted_state()
            runner_evidence = {"tag_state_removed": True}
        for path in runtime_paths:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        evidence = {
            "stopped": not self._launched,
            "owned_state_removed": all(not path.exists() for path in runtime_paths),
            "owned_paths": sorted({str(path) for path in runtime_paths}),
            "preserved_output_root": str(self.config.output_root),
            "runner": _plain(runner_evidence),
        }
        self._details["cleanup"] = evidence
        return deepcopy(evidence)

    def _default_profile(self, **kwargs: Any) -> dict[str, Any]:
        path = Path(kwargs["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            [
                "/usr/bin/sample",
                str(kwargs["pid"]),
                f"{kwargs['duration_s']:g}",
                "-file",
                str(path),
            ],
            text=True,
            capture_output=True,
            check=False,
            timeout=self.config.profile_duration_s + 30.0,
        )
        return {
            "path": str(path),
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }

    def _profile_metadata(
        self, *, phase: str, work_units: Mapping[str, int]
    ) -> list[dict[str, Any]]:
        if self._last_accounting is None:
            self._last_accounting = _top_payload.parse_system_top_payload(
                self._raw_top()
            )
        accounting = self._last_accounting
        roots: list[tuple[str, int]] = [("parent", accounting.app_pid)]
        for root_pid in accounting.webkit_root_pids:
            matching = [
                role
                for role, pids in accounting.webkit_role_pids.items()
                if root_pid in pids
            ]
            if len(matching) != 1:
                raise ValueError(f"WebKit root PID {root_pid} has no unique role")
            roots.append((f"webkit-{matching[0]}", root_pid))
        profile_root = self.config.output_root / "profiles"
        profile_root.mkdir(parents=True, exist_ok=True)
        return [
            {
                "role": role,
                "pid": pid,
                "path": str(profile_root / f"{role}-{pid}.sample.txt"),
                "duration_s": self.config.profile_duration_s,
                "work_unit": self.config.scenario["scenario_id"],
                "phase": phase,
                "work_units": dict(work_units),
            }
            for role, pid in roots
        ]

    def _run_profile(self, metadata: dict[str, Any]) -> dict[str, Any]:
        profile_path = Path(metadata["path"])
        profile_path.unlink(missing_ok=True)
        profile_callable = self._profiler or self._default_profile
        if callable(profile_callable):
            result = profile_callable(**metadata)
        elif hasattr(profile_callable, "sample"):
            result = profile_callable.sample(**metadata)
        else:
            raise TypeError("profiler must be callable or expose sample()")

        record = {**metadata, "result": _plain(result)}
        if isinstance(result, Mapping):
            returncode = result.get("returncode")
            if isinstance(returncode, int) and returncode != 0:
                raise _ProfileCollectionError(
                    f"profile command returned nonzero status {returncode}", record
                )
        if not profile_path.is_file() or profile_path.stat().st_size == 0:
            raise _ProfileCollectionError("profile command produced empty output", record)
        return record

    def collect_profiles(self) -> list[dict[str, Any]]:
        if not self.config.profile_enabled:
            return []
        metadata = self._profile_metadata(phase="manual", work_units={})
        records = [self._run_profile(item) for item in metadata]
        self._details["profiles"] = records
        return deepcopy(records)


def _field(value: Any, name: str, default: Any = None) -> Any:
    if isinstance(value, Mapping):
        return value.get(name, default)
    return getattr(value, name, default)


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _sample_cpu(samples: Any, group: str) -> float | None:
    if not isinstance(samples, (list, tuple)):
        return None
    values: list[float] = []
    for sample in samples:
        attribution = _field(sample, "process_attribution", {})
        subtotal = _field(attribution, group, {})
        value = _field(subtotal, "cpu_percent")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            values.append(float(value))
    return _mean(values)


def extract_metrics(result: Any, raw_details: Mapping[str, Any] | None = None) -> dict[str, float]:
    """Extract only existing driver ``METRIC_GATES`` names from raw evidence."""

    details = raw_details or {}
    scenario = details.get("scenario", {}) if isinstance(details, Mapping) else {}
    requested = _field(result, "requested_shape", {})
    terminals = scenario.get(
        "terminal_surfaces", _field(requested, "terminal_surfaces", 0)
    )
    browsers = scenario.get(
        "browser_surfaces", _field(requested, "browser_surfaces", 0)
    )
    terminals = terminals if type(terminals) is int else 0
    browsers = browsers if type(browsers) is int else 0

    metrics: dict[str, float] = {}
    steady = _field(result, "steady_samples", [])
    churn = _field(result, "churn_samples", [])
    for phase, samples in (("steady", steady), ("churn", churn)):
        for group, suffix in (
            ("parent_direct", "parent"),
            ("full_tree", "full_tree"),
        ):
            value = _sample_cpu(samples, group)
            if value is not None:
                metrics[f"{phase}_{suffix}_cpu_percent"] = value
        if terminals:
            value = _sample_cpu(samples, "terminal")
            if value is not None:
                metrics[f"{phase}_terminal_cpu_percent"] = value
        if browsers:
            value = _sample_cpu(samples, "webkit")
            if value is not None:
                metrics[f"{phase}_webkit_cpu_percent"] = value

    if browsers:
        latencies = _field(result, "latencies_ms", [])
        browser_latency_values: list[float] = []
        if isinstance(latencies, (list, tuple)):
            for item in latencies:
                label = _field(item, "label", "")
                value = _field(item, "milliseconds")
                if (
                    isinstance(label, str)
                    and label.startswith("browser_")
                    and isinstance(value, (int, float))
                    and not isinstance(value, bool)
                ):
                    browser_latency_values.append(float(value))
        value = _mean(browser_latency_values)
        if value is not None:
            metrics["browser_latency_ms"] = value

    throughput = _field(result, "throughput_ops_per_second", {})
    if isinstance(throughput, Mapping):
        for kind, present in (("terminal", bool(terminals)), ("browser", bool(browsers))):
            value = throughput.get(kind)
            if present and isinstance(value, (int, float)) and not isinstance(value, bool):
                metrics[f"{kind}_throughput_per_second"] = float(value)

    render_observations = _field(result, "render_observations", [])
    if isinstance(render_observations, (list, tuple)):
        for kind, present in (("terminal", bool(terminals)), ("browser", bool(browsers))):
            if not present:
                continue
            rates = [
                float(_field(item, "render_rate"))
                for item in render_observations
                if _field(item, "surface_kind") == kind
                and isinstance(_field(item, "render_rate"), (int, float))
                and not isinstance(_field(item, "render_rate"), bool)
            ]
            value = _mean(rates)
            if value is not None:
                metrics[f"{kind}_render_rate"] = value
    return metrics


__all__ = ["AdapterConfig", "CmuxRuntimeAdapter", "extract_metrics"]
