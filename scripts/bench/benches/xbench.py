"""xbench: cmux NEXT against other browsers, and the cmux-budget resource budget (scripts/perf-bench/README.md).

Wraps scripts/measure/perf-bench.sh on a fleet Mac and turns its results.json (`xbench.py report`) into rows:
every row id of every browser in it, the browser as a label (cmux-chromium, cmux-webkit, cmux-terminal,
cmux-budget, cmux-debug, and whatever other browsers the run measured, named as the run names them).

  value = the median over the run's samples (results.json `samples`), else the row's median; n per cell.
  Row ids become snake_case metrics (`memory-20` -> `memory_20`, `budget-memory-total` -> `budget_memory_total`).
  Tab switch rows (`tab-switch-<kind>-<count>-<input>`) become `tab_switch_e2e` with labels kind/tabs/input;
  palette rows (`palette-open-<surface>`) become `palette_open` with label surface. Both are Debug-build rows.
  Units come from the harness's own row tables (xbench.py ROWS, budget.py ROWS, spinners.py ROWS, read as
  source, not imported: procs.py needs macOS). /s -> per_s; KB/s (KiB/s) -> kbps (x 8.192); n -> count.

Default run (a few minutes past the app download, alone on its worker): browsers=cmux-chromium,cmux-budget,
rounds=1, launches=1, tabswitch=off, palette=off; `--build nightly` (default) measures the newest nightly-next
DMG (cmux=nightly, no build); `--build SHA` builds a Release app at that commit (cmux=build, --ref SHA).
Any of the harness's own arguments pass through: `--arg browsers=...`, `--arg rounds=3`, `--arg gate=1` ...

`cmux-bench xbench --import FILE` records a results.json you already have, a checked-in gate baseline
(scripts/perf-bench/baseline/<chip>-macos<major>.json, the same format) or a tab-switch-matrix report
(baseline/tab-switch-*.json). The document's own machine, cmux ref, cmux version and date become the run's
host, build and timestamp, so `--import scripts/perf-bench/baseline/apple-m6-macos27.json` puts the baseline in
the ledger as the run it was.
"""
from __future__ import annotations

import ast
import collections
import json
import re
from pathlib import Path
from typing import Any

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/perf-bench.sh"
ARTIFACT = "artifacts/perf-bench/results.json"
PERF_BENCH = REPO_ROOT / "scripts" / "perf-bench"
# perf-bench.sh's own arguments (everything a bench may pass through). suite=parity writes another
# document (parity.json) and is not this bench.
PASS_THROUGH = ("rounds", "launches", "idle", "active", "settle", "cmux", "gate", "maxload", "browsers",
                "tabswitch", "tabcounts", "palette", "budgets", "bench_config", "app_config")
DEFAULTS = {"browsers": "cmux-chromium,cmux-budget", "rounds": "1", "launches": "1", "tabswitch": "off",
            "palette": "off"}
UNIT_MAP = {"ms": ("ms", 1.0), "MB": ("MB", 1.0), "mW": ("mW", 1.0), "%": ("%", 1.0), "/s": ("per_s", 1.0),
            "KB/s": ("kbps", 1024 * 8 / 1000), "n": ("count", 1.0)}
TAB_SWITCH = re.compile(r"^tab-switch-(?P<kind>[a-z]+)-(?P<tabs>\d+)-(?P<input>[a-z_]+)$")
TAB_SWITCH_INPUTS = ("ctrl_tab", "cmd_shift_bracket", "click")
TAB_SWITCH_BROWSER = "cmux-debug"


def _source_rows(path: Path) -> dict[str, str]:
    """{row id: unit} from a module-level `ROWS = [(id, label, unit, ...), ...]` literal, read as source."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError):
        return {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ROWS" for t in node.targets):
            try:
                rows = ast.literal_eval(node.value)
            except ValueError:
                return {}
            return {r[0]: r[2] for r in rows if isinstance(r, tuple) and len(r) >= 3}
    return {}


_UNITS: dict[str, str] | None = None


def row_units() -> dict[str, str]:
    global _UNITS
    if _UNITS is None:
        _UNITS = {}
        for name in ("xbench.py", "budget.py", "spinners.py"):
            _UNITS.update(_source_rows(PERF_BENCH / name))
    return _UNITS


def unit_of(row: str) -> tuple[str, float] | None:
    """(schema unit, factor) of a results.json row id, or None when the harness names no unit for it."""
    if row.startswith(("tab-switch-", "palette-open-")) or row in ("tab-switch", "launch-link"):
        return "ms", 1.0
    unit = row_units().get(row)
    return UNIT_MAP.get(unit) if unit else None


def metric_of(row: str) -> tuple[str, dict[str, str]]:
    """The metric name and extra labels of a results.json row id."""
    m = TAB_SWITCH.match(row)
    if m:
        return "tab_switch_e2e", {"kind": m["kind"], "tabs": m["tabs"], "input": m["input"]}
    if row.startswith("palette-open-"):
        return "palette_open", {"surface": row[len("palette-open-"):]}
    return row.replace("-", "_"), {}


class XBench(Bench):
    name = "xbench"
    summary = "cmux NEXT vs other browsers (power, launch, paint, idle CPU/wakeups, memory) and the cmux-budget rows"
    units = "ms, MB, mW, %, per_s, kbps, count"
    owner = "perf (msg 2654; budgets CMUX-571)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # The harness's own gate: 15 % past the baseline (plus a unit floor, which compare applies too).
    thresholds = {m: 15.0 for m in (
        "launch_window", "newtab_paint", "memory_1", "memory_10", "memory_20", "memory_closed",
        "power_idle_hidden", "power_idle_visible", "power_idle_visible_1", "power_scroll", "power_video",
        "power_switch", "power_home_idle", "idle_cpu_1", "idle_cpu_20", "idle_cpu_home", "idle_wakeups_1",
        "idle_wakeups_20", "idle_wakeups_home", "tab_switch_e2e", "palette_open",
        "budget_memory_total", "budget_memory_home", "budget_idle_cpu", "budget_idle_cpu_home",
        "budget_idle_wakeups", "budget_idle_wakeups_home")}
    # The resource budget on the newest NIGHTLY: one round, no build (about 15 minutes on cmux20-bench).
    nightly = True
    nightly_args = {"browsers": "cmux-budget", "launches": "0", "rounds": "1"}

    def harness_args(self, ctx: Context) -> tuple[list[str], str | None]:
        if ctx.arg("suite"):
            raise BenchError("xbench: suite= is the parity bench (parity.json); run perf-bench.sh directly")
        args = dict(DEFAULTS)
        args.update({k: v for k, v in ctx.args.items() if k in PASS_THROUGH})
        ref = None
        channel = ctx.build.get("channel")
        if "cmux" not in ctx.args:
            if channel == "nightly":
                args["cmux"] = "nightly"
            elif channel == "sha":
                args["cmux"] = "build"
                ref = ctx.build["sha"]
            else:
                raise BenchError(f"xbench: --build {channel} has no fleet app; use nightly or a commit sha")
        elif args["cmux"] == "build" and channel == "sha":
            ref = ctx.build["sha"]
        return [f"{k}={v}" for k, v in args.items()], ref

    def run(self, ctx: Context) -> None:
        args, ref = self.harness_args(ctx)
        builds = any(a in args for a in ("cmux=build",)) or not {"tabswitch=off", "palette=off"} <= set(args)
        res = ctx.fleet_step(self.harness, args, ARTIFACT, step_class="exclusive", labels=("bench",),
                             timeout=7200 if builds else 3600, ref=ref)
        if not res.artifact_path:
            raise BenchError(f"xbench: step {res.job_id or '?'} left no results.json (exit {res.exit_code}); log {res.log_path}")
        self.ingest(ctx, res.artifact_path)

    # --- ingest ---------------------------------------------------------------------------------
    def ingest(self, ctx: Context, path: Path) -> None:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        if isinstance(doc, dict) and "scenarios" in doc and "rows" not in doc:
            self._tab_switch_report(ctx, doc)
            return
        if not isinstance(doc, dict) or not isinstance(doc.get("rows"), dict):
            raise BenchError(f"{path}: not an xbench results.json (no rows)")
        self._identity(ctx, doc)
        samples: dict[tuple[str, str], list[float]] = {}
        for s in doc.get("samples") or []:
            if isinstance(s, dict) and isinstance(s.get("value"), (int, float)):
                samples.setdefault((s.get("row"), s.get("browser")), []).append(float(s["value"]))
        skipped = set()
        for row, per in doc["rows"].items():
            unit = unit_of(row)
            if unit is None:
                skipped.add(row)
                continue
            unit_name, factor = unit
            metric, extra = metric_of(row)
            for browser, cell in sorted(per.items()):
                if not isinstance(cell, dict) or cell.get("median") is None:
                    continue
                labels = {**extra, "browser": browser}
                got = samples.get((row, browser))
                if got and len(got) == cell.get("n", len(got)):
                    ctx.row(metric, unit=unit_name, samples=[v * factor for v in got], labels=labels)
                else:
                    n = cell.get("n")
                    ctx.row(metric, float(cell["median"]) * factor, unit_name, p50=float(cell["median"]) * factor,
                            n=n if isinstance(n, int) and n >= 1 else None, labels=labels)
        for row in sorted(skipped):
            ctx.notes.append(f"xbench: row {row} has no unit in the harness's row tables; skipped")
        errors = collections.Counter((e.get("browser"), e.get("row"), e.get("note")) for e in doc.get("errors") or []
                                     if isinstance(e, dict) and e.get("row") != "budget-idle-samples")
        for (browser, row, note), count in errors.items():
            ctx.notes.append(f"xbench: not measured: {browser} {row}: {note}" + (f" (x{count})" if count > 1 else ""))
        failed = (doc.get("budgets") or {}).get("failed")
        if failed:
            ctx.notes.append(f"xbench: {failed} enforced budget(s) broken (budgets.json)")

    def _identity(self, ctx: Context, doc: dict[str, Any]) -> None:
        """The document's machine, cmux build and date, so an imported baseline is recorded as the run it was."""
        m = doc.get("machine") or {}
        if m.get("host"):
            ctx.host.update({"name": str(m["host"]), "role": "fleet"})
        if m.get("macos"):
            ctx.host["os"] = f"macOS {m['macos']}"
        if m.get("chip"):
            ctx.host["chip"] = str(m["chip"])
        ref = doc.get("cmux_ref")
        version = next((b.get("version") for k, b in (doc.get("browsers") or {}).items()
                        if k.startswith("cmux") and isinstance(b, dict) and b.get("version")), None)
        if isinstance(ref, str) and re.fullmatch(r"[0-9a-f]{40}", ref) and ref != ctx.build.get("sha"):
            channel = "nightly" if version and "nightly" in version else "sha"
            ctx.build = {"channel": channel, "version": version, "sha": ref}
        elif version and not ctx.build.get("version"):
            ctx.build["version"] = version
        date = doc.get("date")
        if isinstance(date, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", date) and not ctx.timestamp.startswith(date):
            ctx.timestamp = f"{date}T00:00:00Z"

    def _tab_switch_report(self, ctx: Context, doc: dict[str, Any]) -> None:
        """tab-switch-matrix.py's report (as xbench.py tab_switch_rows reads it): end-to-end ms per kind,
        tab count and input, keyed by the switched-to surface's kind."""
        found = 0
        for scenario in doc.get("scenarios") or []:
            kind, count = scenario.get("kind"), scenario.get("count")
            for input_kind in TAB_SWITCH_INPUTS:
                table = (scenario.get(input_kind) or {}).get("table") or {}
                line = table.get(kind) or table.get("page") or next(
                    (v for k, v in table.items() if k != "terminal"), {})
                e2e = line.get("e2e") or line.get("commit") or {}
                if e2e.get("p50") is None:
                    continue
                n = line.get("n")
                ctx.row("tab_switch_e2e", float(e2e["p50"]), "ms", p50=float(e2e["p50"]),
                        p95=None if e2e.get("p95") is None else float(e2e["p95"]),
                        n=n if isinstance(n, int) and n >= 1 else None,
                        labels={"kind": kind, "tabs": count, "input": input_kind, "browser": TAB_SWITCH_BROWSER})
                found += 1
            per_tab = (scenario.get("per_tab") or {}).get("footprint_mb")
            if isinstance(per_tab, (int, float)):
                ctx.row("tab_switch_footprint_per_tab", float(per_tab), "MB",
                        labels={"kind": kind, "tabs": count, "browser": TAB_SWITCH_BROWSER})
        if not found:
            raise BenchError("xbench: the tab switch report has no end-to-end row")
        ctx.notes.append("xbench: a tab switch report names no build or machine; pass --build SHA and --host-name")


BENCH = XBench()
