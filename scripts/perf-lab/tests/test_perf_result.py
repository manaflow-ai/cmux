"""Tests for scripts/perf-lab/perf_result.py and schemas/perf/result-v1.schema.json.

Run: python3 -m unittest scripts/perf-lab/tests/test_perf_result.py
"""

import ast
import copy
import importlib.util
import json
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODULE_PATH = HERE.parent / "perf_result.py"
REPO_ROOT = HERE.parents[2]
SCHEMA_PATH = REPO_ROOT / "schemas" / "perf" / "result-v1.schema.json"


def load_by_path():
    """Loads perf_result the way benches do: by file path, not via sys.path or sys.modules."""
    spec = importlib.util.spec_from_file_location("perf_result_under_test", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pr = load_by_path()
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

SHA = "0123456789abcdef0123456789abcdef01234567"
FINGERPRINT = "ab" * 32
DIGEST = "sha256:" + "cd" * 32
RUN_ID = "5f0c3a9e2b7d4c18a6e1f0b2c3d4e5f6"
STARTED_AT = "2026-10-25T12:00:00.123456Z"
CATAPULT_UNIT_NAMES = {
    # third_party/catapult/tracing/tracing/value/histogram.py UNIT_NAMES
    "ms", "msBestFitFormat", "tsMs", "n%", "sizeInBytes", "bytesPerSecond", "J", "W",
    "A", "Ah", "V", "Hz", "unitless", "count", "sigma",
}


def schema_errors(instance, schema=SCHEMA, root=SCHEMA, where="$"):
    """A JSON Schema 2020-12 evaluator for the keywords result-v1 uses.

    It lets the tests check validate() against the schema itself, with no
    third-party jsonschema package. An unknown keyword fails loudly so the
    evaluator cannot silently skip a constraint added to the schema later.
    """
    known = {
        "$schema", "$id", "$ref", "title", "description", "type", "const", "enum",
        "required", "properties", "additionalProperties", "propertyNames", "items",
        "minItems", "minLength", "pattern", "minimum", "maximum", "exclusiveMinimum", "oneOf",
    }
    unknown = set(schema) - known
    if unknown:
        raise AssertionError(f"evaluator does not support {sorted(unknown)}")
    errors = []
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        errors += schema_errors(instance, node, root, where)
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        checks = {
            "null": lambda v: v is None,
            "string": lambda v: isinstance(v, str),
            "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
            # 2020-12: an integer is any number with a zero fractional part, so 1.0 is one.
            "integer": lambda v: not isinstance(v, bool)
            and (isinstance(v, int) or (isinstance(v, float) and v.is_integer())),
            "object": lambda v: isinstance(v, dict),
            "array": lambda v: isinstance(v, list),
        }
        if not any(checks[t](instance) for t in types):
            return errors + [f"{where}: type"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{where}: const")
    if "enum" in schema and not any(type(instance) is type(v) and instance == v for v in schema["enum"]):
        errors.append(f"{where}: enum")
    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            errors.append(f"{where}: minLength")
        # ECMA-262 `$` (no multiline flag) is end of input; Python's `$` also matches before a final newline.
        if "pattern" in schema and re.search(schema["pattern"].replace("$", r"\Z"), instance) is None:
            errors.append(f"{where}: pattern")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{where}: minimum")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{where}: maximum")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            errors.append(f"{where}: exclusiveMinimum")
    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            errors.append(f"{where}: minItems")
        if "items" in schema:
            for index, item in enumerate(instance):
                errors += schema_errors(item, schema["items"], root, f"{where}[{index}]")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{where}: required {key}")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if "propertyNames" in schema:
                errors += schema_errors(key, schema["propertyNames"], root, f"{where}.<{key}>")
            if key in properties:
                errors += schema_errors(value, properties[key], root, f"{where}.{key}")
            elif schema.get("additionalProperties") is False:
                errors.append(f"{where}: additional {key}")
            elif isinstance(schema.get("additionalProperties"), dict):
                errors += schema_errors(value, schema["additionalProperties"], root, f"{where}.{key}")
    if "oneOf" in schema:
        passing = sum(1 for sub in schema["oneOf"] if not schema_errors(instance, sub, root, where))
        if passing != 1:
            errors.append(f"{where}: oneOf matched {passing}")
    return errors


def valid_dict():
    return {
        "schema": "cmux-perf-result/v1",
        "run": {"id": RUN_ID, "started_at": STARTED_AT},
        "story": "terminal-key-to-frame",
        "metric": "cmd_w.light.key_to_frame",
        "unit": "ms",
        "better": "lower",
        "samples": [4.25, 3.5, 5, 4.0],
        "target_ref": {"target": "key-to-frame"},
        "build": {"sha": SHA, "config": "bench", "measure_version": 1},
        "host": {
            "fingerprint": FINGERPRINT,
            "class": "m6-16gb-120hz",
            "chip": "Apple M6",
            "macos": "26.1",
            "macos_build": "25B78",
            "display_hz": 120,
        },
        "engine": "chromium",
        "session": "light",
        "features": {
            "perfLabKillProbe": {"state": "off", "source": "remote"},
            "instantTabs": {"state": "on", "source": "default"},
        },
        "features_hash": "9f2c01aa",
        "safe_mode": "off",
        "attachments": [{"digest": DIGEST, "kind": "trace"}],
    }


def make_result(**overrides):
    fields = dict(
        story="split-spring",
        metric="pane.split.frame_ms",
        unit="ms",
        better="lower",
        samples=[8.1, 8.3, 7.9],
        build=pr.Build(sha=SHA, config="bench", measure_version=1),
        host=pr.Host(
            fingerprint=FINGERPRINT,
            host_class="m6-16gb-120hz",
            chip="Apple M6",
            macos="26.1",
            macos_build="25B78",
            display_hz=120.0,
        ),
        engine="none",
        session="stress",
        run=pr.Run(id=RUN_ID, started_at=STARTED_AT),
    )
    fields.update(overrides)
    return pr.Result(**fields)


def mutated(path, value=None, delete=False):
    obj = valid_dict()
    node = obj
    for part in path[:-1]:
        node = node[part]
    if delete:
        del node[path[-1]]
    else:
        node[path[-1]] = value
    return obj


# (name, instance, valid?) run through both the schema and validate().
CASES = [
    ("valid", valid_dict(), True),
    ("no target, no features, linux host", {
        **valid_dict(),
        "target_ref": None,
        "features": {},
        "features_hash": None,
        "safe_mode": None,
        "attachments": [],
        "host": {**valid_dict()["host"], "macos": None, "macos_build": None, "display_hz": None},
    }, True),
    ("file target", mutated(["target_ref"], {"path": "scripts/measure/perf-gate.json", "key": "cmd_t.p95"}), True),
    ("corpus session", mutated(["session"], "corpus:agent-swarm"), True),
    ("beta macOS build", mutated(["host", "macos_build"], "25A5279m"), True),
    ("higher is better", mutated(["better"], "higher"), True),
    ("missing samples", mutated(["samples"], delete=True), False),
    ("empty samples", mutated(["samples"], []), False),
    ("string sample", mutated(["samples"], [1, "2"]), False),
    ("bool sample", mutated(["samples"], [True]), False),
    ("missing unit", mutated(["unit"], delete=True), False),
    ("unknown unit", mutated(["unit"], "milliseconds"), False),
    ("missing engine", mutated(["engine"], delete=True), False),
    ("unknown engine", mutated(["engine"], "gecko"), False),
    ("unknown config", mutated(["build", "config"], "profile"), False),
    ("missing config", mutated(["build", "config"], delete=True), False),
    ("short sha", mutated(["build", "sha"], "0123456"), False),
    ("upper-case sha", mutated(["build", "sha"], SHA.upper()), False),
    ("measure_version 0", mutated(["build", "measure_version"], 0), False),
    ("measure_version bool", mutated(["build", "measure_version"], True), False),
    ("measure_version 1.0 is an integer", mutated(["build", "measure_version"], 1.0), True),
    ("measure_version 1.5", mutated(["build", "measure_version"], 1.5), False),
    ("sample past float64", mutated(["samples"], [1, 10**400]), False),
    ("negative sample past float64", mutated(["samples"], [-(10**400)]), False),
    ("largest float64 sample", mutated(["samples"], [1.7976931348623157e308]), True),
    ("display_hz past float64", mutated(["host", "display_hz"], 10**400), False),
    ("missing run", mutated(["run"], delete=True), False),
    ("null run", mutated(["run"], None), False),
    ("run without started_at", mutated(["run", "started_at"], delete=True), False),
    ("run extra key", mutated(["run", "attempt"], 3), False),
    ("caller attempt id", mutated(["run", "id"], "job-4412:attempt.7"), True),
    ("run id with space", mutated(["run", "id"], "job 1"), False),
    ("started_at without fraction", mutated(["run", "started_at"], "2026-10-25T12:00:00Z"), True),
    ("started_at with offset", mutated(["run", "started_at"], "2026-10-25T12:00:00+02:00"), False),
    ("started_at month 13", mutated(["run", "started_at"], "2026-13-01T00:00:00Z"), False),
    ("started_at date only", mutated(["run", "started_at"], "2026-10-25"), False),
    ("wrong schema id", mutated(["schema"], "cmux-perf-result/v2"), False),
    ("missing schema id", mutated(["schema"], delete=True), False),
    ("unknown top-level key", {**valid_dict(), "p95": 4.0}, False),
    ("unknown host key", mutated(["host", "memory_gb"], 16), False),
    ("missing macos key", mutated(["host", "macos"], delete=True), False),
    ("zero hz", mutated(["host", "display_hz"], 0), False),
    ("bad fingerprint", mutated(["host", "fingerprint"], "abc"), False),
    ("empty class", mutated(["host", "class"], ""), False),
    ("bad better", mutated(["better"], "smaller"), False),
    ("bad session", mutated(["session"], "medium"), False),
    ("empty corpus id", mutated(["session"], "corpus:"), False),
    ("story with space", mutated(["story"], "terminal key"), False),
    ("story with trailing newline", mutated(["story"], "terminal\n"), False),
    ("absolute target path", mutated(["target_ref"], {"path": "/etc/passwd", "key": "x"}), False),
    ("escaping target path", mutated(["target_ref"], {"path": "scripts/../../x.json", "key": "x"}), False),
    ("target path without key", mutated(["target_ref"], {"path": "scripts/measure/perf-gate.json"}), False),
    ("target and path", mutated(["target_ref"], {"target": "a", "path": "b", "key": "c"}), False),
    ("empty target key", mutated(["target_ref"], {"path": "a.json", "key": ""}), False),
    ("bad feature state", mutated(["features", "instantTabs", "state"], "enabled"), False),
    ("bad feature source", mutated(["features", "instantTabs", "source"], "finch"), False),
    ("bad feature name", mutated(["features", "1bad"], {"state": "on", "source": "env"}), False),
    ("feature missing source", mutated(["features", "instantTabs"], {"state": "on"}), False),
    ("empty features hash", mutated(["features_hash"], ""), False),
    ("bad safe mode", mutated(["safe_mode"], "safe_seed"), False),
    ("missing safe mode", mutated(["safe_mode"], delete=True), False),
    ("bad digest", mutated(["attachments"], [{"digest": "md5:abc", "kind": "trace"}]), False),
    ("bad attachment kind", mutated(["attachments"], [{"digest": DIGEST, "kind": "Trace File"}]), False),
    ("attachment extra key", mutated(["attachments"], [{"digest": DIGEST, "kind": "trace", "url": "x"}]), False),
    ("not an object", [1, 2], False),
]


class SchemaTests(unittest.TestCase):
    def test_schema_requires_samples_unit_and_engine(self):
        for key in ("samples", "unit", "engine"):
            self.assertIn(key, SCHEMA["required"])
        self.assertEqual(SCHEMA["properties"]["samples"]["minItems"], 1)

    def test_schema_requires_every_key_the_writer_emits(self):
        self.assertEqual(sorted(SCHEMA["required"]), sorted(pr.TOP_LEVEL_KEYS))
        self.assertEqual(sorted(SCHEMA["properties"]), sorted(pr.TOP_LEVEL_KEYS))
        self.assertEqual(sorted(SCHEMA["properties"]["build"]["required"]), sorted(pr.BUILD_KEYS))
        self.assertEqual(sorted(SCHEMA["properties"]["host"]["required"]), sorted(pr.HOST_KEYS))
        self.assertEqual(sorted(SCHEMA["properties"]["run"]["required"]), sorted(pr.RUN_KEYS))

    def test_every_unit_maps_to_a_catapult_unit(self):
        self.assertEqual(tuple(pr.CATAPULT_UNITS), pr.UNITS)
        for unit, (catapult_unit, factor) in pr.CATAPULT_UNITS.items():
            with self.subTest(unit):
                self.assertIn(catapult_unit, CATAPULT_UNIT_NAMES)
                self.assertGreater(factor, 0)
                self.assertIn(f"{unit} -> {catapult_unit}", SCHEMA["properties"]["unit"]["description"])
        self.assertEqual(sorted(pr.CATAPULT_IMPROVEMENT_DIRECTION), sorted(pr.BETTER))
        self.assertNotIn("follow catapult", SCHEMA["description"])

    def test_enums_and_patterns_match_the_module(self):
        props = SCHEMA["properties"]
        feature = props["features"]["additionalProperties"]["properties"]
        target_variants = props["target_ref"]["oneOf"]
        self.assertEqual(props["schema"]["const"], pr.SCHEMA_ID)
        self.assertEqual(tuple(props["unit"]["enum"]), pr.UNITS)
        self.assertEqual(tuple(props["better"]["enum"]), pr.BETTER)
        self.assertEqual(tuple(props["build"]["properties"]["config"]["enum"]), pr.CONFIGS)
        self.assertEqual(tuple(props["engine"]["enum"]), pr.ENGINES)
        self.assertEqual(tuple(feature["state"]["enum"]), pr.FEATURE_STATES)
        self.assertEqual(tuple(feature["source"]["enum"]), pr.FEATURE_SOURCES)
        self.assertEqual(tuple(props["safe_mode"]["enum"]), pr.SAFE_MODES)
        self.assertEqual(props["story"]["pattern"], pr.NAME_PATTERN)
        self.assertEqual(props["metric"]["pattern"], pr.NAME_PATTERN)
        self.assertEqual(props["session"]["pattern"], pr.SESSION_PATTERN)
        self.assertEqual(target_variants[1]["properties"]["target"]["pattern"], pr.NAME_PATTERN)
        self.assertEqual(target_variants[2]["properties"]["path"]["pattern"], pr.TARGET_PATH_PATTERN)
        self.assertEqual(props["build"]["properties"]["sha"]["pattern"], pr.SHA_PATTERN)
        self.assertEqual(props["host"]["properties"]["fingerprint"]["pattern"], pr.FINGERPRINT_PATTERN)
        self.assertEqual(props["host"]["properties"]["macos"]["pattern"], pr.MACOS_PATTERN)
        self.assertEqual(props["host"]["properties"]["macos_build"]["pattern"], pr.MACOS_BUILD_PATTERN)
        self.assertEqual(props["features"]["propertyNames"]["pattern"], pr.FEATURE_NAME_PATTERN)
        self.assertEqual(props["attachments"]["items"]["properties"]["digest"]["pattern"], pr.DIGEST_PATTERN)
        self.assertEqual(props["attachments"]["items"]["properties"]["kind"]["pattern"], pr.ATTACHMENT_KIND_PATTERN)
        self.assertEqual(props["run"]["properties"]["id"]["pattern"], pr.NAME_PATTERN)
        self.assertEqual(props["run"]["properties"]["started_at"]["pattern"], pr.STARTED_AT_PATTERN)
        self.assertEqual(props["samples"]["items"]["maximum"], pr.NUMBER_LIMIT)
        self.assertEqual(props["samples"]["items"]["minimum"], -pr.NUMBER_LIMIT)
        self.assertEqual(props["host"]["properties"]["display_hz"]["maximum"], pr.NUMBER_LIMIT)

    def test_schema_and_validator_agree_on_every_case(self):
        for name, instance, expected_valid in CASES:
            with self.subTest(name):
                schema_verdict = schema_errors(copy.deepcopy(instance))
                module_verdict = pr.validation_errors(copy.deepcopy(instance))
                self.assertEqual(not schema_verdict, expected_valid, f"schema: {schema_verdict}")
                self.assertEqual(not module_verdict, expected_valid, f"validator: {module_verdict}")


class WriterTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name) / "results"

    def tearDown(self):
        self._tmp.cleanup()

    def assertWriteRaises(self, result, reason):
        with self.assertRaisesRegex(pr.ResultError, reason):
            pr.write_ndjson(self.dir, [make_result(), result])
        self.assertFalse(self.dir.exists() and any(self.dir.iterdir()), "an invalid batch wrote a file")

    def test_writer_raises_on_empty_samples(self):
        self.assertWriteRaises(make_result(samples=[]), "samples: empty")

    def test_writer_raises_on_missing_unit(self):
        self.assertWriteRaises(make_result(unit=None), "unit")
        self.assertWriteRaises(make_result(unit=""), "unit")

    def test_writer_raises_on_unknown_config(self):
        build = pr.Build(sha=SHA, config="profile", measure_version=1)
        self.assertWriteRaises(make_result(build=build), "build.config")

    def test_writer_raises_on_non_finite_sample(self):
        self.assertWriteRaises(make_result(samples=[1.0, float("nan")]), "samples")
        self.assertWriteRaises(make_result(samples=[float("inf")]), "samples")

    def test_writer_raises_on_nothing_to_write(self):
        with self.assertRaisesRegex(pr.ResultError, "no results"):
            pr.write_ndjson(self.dir, [])

    def test_validate_raises_naming_each_field(self):
        result = make_result(engine="gecko", session="medium")
        with self.assertRaises(pr.ResultError) as raised:
            result.validate()
        self.assertIn("engine", str(raised.exception))
        self.assertIn("session", str(raised.exception))

    def test_read_dir_round_trips_write_ndjson(self):
        results = [
            make_result(),
            make_result(
                story="tabs-10-idle",
                metric="app.main_wakeups_per_s",
                unit="per_s",
                engine="webkit",
                session="corpus:browse-heavy",
                target_ref=pr.TargetRef(path="scripts/measure/idle-budget.json", key="app.wakeups"),
                features={"cefHelperHost": pr.Feature(state="on", source="env")},
                features_hash="77aa",
                safe_mode="inactive",
                attachments=[pr.Attachment(digest=DIGEST, kind="histogram")],
            ),
            make_result(
                better="higher",
                unit="score",
                samples=[312],
                target_ref=pr.TargetRef(target="speedometer"),
                host=pr.Host(FINGERPRINT, "linux-360c", "AMD EPYC", None, None, None),
            ),
        ]
        path = pr.write_ndjson(self.dir, results)
        self.assertEqual(path.parent, self.dir)
        self.assertEqual(pr.read_dir(self.dir), results)
        self.assertEqual(pr.read_file(path), results)

    def test_single_result_method_round_trips(self):
        result = make_result()
        result.write_ndjson(self.dir)
        self.assertEqual(pr.read_dir(self.dir), [result])

    def test_lines_are_schema_valid_json(self):
        path = pr.write_ndjson(self.dir, [make_result(), make_result(metric="other")])
        lines = path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertEqual(schema_errors(json.loads(line)), [])

    def test_retry_of_the_same_run_is_idempotent_and_writers_do_not_collide(self):
        first = pr.write_ndjson(self.dir, [make_result()])
        again = pr.write_ndjson(self.dir, [make_result()])
        other = pr.write_ndjson(self.dir, [make_result(samples=[1.0])])
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), sorted([first.name, other.name]))
        self.assertEqual(len(pr.read_dir(self.dir)), 2)

    def test_two_runs_with_equal_samples_stay_two_results(self):
        # Deterministic count stories give the same samples on every run.
        clock = lambda: datetime(2026, 10, 25, 12, 0, 0, tzinfo=timezone.utc)  # noqa: E731
        first = pr.write_ndjson(self.dir, [make_result(unit="count", samples=[0, 0, 0], run=pr.Run.start(clock))])
        second = pr.write_ndjson(self.dir, [make_result(unit="count", samples=[0, 0, 0], run=pr.Run.start(clock))])
        self.assertNotEqual(first, second)
        results = pr.read_dir(self.dir)
        self.assertEqual(len(results), 2)
        self.assertNotEqual(results[0].run.id, results[1].run.id)

    def test_run_start_uses_the_injected_clock_and_id(self):
        clock = lambda: datetime(2026, 10, 25, 14, 30, 5, 250000, tzinfo=timezone(timedelta(hours=2)))  # noqa: E731
        run = pr.Run.start(clock, run_id="job-4412:attempt.7")
        self.assertEqual(run, pr.Run(id="job-4412:attempt.7", started_at="2026-10-25T12:30:05.250000Z"))
        self.assertRegex(pr.Run.start().id, r"^[0-9a-f]{32}$")
        self.assertEqual(pr.validation_errors({**valid_dict(), "run": pr.Run.start().to_dict()}), [])

    def test_written_file_is_readable_by_others(self):
        path = pr.write_ndjson(self.dir, [make_result()])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)

    def test_measure_version_1_0_is_written_and_read_as_1(self):
        path = pr.write_ndjson(self.dir, [make_result(build=pr.Build(SHA, "bench", 1.0))])
        self.assertIn('"measure_version":1,', path.read_text(encoding="utf-8"))
        line = json.dumps(valid_dict()).replace('"measure_version": 1', '"measure_version": 1.0')
        (self.dir / "result-float.ndjson").write_text(line + "\n", encoding="utf-8")
        versions = [result.build.measure_version for result in pr.read_dir(self.dir)]
        self.assertEqual(versions, [1, 1])
        self.assertTrue(all(type(version) is int for version in versions))

    def test_writer_raises_result_error_for_a_non_result(self):
        with self.assertRaisesRegex(pr.ResultError, "result 1: not a Result but dict"):
            pr.write_ndjson(self.dir, [make_result(), valid_dict()])
        self.assertFalse(self.dir.exists() and any(self.dir.iterdir()))

    def test_writer_raises_result_error_for_wrong_nested_types(self):
        build = {"sha": SHA, "config": "bench", "measure_version": 1}
        self.assertWriteRaises(make_result(build=build), "build: dict is not a Build")
        self.assertWriteRaises(make_result(host=None), "host: NoneType is not a Host")
        self.assertWriteRaises(make_result(run={"id": RUN_ID}), "run: dict is not a Run")
        self.assertWriteRaises(make_result(target_ref="key-to-frame"), "target_ref: str is not a TargetRef")
        self.assertWriteRaises(make_result(features={"a": {"state": "on", "source": "env"}}), "features.a")
        self.assertWriteRaises(
            make_result(features={"a": pr.Feature("on", "env"), 1: pr.Feature("on", "env")}),
            "features key: int is not a str",
        )
        self.assertWriteRaises(make_result(attachments=[{"digest": DIGEST, "kind": "trace"}]), r"attachments\[0\]")
        self.assertWriteRaises(make_result(samples=5.0), "samples: float is not a list or tuple")

    def test_read_dir_skips_temporary_and_foreign_files(self):
        pr.write_ndjson(self.dir, [make_result()])
        (self.dir / ".result-partial.ndjson.123.tmp").write_text("{", encoding="utf-8")
        (self.dir / ".hidden.ndjson").write_text("{", encoding="utf-8")
        (self.dir / "report.json").write_text("{}", encoding="utf-8")
        self.assertEqual(len(pr.read_dir(self.dir)), 1)

    def test_target_path_must_exist_under_repo_root(self):
        missing = make_result(target_ref=pr.TargetRef(path="scripts/perf-lab/no-such.json", key="k"))
        present = make_result(target_ref=pr.TargetRef(path="schemas/perf/result-v1.schema.json", key="k"))
        missing.validate()
        present.validate(repo_root=REPO_ROOT)
        with self.assertRaisesRegex(pr.ResultError, "does not exist"):
            missing.validate(repo_root=REPO_ROOT)
        with self.assertRaisesRegex(pr.ResultError, "does not exist"):
            pr.write_ndjson(self.dir, [missing], repo_root=REPO_ROOT)
        self.assertFalse(self.dir.exists() and any(self.dir.iterdir()))
        pr.write_ndjson(self.dir, [present], repo_root=REPO_ROOT)

    def test_a_moved_threshold_file_does_not_make_history_unreadable(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / "floors.json").write_text("{}", encoding="utf-8")
            result = make_result(target_ref=pr.TargetRef(path="floors.json", key="k"))
            pr.write_ndjson(self.dir, [result], repo_root=root)
            (Path(root) / "floors.json").unlink()
        self.assertEqual(pr.read_dir(self.dir), [result])


class ReaderErrorTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write_lines(self, *lines):
        path = self.dir / "result-x.ndjson"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def assertReadRaises(self, path, reason):
        with self.assertRaises(pr.ResultError) as raised:
            pr.read_dir(self.dir)
        message = str(raised.exception)
        self.assertIn(str(path), message)
        self.assertRegex(message, reason)

    def test_names_path_line_and_reason(self):
        good = json.dumps(valid_dict())
        bad = json.dumps(mutated(["engine"], delete=True))
        path = self.write_lines(good, bad)
        self.assertReadRaises(path, r":2: .*missing engine")

    def test_rejects_malformed_json(self):
        path = self.write_lines("{not json")
        self.assertReadRaises(path, r":1: ")

    def test_rejects_duplicate_keys(self):
        line = json.dumps(valid_dict())[:-1] + ', "unit": "s"}'
        path = self.write_lines(line)
        self.assertReadRaises(path, "duplicate key 'unit'")

    def test_rejects_nan_samples(self):
        line = json.dumps(valid_dict()).replace("[4.25, 3.5, 5, 4.0]", "[NaN]")
        path = self.write_lines(line)
        self.assertReadRaises(path, "NaN is not a JSON number")

    def test_rejects_non_utf8(self):
        path = self.dir / "result-y.ndjson"
        path.write_bytes(b"\xff\xfe\n")
        self.assertReadRaises(path, "not UTF-8")

    def test_rejects_deep_nesting_as_result_error(self):
        path = self.write_lines("[" * 100_000 + "]" * 100_000)
        self.assertReadRaises(path, r":1: ")

    def test_rejects_an_unreadable_entry_as_result_error(self):
        path = self.dir / "result-dir.ndjson"
        path.mkdir()
        self.assertReadRaises(path, "cannot read")

    def test_on_error_skips_bad_files_and_reads_the_rest(self):
        good = self.dir / "result-a.ndjson"
        good.write_text(json.dumps(valid_dict()) + "\n", encoding="utf-8")
        bad = self.dir / "result-b.ndjson"
        bad.write_text(json.dumps(valid_dict()) + "\n{broken\n", encoding="utf-8")
        deep = self.dir / "result-c.ndjson"
        deep.write_text("[" * 100_000 + "\n", encoding="utf-8")
        errors = []
        results = pr.read_dir(self.dir, on_error=errors.append)
        self.assertEqual([result.story for result in results], ["terminal-key-to-frame"])
        self.assertEqual(len(errors), 2)
        self.assertIn(str(bad), str(errors[0]))
        self.assertIn(str(deep), str(errors[1]))
        self.assertTrue(all(isinstance(error, pr.ResultError) for error in errors))

    def test_keeps_unicode_line_separators_inside_strings(self):
        obj = valid_dict()
        obj["host"]["chip"] = "Apple M6"
        self.write_lines(json.dumps(obj, ensure_ascii=False))
        self.assertEqual(pr.read_dir(self.dir)[0].host.chip, "Apple M6")


class IsolationTests(unittest.TestCase):
    def test_only_standard_library_imports(self):
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        names = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                self.assertEqual(node.level, 0, "relative import breaks loading by file path")
                names.add(node.module.split(".")[0])
        self.assertTrue(names)
        if hasattr(sys, "stdlib_module_names"):
            self.assertEqual(sorted(names - set(sys.stdlib_module_names)), [])
        self.assertNotIn("__future__", names, "string annotations break dataclasses loaded outside sys.modules")

    def test_loads_by_file_path_under_isolated_mode(self):
        script = textwrap.dedent(
            """
            import importlib.util, sys, tempfile
            spec = importlib.util.spec_from_file_location("perf_result", sys.argv[1])
            pr = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(pr)
            assert "perf_result" not in sys.modules
            result = pr.Result(
                story="s", metric="m", unit="ms", better="lower", samples=[1.5],
                build=pr.Build(sys.argv[2], "release", 1),
                host=pr.Host(sys.argv[3], "c", "chip", "26", "25A1", 60),
                engine="none", session="light", run=pr.Run.start(),
            )
            with tempfile.TemporaryDirectory() as directory:
                pr.write_ndjson(directory, [result])
                assert pr.read_dir(directory) == [result]
            print("ok")
            """
        )
        with tempfile.TemporaryDirectory() as cwd:
            completed = subprocess.run(
                [sys.executable, "-I", "-c", script, str(MODULE_PATH), SHA, FINGERPRINT],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=60,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
