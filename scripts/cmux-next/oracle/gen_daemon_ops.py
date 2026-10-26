#!/usr/bin/env python3
"""Generate the daemon-ops suite: a success case and a typed-error case per mutation of the catalog.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite daemon-ops) and task 060. Stdlib only,
Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite daemon-ops` runs it with `--out <corpus>/daemon-ops`.

Chrome reference (chromium/src): third_party/blink/web_tests/external/wpt/resources/idlharness.js makes one
test per member of an interface from its WebIDL types, so a new member is tested without a new hand-written
test; mojo/public/interfaces/bindings/tests/data/validation/ pairs each message vector with the typed error the
bindings must give (`.expected`: VALIDATION_ERROR_*). Here the types are cmux-tui/spec/resource-operations-v2.json:
for each operation with class `mutation`,

- `<op>-ok.json`: the standard fixture steps the operation needs, then the operation with its required fields
  made from their catalog types, its selectors pointing at fixture objects. Expect ok and a mutation_result.
- `<op>-error.json`: the same steps, with one field changed to break its catalog type (the first field, required
  ones first, that has a breakable type), or one unknown parameter when no field has one. Expect
  `validation.invalid`: the daemon checks every request against the same catalog before any handler runs
  (cmux-tui/crates/cmux-tui-core/src/resource_router/catalog_validation.rs), and `CatalogCheck` below is that
  check in Python, so the generator proves each success request passes it and each error request fails it.

The standard fixture is FIXTURE: named objects (a terminal workspace, a split, a browser tab, a tab group, ...),
each made by one catalog mutation and read from its result by a JSON pointer that the generator resolves in the
catalog's result type. A case has only the fixture steps its handles need, in FIXTURE order.

Cases are flat in the suite directory, as every suite: `oracle.py` and the expectation targets
(`suite/case[/step]`) name a case by one path segment. The families of tasks 061-070 tune their operations in
`<family>/_tuning.json` (oracle.py skips `_` files), which this generator reads, so regeneration keeps the tuning
and stays byte-stable. A tuning changes params and target, the error code, and adds `before` steps (a mutation
or a waitFor settle between the fixture and the call), `requires` capabilities (`chromium` for a daemon-rendered
browser, which needs a cmux-browser provider) and `untested` reasons. coverage.json lists every operation with its
family, cases, fixture steps, broken field, placeholders (fields with a fixed id, not a fixture object: the tuning
work), tuning and the capabilities of cases that need more than resource_api.

Usage:
  gen_daemon_ops.py --out DIR          write the cases and coverage.json into DIR
  gen_daemon_ops.py --out DIR --check  exit 1 when DIR differs from a fresh generation
  gen_daemon_ops.py --selftest         offline tests against the checked-in catalog
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CATALOG = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "daemon-ops"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SUITE = "daemon-ops"
GENERATOR = "scripts/cmux-next/oracle/gen_daemon_ops.py"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
COVERAGE = "coverage.json"
TUNING = "_tuning.json"

# Task 061-070 families: the first segment of an operation name picks its family directory. A new first
# segment is an error until it is given a family here.
FAMILIES: Dict[str, Tuple[str, ...]] = {
    "browser": ("browser",),
    "sidebar": ("sidebar", "sidebar_view", "sidebar_layout"),
    "session": ("session",),
    "workspace": ("workspace", "workspace_checklist", "workspace_group", "workspace_log", "workspace_progress",
                  "workspace_status"),
    "terminal": ("terminal",),
    "layout": ("pane", "column", "layout", "screen", "screen_group"),
    "tab": ("tab", "tab_group", "saved_tab_group", "closed"),
    "git": ("git", "project", "stash"),
    "chief": ("chief", "conversation", "room", "participant", "agent"),
    "misc": ("credential", "frontend_projection", "history", "keybindings", "notification", "pairing_request",
             "palette_usage", "settings", "window_record"),
}
FAMILY_OF = {prefix: family for family, prefixes in FAMILIES.items() for prefix in prefixes}

SCOPE = {"machine": "current", "session": "current"}
# catalog_validation.rs validate_resource_id: the id prefix of a resource kind.
ID_PREFIX = {"workspace": "ws", "terminal": "term", "frontend_projection": "projection", "pairing_request": "pairing"}
UNKNOWN_PARAMETER = "oracle_unknown"
ERROR_CODE = "validation.invalid"
# hermetic_env.py ROOT_TOKEN (p15-oracle-200): the case's state root. A path under it is local to the case.
ROOT_TOKEN = "$CASE_ROOT"


class GenError(Exception):
    """The catalog, the fixture or a tuning file cannot make the suite."""


# ------------------------------------------------------------------------------------------------ catalog


class Catalog:
    """resource-operations-v2.json: operations, named types and generics."""

    def __init__(self, data: Mapping[str, Any], text: str):
        self.data = data
        self.sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
        self.operations: Mapping[str, Any] = data["operations"]
        self.types: Mapping[str, Any] = data.get("types", {})
        self.generics: Mapping[str, Any] = data.get("generics", {})

    @classmethod
    def load(cls, path: Path = CATALOG) -> "Catalog":
        text = path.read_text(encoding="utf-8")
        return cls(json.loads(text), text)

    def mutations(self) -> List[str]:
        return sorted(name for name, op in self.operations.items() if op.get("class") == "mutation")

    def resolve(self, descriptor: Mapping[str, Any], bindings: Mapping[str, Any]) -> Tuple[Mapping[str, Any], Dict[str, Any]]:
        """Follows ref, apply and parameter until a structural kind; returns it with its generic bindings."""
        bindings = dict(bindings)
        for _ in range(64):
            kind = descriptor.get("kind")
            if kind == "ref":
                descriptor = self.types[descriptor["name"]]
            elif kind == "parameter":
                descriptor = bindings[descriptor["name"]]
            elif kind == "apply":
                generic = self.generics[descriptor["name"]]
                bindings.update(zip(generic["parameters"], descriptor["arguments"]))
                descriptor = generic["body"]
            else:
                return descriptor, bindings
        raise GenError(f"type reference loop at {descriptor!r:.120}")

    def type_at(self, descriptor: Mapping[str, Any], pointer: str, bindings: Optional[Mapping[str, Any]] = None
                ) -> Optional[Mapping[str, Any]]:
        """The catalog type at a JSON pointer of a value of `descriptor`; a union matches when one variant has it."""
        descriptor, bindings = self.resolve(descriptor, bindings or {})
        if pointer in ("", "#"):
            return descriptor
        head, _, rest = pointer.lstrip("/").partition("/")
        rest = "/" + rest if rest else ""
        kind = descriptor.get("kind")
        if kind == "nullable":
            return self.type_at(descriptor["value"], pointer, bindings)
        if kind == "union":
            for variant in descriptor["variants"]:
                found = self.type_at(variant, pointer, bindings)
                if found is not None:
                    return found
            return None
        if kind == "object":
            spec = descriptor.get("fields", {}).get(head)
            return None if spec is None else self.type_at(spec["type"], rest, bindings)
        if kind == "array" and head.isdigit():
            return self.type_at(descriptor["items"], rest, bindings)
        if kind == "map":
            return self.type_at(descriptor["values"], rest, bindings)
        return None


def resource_id(resource: str) -> str:
    """A well-formed id of a kind that names no object (validate_resource_id accepts it)."""
    return f"{ID_PREFIX.get(resource, resource)}_{'0' * 32}"


class CatalogCheck:
    """The daemon's request check in Python (catalog_validation.rs validate_catalog_params and
    validate_catalog_value, and resource.rs Selector::parse for selector strings). It returns the first
    refusal, or None. validate_operation_constraints (hand-written per operation in Rust) is not ported."""

    def __init__(self, catalog: Catalog):
        self.catalog = catalog

    def params(self, operation: str, params: Mapping[str, Any]) -> Optional[str]:
        descriptor = self.catalog.operations[operation]["params"]
        selectors, fields = descriptor["selectors"], descriptor["fields"]
        if descriptor.get("extra") is False:
            unknown = sorted(key for key in params if key not in selectors and key not in fields)
            if unknown:
                return f"request contains unknown parameters {unknown}"
        for name, requiredness in selectors.items():
            if name in params:
                problem = self.selector(params[name], f"{operation}.{name}")
                if problem:
                    return problem
            elif requiredness == "required":
                return f"required selector {name} is missing"
        for name, spec in fields.items():
            if name in params:
                problem = self.value(params[name], spec["type"], f"{operation}.{name}", {})
                if problem:
                    return problem
            elif spec.get("required"):
                return f"required parameter {name} is missing"
        alternatives = descriptor.get("one_of")
        if alternatives:
            matches = sum(
                all(key in params for key in alt.get("required", ())) and not any(key in params for key in alt.get("forbidden", ()))
                for alt in alternatives
            )
            if matches != 1:
                return "request must match exactly one parameter alternative"
        return None

    @staticmethod
    def selector(value: Any, path: str) -> Optional[str]:
        if not isinstance(value, str):
            return f"{path}: selector must be a string"
        if value.startswith("name:") or value == "current":
            return None
        prefix, _, payload = value.rpartition("_")
        if prefix and re.fullmatch(r"[0-9a-f]{32}", payload):
            return None
        if "_" in value:
            return f"{path}: reserved or ambiguous names must use the name: prefix"
        return None

    def value(self, value: Any, descriptor: Mapping[str, Any], path: str, bindings: Mapping[str, Any]) -> Optional[str]:
        descriptor, bindings = self.catalog.resolve(descriptor, bindings)
        kind = descriptor["kind"]
        if kind == "primitive":
            return self.primitive(value, descriptor, path)
        if kind == "enum":
            return None if value in descriptor["values"] else f"{path}: value is outside the allowed enum"
        if kind == "array":
            if not isinstance(value, list):
                return f"{path}: value must be an array"
            return self.length(len(value), descriptor, path, "items") or next(
                (p for i, item in enumerate(value) if (p := self.value(item, descriptor["items"], f"{path}[{i}]", bindings))), None)
        if kind == "map":
            if not isinstance(value, dict):
                return f"{path}: value must be an object map"
            return next((p for k, item in value.items() if (p := self.value(item, descriptor["values"], f"{path}.{k}", bindings))), None)
        if kind == "nullable":
            return None if value is None else self.value(value, descriptor["value"], path, bindings)
        if kind == "object":
            if not isinstance(value, dict):
                return f"{path}: value must be an object"
            fields = descriptor.get("fields", {})
            if descriptor.get("extra") is False:
                unknown = sorted(key for key in value if key not in fields)
                if unknown:
                    return f"{path}: object contains unknown fields {unknown}"
            for name, spec in fields.items():
                if name in value:
                    problem = self.value(value[name], spec["type"], f"{path}.{name}", bindings)
                    if problem:
                        return problem
                elif spec.get("required"):
                    return f"{path}: required object field {name} is missing"
            return None
        if kind == "selector":
            return self.selector(value, path)
        if kind == "resource_id":
            prefix = ID_PREFIX.get(descriptor["resource"], descriptor["resource"])
            if not isinstance(value, str) or not value.startswith(prefix + "_"):
                return f"{path}: resource id has the wrong type prefix"
            return None if re.fullmatch(r"[0-9a-f]{32}", value[len(prefix) + 1:]) else f"{path}: resource id must contain 32 lowercase hex digits"
        if kind == "union":
            matches = sum(self.value(value, variant, path, bindings) is None for variant in descriptor["variants"])
            return None if matches == 1 else f"{path}: value must match exactly one union variant"
        raise GenError(f"{path}: unknown catalog kind {kind!r}")

    def primitive(self, value: Any, descriptor: Mapping[str, Any], path: str) -> Optional[str]:
        name = descriptor["name"]
        if name == "json":
            return None
        if name == "string":
            if not isinstance(value, str):
                return f"{path}: value must be a string"
            return self.length(len(value.encode("utf-8")), descriptor, path, "UTF-8 bytes")
        if name == "base64":
            ok = isinstance(value, str) and re.fullmatch(r"(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?", value)
            return None if ok else f"{path}: value must use canonical base64"
        if name == "boolean":
            return None if isinstance(value, bool) else f"{path}: value must be a boolean"
        if name == "decimal":
            return None if isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value) else f"{path}: value must be an unsigned decimal string"
        if name == "float64":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                return f"{path}: value must be a finite number"
            return self.number(float(value), descriptor, path)
        bounds = {"uint16": (0, 0xFFFF), "uint32": (0, 0xFFFFFFFF), "int32": (-(2 ** 31), 2 ** 31 - 1)}
        if name in bounds:
            low, high = bounds[name]
            if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
                return f"{path}: value must be a {name}"
            return self.number(float(value), descriptor, path)
        raise GenError(f"{path}: unknown primitive {name!r}")

    @staticmethod
    def length(length: int, descriptor: Mapping[str, Any], path: str, unit: str) -> Optional[str]:
        low = descriptor.get("min_length", descriptor.get("min_items"))
        high = descriptor.get("max_length", descriptor.get("max_items"))
        if low is not None and length < low:
            return f"{path}: value has too few {unit}"
        if high is not None and length > high:
            return f"{path}: value has too many {unit}"
        return None

    @staticmethod
    def number(number: float, descriptor: Mapping[str, Any], path: str) -> Optional[str]:
        if ("minimum" in descriptor and number < descriptor["minimum"]) or ("maximum" in descriptor and number > descriptor["maximum"]):
            return f"{path}: number is outside its allowed range"
        return None


# ------------------------------------------------------------------------------------------ standard fixture


@dataclass(frozen=True)
class Handle:
    """A fixture object in a step's params or target: replaced by a `$step:` reference."""

    name: str


@dataclass(frozen=True)
class FixtureStep:
    id: str
    operation: str
    target: Tuple[Tuple[str, str], ...]  # (selector, handle)
    params: Mapping[str, Any]
    provides: Tuple[Tuple[str, str], ...]  # (handle, pointer into the result)


FIXTURE: Tuple[FixtureStep, ...] = (
    FixtureStep("fx-workspace", "workspace.create", (), {"initial_content": "terminal", "name": "oracle"},
                (("workspace", "/value/workspace_id"), ("screen", "/value/screen_id"), ("pane", "/value/pane_id"),
                 ("tab", "/value/tab_id"), ("terminal", "/value/terminal_id"))),
    FixtureStep("fx-split", "pane.split", (("workspace", "workspace"), ("screen", "screen"), ("pane", "pane")),
                {"direction": "right"}, (("other_pane", "/value/pane_id"), ("other_tab", "/value/tab_id"))),
    FixtureStep("fx-browser", "tab.create_browser", (("workspace", "workspace"), ("screen", "screen"), ("pane", "pane")),
                {"url": "about:blank"}, (("browser", "/value/browser_id"), ("browser_tab", "/value/tab_id"))),
    FixtureStep("fx-tab-group", "tab_group.create", (), {"tabs": [Handle("tab")], "name": "oracle"},
                (("tab_group", "/value/id"),)),
    FixtureStep("fx-saved-tab-group", "saved_tab_group.save", (), {"tab_group": Handle("tab_group")},
                (("saved_tab_group", "/value/id"),)),
    FixtureStep("fx-screen-group", "screen_group.create", (), {"screens": [Handle("screen")], "name": "oracle"},
                (("screen_group", "/value/id"),)),
    FixtureStep("fx-workspace-group", "workspace_group.create", (), {"name": "oracle"}, (("workspace_group", "/value/id"),)),
    FixtureStep("fx-room", "room.create", (), {"name": "oracle"}, (("room", "/value/id"),)),
    FixtureStep("fx-stash", "stash.create", (), {"tabs": [Handle("other_tab")], "name": "oracle"}, (("stash", "/value/stash_id"),)),
    FixtureStep("fx-notification", "notification.create", (), {"title": "oracle", "body": "oracle"},
                (("notification", "/value/id"),)),
    FixtureStep("fx-checklist", "workspace_checklist.add", (("workspace", "workspace"),), {"text": "oracle"},
                (("checklist_item", "/value/items/0/id"),)),
    FixtureStep("fx-chief", "chief.profile.create", (), {"display_name": "oracle"}, (("chief", "/value/id"),)),
    FixtureStep("fx-message", "agent.message.send", (), {"body": "oracle"}, (("message", "/value/id"),)),
    FixtureStep("fx-sidebar-view", "sidebar_view.ensure", (), {"cols": 80, "rows": 24}, (("sidebar_view", "/value/id"),)),
)
FIXTURE_BY_ID = {step.id: step for step in FIXTURE}
HANDLES: Dict[str, Tuple[str, str]] = {handle: (step.id, pointer) for step in FIXTURE for handle, pointer in step.provides}

# Fixture handle of a resource_id field or a selector of that resource kind.
RESOURCE_HANDLE = {kind: kind for kind in ("workspace", "screen", "pane", "tab", "terminal", "browser", "notification", "sidebar_view")}
# A selector-typed field (destination_pane, other_pane) names a second object where the fixture has one.
SELECTOR_FIELD_HANDLE = {"workspace": "workspace", "screen": "screen", "pane": "other_pane"}
# String fields that name a fixture object (StateId and plain string ids in the catalog).
NAMED_FIELD_HANDLE = {
    "tab_group": "tab_group", "saved_tab_group": "saved_tab_group", "screen_group": "screen_group",
    "workspace_group": "workspace_group", "room": "room", "stash": "stash", "chief": "chief",
    "message_id": "message", "pane_id": "pane", "terminal_id": "terminal", "workspace_id": "workspace",
}
OPERATION_FIELD_HANDLE = {("workspace_checklist.remove", "item"): "checklist_item",
                          ("workspace_checklist.update", "item"): "checklist_item"}
# Values for fields whose name says more than their type.
NAMED_VALUES: Dict[str, Any] = {
    "url": "about:blank", "argv": ["/bin/sh", "-c", "exit 0"], "shell": "/bin/sh", "path": f"{ROOT_TOKEN}/oracle",
    "cwd": f"{ROOT_TOKEN}/oracle", "cols": 80, "rows": 24, "columns": 80, "ratio": 0.5, "x_px": 10.0, "y_px": 10.0,
    "index": 0, "foreground": "#336699",
}


def placeholder_field(name: str) -> bool:
    """A string field that names an object the fixture does not make."""
    return name in ("id", "ids", "item", "items", "conversation") or name.endswith(("_id", "_ids"))


# ------------------------------------------------------------------------------------------------ values


@dataclass
class Request:
    """One operation call being built: its params and target (fixture objects as Handle values) and the paths
    of its placeholders."""

    operation: str
    params: Dict[str, Any] = field(default_factory=dict)
    target: Dict[str, Any] = field(default_factory=dict)
    placeholders: List[str] = field(default_factory=list)
    # Family tuning: steps between the fixture and the call, extra capabilities, and what the case cannot test.
    before: List[Dict[str, Any]] = field(default_factory=list)
    requires: List[str] = field(default_factory=list)
    untested: List[str] = field(default_factory=list)


class Synth:
    """Values from catalog types, fixture handles and NAMED_VALUES; every choice is fixed, so output is stable."""

    def __init__(self, catalog: Catalog):
        self.catalog = catalog
        self.check = CatalogCheck(catalog)

    def handle(self, request: Request, name: str) -> Handle:
        if name not in HANDLES:
            raise GenError(f"{request.operation}: no fixture handle {name!r}")
        return Handle(name)

    def sample(self, request: Request, descriptor: Mapping[str, Any], name: str, path: str,
               bindings: Optional[Mapping[str, Any]] = None) -> Any:
        handle = OPERATION_FIELD_HANDLE.get((request.operation, name))
        resolved, bindings = self.catalog.resolve(descriptor, bindings or {})
        kind = resolved["kind"]
        if handle is None and kind == "resource_id":
            handle = RESOURCE_HANDLE.get(resolved["resource"])
            if handle is None:
                request.placeholders.append(path)
                return resource_id(resolved["resource"])
        if handle is None and kind == "selector":
            handle = SELECTOR_FIELD_HANDLE.get(resolved["resource"])
        if handle is None and kind == "primitive" and resolved["name"] == "string":
            handle = NAMED_FIELD_HANDLE.get(name)
        if handle is not None:
            return self.handle(request, handle)
        if name in NAMED_VALUES and self.check.value(NAMED_VALUES[name], resolved, path, bindings) is None:
            value = copy.deepcopy(NAMED_VALUES[name])
            if isinstance(value, str) and value.startswith(ROOT_TOKEN):
                # No driver expands the token yet; the family tuning makes the path.
                request.placeholders.append(path)
            return value
        if kind == "primitive" and resolved["name"] == "string" and placeholder_field(name):
            request.placeholders.append(path)
        return self.structural(request, resolved, name, path, bindings)

    def structural(self, request: Request, t: Mapping[str, Any], name: str, path: str, bindings: Mapping[str, Any]) -> Any:
        kind = t["kind"]
        if kind == "primitive":
            return self.primitive(t)
        if kind == "enum":
            return t["values"][0]
        if kind == "nullable":
            return self.sample(request, t["value"], name, path, bindings)
        if kind == "array":
            count = max(1, t.get("min_items", 0))
            item = name[:-1] if name.endswith("s") else name
            return [self.sample(request, t["items"], item, f"{path}[{i}]", bindings) for i in range(count)]
        if kind == "map":
            return {}
        if kind == "object":
            return {key: self.sample(request, spec["type"], key, f"{path}.{key}", bindings)
                    for key, spec in t.get("fields", {}).items() if spec.get("required")}
        if kind == "selector":
            request.placeholders.append(path)
            return resource_id(t["resource"])
        if kind == "union":
            for variant in t["variants"]:
                trial = Request(request.operation)
                value = self.sample(trial, variant, name, path, bindings)
                if self.check.value(self.concrete(value), t, path, bindings) is None:
                    request.placeholders.extend(trial.placeholders)
                    return value
            raise GenError(f"{path}: no union variant gives a valid sample")
        raise GenError(f"{path}: unknown catalog kind {kind!r}")

    @staticmethod
    def primitive(t: Mapping[str, Any]) -> Any:
        name = t["name"]
        if name == "string":
            text = "oracle"
            low, high = t.get("min_length", 0), t.get("max_length")
            text = text + "0" * max(0, low - len(text))
            return text[:high] if high is not None else text
        if name == "json":
            return {}
        if name == "base64":
            return "b3JhY2xl"
        if name == "boolean":
            return t.get("default", False)
        if name == "decimal":
            return "1"
        if name == "float64":
            low, high = t.get("minimum"), t.get("maximum")
            if low is not None and high is not None:
                return (low + high) / 2
            return float(low) if low is not None else 1.0
        if name in ("uint16", "uint32", "int32"):
            return int(t.get("minimum", 1))
        raise GenError(f"unknown primitive {name!r}")

    def violation(self, descriptor: Mapping[str, Any], bindings: Optional[Mapping[str, Any]] = None
                  ) -> Optional[Tuple[Any, str]]:
        """A value its catalog type refuses, and the rule it breaks; None for a type that takes any JSON."""
        t, bindings = self.catalog.resolve(descriptor, bindings or {})
        kind = t["kind"]
        if kind == "nullable":
            return self.violation(t["value"], bindings)
        if kind == "enum":
            return "oracle-not-in-enum", "value is outside the allowed enum"
        if kind == "array":
            return ([], "value has too few items") if t.get("min_items", 0) >= 1 else ({}, "value must be an array")
        if kind == "object":
            return [], "value must be an object"
        if kind == "map":
            return [], "value must be an object map"
        if kind == "selector":
            return 7, "selector must be a string"
        if kind == "resource_id":
            return "oracle", "resource id has the wrong type prefix"
        if kind == "union" or (kind == "primitive" and t["name"] == "json"):
            return None
        name = t["name"]
        if name == "string":
            return ("", "value has too few UTF-8 bytes") if t.get("min_length", 0) >= 1 else (7, "value must be a string")
        if name == "base64":
            return "!", "value must use canonical base64"
        if name == "boolean":
            return "true", "value must be a boolean"
        if name == "decimal":
            return -1, "value must be an unsigned decimal string"
        if name == "float64":
            return "1.0", "value must be a finite number"
        if name in ("uint16", "uint32"):
            return -1, f"value must be an unsigned {name[4:]}-bit integer"
        if name == "int32":
            return "1", "value must be a signed 32-bit integer"
        raise GenError(f"unknown primitive {name!r}")

    def concrete(self, value: Any) -> Any:
        """The value with each fixture handle replaced by a well-formed value of its catalog type."""
        if isinstance(value, Handle):
            step_id, pointer = HANDLES[value.name]
            step = FIXTURE_BY_ID[step_id]
            t = self.catalog.type_at(self.catalog.operations[step.operation]["result"], pointer)
            if t is None:
                raise GenError(f"{step.id}: {pointer} is not in the result type of {step.operation}")
            resolved, _ = self.catalog.resolve(t, {})
            if resolved["kind"] == "resource_id":
                return resource_id(resolved["resource"])
            return self.primitive(resolved) if resolved["kind"] == "primitive" else self.structural(Request(step.operation), resolved, "", pointer, {})
        if isinstance(value, dict):
            return {key: self.concrete(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.concrete(item) for item in value]
        return value


# ------------------------------------------------------------------------------------------------- cases


def slug(operation: str) -> str:
    return operation.replace(".", "-").replace("_", "-")


def family_of(operation: str) -> str:
    prefix = operation.split(".", 1)[0]
    if prefix not in FAMILY_OF:
        raise GenError(f"{operation}: first segment {prefix!r} has no family in FAMILIES (tasks 061-070)")
    return FAMILY_OF[prefix]


def selector_handle(operation: str, selector: str) -> str:
    if selector == "tab" and operation.startswith("browser."):
        return "browser_tab"
    if selector not in HANDLES:
        return ""
    return selector


def base_request(synth: Synth, operation: str) -> Request:
    """The success request: required fields, the first one_of alternative, fixture selectors."""
    op = synth.catalog.operations[operation]
    descriptor = op["params"]
    request = Request(operation)
    selectors = descriptor["selectors"]
    required = [name for name, need in selectors.items() if need == "required" and name not in SCOPE]
    # An operation with a required selector acts on it; one with only optional selectors gets the fixture's
    # whole chain, so it does not fall back to whatever is focused.
    chosen = required or [name for name in selectors if name not in SCOPE]
    for name in chosen:
        handle = selector_handle(operation, name)
        if handle:
            request.target[name] = Handle(handle)
        else:
            request.target[name] = resource_id(name)
            request.placeholders.append(f"target.{name}")
    alternatives = descriptor.get("one_of") or []
    wanted = [name for name, spec in descriptor["fields"].items() if spec.get("required")]
    if alternatives:
        wanted += [name for name in alternatives[0].get("required", ()) if name not in wanted]
    for name in wanted:
        request.params[name] = synth.sample(request, descriptor["fields"][name]["type"], name, f"params.{name}")
    if not wanted and operation.rsplit(".", 1)[-1] in ("update", "rename"):
        # Updates and renames refuse an empty change; send the first field that is not a precondition.
        first = next((name for name in descriptor["fields"] if name not in ("expected_revision", "if_revision")), None)
        if first is not None:
            request.params[first] = synth.sample(request, descriptor["fields"][first]["type"], first, f"params.{first}")
    return request


def error_request(synth: Synth, success: Request) -> Tuple[Request, Dict[str, str]]:
    """The success request with one field broken against its catalog type."""
    descriptor = synth.catalog.operations[success.operation]["params"]
    fields = descriptor["fields"]
    order = [name for name, spec in fields.items() if spec.get("required")]
    order += [name for name in fields if name not in order]
    request = copy.deepcopy(success)
    for name in order:
        broken = synth.violation(fields[name]["type"])
        if broken is not None:
            request.params[name] = broken[0]
            return request, {"field": name, "rule": broken[1]}
    request.params[UNKNOWN_PARAMETER] = True
    return request, {"field": UNKNOWN_PARAMETER, "rule": "request contains unknown parameters"}


def handles_in(value: Any) -> Iterable[str]:
    if isinstance(value, Handle):
        yield value.name
    elif isinstance(value, dict):
        for item in value.values():
            yield from handles_in(item)
    elif isinstance(value, list):
        for item in value:
            yield from handles_in(item)


def fixture_closure(handles: Iterable[str]) -> List[str]:
    """The fixture steps that make these handles and the handles those steps use, in FIXTURE order."""
    needed: set = set()
    pending = list(handles)
    while pending:
        step = FIXTURE_BY_ID[HANDLES[pending.pop()][0]]
        if step.id in needed:
            continue
        needed.add(step.id)
        pending.extend(handles_in(dict(step.params)))
        pending.extend(handle for _, handle in step.target)
    return [step.id for step in FIXTURE if step.id in needed]


def refs(value: Any) -> Any:
    if isinstance(value, Handle):
        step_id, pointer = HANDLES[value.name]
        return f"$step:{step_id}#{pointer}"
    if isinstance(value, dict):
        return {key: refs(item) for key, item in value.items()}
    if isinstance(value, list):
        return [refs(item) for item in value]
    return value


def call_step(case_id: str, step_id: str, operation: str, target: Mapping[str, Any], params: Mapping[str, Any],
              expect: Mapping[str, Any], checkpoint: Optional[List[str]] = None, note: Optional[str] = None) -> Dict[str, Any]:
    step: Dict[str, Any] = {
        "id": step_id,
        "op": "resource.call",
        "target": {**SCOPE, **refs(dict(target))},
        "args": {"method": operation, "params": refs(dict(params)), "idempotencyKey": f"{case_id}.{step_id}"},
        "expect": dict(expect),
    }
    if checkpoint:
        step["checkpoint"] = checkpoint
    if note:
        step["note"] = note
    return step


OK = {"outcome": "ok", "receipt": "mutation_result"}
# A case that requires `chromium` drives a daemon-rendered browser: only a cmux-browser provider publishes the CDP
# target it attaches to (resource_router/browser_engine.rs), so without one `tab.create_browser` is
# engine_unavailable. The daemon product on the VM has none; the app product brings its browser host.
ENGINE_PRECONDITION = "a cmux-browser provider attached to the case daemon (the daemon launches no browser)"


def case_doc(case_id: str, operation: str, family: str, kind: str, request: Request, expect: Mapping[str, Any],
             note: str) -> Dict[str, Any]:
    steps = []
    used = list(handles_in(request.target)) + list(handles_in(request.params)) + list(handles_in(request.before))
    for step_id in fixture_closure(used):
        fx = FIXTURE_BY_ID[step_id]
        steps.append(call_step(case_id, fx.id, fx.operation, {s: Handle(h) for s, h in fx.target}, fx.params, OK))
    steps.extend(before_step(case_id, spec) for spec in request.before)
    steps.append(call_step(case_id, "call", operation, request.target, request.params, expect, ["before", "settled"], note))
    requires = ["resource_api", *(cap for cap in request.requires if cap != "resource_api")]
    preconditions = ["hermetic state root", "no other cmux-tui on the state root"]
    if "chromium" in requires:
        preconditions.append(ENGINE_PRECONDITION)
    doc: Dict[str, Any] = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{operation}: {'success' if kind == 'success' else 'typed error'} on the standard fixture",
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"{SUITE}.{slug(operation)}", "network": "offline", "clock": "virtual"},
        "preconditions": preconditions,
        "requires": requires,
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [f"generated by {GENERATOR} from the catalog type of {operation} (family {family})"],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }
    untested = [f"{path} is a fixed placeholder, not a fixture object; {family}/{TUNING} tunes it"
                for path in request.placeholders] + request.untested
    if untested:
        doc["untested"] = untested
    return doc


def before_step(case_id: str, spec: Mapping[str, Any]) -> Dict[str, Any]:
    """A tuning `before` step: a mutation call (method, target, params) or a settle that waits (waitFor)."""
    if "waitFor" in spec:
        return {"id": spec["id"], "op": "settle", "waitFor": copy.deepcopy(spec["waitFor"]),
                "settleMaxMs": spec["waitFor"]["maxMs"]}
    return call_step(case_id, spec["id"], spec["method"], spec.get("target") or {}, spec.get("params") or {}, OK)


# ---------------------------------------------------------------------------------------------- tuning


TUNING_KINDS = ("success", "error")
TUNING_KEYS = frozenset({"params", "target", "error", "note", "before", "requires", "untested"})
# The capabilities a tuning may add (case-v1 capability); resource_api is every case's.
TUNING_CAPABILITIES = frozenset({"chromium", "restart"})
BEFORE_CALL_KEYS = frozenset({"id", "method", "target", "params"})
BEFORE_WAIT_KEYS = frozenset({"id", "waitFor"})
STEP_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


def load_tuning(out: Path, catalog: Catalog) -> Dict[str, Dict[str, Any]]:
    """`<out>/<family>/_tuning.json`: {"operations": {op: {"success"|"error": {params, target, error, note, before,
    requires, untested}}}}. A params or target value null removes the key; {"$fixture": NAME} is a fixture handle.
    `before` (steps between the fixture and the call: {id, method, target, params} calls a mutation, {id, waitFor}
    settles until a facet value holds), `requires` (capabilities beyond resource_api) and `untested` replace the
    request's; the error case starts from the tuned success case."""
    tuning: Dict[str, Dict[str, Any]] = {}
    for family in FAMILIES:
        path = out / family / TUNING
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as error:
            raise GenError(f"{path}: {error}") from None
        extra = sorted(set(data) - {"operations", "$comment"}) if isinstance(data, dict) else ["<not an object>"]
        if extra:
            raise GenError(f"{path}: unknown keys {extra}")
        for operation, kinds in sorted((data.get("operations") or {}).items()):
            if operation not in catalog.operations or catalog.operations[operation].get("class") != "mutation":
                raise GenError(f"{path}: {operation} is not a mutation of the catalog")
            if family_of(operation) != family:
                raise GenError(f"{path}: {operation} belongs to family {family_of(operation)}")
            if not isinstance(kinds, dict) or not set(kinds) <= set(TUNING_KINDS):
                raise GenError(f"{path}: {operation} takes only {list(TUNING_KINDS)}")
            for kind, spec in kinds.items():
                if not isinstance(spec, dict) or not set(spec) <= TUNING_KEYS:
                    raise GenError(f"{path}: {operation}.{kind} takes only {sorted(TUNING_KEYS)}")
                if "error" in spec and (kind != "error" or spec["error"] not in catalog.operations[operation]["errors"]):
                    raise GenError(f"{path}: {operation}.{kind} error {spec['error']!r} is not an error of {operation}")
                check_tuned_steps(f"{path}: {operation}.{kind}", spec, catalog)
            tuning[operation] = kinds
    return tuning


def check_tuned_steps(where: str, spec: Mapping[str, Any], catalog: Catalog) -> None:
    """The before, requires and untested keys of one tuning kind."""
    requires = spec.get("requires", [])
    if not isinstance(requires, list) or not set(requires) <= TUNING_CAPABILITIES:
        raise GenError(f"{where}: requires takes only {sorted(TUNING_CAPABILITIES)}")
    untested = spec.get("untested", [])
    if not isinstance(untested, list) or not all(isinstance(item, str) and item for item in untested):
        raise GenError(f"{where}: untested is a list of reasons")
    before = spec.get("before", [])
    if not isinstance(before, list):
        raise GenError(f"{where}: before is a list of steps")
    taken = {step.id for step in FIXTURE} | {"call"}
    for item in before:
        keys = set(item) if isinstance(item, dict) else set()
        shape = BEFORE_WAIT_KEYS if "waitFor" in keys else BEFORE_CALL_KEYS
        if "id" not in keys or not keys <= shape or ("waitFor" not in keys and "method" not in keys):
            raise GenError(f"{where}: a before step is {{id, method, target, params}} or {{id, waitFor}}, not {item!r}")
        step_id = item["id"]
        if not isinstance(step_id, str) or not STEP_ID.match(step_id) or step_id in taken:
            raise GenError(f"{where}: before step id {step_id!r} is not a new step id")
        taken.add(step_id)
        method = item.get("method")
        if "method" in item and (method not in catalog.operations
                                 or catalog.operations[method].get("class") != "mutation"):
            raise GenError(f"{where}: before step {step_id} calls {method!r}, not a mutation of the catalog")


def tuned_value(value: Any) -> Any:
    if isinstance(value, dict) and set(value) == {"$fixture"}:
        if value["$fixture"] not in HANDLES:
            raise GenError(f"tuning names no fixture handle {value['$fixture']!r}")
        return Handle(value["$fixture"])
    if isinstance(value, dict):
        return {key: tuned_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [tuned_value(item) for item in value]
    return value


def non_local_remotes(value: Any, path: str) -> Iterable[str]:
    """Git remotes that are not a path under the case root (hermetic_env.py require_local_remote refuses
    them when the case runs; the generator refuses them before it writes a case)."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "remote" and not (isinstance(item, str) and item.startswith(f"{ROOT_TOKEN}/") and ".." not in item):
                yield f"{path}.{key} {item!r} is not a remote under {ROOT_TOKEN}"
            yield from non_local_remotes(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from non_local_remotes(item, f"{path}[{index}]")


def apply_tuning(request: Request, spec: Mapping[str, Any]) -> None:
    if "before" in spec:
        request.before = [tuned_value(item) for item in spec["before"]]
    if "requires" in spec:
        request.requires = list(spec["requires"])
    if "untested" in spec:
        request.untested = list(spec["untested"])
    for part in ("params", "target"):
        into = request.params if part == "params" else request.target
        for key, value in (spec.get(part) or {}).items():
            if value is None:
                into.pop(key, None)
            else:
                into[key] = tuned_value(value)
            request.placeholders = [p for p in request.placeholders
                                    if p != f"{part}.{key}" and not p.startswith((f"{part}.{key}[", f"{part}.{key}."))]


# ------------------------------------------------------------------------------------------------ suite


def generate(catalog: Catalog, tuning: Mapping[str, Mapping[str, Any]]) -> Dict[str, Any]:
    """{file name: JSON value} for the whole suite, coverage.json included."""
    synth = Synth(catalog)
    files: Dict[str, Any] = {}
    operations: Dict[str, Any] = {}
    families: Dict[str, int] = {family: 0 for family in FAMILIES}
    seen: Dict[str, str] = {}
    for operation in catalog.mutations():
        family = family_of(operation)
        families[family] += 1
        name = slug(operation)
        if name in seen:
            raise GenError(f"{operation} and {seen[name]} have the same case slug {name}")
        seen[name] = operation
        tuned = tuning.get(operation, {})
        code = tuned.get("error", {}).get("error", ERROR_CODE)
        success = base_request(synth, operation)
        apply_tuning(success, tuned.get("success", {}))
        # An untuned error breaks one field of the success request against its catalog type (validation.invalid);
        # a tuned one (another code, or params or target that the handler refuses) is the success request with
        # the tuning's changes.
        error_tuning = tuned.get("error", {})
        broken: Optional[Dict[str, str]] = None
        if code == ERROR_CODE and not {"params", "target"} & set(error_tuning):
            broken_request, broken = error_request(synth, success)
        else:
            broken_request = copy.deepcopy(success)
        apply_tuning(broken_request, error_tuning)
        problem = synth.check.params(operation, synth.concrete({**SCOPE, **success.target, **success.params}))
        if problem is not None:
            raise GenError(f"{operation}: the success request fails the catalog check: {problem}")
        wire = {**SCOPE, **broken_request.target, **broken_request.params}
        if broken and synth.check.params(operation, synth.concrete(wire)) is None:
            raise GenError(f"{operation}: the error request passes the catalog check")
        for request in (success, broken_request):
            remote = next(non_local_remotes(request.params, "params"), None)
            if remote:
                raise GenError(f"{operation}: {remote}")
        ok_id, error_id = f"{name}-ok", f"{name}-error"
        if len(error_id) > 64:
            raise GenError(f"{operation}: case id {error_id} is longer than 64")
        error_note = tuned.get("error", {}).get("note") or (
            f"{broken['field']} breaks its catalog type ({broken['rule']}); the daemon's catalog check refuses it"
            if broken else f"tuned to {code}")
        files[f"{ok_id}.json"] = case_doc(ok_id, operation, family, "success", success, OK,
                                          tuned.get("success", {}).get("note", "every required field from its catalog type"))
        files[f"{error_id}.json"] = case_doc(error_id, operation, family, "error", broken_request,
                                             {"outcome": "error", "error": code}, error_note)
        entry: Dict[str, Any] = {
            "family": family,
            "cases": {"success": f"{SUITE}/{ok_id}", "error": f"{SUITE}/{error_id}"},
            "fixture": [s["id"] for s in files[f"{ok_id}.json"]["steps"][:-1]],
            "error": {"code": code, **(broken or {})},
            "placeholders": sorted(set(success.placeholders)),
        }
        if tuned:
            entry["tuned"] = sorted(tuned)
        requires = {kind: files[f"{case_id}.json"]["requires"] for kind, case_id in (("success", ok_id), ("error", error_id))}
        if any(caps != ["resource_api"] for caps in requires.values()):
            entry["requires"] = requires
        operations[operation] = entry
    total = len(operations)
    files[COVERAGE] = {
        "generator": GENERATOR,
        "catalog": "cmux-tui/spec/resource-operations-v2.json",
        "catalog_sha256": catalog.sha256,
        "suite": SUITE,
        "total": total,
        "covered": total,
        "excluded": {},
        "missing": [],
        "families": families,
        "placeholder_operations": sum(1 for entry in operations.values() if entry["placeholders"]),
        "tokens": {ROOT_TOKEN: "the case's state root (hermetic_env.py ROOT_TOKEN, p15-oracle-200)"},
        "operations": operations,
    }
    return files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The case files the last generation wrote (from its coverage.json)."""
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    names = [case.split("/", 1)[1] + ".json" for entry in data.get("operations", {}).values()
             for case in entry.get("cases", {}).values()]
    return sorted(names)


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(value):
            problems.append(f"{name}: differs from a fresh generation")
    for name in owned_files(out):
        if name not in files and (out / name).exists():
            problems.append(f"{name}: generated earlier, no longer in the catalog")
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    """Writes changed files; removes files an earlier generation wrote that this one does not. Refuses to
    overwrite a case file it did not write."""
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name != COVERAGE and (out / name).exists() and name not in owned:
            raise GenError(f"{out / name}: exists and was not written by this generator")
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        text = render(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    removed = 0
    for name in sorted(owned - set(files)):
        (out / name).unlink(missing_ok=True)
        removed += 1
    return written, removed


# --------------------------------------------------------------------------------------------- self test


class GenDaemonOpsSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = Catalog.load()
        cls.synth = Synth(cls.catalog)
        cls.files = generate(cls.catalog, {})

    def test_every_mutation_has_a_success_and_an_error_case(self) -> None:
        mutations = self.catalog.mutations()
        coverage = self.files[COVERAGE]
        self.assertEqual(sorted(coverage["operations"]), mutations)
        self.assertEqual((coverage["covered"], coverage["total"]), (len(mutations), len(mutations)))
        self.assertEqual(len(self.files), 2 * len(mutations) + 1)
        self.assertEqual(sum(coverage["families"].values()), len(mutations))
        for operation in mutations:
            for kind in ("success", "error"):
                name = coverage["operations"][operation]["cases"][kind].split("/", 1)[1] + ".json"
                self.assertEqual(self.files[name]["steps"][-1]["args"]["method"], operation)

    def test_task_family_sizes(self) -> None:
        """The family sizes tasks 061-070 were cut by (p15-oracle.md task list). A new catalog mutation changes
        one: update it here, and the family's task owns the new op's tuning."""
        self.assertEqual(self.files[COVERAGE]["families"], {
            "browser": 17, "sidebar": 22, "session": 11, "workspace": 26, "terminal": 9, "layout": 25, "tab": 21,
            "git": 18, "chief": 24, "misc": 28})

    def test_fixture_pointers_resolve_in_result_types(self) -> None:
        for step in FIXTURE:
            op = self.catalog.operations[step.operation]
            self.assertEqual(op["class"], "mutation", step.id)
            for handle, pointer in step.provides:
                self.assertIsNotNone(self.catalog.type_at(op["result"], pointer), f"{step.id} {handle} {pointer}")
            params = self.synth.concrete({**SCOPE, **{s: Handle(h) for s, h in step.target}, **dict(step.params)})
            self.assertIsNone(self.synth.check.params(step.operation, params), step.id)
            earlier = {s.id for s in FIXTURE[:FIXTURE.index(step)]}
            for handle in list(handles_in(dict(step.params))) + [h for _, h in step.target]:
                self.assertIn(HANDLES[handle][0], earlier, f"{step.id} uses {handle} before it exists")

    def test_resource_handles_have_the_resource_kind(self) -> None:
        for handle in set(RESOURCE_HANDLE.values()) | {"other_pane", "other_tab", "browser_tab"}:
            step_id, pointer = HANDLES[handle]
            step = FIXTURE_BY_ID[step_id]
            t, _ = self.catalog.resolve(self.catalog.type_at(self.catalog.operations[step.operation]["result"], pointer), {})
            self.assertEqual(t["kind"], "resource_id", handle)
            self.assertEqual(t["resource"], {"other_pane": "pane", "other_tab": "tab", "browser_tab": "tab"}.get(handle, handle))

    def test_cases_pass_the_case_schema(self) -> None:
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        for name, case in sorted(self.files.items()):
            if name == COVERAGE:
                continue
            self.assertEqual(normalize.validate(case, schema), [], name)
            self.assertEqual(checks.check_case(case, rules), [], name)

    def test_step_references_name_earlier_fixture_steps(self) -> None:
        for name, case in self.files.items():
            if name == COVERAGE:
                continue
            ids = [step["id"] for step in case["steps"]]
            for index, step in enumerate(case["steps"]):
                for text in re.findall(r'"\$step:([a-z0-9-]+)#', json.dumps(step)):
                    self.assertIn(text, ids[:index], f"{name} {step['id']}")

    def test_the_error_request_differs_from_success_in_one_field(self) -> None:
        for operation, entry in self.files[COVERAGE]["operations"].items():
            ok = self.files[entry["cases"]["success"].split("/", 1)[1] + ".json"]["steps"][-1]
            bad = self.files[entry["cases"]["error"].split("/", 1)[1] + ".json"]["steps"][-1]
            self.assertEqual(ok["target"], bad["target"], operation)
            changed = {k for k in set(ok["args"]["params"]) | set(bad["args"]["params"])
                       if ok["args"]["params"].get(k, KeyError) != bad["args"]["params"].get(k, KeyError)}
            self.assertEqual(changed, {entry["error"]["field"]}, operation)
            self.assertEqual(bad["expect"], {"outcome": "error", "error": ERROR_CODE})

    def test_regeneration_is_byte_stable_and_check_finds_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / SUITE
            write(out, self.files)
            first = {p.name: p.read_bytes() for p in out.iterdir() if p.is_file()}
            self.assertEqual(write(out, generate(self.catalog, load_tuning(out, self.catalog))), (0, 0))
            self.assertEqual({p.name: p.read_bytes() for p in out.iterdir() if p.is_file()}, first)
            self.assertEqual(drift(out, self.files), [])
            victim = sorted(first)[0]
            (out / victim).write_text("{}\n", encoding="utf-8")
            self.assertEqual(drift(out, self.files), [f"{victim}: differs from a fresh generation"])

    def test_removed_operations_lose_their_cases_and_foreign_files_are_kept(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / SUITE
            write(out, self.files)
            fewer = {k: v for k, v in self.files.items() if not k.startswith("workspace-rename-")}
            coverage = copy.deepcopy(fewer[COVERAGE])
            del coverage["operations"]["workspace.rename"]
            fewer[COVERAGE] = coverage
            self.assertIn("coverage.json: differs from a fresh generation", drift(out, fewer))
            written, removed = write(out, fewer)
            self.assertEqual((written, removed), (1, 2))
            self.assertFalse((out / "workspace-rename-ok.json").exists())
            (out / "hand-written.json").write_text("{}\n", encoding="utf-8")
            write(out, self.files)
            self.assertTrue((out / "hand-written.json").exists())
            clash = dict(self.files)
            clash["hand-written.json"] = {}
            with self.assertRaisesRegex(GenError, "not written by this generator"):
                write(out, clash)

    def test_tuning_survives_regeneration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / SUITE
            (out / "layout").mkdir(parents=True)
            (out / "layout" / TUNING).write_text(json.dumps({"operations": {"pane.swap": {
                "success": {"params": {"other_pane": {"$fixture": "other_pane"}}, "note": "swap with the split"},
                "error": {"target": {"pane": "pane_" + "f" * 32}, "params": {"other_pane": {"$fixture": "other_pane"}},
                          "error": "selector.not_found", "note": "no such pane"}}}}), encoding="utf-8")
            files = generate(self.catalog, load_tuning(out, self.catalog))
            entry = files[COVERAGE]["operations"]["pane.swap"]
            self.assertEqual(entry["tuned"], ["error", "success"])
            self.assertEqual(entry["error"], {"code": "selector.not_found"})
            bad = files["pane-swap-error.json"]["steps"][-1]
            self.assertEqual(bad["expect"], {"outcome": "error", "error": "selector.not_found"})
            self.assertEqual(bad["target"]["pane"], "pane_" + "f" * 32)
            self.assertEqual(files["pane-swap-ok.json"]["steps"][-1]["note"], "swap with the split")
            self.assertEqual(generate(self.catalog, load_tuning(out, self.catalog)), files)

    def test_bad_tuning_is_refused(self) -> None:
        bad = [
            ({"operations": {"workspace.list": {}}}, "not a mutation"),
            ({"operations": {"tab.close": {}}}, "belongs to family tab"),
            ({"operations": {"pane.close": {"success": {"error": "selector.not_found"}}}}, "not an error"),
            ({"operations": {"pane.close": {"error": {"error": "home.pinned_first"}}}}, "not an error"),
            ({"operations": {"pane.close": {"retry": {}}}}, "takes only"),
            ({"rules": {}}, "unknown keys"),
            ({"operations": {"pane.close": {"success": {"requires": ["gui"]}}}}, "requires takes only"),
            ({"operations": {"pane.close": {"success": {"untested": [""]}}}}, "untested is a list"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "workspace.list"}]}}}},
             "not a mutation of the catalog"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "fx-workspace", "method": "pane.split"}]}}}},
             "not a new step id"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "call", "waitFor": {}}]}}}}, "not a new step id"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "waitFor": {}, "method": "pane.split"}]}}}},
             "a before step is"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x"}]}}}}, "a before step is"),
        ]
        for data, message in bad:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                (out / "layout").mkdir()
                (out / "layout" / TUNING).write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaisesRegex(GenError, message):
                    load_tuning(out, self.catalog)
        tuned = {"pane.close": {"success": {"params": {"oracle_extra": 1}}}}
        with self.assertRaisesRegex(GenError, "fails the catalog check"):
            generate(self.catalog, tuned)

    def test_a_tuned_validation_error_is_the_success_request_with_the_tuning(self) -> None:
        """A handler-level validation.invalid (a value its catalog type takes) breaks no field."""
        device = {"title": "o", "screen": {"device-pixel-ratio": 11}}
        files = generate(self.catalog, {"browser.devices.add_custom": {
            "success": {"params": {"device": {"title": "o"}}},
            "error": {"params": {"device": device}, "error": ERROR_CODE}}})
        call = files["browser-devices-add-custom-error.json"]["steps"][-1]
        self.assertEqual(call["args"]["params"], {"device": device})
        self.assertEqual(files[COVERAGE]["operations"]["browser.devices.add_custom"]["error"], {"code": ERROR_CODE})

    def test_before_steps_run_between_the_fixture_and_the_call(self) -> None:
        wait = {"pointer": "/daemon/session/terminals/0/lifecycle", "equals": "exited", "maxMs": 15000}
        tuned = {"sidebar.group.ungroup": {
            "success": {"before": [{"id": "split", "method": "pane.split", "target": {"pane": {"$fixture": "pane"}},
                                    "params": {"direction": "right"}},
                                   {"id": "settled", "waitFor": wait},
                                   {"id": "group", "method": "sidebar.group.create",
                                    "params": {"id": "itm_g", "name": "g", "items": ["itm_home"]}}],
                        "params": {"id": "itm_g"}},
            "error": {"before": [], "params": {"id": "itm_home"}}}}
        files = generate(self.catalog, tuned)
        ok, bad = files["sidebar-group-ungroup-ok.json"], files["sidebar-group-ungroup-error.json"]
        # A fixture handle in a before step pulls its fixture steps in first.
        self.assertEqual([s["id"] for s in ok["steps"]], ["fx-workspace", "split", "settled", "group", "call"])
        self.assertEqual(ok["steps"][1]["target"]["pane"], "$step:fx-workspace#/value/pane_id")
        self.assertEqual(ok["steps"][1]["args"]["idempotencyKey"], "sidebar-group-ungroup-ok.split")
        self.assertEqual(ok["steps"][1]["expect"], OK)
        self.assertEqual(ok["steps"][2], {"id": "settled", "op": "settle", "waitFor": wait, "settleMaxMs": 15000})
        self.assertEqual(ok["steps"][-1]["args"]["params"], {"id": "itm_g"})
        # The error case starts from the tuned success case; an empty before drops the steps (and their fixture).
        self.assertEqual([s["id"] for s in bad["steps"]], ["call"])
        self.assertEqual(bad["steps"][-1]["args"]["params"], {"id": "itm_home"})
        self.assertEqual(bad["steps"][-1]["expect"], {"outcome": "error", "error": ERROR_CODE})

    def test_the_sidebar_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/sidebar/_tuning.json (p15-oracle-062): each of the 22 sidebar mutations has
        a success case on the daemon's default sidebar document and a typed error, with no placeholder left. A
        sidebar view needs a configured plugin, which the success cases write and load before the view starts."""
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        sidebar = sorted(op for op in self.catalog.mutations() if family_of(op) == "sidebar")
        self.assertEqual(len(sidebar), 22)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "sidebar"), sidebar)
        codes = {op: files[COVERAGE]["operations"][op]["error"]["code"] for op in sidebar}
        self.assertEqual({op for op, code in codes.items() if code != ERROR_CODE},
                         {"sidebar_view.ensure", "sidebar_view.input", "sidebar_view.reload", "sidebar_view.resize"})
        plugin_steps = ["write-config", "config-written", "reload-config"]
        for operation in sidebar:
            entry = files[COVERAGE]["operations"][operation]
            self.assertEqual(entry["placeholders"], [], operation)
            for kind in ("success", "error"):
                name = entry["cases"][kind].split("/", 1)[1] + ".json"
                case = files[name]
                self.assertEqual(normalize.validate(case, schema), [], name)
                self.assertEqual(checks.check_case(case, rules), [], name)
                self.assertNotIn("untested", case, name)
                ids = [step["id"] for step in case["steps"]]
                self.assertEqual(ids[-1], "call", name)
                self.assertEqual(case["steps"][-1]["args"]["method"], operation, name)
                # The fixture view would start before the plugin is configured.
                self.assertNotIn("fx-sidebar-view", ids, name)
                needs_plugin = kind == "success" and operation.startswith("sidebar_view.")
                self.assertEqual(ids[:3] == plugin_steps, needs_plugin, name)
                if kind == "error":
                    # Only the refusal of a machine section needs one: the remote machine's section.
                    self.assertEqual(ids[:-1], ["adopt-remote"] if operation == "sidebar.section.remove" else [], name)
            if operation.startswith("sidebar_view.") and operation != "sidebar_view.ensure":
                ok = files[entry["cases"]["success"].split("/", 1)[1] + ".json"]
                self.assertEqual(ok["steps"][-1]["target"]["sidebar_view"], "$step:ensure-view#/value/id")
                self.assertEqual(ok["steps"][-2]["args"]["method"], "sidebar_view.ensure")
                bad = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]
                self.assertEqual(bad["steps"][-1]["target"]["sidebar_view"], "sidebar")
        write = files["sidebar-view-ensure-ok.json"]["steps"][0]["args"]["params"]["argv"]
        self.assertEqual(json.loads(write[-1]), {"sidebar": {"plugin": {"command": ["/bin/cat"]}}})
        self.assertEqual(drift(DEFAULT_OUT, files), [])

    def test_a_git_remote_outside_the_case_root_is_refused(self) -> None:
        for remote in ("git@github.com:manaflow-ai/cmux.git", "/srv/repos/cmux.git", f"{ROOT_TOKEN}/../x.git", "origin"):
            with self.subTest(remote=remote), self.assertRaisesRegex(GenError, "git.push: params.remote"):
                generate(self.catalog, {"git.push": {"success": {"params": {"remote": remote}}}})
        files = generate(self.catalog, {"git.push": {"success": {"params": {"remote": f"{ROOT_TOKEN}/repos/o.git"}}}})
        self.assertEqual(files["git-push-ok.json"]["steps"][-1]["args"]["params"]["remote"], f"{ROOT_TOKEN}/repos/o.git")

    def test_catalog_check_matches_the_daemon_rules(self) -> None:
        check = self.synth.check
        scope = dict(SCOPE)
        self.assertIsNone(check.params("pane.split", {**scope, "pane": resource_id("pane"), "direction": "right"}))
        self.assertRegex(check.params("pane.split", {**scope, "pane": resource_id("pane")}), "direction is missing")
        self.assertRegex(check.params("pane.split", {**scope, "direction": "right"}), "selector pane is missing")
        self.assertRegex(check.params("pane.split", {**scope, "pane": "pane_x", "direction": "right"}), "name: prefix")
        self.assertRegex(check.params("pane.split", {**scope, "pane": resource_id("pane"), "direction": "in"}), "enum")
        self.assertRegex(check.params("workspace.close", {**scope, "workspace": resource_id("workspace"), "x": 1}), "unknown")
        self.assertRegex(check.params("terminal.input.write", {**scope, "terminal": resource_id("terminal")}), "alternative")
        both = {**scope, "terminal": resource_id("terminal"), "text": "a", "bytes_base64": "YQ=="}
        self.assertRegex(check.params("terminal.input.write", both), "alternative")
        self.assertRegex(check.params("screen_group.create", {**scope, "screens": ["ws_" + "0" * 32]}), "prefix")
        self.assertRegex(check.params("screen_group.create", {**scope, "screens": []}), "too few")

    def test_a_split_targets_the_fixture_pane_as_the_example_case_does(self) -> None:
        """schemas/oracle/fixtures/case-example-daemon.json splits the pane of a workspace it created."""
        case = self.files["pane-split-ok.json"]
        self.assertEqual([step["id"] for step in case["steps"]], ["fx-workspace", "call"])
        call = case["steps"][-1]
        self.assertEqual(call["args"]["params"], {"direction": "left"}, "the first value of the catalog enum")
        self.assertEqual(call["target"], {**SCOPE, "pane": "$step:fx-workspace#/value/pane_id"})
        self.assertEqual(call["args"]["idempotencyKey"], "pane-split-ok.call")
        self.assertEqual(call["checkpoint"], ["before", "settled"])


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenDaemonOpsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        catalog = Catalog.load(args.catalog)
        files = generate(catalog, load_tuning(args.out, catalog))
        coverage = files[COVERAGE]
        if args.check:
            problems = drift(args.out, files)
            for problem in problems:
                print(f"gen_daemon_ops: {problem}", file=sys.stderr)
            print(f"gen_daemon_ops: {coverage['covered']}/{coverage['total']} operations, "
                  f"{'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
    except GenError as error:
        print(f"gen_daemon_ops: {error}", file=sys.stderr)
        return 2
    print(f"gen_daemon_ops: {coverage['covered']}/{coverage['total']} operations, {len(files) - 1} cases, "
          f"{written} files written, {removed} removed, {coverage['placeholder_operations']} with placeholders")
    return 0


if __name__ == "__main__":
    sys.exit(main())
