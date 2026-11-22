"""footprint: memory footprint of a running cmux NEXT and every process it owns, per process kind.

--host local-readonly (default, macOS): read-only probes of an app that is already running. It never launches,
quits, signals or attaches a debugger to anything. The app is found by its bundle path (--arg app=PATH; default
the first of /Applications/cmux NIGHTLY.app and /Applications/cmux NEXT.app that runs); its processes are its
descendants, every process running from inside the bundle, every process it is responsible for (WebKit XPC) and
its terminal hosts, as scripts/perf-bench/procs.py (xbench's counters) selects them. Per process:
  - `ps -o pid,ppid,rss,command` (RSS),
  - phys_footprint from proc_pid_rusage (procs.counters; the number Activity Monitor's Memory column shows),
  - `vmmap --summary PID` (physical footprint, dirty and swapped), only with --arg vmmap=1 (vmmap suspends each process while it reads it, so it is off by default on a live app).
The raw probe output is written to a JSON dump first (cmux-bench-footprint/v1) and the rows come from parsing
that dump, so `cmux-bench footprint --import DUMP` gives the same rows on any machine (--arg dump=PATH keeps it).

--host fleet: the per-kind footprint of xbench's resource budget (scripts/measure/perf-bench.sh
browsers=cmux-budget on the newest NIGHTLY, procs.py's per-kind phys_footprint), phase=home (idle on Home after
launch) and phase=tabs-hidden (a workspace of terminals and hidden Chromium and WebKit tabs). `--import` takes
that results.json too.

Rows: footprint (MB) per kind (app, renderer, gpu, utility, webcontent, webkit-gpu, webkit-networking, cmux-tui,
acpmux, terminal-host, helper, other) and kind=total; processes (count) per kind; and in local mode rss, dirty and
swapped (MB) per kind where the probe read them.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

DUMP_SCHEMA = "cmux-bench-footprint/v1"
DEFAULT_APPS = ("/Applications/cmux NIGHTLY.app", "/Applications/cmux NEXT.app")
HARNESS_FLEET = "scripts/measure/perf-bench.sh"
FLEET_ARTIFACT = "artifacts/perf-bench/results.json"
CLONE_CLEANUP = "--type=code-sign-clone-cleanup"
PHASES = {"budget-memory-home": "home", "budget-memory-total": "tabs-hidden"}
SIZE = re.compile(r"^([0-9.]+)([KMGT]?)B?$")
UNIT_BYTES = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
MB = 1024 * 1024


# --- classification ---------------------------------------------------------------------------------
def kind_of(command: str) -> str:
    """The bench's process kind for a command line. procs.py's kind_of names (which the fleet rows carry) map
    onto the same set through `fold`."""
    if "--type=renderer" in command:
        return "renderer"
    if "--type=gpu-process" in command:
        return "gpu"
    if "--type=utility" in command:
        return "utility"
    if "com.apple.WebKit." in command:
        sub = command.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
        return {"webcontent": "webcontent", "gpu": "webkit-gpu", "networking": "webkit-networking"}.get(sub, "webkit-" + sub)
    if "__terminal-host" in command:
        return "terminal-host"
    if "/bin/cmux-tui" in command:
        return "cmux-tui"
    if "/bin/acpmux" in command:
        return "acpmux"
    exe = command.split(" --", 1)[0].split(" -")[0]
    if " Helper" in exe:
        return "helper"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "app"
    return "other"


def fold(procs_kind: str) -> str:
    """procs.py's kind (main, renderer, gpu, utility:X, webkit-webcontent, ...) -> this bench's kind."""
    if procs_kind == "main":
        return "app"
    if procs_kind.startswith("utility:"):
        return "utility"
    if procs_kind == "webkit-webcontent":
        return "webcontent"
    if procs_kind in ("renderer", "gpu", "webkit-gpu", "webkit-networking", "cmux-tui", "acpmux", "terminal-host",
                      "helper"):
        return procs_kind
    return "other"


# --- raw tool output parsers -----------------------------------------------------------------------
def parse_ps(text: str) -> list[dict[str, Any]]:
    """`ps -axww -o pid=,ppid=,rss=,command=` -> [{pid, ppid, rss_kb, command}]."""
    rows = []
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit():
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "rss_kb": int(parts[2]), "command": parts[3]})
    return rows


def size_bytes(token: str) -> float | None:
    m = SIZE.match(token.strip())
    return float(m.group(1)) * UNIT_BYTES[m.group(2)] if m else None


def parse_vmmap(text: str) -> dict[str, float]:
    """`vmmap --summary PID`: physical footprint, and the TOTAL row's resident, dirty and swapped (bytes).
    The TOTAL row is VIRTUAL RESIDENT DIRTY SWAPPED ...; "TOTAL, minus reserved VM space" wins when present."""
    out: dict[str, float] = {}
    m = re.search(r"^Physical footprint:\s+(\S+)", text, re.M)
    if m and size_bytes(m.group(1)) is not None:
        out["footprint"] = size_bytes(m.group(1))
    total = None
    for line in text.splitlines():
        if line.startswith("TOTAL, minus reserved VM space"):
            total = line[len("TOTAL, minus reserved VM space"):]
        elif line.startswith("TOTAL") and total is None:
            total = line[len("TOTAL"):]
    if total:
        cols = [size_bytes(t) for t in total.split()]
        if len(cols) >= 4 and None not in cols[:4]:
            out.update(resident=cols[1], dirty=cols[2], swapped=cols[3])
    return out


def select(table: list[dict[str, Any]], app: str) -> tuple[int | None, list[int]]:
    """The app's main pid and its processes in a ps table: descendants of the main process, every process running
    from inside the bundle and the terminal hosts that name the app's daemon (`--owner ...@PID`). WebKit XPC
    services (parent launchd) need procs.py's responsibility read; the probe adds them when it can."""
    root = app.rstrip("/") + "/"
    macos = root + "Contents/MacOS/"
    mains = [r["pid"] for r in table if r["command"].startswith(macos) and "--type=" not in r["command"]]
    if not mains:
        return None, []
    main = min(mains)
    children: dict[int, list[int]] = {}
    for r in table:
        children.setdefault(r["ppid"], []).append(r["pid"])
    found, stack = set(), [main]
    while stack:
        pid = stack.pop()
        if pid not in found:
            found.add(pid)
            stack.extend(children.get(pid, []))
    found |= {r["pid"] for r in table if r["command"].startswith(root)}
    for r in table:
        owner = re.search(r"--owner \S+@(\d+)", r["command"]) if "__terminal-host" in r["command"] else None
        if owner and int(owner.group(1)) in found:
            found.add(r["pid"])
    by_pid = {r["pid"]: r for r in table}
    return main, sorted(p for p in found if p in by_pid and CLONE_CLEANUP not in by_pid[p]["command"])


# --- the probe (macOS, read-only) -------------------------------------------------------------------
def _procs():
    """scripts/perf-bench/procs.py (proc_pid_rusage, responsibility), or None where it cannot load."""
    sys.path.insert(0, str(REPO_ROOT / "scripts" / "perf-bench"))
    try:
        import procs  # type: ignore
        return procs
    except (ImportError, OSError):
        return None
    finally:
        sys.path.pop(0)


def probe(app: str, use_vmmap: bool) -> dict[str, Any]:
    ps = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,rss=,command="], text=True, capture_output=True, check=True)
    table = parse_ps(ps.stdout)
    main, pids = select(table, app)
    if main is None:
        raise BenchError(f"footprint: {app} is not running (nothing is launched here; start it yourself)")
    procs = _procs()
    if procs is not None:
        try:  # adds the WebKit XPC processes the app is responsible for
            pids = sorted(set(pids) | set(procs.Instance(app, main).pids()))
        except Exception as err:  # noqa: BLE001 - the ps selection stands
            print(f"footprint: procs.py selection failed ({err}); using ps only", file=sys.stderr)
    by_pid = {r["pid"]: r for r in table}
    lines = [f"{r['pid']} {r['ppid']} {r['rss_kb']} {r['command']}" for p in pids if (r := by_pid.get(p))]
    footprint: dict[str, int | None] = {}
    vmmap: dict[str, str] = {}
    for pid in pids:
        if procs is not None:
            got = procs.counters(pid)
            footprint[str(pid)] = int(got[3]) if got else None
        if use_vmmap:
            try:
                out = subprocess.run(["vmmap", "--summary", str(pid)], text=True, capture_output=True, timeout=60)
                if out.returncode == 0:
                    vmmap[str(pid)] = out.stdout
            except (OSError, subprocess.TimeoutExpired):
                pass
    return {"schema": DUMP_SCHEMA, "app": app, "main_pid": main,
            "probed_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "macos": platform.mac_ver()[0], "ps": "\n".join(lines) + "\n", "footprint": footprint, "vmmap": vmmap}


class Footprint(Bench):
    name = "footprint"
    summary = "Memory footprint of a running cmux NEXT per process kind (app, renderers, GPU, WebContent, cmux-tui, acpmux)"
    units = "MB, count"
    owner = "perf (resource budget, CMUX-571)"
    hosts = ("local-readonly", "fleet")
    harness = "scripts/bench/benches/footprint.py"
    version = "1"
    thresholds = {"footprint": 10.0, "dirty": 15.0, "swapped": 50.0, "rss": 15.0}
    nightly = False  # the fleet numbers come from xbench's nightly cmux-budget run

    def run(self, ctx: Context) -> None:
        if ctx.host_role == "fleet":
            if ctx.build.get("channel") != "nightly":
                raise BenchError("footprint --host fleet measures the newest NIGHTLY (xbench cmux=nightly)")
            res = ctx.fleet_step(HARNESS_FLEET, ["browsers=cmux-budget", "launches=0", "rounds=1", "tabswitch=off",
                                                 "palette=off", "cmux=nightly"], FLEET_ARTIFACT,
                                 step_class="exclusive", labels=("bench",), timeout=3600)
            if not res.artifact_path:
                raise BenchError(f"footprint: step {res.job_id or '?'} left no results.json; log {res.log_path}")
            self.ingest(ctx, res.artifact_path)
            return
        if platform.system() != "Darwin":
            raise BenchError("footprint --host local-readonly reads a running app on macOS; elsewhere use --import DUMP")
        app = ctx.arg("app") or next((a for a in DEFAULT_APPS if os.path.isdir(a)), DEFAULT_APPS[0])
        dump = probe(app.rstrip("/"), ctx.arg("vmmap", "0") == "1")
        path = Path(ctx.arg("dump") or ctx.workdir / "footprint-probe.json")
        path.write_text(json.dumps(dump, indent=1))
        ctx.notes.append(f"footprint: probe dump {path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        if isinstance(doc, dict) and doc.get("schema") == DUMP_SCHEMA:
            self._dump(ctx, doc)
        elif isinstance(doc, dict) and isinstance(doc.get("samples"), list):
            self._budget(ctx, doc)
        else:
            raise BenchError(f"{path}: neither a footprint probe dump ({DUMP_SCHEMA}) nor an xbench results.json")

    def _dump(self, ctx: Context, doc: dict[str, Any]) -> None:
        if doc.get("macos"):
            ctx.host["os"] = f"macOS {doc['macos']}"
        agg: dict[str, dict[str, float]] = {}
        missing = 0
        for r in parse_ps(doc.get("ps", "")):
            pid = str(r["pid"])
            vm = parse_vmmap(doc.get("vmmap", {}).get(pid) or "")
            fp = doc.get("footprint", {}).get(pid)
            fp = float(fp) if isinstance(fp, (int, float)) else vm.get("footprint")
            kind = "app" if r["pid"] == doc.get("main_pid") else kind_of(r["command"])
            if fp is None:
                missing += 1
                continue
            for k in (kind, "total"):
                e = agg.setdefault(k, {"footprint": 0.0, "rss": 0.0, "processes": 0, "dirty": 0.0, "swapped": 0.0,
                                       "vmmap": 0})
                e["footprint"] += fp / MB
                e["rss"] += r["rss_kb"] / 1024
                e["processes"] += 1
                if "dirty" in vm:
                    e["dirty"] += vm["dirty"] / MB
                    e["swapped"] += vm["swapped"] / MB
                    e["vmmap"] += 1
        if not agg:
            raise BenchError("footprint: the dump has no process with a footprint")
        if missing:
            ctx.notes.append(f"footprint: {missing} process(es) had no footprint reading (left out)")
        for kind, e in sorted(agg.items(), key=lambda kv: (kv[0] == "total", -kv[1]["footprint"])):
            labels = {"kind": kind}
            ctx.row("footprint", e["footprint"], "MB", labels=labels)
            ctx.row("rss", e["rss"], "MB", labels=labels)
            ctx.row("processes", e["processes"], "count", labels=labels)
            if e["vmmap"] == e["processes"]:  # dirty/swapped only when vmmap read every process of the kind
                ctx.row("dirty", e["dirty"], "MB", labels=labels)
                ctx.row("swapped", e["swapped"], "MB", labels=labels)

    def _budget(self, ctx: Context, doc: dict[str, Any]) -> None:
        m = doc.get("machine") or {}
        if m.get("host"):
            ctx.host.update({"name": str(m["host"]), "role": "fleet"})
        if m.get("macos"):
            ctx.host["os"] = f"macOS {m['macos']}"
        if m.get("chip"):
            ctx.host["chip"] = str(m["chip"])
        per: dict[tuple[str, str], list[float]] = {}
        for s in doc["samples"]:
            phase = PHASES.get(s.get("row"))
            if not phase or not isinstance(s.get("kinds"), dict) or not isinstance(s.get("value"), (int, float)):
                continue
            folded: dict[str, float] = {}
            for k, mb in s["kinds"].items():
                if isinstance(mb, (int, float)):
                    folded[fold(k)] = folded.get(fold(k), 0.0) + float(mb)
            for k, mb in folded.items():
                per.setdefault((phase, k), []).append(mb)
            per.setdefault((phase, "total"), []).append(float(s["value"]))
            if isinstance(s.get("processes"), int):
                per.setdefault((phase, "#processes"), []).append(float(s["processes"]))
        if not per:
            raise BenchError("footprint: the results.json has no cmux-budget memory sample with kinds")
        for (phase, kind), values in sorted(per.items(), key=lambda kv: (kv[0][0], kv[0][1] in ("total", "#processes"), -max(kv[1]))):
            if kind == "#processes":
                ctx.row("processes", unit="count", samples=values, labels={"kind": "total", "phase": phase})
            else:
                ctx.row("footprint", unit="MB", samples=values, labels={"kind": kind, "phase": phase})


BENCH = Footprint()
