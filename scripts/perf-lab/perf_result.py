"""cmux-perf-result/v1: the one result format of the perf lab.

Schema: schemas/perf/result-v1.schema.json. Every bench writes its raw samples
through this module (or BenchApp.record, which calls it), and the lab ingest
reads them back with read_dir()/read_file().

Stdlib only, Python 3.9+, and safe to load by file path under ``python3 -I``
without being on sys.path or in sys.modules::

    spec = importlib.util.spec_from_file_location("perf_result", path)
    perf_result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(perf_result)

On disk a result directory holds ``*.ndjson`` files, one result per line.
Every result names the run that measured it (``run.id``, ``run.started_at``),
as catapult adds BENCHMARK_START and LABEL diagnostics to every histogram set
(tracing/tracing/value/diagnostics/reserved_infos.py). write_ndjson() names
each file by the sha256 of its bytes and renames it into place, so parallel
writers never collide, two runs with equal samples make two files, and only a
retry of the same write (same run id) gives the same file again.
"""

import dataclasses
import hashlib
import json
import math
import os
import re
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Union

SCHEMA_ID = "cmux-perf-result/v1"

# Keep these in sync with schemas/perf/result-v1.schema.json; the tests compare
# them with the schema and run every fixture through both.
NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._:-]*$"
TARGET_PATH_PATTERN = r"^(?!/)(?!.*(^|/)\.\.(/|$))[A-Za-z0-9._/-]+$"
SHA_PATTERN = r"^[0-9a-f]{40}$"
FINGERPRINT_PATTERN = r"^[0-9a-f]{64}$"
MACOS_PATTERN = r"^[0-9]+(\.[0-9]+){0,2}$"
MACOS_BUILD_PATTERN = r"^[0-9]+[A-Z][0-9]+[a-z]?$"
SESSION_PATTERN = r"^(light|stress|corpus:[A-Za-z0-9][A-Za-z0-9._-]*)$"
FEATURE_NAME_PATTERN = r"^[A-Za-z][A-Za-z0-9_.-]*$"
DIGEST_PATTERN = r"^sha256:[0-9a-f]{64}$"
ATTACHMENT_KIND_PATTERN = r"^[a-z][a-z0-9_-]*$"
STARTED_AT_PATTERN = (
    r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"
    r"T([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\.[0-9]{1,9})?Z$"
)
# The largest finite float64. Samples and display_hz must fit one (perf_stats
# math, SQLite REAL); a JSON integer has no bound of its own.
NUMBER_LIMIT = 1.7976931348623157e308

UNITS = (
    "ms",
    "us",
    "ns",
    "s",
    "count",
    "ratio",
    "percent",
    "bytes",
    "bytes_per_s",
    "mW",
    "J",
    "Hz",
    "fps",
    "per_s",
    "score",
    "unitless",
)
# The export of each unit to catapult's histogram units
# (third_party/catapult/tracing/tracing/value/histogram.py UNIT_NAMES):
# the catapult unit and the factor that converts a cmux sample to it.
CATAPULT_UNITS = {
    "ms": ("ms", 1.0),
    "us": ("ms", 1e-3),
    "ns": ("ms", 1e-6),
    "s": ("ms", 1e3),
    "count": ("count", 1.0),
    "ratio": ("unitless", 1.0),
    "percent": ("n%", 1e-2),
    "bytes": ("sizeInBytes", 1.0),
    "bytes_per_s": ("bytesPerSecond", 1.0),
    "mW": ("W", 1e-3),
    "J": ("J", 1.0),
    "Hz": ("Hz", 1.0),
    "fps": ("Hz", 1.0),
    "per_s": ("Hz", 1.0),
    "score": ("unitless", 1.0),
    "unitless": ("unitless", 1.0),
}
BETTER = ("lower", "higher")
# better -> catapult's improvement_direction suffix of the unit name.
CATAPULT_IMPROVEMENT_DIRECTION = {"lower": "smallerIsBetter", "higher": "biggerIsBetter"}
CONFIGS = ("debug", "bench", "bench-checks", "release")
ENGINES = ("chromium", "webkit", "none")
FEATURE_STATES = ("on", "off")
FEATURE_SOURCES = ("policy", "env", "local", "remote", "study", "default")
SAFE_MODES = ("off", "inactive", "last_known_good", "no_remote", None)

TOP_LEVEL_KEYS = (
    "schema",
    "run",
    "story",
    "metric",
    "unit",
    "better",
    "samples",
    "target_ref",
    "build",
    "host",
    "engine",
    "session",
    "features",
    "features_hash",
    "safe_mode",
    "attachments",
)
RUN_KEYS = ("id", "started_at")
BUILD_KEYS = ("sha", "config", "measure_version")
HOST_KEYS = ("fingerprint", "class", "chip", "macos", "macos_build", "display_hz")

# Result files are write-once: everyone may read them, only the writer owns them.
RESULT_FILE_MODE = 0o644


class ResultError(ValueError):
    """A result that is not valid cmux-perf-result/v1, or a file that holds one."""


@dataclasses.dataclass
class Run:
    """One bench run. Every result of the run carries it, so two runs never merge.

    ``id`` is a uuid4 hex by default, or the caller's stable attempt id (for
    example a controller job and attempt), so that a retry of the same attempt
    rewrites the same file instead of adding a repeat.
    """

    id: str
    started_at: str

    def to_dict(self) -> Dict[str, str]:
        return {"id": self.id, "started_at": self.started_at}

    @classmethod
    def start(
        cls,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        run_id: Optional[str] = None,
    ) -> "Run":
        """A run that starts at ``now()`` (an aware datetime), with a new uuid4 id unless ``run_id`` is given."""
        started = now().astimezone(timezone.utc)
        return cls(
            id=uuid.uuid4().hex if run_id is None else run_id,
            started_at=started.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        )


@dataclasses.dataclass
class TargetRef:
    """A targets.json id, or a key in an existing threshold file (path + key)."""

    target: Optional[str] = None
    path: Optional[str] = None
    key: Optional[str] = None

    def to_dict(self) -> Dict[str, str]:
        fields = (("target", self.target), ("path", self.path), ("key", self.key))
        return {name: value for name, value in fields if value is not None}

    @classmethod
    def from_dict(cls, obj: Dict[str, str]) -> "TargetRef":
        return cls(target=obj.get("target"), path=obj.get("path"), key=obj.get("key"))


@dataclasses.dataclass
class Build:
    sha: str
    config: str
    measure_version: int

    def to_dict(self) -> Dict[str, Any]:
        return {"sha": self.sha, "config": self.config, "measure_version": _integral(self.measure_version)}

    @classmethod
    def from_dict(cls, obj: Dict[str, Any]) -> "Build":
        return cls(sha=obj["sha"], config=obj["config"], measure_version=_integral(obj["measure_version"]))


@dataclasses.dataclass
class Host:
    fingerprint: str
    host_class: str
    chip: str
    macos: Optional[str]
    macos_build: Optional[str]
    display_hz: Optional[float]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "fingerprint": self.fingerprint,
            "class": self.host_class,
            "chip": self.chip,
            "macos": self.macos,
            "macos_build": self.macos_build,
            "display_hz": self.display_hz,
        }

    @classmethod
    def from_dict(cls, obj: Dict[str, Any]) -> "Host":
        return cls(
            fingerprint=obj["fingerprint"],
            host_class=obj["class"],
            chip=obj["chip"],
            macos=obj["macos"],
            macos_build=obj["macos_build"],
            display_hz=obj["display_hz"],
        )


@dataclasses.dataclass
class Feature:
    state: str
    source: str

    def to_dict(self) -> Dict[str, str]:
        return {"state": self.state, "source": self.source}


@dataclasses.dataclass
class Attachment:
    digest: str
    kind: str

    def to_dict(self) -> Dict[str, str]:
        return {"digest": self.digest, "kind": self.kind}


@dataclasses.dataclass
class Result:
    story: str
    metric: str
    unit: str
    better: str
    samples: List[float]
    build: Build
    host: Host
    engine: str
    session: str
    run: Run
    target_ref: Optional[TargetRef] = None
    features: Dict[str, Feature] = dataclasses.field(default_factory=dict)
    features_hash: Optional[str] = None
    safe_mode: Optional[str] = None
    attachments: List[Attachment] = dataclasses.field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        """The result-v1 object; raises ResultError naming a field of the wrong type."""
        _require_type("run", self.run, Run)
        _require_type("build", self.build, Build)
        _require_type("host", self.host, Host)
        if self.target_ref is not None:
            _require_type("target_ref", self.target_ref, TargetRef)
        _require_type("samples", self.samples, (list, tuple))
        _require_type("features", self.features, dict)
        for name, feature in self.features.items():
            _require_type("features key", name, str)
            _require_type(f"features.{name}", feature, Feature)
        _require_type("attachments", self.attachments, (list, tuple))
        for index, attachment in enumerate(self.attachments):
            _require_type(f"attachments[{index}]", attachment, Attachment)
        return {
            "schema": SCHEMA_ID,
            "run": self.run.to_dict(),
            "story": self.story,
            "metric": self.metric,
            "unit": self.unit,
            "better": self.better,
            "samples": list(self.samples),
            "target_ref": None if self.target_ref is None else self.target_ref.to_dict(),
            "build": self.build.to_dict(),
            "host": self.host.to_dict(),
            "engine": self.engine,
            "session": self.session,
            "features": {name: feature.to_dict() for name, feature in sorted(self.features.items())},
            "features_hash": self.features_hash,
            "safe_mode": self.safe_mode,
            "attachments": [attachment.to_dict() for attachment in self.attachments],
        }

    @classmethod
    def from_dict(cls, obj: Any, repo_root: Optional[Union[str, Path]] = None) -> "Result":
        """Validates ``obj`` as result-v1 and builds the Result; raises ResultError."""
        _raise_if_invalid(obj, repo_root)
        target_ref = obj["target_ref"]
        return cls(
            story=obj["story"],
            metric=obj["metric"],
            unit=obj["unit"],
            better=obj["better"],
            samples=list(obj["samples"]),
            build=Build.from_dict(obj["build"]),
            host=Host.from_dict(obj["host"]),
            engine=obj["engine"],
            session=obj["session"],
            run=Run(**obj["run"]),
            target_ref=None if target_ref is None else TargetRef.from_dict(target_ref),
            features={name: Feature(**value) for name, value in obj["features"].items()},
            features_hash=obj["features_hash"],
            safe_mode=obj["safe_mode"],
            attachments=[Attachment(**value) for value in obj["attachments"]],
        )

    def validate(self, repo_root: Optional[Union[str, Path]] = None) -> None:
        """Raises ResultError naming every invalid field.

        With ``repo_root``, a path target_ref must name an existing file under it.
        """
        _raise_if_invalid(self.to_dict(), repo_root)

    def write_ndjson(self, directory: Union[str, Path], repo_root: Optional[Union[str, Path]] = None) -> Path:
        return write_ndjson(directory, [self], repo_root)


def validation_errors(obj: Any, repo_root: Optional[Union[str, Path]] = None) -> List[str]:
    """Returns one "field: reason" line per schema violation of ``obj`` (empty if valid)."""
    errors: List[str] = []
    if not isinstance(obj, dict):
        return ["result: not an object"]
    _check_keys(errors, "result", obj, TOP_LEVEL_KEYS)
    if "schema" in obj and obj["schema"] != SCHEMA_ID:
        errors.append(f"schema: not {SCHEMA_ID}")
    if "run" in obj:
        _check_run(errors, obj["run"])
    _check_pattern(errors, "story", obj, NAME_PATTERN)
    _check_pattern(errors, "metric", obj, NAME_PATTERN)
    _check_enum(errors, "unit", obj, UNITS)
    _check_enum(errors, "better", obj, BETTER)
    if "samples" in obj:
        _check_samples(errors, obj["samples"])
    if "target_ref" in obj:
        _check_target_ref(errors, obj["target_ref"], repo_root)
    if "build" in obj:
        _check_build(errors, obj["build"])
    if "host" in obj:
        _check_host(errors, obj["host"])
    _check_enum(errors, "engine", obj, ENGINES)
    _check_pattern(errors, "session", obj, SESSION_PATTERN)
    if "features" in obj:
        _check_features(errors, obj["features"])
    if obj.get("features_hash") is not None and not _is_nonempty_string(obj["features_hash"]):
        errors.append("features_hash: not a non-empty string or null")
    _check_enum(errors, "safe_mode", obj, SAFE_MODES)
    if "attachments" in obj:
        _check_attachments(errors, obj["attachments"])
    return errors


def write_ndjson(
    directory: Union[str, Path],
    results: Iterable[Result],
    repo_root: Optional[Union[str, Path]] = None,
) -> Path:
    """Validates every result, then writes them as one new .ndjson file in ``directory``.

    Nothing is written when any result is invalid (ResultError). With
    ``repo_root``, a path target_ref must name an existing file under it. That
    check runs at write time only, so a threshold file renamed later never
    makes stored results unreadable. Returns the file's path.
    """
    results = list(results)
    if not results:
        raise ResultError("write_ndjson: no results to write")
    lines = []
    for index, result in enumerate(results):
        if not isinstance(result, Result):
            raise ResultError(f"result {index}: not a Result but {type(result).__name__}")
        try:
            obj = result.to_dict()
        except ResultError as error:
            raise ResultError(f"result {index} ({result.story!r}/{result.metric!r}): {error}") from None
        errors = validation_errors(obj, repo_root)
        if errors:
            raise ResultError(f"result {index} ({obj['story']!r}/{obj['metric']!r}): " + "; ".join(errors))
        lines.append(json.dumps(obj, sort_keys=True, separators=(",", ":"), allow_nan=False))
    data = ("\n".join(lines) + "\n").encode("utf-8")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"result-{hashlib.sha256(data).hexdigest()[:32]}.ndjson"
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            # mkstemp makes the file 0600, and the ingest may run as another user.
            os.fchmod(handle.fileno(), RESULT_FILE_MODE)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return path


def read_file(path: Union[str, Path]) -> List[Result]:
    """Reads one .ndjson file; raises ResultError naming the path, line and reasons.

    A file is one atomic write, so one bad line rejects the whole file.
    target_ref paths are not checked against the current tree (see write_ndjson).
    """
    path = Path(path)
    results = []
    try:
        text = path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as error:
        raise ResultError(f"{path}: not UTF-8 ({error})") from None
    except OSError as error:
        raise ResultError(f"{path}: cannot read ({error.strerror or error})") from None
    for number, line in enumerate(text.split("\n"), start=1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line, object_pairs_hook=_unique_keys, parse_constant=_reject_constant)
            results.append(Result.from_dict(obj))
        except ValueError as error:
            raise ResultError(f"{path}:{number}: {error}") from None
        except RecursionError:
            raise ResultError(f"{path}:{number}: JSON nested too deeply") from None
    return results


def read_dir(
    directory: Union[str, Path],
    on_error: Optional[Callable[[ResultError], None]] = None,
) -> List[Result]:
    """Reads every ``*.ndjson`` file of ``directory`` (not recursive), files in name order.

    Without ``on_error`` the first bad file raises its ResultError. With it,
    each bad file's ResultError goes to ``on_error``, that file is skipped and
    the other files are still read.
    """
    results = []
    for path in sorted(Path(directory).glob("*.ndjson")):
        if path.name.startswith("."):
            continue
        try:
            results.extend(read_file(path))
        except ResultError as error:
            if on_error is None:
                raise
            on_error(error)
    return results


def _raise_if_invalid(obj: Any, repo_root: Optional[Union[str, Path]]) -> None:
    errors = validation_errors(obj, repo_root)
    if errors:
        raise ResultError("; ".join(errors))


def _unique_keys(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ResultError(f"duplicate key {key!r}")
        obj[key] = value
    return obj


def _reject_constant(name):
    raise ResultError(f"{name} is not a JSON number")


def _require_type(field: str, value: Any, expected) -> None:
    if not isinstance(value, expected):
        types = expected if isinstance(expected, tuple) else (expected,)
        raise ResultError(f"{field}: {type(value).__name__} is not a {' or '.join(t.__name__ for t in types)}")


def _integral(value: Any) -> Any:
    """1.0 -> 1: JSON Schema 2020-12 counts a number with a zero fraction as an integer."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _is_integer(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    return isinstance(value, int) or (isinstance(value, float) and value.is_integer())


def _is_number(value: Any) -> bool:
    """A JSON number that fits a finite float64; ints are compared exactly, never converted."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, float) and not math.isfinite(value):
        return False
    return -NUMBER_LIMIT <= value <= NUMBER_LIMIT


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and value != ""


def _matches(pattern: str, value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def _check_keys(errors: List[str], where: str, obj: Dict[str, Any], keys) -> None:
    for key in keys:
        if key not in obj:
            errors.append(f"{where}: missing {key}")
    for key in obj:
        if key not in keys:
            errors.append(f"{where}: unknown key {key}")


def _check_enum(errors: List[str], field: str, obj: Dict[str, Any], allowed) -> None:
    if field in obj and obj[field] not in allowed:
        errors.append(f"{field}: {obj[field]!r} is not one of {', '.join(str(value) for value in allowed)}")


def _check_pattern(errors: List[str], field: str, obj: Dict[str, Any], pattern: str) -> None:
    if field in obj and not _matches(pattern, obj[field]):
        errors.append(f"{field}: {obj[field]!r} does not match {pattern}")


def _check_run(errors: List[str], run: Any) -> None:
    if not isinstance(run, dict):
        errors.append("run: not an object")
        return
    _check_keys(errors, "run", run, RUN_KEYS)
    if "id" in run and not _matches(NAME_PATTERN, run["id"]):
        errors.append(f"run.id: {run['id']!r} does not match {NAME_PATTERN}")
    if "started_at" in run and not _matches(STARTED_AT_PATTERN, run["started_at"]):
        errors.append(f"run.started_at: {run['started_at']!r} is not an RFC 3339 UTC time ending in Z")


def _check_samples(errors: List[str], samples: Any) -> None:
    if not isinstance(samples, list):
        errors.append("samples: not a list")
    elif not samples:
        errors.append("samples: empty; a result needs at least one raw sample")
    else:
        bad = [index for index, sample in enumerate(samples) if not _is_number(sample)]
        if bad:
            errors.append(f"samples: entries {bad[:5]} are not finite float64 numbers")


def _check_target_ref(errors: List[str], ref: Any, repo_root: Optional[Union[str, Path]]) -> None:
    if ref is None:
        return
    if not isinstance(ref, dict):
        errors.append("target_ref: not an object or null")
    elif set(ref) == {"target"}:
        if not _matches(NAME_PATTERN, ref["target"]):
            errors.append(f"target_ref.target: {ref['target']!r} does not match {NAME_PATTERN}")
    elif set(ref) == {"path", "key"}:
        if not _matches(TARGET_PATH_PATTERN, ref["path"]):
            errors.append(f"target_ref.path: {ref['path']!r} is not a repository-relative path")
        elif repo_root is not None and not (Path(repo_root) / ref["path"]).is_file():
            errors.append(f"target_ref.path: {ref['path']} does not exist under {repo_root}")
        if not _is_nonempty_string(ref["key"]):
            errors.append("target_ref.key: not a non-empty string")
    else:
        errors.append("target_ref: needs exactly {target} or {path, key}")


def _check_build(errors: List[str], build: Any) -> None:
    if not isinstance(build, dict):
        errors.append("build: not an object")
        return
    _check_keys(errors, "build", build, BUILD_KEYS)
    if "sha" in build and not _matches(SHA_PATTERN, build["sha"]):
        errors.append(f"build.sha: {build['sha']!r} is not a full 40-hex commit sha")
    if "config" in build and build["config"] not in CONFIGS:
        errors.append(f"build.config: {build['config']!r} is not one of {', '.join(CONFIGS)}")
    version = build.get("measure_version")
    if "measure_version" in build and not (_is_integer(version) and version >= 1):
        errors.append(f"build.measure_version: {version!r} is not an integer >= 1")


def _check_host(errors: List[str], host: Any) -> None:
    if not isinstance(host, dict):
        errors.append("host: not an object")
        return
    _check_keys(errors, "host", host, HOST_KEYS)
    if "fingerprint" in host and not _matches(FINGERPRINT_PATTERN, host["fingerprint"]):
        errors.append(f"host.fingerprint: {host['fingerprint']!r} is not a sha256 hex digest")
    for field in ("class", "chip"):
        if field in host and not _is_nonempty_string(host[field]):
            errors.append(f"host.{field}: not a non-empty string")
    for field, pattern in (("macos", MACOS_PATTERN), ("macos_build", MACOS_BUILD_PATTERN)):
        if host.get(field) is not None and not _matches(pattern, host[field]):
            errors.append(f"host.{field}: {host[field]!r} does not match {pattern}")
    hz = host.get("display_hz")
    if hz is not None and not (_is_number(hz) and hz > 0):
        errors.append(f"host.display_hz: {hz!r} is not a finite number > 0 or null")


def _check_features(errors: List[str], features: Any) -> None:
    if not isinstance(features, dict):
        errors.append("features: not an object")
        return
    for name, value in features.items():
        where = f"features.{name}"
        if not _matches(FEATURE_NAME_PATTERN, name):
            errors.append(f"{where}: name does not match {FEATURE_NAME_PATTERN}")
        if not isinstance(value, dict):
            errors.append(f"{where}: not an object")
            continue
        _check_keys(errors, where, value, ("state", "source"))
        if "state" in value and value["state"] not in FEATURE_STATES:
            errors.append(f"{where}.state: {value['state']!r} is not on or off")
        if "source" in value and value["source"] not in FEATURE_SOURCES:
            errors.append(f"{where}.source: {value['source']!r} is not one of {', '.join(FEATURE_SOURCES)}")


def _check_attachments(errors: List[str], attachments: Any) -> None:
    if not isinstance(attachments, list):
        errors.append("attachments: not a list")
        return
    for index, value in enumerate(attachments):
        where = f"attachments[{index}]"
        if not isinstance(value, dict):
            errors.append(f"{where}: not an object")
            continue
        _check_keys(errors, where, value, ("digest", "kind"))
        if "digest" in value and not _matches(DIGEST_PATTERN, value["digest"]):
            errors.append(f"{where}.digest: {value['digest']!r} is not sha256:<64 hex>")
        if "kind" in value and not _matches(ATTACHMENT_KIND_PATTERN, value["kind"]):
            errors.append(f"{where}.kind: {value['kind']!r} does not match {ATTACHMENT_KIND_PATTERN}")
