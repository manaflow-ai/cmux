"""Small macOS IOAccelerator sampler shared by the WindowServer probes."""
from __future__ import annotations

import plistlib
import subprocess
import threading
from typing import Any


def read_gpu_stats(run: subprocess.CompletedProcess[bytes] | None = None) -> dict[str, float]:
    try:
        proc = run or subprocess.run(["ioreg", "-r", "-c", "IOAccelerator", "-d", "1", "-a"],
                                     capture_output=True, timeout=10)
        entries = plistlib.loads(proc.stdout) if proc.stdout else []
    except (OSError, subprocess.SubprocessError, ValueError, plistlib.InvalidFileException, TypeError):
        return {}
    if isinstance(entries, dict):
        entries = [entries]
    for entry in entries if isinstance(entries, list) else []:
        stats = entry.get("PerformanceStatistics") if isinstance(entry, dict) else None
        if not isinstance(stats, dict):
            continue
        out: dict[str, float] = {}
        for key in ("Device Utilization %", "Renderer Utilization %", "Tiler Utilization %",
                    "In use system memory", "Alloc system memory"):
            value = stats.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                out[key] = float(value)
        if out:
            return out
    return {}


def summarize(samples: list[dict[str, float]]) -> dict[str, Any]:
    if not samples:
        return {"available": False, "samples": 0}
    names = {"Device Utilization %": "device_utilization_percent",
             "Renderer Utilization %": "renderer_utilization_percent",
             "Tiler Utilization %": "tiler_utilization_percent",
             "In use system memory": "in_use_system_memory_mb",
             "Alloc system memory": "alloc_system_memory_mb"}
    out: dict[str, Any] = {"available": True, "samples": len(samples)}
    for source, name in names.items():
        values = [sample[source] for sample in samples if source in sample]
        if values:
            mean = sum(values) / len(values)
            out[name] = round(mean / (1024 * 1024), 1) if name.endswith("_mb") else round(mean, 2)
    return out


class GPUSampler(threading.Thread):
    def __init__(self, interval: float = 1.0) -> None:
        super().__init__(daemon=True)
        self.interval = max(1.0, interval)
        self.samples: list[dict[str, float]] = []
        self.stop_event = threading.Event()

    def run(self) -> None:
        while not self.stop_event.is_set():
            stats = read_gpu_stats()
            if stats and not self.stop_event.is_set():
                self.samples.append(stats)
            self.stop_event.wait(self.interval)

    def finish(self) -> dict[str, Any]:
        self.stop_event.set()
        # read_gpu_stats has a 10-second subprocess timeout. Join fully so
        # no sampling thread or subprocess can outlive the measurement.
        self.join()
        return summarize(self.samples)

    def __enter__(self) -> GPUSampler:
        self.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.result = self.finish()
