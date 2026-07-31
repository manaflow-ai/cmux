#!/usr/bin/env python3
"""Behavioral tests for the mobile soak's process resource sampling."""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mobile-stability-soak" / "resource-monitor.py"


def load_resource_monitor_module():
    spec = importlib.util.spec_from_file_location("mobile_resource_monitor", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_sample_pid_includes_threads_and_numeric_file_descriptors() -> None:
    monitor = load_resource_monitor_module()

    def fake_run(*args: str, timeout: float = 10) -> subprocess.CompletedProcess[str]:
        del timeout
        if args == ("ps", "-o", "%cpu=", "-o", "rss=", "-p", "42"):
            return subprocess.CompletedProcess(args, 0, "12.5 4096\n")
        if args == ("ps", "-M", "-p", "42"):
            return subprocess.CompletedProcess(
                args,
                0,
                "USER PID COMMAND\nuser 42 app\n     42 thread\n     42 thread\n",
            )
        if args == ("lsof", "-a", "-p", "42", "-d", "0-9999", "-Ff"):
            return subprocess.CompletedProcess(args, 0, "p42\nf0\nf1\nfcwd\nf17\n")
        raise AssertionError(f"unexpected command: {args!r}")

    monitor.run = fake_run

    sample = monitor.sample_pid(42)

    assert sample is not None
    assert sample.cpu_percent == 12.5
    assert sample.rss_kb == 4096
    assert sample.thread_count == 3
    assert sample.fd_count == 3


def test_absolute_and_growth_limits_are_both_enforced() -> None:
    monitor = load_resource_monitor_module()

    assert monitor.exceeds_absolute_or_growth(
        current=99,
        maximum=100,
        baseline=10,
        absolute_limit=100,
        growth_limit=90,
    ) is False
    assert monitor.exceeds_absolute_or_growth(
        current=101,
        maximum=101,
        baseline=100,
        absolute_limit=100,
        growth_limit=90,
    ) is True
    assert monitor.exceeds_absolute_or_growth(
        current=50,
        maximum=101,
        baseline=10,
        absolute_limit=200,
        growth_limit=90,
    ) is True
