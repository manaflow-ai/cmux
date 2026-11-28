#!/usr/bin/env python3
"""Reproducible physical benchmark for dev-fleet warm build slots."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import select
import shutil
import signal
import stat
import statistics
import subprocess
import sys
import time
from typing import Any, Sequence

HERE = Path(__file__).resolve().parent
DEFAULT_HELPER = HERE / "dev-fleet-warm-slot.py"
GRAPH_NAMES = {"Package.swift", "Package.resolved", "project.pbxproj"}


def git(checkout: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(checkout), *args],
        check=check,
        capture_output=True,
        text=True,
        timeout=120,
    )


def gout(checkout: Path, *args: str) -> str:
    return git(checkout, *args).stdout.strip()


def clean(checkout: Path) -> bool:
    return gout(checkout, "status", "--porcelain=v1", "--untracked-files=all") == ""


def paths_for(checkout: Path, commit: str) -> list[str]:
    raw = gout(checkout, "diff-tree", "--no-commit-id", "--name-only", "-r", f"{commit}^", commit)
    return [line for line in raw.splitlines() if line]


def graph_path(path: str) -> bool:
    name = Path(path).name
    return (
        name in GRAPH_NAMES
        or ".xcodeproj/" in path
        or ".xcworkspace/" in path
        or path.endswith(".xcodeproj")
        or path.endswith(".xcworkspace")
    )


def source_path(path: str) -> bool:
    return path.startswith("Sources/") or (path.startswith("Packages/") and "/Sources/" in path)


def discover_history(checkout: Path, main: str, behind: int, limit: int) -> dict[str, Any]:
    main_sha = gout(checkout, "rev-parse", main)
    behind_sha = gout(checkout, "rev-parse", f"{main_sha}~{behind}")
    commits = gout(checkout, "rev-list", "--first-parent", f"--max-count={limit}", main_sha).splitlines()
    source_case = None
    graph_case = None
    for commit in commits[1:]:
        try:
            paths = paths_for(checkout, commit)
        except subprocess.SubprocessError:
            continue
        if source_case is None and paths and all(source_path(path) for path in paths):
            source_case = {"commit": commit, "parent": gout(checkout, "rev-parse", f"{commit}^"), "paths": paths}
        if graph_case is None and any(graph_path(path) for path in paths):
            graph_case = {"commit": commit, "parent": gout(checkout, "rev-parse", f"{commit}^"), "paths": paths}
        if source_case and graph_case:
            break
    if source_case is None:
        raise RuntimeError("no recent source-only first-parent commit found")
    if graph_case is None:
        raise RuntimeError("no recent package/project graph first-parent commit found")
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "checkout_head": gout(checkout, "rev-parse", "HEAD"),
        "main_ref": main,
        "main_commit": main_sha,
        "behind_count": behind,
        "behind_commit": behind_sha,
        "source_only": source_case,
        "graph_change": graph_case,
        "cases": [
            "cold_new_slot",
            "exact_base_warm",
            "warm_few_commits_behind",
            "source_only_change",
            "package_project_graph_change",
            "toolchain_change",
            "warmer_interrupted_by_real_work",
        ],
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def parse_json(stdout: str) -> dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    value = json.loads(stdout)
    if not isinstance(value, dict):
        raise RuntimeError("helper returned non-object JSON")
    return value


def run_helper(
    helper: Path,
    argv: Sequence[str],
    *,
    env: dict[str, str] | None = None,
    accepted: set[int] | None = None,
) -> dict[str, Any]:
    result = subprocess.run(
        [sys.executable, str(helper), *argv],
        text=True,
        capture_output=True,
        env=env,
        timeout=7200,
    )
    allowed = accepted or {0, 75, 130}
    if result.returncode not in allowed:
        raise RuntimeError(
            f"helper failed ({result.returncode}): {' '.join(argv)}\n{result.stderr[-4000:]}\n{result.stdout[-4000:]}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid helper JSON: {result.stdout[-4000:]}") from error
    if not isinstance(payload, dict):
        raise RuntimeError("helper JSON must be an object")
    payload["_helper_exit"] = result.returncode
    if result.stderr.strip():
        payload["_stderr"] = result.stderr[-4000:]
    return payload


def command_tail(command: Sequence[str]) -> list[str]:
    if not command:
        return []
    return ["--", *command]


def warm(
    helper: Path,
    state: Path,
    checkout: Path,
    slot: str,
    target: str,
    command: Sequence[str],
    *,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    return run_helper(
        helper,
        [
            "warm", "--machine-state", str(state), "--slot", slot,
            "--checkout", str(checkout), "--target", target,
            "--measure-disk",
            *command_tail(command),
        ],
        env=env,
    )


def task(
    helper: Path,
    state: Path,
    checkout: Path,
    slot: str,
    target: str,
    task_id: str,
    command: Sequence[str],
    *,
    known_at: float | None = None,
    env: dict[str, str] | None = None,
    lease_id: str | None = None,
    warm_generation_id: str | None = None,
) -> dict[str, Any]:
    argv = [
        "task-run", "--machine-state", str(state), "--slot", slot,
        "--checkout", str(checkout), "--target", target, "--task-id", task_id,
        "--measure-disk",
    ]
    if known_at is not None:
        argv += ["--known-at", str(known_at)]
    if lease_id:
        argv += ["--lease-id", lease_id]
    if warm_generation_id:
        argv += ["--warm-generation-id", warm_generation_id]
    argv += command_tail(command)
    return run_helper(helper, argv, env=env)


def cleanup(
    helper: Path,
    state: Path,
    slot: str,
    *,
    max_generations: int = 1,
    measure_bytes: bool = True,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    argv = [
        "cleanup",
        "--machine-state", str(state),
        "--slot", slot,
        "--max-generations", str(max_generations),
    ]
    if measure_bytes:
        argv.append("--measure-bytes")
    return run_helper(helper, argv, env=env)


def reserve(
    helper: Path,
    state: Path,
    checkout: Path,
    slot: str,
    authoritative_main: str,
    task_id: str,
    *,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    return run_helper(
        helper,
        [
            "task-base",
            "--machine-state", str(state),
            "--slot", slot,
            "--checkout", str(checkout),
            "--authoritative-main", authoritative_main,
            "--task-id", task_id,
        ],
        env=env,
    )


def task_from_reservation(
    helper: Path,
    state: Path,
    checkout: Path,
    slot: str,
    target: str,
    task_id: str,
    command: Sequence[str],
    reservation: dict[str, Any],
    *,
    known_at: float,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    return task(
        helper,
        state,
        checkout,
        slot,
        target,
        task_id,
        command,
        known_at=known_at,
        env=env,
        lease_id=reservation.get("lease_id") if reservation.get("status") == "warm_base" else None,
        warm_generation_id=reservation.get("warm_generation_id") if reservation.get("status") == "warm_base" else None,
    )


def wait_for_warmer_ready(fd: int, timeout: float = 180.0) -> bool:
    """Wait for the helper-owned readiness pipe without filesystem polling."""
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return False
    try:
        return os.read(fd, 1) == b"1"
    except OSError:
        return False


def clear_owned_warmer_state(state: Path, slot: str, pid: int) -> None:
    """Remove benchmark-owned stale warmer markers after its process exits."""
    lease_path = state / "slots" / slot / "lease.json"
    try:
        lease = json.loads(lease_path.read_text())
    except (OSError, ValueError):
        lease = {}
    if lease.get("kind") == "warmer" and lease.get("pid") == pid:
        lease_path.unlink(missing_ok=True)
    (state / "warmer-preempt.fifo").unlink(missing_ok=True)


def cleanup_warmer(
    state: Path,
    slot: str,
    process: subprocess.Popen[str],
) -> tuple[str, str]:
    """Terminate the owned warmer and its native group after benchmark failure."""
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        stdout, stderr = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        inflight_path = state / "slots" / slot / "inflight.json"
        try:
            inflight = json.loads(inflight_path.read_text())
        except (OSError, ValueError):
            inflight = {}
        pgid = inflight.get("process_group")
        if isinstance(pgid, int) and pgid > 0:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        inflight_path.unlink(missing_ok=True)
    clear_owned_warmer_state(state, slot, process.pid)
    return stdout, stderr


def run_preemption(
    helper: Path,
    state: Path,
    checkout: Path,
    target: str,
    command: Sequence[str],
) -> dict[str, Any]:
    slot = "slot"
    ready_r, ready_w = os.pipe()
    warmer_argv = [
        sys.executable, str(helper),
        "warm", "--machine-state", str(state), "--slot", slot,
        "--checkout", str(checkout), "--target", target,
        "--ready-fd", str(ready_w),
        *command_tail(command),
    ]
    try:
        warmer = subprocess.Popen(
            warmer_argv,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(ready_w,),
            start_new_session=True,
        )
    finally:
        os.close(ready_w)
    try:
        if not wait_for_warmer_ready(ready_r):
            stdout, stderr = cleanup_warmer(state, slot, warmer)
            return {
                "status": "skipped",
                "reason": "warmer_finished_before_task_arrived",
                "warmer_stdout": stdout[-4000:],
                "warmer_stderr": stderr[-4000:],
            }
        known_at = time.time()
        try:
            task_result = task(
                helper,
                state,
                checkout,
                slot,
                target,
                "preempt-real-work",
                command,
                known_at=known_at,
            )
        except BaseException:
            cleanup_warmer(state, slot, warmer)
            raise
        try:
            stdout, stderr = warmer.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            stdout, stderr = cleanup_warmer(state, slot, warmer)
            return {
                "status": "invalid",
                "reason": "warmer_preemption_timeout",
                "warmer_stdout": stdout[-4000:],
                "warmer_stderr": stderr[-4000:],
                "task": task_result,
            }
    finally:
        os.close(ready_r)
    try:
        warm_result = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        warm_result = {"status": "unknown", "stdout": (stdout or "")[-4000:]}
    warm_result["_helper_exit"] = warmer.returncode
    if stderr:
        warm_result["_stderr"] = stderr[-4000:]
    if warm_result.get("status") != "yielded":
        return {
            "status": "invalid",
            "reason": "warmer_did_not_yield",
            "warmer": warm_result,
            "task": task_result,
        }
    return {"status": "completed", "warmer": warm_result, "task": task_result}


def receipt_from(result: dict[str, Any]) -> dict[str, Any] | None:
    value = result.get("receipt")
    return value if isinstance(value, dict) else None


def bytes_under(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except FileNotFoundError:
                pass
    return total


def event_journal_paths(path: Path) -> list[Path]:
    """Return retained telemetry oldest-first, including an archive-only crash state."""
    if path.is_dir():
        bases = {
            candidate if candidate.name == "events.jsonl" else candidate.with_name("events.jsonl")
            for candidate in path.rglob("events.jsonl*")
            if candidate.name in {"events.jsonl", "events.jsonl.1"}
        }
    else:
        bases = {path}

    journals: list[Path] = []
    for current in sorted(bases, key=str):
        archive = current.with_name(f"{current.name}.1")
        if archive.exists():
            journals.append(archive)
        if current.exists():
            journals.append(current)
    return journals


def cold_generation_count(state_root: Path, namespace: str) -> int:
    """Count generated cold directories without traversing any symlink ancestor."""
    count = 0
    try:
        cases = list(state_root.iterdir())
    except OSError:
        return 0

    for case in cases:
        try:
            if not stat.S_ISDIR(case.lstat().st_mode):
                continue
            slots = case / "slots"
            if not stat.S_ISDIR(slots.lstat().st_mode):
                continue
            slot_entries = list(slots.iterdir())
        except OSError:
            continue

        for slot in slot_entries:
            try:
                if not stat.S_ISDIR(slot.lstat().st_mode):
                    continue
                cache = slot / "cache"
                if not stat.S_ISDIR(cache.lstat().st_mode):
                    continue
                root = cache / namespace
                if not stat.S_ISDIR(root.lstat().st_mode):
                    continue
                entries = list(root.iterdir())
            except OSError:
                continue

            for entry in entries:
                name = entry.name
                try:
                    mode = entry.lstat().st_mode
                except OSError:
                    continue
                if (
                    len(name) == 32
                    and all(character in "0123456789abcdef" for character in name)
                    and stat.S_ISDIR(mode)
                ):
                    count += 1
    return count


def summarize(results: dict[str, Any], elapsed: float, state_root: Path) -> dict[str, Any]:
    tasks: list[dict[str, Any]] = []
    warms: list[dict[str, Any]] = []
    cleanup_passes: list[dict[str, Any]] = []
    fallbacks_required = 0
    for name, result in results.items():
        if name.endswith("_cleanup") and isinstance(result.get("reclaimed"), int):
            cleanup_passes.append({"case": name, **result})
        if name == "warmer_interrupted_by_real_work" and result.get("status") == "completed":
            warm_receipt = receipt_from(result.get("warmer", {}))
            task_receipt = receipt_from(result.get("task", {}))
            if warm_receipt:
                warms.append({"case": name, **warm_receipt})
            if task_receipt:
                tasks.append({"case": name, **task_receipt})
            if result.get("task", {}).get("status") == "cold_fallback_required":
                fallbacks_required += 1
            continue
        receipt = receipt_from(result)
        if receipt:
            if receipt.get("kind") == "task":
                tasks.append({"case": name, **receipt})
            elif receipt.get("kind") == "warm":
                warms.append({"case": name, **receipt})
        if result.get("status") == "cold_fallback_required":
            fallbacks_required += 1

    exact = sum(row.get("match_class") == "exact" for row in tasks)
    near = sum(row.get("match_class") == "near" for row in tasks)
    cold = sum(row.get("match_class") == "cold" for row in tasks)
    useful = exact + near
    warm_seconds = sum(float(row.get("wall_seconds", 0)) for row in warms)
    quarantines = 0
    recovered = 0
    for events in event_journal_paths(state_root):
        for line in events.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            quarantines += row.get("event") == "lineage_quarantined"
            recovered += row.get("event") == "native_run_recovered"

    cold_row = next((row for row in tasks if row["case"] == "cold_new_slot"), None)
    preempt_row = next((row for row in tasks if row["case"] == "warmer_interrupted_by_real_work"), None)
    slowdown = None
    queue_delta = None
    if cold_row and preempt_row:
        slowdown = round(float(preempt_row.get("wall_seconds", 0)) - float(cold_row.get("wall_seconds", 0)), 6)
        queue_delta = round(
            float(preempt_row.get("task_known_to_build_start_seconds", 0))
            - float(cold_row.get("task_known_to_build_start_seconds", 0)),
            6,
        )

    def stats(field: str) -> dict[str, float] | None:
        values = [float(row[field]) for row in tasks if isinstance(row.get(field), (int, float))]
        if not values:
            return None
        return {
            "count": len(values),
            "median": round(statistics.median(values), 6),
            "min": round(min(values), 6),
            "max": round(max(values), 6),
        }

    return {
        "schema_version": 1,
        "task_count": len(tasks),
        "exact_warm_tasks": exact,
        "near_warm_tasks": near,
        "cold_tasks": cold,
        "useful_warm_hit_percent": round(100.0 * useful / len(tasks), 3) if tasks else 0.0,
        "task_known_to_build_start_seconds": stats("task_known_to_build_start_seconds"),
        "first_build_wall_seconds": stats("wall_seconds"),
        "cold_cache_retirement_seconds": stats("cold_cache_retirement_seconds"),
        "swift_compile_count_total": sum(int(row.get("swift_compile_count", 0)) for row in tasks),
        "warmer_build_seconds": round(warm_seconds, 6),
        "warmer_duty_cycle_percent": round(100.0 * warm_seconds / elapsed, 3) if elapsed > 0 else 0.0,
        "real_work_build_slowdown_vs_cold_seconds": slowdown,
        "real_work_queue_delay_vs_cold_seconds": queue_delta,
        "cold_fallback_count": sum(bool(row.get("cold_fallback")) for row in tasks),
        "fallback_required_count": fallbacks_required,
        "quarantine_count": quarantines,
        "reset_required_count": quarantines,
        "recovery_count": recovered,
        "state_disk_bytes": bytes_under(state_root),
        "task_cache_growth_bytes": sum(int(row.get("disk_growth_bytes", 0)) for row in tasks),
        "warmer_cache_growth_bytes": sum(int(row.get("disk_growth_bytes", 0)) for row in warms),
        "cold_cleanup_pass_count": len(cleanup_passes),
        "cold_cleanup_wall_seconds": round(
            sum(float(row.get("wall_seconds", 0)) for row in cleanup_passes),
            6,
        ),
        "cold_cleanup_reclaimed_bytes": sum(
            int(row.get("reclaimed_bytes", 0)) for row in cleanup_passes
        ),
        "active_cold_generation_count": cold_generation_count(
            state_root,
            "cold-tasks",
        ),
        "retired_cold_generation_count": cold_generation_count(
            state_root,
            "retired-cold-tasks",
        ),
        "tasks": [
            {
                "case": row["case"],
                "match_class": row.get("match_class"),
                "distance_from_warm_source": row.get("distance_from_warm_source"),
                "task_known_to_build_start_seconds": row.get("task_known_to_build_start_seconds"),
                "first_build_wall_seconds": row.get("wall_seconds"),
                "swift_compile_count": row.get("swift_compile_count"),
                "cold_fallback": row.get("cold_fallback"),
                "fallback_reason": row.get("fallback_reason"),
                "warmer_in_flight_at_task_known": row.get("warmer_in_flight_at_task_known"),
                "disk_growth_bytes": row.get("disk_growth_bytes"),
                "cold_cache_retirement_seconds": row.get("cold_cache_retirement_seconds"),
            }
            for row in tasks
        ],
    }


def run_matrix(args: argparse.Namespace) -> dict[str, Any]:
    checkout = args.checkout.resolve()
    helper = args.helper.resolve()
    output = args.output.resolve()
    if not clean(checkout):
        raise RuntimeError("benchmark requires a clean checkout")
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("output directory must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    state_root = output / "machine-state"
    cases_dir = output / "cases"
    manifest = json.loads(args.manifest.read_text())
    original = gout(checkout, "rev-parse", "HEAD")
    command = list(args.command or [])
    if command and command[0] == "--":
        command = command[1:]
    results: dict[str, Any] = {}
    started = time.monotonic()

    def state(name: str) -> Path:
        return state_root / name

    def record(name: str, result: dict[str, Any]) -> None:
        results[name] = result
        write_json(cases_dir / f"{name}.json", result)

    try:
        main = manifest["main_commit"]
        cold_state = state("cold_new_slot")
        record("cold_new_slot", task(helper, cold_state, checkout, "slot", main, "cold", command))
        record(
            "cold_new_slot_cleanup",
            cleanup(helper, cold_state, "slot", max_generations=1, measure_bytes=True),
        )

        exact_state = state("exact_base_warm")
        record("exact_base_warm_seed", warm(helper, exact_state, checkout, "slot", main, command))
        exact_known = time.time()
        exact_reservation = reserve(helper, exact_state, checkout, "slot", main, "exact")
        record("exact_base_warm_reservation", exact_reservation)
        record(
            "exact_base_warm",
            task_from_reservation(
                helper, exact_state, checkout, "slot", main, "exact", command,
                exact_reservation, known_at=exact_known,
            ),
        )

        behind_state = state("warm_few_commits_behind")
        record("warm_few_commits_behind_seed", warm(helper, behind_state, checkout, "slot", manifest["behind_commit"], command))
        behind_known = time.time()
        behind_reservation = reserve(helper, behind_state, checkout, "slot", main, "behind")
        record("warm_few_commits_behind_reservation", behind_reservation)
        record(
            "warm_few_commits_behind",
            task_from_reservation(
                helper, behind_state, checkout, "slot", main, "behind", command,
                behind_reservation, known_at=behind_known,
            ),
        )

        source = manifest["source_only"]
        source_state = state("source_only_change")
        record("source_only_change_seed", warm(helper, source_state, checkout, "slot", source["parent"], command))
        source_known = time.time()
        source_reservation = reserve(helper, source_state, checkout, "slot", source["commit"], "source")
        record("source_only_change_reservation", source_reservation)
        record(
            "source_only_change",
            task_from_reservation(
                helper, source_state, checkout, "slot", source["commit"], "source", command,
                source_reservation, known_at=source_known,
            ),
        )

        graph = manifest["graph_change"]
        graph_state = state("package_project_graph_change")
        record("package_project_graph_change_seed", warm(helper, graph_state, checkout, "slot", graph["parent"], command))
        graph_known = time.time()
        graph_reservation = reserve(helper, graph_state, checkout, "slot", graph["commit"], "graph")
        record("package_project_graph_change_reservation", graph_reservation)
        record(
            "package_project_graph_change",
            task_from_reservation(
                helper, graph_state, checkout, "slot", graph["commit"], "graph", command,
                graph_reservation, known_at=graph_known,
            ),
        )

        if args.alternate_developer_dir:
            tc_state = state("toolchain_change")
            record("toolchain_change_seed", warm(helper, tc_state, checkout, "slot", main, command))
            env = os.environ.copy()
            env["DEVELOPER_DIR"] = str(args.alternate_developer_dir.resolve())
            toolchain_known = time.time()
            toolchain_reservation = reserve(
                helper, tc_state, checkout, "slot", main, "toolchain-change", env=env
            )
            record("toolchain_change_reservation", toolchain_reservation)
            record(
                "toolchain_change",
                task_from_reservation(
                    helper,
                    tc_state,
                    checkout,
                    "slot",
                    main,
                    "toolchain-change",
                    command,
                    toolchain_reservation,
                    known_at=toolchain_known,
                    env=env,
                ),
            )
        else:
            record("toolchain_change", {"status": "skipped", "reason": "alternate_developer_dir_required"})

        record(
            "warmer_interrupted_by_real_work",
            run_preemption(helper, state("warmer_interrupted_by_real_work"), checkout, main, command),
        )
    finally:
        if clean(checkout):
            git(checkout, "switch", "--detach", original)

    elapsed = time.monotonic() - started
    summary = summarize(results, elapsed, state_root)
    report = {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "elapsed_seconds": round(elapsed, 6),
        "manifest": manifest,
        "summary": summary,
        "results": results,
    }
    write_json(output / "report.json", report)
    return report


def summarize_events(path: Path) -> dict[str, Any]:
    rows = []
    for journal in event_journal_paths(path):
        for line in journal.read_text(errors="replace").splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                rows.append(value)
    tasks = [row["receipt"] for row in rows if row.get("event") == "task_finished" and isinstance(row.get("receipt"), dict)]
    warms = [row["receipt"] for row in rows if row.get("event") == "warm_finished" and isinstance(row.get("receipt"), dict)]
    exact = sum(row.get("match_class") == "exact" for row in tasks)
    near = sum(row.get("match_class") == "near" for row in tasks)
    quarantines = sum(row.get("event") == "lineage_quarantined" for row in rows)
    cold_retired = sum(row.get("event") == "cold_task_retired" for row in rows)
    cold_reclaimed = sum(row.get("event") == "cold_task_reclaimed" for row in rows)
    cold_preempted = sum(row.get("event") == "cold_task_cleanup_preempted" for row in rows)
    cold_failed = sum(row.get("event") == "cold_task_cleanup_failed" for row in rows)
    cold_deferred = sum(
        row.get("event") in {"cold_task_retirement_deferred", "cold_task_cleanup_deferred"}
        for row in rows
    )
    timestamps = []
    for row in rows:
        raw = row.get("at")
        if not isinstance(raw, str):
            continue
        try:
            timestamps.append(dt.datetime.fromisoformat(raw).timestamp())
        except ValueError:
            pass
    elapsed = max(timestamps) - min(timestamps) if len(timestamps) >= 2 else 0.0
    warmer_seconds = sum(float(row.get("wall_seconds", 0)) for row in warms)
    return {
        "events": len(rows),
        "tasks": len(tasks),
        "warms": len(warms),
        "observation_seconds": round(elapsed, 6),
        "exact_tasks": exact,
        "near_tasks": near,
        "useful_warm_hit_percent": round(100.0 * (exact + near) / len(tasks), 3) if tasks else 0.0,
        "cold_fallback_count": sum(bool(row.get("cold_fallback")) for row in tasks),
        "quarantine_count": quarantines,
        "reset_required_count": quarantines,
        "recovery_count": sum(row.get("event") == "native_run_recovered" for row in rows),
        "task_known_to_build_start_seconds": [row.get("task_known_to_build_start_seconds") for row in tasks],
        "first_build_wall_seconds": [row.get("wall_seconds") for row in tasks],
        "cold_cache_retirement_seconds": [
            row.get("cold_cache_retirement_seconds") for row in tasks
        ],
        "swift_compile_count": [row.get("swift_compile_count") for row in tasks],
        "warmer_build_seconds": round(warmer_seconds, 6),
        "warmer_duty_cycle_percent": round(100.0 * warmer_seconds / elapsed, 3) if elapsed > 0 else 0.0,
        "disk_growth_bytes": sum(int(row.get("disk_growth_bytes", 0)) for row in tasks + warms),
        "cold_task_retired_count": cold_retired,
        "cold_task_reclaimed_count": cold_reclaimed,
        "cold_task_cleanup_preempted_count": cold_preempted,
        "cold_task_cleanup_failed_count": cold_failed,
        "cold_task_cleanup_deferred_count": cold_deferred,
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="action", required=True)

    d = sub.add_parser("discover")
    d.add_argument("--checkout", type=Path, default=Path.cwd())
    d.add_argument("--main", default="origin/main")
    d.add_argument("--behind", type=int, default=3)
    d.add_argument("--history-limit", type=int, default=400)
    d.add_argument("--output", type=Path, required=True)

    r = sub.add_parser("run")
    r.add_argument("--checkout", type=Path, default=Path.cwd())
    r.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    r.add_argument("--manifest", type=Path, required=True)
    r.add_argument("--output", type=Path, required=True)
    r.add_argument("--alternate-developer-dir", type=Path)
    r.add_argument("command", nargs=argparse.REMAINDER)

    q = sub.add_parser("report")
    q.add_argument("--input", type=Path)
    q.add_argument("--events", type=Path)
    return p


def main() -> int:
    args = parser().parse_args()
    if args.action == "discover":
        if not clean(args.checkout.resolve()):
            raise SystemExit("discover requires a clean checkout")
        value = discover_history(args.checkout.resolve(), args.main, args.behind, args.history_limit)
        write_json(args.output, value)
        print(json.dumps(value, indent=2, sort_keys=True))
        return 0
    if args.action == "run":
        value = run_matrix(args)
        print(json.dumps(value["summary"], indent=2, sort_keys=True))
        return 0
    if args.action == "report":
        if bool(args.input) == bool(args.events):
            raise SystemExit("pass exactly one of --input or --events")
        if args.events:
            value = summarize_events(args.events)
        else:
            raw = json.loads(args.input.read_text())
            value = raw.get("summary", raw)
        print(json.dumps(value, indent=2, sort_keys=True))
        return 0
    raise AssertionError(args.action)


if __name__ == "__main__":
    raise SystemExit(main())
