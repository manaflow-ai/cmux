#!/usr/bin/env python3
"""Check the oracle snapshot schema against its own rules and against the wire.

Stdlib only, safe under `python3 -I`. It checks four things and prints one line per problem:

1. lint: the annotation rules of schemas/oracle/README.md, including that each `x-oracle-source.path` is its
   parent's path plus `/<key>` (`/*` for array items) unless the field has a `derive`;
2. validate: each example snapshot passes the README's validator subset, names every facet of `meta.facets`,
   and every id-shaped string in a typed field has an `x-oracle-id-kind` that matches it;
3. wire shape: `daemon.session` against `ResourceSnapshot` and `daemon.settings` against the
   `settings.snapshot` result in cmux-tui/spec/resource-operations-v2.json;
4. wire captures: every `schemas/oracle/fixtures/wire/*.json` (a real daemon reply) passes the schema after
   the capture rules (`derive: sha256`) are applied.

Task p15-oracle-013 moves the validator into normalize.py; this check then imports it.

Usage: python3 -I scripts/cmux-next/oracle/check_snapshot_schema.py [--repo DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HASH = "^sha256:[0-9a-f]{64}$"
DECIMAL = "^(0|[1-9][0-9]*)$"
TASK = re.compile(r"^p[0-9]{2}-[a-z]+-[0-9]{3}$")
KEYWORDS = {
    "$schema", "$id", "title", "description", "definitions",
    "type", "enum", "const", "pattern", "minimum", "maxItems", "required", "properties",
    "additionalProperties", "items", "oneOf", "$ref",
}
ANNOTATIONS = {
    "x-oracle-source", "x-oracle-order", "x-oracle-id-kind", "x-oracle-id-patterns", "x-oracle-id-unpatterned",
    "x-oracle-open-keys", "x-oracle-volatile", "x-oracle-precision", "x-oracle-precision-default",
    "x-oracle-rewrite", "x-oracle-time", "x-oracle-counter", "x-oracle-decimal",
}
OPEN_RULES = {"x-oracle-time", "x-oracle-volatile"}
# resource_scopes name -> schema id kind
RESOURCE_KIND = {
    "machine": "machine", "session": "session", "workspace": "workspace", "screen": "screen", "pane": "pane",
    "tab": "tab", "terminal": "terminal", "browser": "browser", "client": "client", "split": "split",
    "notification": "notification", "agent": "agent", "frontend_projection": "frontendProjection",
    "sidebar_view": "sidebarView", "pairing_request": "pairingRequest", "stream": "stream",
}


def types_of(node: dict) -> list[str]:
    t = node.get("type")
    return [t] if isinstance(t, str) else list(t or [])


def child_ptr(ptr: str, key: str) -> str:
    return ("" if ptr == "/" else ptr) + "/" + key


# ---------------------------------------------------------------- 1. lint


class Lint:
    def __init__(self, schema: dict):
        self.schema = schema
        self.problems: list[str] = []
        self.patterns = schema.get("x-oracle-id-patterns", {})
        self.unpatterned = schema.get("x-oracle-id-unpatterned", {})

    def say(self, loc: str, text: str) -> None:
        self.problems.append(f"lint {loc or '/'}: {text}")

    def run(self) -> list[str]:
        for kind, regex in self.patterns.items():
            try:
                re.compile(regex)
            except re.error as error:
                self.say("#/x-oracle-id-patterns", f"{kind}: {error}")
        for kind, reason in self.unpatterned.items():
            if kind in self.patterns or not reason:
                self.say("#/x-oracle-id-unpatterned", f"{kind} needs a reason and no pattern")
        for index, rule in enumerate(self.schema.get("x-oracle-open-keys", [])):
            loc = f"#/x-oracle-open-keys/{index}"
            try:
                re.compile(rule.get("key", ""))
            except re.error as error:
                self.say(loc, f"key regex: {error}")
            rules = [k for k in rule if k != "key"]
            if len(rules) != 1 or rules[0] not in OPEN_RULES:
                self.say(loc, f"one of {sorted(OPEN_RULES)} per entry, got {rules}")
            self.check_volatile(loc, rule)
        self.walk(self.schema, "#", None, None, top=True)
        for name, definition in self.schema.get("definitions", {}).items():
            self.walk(definition, f"#/definitions/{name}", None, None)
        return self.problems

    def check_volatile(self, loc: str, node: dict) -> None:
        volatile = node.get("x-oracle-volatile")
        if volatile is not None and (not volatile.get("reason") or not TASK.match(str(volatile.get("task", "")))):
            self.say(loc, "x-oracle-volatile needs a reason and a task")

    def walk(self, node: dict, loc: str, ptr: str | None, method: str | None, key: str | None = None,
             top: bool = False) -> None:
        if not isinstance(node, dict):
            self.say(loc, "a schema is an object")
            return
        for k in node:
            if k not in KEYWORDS and k not in ANNOTATIONS:
                self.say(loc, f"keyword {k} is outside the validator subset")
        source = node.get("x-oracle-source")
        if key is not None and not source:
            self.say(loc, "a property needs x-oracle-source")
        if source:
            if not source.get("method") or not source.get("path"):
                self.say(loc, "x-oracle-source needs method and path")
            elif key is not None and ptr is not None and source["method"] == method and "derive" not in source:
                expected = child_ptr(ptr, key)
                if source["path"] != expected:
                    self.say(loc, f"path {source['path']} is not its location {expected} (add a derive if computed)")
            ptr, method = source.get("path"), source.get("method")
        elif key is not None and ptr is not None:
            ptr = child_ptr(ptr, key)
        self.check_annotations(node, loc, source or {})
        if top:
            ptr, method = None, None
        for k, sub in node.get("properties", {}).items():
            self.walk(sub, f"{loc}/properties/{k}", ptr, method, key=k)
        items = node.get("items")
        if isinstance(items, dict):
            self.walk(items, f"{loc}/items", None if ptr is None else child_ptr(ptr, "*"), method)
        extra = node.get("additionalProperties")
        if isinstance(extra, dict):
            self.walk(extra, f"{loc}/additionalProperties", None if ptr is None else child_ptr(ptr, "*"), method)
        for index, branch in enumerate(node.get("oneOf", [])):
            self.walk(branch, f"{loc}/oneOf/{index}", ptr, method)

    def check_annotations(self, node: dict, loc: str, source: dict) -> None:
        types = types_of(node)
        if "array" in types and node.get("x-oracle-order") not in ("sequence", "set"):
            self.say(loc, "an array needs x-oracle-order sequence or set")
        if "number" in types and not (isinstance(node.get("x-oracle-precision"), (int, float))
                                      and node["x-oracle-precision"] > 0):
            self.say(loc, "a number needs x-oracle-precision")
        self.check_volatile(loc, node)
        kind = node.get("x-oracle-id-kind")
        if kind is not None:
            kinds = kind if isinstance(kind, list) else [kind]
            if not kinds:
                self.say(loc, "x-oracle-id-kind list is empty")
            for k in kinds:
                if k not in self.patterns and (isinstance(kind, list) or k not in self.unpatterned):
                    self.say(loc, f"id kind {k} has no x-oracle-id-patterns entry"
                             + ("" if isinstance(kind, list) else " and is not in x-oracle-id-unpatterned"))
        if node.get("x-oracle-decimal") and not ("string" in types and node.get("pattern") == DECIMAL):
            self.say(loc, f"x-oracle-decimal needs type string and pattern {DECIMAL}")
        time = node.get("x-oracle-time")
        if time is not None:
            if time.get("unit") not in ("ns", "ms", "s") or time.get("epoch") != "fixture":
                self.say(loc, "x-oracle-time needs unit ns|ms|s and epoch fixture")
            if not ({"integer", "number"} & set(types) or node.get("x-oracle-decimal")):
                self.say(loc, "x-oracle-time applies to a number or a wire decimal")
            if "x-oracle-volatile" in node:
                self.say(loc, "a field is either volatile or a time")
        if node.get("x-oracle-counter") not in (None, "monotonic"):
            self.say(loc, "x-oracle-counter is monotonic")
        if node.get("x-oracle-rewrite") not in (None, "path", "url"):
            self.say(loc, "x-oracle-rewrite is path or url")
        if str(source.get("derive", "")).startswith("sha256") and node.get("pattern") != HASH:
            self.say(loc, f"a sha256 derive needs pattern {HASH}")
        name = loc.rsplit("/", 1)[-1]
        parent = loc.rsplit("/", 3)
        id_named = name == "id" or name.endswith("_id") or (
            name == "items" and len(parent) > 2 and parent[-2].endswith("_ids"))
        if (id_named and "string" in types and "derive" not in source and kind is None
                and "x-oracle-volatile" not in node):
            self.say(loc, "an id field needs x-oracle-id-kind (or x-oracle-volatile with a reason)")


# ---------------------------------------------------------------- 2. validate


class Validator:
    """The README's keyword subset; jsonschema.Draft7Validator gives the same verdicts."""

    def __init__(self, root: dict):
        self.root = root

    def errors(self, node: dict, value, ptr: str = "") -> list[str]:
        out: list[str] = []
        if "$ref" in node:
            ref = node["$ref"]
            if not ref.startswith("#/definitions/"):
                return [f"{ptr or '/'}: unsupported $ref {ref}"]
            return self.errors(self.root["definitions"][ref.split("/")[-1]], value, ptr)
        types = types_of(node)
        if types and not any(self.is_type(value, t) for t in types):
            return [f"{ptr or '/'}: {json.dumps(value)[:60]} is not {'/'.join(types)}"]
        if "const" in node and value != node["const"]:
            out.append(f"{ptr or '/'}: is not {node['const']!r}")
        if "enum" in node and value not in node["enum"]:
            out.append(f"{ptr or '/'}: {value!r} is not one of {node['enum']}")
        if isinstance(value, str) and "pattern" in node and not re.search(node["pattern"], value):
            out.append(f"{ptr or '/'}: {value[:60]!r} does not match {node['pattern']}")
        if self.is_type(value, "number") and "minimum" in node and value < node["minimum"]:
            out.append(f"{ptr or '/'}: {value} < {node['minimum']}")
        if isinstance(value, list):
            if "maxItems" in node and len(value) > node["maxItems"]:
                out.append(f"{ptr or '/'}: more than {node['maxItems']} items")
            if isinstance(node.get("items"), dict):
                for index, item in enumerate(value):
                    out += self.errors(node["items"], item, f"{ptr}/{index}")
        if isinstance(value, dict):
            props = node.get("properties", {})
            for key in node.get("required", []):
                if key not in value:
                    out.append(f"{ptr or '/'}: missing {key}")
            extra = node.get("additionalProperties", True)
            for key, item in value.items():
                if key in props:
                    out += self.errors(props[key], item, f"{ptr}/{key}")
                elif extra is False:
                    out.append(f"{ptr or '/'}: unknown key {key}")
                elif isinstance(extra, dict):
                    out += self.errors(extra, item, f"{ptr}/{key}")
        if "oneOf" in node:
            results = [self.errors(branch, value, ptr) for branch in node["oneOf"]]
            passing = [r for r in results if not r]
            if len(passing) != 1:
                best = min(results, key=len)
                out.append(f"{ptr or '/'}: matches {len(passing)} oneOf branches, not 1"
                           + (f" (closest: {'; '.join(best[:3])})" if not passing else ""))
        return out

    @staticmethod
    def is_type(value, name: str) -> bool:
        if isinstance(value, bool):
            return name == "boolean"
        if name == "integer":
            return isinstance(value, int) or (isinstance(value, float) and value.is_integer())
        if name == "number":
            return isinstance(value, (int, float))
        return isinstance(value, {"string": str, "object": dict, "array": list, "null": type(None)}.get(name, ()))


def typed_id_problems(schema: dict, node: dict, value, ptr: str, label: str) -> list[str]:
    """Every id-shaped string in a typed field has an id kind, and the kind matches the value."""
    patterns = {k: re.compile(v) for k, v in schema.get("x-oracle-id-patterns", {}).items()}
    out: list[str] = []

    def kinds_of(text: str) -> list[str]:
        return [k for k, p in patterns.items() if p.match(text)]

    def walk(n: dict, v, p: str) -> None:
        if "$ref" in n:
            n = schema["definitions"][n["$ref"].split("/")[-1]]
        if "oneOf" in n:
            for branch in n["oneOf"]:
                if not Validator(schema).errors(branch, v, p):
                    walk(branch, v, p)
                    return
            return
        if isinstance(v, str):
            kind = n.get("x-oracle-id-kind")
            found = kinds_of(v)
            if kind is None:
                if found and "x-oracle-volatile" not in n and "derive" not in n.get("x-oracle-source", {}):
                    out.append(f"{label} {p}: {v} is a {found[0]} id in a field without x-oracle-id-kind")
            else:
                allowed = kind if isinstance(kind, list) else [kind]
                checked = [k for k in allowed if k in patterns]
                if checked and not any(patterns[k].match(v) for k in checked):
                    out.append(f"{label} {p}: {v} does not match id kind {kind}")
        elif isinstance(v, list) and isinstance(n.get("items"), dict):
            for index, item in enumerate(v):
                walk(n["items"], item, f"{p}/{index}")
        elif isinstance(v, dict) and "properties" in n:
            for key, item in v.items():
                if key in n["properties"]:
                    walk(n["properties"][key], item, f"{p}/{key}")

    walk(node, value, ptr)
    return out


def check_snapshot(schema: dict, snapshot: dict, label: str) -> list[str]:
    out = [f"{label} {e}" for e in Validator(schema).errors(schema, snapshot)]
    asked = snapshot.get("meta", {}).get("facets", [])
    present = set(snapshot.get("facets", {}))
    for name in asked:
        if name not in present:
            out.append(f"{label} /facets: meta.facets asks for {name} and the snapshot has none")
    for name in sorted(present - set(asked)):
        out.append(f"{label} /facets/{name}: not in meta.facets")
    out += typed_id_problems(schema, schema, snapshot, "", label)
    return out


# ---------------------------------------------------------------- 3. wire shape


class WireShape:
    def __init__(self, schema: dict, spec: dict):
        self.schema = schema
        self.spec = spec
        self.problems: list[str] = []

    def say(self, loc: str, text: str) -> None:
        self.problems.append(f"wire {loc}: {text}")

    def resolve(self, wire: dict) -> dict:
        while wire.get("kind") == "ref":
            wire = self.spec["types"][wire["name"]]
        return wire

    def compare(self, node: dict, wire: dict, loc: str) -> None:
        wire = self.resolve(wire)
        types = set(types_of(node))
        derived = "derive" in node.get("x-oracle-source", {})
        kind = wire["kind"]
        if kind == "nullable":
            if "null" not in types:
                self.say(loc, "the wire value is nullable; add null to type")
            self.compare(node, wire["value"], loc)
            return
        types.discard("null")
        if derived:
            if node.get("pattern") != HASH:
                self.say(loc, "a derived field must be a sha256 hash")
            return
        if kind == "primitive" and wire["name"] == "json":
            if "properties" in node:
                self.say(loc, "the wire value is any JSON; the schema cannot fix its fields")
            return
        if kind == "object":
            if types != {"object"}:
                self.say(loc, f"the wire value is an object, schema type is {sorted(types)}")
                return
            if "properties" not in node:
                self.say(loc, "the wire value has fixed fields; list them so their decimals and ids get rules")
                return
            self.compare_fields(node, wire, loc)
        elif kind == "map":
            if types != {"object"} or node.get("additionalProperties") is False:
                self.say(loc, "the wire value is an open map; the schema must be an open object")
        elif kind == "array":
            if types != {"array"}:
                self.say(loc, f"the wire value is an array, schema type is {sorted(types)}")
            elif isinstance(node.get("items"), dict):
                self.compare(node["items"], wire["items"], f"{loc}/*")
        elif kind == "enum":
            if types != {"string"}:
                self.say(loc, "the wire value is an enum string")
            elif "enum" in node and sorted(node["enum"]) != sorted(wire["values"]):
                self.say(loc, f"enum {sorted(node['enum'])} is not the wire's {sorted(wire['values'])}")
        elif kind == "resource_id":
            self.compare_ids(node, [wire["resource"]], types, loc)
        elif kind == "union":
            variants = [self.resolve(v) for v in wire["variants"]]
            if all(v["kind"] == "resource_id" for v in variants):
                self.compare_ids(node, [v["resource"] for v in variants], types, loc)
            elif types != {"object"} or "properties" in node:
                self.say(loc, "a union of objects is an open object in the schema")
        elif kind == "primitive":
            name = wire["name"]
            if name == "decimal":
                if types != {"string"} or not node.get("x-oracle-decimal"):
                    self.say(loc, "the wire sends decimal as a string: type string with x-oracle-decimal")
            elif name == "string":
                if types != {"string"}:
                    self.say(loc, f"the wire value is a string, schema type is {sorted(types)}")
            elif name == "boolean":
                if types != {"boolean"}:
                    self.say(loc, f"the wire value is a boolean, schema type is {sorted(types)}")
            elif re.match(r"^u?int(8|16|32|64)$", name):
                if types != {"integer"}:
                    self.say(loc, f"the wire value is {name}, schema type is {sorted(types)}")
            elif name in ("float32", "float64", "number"):
                if types != {"number"}:
                    self.say(loc, f"the wire value is {name}, schema type is {sorted(types)}")
            else:
                self.say(loc, f"no rule for wire primitive {name}")
        else:
            self.say(loc, f"no rule for wire kind {kind}")

    def compare_ids(self, node: dict, resources: list[str], types: set, loc: str) -> None:
        if types != {"string"}:
            self.say(loc, "a resource id is a string")
            return
        want = sorted(RESOURCE_KIND.get(r, r) for r in resources)
        kind = node.get("x-oracle-id-kind")
        have = sorted(kind if isinstance(kind, list) else [kind]) if kind is not None else []
        if "x-oracle-volatile" not in node and have != want:
            self.say(loc, f"x-oracle-id-kind {kind} is not the wire's {want if len(want) > 1 else want[0]}")

    def compare_fields(self, node: dict, wire: dict, loc: str) -> None:
        props = node["properties"]
        required = set(node.get("required", []))
        for name, field in wire["fields"].items():
            if name not in props:
                self.say(f"{loc}/{name}", "on the wire, missing from the schema")
                continue
            if bool(field.get("required")) != (name in required):
                self.say(f"{loc}/{name}", f"wire required={bool(field.get('required'))}, schema differs")
            self.compare(props[name], field["type"], f"{loc}/{name}")
        for name in props:
            if name not in wire["fields"]:
                self.say(f"{loc}/{name}", "in the schema, not on the wire")

    def settings(self, node: dict) -> None:
        constraint = " ".join(self.spec["operations"]["settings.snapshot"]["params"].get("constraints", []))
        match = re.search(r"\{([a-z_, ]+)\}", constraint)
        if not match:
            self.say("settings.snapshot", "the spec no longer lists its result keys")
            return
        wire_keys = {k.strip() for k in match.group(1).split(",")}
        covered = {}
        for key, prop in node["properties"].items():
            top = prop.get("x-oracle-source", {}).get("path", "").split("/")[1:2]
            if not top or top[0] not in wire_keys:
                self.say(f"daemon.settings/{key}", f"source {prop.get('x-oracle-source')} is not a result key")
                continue
            if top[0] != key and "derive" not in prop["x-oracle-source"]:
                self.say(f"daemon.settings/{key}", "a renamed key needs a derive")
            covered[top[0]] = key
        for key in sorted(wire_keys - set(covered)):
            self.say(f"daemon.settings/{key}", "settings.snapshot sends it; the schema has no field for it")

    def run(self) -> list[str]:
        daemon = self.schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]
        self.compare(daemon["session"], {"kind": "ref", "name": "ResourceSnapshot"}, "daemon.session")
        self.settings(daemon["settings"])
        return self.problems


# ---------------------------------------------------------------- 4. wire captures


def sha256_of(value) -> str:
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True, separators=(",", ":"),
                                                           ensure_ascii=False)
    return "sha256:" + hashlib.sha256(text.encode()).hexdigest()


def capture(schema: dict, node: dict, wire):
    """The capture rules: a `derive: sha256` field holds the hash of the wire value at its source key."""
    if "$ref" in node:
        node = schema["definitions"][node["$ref"].split("/")[-1]]
    if isinstance(wire, list) and isinstance(node.get("items"), dict):
        return [capture(schema, node["items"], item) for item in wire]
    if not isinstance(wire, dict) or "properties" not in node:
        return wire
    out = {}
    taken = set()
    for key, prop in node["properties"].items():
        source = prop.get("x-oracle-source", {})
        wire_key = source.get("path", "").rsplit("/", 1)[-1] if "derive" in source else key
        if wire_key not in wire:
            continue
        taken.add(wire_key)
        if str(source.get("derive", "")).startswith("sha256"):
            out[key] = None if wire[wire_key] is None else sha256_of(wire[wire_key])
        else:
            out[key] = capture(schema, prop, wire[wire_key])
    for key, value in wire.items():
        if key not in taken:
            out[key] = value
    return out


def check_wire_capture(schema: dict, name: str, record: dict) -> list[str]:
    daemon = schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]
    target = {"session.snapshot": "session", "settings.snapshot": "settings"}.get(record.get("method"))
    label = f"capture {name}"
    if target is None:
        return [f"{label}: method {record.get('method')} has no daemon facet field"]
    value = capture(schema, daemon[target], record["result"])
    out = [f"{label} {e}" for e in Validator(schema).errors(daemon[target], value, f"/facets/daemon/{target}")]
    out += typed_id_problems(schema, daemon[target], value, f"/facets/daemon/{target}", label)
    return out


# ---------------------------------------------------------------- main


def check_all(schema: dict, spec: dict, examples: dict[str, dict], captures: dict[str, dict]) -> list[str]:
    problems = Lint(schema).run()
    for name, snapshot in examples.items():
        problems += check_snapshot(schema, snapshot, f"example {name}")
    problems += WireShape(schema, spec).run()
    for name, record in captures.items():
        problems += check_wire_capture(schema, name, record)
    return problems


def daemon_session(schema: dict) -> dict:
    return schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]["session"]["properties"]


def layout_column(examples: dict) -> dict:
    """The example's first strip column (a `column` layoutNode)."""
    screens = examples["snapshot-example.json"]["facets"]["layout"]["screens"]
    return next(s["root"] for s in screens if s["root"]["kind"] == "strip")["children"][0]


def mutations() -> list[tuple[str, object]]:
    """Each breaks one rule; the check must report it. Mutators take (schema, examples, captures)."""

    def copy_paste_path(schema, examples, captures):
        daemon_session(schema)["panes"]["items"]["properties"]["name"]["x-oracle-source"]["path"] = "/screens/*/name"

    def decimal_as_integer(schema, examples, captures):
        revision = daemon_session(schema)["session"]["properties"]["revision"]
        for key in ("pattern", "x-oracle-decimal"):
            revision.pop(key)
        revision["type"] = "integer"

    def wire_integer_revision(schema, examples, captures):
        record = captures["session.snapshot.json"]
        record["result"]["session"]["revision"] = int(record["result"]["session"]["revision"])

    def dropped_facet(schema, examples, captures):
        del examples["snapshot-example.json"]["facets"]["focus"]

    def id_without_kind(schema, examples, captures):
        del daemon_session(schema)["tabs"]["items"]["properties"]["content_id"]["x-oracle-id-kind"]

    def raw_private_text(schema, examples, captures):
        examples["snapshot-example.json"]["facets"]["daemon"]["session"]["notifications"][0]["body"] = "all green"

    def missing_wire_key(schema, examples, captures):
        settings = schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]["settings"]
        del settings["properties"]["domains"]
        settings["required"].remove("domains")

    def volatile_without_reason(schema, examples, captures):
        daemon_session(schema)["cursor"]["properties"]["revision"]["x-oracle-volatile"] = {"task": "p15-oracle-011"}

    def wrong_id_kind(schema, examples, captures):
        daemon_session(schema)["panes"]["items"]["properties"]["screen_id"]["x-oracle-id-kind"] = "workspace"

    def column_without_width(schema, examples, captures):
        del layout_column(examples)["width"]

    def width_on_a_split(schema, examples, captures):
        examples["snapshot-example.json"]["facets"]["layout"]["screens"][0]["root"]["width"] = 0.5

    def height_on_a_column(schema, examples, captures):
        layout_column(examples)["height"] = 0.5

    return [(f.__name__, f) for f in (
        copy_paste_path, decimal_as_integer, wire_integer_revision, dropped_facet, id_without_kind,
        raw_private_text, missing_wire_key, volatile_without_reason, wrong_id_kind,
        column_without_width, width_on_a_split, height_on_a_column,
    )]


def load(repo: Path) -> tuple[dict, dict, dict[str, dict], dict[str, dict]]:
    oracle = repo / "schemas" / "oracle"
    schema = json.loads((oracle / "snapshot-v1.schema.json").read_text())
    spec = json.loads((repo / "cmux-tui" / "spec" / "resource-operations-v2.json").read_text())
    examples = {p.name: json.loads(p.read_text()) for p in sorted((oracle / "fixtures").glob("snapshot-*.json"))}
    captures = {p.name: json.loads(p.read_text()) for p in sorted((oracle / "fixtures" / "wire").glob("*.json"))}
    return schema, spec, examples, captures


def selftest(repo: Path) -> int:
    failed = 0
    for name, mutate in mutations():
        schema, spec, examples, captures = load(repo)
        mutate(schema, examples, captures)
        problems = check_all(schema, spec, examples, captures)
        first = f" ({problems[0]})" if problems else ""
        print(f"{'ok' if problems else 'MISSED'} {name}: {len(problems)} problems{first}")
        failed += not problems
    print(f"check_snapshot_schema --selftest: {len(mutations()) - failed}/{len(mutations())} mutations caught",
          file=sys.stderr)
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--selftest", action="store_true", help="check that each seeded schema defect is reported")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest(args.repo)
    schema, spec, examples, captures = load(args.repo)
    problems = check_all(schema, spec, examples, captures)
    for line in problems:
        print(line)
    print(f"check_snapshot_schema: {len(examples)} examples, {len(captures)} wire captures, {len(problems)} problems",
          file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
