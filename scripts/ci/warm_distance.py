#!/usr/bin/env python3
"""Warm-state distance: what a compile admission starts from, what it costs, and a model to route by.

    warm_distance.py admission STORE            append this admission's line, print its summary
    warm_distance.py fit DATA.jsonl... [--out MODEL] [--rows]
    warm_distance.py evaluate DATA.jsonl... [--model MODEL]
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
per glaeda job class (job_seconds) for the picker's wait estimate. The model
is scripts/ci/warm-distance-model.json; refit with

    python3 scripts/ci/warm_distance.py collect cmux14 cmux8s-mac-mini ... > data.jsonl
    python3 scripts/ci/warm_distance.py fit data.jsonl --out scripts/ci/warm-distance-model.json
"""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time
import urllib.parse
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


def predict(feature: Mapping[str, Any], model: Mapping[str, Any]) -> tuple[str, float | None]:
    """(tier, predicted compile seconds) for these distance features; None without a model."""
    name = tier(feature, model)
    entry = (model.get("tiers") or {}).get(name) or {}
    seconds = entry.get("p50")
    return name, float(seconds) if isinstance(seconds, (int, float)) else None


def start_class_seconds(start: str, job_tier: str, model: Mapping[str, Any]) -> float | None:
    """The picker's predicted compile for a start class ('base', 'pr', 'none') and the job's own tier."""
    classes = model.get("start_classes") or {}
    entry = classes.get(start) or {}
    cell = (entry.get("by_job_tier") or {}).get(job_tier) or {}
    for value in (cell.get("expected"), entry.get("expected")):
        if isinstance(value, (int, float)):
            return float(value)
    return None


# A pull request's own previous build is near when it is recent and far or a rebuild once main moved
# (09-25/26 re-pushes: within 30 min 16 of 26 near; after 90 min 21 of 23 rebuilt), so `fit` prices a
# same-pull-request start by its age, in these buckets (minutes, upper bounds).
PR_AGE_BUCKETS = (30, 90, 360)


def age_bucket(minutes: float | None) -> str:
    if minutes is None:
        return "unknown"
    for bound in PR_AGE_BUCKETS:
        if minutes < bound:
            return f"<{bound}"
    return f">={PR_AGE_BUCKETS[-1]}"


def pr_start_seconds(age_minutes: float | None, job_tier: str, model: Mapping[str, Any]) -> float | None:
    """Predicted compile from this pull request's own previous build AGE_MINUTES old, by the job's own tier.

    Falls back to the age bucket's overall value, then the 'pr' start class.
    """
    bucket = (model.get("pr_by_age") or {}).get(age_bucket(age_minutes)) or {}
    cell = (bucket.get("by_job_tier") or {}).get(job_tier) or {}
    for value in (cell.get("expected"), bucket.get("expected")):
        if isinstance(value, (int, float)):
            return float(value)
    return start_class_seconds("pr", job_tier, model)


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
    predicted = predict(distance, model) if distance else (None, None)
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
# A compile on a mini whose other root already compiles runs slower: alone p50 366 s, overlapped by
# another compile at least half its length p50 499 s (310 compiles on 12 minis, 09-26). Austin's M4
# minis run p50 408 s against 366. Both multiply a candidate's predicted compile, which spreads compiles
# across minis without a separate spread pin (CI_OWNED_SPREAD stays unset).
CONTENDED_FACTOR = 1.3
SLOW_MINI_FACTOR = 1.11
SLOW_MINI = re.compile(r"austin")
RUNNER_MEMBER = re.compile(r"(?P<member>.+)-glaeda(?:-[0-9]+)?")


def mini_of(name: str) -> str:
    match = RUNNER_MEMBER.fullmatch(name or "")
    return match.group("member") if match else name


def compile_factor(name: str, busy: set[str]) -> float:
    """How much slower than alone on an M4 Pro a compile on runner NAME runs now: contended when another
    root runner of its mini is busy (BUSY names them), slower on an Austin mini."""
    contended = any(other != name and mini_of(other) == mini_of(name) for other in busy)
    factor = CONTENDED_FACTOR if contended else 1.0
    return factor * (SLOW_MINI_FACTOR if SLOW_MINI.search(name) else 1.0)


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
                    pr_warm: Mapping[str, float | None] | Iterable[str], running: Mapping[str, Any], job_tier: str,
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
    base_warm = set(base_warm)
    # name -> the age in minutes of this pull request's build there (None: unknown)
    pr_warm = dict(pr_warm) if isinstance(pr_warm, Mapping) else {name: None for name in pr_warm}
    cold = start_class_seconds("none", job_tier, model)
    decision: dict[str, Any] = {"job_tier": job_tier, "none_seconds": cold, "candidates": []}
    if cold is None:
        decision["why"] = "no model"
        return "", decision
    waits: list[float | None] = []
    pinnable: list[tuple[str, float | None]] = []
    idle_names: list[str] = []
    # Root runners run compiles (GUI jobs have their own runners since cmux#14796): a busy one means its
    # mini compiles now.
    busy = {str(runner.get("name") or "") for runner in runners
            if runner.get("status") == "online" and runner.get("busy")
            and root in {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}}
    for runner in runners:
        name = str(runner.get("name") or "")
        labels = {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}
        if runner.get("status") != "online" or not name or root not in labels:
            continue
        if not runner.get("busy"):
            wait: float | None = 0.0
        elif name in running:
            wait = remaining_seconds(running.get(name), model, now)
        else:
            # Busy with a job that started after the snapshot: a root job that has only just begun.
            wait = remaining_seconds({"job": "macos-compile-admission", "started_at": now.isoformat()}, model, now)
        waits.append(wait)
        if wait == 0.0:
            idle_names.append(name)
        if runner_label(name) in labels:
            pinnable.append((name, wait))
    if not waits:
        decision["why"] = "no online root runner"
        return "", decision
    if idle_names:
        # GitHub gives the root label any idle root runner: price the fastest place it could land.
        baseline = cold * min(compile_factor(name, busy) for name in idle_names)
    else:
        baseline = cold + min((wait for wait in waits if wait is not None), default=UNKNOWN_JOB_SECONDS)
    decision["baseline_seconds"] = round(baseline, 1)
    best: tuple[float, str] | None = None
    for name, wait in pinnable:
        options = []
        if name in base_warm:
            options.append(("base", start_class_seconds("base", job_tier, model)))
        if name in pr_warm:
            options.append(("pr", pr_start_seconds(pr_warm[name], job_tier, model)))
        options = [(start, value) for start, value in options if value is not None]
        if not options:
            continue
        start, compile_seconds = min(options, key=lambda option: option[1])
        compile_seconds = round(compile_seconds * compile_factor(name, busy), 1)
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


ADMISSION_JOB_SUFFIX = "macOS compile admission"
KEEP_STEP = "Keep this owned Mac's DerivedData"
PREVIOUS_RUNS = 2


def previous_admission(get: Callable[[str], Any], head_ref: str, exclude_run: str,
                       now: dt.datetime) -> tuple[str, float] | None:
    """The runner that kept this pull request's newest earlier build, and its age in minutes.

    The janitor's warm state lags a sweep or more behind, and a re-push usually
    comes within minutes (09-26: #13504's second push found no key for its first
    build, 21 minutes old). At most 1 + PREVIOUS_RUNS requests.
    """
    if not head_ref:
        return None
    runs = get(f"/actions/runs?event=pull_request&branch={urllib.parse.quote(head_ref, safe='')}&per_page=5")
    checked = 0
    for run in (runs or {}).get("workflow_runs") or []:
        if str(run.get("id")) == exclude_run or run.get("name") != "CI":
            continue
        if checked >= PREVIOUS_RUNS:
            break
        checked += 1
        jobs = (get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page=100") or {}).get("jobs") or []
        for job in jobs:
            if not str(job.get("name") or "").endswith(ADMISSION_JOB_SUFFIX) or not job.get("runner_name"):
                continue
            for step in job.get("steps") or []:
                if step.get("name") == KEEP_STEP and step.get("conclusion") == "success" and step.get("completed_at"):
                    done = dt.datetime.fromisoformat(str(step["completed_at"]).replace("Z", "+00:00"))
                    return str(job["runner_name"]), max(0.0, (now - done).total_seconds() / 60)
    return None


def picker_route(runners: Sequence[Mapping[str, Any]], root: str, *, merged_onto: str | None,
                 pr_number: str | None, snapshot: Mapping[str, Any], workspace: Path, queue_rounds: int | None,
                 now: dt.datetime, warm_key: Callable[[str | None], str],
                 runner_label: Callable[[str], str], model: Mapping[str, Any] | None = None,
                 previous: Callable[[], tuple[str, float] | None] | None = None) -> tuple[str, dict[str, Any]]:
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
    # This pull request's builds: the snapshot's keys, aged by that runner's newest admission (a lower
    # bound), and the runner the jobs API says kept its newest build, aged exactly.
    pr_warm: dict[str, float | None] = {}
    for held in holding(pr_key):
        entry = kept.get(held) or {}
        try:
            at = dt.datetime.fromisoformat(str(entry.get("at")).replace("Z", "+00:00"))
            pr_warm[held] = max(0.0, (now - at).total_seconds() / 60)
        except ValueError:
            pr_warm[held] = None
    found = None
    if previous is not None and pr_key:
        try:
            found = previous()
        except Exception:  # noqa: BLE001 - the snapshot's keys still route
            found = None
    if found:
        pr_warm[found[0]] = found[1]
    name, decision = route_admission(runners, root, base_warm=holding(base_key), pr_warm=pr_warm,
                                     running=running, job_tier=job_tier, model=model, now=now,
                                     max_wait=routed_wait_limit(queue_rounds), runner_label=runner_label)
    decision["previous_build"] = list(found) if found else None
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


def read_rows(paths: Sequence[str]) -> list[dict[str, Any]]:
    rows = []
    for path in paths:
        with open(path) as handle:
            for line in handle:
                with contextlib.suppress(ValueError):
                    row = json.loads(line)
                    if isinstance(row, dict):
                        rows.append(row)
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


def pr_by_age(rows: Sequence[Mapping[str, Any]], model: Mapping[str, Any],
              repo: Path | None) -> dict[str, dict[str, Any]]:
    """Predicted compile from this pull request's newest earlier build, by its age (age_bucket()) and the job's tier.

    For each admission with an earlier build of the same pull request, the
    tier mean of the distance between the two builds (with REPO), or the
    actual compile when it did start there.
    """
    ordered = sorted((row for row in rows if parse_at(row)), key=lambda row: parse_at(row))
    cells: dict[str, list[tuple[str, float]]] = {}
    for index, row in enumerate(ordered):
        if not row.get("pr") or not row.get("sha"):
            continue
        match = next((other for other in reversed(ordered[:index])
                      if other.get("pr") == row["pr"] and other.get("sha") and other["sha"] != row["sha"]), None)
        if match is None:
            continue
        age = (parse_at(row) - parse_at(match)).total_seconds() / 60
        own = tier(with_hot(row["own"], model), model) if row.get("own") else ""
        if start_class(row) == "pr":
            value: float | None = float(row["compile_seconds"])
        elif repo is not None:
            feature = tree_features(repo, match["sha"], row["sha"], model.get("hot_files") or ())
            entry = (model.get("tiers") or {}).get(tier(feature, model)) or {} if feature else {}
            value = entry.get("mean", entry.get("p50"))
        else:
            value = None
        if isinstance(value, (int, float)):
            cells.setdefault(age_bucket(age), []).append((own, float(value)))
    out: dict[str, dict[str, Any]] = {}
    for bucket, pairs in cells.items():
        entry: dict[str, Any] = {"n": len(pairs)}
        if len(pairs) >= MIN_CLASS_ROWS:
            entry["expected"] = round(statistics.fmean(value for _, value in pairs), 1)
        by_tier = {}
        for own in TIERS:
            picked = [value for job_tier, value in pairs if job_tier == own]
            if len(picked) >= MIN_CLASS_ROWS:
                by_tier[own] = {"n": len(picked), "expected": round(statistics.fmean(picked), 1)}
        entry["by_job_tier"] = by_tier
        out[bucket] = entry
    return out


def fit(rows: Sequence[Mapping[str, Any]], *, now: dt.datetime, jobs: Sequence[Mapping[str, Any]] = (),
        near: int = NEAR_APP_SWIFT_FILES, hot_floor: Sequence[str] = DEFAULT_HOT_FILES,
        repo: Path | None = None) -> dict[str, Any]:
    rows = [row for row in rows if usable(row)]
    hot = learn_hot_files(rows, hot_floor)
    model: dict[str, Any] = {"version": 1, "fitted_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "rows": len(rows),
                             "near_app_swift_files": near, "hot_files": hot, "app_rebuild_units": APP_REBUILD_UNITS}
    by_tier: dict[str, list[Mapping[str, Any]]] = {name: [] for name in TIERS}
    for row in rows:
        distance = dict(row["distance"])
        distance["hot_files"] = sorted(set(distance.get("paths") or distance.get("hot_files") or []) & set(hot))
        by_tier[tier(distance, model)].append(row)
    tiers = {}
    for name, members in by_tier.items():
        tiers[name] = cell([row["compile_seconds"] for row in members], [row["app_rebuilt"] for row in members])
    model["tiers"] = tiers
    # A tier "misclassifies" an admission when it says rebuild and none happened, or the reverse.
    wrong = sum(1 for name, members in by_tier.items() for row in members
                if bool(row["app_rebuilt"]) != (name == "rebuild"))
    model["misclassified"] = {"rows": wrong, "share": round(wrong / len(rows), 3) if rows else None}
    model["start_classes"] = start_classes(rows, model, repo)
    model["pr_by_age"] = pr_by_age(rows, model, repo)
    lengths: dict[str, list[float]] = {}
    for job in jobs:
        if isinstance(job.get("seconds"), (int, float)) and job.get("job"):
            lengths.setdefault(str(job["job"]), []).append(float(job["seconds"]))
    model["job_seconds"] = {name: cell(values) for name, values in sorted(lengths.items()) if len(values) >= 5}
    return model


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


def collect(hosts: Sequence[str]) -> int:
    for host in hosts:
        try:
            # bash with nullglob: the minis' zsh aborts the whole command on a glob with no match.
            out = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                                  "bash -c 'shopt -s nullglob; cat /Users/Shared/cmux-build-fleet/ci/"
                                  f"{LOG_NAME}* /Users/Shared/cmux-build-fleet/ci/cmux-ci-*/{LOG_NAME}*'"],
                                 capture_output=True, text=True, timeout=120).stdout
        except (OSError, subprocess.SubprocessError) as error:
            print(f"{host}: {error}", file=sys.stderr)
            continue
        sys.stdout.write(out)
    return 0


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
    if len(argv) >= 3 and argv[1] == "collect":
        return collect(argv[2:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
