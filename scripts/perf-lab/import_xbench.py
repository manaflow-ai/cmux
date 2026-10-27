#!/usr/bin/env python3
"""Imports the nightly xbench's checked-in results (scripts/perf-bench/baseline/*.json) as legacy vs-browsers points.

    python3 -I scripts/perf-lab/lab.py import-xbench --db LAB.sqlite3 [RESULTS.json ...]

Without paths it reads every xbench report in scripts/perf-bench/baseline/ (a file with `machine` and `rows`; the
tab-switch-matrix reports beside them are not xbench reports). Each (file, browser) becomes one run of the story
vs-browsers (stories.d/vs-browsers.json, task 208) at the report's `cmux_ref`, with one metric per row under the name
the lab story writes, `xbench.<arm>.<row>` in result-v1 units (xbench.result_metric, xbench.result_unit; a vendor
browser's <arm> carries the version the report's `browsers` block names), and for a cmux arm the row's ratio to
Chrome's median, `xbench.<browser>.<row>.vs-chrome-<version>`. `cmux_ref` is the commit of the checkout that ran the
bench scripts (scripts/measure/perf-bench.sh), so a cmux arm is a point of it only when it measured a build of it
(cmux=build): an arm that ran the nightly-next binary (cmux=nightly, a fetch_browsers.py cmux-nightly bundle) or
whose bundle the report does not name is rejected with the reason. The nightly kept per-row medians
with min, max and n, so a point has no raw samples: its summary carries them and LEGACY_FLAGS, its measure version is
`legacy-xbench` and its host class is `xbench:<chip>/<n>gb/<n>hz`, so it is shown on the dashboard, never judged
(alerts.judged_points) and never a point of the lab's bench series, as ingest.import_perf_cron does for the cron.

Idempotent: a run is stored under `xbench:<file stem>:<browser>`, and a replay of the same content adds 0 rows.
Stdlib only; loads its siblings and xbench.py by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import sqlite3
import sys
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE_DIR = ROOT / "scripts" / "perf-bench" / "baseline"
XBENCH = ROOT / "scripts" / "perf-bench" / "xbench.py"


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (ingest.py's loader, which this module loads it with)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"import-xbench: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


ingest = _sibling("perf_lab_ingest", HERE / "ingest.py")
store = ingest.store
perf_result = ingest.perf_result

LAB_COMMANDS = {
    "import-xbench": "import scripts/perf-bench/baseline xbench results as legacy vs-browsers points (shown, never judged)",
}

# legacy_median_only: the point is the nightly's median of its runs, with no raw samples. legacy_stat: the statistic
# came from xbench's own aggregate, not from perf_stats over raw samples, so no lab rule may compare it.
LEGACY_FLAGS = ("legacy_median_only", "legacy_stat")
LEGACY_MEASURE_VERSION = "legacy-xbench"  # alerts.judged_points skips a "legacy" measure version
LEGACY_HOST_PREFIX = "xbench:"
# A cmux arm the import keeps measured `reload.sh --config release` of cmux_ref (cmux=build); the
# matrix rows of its Debug arm (`cmux-debug`, xbench.TAB_SWITCH_BROWSER) came from a tagged Debug build.
LEGACY_CONFIG = "release"
DEBUG_ARM_CONFIG = "debug"
# The engine of the Debug arm's rows: they switch between tabs of several kinds, not pages of one engine.
DEBUG_ARM_ENGINE = "none"
LEGACY_SESSION = "light"
# How a report's browsers block shows the nightly-next binary: fetch_browsers.py's cmux-nightly cache folder and the
# nightly's CFBundleShortVersionString (1.0.0-nightly.3946367535401).
NIGHTLY_BUNDLE = "/cmux-nightly/"
NIGHTLY_VERSION = "-nightly."
STORY_TIER = "T2"


def xbench():
    """scripts/perf-bench/xbench.py, the owner of the metric names, units and arm engines."""
    return _sibling("xbench", XBENCH)


def baseline_files(directory: Path = BASELINE_DIR) -> list[Path]:
    """The xbench reports in `directory`: JSON files with a `machine` and a `rows` object, in name order."""
    found = []
    for path in sorted(directory.glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            found.append(path)  # unreadable: the import names it as rejected
            continue
        if isinstance(doc, dict) and isinstance(doc.get("machine"), dict) and isinstance(doc.get("rows"), dict):
            found.append(path)
    return found


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return float(value)


def _host(machine: dict) -> ingest.LabHost:
    """The legacy host of a report's `machine` block: its class names the chip, memory and Hz under `xbench:`."""
    chip, memory = machine.get("chip"), machine.get("ram_gb")
    displays = (machine.get("displays") or {}).get("displays") or []
    hz = _number(displays[0].get("hz")) if displays and isinstance(displays[0], dict) else None
    if not isinstance(chip, str) or not chip or isinstance(memory, bool) or not isinstance(memory, int) or not hz:
        raise ingest._Reject("machine names no chip, ram_gb or display Hz")
    name = machine.get("host") if isinstance(machine.get("host"), str) and machine.get("host") else "unknown"
    lab_class = LEGACY_HOST_PREFIX + store.host_class(chip=chip, memory_gb=memory, display_hz=int(round(hz)))
    return ingest.LabHost(name=name, chip=chip, memory_gb=memory, display_hz=int(round(hz)),
                          fingerprint=f"{lab_class}:{name}", declared_class=lab_class)


def _summary(cell: dict, factor: float) -> dict[str, object] | None:
    median = _number(cell.get("median")) if isinstance(cell, dict) else None
    if median is None:
        return None
    summary: dict[str, object] = {"p50": median * factor}
    for key in ("min", "max"):
        value = _number(cell.get(key))
        if value is not None:
            summary[key] = value * factor
    if isinstance(cell.get("n"), int) and not isinstance(cell.get("n"), bool):
        summary["n"] = cell["n"]
    return {**summary, **dict.fromkeys(LEGACY_FLAGS, True)}


def _known_row(row: str) -> bool:
    return row in xbench().ROW_INFO or row.startswith(("tab-switch-", "palette-open-"))


def _measured(rows: dict, browser: str) -> bool:
    """Whether an arm has a median in any row (an arm that measured nothing is neither stored nor refused)."""
    return any(isinstance(per, dict) and _summary(per.get(browser), 1.0) is not None for per in rows.values())


def arm_metrics(rows: dict, browser: str, versions: dict[str, str]) -> list[store.Metric]:
    """The legacy metrics of one browser arm of a report's `rows` ({row: {browser: {median, min, max, n}}});
    `versions` is each vendor arm's version (report_versions). A cmux arm has ratios only when Chrome's version
    is known."""
    xb = xbench()
    reference = xb.REFERENCE_ARM if browser in xb.CMUX and xb.REFERENCE_ARM in versions else None
    metrics = []
    for row in sorted(rows):
        per = rows[row]
        if not isinstance(per, dict) or not _known_row(row) or browser not in per:
            continue
        unit, factor = xb.result_unit(row)
        summary = _summary(per[browser], factor)
        if summary is None:
            continue
        name = xb.result_metric(browser, row, versions)
        metrics.append(store.Metric(name=name, unit=unit, better="lower", samples=[], summary=summary))
        ref = _summary(per.get(reference), factor) if reference else None
        if ref and ref["p50"] > 0:
            metrics.append(store.Metric(name=f"{name}.vs-{xb.arm_name(reference, versions)}", unit="ratio",
                                        better="lower", samples=[],
                                        summary={"p50": summary["p50"] / ref["p50"],
                                                 **dict.fromkeys(LEGACY_FLAGS, True)}))
    return metrics


def report_versions(doc: dict) -> dict[str, str]:
    """{browser: version} of the vendor arms whose version the report's `browsers` block names (xbench Browser.info)."""
    xb = xbench()
    browsers = doc.get("browsers") if isinstance(doc.get("browsers"), dict) else {}
    versions = {}
    for browser, info in browsers.items():
        version = info.get("version") if isinstance(info, dict) else None
        if browser in xb.VENDORS and isinstance(version, str) and xb.VENDOR_VERSION.fullmatch(version):
            versions[browser] = version
    return versions


def arm_refusal(doc: dict, browser: str, versions: dict[str, str]) -> str | None:
    """Why an arm of a report is not a point of its `cmux_ref`, or None. The Debug matrix arm is a build of the
    checkout (perf-bench.sh reload.sh --tag pbswitch); every other cmux arm must name its bundle, and a nightly-next
    bundle is not a build of the checkout. A vendor arm must name its version."""
    xb = xbench()
    if browser == xb.TAB_SWITCH_BROWSER:
        return None
    if browser not in xb.ENGINES:
        return f"{browser} is not an xbench browser"
    if browser not in xb.CMUX:
        return None if browser in versions else f"{browser}: the report's browsers block names no version of it"
    info = (doc.get("browsers") or {}).get(browser) if isinstance(doc.get("browsers"), dict) else None
    bundle = info.get("bundle") if isinstance(info, dict) else None
    if not isinstance(bundle, str) or not bundle:
        return f"{browser}: the report's browsers block names no bundle, so no commit names what it measured"
    version = str(info.get("version") or "")
    if NIGHTLY_BUNDLE in bundle or NIGHTLY_VERSION in version:
        return (f"{browser} ran the nightly-next binary {version or bundle}, not a build of cmux_ref "
                f"{doc.get('cmux_ref')}; no lab build config is that binary")
    return None


def _arm(browser: str) -> tuple[str, str]:
    """(engine, build config) of a report's browser arm."""
    xb = xbench()
    if browser == xb.TAB_SWITCH_BROWSER:
        return DEBUG_ARM_ENGINE, DEBUG_ARM_CONFIG
    return xb.ENGINES[browser], LEGACY_CONFIG


def report_points(doc: object, stem: str, *, commit_positions: ingest.CommitPositions):
    """(source suffix, run, build, host, metrics) of every arm of one report; raises ingest._Reject for the file."""
    if not isinstance(doc, dict) or not isinstance(doc.get("rows"), dict) or not isinstance(doc.get("machine"), dict):
        raise ingest._Reject("not an xbench report: no machine and rows objects")
    sha = doc.get("cmux_ref")
    if not isinstance(sha, str) or not re.fullmatch(perf_result.SHA_PATTERN, sha):
        raise ingest._Reject(f"cmux_ref {sha!r} is not a full commit sha")
    try:
        started = datetime.strptime(str(doc.get("date")), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        raise ingest._Reject(f"date {doc.get('date')!r} is not YYYY-MM-DD") from None
    machine = doc["machine"]
    host = _host(machine)
    macos = str(machine.get("macos") or "")
    major = int(macos.split(".")[0]) if macos.split(".")[0].isdigit() else 0
    position = ingest._position(commit_positions, sha, waterfall=True, again="import again")
    xb = xbench()
    arms = sorted({browser for per in doc["rows"].values() if isinstance(per, dict) for browser in per})
    versions = report_versions(doc)
    points = []
    for browser in arms:
        refusal = arm_refusal(doc, browser, versions)
        if refusal and _measured(doc["rows"], browser):
            points.append((browser, None, refusal))
        metrics = [] if refusal else arm_metrics(doc["rows"], browser, versions)
        if not metrics:
            continue
        engine, config = _arm(browser)
        run = store.Run(run_uuid=f"xbench:{stem}:{browser}", kind="waterfall", measure_version=LEGACY_MEASURE_VERSION,
                        story=xb.STORY, engine=engine, macos_major=major,
                        macos_build=str(machine.get("build") or ""), features_hash="", safe_mode="",
                        started_at=started, tier=STORY_TIER, session=LEGACY_SESSION)
        points.append((browser, (run, store.Build(sha=sha, config=config, commit_pos=position), host, metrics), None))
    return points


def import_xbench(db: store.Store, paths: Sequence[Path | str], *,
                  commit_positions: ingest.CommitPositions) -> ingest.IngestReport:
    """Stores every arm of every report in `paths` as legacy points; returns what was stored or refused."""
    report = ingest.IngestReport()
    for path in map(Path, paths):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            report.rejected.append(ingest.Rejection(str(path), f"cannot read: {error}"))
            continue
        try:
            points = report_points(doc, path.stem, commit_positions=commit_positions)
        except ingest._Reject as reason:
            report.rejected.append(ingest.Rejection(str(path), str(reason)))
            continue
        for browser, records, refused in points:
            where = f"{path} {browser}"
            if refused:
                report.rejected.append(ingest.Rejection(where, refused))
            else:
                ingest._insert(db, report, where, *records)
    return report


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", default=os.environ.get(ingest.DB_ENV),
                        help=f"the lab store (SQLite); default ${ingest.DB_ENV}")
    parser.add_argument("--repo", default=str(ROOT), help="git checkout that resolves commit positions")
    parser.add_argument("--mainline", default=ingest.DEFAULT_MAINLINE,
                        help=f"the ref whose first-parent chain orders the points (default {ingest.DEFAULT_MAINLINE})")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("paths", nargs="*", help=f"xbench results.json files (default: the reports in {BASELINE_DIR})")


def run(command: str, args: argparse.Namespace) -> int:
    """Exit 0 when everything was stored (or already was), 1 when anything was rejected, 2 when nothing could run."""
    if not args.db:
        print(f"lab.py {command}: --db or ${ingest.DB_ENV} names the lab store", file=sys.stderr)
        return 2
    try:
        positions = ingest.GitCommitPositions(args.repo, mainline=args.mainline)
        db = store.Store(args.db)
    except (ingest.IngestError, store.StoreError, sqlite3.Error) as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2
    try:
        db.migrate()
        report = import_xbench(db, args.paths or baseline_files(), commit_positions=positions)
    except (store.StoreError, sqlite3.Error) as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2
    finally:
        db.close()
    ingest._print(report, args.json)
    return 1 if report.rejected else 0
