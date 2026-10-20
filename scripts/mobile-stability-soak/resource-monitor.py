#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import time
from pathlib import Path


TAG = os.environ.get("CMUX_TAG", "swmob")
DURATION_SECONDS = int(os.environ.get("SOAK_SECONDS", "43200"))
INTERVAL_SECONDS = float(os.environ.get("RESOURCE_SAMPLE_INTERVAL", "60"))
soak_root = Path(os.environ.get("SOAK_ROOT", f"/tmp/cmux-mobile-soak-{TAG}"))
LOG_PATH = Path(os.environ.get("RESOURCE_LOG", soak_root / "resources.jsonl"))
STATUS_PATH = Path(os.environ.get("RESOURCE_STATUS", soak_root / "resources.status"))
IPHONE_SIM_ID = os.environ.get("IPHONE_SIM_ID", "")
IPAD_SIM_ID = os.environ.get("IPAD_SIM_ID", "")
MAX_GROWTH_KB = int(os.environ.get("RESOURCE_MAX_GROWTH_KB", "524288"))
MAX_RSS_KB = int(os.environ.get("RESOURCE_MAX_RSS_KB", "1258291"))
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
last_cpu: dict[str, float] = {}
max_cpu: dict[str, float] = {}
last_pid: dict[str, int] = {}
missing_count: dict[str, int] = {}
cpu_high_streak: dict[str, int] = {}
pid_first_seen: dict[str, float] = {}
pid_sample_count: dict[str, int] = {}


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


def sample_pid(pid: int) -> tuple[float, int] | None:
    result = run("ps", "-o", "%cpu=", "-o", "rss=", "-p", str(pid), timeout=10)
    parts = result.stdout.split()
    if len(parts) < 2 or result.returncode != 0:
        return None
    try:
        return float(parts[0]), int(parts[1])
    except ValueError:
        return None


def log_json(payload: dict[str, object]) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as f:
        f.write(json.dumps(payload, separators=(",", ":")) + "\n")


def write_status(status: str, samples: int, failures: int) -> None:
    processes = {}
    for label in LABELS:
        base = baseline_rss.get(label, 0)
        high = max_rss.get(label, 0)
        processes[label] = {
            "pid": last_pid.get(label, 0),
            "last_cpu_percent": last_cpu.get(label, 0),
            "max_cpu_percent": max_cpu.get(label, 0),
            "cpu_high_streak": cpu_high_streak.get(label, 0),
            "baseline_rss_kb": base,
            "last_rss_kb": last_rss.get(label, 0),
            "max_rss_kb": high,
            "rss_growth_kb": max(0, high - base) if base else 0,
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
                    baseline_rss.pop(label, None)
                    max_rss.pop(label, None)
                    last_rss.pop(label, None)
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

            cpu, rss = sample
            missing_count[label] = 0
            last_cpu[label] = cpu
            last_rss[label] = rss
            max_cpu[label] = max(max_cpu.get(label, cpu), cpu)
            pid_sample_count[label] = pid_sample_count.get(label, 0) + 1
            process_age = time.monotonic() - pid_first_seen.get(label, STARTED_MONOTONIC)

            if pid_sample_count[label] < WARMUP_SAMPLES or process_age < STARTUP_GRACE_SECONDS:
                baseline_rss[label] = 0
                max_rss[label] = 0
                cpu_high_streak[label] = 0
                log_json({
                    "ts": now,
                    "label": label,
                    "pid": pid,
                    "cpu_percent": cpu,
                    "rss_kb": rss,
                    "warmup": True,
                    "process_age_seconds": round(process_age, 1),
                    "pid_sample_count": pid_sample_count[label],
                })
                continue

            if not baseline_rss.get(label):
                baseline_rss[label] = rss
            max_rss[label] = max(max_rss.get(label, rss), rss)
            cpu_high_streak[label] = cpu_high_streak.get(label, 0) + 1 if cpu > MAX_CPU_PERCENT else 0
            growth = max_rss[label] - baseline_rss[label]

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
                "rss_growth_kb": growth,
            })

            if rss > MAX_RSS_KB or growth > MAX_GROWTH_KB or cpu_high_streak[label] >= CPU_STREAK_LIMIT:
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
