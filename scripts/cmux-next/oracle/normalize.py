#!/usr/bin/env python3
"""Oracle snapshot canonicalizer and the one stdlib JSON Schema validator (p15-oracle-013).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3C. Stdlib only and safe under `python3 -I`
(fleet minis have no jsonschema; rule 9: this is the one validator).

A snapshot becomes canonical JSON in five rules, each listed with its reason by `--list-rules`:

  volatile  drop a member only when the schema marks it `x-oracle-volatile: "<reason>"`; nothing else drops
  path      `$ROOT`, `$HOME`, `$WEB` for the run's state root, home and loopback origins (`--root/--home/--web`)
  number    floats to `x-oracle-precision` (default 1e-3); an integral float prints as an integer
  set       `x-oracle-order: "set"` arrays sorted by the canonical JSON of each element
  id        `x-oracle-id-kind: K` values (and `x-oracle-key-id-kind: K` object keys) become `K#1`, `K#2`, ...

Ids are numbered per kind in first-seen order of a sorted-key traversal. Unordered parts (sets and id-keyed
maps) are visited in the order of their content with ids replaced by a color from color refinement
(Weisfeiler-Lehman), so the labels depend on what the ids are attached to, never on their raw values or on the
producer's iteration order. Chromium's DevTools protocol tests stabilize ids the same way, but by type only
(third_party/blink/web_tests/http/tests/inspector-protocol/resources/inspector-protocol-test.js,
`stabilizeNames`); numbering by kind keeps the relations between ids, which the oracle compares. Canonical
JSON has sorted keys like base::Value::Dict (base/values.h) written by base/json/json_writer.h.

The schema decides every rule through annotations collected while it validates the snapshot, with JSON Schema
2020-12 annotation rules: a keyword applies only from a subschema that passed (an `anyOf` branch that does not
match marks nothing). An invalid snapshot is refused, never normalized.

Schema keywords this file owns (schemas/oracle/README.md, p15-oracle-011, documents them for authors):
  x-oracle-volatile      reason string; the member is dropped
  x-oracle-order         "set" or "list" (default "list": order is behavior)
  x-oracle-id-kind       id kind of a string or integer value
  x-oracle-key-id-kind   id kind of every member name of an object
  x-oracle-precision     power of ten, 1 down to 1e-9 (windows frames: 0.01)
  x-oracle-source        source method(s) of the value (checked by `--lint-schema --require-source`)

Usage:
  normalize.py [--schema S] [--root DIR]... [--home DIR]... [--web ORIGIN]... [--explain] [--sha256] [FILE|-]...
  normalize.py --validate [--schema S] FILE...
  normalize.py --lint-schema [--schema S] [--require-source]
  normalize.py --list-rules
  normalize.py --selftest [--seed N]

A `.jsonl` input holds one snapshot per line; its snapshots share one id labeler, so an id keeps its label
across the checkpoints of a case (invariant I2). `--explain` writes one JSON line per applied rule to stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import random
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

TASK = "p15-oracle-013"
REPO = Path(__file__).resolve().parents[3]
DEFAULT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"

# Every rule has a reason naming the source of nondeterminism and a task id (spec rule 6).
RULES: Dict[str, str] = {
    "volatile": "the schema marks the member x-oracle-volatile; its reason names the nondeterministic source "
    "(wall clock, pid, ephemeral port). Only schema-marked members are dropped.",
    "path": "per-case state roots, HOME and loopback server ports are fresh for every run "
    "(hermetic per-case env); the rest of the string is kept.",
    "number": "Swift (Foundation) and Rust (serde_json/ryu) print doubles differently, and layout "
    "arithmetic differs in the last bits across CPUs; 1.0 and 1 are the same JSON number.",
    "set": "the producer iterates a HashMap, Dictionary or Set; the schema marks the array x-oracle-order: set.",
    "id": "ids come from UUID(), Uuid::new_v4 and per-process counters (spec section 2.7); "
    "only which values are the same id is behavior.",
}

ORACLE_KEYWORDS = {
    "x-oracle-volatile",
    "x-oracle-order",
    "x-oracle-id-kind",
    "x-oracle-key-id-kind",
    "x-oracle-precision",
    "x-oracle-source",
}
ANNOTATION_KEYWORDS = {
    "$schema", "$id", "$comment", "title", "description", "default", "examples", "format",
    "deprecated", "readOnly", "writeOnly", "contentMediaType", "contentEncoding",
}
DEFS_KEYWORDS = {"$defs", "definitions"}
SINGLE_SUBSCHEMA = {"not", "if", "then", "else", "additionalProperties", "items", "contains", "propertyNames"}
MAP_SUBSCHEMA = {"properties", "patternProperties", "dependentSchemas"}
LIST_SUBSCHEMA = {"allOf", "anyOf", "oneOf", "prefixItems"}
NON_NEGATIVE_INT = {"minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
                    "minContains", "maxContains"}
NUMBER_BOUNDS = {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}
OTHER_ASSERTIONS = {"type", "enum", "const", "required", "pattern", "uniqueItems", "multipleOf",
                    "dependentRequired", "$ref"}
JSON_TYPES = {"null", "boolean", "object", "array", "number", "string", "integer"}
KIND_RE = re.compile(r"^[a-z][A-Za-z0-9_-]*$")
DEFAULT_PRECISION_DECIMALS = 3
MAX_SAFE_INT = 2 ** 53


class OracleError(Exception):
    """A refusal with a message for the person: bad schema, invalid snapshot, ambiguous rule."""


class SchemaError(OracleError):
    pass


class SnapshotInvalid(OracleError):
    def __init__(self, errors: List[str]):
        super().__init__("snapshot does not match the schema:\n  " + "\n  ".join(errors[:50]))
        self.errors = errors


Path_ = Tuple[Any, ...]  # instance location: str for an object member, int for an array index


def pointer(path: Iterable[Any]) -> str:
    return "".join("/" + str(p).replace("~", "~0").replace("/", "~1") for p in path)


# ---------------------------------------------------------------------------------------------------------
# JSON input


def _refuse_constant(name: str) -> Any:
    raise OracleError(f"{name} is not JSON")


def _refuse_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise OracleError(f"duplicate object key {key!r}: the last value would hide the first")
        out[key] = value
    return out


def parse_json(text: str) -> Any:
    try:
        return json.loads(text, parse_constant=_refuse_constant, object_pairs_hook=_refuse_duplicates)
    except json.JSONDecodeError as error:
        raise OracleError(f"not JSON: {error}") from None


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


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


# ---------------------------------------------------------------------------------------------------------
# Schema: lint, validation and annotation collection


def _precision_decimals(value: Any) -> Optional[int]:
    if not _is_number(value) or value <= 0:
        return None
    for decimals in range(0, 10):
        if math.isclose(value, 10.0 ** -decimals, rel_tol=1e-12):
            return decimals
    return None


class Schema:
    """A linted JSON Schema (2020-12 subset). Keywords it does not implement are refused, never ignored."""

    def __init__(self, doc: Any, origin: str = "<schema>", require_source: bool = False):
        self.doc = doc
        self.origin = origin
        self._patterns: Dict[str, Any] = {}
        problems: List[str] = []
        self._lint(doc, (), problems)
        if require_source:
            self._lint_sources(doc, (), False, problems, set())
        if problems:
            raise SchemaError(f"{origin}: schema refused:\n  " + "\n  ".join(problems))

    @classmethod
    def load(cls, path: Path, require_source: bool = False) -> "Schema":
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            raise SchemaError(f"{path}: no schema (the snapshot schema is p15-oracle-011)") from None
        return cls(parse_json(text), str(path), require_source)

    # -- lint

    def _lint(self, node: Any, at: Path_, problems: List[str]) -> None:
        where = pointer(at) or "/"
        if isinstance(node, bool):
            return
        if not isinstance(node, dict):
            problems.append(f"{where}: a schema is an object or a boolean")
            return
        for key, value in node.items():
            here = at + (key,)
            if key in ORACLE_KEYWORDS:
                self._lint_oracle(key, value, pointer(here), problems)
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
                    problems.append(f"{pointer(here)}: array form of items; use prefixItems (2020-12)")
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
            if not isinstance(value, str) or len(value.strip()) < 3:
                problems.append(f"{where}: x-oracle-volatile needs a reason string naming the nondeterministic source")
        elif key == "x-oracle-order":
            if value not in ("set", "list"):
                problems.append(f"{where}: x-oracle-order is \"set\" or \"list\"")
        elif key in ("x-oracle-id-kind", "x-oracle-key-id-kind"):
            if not isinstance(value, str) or not KIND_RE.match(value):
                problems.append(f"{where}: {key} is a kind name matching {KIND_RE.pattern}")
        elif key == "x-oracle-precision":
            if _precision_decimals(value) is None:
                problems.append(f"{where}: x-oracle-precision is a power of ten from 1 down to 1e-9")
        elif key == "x-oracle-source":
            names = value if isinstance(value, list) else [value]
            if not names or not all(isinstance(n, str) and n.strip() for n in names):
                problems.append(f"{where}: x-oracle-source is a method name or a non-empty list of them")

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

    def _lint_sources(self, node: Any, at: Path_, inherited: bool, problems: List[str],
                      seen: set) -> None:
        if not isinstance(node, dict) or (at, inherited) in seen:
            return
        seen.add((at, inherited))
        has = inherited or self._has_source(node)
        if "$ref" in node and isinstance(node["$ref"], str):
            try:
                target = self.resolve(node["$ref"])
                where = tuple(p.replace("~1", "/").replace("~0", "~") for p in node["$ref"][2:].split("/") if p)
                self._lint_sources(target, where, has, problems, seen)
            except SchemaError:
                pass
        for key in ("properties", "patternProperties"):
            for name, sub in (node.get(key) or {}).items():
                if not (has or self._has_source(sub)):
                    problems.append(f"{pointer(at + (key, name))}: no x-oracle-source on the field or above it")
                self._lint_sources(sub, at + (key, name), has, problems, seen)
        for key in ("additionalProperties", "items", "not", "if", "then", "else", "contains"):
            if key in node:
                self._lint_sources(node[key], at + (key,), has, problems, seen)
        for key in ("allOf", "anyOf", "oneOf", "prefixItems"):
            for index, sub in enumerate(node.get(key) or []):
                self._lint_sources(sub, at + (key, index), has, problems, seen)
        # Definitions are checked where a $ref uses them, with that site's inherited source.

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

    # -- validation

    def validate(self, instance: Any) -> Tuple[List[str], Dict[Path_, Dict[str, Any]]]:
        """Returns (errors, annotations by instance location). Annotations are empty when errors exist."""
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
        for key in ("allOf",):
            for index, schema in enumerate(node.get(key, [])):
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
            self._check_object(inst, node, at, errors, sub)

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
        prefix = node.get("prefixItems", [])
        for index, value in enumerate(inst):
            if index < len(prefix):
                sub(value, prefix[index], at + (index,))
            elif "items" in node:
                sub(value, node["items"], at + (index,))
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
                      sub: Any) -> None:
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
            if "propertyNames" in node:
                e, _ = self._check(name, node["propertyNames"], at)
                errors.extend(f"{where}: member name {name!r}: {msg}" for msg in e)
            covered = False
            if name in properties:
                covered = True
                sub(value, properties[name], at + (name,))
            for pattern, schema in patterns.items():
                if self._compile(pattern, where).search(name):
                    covered = True
                    sub(value, schema, at + (name,))
            if not covered and "additionalProperties" in node:
                if node["additionalProperties"] is False:
                    errors.append(f"{where}: member {name!r} is not allowed")
                else:
                    sub(value, node["additionalProperties"], at + (name,))


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


# ---------------------------------------------------------------------------------------------------------
# Canonicalization


@dataclass(frozen=True)
class Context:
    """The run's nondeterministic prefixes. Several values per token cover realpath aliases (/private/tmp)."""

    root: Tuple[str, ...] = ()
    home: Tuple[str, ...] = ()
    web: Tuple[str, ...] = ()


class _Rewriter:
    # A prefix matches only as a whole path or origin: never inside a longer name or port.
    _BEFORE = r"(?<![A-Za-z0-9._~-])"
    _AFTER = r"(?![A-Za-z0-9._~-])"

    def __init__(self, ctx: Context):
        table: Dict[str, str] = {}
        for token, values in (("$ROOT", ctx.root), ("$HOME", ctx.home), ("$WEB", ctx.web)):
            for value in values:
                trimmed = value.rstrip("/")
                if not trimmed:
                    raise OracleError(f"{token} prefix {value!r} is empty or '/'")
                if table.get(trimmed, token) != token:
                    raise OracleError(f"{trimmed!r} is given for both {table[trimmed]} and {token}")
                table[trimmed] = token
        self.table = table
        ordered = sorted(table, key=lambda p: (-len(p), p))  # longest first: a root inside home is $ROOT
        self.regex = (
            re.compile(self._BEFORE + "(" + "|".join(re.escape(p) for p in ordered) + ")" + self._AFTER)
            if ordered else None
        )

    def apply(self, text: str) -> Tuple[str, List[str]]:
        if self.regex is None:
            return text, []
        used: List[str] = []

        def swap(match: "re.Match[str]") -> str:
            token = self.table[match.group(1)]
            used.append(token)
            return token

        return self.regex.sub(swap, text), used


class _Id:
    __slots__ = ("kind", "key")

    def __init__(self, kind: str, raw: Any):
        self.kind = kind
        self.key = (kind, type(raw).__name__, raw)  # 7 and "7" are different ids


class _Set:
    __slots__ = ("items", "at")

    def __init__(self, items: List[Any], at: Path_):
        self.items = items
        self.at = at


class _Entry:
    __slots__ = ("ident", "value")

    def __init__(self, ident: _Id, value: Any):
        self.ident = ident
        self.value = value


class _IdMap:
    __slots__ = ("kind", "entries", "at")

    def __init__(self, kind: str, entries: List[_Entry], at: Path_):
        self.kind = kind
        self.entries = entries
        self.at = at


class _Serializer:
    """Content of a lifted tree with ids replaced by their colors; `me` is written as §self. Strings of
    subtrees that do not contain `me` are cached, so one refinement round is linear in the tree size."""

    def __init__(self, colors: Dict[Tuple[Any, ...], str], contains: Dict[int, frozenset]):
        self.colors = colors
        self.contains = contains
        self.cache: Dict[int, str] = {}

    def __call__(self, node: Any, me: Optional[Tuple[Any, ...]] = None) -> str:
        if isinstance(node, _Id):
            return '"§self"' if node.key == me else json.dumps("§" + self.colors[node.key])
        if not isinstance(node, (dict, list, _Set, _IdMap, _Entry)):
            return json.dumps(node, ensure_ascii=False)
        mine = me is not None and me in self.contains[id(node)]
        if not mine and id(node) in self.cache:
            return self.cache[id(node)]
        inner = me if mine else None
        if isinstance(node, dict):
            text = "{" + ",".join(json.dumps(k) + ":" + self(node[k], inner) for k in sorted(node)) + "}"
        elif isinstance(node, list):
            text = "[" + ",".join(self(v, inner) for v in node) + "]"
        elif isinstance(node, _Set):
            text = "<" + ",".join(sorted(self(v, inner) for v in node.items)) + ">"
        elif isinstance(node, _IdMap):
            text = "{#" + ",".join(sorted(self(e, inner) for e in node.entries)) + "}"
        else:
            text = "(" + self(node.ident, inner) + ":" + self(node.value, inner) + ")"
        if not mine:
            self.cache[id(node)] = text
        return text


class Labeler:
    """Per-kind id numbering. Share one across the snapshots of a case so an id keeps its label (I2)."""

    def __init__(self) -> None:
        self.labels: Dict[Tuple[Any, ...], str] = {}
        self.counts: Dict[str, int] = {}

    def assign(self, key: Tuple[Any, ...]) -> str:
        label = self.labels.get(key)
        if label is None:
            kind = key[0]
            self.counts[kind] = self.counts.get(kind, 0) + 1
            label = f"{kind}#{self.counts[kind]}"
            self.labels[key] = label
        return label


@dataclass
class Result:
    value: Any
    text: str
    sha256: str
    explain: List[Dict[str, Any]] = field(default_factory=list)


def _node_count(value: Any) -> int:
    if isinstance(value, dict):
        return 1 + sum(_node_count(v) for v in value.values())
    if isinstance(value, list):
        return 1 + sum(_node_count(v) for v in value)
    return 1


class _Canonicalizer:
    def __init__(self, annotations: Dict[Path_, Dict[str, Any]], ctx: Context, labeler: Labeler):
        self.ann = annotations
        self.rewriter = _Rewriter(ctx)
        self.labeler = labeler
        self.explain: List[Dict[str, Any]] = []
        self.dropped_nodes = 0
        self.id_sites: Dict[Tuple[Any, ...], List[str]] = {}

    def note(self, rule: str, at: Path_, **extra: Any) -> None:
        self.explain.append({"rule": rule, "pointer": pointer(at), "task": TASK, **extra})

    # Pass 1: drop volatile members, rewrite paths, round numbers; mark ids, sets and id-keyed maps.
    def lift(self, value: Any, at: Path_) -> Any:
        ann = self.ann.get(at, {})
        kind = ann.get("x-oracle-id-kind")
        if isinstance(value, dict):
            if kind:
                raise OracleError(f"{pointer(at)}: x-oracle-id-kind marks an object; mark its id member")
            return self._lift_object(value, at, ann.get("x-oracle-key-id-kind"))
        if isinstance(value, list):
            if kind:
                raise OracleError(f"{pointer(at)}: x-oracle-id-kind marks an array; mark its items")
            items = []
            for index, item in enumerate(value):
                if "x-oracle-volatile" in self.ann.get(at + (index,), {}):
                    raise OracleError(f"{pointer(at + (index,))}: x-oracle-volatile marks an array item; "
                                      "mark the member that holds it")
                items.append(self.lift(item, at + (index,)))
            if ann.get("x-oracle-order") == "set":
                return _Set(items, at)
            return items
        if kind and value is not None:
            if isinstance(value, bool) or isinstance(value, float):
                raise OracleError(f"{pointer(at)}: an id is a string or an integer, got {_type_name(value)}")
            ident = _Id(kind, value)
            self.id_sites.setdefault(ident.key, []).append(pointer(at))
            return ident
        if isinstance(value, str):
            text, used = self.rewriter.apply(value)
            if used:
                self.note("path", at, tokens=sorted(set(used)))
            return text
        if isinstance(value, float):
            return self._round(value, at, ann)
        return value

    def _lift_object(self, value: Dict[str, Any], at: Path_, key_kind: Optional[str]) -> Any:
        members: Dict[str, Any] = {}
        entries: List[_Entry] = []
        origins: Dict[str, str] = {}
        for name, item in value.items():
            child = at + (name,)
            reason = self.ann.get(child, {}).get("x-oracle-volatile")
            if reason is not None:
                self.dropped_nodes += _node_count(item)
                self.note("volatile", child, reason=reason)
                continue
            lifted = self.lift(item, child)
            if key_kind:
                ident = _Id(key_kind, name)
                self.id_sites.setdefault(ident.key, []).append(pointer(child))
                entries.append(_Entry(ident, lifted))
                continue
            new_name, used = self.rewriter.apply(name)
            if used:
                self.note("path", child, tokens=sorted(set(used)), member_name=True)
            if new_name in origins:
                raise OracleError(f"{pointer(at) or '/'}: members {origins[new_name]!r} and {name!r} both become "
                                  f"{new_name!r}; a rewrite may never merge two members")
            origins[new_name] = name
            members[new_name] = lifted
        if key_kind:
            return _IdMap(key_kind, entries, at)
        return members

    def _round(self, value: float, at: Path_, ann: Dict[str, Any]) -> Any:
        precision = ann.get("x-oracle-precision")
        decimals = DEFAULT_PRECISION_DECIMALS if precision is None else _precision_decimals(precision)
        rounded = round(value, decimals)
        if rounded == 0:
            rounded = 0.0  # -0.0 and 0.0 are one value
        out: Any = int(rounded) if rounded.is_integer() and abs(rounded) < MAX_SAFE_INT else rounded
        if out != value or type(out) is not float:
            self.note("number", at, decimals=decimals)
        return out

    # Pass 2: color refinement. An id's color is its kind, refined by the positions it occurs at and by the
    # content around it with other ids replaced by their colors, until the partition stops splitting.
    def occurrences(self, tree: Any) -> Tuple[Dict[Tuple[Any, ...], List[Tuple[str, Any]]], Dict[int, frozenset]]:
        """For every id: (position, unit) per occurrence. The unit is the outermost unordered element around
        it (a set item or an id-map entry); positions inside unordered parts use '*' instead of an index.
        Also returns the ids each container holds, for the serializer cache."""
        found: Dict[Tuple[Any, ...], List[Tuple[str, Any]]] = {}
        contains: Dict[int, frozenset] = {}

        def walk(node: Any, position: str, unit: Any) -> frozenset:
            if isinstance(node, _Id):
                found.setdefault(node.key, []).append((position, unit))
                return frozenset((node.key,))
            held: List[frozenset] = []
            if isinstance(node, dict):
                for name in sorted(node):
                    held.append(walk(node[name], position + "/" + json.dumps(name), unit))
            elif isinstance(node, list):
                for index, item in enumerate(node):
                    held.append(walk(item, f"{position}/{index}", unit))
            elif isinstance(node, _Set):
                for item in node.items:
                    held.append(walk(item, position + "/*", item if unit is None else unit))
            elif isinstance(node, _IdMap):
                for entry in node.entries:
                    owner = entry if unit is None else unit
                    keys = walk(entry.ident, position + "/{key}", owner)
                    keys |= walk(entry.value, position + "/{value}", owner)
                    contains[id(entry)] = keys
                    held.append(keys)
            else:
                return frozenset()
            keys = frozenset().union(*held)
            contains[id(node)] = keys
            return keys

        walk(tree, "", None)
        return found, contains

    def refine(self, tree: Any) -> _Serializer:
        found, contains = self.occurrences(tree)
        colors = {key: ("L:" + self.labeler.labels[key]) if key in self.labeler.labels else ("K:" + key[0])
                  for key in found}
        fixed = {key for key in found if key in self.labeler.labels}
        classes = len(set(colors.values()))
        for _ in range(len(found) + 1):
            text = _Serializer(colors, contains)
            refined: Dict[Tuple[Any, ...], str] = {}
            for key, sites in found.items():
                if key in fixed:
                    refined[key] = colors[key]
                    continue
                context = sorted(position + "|" + ("" if unit is None else text(unit, key)) for position, unit in sites)
                digest = hashlib.sha256("\0".join([colors[key]] + context).encode("utf-8")).hexdigest()
                refined[key] = key[0] + ":" + digest[:24]
            colors = refined
            count = len(set(colors.values()))
            if count == classes:
                break
            classes = count
        return _Serializer(colors, contains)

    # Pass 3: number ids in first-seen order of a sorted-key traversal; unordered parts in color order.
    def label(self, tree: Any, text: _Serializer) -> None:
        def visit(node: Any) -> None:
            if isinstance(node, _Id):
                self.labeler.assign(node.key)
            elif isinstance(node, dict):
                for name in sorted(node):
                    visit(node[name])
            elif isinstance(node, list):
                for item in node:
                    visit(item)
            elif isinstance(node, _Set):
                for item in sorted(node.items, key=text):
                    visit(item)
            elif isinstance(node, _IdMap):
                for entry in sorted(node.entries, key=text):
                    visit(entry.ident)
                    visit(entry.value)

        visit(tree)

    # Pass 4: plain JSON with labels; sets sorted by canonical JSON.
    def materialize(self, node: Any) -> Any:
        if isinstance(node, _Id):
            return self.labeler.labels[node.key]
        if isinstance(node, dict):
            return {name: self.materialize(value) for name, value in node.items()}
        if isinstance(node, list):
            return [self.materialize(value) for value in node]
        if isinstance(node, _Set):
            self.note("set", node.at, items=len(node.items))
            return sorted((self.materialize(v) for v in node.items), key=canonical_json)
        if isinstance(node, _IdMap):
            return {self.labeler.labels[e.ident.key]: self.materialize(e.value) for e in node.entries}
        return node


def canonicalize(instance: Any, schema: Schema, ctx: Context = Context(),
                 labeler: Optional[Labeler] = None) -> Result:
    """Validates `instance` and returns its canonical form. Raises SnapshotInvalid or OracleError."""
    errors, annotations = schema.validate(instance)
    if errors:
        raise SnapshotInvalid(errors)
    if "x-oracle-volatile" in annotations.get((), {}):
        raise OracleError("/: x-oracle-volatile marks the whole snapshot")
    work = _Canonicalizer(annotations, ctx, labeler or Labeler())
    tree = work.lift(instance, ())
    work.label(tree, work.refine(tree))
    for key, sites in sorted(work.id_sites.items(), key=lambda kv: kv[1][0]):
        work.note("id", (), kind=key[0], label=work.labeler.labels[key], sites=sites)
    value = work.materialize(tree)
    if _node_count(value) + work.dropped_nodes != _node_count(instance):
        raise OracleError("internal: a rule other than volatile changed the number of values")
    text = canonical_json(value)
    return Result(value, text, hashlib.sha256(text.encode("utf-8")).hexdigest(), work.explain)


# ---------------------------------------------------------------------------------------------------------
# CLI


def _read_documents(name: str) -> List[Tuple[str, Any]]:
    text = sys.stdin.read() if name == "-" else Path(name).read_text(encoding="utf-8")
    if name.endswith(".jsonl"):
        return [(f"{name}:{n}", parse_json(line)) for n, line in enumerate(text.splitlines(), 1) if line.strip()]
    return [(name, parse_json(text))]


def _cli_validate(schema: Schema, files: Sequence[str], out: Any) -> int:
    status = 0
    for name in files:
        for label, doc in _read_documents(name):
            errors, _ = schema.validate(doc)
            if errors:
                status = 1
                out.write(f"FAIL {label}\n" + "".join(f"  {e}\n" for e in errors))
            else:
                out.write(f"ok {label}\n")
    return status


def _cli_normalize(schema: Schema, args: argparse.Namespace, out: Any, err: Any) -> int:
    ctx = Context(tuple(args.root), tuple(args.home), tuple(args.web))
    for name in args.files or ["-"]:
        labeler = Labeler()  # one per file: the snapshots of a .jsonl case share labels
        for label, doc in _read_documents(name):
            result = canonicalize(doc, schema, ctx, labeler)
            if args.explain:
                for event in result.explain:
                    err.write(canonical_json({"input": label, **event}) + "\n")
            out.write((result.sha256 if args.sha256 else result.text) + "\n")
    return 0


def main(argv: Optional[Sequence[str]] = None, out: Any = None, err: Any = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*", help="snapshot JSON or .jsonl files; '-' is stdin")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--root", action="append", default=[], help="state root, rewritten to $ROOT")
    parser.add_argument("--home", action="append", default=[], help="home directory, rewritten to $HOME")
    parser.add_argument("--web", action="append", default=[], help="loopback origin, rewritten to $WEB")
    parser.add_argument("--explain", action="store_true", help="one JSON line per applied rule on stderr")
    parser.add_argument("--sha256", action="store_true", help="print the sha256 of the canonical JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--validate", action="store_true", help="validate files against the schema")
    mode.add_argument("--lint-schema", action="store_true", help="lint the schema only")
    mode.add_argument("--list-rules", action="store_true", help="print every rule with its reason")
    mode.add_argument("--selftest", action="store_true", help="run the property cases")
    parser.add_argument("--require-source", action="store_true",
                        help="with --lint-schema: every field names its source method (x-oracle-source)")
    parser.add_argument("--seed", type=int, default=13, help="selftest seed")
    args = parser.parse_args(argv)
    try:
        if args.list_rules:
            for rule, reason in RULES.items():
                out.write(f"{rule}\t{TASK}\t{reason}\n")
            return 0
        if args.selftest:
            return selftest(args.seed, out)
        schema = Schema.load(args.schema, require_source=args.require_source)
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
# Selftest: 30 property cases (deterministic for a seed)

SELFTEST_SCHEMA: Dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["windows", "panes"],
    "x-oracle-source": "selftest",
    "properties": {
        "meta": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "pid": {"type": "integer", "x-oracle-volatile": "process id differs per launch"},
                "startedAt": {"type": "number", "x-oracle-volatile": "wall clock at launch"},
                "build": {"type": "string"},
            },
        },
        "windows": {"type": "array", "items": {"$ref": "#/$defs/window"}},
        "panes": {
            "type": "object",
            "x-oracle-key-id-kind": "pane",
            "additionalProperties": {"$ref": "#/$defs/pane"},
        },
        "tags": {"type": "array", "x-oracle-order": "set", "items": {"type": "string"}},
        "counters": {"type": "object", "additionalProperties": {"type": "integer", "minimum": 0}},
    },
    "$defs": {
        "window": {
            "type": "object",
            "additionalProperties": False,
            "required": ["id", "workspaces"],
            "properties": {
                "id": {"type": "string", "x-oracle-id-kind": "window"},
                "frame": {"type": "array", "prefixItems": [{"$ref": "#/$defs/fraction"}] * 4,
                          "minItems": 4, "maxItems": 4},
                "focusedWorkspace": {"type": ["string", "null"], "x-oracle-id-kind": "workspace"},
                "lastActiveAt": {"type": "number", "x-oracle-volatile": "wall clock of the last key event"},
                "workspaces": {"type": "array", "x-oracle-order": "set", "items": {"$ref": "#/$defs/workspace"}},
            },
        },
        "fraction": {"type": "number", "minimum": 0, "maximum": 1, "x-oracle-precision": 0.01},
        "workspace": {
            "type": "object",
            "additionalProperties": False,
            "required": ["id", "panes"],
            "properties": {
                "id": {"type": "string", "x-oracle-id-kind": "workspace"},
                "title": {"type": "string"},
                "cwd": {"type": "string"},
                "pinned": {"type": "boolean"},
                "panes": {"type": "array", "items": {"type": "string", "x-oracle-id-kind": "pane"}},
            },
        },
        "pane": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "workspace": {"type": "string", "x-oracle-id-kind": "workspace"},
                "title": {"type": "string"},
                "ratio": {"type": "number"},
                "size": {"type": "array", "items": {"type": "integer"}},
            },
        },
    },
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


def _names(model: _Model, rng: random.Random, reverse: bool = False) -> Dict[Tuple[str, int], str]:
    tokens = model.tokens()
    raw = sorted(f"{rng.getrandbits(128):032x}" for _ in tokens)
    if reverse:
        raw.reverse()
    else:
        rng.shuffle(raw)
    return dict(zip(tokens, raw))


def selftest(seed: int, out: Any) -> int:
    schema = Schema(SELFTEST_SCHEMA, "<selftest schema>", require_source=True)
    env_a = ("/tmp/o/aaaaaa/bbbbbb", "/home/u", "http://127.0.0.1:4321")
    env_b = ("/tmp/o/cccccc/dddddd", "/Users/v", "http://127.0.0.1:51000")
    ctx_a = Context((env_a[0],), (env_a[1],), (env_a[2],))
    ctx_b = Context((env_b[0],), (env_b[1],), (env_b[2],))
    rounds = 25

    def norm(doc: Any, ctx: Context = ctx_a, labeler: Optional[Labeler] = None, using: Schema = schema) -> Result:
        return canonicalize(doc, using, ctx, labeler)

    def models(salt: int) -> Iterable[Tuple[random.Random, _Model]]:
        for i in range(rounds):
            rng = random.Random(f"{seed}:{salt}:{i}")
            yield rng, _Model(rng)

    def refused(fn: Any, needle: str) -> None:
        try:
            fn()
        except OracleError as error:
            assert needle in str(error), f"refusal {error!s:.200} lacks {needle!r}"
            return
        raise AssertionError(f"expected a refusal mentioning {needle!r}")

    def schema_of(extra: Dict[str, Any]) -> Schema:
        return Schema({"type": "object", **extra})

    def errors_of(node: Dict[str, Any], doc: Any) -> List[str]:
        return Schema(node).validate(doc)[0]

    cases: List[Tuple[str, Any]] = []

    def case(fn: Any) -> Any:
        cases.append((fn.__name__, fn))
        return fn

    @case
    def key_order_invariance() -> None:
        for rng, m in models(1):
            names = _names(m, rng)
            assert norm(m.render(names)).sha256 == norm(m.render(names, shuffle=rng)).sha256

    @case
    def id_rename_invariance() -> None:
        for rng, m in models(2):
            assert norm(m.render(_names(m, rng))).text == norm(m.render(_names(m, rng))).text

    @case
    def id_rename_reversed_raw_order() -> None:
        for rng, m in models(3):
            a = norm(m.render(_names(m, rng, reverse=False)))
            b = norm(m.render(_names(m, rng, reverse=True)))
            assert a.text == b.text, "labels depend on the raw sort order of ids"

    @case
    def set_and_map_order_invariance() -> None:
        for rng, m in models(4):
            names = _names(m, rng)
            texts = {norm(m.render(names, shuffle=random.Random(k))).text for k in range(4)}
            assert len(texts) == 1, "set or id-map order leaks into the output"

    @case
    def all_nondeterminism_combined() -> None:
        for rng, m in models(5):
            a = norm(m.render(_names(m, rng), shuffle=rng, env=env_a, clock=10.0), ctx_a)
            b = norm(m.render(_names(m, rng), shuffle=rng, env=env_b, clock=99.5), ctx_b)
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
        drops = {e["pointer"]: e["reason"] for e in result.explain if e["rule"] == "volatile"}
        assert drops == {"/meta/pid": "process id differs per launch", "/meta/startedAt": "wall clock at launch"}
        assert all(e["task"] == TASK for e in result.explain)

    @case
    def unmarked_fields_never_dropped() -> None:
        for rng, m in models(8):
            doc = m.render(_names(m, rng), shuffle=rng)
            marked = sum(_node_count(doc["meta"][k]) for k in ("pid", "startedAt"))
            marked += sum(1 for w in doc["windows"] if "lastActiveAt" in w)
            result = norm(doc)
            assert _node_count(result.value) == _node_count(doc) - marked
            assert set(result.value) == set(doc) and set(result.value["meta"]) == {"build"}
            assert set(result.value["counters"]) == set(doc["counters"])

    @case
    def volatile_needs_reason() -> None:
        for bad in (True, "", "  "):
            refused(lambda: schema_of({"properties": {"t": {"x-oracle-volatile": bad}}}), "needs a reason")

    @case
    def volatile_on_array_item_refused() -> None:
        s = schema_of({"properties": {"l": {"type": "array", "items": {"x-oracle-volatile": "clock"}}}})
        refused(lambda: canonicalize({"l": [1]}, s), "array item")

    @case
    def annotations_only_from_passing_branches() -> None:
        s = schema_of({"properties": {"t": {"anyOf": [
            {"type": "string", "x-oracle-volatile": "string form is a timestamp"},
            {"type": "integer"},
        ]}}})
        assert canonicalize({"t": 5}, s).value == {"t": 5}
        assert canonicalize({"t": "now"}, s).value == {}
        s2 = schema_of({"properties": {"t": {"oneOf": [
            {"type": "string", "x-oracle-id-kind": "tab"}, {"type": "integer"}]}}})
        assert canonicalize({"t": 7}, s2).value == {"t": 7}
        assert canonicalize({"t": "x"}, s2).value == {"t": "tab#1"}

    @case
    def id_relations_preserved() -> None:
        for rng, m in models(12):
            v = norm(m.render(_names(m, rng), shuffle=rng)).value
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
            v = norm(m.render(_names(m, rng))).value
            ws = [s["id"] for w in v["windows"] for s in w["workspaces"]]
            assert len(set(ws)) == len(ws) == sum(len(w["workspaces"]) for w in m.windows)
            assert len(v["panes"]) == len(m.panes)
            assert sorted(v["panes"]) == sorted(f"pane#{n}" for n in range(1, len(m.panes) + 1))

    @case
    def no_raw_id_survives() -> None:
        for rng, m in models(15):
            names = _names(m, rng)
            text = norm(m.render(names, shuffle=rng)).text
            assert not any(raw in text for raw in names.values())

    @case
    def shared_labeler_keeps_labels_across_checkpoints() -> None:
        first = {"windows": [{"id": "W1", "workspaces": [{"id": "S1", "panes": ["P1"]}]}],
                 "panes": {"P1": {"workspace": "S1"}}}
        second = {"windows": [{"id": "W1", "workspaces": [
            {"id": "S0", "panes": ["P0"]}, {"id": "S1", "panes": ["P1"]}]}],
            "panes": {"P0": {"workspace": "S0"}, "P1": {"workspace": "S1"}}}
        labeler = Labeler()
        norm(first, labeler=labeler)
        v = norm(second, labeler=labeler).value
        spaces = {tuple(s["panes"]): s["id"] for s in v["windows"][0]["workspaces"]}
        assert spaces == {("pane#1",): "workspace#1", ("pane#2",): "workspace#2"}, spaces

    @case
    def root_rewrite_respects_boundaries() -> None:
        r = _Rewriter(Context(root=("/tmp/o/ab",)))
        assert r.apply("/tmp/o/ab/x")[0] == "$ROOT/x"
        assert r.apply("/tmp/o/abc/x")[0] == "/tmp/o/abc/x"
        assert r.apply("file:///tmp/o/ab/x")[0] == "file://$ROOT/x"
        assert r.apply("cd /tmp/o/ab && ls")[0] == "cd $ROOT && ls"

    @case
    def longest_prefix_wins() -> None:
        r = _Rewriter(Context(root=("/home/u/.cache/o/1",), home=("/home/u/",)))
        assert r.apply("/home/u/.cache/o/1/s.sock")[0] == "$ROOT/s.sock"
        assert r.apply("/home/u/src")[0] == "$HOME/src"
        refused(lambda: _Rewriter(Context(root=("/a",), home=("/a",))), "both")

    @case
    def web_origin_rewrite_respects_port() -> None:
        r = _Rewriter(Context(web=("http://127.0.0.1:4321",)))
        assert r.apply("http://127.0.0.1:4321/page?q=1")[0] == "$WEB/page?q=1"
        assert r.apply("http://127.0.0.1:43210/page")[0] == "http://127.0.0.1:43210/page"

    @case
    def rewritten_member_collision_refused() -> None:
        s = schema_of({"additionalProperties": {"type": "integer"}})
        refused(lambda: canonicalize({"/home/u/a": 1, "$HOME/a": 2}, s, Context(home=("/home/u",))),
                "both become")

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

    @case
    def canonicalization_is_idempotent() -> None:
        loose = Schema(json.loads(json.dumps(SELFTEST_SCHEMA).replace('"minimum": 0, "maximum": 1, ', "")))
        for rng, m in models(23):
            once = canonicalize(m.render(_names(m, rng), shuffle=rng), loose, ctx_a)
            twice = canonicalize(once.value, loose, ctx_a)
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
    def validator_refs_and_unknown_keywords() -> None:
        s = Schema({"$defs": {"n": {"type": "integer"}}, "items": {"$ref": "#/$defs/n"}})
        assert s.validate([1, "x"])[0] == ["/1: expected integer, got string"]
        refused(lambda: Schema({"$ref": "#/$defs/missing"}), "does not resolve")
        refused(lambda: Schema({"$ref": "other.json#/a"}), "only local refs")
        refused(lambda: Schema({"unevaluatedProperties": False}), "unknown keyword")
        refused(lambda: Schema({"properties": {"a": {"x-oracle-volatil": "clock"}}}), "misspelled")
        refused(lambda: Schema({"items": [{"type": "string"}]}), "prefixItems")
        refused(lambda: Schema({"x-oracle-order": "bag"}), "x-oracle-order")
        refused(lambda: Schema({"properties": {"a": {"type": "string"}}}, require_source=True), "x-oracle-source")

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
    def refusals_before_normalizing() -> None:
        refused(lambda: parse_json('{"a": NaN}'), "not JSON")
        refused(lambda: parse_json('{"a": Infinity}'), "not JSON")
        refused(lambda: parse_json('{"a": 1, "a": 2}'), "duplicate object key")
        refused(lambda: norm({"windows": "nope", "panes": {}}), "does not match the schema")
        conflict = schema_of({"properties": {"a": {"allOf": [{"x-oracle-id-kind": "tab"},
                                                             {"x-oracle-id-kind": "pane"}]}}})
        refused(lambda: canonicalize({"a": "x"}, conflict), "disagree")
        stream = io.StringIO()
        assert main(["--list-rules"], out=stream) == 0 and len(stream.getvalue().splitlines()) == len(RULES)

    failures = 0
    for number, (name, fn) in enumerate(cases, 1):
        try:
            fn()
            out.write(f"ok {number} {name}\n")
        except Exception as error:  # noqa: BLE001 - a selftest reports every failure, then exits non-zero
            failures += 1
            out.write(f"FAIL {number} {name}: {type(error).__name__}: {error}\n")
    out.write(f"{len(cases) - failures}/{len(cases)} property cases passed (seed {seed})\n")
    if len(cases) != 30:
        out.write(f"expected 30 property cases, found {len(cases)}\n")
        return 1
    return 1 if failures else 0


PINNED_SHA256 = "c8af40a1466c97a078a3aa7f52ec9bec3317e977b35e2a06b135aedc01a0b9ee"

if __name__ == "__main__":
    sys.exit(main())
