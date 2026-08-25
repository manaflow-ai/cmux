#!/usr/bin/env python3
"""Pure metric and budget logic for the target-scale performance fixture.

The benchmark itself runs on macOS, but this module intentionally has no
platform or cmux dependency.  Keeping parsing and budget decisions here makes
the regression contract testable on every CI runner and makes a failing budget
unambiguous in the machine-readable artifact.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, Sequence


BYTES_PER_KIB = 1024
BYTES_PER_MIB = BYTES_PER_KIB * 1024
BYTES_PER_GIB = BYTES_PER_MIB * 1024
SCHEMA_VERSION = 1
FIXTURE_SIZES = (1, 10, 100, 200)
VISIBLE_SURFACE_LIMIT = 5
MIN_CPU_SECONDS = 30.0


def parse_size(value: str | int | float | None) -> int | None:
    """Parse a macOS diagnostic size into bytes.

    ``footprint`` and ``vmmap`` have emitted both ``123.4M`` and
    ``123.4 MB`` over time.  The parser accepts either spelling, commas, and a
    bare byte count.  macOS diagnostic suffixes are binary units.
    """

    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    text = str(value).strip().replace(",", "")
    if not text or text in {"-", "n/a", "NA", "null"}:
        return None
    match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*([KMGT]?)(?:i?B)?", text, re.I)
    if not match:
        return None
    number = float(match.group(1))
    unit = match.group(2).upper()
    multiplier = {
        "": 1,
        "K": BYTES_PER_KIB,
        "M": BYTES_PER_MIB,
        "G": BYTES_PER_GIB,
        "T": BYTES_PER_GIB * 1024,
    }[unit]
    return max(0, int(number * multiplier))


_SIZE_TOKEN = r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)\s*[KMGT]?(?:i?B)?)"
_LABELS = {
    "phys_footprint": (
        r"physical\s+footprint|phys[_ ]footprint|physicalFootprint"
    ),
    "phys_footprint_peak": (
        r"peak\s+physical\s+footprint|physical\s+footprint\s*(?:\(\s*peak\s*\)|peak)|"
        r"peak[_ ]phys(?:ical)?[_ ]footprint|phys[_ ]footprint[_ ]peak"
    ),
    "dirty_graphics": r"dirty\s+graphics|dirtyGraphics|graphics\s+footprint|\(\s*graphics\s*\)",
    "iosurface": r"io\s*surface|iosurface|ioSurface",
    "ioaccelerator": r"io\s*accelerator|ioaccelerator|ioAccelerator",
}


def parse_footprint_output(text: str) -> dict[str, int | None]:
    """Extract physical and graphics categories from ``footprint`` output.

    The output format is not a stable API: some OS versions use a colon,
    others align values in a table.  We search on both sides of each known
    label, aggregate repeated graphics rows, and retain ``None`` when a
    category is not present instead of inventing a zero.
    """

    result: dict[str, int | None] = {
        "phys_footprint_bytes": None,
        "phys_footprint_peak_bytes": None,
        "dirty_graphics_bytes": None,
        "iosurface_bytes": None,
        "ioaccelerator_bytes": None,
    }
    def line_value(line: str, label: str) -> int | None:
        """Read either ``label: value`` or footprint's table row.

        The human-readable format has changed between macOS releases.  Some
        versions put the value after a label (``IOSurface: 40 MB``), while
        the current table puts the dirty value before the category
        (``40 MB ... IOSurface``).  Looking on both sides of the label keeps
        the collector independent of that presentation detail.
        """

        label_match = re.search(label, line, re.I)
        if label_match is None:
            return None
        tokens = list(re.finditer(_SIZE_TOKEN, line, re.I))
        before = [token for token in tokens if token.start() < label_match.start()]
        after = [token for token in tokens if token.start() >= label_match.end()]
        # In the table form the first column is Dirty, so the first token
        # before the category is the value we want.  In key/value form the
        # first token after the label is the value.
        candidates = before or after
        if not candidates:
            return None
        return parse_size(candidates[0].group(1))

    # Prefer peak-specific expressions before the shorter current expression.
    # Graphics categories can occur more than once (for example, several
    # graphics sub-ledgers), so aggregate their dirty columns.  Physical
    # footprint values are single auxiliary-data entries and use the first
    # matching line.
    ordered = ("phys_footprint_peak", "phys_footprint", "dirty_graphics", "iosurface", "ioaccelerator")
    aggregate = {"dirty_graphics", "iosurface", "ioaccelerator"}
    for key in ordered:
        total = 0
        found = False
        for line in text.splitlines():
            # ``phys_footprint_peak`` also contains the shorter
            # ``phys_footprint`` label.  Keep the current and peak entries
            # distinct when scanning auxiliary data.
            if key == "phys_footprint" and re.search(r"(?i)peak", line):
                continue
            # Graphics tables commonly contain a category such as
            # ``Owned physical footprint (unmapped) (graphics)``.  That is
            # not the auxiliary ``Physical footprint`` value.
            if key.startswith("phys_footprint") and re.search(r"(?i)owned\s+physical\s+footprint", line):
                continue
            parsed = line_value(line, _LABELS[key])
            if parsed is None:
                continue
            if key in aggregate:
                total += parsed
                found = True
            else:
                result[f"{key}_bytes"] = parsed
                found = True
                break
        if key in aggregate and found:
            result[f"{key}_bytes"] = total

    # A few footprint versions print key/value pairs without a line prefix,
    # e.g. ``phys_footprint=123456``.  The line parser above handles most
    # cases; this fallback also handles a value before a trailing unit.
    compact_patterns = {
        "phys_footprint_bytes": r"phys[_ ]footprint\s*[:=]\s*" + _SIZE_TOKEN,
        "phys_footprint_peak_bytes": r"phys[_ ]footprint(?:[_ ]peak|\s+peak|\s*\(\s*peak\s*\))\s*[:=]\s*" + _SIZE_TOKEN,
        "dirty_graphics_bytes": r"dirty[_ ]graphics\s*[:=]\s*" + _SIZE_TOKEN,
        "iosurface_bytes": r"io\s*surface\s*[:=]\s*" + _SIZE_TOKEN,
        "ioaccelerator_bytes": r"io\s*accelerator\s*[:=]\s*" + _SIZE_TOKEN,
    }
    for key, expression in compact_patterns.items():
        if result[key] is not None:
            continue
        match = re.search(expression, text, re.I)
        if match:
            result[key] = parse_size(match.group(1))

    if result["phys_footprint_peak_bytes"] is None:
        trailing_peak = re.search(
            r"(?i)physical\s+footprint[^\n]*?\(?\s*peak\s*[:=]?\s*" + _SIZE_TOKEN,
            text,
        )
        if trailing_peak:
            result["phys_footprint_peak_bytes"] = parse_size(trailing_peak.group(1))

    if result["phys_footprint_peak_bytes"] is None:
        result["phys_footprint_peak_bytes"] = result["phys_footprint_bytes"]
    return result


def parse_vmmap_summary(text: str) -> dict[str, int | None]:
    """Parse the subset of ``vmmap --summary`` used as a footprint fallback."""

    parsed = parse_footprint_output(text)
    if parsed["phys_footprint_bytes"] is None:
        match = re.search(r"(?i)physical\s+footprint\s*:\s*" + _SIZE_TOKEN, text)
        if match:
            parsed["phys_footprint_bytes"] = parse_size(match.group(1))
    if parsed["phys_footprint_peak_bytes"] is None:
        parsed["phys_footprint_peak_bytes"] = parsed["phys_footprint_bytes"]
    return parsed


def parse_cpu_samples(lines: Iterable[str]) -> list[float]:
    """Parse ``ps -o %cpu=`` output, ignoring transient non-numeric lines."""

    values: list[float] = []
    for line in lines:
        token = str(line).strip().replace(",", "")
        if not token or token in {"-", "N/A"}:
            continue
        try:
            value = float(token)
        except ValueError:
            continue
        if math.isfinite(value) and value >= 0:
            values.append(value)
    return values


def summarize_cpu_samples(
    samples: Sequence[float],
    duration_seconds: float,
    logical_cores: int = 1,
) -> dict[str, Any]:
    """Summarize CPU as a percentage of one core and of the whole machine.

    macOS ``ps %cpu`` uses 100 for one fully busy core.  The issue's 10% budget
    is therefore compared with ``mean_one_core_percent``; the machine-normalized
    value is recorded separately for readers who prefer a whole-host metric.
    """

    values = list(samples)
    if not values:
        return {
            "sample_count": 0,
            "duration_seconds": float(duration_seconds),
            "mean_one_core_percent": None,
            "p95_one_core_percent": None,
            "max_one_core_percent": None,
            "mean_machine_percent": None,
            "logical_cores": max(1, int(logical_cores)),
        }
    ordered = sorted(values)
    rank = 0.95 * (len(ordered) - 1)
    lower = int(math.floor(rank))
    upper = int(math.ceil(rank))
    p95 = ordered[lower] if lower == upper else ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower)
    mean = sum(values) / len(values)
    cores = max(1, int(logical_cores))
    return {
        "sample_count": len(values),
        "duration_seconds": float(duration_seconds),
        "mean_one_core_percent": mean,
        "p95_one_core_percent": p95,
        "max_one_core_percent": max(values),
        "mean_machine_percent": mean / cores,
        "logical_cores": cores,
    }


def classify_thread_role(name: str) -> str:
    """Map a macOS thread name to a stable, reviewable role."""

    lowered = re.sub(r"[^a-z0-9]+", " ", str(name).lower()).strip()
    if not lowered:
        return "other"
    if "cvdisplaylink" in lowered or "displaylink" in lowered or "display link" in lowered:
        return "display_link"
    if any(token in lowered for token in ("renderer", "ghostty", "metal", "iosurface", "core animation")):
        return "renderer"
    if any(token in lowered for token in ("pty", "terminal", "tty", "shell")):
        return "pty_io"
    if "main" in lowered or lowered in {"com.apple.main-thread", "com.apple.main thread"}:
        return "main"
    if any(token in lowered for token in ("dispatch", "work queue", "worker")):
        return "dispatch"
    if any(token in lowered for token in ("io", "event", "socket")):
        return "io"
    return "other"


def group_thread_names(names: Iterable[str]) -> dict[str, int]:
    roles: dict[str, int] = {}
    for name in names:
        role = classify_thread_role(name)
        roles[role] = roles.get(role, 0) + 1
    return dict(sorted(roles.items()))


def parse_thread_listing(text: str) -> dict[str, Any]:
    """Parse ``ps -M`` output and return total plus role counts."""

    names: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or re.search(r"(?i)\b(thread|tid|thcomm|command)\b", line) and not re.match(r"^\d", line):
            continue
        # ``ps -M -o tid=,thcomm=`` starts with a numeric TID.  Keep the
        # remainder intact because role names can contain spaces.
        if re.match(r"^\d+\b", line):
            names.append(re.sub(r"^\d+\s*", "", line).strip())
        else:
            # Be tolerant of the default table format: PID/TID columns are
            # numeric, and the final token(s) are the thread command.
            fields = line.split()
            if len(fields) >= 2 and any(field.isdigit() for field in fields[:2]):
                names.append(" ".join(fields[2:] or fields[1:]))
    roles = group_thread_names(names)
    return {"total": len(names), "roles": roles}


def linear_slope(x_values: Sequence[float], y_values: Sequence[float]) -> float | None:
    """Return least-squares slope, or ``None`` for fewer than two x values."""

    if len(x_values) != len(y_values) or len(x_values) < 2:
        return None
    x_mean = sum(x_values) / len(x_values)
    y_mean = sum(y_values) / len(y_values)
    denominator = sum((x - x_mean) ** 2 for x in x_values)
    if denominator == 0:
        return None
    return sum((x - x_mean) * (y - y_mean) for x, y in zip(x_values, y_values)) / denominator


@dataclass(frozen=True)
class BudgetConfig:
    """Initial generous guardrails from issue #9812.

    Slope values are deliberately explicit calibration knobs.  They remain in
    the artifact so a hosted-runner calibration can change them without
    changing the fixture or collector contract.
    """

    app_base_bytes: int = 500 * BYTES_PER_MIB
    app_hidden_bytes: int = 3 * BYTES_PER_MIB
    app_visible_bytes: int = 50 * BYTES_PER_MIB
    gpu_base_bytes: int = 150 * BYTES_PER_MIB
    gpu_visible_bytes: int = 50 * BYTES_PER_MIB
    idle_cpu_percent: float = 10.0
    soak_ratio: float = 1.10
    hidden_gpu_slope_bytes: float = 0.25 * BYTES_PER_MIB
    hidden_cpu_slope_percent: float = 0.05
    hidden_thread_slope: float = 0.25
    display_link_base_threads: int = 2
    display_link_per_visible: int = 1
    total_thread_base: int = 32
    total_thread_per_visible: int = 4
    total_thread_per_hidden: float = 0.25

    def as_dict(self) -> dict[str, Any]:
        return {
            "app": {
                "base_bytes": self.app_base_bytes,
                "per_hidden_bytes": self.app_hidden_bytes,
                "per_visible_bytes": self.app_visible_bytes,
            },
            "gpu": {
                "base_bytes": self.gpu_base_bytes,
                "per_visible_bytes": self.gpu_visible_bytes,
                "hidden_slope_bytes_per_terminal": self.hidden_gpu_slope_bytes,
            },
            "cpu": {
                "idle_one_core_percent": self.idle_cpu_percent,
                "hidden_slope_percent_per_terminal": self.hidden_cpu_slope_percent,
                "minimum_sample_seconds": MIN_CPU_SECONDS,
            },
            "soak": {"max_ratio": self.soak_ratio},
            "threads": {
                "hidden_slope_per_terminal": self.hidden_thread_slope,
                "display_link_base": self.display_link_base_threads,
                "display_link_per_visible": self.display_link_per_visible,
                "total_base": self.total_thread_base,
                "total_per_visible": self.total_thread_per_visible,
                "total_per_hidden": self.total_thread_per_hidden,
            },
        }

    def app_limit(self, live: int, visible: int) -> int:
        return self.app_base_bytes + max(0, live - visible) * self.app_hidden_bytes + visible * self.app_visible_bytes

    def gpu_limit(self, visible: int) -> int:
        return self.gpu_base_bytes + visible * self.gpu_visible_bytes

    def display_link_limit(self, visible: int) -> int:
        return self.display_link_base_threads + visible * self.display_link_per_visible

    def total_thread_limit(self, live: int, visible: int) -> int:
        hidden = max(0, live - visible)
        return math.ceil(self.total_thread_base + visible * self.total_thread_per_visible + hidden * self.total_thread_per_hidden)


DEFAULT_BUDGETS = BudgetConfig()


def _number(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _bytes(value: Any) -> float | None:
    number = _number(value)
    return number if number is not None else None


def retained_gpu_bytes(snapshot: Mapping[str, Any]) -> int | None:
    """Return a conservative GPU total without double-counting nested fields.

    ``Dirty Graphics`` can include IOSurface/IOAccelerator on some macOS
    releases.  We therefore use the larger of the graphics bucket and the two
    explicit buckets together, while retaining all three raw values in the
    artifact.
    """

    gpu = snapshot.get("gpu") if isinstance(snapshot.get("gpu"), Mapping) else snapshot
    dirty = _bytes(gpu.get("dirty_graphics_bytes"))
    iosurface = _bytes(gpu.get("iosurface_bytes"))
    accelerator = _bytes(gpu.get("ioaccelerator_bytes"))
    explicit = [value for value in (iosurface, accelerator) if value is not None]
    candidates = [value for value in (dirty, sum(explicit) if explicit else None) if value is not None]
    if not candidates:
        return None
    return int(max(candidates))


def _snapshot_value(snapshot: Mapping[str, Any], key: str) -> Any:
    if key in snapshot:
        return snapshot[key]
    return snapshot.get("metrics", {}).get(key) if isinstance(snapshot.get("metrics"), Mapping) else None


def _failure(code: str, message: str, **details: Any) -> dict[str, Any]:
    return {"code": code, "message": message, **details}


def evaluate_run(run: Mapping[str, Any], budgets: BudgetConfig = DEFAULT_BUDGETS) -> list[dict[str, Any]]:
    """Evaluate one fixture size, excluding child workload from app budgets."""

    fixture = run.get("fixture") if isinstance(run.get("fixture"), Mapping) else run
    live = int(fixture.get("live_terminal_count", fixture.get("live_terminals", 0)) or 0)
    visible = int(fixture.get("visible_terminal_count", fixture.get("visible_terminals", 0)) or 0)
    hidden = max(0, live - visible)
    failures: list[dict[str, Any]] = []
    if live not in FIXTURE_SIZES:
        failures.append(_failure("fixture_size", f"unsupported fixture size {live}; expected one of {FIXTURE_SIZES}", observed=live))
    if visible != min(VISIBLE_SURFACE_LIMIT, live):
        failures.append(_failure("visible_count", f"expected {min(VISIBLE_SURFACE_LIMIT, live)} visible terminals, got {visible}", observed=visible))

    first = run.get("first_settled") or run.get("initial") or {}
    post = run.get("post_cycle_settled") or run.get("post_cycle") or {}
    for label, snapshot in (("first_settled", first), ("post_cycle_settled", post)):
        if not isinstance(snapshot, Mapping):
            failures.append(_failure("missing_snapshot", f"{label} measurement is missing"))
            continue
        footprint = _bytes(_snapshot_value(snapshot, "phys_footprint_bytes"))
        peak = _bytes(_snapshot_value(snapshot, "phys_footprint_peak_bytes"))
        observed_footprint = max(value for value in (footprint, peak) if value is not None) if any(value is not None for value in (footprint, peak)) else None
        if observed_footprint is None:
            failures.append(_failure("app_footprint_unavailable", f"{label} did not report a physical app footprint"))
        elif observed_footprint > budgets.app_limit(live, visible):
            failures.append(_failure("app_footprint", f"{label} app footprint exceeds target-scale budget", observed_bytes=observed_footprint, budget_bytes=budgets.app_limit(live, visible), live_terminals=live, visible_terminals=visible))
        gpu = retained_gpu_bytes(snapshot)
        if gpu is None:
            failures.append(_failure("gpu_unavailable", f"{label} did not report a GPU footprint category"))
        elif gpu > budgets.gpu_limit(visible):
            failures.append(_failure("gpu_budget", f"{label} retained GPU memory exceeds target-scale budget", observed_bytes=gpu, budget_bytes=budgets.gpu_limit(visible), live_terminals=live, visible_terminals=visible))

    cpu = run.get("cpu") if isinstance(run.get("cpu"), Mapping) else {}
    duration = _number(cpu.get("duration_seconds"))
    mean_cpu = _number(cpu.get("mean_one_core_percent"))
    if duration is None:
        failures.append(_failure("cpu_unavailable", "CPU sample duration is missing"))
    elif duration < MIN_CPU_SECONDS:
        failures.append(_failure("cpu_duration", f"CPU sample lasted {duration:.2f}s; at least {MIN_CPU_SECONDS:.0f}s is required", observed_seconds=duration, minimum_seconds=MIN_CPU_SECONDS))
    if mean_cpu is None:
        failures.append(_failure("cpu_unavailable", "CPU sample has no one-core mean"))
    elif mean_cpu > budgets.idle_cpu_percent:
        failures.append(_failure("idle_cpu", "settled idle CPU exceeds the one-core budget", observed_percent=mean_cpu, budget_percent=budgets.idle_cpu_percent, live_terminals=live, visible_terminals=visible))

    threads = run.get("threads") if isinstance(run.get("threads"), Mapping) else {}
    total_threads = _number(threads.get("total"))
    roles = threads.get("roles") if isinstance(threads.get("roles"), Mapping) else {}
    if total_threads is None:
        failures.append(_failure("thread_unavailable", "thread count is missing"))
    elif total_threads > budgets.total_thread_limit(live, visible):
        failures.append(_failure("thread_model", "thread count exceeds the documented Ghostty runtime model", observed=int(total_threads), budget=budgets.total_thread_limit(live, visible), live_terminals=live, visible_terminals=visible))
    display_links = _number(roles.get("display_link"))
    if display_links is not None and display_links > budgets.display_link_limit(visible):
        failures.append(_failure("display_link_model", "CVDisplayLink/display-link threads exceed the visible-surface model", observed=int(display_links), budget=budgets.display_link_limit(visible), visible_terminals=visible))

    first_footprint = _bytes(_snapshot_value(first, "phys_footprint_bytes"))
    post_footprint = _bytes(_snapshot_value(post, "phys_footprint_bytes"))
    if first_footprint and post_footprint and post_footprint > first_footprint * budgets.soak_ratio:
        failures.append(_failure("soak_footprint", "post-cycle settled footprint is above the reveal/hide soak bound", first_bytes=first_footprint, post_bytes=post_footprint, ratio=post_footprint / first_footprint, budget_ratio=budgets.soak_ratio))
    first_gpu = retained_gpu_bytes(first)
    post_gpu = retained_gpu_bytes(post)
    if first_gpu and post_gpu and post_gpu > first_gpu * budgets.soak_ratio:
        failures.append(_failure("soak_gpu", "post-cycle settled GPU memory is above the reveal/hide soak bound", first_bytes=first_gpu, post_bytes=post_gpu, ratio=post_gpu / first_gpu, budget_ratio=budgets.soak_ratio))
    # ``child_workload`` is intentionally not read by any budget calculation;
    # it remains reporting-only in the artifact.
    runtime = fixture.get("runtime_terminals") if isinstance(fixture.get("runtime_terminals"), Mapping) else {}
    reported_runtime = runtime.get("reported_count")
    if reported_runtime is not None and int(reported_runtime) != live:
        failures.append(_failure("runtime_count", "debug.terminals did not report every fixture terminal", observed=int(reported_runtime), expected=live))
    return failures


def evaluate_series(runs: Sequence[Mapping[str, Any]], budgets: BudgetConfig = DEFAULT_BUDGETS) -> dict[str, Any]:
    """Evaluate per-size budgets and hidden-terminal slopes."""

    failures: list[dict[str, Any]] = []
    for run in runs:
        failures.extend(evaluate_run(run, budgets))

    points: list[tuple[int, int, float | None, float | None, float | None]] = []
    for run in runs:
        fixture = run.get("fixture") if isinstance(run.get("fixture"), Mapping) else run
        live = int(fixture.get("live_terminal_count", fixture.get("live_terminals", 0)) or 0)
        visible = int(fixture.get("visible_terminal_count", fixture.get("visible_terminals", 0)) or 0)
        hidden = max(0, live - visible)
        post = run.get("post_cycle_settled") or run.get("post_cycle") or {}
        gpu = retained_gpu_bytes(post) if isinstance(post, Mapping) else None
        cpu = run.get("cpu") if isinstance(run.get("cpu"), Mapping) else {}
        mean_cpu = _number(cpu.get("mean_one_core_percent"))
        threads = run.get("threads") if isinstance(run.get("threads"), Mapping) else {}
        total_threads = _number(threads.get("total"))
        points.append((live, hidden, gpu, mean_cpu, total_threads))
    points.sort(key=lambda item: item[0])

    def slope_for(index: int) -> float | None:
        # The one-surface point has fewer visible terminals by contract.  Use
        # the fixed-five-visible points for a hidden-terminal slope so the
        # visible-renderer intercept cannot masquerade as hidden growth.
        slope_points = [item for item in points if item[0] >= VISIBLE_SURFACE_LIMIT]
        if len(slope_points) < 2:
            return None
        pairs = [(float(item[1]), float(item[index])) for item in slope_points if item[index] is not None]
        return linear_slope([pair[0] for pair in pairs], [pair[1] for pair in pairs])

    gpu_slope = slope_for(2)
    cpu_slope = slope_for(3)
    thread_slope = slope_for(4)
    slopes = {
        "hidden_gpu_bytes_per_terminal": gpu_slope,
        "hidden_cpu_percent_per_terminal": cpu_slope,
        "hidden_thread_count_per_terminal": thread_slope,
    }
    if gpu_slope is not None and gpu_slope > budgets.hidden_gpu_slope_bytes:
        failures.append(_failure("gpu_hidden_slope", "retained GPU memory grows with hidden terminals", observed_bytes_per_terminal=gpu_slope, budget_bytes_per_terminal=budgets.hidden_gpu_slope_bytes))
    if cpu_slope is not None and cpu_slope > budgets.hidden_cpu_slope_percent:
        failures.append(_failure("cpu_hidden_slope", "idle CPU grows with hidden terminals", observed_percent_per_terminal=cpu_slope, budget_percent_per_terminal=budgets.hidden_cpu_slope_percent))
    if thread_slope is not None and thread_slope > budgets.hidden_thread_slope:
        failures.append(_failure("thread_hidden_slope", "thread count grows with hidden terminals beyond the runtime model", observed_per_terminal=thread_slope, budget_per_terminal=budgets.hidden_thread_slope))

    return {
        "failures": failures,
        "slopes": slopes,
        "point_count": len(points),
        "passed": not failures,
    }


def make_artifact(
    runs: Sequence[Mapping[str, Any]],
    *,
    metadata: Mapping[str, Any],
    budgets: BudgetConfig = DEFAULT_BUDGETS,
    advisory: bool = True,
    collector_warnings: Sequence[str] = (),
    reveal_hide_cycles: int = 20,
) -> dict[str, Any]:
    evaluation = evaluate_series(runs, budgets)
    failures = evaluation["failures"]
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "metadata": dict(metadata),
        "budgets": budgets.as_dict(),
        "advisory": bool(advisory),
        "fixture_contract": {
            "sizes": list(FIXTURE_SIZES),
            "visible_surface_limit": VISIBLE_SURFACE_LIMIT,
            "reveal_hide_cycles": int(reveal_hide_cycles),
            "minimum_cpu_seconds": MIN_CPU_SECONDS,
            "idle_pty": True,
            "child_workload_charged_to_app": False,
        },
        "runs": [dict(run) for run in runs],
        "evaluation": evaluation,
        "collector_warnings": list(collector_warnings),
        "status": "advisory_failures" if failures and advisory else ("failed" if failures else "passed"),
    }


def fixture_contract(live_terminals: int, scrollback_bytes: int, cycles: int = 20) -> dict[str, Any]:
    visible = min(VISIBLE_SURFACE_LIMIT, live_terminals)
    return {
        "live_terminal_count": int(live_terminals),
        "visible_terminal_count": visible,
        "hidden_terminal_count": max(0, live_terminals - visible),
        "scrollback_bytes": int(scrollback_bytes),
        "reveal_hide_cycles": int(cycles),
        "idle_pty": True,
        "child_coding_agents": False,
        "child_builds": False,
    }


def balanced_layout(pane_count: int) -> dict[str, Any]:
    """Build a deterministic split tree with one terminal per visible pane."""

    if pane_count < 1:
        raise ValueError("pane_count must be positive")
    if pane_count == 1:
        return {"pane": {"surfaces": [{"type": "terminal", "name": "target-scale-001"}]}}

    left_count = pane_count // 2
    right_count = pane_count - left_count

    def rename(node: dict[str, Any], counter: list[int]) -> dict[str, Any]:
        if "pane" in node:
            counter[0] += 1
            node["pane"]["surfaces"][0]["name"] = f"target-scale-{counter[0]:03d}"
        else:
            for child in node.get("children", []):
                rename(child, counter)
        return node

    tree = {
        "direction": "horizontal" if pane_count % 2 else "vertical",
        "split": 0.5,
        "children": [balanced_layout(left_count), balanced_layout(right_count)],
    }
    return rename(tree, [0])


def synthetic_run(live: int, fault: str | None = None) -> dict[str, Any]:
    """Produce deterministic data for contract tests and ``--self-test``."""

    visible = min(VISIBLE_SURFACE_LIMIT, live)
    hidden = max(0, live - visible)
    physical = 300 * BYTES_PER_MIB + visible * 8 * BYTES_PER_MIB + hidden * 1 * BYTES_PER_MIB
    gpu = 100 * BYTES_PER_MIB + visible * 5 * BYTES_PER_MIB
    cpu = 2.0 + hidden * 0.005
    roles = {"main": 1, "renderer": 5 + visible * 2, "pty_io": min(live, 20) + 4, "display_link": visible + 1}
    post_physical = physical
    post_gpu = gpu
    if fault == "hidden-renderer":
        gpu += hidden * 2 * BYTES_PER_MIB
        post_gpu = gpu
    elif fault == "hidden-wakeup":
        cpu += hidden * 0.20
    elif fault == "retained-allocation":
        post_physical = int(physical * 1.25)
    elif fault == "display-link":
        roles["display_link"] += hidden
    elif fault:
        raise ValueError(f"unknown synthetic fault: {fault}")

    def snapshot(footprint: int, gpu_bytes: int) -> dict[str, Any]:
        return {
            "phys_footprint_bytes": footprint,
            "phys_footprint_peak_bytes": footprint,
            "gpu": {
                "dirty_graphics_bytes": gpu_bytes,
                "iosurface_bytes": gpu_bytes // 2,
                "ioaccelerator_bytes": gpu_bytes // 4,
                "retained_bytes": gpu_bytes,
            },
        }

    return {
        "fixture": {
            **fixture_contract(live, 64 * 1024),
            "runtime_terminals": {"reported_count": live, "runtime_ready_count": live},
        },
        "first_settled": snapshot(physical, gpu),
        "post_cycle_settled": snapshot(post_physical, post_gpu),
        "cpu": summarize_cpu_samples([cpu] * 30, MIN_CPU_SECONDS, logical_cores=8),
        "threads": {"total": sum(roles.values()), "roles": roles},
        "child_workload": {"process_count": 200, "rss_bytes": 10 * 1024**3},
    }


def self_test() -> dict[str, Any]:
    """Run the three acceptance fault injections plus a thread leak check."""

    checks = {
        "hidden-renderer": "gpu_hidden_slope",
        "hidden-wakeup": "cpu_hidden_slope",
        "retained-allocation": "soak_footprint",
        "display-link": "display_link_model",
    }
    results: dict[str, Any] = {}
    for fault, expected_code in checks.items():
        evaluation = evaluate_series([synthetic_run(size, fault) for size in FIXTURE_SIZES])
        codes = {failure["code"] for failure in evaluation["failures"]}
        results[fault] = {"expected": expected_code, "failure_codes": sorted(codes), "passed": expected_code in codes}
    return {"passed": all(item["passed"] for item in results.values()), "checks": results}
