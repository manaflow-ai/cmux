#!/usr/bin/env python3
"""Oracle snapshot canonicalizer and the one stdlib JSON Schema validator (p15-oracle-013).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3C. Stdlib only and safe under `python3 -I`
(fleet minis have no jsonschema; rule 9: this is the one validator). The snapshot schema and its keyword
contract are schemas/oracle/snapshot-v1.schema.json and schemas/oracle/README.md (p15-oracle-011).

The schema decides every rule through `x-oracle-*` annotations collected while it validates the snapshot:
a keyword applies only from a subschema that passed (a `oneOf` branch that does not match marks nothing).
An invalid snapshot is refused, never normalized. The rules run in the README's normalization order:

  1 volatile  drop a field marked `x-oracle-volatile: {reason, task}`; nothing else drops but
    drop      the caller's `Context.drop` pointers (an engine arm drops the tabs' engine, p15-oracle-113)
  2 rewrite   `x-oracle-rewrite: path` -> `$ROOT`, `$HOME`; `url` -> `$WEB` (`--root/--home/--web`)
  3 time      `x-oracle-time: {unit, epoch: fixture}` -> offset from the fixture epoch (`--epoch-ms`);
              on `meta.clock: wall` the value is marked not comparable
    counter   `x-oracle-counter: monotonic` -> delta from the previous checkpoint of the case
  4 number    round to `x-oracle-precision` (`x-oracle-precision-default` inside open objects)
  5 set       `x-oracle-order: set` arrays sorted by each item's canonical JSON with ids masked to kind
  6 id        `x-oracle-id-kind` values, `propertyNames: {x-oracle-id-kind}` member names, other strings
              that match an `x-oracle-id-patterns` regex, and member names of open objects that match one
              become `kind#1`, `kind#2`, ...
  7 sha256    of the canonical JSON (sorted keys, no whitespace)

Ids are numbered per kind in first-seen order of a sorted-key traversal (id-keyed members after the other
members of their object, ordered like set items). Where the order of that traversal
is not fixed by content (set items and id-keyed members that tie in step 5), the tie is broken by a
canonical labeling of the case graph (set items, id-keyed members and ids are vertices; positions are edge
labels): equitable partition refinement, then individualization-refinement with automorphism pruning, the
search that nauty and Traces use (McKay and Piperno, "Practical graph isomorphism, II", 2014). The
lexicographically smallest output over the search tree is the result, so labels never depend on raw id
values or on the producer's iteration order. All checkpoints of a case are labeled as one graph, so an id
keeps its label across checkpoints (invariant I2) and a later checkpoint can break an earlier tie.

Chromium: DevTools protocol tests stabilize ids by type
(third_party/blink/web_tests/http/tests/inspector-protocol/resources/inspector-protocol-test.js,
`stabilizeNames`); numbering by kind keeps the relations between ids, which the oracle compares. Canonical
JSON has sorted keys like base::Value::Dict (base/values.h) written by base/json/json_writer.h.

Usage:
  normalize.py [--schema S] [--root DIR]... [--home DIR]... [--web ORIGIN]... [--epoch-ms N]
               [--explain] [--sha256] [FILE|-]...
  normalize.py --validate [--schema S] FILE...
  normalize.py --lint-schema [--schema S]
  normalize.py --list-rules
  normalize.py --selftest [--seed N]

Every input file is one case: a `.json` file is one checkpoint, a `.jsonl` file holds one checkpoint per
line. Output is one line per checkpoint (canonical JSON, or its sha256). Nothing is written to stdout
unless every input normalizes; a nonzero exit means no output. `--explain` writes one JSON line per applied
rule to stderr. `--validate` and normalizing also lint the schema against the README contract: every
property names its source, every array its order, every number its precision.
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import io
import json
import math
import random
import re
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

TASK = "p15-oracle-013"
REPO = Path(__file__).resolve().parents[3]
DEFAULT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
EXAMPLE_SNAPSHOT = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"
PATH_REWRITE_FIXTURE = REPO / "schemas" / "oracle" / "fixtures" / "path-rewrite.json"
# The app's case-root variable (README "Case root and home"); CMUX_NEXT_, because the app unsets every other
# inherited CMUX* variable at launch.
APP_ROOT_VARIABLE = "CMUX_NEXT_ORACLE_ROOT"

# Every rule has a reason naming the source of nondeterminism and a task id (spec rule 6).
RULES: Dict[str, str] = {
    "volatile": "the schema marks the field x-oracle-volatile; its reason names the nondeterministic source "
    "(wall clock, pid, publish counts). Only schema-marked fields are dropped.",
    "drop": "the caller compares runs that differ in this field by design (oracle.py --engine arms differ in "
    "every tab's engine, p15-oracle-113): Context.drop leaves it out before set order and id labels see it.",
    "rewrite": "per-case state roots, HOME and loopback fixture ports are fresh for every run "
    "(hermetic per-case env); only fields marked x-oracle-rewrite change, and the rest of the string is kept.",
    "time": "virtual-clock times (p15-oracle-185) are compared as offsets from the fixture epoch; a wall clock "
    "makes them not comparable.",
    "counter": "process totals depend on what the process did before the case (sessions run several cases); "
    "the delta between checkpoints is behavior.",
    "number": "Swift (Foundation) and Rust (serde_json/ryu) print doubles differently, and layout "
    "arithmetic differs in the last bits across CPUs; 1.0 and 1 are the same JSON number.",
    "set": "the producer iterates a HashMap, Dictionary or Set; the schema marks the array x-oracle-order: set.",
    "decimal": "the daemon sends uint64 values as decimal strings (cmux-tui/spec/bindings.md); the rules "
    "below compare the number, so 9 and 10 order and offset as numbers.",
    "id": "ids come from UUID(), Uuid::new_v4 and per-process counters (spec section 2.7); "
    "only which values are the same id is behavior.",
}

# Annotation keywords collected per instance location (README "Annotations").
ORACLE_KEYWORDS = {
    "x-oracle-source",
    "x-oracle-order",
    "x-oracle-id-kind",
    "x-oracle-volatile",
    "x-oracle-precision",
    "x-oracle-rewrite",
    "x-oracle-time",
    "x-oracle-counter",
    "x-oracle-decimal",
}
ROOT_KEYWORDS = {"x-oracle-id-patterns", "x-oracle-precision-default", "x-oracle-id-unpatterned",
                 "x-oracle-open-keys"}
# Rules an x-oracle-open-keys entry may apply to the members of open objects whose key it matches.
OPEN_KEY_RULES = ("x-oracle-time", "x-oracle-volatile")
DECIMAL_PATTERN = "^(0|[1-9][0-9]*)$"
# Case-schema keywords (schemas/oracle/case-v1.schema.json); case_checks.py runs them.
CASE_KEYWORDS = {"x-oracle-unique", "x-oracle-step-ref", "x-oracle-crash-scope", "x-oracle-error"}
ANNOTATION_KEYWORDS = {
    "$schema", "$id", "$comment", "title", "description", "default", "examples", "format",
    "deprecated", "readOnly", "writeOnly", "contentMediaType", "contentEncoding",
}
DEFS_KEYWORDS = {"$defs", "definitions"}
SINGLE_SUBSCHEMA = {"not", "if", "then", "else", "additionalProperties", "additionalItems", "items",
                    "contains", "propertyNames"}
MAP_SUBSCHEMA = {"properties", "patternProperties", "dependentSchemas"}
LIST_SUBSCHEMA = {"allOf", "anyOf", "oneOf", "prefixItems"}
NON_NEGATIVE_INT = {"minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
                    "minContains", "maxContains"}
NUMBER_BOUNDS = {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}
OTHER_ASSERTIONS = {"type", "enum", "const", "required", "pattern", "uniqueItems", "multipleOf",
                    "dependentRequired", "$ref"}
JSON_TYPES = {"null", "boolean", "object", "array", "number", "string", "integer"}
DRAFT_07 = {"http://json-schema.org/draft-07/schema#", "http://json-schema.org/draft-07/schema"}
DRAFT_2020 = {"https://json-schema.org/draft/2020-12/schema", "https://json-schema.org/draft/2020-12/schema#"}
NOT_IN_DRAFT_07 = {"prefixItems", "dependentRequired", "dependentSchemas", "minContains", "maxContains"}
KIND_RE = re.compile(r"^[a-z][A-Za-z0-9_-]*$")
TASK_RE = re.compile(r"^p[0-9]{2}-[a-z]+-[0-9]{3}$")
SOURCE_KEYS = {"method", "path", "from", "derive", "v0", "provider", "task"}
TIME_UNITS_PER_MS = {"ns": 1_000_000, "us": 1_000, "ms": 1, "s": 0.001}
DEFAULT_PRECISION = 0.001
MAX_SAFE_INT = 2 ** 53
WALL_CLOCK_MARK = "not-comparable: wall clock (x-oracle-time, p15-oracle-185)"
SEARCH_LEAF_BUDGET = 4096
SEARCH_NODE_BUDGET = 200_000


class OracleError(Exception):
    """A refusal with a message for the person: bad schema, invalid snapshot, ambiguous rule."""


class SchemaError(OracleError):
    pass


class SnapshotInvalid(OracleError):
    def __init__(self, errors: List[str], label: str = ""):
        head = f"{label}: " if label else ""
        super().__init__(head + "snapshot does not match the schema:\n  " + "\n  ".join(errors[:50]))
        self.errors = errors


Path_ = Tuple[Any, ...]  # instance location: str for an object member, int for an array index


def pointer(path: Iterable[Any]) -> str:
    return "".join("/" + str(p).replace("~", "~0").replace("/", "~1") for p in path)


# ---------------------------------------------------------------------------------------------------------
# JSON input and output


def _refuse_constant(name: str) -> Any:
    raise OracleError(f"{name} is not JSON")


def _finite_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise OracleError(f"number {text} is out of range for a double")
    return value


def _refuse_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise OracleError(f"duplicate object key {key!r}: the last value would hide the first")
        out[key] = value
    return out


def parse_json(text: str) -> Any:
    try:
        return json.loads(text, parse_constant=_refuse_constant, parse_float=_finite_float,
                          object_pairs_hook=_refuse_duplicates)
    except json.JSONDecodeError as error:
        raise OracleError(f"not JSON: {error}") from None


def canonical_json(value: Any) -> str:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    except ValueError as error:
        raise OracleError(f"no canonical JSON: {error}") from None


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _equality_key(value: Any) -> str:
    """JSON equality: 1 == 1.0, true != 1, key order is irrelevant."""

    def fold(v: Any) -> Any:
        if isinstance(v, float) and v.is_integer() and abs(v) < MAX_SAFE_INT:
            return int(v)
        if isinstance(v, dict):
            return {k: fold(x) for k, x in v.items()}
        if isinstance(v, list):
            return [fold(x) for x in v]
        return v

    return canonical_json(fold(value))


def _precision_decimals(value: Any) -> Optional[int]:
    if not _is_number(value) or value <= 0:
        return None
    for decimals in range(0, 10):
        if math.isclose(value, 10.0 ** -decimals, rel_tol=1e-12):
            return decimals
    return None


def _types(node: Dict[str, Any]) -> Set[str]:
    names = node.get("type")
    if names is None:
        return set()
    return set(names) if isinstance(names, list) else {names}


# ---------------------------------------------------------------------------------------------------------
# Schema: lint, validation and annotation collection


class Schema:
    """A linted JSON Schema: draft-07 (what snapshot-v1 uses) or a 2020-12 subset. Keywords it does not
    implement are refused, never ignored. `contract=True` also checks the README contract of 011."""

    def __init__(self, doc: Any, origin: str = "<schema>", contract: bool = False):
        self.doc = doc
        self.origin = origin
        self._patterns: Dict[str, Any] = {}
        self._id_search: Any = None
        self._id_kinds: List[str] = []
        problems: List[str] = []
        declared = doc.get("$schema") if isinstance(doc, dict) else None
        if declared is None or declared in DRAFT_2020:
            self.draft = 2020
        elif declared in DRAFT_07:
            self.draft = 7
        else:
            self.draft = 2020
            problems.append(f"/$schema: {declared!r} is not draft-07 or 2020-12")
        self.id_patterns: List[Tuple[str, Any]] = []
        # (key regex, rule keyword, rule value) for members of open objects (README x-oracle-open-keys).
        self.open_keys: List[Tuple[Any, str, Any]] = []
        self.precision_default = DEFAULT_PRECISION
        self._lint(doc, (), problems)
        if contract:
            self._lint_contract(doc, (), problems, set())
            self._lint_sources(doc, (), False, problems, set())
        if problems:
            raise SchemaError(f"{origin}: schema refused:\n  " + "\n  ".join(problems))

    @classmethod
    def load(cls, path: Path, contract: bool = True) -> "Schema":
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise SchemaError(f"{path}: no schema (the snapshot schema is p15-oracle-011)") from None
        try:
            doc = parse_json(text)
        except OracleError as error:
            raise SchemaError(f"{path}: {error}") from None
        return cls(doc, str(path), contract)

    # -- lint: keyword shapes

    def _lint(self, node: Any, at: Path_, problems: List[str]) -> None:
        where = pointer(at) or "/"
        if isinstance(node, bool):
            return
        if not isinstance(node, dict):
            problems.append(f"{where}: a schema is an object or a boolean")
            return
        if self.draft == 7 and "$ref" in node:
            ignored = sorted(set(node) - {"$ref"} - ANNOTATION_KEYWORDS - ORACLE_KEYWORDS - CASE_KEYWORDS
                             - DEFS_KEYWORDS - ROOT_KEYWORDS)
            if ignored:
                problems.append(f"{where}: draft-07 ignores {ignored} beside $ref; move them into the target")
        for key, value in node.items():
            here = at + (key,)
            if self.draft == 7 and key in NOT_IN_DRAFT_07:
                problems.append(f"{pointer(here)}: {key!r} is not a draft-07 keyword")
            elif key in ORACLE_KEYWORDS:
                self._lint_oracle(key, value, pointer(here), problems)
            elif key in ROOT_KEYWORDS:
                if at:
                    problems.append(f"{pointer(here)}: {key} belongs at the schema root")
                else:
                    self._lint_root_keyword(key, value, pointer(here), problems)
            elif key in CASE_KEYWORDS:
                pass  # checked by scripts/cmux-next/oracle/case_checks.py
            elif key in ANNOTATION_KEYWORDS:
                if key == "$id" and at:
                    problems.append(f"{pointer(here)}: only the root may have $id (refs are local)")
            elif key in DEFS_KEYWORDS:
                if not isinstance(value, dict):
                    problems.append(f"{pointer(here)}: must be an object of schemas")
                else:
                    for name, sub in value.items():
                        self._lint(sub, here + (name,), problems)
            elif key in SINGLE_SUBSCHEMA:
                if key == "items" and isinstance(value, list):
                    if self.draft != 7:
                        problems.append(f"{pointer(here)}: array form of items; use prefixItems (2020-12)")
                    for index, sub in enumerate(value):
                        self._lint(sub, here + (index,), problems)
                elif key == "additionalItems" and self.draft != 7:
                    problems.append(f"{pointer(here)}: additionalItems is draft-07; use items (2020-12)")
                else:
                    self._lint(value, here, problems)
            elif key in MAP_SUBSCHEMA:
                if not isinstance(value, dict):
                    problems.append(f"{pointer(here)}: must be an object of schemas")
                    continue
                for name, sub in value.items():
                    if key == "patternProperties" and self._compile(name, pointer(here + (name,)), problems) is None:
                        continue
                    self._lint(sub, here + (name,), problems)
            elif key in LIST_SUBSCHEMA:
                if not isinstance(value, list) or not value:
                    problems.append(f"{pointer(here)}: must be a non-empty array of schemas")
                    continue
                for index, sub in enumerate(value):
                    self._lint(sub, here + (index,), problems)
            elif key in NON_NEGATIVE_INT:
                if not (isinstance(value, int) and not isinstance(value, bool) and value >= 0):
                    problems.append(f"{pointer(here)}: must be a non-negative integer")
            elif key in NUMBER_BOUNDS:
                if not _is_number(value):
                    problems.append(f"{pointer(here)}: must be a number")
            elif key in OTHER_ASSERTIONS:
                self._lint_assertion(key, value, here, problems)
            else:
                hint = " (misspelled x-oracle keyword?)" if key.startswith("x-") else ""
                problems.append(f"{pointer(here)}: unknown keyword {key!r}{hint}; this validator refuses "
                                "keywords it does not implement")

    def _lint_oracle(self, key: str, value: Any, where: str, problems: List[str]) -> None:
        if key == "x-oracle-volatile":
            if not (isinstance(value, dict) and set(value) == {"reason", "task"}
                    and isinstance(value["reason"], str) and len(value["reason"].strip()) >= 3
                    and isinstance(value["task"], str) and TASK_RE.match(value["task"])):
                problems.append(f"{where}: x-oracle-volatile is {{reason, task}}: a reason naming the "
                                "nondeterministic source and the task (pNN-name-NNN) that owns it")
        elif key == "x-oracle-order":
            if value not in ("set", "sequence"):
                problems.append(f"{where}: x-oracle-order is \"set\" or \"sequence\"")
        elif key == "x-oracle-id-kind":
            kinds = value if isinstance(value, list) else [value]
            if not kinds or not all(isinstance(k, str) and KIND_RE.match(k) for k in kinds):
                problems.append(f"{where}: x-oracle-id-kind is a kind name matching {KIND_RE.pattern}, or a "
                                "non-empty list of them")
            elif isinstance(value, list) and len(set(value)) != len(value):
                problems.append(f"{where}: x-oracle-id-kind lists a kind twice")
        elif key == "x-oracle-decimal":
            if value is not True:
                problems.append(f"{where}: x-oracle-decimal is true")
        elif key == "x-oracle-precision":
            if _precision_decimals(value) is None:
                problems.append(f"{where}: x-oracle-precision is a power of ten from 1 down to 1e-9")
        elif key == "x-oracle-source":
            if not (isinstance(value, dict) and isinstance(value.get("method"), str) and value["method"].strip()
                    and isinstance(value.get("path"), str) and (value["path"] == "" or value["path"].startswith("/"))):
                problems.append(f"{where}: x-oracle-source is {{method, path}}: the wire method and a JSON "
                                "pointer into its result")
            elif set(value) - SOURCE_KEYS:
                problems.append(f"{where}: x-oracle-source has unknown members {sorted(set(value) - SOURCE_KEYS)}")
        elif key == "x-oracle-rewrite":
            if value not in ("path", "url"):
                problems.append(f"{where}: x-oracle-rewrite is \"path\" or \"url\"")
        elif key == "x-oracle-time":
            if not (isinstance(value, dict) and set(value) == {"unit", "epoch"}
                    and value["unit"] in TIME_UNITS_PER_MS and value["epoch"] == "fixture"):
                problems.append(f"{where}: x-oracle-time is {{unit: {'|'.join(TIME_UNITS_PER_MS)}, epoch: fixture}}")
        elif key == "x-oracle-counter":
            if value != "monotonic":
                problems.append(f"{where}: x-oracle-counter is \"monotonic\"")

    def _lint_root_keyword(self, key: str, value: Any, where: str, problems: List[str]) -> None:
        if key == "x-oracle-id-unpatterned":
            if not isinstance(value, dict) or not all(
                    KIND_RE.match(k) and isinstance(r, str) and len(r.strip()) >= 3 for k, r in value.items()):
                problems.append(f"{where}: x-oracle-id-unpatterned maps id kinds to the reason they have no pattern")
            return
        if key == "x-oracle-open-keys":
            self._lint_open_keys(value, where, problems)
            return
        if key == "x-oracle-precision-default":
            if _precision_decimals(value) is None:
                problems.append(f"{where}: x-oracle-precision-default is a power of ten from 1 down to 1e-9")
            else:
                self.precision_default = value
            return
        if not isinstance(value, dict) or not value:
            problems.append(f"{where}: x-oracle-id-patterns maps id kinds to regexes")
            return
        for kind, pattern in sorted(value.items()):
            if not KIND_RE.match(kind) or not isinstance(pattern, str):
                problems.append(f"{where}/{kind}: a kind name and a regex string")
                continue
            compiled = self._compile(pattern, f"{where}/{kind}", problems)
            if compiled is not None:
                self.id_patterns.append((kind, compiled))

    def _lint_open_keys(self, value: Any, where: str, problems: List[str]) -> None:
        if not isinstance(value, list):
            problems.append(f"{where}: x-oracle-open-keys is a list of {{key, <rule>}}")
            return
        for index, entry in enumerate(value):
            at = f"{where}/{index}"
            rules = [k for k in OPEN_KEY_RULES if isinstance(entry, dict) and k in entry]
            if not (isinstance(entry, dict) and isinstance(entry.get("key"), str) and len(rules) == 1
                    and set(entry) == {"key", rules[0]}):
                problems.append(f"{at}: an open-keys entry is {{key: <regex>, one of {list(OPEN_KEY_RULES)}}}")
                continue
            compiled = self._compile(entry["key"], f"{at}/key", problems)
            before = len(problems)
            self._lint_oracle(rules[0], entry[rules[0]], f"{at}/{rules[0]}", problems)
            if compiled is not None and len(problems) == before:
                self.open_keys.append((compiled, rules[0], entry[rules[0]]))

    def open_key_rule(self, name: str) -> Optional[Tuple[str, Any]]:
        """The x-oracle-open-keys rule for a member of an open object named `name`; the first entry wins."""
        for regex, rule, value in self.open_keys:
            if regex.search(name):
                return rule, value
        return None

    def _lint_assertion(self, key: str, value: Any, at: Path_, problems: List[str]) -> None:
        where = pointer(at)
        if key == "type":
            names = value if isinstance(value, list) else [value]
            if not names or not all(n in JSON_TYPES for n in names):
                problems.append(f"{where}: type must name JSON types {sorted(JSON_TYPES)}")
        elif key == "enum":
            if not isinstance(value, list) or not value:
                problems.append(f"{where}: enum must be a non-empty array")
        elif key == "required":
            if not isinstance(value, list) or not all(isinstance(n, str) for n in value):
                problems.append(f"{where}: required must be an array of strings")
        elif key == "pattern":
            if isinstance(value, str):
                self._compile(value, where, problems)
            else:
                problems.append(f"{where}: pattern must be a string")
        elif key == "uniqueItems":
            if not isinstance(value, bool):
                problems.append(f"{where}: uniqueItems must be a boolean")
        elif key == "multipleOf":
            if not _is_number(value) or value <= 0:
                problems.append(f"{where}: multipleOf must be a positive number")
        elif key == "dependentRequired":
            if not isinstance(value, dict) or not all(
                isinstance(v, list) and all(isinstance(n, str) for n in v) for v in value.values()
            ):
                problems.append(f"{where}: dependentRequired must map names to arrays of names")
        elif key == "$ref":
            if not isinstance(value, str):
                problems.append(f"{where}: $ref must be a string")
            else:
                try:
                    self.resolve(value)
                except SchemaError as error:
                    problems.append(f"{where}: {error}")

    # -- lint: the README contract (every array has an order, every number a precision, ...)

    def _lint_contract(self, node: Any, at: Path_, problems: List[str], seen: set) -> None:
        if not isinstance(node, dict):
            if isinstance(node, list):
                for index, sub in enumerate(node):
                    self._lint_contract(sub, at + (index,), problems, seen)
            return
        where = pointer(at) or "/"
        types = _types(node)
        if ("array" in types or "items" in node) and "x-oracle-order" not in node:
            problems.append(f"{where}: an array needs x-oracle-order (sequence or set)")
        if "number" in types and "x-oracle-precision" not in node:
            problems.append(f"{where}: a number needs x-oracle-precision")
        if "x-oracle-rewrite" in node and types and "string" not in types:
            problems.append(f"{where}: x-oracle-rewrite marks a string")
        decimal = node.get("x-oracle-decimal") is True
        if decimal and (types != {"string"} or node.get("pattern") != DECIMAL_PATTERN):
            problems.append(f"{where}: x-oracle-decimal marks a string with pattern {DECIMAL_PATTERN}")
        for key in ("x-oracle-time", "x-oracle-counter"):
            if key in node and types and not types & {"number", "integer"} and not decimal:
                problems.append(f"{where}: {key} marks a number or an x-oracle-decimal string")
        kinds = node.get("x-oracle-id-kind")
        if isinstance(kinds, list):
            patterned = {kind for kind, _ in self.id_patterns}
            for kind in kinds:
                if kind not in patterned:
                    problems.append(f"{where}: x-oracle-id-kind lists {kind!r}, which has no x-oracle-id-patterns "
                                    "entry: a list picks the kind by pattern")
        if "x-oracle-id-kind" in node and types & {"object", "array", "boolean"}:
            problems.append(f"{where}: x-oracle-id-kind marks a string or integer id; mark the array's items")
        for key, value in node.items():
            if key in ORACLE_KEYWORDS or key in ROOT_KEYWORDS or key in ANNOTATION_KEYWORDS or key == "enum" \
                    or key == "const":
                continue
            if isinstance(value, (dict, list)):
                if key in MAP_SUBSCHEMA or key in DEFS_KEYWORDS:
                    for name, sub in value.items():
                        self._lint_contract(sub, at + (key, name), problems, seen)
                else:
                    self._lint_contract(value, at + (key,), problems, seen)

    def _lint_sources(self, node: Any, at: Path_, inherited: bool, problems: List[str], seen: set) -> None:
        """Every property names its own source; additionalProperties and item schemas name one or inherit
        it from the schema that holds them. Definitions are checked where a $ref uses them."""
        if not isinstance(node, dict) or (at, inherited) in seen:
            return
        seen.add((at, inherited))
        has = inherited or self._has_source(node)
        if isinstance(node.get("$ref"), str):
            try:
                target = self.resolve(node["$ref"])
                where = tuple(p.replace("~1", "/").replace("~0", "~") for p in node["$ref"][2:].split("/") if p)
                self._lint_sources(target, where, has, problems, seen)
            except SchemaError:
                pass
        for key in ("properties", "patternProperties"):
            for name, sub in (node.get(key) or {}).items():
                if not self._has_source(sub):
                    problems.append(f"{pointer(at + (key, name))}: no x-oracle-source {{method, path}} on the field")
                self._lint_sources(sub, at + (key, name), True, problems, seen)
        for key in ("additionalProperties", "additionalItems", "items", "propertyNames"):
            sub = node.get(key)
            if isinstance(sub, list):
                for index, item in enumerate(sub):
                    if not (has or self._has_source(item)):
                        problems.append(f"{pointer(at + (key, index))}: no x-oracle-source on the items or above")
                    self._lint_sources(item, at + (key, index), has, problems, seen)
            elif isinstance(sub, dict):
                if key != "propertyNames" and not (has or self._has_source(sub)):
                    problems.append(f"{pointer(at + (key,))}: no x-oracle-source on the {key} schema or above it")
                self._lint_sources(sub, at + (key,), has, problems, seen)
        for key in ("not", "if", "then", "else", "contains"):
            if key in node:
                self._lint_sources(node[key], at + (key,), has, problems, seen)
        for key in ("allOf", "anyOf", "oneOf", "prefixItems"):
            for index, sub in enumerate(node.get(key) or []):
                self._lint_sources(sub, at + (key, index), has, problems, seen)

    def _has_source(self, node: Any) -> bool:
        if not isinstance(node, dict):
            return False
        if "x-oracle-source" in node:
            return True
        ref = node.get("$ref")
        if isinstance(ref, str):
            try:
                target = self.resolve(ref)
            except SchemaError:
                return False
            return isinstance(target, dict) and "x-oracle-source" in target
        return False

    def _compile(self, pattern: str, where: str, problems: Optional[List[str]] = None) -> Any:
        compiled = self._patterns.get(pattern)
        if compiled is None:
            try:
                compiled = re.compile(pattern)
            except re.error as error:
                if problems is not None:
                    problems.append(f"{where}: pattern {pattern!r} does not compile: {error}")
                return None
            self._patterns[pattern] = compiled
        return compiled

    def resolve(self, ref: str) -> Any:
        if not ref.startswith("#"):
            raise SchemaError(f"$ref {ref!r}: only local refs (#/...) are supported")
        node = self.doc
        fragment = ref[1:]
        if fragment == "":
            return node
        if not fragment.startswith("/"):
            raise SchemaError(f"$ref {ref!r}: anchors are not supported, use a JSON pointer")
        for raw in fragment[1:].split("/"):
            part = raw.replace("~1", "/").replace("~0", "~")
            if isinstance(node, dict) and part in node:
                node = node[part]
            elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
                node = node[int(part)]
            else:
                raise SchemaError(f"$ref {ref!r} does not resolve")
        return node

    def id_kind_of(self, text: str) -> Optional[str]:
        """The kind whose x-oracle-id-patterns regex matches the whole string (open objects only)."""
        kinds = [kind for kind, regex in self.id_patterns if regex.fullmatch(text)]
        if len(kinds) > 1:
            raise OracleError(f"{text!r} matches the id patterns of {kinds}; patterns must not overlap")
        return kinds[0] if kinds else None

    def id_spans(self, text: str) -> List[Tuple[int, int, str]]:
        """(start, end, kind) of every id inside an open-object string (README "Id relabeling"): each
        x-oracle-id-patterns regex without its anchors, between non-alphanumerics, the longest literal prefix
        first and left to right, so `itm_w_<uuid>_ws_<hex>` holds a uuid and a workspace id."""
        if self._id_search is None:
            ordered = sorted(self.id_patterns, key=lambda kr: (-len(kr[1].pattern.split("[", 1)[0]), kr[0]))
            branches = []
            for _, regex in ordered:
                body = regex.pattern[1:] if regex.pattern.startswith("^") else regex.pattern
                body = body[:-1] if body.endswith("$") else body
                branches.append(f"(?P<k{len(branches)}>{body})")
            self._id_kinds = [kind for kind, _ in ordered]
            joined = "|".join(branches)
            self._id_search = re.compile(f"(?<![A-Za-z0-9])(?:{joined})(?![A-Za-z0-9])") if branches else False
        if not self._id_search:
            return []
        return [(m.start(), m.end(), self._id_kinds[int(m.lastgroup[1:])]) for m in self._id_search.finditer(text)]

    # -- validation

    def validate(self, instance: Any) -> Tuple[List[str], Dict[Path_, Dict[str, Any]]]:
        """Returns (errors, annotations by instance location). Annotations are empty when errors exist.
        Besides the x-oracle keywords, a location carries `§typed` (a schema covers it), `§open` (no schema
        covers it: an open object member or an untyped array item) and `§name-kind` (its member name is an
        id of that kind, from `propertyNames: {x-oracle-id-kind}`)."""
        errors, collected = self._check(instance, self.doc, ())
        if errors:
            return errors, {}
        annotations: Dict[Path_, Dict[str, Any]] = {}
        for at, key, value in collected:
            slot = annotations.setdefault(at, {})
            if key in slot and _equality_key(slot[key]) != _equality_key(value):
                if key in ("x-oracle-source", "x-oracle-volatile"):
                    continue  # two passing subschemas agree on the rule, differ only in prose
                errors.append(f"{pointer(at) or '/'}: subschemas disagree on {key}: {slot[key]!r} vs {value!r}")
            slot.setdefault(key, value)
        return errors, ({} if errors else annotations)

    def _check(self, inst: Any, node: Any, at: Path_) -> Tuple[List[str], List[Tuple[Path_, str, Any]]]:
        if node is True:
            return [], []
        if node is False:
            return [f"{pointer(at) or '/'}: no value is allowed here"], []
        errors: List[str] = []
        notes: List[Tuple[Path_, str, Any]] = []
        where = pointer(at) or "/"

        def sub(value: Any, schema: Any, path: Path_) -> bool:
            e, n = self._check(value, schema, path)
            errors.extend(e)
            notes.extend(n)
            return not e

        if "$ref" in node:
            sub(inst, self.resolve(node["$ref"]), at)
        if "type" in node:
            names = node["type"] if isinstance(node["type"], list) else [node["type"]]
            if not any(_type_matches(inst, name) for name in names):
                errors.append(f"{where}: expected {' or '.join(names)}, got {_type_name(inst)}")
        if "enum" in node and _equality_key(inst) not in {_equality_key(v) for v in node["enum"]}:
            errors.append(f"{where}: {_short(inst)} is not one of {node['enum']}")
        if "const" in node and _equality_key(inst) != _equality_key(node["const"]):
            errors.append(f"{where}: must equal {node['const']!r}")
        for schema in node.get("allOf", []):
            sub(inst, schema, at)
        if "anyOf" in node:
            passing = [self._check(inst, s, at) for s in node["anyOf"]]
            good = [n for e, n in passing if not e]
            if not good:
                errors.append(f"{where}: matches no anyOf branch ({passing[0][0][0]})")
            for n in good:
                notes.extend(n)
        if "oneOf" in node:
            passing = [self._check(inst, s, at) for s in node["oneOf"]]
            good = [n for e, n in passing if not e]
            if len(good) != 1:
                detail = f" ({passing[0][0][0]})" if not good else ""
                errors.append(f"{where}: matches {len(good)} oneOf branches, expected 1{detail}")
            else:
                notes.extend(good[0])
        if "not" in node and not self._check(inst, node["not"], at)[0]:
            errors.append(f"{where}: matches the schema under not")
        if "if" in node:
            e, n = self._check(inst, node["if"], at)
            if not e:
                notes.extend(n)
                if "then" in node:
                    sub(inst, node["then"], at)
            elif "else" in node:
                sub(inst, node["else"], at)

        if _is_number(inst):
            self._check_number(inst, node, where, errors)
        elif isinstance(inst, str):
            if "minLength" in node and len(inst) < node["minLength"]:
                errors.append(f"{where}: shorter than {node['minLength']}")
            if "maxLength" in node and len(inst) > node["maxLength"]:
                errors.append(f"{where}: longer than {node['maxLength']}")
            if "pattern" in node and not self._compile(node["pattern"], where).search(inst):
                errors.append(f"{where}: does not match {node['pattern']!r}")
        elif isinstance(inst, list):
            self._check_array(inst, node, at, errors, notes, sub)
        elif isinstance(inst, dict):
            self._check_object(inst, node, at, errors, notes, sub)

        if errors:
            return errors, []
        notes.extend((at, key, node[key]) for key in ORACLE_KEYWORDS if key in node)
        return [], notes

    @staticmethod
    def _check_number(inst: Any, node: Dict[str, Any], where: str, errors: List[str]) -> None:
        if "minimum" in node and inst < node["minimum"]:
            errors.append(f"{where}: {inst} < minimum {node['minimum']}")
        if "maximum" in node and inst > node["maximum"]:
            errors.append(f"{where}: {inst} > maximum {node['maximum']}")
        if "exclusiveMinimum" in node and inst <= node["exclusiveMinimum"]:
            errors.append(f"{where}: {inst} <= exclusiveMinimum {node['exclusiveMinimum']}")
        if "exclusiveMaximum" in node and inst >= node["exclusiveMaximum"]:
            errors.append(f"{where}: {inst} >= exclusiveMaximum {node['exclusiveMaximum']}")
        if "multipleOf" in node:
            quotient = inst / node["multipleOf"]
            if not math.isclose(quotient, round(quotient), rel_tol=0, abs_tol=1e-9):
                errors.append(f"{where}: {inst} is not a multiple of {node['multipleOf']}")

    def _check_array(self, inst: List[Any], node: Dict[str, Any], at: Path_, errors: List[str],
                     notes: List[Tuple[Path_, str, Any]], sub: Any) -> None:
        where = pointer(at) or "/"
        items = node.get("items")
        if isinstance(items, list):  # draft-07 tuple form
            prefix, rest = items, node.get("additionalItems")
        else:
            prefix, rest = node.get("prefixItems", []), items
        for index, value in enumerate(inst):
            schema = prefix[index] if index < len(prefix) else rest
            if schema is None or schema is True:
                notes.append((at + (index,), "§open", True))
            else:
                notes.append((at + (index,), "§typed", True))
                sub(value, schema, at + (index,))
        if "minItems" in node and len(inst) < node["minItems"]:
            errors.append(f"{where}: fewer than {node['minItems']} items")
        if "maxItems" in node and len(inst) > node["maxItems"]:
            errors.append(f"{where}: more than {node['maxItems']} items")
        if node.get("uniqueItems"):
            seen: Dict[str, int] = {}
            for index, value in enumerate(inst):
                key = _equality_key(value)
                if key in seen:
                    errors.append(f"{where}: items {seen[key]} and {index} are equal")
                    break
                seen[key] = index
        if "contains" in node:
            matched = 0
            for index, value in enumerate(inst):
                e, n = self._check(value, node["contains"], at + (index,))
                if not e:
                    matched += 1
                    notes.extend(n)
            low = node.get("minContains", 1)
            if matched < low:
                errors.append(f"{where}: {matched} items match contains, need {low}")
            if "maxContains" in node and matched > node["maxContains"]:
                errors.append(f"{where}: {matched} items match contains, at most {node['maxContains']}")

    def _check_object(self, inst: Dict[str, Any], node: Dict[str, Any], at: Path_, errors: List[str],
                      notes: List[Tuple[Path_, str, Any]], sub: Any) -> None:
        where = pointer(at) or "/"
        for name in node.get("required", []):
            if name not in inst:
                errors.append(f"{where}: missing required member {name!r}")
        for name, names in node.get("dependentRequired", {}).items():
            if name in inst:
                for other in names:
                    if other not in inst:
                        errors.append(f"{where}: {name!r} requires {other!r}")
        for name, schema in node.get("dependentSchemas", {}).items():
            if name in inst:
                sub(inst, schema, at)
        if "minProperties" in node and len(inst) < node["minProperties"]:
            errors.append(f"{where}: fewer than {node['minProperties']} members")
        if "maxProperties" in node and len(inst) > node["maxProperties"]:
            errors.append(f"{where}: more than {node['maxProperties']} members")
        properties = node.get("properties", {})
        patterns = node.get("patternProperties", {})
        for name, value in inst.items():
            child = at + (name,)
            if "propertyNames" in node:
                e, n = self._check(name, node["propertyNames"], at + (("§name", name),))
                errors.extend(f"{where}: member name {name!r}: {msg}" for msg in e)
                notes.extend((child, "§name-kind", v) for _, k, v in n if k == "x-oracle-id-kind")
            covered = False
            if name in properties:
                covered = True
                sub(value, properties[name], child)
            for pattern, schema in patterns.items():
                if self._compile(pattern, where).search(name):
                    covered = True
                    sub(value, schema, child)
            if not covered:
                rest = node.get("additionalProperties", True)
                if rest is False:
                    errors.append(f"{where}: member {name!r} is not allowed")
                elif rest is True:
                    notes.append((child, "§open", True))
                    continue
                else:
                    sub(value, rest, child)
            notes.append((child, "§typed", True))


def _type_matches(value: Any, name: str) -> bool:
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "number":
        return _is_number(value)
    if name == "integer":
        return _is_number(value) and (isinstance(value, int) or value.is_integer())
    return False


def _type_name(value: Any) -> str:
    for name in ("null", "boolean", "object", "array", "string", "integer", "number"):
        if _type_matches(value, name):
            return name
    return type(value).__name__


def _short(value: Any) -> str:
    text = canonical_json(value)
    return text if len(text) <= 60 else text[:57] + "..."


_SCHEMA_CACHE: Dict[int, Tuple[Any, Schema]] = {}


def validate(instance: Any, schema: Any) -> List[str]:
    """The validator API for other oracle scripts (oracle.py check, p15-oracle-017): errors as
    "<pointer>: <message>" lines, empty when `instance` matches. `schema` is a Schema or a schema document;
    a schema this validator refuses is reported as errors, never ignored."""
    if not isinstance(schema, Schema):
        cached = _SCHEMA_CACHE.get(id(schema))
        if cached is None or cached[0] is not schema:
            try:
                cached = (schema, Schema(schema))
            except SchemaError as error:
                return [str(error)]
            _SCHEMA_CACHE[id(schema)] = cached
        schema = cached[1]
    return schema.validate(instance)[0]


# ---------------------------------------------------------------------------------------------------------
# Canonicalization, steps 1-4: lift each checkpoint into a tree with ids, sets and id-keyed members marked


@dataclass(frozen=True)
class Context:
    """The run's nondeterministic prefixes (several values per token cover realpath aliases such as
    /private/tmp), the fixture epoch of the virtual clock in ms (0: times are already offsets), and the
    instance pointers the caller drops (`drop`, a `*` segment matches any member or index): fields its runs
    differ in by design, left out in step 1 so that no set order or id label depends on them."""

    root: Tuple[str, ...] = ()
    home: Tuple[str, ...] = ()
    web: Tuple[str, ...] = ()
    epoch_ms: int = 0
    drop: Tuple[str, ...] = ()


def _drop_patterns(drop: Sequence[str]) -> List[Tuple[str, ...]]:
    patterns = []
    for text in drop:
        if not isinstance(text, str) or not text.startswith("/") or text == "/":
            raise OracleError(f"Context.drop {text!r} is not a JSON pointer below the root")
        patterns.append(tuple(part.replace("~1", "/").replace("~0", "~") for part in text[1:].split("/")))
    return patterns


def app_environment(ctx: Context) -> Dict[str, str]:
    """The variables the oracle's app driver exports to the app for a case, from the same Context it gives this
    script as --root/--home: the app rewrites hashed text (terminal titles and rows) itself, before hashing, so it
    must know the same prefixes."""
    if len(ctx.home) != 1:
        raise OracleError(f"the app takes one hermetic home, got {len(ctx.home)}")
    for value in ctx.root:
        if ":" in value or not value.rstrip("/"):
            raise OracleError(f"case root {value!r} cannot be passed in {APP_ROOT_VARIABLE} (empty, '/' or has ':')")
    return {APP_ROOT_VARIABLE: ":".join(ctx.root), "HOME": ctx.home[0]}


class _Rewriter:
    # A prefix matches only as a whole path or origin: never inside a longer name or port.
    _BEFORE = r"(?<![A-Za-z0-9._~-])"
    _AFTER = r"(?![A-Za-z0-9._~-])"

    def __init__(self, ctx: Context):
        self.table: Dict[str, str] = {}
        for token, values in (("$ROOT", ctx.root), ("$HOME", ctx.home), ("$WEB", ctx.web)):
            for value in values:
                trimmed = value.rstrip("/")
                if not trimmed:
                    raise OracleError(f"{token} prefix {value!r} is empty or '/'")
                if self.table.get(trimmed, token) != token:
                    raise OracleError(f"{trimmed!r} is given for both {self.table[trimmed]} and {token}")
                self.table[trimmed] = token
        self.regexes: Dict[str, Any] = {}
        for mode, tokens in (("path", {"$ROOT", "$HOME"}), ("url", {"$WEB", "$ROOT", "$HOME"})):
            # Longest first: a root inside home is $ROOT.
            ordered = sorted((p for p, t in self.table.items() if t in tokens), key=lambda p: (-len(p), p))
            self.regexes[mode] = (re.compile(self._BEFORE + "(" + "|".join(map(re.escape, ordered)) + ")"
                                             + self._AFTER) if ordered else None)

    def apply(self, mode: str, text: str) -> Tuple[str, List[str]]:
        """`path`: state root and home. `url`: the loopback fixture origin, and the root and home in the path
        of a file: URL."""
        regex = self.regexes[mode]
        if regex is None:
            return text, []
        used: List[str] = []

        def swap(match: "re.Match[str]") -> str:
            token = self.table[match.group(1)]
            used.append(token)
            return token

        return regex.sub(swap, text), used


class _Ref:
    """One occurrence of an id. `key` is (kind, text): an integer id is its decimal string, so the value 7
    and the member name "7" (serde_json writes HashMap<u64, _> keys as strings) are one id."""

    __slots__ = ("kind", "key", "vertex")

    def __init__(self, kind: str, key: Tuple[str, str]):
        self.kind = kind
        self.key = key
        self.vertex = -1


class _Unit:
    """An item of an unordered collection: a set item (key None) or an id-keyed member (key is its _Ref)."""

    __slots__ = ("key", "value", "vertex", "masked", "rank")

    def __init__(self, key: Optional[_Ref], value: Any):
        self.key = key
        self.value = value
        self.vertex = -1
        self.masked = ""
        self.rank = 0


class _Text:
    """An open-object string with ids inside it: literal text and _Ref parts, joined when written."""

    __slots__ = ("parts",)

    def __init__(self, parts: List[Any]):
        self.parts = parts


class _Obj:
    __slots__ = ("members", "entries")

    def __init__(self, members: Dict[str, Any], entries: List[_Unit]):
        self.members = members
        self.entries = entries


class _Set:
    __slots__ = ("items",)

    def __init__(self, items: List[_Unit]):
        self.items = items


def _node_count(value: Any) -> int:
    if isinstance(value, dict):
        return 1 + sum(_node_count(v) for v in value.values())
    if isinstance(value, list):
        return 1 + sum(_node_count(v) for v in value)
    return 1


_DROPPED = object()


def _open_time(value: Any) -> bool:
    """A time an open-keys rule converts: a number, or a uint64 decimal string as the wire sends it."""
    return (_is_number(value) and not isinstance(value, bool)) or (
        isinstance(value, str) and re.fullmatch(DECIMAL_PATTERN, value) is not None)


def _open(ann: Dict[str, Any]) -> bool:
    return "§open" in ann and "§typed" not in ann


class _Lifter:
    """Steps 1-4 for the checkpoints of one case, in order (counters need the previous checkpoint)."""

    def __init__(self, schema: Schema, ctx: Context):
        self.schema = schema
        self.ctx = ctx
        self.rewriter = _Rewriter(ctx)
        self.drops = _drop_patterns(ctx.drop)
        self.default_decimals = _precision_decimals(schema.precision_default)
        self.explain: List[Dict[str, Any]] = []
        self.sites: Dict[Tuple[str, str], List[str]] = {}
        self.counters: Dict[str, Any] = {}
        self.ann: Dict[Path_, Dict[str, Any]] = {}
        self.checkpoint = 0
        self.clock: Optional[str] = None
        self.dropped = 0
        self.set_depth = 0

    def note(self, rule: str, at: Path_, **extra: Any) -> None:
        self.explain.append({"checkpoint": self.checkpoint, "rule": rule, "pointer": pointer(at), "task": TASK,
                             **extra})

    def lift_checkpoint(self, index: int, instance: Any, annotations: Dict[Path_, Dict[str, Any]]) -> Any:
        self.checkpoint = index
        self.ann = annotations
        self.dropped = 0
        meta = instance.get("meta") if isinstance(instance, dict) else None
        self.clock = meta.get("clock") if isinstance(meta, dict) else None
        if "x-oracle-volatile" in annotations.get((), {}):
            raise OracleError("/: x-oracle-volatile marks the whole snapshot")
        return self.lift(instance, ())

    def dropped_by_caller(self, at: Path_) -> bool:
        return any(len(p) == len(at) and all(want in ("*", str(got)) for want, got in zip(p, at)) for p in self.drops)

    def ref(self, kind: Any, raw: Any, at: Path_) -> _Ref:
        if isinstance(raw, bool) or not isinstance(raw, (str, int)):
            raise OracleError(f"{pointer(at)}: an id is a string or an integer, got {_type_name(raw)}")
        if isinstance(kind, list):
            # A field that holds one of several kinds (tabs[].content_id): the kind whose pattern matches.
            found = self.schema.id_kind_of(str(raw))
            if found not in kind:
                raise OracleError(f"{pointer(at)}: {_short(raw)} matches none of the id kinds {kind}")
            kind = found
        key = (kind, raw if isinstance(raw, str) else str(raw))
        self.sites.setdefault(key, []).append(f"{self.checkpoint}:{pointer(at)}")
        return _Ref(kind, key)

    def lift(self, value: Any, at: Path_) -> Any:
        ann = self.ann.get(at, {})
        if _open(ann):
            return self.lift_open(value, at)
        kind = ann.get("x-oracle-id-kind")
        if isinstance(value, dict):
            if kind:
                raise OracleError(f"{pointer(at)}: x-oracle-id-kind marks an object; mark its id member")
            return self._lift_object(value, at)
        if isinstance(value, list):
            if kind:
                raise OracleError(f"{pointer(at)}: x-oracle-id-kind marks an array; mark its items")
            is_set = ann.get("x-oracle-order") == "set"
            self.set_depth += is_set
            items = []
            for index, item in enumerate(value):
                if "x-oracle-volatile" in self.ann.get(at + (index,), {}):
                    raise OracleError(f"{pointer(at + (index,))}: x-oracle-volatile marks an array item; "
                                      "mark the member that holds it")
                items.append(self.lift(item, at + (index,)))
            self.set_depth -= is_set
            if is_set:
                self.note("set", at, items=len(items))
                return _Set([_Unit(None, item) for item in items])
            return items
        if value is None:
            return None
        if kind:
            return self.ref(kind, value, at)
        if ann.get("x-oracle-decimal") is True and isinstance(value, str):
            # README step 1: the wire's uint64 decimal string is a number for the rules below. The validator
            # already checked the pattern, so int() cannot fail.
            value = int(value)
            self.note("decimal", at)
        if isinstance(value, str):
            mode = ann.get("x-oracle-rewrite")
            if mode:
                value, used = self.rewriter.apply(mode, value)
                if used:
                    self.note("rewrite", at, mode=mode, tokens=sorted(set(used)))
                return value
            # A typed string without a kind can still hold an id of several kinds (tabs[].content_id is a
            # terminal, browser or conversation id): 011 relabels those by x-oracle-id-patterns too.
            kind = self.schema.id_kind_of(value)
            return self.ref(kind, value, at) if kind else value
        if isinstance(value, bool):
            return value
        if "x-oracle-time" in ann:
            value = self._time(value, ann["x-oracle-time"], at)
            if isinstance(value, str):
                return value
        if "x-oracle-counter" in ann:
            value = self._counter(value, at)
        precision = ann.get("x-oracle-precision")
        decimals = self.default_decimals if precision is None else _precision_decimals(precision)
        return self._round(value, decimals, at)

    def lift_open(self, value: Any, at: Path_) -> Any:
        """No schema covers an open object (LayoutDocument, `extra`): ids by x-oracle-id-patterns, numbers by
        x-oracle-precision-default, arrays keep their order."""
        if isinstance(value, dict):
            members: Dict[str, Any] = {}
            entries: List[_Unit] = []
            for name, item in value.items():
                node = self.open_member(name, item, at + (name,))
                if node is _DROPPED:
                    continue
                kind = self.schema.id_kind_of(name)
                if kind:
                    entries.append(_Unit(self.ref(kind, name, at + (name,)), node))
                else:
                    members[name] = node
            return _Obj(members, entries)
        if isinstance(value, list):
            return [self.lift_open(item, at + (index,)) for index, item in enumerate(value)]
        if isinstance(value, str):
            kind = self.schema.id_kind_of(value)
            if kind:
                return self.ref(kind, value, at)
            # README step 3: every string of an open object gets the path and url rewrites.
            text, used = self.rewriter.apply("url", value)
            if used:
                self.note("rewrite", at, mode="open", tokens=sorted(set(used)))
            spans = self.schema.id_spans(text)
            if not spans:
                return text
            parts: List[Any] = []
            cursor = 0
            for start, end, span_kind in spans:
                if start > cursor:
                    parts.append(text[cursor:start])
                parts.append(self.ref(span_kind, text[start:end], at))
                cursor = end
            if cursor < len(text):
                parts.append(text[cursor:])
            return _Text(parts)
        if _is_number(value):
            return self._round(value, self.default_decimals, at)
        return value

    def open_member(self, name: str, item: Any, at: Path_) -> Any:
        """A member of an open object, after the x-oracle-open-keys rule its name matches (README steps 2 and
        4): _DROPPED for a volatile one, an offset (or the wall-clock mark) for a time."""
        rule = self.schema.open_key_rule(name)
        if rule is not None and rule[0] == "x-oracle-volatile":
            self.dropped += _node_count(item)
            self.note("volatile", at, reason=rule[1]["reason"], owner=rule[1]["task"], open=True)
            return _DROPPED
        if rule is not None and rule[0] == "x-oracle-time" and _open_time(item):
            node = self._time(int(item) if isinstance(item, str) else item, rule[1], at)
            return node if isinstance(node, str) else self._round(node, self.default_decimals, at)
        return self.lift_open(item, at)

    def _lift_object(self, value: Dict[str, Any], at: Path_) -> _Obj:
        members: Dict[str, Any] = {}
        entries: List[_Unit] = []
        for name, item in value.items():
            child = at + (name,)
            child_ann = self.ann.get(child, {})
            if self.drops and self.dropped_by_caller(child):
                self.dropped += _node_count(item)
                self.note("drop", child)
                continue
            volatile = child_ann.get("x-oracle-volatile")
            if volatile is not None:
                self.dropped += _node_count(item)
                self.note("volatile", child, reason=volatile["reason"], owner=volatile["task"])
                continue
            node = self.open_member(name, item, child) if _open(child_ann) else self.lift(item, child)
            if node is _DROPPED:
                continue
            name_kind = child_ann.get("§name-kind") or (self.schema.id_kind_of(name) if _open(child_ann) else None)
            if name_kind:
                entries.append(_Unit(self.ref(name_kind, name, child), node))
            else:
                members[name] = node
        return _Obj(members, entries)

    def _time(self, value: Any, spec: Dict[str, Any], at: Path_) -> Any:
        if self.clock == "wall":
            self.note("time", at, comparable=False)
            return WALL_CLOCK_MARK
        epoch = self.ctx.epoch_ms * TIME_UNITS_PER_MS[spec["unit"]]
        if epoch:
            self.note("time", at, unit=spec["unit"], epoch_ms=self.ctx.epoch_ms)
            return value - epoch
        return value

    def _counter(self, value: Any, at: Path_) -> Any:
        if self.set_depth:
            raise OracleError(f"{pointer(at)}: x-oracle-counter inside a set array has no stable place to "
                              "take a delta from; give the total a fixed path")
        place = pointer(at)
        previous = self.counters.get(place)
        self.counters[place] = value
        if previous is None:
            delta = 0  # the first checkpoint is the baseline
        elif value < previous:
            delta = value  # a restart reset the total
        else:
            delta = value - previous
        self.note("counter", at, previous=previous)
        return delta

    def _round(self, value: Any, decimals: int, at: Path_) -> Any:
        if isinstance(value, int):
            return value
        if not math.isfinite(value):
            raise OracleError(f"{pointer(at)}: {value} is not a finite number")
        rounded = round(value, decimals)
        if rounded == 0:
            rounded = 0.0  # -0.0 and 0.0 are one value
        out: Any = int(rounded) if rounded.is_integer() and abs(rounded) < MAX_SAFE_INT else rounded
        if out != value or type(out) is not float:
            self.note("number", at, decimals=decimals)
        return out


# ---------------------------------------------------------------------------------------------------------
# Steps 5-6: the case graph and its canonical labeling


def _segment(name: str) -> str:
    # "#" is escaped too, so the "#*" (set item), "#{}" (id-keyed member), "#k" and "#v" labels are unambiguous.
    return "/" + name.replace("~", "~0").replace("/", "~1").replace("#", "~2")


class _Graph:
    """Vertices: the case root (0), every unit and every distinct id. A unit's ordered content (everything
    down to the next unordered collection) is fixed by position, so it is one vertex with labeled edges: to
    each id it holds (label: the relative position) and to each unit of a collection it holds. Two cases
    are equal up to id renaming and set order exactly when their graphs are isomorphic, so a canonical
    labeling of the graph is a canonical form of the case."""

    def __init__(self, checkpoints: List[Any]):
        self.color: List[Tuple[int, str, str]] = [(0, "", "")]
        self.ids: Dict[Tuple[str, str], int] = {}
        self._edges: List[Tuple[int, str, int]] = []
        self.root = checkpoints
        self._region(checkpoints, 0, "", "")
        raw_edges = self._edges
        del self._edges
        labels = {label: rank for rank, label in enumerate(sorted({label for _, label, _ in raw_edges}))}
        self.n = len(self.color)
        self.edges = len(raw_edges)
        self.adj: List[List[Tuple[int, int]]] = [[] for _ in range(self.n)]
        for source, label, target in raw_edges:
            rank = labels[label]
            self.adj[target].append((source, 2 * rank))
            self.adj[source].append((target, 2 * rank + 1))

    def _id_vertex(self, ref: _Ref) -> int:
        vertex = self.ids.get(ref.key)
        if vertex is None:
            vertex = len(self.color)
            self.ids[ref.key] = vertex
            self.color.append((1, ref.kind, ""))
        ref.vertex = vertex
        return vertex

    def _region(self, node: Any, unit: int, rel: str, where: str) -> str:
        """Returns the canonical JSON of `node` with ids masked to their kind (step 5's sort key)."""
        if isinstance(node, _Ref):
            self._edges.append((unit, rel, self._id_vertex(node)))
            return json.dumps("§" + node.kind)
        if isinstance(node, _Text):
            masked = []
            for index, part in enumerate(node.parts):
                if isinstance(part, _Ref):
                    self._edges.append((unit, f"{rel}#t{index}", self._id_vertex(part)))
                    masked.append("§" + part.kind)
                else:
                    masked.append(part)
            return json.dumps("".join(masked), ensure_ascii=False)
        if isinstance(node, _Obj):
            parts = [json.dumps(name, ensure_ascii=False) + ":" +
                     self._region(node.members[name], unit, rel + _segment(name), where + _segment(name))
                     for name in sorted(node.members)]
            if node.entries:
                masked = self._collection(node.entries, unit, rel + "#{}", where + "#{}")
                parts.append('"#{}":[' + ",".join(masked) + "]")
            return "{" + ",".join(parts) + "}"
        if isinstance(node, list):
            return "[" + ",".join(self._region(item, unit, f"{rel}/{index}", f"{where}/{index}")
                                  for index, item in enumerate(node)) + "]"
        if isinstance(node, _Set):
            return "[" + ",".join(self._collection(node.items, unit, rel + "#*", where + "#*")) + "]"
        return canonical_json(node)

    def _collection(self, members: List[_Unit], parent: int, label: str, where: str) -> List[str]:
        for item in members:
            vertex = len(self.color)
            item.vertex = vertex
            self.color.append((0, where, ""))
            self._edges.append((parent, label, vertex))
            if item.key is None:
                item.masked = self._region(item.value, vertex, "", where)
            else:
                item.masked = "[" + self._region(item.key, vertex, "#k", where) + "," + \
                              self._region(item.value, vertex, "#v", where + "#v") + "]"
            self.color[vertex] = (0, where, item.masked)
        ordered = sorted({item.masked for item in members})
        rank = {masked: index for index, masked in enumerate(ordered)}
        for item in members:
            item.rank = rank[item.masked]
        return sorted(item.masked for item in members)


class _Partition:
    """An ordered partition of the vertices (nauty's representation): `perm` lists the vertices cell by
    cell, a cell is named by its start index in `perm`, and `end[start]` is where it stops."""

    __slots__ = ("perm", "pos", "cell", "end", "first")

    def copy(self) -> "_Partition":
        other = _Partition.__new__(_Partition)
        other.perm = self.perm[:]
        other.pos = self.pos[:]
        other.cell = self.cell[:]
        other.end = self.end[:]
        other.first = self.first
        return other

    def target(self) -> int:
        """The first cell with more than one vertex, or -1 when the partition is discrete. Cells only
        split, so the scan resumes where the last one stopped."""
        start = self.first
        n = len(self.perm)
        while start < n and self.end[start] - start == 1:
            start = self.end[start]
        self.first = start
        return start if start < n else -1


class _Labeling:
    """Equitable refinement and individualization-refinement search with automorphism pruning (nauty;
    McKay and Piperno 2014). The result is the smallest output over the search tree; pruning drops only
    subtrees that an automorphism maps onto explored ones, so the result never depends on input order."""

    def __init__(self, graph: _Graph):
        self.g = graph
        self.gens: List[Dict[int, int]] = []
        self.gens_of: Dict[int, List[int]] = {}
        self.first: Optional[_Leaf] = None
        self.best: Optional[_Leaf] = None
        self.leaves = 0
        self.nodes = 0

    # -- refinement

    def initial(self) -> Tuple[_Partition, Set[int], List[int]]:
        g = self.g
        part = _Partition.__new__(_Partition)
        part.perm = sorted(range(g.n), key=g.color.__getitem__)
        part.pos = [0] * g.n
        part.cell = [0] * g.n
        part.end = [0] * g.n
        part.first = 0
        starts = []
        start = 0
        for index, vertex in enumerate(part.perm):
            part.pos[vertex] = index
            if index and g.color[vertex] != g.color[part.perm[index - 1]]:
                part.end[start] = index
                starts.append(start)
                start = index
            part.cell[vertex] = start
        part.end[start] = g.n
        starts.append(start)
        return part, set(starts), starts

    def refine(self, part: _Partition, active: Set[int], heap: List[int]) -> None:
        """Split cells by the number of neighbors (per edge label) in a splitter cell until the partition is
        equitable. Splitters run smallest start first and the pieces of a cell are ordered by their counts,
        so the resulting ordered partition is the same for isomorphic inputs. A split cell that is not
        waiting adds all pieces but its largest (Hopcroft), which keeps refinement at O(E log V)."""
        adj = self.g.adj
        perm, pos, cell, end = part.perm, part.pos, part.cell, part.end
        while heap:
            start = heapq.heappop(heap)
            if start not in active:
                continue
            active.discard(start)
            counts: Dict[int, Dict[int, int]] = {}
            for index in range(start, end[start]):
                for neighbor, label in adj[perm[index]]:
                    tally = counts.get(neighbor)
                    if tally is None:
                        counts[neighbor] = {label: 1}
                    else:
                        tally[label] = tally.get(label, 0) + 1
            touched: Dict[int, List[int]] = {}
            for vertex in counts:
                touched.setdefault(cell[vertex], []).append(vertex)
            for first in sorted(touched):
                members = touched[first]
                stop = end[first]
                signature = {v: tuple(sorted(counts[v].items())) for v in members}
                if len(members) == stop - first and len(set(signature.values())) == 1:
                    continue
                # Move the touched vertices to the tail of the cell, then order them by signature.
                boundary = stop
                for vertex in members:
                    boundary -= 1
                    here, other = pos[vertex], perm[boundary]
                    perm[boundary], perm[here] = vertex, other
                    pos[vertex], pos[other] = boundary, here
                members.sort(key=signature.__getitem__)
                pieces: List[Tuple[int, int]] = []
                if boundary > first:
                    end[first] = boundary
                    pieces.append((first, boundary - first))
                index = boundary
                while index < stop:
                    piece = index
                    sig = signature[members[index - boundary]]
                    while index < stop and signature[members[index - boundary]] == sig:
                        member = members[index - boundary]
                        perm[index] = member
                        pos[member] = index
                        cell[member] = piece
                        index += 1
                    end[piece] = index
                    pieces.append((piece, index - piece))
                if first in active:
                    new = [p for p, _ in pieces if p != first]
                else:
                    largest = max(pieces, key=lambda p: (p[1], -p[0]))[0]
                    new = [p for p, _ in pieces if p != largest]
                for piece in new:
                    if piece not in active:
                        active.add(piece)
                        heapq.heappush(heap, piece)

    def individualize(self, part: _Partition, vertex: int) -> None:
        """Give `vertex` a cell of its own (the last place of its cell, so the rest keep their start)."""
        first = part.cell[vertex]
        last = part.end[first] - 1
        here, other = part.pos[vertex], part.perm[last]
        part.perm[last], part.perm[here] = vertex, other
        part.pos[vertex], part.pos[other] = last, here
        part.end[first] = last
        part.end[last] = last + 1
        part.cell[vertex] = last
        self.refine(part, {last}, [last])

    # -- automorphisms

    def add_generator(self, mapping: Dict[int, int]) -> None:
        index = len(self.gens)
        self.gens.append(mapping)
        for vertex in mapping:
            self.gens_of.setdefault(vertex, []).append(index)

    def find_swaps(self, part: _Partition) -> None:
        """Seed generators for orbit pruning: for two vertices refinement cannot tell apart, try the
        involution that swaps them, extended through their neighbors cell by cell, and keep it when it is an
        automorphism (identical workspaces, tabs and panes are the usual case). Only the search's speed
        depends on what is found here; every kept generator is checked edge by edge."""
        g = self.g
        budget = [20 * (g.n + g.edges) + 1000]
        parent: Dict[int, int] = {}

        def find(v: int) -> int:
            parent.setdefault(v, v)
            while parent[v] != v:
                parent[v] = parent[parent[v]]
                v = parent[v]
            return v

        start = 0
        while start < g.n and budget[0] > 0:
            stop = part.end[start]
            if stop - start > 1:
                members = part.perm[start:stop]
                for a, b in zip(members, members[1:]):
                    if find(a) == find(b):
                        continue
                    mapping = self._swap(part, a, b, budget)
                    if mapping is None:
                        if budget[0] <= 0:
                            break
                        continue
                    self.add_generator(mapping)
                    for v, w in mapping.items():
                        x, y = find(v), find(w)
                        if x != y:
                            parent[max(x, y)] = min(x, y)
            start = stop

    def _swap(self, part: _Partition, a: int, b: int, budget: List[int]) -> Optional[Dict[int, int]]:
        adj, cell, color, pos = self.g.adj, part.cell, self.g.color, part.pos
        mapping = {a: b, b: a}
        queue = [a, b]
        while queue:
            x = queue.pop()
            y = mapping[x]
            budget[0] -= len(adj[x]) + 1
            if budget[0] <= 0:
                return None
            groups_x: Dict[Tuple[int, int], List[int]] = {}
            groups_y: Dict[Tuple[int, int], List[int]] = {}
            for w, label in adj[x]:
                groups_x.setdefault((label, cell[w]), []).append(w)
            for w, label in adj[y]:
                groups_y.setdefault((label, cell[w]), []).append(w)
            if groups_x.keys() != groups_y.keys():
                return None
            for key, xs in groups_x.items():
                ys = groups_y[key]
                if len(xs) != len(ys):
                    return None
                if len(xs) > 1:
                    common = set(xs) & set(ys)
                    xs = sorted((w for w in xs if w not in common), key=pos.__getitem__) + sorted(common)
                    ys = sorted((w for w in ys if w not in common), key=pos.__getitem__) + sorted(common)
                for p, q in zip(xs, ys):
                    if p in mapping or q in mapping:
                        if mapping.get(p, q) != q or mapping.get(q, p) != p:
                            return None
                        continue
                    mapping[p] = q
                    mapping[q] = p
                    if p != q:
                        queue.extend((p, q))
        moved = {v: w for v, w in mapping.items() if v != w}
        for v, w in moved.items():
            if color[v] != color[w]:
                return None
            image = sorted((label, moved.get(u, u)) for u, label in adj[v])
            if image != sorted((label, u) for u, label in adj[w]):
                return None
        return moved

    # -- search

    def run(self) -> Tuple[List[Any], Dict[int, str]]:
        part, active, heap = self.initial()
        self.refine(part, active, heap)
        self.find_swaps(part)
        self.search(part, [], set(), set(), 0)
        assert self.best is not None
        return self.best.values, self.best.labels

    def _invalidate(self, path: List[int], fixed: Set[int], invalid: Set[int], checked: int) -> int:
        """Pruning at a node may use only generators that fix its path. Marks the generators added since
        `checked` that move a path vertex; earlier ones were marked when their vertex joined the path."""
        for index in range(checked, len(self.gens)):
            gen = self.gens[index]
            if len(gen) < len(path):
                moves = any(v in fixed for v in gen)
            else:
                moves = any(v in gen for v in path)
            if moves:
                invalid.add(index)
        return len(self.gens)

    def _orbits(self, members: List[int], invalid: Set[int], gens: Iterable[int],
                parent: Optional[Dict[int, int]] = None) -> Dict[int, int]:
        """Union-find of the cell's orbits under the valid generators in `gens` (they map the cell onto
        itself), added to `parent` when given. Read it with _root."""
        if parent is None:
            parent = {v: v for v in members}
        for index in gens:
            if index in invalid:
                continue
            for v, w in self.gens[index].items():
                if v in parent:
                    a, b = _root(parent, v), _root(parent, w)
                    if a != b:
                        parent[max(a, b)] = min(a, b)
        return parent

    def _cell_gens(self, members: List[int], invalid: Set[int]) -> List[int]:
        found: Set[int] = set()
        for v in members:
            for index in self.gens_of.get(v, ()):
                if index not in invalid:
                    found.add(index)
        return sorted(found)

    def _end_of_orbit(self, vertex: int, part: _Partition, start: int, invalid: Set[int]) -> Optional[int]:
        """When exactly one valid generator moves `vertex` and it swaps `vertex` with one other member x
        of the cell and moves no other member, `vertex` is a leaf of the cell's orbit graph: the rest of
        the cell stays one orbit without it. Returns x (the next leaf of a chain of swaps), else None."""
        moving = [index for index in self.gens_of.get(vertex, ()) if index not in invalid]
        if len(moving) != 1:
            return None
        gen = self.gens[moving[0]]
        other = gen[vertex]
        if gen.get(other) != vertex:
            return None
        cell = part.cell
        if any(cell[v] == start for v in gen if v != vertex and v != other):
            return None
        return other

    def search(self, part: _Partition, path: List[int], fixed: Set[int], invalid: Set[int],
               checked: int) -> Optional[int]:
        """Depth first over individualizations. Returns the level to resume at after an automorphism maps
        the current node onto an explored one (nauty's jump back to the common ancestor)."""
        known: Optional[Tuple[int, int, int]] = None  # (start, size, leaf): a cell known to be one orbit
        while True:
            self.nodes += 1
            if self.nodes > SEARCH_NODE_BUDGET:
                raise OracleError(f"canonical labeling needs more than {SEARCH_NODE_BUDGET} search nodes; "
                                  "the case is too symmetric to label (report it to p15-oracle-013)")
            start = part.target()
            if start < 0:
                return self.leaf(part, path)
            checked = self._invalidate(path, fixed, invalid, checked)
            size = part.end[start] - start
            vertex = -1
            if known is not None and known[0] == start and known[1] == size:
                vertex = known[2]  # the previous level removed a leaf of this orbit; the rest is one orbit
            else:
                members = sorted(part.perm[start:part.end[start]], key=part.pos.__getitem__)
                orbits = self._orbits(members, invalid, self._cell_gens(members, invalid))
                if any(_root(orbits, v) != _root(orbits, members[0]) for v in members):
                    break
                vertex = next((v for v in members if self._end_of_orbit(v, part, start, invalid) is not None),
                              members[0])
            # One orbit: every child is an automorphic image of the first, so only one is explored.
            following = self._end_of_orbit(vertex, part, start, invalid)
            invalid.update(self.gens_of.get(vertex, ()))
            self.individualize(part, vertex)
            path = path + [vertex]
            fixed.add(vertex)
            known = None
            if following is not None and self._end_of_orbit(following, part, start, invalid) is not None:
                known = (start, size - 1, following)
        level = len(path)
        tried_roots: Set[int] = set()
        tried: List[int] = []
        for vertex in members:
            if tried:
                seen = checked
                checked = self._invalidate(path, fixed, invalid, checked)
                if checked > seen:
                    # Generators found in earlier subtrees join the orbits when they fix this node's path.
                    self._orbits(members, invalid, range(seen, checked), orbits)
                    tried_roots = {_root(orbits, t) for t in tried}
                if _root(orbits, vertex) in tried_roots:
                    continue
            tried.append(vertex)
            tried_roots.add(_root(orbits, vertex))
            child = part.copy()
            child_invalid = invalid | set(self.gens_of.get(vertex, ()))
            self.individualize(child, vertex)
            jump = self.search(child, path + [vertex], fixed | {vertex}, child_invalid, checked)
            if jump is not None and jump < level:
                return jump
        return None

    def leaf(self, part: _Partition, path: List[int]) -> Optional[int]:
        self.leaves += 1
        if self.leaves > SEARCH_LEAF_BUDGET:
            raise OracleError(f"canonical labeling needs more than {SEARCH_LEAF_BUDGET} leaves; the case is too "
                              "symmetric to label (report it to p15-oracle-013)")
        values, labels, order = _materialize(self.g, part.pos)
        leaf = _Leaf("\n".join(canonical_json(v) for v in values), part.perm[:], order, path, values, labels)
        for reference in (self.first, self.best):
            if reference is None or reference.certificate != leaf.certificate:
                continue
            # The map between two discrete partitions, place by place, sends each path vertex to the other
            # path's vertex at that level (an individualized vertex keeps its place). When it is an
            # automorphism, the subtree below the first differing level holds nothing new (nauty's jump).
            positional = {v: w for v, w in zip(leaf.perm, reference.perm) if v != w}
            if self.is_automorphism(positional):
                self.add_generator(positional)
                common = 0
                for x, y in zip(path, reference.path):
                    if x != y:
                        break
                    common += 1
                return common
            # Equal outputs still give an automorphism (same output place, same vertex); it serves orbit
            # pruning but not the jump.
            by_output = {v: w for v, w in zip(leaf.order, reference.order) if v != w}
            if self.is_automorphism(by_output):
                self.add_generator(by_output)
            return None
        if self.first is None:
            self.first = leaf
        if self.best is None or leaf.certificate < self.best.certificate:
            self.best = leaf
        return None

    def is_automorphism(self, mapping: Dict[int, int]) -> bool:
        adj, color = self.g.adj, self.g.color
        if not mapping or sorted(mapping) != sorted(mapping.values()):
            return False
        for v, w in mapping.items():
            if color[v] != color[w]:
                return False
            if sorted((label, mapping.get(u, u)) for u, label in adj[v]) != sorted((label, u) for u, label in adj[w]):
                return False
        return True


@dataclass
class _Leaf:
    certificate: str
    perm: List[int]
    order: List[int]
    path: List[int]
    values: List[Any]
    labels: Dict[int, str]


def _root(parent: Dict[int, int], v: int) -> int:
    while parent[v] != v:
        parent[v] = parent[parent[v]]
        v = parent[v]
    return v


def _materialize(g: _Graph, pos: List[int]) -> Tuple[List[Any], Dict[int, str], List[int]]:
    """Plain JSON for every checkpoint: ids labeled per kind in first-seen order of a sorted-key traversal,
    unordered items visited (and set arrays written) by their masked canonical JSON, ties by `pos`.
    `order` lists the vertices in visiting order, which maps one leaf onto another."""
    labels: Dict[int, str] = {}
    counts: Dict[str, int] = {}
    order: List[int] = [0]

    def unit_order(units: List[_Unit]) -> List[_Unit]:
        return sorted(units, key=lambda u: (u.rank, pos[u.vertex]))

    def visit(node: Any) -> Any:
        if isinstance(node, _Ref):
            label = labels.get(node.vertex)
            if label is None:
                counts[node.kind] = counts.get(node.kind, 0) + 1
                label = labels[node.vertex] = f"{node.kind}#{counts[node.kind]}"
                order.append(node.vertex)
            return label
        if isinstance(node, _Text):
            return "".join(visit(part) if isinstance(part, _Ref) else part for part in node.parts)
        if isinstance(node, _Obj):
            out = {name: visit(node.members[name]) for name in sorted(node.members)}
            for unit in unit_order(node.entries):
                order.append(unit.vertex)
                key = visit(unit.key)
                if key in out:
                    raise OracleError(f"member {key!r} and an id-keyed member labeled {key!r} collide")
                out[key] = visit(unit.value)
            return out
        if isinstance(node, list):
            return [visit(item) for item in node]
        if isinstance(node, _Set):
            items = []
            for unit in unit_order(node.items):
                order.append(unit.vertex)
                items.append(visit(unit.value))
            return items
        return node

    values = [visit(checkpoint) for checkpoint in g.root]
    return values, labels, order


@dataclass
class Result:
    value: Any
    text: str
    sha256: str
    explain: List[Dict[str, Any]] = field(default_factory=list)


def canonicalize_case(snapshots: Sequence[Any], schema: Schema, ctx: Context = Context(),
                      labels: Sequence[str] = ()) -> List[Result]:
    """Validates and canonicalizes the checkpoints of one case as one structure, so ids keep their labels
    across checkpoints and a later checkpoint can break an earlier tie. Raises SnapshotInvalid or
    OracleError; `labels` name the checkpoints in messages."""
    lifter = _Lifter(schema, ctx)
    trees: List[Tuple[Any, int]] = []
    for index, instance in enumerate(snapshots):
        label = labels[index] if index < len(labels) else f"checkpoint {index}"
        errors, annotations = schema.validate(instance)
        if errors:
            raise SnapshotInvalid(errors, label)
        try:
            trees.append((lifter.lift_checkpoint(index, instance, annotations), lifter.dropped))
        except OracleError as error:
            raise OracleError(f"{label}: {error}") from None
    graph = _Graph([tree for tree, _ in trees])
    values, id_labels = _Labeling(graph).run()
    events: Dict[int, List[Dict[str, Any]]] = {}
    for event in lifter.explain:
        events.setdefault(event["checkpoint"], []).append(event)
    for key, vertex in sorted(graph.ids.items(), key=lambda kv: _label_order(id_labels[kv[1]])):
        first = int(lifter.sites[key][0].split(":", 1)[0])
        events.setdefault(first, []).append({"checkpoint": first, "rule": "id", "pointer": "", "task": TASK,
                                             "kind": key[0], "label": id_labels[vertex],
                                             "sites": lifter.sites[key]})
    results = []
    for index, (value, instance) in enumerate(zip(values, snapshots)):
        if _node_count(value) + trees[index][1] != _node_count(instance):
            raise OracleError("internal: a rule other than volatile changed the number of values")
        text = canonical_json(value)
        results.append(Result(value, text, hashlib.sha256(text.encode("utf-8")).hexdigest(), events.get(index, [])))
    return results


def _label_order(label: str) -> Tuple[str, int]:
    kind, _, number = label.rpartition("#")
    return kind, int(number)


def canonicalize(instance: Any, schema: Schema, ctx: Context = Context()) -> Result:
    """One snapshot as a one-checkpoint case."""
    return canonicalize_case([instance], schema, ctx)[0]


# ---------------------------------------------------------------------------------------------------------
# CLI


def _read_case(name: str) -> List[Tuple[str, Any]]:
    """The checkpoints of one case file, each with a label (`file` or `file:line`) for messages."""
    try:
        text = sys.stdin.read() if name == "-" else Path(name).read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise OracleError(f"{name}: not UTF-8: {error}") from None
    if not name.endswith(".jsonl"):
        try:
            return [(name, parse_json(text))]
        except OracleError as error:
            raise OracleError(f"{name}: {error}") from None
    documents = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.strip():
            try:
                documents.append((f"{name}:{number}", parse_json(line)))
            except OracleError as error:
                raise OracleError(f"{name}:{number}: {error}") from None
    if not documents:
        raise OracleError(f"{name}: no checkpoints")
    return documents


def _cli_validate(schema: Schema, files: Sequence[str], out: Any) -> int:
    status = 0
    for name in files:
        for label, doc in _read_case(name):
            errors, _ = schema.validate(doc)
            if errors:
                status = 1
                out.write(f"FAIL {label}\n" + "".join(f"  {e}\n" for e in errors))
            else:
                out.write(f"ok {label}\n")
    return status


def _cli_normalize(schema: Schema, args: argparse.Namespace, out: Any, err: Any) -> int:
    ctx = Context(tuple(args.root), tuple(args.home), tuple(args.web), args.epoch_ms)
    lines: List[str] = []
    events: List[str] = []
    for name in args.files or ["-"]:
        documents = _read_case(name)
        names = [label for label, _ in documents]
        results = canonicalize_case([doc for _, doc in documents], schema, ctx, names)
        for label, result in zip(names, results):
            lines.append(result.sha256 if args.sha256 else result.text)
            events.extend(canonical_json({"input": label, **event}) for event in result.explain)
    # Written only when every case normalized: a nonzero exit never leaves a truncated case on stdout.
    if args.explain:
        err.write("".join(event + "\n" for event in events))
    out.write("".join(line + "\n" for line in lines))
    return 0


def main(argv: Optional[Sequence[str]] = None, out: Any = None, err: Any = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*", help="case files: .json (one checkpoint) or .jsonl; '-' is stdin")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--root", action="append", default=[], help="state root, rewritten to $ROOT")
    parser.add_argument("--home", action="append", default=[], help="home directory, rewritten to $HOME")
    parser.add_argument("--web", action="append", default=[], help="loopback origin, rewritten to $WEB")
    parser.add_argument("--epoch-ms", type=int, default=0,
                        help="fixture epoch of the virtual clock; x-oracle-time values become offsets from it")
    parser.add_argument("--explain", action="store_true", help="one JSON line per applied rule on stderr")
    parser.add_argument("--sha256", action="store_true", help="print the sha256 of the canonical JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--validate", action="store_true", help="validate files against the schema")
    mode.add_argument("--lint-schema", action="store_true", help="lint the schema against the README contract")
    mode.add_argument("--list-rules", action="store_true", help="print every rule with its reason")
    mode.add_argument("--selftest", action="store_true", help="run the property cases")
    parser.add_argument("--seed", type=int, default=13, help="selftest seed")
    args = parser.parse_args(argv)
    try:
        if args.list_rules:
            for rule, reason in RULES.items():
                out.write(f"{rule}\t{TASK}\t{reason}\n")
            return 0
        if args.selftest:
            return selftest(args.seed, out)
        schema = Schema.load(args.schema)
        if args.lint_schema:
            out.write(f"ok {args.schema}\n")
            return 0
        if args.validate:
            if not args.files:
                parser.error("--validate needs at least one file")
            return _cli_validate(schema, args.files, out)
        return _cli_normalize(schema, args, out, err)
    except SnapshotInvalid as error:
        err.write(f"normalize.py: {error}\n")
        return 1
    except (OracleError, OSError) as error:
        err.write(f"normalize.py: {error}\n")
        return 2


# ---------------------------------------------------------------------------------------------------------
# Selftest: property cases (deterministic for a seed)

DRAFT_07_URI = "http://json-schema.org/draft-07/schema#"
SET = {"x-oracle-order": "set"}
SEQUENCE = {"x-oracle-order": "sequence"}


def _kind(name: str) -> Dict[str, Any]:
    return {"x-oracle-id-kind": name}


def _volatile(reason: str) -> Dict[str, Any]:
    return {"x-oracle-volatile": {"reason": reason, "task": TASK}}


def _f(path: str, *extra: Dict[str, Any], **schema: Any) -> Dict[str, Any]:
    """A field schema with its source."""
    node: Dict[str, Any] = {"x-oracle-source": {"method": "selftest.model", "path": path}, **schema}
    for more in extra:
        node.update(more)
    return node


def _object(**properties: Any) -> Dict[str, Any]:
    return {"type": "object", "additionalProperties": False, "properties": properties}


SELFTEST_SCHEMA: Dict[str, Any] = {
    "$schema": DRAFT_07_URI,
    "type": "object",
    "additionalProperties": False,
    "required": ["windows", "panes"],
    "x-oracle-precision-default": 0.001,
    "properties": {
        "meta": _f("/meta", **_object(
            pid=_f("/meta/pid", _volatile("process id differs per launch"), type="integer"),
            startedAt=_f("/meta/startedAt", _volatile("wall clock at launch"), {"x-oracle-precision": 0.001},
                         type="number"),
            build=_f("/meta/build", {"x-oracle-rewrite": "url"}, type="string"),
        )),
        "windows": _f("/windows", SEQUENCE, type="array", items={"$ref": "#/definitions/window"}),
        "panes": _f("/panes", type="object", propertyNames=_kind("pane"),
                    additionalProperties={"$ref": "#/definitions/pane"}),
        "tags": _f("/tags", SET, type="array", items={"type": "string"}),
        "counters": _f("/counters", type="object", additionalProperties={"type": "integer", "minimum": 0}),
    },
    "definitions": {
        "window": {
            "type": "object",
            "additionalProperties": False,
            "required": ["id", "workspaces"],
            "properties": {
                "id": _f("/windows/*/id", _kind("window"), type="string"),
                "frame": _f("/windows/*/frame", SEQUENCE, type="array", items=[{"$ref": "#/definitions/fraction"}] * 4,
                            additionalItems=False, minItems=4, maxItems=4),
                "focusedWorkspace": _f("/windows/*/focusedWorkspace", _kind("workspace"), type=["string", "null"]),
                "lastActiveAt": _f("/windows/*/lastActiveAt", _volatile("wall clock of the last key event"),
                                   {"x-oracle-precision": 0.001}, type="number"),
                "workspaces": _f("/windows/*/workspaces", SET, type="array",
                                 items={"$ref": "#/definitions/workspace"}),
            },
        },
        "fraction": {"type": "number", "minimum": 0, "maximum": 1, "x-oracle-precision": 0.01},
        "workspace": {
            "type": "object",
            "additionalProperties": False,
            "required": ["id", "panes"],
            "properties": {
                "id": _f("/windows/*/workspaces/*/id", _kind("workspace"), type="string"),
                "title": _f("/windows/*/workspaces/*/title", type="string"),
                "cwd": _f("/windows/*/workspaces/*/cwd", {"x-oracle-rewrite": "path"}, type="string"),
                "pinned": _f("/windows/*/workspaces/*/pinned", type="boolean"),
                "panes": _f("/windows/*/workspaces/*/panes", SEQUENCE, type="array",
                            items={"type": "string", "x-oracle-id-kind": "pane"}),
            },
        },
        "pane": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "workspace": _f("/panes/*/workspace", _kind("workspace"), type="string"),
                "title": _f("/panes/*/title", type="string"),
                "ratio": _f("/panes/*/ratio", {"x-oracle-precision": 0.001}, type="number"),
                "size": _f("/panes/*/size", SEQUENCE, type="array", items={"type": "integer"}),
            },
        },
    },
}

# Graphs with symmetric cycles: 1-WL refinement alone cannot label these canonically.
GRAPH_SCHEMA: Dict[str, Any] = {
    "$schema": DRAFT_07_URI,
    **_object(
        tabs=_f("/tabs", SET, type="array", items=_object(
            id=_f("/tabs/*/id", _kind("tab"), type="string"),
            next=_f("/tabs/*/next", _kind("tab"), type=["string", "null"]),
        )),
        edges=_f("/edges", SET, type="array", items=_object(
            ends=_f("/edges/*/ends", SET, type="array", items={"type": "string", "x-oracle-id-kind": "node"}),
        )),
        nodes=_f("/nodes", SET, type="array", items=_object(
            id=_f("/nodes/*/id", _kind("node"), type="string"),
            nbrs=_f("/nodes/*/nbrs", SET, type="array", items={"type": "string", "x-oracle-id-kind": "node"}),
        )),
    ),
}


class _Model:
    """An abstract snapshot: ids are tokens, rendered with any naming, key order and set order."""

    def __init__(self, rng: random.Random):
        self.windows = []
        self.panes: Dict[Tuple[str, int], Dict[str, Any]] = {}
        n_ws = n_pane = 0
        for w in range(rng.randint(1, 3)):
            workspaces = []
            for _ in range(rng.randint(1, 4)):
                n_ws += 1
                pane_tokens = []
                for _ in range(rng.randint(1, 3)):
                    n_pane += 1
                    token = ("pane", n_pane)
                    pane_tokens.append(token)
                    self.panes[token] = {"workspace": ("workspace", n_ws), "title": rng.choice("xyz"),
                                         "ratio": rng.choice([0.5, 1 / 3, 0.25004, 2 / 3]),
                                         "size": [rng.randint(1, 3), rng.randint(1, 3)]}
                workspaces.append({"id": ("workspace", n_ws), "title": rng.choice("ab"),
                                   "cwd": rng.choice(["{root}/w", "{home}/src", "/etc"]) + str(rng.randint(0, 1)),
                                   "pinned": rng.random() < 0.3, "panes": pane_tokens})
            focus = rng.choice(workspaces)["id"] if rng.random() < 0.7 else None
            self.windows.append({"id": ("window", w + 1), "frame": [rng.random() for _ in range(4)],
                                 "focusedWorkspace": focus, "workspaces": workspaces})
        self.tags = [rng.choice(["t1", "t2", "t3"]) for _ in range(rng.randint(0, 4))]
        self.counters = {name: rng.randint(0, 9) for name in rng.sample(["a", "b", "c", "d"], 3)}
        self.build = rng.choice(["{web}/build", "dev"])

    def tokens(self) -> List[Tuple[str, int]]:
        found = [w["id"] for w in self.windows]
        found += [ws["id"] for w in self.windows for ws in w["workspaces"]]
        return found + list(self.panes)

    def render(self, names: Dict[Tuple[str, int], str], shuffle: Optional[random.Random] = None,
               env: Tuple[str, str, str] = ("/tmp/o/aaaaaa/bbbbbb", "/home/u", "http://127.0.0.1:4321"),
               clock: float = 1000.0) -> Dict[str, Any]:
        root, home, web = env

        def text(s: str) -> str:
            return s.format(root=root, home=home, web=web)

        def obj(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
            if shuffle is not None:
                pairs = list(pairs)
                shuffle.shuffle(pairs)
            return dict(pairs)

        def unordered(items: List[Any]) -> List[Any]:
            items = list(items)
            if shuffle is not None:
                shuffle.shuffle(items)
            return items

        windows = []
        for w in self.windows:
            workspaces = [obj([("id", names[ws["id"]]), ("title", ws["title"]), ("cwd", text(ws["cwd"])),
                               ("pinned", ws["pinned"]), ("panes", [names[p] for p in ws["panes"]])])
                          for ws in w["workspaces"]]
            windows.append(obj([("id", names[w["id"]]), ("frame", list(w["frame"])),
                                ("focusedWorkspace", names[w["focusedWorkspace"]] if w["focusedWorkspace"] else None),
                                ("lastActiveAt", clock + len(windows)), ("workspaces", unordered(workspaces))]))
        panes = obj([(names[token], obj([("workspace", names[p["workspace"]]), ("title", p["title"]),
                                         ("ratio", p["ratio"]), ("size", list(p["size"]))]))
                     for token, p in self.panes.items()])
        return obj([("meta", obj([("pid", int(clock) % 65536), ("startedAt", clock), ("build", text(self.build))])),
                    ("windows", windows), ("panes", panes), ("tags", unordered(self.tags)),
                    ("counters", obj(list(self.counters.items())))])


def _names(tokens: Sequence[Any], rng: random.Random, reverse: bool = False) -> Dict[Any, str]:
    raw = sorted(f"{rng.getrandbits(128):032x}" for _ in tokens)
    if reverse:
        raw.reverse()
    else:
        rng.shuffle(raw)
    return dict(zip(tokens, raw))


def _shuffled(value: Any, rng: random.Random) -> Any:
    """The same JSON with every object's member order shuffled."""
    if isinstance(value, dict):
        pairs = [(k, _shuffled(v, rng)) for k, v in value.items()]
        rng.shuffle(pairs)
        return dict(pairs)
    if isinstance(value, list):
        return [_shuffled(v, rng) for v in value]
    return value


def selftest(seed: int, out: Any) -> int:
    schema = Schema(SELFTEST_SCHEMA, "<selftest schema>", contract=True)
    graphs = Schema(GRAPH_SCHEMA, "<graph schema>", contract=True)
    env_a = ("/tmp/o/aaaaaa/bbbbbb", "/home/u", "http://127.0.0.1:4321")
    env_b = ("/tmp/o/cccccc/dddddd", "/Users/v", "http://127.0.0.1:51000")
    ctx_a = Context((env_a[0],), (env_a[1],), (env_a[2],))
    ctx_b = Context((env_b[0],), (env_b[1],), (env_b[2],))
    rounds = 25

    def norm(doc: Any, ctx: Context = ctx_a, using: Schema = schema) -> Result:
        return canonicalize(doc, using, ctx)

    def models(salt: int) -> Iterable[Tuple[random.Random, _Model]]:
        for i in range(rounds):
            rng = random.Random(f"{seed}:{salt}:{i}")
            yield rng, _Model(rng)

    def refused(fn: Any, needle: str) -> None:
        try:
            fn()
        except OracleError as error:
            assert needle in str(error), f"refusal {error!s:.300} lacks {needle!r}"
            return
        raise AssertionError(f"expected a refusal mentioning {needle!r}")

    def schema_of(extra: Dict[str, Any]) -> Schema:
        return Schema({"type": "object", **extra})

    def errors_of(node: Any, doc: Any) -> List[str]:
        return Schema(node).validate(doc)[0]

    def outputs(make: Any, using: Schema, trials: int, salt: int) -> Set[str]:
        found = set()
        for trial in range(trials):
            rng = random.Random(f"{seed}:{salt}:{trial}")
            found.add(canonicalize(make(rng), using).text)
        return found

    cases: List[Tuple[str, Any]] = []

    def case(fn: Any) -> Any:
        cases.append((fn.__name__, fn))
        return fn

    @case
    def key_order_invariance() -> None:
        for rng, m in models(1):
            names = _names(m.tokens(), rng)
            assert norm(m.render(names)).sha256 == norm(m.render(names, shuffle=rng)).sha256

    @case
    def id_rename_invariance() -> None:
        for rng, m in models(2):
            assert norm(m.render(_names(m.tokens(), rng))).text == norm(m.render(_names(m.tokens(), rng))).text

    @case
    def id_rename_reversed_raw_order() -> None:
        for rng, m in models(3):
            a = norm(m.render(_names(m.tokens(), rng, reverse=False)))
            b = norm(m.render(_names(m.tokens(), rng, reverse=True)))
            assert a.text == b.text, "labels depend on the raw sort order of ids"

    @case
    def set_and_map_order_invariance() -> None:
        for rng, m in models(4):
            names = _names(m.tokens(), rng)
            texts = {norm(m.render(names, shuffle=random.Random(k))).text for k in range(4)}
            assert len(texts) == 1, "set or id-map order leaks into the output"

    @case
    def all_nondeterminism_combined() -> None:
        for rng, m in models(5):
            a = norm(m.render(_names(m.tokens(), rng), shuffle=rng, env=env_a, clock=10.0), ctx_a)
            b = norm(m.render(_names(m.tokens(), rng), shuffle=rng, env=env_b, clock=99.5), ctx_b)
            assert a.sha256 == b.sha256

    @case
    def list_order_is_behavior() -> None:
        doc = {"windows": [{"id": "w", "workspaces": [{"id": "s", "panes": ["p", "q"]}]}],
               "panes": {"p": {"workspace": "s", "title": "x"}, "q": {"workspace": "s", "title": "y"}}}
        swapped = json.loads(json.dumps(doc))
        swapped["windows"][0]["workspaces"][0]["panes"] = ["q", "p"]
        assert norm(doc).text != norm(swapped).text

    @case
    def volatile_dropped_with_reason() -> None:
        doc = {"meta": {"pid": 4242, "startedAt": 1.5, "build": "dev"}, "windows": [], "panes": {}}
        result = norm(doc)
        assert result.value["meta"] == {"build": "dev"}, result.value
        drops = {e["pointer"]: (e["reason"], e["owner"]) for e in result.explain if e["rule"] == "volatile"}
        assert drops == {"/meta/pid": ("process id differs per launch", TASK),
                         "/meta/startedAt": ("wall clock at launch", TASK)}, drops
        assert all(e["task"] == TASK for e in result.explain)

    @case
    def unmarked_fields_never_dropped() -> None:
        for rng, m in models(8):
            doc = m.render(_names(m.tokens(), rng), shuffle=rng)
            marked = sum(_node_count(doc["meta"][k]) for k in ("pid", "startedAt"))
            marked += sum(1 for w in doc["windows"] if "lastActiveAt" in w)
            result = norm(doc)
            assert _node_count(result.value) == _node_count(doc) - marked
            assert set(result.value) == set(doc) and set(result.value["meta"]) == {"build"}
            assert set(result.value["counters"]) == set(doc["counters"])

    @case
    def volatile_needs_reason_and_task() -> None:
        for bad in (True, "wall clock", {"reason": "wall clock"}, {"reason": " ", "task": TASK},
                    {"reason": "wall clock", "task": "later"}):
            refused(lambda: schema_of({"properties": {"t": {"x-oracle-volatile": bad}}}), "x-oracle-volatile is")

    @case
    def volatile_on_array_item_refused() -> None:
        s = schema_of({"properties": {"l": {"type": "array", "items": _volatile("clock")}}})
        refused(lambda: canonicalize({"l": [1]}, s), "array item")

    @case
    def annotations_only_from_passing_branches() -> None:
        s = schema_of({"properties": {"t": {"anyOf": [
            {"type": "string", **_volatile("string form is a timestamp")},
            {"type": "integer"},
        ]}}})
        assert canonicalize({"t": 5}, s).value == {"t": 5}
        assert canonicalize({"t": "now"}, s).value == {}
        s2 = schema_of({"properties": {"t": {"oneOf": [
            {"type": "string", "x-oracle-id-kind": "tab"}, {"type": "boolean"}]}}})
        assert canonicalize({"t": True}, s2).value == {"t": True}
        assert canonicalize({"t": "x"}, s2).value == {"t": "tab#1"}

    @case
    def id_relations_preserved() -> None:
        for rng, m in models(12):
            v = norm(m.render(_names(m.tokens(), rng), shuffle=rng)).value
            ws_ids = {ws["id"] for w in v["windows"] for ws in w["workspaces"]}
            for pane, body in v["panes"].items():
                assert body["workspace"] in ws_ids
                owners = [ws for w in v["windows"] for ws in w["workspaces"] if pane in ws["panes"]]
                assert len(owners) == 1 and owners[0]["id"] == body["workspace"]
            for w in v["windows"]:
                assert w["focusedWorkspace"] is None or w["focusedWorkspace"] in {s["id"] for s in w["workspaces"]}

    @case
    def id_kinds_number_independently() -> None:
        doc = {"windows": [{"id": "same", "workspaces": [{"id": "same", "panes": ["same"]}]}],
               "panes": {"same": {"workspace": "same"}}}
        v = norm(doc).value
        assert v["windows"][0]["id"] == "window#1"
        assert v["windows"][0]["workspaces"][0] == {"id": "workspace#1", "panes": ["pane#1"]}
        assert v["panes"] == {"pane#1": {"workspace": "workspace#1"}}

    @case
    def ids_are_injective_per_kind() -> None:
        for rng, m in models(14):
            v = norm(m.render(_names(m.tokens(), rng))).value
            ws = [s["id"] for w in v["windows"] for s in w["workspaces"]]
            assert len(set(ws)) == len(ws) == sum(len(w["workspaces"]) for w in m.windows)
            assert len(v["panes"]) == len(m.panes)
            assert sorted(v["panes"]) == sorted(f"pane#{n}" for n in range(1, len(m.panes) + 1))

    @case
    def no_raw_id_survives() -> None:
        for rng, m in models(15):
            names = _names(m.tokens(), rng)
            text = norm(m.render(names, shuffle=rng)).text
            assert not any(raw in text for raw in names.values())

    def split_case(rng: random.Random, split: bool = True) -> List[Dict[str, Any]]:
        """Two identical workspaces with one pane each; the second checkpoint splits one of them."""
        n = _names(["W", "A", "B", "p", "q", "r"], rng)
        target = rng.choice("AB")

        def snapshot(after: bool) -> Dict[str, Any]:
            panes = {"A": [n["p"]], "B": [n["q"]]}
            if after:
                panes[target].append(n["r"])
            spaces = [{"id": n[s], "panes": panes[s]} for s in "AB"]
            rng.shuffle(spaces)
            owner = {n["p"]: n["A"], n["q"]: n["B"], n["r"]: n[target]}
            members = [(p, {"workspace": owner[p]}) for ps in panes.values() for p in ps]
            rng.shuffle(members)
            return _shuffled({"windows": [{"id": n["W"], "workspaces": spaces}], "panes": dict(members)}, rng)

        return [snapshot(False), snapshot(split)]

    @case
    def case_labels_shared_across_checkpoints() -> None:
        rng = random.Random(seed)
        first, second = (r.value for r in canonicalize_case(split_case(rng), schema))
        before = {tuple(s["panes"]): s["id"] for s in first["windows"][0]["workspaces"]}
        after = {s["id"]: s["panes"] for s in second["windows"][0]["workspaces"]}
        for panes, space in before.items():
            assert after[space][:len(panes)] == list(panes), (before, after)
        assert set(first["panes"]) < set(second["panes"])

    @case
    def later_checkpoint_breaks_symmetry() -> None:
        found = set()
        for trial in range(64):
            rng = random.Random(f"{seed}:split:{trial}")
            found.add(tuple(r.text for r in canonicalize_case(split_case(rng), schema)))
        assert len(found) == 1, f"{len(found)} outputs for one case:\n" + "\n".join(map(str, sorted(found)))

    def ring(rng: random.Random, n: int = 5) -> Dict[str, Any]:
        names = _names(list(range(n)), rng)
        tabs = [{"id": names[i], "next": names[(i + 1) % n]} for i in range(n)]
        rng.shuffle(tabs)
        return _shuffled({"tabs": tabs}, rng)

    def cycle_edges(rng: random.Random, n: int = 6) -> Dict[str, Any]:
        names = _names(list(range(n)), rng)
        edges = [{"ends": [names[i], names[(i + 1) % n]]} for i in range(n)]
        for edge in edges:
            rng.shuffle(edge["ends"])
        rng.shuffle(edges)
        return {"edges": edges}

    def cycles(rng: random.Random, sizes: Sequence[int]) -> Dict[str, Any]:
        tokens = [(c, i) for c, size in enumerate(sizes) for i in range(size)]
        names = _names(tokens, rng)
        nodes = []
        for c, size in enumerate(sizes):
            for i in range(size):
                nbrs = [names[(c, (i - 1) % size)], names[(c, (i + 1) % size)]]
                rng.shuffle(nbrs)
                nodes.append({"id": names[(c, i)], "nbrs": nbrs})
        rng.shuffle(nodes)
        return _shuffled({"nodes": nodes}, rng)

    @case
    def directed_ring_and_undirected_cycle() -> None:
        texts = outputs(ring, graphs, 40, 18)
        assert len(texts) == 1, f"directed 5-ring: {len(texts)} outputs"
        tabs = json.loads(texts.pop())["tabs"]
        successor = {t["id"]: t["next"] for t in tabs}
        seen, at = set(), "tab#1"
        while at not in seen:
            seen.add(at)
            at = successor[at]
        assert len(seen) == 5 and at == "tab#1", successor
        texts = outputs(cycle_edges, graphs, 50, 19)
        assert len(texts) == 1, f"undirected 6-cycle: {len(texts)} outputs"

    @case
    def wl_equivalent_c3_c6() -> None:
        c3_c6 = outputs(lambda rng: cycles(rng, (3, 6)), graphs, 40, 20)
        assert len(c3_c6) == 1, f"C3+C6: {len(c3_c6)} outputs"
        c9 = outputs(lambda rng: cycles(rng, (9,)), graphs, 10, 21)
        assert len(c9) == 1 and c9 != c3_c6, "C9 and C3+C6 are not isomorphic but compare equal"

    def undirected(edges: List[Tuple[int, int]], count: int) -> Any:
        def make(rng: random.Random) -> Dict[str, Any]:
            names = _names(list(range(count)), rng)
            nbrs: Dict[int, List[str]] = {v: [] for v in range(count)}
            for a, b in edges:
                nbrs[a].append(names[b])
                nbrs[b].append(names[a])
            nodes = [{"id": names[v], "nbrs": rng.sample(nbrs[v], len(nbrs[v]))} for v in range(count)]
            rng.shuffle(nodes)
            return {"nodes": nodes}

        return make

    @case
    def strongly_regular_graphs() -> None:
        # The 4x4 rook graph and the Shrikhande graph are both srg(16, 6, 2, 2): every refinement-only
        # method colors them alike. They must give one output each, and different outputs.
        rook = [(a, b) for a in range(16) for b in range(a + 1, 16) if a // 4 == b // 4 or a % 4 == b % 4]
        steps = {(0, 1), (0, 3), (1, 0), (3, 0), (1, 1), (3, 3)}
        shrikhande = [(a, b) for a in range(16) for b in range(a + 1, 16)
                      if ((a // 4 - b // 4) % 4, (a % 4 - b % 4) % 4) in steps]
        petersen = [(i, (i + 1) % 5) for i in range(5)] + [(5 + i, 5 + (i + 2) % 5) for i in range(5)] + \
                   [(i, i + 5) for i in range(5)]
        found = []
        for salt, (edges, count) in enumerate(((rook, 16), (shrikhande, 16), (petersen, 10))):
            texts = outputs(undirected(edges, count), graphs, 12, 30 + salt)
            assert len(texts) == 1, f"graph {salt}: {len(texts)} outputs"
            found.append(texts.pop())
        assert found[0] != found[1], "rook 4x4 and Shrikhande compare equal"

    @case
    def integer_id_matches_map_key() -> None:
        s = Schema({"$schema": DRAFT_07_URI, **_object(
            focused=_f("/focused", _kind("pane"), type=["integer", "string"]),
            panes=_f("/panes", type="object", propertyNames=_kind("pane"),
                     additionalProperties={"type": "integer", "minimum": 0}),
        )}, contract=True)
        for doc in ({"focused": 7, "panes": {"7": 1, "9": 2}}, {"panes": {"9": 2, "7": 1}, "focused": "7"},
                    {"focused": 9, "panes": {"7": 2, "9": 1}}):
            v = canonicalize(doc, s).value
            assert v["panes"][v["focused"]] == 1, v
        loose = schema_of({"properties": {"focused": _kind("pane")}})
        refused(lambda: canonicalize({"focused": True}, loose), "an id is a string or an integer")

    @case
    def open_objects_use_id_patterns() -> None:
        s = Schema({"$schema": DRAFT_07_URI, "x-oracle-id-patterns": {"pane": "^pane_[0-9a-f]{4}$"},
                    "x-oracle-precision-default": 0.01, **_object(
                        focused=_f("/focused", _kind("pane"), type="string"),
                        extra=_f("/extra", type="object"))}, contract=True)

        def doc(a: str, b: str) -> Dict[str, Any]:
            return {"focused": a, "extra": {a: {"ratio": 0.12345, "next": b}, b: {"ratio": 0.5, "next": None},
                                            "note": f"{a} is here", "list": [b, 1.23456]}}

        v = canonicalize(doc("pane_00aa", "pane_11bb"), s).value
        assert v == {"focused": "pane#2", "extra": {"pane#2": {"ratio": 0.12, "next": "pane#1"},
                                                    "pane#1": {"ratio": 0.5, "next": None},
                                                    "note": "pane#2 is here", "list": ["pane#1", 1.23]}}, v
        assert canonicalize(doc("pane_ffff", "pane_0000"), s).text == canonical_json(v)

    @case
    def wire_keywords_of_the_snapshot_schema() -> None:
        # snapshot-v1: decimal strings, a list of id kinds, open-key rules, unpatterned kinds.
        decimal = {"pattern": DECIMAL_PATTERN, "x-oracle-decimal": True}
        root = {"$schema": DRAFT_07_URI, "x-oracle-id-patterns": {"term": "^term_[0-9a-f]{4}$",
                                                                  "browser": "^browser_[0-9a-f]{4}$"},
                "x-oracle-id-unpatterned": {"surface": "daemon surface handle; typed fields only"},
                "x-oracle-open-keys": [
                    {"key": "^(.+_)?at_ms$", "x-oracle-time": {"unit": "ms", "epoch": "fixture"}},
                    {"key": "^(.+_)?revision$", "x-oracle-volatile": {"reason": "commit count", "task": TASK}}]}
        s = Schema({**root, **_object(
            seen=_f("/seen", decimal, {"x-oracle-time": {"unit": "ms", "epoch": "fixture"}}, type="string"),
            count=_f("/count", decimal, type="string"),
            content=_f("/content", {"x-oracle-id-kind": ["term", "browser"]}, type="string"),
            extra=_f("/extra", type="object"))}, contract=True)
        doc = {"seen": "1500", "count": "10", "content": "browser_00aa",
               "extra": {"closed_at_ms": "1700", "row_revision": 7, "note": "at $x /tmp/o/ab/f"}}
        meta_ctx = Context(root=("/tmp/o/ab",), epoch_ms=1000)
        v = canonicalize(doc, s, meta_ctx).value
        assert v == {"seen": 500, "count": 10, "content": "browser#1",
                     "extra": {"closed_at_ms": 700, "note": "at $x $ROOT/f"}}, v
        # Ids inside an open string (README "Id relabeling"): `itm_w_<uuid>_ws_<hex>` holds two ids.
        u = Schema({**root, "x-oracle-id-patterns": {
            "uuid": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", "workspace": "^ws_[0-9a-f]{4}$"},
            **_object(extra=_f("/extra", type="object"))}, contract=True)

        def item(machine: str, ws: str) -> Dict[str, Any]:
            return {"extra": {"rows": [f"itm_w_{machine}_ws_{ws}", f"sec_m_{machine}", f"news_{ws}x"]}}

        first = canonicalize(item("78bbf1cd-d977-4707-94c8-55d4f26863f0", "eb25"), u).value
        assert first == {"extra": {"rows": ["itm_w_uuid#1_workspace#1", "sec_m_uuid#1", "news_eb25x"]}}, first
        assert canonicalize(item("42fd84d1-fa1d-4ad4-85f0-84dc026bd0cd", "fb53"), u).value["extra"]["rows"][:2] \
            == first["extra"]["rows"][:2]
        try:
            canonicalize({**doc, "content": "pane_00aa"}, s)
            raise AssertionError("a value of no listed kind was labeled")
        except OracleError as error:
            assert "matches none of the id kinds" in str(error), error
        assert validate({**doc, "count": "010"}, s.doc), "a non-canonical decimal string passed"
        refusals = [({"type": "string", "x-oracle-decimal": True}, "x-oracle-decimal marks a string"),
                    ({"type": "string", "x-oracle-id-kind": ["term", "surface"]}, "has no x-oracle-id-patterns"),
                    ({"type": "string", "x-oracle-time": {"unit": "ms", "epoch": "fixture"}}, "marks a number")]
        for bad, message in refusals:
            try:
                Schema({**root, **_object(x=_f("/x", **bad))}, contract=True)
                raise AssertionError(f"{bad} was not refused")
            except SchemaError as error:
                assert message in str(error), error

    @case
    def rewrite_only_marked_fields() -> None:
        r = _Rewriter(Context(root=("/tmp/o/ab",)))
        assert r.apply("path", "/tmp/o/ab/x")[0] == "$ROOT/x"
        assert r.apply("path", "/tmp/o/abc/x")[0] == "/tmp/o/abc/x"
        assert r.apply("url", "file:///tmp/o/ab/x")[0] == "file://$ROOT/x"
        assert r.apply("path", "cd /tmp/o/ab && ls")[0] == "cd $ROOT && ls"
        doc = {"windows": [{"id": "w", "workspaces": [{"id": "s", "title": "/tmp/o/ab/t", "cwd": "/tmp/o/ab/c",
                                                        "panes": []}]}], "panes": {}}
        space = canonicalize(doc, schema, Context(root=("/tmp/o/ab",))).value["windows"][0]["workspaces"][0]
        assert space["title"] == "/tmp/o/ab/t" and space["cwd"] == "$ROOT/c", space

    @case
    def app_environment_rewrite_matches() -> None:
        fixture = json.loads(PATH_REWRITE_FIXTURE.read_text())
        ctx = Context(root=tuple(fixture["root"]), home=tuple(fixture["home"]))
        assert app_environment(ctx) == fixture["environment"], app_environment(ctx)
        r = _Rewriter(ctx)
        for row in fixture["cases"]:
            assert r.apply("path", row["text"])[0] == row["expected"], row
        refused(lambda: app_environment(Context(root=("/a:b",), home=("/h",))), "cannot be passed")
        refused(lambda: app_environment(Context(root=("/a",))), "one hermetic home")

    @case
    def longest_prefix_wins() -> None:
        r = _Rewriter(Context(root=("/home/u/.cache/o/1",), home=("/home/u/",)))
        assert r.apply("path", "/home/u/.cache/o/1/s.sock")[0] == "$ROOT/s.sock"
        assert r.apply("path", "/home/u/src")[0] == "$HOME/src"
        refused(lambda: _Rewriter(Context(root=("/a",), home=("/a",))), "both")

    @case
    def web_origin_rewrite_respects_port() -> None:
        r = _Rewriter(Context(web=("http://127.0.0.1:4321",)))
        assert r.apply("url", "http://127.0.0.1:4321/page?q=1")[0] == "$WEB/page?q=1"
        assert r.apply("url", "http://127.0.0.1:43210/page")[0] == "http://127.0.0.1:43210/page"
        assert r.apply("path", "http://127.0.0.1:4321/page")[0] == "http://127.0.0.1:4321/page"

    clocked = Schema({"$schema": DRAFT_07_URI, **_object(
        meta=_f("/meta", **_object(clock=_f("/meta/clock", enum=["virtual", "wall"]))),
        t=_f("/t", {"x-oracle-time": {"unit": "ms", "epoch": "fixture"}, "x-oracle-precision": 1}, type="number"),
        s=_f("/s", {"x-oracle-time": {"unit": "s", "epoch": "fixture"}, "x-oracle-precision": 0.001}, type="number"),
        totals=_f("/totals", **_object(applied=_f("/totals/applied", {"x-oracle-counter": "monotonic"},
                                                  type="integer"))),
        bins=_f("/bins", SET, type="array", items=_object(
            n=_f("/bins/*/n", {"x-oracle-counter": "monotonic"}, type="integer"))),
    )}, contract=True)

    @case
    def time_offsets_and_wall_clock() -> None:
        virtual = canonicalize({"meta": {"clock": "virtual"}, "t": 1500, "s": 3.5}, clocked, Context(epoch_ms=1000))
        assert virtual.value == {"meta": {"clock": "virtual"}, "t": 500, "s": 2.5}, virtual.value
        wall = canonicalize({"meta": {"clock": "wall"}, "t": 1500}, clocked, Context(epoch_ms=1000))
        assert wall.value["t"] == WALL_CLOCK_MARK

    @case
    def counter_deltas() -> None:
        values = [r.value["totals"]["applied"] for r in canonicalize_case(
            [{"totals": {"applied": n}} for n in (10, 12, 3)], clocked)]
        assert values == [0, 2, 3], values
        refused(lambda: canonicalize({"bins": [{"n": 1}]}, clocked), "inside a set array")

    @case
    def float_default_rounding() -> None:
        s = schema_of({"additionalProperties": {"type": "number"}})
        v = canonicalize({"a": 0.12345, "b": 2.0, "c": -0.0, "d": -0.0004, "e": 7, "f": 1e20}, s).value
        assert v == {"a": 0.123, "b": 2, "c": 0, "d": 0, "e": 7, "f": 1e20}, v
        assert canonical_json(v) == '{"a":0.123,"b":2,"c":0,"d":0,"e":7,"f":1e+20}'

    @case
    def precision_annotation() -> None:
        doc = {"windows": [{"id": "w", "frame": [0.123456, 0.5049, 0.0, 1.0], "workspaces": []}], "panes": {}}
        assert norm(doc).value["windows"][0]["frame"] == [0.12, 0.5, 0, 1]
        refused(lambda: schema_of({"properties": {"x": {"x-oracle-precision": 0.02}}}), "power of ten")
        assert schema_of({"properties": {"x": {"type": "number", "x-oracle-precision": 1}}})

    @case
    def canonicalization_is_idempotent() -> None:
        for rng, m in models(23):
            once = canonicalize(m.render(_names(m.tokens(), rng), shuffle=rng), schema, ctx_a)
            twice = canonicalize(once.value, schema, ctx_a)
            assert once.text == twice.text

    @case
    def sha256_of_canonical_bytes_is_pinned() -> None:
        doc = {"panes": {"b": {"title": "é", "ratio": 0.33333}}, "windows": [], "tags": ["z", "a"]}
        result = norm(doc)
        assert result.text == '{"panes":{"pane#1":{"ratio":0.333,"title":"é"}},"tags":["a","z"],"windows":[]}'
        assert result.sha256 == hashlib.sha256(result.text.encode("utf-8")).hexdigest()
        assert result.sha256 == PINNED_SHA256, result.sha256

    @case
    def validator_reports_pointers() -> None:
        errs = schema.validate({"windows": [{"id": 3, "workspaces": []}], "panes": {"p": {"size": ["x"]}}})[0]
        assert any(e.startswith("/windows/0/id: expected string") for e in errs), errs
        assert any(e.startswith("/panes/p/size/0: expected integer") for e in errs), errs

    @case
    def validator_required_and_additional() -> None:
        errs = schema.validate({"windows": [], "extra": 1})[0]
        assert "/: missing required member 'panes'" in errs and "/: member 'extra' is not allowed" in errs, errs
        assert errors_of({"dependentRequired": {"a": ["b"]}}, {"a": 1}) == ["/: 'a' requires 'b'"]
        assert errors_of({"propertyNames": {"pattern": "^[a-z]+$"}}, {"A": 1})
        assert errors_of({"minProperties": 1}, {}) and not errors_of({"maxProperties": 1}, {"a": 1})

    @case
    def validator_combinators() -> None:
        one = {"oneOf": [{"type": "integer"}, {"type": "number"}]}
        assert errors_of(one, 1) and not errors_of(one, 1.5)
        assert not errors_of({"anyOf": [{"type": "integer"}, {"type": "number"}]}, 1)
        assert errors_of({"not": {"type": "string"}}, "s") and not errors_of({"not": {"type": "string"}}, 1)
        cond = {"if": {"type": "integer"}, "then": {"minimum": 5}, "else": {"type": "string"}}
        assert errors_of(cond, 3) and not errors_of(cond, 6) and errors_of(cond, [1]) and not errors_of(cond, "s")
        assert errors_of({"allOf": [{"minimum": 1}, {"maximum": 2}]}, 3)
        contains = {"contains": {"const": 2}, "maxContains": 1}
        assert errors_of(contains, [1]) and not errors_of(contains, [2]) and errors_of(contains, [2, 2])
        assert Schema(False).validate(1)[0] and not Schema(True).validate(1)[0]

    @case
    def validator_refs_drafts_and_unknown_keywords() -> None:
        s = Schema({"$defs": {"n": {"type": "integer"}}, "items": {"$ref": "#/$defs/n"}})
        assert s.validate([1, "x"])[0] == ["/1: expected integer, got string"]
        d7 = Schema({"$schema": DRAFT_07_URI, "definitions": {"n": {"type": "integer"}},
                     "items": [{"$ref": "#/definitions/n"}, {"type": "string"}], "additionalItems": False})
        assert d7.validate([1, "a"])[0] == [] and d7.validate([1, 2])[0] and d7.validate([1, "a", 3])[0]
        refused(lambda: Schema({"$schema": DRAFT_07_URI, "prefixItems": [True]}), "not a draft-07 keyword")
        refused(lambda: Schema({"$schema": DRAFT_07_URI, "properties": {"a": {"$ref": "#", "type": "string"}}}),
                "beside $ref")
        refused(lambda: Schema({"$schema": "https://json-schema.org/draft/2019-09/schema"}), "not draft-07")
        refused(lambda: Schema({"$ref": "#/$defs/missing"}), "does not resolve")
        refused(lambda: Schema({"$ref": "other.json#/a"}), "only local refs")
        refused(lambda: Schema({"unevaluatedProperties": False}), "unknown keyword")
        refused(lambda: Schema({"properties": {"a": {"x-oracle-volatil": "clock"}}}), "misspelled")
        refused(lambda: Schema({"items": [{"type": "string"}]}), "prefixItems")
        refused(lambda: Schema({"x-oracle-order": "list"}), "x-oracle-order")
        refused(lambda: Schema({"properties": {"a": {"x-oracle-id-patterns": {}}}}), "belongs at the schema root")

    @case
    def validator_scalar_assertions() -> None:
        assert errors_of({"enum": [1, "a"]}, 2) and not errors_of({"enum": [1, "a"]}, 1.0)
        assert errors_of({"const": {"a": [1]}}, {"a": [2]}) and not errors_of({"const": {"a": [1]}}, {"a": [1.0]})
        assert errors_of({"pattern": "^a"}, "ba") and not errors_of({"pattern": "^a"}, "ab")
        assert errors_of({"minLength": 2}, "a") and errors_of({"maxLength": 1}, "ab")
        assert errors_of({"exclusiveMinimum": 1}, 1) and errors_of({"exclusiveMaximum": 1}, 1)
        assert errors_of({"multipleOf": 0.1}, 0.35) and not errors_of({"multipleOf": 0.1}, 0.3)
        assert errors_of({"uniqueItems": True}, [1, 1.0]) and not errors_of({"uniqueItems": True}, [1, True])
        assert errors_of({"type": "integer"}, True) and not errors_of({"type": "integer"}, 2.0)
        assert errors_of({"minItems": 1}, []) and errors_of({"maxItems": 0}, [1])

    @case
    def contract_lint() -> None:
        def contract(doc: Dict[str, Any]) -> Schema:
            return Schema({"$schema": DRAFT_07_URI, **doc}, contract=True)

        refused(lambda: contract({"type": "object", "additionalProperties": {"type": "string"}}),
                "no x-oracle-source on the additionalProperties schema")
        refused(lambda: contract({"type": "array", "x-oracle-order": "set", "items": {"type": "string"}}),
                "no x-oracle-source on the items schema")
        refused(lambda: contract(_object(a={"type": "string"})), "/properties/a: no x-oracle-source")
        refused(lambda: contract(_object(a=_f("/a", type="array", items={"type": "string"}))),
                "needs x-oracle-order")
        refused(lambda: contract(_object(a=_f("/a", type=["number", "null"]))), "needs x-oracle-precision")
        refused(lambda: contract(_object(a={"x-oracle-source": "snapshot.get", "type": "string"})),
                "x-oracle-source is {method, path}")
        refused(lambda: contract(_object(a=_f("/a", {"x-oracle-rewrite": "path"}, type="integer"))), "marks a string")
        inherited = contract(_object(a=_f("/a", type="object", additionalProperties={"type": "string"})))
        assert inherited.validate({"a": {"k": "v"}})[0] == []

    @case
    def refusals_before_normalizing() -> None:
        refused(lambda: parse_json('{"a": NaN}'), "not JSON")
        refused(lambda: parse_json('{"a": Infinity}'), "not JSON")
        refused(lambda: parse_json('{"a": 1e400}'), "out of range")
        refused(lambda: parse_json('{"a": -1e400}'), "out of range")
        refused(lambda: parse_json('{"a": 1, "a": 2}'), "duplicate object key")
        refused(lambda: canonical_json({"a": float("inf")}), "no canonical JSON")
        refused(lambda: norm({"windows": "nope", "panes": {}}), "does not match the schema")
        conflict = schema_of({"properties": {"a": {"allOf": [{"x-oracle-id-kind": "tab"},
                                                             {"x-oracle-id-kind": "pane"}]}}})
        refused(lambda: canonicalize({"a": "x"}, conflict), "disagree")
        stream = io.StringIO()
        assert main(["--list-rules"], out=stream) == 0 and len(stream.getvalue().splitlines()) == len(RULES)

    @case
    def jsonl_errors_name_the_line_and_write_nothing() -> None:
        good = json.dumps({"windows": [], "panes": {}})
        with tempfile.TemporaryDirectory() as tmp:
            schema_path = Path(tmp) / "schema.json"
            schema_path.write_text(json.dumps(SELFTEST_SCHEMA), encoding="utf-8")
            path = Path(tmp) / "case.jsonl"
            for body, code, needle in ((f"{good}\n{{bad\n", 2, f"{path}:2: not JSON"),
                                       (f"{good}\n{good[:-1]}, \"x\": 1}}\n", 1, f"{path}:2: snapshot does not"),
                                       ('{"windows": [], "panes": {}, "tags": [1e999]}\n', 2, "out of range"),
                                       (f"{good}\n\n{good}\n", 0, "")):
                path.write_text(body, encoding="utf-8")
                out, err = io.StringIO(), io.StringIO()
                assert main(["--schema", str(schema_path), str(path)], out, err) == code, err.getvalue()
                assert needle in err.getvalue(), err.getvalue()
                lines = out.getvalue().splitlines()
                assert lines == ([] if code else ['{"panes":{},"windows":[]}'] * 2), lines

    def renamed_example(example: Any, annotations: Dict[Path_, Dict[str, Any]], rng: random.Random) -> Any:
        fresh: Dict[str, str] = {}

        def rename(match: "re.Match[str]") -> str:
            return fresh.setdefault(match.group(0), match.group(1) + f"{rng.getrandbits(128):032x}")

        doc = json.loads(re.sub(r"\b([a-z_]+_)[0-9a-f]{32}\b", rename, json.dumps(example)))
        for at in sorted((at for at, ann in annotations.items() if ann.get("x-oracle-order") == "set"),
                         key=len, reverse=True):
            node = doc
            for part in at:
                node = node[part]
            if isinstance(node, list):  # a nullable set array may be null here
                rng.shuffle(node)
        return _shuffled(doc, rng)

    @case
    def real_schema_example() -> None:
        real = Schema.load(DEFAULT_SCHEMA)
        example = parse_json(EXAMPLE_SNAPSHOT.read_text(encoding="utf-8"))
        errors, annotations = real.validate(example)
        assert errors == [], errors[:5]
        stream = io.StringIO()
        assert main(["--validate", str(EXAMPLE_SNAPSHOT)], out=stream) == 0, stream.getvalue()
        base = canonicalize(example, real)
        raw = set(re.findall(r"\b[a-z_]+_[0-9a-f]{32}\b", json.dumps(example)))
        assert raw and not any(r in base.text for r in raw), "a raw id survives normalization"
        for trial in range(8):
            other = canonicalize(renamed_example(example, annotations, random.Random(f"{seed}:real:{trial}")), real)
            assert other.sha256 == base.sha256, "the real example changes under id renaming and set order"

    @case
    def caller_drop_comes_before_set_order() -> None:
        # Two panes whose set order the engine decides ("engine" sorts before "url"): an engine arm drops it
        # first, so both arms order and label the panes alike (oracle.py --engine).
        real = Schema.load(DEFAULT_SCHEMA)
        example = parse_json(EXAMPLE_SNAPSHOT.read_text(encoding="utf-8"))
        tab = example["facets"]["tabs"]["panes"][0]["tabs"][0]

        def arm(engines: Tuple[str, str]) -> Any:
            doc = json.loads(json.dumps(example))
            doc["facets"]["tabs"]["panes"] = [
                {"pane": f"pane_{n:032x}", "selected": f"tab_{n + 16:032x}",
                 "tabs": [{**tab, "tab": f"tab_{n + 16:032x}", "engine": engine, "url": f"$WEB/{name}.html"}]}
                for n, engine, name in ((0xa1, engines[0], "a"), (0xa2, engines[1], "b"))]
            return doc

        neutral = Context(drop=("/facets/tabs/panes/*/tabs/*/engine",))
        webkit, chromium = arm(("webkit", "webkit")), arm(("webkit", "cef"))
        def urls(result: Result) -> List[str]:
            return [p["tabs"][0]["url"] for p in result.value["facets"]["tabs"]["panes"]]

        assert urls(canonicalize(webkit, real)) != urls(canonicalize(chromium, real)), "dropping it after is too late"
        a, b = canonicalize(webkit, real, neutral), canonicalize(chromium, real, neutral)
        assert a.text == b.text, "the engine decided the pane order"
        assert urls(a) == ["$WEB/a.html", "$WEB/b.html"], urls(a)
        assert not any("engine" in t for p in a.value["facets"]["tabs"]["panes"] for t in p["tabs"])
        drops = [e["pointer"] for e in a.explain if e["rule"] == "drop"]
        assert drops == ["/facets/tabs/panes/0/tabs/0/engine", "/facets/tabs/panes/1/tabs/0/engine"], drops
        refused(lambda: canonicalize(webkit, real, Context(drop=("facets",))), "not a JSON pointer")

    @case
    def validate_api_for_case_schemas() -> None:
        case_schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "properties": {
            "steps": {"type": "array", "x-oracle-unique": {"key": "/id", "error": "duplicate"},
                      "items": {"type": "object", "required": ["id"]}}}}
        assert validate({"steps": [{"id": "a"}]}, case_schema) == []
        assert validate({"steps": [{}]}, case_schema) == ["/steps/0: missing required member 'id'"]
        assert "schema refused" in validate(1, {"bogus": 1})[0]

    @case
    def large_and_symmetric_cases_are_fast() -> None:
        def timed(fn: Any) -> float:
            began = time.perf_counter()
            fn()
            return time.perf_counter() - began

        spaces = [{"id": f"s{i:04d}", "panes": [f"p{i:04d}a", f"p{i:04d}b"]} for i in range(800)]
        wide = {"windows": [{"id": "w", "workspaces": spaces}],
                "panes": {f"p{i:04d}{x}": {"workspace": f"s{i:04d}"} for i in range(800) for x in "ab"}}
        many = {"windows": [{"id": "w", "workspaces": [
            {"id": f"s{j}", "panes": [f"p{j}-{i}" for i in range(4000)]} for j in range(2)]}], "panes": {}}
        chain = {"tabs": [{"id": f"t{i}", "next": f"t{i + 1}" if i < 999 else None} for i in range(1000)]}
        big_ring = ring(random.Random(seed), 1000)
        pairs = {"tabs": [{"id": f"t{i}", "next": f"t{i ^ 1}"} for i in range(400)]}
        rings = {"tabs": [{"id": f"t{i}", "next": f"t{i - i % 5 + (i + 1) % 5}"} for i in range(500)]}
        # Measured on cmux-orchestrator-1: 0.10, 0.13, 0.04, 0.12, 0.10 and 0.07 s. The bounds leave room for
        # slower fleet hosts and catch a return of the quadratic refinement (3.8, 8.3 and > 120 s before).
        for name, fn, bound in (("800 identical workspaces", lambda: canonicalize(wide, schema), 2.0),
                                ("2 sets of 4000 pane ids", lambda: canonicalize(many, schema), 2.0),
                                ("1000-tab chain", lambda: canonicalize(chain, graphs), 2.0),
                                ("1000-tab ring", lambda: canonicalize(big_ring, graphs), 2.0),
                                ("200 two-tab rings", lambda: canonicalize(pairs, graphs), 2.0),
                                ("100 identical five-tab rings", lambda: canonicalize(rings, graphs), 2.0)):
            spent = timed(fn)
            assert spent < bound, f"{name}: {spent:.2f} s (bound {bound} s)"

    failures = 0
    for number, (name, fn) in enumerate(cases, 1):
        try:
            fn()
            out.write(f"ok {number} {name}\n")
        except Exception as error:  # noqa: BLE001 - a selftest reports every failure, then exits non-zero
            failures += 1
            out.write(f"FAIL {number} {name}: {type(error).__name__}: {error}\n")
    out.write(f"{len(cases) - failures}/{len(cases)} property cases passed (seed {seed})\n")
    if len(cases) < 30:
        out.write(f"expected at least 30 property cases, found {len(cases)}\n")
        return 1
    return 1 if failures else 0


PINNED_SHA256 = "c8af40a1466c97a078a3aa7f52ec9bec3317e977b35e2a06b135aedc01a0b9ee"

if __name__ == "__main__":
    sys.exit(main())
