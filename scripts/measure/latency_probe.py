#!/usr/bin/env python3
"""How interactive a machine is right now, as one JSON line (RFD 0072, "The measurement").

    python3 -I scripts/measure/latency_probe.py SECONDS [LABEL]

For SECONDS a thread at user-interactive QoS (macOS) sleeps 10 ms again and again and records how late each wake is;
around that window it reads CPU busy (two readings), memory pressure, swap (size and growth), thermal pressure, load
and HID idle (how long since the person last touched a key or the mouse). It prints exactly one line on stdout:

    {"schema": "interactive-lateness/v1", "label": ..., "lateness_ms": {"wakes", "p50", "p95", "p99", "max",
     "over_5ms_pct", "over_16ms_pct"}, "cpu": {...}, "memory": {...}, "swap": {...}, "thermal": {...},
     "hid_idle_s": ..., "load": [1, 5, 15], "errors": {...}}

A reading that fails is null with its reason under "errors"; the probe never fails for a missing reading. It reads
only (sysctl, vm_stat, ioreg, /proc, /sys) and runs on macOS and Linux with the standard library alone.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import datetime as dt
import glob
import json
import os
import platform
import re
import subprocess
import sys
import threading
import time

SCHEMA = "interactive-lateness/v1"
SLEEP_S = 0.010
DARWIN = sys.platform == "darwin"
PRESSURE = {1: "normal", 2: "warning", 4: "critical"}
# OSThermalPressureLevel (com.apple.system.thermalpressurelevel)
THERMAL = {0: "nominal", 1: "moderate", 2: "heavy", 3: "trapping", 4: "sleeping"}


def run(cmd: list[str], timeout: float = 10) -> str:
    return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=True).stdout


def sysctl(name: str) -> str:
    return run(["sysctl", "-n", name]).strip()


def pct(sorted_vals: list[float], q: float) -> float | None:
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, max(0, int(round(q * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


def r3(v: float | None) -> float | None:
    return None if v is None else round(v, 3)


# --- timer lateness ---------------------------------------------------------------------------------------------------
def _user_interactive_qos() -> None:
    if not DARWIN:
        return
    lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
    lib.pthread_set_qos_class_self_np(ctypes.c_uint(0x21), ctypes.c_int(0))  # QOS_CLASS_USER_INTERACTIVE


def lateness(seconds: float, errors: dict[str, str]) -> list[float]:
    late: list[float] = []

    def loop() -> None:
        try:
            _user_interactive_qos()
        except Exception as e:  # noqa: BLE001 - recorded, the timer still runs at default QoS
            errors["qos"] = str(e)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            t0 = time.monotonic_ns()
            time.sleep(SLEEP_S)
            late.append(max(0.0, (time.monotonic_ns() - t0) / 1e6 - SLEEP_S * 1000))

    t = threading.Thread(target=loop, name="lateness", daemon=True)
    t.start()
    t.join()
    return late


def summarize_lateness(late: list[float]) -> dict:
    s = sorted(late)
    n = len(s)
    return {"wakes": n, "sleep_ms": SLEEP_S * 1000, "p50": r3(pct(s, 0.50)), "p95": r3(pct(s, 0.95)),
            "p99": r3(pct(s, 0.99)), "max": r3(s[-1] if s else None),
            "over_5ms_pct": r3(100.0 * sum(1 for v in s if v > 5) / n) if n else None,
            "over_16ms_pct": r3(100.0 * sum(1 for v in s if v > 16) / n) if n else None}


# --- CPU --------------------------------------------------------------------------------------------------------------
def cpu_ticks() -> tuple[int, int, int, int]:
    """(user, system, idle, nice) ticks since boot, all CPUs."""
    if DARWIN:
        lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
        lib.mach_host_self.restype = ctypes.c_uint
        info = (ctypes.c_uint * 4)()  # host_cpu_load_info: user, system, idle, nice
        count = ctypes.c_uint(4)
        kr = lib.host_statistics(lib.mach_host_self(), 3, info, ctypes.byref(count))  # HOST_CPU_LOAD_INFO
        if kr != 0:
            raise OSError(f"host_statistics returned {kr}")
        return info[0], info[1], info[2], info[3]
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    # user nice system idle iowait irq softirq steal
    return v[0], v[2] + v[5] + v[6] + (v[7] if len(v) > 7 else 0), v[3] + v[4], v[1]


def cpu_share(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> dict:
    d = [y - x for x, y in zip(a, b)]
    total = sum(d)
    if total <= 0:
        raise ValueError("no CPU ticks passed")
    user, system, idle, nice = (100.0 * x / total for x in d)
    return {"busy_pct": r3(100.0 - idle), "user_pct": r3(user + nice), "system_pct": r3(system), "idle_pct": r3(idle)}


def cpu_counts(errors: dict[str, str]) -> dict:
    out: dict = {"cpus": os.cpu_count()}
    if DARWIN:
        for key, name in (("physical", "hw.physicalcpu"), ("perf_physical", "hw.perflevel0.physicalcpu"),
                          ("perf_logical", "hw.perflevel0.logicalcpu"), ("eff_physical", "hw.perflevel1.physicalcpu")):
            try:
                out[key] = int(sysctl(name))
            except Exception as e:  # noqa: BLE001
                errors[f"cpu.{key}"] = str(e)[:200]
    return out


# --- memory and swap --------------------------------------------------------------------------------------------------
def parse_swapusage(text: str) -> dict:
    """`sysctl -n vm.swapusage`: total = 24576.00M  used = 23450.25M  free = 1125.75M  (encrypted)"""
    out = {}
    for key, num, unit in re.findall(r"(total|used|free) = ([\d.]+)([KMG])", text):
        out[f"{key}_mb"] = round(float(num) * {"K": 1 / 1024, "M": 1.0, "G": 1024.0}[unit], 1)
    if "total_mb" not in out:
        raise ValueError(f"vm.swapusage unreadable: {text[:120]!r}")
    return out


def parse_vm_stat_swapouts(text: str) -> tuple[int, int]:
    """(swapouts in pages, page size in bytes) from `vm_stat`."""
    size = re.search(r"page size of (\d+) bytes", text)
    outs = re.search(r"Swapouts:\s+(\d+)", text)
    if not outs:
        raise ValueError("vm_stat has no Swapouts line")
    return int(outs.group(1)), int(size.group(1)) if size else 16384


def swapouts_bytes() -> int:
    if DARWIN:
        pages, size = parse_vm_stat_swapouts(run(["vm_stat"]))
        return pages * size
    with open("/proc/vmstat") as f:
        for line in f:
            if line.startswith("pswpout "):
                return int(line.split()[1]) * os.sysconf("SC_PAGE_SIZE")
    raise ValueError("/proc/vmstat has no pswpout")


def meminfo() -> dict[str, int]:
    out = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, rest = line.partition(":")
            out[k] = int(rest.split()[0]) * 1024
    return out


def memory(errors: dict[str, str]) -> dict:
    out: dict = {}
    try:
        if DARWIN:
            level = int(sysctl("kern.memorystatus_vm_pressure_level"))
            out.update(pressure_level=level, pressure=PRESSURE.get(level, str(level)))
            out["free_pct"] = int(sysctl("kern.memorystatus_level"))
            out["total_gb"] = round(int(sysctl("hw.memsize")) / 2**30, 1)
        else:
            m = meminfo()
            out["total_gb"] = round(m["MemTotal"] / 2**30, 1)
            out["free_pct"] = round(100.0 * m.get("MemAvailable", m["MemFree"]) / m["MemTotal"], 1)
            with open("/proc/pressure/memory") as f:
                some = re.search(r"some avg10=([\d.]+)", f.read())
            avg10 = float(some.group(1)) if some else None
            out["psi_some_avg10"] = avg10
            out["pressure"] = None if avg10 is None else ("normal" if avg10 < 1 else "warning" if avg10 < 10 else "critical")
    except Exception as e:  # noqa: BLE001
        errors["memory"] = str(e)[:200]
    return out


def swap_size(errors: dict[str, str]) -> dict:
    try:
        if DARWIN:
            return parse_swapusage(sysctl("vm.swapusage"))
        m = meminfo()
        total, free = m.get("SwapTotal", 0), m.get("SwapFree", 0)
        return {"total_mb": round(total / 2**20, 1), "used_mb": round((total - free) / 2**20, 1),
                "free_mb": round(free / 2**20, 1)}
    except Exception as e:  # noqa: BLE001
        errors["swap"] = str(e)[:200]
        return {}


# --- thermal, presence ------------------------------------------------------------------------------------------------
def thermal(errors: dict[str, str]) -> dict:
    try:
        if DARWIN:
            lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
            token = ctypes.c_int(0)
            if lib.notify_register_check(b"com.apple.system.thermalpressurelevel", ctypes.byref(token)) != 0:
                raise OSError("notify_register_check failed")
            state = ctypes.c_uint64(0)
            rc = lib.notify_get_state(token, ctypes.byref(state))
            lib.notify_cancel(token)
            if rc != 0:
                raise OSError(f"notify_get_state returned {rc}")
            return {"level": int(state.value), "pressure": THERMAL.get(int(state.value), str(state.value)),
                    "source": "notify:com.apple.system.thermalpressurelevel"}
        temps = []
        for path in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            try:
                with open(path) as f:
                    temps.append(int(f.read().strip()) / 1000.0)
            except (OSError, ValueError):
                continue
        if not temps:
            return {"level": None, "pressure": None, "max_c": None, "source": "none: no /sys/class/thermal zone"}
        return {"level": None, "pressure": None, "max_c": max(temps), "source": "/sys/class/thermal"}
    except Exception as e:  # noqa: BLE001
        errors["thermal"] = str(e)[:200]
        return {}


def parse_hid_idle(text: str) -> float:
    m = re.search(r'"HIDIdleTime" = (\d+)', text)
    if not m:
        raise ValueError("ioreg printed no HIDIdleTime")
    return round(int(m.group(1)) / 1e9, 1)


def hid_idle(errors: dict[str, str]) -> float | None:
    if not DARWIN:
        errors["hid_idle"] = "no HID idle reading off macOS"
        return None
    try:
        return parse_hid_idle(run(["ioreg", "-c", "IOHIDSystem", "-d", "4", "-r", "-k", "HIDIdleTime"]))
    except Exception as e:  # noqa: BLE001
        errors["hid_idle"] = str(e)[:200]
        return None


# --- the probe --------------------------------------------------------------------------------------------------------
def probe(seconds: float, label: str) -> dict:
    errors: dict[str, str] = {}
    started = dt.datetime.now(dt.timezone.utc)
    idle_before = hid_idle(errors)
    swap_before = swap_size(errors)
    try:
        swapped_before = swapouts_bytes()
    except Exception as e:  # noqa: BLE001
        swapped_before = None
        errors["swapouts"] = str(e)[:200]
    try:
        ticks_before = cpu_ticks()
    except Exception as e:  # noqa: BLE001
        ticks_before = None
        errors["cpu"] = str(e)[:200]

    t0 = time.monotonic()
    late = lateness(seconds, errors)
    elapsed = time.monotonic() - t0

    cpu = cpu_counts(errors)
    if ticks_before is not None:
        try:
            cpu.update(cpu_share(ticks_before, cpu_ticks()))
        except Exception as e:  # noqa: BLE001
            errors["cpu"] = str(e)[:200]
    swap = swap_size(errors)
    if swap_before.get("used_mb") is not None and swap.get("used_mb") is not None:
        swap["used_growth_mb"] = round(swap["used_mb"] - swap_before["used_mb"], 1)
    if swapped_before is not None:
        try:
            out_mb = (swapouts_bytes() - swapped_before) / 2**20
            swap["swapout_mb"] = round(out_mb, 1)
            swap["swapout_mb_per_min"] = round(out_mb * 60 / elapsed, 1) if elapsed > 0 else None
        except Exception as e:  # noqa: BLE001
            errors["swapouts"] = str(e)[:200]
    idle_after = hid_idle(errors) if DARWIN else None

    try:
        load = [round(x, 2) for x in os.getloadavg()]
    except OSError as e:
        load = None
        errors["load"] = str(e)
    if DARWIN:
        os_name = f"macOS {platform.mac_ver()[0]}"
    else:
        os_name = f"{platform.system()} {platform.release()}"
    return {
        "schema": SCHEMA, "label": label, "host": platform.node().split(".")[0], "os": os_name,
        "at": started.strftime("%Y-%m-%dT%H:%M:%SZ"), "seconds": round(elapsed, 2),
        "lateness_ms": summarize_lateness(late), "cpu": cpu, "load": load, "memory": memory(errors), "swap": swap,
        "thermal": thermal(errors),
        # the smaller of the two readings: input at either end of the window means the person was there
        "hid_idle_s": min((v for v in (idle_before, idle_after) if v is not None), default=None),
        "errors": errors,
    }


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2 if not argv else 0
    try:
        seconds = float(argv[0])
    except ValueError:
        print(f"latency_probe.py: SECONDS must be a number, got {argv[0]!r}", file=sys.stderr)
        return 2
    if not 0 < seconds <= 3600:
        print("latency_probe.py: SECONDS must be over 0 and at most 3600", file=sys.stderr)
        return 2
    label = argv[1] if len(argv) > 1 else "run"
    print(json.dumps(probe(seconds, label), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
