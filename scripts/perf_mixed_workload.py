#!/usr/bin/env python3
"""Pure fixture planning and adapter-driven mixed-workload orchestration."""

from __future__ import annotations

from dataclasses import dataclass
from html import escape
from pathlib import Path
import re
from types import TracebackType
from typing import Any, Mapping, Protocol, Sequence


_SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}\Z")
_SHAPE_FIELDS = frozenset({"terminal_surfaces", "browser_surfaces"})
_BROWSER_IDENTITY_FIELDS = frozenset(
    {"surface_id", "url", "title", "content_marker"}
)
_KNOWN_ORDERS = frozenset({"AB", "BA"})


@dataclass(frozen=True, slots=True)
class BrowserSurface:
    """Stable identity for one owned local browser fixture."""

    surface_id: str
    url: str
    title: str
    content_marker: str


@dataclass(frozen=True, slots=True)
class BrowserFixturePlan:
    """Immutable plan for browser surfaces in one scenario."""

    scenario_id: str
    terminal_count: int
    browser_count: int
    browser_surfaces: tuple[BrowserSurface, ...]


@dataclass(frozen=True, slots=True)
class InvocationResult:
    """Raw observations produced by one completely cleaned-up invocation."""

    scenario_id: str
    sha: str
    order: str
    repetition: int
    requested_shape: Mapping[str, int]
    observed_shape: Mapping[str, int]
    steady_samples: Any
    churn_samples: Any
    latencies_ms: Any
    throughput_ops_per_second: Any
    render_observations: Any
    failures: Any
    cleanup: Any


class RuntimeAdapter(Protocol):
    """Synchronous side-effect seam used by :func:`run_invocation`."""

    def clean_state(self) -> None: ...

    def launch(self, sha: str) -> None: ...

    def create_fixture(self, plan: BrowserFixturePlan) -> None: ...

    def observe_fixture(self) -> Mapping[str, Any]: ...

    def sample_steady(self) -> Any: ...

    def run_churn(self, operations: list[dict[str, Any]]) -> Mapping[str, Any]: ...

    def snapshot(self) -> Any: ...

    def restore(self, snapshot: Any) -> None: ...

    def stop(self) -> None: ...

    def cleanup_owned(self) -> Any: ...


def _require_nonnegative_exact_int(value: Any, name: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")
    return value


def _validate_scenario_id(scenario_id: Any) -> str:
    if type(scenario_id) is not str or not scenario_id:
        raise ValueError("scenario_id must be a nonempty string")
    return scenario_id


def _validate_requested_shape(requested_shape: Any) -> Mapping[str, int]:
    if not isinstance(requested_shape, Mapping):
        raise ValueError("requested_shape must be a mapping")
    if set(requested_shape) != _SHAPE_FIELDS:
        raise ValueError(
            "requested_shape must contain exactly terminal_surfaces and "
            "browser_surfaces"
        )
    _require_nonnegative_exact_int(
        requested_shape["terminal_surfaces"], "terminal_surfaces"
    )
    _require_nonnegative_exact_int(
        requested_shape["browser_surfaces"], "browser_surfaces"
    )
    return requested_shape


def build_browser_fixture_plan(
    *,
    scenario_id: str,
    terminal_count: int,
    browser_count: int,
    owned_root: Path,
) -> BrowserFixturePlan:
    """Create deterministic local HTML fixtures and return their stable plan."""

    scenario_id = _validate_scenario_id(scenario_id)
    terminal_count = _require_nonnegative_exact_int(terminal_count, "terminal_count")
    browser_count = _require_nonnegative_exact_int(browser_count, "browser_count")

    fixture_root = Path(owned_root).resolve() / "browser-fixtures"
    fixture_root.mkdir(parents=True, exist_ok=True)
    surfaces: list[BrowserSurface] = []
    for index in range(1, browser_count + 1):
        ordinal = f"{index:03d}"
        surface_id = f"browser-{scenario_id}-{ordinal}"
        title = f"cmux perf {scenario_id} browser {ordinal}"
        content_marker = f"cmux-perf:scenario={scenario_id};surface=browser-{ordinal}"
        fixture_path = fixture_root / f"browser-{ordinal}.html"
        html = (
            "<!doctype html>\n"
            '<html lang="en">\n'
            "<head>\n"
            '  <meta charset="utf-8">\n'
            f"  <title>{escape(title)}</title>\n"
            "</head>\n"
            "<body>\n"
            f"  <main>{escape(content_marker)}</main>\n"
            "</body>\n"
            "</html>\n"
        )
        fixture_path.write_text(html, encoding="utf-8")
        surfaces.append(
            BrowserSurface(
                surface_id=surface_id,
                url=fixture_path.as_uri(),
                title=title,
                content_marker=content_marker,
            )
        )

    return BrowserFixturePlan(
        scenario_id=scenario_id,
        terminal_count=terminal_count,
        browser_count=browser_count,
        browser_surfaces=tuple(surfaces),
    )


def validate_browser_observations(
    plan: BrowserFixturePlan, observations: Any
) -> None:
    """Require an ordered, exact identity match for every planned browser."""

    if type(observations) is not list:
        raise ValueError("browser observations must be a list")
    if len(observations) != len(plan.browser_surfaces):
        raise ValueError("browser observation count does not match the fixture plan")

    for index, (planned, observed) in enumerate(
        zip(plan.browser_surfaces, observations, strict=True)
    ):
        if type(observed) is not dict:
            raise ValueError(f"browser observation {index} must be a dictionary")
        if set(observed) != _BROWSER_IDENTITY_FIELDS:
            raise ValueError(
                f"browser observation {index} must contain exactly the identity fields"
            )
        for field in _BROWSER_IDENTITY_FIELDS:
            if observed[field] != getattr(planned, field):
                raise ValueError(
                    f"browser observation {index} has mismatched {field}"
                )


def build_churn_operations(
    plan: BrowserFixturePlan,
) -> list[dict[str, Any]]:
    """Build the deterministic churn sequence for the available surfaces."""

    operations: list[dict[str, Any]] = []
    if plan.terminal_count:
        operations.append(
            {
                "operation": "activate",
                "surface_kind": "terminal",
                "surface_id": "terminal-001",
            }
        )
    if plan.browser_surfaces:
        operations.append(
            {
                "operation": "activate",
                "surface_kind": "browser",
                "surface_id": plan.browser_surfaces[0].surface_id,
            }
        )
    if plan.terminal_count:
        terminal_index = min(2, plan.terminal_count)
        terminal_id = f"terminal-{terminal_index:03d}"
        operations.append(
            {
                "operation": "terminal_input",
                "surface_id": terminal_id,
                "payload": (
                    f"printf 'cmux-perf-churn:{plan.scenario_id}:"
                    f"{terminal_id}\\n'"
                ),
            }
        )
    if plan.browser_surfaces:
        browser_index = min(2, len(plan.browser_surfaces)) - 1
        operations.append(
            {
                "operation": "browser_reload",
                "surface_id": plan.browser_surfaces[browser_index].surface_id,
            }
        )
    return operations


def _validate_fixture_observation(
    plan: BrowserFixturePlan,
    requested_shape: Mapping[str, int],
    observation: Any,
) -> Mapping[str, int]:
    if type(observation) is not dict or set(observation) != {"shape", "browsers"}:
        raise ValueError("fixture observation must contain exactly shape and browsers")
    observed_shape = _validate_requested_shape(observation["shape"])
    if observed_shape != requested_shape:
        raise ValueError("observed fixture shape does not match requested shape")
    validate_browser_observations(plan, observation["browsers"])
    return observed_shape


def _validate_invocation_inputs(
    scenario_id: Any,
    sha: Any,
    order: Any,
    repetition: Any,
    requested_shape: Any,
) -> Mapping[str, int]:
    _validate_scenario_id(scenario_id)
    if type(sha) is not str or _SHA_PATTERN.fullmatch(sha) is None:
        raise ValueError("sha must be exactly 40 hexadecimal characters")
    if order not in _KNOWN_ORDERS or type(order) is not str:
        raise ValueError(f"order must be one of {sorted(_KNOWN_ORDERS)}")
    _require_nonnegative_exact_int(repetition, "repetition")
    return _validate_requested_shape(requested_shape)


def run_invocation(
    *,
    scenario_id: str,
    sha: str,
    order: str,
    repetition: int,
    requested_shape: Mapping[str, int],
    owned_root: Path,
    adapter: RuntimeAdapter,
) -> InvocationResult:
    """Run one invocation, preserving adapter data and always cleaning up."""

    primary_error: BaseException | None = None
    primary_traceback: TracebackType | None = None
    cleanup: Any = None
    result_values: dict[str, Any] | None = None

    try:
        requested_shape = _validate_invocation_inputs(
            scenario_id, sha, order, repetition, requested_shape
        )
        adapter.clean_state()
        adapter.launch(sha)
        plan = build_browser_fixture_plan(
            scenario_id=scenario_id,
            terminal_count=requested_shape["terminal_surfaces"],
            browser_count=requested_shape["browser_surfaces"],
            owned_root=owned_root,
        )
        adapter.create_fixture(plan)

        initial_observation = adapter.observe_fixture()
        observed_shape = _validate_fixture_observation(
            plan, requested_shape, initial_observation
        )
        steady_samples = adapter.sample_steady()
        churn = adapter.run_churn(build_churn_operations(plan))
        snapshot = adapter.snapshot()
        adapter.restore(snapshot)
        restored_observation = adapter.observe_fixture()
        _validate_fixture_observation(plan, requested_shape, restored_observation)

        result_values = {
            "observed_shape": observed_shape,
            "steady_samples": steady_samples,
            "churn_samples": churn["samples"],
            "latencies_ms": churn["latencies_ms"],
            "throughput_ops_per_second": churn["throughput_ops_per_second"],
            "render_observations": churn["render_observations"],
            "failures": churn["failures"],
        }
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        cleanup_error: BaseException | None = None
        cleanup_traceback: TracebackType | None = None
        try:
            adapter.stop()
        except BaseException as error:
            cleanup_error = error
            cleanup_traceback = error.__traceback__
        try:
            cleanup = adapter.cleanup_owned()
        except BaseException as error:
            if cleanup_error is None:
                cleanup_error = error
                cleanup_traceback = error.__traceback__
        if primary_error is None and cleanup_error is not None:
            primary_error = cleanup_error
            primary_traceback = cleanup_traceback

    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    if result_values is None:
        raise RuntimeError("invocation completed without observations")

    return InvocationResult(
        scenario_id=scenario_id,
        sha=sha,
        order=order,
        repetition=repetition,
        requested_shape=requested_shape,
        cleanup=cleanup,
        **result_values,
    )
