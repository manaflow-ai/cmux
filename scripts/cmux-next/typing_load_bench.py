"""Load modes for agent-engine-bench's existing native composer key path.

Uses isolated app panes and the existing mock-daemon load_run, never a model provider.
The page's after-frame message is a paint proxy, not a display presentation timestamp.
Native debug.key RPC duration and driver lateness are retained separately: neither may
be silently omitted when interpreting renderer keydown-to-paint results.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import math
import os
import random
import resource
import subprocess
import sys
import time

MODES = ("idle", "streaming-3", "background-wake", "cpu", "100k")


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, math.floor((len(values) - 1) * fraction + 0.5))] if values else None


def verdict(report, expected, dispatch=None):
    samples = report.get("samples", [])
    finite = bool(expected) and len(samples) == len(expected) and all(
        isinstance(s, dict) and all(type(s.get(k)) in (int, float) and math.isfinite(s[k]) and s[k] >= 0
                                   for k in ("frame", "paint", "listener", "work")) for s in samples)
    ordered = all(isinstance(s, dict) and isinstance(s.get("key"), str) for s in samples) and (
        "".join(s["key"] for s in samples) == expected)
    intact = report.get("composer_text") == expected
    paints = [s["paint"] for s in samples] if finite else []
    p95, p99 = percentile(paints, .95), percentile(paints, .99)
    end_to_end = []
    if finite and ordered and dispatch and len(dispatch) == len(samples):
        for sample, sent in zip(samples, dispatch):
            painted = sample.get("paint_epoch_ms")
            if type(painted) not in (int, float) or not math.isfinite(painted):
                break
            end_to_end.append(painted - sent["epoch_ms"])
    joined = len(end_to_end) == len(expected) and all(0 <= ms < 60000 for ms in end_to_end)
    return {"complete": finite and ordered and intact and joined, "key_order_ok": ordered,
            "text_exact": intact, "expected_keys": len(expected), "observed_keys": len(samples),
            "paint_p95_ms": p95, "paint_p99_ms": p99,
            "dispatch_to_after_frame_ms": end_to_end,
            "dispatch_to_after_frame_p95_ms": percentile(end_to_end, .95),
            "dispatch_to_after_frame_p99_ms": percentile(end_to_end, .99),
            "renderer_budget_met": bool(finite and ordered and intact and p95 <= 16 and p99 <= 33)}


def run_loads(rpc, pane, open_chat, wait, modes, keys, gap_ms):
    if not modes or any(mode not in MODES for mode in modes) or len(set(modes)) != len(modes):
        raise ValueError(f"typing load modes must be distinct members of {MODES}")
    if not 200 <= keys <= 2000 or not math.isfinite(gap_ms) or not 1 <= gap_ms <= 100:
        raise ValueError("typing-loads needs 200..2000 keys and a 1..100 ms gap")
    duration = keys * gap_ms / 1000
    if duration > 35:
        raise ValueError("typing interval must fit in 35 seconds (native load_run deadline is 60s)")
    rng = random.Random(571)
    expected = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(keys))
    results = []

    def checked(reply):
        if not isinstance(reply, dict) or reply.get("error"):
            raise RuntimeError(f"native bench action failed: {reply}")
        return reply

    def new_pane():
        checked(rpc("action.run", {"action": "splitRight", "focus": True, "origin": "script"}))
        checked(open_chat())
        checked(pane("select_session", session="mock-session"))
        target = checked(pane("engine"))["pane"]
        if not wait(lambda: pane("readiness", pane=target).get("composer_visible"), 20):
            raise RuntimeError(f"composer did not become visible in {target}")
        return target

    def stream(target, delay=0):
        if delay:
            time.sleep(delay)  # intentional workload onset, not synchronization
        started = time.monotonic()
        result = checked(pane("load_run", pane=target, seconds=duration + 8, chunk_ms=4,
                              chunk_chars=32, tool_every=60, scroll_speed=0, timeout=60))
        return {"pane": target, "started": started, "ended": time.monotonic(), "result": result}

    for mode in modes:
        row = {"load": mode, "requested_keys": keys, "gap_ms": gap_ms,
               "clock": "DOM keydown timestamp to after-frame MessageChannel callback",
               "native_queue_included": True,
               "dispatch_clock": "Python time.time; paint performance.timeOrigin + performance.now, same host"}
        stress = []
        owned_panes = []
        pool = ThreadPoolExecutor(max_workers=3)
        futures = []
        try:
            # Fresh panes keep previous drafts and workloads out of the next sample.
            target = new_pane()
            owned_panes.append(target)
            row["pane"] = target
            if mode in ("streaming-3", "background-wake"):
                targets = [target]
                for _ in range(2 if mode == "streaming-3" else 1):
                    other = new_pane()
                    targets.append(other)
                    owned_panes.append(other)
                for load_pane in targets:
                    checked(pane("load_seed", pane=load_pane, turns=20, timeout=60))
                if mode == "streaming-3":
                    futures = [pool.submit(stream, p) for p in targets]
                    for p in targets:
                        active = wait(lambda: (pane("chat_state", pane=p).get("lastAssistant") or {}).get("streaming"), 10)
                        if not active:
                            raise RuntimeError(f"stream did not start in {p}")
                else:
                    # Another pane's turn starts while keys are in flight, without taking focus.
                    futures = [pool.submit(stream, targets[-1], duration / 3)]
            if mode == "100k":
                # syntheticRows rounds to complete three-row turns: request 100002, not 100000 -> 99999.
                row["seed"] = checked(pane("seed_rows", pane=target, count=100002, timeout=60))
                if row["seed"].get("rows", 0) < 100000:
                    raise RuntimeError("100k fixture did not expose at least 100000 rows")
            checked(pane("focus_composer", pane=target))
            before_clear = checked(pane("typing_stats", pane=target)).get("keys", 0)
            # These are isolated benchmark panes. Clear the mock session's persisted draft,
            # then measure only fresh ordinary keys (the selection/deletion is outside the reset).
            checked(rpc("debug.key", {"target": "page", "pane": target, "key": "a", "modifiers": ["command"]}))
            checked(rpc("debug.key", {"target": "page", "pane": target, "key": "backspace"}))
            cleared = wait(lambda: (lambda r: r if r.get("composer_text") == "" and
                r.get("keys", 0) >= before_clear + 2 else None)(pane("typing_stats", pane=target)), 5)
            if not cleared:
                raise RuntimeError("fresh composer is not empty or text readback is unavailable")
            checked(pane("reset_typing", pane=target))
            if mode == "cpu":
                cores = os.cpu_count() or 1
                # Only these recorded child PIDs are stopped; a wall-clock limit also bounds them.
                program = "import time\nend=time.monotonic()+60\nx=1\nwhile time.monotonic()<end: x=(x*1664525+1013904223)%4294967296"
                row["stress_cores"] = cores
                row["stress_cpu_before"] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime
                row["stress_started"] = time.monotonic()
                for _ in range(cores):
                    stress.append(subprocess.Popen([sys.executable, "-c", program], stdout=subprocess.DEVNULL,
                                                   stderr=subprocess.DEVNULL))
                row["stress_pids"] = [p.pid for p in stress]
                time.sleep(.5)  # intentional load warmup
            send_start = time.monotonic()
            wall_start = time.time()
            dispatch = []
            for index, letter in enumerate(expected):
                if time.monotonic() > send_start + duration + 10:
                    raise RuntimeError("native typing exceeded its scheduled duration by 10 seconds")
                deadline = send_start + index * gap_ms / 1000
                time.sleep(max(0, deadline - time.monotonic()))
                start = time.monotonic()
                epoch_ms = time.time() * 1000
                reply = checked(rpc("debug.key", {"target": "page", "pane": target, "key": letter}, timeout=2))
                dispatch.append({"index": index, "epoch_ms": epoch_ms, "late_ms": (start - deadline) * 1000,
                                 "rpc_ms": (time.monotonic() - start) * 1000, "reply": reply})
            row["send_started"], row["send_ended"] = send_start, time.monotonic()
            row["wall_clock_drift_ms"] = abs((time.time() - wall_start) - (time.monotonic() - send_start)) * 1000
            row["dispatch"] = dispatch
            report = wait(lambda: (lambda r: r if r.get("keys", 0) >= keys else None)(
                pane("typing_stats", pane=target)), 10)
            row["typing"] = report or checked(pane("typing_stats", pane=target))
            row.update(verdict(row["typing"], expected, dispatch))
            row["driver_p95_late_ms"] = percentile([d["late_ms"] for d in dispatch], .95)
            row["driver_p99_rpc_ms"] = percentile([d["rpc_ms"] for d in dispatch], .99)
            row["cadence_valid"] = row["driver_p95_late_ms"] <= gap_ms
            row["complete"] = row["complete"] and row["cadence_valid"]
            row["complete"] = row["complete"] and row["wall_clock_drift_ms"] < 2 and abs(
                row["typing"].get("epoch_clock_error_ms", math.inf)) < 2
        except Exception as error:
            row.update(complete=False, error=str(error))
        finally:
            for process in stress:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()  # this exact child only
                    process.wait(timeout=10)
            if stress:
                elapsed = time.monotonic() - row["stress_started"]
                used = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime - row["stress_cpu_before"]
                row["stress_core_utilization"] = used / elapsed / len(stress)
                row["complete"] = row.get("complete", False) and row["stress_core_utilization"] >= .8
            try:
                row["streams"] = [future.result(timeout=60) for future in futures]
                for stream_result in row["streams"]:
                    if stream_result["result"].get("deltas", 0) < 1:
                        row["complete"] = False
                    observed = stream_result["result"]
                    first = row.get("dispatch", [{}])[0].get("epoch_ms", math.inf)
                    last = row.get("dispatch", [{}])[-1].get("epoch_ms", -math.inf)
                    began = observed.get("stream_started_epoch_ms", math.inf)
                    ended = observed.get("stream_finished_epoch_ms", -math.inf)
                    if mode == "streaming-3" and not began <= first < last <= ended:
                        row["complete"] = False
                    if mode == "background-wake" and not first < began < last:
                        row["complete"] = False
            except Exception as error:
                row.update(complete=False, stream_error=str(error))
            pool.shutdown(wait=True)
            for owned in reversed(owned_panes):
                reply = rpc("action.run", {"action": "closePane", "target": f"pane:{owned}"})
                if not isinstance(reply, dict) or reply.get("error"):
                    row.update(complete=False, cleanup_error=reply)
        row["acceptance_met"] = bool(row.get("complete") and
            row.get("dispatch_to_after_frame_p95_ms", math.inf) <= 16 and
            row.get("dispatch_to_after_frame_p99_ms", math.inf) <= 33)
        results.append(row)
        print("TYPING-LOAD", mode, row.get("paint_p95_ms"), row.get("paint_p99_ms"),
              "complete", row.get("complete"), flush=True)
    return results
