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
SWIFT_COMPILE = re.compile(r"^SwiftCompile \S+ \S+ Compiling (.*?) \(in target '([^']*)'")
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


# Recording --------------------------------------------------------------------------------------------------


def start_distance(current: Mapping[str, list], start: Mapping[str, list] | None, changed: set[str] | None,
                   out: Path) -> None:
    """Write the start's distance for `admission`: the changed Swift paths between the two records."""
    if start is None or changed is None:
        document: dict[str, Any] = {"start": "cold"}
    else:
        swift = sorted(path for path in changed if path.endswith(".swift"))
        document = {"start": "warm", "changed_inputs": len(changed),
                    "swift_paths": swift[:MAX_PATHS], "swift_paths_total": len(swift)}
    out.parent.mkdir(parents=True, exist_ok=True)
    incoming = out.with_name(f".{out.name}.{os.getpid()}")
    incoming.write_text(json.dumps(document, sort_keys=True))
    incoming.rename(out)


def git(workspace: Path, *args: str, timeout: int = 30) -> str | None:
    env = {**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0"}
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
    git(workspace, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--depth=1", "origin", sha, timeout=60)
    return have_commit(workspace, sha)


def diff_interface(workspace: Path, old: str, new: str, paths: Sequence[str]) -> bool | None:
    """Whether the package PATHS changed an interface between two commits; None when git cannot say."""
    if not paths:
        return False
    text = git(workspace, "diff", "-U0", "--no-color", "--no-ext-diff", old, new, "--", *paths, timeout=60)
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
                if interface is False and undone and start_stamp.get("pr_package_interface") is not False:
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
    for log in sorted(logs.glob("*-build.log")) if logs.is_dir() else ():
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
        "own": {"app_swift_files": len(own[0]), "package_interface": own[1],
                **features(own[0], own[1], hot_files)} if own else None,
        "swift_units": units, "swift_units_total": sum(units.values()),
        "app_rebuilt": units.get("cmux", 0) >= APP_REBUILD_UNITS if units else None,
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
    append_line(store / LOG_NAME, record)
    share_model(store)
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


def remaining_seconds(entry: Mapping[str, Any] | None, model: Mapping[str, Any], now: dt.datetime) -> float:
    """How long a busy runner's current job still runs: its class's p50 less the time it has run (the
    p90 once it passed the p50), at least a minute. Unknown job: UNKNOWN_JOB_SECONDS."""
    if not isinstance(entry, Mapping):
        return UNKNOWN_JOB_SECONDS
    lengths = (model.get("job_seconds") or {}).get(job_key(str(entry.get("job") or ""))) or {}
    p50, p90 = lengths.get("p50"), lengths.get("p90")
    try:
        started = dt.datetime.fromisoformat(str(entry.get("started_at")).replace("Z", "+00:00"))
    except ValueError:
        started = None
    if not isinstance(p50, (int, float)) or started is None:
        return UNKNOWN_JOB_SECONDS
    ran = max(0.0, (now - started).total_seconds())
    left = p50 - ran if ran < p50 else (p90 if isinstance(p90, (int, float)) else p50) - ran
    return max(60.0, left)


def routed_wait_limit(queue_rounds: int | None) -> int:
    """The longest wait for a busy warm runner the rescue budget covers (0: idle runners only)."""
    return min(MAX_ROUTED_WAIT_SECONDS, max(0, queue_rounds or 0) * QUEUE_ROUND_SECONDS)


def route_admission(runners: Sequence[Mapping[str, Any]], root: str, *, base_warm: Iterable[str],
                    pr_warm: Iterable[str], running: Mapping[str, Any], job_tier: str,
                    model: Mapping[str, Any], now: dt.datetime, max_wait: float,
                    runner_label: Callable[[str], str], root_free: int | None = None) -> tuple[str, dict[str, Any]]:
    """The root runner whose expected wait plus predicted compile is lowest, if it beats the unpinned root label.

    A candidate's cost is its expected wait (0 when idle, else what its
    current job has left, remaining_seconds()) plus the compile predicted for
    its start class: a kept build of this run's merge base (`base_warm`), of
    this pull request (`pr_warm`), or neither ('none'), by this pull
    request's own tier (start_class_seconds()). The unpinned root label goes
    to any idle root runner, cost 'none', or waits for the first to finish.
    `root_free` is the picker's live count of root runners free for this run
    (pr_runner_pool.py Choice.root_budget: idle runners less what busy
    runners, the janitor's queue and the last LIVE_WINDOW_MINUTES of runs
    hold); 0 means the root label waits too. A pin to a busy runner is taken
    only within `max_wait`. Returns the runner name ("" to leave the root
    label) and the costs, for the log.
    """
    base_warm, pr_warm = set(base_warm), set(pr_warm)
    cold = start_class_seconds("none", job_tier, model)
    decision: dict[str, Any] = {"job_tier": job_tier, "none_seconds": cold, "candidates": []}
    if cold is None:
        decision["why"] = "no model"
        return "", decision
    online = []
    for runner in runners:
        name = str(runner.get("name") or "")
        labels = {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}
        if runner.get("status") == "online" and name and root in labels and runner_label(name) in labels:
            wait = 0.0 if not runner.get("busy") else remaining_seconds(running.get(name), model, now)
            online.append((name, wait))
    if not online:
        decision["why"] = "no online root runner with its own label"
        return "", decision
    busy_waits = [wait for _, wait in online if wait > 0]
    idle = root_free > 0 if root_free is not None else len(busy_waits) < len(online)
    baseline = cold + (0.0 if idle else min(busy_waits, default=UNKNOWN_JOB_SECONDS))
    decision["baseline_seconds"] = round(baseline, 1)
    best: tuple[float, str] | None = None
    for name, wait in online:
        start = "base" if name in base_warm else "pr" if name in pr_warm else ""
        if not start:
            continue
        compile_seconds = start_class_seconds(start, job_tier, model)
        if compile_seconds is None:
            continue
        cost = wait + compile_seconds
        decision["candidates"].append({"runner": name, "start": start, "wait": round(wait, 1),
                                       "compile": compile_seconds, "cost": round(cost, 1)})
        if wait <= max_wait and (best is None or cost < best[0]):
            best = (cost, name)
    if best is None:
        decision["why"] = "no warm runner within the wait limit"
        return "", decision
    if best[0] + ROUTE_MARGIN_SECONDS > baseline:
        decision["why"] = f"the best warm runner ({best[0]:.0f} s) does not beat the root label ({baseline:.0f} s)"
        return "", decision
    decision["why"] = f"{best[1]}: {best[0]:.0f} s against {baseline:.0f} s on the root label"
    return best[1], decision


def picker_route(runners: Sequence[Mapping[str, Any]], root: str, *, merged_onto: str | None,
                 pr_number: str | None, snapshot: Mapping[str, Any], workspace: Path, queue_rounds: int | None,
                 now: dt.datetime, warm_key: Callable[[str | None], str],
                 runner_label: Callable[[str], str], model: Mapping[str, Any] | None = None,
                 root_free: int | None = None) -> tuple[str, dict[str, Any]]:
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

    own = pull_request_files(workspace, (merged_onto or "").strip().lower(), fetch=False) if merged_onto else None
    job_tier = tier(features(own[0], own[1], model.get("hot_files") or DEFAULT_HOT_FILES), model) if own else ""
    running = snapshot.get("running") if isinstance(snapshot.get("running"), Mapping) else {}
    name, decision = route_admission(runners, root, base_warm=holding(base_key), pr_warm=holding(pr_key),
                                     running=running, job_tier=job_tier, model=model, now=now,
                                     max_wait=routed_wait_limit(queue_rounds), runner_label=runner_label,
                                     root_free=root_free)
    return (json.dumps([root, runner_label(name)], separators=(",", ":")) if name else ""), decision


# Fitting ----------------------------------------------------------------------------------------------------


def quantile(values: Sequence[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))
    return round(ordered[index], 1)


def cell(values: Sequence[float], rebuilt: Sequence[bool] = ()) -> dict[str, Any]:
    entry: dict[str, Any] = {"n": len(values), "p50": quantile(values, 0.5), "p90": quantile(values, 0.9)}
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


def start_classes(rows: Sequence[Mapping[str, Any]], model: Mapping[str, Any],
                  repo: Path | None) -> dict[str, dict[str, Any]]:
    """The predicted compile of each start class the picker can see, by the job's own tier (expected seconds).

    'none' is each admission's actual start when it was neither of the others.
    'base' and 'pr' are counterfactual: with REPO, the tier cost (tiers' p50)
    of the distance from the newest earlier admission's build on the same
    merge base, or of the same pull request (within COUNTERFACTUAL_HOURS), to
    this build: what routing to that kept build would have compiled. Without
    REPO only the admissions that actually started there count. A cell needs
    MIN_CLASS_ROWS.
    """
    hot = model.get("hot_files") or ()
    costs: dict[str, list[tuple[str, float]]] = {"base": [], "pr": [], "none": []}

    def cost(feature: Mapping[str, Any]) -> float | None:
        return predict(feature, model)[1]

    ordered = sorted((row for row in rows if parse_at(row)), key=lambda row: parse_at(row))
    for index, row in enumerate(ordered):
        own = tier(row["own"], model) if row.get("own") else ""
        actual = start_class(row)
        observed = cost({**row["distance"], "hot_files": sorted(set(row["distance"].get("paths") or []) & set(hot))})
        if observed is not None:
            costs[actual].append((own, observed))
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
        otherwise = start_class_seconds("none", tier(own, model), model) if own else None
        if otherwise is not None:
            saved.append(otherwise - row["compile_seconds"])
    lines.append("")
    lines.append(f"Routed admissions: {len(routed)}; realized saving against an unrouted start of the same "
                 f"pull request tier: total {round(sum(saved))} s, p50 {quantile(saved, 0.5)} s")
    return "\n".join(lines)


def collect(hosts: Sequence[str]) -> int:
    for host in hosts:
        try:
            out = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                                  f"cat /Users/Shared/cmux-build-fleet/ci/{LOG_NAME}.1 "
                                  f"/Users/Shared/cmux-build-fleet/ci/{LOG_NAME} 2>/dev/null"],
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
