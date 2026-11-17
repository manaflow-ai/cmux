#!/usr/bin/env python3
"""cmux.rd/1 under kernel netem jitter on one Linux machine, no Mac.

  rd-netem-linux.py --commit SHA [--commit SHA ...] --out DIR [--deps]
  rd-netem-linux.py --bin LABEL=PATH [--bin ...] --out DIR
  rd-netem-linux.py table RESULTS.jsonl
  rd-netem-linux.py holds [SEED [SECONDS]]

For each cmux commit it builds `cmux-rd` (`cmux-tui/crates/cmux-rd-host`, release, features
`bench,openh264,link`) in a fresh sparse source tree, then runs the real host and viewer in two network
namespaces joined by a veth whose two ends each carry `tc netem`:

  host ns:   Xvfb, `cmux-rd testapp --workload motion`, `cmux-rd host --profile baseline`
  viewer ns: `cmux-rd bench --carrier udp` (OpenH264 decode, hence the baseline profile)

The host encodes with Cisco's OpenH264 binary, the one shipped hosts load, fetched by the measured
binary's `cmux-rd openh264-install` (--openh264 cisco, the default) or given as a path.
`--openh264 source` keeps the bench feature's source build, which compiles without its assembly and
encodes about 3x slower; the tables mark its rows "source-built, about 3x slower", and so rows
written before this flag existed, which were all source-built.

Profiles (the netem line is applied to each direction's egress, so media and feedback both
see it; jitter is netem's default distribution, which reorders packets):

  clean            delay 0ms
  jitter-5         delay 5ms 5ms
  jitter-15-burst  delay 15ms 15ms, Gilbert-Elliott loss averaging 1 % in bursts of ~4 packets
  jitter-30-loss2  delay 30ms 30ms, 2 % random loss
  stall            delay 4ms, and every 5 s every packet held 0.6 s, then released at once (a Wi-Fi
                   leg). It runs host and viewer in the host namespace over its own `lo`, so the
                   bench's --eval-local decode records give, per stall, the first frame captured
                   after the release and when it decoded; it runs the passive session only.
  wifi-away        Leo's radio away from the access point: delay 4ms, 2 % loss, short 50-100 ms holds
                   every 0.53 s and long 300-580 ms holds at irregular gaps, from the seeded
                   wifi-away-holds.json (`rd-netem-linux.py holds [SEED [SECONDS]]` prints it).
                   Ablations: wifi-away-short, wifi-away-long, wifi-away-loss; wifi-gate (the gate profile,
                   p50 <= 60 ms and p95 <= 100 ms) is the short holds plus the 2 % loss; wifi-short is
                   wifi-gate with every hold capped at 60 ms (its holds alone floor wifi-gate's p95 at
                   ~95 ms, so a 100 ms p95 is reported on wifi-short beside it). Same `lo` topology;
                   passive then key session; reports the target's largest fall and its recovery,
                   gate wait, and the share of key samples over 50 ms. Opt-in (--profile).

Each profile starts a fresh host and runs two viewer sessions against it:
  passive  `bench --input none --duration-s N`: received Mbps per second and the host's target
           bitrate per second (the `kbps` of the host's newest stats message in that second)
  key      `bench --input key --samples N`: key press to decoded marker, p50/p95, lost
IDRs are the host's own per-frame timing records (CMUX_RD_TIMING_LOG) during each session.
`stage_ledger` (schema cmux.rd-stage-ledger/1) is copied from each bench line that has it.

Writes DIR/results.jsonl (one line per commit and profile, also printed) and DIR/results.md.
Needs root for `ip netns` and `tc` (it prefixes `sudo -n` when not root) and a kernel with
sch_netem. On the fleet: cmuxterm-hq `cmux-ci test --setup netem` (README.md here).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

SCHEMA = "cmux.rd-netem-linux/1"
LEDGER_SCHEMA = "cmux.rd-stage-ledger/1"
REPO_URL = "https://github.com/manaflow-ai/cmux.git"
BUILD_FEATURES = "bench,openh264,link"
HOST_IP, VIEW_IP, PORT ="10.78.0.1", "10.78.0.2", 4103

# name -> netem arguments for each direction's egress (after `netem`).
PROFILES = {
    "clean": "delay 0ms",
    "jitter-5": "delay 5ms 5ms",
    # Gilbert-Elliott: p=0.25 % into the bad state, r=25 % out (mean burst 4 packets), every
    # packet lost in the bad state and none in the good one: p/(p+r) = 0.99 % lost on average.
    "jitter-15-burst": "delay 15ms 15ms loss gemodel 0.25% 25% 100% 0%",
    "jitter-30-loss2": "delay 30ms 30ms loss random 2%",
    # A Wi-Fi leg: 4 ms steady, then every STALL_PERIOD_S every packet is held for STALL_HOLD_S and
    # released as one burst (StallDriver). Runs on the host namespace's own `lo` (below).
    "stall": "delay 4ms",
    # Leo's radio away from the access point (air-blue capture): 4 ms, short 50-100 ms holds every
    # 0.53 s, long 300-580 ms holds at irregular gaps, 2 % loss. The holds come from
    # wifi-away-holds.json (seeded, WIFI_AWAY_SEED); the three ablations split it.
    "wifi-away": "delay 4ms loss random 2%",
    "wifi-away-short": "delay 4ms",
    "wifi-away-long": "delay 4ms",
    "wifi-away-loss": "delay 4ms loss random 2%",
    # The screen-share gate profile (p50 <= 60 ms, p95 <= 100 ms): wifi-away-short plus wifi-away-loss.
    "wifi-gate": "delay 4ms loss random 2%",
    # wifi-gate with every hold capped at WIFI_SHORT_CAP_S: holds over ~60 ms alone push a press past
    # 100 ms on a ~33 ms pipeline, so a p95 <= 100 ms target is reported here beside wifi-gate.
    "wifi-short": "delay 4ms loss random 2%",
}
WIFI_SHORT_CAP_S = 0.060
STALL_PERIOD_S, STALL_HOLD_S = 5.0, 0.6
# Profiles that run host and viewer in the host namespace over its own `lo` (one qdisc, each
# direction crosses it once), with HoldDriver applying their holds.
LO_PROFILES = ("stall", "wifi-away", "wifi-away-short", "wifi-away-long", "wifi-away-loss", "wifi-gate",
               "wifi-short")
WIFI_AWAY_SEED, WIFI_AWAY_SECONDS = 7, 120.0
HOLDS_FILE = Path(__file__).with_name("wifi-away-holds.json")
# Extra `cmux-rd host` flags for every host this run starts (--host-arg, e.g. an encode profile).
HOST_ARGS: list[str] = []
# The OpenH264 every host encodes with (--openh264): "cisco", Cisco's binary that shipped hosts load,
# fetched with the measured cmux-rd's own `openh264-install`; "source", the bench feature's source
# build, compiled without its assembly; or a path to Cisco's library.
OPENH264 = ["cisco"]
# The `--openh264-lib PATH` the binary being measured passes its hosts, empty for the source build.
LIB_ARGS: list[str] = []
# How a table marks a row whose host encoded with the source build. A row without an `openh264`
# field predates the flag and was source-built too.
SOURCE_BUILT = "source-built, about 3x slower"
PROFILE_LABELS = {
    "clean": "clean",
    "jitter-5": "5±5 ms",
    "jitter-15-burst": "15±15 ms, 1% burst loss",
    "jitter-30-loss2": "30±30 ms, 2% loss",
    "stall": "4 ms, 0.6 s hold every 5 s",
    "wifi-away": "Wi-Fi away: short + long holds, 2% loss",
    "wifi-away-short": "Wi-Fi away: short holds only",
    "wifi-away-long": "Wi-Fi away: long holds only",
    "wifi-away-loss": "Wi-Fi away: 2% loss only",
    "wifi-gate": "Wi-Fi gate: short holds + 2% loss",
    "wifi-short": "Wi-Fi gate, holds capped at 60 ms",
}


# ---------------------------------------------------------------- pure parsing and table


def netem_args(profile: str) -> list[str]:
    return ["netem", *PROFILES[profile].split(), "limit", "100000"]


def last_json_line(text: str) -> dict | None:
    """The bench prints one JSON report as its last stdout line."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                return value
    return None


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def ledger_of(report: dict | None):
    """The bench line's stage ledger, or None when this commit's bench has none."""
    ledger = (report or {}).get("stage_ledger")
    return ledger if isinstance(ledger, dict) else None


def summarize_passive(report: dict | None) -> dict:
    """Per-second received Mbps and host target kbps from a `--input none` bench line."""
    if not report:
        return {"ok": False}
    mbps, target, keyframes, fps = [], [], [], []
    for row in report.get("series") or []:
        b, ms = _num(row.get("bytes")), _num(row.get("duration_ms"))
        mbps.append(round(b * 8 / (ms / 1000) / 1e6, 3) if b is not None and ms else None)
        n = _num(row.get("decoded_frames"))
        fps.append(round(n / (ms / 1000), 2) if n is not None and ms else None)
        stats = row.get("host_stats") or {}
        target.append(_num(stats.get("kbps")))
        keyframes.append(_num(stats.get("keyframes")))
    seen = [k for k in keyframes if k is not None]
    seconds = _num(report.get("seconds"))
    total = _num(report.get("bytes"))
    return {
        "ok": bool(mbps) and report.get("ended") is None,
        "seconds": seconds,
        "mbps_per_s": mbps,
        "mbps_mean": round(total * 8 / seconds / 1e6, 3) if total is not None and seconds else None,
        "target_kbps_per_s": target,
        "decoded_fps_per_s": fps,
        "target_s_to_15mbps": seconds_to(target, 15_000),
        "received_s_to_15mbps": seconds_to(mbps, 15),
        "host_keyframes_delta": (seen[-1] - seen[0]) if len(seen) >= 2 else None,
        "fps": _num(report.get("fps")),
        "decoded_frames": _num(report.get("decoded_frames")),
        "decode_errors": report.get("decode_errors"),
        "first_frame_ms": _num(report.get("first_frame_ms")),
        "ended": report.get("ended"),
        "stage_ledger": ledger_of(report),
    }


def seconds_to(series: list, level: float):
    """The 1-based second in which a per-second series first reaches level, or None."""
    return next((i + 1 for i, v in enumerate(series) if v is not None and v >= level), None)


def pct_over(sample_times, ms: float):
    """Percent of shown key samples whose key-to-decoded time exceeded ms (bench `sample_times`)."""
    g2g = [(t["decoded_ns"] - t["sent_ns"]) / 1e6 for t in sample_times or []
           if _num(t.get("decoded_ns")) is not None and _num(t.get("sent_ns")) is not None]
    return round(sum(v > ms for v in g2g) * 100 / len(g2g), 1) if g2g else None


def pct_of(sample_times, p: float):
    """The p-th percentile (nearest rank) of key-to-decoded ms over the bench's `sample_times`, or None."""
    g2g = sorted((t["decoded_ns"] - t["sent_ns"]) / 1e6 for t in sample_times or []
                 if _num(t.get("decoded_ns")) is not None and _num(t.get("sent_ns")) is not None)
    return round(g2g[min(len(g2g) - 1, int(round(p / 100.0 * (len(g2g) - 1))))], 2) if g2g else None


def _overlap_us(a: float, b: float, holds: list[tuple[int, int]]) -> float:
    """Microseconds of [a, b] that fall inside any (start_us, end_us) hold."""
    return sum(max(0.0, min(b, e) - max(a, s)) for s, e in holds) if b > a else 0.0


def press_rows(sample_times, timing_text: str, holds: list[tuple[int, int]] | None = None) -> list[dict]:
    """One row per shown key press, every stage in ms, for tail attribution.

    Joins the bench's `sample_times` (viewer: sent_ns, capture_us, first_rx_ns, complete_ns,
    decoded_ns) to the host's CMUX_RD_TIMING_LOG for the same session (inject lines
    {inject_us, recv_us}; frame lines whose release_us is the sample's capture_us). Host and viewer
    share CLOCK_MONOTONIC on one machine. Stages: up (sent -> host read the input), inject (read ->
    injected), to_release (injected -> the marker frame's encode released; it holds the capture tick,
    the app's redraw and the gate), gate (the marker frame's damage -> release), encode, pace
    (encoded -> last datagram sent), wire (last datagram sent -> frame complete at the viewer: netem,
    holds, lost shards and their NACK rounds), rx_spread (first datagram -> complete), decode
    (complete -> decoded). hold_up / hold_down: ms of the up stage / of [encoded, complete] inside a
    netem hold; frames_skipped: frames released between the injection and the marker frame."""
    injects, frames = [], {}
    for line in timing_text.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict):
            continue
        if _num(r.get("inject_us")) is not None:
            injects.append(r)
        elif _num(r.get("release_us")) is not None:
            frames[r["release_us"]] = r
    injects.sort(key=lambda r: r["inject_us"])
    releases = sorted(frames)
    holds = holds or []
    out = []
    for t in sample_times or []:
        sent_us, cap = t.get("sent_ns", 0) / 1000, t.get("capture_us")
        row = {"sent_us": int(sent_us), "total": round((t["decoded_ns"] - t["sent_ns"]) / 1e6, 2),
               "frame": t.get("frame")}
        inj = next((r for r in injects if r["inject_us"] >= sent_us), None)
        f = frames.get(cap)
        if inj:
            recv = _num(inj.get("recv_us")) or inj["inject_us"]
            row["up"] = round((recv - sent_us) / 1000, 2)
            row["inject"] = round((inj["inject_us"] - recv) / 1000, 2)
            row["to_release"] = round((cap - inj["inject_us"]) / 1000, 2) if cap else None
            row["frames_skipped"] = sum(inj["inject_us"] < x < (cap or 0) for x in releases)
            row["hold_up"] = round(_overlap_us(sent_us, recv, holds) / 1000, 2)
        if f:
            dmg = _num(f.get("damage_us"))
            row["gate"] = round((f["release_us"] - dmg) / 1000, 2) if dmg is not None else None
            row["encode"] = round((f["encoded_us"] - f["release_us"]) / 1000, 2)
            sent_f = _num(f.get("sent_us")) or f["encoded_us"]
            row["pace"] = round((sent_f - f["encoded_us"]) / 1000, 2)
            row["wire"] = round((t["complete_ns"] / 1000 - sent_f) / 1000, 2)
            row["idr"], row["bytes"] = f.get("idr"), f.get("encoded_bytes")
            row["hold_down"] = round(_overlap_us(f["encoded_us"], t["complete_ns"] / 1000, holds) / 1000, 2)
        row["rx_spread"] = round((t["complete_ns"] - t["first_rx_ns"]) / 1e6, 2)
        row["decode"] = round((t["decoded_ns"] - t["complete_ns"]) / 1e6, 2)
        out.append(row)
    return out


def key_frames(timing_text: str) -> list[list]:
    """The session's encoded frames as [release_us, damage_us, encoded_us, sent_us, idr, bytes]."""
    out = []
    for line in timing_text.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and _num(r.get("release_us")) is not None and _num(r.get("encoded_us")) is not None:
            out.append([r["release_us"], r.get("damage_us"), r["encoded_us"], r.get("sent_us"),
                        int(bool(r.get("idr"))), r.get("encoded_bytes")])
    return out


def summarize_key(report: dict | None) -> dict:
    """Key press to decoded marker from a `--input key` bench line."""
    if not report:
        return {"ok": False}
    g2g = report.get("g2g_ms") or {}
    stats = report.get("host_stats_last") or {}
    return {
        "ok": bool(g2g.get("n")),
        "n": g2g.get("n"),
        "p50_ms": _num(g2g.get("p50")),
        "p95_ms": _num(g2g.get("p95")),
        "p99_ms": pct_of(report.get("sample_times"), 99),
        "lost": report.get("lost"),
        "stalls_ms": report.get("stalls_ms"),
        "mbit_per_s": _num(report.get("mbit_per_s")),
        "frames_per_s": _num(report.get("frames_per_s")),
        "pct_over_50ms": pct_over(report.get("sample_times"), 50),
        "target_kbps_last": _num(stats.get("kbps")),
        "host_loss_pct_last": _num(stats.get("loss_pct")),
        "ended": report.get("ended"),
        "stage_ledger": ledger_of(report),
    }


def wire_summary(samples: list[tuple[float, int, int]]) -> dict:
    """Per-second Mbps from (monotonic s, viewer rx bytes, viewer tx bytes) veth counter samples.

    The viewer veth's counters are every byte on the wire after netem, all kinds together
    (media, FEC, probes, control, feedback and IP/UDP headers). The bench's own media + FEC
    count is `passive.mbps_per_s`; the difference is the rest."""
    down, up = [], []
    for (t0, r0, x0), (t1, r1, x1) in zip(samples, samples[1:]):
        dt = t1 - t0
        if dt > 0:
            down.append(round((r1 - r0) * 8 / dt / 1e6, 3))
            up.append(round((x1 - x0) * 8 / dt / 1e6, 3))
    return {"down_mbps_per_s": down, "up_mbps_per_s": up,
            "source": "viewer veth rx/tx bytes (all datagram kinds, with headers)"}


def wifi_away_schedule(seed: int = WIFI_AWAY_SEED, seconds: float = WIFI_AWAY_SECONDS) -> dict:
    """The wifi-away hold schedule: [start s, length s] pairs, the same for every run of a seed.

    Short holds: every 0.53 s, 50-100 ms (uniform). Long holds: gaps lognormal with median 3.4 s
    clipped to 0.5-11 s, lengths normal around 455 ms clipped to 300-580 ms."""
    rng = random.Random(seed)
    short, t = [], 0.53
    while t < seconds:
        short.append([round(t, 3), round(rng.uniform(0.05, 0.10), 3)])
        t += 0.53
    long, t = [], 0.0
    while True:
        t += min(11.0, max(0.5, rng.lognormvariate(math.log(3.4), 0.8)))
        if t >= seconds:
            break
        length = min(0.58, max(0.30, rng.gauss(0.455, 0.07)))
        long.append([round(t, 3), round(length, 3)])
        t += length
    return {"schema": "cmux.rd-netem-holds/1", "seed": seed, "seconds": seconds, "base_delay_ms": 4,
            "loss_pct": 2.0, "short": short, "long": long}


def merge_holds(pairs: list) -> list[tuple[float, float]]:
    """[start, length] pairs as non-overlapping (start, end) intervals, in order."""
    out: list[list[float]] = []
    for start, end in sorted((a, a + b) for a, b in pairs):
        if out and start <= out[-1][1]:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return [(a, b) for a, b in out]


def profile_holds(profile: str, schedule: dict | None = None) -> tuple[list[tuple[float, float]], float, float]:
    """(holds as (start, end) s, schedule period s, loss %) for a LO_PROFILES profile."""
    if profile == "stall":
        return [(k * STALL_PERIOD_S, k * STALL_PERIOD_S + STALL_HOLD_S) for k in range(1, 2)], STALL_PERIOD_S, 0.0
    schedule = schedule or json.loads(HOLDS_FILE.read_text())
    pick = {"wifi-away": ("short", "long"), "wifi-away-short": ("short",), "wifi-away-long": ("long",),
            "wifi-away-loss": (), "wifi-gate": ("short",), "wifi-short": ("short",)}[profile]
    loss = schedule["loss_pct"] if profile in ("wifi-away", "wifi-away-loss", "wifi-gate", "wifi-short") else 0.0
    cap = WIFI_SHORT_CAP_S if profile == "wifi-short" else math.inf
    pairs = [(a, min(length, cap)) for kind in pick for a, length in schedule[kind]]
    return merge_holds(pairs), schedule["seconds"], loss


def target_drawdown(target: list) -> dict:
    """The largest fall of a per-second target series: from its running peak to the lowest value
    after it, how many seconds the fall took, and how many seconds until it was back at the peak."""
    values = [v for v in target if v is not None]
    best = {"peak_kbps": None, "trough_kbps": None, "drop_pct": 0.0, "fall_s": None, "recover_s": None,
            "seconds_falling": sum(b < a for a, b in zip(values, values[1:]))}
    peak_i = 0
    for i, v in enumerate(values):
        if v > values[peak_i]:
            peak_i = i
        drop = (values[peak_i] - v) / values[peak_i] * 100 if values[peak_i] else 0.0
        if drop > best["drop_pct"]:
            back = next((j for j in range(i + 1, len(values)) if values[j] >= values[peak_i]), None)
            best.update(peak_kbps=values[peak_i], trough_kbps=v, drop_pct=round(drop, 1), fall_s=i - peak_i,
                        recover_s=(back - i) if back is not None else None)
    return best


def gate_wait(timing_text: str) -> dict | None:
    """Gate wait (damage seen until the gate released the encode), ms, from the host's timing log."""
    waits = []
    for line in timing_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and _num(row.get("damage_us")) is not None and _num(row.get("release_us")) is not None:
            waits.append((row["release_us"] - row["damage_us"]) / 1000)
    waits.sort()
    if not waits:
        return None
    return {"n": len(waits), "p50_ms": round(waits[len(waits) // 2], 2),
            "p95_ms": round(waits[min(len(waits) - 1, int(len(waits) * 0.95))], 2)}


def lo_table(rows: list[dict]) -> str:
    out = ["| cmux-rd | profile | target: peak → trough kbps (drop %), fall s, back to peak s, seconds falling "
           "| decoded fps median | gate wait p50 / p95 ms | key to decoded p50 / p95 / p99 ms | keys > 50 ms | holds |",
           "|" + "---|" * 8]
    for r in rows:
        if not str(r.get("profile", "")).startswith("wifi-") or r.get("error"):
            continue
        d, key, passive = r.get("drawdown") or {}, r.get("key") or {}, r.get("passive") or {}
        fps = [v for v in passive.get("decoded_fps_per_s") or [] if v is not None]
        gate = r.get("gate_wait") or {}
        out.append(f"| {rd_cell(r)} | {PROFILE_LABELS.get(r['profile'], r['profile'])} "
                   f"| {_fmt(d.get('peak_kbps'))} → {_fmt(d.get('trough_kbps'))} ({_fmt(d.get('drop_pct'))}%), "
                   f"{_fmt(d.get('fall_s'))}, {_fmt(d.get('recover_s'))}, {_fmt(d.get('seconds_falling'))} "
                   f"| {f'{statistics.median(fps):.1f}' if fps else '–'} "
                   f"| {_fmt(gate.get('p50_ms'))} / {_fmt(gate.get('p95_ms'))} "
                   f"| {_fmt(key.get('p50_ms'))} / {_fmt(key.get('p95_ms'))} / {_fmt(key.get('p99_ms'))} "
                   f"| {_fmt(key.get('pct_over_50ms'))}% "
                   f"| {_fmt(r.get('holds_applied'))} |")
    return "\n".join(out) + "\n" if len(out) > 2 else ""


def stall_metrics(report: dict | None, stalls: list[dict]) -> list[dict]:
    """Per stall: the host target just before and after, the first fresh decoded frame, fps after.

    `stalls` are {"start_us", "end_us"} on CLOCK_MONOTONIC and {"start_ms", "end_ms"} on the wall
    clock. The bench's `decode_records` ({"release_us": host capture time, "decoded_us"}) and its
    per-second `series` ({"unix_ms": the second's end, "host_stats": {"kbps"}}) give the rest.
    A frame is fresh when the host captured it at or after the stall's end."""
    report = report or {}
    records = sorted((r for r in report.get("decode_records") or []
                      if _num(r.get("release_us")) is not None and _num(r.get("decoded_us")) is not None),
                     key=lambda r: r["decoded_us"])
    series = [r for r in report.get("series") or [] if _num(r.get("unix_ms")) is not None]
    def target_at_or_before(ms):
        rows = [r for r in series if r["unix_ms"] <= ms]
        return _num((rows[-1].get("host_stats") or {}).get("kbps")) if rows else None
    def targets_between(a, b):
        return [_num((r.get("host_stats") or {}).get("kbps")) for r in series if a < r["unix_ms"] <= b]
    out = []
    for st in stalls:
        start, end = st["start_us"], st["end_us"]
        fresh = next((r for r in records if r["release_us"] >= end), None)
        after = [t for t in targets_between(st["end_ms"] + 1000, st["end_ms"] + 2000) if t is not None]
        window = [t for t in targets_between(st["start_ms"], st["end_ms"] + 3000) if t is not None]
        out.append({
            "start_us": start, "end_us": end,
            "target_before_kbps": target_at_or_before(st["start_ms"]),
            "target_after_kbps": after[0] if after else None,
            "target_min_within_3s_kbps": min(window) if window else None,
            "fresh_frame_ms": round((fresh["decoded_us"] - end) / 1000, 2) if fresh else None,
            "fps_second_after": sum(end <= r["decoded_us"] < end + 1_000_000 for r in records),
            # Evidence the hold happened: decodes inside the hold (after its first 50 ms) and the burst.
            "decoded_during_hold": sum(start + 50_000 <= r["decoded_us"] < end for r in records),
            "decoded_in_100ms_after": sum(end <= r["decoded_us"] < end + 100_000 for r in records),
        })
    return out


def stall_table(rows: list[dict]) -> str:
    out = ["| cmux-rd | stall | target kbps before → after (min in 3 s) | first fresh frame ms after release "
           "| fps in the second after | decodes during hold / in 100 ms after |", "|" + "---|" * 6]
    for r in rows:
        for i, st in enumerate(r.get("stalls") or [], 1):
            out.append(f"| {rd_cell(r)} | {i} | {_fmt(st.get('target_before_kbps'))} → "
                       f"{_fmt(st.get('target_after_kbps'))} ({_fmt(st.get('target_min_within_3s_kbps'))}) "
                       f"| {_fmt(st.get('fresh_frame_ms'))} | {_fmt(st.get('fps_second_after'))} "
                       f"| {_fmt(st.get('decoded_during_hold'))} / {_fmt(st.get('decoded_in_100ms_after'))} |")
    return "\n".join(out) + "\n" if len(out) > 2 else ""


def count_idrs(timing_text: str) -> dict:
    """Encoded frames and IDRs in a slice of the host's CMUX_RD_TIMING_LOG.

    `reasons` counts each IDR's `idr_reason` (or `force_idr`) for a host that logs one. No host
    does yet (`Timing::frame` in cmux-rd-host's stream.rs writes only `idr`), so today every IDR
    counts under "unlogged"."""
    frames = idrs = 0
    reasons: dict[str, int] = {}
    for line in timing_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue  # a line the host was still writing
        if not isinstance(row, dict) or not isinstance(row.get("idr"), bool):
            continue  # input lines carry no encode
        if (_num(row.get("encoded_bytes")) or 0) <= 0:
            continue
        frames += 1
        idrs += row["idr"]
        if row["idr"]:
            reason = row.get("idr_reason")
            if reason is None and isinstance(row.get("force_idr"), bool):
                reason = "requested" if row["force_idr"] else "encoder"
            reason = str(reason) if reason is not None else "unlogged"
            reasons[reason] = reasons.get(reason, 0) + 1
    return {"frames": frames, "idrs": idrs, "reasons": reasons}


def _fmt(value, digits=1):
    if value is None:
        return "–"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def rd_cell(r: dict) -> str:
    """The cmux-rd column: the commit, marked when its host encoded with the source build."""
    commit = f"`{str(r.get('commit', '?'))[:12]}`"
    return commit if r.get("openh264") == "cisco" else f"{commit} ({SOURCE_BUILT})"


def _series(values, digits=1, limit=30):
    shown = [_fmt(v, digits) for v in values[:limit]]
    return " ".join(shown) + (" …" if len(values) > limit else "") if shown else "–"


def markdown_table(rows: list[dict]) -> str:
    head = ("| cmux-rd | profile | key p50 / p95 ms (lost) | Mbps median (min–max) | Mbps per second "
            "| target kbps per second | wire Mbps down median (all kinds) | s to 15 Mbps target / received "
            "| decoded fps median "
            "| IDRs / frames passive, key (reasons) | stage ledger |")
    out = [head, "|" + "---|" * 11]
    for r in rows:
        if r.get("error"):
            out.append(f"| `{r.get('commit', '?')[:12]}` | {PROFILE_LABELS.get(r.get('profile'), r.get('profile'))} "
                       f"| error: {' '.join(str(r['error']).split())[:120]} | | | | | | | | |")
            continue
        key, passive = r.get("key") or {}, r.get("passive") or {}
        mbps = [v for v in passive.get("mbps_per_s") or [] if v is not None]
        target = [v for v in passive.get("target_kbps_per_s") or []]
        spread = (f"{statistics.median(mbps):.2f} ({min(mbps):.2f}–{max(mbps):.2f})" if mbps else "–")
        def idr_cell(c):
            c = c or {}
            why = ", ".join(f"{k} {v}" for k, v in sorted((c.get("reasons") or {}).items()))
            return f"{_fmt(c.get('idrs'))}/{_fmt(c.get('frames'))}" + (f" ({why})" if why else "")
        idr = f"{idr_cell(r.get('idr_passive'))}, {idr_cell(r.get('idr_key'))}"
        fps = [v for v in passive.get("decoded_fps_per_s") or [] if v is not None]
        fps_cell = f"{statistics.median(fps):.1f}" if fps else _fmt(passive.get("fps"))
        down = (r.get("wire") or {}).get("down_mbps_per_s") or []
        wire_cell = f"{statistics.median(down):.2f}" if down else "–"
        t15 = f"{_fmt(passive.get('target_s_to_15mbps'))} / {_fmt(passive.get('received_s_to_15mbps'))}"
        ledgers = [x for x in (passive.get("stage_ledger"), key.get("stage_ledger")) if x]
        ledger = "yes" if ledgers else "no"
        out.append(
            f"| {rd_cell(r)} | {PROFILE_LABELS.get(r['profile'], r['profile'])} "
            f"| {_fmt(key.get('p50_ms'))} / {_fmt(key.get('p95_ms'))} ({_fmt(key.get('lost'))}) "
            f"| {spread} | {_series(passive.get('mbps_per_s') or [], 1)} "
            f"| {_series(target, 0)} | {wire_cell} | {t15} | {fps_cell} | {idr} | {ledger} |")
    return "\n".join(out) + "\n"


def read_rows(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


# ---------------------------------------------------------------- privileged plumbing


def priv(cmd: list[str]) -> list[str]:
    return cmd if os.geteuid() == 0 else ["sudo", "-n", *cmd]


def run(cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, **kw)


class Rig:
    """Two namespaces and a veth, named after this process so parallel runs never collide."""

    def __init__(self):
        tag = os.getpid()
        self.host_ns, self.view_ns = f"rdnh-{tag}", f"rdnv-{tag}"
        self.host_dev, self.view_dev = f"rdh{tag % 100000}", f"rdv{tag % 100000}"

    def up(self):
        run(priv(["ip", "netns", "add", self.host_ns]))
        run(priv(["ip", "netns", "add", self.view_ns]))
        run(priv(["ip", "link", "add", self.host_dev, "netns", self.host_ns, "type", "veth",
                  "peer", "name", self.view_dev, "netns", self.view_ns]))
        for ns, dev, ip in ((self.host_ns, self.host_dev, HOST_IP), (self.view_ns, self.view_dev, VIEW_IP)):
            run(priv(["ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up"]))
            run(priv(["ip", "netns", "exec", ns, "ip", "addr", "add", f"{ip}/24", "dev", dev]))
            run(priv(["ip", "netns", "exec", ns, "ip", "link", "set", dev, "mtu", "1500", "up"]))
            # Segmentation offload would hand netem 64 KB super-packets instead of datagrams.
            run(priv(["ip", "netns", "exec", ns, "ethtool", "-K", dev, "gso", "off", "tso", "off", "gro", "off"]),
                check=False)

    def shape(self, profile: str) -> list[str]:
        lines = []
        links = (((self.host_ns, "lo"),) if profile in LO_PROFILES
                 else ((self.host_ns, self.host_dev), (self.view_ns, self.view_dev)))
        for ns, dev in links:
            run(priv(["ip", "netns", "exec", ns, "tc", "qdisc", "replace", "dev", dev, "root", *netem_args(profile)]))
            lines.append(run(priv(["ip", "netns", "exec", ns, "tc", "qdisc", "show", "dev", dev])).stdout.strip())
        return lines

    def down(self):
        for ns in (self.host_ns, self.view_ns):
            run(priv(["ip", "netns", "del", ns]), check=False)

    def unshape_lo(self):
        run(priv(["ip", "netns", "exec", self.host_ns, "tc", "qdisc", "del", "dev", "lo", "root"]), check=False)

    def spawn(self, ns: str, argv: list[str], env: dict | None = None, token: Path | None = None,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) -> subprocess.Popen:
        # sudo closes inherited descriptors, so the token reaches fd 3 inside the namespace, as a
        # pipe: cmux-rd refuses a token fd that is a file.
        inner = ["env", *(f"{k}={v}" for k, v in (env or {}).items())]
        if token is not None:
            inner += ["bash", "-c", 'exec "$@" 3< <(cat "$0")', str(token)]
        return subprocess.Popen(priv(["ip", "netns", "exec", ns, *inner, *argv]),
                                stdout=stdout, stderr=stderr, start_new_session=True)


class HoldDriver:
    """Holds every packet on the host namespace's `lo` during each (start, end) interval of
    `holds` (seconds from start(), repeating every `period_s`), then releases them at once, by
    toggling netem's delay: during a hold it lowers the delay every 10 ms to (hold end - now) +
    4 ms, so each held packet is due at the hold's end. `loss_pct` stays on throughout. One
    `tc -batch -` process takes the changes; each applied hold lands in `stalls`."""

    def __init__(self, rig: "Rig", holds: list[tuple[float, float]], period_s: float, loss_pct: float = 0.0):
        self.rig, self.holds, self.period_s, self.loss = rig, holds, period_s, loss_pct
        self.stalls, self.done = [], threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.tc = None

    def set_delay(self, ms: float):
        loss = f" loss random {self.loss:g}%" if self.loss else ""
        self.tc.stdin.write(f"qdisc change dev lo root netem delay {ms:.1f}ms{loss} limit 100000\n".encode())
        self.tc.stdin.flush()

    def run(self):
        self.tc = subprocess.Popen(priv(["ip", "netns", "exec", self.rig.host_ns, "tc", "-force", "-batch", "-"]),
                                   stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.monotonic_ns()
        try:
            for cycle in range(10_000):
                for a, b in self.holds:
                    start_ns = t0 + int((cycle * self.period_s + a) * 1e9)
                    end_ns = t0 + int((cycle * self.period_s + b) * 1e9)
                    if self.done.wait(max(0.0, (start_ns - time.monotonic_ns()) / 1e9)):
                        return
                    start_ms = time.time() * 1000 - (time.monotonic_ns() - start_ns) / 1e6
                    while (left := end_ns - time.monotonic_ns()) > 0:
                        self.set_delay(4 + left / 1e6)
                        time.sleep(0.01)
                    self.set_delay(4)
                    self.stalls.append({"start_us": start_ns // 1000, "end_us": end_ns // 1000, "start_ms": start_ms,
                                        "end_ms": start_ms + (end_ns - start_ns) / 1e6})
                if not self.holds and self.done.wait(self.period_s):
                    return
        finally:
            self.tc.stdin.close()
            self.tc.wait(timeout=10)

    def start(self):
        self.thread.start()

    def stop(self):
        self.done.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=10)


class WireSampler:
    """Reads the viewer veth's byte counters once a second while a bench session runs."""

    def __init__(self, rig: "Rig"):
        self.rig, self.samples, self.done = rig, [], threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def read(self):
        out = run(priv(["ip", "netns", "exec", self.rig.view_ns, "cat",
                        f"/sys/class/net/{self.rig.view_dev}/statistics/rx_bytes",
                        f"/sys/class/net/{self.rig.view_dev}/statistics/tx_bytes"]), check=False).stdout.split()
        if len(out) == 2:
            self.samples.append((time.monotonic(), int(out[0]), int(out[1])))

    def run(self):
        while not self.done.is_set():
            self.read()
            self.done.wait(1.0)

    def start(self):
        self.thread.start()

    def stop(self):
        self.done.set()
        self.thread.join(timeout=5)


def stop(proc: subprocess.Popen | None):
    """Stops a child this script started (by its own pid; sudo forwards the signal)."""
    if proc is None or proc.poll() is not None:
        return
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


# ---------------------------------------------------------------- build


DEPS = ("build-essential", "pkg-config", "libssl-dev", "nasm", "curl", "iproute2", "ethtool", "xvfb", "x11-xkb-utils")


def missing_deps() -> list[str]:
    """The DEPS dpkg does not list as installed."""
    out = run(["dpkg-query", "-W", "-f", "${Package} ${Status}\n", *DEPS], check=False).stdout
    have = {line.split()[0] for line in out.splitlines() if line.endswith("install ok installed")}
    return [p for p in DEPS if p not in have]


def ensure_deps():
    """apt-get only what is missing: a worker that already has every package never touches apt, so
    an apt lock or a bad mirror on it cannot fail the run (2026-11-16: three runs died in apt)."""
    missing = missing_deps()
    if not missing:
        return
    install = ["apt-get", "install", "-y", "-qq", "--no-install-recommends"]
    run(priv(["apt-get", "update", "-qq"]), check=False)
    done = run(priv([*install, *missing]), check=False)
    still = missing_deps()
    if still:
        # A stale mirror index 404s on a package file: refresh once more and skip what still 404s
        # (--fix-missing), so one bad mirror on a fleet worker does not kill the run.
        run(priv(["apt-get", "update", "-qq"]), check=False)
        done = run(priv([*install, "--fix-missing", *still]), check=False)
        still = missing_deps()
    if still:
        raise SystemExit(f"rd-netem-linux: apt-get could not install {' '.join(still)} "
                         f"(exit {done.returncode}): {done.stderr.strip()[-600:]}")


def build(commit: str, work: Path, repo_url: str) -> Path:
    src = work / f"src-{commit[:12]}"
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    git = ["git", "-C", str(src)]
    run(git + ["init", "-q"])
    run(git + ["remote", "add", "origin", repo_url])
    run(git + ["fetch", "-q", "--depth=1", "--filter=blob:none", "origin", commit])
    run(git + ["sparse-checkout", "set", "cmux-tui/crates"])
    run(git + ["checkout", "-q", "--detach", commit])
    full = run(git + ["rev-parse", "HEAD"]).stdout.strip()
    if not full.startswith(commit):
        raise SystemExit(f"fetched {full}, asked for {commit}")
    found = re.search(r'channel\s*=\s*"([^"]+)"', (src / "cmux-tui/rust-toolchain.toml").read_text())
    if not found:
        raise SystemExit(f"{commit}: no toolchain channel in cmux-tui/rust-toolchain.toml")
    toolchain = found.group(1)
    env = dict(os.environ, RUSTUP_TOOLCHAIN=toolchain, CARGO_TARGET_DIR=str(work / "target"))
    cargo_bin = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")) / "bin"
    env["PATH"] = f"{cargo_bin}:{env['PATH']}"
    if not shutil.which("rustup", path=env["PATH"]):
        installer = work / "rustup-init.sh"
        subprocess.run(["curl", "--fail", "-sS", "https://sh.rustup.rs", "-o", str(installer)], check=True)
        subprocess.run(["sh", str(installer), "-y", "--profile", "minimal", "--default-toolchain", "none",
                        "--no-modify-path"], check=True)
    subprocess.run(["rustup", "toolchain", "install", toolchain, "--profile", "minimal"], check=True, env=env)
    t0 = time.time()
    # The release build's features plus the bench viewer; `portal` (Wayland capture through PipeWire)
    # is left out like cmux-rd-release.yml does: Xvfb needs none of it.
    subprocess.run(["cargo", "build", "--release", "--locked", "--bin", "cmux-rd", "--no-default-features",
                    "--features", BUILD_FEATURES, "--manifest-path",
                    str(src / "cmux-tui/crates/cmux-rd-host/Cargo.toml")], check=True, env=env)
    print(f"rd-netem-linux: built {full[:12]} in {time.time() - t0:.0f} s", file=sys.stderr, flush=True)
    out = work / "bin" / f"cmux-rd-{full}"
    out.parent.mkdir(exist_ok=True)
    shutil.copy2(work / "target/release/cmux-rd", out)
    shutil.rmtree(src)
    return out


# ---------------------------------------------------------------- measure


def wait_for(path: Path, needle: str, proc: subprocess.Popen, seconds: float) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if path.exists() and needle in path.read_text(errors="replace"):
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    return False


def bench(rig: Rig, binary: Path, token: Path, args: list[str], timeout: float,
          loopback: bool = False) -> tuple[dict | None, str]:
    addr = f"127.0.0.1:{PORT}" if loopback else f"{HOST_IP}:{PORT}"
    argv = [str(binary), "bench", "--addr", addr, "--carrier", "udp", "--user", "owner",
            "--token-fd", "3", *(["--eval-local", "1"] if loopback else []), *args]
    proc = rig.spawn(rig.host_ns if loopback else rig.view_ns, argv, token=token,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        stop(proc)
        out, err = proc.communicate()
        err = (err or b"") + b"\nrd-netem-linux: bench timed out"
    return last_json_line(out.decode(errors="replace")), err.decode(errors="replace")[-800:]


def measure_profile(rig: Rig, binary: Path, commit: str, profile: str, scratch: Path, display: str,
                    passive_s: int, samples: int) -> dict:
    row = {"schema": SCHEMA, "commit": commit, "profile": profile, "netem_each_direction": PROFILES[profile],
           "workload": "motion", "carrier": "udp", "host_args": HOST_ARGS,
           "openh264": "cisco" if LIB_ARGS else "source"}
    row["qdisc"] = rig.shape(profile)
    if profile in LO_PROFILES:
        return measure_lo(rig, binary, row, scratch, display, passive_s, samples)
    # The token lives in the private 0700 scratch, never under --out (an uploaded artifact).
    token = scratch / "token"
    token.write_text(os.urandom(32).hex())
    token.chmod(0o600)
    timing = scratch / f"timing-{profile}.jsonl"
    host_log = scratch / f"host-{profile}.log"
    timing.touch()
    host_log.touch()
    with open(host_log, "wb") as log:
        host = rig.spawn(rig.host_ns, [str(binary), "host", "--owner", "owner", "--bind", HOST_IP,
                                       "--single-tenant-overlay", "1", "--display", display, "--port", str(PORT),
                                       "--profile", "baseline", "--token-fd", "3", *LIB_ARGS, *HOST_ARGS],
                         env={"CMUX_RD_TIMING_LOG": str(timing)}, token=token, stdout=log, stderr=log)
    try:
        if not wait_for(host_log, "listening", host, 20):
            row["error"] = "host did not listen: " + host_log.read_text(errors="replace")[-600:]
            return row
        start = timing.stat().st_size
        wire = WireSampler(rig)
        wire.start()
        passive, perr = bench(rig, binary, token, ["--input", "none", "--duration-s", str(passive_s)], passive_s + 60)
        wire.stop()
        row["wire"] = wire_summary(wire.samples)
        mid = timing.stat().st_size
        key, kerr = bench(rig, binary, token, ["--input", "key", "--samples", str(samples)], samples * 3 + 90)
        end = timing.stat().st_size
        data = timing.read_bytes()  # st_size offsets are bytes: slice bytes, then decode
        row["passive"] = summarize_passive(passive)
        row["key"] = summarize_key(key)
        row["idr_passive"] = count_idrs(data[start:mid].decode(errors="replace"))
        row["idr_key"] = count_idrs(data[mid:end].decode(errors="replace"))
        row["key_presses"] = press_rows((key or {}).get("sample_times"), data[mid:end].decode(errors="replace"))
        if not row["passive"]["ok"]:
            row["passive"]["stderr"] = perr
        if not row["key"]["ok"]:
            row["key"]["stderr"] = kerr
        return row
    finally:
        stop(host)
        time.sleep(0.5)  # the next host binds the same port


def warmup_diag(scratch: Path, host_log: Path, frames: list, presses: list) -> dict:
    """Diagnostic: the testapp's paints and the host's trace lines from 0.3 s before the key
    session's first frame to 3 s after it, all CLOCK_MONOTONIC µs."""
    if not frames:
        return {}
    s0 = frames[0][0]
    lo, hi = s0 - 300_000, s0 + 3_000_000
    paints = []
    try:
        for line in (scratch / "testapp-paint.log").read_text(errors="replace").splitlines():
            parts = line.split()
            if len(parts) >= 4 and lo <= int(parts[-1]) <= hi:
                paints.append([parts[0], *(int(p) - s0 for p in parts[1:])])
    except (OSError, ValueError) as error:
        paints.append(repr(error))
    trace = []
    for line in host_log.read_text(errors="replace").splitlines():
        head = line.split(" ", 1)
        if len(head) == 2 and head[0].isdigit() and lo <= int(head[0]) <= hi:
            trace.append(f"{int(head[0]) - s0} {head[1][:90]}")
    return {"s0_us": s0, "load": os.getloadavg(), "ncpu": os.cpu_count(),
            "frames": [[f[0] - s0, (f[1] or s0) - s0, f[2] - s0, f[4], f[5]] for f in frames[:24]],
            "presses": [[p["sent_us"] - s0, p.get("to_release"), p["total"]] for p in presses[:10]],
            "paints": paints[:400], "trace": trace[:400]}


def measure_lo(rig: Rig, binary: Path, row: dict, scratch: Path, display: str, passive_s: int,
               samples: int) -> dict:
    """LO_PROFILES: host and viewer in the host namespace over its own `lo` (netem there delays each
    direction once, 4 ms), so the bench's `--eval-local` decode records share the host's clock.
    `stall` runs the passive session and times the first fresh frame after each release; the
    wifi-away profiles run the passive and then the key session, both under the holds."""
    profile = row["profile"]
    row["topology"] = "host namespace lo (one netem qdisc; each direction crosses it once)"
    holds, period, loss = profile_holds(profile)
    row["hold_method"] = "netem delay lowered every 10 ms to (hold end - now) + 4 ms: held, then one burst"
    if profile != "stall":
        row["holds_file"] = {"path": HOLDS_FILE.name, "seed": json.loads(HOLDS_FILE.read_text())["seed"]}
    token = scratch / "token"
    token.write_text(os.urandom(32).hex())
    token.chmod(0o600)
    timing, host_log = scratch / f"timing-{profile}.jsonl", scratch / f"host-{profile}.log"
    timing.touch()
    with open(host_log, "wb") as log:
        host = rig.spawn(rig.host_ns, [str(binary), "host", "--owner", "owner", "--bind", "127.0.0.1",
                                       "--display", display, "--port", str(PORT), "--profile", "baseline",
                                       "--token-fd", "3", *LIB_ARGS, *HOST_ARGS],
                         env={"CMUX_RD_TIMING_LOG": str(timing), "CMUX_RD_TRACE": "1"}, token=token,
                         stdout=log, stderr=log)
    driver = HoldDriver(rig, holds, period, loss)
    try:
        if not wait_for(host_log, "listening", host, 20):
            row["error"] = "host did not listen: " + host_log.read_text(errors="replace")[-600:]
            return row
        seconds = max(passive_s, 32 if profile == "stall" else 40)
        driver.start()
        passive, perr = bench(rig, binary, token, ["--input", "none", "--duration-s", str(seconds)],
                              seconds + 60, loopback=True)
        mid = timing.stat().st_size
        row["passive"] = summarize_passive(passive)
        if not row["passive"]["ok"]:
            row["passive"]["stderr"] = perr
        if profile == "stall":
            driver.stop()
            row["stall_period_s"], row["stall_hold_s"] = STALL_PERIOD_S, STALL_HOLD_S
            row["stalls"] = stall_metrics(passive, driver.stalls)
            row["key"] = {"skipped": "the stall profile measures the passive session only"}
        else:
            key, kerr = bench(rig, binary, token, ["--input", "key", "--samples", str(samples)],
                              samples * 3 + 90, loopback=True)
            driver.stop()
            row["key"] = summarize_key(key)
            if not row["key"]["ok"]:
                row["key"]["stderr"] = kerr
            row["drawdown"] = target_drawdown(row["passive"].get("target_kbps_per_s") or [])
            row["holds_applied"] = len(driver.stalls)
            # Per-press tail attribution (press_rows), the key session's frames and holds, raw.
            key_text = timing.read_bytes()[mid:].decode(errors="replace")
            first = min((t["sent_ns"] // 1000 for t in (key or {}).get("sample_times") or []), default=0)
            key_holds = [(h["start_us"], h["end_us"]) for h in driver.stalls if h["end_us"] >= first]
            row["key_holds_us"] = key_holds
            row["key_presses"] = press_rows((key or {}).get("sample_times"), key_text, key_holds)
            row["key_frames"] = key_frames(key_text)
            row["diag"] = warmup_diag(scratch, host_log, row["key_frames"], row["key_presses"])
        data = timing.read_bytes()
        row["idr_passive"] = count_idrs(data[:mid].decode(errors="replace"))
        row["gate_wait"] = gate_wait(data[:mid].decode(errors="replace"))
        return row
    finally:
        driver.stop()
        stop(host)
        rig.unshape_lo()
        time.sleep(0.5)


def openh264_lib(binary: Path, scratch: Path) -> list[str]:
    """The `cmux-rd host` flags for OPENH264: Cisco's library, through the measured binary's own
    installer (it checks the pinned SHA-256) or at a given path, or none for the source build."""
    choice = OPENH264[0]
    if choice == "source":
        return []
    if choice == "cisco":
        cmd = [str(binary), "openh264-install", "--dir", str(scratch / "openh264")]
        printed = [line for line in run(cmd, timeout=300).stdout.splitlines() if line.strip()]
        if not printed:
            raise subprocess.CalledProcessError(0, cmd, stderr="printed no library path")
        choice = printed[-1]
    return ["--openh264-lib", choice]


def measure_binary(binary: Path, commit: str, profiles: list[str], out: Path, args) -> list[dict]:
    rig = Rig()
    rig.down()
    # Private scratch (token, logs); --keep-logs copies only the logs into --out afterwards.
    scratch = Path(tempfile.mkdtemp(prefix=f"rd-netem-{commit[:12]}-"))
    rows, procs = [], []
    try:
        try:
            LIB_ARGS[:] = openh264_lib(binary, scratch)
            rig.up()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            step = "openh264" if error.cmd[:2] == [str(binary), "openh264-install"] else "netns setup"
            for profile in profiles:
                row = {"schema": SCHEMA, "commit": commit, "profile": profile,
                       "error": f"{step}: {error.cmd}: {(error.stderr or '').strip()}"}
                print(json.dumps(row), flush=True)
                with open(out / "results.jsonl", "a") as f:
                    f.write(json.dumps(row) + "\n")
                rows.append(row)
            return rows
        display = f":{170 + os.getpid() % 50}"
        procs.append(rig.spawn(rig.host_ns, ["Xvfb", display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"]))
        time.sleep(1.5)
        procs.append(rig.spawn(rig.host_ns, [str(binary), "testapp", "--display", display, "--workload", "motion"],
                               env={"CMUX_RD_TESTAPP_LOG": str(scratch / "testapp-paint.log")}))
        time.sleep(1.5)
        for profile in profiles:
            try:
                row = measure_profile(rig, binary, commit, profile, scratch, display, args.passive_s, args.samples)
            except Exception as error:  # noqa: BLE001 - one profile's failure is that row's data
                row = {"schema": SCHEMA, "commit": commit, "profile": profile, "error": repr(error)}
            row["kernel"] = os.uname().release
            line = json.dumps(row)
            print(line, flush=True)
            with open(out / "results.jsonl", "a") as f:
                f.write(line + "\n")
            rows.append(row)
    finally:
        for proc in reversed(procs):
            stop(proc)
        rig.down()
        if args.keep_logs:
            keep = out / f"logs-{commit[:12]}"
            keep.mkdir(exist_ok=True)
            for log in scratch.glob("*.log*"):
                shutil.copy2(log, keep / log.name)
            for log in scratch.glob("timing-*.jsonl"):
                shutil.copy2(log, keep / log.name)
        shutil.rmtree(scratch, ignore_errors=True)
    return rows


def main(argv: list[str]) -> int:
    if argv[:1] == ["holds"]:
        # holds [SEED [SECONDS]]: print the wifi-away schedule (wifi-away-holds.json is seed 7, 120 s).
        seed = int(argv[1]) if len(argv) > 1 else WIFI_AWAY_SEED
        seconds = float(argv[2]) if len(argv) > 2 else WIFI_AWAY_SECONDS
        print(json.dumps(wifi_away_schedule(seed, seconds), indent=1))
        return 0
    if argv[:1] == ["table"]:
        if len(argv) != 2:
            raise SystemExit("usage: rd-netem-linux.py table RESULTS.jsonl")
        rows = read_rows(Path(argv[1]))
        sys.stdout.write(markdown_table(rows) + "\n" + stall_table(rows) + "\n" + lo_table(rows))
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--commit", action="append", default=[], help="full cmux commit to build and measure")
    ap.add_argument("--bin", action="append", default=[], metavar="COMMIT=PATH", help="a prebuilt cmux-rd")
    ap.add_argument("--profile", action="append", choices=sorted(PROFILES),
                    help="default: clean, jitter-5, jitter-15-burst, jitter-30-loss2, stall")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-url", default=REPO_URL)
    ap.add_argument("--host-arg", action="append", default=[], metavar="ARG",
                    help="pass ARG to every `cmux-rd host` (repeat per word: --host-arg=--encode-profile --host-arg=ultra)")
    ap.add_argument("--openh264", default="cisco", metavar="cisco|source|PATH",
                    help="the OpenH264 hosts encode with: Cisco's binary, as shipped hosts load it (default), "
                         f"the bench feature's source build ({SOURCE_BUILT}), or Cisco's library at PATH")
    ap.add_argument("--passive-s", type=int, default=20)
    ap.add_argument("--samples", type=int, default=60)
    ap.add_argument("--deps", action="store_true", help="apt-get the build and rig packages first")
    ap.add_argument("--keep-logs", action="store_true", help="keep host logs and timing records under --out")
    args = ap.parse_args(argv)
    if not args.commit and not args.bin:
        ap.error("give --commit or --bin")
    if any("=" not in b for b in args.bin):
        ap.error("--bin takes LABEL=PATH")
    for c in args.commit:
        if not re.fullmatch(r"[0-9a-f]{40}", c):
            ap.error(f"--commit {c}: a full 40-hex sha")
    profiles = args.profile or ["clean", "jitter-5", "jitter-15-burst", "jitter-30-loss2", "stall"]
    HOST_ARGS[:] = args.host_arg
    OPENH264[:] = [args.openh264]
    args.out.mkdir(parents=True, exist_ok=True)
    if args.deps:
        ensure_deps()
    preflight = run(priv(["modprobe", "sch_netem"]), check=False)
    if preflight.returncode:
        print(f"rd-netem-linux: modprobe sch_netem failed: {preflight.stderr.strip()} (the kernel needs sch_netem; "
              "cmuxterm-hq docs/handbook/netem-route-without-host-module.md)", file=sys.stderr)
        return 3
    work = Path(tempfile.mkdtemp(prefix="rd-netem-build-"))
    rows = []
    try:
        targets = [(label, Path(path)) for label, path in (b.split("=", 1) for b in args.bin)]
        for label, path in targets:
            rows += measure_binary(path, label, profiles, args.out, args)
        for commit in args.commit:
            try:
                binary = build(commit, work, args.repo_url)
            except (subprocess.CalledProcessError, SystemExit, OSError) as error:
                for profile in profiles:
                    row = {"schema": SCHEMA, "commit": commit, "profile": profile, "error": f"build: {error!r}"}
                    print(json.dumps(row), flush=True)
                    with open(args.out / "results.jsonl", "a") as f:
                        f.write(json.dumps(row) + "\n")
                    rows.append(row)
                continue
            rows += measure_binary(binary, commit, profiles, args.out, args)
            mine = [r for r in rows if r["commit"] == commit]
            print(markdown_table(mine) + "\n" + stall_table(mine) + "\n" + lo_table(mine), file=sys.stderr, flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    table = markdown_table(rows) + "\n" + stall_table(rows) + "\n" + lo_table(rows)
    (args.out / "results.md").write_text(table)
    print(table)
    return 0 if rows and not any(r.get("error") for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
