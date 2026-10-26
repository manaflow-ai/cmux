#!/usr/bin/env python3
"""Cold scrollback against the macOS memory compressor (p07-memory-112; gates tasks 040 and 041).

bench_memory.py --cold-scrollback N runs the phase below; this module holds its parts, each testable off macOS.

The question: would cmux's own deflate codec for cold scrollback (task 040) keep at least 2x fewer bytes than the
kernel's compressor (WKdm/LZ4 on Apple silicon) keeps for the same idle terminals? Chrome answers it for its own
state on macOS by not compressing in user space (it relies on the kernel compressor); cmux builds the codec only if
the measured gain is >= 2x.

Phase:
  1. a base sample: `footprint -j` of the app and every daemon-side process (tui-daemon, terminal-host,
     terminal-holder), and `vm_stat`;
  2. N workspaces, one terminal each, every terminal prints --cold-scrollback-mb MiB of seeded log-like text
     (``emit``: timestamps, SGR colors, paths, hashes), more than the 10 MB `scrollback-limit` holds, so each
     terminal ends with a full scrollback; the bench waits for each terminal's end marker (daemon `wait-for`);
  3. the first workspace is shown again (every cold terminal hidden, no viewer, no output), and the same sample is
     taken at each --cold-idle minute (0, 10, 30) after that, touching nothing in between;
  4. after the last sample, the daemon's `read-scrollback` of --cold-codec-samples terminals (styled rows, the
     content 040 would serialize) is deflated (zlib level 6, flate2's default) - the codec's bytes per terminal.

Per cold terminal, from the daemon's footprint over the base (the daemon keeps the VT pages; terminal hosts and
holders keep a PTY and a byte ring, reported apart): resident dirty bytes, compressed bytes (what the
kernel compressor holds, counted at their uncompressed size, as footprint counts them), and the kernel's ratio (the
compressor's stored/occupied pages from vm_stat over the base when this run's pages are most of what was added,
else the whole compressor's ratio). The kernel keeps at best (dirty + compressed) / ratio for a terminal once all of
it is cold and compressed; gain = that / the codec's deflated bytes. Go for 040/041 only if gain >= 2.

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

GO_GAIN = 2.0
# flate2's default compression level, the deflate already in cmux-tui's dependencies (task 040's codec).
DEFLATE_LEVEL = 6
DAEMON_KINDS = ("tui-daemon", "terminal-host", "terminal-holder")
# The process that keeps the terminals' VT pages (Surface's ghostty-vt Terminal); hosts and holders keep a PTY and a
# byte ring only, so their bytes are reported apart and stay out of the gate.
SCROLLBACK_KIND = "tui-daemon"
HOLDER_KINDS = ("terminal-host", "terminal-holder")
# Each terminal's scrollback cap (Ghostty `scrollback-limit`, cmux-tui-core DEFAULT_SCROLLBACK_LIMIT_BYTES).
SCROLLBACK_LIMIT_BYTES = 10_000_000
# read-scrollback's `count` is a u16.
READ_ROWS = 10_000
# Our compressed bytes must be at least this share of what the compressor gained for its ratio delta to be ours.
OWN_RATIO_SHARE = 0.5

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


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _processes(node, found: list):
    if isinstance(node, dict):
        if _number(node.get("pid")):
            found.append(node)
            return
        for value in node.values():
            _processes(value, found)
    elif isinstance(node, list):
        for value in node:
            _processes(value, found)


def _category_counts(proc: dict) -> list[dict]:
    """The per-category count dicts of one footprint process object (a map of name to counts or a list)."""
    for value in proc.values():
        if isinstance(value, dict) and value and all(isinstance(v, dict) for v in value.values()):
            rows = [entry for name, entry in value.items() if str(name).upper() != "TOTAL"]
        elif isinstance(value, list) and value and all(isinstance(v, dict) for v in value):
            rows = [entry for entry in value if str(entry.get("category", entry.get("name", ""))).upper() != "TOTAL"]
        else:
            continue
        rows = [{str(k).lower(): v for k, v in entry.items() if _number(v)} for entry in rows]
        rows = [row for row in rows if "dirty" in row]
        if rows:
            return rows
    return []


def parse_footprint(document) -> dict[int, dict]:
    """{pid: {"dirty", "compressed", "footprint"}} from `footprint -j` JSON. `dirty` is resident dirty bytes.

    footprint's `dirty` column may or may not include the compressed (swapped) bytes it also lists; phys_footprint
    is resident dirty plus compressed, so whichever reading matches the process's footprint is taken."""
    found: list[dict] = []
    _processes(document, found)
    result = {}
    for proc in found:
        rows = _category_counts(proc)
        dirty = sum(row["dirty"] for row in rows)
        compressed = sum(v for row in rows for k, v in row.items() if "swap" in k or "compress" in k)
        totals = sorted((k for k, v in proc.items() if "footprint" in k.lower() and "peak" not in k.lower()
                         and _number(v)), key=len)
        footprint = int(proc[totals[0]]) if totals else None
        if footprint is not None and compressed and abs(dirty - footprint) < abs(dirty + compressed - footprint):
            dirty -= compressed
        result[int(proc["pid"])] = {"dirty": int(max(0, dirty)), "compressed": int(compressed),
                                    "footprint": footprint if footprint is not None else int(dirty + compressed)}
    return result


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
    """{kind: {"processes", "dirty", "compressed", "footprint"}} over the pids of `columns`."""
    totals: dict[str, dict] = {}
    for pid, entry in columns.items():
        kind = kinds.get(pid)
        if kind is None:
            continue
        total = totals.setdefault(kind, {"processes": 0, "dirty": 0, "compressed": 0, "footprint": 0})
        total["processes"] += 1
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


def idle_point(label: str, minutes: float, base: dict, now: dict, terminals: int) -> dict:
    """One idle sample over the base: per cold terminal, the daemon's dirty and compressed bytes, the kernel's ratio,
    what the kernel holds now and what it would hold with every cold byte compressed; the footprint the terminal hosts
    or holders and the app add per terminal too."""
    old, new, n = base["kinds"], now["kinds"], max(1, terminals)
    dirty = per_terminal(old, new, [SCROLLBACK_KIND], "dirty", n)
    compressed = per_terminal(old, new, [SCROLLBACK_KIND], "compressed", n)
    own = per_terminal(old, new, DAEMON_KINDS + ("app",), "compressed", n) * n
    ratio, source = kernel_ratio(base["vm"], now["vm"], int(own))
    return {"label": label, "idle_min": minutes, "terminals": terminals,
            "dirty_bytes": round(dirty), "compressed_bytes": round(compressed),
            "kernel_ratio": round(ratio, 2) if ratio else None, "kernel_ratio_source": source,
            "kernel_now_bytes": round(dirty + compressed / ratio) if ratio else None,
            "kernel_cold_bytes": round((dirty + compressed) / ratio) if ratio else None,
            "holder_footprint_bytes": round(per_terminal(old, new, HOLDER_KINDS, "footprint", n)),
            "app_footprint_bytes": round(per_terminal(old, new, ["app"], "footprint", n)),
            "kinds": new}


def decide(points: list[dict], codecs: list[dict]) -> dict:
    """Go for 040/041 only when the kernel's best case at the last idle point is >= GO_GAIN x the codec's bytes."""
    deflated = [c["deflate_bytes"] for c in codecs if c.get("rows")]
    codec = round(sum(deflated) / len(deflated)) if deflated else None
    last = points[-1] if points else {}
    kernel = last.get("kernel_cold_bytes")
    decision = {"codec_bytes": codec, "codec_samples": len(deflated), "kernel_cold_bytes": kernel,
                "idle_min": last.get("idle_min"), "go_gain": GO_GAIN}
    if codec is None or kernel is None:
        missing = "the codec's bytes" if codec is None else "the kernel compressor's ratio"
        decision.update({"gain": None, "go": False, "reason": f"no-go: {missing} not measured, 040/041 stay off"})
        return decision
    gain = kernel / codec if codec else float("inf")
    decision["gain"] = round(gain, 2)
    decision["go"] = gain >= GO_GAIN
    decision["reason"] = (f"{'go' if decision['go'] else 'no-go'}: deflate keeps {codec} bytes per cold terminal, the "
                          f"kernel compressor at best {kernel} ({gain:.2f}x, threshold {GO_GAIN:g}x)")
    return decision


def mib(value) -> str:
    return "-" if value is None else f"{value / 1048576:.2f}"


def markdown(phase: dict) -> str:
    """The rows memory-DESIGN.md section 11 records."""
    lines = ["| idle min | dirty MiB | compressed MiB | kernel ratio (source) | kernel now MiB | kernel all-cold MiB "
             "| hosts MiB | app MiB |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for p in phase.get("points", []):
        ratio = "-" if p["kernel_ratio"] is None else f"{p['kernel_ratio']:.2f} ({p['kernel_ratio_source']})"
        lines.append(f"| {p['idle_min']:g} | {mib(p['dirty_bytes'])} | {mib(p['compressed_bytes'])} | {ratio} | "
                     f"{mib(p['kernel_now_bytes'])} | {mib(p['kernel_cold_bytes'])} | "
                     f"{mib(p['holder_footprint_bytes'])} | {mib(p['app_footprint_bytes'])} |")
    d = phase.get("decision", {})
    lines.append("")
    lines.append(f"Deflate per cold terminal: {mib(d.get('codec_bytes'))} MiB over {d.get('codec_samples', 0)} "
                 f"terminals. Decision: {d.get('reason', 'not run')}.")
    return "\n".join(lines)


# The phase. Every effect is injected: `env` has app (App), daemon(cmd, params, timeout) -> reply dict,
# columns() -> ({pid: footprint columns}, {pid: kind}), vm_stat() -> text, open_workspace() -> id or None,
# terminal_surface(workspace) -> int or None, sleep(s), monotonic(), say(text).


def take(env, label: str) -> dict:
    columns, kinds = env.columns()
    return {"label": label, "kinds": group_totals(columns, kinds), "vm": parse_vm_stat(env.vm_stat())}


def fill(env, count: int, nbytes: int, wait_s: float) -> tuple[list[int], list[str]]:
    """Opens `count` workspaces and has each one's terminal print `nbytes`; returns (surfaces filled, errors)."""
    errors: list[str] = []
    surfaces: list[tuple[int, int]] = []
    for index in range(count):
        workspace = env.open_workspace()
        surface = env.terminal_surface(workspace) if workspace else None
        if surface is None:
            errors.append(f"terminal {index}: no terminal in workspace {workspace}")
            continue
        sent = env.daemon("send", {"surface": surface, "text": fill_command(env.python, nbytes, index)}, 30)
        if not sent.get("ok"):
            errors.append(f"terminal {index}: send: {sent.get('error')}")
            continue
        surfaces.append((index, surface))
    done: list[int] = []
    deadline = env.monotonic() + wait_s
    for index, surface in surfaces:
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


def cold_scrollback_phase(env, count: int, nbytes: int, idle_minutes: list[float], codec_samples: int,
                          wait_s: float = 1800) -> dict:
    env.app.run("workspace.selectFirst")
    base = take(env, "cold-base")
    surfaces, errors = fill(env, count, nbytes, wait_s)
    env.app.run("workspace.selectFirst")
    cold_at = env.monotonic()
    phase = {"requested": count, "terminals": len(surfaces), "bytes_printed_each": nbytes,
             "scrollback_limit_bytes": SCROLLBACK_LIMIT_BYTES, "idle_min": idle_minutes, "errors": errors,
             "base": base, "points": []}
    for minutes in idle_minutes:
        env.sleep(max(0.0, cold_at + minutes * 60 - env.monotonic()))
        now = take(env, f"cold-{minutes:g}min")
        point = idle_point(now["label"], minutes, base, now, len(surfaces))
        phase["points"].append(point)
        env.say(f"COLD-SCROLLBACK idle_min={minutes:g} terminals={len(surfaces)} dirty_bytes={point['dirty_bytes']} "
                f"compressed_bytes={point['compressed_bytes']} kernel_ratio={point['kernel_ratio']} "
                f"ratio_source={point['kernel_ratio_source']} kernel_now_bytes={point['kernel_now_bytes']} "
                f"kernel_cold_bytes={point['kernel_cold_bytes']} holder_bytes={point['holder_footprint_bytes']} "
                f"app_bytes={point['app_footprint_bytes']}")
    # Last: reading the rows pages them back in.
    phase["codec"] = [dict(codec_size(read_rows(env, surface)), surface=surface)
                      for surface in surfaces[:codec_samples]]
    phase["decision"] = decide(phase["points"], phase["codec"])
    d = phase["decision"]
    env.say(f"COLD-SCROLLBACK-DECISION go={str(d['go']).lower()} gain={d['gain']} codec_bytes={d['codec_bytes']} "
            f"kernel_cold_bytes={d['kernel_cold_bytes']} reason={d['reason']!r}")
    env.say(markdown(phase))
    return phase


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "emit":
        emit(int(sys.argv[2]), int(sys.argv[3]), sys.stdout.buffer)
    else:
        raise SystemExit("usage: cold_scrollback.py emit BYTES SEED (bench_memory.py --cold-scrollback runs the phase)")
