#!/usr/bin/env python3
"""The perf lab's story catalog: stories.d/, targets.json, owners and their lints.

    python3 -I scripts/perf-lab/catalog.py stories [--lint [--format=paths]]
    python3 -I scripts/perf-lab/catalog.py stories --orphans [--json]     # MQ12, orphans.py
    python3 -I scripts/perf-lab/catalog.py targets --check | --uncovered
    python3 -I scripts/perf-lab/catalog.py hot-paths --uncovered

The same commands run as `lab.py stories|targets|hot-paths ...`: this module is a lab.py command module
(LAB_COMMANDS, add_arguments, run; task 005).

A story is one JSON file `stories.d/<id>.json` (rule R7, so parallel tasks never edit one file). Chrome keeps
the same split: every benchmark carries its owners and bug component (`@benchmark.Info(emails=...,
component=...)`, third_party/catapult/telemetry/telemetry/benchmark.py), tools/perf/core/perf_data_generator.py
refuses a benchmark without that metadata, and tools/perf/core/shard_maps bind each story to a device by its
measured time. Here the owner is an OWNERS.md lane (R6, R9), `seconds` feeds the shard map (task 011), and
`needs` lists the capabilities the measured build must have (task 211). `not_measurable` says why the lab cannot
run a story yet (a build or runner argument it lacks): the story is linted, but gets no shard, round or build.

targets.json holds only the 12 fixed program targets (R4). A story claims a target row with a metric whose
`name` is the row check's metric pattern, verbatim, and whose target_ref is {"target": <row id>}. Every other
limit or noise floor is a reference {path, key} into the file that already owns the number, never a copy: the
lint refuses a number anywhere in a story except `repeats` and `seconds`, and in targets.json anywhere except a
check's `value` and a row's `hz`.

Stdlib only; loads perf_result.py by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


perf_result = _load_sibling("perf_result")

# Repository-relative inputs. Every command takes --root so tests run on a fixture tree.
STORIES_DIR = "scripts/perf-lab/stories.d"
TARGETS_PATH = "scripts/perf-lab/targets.json"
OWNERS_PATH = "plans/cmux-next/OWNERS.md"
HOT_PATHS_PATH = "scripts/cmux-next/perf-hot-benches.json"
PERF_CRON_PATH = "scripts/cmux-next/perf-cron.py"

TARGETS_SCHEMA = "cmux-perf-targets/v1"
TARGET_COUNT = 12  # p12-perf-process.md section 6, done check 3
T0_SECONDS_MAX = 480  # p12-perf-process.md section 3.3: T0 sums at most 480 s over all its stories
TIERS = ("T0", "T1", "T2", "linux", "builder")
# Debug is never a lab config (done check 4); bench-checks only where a target row asks for it.
STORY_CONFIGS = tuple(c for c in perf_result.CONFIGS if c != "debug")
# A builder story times the build itself, not an app. The edit loop it measures is the Debug build (p11-codebase.md
# F13), and done check 4 counts debug runs in T0 and T1 only.
BUILDER_STORY_CONFIGS = perf_result.CONFIGS
BROWSER_ENGINES = tuple(e for e in perf_result.ENGINES if e != "none")  # F12: a browser target has a row for each
STATS = ("p50", "p95", "p99", "max", "min", "mean")
OPS: dict[str, Callable[[float, float], bool]] = {
    "<=": lambda a, b: a <= b,
    "<": lambda a, b: a < b,
    ">=": lambda a, b: a >= b,
    ">": lambda a, b: a > b,
}
# What a `needs` entry may name: a debug method, an emitted signpost, a probe env name (debug.capabilities,
# task 211), a file the measured commit must have (perf-cron.py supported_parts_at), or a host privilege (D3).
NEED_KINDS = ("debug", "signpost", "env", "file", "privilege")
NEED_PATTERN = re.compile(r"^(" + "|".join(NEED_KINDS) + r"):\S+$")
COMPONENT_PATTERN = re.compile(r"^[A-Z][A-Za-z0-9]*(>[A-Z][A-Za-z0-9]*)*$")
OWNER_LANE_PATTERN = re.compile(r"\bPL-[a-z0-9]+(?:-[a-z0-9]+)*")
OWNER_AGENT_PATTERN = re.compile(r"(?<![\w-])[a-z][0-9]{2,}(?![\w-])")
OWNER_LEAD = "Performance Lead"
# A command flag that sets a limit: its value is a threshold, which belongs in the file that owns it.
THRESHOLD_FLAG = re.compile(r"^--[a-z0-9-]*(budget|limit|threshold|floor|target)[a-z0-9-]*$")
NUMBER_TEXT = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")

STORY_REQUIRED = ("id", "tier", "description", "command", "session", "engine", "config", "metrics", "repeats",
                  "seconds", "needs", "owner", "component")
STORY_OPTIONAL = ("hot_paths", "perf_cron_part", "not_measurable", "runs")
STORY_NUMBERS = ("repeats", "seconds")
METRIC_REQUIRED = ("name", "unit", "better")
METRIC_OPTIONAL = ("target_ref", "floor_ref")
TARGET_KEYS = ("id", "text", "browser", "rows")
ROW_REQUIRED = ("id", "checks")
ROW_OPTIONAL = ("engine", "session", "config", "hz")
CHECK_REQUIRED = ("metric", "stat", "op", "value", "unit")
CHECK_OPTIONAL = ("floor_ref", "note")


class CatalogError(RuntimeError):
    """An input the catalog cannot read at all (a missing file, broken JSON)."""


class RefError(ValueError):
    """A {path, key} reference that does not name a number in an existing file."""


@dataclass(frozen=True)
class Ref:
    path: str
    key: str

    def describe(self) -> str:
        return f"{self.path}#{self.key}"


@dataclass(frozen=True)
class Metric:
    name: str
    unit: str
    better: str
    target: str | None
    target_ref: Ref | None
    floor_ref: Ref | None


@dataclass(frozen=True)
class Story:
    id: str
    path: str
    tier: str
    description: str
    command: tuple[str, ...]
    session: str
    engine: str
    config: str
    metrics: tuple[Metric, ...]
    repeats: int
    seconds: int
    needs: tuple[str, ...]
    owner: str
    component: str
    hot_paths: tuple[str, ...] = ()
    perf_cron_part: str | None = None
    # Why the lab cannot run the story yet (the missing runner or build support), or None. Such a story is defined
    # (its series, owner and metrics are linted) but no shard, round or build is planned for it (measurable()).
    not_measurable: str | None = None
    # The scripts the command runs on every run besides command[0] (a session script's bench, a fleet step's story
    # module). orphans.py counts only these and the command's own paths as run by a story (MQ12).
    runs: tuple[str, ...] = ()

    def measurable(self) -> bool:
        return self.not_measurable is None


@dataclass(frozen=True)
class Check:
    metric: str
    stat: str
    op: str
    value: float
    unit: str
    floor_ref: Ref | None = None


@dataclass(frozen=True)
class Row:
    id: str
    target_id: str
    checks: tuple[Check, ...]
    engine: str | None = None
    session: str | None = None
    config: str | None = None
    hz: int | None = None


@dataclass(frozen=True)
class Target:
    id: str
    text: str
    browser: bool
    rows: tuple[Row, ...]


@dataclass(frozen=True)
class Catalog:
    root: Path
    stories: tuple[Story, ...]
    targets: tuple[Target, ...]
    owners: frozenset[str]
    hot_paths: dict[str, dict[str, Any]]
    cron_parts: tuple[str, ...]
    problems: tuple[str, ...]


# ---------- references into existing threshold files ----------

def _json_pointer(doc: Any, pointer: str) -> Any:
    """RFC 6901: '/rows/<key>/p95'; '~1' is '/', '~0' is '~'."""
    if not pointer.startswith("/"):
        raise RefError(f"a JSON key is a JSON pointer starting with '/', got {pointer!r}")
    node = doc
    for raw in pointer[1:].split("/"):
        part = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            raise RefError(f"{pointer!r}: no {part!r}")
    return node


def _constant(node: ast.AST) -> Any:
    """A literal, allowing number arithmetic (perf-cron.py's DIFF_BUDGETS has `1024 * 1000 / 500.0`)."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Dict):
        return {_constant(k): _constant(v) for k, v in zip(node.keys, node.values)}
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_constant(e) for e in node.elts]
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -_number(_constant(node.operand))
    if isinstance(node, ast.BinOp):
        a, b = _number(_constant(node.left)), _number(_constant(node.right))
        ops = {ast.Add: lambda: a + b, ast.Sub: lambda: a - b, ast.Mult: lambda: a * b, ast.Div: lambda: a / b}
        if type(node.op) in ops:
            return ops[type(node.op)]()
    raise RefError(f"line {getattr(node, 'lineno', '?')}: not a constant")


def _number(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RefError(f"{value!r} is not a number")
    return value


def _python_key(text: str, key: str) -> Any:
    """'NAME' or 'NAME/inner/key': a top-level constant assignment of a Python file, read with ast (never run)."""
    name, _, rest = key.partition("/")
    for node in ast.parse(text).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            value = _constant(node.value)
            for part in rest.split("/") if rest else []:
                if not isinstance(value, dict) or part not in value:
                    raise RefError(f"{key!r}: no {part!r}")
                value = value[part]
            return value
    raise RefError(f"{key!r}: no top-level assignment {name}")


def resolve_ref(root: Path, ref: Ref) -> float:
    """The number a reference names: a JSON pointer into a .json file or NAME[/key] in a .py file."""
    if not re.match(perf_result.TARGET_PATH_PATTERN, ref.path):
        raise RefError(f"{ref.path!r} is not a repository-relative path")
    path = root / ref.path
    if not path.is_file():
        raise RefError(f"{ref.path} does not exist")
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".json":
        value = _json_pointer(json.loads(text), ref.key)
    elif path.suffix == ".py":
        value = _python_key(text, ref.key)
    else:
        raise RefError(f"{ref.path}: references read .json (JSON pointer) or .py (NAME/key) files")
    return _number(value)


# ---------- owners, hot paths and the perf cron ----------

def owner_lanes(owners_md: str) -> frozenset[str]:
    """The owners a story may name: every PL-* lane, the Performance Lead and every agent name (a590) in the
    Owner column of OWNERS.md's table. People are not story owners."""
    lanes: set[str] = set()
    for line in owners_md.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not line.lstrip().startswith("|") or len(cells) < 3:
            continue
        owner = cells[2]
        lanes.update(OWNER_LANE_PATTERN.findall(owner))
        lanes.update(OWNER_AGENT_PATTERN.findall(owner))
        if OWNER_LEAD in owner:
            lanes.add(OWNER_LEAD)
    return frozenset(lanes)


def cron_parts(perf_cron_py: str) -> tuple[str, ...]:
    """The `name` of every entry of perf-cron.py's PARTS, read with ast (the module is never run)."""
    for node in ast.parse(perf_cron_py).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "PARTS" for t in node.targets):
            names = []
            for entry in getattr(node.value, "elts", []):
                for key, value in zip(getattr(entry, "keys", []), getattr(entry, "values", [])):
                    if isinstance(key, ast.Constant) and key.value == "name" and isinstance(value, ast.Constant):
                        names.append(value.value)
            return tuple(names)
    raise CatalogError("perf-cron.py has no PARTS list")


# ---------- loading and linting ----------

def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CatalogError(f"{path} does not exist") from None
    except json.JSONDecodeError as error:
        raise CatalogError(f"{path}: {error}") from None


def _numbers(node: Any, where: str) -> Iterable[tuple[str, Any]]:
    """Every number in a JSON document, with its location."""
    if isinstance(node, bool):
        return
    if isinstance(node, (int, float)):
        yield where, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from _numbers(value, f"{where}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _numbers(value, f"{where}[{index}]")


def _keys(problems: list[str], where: str, obj: Any, required: tuple[str, ...], optional: tuple[str, ...]) -> bool:
    if not isinstance(obj, dict):
        problems.append(f"{where}: not an object")
        return False
    missing = [k for k in required if k not in obj]
    unknown = sorted(set(obj) - set(required) - set(optional))
    if missing:
        problems.append(f"{where}: missing {', '.join(missing)}")
    if unknown:
        problems.append(f"{where}: unknown {', '.join(unknown)}")
    return not missing


def _is_text(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def _ref(problems: list[str], where: str, obj: Any, root: Path) -> Ref | None:
    if not (isinstance(obj, dict) and set(obj) == {"path", "key"} and _is_text(obj["path"]) and _is_text(obj["key"])):
        problems.append(f"{where}: a reference is exactly {{path, key}}")
        return None
    ref = Ref(obj["path"], obj["key"])
    try:
        resolve_ref(root, ref)
    except RefError as error:
        problems.append(f"{where}: {ref.describe()}: {error}")
    return ref


def _pattern(problems: list[str], where: str, value: Any) -> bool:
    if not _is_text(value):
        problems.append(f"{where}: not a non-empty string")
        return False
    try:
        re.compile(value)
    except re.error as error:
        problems.append(f"{where}: {value!r} is not a regex ({error})")
        return False
    return True


def _arm_shape(row: Row) -> tuple:
    """What a row judges with its engine's name taken out of the metric patterns (crash_survival.<engine>).
    Noise floors are left out: each engine's series has its own."""
    engine_name = re.compile(rf"(?<![A-Za-z]){re.escape(row.engine or '')}(?![A-Za-z])")
    checks = sorted((engine_name.sub("<engine>", c.metric), c.stat, c.op, c.value, c.unit) for c in row.checks)
    return (row.session or "", row.config or "", row.hz or 0, tuple(checks))


def engine_row_problems(target_id: str, rows: Iterable[Row]) -> list[str]:
    """F12: a browser target is judged per engine. Every row names chromium or webkit, both engines have rows,
    and the webkit rows judge exactly what the chromium rows judge (same checks and limits), so neither engine's
    arm can be dropped or loosened alone."""
    rows = list(rows)
    out = [f"row {r.id} of browser target {target_id} names no browser engine (chromium or webkit)"
           for r in rows if r.engine not in BROWSER_ENGINES]
    arms = {engine: sorted(_arm_shape(r) for r in rows if r.engine == engine) for engine in BROWSER_ENGINES}
    if not all(arms.values()):
        out.append(f"browser target {target_id} needs a chromium row and a webkit row (F12)")
    elif arms["chromium"] != arms["webkit"]:
        out.append(f"browser target {target_id}: its webkit rows do not judge the same checks as its chromium rows (F12)")
    return out


def _load_targets(root: Path, problems: list[str]) -> tuple[Target, ...]:
    doc = _read_json(root / TARGETS_PATH)
    where = TARGETS_PATH
    if not isinstance(doc, dict) or doc.get("schema") != TARGETS_SCHEMA:
        problems.append(f"{where}: schema is not {TARGETS_SCHEMA}")
        return ()
    for at, value in _numbers(doc, "$"):
        if not re.fullmatch(r"\$\.targets\[\d+\]\.rows\[\d+\]\.(checks\[\d+\]\.value|hz)", at):
            problems.append(f"{where}: copied threshold number {value} at {at}: reference it with floor_ref {{path, key}}")
    targets, target_ids, row_ids = [], set(), set()
    for ti, t in enumerate(doc.get("targets") or []):
        tw = f"{where}: targets[{ti}]"
        if not _keys(problems, tw, t, TARGET_KEYS, ()):
            continue
        if t["id"] in target_ids:
            problems.append(f"{tw}: duplicate target id {t['id']}")
        target_ids.add(t["id"])
        rows = []
        for ri, r in enumerate(t["rows"] if isinstance(t["rows"], list) else []):
            rw = f"{tw}.rows[{ri}]"
            if not _keys(problems, rw, r, ROW_REQUIRED, ROW_OPTIONAL):
                continue
            if not re.match(perf_result.NAME_PATTERN, str(r["id"])) or r["id"] in row_ids:
                problems.append(f"{rw}: row id {r['id']!r} is not a unique name")
            row_ids.add(r["id"])
            if "engine" in r and r["engine"] not in perf_result.ENGINES:
                problems.append(f"{rw}: engine {r['engine']!r} is not one of {', '.join(perf_result.ENGINES)}")
            if "session" in r and not re.match(perf_result.SESSION_PATTERN, str(r["session"])):
                problems.append(f"{rw}: session {r['session']!r} is not light, stress or corpus:<id>")
            if "config" in r and r["config"] not in STORY_CONFIGS:
                problems.append(f"{rw}: config {r['config']!r} is not one of {', '.join(STORY_CONFIGS)}")
            if "hz" in r and r["hz"] not in (60, 120):
                problems.append(f"{rw}: hz is 60 or 120")
            checks = []
            for ci, c in enumerate(r["checks"] if isinstance(r["checks"], list) else []):
                cw = f"{rw}.checks[{ci}]"
                if not _keys(problems, cw, c, CHECK_REQUIRED, CHECK_OPTIONAL):
                    continue
                _pattern(problems, f"{cw}.metric", c["metric"])
                if c["stat"] not in STATS:
                    problems.append(f"{cw}: stat {c['stat']!r} is not one of {', '.join(STATS)}")
                if c["op"] not in OPS:
                    problems.append(f"{cw}: op {c['op']!r} is not one of {', '.join(OPS)}")
                if c["unit"] not in perf_result.UNITS:
                    problems.append(f"{cw}: unit {c['unit']!r} is not a result-v1 unit")
                floor = _ref(problems, f"{cw}.floor_ref", c["floor_ref"], root) if "floor_ref" in c else None
                checks.append(Check(c["metric"], c["stat"], c["op"], c["value"], c["unit"], floor))
            if not checks:
                problems.append(f"{rw}: no checks")
            rows.append(Row(r["id"], t["id"], tuple(checks), r.get("engine"), r.get("session"), r.get("config"),
                            r.get("hz")))
        if not rows:
            problems.append(f"{tw}: no rows")
        if t["browser"] is True:
            problems.extend(f"{tw}: {problem}" for problem in engine_row_problems(t["id"], rows))
        targets.append(Target(t["id"], t["text"], t["browser"] is True, tuple(rows)))
    if len(targets) != TARGET_COUNT:
        problems.append(f"{where}: {len(targets)} targets; the program has exactly {TARGET_COUNT} (R4)")
    return tuple(targets)


def _load_story(root: Path, path: Path, problems: list[str], targets: tuple[Target, ...]) -> Story | None:
    where = f"{STORIES_DIR}/{path.name}"
    try:
        doc = _read_json(path)
    except CatalogError as error:
        problems.append(str(error))
        return None
    if not _keys(problems, where, doc, STORY_REQUIRED, STORY_OPTIONAL):
        return None
    for at, value in _numbers(doc, "$"):
        if at not in {f"$.{k}" for k in STORY_NUMBERS}:
            problems.append(f"{where}: copied threshold number {value} at {at}: "
                            "reference it with target_ref/floor_ref {path, key}")
    if doc["id"] != path.stem or not re.match(perf_result.NAME_PATTERN, str(doc["id"])):
        problems.append(f"{where}: id {doc['id']!r} must equal the file name and be a result-v1 name")
    if doc["tier"] not in TIERS:
        problems.append(f"{where}: tier {doc['tier']!r} is not one of {', '.join(TIERS)}")
    if not _is_text(doc["description"]):
        problems.append(f"{where}: description is empty")
    command = doc["command"]
    if not (isinstance(command, list) and command and all(isinstance(a, str) for a in command)):
        problems.append(f"{where}: command is a non-empty list of strings")
        command = []
    elif not re.match(perf_result.TARGET_PATH_PATTERN, command[0]) or not (root / command[0]).is_file():
        problems.append(f"{where}: command path {command[0]} does not exist in the repository")
    for flag, value in _flag_values(command):
        if THRESHOLD_FLAG.match(flag) and NUMBER_TEXT.match(value):
            problems.append(f"{where}: copied threshold number {value} in command flag {flag}: "
                            "the bench reads its limit from the file that owns it")
    if not re.match(perf_result.SESSION_PATTERN, str(doc["session"])):
        problems.append(f"{where}: session {doc['session']!r} is not light, stress or corpus:<id>")
    if doc["engine"] not in perf_result.ENGINES:
        problems.append(f"{where}: engine {doc['engine']!r} is not one of {', '.join(perf_result.ENGINES)}")
    configs = BUILDER_STORY_CONFIGS if doc["tier"] == "builder" else STORY_CONFIGS
    if not isinstance(doc["config"], str) or doc["config"] not in configs:
        problems.append(f"{where}: config is one of {', '.join(configs)} (one config, R6), got {doc['config']!r}")
    for key in STORY_NUMBERS:
        if isinstance(doc[key], bool) or not isinstance(doc[key], int) or doc[key] < 1:
            problems.append(f"{where}: {key} is an integer >= 1")
    needs = doc["needs"] if isinstance(doc["needs"], list) else []
    if not isinstance(doc["needs"], list):
        problems.append(f"{where}: needs is a list")
    for need in needs:
        if not isinstance(need, str) or not NEED_PATTERN.match(need):
            problems.append(f"{where}: need {need!r} is not <{'|'.join(NEED_KINDS)}>:<name>")
        elif need.startswith("file:") and not (root / need[5:]).is_file():
            problems.append(f"{where}: need {need} names a file that does not exist")
    if not _is_text(doc["owner"]):
        problems.append(f"{where}: owner is empty")
    if not isinstance(doc["component"], str) or not COMPONENT_PATTERN.match(doc["component"]):
        problems.append(f"{where}: component {doc['component']!r} is not Area>Sub (Chrome bug component form)")
    rows = {row.id: row for target in targets for row in target.rows}
    metrics, names = [], set()
    for mi, m in enumerate(doc["metrics"] if isinstance(doc["metrics"], list) else []):
        mw = f"{where}: metrics[{mi}]"
        if not _keys(problems, mw, m, METRIC_REQUIRED, METRIC_OPTIONAL):
            continue
        _pattern(problems, f"{mw}.name", m["name"])
        if m["name"] in names:
            problems.append(f"{mw}: metric {m['name']} is listed twice")
        names.add(m["name"])
        if m["unit"] not in perf_result.UNITS:
            problems.append(f"{mw}: unit {m['unit']!r} is not a result-v1 unit")
        if m["better"] not in perf_result.BETTER:
            problems.append(f"{mw}: better is lower or higher")
        target, target_ref = None, None
        ref = m.get("target_ref")
        if isinstance(ref, dict) and set(ref) == {"target"}:
            target = ref["target"]
            row = rows.get(target)
            if row is None:
                problems.append(f"{mw}: target {target!r} is not a targets.json row")
            else:
                _claim_problems(problems, mw, doc, m, row)
        elif ref is not None:
            target_ref = _ref(problems, f"{mw}.target_ref", ref, root)
        floor_ref = _ref(problems, f"{mw}.floor_ref", m["floor_ref"], root) if "floor_ref" in m else None
        metrics.append(Metric(m["name"], m["unit"], m["better"], target, target_ref, floor_ref))
    if not metrics:
        problems.append(f"{where}: no metrics")
    hot = doc.get("hot_paths", [])
    part = doc.get("perf_cron_part")
    if part is not None and not _is_text(part):
        problems.append(f"{where}: perf_cron_part is a part name")
    blocked = doc.get("not_measurable")
    if blocked is not None and not _is_text(blocked):
        problems.append(f"{where}: not_measurable is the reason the lab cannot run the story yet")
        blocked = repr(blocked)  # still not measurable: a malformed reason never puts a story into a round
    runs = doc.get("runs", [])
    if not (isinstance(runs, list) and all(isinstance(r, str) for r in runs)):
        problems.append(f"{where}: runs is a list of repository paths")
        runs = []
    for rel in runs:
        if not re.match(perf_result.TARGET_PATH_PATTERN, rel) or not (root / rel).is_file():
            problems.append(f"{where}: runs path {rel} does not exist in the repository")
        elif rel in command:
            problems.append(f"{where}: runs path {rel} is in the command already")
    return Story(
        id=str(doc["id"]), path=where, tier=doc["tier"], description=str(doc["description"]),
        command=tuple(command), session=str(doc["session"]), engine=str(doc["engine"]), config=str(doc["config"]),
        metrics=tuple(metrics), repeats=doc["repeats"] if isinstance(doc["repeats"], int) else 0,
        seconds=doc["seconds"] if isinstance(doc["seconds"], int) else 0,
        needs=tuple(n for n in needs if isinstance(n, str)), owner=str(doc["owner"]),
        component=str(doc["component"]), hot_paths=tuple(hot) if isinstance(hot, list) else (),
        perf_cron_part=part, not_measurable=blocked, runs=tuple(runs))


def _flag_values(command: list[str]) -> Iterable[tuple[str, str]]:
    """(--flag, value) for `--flag value` and `--flag=value` arguments."""
    for index, arg in enumerate(command):
        if arg.startswith("--") and "=" in arg:
            flag, _, value = arg.partition("=")
            yield flag, value
        elif arg.startswith("--") and index + 1 < len(command):
            yield arg, command[index + 1]


def _claim_problems(problems: list[str], where: str, story: dict, metric: dict, row: Row) -> None:
    """A metric that claims a target row must name one of its checks verbatim and fit the row's constraints."""
    check = next((c for c in row.checks if c.metric == metric["name"]), None)
    if check is None:
        problems.append(f"{where}: {metric['name']} is not a check of target row {row.id} "
                        f"({', '.join(c.metric for c in row.checks)})")
    elif check.unit != metric["unit"]:
        problems.append(f"{where}: unit {metric['unit']} differs from target row {row.id}'s {check.unit}")
    for field in ("engine", "session", "config"):
        want = getattr(row, field)
        if want is not None and story.get(field) != want:
            problems.append(f"{where}: target row {row.id} needs {field} {want}, the story has {story.get(field)}")


def load_catalog(root: Path = REPO_ROOT) -> Catalog:
    """Read every catalog input under root. Problems are collected, never raised, so one lint run lists them all.
    Raises CatalogError only when an input file is missing or is not JSON."""
    root = Path(root)
    problems: list[str] = []
    targets = _load_targets(root, problems)
    owners = owner_lanes((root / OWNERS_PATH).read_text(encoding="utf-8")) if (root / OWNERS_PATH).is_file() else None
    if owners is None:
        raise CatalogError(f"{root / OWNERS_PATH} does not exist")
    hot_doc = _read_json(root / HOT_PATHS_PATH)
    hot_paths = hot_doc.get("paths") if isinstance(hot_doc, dict) and isinstance(hot_doc.get("paths"), dict) else {}
    cron_file = root / PERF_CRON_PATH
    parts = cron_parts(cron_file.read_text(encoding="utf-8")) if cron_file.is_file() else ()
    story_dir = root / STORIES_DIR
    stories = []
    for path in sorted(story_dir.glob("*.json")) if story_dir.is_dir() else []:
        story = _load_story(root, path, problems, targets)
        if story is None:
            continue
        if story.owner not in owners:
            problems.append(f"{story.path}: owner {story.owner!r} is not an owner in {OWNERS_PATH}")
        for hot in story.hot_paths:
            if hot not in hot_paths:
                problems.append(f"{story.path}: hot path {hot!r} is not in {HOT_PATHS_PATH}")
        if story.perf_cron_part is not None and parts and story.perf_cron_part not in parts:
            problems.append(f"{story.path}: perf_cron_part {story.perf_cron_part!r} is not a perf-cron.py part")
        stories.append(story)
    t0 = sum(s.seconds for s in stories if s.tier == "T0")
    if t0 > T0_SECONDS_MAX:
        problems.append(f"{STORIES_DIR}: T0 stories sum to {t0} s, over the {T0_SECONDS_MAX} s T0 budget")
    covered = {s.perf_cron_part for s in stories}
    for part in parts:
        if part not in covered:
            problems.append(f"{STORIES_DIR}: perf-cron.py part {part} has no story (perf_cron_part)")
    return Catalog(root, tuple(stories), targets, owners, hot_paths, parts, tuple(problems))


# ---------- queries ----------

def claimed_checks(catalog: Catalog) -> dict[tuple[str, str], list[str]]:
    """(row id, check metric pattern) -> the stories that claim it."""
    claims: dict[tuple[str, str], list[str]] = {}
    for story in catalog.stories:
        for metric in story.metrics:
            if metric.target is not None:
                claims.setdefault((metric.target, metric.name), []).append(story.id)
    return claims


def uncovered_rows(catalog: Catalog) -> list[tuple[Row, list[str]]]:
    """Each target row with a check no story claims, and those checks' metric patterns, in targets.json order."""
    claims = claimed_checks(catalog)
    out = []
    for target in catalog.targets:
        for row in target.rows:
            missing = list(dict.fromkeys(c.metric for c in row.checks if (row.id, c.metric) not in claims))
            if missing:
                out.append((row, missing))
    return out


def mapped_targets(catalog: Catalog) -> list[tuple[Target, bool]]:
    """Each target and whether every check of every row has a story."""
    open_rows = {row.id for row, _ in uncovered_rows(catalog)}
    return [(t, not any(r.id in open_rows for r in t.rows)) for t in catalog.targets]


def uncovered_hot_paths(catalog: Catalog) -> list[str]:
    """perf-hot-benches.json path ids that no story lists in hot_paths."""
    covered = {hot for story in catalog.stories for hot in story.hot_paths}
    return [path_id for path_id in catalog.hot_paths if path_id not in covered]


def story_for_row(catalog: Catalog, row_name: str) -> list[Story]:
    """The stories with a metric pattern that full-matches a result row name."""
    return [s for s in catalog.stories if any(re.fullmatch(m.name, row_name) for m in s.metrics)]


# ---------- commands (lab.py protocol, task 005) ----------

LAB_COMMANDS = {
    "stories": "List the lab stories (stories.d/); --lint checks owners, paths, configs and copied thresholds.",
    "targets": "The 12 fixed targets: --check prints N/12 mapped, --uncovered prints each row no story claims.",
    "hot-paths": "perf-hot-benches.json paths: --uncovered prints each hot path whose bench is not a lab story.",
}


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    if command == "stories":
        parser.add_argument("--lint", action="store_true", help="exit 1 when any catalog problem is found")
        parser.add_argument("--format", choices=("text", "paths"), default="text",
                            help="paths: print each story's command path, one per line (MQ4)")
        parser.add_argument("--orphans", action="store_true",
                            help="MQ12: print each perf script that is not a story and not in retired.json (orphans.py)")
        parser.add_argument("--json", action="store_true", help="with --orphans: one JSON list of paths (done check 8)")
    elif command == "targets":
        mode = parser.add_mutually_exclusive_group(required=True)
        mode.add_argument("--check", action="store_true", help="print N/12 mapped; exit 1 unless 12/12")
        mode.add_argument("--uncovered", action="store_true", help="print each target row no story claims (MQ8)")
    elif command == "hot-paths":
        parser.add_argument("--uncovered", action="store_true", required=True,
                            help="print each perf-hot path whose bench is not a story (MQ9)")


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    if command == "stories" and args.orphans:
        return _load_sibling("orphans").run_orphans(args.root, args.json, out, err)
    try:
        catalog = load_catalog(args.root)
    except (CatalogError, OSError, SyntaxError) as error:
        print(f"catalog: {error}", file=err)
        return 2
    if command == "stories":
        return _run_stories(catalog, args, out, err)
    if catalog.problems:
        for problem in catalog.problems:
            print(problem, file=err)
        print(f"catalog: {len(catalog.problems)} problems; run `lab.py stories --lint`", file=err)
        return 2
    if command == "targets" and args.check:
        mapped = mapped_targets(catalog)
        open_rows = {row.id for row, _ in uncovered_rows(catalog)}
        for target, ok in mapped:
            rows = [r.id for r in target.rows if r.id in open_rows]
            print(f"{'ok' if ok else 'unmapped'} {target.id}" + ("" if ok else f" (rows: {', '.join(rows)})"), file=out)
        count = sum(ok for _, ok in mapped)
        print(f"targets mapped: {count}/{len(mapped)}", file=out)
        return 0 if count == len(mapped) == TARGET_COUNT else 1
    if command == "targets":
        for row, missing in uncovered_rows(catalog):
            print(f"{row.target_id}\t{row.id}\t{' '.join(missing)}", file=out)
        return 0
    for path_id in uncovered_hot_paths(catalog):
        entry = catalog.hot_paths[path_id]
        print(f"{path_id}\t{entry.get('owner', '')}\t{entry.get('bench', '')}", file=out)
    return 0


def _run_stories(catalog: Catalog, args: argparse.Namespace, out, err) -> int:
    if args.format == "paths":
        for path in sorted({s.command[0] for s in catalog.stories if s.command}):
            print(path, file=out)
    elif not args.lint:
        for s in catalog.stories:
            blocked = "" if s.measurable() else f"\tnot measurable: {s.not_measurable}"
            print(f"{s.id}\t{s.tier}\t{s.seconds}s\t{s.config}\t{s.owner}{blocked}", file=out)
    if args.lint:
        report = err if args.format == "paths" else out
        for problem in catalog.problems:
            print(problem, file=report)
        print(f"stories: {len(catalog.stories)}, problems: {len(catalog.problems)}", file=report)
        return 1 if catalog.problems else 0
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="catalog.py", description="The perf lab story catalog.")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)
    for name, text in LAB_COMMANDS.items():
        add_arguments(name, sub.add_parser(name, help=text, description=text))
    args = parser.parse_args(argv)
    return run(args.command, args)


if __name__ == "__main__":
    sys.exit(main())
