#!/usr/bin/env python3
"""Warm-state distance: what a compile admission starts from, what it costs, and a model to route by.

    warm_distance.py admission STORE            append this admission's line, print its summary
    warm_distance.py fit DATA.jsonl... [--out MODEL] [--rows]
    warm_distance.py evaluate DATA.jsonl... [--model MODEL]
    warm_distance.py refit DATA.jsonl... [--model MODEL] [--out MODEL] [--days 14]
    warm_distance.py backtest DATA.jsonl... [--model MODEL] [--every-hours 24] [--days 14]
    warm_distance.py collect HOST...            every mini's admissions.jsonl, over SSH, to stdout

An owned mini keeps compile admission's DerivedData (owned_build_state.py),
and what a compile costs depends on how far its start (the kept build, or a
seed) is from the tree it builds. Measured on 142 owned admissions on
2026-09-25 (cmuxterm-hq#661 WS6): starting within 5 app Swift files of the
build never recompiled the `cmux` module (0 of 21), 6 or more did in 26 of
40, and so did any change to an imported package's interface (about 2,700
`cmux` files) and to in-module types most files use (AppDelegate,
Workspace, cmuxApp). Commit counts and the kept record's changed inputs
predicted it badly. An avoided rebuild saves about 220 s of wall time.

Distance is counted in app Swift files: changed `.swift` files outside
tests (any `/Tests/`, cmuxTests/, cmuxUITests/). A package Swift file is one
under PACKAGE_SOURCES; a package change is an interface change when a changed
line declares something `public`, `open` or `package`, or `@inlinable` /
`@usableFromInline` code, which every importer sees. A hot file is one the
model lists (HOT_FILES, refit from the data).

Record. owned_build_state.py `record` compares the digests of the tree it is
about to compile with the record the adopted DerivedData carries (the kept
build's own record, or the seed's manifest) and writes the changed paths to
CMUX_WARM_DISTANCE_START: the exact distance, at no cost, since the record is
computed anyway. `admission` runs at the end of every owned admission and
appends one JSON line to STORE/admissions.jsonl with the pull request, head,
merge base, the start (kept build, seed or cold), the distance features, the
SwiftCompile units per target from the build log, whether the `cmux` module
was rebuilt (APP_REBUILD_UNITS or more units), compile, admission and queue
seconds, the runner and root, and the routing decisions (the picker's pin and
glaeda's root choice). It also stamps the kept build with this pull
request's own app Swift files, which glaeda's hook needs to tell how far that
build is from the next job, and copies the model next to the stamps for the
hook. Everything is best effort and bounded: it never fails the job.

Model. `fit` reads admission lines (these, or the backfill of 09-25/26 job
logs) and fits tiers, each a p50/p90 compile time:

- near: at most NEAR_APP_SWIFT_FILES app Swift files, no package interface
  change, no hot file;
- far: more files, or a hot file, no package interface change;
- package: a package interface change (unknown counts as one).

It also fits the start classes the picker can see before the job starts
(start_classes: a kept build of the same merge base, of the same pull
request, or anything else, by the pull request's own tier) and job lengths
per glaeda job class (job_seconds) for the picker's wait estimate, and each
tier's p50 per start kind (tiers_by_start, with counts): a near compile from
a kept build costs about 90 s, one from a seed about 155 s. predict() uses a
start's cell once it has MIN_START_ROWS compiles, else the tier, and so does
glaeda's hook for a root's kept build. `refit` refits only the tiers and
cells from recent admissions, `backtest` replays them in time order, and
warm_model_refit.py runs both daily and proposes a drifted model as a pull
request. The model is scripts/ci/warm-distance-model.json; refit all of it with

    python3 scripts/ci/warm_distance.py collect cmux14 cmux8s-mac-mini ... > data.jsonl
    python3 scripts/ci/warm_distance.py fit data.jsonl --out scripts/ci/warm-distance-model.json
"""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import io
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time
from typing import Any, Callable, Iterable, Mapping, Sequence

MODEL_PATH = Path(__file__).resolve().with_name("warm-distance-model.json")
LOG_NAME = "admissions.jsonl"
# The copy glaeda-cmux-runner-hook reads (its WARM_MODEL): beside root 1's stamp.
HOOK_MODEL_NAME = "warm-distance-model.json"
LOG_MAX_BYTES = 8 * 1024 * 1024
PACKAGE_SOURCES = ("Packages/", "vendor/", "Examples/")
NOT_APP_SOURCES = ("cmuxTests/", "cmuxUITests/")
NEAR_APP_SWIFT_FILES = 5
# The `cmux` target compiles about 2,700 Swift files; an incremental build a few hundred.
APP_REBUILD_UNITS = 1000
# Files whose change recompiles the `cmux` module without any package change; `fit` learns them
# (HOT_MIN_REBUILDS and HOT_MIN_SHARE). AppDelegate, Workspace and cmuxApp alone did not (09-25/26).
DEFAULT_HOT_FILES: tuple[str, ...] = ()
HOT_MIN_REBUILDS = 3
HOT_MIN_SHARE = 0.6
# A changed line that changes what an importer of the package sees.
INTERFACE_LINE = re.compile(
    r"^[+-](?![+-])\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|open|package)\b|@inlinable\b|@usableFromInline\b|@_exported\b)")
# xcodebuild escapes the space after "Compiling" ("Compiling\\ A.swift /abs/A.swift (in target 'cmux' ...)").
SWIFT_COMPILE = re.compile(r"^SwiftCompile \S+ \S+ Compiling\\? (.*?) \(in target '([^']*)'")
TIERS = ("near", "far", "rebuild")
# A (tier, start kind) cell of tiers_by_start predicts once it has this many compiles; glaeda's hook uses the same.
MIN_START_ROWS = 5
# Paths kept per record: enough for any near start, bounded for a far one.
MAX_PATHS = 400


def app_swift(path: str) -> bool:
    return path.endswith(".swift") and "/Tests/" not in path and not path.startswith(NOT_APP_SOURCES)


def package_swift(path: str) -> bool:
    return app_swift(path) and path.startswith(PACKAGE_SOURCES)


def interface_change(diff: str) -> bool:
    return any(INTERFACE_LINE.match(line) for line in diff.splitlines())


def features(paths: Iterable[str], interface: bool | None = None,
             hot_files: Iterable[str] = DEFAULT_HOT_FILES) -> dict[str, Any]:
    """The distance features of a set of changed paths.

    `interface` says whether the package changes among them change an
    interface (None: unknown); it is False when no package source changed.
    """
    app = sorted({path for path in paths if app_swift(path)})
    package = [path for path in app if package_swift(path)]
    hot = sorted(set(app) & set(hot_files))
    return {
        "app_swift_files": len(app),
        "package_swift_files": len(package),
        "package_interface": (interface if package else False),
        "hot_files": hot,
    }


def tier(feature: Mapping[str, Any], model: Mapping[str, Any] | None = None) -> str:
    near = int((model or {}).get("near_app_swift_files") or NEAR_APP_SWIFT_FILES)
    if feature.get("package_swift_files") and feature.get("package_interface") is not False:
        return "rebuild"
    if feature.get("hot_files"):
        return "rebuild"
    return "far" if int(feature.get("app_swift_files") or 0) > near else "near"


def load_model(path: Path | str | None = None) -> dict[str, Any]:
    try:
        model = json.loads(Path(path or MODEL_PATH).read_text())
    except (OSError, ValueError):
        return {}
    return model if isinstance(model, dict) else {}


def seconds_of(entry: Any) -> float | None:
    """A fitted entry's p50, when it is a positive finite number."""
    value = entry.get("p50") if isinstance(entry, Mapping) else None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        return None
    return float(value)


def tier_seconds(name: str, start: str | None, model: Mapping[str, Any]) -> float | None:
    """The predicted compile of tier NAME from a START kind ('kept', 'seed', ...): the (tier, start) cell's
    p50 once it has MIN_START_ROWS rows, else the tier's p50 (models before tiers_by_start have only that)."""
    if start:
        cells = (model.get("tiers_by_start") or {}).get(name)
        entry = cells.get(start) if isinstance(cells, Mapping) else None
        count = entry.get("n") if isinstance(entry, Mapping) else None
        if isinstance(count, int) and count >= MIN_START_ROWS and seconds_of(entry) is not None:
            return seconds_of(entry)
    return seconds_of((model.get("tiers") or {}).get(name))


def predict(feature: Mapping[str, Any], model: Mapping[str, Any], start: str | None = None) -> tuple[str, float | None]:
    """(tier, predicted compile seconds) for these distance features from a START kind; None without a model."""
    name = tier(feature, model)
    return name, tier_seconds(name, start, model)


def start_class_seconds(start: str, job_tier: str, model: Mapping[str, Any]) -> float | None:
    """The picker's predicted compile for a start class ('base', 'pr', 'none') and the job's own tier."""
    classes = model.get("start_classes") or {}
    entry = classes.get(start) or {}
    cell = (entry.get("by_job_tier") or {}).get(job_tier) or {}
    for value in (cell.get("expected"), entry.get("expected")):
        if isinstance(value, (int, float)):
            return float(value)
    return None


# Recording --------------------------------------------------------------------------------------------------


def start_distance(current: Mapping[str, list], start: Mapping[str, list] | None, changed: set[str] | None,
                   out: Path) -> None:
    """Write the start's distance for `admission`: the changed Swift paths between the two records."""
    if start is None or changed is None:
        document: dict[str, Any] = {"start": "cold"}
    else:
        swift = sorted(path for path in changed if app_swift(path))
        # Package paths first, so a cap never hides a package change.
        kept = sorted(swift, key=lambda path: not package_swift(path))[:MAX_PATHS]
        document = {"start": "warm", "changed_inputs": len(changed),
                    "swift_paths": sorted(kept), "swift_paths_total": len(swift)}
    out.parent.mkdir(parents=True, exist_ok=True)
    incoming = out.with_name(f".{out.name}.{os.getpid()}")
    incoming.write_text(json.dumps(document, sort_keys=True))
    incoming.rename(out)


# Every git call of one admission record or picker decision shares this deadline (time.monotonic()), so
# the step never approaches its timeout; a call past it answers None (unknown), never an error.
_deadline: list[float] = [float("inf")]
GIT_TIMEOUT_SECONDS = 10
FETCH_TIMEOUT_SECONDS = 20
RECORD_BUDGET_SECONDS = 60
PICKER_BUDGET_SECONDS = 8


def git(workspace: Path, *args: str, timeout: float = GIT_TIMEOUT_SECONDS) -> str | None:
    env = {**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0"}
    timeout = min(timeout, _deadline[0] - time.monotonic())
    if timeout <= 0:
        return None
    try:
        result = subprocess.run(["git", "-C", str(workspace), *args], capture_output=True, text=True,
                                timeout=timeout, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def have_commit(workspace: Path, sha: str) -> bool:
    return bool(sha) and git(workspace, "cat-file", "-e", f"{sha}^{{commit}}") is not None


def ensure_commit(workspace: Path, sha: str) -> bool:
    """SHA's commit and trees in the checkout, fetched shallow (public, no credentials) when missing."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
        return False
    if have_commit(workspace, sha):
        return True
    git(workspace, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--depth=1", "origin", sha,
        timeout=FETCH_TIMEOUT_SECONDS)
    return have_commit(workspace, sha)


def diff_interface(workspace: Path, old: str, new: str, paths: Sequence[str]) -> bool | None:
    """Whether the package PATHS changed an interface between two commits; None when git cannot say."""
    if not paths:
        return False
    text = git(workspace, "diff", "-U0", "--no-color", "--no-ext-diff", old, new, "--", *paths)
    return None if text is None else interface_change(text)


def pull_request_files(workspace: Path, base: str, fetch: bool = True) -> tuple[list[str], bool | None] | None:
    """This build's own app Swift files against its merge base, and whether a package interface changed.

    FETCH fetches a missing base (compile admission's depth-1 checkout); the
    picker's depth-2 checkout has it, and must not wait on a fetch.
    """
    if not (ensure_commit(workspace, base) if fetch else have_commit(workspace, base)):
        return None
    names = git(workspace, "diff", "--name-only", "--no-renames", base, "HEAD")
    if names is None:
        return None
    files = sorted(path for path in names.split("\n") if app_swift(path))
    packages = [path for path in files if package_swift(path)]
    return files, diff_interface(workspace, base, "HEAD", packages)


def swift_units(log: Path) -> dict[str, int]:
    """SwiftCompile units per target in an xcodebuild log (a batch line counts each file it names)."""
    units: dict[str, int] = {}
    try:
        handle = log.open(errors="replace")
    except OSError:
        return units
    with handle:
        for line in handle:
            match = SWIFT_COMPILE.match(line)
            if match:
                # "Compiling A.swift, B.swift /abs/A.swift /abs/B.swift": the names before the paths.
                files = match.group(1).split(" /")[0].count(",") + 1
                units[match.group(2)] = units.get(match.group(2), 0) + files
    return units


def number(value: Any) -> float | None:
    try:
        return round(float(value), 3) if value not in (None, "") else None
    except (TypeError, ValueError):
        return None


def append_line(log: Path, record: Mapping[str, Any]) -> None:
    """Append one line under a lock; the file is rotated once past LOG_MAX_BYTES (one old copy kept)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log.with_name(f".{log.name}.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with contextlib.suppress(OSError):
            if log.stat().st_size > LOG_MAX_BYTES:
                log.replace(log.with_name(log.name + ".1"))
        with open(log, "a") as handle:
            handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def fleet_dir(store: Path) -> Path:
    """Root 1's store (the mini's ci directory) for any root's: the one log and model copy per mini."""
    return store.parent if re.fullmatch(r"cmux-ci-[0-9]{1,2}", store.name) else store


def share_model(store: Path, model_path: Path = MODEL_PATH) -> None:
    """Copy the model beside the stamps for glaeda's hook, when it changed."""
    try:
        text = model_path.read_text()
        target = store / HOOK_MODEL_NAME
        if target.is_file() and target.read_text() == text:
            return
        incoming = store / f".{HOOK_MODEL_NAME}.{os.getpid()}"
        incoming.write_text(text)
        incoming.rename(target)
    except OSError:
        pass


def stamp_pull_request(store: Path, files: Sequence[str], interface: bool | None, hot_files: Iterable[str]) -> None:
    """Add this build's own diff to its stamp (owned_build_state.py `keep` wrote it just before)."""
    stamp_path = store / "stamp.json"
    try:
        stamp = json.loads(stamp_path.read_text())
    except (OSError, ValueError):
        return
    if not isinstance(stamp, dict):
        return
    stamp["pr_app_swift_files"] = list(files[:MAX_PATHS])
    stamp["pr_app_swift_total"] = len(files)
    stamp["pr_package_interface"] = interface
    stamp["pr_hot_files"] = sorted(set(files) & set(hot_files))
    incoming = store / f".stamp.json.{os.getpid()}"
    incoming.write_text(json.dumps(stamp, sort_keys=True))
    incoming.rename(stamp_path)


def admission(store: Path, env: Mapping[str, str], workspace: Path, now: Callable[[], dt.datetime]) -> dict[str, Any]:
    _deadline[0] = time.monotonic() + RECORD_BUDGET_SECONDS
    model = load_model()
    hot_files = model.get("hot_files") or DEFAULT_HOT_FILES
    base = (env.get("MERGED_ONTO") or "").strip().lower()
    start_doc: dict[str, Any] = {}
    with contextlib.suppress(OSError, ValueError):
        start_doc = json.loads(Path(env.get("CMUX_WARM_DISTANCE_START") or "/nonexistent").read_text())
    seed_key = env.get("SEED_KEY", "") if env.get("SEED_HIT") == "true" else ""
    kept = env.get("OWNED_ADOPT_HIT") == "true" and not seed_key
    start_stamp: dict[str, Any] = {}
    with contextlib.suppress(OSError, ValueError):
        start_stamp = json.loads(Path(env.get("CMUX_WARM_START_STAMP") or "/nonexistent").read_text())
    if start_doc.get("start") != "warm":
        start = {"kind": "cold"}
    elif seed_key:
        start = {"kind": "seed", "key": seed_key, "commit": seed_key.rsplit("-", 1)[-1],
                 "local": env.get("SEED_LOCAL", "")}
    elif kept:
        start = {"kind": "kept", "merged_onto": start_stamp.get("merged_onto"), "pr": start_stamp.get("pr")}
    else:
        start = {"kind": "unknown"}
    distance: dict[str, Any] = {}
    if start_doc.get("start") == "warm":
        paths = start_doc.get("swift_paths") or []
        packages = [path for path in paths if package_swift(path)]
        interface: bool | None = None
        if not packages:
            interface = False
        else:
            old = start.get("commit") or start.get("merged_onto") or ""
            if ensure_commit(workspace, str(old)):
                interface = diff_interface(workspace, str(old), "HEAD", packages)
                # A kept build's own package change is undone here, and main's diff does not show it.
                undone = set(packages) & set(start_stamp.get("pr_app_swift_files") or [])
                if (start["kind"] == "kept" and interface is False and undone
                        and start_stamp.get("pr_package_interface") is not False):
                    interface = start_stamp.get("pr_package_interface")
        distance = features(paths, interface, hot_files)
        distance["paths"] = sorted(path for path in paths if app_swift(path))[:MAX_PATHS]
        distance["changed_inputs"] = start_doc.get("changed_inputs")
        if start_doc.get("swift_paths_total", 0) > len(paths):
            distance["app_swift_files_lower_bound"] = True
        distance["commits_behind"] = number(env.get("SEED_DISTANCE")) if seed_key else None
        if start["kind"] == "kept":
            distance["same_base"] = bool(base) and base == str(start.get("merged_onto") or "")
            distance["same_pr"] = str(start.get("pr") or "") == (env.get("PR_NUMBER") or "").strip()
    own = pull_request_files(workspace, base) if base else None
    units: dict[str, int] = {}
    logs = Path(env.get("BUILD_LOGS") or "/nonexistent")
    found = sorted(logs.glob("*-build.log")) if logs.is_dir() else []
    for log in found:
        for target, count in swift_units(log).items():
            units[target] = units.get(target, 0) + count
    metrics: dict[str, Any] = {}
    with contextlib.suppress(OSError, ValueError):
        metrics = json.loads(Path(env.get("METRICS") or "/nonexistent").read_text())
    compiled = env.get("COMPILE_OUTCOME") == "success"
    predicted = predict(distance, model, start["kind"]) if distance else (None, None)
    record = {
        "schema": "cmux-warm-admission/v1",
        "at": now().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id": env.get("GITHUB_RUN_ID"), "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "job": env.get("GITHUB_JOB"), "event": env.get("GITHUB_EVENT_NAME"),
        "pr": int(env["PR_NUMBER"]) if (env.get("PR_NUMBER") or "").isdigit() else None,
        "head_sha": env.get("HEAD_SHA") or None, "sha": env.get("GITHUB_SHA"), "merged_onto": base or None,
        "runner": env.get("RUNNER_NAME"), "root": env.get("CMUX_CI_CANONICAL_ROOT") or "/private/tmp/cmux-ci",
        "start": start, "distance": distance or None,
        "own": {**features(own[0], own[1], hot_files), "paths": own[0][:MAX_PATHS]} if own else None,
        "swift_units": units, "swift_units_total": sum(units.values()),
        # No build log: unknown. A log without SwiftCompile lines compiled no Swift at all.
        "app_rebuilt": units.get("cmux", 0) >= APP_REBUILD_UNITS if found else None,
        "compile_outcome": env.get("COMPILE_OUTCOME"),
        "compile_seconds": number(metrics.get("compile_duration_seconds")) if compiled else None,
        "admission_seconds": number(metrics.get("total_macos_compile_admission_seconds")),
        "queue_seconds": number(metrics.get("queue_to_start_seconds")),
        "tier": predicted[0], "predicted_seconds": predicted[1], "model_fitted_at": model.get("fitted_at"),
        "route": {
            "admission_runner": env.get("ADMISSION_RUNNER") or None,
            "placement": env.get("PLACEMENT") or None,
            "hook": env.get("GLAEDA_WARM_ROUTE") or None,
        },
    }
    _deadline[0] = float("inf")
    append_line(fleet_dir(store) / LOG_NAME, record)
    share_model(fleet_dir(store))
    if own is not None and env.get("KEPT") == "true":
        stamp_pull_request(store, own[0], own[1], hot_files)
    return record


def summary_line(record: Mapping[str, Any]) -> str:
    start = record.get("start") or {}
    distance = record.get("distance") or {}
    what = start.get("kind", "cold")
    if what == "seed":
        what += f" {str(start.get('commit') or '')[:12]}"
    elif what == "kept":
        what += f" {str(start.get('merged_onto') or '')[:12]} pr-{start.get('pr')}"
    parts = [f"start: {what}"]
    if distance:
        parts.append(f"{distance.get('app_swift_files')} app Swift files, {distance.get('package_swift_files')} package "
                     f"(interface: {distance.get('package_interface')}), hot: {', '.join(distance.get('hot_files') or []) or 'none'}")
    parts.append(f"tier {record.get('tier')}, predicted {record.get('predicted_seconds')} s, "
                 f"compiled {record.get('compile_seconds')} s ({record.get('swift_units_total')} Swift units, "
                 f"app {'rebuilt' if record.get('app_rebuilt') else 'kept'})")
    return "Warm distance: " + "; ".join(parts)


# Routing (pr_runner_pool.py) ---------------------------------------------------------------------------------

# Wait for a busy warm runner only this long, and only when the rescue budget covers it: a CI run's
# attempt-1 owned job may wait CI_OWNED_POOL_RESCUE_SECONDS plus QUEUE_ROUND_SECONDS per queue round
# before ci-owned-pool-rescue.yml moves it (owned_pool_rescue.queue_seconds()).
MAX_ROUTED_WAIT_SECONDS = 600
QUEUE_ROUND_SECONDS = 900
# A pin must beat the unpinned root label by this much; below it, placement noise decides.
ROUTE_MARGIN_SECONDS = 30
UNKNOWN_JOB_SECONDS = 600.0


def job_key(name: str) -> str:
    """A GitHub job display name as glaeda's job telemetry keys it: `macOS / app-host unit tests (3)` ->
    `app-host-unit-tests`."""
    name = name.rsplit(" / ", 1)[-1]
    name = re.sub(r"\s*\([^)]*\)\s*$", "", name)
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def remaining_seconds(entry: Mapping[str, Any] | None, model: Mapping[str, Any], now: dt.datetime) -> float | None:
    """How long a busy runner's current job still runs: its class's p50 less the time it has run (the
    p90 once it passed the p50), at least a minute. None when unknown: no entry, a job the model has no
    length for, or one past its p90 (it may hang)."""
    if not isinstance(entry, Mapping):
        return None
    lengths = (model.get("job_seconds") or {}).get(job_key(str(entry.get("job") or ""))) or {}
    p50, p90 = lengths.get("p50"), lengths.get("p90")
    try:
        started = dt.datetime.fromisoformat(str(entry.get("started_at")).replace("Z", "+00:00"))
    except ValueError:
        started = None
    if not isinstance(p50, (int, float)) or started is None:
        return None
    ran = max(0.0, (now - started).total_seconds())
    left = p50 - ran if ran < p50 else (p90 if isinstance(p90, (int, float)) else p50) - ran
    return max(60.0, left) if left > 0 else None


def routed_wait_limit(queue_rounds: int | None) -> int:
    """The longest wait for a busy warm runner the rescue budget covers (0: idle runners only)."""
    return min(MAX_ROUTED_WAIT_SECONDS, max(0, queue_rounds or 0) * QUEUE_ROUND_SECONDS)


def route_admission(runners: Sequence[Mapping[str, Any]], root: str, *, base_warm: Iterable[str],
                    pr_warm: Iterable[str], running: Mapping[str, Any], job_tier: str,
                    model: Mapping[str, Any], now: dt.datetime, max_wait: float,
                    runner_label: Callable[[str], str]) -> tuple[str, dict[str, Any]]:
    """The root runner whose expected wait plus predicted compile is lowest, if it beats the unpinned root label.

    A candidate is an online `root` runner carrying its own label, warm for
    this run: its keys hold the merge base (`base_warm`) or this pull request
    (`pr_warm`). Its cost is its expected wait (0 when idle, else what its
    current job has left, remaining_seconds(); a busy one whose wait is
    unknown or not under `max_wait` is skipped) plus the compile predicted for
    its start class, by this pull request's own tier (start_class_seconds()).
    The unpinned root label goes to any idle root runner at the 'none' cost,
    or, when every online root runner is busy, also waits for the first to
    finish (UNKNOWN_JOB_SECONDS when none is known). Returns the runner name
    ("" to leave the root label) and the costs, for the log.
    """
    base_warm, pr_warm = set(base_warm), set(pr_warm)
    cold = start_class_seconds("none", job_tier, model)
    decision: dict[str, Any] = {"job_tier": job_tier, "none_seconds": cold, "candidates": []}
    if cold is None:
        decision["why"] = "no model"
        return "", decision
    waits: list[float | None] = []
    pinnable: list[tuple[str, float | None]] = []
    for runner in runners:
        name = str(runner.get("name") or "")
        labels = {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}
        if runner.get("status") != "online" or not name or root not in labels:
            continue
        wait = 0.0 if not runner.get("busy") else remaining_seconds(running.get(name), model, now)
        waits.append(wait)
        if runner_label(name) in labels:
            pinnable.append((name, wait))
    if not waits:
        decision["why"] = "no online root runner"
        return "", decision
    if 0.0 in waits:
        baseline = cold
    else:
        baseline = cold + min((wait for wait in waits if wait is not None), default=UNKNOWN_JOB_SECONDS)
    decision["baseline_seconds"] = round(baseline, 1)
    best: tuple[float, str] | None = None
    for name, wait in pinnable:
        start = "base" if name in base_warm else "pr" if name in pr_warm else ""
        compile_seconds = start_class_seconds(start, job_tier, model) if start else None
        if compile_seconds is None:
            continue
        cost = None if wait is None else wait + compile_seconds
        decision["candidates"].append({"runner": name, "start": start, "wait": wait,
                                       "compile": compile_seconds, "cost": cost})
        if wait is not None and (wait == 0 or wait < max_wait) and cost is not None \
                and (best is None or cost < best[0]):
            best = (cost, name)
    if best is None:
        decision["why"] = "no warm runner idle or with a known wait within the limit"
        return "", decision
    if best[0] + ROUTE_MARGIN_SECONDS > baseline:
        decision["why"] = f"the best warm runner ({best[0]:.0f} s) does not beat the root label ({baseline:.0f} s)"
        return "", decision
    decision["why"] = f"{best[1]}: {best[0]:.0f} s against {baseline:.0f} s on the root label"
    return best[1], decision


def picker_route(runners: Sequence[Mapping[str, Any]], root: str, *, merged_onto: str | None,
                 pr_number: str | None, snapshot: Mapping[str, Any], workspace: Path, queue_rounds: int | None,
                 now: dt.datetime, warm_key: Callable[[str | None], str],
                 runner_label: Callable[[str], str], model: Mapping[str, Any] | None = None) -> tuple[str, dict[str, Any]]:
    """pr_runner_pool.py's admission pin: route_admission() over the snapshot's `warm` and `running`.

    The pull request's own tier comes from the checkout (the merge commit and
    its first parent, ci.yml's depth-2 checkout); without it the start
    classes' overall p50s decide. Returns admission's runs-on JSON ("" for
    the root label) and the decision.
    """
    model = load_model() if model is None else model
    warm = snapshot.get("warm") if isinstance(snapshot.get("warm"), Mapping) else {}
    kept = warm.get("runners") if isinstance(warm.get("runners"), Mapping) else {}
    base_key, pr_key = warm_key(merged_onto), warm_key(f"pr-{(pr_number or '').strip()}")

    def holding(key: str) -> set[str]:
        return {str(name) for name, entry in kept.items()
                if key and isinstance(entry, Mapping) and key in (entry.get("keys") or [])}

    _deadline[0] = time.monotonic() + PICKER_BUDGET_SECONDS
    try:
        own = pull_request_files(workspace, (merged_onto or "").strip().lower(), fetch=False) if merged_onto else None
    finally:
        _deadline[0] = float("inf")
    job_tier = tier(features(own[0], own[1], model.get("hot_files") or DEFAULT_HOT_FILES), model) if own else ""
    running = snapshot.get("running") if isinstance(snapshot.get("running"), Mapping) else {}
    name, decision = route_admission(runners, root, base_warm=holding(base_key), pr_warm=holding(pr_key),
                                     running=running, job_tier=job_tier, model=model, now=now,
                                     max_wait=routed_wait_limit(queue_rounds), runner_label=runner_label)
    return (json.dumps([root, runner_label(name)], separators=(",", ":")) if name else ""), decision


# Fitting ----------------------------------------------------------------------------------------------------


def quantile(values: Sequence[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))
    return round(ordered[index], 1)


def cell(values: Sequence[float], rebuilt: Sequence[bool] = ()) -> dict[str, Any]:
    entry: dict[str, Any] = {"n": len(values), "p50": quantile(values, 0.5), "p90": quantile(values, 0.9),
                             "mean": round(statistics.fmean(values), 1) if values else None}
    if rebuilt:
        entry["rebuilt"] = sum(1 for flag in rebuilt if flag)
    return entry


def from_dash(row: Mapping[str, Any]) -> dict[str, Any]:
    """An admission line as ci-dash keeps it (cmuxterm-hq build-fleet/ci-dash, `estimates.jsonl`: the probe's
    cut of this file's record, no paths) in this file's schema. Its hot files are only a count: the tier
    they gave under the model it was recorded with."""
    distance = None
    if row.get("files") is not None:
        distance = {"app_swift_files": row.get("files"), "package_swift_files": row.get("pkg"),
                    "package_interface": row.get("iface"), "hot_files": ["(recorded)"] * int(row.get("hot") or 0)}
    compiled = row.get("outcome") in (None, "success")
    return {"schema": "cmux-warm-admission/v1", "at": row.get("at"), "run_id": row.get("run_id"),
            "run_attempt": row.get("run_attempt"), "job": row.get("job"), "runner": row.get("runner"),
            "root": row.get("root"), "pr": row.get("pr"), "start": {"kind": row.get("start") or "cold"},
            "distance": distance, "tier": row.get("tier"), "predicted_seconds": row.get("pred"),
            "compile_seconds": row.get("compile") if compiled else None, "compile_outcome": row.get("outcome"),
            "app_rebuilt": row.get("rebuilt"), "model_fitted_at": row.get("fitted")}


def read_rows(paths: Sequence[str]) -> list[dict[str, Any]]:
    """Admission lines from files of this schema or ci-dash's (from_dash())."""
    rows = []
    for path in paths:
        with open(path) as handle:
            for line in handle:
                with contextlib.suppress(ValueError):
                    row = json.loads(line)
                    if isinstance(row, dict):
                        rows.append(from_dash(row) if "compile" in row and "compile_seconds" not in row else row)
    return rows


def usable(row: Mapping[str, Any]) -> bool:
    return bool(row.get("distance")) and isinstance(row.get("compile_seconds"), (int, float)) \
        and row.get("app_rebuilt") is not None


def start_class(row: Mapping[str, Any]) -> str:
    distance = row.get("distance") or {}
    if (row.get("start") or {}).get("kind") == "kept":
        if distance.get("same_base"):
            return "base"
        if distance.get("same_pr"):
            return "pr"
    return "none"


def learn_hot_files(rows: Sequence[Mapping[str, Any]], floor: Sequence[str]) -> list[str]:
    """Files that, changed with no package interface change, came with an app rebuild
    at least HOT_MIN_REBUILDS times and in at least HOT_MIN_SHARE of the starts that changed them."""
    seen: dict[str, list[bool]] = {}
    for row in rows:
        distance = row["distance"]
        if distance.get("package_swift_files") and distance.get("package_interface") is not False:
            continue
        for path in distance.get("paths") or []:
            if app_swift(path) and not package_swift(path):
                seen.setdefault(path, []).append(bool(row["app_rebuilt"]))
    learned = {path for path, flags in seen.items()
               if sum(flags) >= HOT_MIN_REBUILDS and sum(flags) >= HOT_MIN_SHARE * len(flags)}
    return sorted(learned | set(floor))


# A kept build older than this is not a start routing could have used (the warm keys' MAX_AGE_HOURS is 24,
# but a mini's roots are replaced within hours).
COUNTERFACTUAL_HOURS = 6
MIN_CLASS_ROWS = 5


def parse_at(row: Mapping[str, Any]) -> dt.datetime | None:
    text = str(row.get("at") or "").replace(" ", "T").replace("Z", "+00:00")
    try:
        moment = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=dt.timezone.utc)


def tree_features(repo: Path, old: str, new: str, hot_files: Iterable[str]) -> dict[str, Any] | None:
    """features() of the diff between two commits in REPO (the backfill and refit, never a job)."""
    names = git(repo, "diff", "--name-only", "--no-renames", old, new, timeout=120)
    if names is None:
        return None
    files = [path for path in names.split("\n") if app_swift(path)]
    packages = [path for path in files if package_swift(path)]
    return features(files, diff_interface(repo, old, new, packages), hot_files)


def with_hot(feature: Mapping[str, Any], model: Mapping[str, Any]) -> dict[str, Any]:
    """FEATURE with its hot files recomputed from its paths under the model's list (a row keeps the list
    of the model it was recorded under)."""
    paths = feature.get("paths")
    if paths is None:
        return dict(feature)
    return {**feature, "hot_files": sorted(set(paths) & set(model.get("hot_files") or ()))}


def start_classes(rows: Sequence[Mapping[str, Any]], model: Mapping[str, Any],
                  repo: Path | None) -> dict[str, dict[str, Any]]:
    """The predicted compile of each start class the picker can see, by the job's own tier (expected seconds).

    An admission that started from one of them counts its actual compile
    there ('none' is every other start). 'base' and 'pr' also count
    counterfactuals: with REPO, the tier mean of the distance from the newest
    earlier admission's build on the same merge base, or of the same pull
    request (within COUNTERFACTUAL_HOURS), to this build: what routing to that
    kept build would have compiled on average. A cell needs MIN_CLASS_ROWS.
    """
    hot = model.get("hot_files") or ()
    costs: dict[str, list[tuple[str, float]]] = {"base": [], "pr": [], "none": []}

    def cost(feature: Mapping[str, Any]) -> float | None:
        entry = (model.get("tiers") or {}).get(tier(feature, model)) or {}
        value = entry.get("mean", entry.get("p50"))
        return float(value) if isinstance(value, (int, float)) else None

    ordered = sorted((row for row in rows if parse_at(row)), key=lambda row: parse_at(row))
    for index, row in enumerate(ordered):
        own = tier(with_hot(row["own"], model), model) if row.get("own") else ""
        actual = start_class(row)
        costs[actual].append((own, float(row["compile_seconds"])))
        if repo is None or not row.get("sha"):
            continue
        since = parse_at(row) - dt.timedelta(hours=COUNTERFACTUAL_HOURS)
        earlier = [other for other in ordered[:index] if parse_at(other) >= since and other.get("sha")]
        for name, same in (("base", "merged_onto"), ("pr", "pr")):
            if name == actual or not row.get(same):
                continue
            match = next((other for other in reversed(earlier) if other.get(same) == row.get(same)), None)
            feature = tree_features(repo, match["sha"], row["sha"], hot) if match else None
            predicted = cost(feature) if feature else None
            if predicted is not None:
                costs[name].append((own, predicted))
    classes: dict[str, dict[str, Any]] = {}
    for name, pairs in costs.items():
        values = [value for _, value in pairs]
        entry: dict[str, Any] = {"n": len(values)}
        if len(values) >= MIN_CLASS_ROWS:
            entry["expected"] = round(statistics.fmean(values), 1)
        by_tier = {}
        for own in TIERS:
            picked = [value for job_tier, value in pairs if job_tier == own]
            if len(picked) >= MIN_CLASS_ROWS:
                by_tier[own] = {"n": len(picked), "expected": round(statistics.fmean(picked), 1)}
        entry["by_job_tier"] = by_tier
        classes[name] = entry
    return classes


def start_kind(row: Mapping[str, Any]) -> str:
    """What the compile started from: 'kept' (this mini's kept build), 'seed', 'unknown' or 'cold'."""
    return str((row.get("start") or {}).get("kind") or "cold")


def row_tier(row: Mapping[str, Any], model: Mapping[str, Any]) -> str:
    """The row's tier under MODEL's near threshold and hot files (not the list it was recorded under)."""
    return tier(with_hot(row["distance"], model), model)


def tier_cells(rows: Sequence[Mapping[str, Any]], model: Mapping[str, Any]) -> dict[str, Any]:
    """The tiers (p50/p90 compile), tiers_by_start (the same per start kind, with counts; predict() uses a
    cell from MIN_START_ROWS) and the misclassified share of usable ROWS, tiered by MODEL. p50s, so a few
    hung or cache-missing compiles move nothing."""
    by_tier: dict[str, list[Mapping[str, Any]]] = {name: [] for name in TIERS}
    for row in rows:
        by_tier[row_tier(row, model)].append(row)
    tiers, by_start = {}, {}
    for name, members in by_tier.items():
        tiers[name] = cell([row["compile_seconds"] for row in members], [row["app_rebuilt"] for row in members])
        kinds: dict[str, list[Mapping[str, Any]]] = {}
        for row in members:
            kinds.setdefault(start_kind(row), []).append(row)
        by_start[name] = {kind: cell([row["compile_seconds"] for row in picked], [row["app_rebuilt"] for row in picked])
                          for kind, picked in sorted(kinds.items())}
    # A tier "misclassifies" an admission when it says rebuild and none happened, or the reverse.
    wrong = sum(1 for name, members in by_tier.items() for row in members
                if bool(row["app_rebuilt"]) != (name == "rebuild"))
    return {"tiers": tiers, "tiers_by_start": by_start,
            "misclassified": {"rows": wrong, "share": round(wrong / len(rows), 3) if rows else None}}


def fit(rows: Sequence[Mapping[str, Any]], *, now: dt.datetime, jobs: Sequence[Mapping[str, Any]] = (),
        near: int = NEAR_APP_SWIFT_FILES, hot_floor: Sequence[str] = DEFAULT_HOT_FILES,
        repo: Path | None = None) -> dict[str, Any]:
    rows = [row for row in rows if usable(row)]
    hot = learn_hot_files(rows, hot_floor)
    model: dict[str, Any] = {"version": 1, "fitted_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "rows": len(rows),
                             "near_app_swift_files": near, "hot_files": hot, "app_rebuild_units": APP_REBUILD_UNITS}
    model.update(tier_cells(rows, model))
    model["start_classes"] = start_classes(rows, model, repo)
    lengths: dict[str, list[float]] = {}
    for job in jobs:
        if isinstance(job.get("seconds"), (int, float)) and job.get("job"):
            lengths.setdefault(str(job["job"]), []).append(float(job["seconds"]))
    model["job_seconds"] = {name: cell(values) for name, values in sorted(lengths.items()) if len(values) >= 5}
    return model


# Self-calibration --------------------------------------------------------------------------------------------
#
# `refit` is `fit` for the part of the model that drifts: the tier and (tier, start kind) p50s, refit from the
# recent admissions under the committed model's near threshold and hot files. Everything else (hot files,
# start_classes, job_seconds) needs the git history or glaeda's job log and stays as committed. It reports
# drift: a p50 at least DRIFT_MIN_ROWS rows back that moved more than DRIFT_SHARE from what the committed model
# predicts for it; scripts/ci/warm_model_refit.py opens a pull request only then.

REFIT_DAYS = 14
DRIFT_SHARE = 0.2
DRIFT_MIN_ROWS = 20
# A compile outside this range is a broken record, not a slow or fast build.
PLAUSIBLE_SECONDS = (5.0, 7200.0)


def dedupe(rows: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Each admission once (a root's old log, the rotated copy and the collect of two aliases may repeat it),
    oldest first; rows without a time go last."""
    seen: dict[tuple, dict[str, Any]] = {}
    for row in rows:
        key = (row.get("runner"), row.get("run_id"), row.get("run_attempt"), row.get("job"), row.get("at"))
        seen.setdefault(key, dict(row))
    far = dt.datetime.max.replace(tzinfo=dt.timezone.utc)
    return sorted(seen.values(), key=lambda row: parse_at(row) or far)


def calibration_rows(rows: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    low, high = PLAUSIBLE_SECONDS
    return [row for row in dedupe(rows) if usable(row) and parse_at(row) and low <= row["compile_seconds"] <= high]


def refit(rows: Iterable[Mapping[str, Any]], model: Mapping[str, Any], *, now: dt.datetime,
          days: float | None = REFIT_DAYS) -> dict[str, Any]:
    """MODEL with its tiers and tiers_by_start refit from ROWS of the last DAYS. A tier with fewer than
    MIN_START_ROWS rows keeps the committed entry."""
    recent = calibration_rows(rows)
    if days is not None:
        recent = [row for row in recent if parse_at(row) >= now - dt.timedelta(days=days)]
    fitted = tier_cells(recent, model)
    new = dict(model)
    new["tiers"] = {name: (entry if entry["n"] >= MIN_START_ROWS or name not in (model.get("tiers") or {})
                           else model["tiers"][name])
                    for name, entry in fitted["tiers"].items()}
    new["tiers_by_start"] = fitted["tiers_by_start"]
    new["misclassified"] = fitted["misclassified"]
    new["rows"] = len(recent)
    new["fitted_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    new["calibrated"] = {"days": days, "rows": len(recent),
                         "from": recent[0]["at"] if recent else None, "to": recent[-1]["at"] if recent else None}
    return new


def drift(old: Mapping[str, Any], new: Mapping[str, Any], *, share: float = DRIFT_SHARE,
          min_rows: int = DRIFT_MIN_ROWS) -> list[dict[str, Any]]:
    """The p50s of NEW (a tier, or a tier from a start kind) with MIN_ROWS rows that moved more than SHARE
    from what OLD predicts for the same compiles."""
    moved = []
    for name in TIERS:
        places: list[tuple[str | None, Any]] = [(None, (new.get("tiers") or {}).get(name))]
        places += sorted(((new.get("tiers_by_start") or {}).get(name) or {}).items())
        for start, entry in places:
            after, count = seconds_of(entry), (entry or {}).get("n") or 0
            before = tier_seconds(name, start, old)
            if after is None or before is None or count < min_rows:
                continue
            change = after / before - 1
            if abs(change) > share:
                moved.append({"tier": name, "start": start, "n": count, "before": round(before, 1),
                              "after": round(after, 1), "change": round(change, 3)})
    return moved


def errors(pairs: Sequence[tuple[float, float]]) -> dict[str, Any]:
    """[(predicted, actual)] -> n, median absolute error, bias (median actual - predicted) and the share
    within 25% of the prediction."""
    if not pairs:
        return {"n": 0}
    return {"n": len(pairs), "mae": round(statistics.median(abs(a - p) for p, a in pairs), 1),
            "bias": round(statistics.median(a - p for p, a in pairs), 1),
            "within25": round(sum(1 for p, a in pairs if abs(a - p) <= 0.25 * p) / len(pairs), 3)}


def backtest(rows: Iterable[Mapping[str, Any]], model: Mapping[str, Any], *,
             every: dt.timedelta | None = None, days: float | None = REFIT_DAYS) -> list[dict[str, Any]]:
    """Time-ordered replay: each usable admission's compile as MODEL predicts it (tier p50s only, as
    committed) and as a self-calibrated model would have: refit() from the admissions before it (EVERY:
    only those before the last refit, one every EVERY from midnight UTC), its cell once MIN_START_ROWS.
    Each result: tier, start, actual, model, calibrated."""
    ordered = calibration_rows(rows)
    static = {key: value for key, value in model.items() if key != "tiers_by_start"}
    out, cache = [], {}
    for index, row in enumerate(ordered):
        at = parse_at(row)
        if every:
            midnight = at.replace(hour=0, minute=0, second=0, microsecond=0)
            cut = midnight + every * ((at - midnight) // every)
        else:
            cut = at
        if cut not in cache:
            earlier = [other for other in ordered[:index] if parse_at(other) < cut]
            cache[cut] = refit(earlier, static, now=cut, days=days)
        name = row_tier(row, static)
        out.append({"tier": name, "start": start_kind(row), "actual": row["compile_seconds"],
                    "model": tier_seconds(name, None, static),
                    "calibrated": tier_seconds(name, start_kind(row), cache[cut])})
    return out


def backtest_table(results: Sequence[Mapping[str, Any]], label: str = "self-calibrated") -> str:
    lines = [f"| compiles | n | model MAE s | model bias s | model within 25% | {label} MAE s | bias s | within 25% |",
             "|---|---|---|---|---|---|---|---|"]
    groups: list[tuple[str, list[Mapping[str, Any]]]] = [("all", list(results))]
    groups += [(f"tier {name}", [r for r in results if r["tier"] == name]) for name in TIERS]
    groups += [(f"start {kind}", [r for r in results if r["start"] == kind])
               for kind in sorted({r["start"] for r in results})]
    groups += [(f"{name} from {kind}", [r for r in results if r["tier"] == name and r["start"] == kind])
               for name in TIERS for kind in sorted({r["start"] for r in results})]
    for title, members in groups:
        if not members:
            continue
        before = errors([(r["model"], r["actual"]) for r in members if r["model"]])
        after = errors([(r["calibrated"], r["actual"]) for r in members if r["calibrated"]])
        lines.append(f"| {title} | {len(members)} | {before.get('mae')} | {before.get('bias')} | "
                     f"{pct(before.get('within25'))} | {after.get('mae')} | {after.get('bias')} | {pct(after.get('within25'))} |")
    return "\n".join(lines)


def pct(share: float | None) -> str:
    return "" if share is None else f"{round(100 * share)}%"


def drift_table(moved: Sequence[Mapping[str, Any]]) -> str:
    lines = ["| tier | start | n | committed s | refit s | change |", "|---|---|---|---|---|---|"]
    lines += [f"| {m['tier']} | {m['start'] or 'any'} | {m['n']} | {m['before']} | {m['after']} | "
              f"{m['change']:+.0%} |" for m in moved]
    return "\n".join(lines)


def cells_table(model: Mapping[str, Any]) -> str:
    lines = ["| tier | start | n | p50 s | p90 s | app rebuilt |", "|---|---|---|---|---|---|"]
    for name in TIERS:
        entry = (model.get("tiers") or {}).get(name) or {}
        lines.append(f"| {name} | any | {entry.get('n')} | {entry.get('p50')} | {entry.get('p90')} | {entry.get('rebuilt')} |")
        for kind, cell_entry in sorted(((model.get("tiers_by_start") or {}).get(name) or {}).items()):
            used = "" if (cell_entry.get("n") or 0) >= MIN_START_ROWS else " (tier used)"
            lines.append(f"| {name} | {kind}{used} | {cell_entry.get('n')} | {cell_entry.get('p50')} | "
                         f"{cell_entry.get('p90')} | {cell_entry.get('rebuilt')} |")
    return "\n".join(lines)


def table(model: Mapping[str, Any]) -> str:
    lines = ["| tier | n | app rebuilt | compile p50 s | p90 s |", "|---|---|---|---|---|"]
    for name in TIERS:
        entry = (model.get("tiers") or {}).get(name) or {}
        lines.append(f"| {name} | {entry.get('n')} | {entry.get('rebuilt')} | {entry.get('p50')} | {entry.get('p90')} |")
    wrong = model.get("misclassified") or {}
    lines.append("")
    lines.append(f"Misclassified (tier says rebuild and none happened, or the reverse): {wrong.get('rows')} "
                 f"of {model.get('rows')} ({wrong.get('share')})")
    return "\n".join(lines)


def evaluate(rows: Sequence[Mapping[str, Any]], model: Mapping[str, Any]) -> str:
    """Predicted against actual per tier, and what routing saved against the start it would otherwise have had."""
    hot = set(model.get("hot_files") or ())
    rows = [{**row, "distance": {**row["distance"], "hot_files": sorted(
        set(row["distance"].get("paths") or row["distance"].get("hot_files") or []) & hot)}}
        for row in rows if usable(row)]
    lines = ["| tier | n | predicted p50 s | actual p50 s | actual p90 s | abs error p50 s |", "|---|---|---|---|---|---|"]
    for name in TIERS:
        members = [row for row in rows if predict(row["distance"], model)[0] == name]
        predicted = predict({"package_swift_files": 1, "package_interface": True} if name == "rebuild"
                            else {"app_swift_files": 99} if name == "far" else {}, model)[1]
        actual = [row["compile_seconds"] for row in members]
        errors = [abs(value - predicted) for value in actual] if predicted is not None else []
        lines.append(f"| {name} | {len(members)} | {predicted} | {quantile(actual, 0.5)} | {quantile(actual, 0.9)} "
                     f"| {quantile(errors, 0.5)} |")
    routed = [row for row in rows if "glaeda-runner-" in str((row.get("route") or {}).get("admission_runner") or "")]
    saved = []
    for row in routed:
        own = row.get("own")
        otherwise = start_class_seconds("none", tier(with_hot(own, model), model), model) if own else None
        if otherwise is not None:
            saved.append(otherwise - row["compile_seconds"])
    lines.append("")
    lines.append(f"Routed admissions: {len(routed)}; realized saving against an unrouted start of the same "
                 f"pull request tier: total {round(sum(saved))} s, p50 {quantile(saved, 0.5)} s")
    return "\n".join(lines)


def collect(hosts: Sequence[str], out: Any = None) -> int:
    """Every HOST's admission logs (root 1's, its rotated copy, and any root's own), over SSH, to OUT."""
    out = out or sys.stdout
    for host in hosts:
        try:
            text = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                                  # find, not a glob: the minis' login shell is zsh, whose unmatched glob
                                  # (no cmux-ci-*/ log) failed the whole command and read nothing.
                                  "find /Users/Shared/cmux-build-fleet/ci -maxdepth 2 -type f "
                                  f"\\( -name {LOG_NAME} -o -name {LOG_NAME}.1 \\) -exec cat {{}} + 2>/dev/null; true"],
                                 capture_output=True, text=True, timeout=120).stdout
        except (OSError, subprocess.SubprocessError) as error:
            print(f"{host}: {error}", file=sys.stderr)
            continue
        out.write(text)
    return 0


def collect_rows(hosts: Sequence[str]) -> list[dict[str, Any]]:
    buffer = io.StringIO()
    collect(hosts, buffer)
    rows = []
    for line in buffer.getvalue().splitlines():
        with contextlib.suppress(ValueError):
            row = json.loads(line)
            if isinstance(row, dict):
                rows.append(row)
    return rows


def main(argv: Sequence[str]) -> int:
    now = lambda: dt.datetime.now(dt.timezone.utc)  # noqa: E731
    if len(argv) == 3 and argv[1] == "admission":
        try:
            record = admission(Path(argv[2]), os.environ, Path.cwd(), now)
        except Exception as error:  # noqa: BLE001 - a record never fails the job
            print(f"warm distance: not recorded ({type(error).__name__}: {error})"[:300])
            return 0
        line = summary_line(record)
        print(line)
        print(json.dumps(record, sort_keys=True))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
                handle.write(f"\n{line}\n")
        return 0
    if len(argv) >= 3 and argv[1] in ("fit", "evaluate"):
        args = list(argv[2:])
        option = lambda name: args.pop(args.index(name) + 1) if name in args and args.index(name) + 1 < len(args) else None  # noqa: E731
        out, model_path, jobs_path, repo = option("--out"), option("--model"), option("--jobs"), option("--git")
        args = [arg for arg in args if arg not in ("--out", "--model", "--jobs", "--git")]
        rows = read_rows(args)
        if argv[1] == "evaluate":
            print(evaluate(rows, load_model(model_path)))
            return 0
        model = fit(rows, now=now(), jobs=read_rows([jobs_path]) if jobs_path else (),
                    repo=Path(repo) if repo else None)
        print(table(model))
        if out:
            Path(out).write_text(json.dumps(model, indent=2, sort_keys=True) + "\n")
        return 0
    if len(argv) >= 3 and argv[1] in ("refit", "backtest"):
        args = list(argv[2:])
        option = lambda name: args.pop(args.index(name) + 1) if name in args and args.index(name) + 1 < len(args) else None  # noqa: E731
        out, model_path, days, every = option("--out"), option("--model"), option("--days"), option("--every-hours")
        args = [arg for arg in args if arg not in ("--out", "--model", "--days", "--every-hours")]
        model, rows = load_model(model_path), read_rows(args)
        days_value = float(days) if days else REFIT_DAYS
        if argv[1] == "backtest":
            step = dt.timedelta(hours=float(every)) if every else None
            print(backtest_table(backtest(rows, model, every=step, days=days_value)))
            return 0
        new = refit(rows, model, now=now(), days=days_value)
        moved = drift(model, new)
        print(cells_table(new))
        print("")
        print(drift_table(moved) if moved else "No drift: every p50 is within 20% of the committed model's.")
        if out:
            Path(out).write_text(json.dumps(new, indent=2, sort_keys=True) + "\n")
        return 0
    if len(argv) >= 3 and argv[1] == "collect":
        return collect(argv[2:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
