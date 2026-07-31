#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import NamedTuple


TAG = os.environ.get("CMUX_TAG", "swmob")
DURATION_SECONDS = int(os.environ.get("SOAK_SECONDS", "43200"))
INTERVAL_SECONDS = float(os.environ.get("RESOURCE_SAMPLE_INTERVAL", "60"))
soak_root = Path(os.environ.get("SOAK_ROOT", f"/tmp/cmux-mobile-soak-{TAG}"))
LOG_PATH = Path(os.environ.get("RESOURCE_LOG", soak_root / "resources.jsonl"))
STATUS_PATH = Path(os.environ.get("RESOURCE_STATUS", soak_root / "resources.status"))
IPHONE_SIM_ID = os.environ.get("IPHONE_SIM_ID", "")
IPAD_SIM_ID = os.environ.get("IPAD_SIM_ID", "")
MIN_MEMORY_GROWTH_KB = int(
    os.environ.get("RESOURCE_MIN_MEMORY_GROWTH_KB", "30720")
)
MAX_MEMORY_GROWTH_PERCENT = float(
    os.environ.get("RESOURCE_MAX_MEMORY_GROWTH_PERCENT", "10")
)
MAX_RSS_KB = int(os.environ.get("RESOURCE_MAX_RSS_KB", "1258291"))
MAX_FD_COUNT = int(os.environ.get("RESOURCE_MAX_FD_COUNT", "4096"))
MAX_FD_GROWTH = int(os.environ.get("RESOURCE_MAX_FD_GROWTH", "512"))
MAX_THREAD_COUNT = int(os.environ.get("RESOURCE_MAX_THREAD_COUNT", "1024"))
MAX_THREAD_GROWTH = int(os.environ.get("RESOURCE_MAX_THREAD_GROWTH", "256"))
MAX_CPU_PERCENT = float(os.environ.get("RESOURCE_MAX_CPU_PERCENT", "250"))
CPU_STREAK_LIMIT = int(os.environ.get("RESOURCE_CPU_STREAK_LIMIT", "5"))
WARMUP_SAMPLES = int(os.environ.get("RESOURCE_WARMUP_SAMPLES", "5"))
STARTUP_GRACE_SECONDS = float(os.environ.get("RESOURCE_STARTUP_GRACE_SECONDS", "0"))
FAIL_ON_PID_CHANGE = os.environ.get("RESOURCE_FAIL_ON_PID_CHANGE", "1").lower() not in {"0", "false", "no"}
PID_CHANGE_ALLOWED_LABELS = {
    value.strip()
    for value in os.environ.get("RESOURCE_PID_CHANGE_ALLOWED_LABELS", "").split(",")
    if value.strip()
}


LABELS = tuple(
    value.strip()
    for value in os.environ.get("RESOURCE_LABELS", "mac,iphone,ipad").split(",")
    if value.strip()
)
STARTED_MONOTONIC = time.monotonic()


baseline_rss: dict[str, int] = {}
max_rss: dict[str, int] = {}
last_rss: dict[str, int] = {}
baseline_fd_count: dict[str, int] = {}
max_fd_count: dict[str, int] = {}
last_fd_count: dict[str, int] = {}
baseline_thread_count: dict[str, int] = {}
max_thread_count: dict[str, int] = {}
last_thread_count: dict[str, int] = {}
last_cpu: dict[str, float] = {}
max_cpu: dict[str, float] = {}
last_pid: dict[str, int] = {}
missing_count: dict[str, int] = {}
cpu_high_streak: dict[str, int] = {}
pid_first_seen: dict[str, float] = {}
pid_sample_count: dict[str, int] = {}


class ProcessSample(NamedTuple):
    cpu_percent: float
    rss_kb: int
    thread_count: int
    fd_count: int


def stamp() -> str:
    return dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def run(*args: str, timeout: float = 10) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="replace")
        return subprocess.CompletedProcess(list(args), 124, out)


def all_processes() -> list[tuple[int, str]]:
    result = run("ps", "-axo", "pid=,command=", timeout=10)
    processes: list[tuple[int, str]] = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            processes.append((int(pid_text), command))
        except ValueError:
            continue
    return processes


def find_pid(label: str, processes: list[tuple[int, str]]) -> int | None:
    if label == "mac":
        needle = f"cmux-{TAG}/Build/Products/Debug/cmux DEV {TAG}.app/Contents/MacOS/cmux DEV"
        for pid, command in processes:
            if needle in command:
                return pid
    elif label == "iphone":
        candidates: list[int] = []
        for pid, command in processes:
            if f"/Devices/{IPHONE_SIM_ID}/" in command and "cmux.app/cmux" in command:
                candidates.append(pid)
        return max(candidates) if candidates else None
    elif label == "ipad":
        candidates: list[int] = []
        for pid, command in processes:
            if f"/Devices/{IPAD_SIM_ID}/" in command and "cmux.app/cmux" in command:
                candidates.append(pid)
        return max(candidates) if candidates else None
    return None


def sample_pid(pid: int) -> ProcessSample | None:
    pid_text = str(pid)
    process_result = run("ps", "-o", "%cpu=", "-o", "rss=", "-p", pid_text, timeout=10)
    process_parts = process_result.stdout.split()
    if len(process_parts) < 2 or process_result.returncode != 0:
        return None

    thread_result = run("ps", "-M", "-p", pid_text, timeout=10)
    thread_rows = [line for line in thread_result.stdout.splitlines()[1:] if line.strip()]
    if thread_result.returncode != 0 or not thread_rows:
        return None

    fd_result = run("lsof", "-a", "-p", pid_text, "-d", "0-9999", "-Ff", timeout=10)
    if fd_result.returncode != 0:
        return None
    fd_count = sum(1 for line in fd_result.stdout.splitlines() if re.fullmatch(r"f\d+", line))
    if fd_count == 0:
        return None

    try:
        return ProcessSample(
            cpu_percent=float(process_parts[0]),
            rss_kb=int(process_parts[1]),
            thread_count=len(thread_rows),
            fd_count=fd_count,
        )
    except ValueError:
        return None


def exceeds_absolute_or_growth(
    *,
    current: int,
    maximum: int,
    baseline: int,
    absolute_limit: int,
    growth_limit: int,
) -> bool:
    return current > absolute_limit or (baseline > 0 and maximum - baseline > growth_limit)


def memory_growth_limit_kb(
    *,
    baseline_kb: int,
    minimum_kb: int,
    percent: float,
) -> int:
    return max(minimum_kb, round(baseline_kb * percent / 100))


def reset_process_baselines(label: str) -> None:
    for values in (
        baseline_rss,
        max_rss,
        last_rss,
        baseline_fd_count,
        max_fd_count,
        last_fd_count,
        baseline_thread_count,
        max_thread_count,
        last_thread_count,
    ):
        values.pop(label, None)


def log_json(payload: dict[str, object]) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as f:
        f.write(json.dumps(payload, separators=(",", ":")) + "\n")


def write_status(status: str, samples: int, failures: int) -> None:
    processes = {}
    for label in LABELS:
        rss_base = baseline_rss.get(label, 0)
        rss_high = max_rss.get(label, 0)
        fd_base = baseline_fd_count.get(label, 0)
        fd_high = max_fd_count.get(label, 0)
        thread_base = baseline_thread_count.get(label, 0)
        thread_high = max_thread_count.get(label, 0)
        processes[label] = {
            "pid": last_pid.get(label, 0),
            "last_cpu_percent": last_cpu.get(label, 0),
            "max_cpu_percent": max_cpu.get(label, 0),
            "cpu_high_streak": cpu_high_streak.get(label, 0),
            "baseline_rss_kb": rss_base,
            "last_rss_kb": last_rss.get(label, 0),
            "max_rss_kb": rss_high,
            "rss_growth_kb": max(0, rss_high - rss_base) if rss_base else 0,
            "rss_growth_limit_kb": memory_growth_limit_kb(
                baseline_kb=rss_base,
                minimum_kb=MIN_MEMORY_GROWTH_KB,
                percent=MAX_MEMORY_GROWTH_PERCENT,
            ) if rss_base else 0,
            "baseline_fd_count": fd_base,
            "last_fd_count": last_fd_count.get(label, 0),
            "max_fd_count": fd_high,
            "fd_growth": max(0, fd_high - fd_base) if fd_base else 0,
            "baseline_thread_count": thread_base,
            "last_thread_count": last_thread_count.get(label, 0),
            "max_thread_count": thread_high,
            "thread_growth": max(0, thread_high - thread_base) if thread_base else 0,
        }
    payload = {
        "status": status,
        "samples": samples,
        "failures": failures,
        "elapsed_seconds": int(time.monotonic() - STARTED_MONOTONIC),
        "processes": processes,
    }
    STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(STATUS_PATH)


def main() -> int:
    samples = 0
    failures = 0
    deadline = STARTED_MONOTONIC + DURATION_SECONDS

    while time.monotonic() < deadline:
        samples += 1
        now = stamp()
        processes = all_processes()

        for label in LABELS:
            pid = find_pid(label, processes)
            if pid is None:
                in_startup_grace = time.monotonic() - STARTED_MONOTONIC < STARTUP_GRACE_SECONDS
                if in_startup_grace:
                    log_json({"ts": now, "label": label, "status": "missing", "startup_grace": True})
                    continue
                missing_count[label] = missing_count.get(label, 0) + 1
                log_json({
                    "ts": now,
                    "label": label,
                    "status": "missing",
                    "missing_count": missing_count[label],
                })
                if missing_count[label] >= 3:
                    failures += 1
                continue

            previous_pid = last_pid.get(label)
            if FAIL_ON_PID_CHANGE and previous_pid is not None and previous_pid != pid:
                if label in PID_CHANGE_ALLOWED_LABELS:
                    last_pid[label] = pid
                    reset_process_baselines(label)
                    cpu_high_streak[label] = 0
                    pid_first_seen[label] = time.monotonic()
                    pid_sample_count[label] = 0
                    log_json({
                        "ts": now,
                        "label": label,
                        "pid": pid,
                        "previous_pid": previous_pid,
                        "status": "pid_changed_allowed",
                    })
                else:
                    in_startup_grace = time.monotonic() - STARTED_MONOTONIC < STARTUP_GRACE_SECONDS
                    if in_startup_grace or not baseline_rss.get(label):
                        last_pid[label] = pid
                        pid_first_seen[label] = time.monotonic()
                        pid_sample_count[label] = 0
                        log_json({
                            "ts": now,
                            "label": label,
                            "pid": pid,
                            "previous_pid": previous_pid,
                            "status": "pid_changed_startup_grace" if in_startup_grace else "pid_changed_before_baseline",
                        })
                    else:
                        failures += 1
                        last_pid[label] = pid
                        pid_first_seen[label] = time.monotonic()
                        pid_sample_count[label] = 0
                        log_json({
                            "ts": now,
                            "label": label,
                            "pid": pid,
                            "previous_pid": previous_pid,
                            "status": "pid_changed",
                            "failures": failures,
                        })
                        write_status("failed", samples, failures)
                        return 1
            if previous_pid != pid:
                pid_first_seen[label] = time.monotonic()
                pid_sample_count[label] = 0
            last_pid[label] = pid
            sample = sample_pid(pid)
            if sample is None:
                in_startup_grace = time.monotonic() - STARTED_MONOTONIC < STARTUP_GRACE_SECONDS
                if in_startup_grace:
                    log_json({
                        "ts": now,
                        "label": label,
                        "pid": pid,
                        "status": "sample_failed_startup_grace",
                    })
                    continue
                missing_count[label] = missing_count.get(label, 0) + 1
                log_json({
                    "ts": now,
                    "label": label,
                    "pid": pid,
                    "status": "sample_failed",
                    "missing_count": missing_count[label],
                })
                if missing_count[label] >= 3:
                    failures += 1
                continue

            cpu = sample.cpu_percent
            rss = sample.rss_kb
            fd_count = sample.fd_count
            thread_count = sample.thread_count
            missing_count[label] = 0
            last_cpu[label] = cpu
            last_rss[label] = rss
            last_fd_count[label] = fd_count
            last_thread_count[label] = thread_count
            max_cpu[label] = max(max_cpu.get(label, cpu), cpu)
            pid_sample_count[label] = pid_sample_count.get(label, 0) + 1
            process_age = time.monotonic() - pid_first_seen.get(label, STARTED_MONOTONIC)

            if pid_sample_count[label] < WARMUP_SAMPLES or process_age < STARTUP_GRACE_SECONDS:
                baseline_rss[label] = 0
                max_rss[label] = 0
                baseline_fd_count[label] = 0
                max_fd_count[label] = 0
                baseline_thread_count[label] = 0
                max_thread_count[label] = 0
                cpu_high_streak[label] = 0
                log_json({
                    "ts": now,
                    "label": label,
                    "pid": pid,
                    "cpu_percent": cpu,
                    "rss_kb": rss,
                    "fd_count": fd_count,
                    "thread_count": thread_count,
                    "warmup": True,
                    "process_age_seconds": round(process_age, 1),
                    "pid_sample_count": pid_sample_count[label],
                })
                continue

            if not baseline_rss.get(label):
                baseline_rss[label] = rss
            if not baseline_fd_count.get(label):
                baseline_fd_count[label] = fd_count
            if not baseline_thread_count.get(label):
                baseline_thread_count[label] = thread_count
            max_rss[label] = max(max_rss.get(label, rss), rss)
            max_fd_count[label] = max(max_fd_count.get(label, fd_count), fd_count)
            max_thread_count[label] = max(max_thread_count.get(label, thread_count), thread_count)
            cpu_high_streak[label] = cpu_high_streak.get(label, 0) + 1 if cpu > MAX_CPU_PERCENT else 0
            rss_growth = max_rss[label] - baseline_rss[label]
            rss_growth_limit = memory_growth_limit_kb(
                baseline_kb=baseline_rss[label],
                minimum_kb=MIN_MEMORY_GROWTH_KB,
                percent=MAX_MEMORY_GROWTH_PERCENT,
            )
            fd_growth = max_fd_count[label] - baseline_fd_count[label]
            thread_growth = max_thread_count[label] - baseline_thread_count[label]

            limit_violations = []
            if exceeds_absolute_or_growth(
                current=rss,
                maximum=max_rss[label],
                baseline=baseline_rss[label],
                absolute_limit=MAX_RSS_KB,
                growth_limit=rss_growth_limit,
            ):
                limit_violations.append("rss")
            if exceeds_absolute_or_growth(
                current=fd_count,
                maximum=max_fd_count[label],
                baseline=baseline_fd_count[label],
                absolute_limit=MAX_FD_COUNT,
                growth_limit=MAX_FD_GROWTH,
            ):
                limit_violations.append("file_descriptors")
            if exceeds_absolute_or_growth(
                current=thread_count,
                maximum=max_thread_count[label],
                baseline=baseline_thread_count[label],
                absolute_limit=MAX_THREAD_COUNT,
                growth_limit=MAX_THREAD_GROWTH,
            ):
                limit_violations.append("threads")
            if cpu_high_streak[label] >= CPU_STREAK_LIMIT:
                limit_violations.append("cpu")

            log_json({
                "ts": now,
                "label": label,
                "pid": pid,
                "cpu_percent": cpu,
                "max_cpu_percent": max_cpu[label],
                "cpu_high_streak": cpu_high_streak[label],
                "rss_kb": rss,
                "baseline_rss_kb": baseline_rss[label],
                "max_rss_kb": max_rss[label],
                "rss_growth_kb": rss_growth,
                "rss_growth_limit_kb": rss_growth_limit,
                "fd_count": fd_count,
                "baseline_fd_count": baseline_fd_count[label],
                "max_fd_count": max_fd_count[label],
                "fd_growth": fd_growth,
                "thread_count": thread_count,
                "baseline_thread_count": baseline_thread_count[label],
                "max_thread_count": max_thread_count[label],
                "thread_growth": thread_growth,
                "limit_violations": limit_violations,
            })

            if limit_violations:
                failures += 1

        write_status("running", samples, failures)
        if failures >= 3:
            write_status("failed", samples, failures)
            return 1
        time.sleep(INTERVAL_SECONDS)

    write_status("passed", samples, failures)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
