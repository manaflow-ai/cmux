"""Baselines per product area: area / bench / machine class -> value, recorded nightly, fetched per pull request.

Leo, 2026-11-27 (forwarding the @cmux answer he asked for): "Baseline lookup per area. A nightly job on
feat-cmux-next records results as area/bench/machine class → value, stored in R2 or Axiom. A PR fetches only the
baselines for its own areas, which takes milliseconds. A wall-clock result blocks only if it's more than ~15% worse
on 3 repeats. If the baseline is missing, no Mac is free or the infrastructure is flaky, the check posts a warning
and passes. That's what makes it fail-open."

Store: one small JSON object per (machine class, area) at

    <base>/bench-baselines/v1/<machine class>/<area slug>.json

`<base>` is the public read URL of the cmux-ci-cache-next R2 bucket (https://ci-cache-next.cmux.com), so a pull
request (forks too) reads with no secret, and only the nightly writer (.github/workflows/bench-baselines-nightly.yml)
holds the bucket key. CMUX_BENCH_BASELINES=URL|DIR points both read and record somewhere else (a plain directory in
tests and offline work).

One object:

    {"schema": "cmux-bench/baselines/v1", "area": "Diff view", "machine_class": "linux-x86_64-4cpu",
     "sha": "<feat-cmux-next commit>", "recorded_at": "2026-11-28T03:00:00Z",
     "benches": {"<bench id>": {"cmd": "...", "value_s": 1.234, "repeats_s": [1.21, 1.23, 1.26]}}}

A bench id is a slug of its command plus a short hash, so renaming an area keeps nothing stale and editing a
command starts a new series (its first PR run warns: no baseline yet).

The rule (`judge`): a pull request runs each bench REPEATS (3) times; it regresses only when every repeat is more
than THRESHOLD (15%) over the baseline value (the median of the nightly's repeats). One slow repeat out of three is
noise and passes. A missing baseline, an unreachable store, a broken object or a bench that did not measure is a
warning and passes.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import statistics
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCHEMA = "cmux-bench/baselines/v1"
PREFIX = "bench-baselines/v1"
DEFAULT_BASE = "https://ci-cache-next.cmux.com"
THRESHOLD = 0.15
REPEATS = 3
FETCH_TIMEOUT_S = 3.0

REGRESSED, PASSED, NO_BASELINE, NO_MEASURE = "regressed", "within-baseline", "no-baseline", "not-measured"


def base() -> str:
    return os.environ.get("CMUX_BENCH_BASELINES", DEFAULT_BASE).rstrip("/")


def machine_class() -> str:
    """The runner shape a value is only comparable on: OS, CPU architecture, CPU count. CMUX_BENCH_MACHINE_CLASS
    names it outright (a runner label that hides its shape)."""
    named = os.environ.get("CMUX_BENCH_MACHINE_CLASS", "").strip()
    if named:
        return slug(named)
    arch = {"amd64": "x86_64", "aarch64": "arm64"}.get(platform.machine().lower(), platform.machine().lower())
    return f"{platform.system().lower()}-{arch}-{os.cpu_count() or 0}cpu"


def slug(text: str, keep: int = 48) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:keep] or "x"


def bench_id(cmd: str) -> str:
    return f"{slug(cmd, 40)}-{hashlib.sha256(cmd.encode()).hexdigest()[:8]}"


def object_path(area: str, mclass: str) -> str:
    return f"{PREFIX}/{slug(mclass)}/{slug(area)}.json"


def _is_url(where: str) -> bool:
    return where.startswith(("http://", "https://"))


def fetch_one(area: str, mclass: str, where: str | None = None, timeout: float = FETCH_TIMEOUT_S) -> tuple[dict | None, str]:
    """One area's object, or None and why (fail open: every failure is a reason, never an exception)."""
    where = (where or base()).rstrip("/")
    rel = object_path(area, mclass)
    try:
        if _is_url(where):
            req = urllib.request.Request(f"{where}/{rel}", headers={"User-Agent": "cmux-bench"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read(1 << 20)
        else:
            raw = (Path(where) / rel).read_bytes()
    except urllib.error.HTTPError as err:
        return None, "no baseline recorded" if err.code in (403, 404) else f"store answered HTTP {err.code}"
    except FileNotFoundError:
        return None, "no baseline recorded"
    except (OSError, urllib.error.URLError, TimeoutError) as err:
        return None, f"store unreachable: {getattr(err, 'reason', err)}"
    try:
        doc = json.loads(raw)
    except ValueError:
        return None, "baseline object is not JSON"
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or not isinstance(doc.get("benches"), dict):
        return None, f"baseline object is not {SCHEMA}"
    return doc, ""


def fetch(areas: list[str], mclass: str | None = None, where: str | None = None,
          timeout: float = FETCH_TIMEOUT_S) -> tuple[dict[str, dict], dict[str, str], float]:
    """Only these areas' objects, in parallel: (area -> object, area -> why it is missing, seconds taken)."""
    mclass = mclass or machine_class()
    names = sorted(set(areas))
    t = time.perf_counter()
    got: dict[str, dict] = {}
    missing: dict[str, str] = {}
    if names:
        with ThreadPoolExecutor(max_workers=min(16, len(names))) as pool:
            for name, (doc, why) in zip(names, pool.map(lambda a: fetch_one(a, mclass, where, timeout), names)):
                if doc is None:
                    missing[name] = why
                else:
                    got[name] = doc
    return got, missing, time.perf_counter() - t


def lookup(docs: dict[str, dict], areas: list[str], cmd: str) -> tuple[float | None, str]:
    """The baseline value for a bench command under any of its areas (the tightest, if several name it)."""
    key = bench_id(cmd)
    values = []
    for a in areas:
        entry = docs.get(a, {}).get("benches", {}).get(key)
        v = entry.get("value_s") if isinstance(entry, dict) else None
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
            values.append((float(v), a))
    if not values:
        return None, ""
    return min(values)


def judge(repeats: list[float], baseline: float | None, threshold: float = THRESHOLD) -> str:
    """REGRESSED only when there are REPEATS measurements and every one is more than `threshold` over the
    baseline; anything less certain passes."""
    if baseline is None:
        return NO_BASELINE
    if len(repeats) < REPEATS:
        return NO_MEASURE
    limit = baseline * (1 + threshold)
    return REGRESSED if all(r > limit for r in repeats) else PASSED


def documents(results: list[dict], mclass: str, sha: str, now: str | None = None) -> dict[str, dict]:
    """The objects a nightly run writes: one per area, each bench that measured all its repeats, by its median."""
    now = now or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    out: dict[str, dict] = {}
    for r in results:
        reps = [x for x in r.get("repeats_s") or [] if isinstance(x, (int, float))]
        if len(reps) < REPEATS or r.get("status") not in ("ok", "over-budget"):
            continue
        entry = {"cmd": r["cmd"], "value_s": round(statistics.median(reps), 6), "repeats_s": reps}
        for area in r["areas"]:
            doc = out.setdefault(area, {"schema": SCHEMA, "area": area, "machine_class": mclass, "sha": sha,
                                        "recorded_at": now, "benches": {}})
            doc["benches"][bench_id(r["cmd"])] = entry
    return out


def write_dir(docs: dict[str, dict], root: Path) -> list[Path]:
    """Lay the objects out under root as the store holds them (the nightly uploads root as is)."""
    written = []
    for area, doc in sorted(docs.items()):
        p = root / object_path(area, doc["machine_class"])
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
        written.append(p)
    return written


# Mac-only benches: they run on a fleet Mac (cmux-ci, a step submitted from a Linux runner), and their numbers come
# back as lines in the step's log, not as a command this runner times. Each entry: the bench's stable command name
# (its bench id), the line it reads, and the relevance-map bench it measures (which names its areas). SidebarChiefLagTests
# prints "SIDEBAR-CHIEF-LAG <bench> <label> ... p95_ms=..." per run; the nightly runs it REPEATS times in one step.
LOG_BENCHES = (
    ("SidebarChiefLagTests ticks after p95_ms",
     re.compile(r"SIDEBAR-CHIEF-LAG ticks after [^\n]*?\bp95_ms=([0-9.]+)"), "SidebarLagBench"),
    ("SidebarChiefLagTests scroll after p95_ms",
     re.compile(r"SIDEBAR-CHIEF-LAG scroll after [^\n]*?\bp95_ms=([0-9.]+)"), "SidebarScrollBench"),
    ("SidebarChiefLagTests remap after full_pass_ms",
     re.compile(r"SIDEBAR-CHIEF-LAG remap after [^\n]*?\bfull_pass_ms=([0-9.]+)"), "ChiefFaceFlushBenchTests"),
)


def from_log(text: str, rules) -> list[dict]:
    """Results (as relevance.run_benches gives them) from a fleet step's log: one per LOG_BENCHES entry, every
    repeat it printed, in seconds, under each area whose `benches` names it."""
    out = []
    for cmd, pattern, bench in LOG_BENCHES:
        reps = [round(float(m.group(1)) / 1000, 6) for m in pattern.finditer(text)]
        areas = sorted({r.name for r in rules if r.kind == "area" and bench in r.benches})
        ok = len(reps) >= REPEATS and areas
        out.append({"cmd": cmd, "areas": areas, "repeats_s": reps, "status": "ok" if ok else "not-measured",
                    "detail": "" if ok else f"{len(reps)} of {REPEATS} repeats in the log, areas {areas or 'none'}"})
    return out
