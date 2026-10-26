#!/usr/bin/env python3
"""Import the nightly xbench comparisons (scripts/perf-bench/baseline/*.json) into the lab store as legacy series.

    python3 -I scripts/perf-lab/import_xbench.py --db LAB.sqlite3 scripts/perf-bench/baseline/*.json
    python3 -I scripts/perf-lab/lab.py import-xbench --db LAB.sqlite3 FILE ...   # the same, through lab.py

A baseline is an `xbench.py report --json` document: per row and browser, the median, min, max and n of the runs.
Each (row, browser) cell becomes one point of the series `xbench.vs-browsers` / `<row>.<browser>` (lab_series.py,
the names `xbench.py story` writes; Chrome's metrics end in `_ref`). The cells of one file and one engine are one
store run, as one `xbench.py story` run is.

A legacy point holds the median only (its samples list is that value), from a Release (nightly) or tagged Debug
cmux build, not raw samples of a bench build. Its summary carries `legacy_stat` (ingest.py LEGACY_FLAGS, task 005)
and `legacy_median_only`, so it is shown and never judged, and the build config and story name keep it out of the
lab's `vs-browsers` bench series.

A second import of the same files adds nothing: each run has a stable id and store.insert_run keeps a replay of the
same content as a no-op. Stdlib only; reads xbench.py's and budget.py's row tables with ast (never imports them, they
need macOS), so it runs under `python3 -I` on any host.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PERF_BENCH = ROOT / "scripts" / "perf-bench"
DB_ENV = "CMUX_PERF_LAB_DB"


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (the names bench_launch.py and ingest.py use)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"import_xbench: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


perf_result = _sibling("perf_result", HERE / "perf_result.py")
store = _sibling("perf_lab_store", HERE / "store.py")
lab_series = _sibling("perf_bench_lab_series", PERF_BENCH / "lab_series.py")

# lab.py (task 005) reads this literal with ast to list its commands, and imports this module only to run one.
LAB_COMMANDS = {"import-xbench": "import scripts/perf-bench/baseline/*.json as legacy vs-browsers points (never judged)"}

LEGACY_STORY = "xbench.vs-browsers"
LEGACY_MEASURE_VERSION = "xbench-baseline"
LEGACY_FLAGS = {"legacy_stat": True, "legacy_median_only": True}
# The cmux arms of the nightly comparison are Release builds (perf-bench.sh cmux=build builds --config release,
# cmux=nightly fetches the nightly DMG). Its tab switch and palette rows come from a tagged Debug build.
CMUX_CONFIG = "release"
DEBUG_BROWSER = "cmux-debug"
DEBUG_CONFIG = "debug"
DEBUG_ROW_ENGINE = re.compile(r"^tab-switch-(?P<engine>chromium|webkit)-")
DEBUG_ROW_PREFIXES = ("tab-switch-", "palette-open-")
DEBUG_ROW_UNIT = "ms"
TAB_SWITCH_SKIP = "a tab-switch-matrix report: its rows are imported from the xbench results that embed them"
SUMMARY_STATS = ("median", "min", "max", "p90")
COUNT_STATS = ("n",)


class XbenchImportError(RuntimeError):
    """The import cannot run at all (no store, no checkout)."""


class _Reject(Exception):
    """One file or cell that is not stored; becomes a Rejection."""


@dataclass(frozen=True)
class Rejection:
    source: str
    reason: str

    def line(self) -> str:
        return f"{self.source}: {self.reason}"


@dataclass
class ImportReport:
    added_runs: int = 0
    added_results: int = 0
    unchanged_runs: int = 0
    skipped: list[Rejection] = field(default_factory=list)  # files with nothing to import, and why
    rejected: list[Rejection] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {"added_runs": self.added_runs, "added_results": self.added_results,
                "unchanged_runs": self.unchanged_runs,
                "skipped": [{"source": r.source, "reason": r.reason} for r in self.skipped],
                "rejected": [{"source": r.source, "reason": r.reason} for r in self.rejected]}

    def summary_line(self) -> str:
        return (f"stored {self.added_runs} run(s) with {self.added_results} result(s); "
                f"{self.unchanged_runs} already stored; {len(self.skipped)} skipped; {len(self.rejected)} rejected")


CommitPositions = Callable[[str], "int | None"]


def git_commit_positions(repo: Path | str, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run
                         ) -> CommitPositions:
    """A commit's first-parent position in `repo` (Chromium's Cr-Commit-Position), or None when it is not there.
    Raises XbenchImportError for a shallow checkout, whose counts are not positions."""
    def git(*args: str) -> str | None:
        try:
            done = run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout.strip() if done.returncode == 0 else None

    shallow = git("rev-parse", "--is-shallow-repository")
    if shallow is None:
        raise XbenchImportError(f"{repo}: not a git checkout; commit positions need one")
    if shallow == "true":
        raise XbenchImportError(f"{repo}: shallow checkout; its first-parent counts are not commit positions")
    cache: dict[str, int | None] = {}

    def position(sha: str) -> int | None:
        if sha not in cache:
            count = git("rev-list", "--count", "--first-parent", f"{sha}^{{commit}}", "--")
            cache[sha] = int(count) if count and count.isdigit() else None
        return cache[sha]

    return position


def _rows_literal(path: Path) -> list[tuple]:
    """The top-level `ROWS = [...]` of a perf-bench module, read with ast (the module is never run)."""
    for node in ast.parse(path.read_text(encoding="utf-8"), filename=str(path)).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ROWS" for t in node.targets):
            return [tuple(row) for row in ast.literal_eval(node.value)]
    raise XbenchImportError(f"{path}: no ROWS table")


def row_units(perf_bench: Path = PERF_BENCH) -> dict[str, str]:
    """xbench row id -> its xbench unit (xbench.py ROWS: id, label, unit, main; budget.py and spinners.py ROWS: id,
    label, unit; budget.py adds spinners.py's rows to its own)."""
    units = {row[0]: row[2] for row in _rows_literal(perf_bench / "xbench.py")}
    for module in ("budget.py", "spinners.py"):
        units.update({row[0]: row[2] for row in _rows_literal(perf_bench / module)})
    return units


def _number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _cell(row: str, browser: str, stats: object, units: dict[str, str]) -> tuple[str, str, store.Metric]:
    """(engine, build config, metric) of one baseline cell."""
    if browser == DEBUG_BROWSER:
        if not row.startswith(DEBUG_ROW_PREFIXES):
            raise _Reject(f"{DEBUG_BROWSER} measures only {', '.join(DEBUG_ROW_PREFIXES)} rows")
        match = DEBUG_ROW_ENGINE.match(row)
        engine, config, unit = (match["engine"] if match else "none"), DEBUG_CONFIG, DEBUG_ROW_UNIT
    else:
        engine = lab_series.BROWSER_ENGINES.get(browser)
        if engine is None:
            raise _Reject(f"browser {browser} has no lab engine (lab_series.BROWSER_ENGINES)")
        unit = units.get(row)
        if unit is None:
            raise _Reject("not an xbench row (xbench.py or budget.py ROWS)")
        config = CMUX_CONFIG
    if not isinstance(stats, dict) or not _number(stats.get("median")):
        raise _Reject("no numeric median")
    try:
        result_unit, median = lab_series.result_value(unit, stats["median"])
    except KeyError:
        raise _Reject(f"unit {unit!r} has no result-v1 unit (lab_series.RESULT_UNITS)") from None
    summary: dict[str, object] = {**LEGACY_FLAGS}
    for stat in SUMMARY_STATS:
        if _number(stats.get(stat)):
            summary[stat] = lab_series.result_value(unit, stats[stat])[1]
    for stat in COUNT_STATS:
        if _number(stats.get(stat)):
            summary[stat] = stats[stat]
    metric = lab_series.metric_name(row, browser)
    if not re.fullmatch(perf_result.NAME_PATTERN, metric):
        raise _Reject(f"metric {metric!r} does not match {perf_result.NAME_PATTERN}")
    return engine, config, store.Metric(name=metric, unit=result_unit, better="lower", samples=[median],
                                        summary=summary)


def _host(machine: object) -> tuple[store.Host, int, str]:
    """(store host, macOS major, macOS build) of a baseline's `machine` block."""
    if not isinstance(machine, dict):
        raise _Reject("no machine block")
    chip, ram_gb, macos, build = machine.get("chip"), machine.get("ram_gb"), machine.get("macos"), machine.get("build")
    displays = (machine.get("displays") or {}).get("displays") or []
    hz = displays[0].get("hz") if displays and isinstance(displays[0], dict) else None
    missing = [name for name, value in (("chip", chip), ("ram_gb", ram_gb), ("macos", macos), ("display hz", hz))
               if not value]
    if missing:
        raise _Reject(f"machine block has no {', '.join(missing)}")
    if not re.fullmatch(perf_result.MACOS_PATTERN, str(macos)):
        raise _Reject(f"machine.macos {macos!r} is not a macOS version")
    hz = int(round(float(hz)))
    # bench_launch.host_record's fingerprint: sha256 of (chip, macOS build, Hz, memory bytes).
    fingerprint = hashlib.sha256("\0".join(str(v) for v in (chip, build or "", hz, int(ram_gb) * 2**30)).encode())
    host = store.Host(name=str(machine.get("host") or "unknown"), chip=str(chip), memory_gb=int(ram_gb),
                      display_hz=hz, fingerprint=fingerprint.hexdigest())
    return host, int(str(macos).split(".")[0]), str(build or "")


def is_tab_switch_report(doc: object) -> bool:
    """tab-switch-matrix.py's --json report: `xbench.py report --tabswitch` turns it into the results' tab-switch-*
    rows, so its numbers are imported from the results file of the same run, never twice."""
    return isinstance(doc, dict) and "rows" not in doc and isinstance(doc.get("scenarios"), list)


def file_runs(path: Path, doc: object, *, units: dict[str, str], commit_positions: CommitPositions,
              rejected: list[Rejection]) -> list[tuple[store.Run, store.Build, store.Host, list[store.Metric]]]:
    """The store runs of one baseline document, one per (engine, build config); a bad cell is rejected alone."""
    if not isinstance(doc, dict) or not isinstance(doc.get("rows"), dict):
        raise _Reject("not an xbench results document (no rows object)")
    sha = doc.get("cmux_ref")
    if not isinstance(sha, str) or not re.fullmatch(perf_result.SHA_PATTERN, sha):
        raise _Reject(f"cmux_ref {sha!r} is not a full commit sha")
    position = commit_positions(sha)
    if position is None:
        raise _Reject(f"commit {sha} is not in the lab's checkout; fetch it and import again")
    try:
        started = datetime.strptime(str(doc.get("date")), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        raise _Reject(f"date {doc.get('date')!r} is not YYYY-MM-DD") from None
    host, macos_major, macos_build = _host(doc.get("machine"))
    label = str(doc.get("job") or path.stem)
    groups: dict[tuple[str, str], list[store.Metric]] = {}
    for row, per in sorted(doc["rows"].items()):
        for browser, stats in sorted((per or {}).items()) if isinstance(per, dict) else []:
            try:
                engine, config, metric = _cell(row, browser, stats, units)
            except _Reject as reason:
                rejected.append(Rejection(f"{path} {row}|{browser}", str(reason)))
                continue
            groups.setdefault((engine, config), []).append(metric)
    runs = []
    for (engine, config), metrics in sorted(groups.items()):
        run = store.Run(run_uuid=f"xbench-baseline:{label}:{engine}:{config}", kind="waterfall",
                        measure_version=LEGACY_MEASURE_VERSION, story=LEGACY_STORY, engine=engine,
                        macos_major=macos_major, macos_build=macos_build, features_hash="", safe_mode="",
                        started_at=started, tier="T2", session="light")
        runs.append((run, store.Build(sha=sha, config=config, commit_pos=position), host, metrics))
    return runs


def import_files(db: store.Store, paths: Sequence[Path | str], *, commit_positions: CommitPositions,
                 units: dict[str, str] | None = None) -> ImportReport:
    """Stores every good cell of the baseline files; a bad file or cell is rejected, the rest is stored."""
    units = row_units() if units is None else units
    report = ImportReport()
    for path in map(Path, paths):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            if is_tab_switch_report(doc):
                report.skipped.append(Rejection(str(path), TAB_SWITCH_SKIP))
                continue
            runs = file_runs(path, doc, units=units, commit_positions=commit_positions, rejected=report.rejected)
        except (OSError, UnicodeDecodeError, ValueError) as error:
            report.rejected.append(Rejection(str(path), f"cannot read ({error})"))
            continue
        except _Reject as reason:
            report.rejected.append(Rejection(str(path), str(reason)))
            continue
        for run, build, host, metrics in runs:
            existed = bool(db.run_metrics(run.run_uuid))
            try:
                db.insert_run(run, build=build, host=host, metrics=metrics)
            except (store.StoreError, sqlite3.IntegrityError) as error:
                report.rejected.append(Rejection(f"{path} {run.run_uuid}", str(error)))
                continue
            if existed:
                report.unchanged_runs += 1
            else:
                report.added_runs += 1
                report.added_results += len(metrics)
    return report


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=os.environ.get(DB_ENV), help=f"the lab store (SQLite); default ${DB_ENV}")
    parser.add_argument("--repo", default=str(ROOT), help="git checkout that resolves commit positions")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("paths", nargs="+", help="xbench results files (scripts/perf-bench/baseline/*.json)")


def run(command: str, args: argparse.Namespace) -> int:
    """Exit 0 when everything was stored (or already was), 1 when anything was rejected, 2 when nothing could run."""
    if not args.db:
        print(f"{command}: --db or ${DB_ENV} names the lab store", file=sys.stderr)
        return 2
    try:
        positions = git_commit_positions(args.repo)
        db = store.Store(args.db)
    except (XbenchImportError, store.StoreError, sqlite3.Error) as error:
        print(f"{command}: {error}", file=sys.stderr)
        return 2
    try:
        db.migrate()
        report = import_files(db, args.paths, commit_positions=positions)
    except (XbenchImportError, store.StoreError, sqlite3.Error) as error:
        print(f"{command}: {error}", file=sys.stderr)
        return 2
    finally:
        db.close()
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        for skip in report.skipped:
            print(f"skipped: {skip.line()}", file=sys.stderr)
        for rejection in report.rejected:
            print(f"rejected: {rejection.line()}", file=sys.stderr)
        print(report.summary_line())
    return 1 if report.rejected else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="import_xbench.py", description=LAB_COMMANDS["import-xbench"])
    add_arguments("import-xbench", parser)
    return run("import-xbench", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
