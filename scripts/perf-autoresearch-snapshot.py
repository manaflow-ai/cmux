#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import math
import pathlib
import shutil
import subprocess
import sys
import threading
import time
from types import ModuleType
from typing import Any

WORKSPACE_COUNT = 12
SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL = 165_000
MIN_SNAPSHOT_SCROLLBACK_CHARS = 1_000_000
MINIMUM_TERMINAL_SURFACES = 40
DEFAULT_SAMPLE_COUNT = 5
DEFAULT_ITERATION_COUNT = 3
IN_FLIGHT_SAMPLE_INTERVAL_SECONDS = 0.02
_PROC_PID_RUSAGE: Any = None


class RusageInfoV0(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
    ]


def positive_integer(raw: str) -> int:
    value = int(raw)
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def load_fixture_module() -> ModuleType:
    module_path = pathlib.Path(__file__).with_name("perf-activation-session.py")
    spec = importlib.util.spec_from_file_location("cmux_perf_activation_session", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load fixture module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_args(args: argparse.Namespace) -> argparse.Namespace:
    return argparse.Namespace(
        tag=args.tag,
        app_path=args.app_path,
        fixture_root=args.fixture_root,
        output="",
        junit="",
        keep_fixture=False,
        no_fail_budget=False,
        workspace_count=WORKSPACE_COUNT,
        heavy_workspace_panes=8,
        other_workspace_panes=4,
        heavy_tabbed_panes=3,
        other_tabbed_panes=1,
        heavy_scrollback_lines=0,
        other_scrollback_lines=0,
        line_payload_chars=96,
        scrollback_target_chars=0,
        synthetic_scrollback_fallback=False,
        synthetic_scrollback_chars_per_terminal=SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL,
        real_scrollback_capture_timeout=0,
        real_scrollback_refresh_interval=0.5,
        launch_timeout=args.launch_timeout,
        scrollback_timeout=args.scrollback_timeout,
        snapshot_timeout=args.snapshot_timeout,
        budget_launch_socket_ready_ms=15_000,
        budget_restore_socket_ready_ms=15_000,
        budget_no_scrollback_snapshot_ms=250,
        budget_scrollback_snapshot_ms=1_500,
        budget_min_scrollback_chars=MIN_SNAPSHOT_SCROLLBACK_CHARS,
        budget_min_terminal_surfaces=MINIMUM_TERMINAL_SURFACES,
        budget_snapshot_samples=args.samples,
        fail_on_timing_budget=False,
    )


def validate_shape(payload: dict[str, Any], *, label: str) -> dict[str, Any]:
    shape = payload.get("shape")
    if not isinstance(shape, dict):
        raise RuntimeError(f"{label}: shape is not an object")
    if shape.get("workspaces") != WORKSPACE_COUNT:
        raise RuntimeError(
            f"{label}: shape.workspaces={shape.get('workspaces')!r}, expected {WORKSPACE_COUNT}"
        )
    terminals = shape.get("terminals")
    if isinstance(terminals, bool) or not isinstance(terminals, int) or terminals < MINIMUM_TERMINAL_SURFACES:
        raise RuntimeError(
            f"{label}: shape.terminals={terminals!r}, expected at least {MINIMUM_TERMINAL_SURFACES}"
        )
    return shape


def validate_payload(
    payload: Any,
    *,
    include_scrollback: bool,
    label: str,
    persist: bool = False,
    require_saved: bool = False,
) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise RuntimeError(f"{label}: RPC payload is not an object")
    if payload.get("include_scrollback") is not include_scrollback:
        raise RuntimeError(f"{label}: include_scrollback does not match request")
    if payload.get("persist") is not persist:
        raise RuntimeError(f"{label}: persist does not match request")
    if payload.get("built") is not True:
        raise RuntimeError(f"{label}: snapshot was not built")
    if require_saved and payload.get("saved") is not True:
        raise RuntimeError(f"{label}: persisted snapshot was not saved")
    value = payload.get("build_ms")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RuntimeError(f"{label}: build_ms is not numeric")
    if not math.isfinite(float(value)) or float(value) < 0:
        raise RuntimeError(f"{label}: build_ms is not a finite non-negative number")
    validate_shape(payload, label=label)
    return payload


def proc_memory_bytes(pid: int) -> tuple[int | None, int | None, str | None]:
    """Read resident size and physical footprint without spawning a process."""
    global _PROC_PID_RUSAGE
    if sys.platform != "darwin":
        return None, None, "proc_pid_rusage is only available on Darwin"
    try:
        if _PROC_PID_RUSAGE is None:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            function = libproc.proc_pid_rusage
            function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
            function.restype = ctypes.c_int
            _PROC_PID_RUSAGE = function
        info = RusageInfoV0()
        if _PROC_PID_RUSAGE(pid, 0, ctypes.byref(info)) != 0:
            return None, None, f"proc_pid_rusage failed with errno {ctypes.get_errno()}"
        return int(info.ri_resident_size), int(info.ri_phys_footprint), None
    except (AttributeError, OSError) as exc:
        return None, None, str(exc)


def ps_rss_bytes(pid: int) -> int:
    completed = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)],
        check=True,
        capture_output=True,
        text=True,
    )
    raw = completed.stdout.strip()
    if not raw or not raw.isdigit():
        raise RuntimeError(f"could not parse RSS for pid {pid}: {raw!r}")
    return int(raw) * 1024


def capture_memory(
    runner: Any,
    samples: list[dict[str, Any]],
    *,
    phase: str,
    started_at: float,
    **dimensions: Any,
) -> dict[str, Any]:
    proc = runner.proc
    if proc is None or proc.poll() is not None:
        raise RuntimeError(f"{phase}: cmux process is not running")
    resident, footprint, memory_error = proc_memory_bytes(proc.pid)
    rss_source = "proc_pid_rusage.ri_resident_size"
    if resident is None:
        resident = ps_rss_bytes(proc.pid)
        rss_source = "ps rss (KiB converted to bytes) fallback"
    sample: dict[str, Any] = {
        "sequence": len(samples),
        "phase": phase,
        "elapsed_ms": round((time.monotonic() - started_at) * 1000.0, 2),
        "pid": proc.pid,
        "rss_bytes": resident,
        "rss_source": rss_source,
        "physical_footprint_bytes": footprint,
    }
    sample.update(dimensions)
    if memory_error:
        sample["memory_capture_warning"] = memory_error
    samples.append(sample)
    return sample


def run_sampled_rpc(
    runner: Any,
    memory_samples: list[dict[str, Any]],
    *,
    memory_started_at: float,
    rpc_call: Any,
    **dimensions: Any,
) -> Any:
    """Sample proc_pid_rusage every 20 ms while one snapshot RPC is in flight."""
    proc = runner.proc
    if proc is None or proc.poll() is not None:
        raise RuntimeError("in_flight: cmux process is not running")

    rpc_started_at = time.monotonic()
    local_samples: list[dict[str, Any]] = []
    stop = threading.Event()
    ready = threading.Event()

    def record(sample_kind: str) -> None:
        resident, footprint, memory_error = proc_memory_bytes(proc.pid)
        sample: dict[str, Any] = {
            "phase": "in_flight",
            "sample_kind": sample_kind,
            "rpc_elapsed_ms": round((time.monotonic() - rpc_started_at) * 1000.0, 2),
            "elapsed_ms": round((time.monotonic() - memory_started_at) * 1000.0, 2),
            "pid": proc.pid,
            "rss_bytes": resident,
            "rss_source": "proc_pid_rusage.ri_resident_size",
            "physical_footprint_bytes": footprint,
        }
        sample.update(dimensions)
        if memory_error:
            sample["memory_capture_warning"] = memory_error
        local_samples.append(sample)

    def sample_until_stopped() -> None:
        record("sampler_start")
        ready.set()
        while not stop.wait(IN_FLIGHT_SAMPLE_INTERVAL_SECONDS):
            record("sampler_poll")

    sampler = threading.Thread(
        target=sample_until_stopped,
        name="cmux-memory-sampler",
        daemon=True,
    )
    sampler.start()
    if not ready.wait(timeout=1):
        stop.set()
        sampler.join(timeout=1)
        raise RuntimeError("in-flight memory sampler did not start")
    try:
        payload = rpc_call()
    finally:
        stop.set()
        sampler.join(timeout=1)
        if sampler.is_alive():
            raise RuntimeError("in-flight memory sampler did not stop")
        record("sampler_end")
        for in_flight_index, sample in enumerate(local_samples):
            sample["in_flight_index"] = in_flight_index
            sample["sequence"] = len(memory_samples)
            memory_samples.append(sample)
    return payload


def collect_samples(
    runner: Any,
    *,
    include_scrollback: bool,
    name: str,
    iteration: int,
    sample_count: int,
    synthetic_terminals: int | None,
    memory_samples: list[dict[str, Any]],
    memory_started_at: float,
) -> dict[str, Any]:
    request = {"include_scrollback": include_scrollback, "persist": False}
    seed_payloads: list[dict[str, Any]] = []

    def invoke(snapshot_kind: str, sample_index: int) -> dict[str, Any]:
        label = f"iteration[{iteration}].{name}.{snapshot_kind}[{sample_index}]"
        if synthetic_terminals is not None:
            seed = runner.rpc(
                "debug.session_snapshot_seed_scrollback",
                {"characters_per_terminal": SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL},
                timeout=max(60, runner.args.snapshot_timeout),
            )
            if not isinstance(seed, dict):
                raise RuntimeError(f"{label}: synthetic scrollback seed payload is not an object")
            expected_chars = SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL * synthetic_terminals
            if seed.get("characters_per_terminal") != SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL:
                raise RuntimeError(f"{label}: synthetic scrollback seed size does not match the request")
            if seed.get("terminals") != synthetic_terminals:
                raise RuntimeError(f"{label}: synthetic scrollback terminal count does not match the fixture")
            if seed.get("scrollback_chars") != expected_chars:
                raise RuntimeError(f"{label}: synthetic scrollback character count does not match the fixture")
            seed_payloads.append(seed)
        payload = validate_payload(
            run_sampled_rpc(
                runner,
                memory_samples,
                memory_started_at=memory_started_at,
                rpc_call=lambda: runner.rpc(
                    "debug.session_snapshot_benchmark",
                    request,
                    timeout=max(60, runner.args.snapshot_timeout),
                ),
                iteration=iteration,
                variant=name,
                snapshot_kind=snapshot_kind,
                snapshot_index=sample_index,
            ),
            include_scrollback=include_scrollback,
            label=label,
        )
        return payload

    warmup = invoke("warmup", 0)
    samples = [invoke("timed", index) for index in range(sample_count)]
    collected: dict[str, Any] = {
        "warmup": warmup,
        "samples": samples,
        "build_ms": [float(sample["build_ms"]) for sample in samples],
        "sample_count": len(samples),
    }
    if seed_payloads:
        collected["synthetic_seed_payloads"] = seed_payloads
    return collected


def phase_delta(
    samples: list[dict[str, Any]],
    field: str,
    *,
    before_phase: str,
    after_phase: str,
    peak_phases: set[str] | None = None,
) -> dict[str, int] | None:
    before_samples = [sample for sample in samples if sample.get("phase") == before_phase]
    after_samples = [sample for sample in samples if sample.get("phase") == after_phase]
    if not before_samples or not after_samples:
        return None
    before = before_samples[-1].get(field)
    after = after_samples[-1].get(field)
    if not isinstance(before, int) or not isinstance(after, int):
        return None
    result = {
        "before_bytes": before,
        "after_bytes": after,
        "delta_bytes": after - before,
    }
    if peak_phases is not None:
        values = [
            sample[field]
            for sample in samples
            if sample.get("phase") in peak_phases and isinstance(sample.get(field), int)
        ]
        if values:
            peak = max(values)
            result["peak_bytes"] = peak
            result["peak_delta_bytes"] = peak - before
    return result


def memory_delta(samples: list[dict[str, Any]], field: str) -> dict[str, int] | None:
    return phase_delta(
        samples,
        field,
        before_phase="before_snapshots",
        after_phase="after_snapshots",
        peak_phases={"before_snapshots", "in_flight", "after_snapshots"},
    )


def write_result(path: pathlib.Path, result: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def finalize_status(result: dict[str, Any]) -> None:
    failures = result.get("failures") or []
    cleanup_errors = result.get("cleanup_errors") or []
    passed = not failures and not cleanup_errors
    result["passed"] = passed
    result["status"] = "pass" if passed else "fail"
    result["pass_fail"] = {
        "passed": passed,
        "status": result["status"],
        "failure_count": len(failures),
        "cleanup_error_count": len(cleanup_errors),
    }


def run(args: argparse.Namespace) -> dict[str, Any]:
    memory_samples: list[dict[str, Any]] = []
    result: dict[str, Any] = {
        "tag": args.tag,
        "app_path": args.app_path,
        "source": {"requested_ref": args.source_ref, "sha": args.source_sha},
        "configuration": {
            "workspace_count": WORKSPACE_COUNT,
            "sample_count_per_variant_per_iteration": args.samples,
            "iteration_count": args.iterations,
            "snapshot_variants": ["without_scrollback", "with_synthetic_scrollback"],
            "synthetic_scrollback_chars_per_terminal": SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL,
            "warmup_count_per_variant_per_iteration": 1,
            "snapshots_persist": False,
            "in_flight_sample_interval_ms": int(IN_FLIGHT_SAMPLE_INTERVAL_SECONDS * 1000),
        },
        "benchmark_contract": {
            "workspace_count": WORKSPACE_COUNT,
            "minimum_terminal_surfaces": MINIMUM_TERMINAL_SURFACES,
            "heavy_scrollback_lines": 0,
            "other_scrollback_lines": 0,
            "synthetic_scrollback_chars_per_terminal": SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL,
        },
        "measurements": {},
        "fixture": {},
        "budgets": {},
        "failures": [],
        "samples": memory_samples,
        "memory": {
            "units": "bytes",
            "rss_source": "proc_pid_rusage.ri_resident_size; ps RSS only as an outside-loop fallback",
            "physical_footprint_source": "proc_pid_rusage RUSAGE_INFO_V0",
            "in_flight_sampling": {
                "interval_ms": int(IN_FLIGHT_SAMPLE_INTERVAL_SECONDS * 1000),
                "source": "proc_pid_rusage only",
                "ordering": "RPC order, then sampler_start/polls/sampler_end order within each RPC",
            },
            "samples": memory_samples,
            "deltas": {},
        },
        "cleanup": {
            "runner_constructed": False,
            "stop_app": "not_attempted",
            "clean_persisted_state": "not_attempted",
            "fixture_deletion": "not_attempted",
        },
    }
    runner: Any = None
    execution_stage = "load_fixture_module"
    try:
        fixture = load_fixture_module()
        execution_stage = "construct_runner"
        runner = fixture.CmuxPerfRunner(fixture_args(args))
        runner.result.update(
            {
                "source": result["source"],
                "configuration": result["configuration"],
                "benchmark_contract": result["benchmark_contract"],
                "samples": memory_samples,
                "memory": result["memory"],
                "cleanup": result["cleanup"],
            }
        )
        result = runner.result
        result["cleanup"]["runner_constructed"] = True

        execution_stage = "check_paths"
        runner.check_paths()
        execution_stage = "initial_stop_app"
        runner.stop_app()
        execution_stage = "initial_clean_persisted_state"
        runner.clean_persisted_state()
        execution_stage = "launch"
        runner.launch("launch")
        execution_stage = "create_fixture"
        terminals = runner.create_fixture()
        execution_stage = "seed_scrollback"
        runner.seed_scrollback(terminals)
        if result["fixture"].get("workspaces") != WORKSPACE_COUNT:
            raise RuntimeError(
                f"fixture workspace count is {result['fixture'].get('workspaces')}, expected {WORKSPACE_COUNT}"
            )
        terminal_surfaces = result["fixture"].get("terminal_surfaces")
        if isinstance(terminal_surfaces, bool) or not isinstance(terminal_surfaces, int):
            raise RuntimeError(f"invalid fixture terminal surface count: {terminal_surfaces!r}")
        if terminal_surfaces < MINIMUM_TERMINAL_SURFACES:
            raise RuntimeError(
                f"fixture has {terminal_surfaces} terminals, expected at least {MINIMUM_TERMINAL_SURFACES}"
            )
        if result["fixture"].get("scrollback_pending") != 0:
            raise RuntimeError("zero-live-scrollback fixture did not settle")

        execution_stage = "repeated_snapshots"
        memory_started_at = time.monotonic()
        capture_memory(
            runner,
            memory_samples,
            phase="before_snapshots",
            started_at=memory_started_at,
        )
        iterations: list[dict[str, Any]] = []
        result["measurements"]["snapshot_iterations"] = iterations
        for iteration in range(args.iterations):
            no_scrollback = collect_samples(
                runner,
                include_scrollback=False,
                name="without_scrollback",
                iteration=iteration,
                sample_count=args.samples,
                synthetic_terminals=None,
                memory_samples=memory_samples,
                memory_started_at=memory_started_at,
            )
            for index, sample in enumerate(no_scrollback["samples"]):
                if sample["shape"].get("scrollback_chars") != 0:
                    raise RuntimeError(
                        f"iteration[{iteration}].without_scrollback.samples[{index}] contains scrollback"
                    )

            with_scrollback = collect_samples(
                runner,
                include_scrollback=True,
                name="with_synthetic_scrollback",
                iteration=iteration,
                sample_count=args.samples,
                synthetic_terminals=terminal_surfaces,
                memory_samples=memory_samples,
                memory_started_at=memory_started_at,
            )
            for index, sample in enumerate(with_scrollback["samples"]):
                scrollback_chars = sample["shape"].get("scrollback_chars")
                if not isinstance(scrollback_chars, int) or scrollback_chars < MIN_SNAPSHOT_SCROLLBACK_CHARS:
                    raise RuntimeError(
                        f"iteration[{iteration}].with_synthetic_scrollback.samples[{index}] "
                        f"scrollback_chars={scrollback_chars!r}, expected at least {MIN_SNAPSHOT_SCROLLBACK_CHARS}"
                    )
            iterations.append(
                {
                    "iteration": iteration,
                    "without_scrollback": no_scrollback,
                    "with_synthetic_scrollback": with_scrollback,
                }
            )

        capture_memory(
            runner,
            memory_samples,
            phase="after_snapshots",
            started_at=memory_started_at,
        )

        execution_stage = "persist_for_restore"
        restore_seed = runner.rpc(
            "debug.session_snapshot_seed_scrollback",
            {"characters_per_terminal": SYNTHETIC_SCROLLBACK_CHARS_PER_TERMINAL},
            timeout=max(60, runner.args.snapshot_timeout),
        )
        result["fixture"]["restore_synthetic_scrollback_seed"] = restore_seed
        persisted = validate_payload(
            runner.rpc(
                "debug.session_snapshot_benchmark",
                {"include_scrollback": True, "persist": True},
                timeout=max(60, runner.args.snapshot_timeout),
            ),
            include_scrollback=True,
            persist=True,
            require_saved=True,
            label="persist_for_restore",
        )
        result["measurements"]["persist_for_restore"] = persisted
        execution_stage = "restore_launch"
        runner.stop_app()
        runner.launch("restore")
        capture_memory(
            runner,
            memory_samples,
            phase="post_restore_ready",
            started_at=memory_started_at,
        )
        execution_stage = "post_restore_snapshot"
        post_restore = validate_payload(
            runner.rpc(
                "debug.session_snapshot_benchmark",
                {"include_scrollback": False, "persist": False},
                timeout=max(60, runner.args.snapshot_timeout),
            ),
            include_scrollback=False,
            label="post_restore_snapshot",
        )
        result["measurements"]["post_restore_no_scrollback_snapshot"] = post_restore
        result["fixture"]["post_restore_shape"] = post_restore["shape"]
        capture_memory(
            runner,
            memory_samples,
            phase="post_restore",
            started_at=memory_started_at,
        )
        result["memory"]["deltas"] = {
            "rss": memory_delta(memory_samples, "rss_bytes"),
            "physical_footprint": memory_delta(memory_samples, "physical_footprint_bytes"),
        }
        result["memory"]["deltas"]["post_restore_vs_before_snapshots"] = {
            "rss": phase_delta(
                memory_samples,
                "rss_bytes",
                before_phase="before_snapshots",
                after_phase="post_restore_ready",
            ),
            "physical_footprint": phase_delta(
                memory_samples,
                "physical_footprint_bytes",
                before_phase="before_snapshots",
                after_phase="post_restore_ready",
            ),
        }
        result["memory"]["deltas"]["post_restore_snapshot"] = {
            "rss": phase_delta(
                memory_samples,
                "rss_bytes",
                before_phase="post_restore_ready",
                after_phase="post_restore",
            ),
            "physical_footprint": phase_delta(
                memory_samples,
                "physical_footprint_bytes",
                before_phase="post_restore_ready",
                after_phase="post_restore",
            ),
        }
        result["memory"]["physical_footprint_available"] = any(
            isinstance(sample.get("physical_footprint_bytes"), int) for sample in memory_samples
        )
        result["failures"] = []
    except BaseException as exc:
        result.setdefault("failures", []).append(
            f"{execution_stage}: {type(exc).__name__}: {exc}"
        )
    finally:
        cleanup_errors: list[str] = []
        if runner is not None:
            result["cleanup"]["stop_app"] = "attempted"
            try:
                runner.stop_app()
                result["cleanup"]["stop_app"] = "success"
            except BaseException as exc:
                result["cleanup"]["stop_app"] = "failed"
                cleanup_errors.append(f"stop_app: {type(exc).__name__}: {exc}")

            result["cleanup"]["clean_persisted_state"] = "attempted"
            try:
                runner.clean_persisted_state()
                result["cleanup"]["clean_persisted_state"] = "success"
            except BaseException as exc:
                result["cleanup"]["clean_persisted_state"] = "failed"
                cleanup_errors.append(f"clean_persisted_state: {type(exc).__name__}: {exc}")

            result["cleanup"]["fixture_deletion"] = "attempted"
            try:
                if runner.fixture_root.exists():
                    shutil.rmtree(runner.fixture_root)
                result["cleanup"]["fixture_deletion"] = "success"
            except BaseException as exc:
                result["cleanup"]["fixture_deletion"] = "failed"
                cleanup_errors.append(f"fixture_deletion: {type(exc).__name__}: {exc}")
        else:
            result["cleanup"]["not_attempted_reason"] = "runner construction did not complete"
        if cleanup_errors:
            result.setdefault("cleanup_errors", []).extend(cleanup_errors)
    finalize_status(result)
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure cmux memory while repeatedly building deterministic session snapshots."
    )
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app-path", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--samples", type=positive_integer, default=DEFAULT_SAMPLE_COUNT)
    parser.add_argument("--iterations", type=positive_integer, default=DEFAULT_ITERATION_COUNT)
    parser.add_argument("--fixture-root", default="")
    parser.add_argument("--launch-timeout", type=float, default=45)
    parser.add_argument("--scrollback-timeout", type=float, default=180)
    parser.add_argument("--snapshot-timeout", type=float, default=120)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output = pathlib.Path(args.output).expanduser()
    try:
        result = run(args)
    except BaseException as exc:
        result = {
            "source": {"requested_ref": args.source_ref, "sha": args.source_sha},
            "configuration": {
                "workspace_count": WORKSPACE_COUNT,
                "sample_count_per_variant_per_iteration": args.samples,
                "iteration_count": args.iterations,
                "in_flight_sample_interval_ms": int(IN_FLIGHT_SAMPLE_INTERVAL_SECONDS * 1000),
            },
            "samples": [],
            "memory": {"units": "bytes", "samples": [], "deltas": {}},
            "cleanup": {
                "runner_constructed": False,
                "stop_app": "not_attempted",
                "clean_persisted_state": "not_attempted",
                "fixture_deletion": "not_attempted",
                "not_attempted_reason": "run escaped before managed cleanup completed",
            },
            "failures": [f"unmanaged_run_failure: {type(exc).__name__}: {exc}"],
        }
        finalize_status(result)
    write_result(output, result)
    if not result["passed"]:
        print(f"benchmark failed: {result.get('failures') or result.get('cleanup_errors')}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
