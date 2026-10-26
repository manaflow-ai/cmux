#!/usr/bin/env python3
"""Cold scrollback against the macOS memory compressor (p07-memory-112; gates tasks 040 and 041).

bench_memory.py --cold-scrollback N runs the phase below; this module holds its parts, each testable off macOS.

The question: would cmux's own deflate codec for cold scrollback (task 040) keep at least 2x fewer bytes than the
kernel's compressor (WKdm/LZ4 on Apple silicon) keeps for the same idle terminals? Chrome answers it for its own
state on macOS by not compressing in user space (it relies on the kernel compressor); cmux builds the codec only if
the measured gain is >= 2x.

The launch uses the holder terminal model. A terminal host runs its own VT terminal with a second copy of the
scrollback (HostLaunch::host_scrollback); under the hosts model the run decides `not measured`.

Phase:
  1. a base sample: `footprint -j` of the app and every daemon-side process (tui-daemon, terminal-host,
     terminal-holder), and `vm_stat`;
  2. N workspaces, one terminal each, are opened and hidden; the control sample is taken with every scrollback
     empty, so the Surface, active screen, threads and buffers of N terminals are not counted as scrollback;
  3. every terminal prints --cold-scrollback-mb MiB of seeded log-like text (``emit``: timestamps, SGR colors,
     paths, hashes), more than the 10 MB `scrollback-limit` holds; the bench waits for each end marker (daemon
     `wait-for`);
  4. a sample at each --cold-idle minute (0, 10, 30), touching nothing in between;
  5. real memory pressure (`memory_pressure -p 5 -y 30` allocates until 5% of RAM is free, waits, exits) until the
     compressor holds most of the daemon's growth, then a sample after the tool has exited and freed its pages. An
     idle Mac with free RAM compresses almost nothing, so only this sample measures the compressor on scrollback;
  6. last, the daemon's `read-scrollback` of --cold-codec-samples terminals (styled rows, the content 040 would
     serialize) is deflated (zlib level 6, flate2's default): the codec's bytes per terminal.

Per opened terminal, from the daemon's footprint over the control: dirty and compressed growth; of it, the
scrollback (the growth up to the scrollback-limit; the rest is allocator slack that stays resident under either
choice, reported as `other`); the kernel's ratio (vm_stat stored/occupied over the control when this run's
compressed pages are most of what the compressor took in: the `delta` source). The kernel keeps scrollback / ratio;
gain = that / the codec's deflated bytes, both for the same scrollback. Go for 040/041 only if gain >= 2 on the
pressed sample, with a `delta` ratio and most growth compressed. A terminal error, the hosts model, a sample without
daemon category rows, a daemon restart, or growth under half the scrollback-limit decides `not measured`.

`python3 cold_scrollback.py emit BYTES SEED` is the text one terminal prints.
"""
from __future__ import annotations

import json
import os
import random
import re
import shlex
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import footprint_json  # noqa: E402

GO_GAIN = 2.0
# flate2's default compression level, the deflate already in cmux-tui's dependencies (task 040's codec).
DEFLATE_LEVEL = 6
DAEMON_KINDS = ("tui-daemon", "terminal-host", "terminal-holder")
# The process whose VT terminals (Surface's ghostty-vt Terminal) keep the scrollback the gate measures. Holders keep a
# PTY and a byte ring; hosts keep a second VT copy, so the run then decides `not measured`.
SCROLLBACK_KIND = "tui-daemon"
HOLDER_KINDS = ("terminal-host", "terminal-holder")
# Each terminal's scrollback cap (Ghostty `scrollback-limit`, cmux-tui-core DEFAULT_SCROLLBACK_LIMIT_BYTES).
SCROLLBACK_LIMIT_BYTES = 10_000_000
# read-scrollback's `count` is a u16.
READ_ROWS = 10_000
# Our compressed bytes must be at least this share of what the compressor gained for its ratio delta to be ours.
OWN_RATIO_SHARE = 0.5
# A sample counts only when the daemon grew by at least this share of the scrollback-limit per terminal.
MIN_SCROLLBACK_SHARE = 0.5
# The pressed sample must have at least this share of the daemon's growth in the compressor.
PRESSED_SHARE = 0.5
# The most pressure runs to get there.
PRESSURE_ROUNDS = 3

WORDS = ("compile", "link", "fetch", "resolve", "index", "render", "agent", "tool", "result", "warning", "cache",
         "module", "request", "response", "token", "session", "worker", "build", "test", "pass", "fail", "retry")
EXTS = (".rs", ".swift", ".ts", ".py", ".json", ".md", ".toml")
LEVELS = (("INFO", 32), ("DEBUG", 36), ("WARN", 33), ("ERROR", 31))


def emit_lines(seed: int):
    """Endless log lines, each under 80 columns, from `seed`: what a build or an agent leaves in scrollback."""
    rng = random.Random(seed)
    clock = 1_700_000_000.0 + seed
    while True:
        clock += rng.expovariate(20)
        level, color = LEVELS[min(3, int(rng.expovariate(1.5)))]
        path = "/".join(rng.choice(WORDS) for _ in range(rng.randint(1, 3))) + rng.choice(EXTS)
        body = " ".join(rng.choice(WORDS) for _ in range(rng.randint(1, 4)))
        stamp = f"{int(clock) % 86400 // 3600:02}:{int(clock) % 3600 // 60:02}:{clock % 60:06.3f}"
        tail = rng.choice((f"{rng.getrandbits(32):08x}", f"{rng.randint(0, 99999)} ms", f"line {rng.randint(1, 2000)}"))
        yield f"{stamp} \x1b[{color}m{level:<5}\x1b[0m {path[:26]} {body[:22]} {tail}\n"


def emit(nbytes: int, seed: int, out) -> int:
    """Writes about `nbytes` bytes of ``emit_lines`` to the binary stream `out`; returns the bytes written."""
    written = 0
    chunk = []
    for line in emit_lines(seed):
        data = line.encode()
        chunk.append(data)
        written += len(data)
        if written >= nbytes or len(chunk) >= 2048:
            out.write(b"".join(chunk))
            chunk = []
        if written >= nbytes:
            break
    out.flush()
    return written


def done_marker(index: int) -> str:
    return f"COLD-DONE-{index}"


def fill_command(python: str, nbytes: int, index: int) -> str:
    """The shell line a terminal runs. printf builds the marker, so the echoed command line never matches it."""
    script = os.path.abspath(__file__)
    return (f"{shlex.quote(python)} -I {shlex.quote(script)} emit {nbytes} {index}; "
            f"printf 'COLD-DONE-%d\\n' {index}\r")


# Parsers: each takes a tool's output and returns plain data.


def parse_footprint(document) -> dict[int, dict]:
    """{pid: {"dirty" (resident), "compressed", "footprint", "rows", "categories"}} from `footprint -j` JSON (the
    parser memory-report.py shares, footprint_json.py)."""
    return footprint_json.parse(document)


VM_STAT_PAGE = re.compile(r"page size of (\d+) bytes")
VM_STAT_ROW = re.compile(r"^\"?([^:\"]+)\"?:\s+(\d+)\.?\s*$", re.M)


def parse_vm_stat(text: str) -> dict:
    """{"page_size", "stored_pages", "occupied_pages"} from vm_stat (compressor rows None when missing)."""
    page = VM_STAT_PAGE.search(text)
    rows = {name.strip().lower(): int(value) for name, value in VM_STAT_ROW.findall(text)}
    return {"page_size": int(page.group(1)) if page else 16384,
            "stored_pages": rows.get("pages stored in compressor"),
            "occupied_pages": rows.get("pages occupied by compressor")}


def serialize_rows(rows: list[dict]) -> bytes:
    """read-scrollback rows as the codec would keep them: each run's style then its text, one row per line."""
    out = []
    for row in rows:
        runs = []
        for run in row.get("runs") or []:
            style = f"{run.get('fg') or ''},{run.get('bg') or ''},{run.get('attrs') or 0},{run.get('underline') or ''}"
            runs.append(f"{style}\x1f{run.get('text') or ''}")
        out.append("\x1e".join(runs))
    return "\n".join(out).encode()


def codec_size(rows: list[dict]) -> dict:
    raw = serialize_rows(rows)
    return {"rows": len(rows), "raw_bytes": len(raw), "deflate_bytes": len(zlib.compress(raw, DEFLATE_LEVEL))}


# Arithmetic of the measurement.


def group_totals(columns: dict[int, dict], kinds: dict[int, str]) -> dict[str, dict]:
    """{kind: {"processes", "dirty", "compressed", "footprint"}} over the pids of `kinds` (a pid footprint did not
    return still counts as a process, with no bytes)."""
    totals: dict[str, dict] = {}
    for pid, kind in kinds.items():
        total = totals.setdefault(kind, {"processes": 0, "dirty": 0, "compressed": 0, "footprint": 0})
        total["processes"] += 1
        entry = columns.get(pid)
        if entry is None:
            continue
        for key in ("dirty", "compressed", "footprint"):
            total[key] += entry[key]
    return totals


def kind_sum(totals: dict[str, dict], kinds) -> dict:
    side = {"dirty": 0, "compressed": 0, "footprint": 0}
    for kind in kinds:
        for key in side:
            side[key] += totals.get(kind, {}).get(key, 0)
    return side


def per_terminal(base: dict, now: dict, kinds, key: str, n: int) -> float:
    return (kind_sum(now, kinds)[key] - kind_sum(base, kinds)[key]) / n


def kernel_ratio(base_vm: dict, vm: dict, own_compressed: int) -> tuple[float | None, str]:
    """(stored / occupied bytes of the compressor, its source). `delta` when this run's compressed bytes are most of
    what the compressor took in since the base, else `system` (the whole compressor), else (None, `none`)."""
    page = vm.get("page_size") or 16384
    stored, occupied = vm.get("stored_pages"), vm.get("occupied_pages")
    if stored is None or occupied is None:
        return None, "none"
    if base_vm.get("stored_pages") is not None and base_vm.get("occupied_pages") is not None:
        gained = (stored - base_vm["stored_pages"]) * page
        held = (occupied - base_vm["occupied_pages"]) * page
        if gained > 0 and held > 0 and own_compressed >= OWN_RATIO_SHARE * gained:
            return gained / held, "delta"
    if stored > 0 and occupied > 0:
        return stored / occupied, "system"
    return None, "none"


def sample_valid(columns: dict[int, dict], kinds: dict[int, str]) -> tuple[bool, list[int]]:
    """(valid, daemon pids): a sample counts only when footprint returned every daemon pid with category rows."""
    daemons = sorted(pid for pid, kind in kinds.items() if kind == SCROLLBACK_KIND)
    valid = bool(daemons) and all((columns.get(pid) or {}).get("rows", 0) > 0 for pid in daemons)
    return valid, daemons


def host_model_of(base: dict, control: dict) -> str:
    """`hosts` when opening the terminals added terminal hosts (each runs its own VT terminal holding a second copy
    of the scrollback, HostLaunch::host_scrollback), `holder` when a holder runs and no host was added."""
    def processes(sample: dict, kind: str) -> int:
        return sample["kinds"].get(kind, {}).get("processes", 0)

    if processes(control, "terminal-host") > processes(base, "terminal-host"):
        return "hosts"
    return "holder" if processes(control, "terminal-holder") else "unknown"


def idle_point(label: str, minutes: float | None, control: dict, now: dict, terminals: int) -> dict:
    """One sample over the control (every terminal open, scrollback empty), per opened terminal: the daemon's dirty
    and compressed growth; the scrollback share of it (the growth up to the scrollback-limit; the rest, allocator
    slack from parsing, stays resident under either choice and is reported apart); the kernel's ratio; what the
    kernel holds now, and what it holds for the scrollback once every page of it is compressed. The footprint the
    holders and the app add per terminal is reported too."""
    old, new, n = control["kinds"], now["kinds"], max(1, terminals)
    dirty = per_terminal(old, new, [SCROLLBACK_KIND], "dirty", n)
    compressed = per_terminal(old, new, [SCROLLBACK_KIND], "compressed", n)
    growth = dirty + compressed
    scrollback = min(max(0.0, growth), SCROLLBACK_LIMIT_BYTES)
    own = per_terminal(old, new, DAEMON_KINDS + ("app",), "compressed", n) * n
    ratio, source = kernel_ratio(control["vm"], now["vm"], int(own))
    valid = bool(control["valid"] and now["valid"] and control["daemon_pids"] == now["daemon_pids"])
    return {"label": label, "idle_min": minutes, "terminals": terminals, "valid": valid,
            "dirty_bytes": round(dirty), "compressed_bytes": round(compressed), "growth_bytes": round(growth),
            "scrollback_bytes": round(scrollback), "other_bytes": round(growth - scrollback),
            "compressed_share": round(compressed / growth, 3) if growth > 0 else 0.0,
            "kernel_ratio": round(ratio, 2) if ratio else None, "kernel_ratio_source": source,
            "kernel_now_bytes": round(dirty + compressed / ratio) if ratio else None,
            "kernel_cold_bytes": round(scrollback / ratio) if ratio else None,
            "holder_footprint_bytes": round(per_terminal(old, new, HOLDER_KINDS, "footprint", n)),
            "app_footprint_bytes": round(per_terminal(old, new, ["app"], "footprint", n)),
            "kinds": new}


def _not_measured(decision: dict, why: str) -> dict:
    decision.update({"gain": None, "go": False, "measured": False,
                     "reason": f"no-go: not measured ({why}), 040/041 stay off"})
    return decision


def decide(phase: dict) -> dict:
    """Go for 040/041 only when the kernel keeps >= GO_GAIN x the codec's bytes for the same scrollback, on the
    sample under pressure (else the last idle one). A run with any doubt is `not measured`, never a gain."""
    deflated = [c["deflate_bytes"] for c in phase.get("codec") or [] if c.get("rows")]
    codec = round(sum(deflated) / len(deflated)) if deflated else None
    points = phase.get("points") or []
    point = phase.get("pressed") or (points[-1] if points else {})
    kernel = point.get("kernel_cold_bytes")
    decision = {"codec_bytes": codec, "codec_samples": len(deflated), "kernel_cold_bytes": kernel,
                "sample": point.get("label"), "go_gain": GO_GAIN, "measured": True}
    errors = phase.get("errors") or []
    floor = MIN_SCROLLBACK_SHARE * SCROLLBACK_LIMIT_BYTES
    if errors:
        return _not_measured(decision, f"{len(errors)} terminal errors, first: {errors[0]}")
    if phase.get("terminal_host_model") == "hosts":
        return _not_measured(decision, "terminal hosts keep a second VT copy of each scrollback; run the holder model")
    if not (phase.get("control") or {}).get("valid") or not point.get("valid"):
        return _not_measured(decision, "footprint gave no daemon category rows, or the daemon changed")
    if point.get("growth_bytes", 0) < floor:
        return _not_measured(decision, f"the daemon grew {point.get('growth_bytes', 0)} bytes per terminal, under "
                                       f"{floor:.0f} of the scrollback filled")
    if codec is None:
        return _not_measured(decision, "no read-back to deflate")
    if kernel is None:
        return _not_measured(decision, "no kernel compressor ratio")
    if point.get("kernel_ratio_source") != "delta" or point.get("compressed_share", 0) < PRESSED_SHARE:
        decision.update({"gain": None, "go": False,
                         "reason": f"no-go: the compressor did not take the cold pages (compressed share "
                                   f"{point.get('compressed_share')}, ratio source {point.get('kernel_ratio_source')}), "
                                   f"040/041 stay off"})
        return decision
    gain = kernel / codec if codec else float("inf")
    decision["gain"] = round(gain, 2)
    decision["go"] = gain >= GO_GAIN
    decision["reason"] = (f"{'go' if decision['go'] else 'no-go'}: deflate keeps {codec} bytes per cold terminal, the "
                          f"kernel compressor {kernel} for the same scrollback ({gain:.2f}x, threshold {GO_GAIN:g}x)")
    return decision


def mib(value) -> str:
    return "-" if value is None else f"{value / 1048576:.2f}"


def markdown(phase: dict) -> str:
    """The rows cold-scrollback-DESIGN.md records."""
    lines = [f"Terminal host model: {phase.get('terminal_host_model')}. Terminals: {phase.get('terminals')} opened, "
             f"{phase.get('finished')} finished, {len(phase.get('errors') or [])} errors. Daemon footprint per "
             f"terminal before printing: {mib(phase.get('terminal_overhead_bytes'))} MiB.", "",
             "| sample | valid | dirty MiB | compressed MiB | scrollback MiB | other MiB | kernel ratio (source) "
             "| kernel now MiB | kernel scrollback MiB | holders MiB | app MiB |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for p in list(phase.get("points") or []) + ([phase["pressed"]] if phase.get("pressed") else []):
        ratio = "-" if p["kernel_ratio"] is None else f"{p['kernel_ratio']:.2f} ({p['kernel_ratio_source']})"
        sample = p["label"] if p["idle_min"] is None else f"{p['idle_min']:g} min idle"
        lines.append(f"| {sample} | {'yes' if p['valid'] else 'no'} | {mib(p['dirty_bytes'])} | "
                     f"{mib(p['compressed_bytes'])} | {mib(p['scrollback_bytes'])} | {mib(p['other_bytes'])} | {ratio} "
                     f"| {mib(p['kernel_now_bytes'])} | {mib(p['kernel_cold_bytes'])} | "
                     f"{mib(p['holder_footprint_bytes'])} | {mib(p['app_footprint_bytes'])} |")
    d = phase.get("decision") or {}
    lines.append("")
    lines.append(f"Deflate per cold terminal: {mib(d.get('codec_bytes'))} MiB over {d.get('codec_samples', 0)} "
                 f"terminals. Decision: {d.get('reason', 'not run')}.")
    return "\n".join(lines)


# The phase. Every effect is injected: `env` has app (App), daemon(cmd, params, timeout) -> reply dict,
# columns() -> ({pid: footprint columns}, {pid: kind}), vm_stat() -> text, open_workspace() -> id or None,
# terminal_surface(workspace) -> int or None, press(free_pct, hold_s) -> {"ok", "error"?} (real kernel pressure; returns
# once the pressure tool has exited and freed its pages), sleep(s), monotonic(), say(text).


def take(env, label: str) -> dict:
    columns, kinds = env.columns()
    valid, daemons = sample_valid(columns, kinds)
    return {"label": label, "valid": valid, "daemon_pids": daemons, "kinds": group_totals(columns, kinds),
            "vm": parse_vm_stat(env.vm_stat())}


def open_terminals(env, count: int) -> tuple[list[tuple[int, int]], list[str]]:
    """Opens `count` workspaces; returns ([(index, terminal surface)], errors)."""
    errors: list[str] = []
    surfaces: list[tuple[int, int]] = []
    for index in range(count):
        workspace = env.open_workspace()
        surface = env.terminal_surface(workspace) if workspace else None
        if surface is None:
            errors.append(f"terminal {index}: no terminal in workspace {workspace}")
            continue
        surfaces.append((index, surface))
    return surfaces, errors


def fill(env, surfaces: list[tuple[int, int]], nbytes: int, wait_s: float) -> tuple[list[int], list[str]]:
    """Has each terminal print `nbytes`, then waits for each end marker; returns (surfaces finished, errors)."""
    errors: list[str] = []
    sent: list[tuple[int, int]] = []
    for index, surface in surfaces:
        reply = env.daemon("send", {"surface": surface, "text": fill_command(env.python, nbytes, index)}, 30)
        if reply.get("ok"):
            sent.append((index, surface))
        else:
            errors.append(f"terminal {index}: send: {reply.get('error')}")
    done: list[int] = []
    deadline = env.monotonic() + wait_s
    for index, surface in sent:
        while True:
            left = deadline - env.monotonic()
            if left <= 0:
                errors.append(f"terminal {index}: no {done_marker(index)} within {wait_s:.0f} s")
                break
            reply = env.daemon("wait-for", {"surface": surface, "pattern": f"(?m)^{done_marker(index)}$",
                                            "timeout_ms": int(min(left, 60) * 1000)}, min(left, 60) + 10)
            if reply.get("ok"):
                done.append(surface)
                break
            if "timeout" not in json.dumps(reply.get("error")).lower():
                errors.append(f"terminal {index}: wait-for: {reply.get('error')}")
                break
    return done, errors


def read_rows(env, surface: int) -> list[dict]:
    first = env.daemon("read-scrollback", {"surface": surface, "start": 0, "count": 0}, 60)
    total = int(((first.get("data") or {}).get("total")) or 0)
    rows: list[dict] = []
    start = 0
    while start < total:
        reply = env.daemon("read-scrollback", {"surface": surface, "start": start, "count": READ_ROWS}, 120)
        page = (reply.get("data") or {}).get("rows") or []
        if not reply.get("ok") or not page:
            break
        rows.extend(page)
        start += len(page)
    return rows


def say_point(env, point: dict):
    env.say(f"COLD-SCROLLBACK sample={point['label']} valid={str(point['valid']).lower()} "
            f"terminals={point['terminals']} dirty_bytes={point['dirty_bytes']} "
            f"compressed_bytes={point['compressed_bytes']} scrollback_bytes={point['scrollback_bytes']} "
            f"other_bytes={point['other_bytes']} kernel_ratio={point['kernel_ratio']} "
            f"ratio_source={point['kernel_ratio_source']} kernel_now_bytes={point['kernel_now_bytes']} "
            f"kernel_cold_bytes={point['kernel_cold_bytes']} holder_bytes={point['holder_footprint_bytes']} "
            f"app_bytes={point['app_footprint_bytes']}")


def press(env, control: dict, terminals: int, free_pct: int, hold_s: float) -> tuple[dict | None, list[dict]]:
    """Real kernel pressure until the compressor holds most of the daemon's growth, at most PRESSURE_ROUNDS times.
    Each sample follows the pressure tool's exit, so its own pages are gone from the vm_stat delta."""
    point, runs = None, []
    for attempt in range(PRESSURE_ROUNDS):
        ran = env.press(free_pct, hold_s)
        runs.append(ran)
        if not ran.get("ok"):
            env.say(f"COLD-SCROLLBACK pressure to {free_pct}% free did not run: {ran.get('error')}")
            break
        now = take(env, f"cold-pressed-{free_pct}pct-{attempt + 1}")
        point = idle_point(now["label"], None, control, now, terminals)
        say_point(env, point)
        if point["compressed_share"] >= PRESSED_SHARE:
            break
    return point, runs


def cold_scrollback_phase(env, count: int, nbytes: int, idle_minutes: list[float], codec_samples: int,
                          wait_s: float = 1800, pressure: int = 5, pressure_hold_s: float = 30) -> dict:
    env.app.run("workspace.selectFirst")
    base = take(env, "cold-base")
    surfaces, errors = open_terminals(env, count)
    env.app.run("workspace.selectFirst")
    # The control: every terminal open and hidden with an empty scrollback; growth past it is what printing added.
    control = take(env, "cold-control")
    opened = len(surfaces)
    phase = {"requested": count, "terminals": opened, "bytes_printed_each": nbytes,
             "scrollback_limit_bytes": SCROLLBACK_LIMIT_BYTES, "idle_min": idle_minutes, "errors": errors,
             "terminal_host_model": host_model_of(base, control), "base": base, "control": control,
             "terminal_overhead_bytes": round(per_terminal(base["kinds"], control["kinds"], [SCROLLBACK_KIND],
                                                           "footprint", max(1, opened))),
             "pressure": pressure, "points": []}
    done, fill_errors = fill(env, surfaces, nbytes, wait_s)
    errors.extend(fill_errors)
    phase["finished"] = len(done)
    cold_at = env.monotonic()
    for minutes in idle_minutes:
        env.sleep(max(0.0, cold_at + minutes * 60 - env.monotonic()))
        now = take(env, f"cold-{minutes:g}min")
        point = idle_point(now["label"], minutes, control, now, opened)
        phase["points"].append(point)
        say_point(env, point)
    if pressure > 0 and opened:
        phase["pressed"], phase["pressure_runs"] = press(env, control, opened, pressure, pressure_hold_s)
    # Last: reading the rows pages them back in.
    phase["codec"] = [dict(codec_size(read_rows(env, surface)), surface=surface) for surface in done[:codec_samples]]
    phase["decision"] = decide(phase)
    d = phase["decision"]
    env.say(f"COLD-SCROLLBACK-DECISION go={str(d['go']).lower()} measured={str(d['measured']).lower()} "
            f"gain={d['gain']} codec_bytes={d['codec_bytes']} kernel_cold_bytes={d['kernel_cold_bytes']} "
            f"host_model={phase['terminal_host_model']} reason={d['reason']!r}")
    env.say(markdown(phase))
    return phase


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "emit":
        emit(int(sys.argv[2]), int(sys.argv[3]), sys.stdout.buffer)
    else:
        raise SystemExit("usage: cold_scrollback.py emit BYTES SEED (bench_memory.py --cold-scrollback runs the phase)")
