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
  Rules that live in a handler, not in that check, are HANDLER_FIELDS; preconditions the standard fixture
  cannot meet are KNOWN_GAPS.

The standard fixture is FIXTURE: named objects (a terminal workspace, a split, a browser tab, a tab group, ...),
each made by one catalog mutation and read from its result by a JSON pointer that the generator resolves in the
catalog's result type. A case has only the fixture steps its handles need, in FIXTURE order.

Cases are flat in the suite directory, as every suite: `oracle.py` and the expectation targets
(`suite/case[/step]`) name a case by one path segment. The families of tasks 061-070 tune their operations in
`<family>/_tuning.json` (oracle.py skips `_` files), which this generator reads, so regeneration keeps the tuning
and stays byte-stable. coverage.json lists every operation with its family, cases, fixture steps, broken field,
placeholders (fields with a fixed id, not a fixture object: the tuning work), known gap and tuning. An operation
counts as covered only when its success case has no placeholder and no known gap; the rest are excluded with the
family task that tunes them. Covered is not a verdict: driver_daemon.py on the VM gives the first one.

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
# resource.rs PUBLIC_ID_PREFIXES: Selector::parse reads `<prefix>_<32 hex>` as an id only for these prefixes.
PUBLIC_ID_PREFIXES = ("machine", "session", "ws", "screen", "pane", "tab", "term", "browser", "client", "split", "stream",
                      "notification", "agent", "projection", "pairing", "sidebar_view", "sidebar_plugin")
# resource/selector_tokens.rs is_reserved_selector_token: CLI grammar words a bare selector may not be.
RESERVED_SELECTOR_TOKENS = frozenset("""
    machine session client window pairing request frontend projection workspace screen pane tab terminal browser split
    notification agent sidebar view plugin provider scope action notice list get show create open rename delete restore
    purge connect snapshot events ping shutdown update metadata detach set clear resolve put move focus close run apply
    export undo neighbor swap zoom resize send keys read history state direction process renderer grant cell pixels copy
    attach navigate back forward reload activate install use builtin disable remove report notify
""".split())
# catalog_validation.rs validate_operation_constraints: the per-operation rules the catalog types cannot say.
TERMINAL_LAUNCH_OPS = frozenset({"workspace.create", "pane.split", "pane.create", "screen.create", "tab.create_terminal"})
ARGV_OPS = TERMINAL_LAUNCH_OPS | {"pane.run", "workspace.run"}
PAIRED_SIZE_OPS = {"browser.attach": ("width_px", "height_px"), "tab.create_browser": ("width_px", "height_px"),
                   **{name: ("cols", "rows") for name in ("pane.create", "pane.run", "pane.split", "tab.create_terminal",
                                                          "terminal.attach", "workspace.run")}}
REQUIRE_ANY = {
    "client.metadata.update": ("name", "kind", "capabilities"),
    "session.terminal_defaults.update": ("foreground", "background", "cursor", "selection_background",
                                         "selection_foreground", "palette", "cursor_style", "cursor_blink", "complete"),
}
RATIO_OPS = frozenset({"pane.split_ratio.set", "pane.split"})
NAME_UPDATE_OPS = frozenset({"tab.rename", "workspace.rename"})
CONSTRAINT_OPS = (TERMINAL_LAUNCH_OPS | ARGV_OPS | set(PAIRED_SIZE_OPS) | set(REQUIRE_ANY) | RATIO_OPS | NAME_UPDATE_OPS
                  | {"session.journal.subscribe", "browser.input.mouse", "terminal.input.mouse"})
# Fields that only state an expectation: an update that sets only these (and ids) changes nothing.
PRECONDITION_FIELDS = frozenset({"expected_revision", "if_revision", "expected_rev", "expected_generation",
                                 "expected_name_revision"})
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
    """The daemon's request check in Python: catalog_validation.rs validate_catalog_params, validate_catalog_value
    and validate_operation_constraints (with mouse.rs and resource_name.rs NameUpdate::parse), and resource.rs
    Selector::parse for selector strings. It returns the first refusal, or None. One rule is stricter than the
    catalog check: an id in a selector of a resource kind must be an id of that kind, which the routing and the
    handlers refuse otherwise (resource_selector.rs, mux/resource_topology/client_ids.rs "is not a pane id")."""

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
                problem = self.selector(params[name], f"{operation}.{name}", name)
                if problem:
                    return problem
            elif requiredness == "required":
                return f"required selector {name} is missing"
        with_defaults: Dict[str, Any] = {}
        for name, spec in fields.items():
            if name in params:
                problem = self.value(params[name], spec["type"], f"{operation}.{name}", {})
                if problem:
                    return problem
                with_defaults[name] = params[name]
            elif spec.get("required"):
                return f"required parameter {name} is missing"
            elif "default" in spec:
                with_defaults[name] = spec["default"]
        alternatives = descriptor.get("one_of")
        if alternatives:
            matches = sum(
                all(key in params for key in alt.get("required", ())) and not any(key in params for key in alt.get("forbidden", ()))
                for alt in alternatives
            )
            if matches != 1:
                return "request must match exactly one parameter alternative"
        return self.constraints(operation, with_defaults, params)

    @staticmethod
    def constraints(operation: str, fields: Mapping[str, Any], supplied: Mapping[str, Any]) -> Optional[str]:
        """validate_operation_constraints: `fields` has the catalog defaults filled in, `supplied` is the request."""
        if operation in NAME_UPDATE_OPS:
            source = fields.get("source", "user")
            release = fields.get("release", False)
            if release and source != "auto":
                return f"{operation}.release: release hands a name to source auto"
            if source == "auto" and not release and not ("expected_generation" in fields and "expected_name_revision" in fields):
                return f"{operation}.source: automatic names require a generation and name revision"
        if operation == "workspace.create" and fields.get("initial_content") == "empty":
            field_name = next((name for name in ("cwd", "argv", "shell") if name in fields), None)
            if field_name:
                return f"workspace.create.{field_name}: an empty workspace has no terminal to launch"
        if operation in TERMINAL_LAUNCH_OPS and "argv" in fields and "shell" in fields:
            return f"{operation}.shell: argv and shell are exclusive"
        if operation in ARGV_OPS and isinstance(fields.get("argv"), list):
            argv = fields["argv"]
            if not argv or not isinstance(argv[0], str) or not argv[0]:
                return f"{operation}.argv[0]: argv[0] must be non-empty"
        if operation in PAIRED_SIZE_OPS:
            first, second = PAIRED_SIZE_OPS[operation]
            if (first in fields) != (second in fields):
                return f"{operation}: paired size parameters must be sent together ({first}, {second})"
        if operation in REQUIRE_ANY and not any(name in supplied for name in REQUIRE_ANY[operation]):
            return f"{operation}: at least one update parameter is required"
        if operation == "session.journal.subscribe" and "cursor" in supplied and "start" in supplied:
            return f"{operation}: journal cursor and start are mutually exclusive"
        ratio = fields.get("ratio")
        if operation in RATIO_OPS and isinstance(ratio, (int, float)) and not isinstance(ratio, bool) and not 0.0 < ratio < 1.0:
            return f"{operation}.ratio: ratio must be greater than zero and less than one"
        kind = fields.get("kind")
        if operation == "browser.input.mouse":
            if kind in ("down", "up") and "button" not in fields:
                return "browser.input.mouse.button: button is required for down and up"
            if kind == "move" and ("button" in fields or "click_count" in fields):
                return "browser.input.mouse: move forbids button and click_count"
        if operation == "terminal.input.mouse":
            button, delta = "button" in fields, fields.get("delta_rows")
            valid = {"down": button and delta is None, "up": button and delta is None, "move": not button and delta is None,
                     "wheel": not button and isinstance(delta, int) and not isinstance(delta, bool) and delta != 0}
            if not valid.get(kind, False):
                return "terminal.input.mouse: terminal mouse parameters do not match the input kind"
        return None

    @staticmethod
    def selector(value: Any, path: str, resource: Optional[str] = None) -> Optional[str]:
        """Selector::parse; with `resource`, an id must also be an id of that kind."""
        if not isinstance(value, str):
            return f"{path}: selector must be a string"
        if value.startswith("name:") or value == "current":
            return None
        prefix, _, payload = value.rpartition("_")
        if prefix in PUBLIC_ID_PREFIXES and len(payload) == 32 and re.fullmatch(r"[0-9a-f]{32}", payload):
            wanted = ID_PREFIX.get(resource, resource) if resource else None
            if wanted is not None and prefix != wanted:
                return f"{path}: {value} is not a {resource} id"
            return None
        if prefix in PUBLIC_ID_PREFIXES and payload and re.fullmatch(r"[0-9a-fA-F]+", payload):
            return f"{path}: {value} is not an id"
        if "_" in value or value in RESERVED_SELECTOR_TOKENS:
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
            return self.selector(value, path, descriptor["resource"])
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
                (("tab_group", "/value/id"), ("grouped_tab", "/value/tab_ids/0"))),
    FixtureStep("fx-saved-tab-group", "saved_tab_group.save", (), {"tab_group": Handle("tab_group")},
                (("saved_tab_group", "/value/id"),)),
    FixtureStep("fx-screen-group", "screen_group.create", (), {"screens": [Handle("screen")], "name": "oracle"},
                (("screen_group", "/value/id"), ("grouped_screen", "/value/screen_ids/0"))),
    FixtureStep("fx-workspace-group", "workspace_group.create", (), {"name": "oracle"}, (("workspace_group", "/value/id"),)),
    FixtureStep("fx-room", "room.create", (), {"name": "oracle"}, (("room", "/value/id"),)),
    FixtureStep("fx-stash", "stash.create", (), {"tabs": [Handle("other_tab")], "name": "oracle"}, (("stash", "/value/stash_id"),)),
    FixtureStep("fx-notification", "notification.create", (), {"title": "oracle", "body": "oracle"},
                (("notification", "/value/id"),)),
    FixtureStep("fx-checklist", "workspace_checklist.add", (("workspace", "workspace"),), {"text": "oracle"},
                (("checklist_item", "/value/items/0/id"),)),
    FixtureStep("fx-chief", "chief.profile.create", (), {"display_name": "oracle"}, (("chief", "/value/id"),)),
    # agent_message_store.rs recipients_of refuses a send with no recipient and no parent: address the fixture terminal.
    FixtureStep("fx-message", "agent.message.send", (), {"recipients": [Handle("terminal")], "body": "oracle"},
                (("message", "/value/id"),)),
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
                          ("workspace_checklist.update", "item"): "checklist_item",
                          # A removal takes a member of the fixture group (array items are sampled by singular name).
                          ("tab_group.remove_tabs", "tab"): "grouped_tab",
                          ("screen_group.remove_screens", "screen"): "grouped_screen"}
# Fields a handler requires that the catalog marks optional; the success request sends these values.
HANDLER_FIELDS: Dict[str, Dict[str, Any]] = {
    # agent_message_store.rs recipients_of: "give at least one recipient, or a message to reply to".
    "agent.message.send": {"recipients": [Handle("terminal")]},
    # closed_history_delete.rs: exactly one of closed or all.
    "closed.delete": {"all": True},
}
# Success cases that pass the request check but cannot succeed on the standard fixture; the family task owns the
# precondition. A tuned success request takes the case over from this list.
KNOWN_GAPS: Dict[str, str] = {
    "closed.reopen": "a fresh daemon has no closed group to reopen; the family task closes one first",
}
KNOWN_GAP_PREFIXES: Tuple[Tuple[str, str], ...] = (
    ("git.", "the fixture workspace has no git repository; the family task generates one under $CASE_ROOT"),
)
FAMILY_TASK = {"browser": "p15-oracle-061", "sidebar": "p15-oracle-062", "session": "p15-oracle-063",
               "workspace": "p15-oracle-064", "terminal": "p15-oracle-065", "layout": "p15-oracle-066",
               "tab": "p15-oracle-067", "git": "p15-oracle-068", "chief": "p15-oracle-069", "misc": "p15-oracle-070"}
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
    request.params.update(copy.deepcopy(HANDLER_FIELDS.get(operation, {})))
    optional = [name for name in descriptor["fields"] if name not in request.params and name not in PRECONDITION_FIELDS]
    if is_change_operation(operation) and not changed_fields(request) and optional:
        # Updates and renames refuse an empty change: send the first field that is not a precondition.
        add_field(synth, request, optional[0])
    elif synth.check.params(operation, synth.concrete(wire_params(request))) is not None:
        # validate_operation_constraints (a mouse down needs a button, ...): the first optional field that
        # makes the request pass.
        for name in optional:
            trial = copy.deepcopy(request)
            add_field(synth, trial, name)
            if synth.check.params(operation, synth.concrete(wire_params(trial))) is None:
                return trial
    return request


def is_change_operation(operation: str) -> bool:
    return operation.rsplit(".", 1)[-1] in ("update", "rename")


def add_field(synth: Synth, request: Request, name: str) -> None:
    spec = synth.catalog.operations[request.operation]["params"]["fields"][name]
    request.params[name] = synth.sample(request, spec["type"], name, f"params.{name}")


def changed_fields(request: Request) -> List[str]:
    """The params that change something: not a precondition, and not an identity (a fixture object or a
    fixed placeholder id that names what the operation changes)."""
    return [name for name, value in request.params.items()
            if name not in PRECONDITION_FIELDS and not any(True for _ in handles_in(value))
            and not any(p == f"params.{name}" or p.startswith((f"params.{name}[", f"params.{name}."))
                        for p in request.placeholders)]


def wire_params(request: Request) -> Dict[str, Any]:
    return {**SCOPE, **request.target, **request.params}


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


def known_gap(operation: str) -> Optional[str]:
    """Why the success case cannot succeed on the standard fixture, or None."""
    if operation in KNOWN_GAPS:
        return KNOWN_GAPS[operation]
    return next((reason for prefix, reason in KNOWN_GAP_PREFIXES if operation.startswith(prefix)), None)


def case_doc(case_id: str, operation: str, family: str, kind: str, request: Request, expect: Mapping[str, Any],
             note: str, gap: Optional[str] = None) -> Dict[str, Any]:
    steps = []
    for step_id in fixture_closure(list(handles_in(request.target)) + list(handles_in(request.params))):
        fx = FIXTURE_BY_ID[step_id]
        steps.append(call_step(case_id, fx.id, fx.operation, {s: Handle(h) for s, h in fx.target}, fx.params, OK))
    steps.append(call_step(case_id, "call", operation, request.target, request.params, expect, ["before", "settled"], note))
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
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root"],
        "requires": ["resource_api"],
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [f"generated by {GENERATOR} from the catalog type of {operation} (family {family})"],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }
    untested = [f"{path} is a fixed placeholder, not a fixture object; {family}/{TUNING} tunes it"
                for path in request.placeholders]
    if gap:
        untested.append(f"{gap}; {family}/{TUNING} tunes it")
    if untested:
        doc["untested"] = untested
    return doc


# ---------------------------------------------------------------------------------------------- tuning


TUNING_KINDS = ("success", "error")
TUNING_KEYS = frozenset({"params", "target", "error", "note"})


def load_tuning(out: Path, catalog: Catalog) -> Dict[str, Dict[str, Any]]:
    """`<out>/<family>/_tuning.json`: {"operations": {op: {"success"|"error": {params, target, error, note}}}}.
    A params or target value null removes the key; {"$fixture": NAME} is a fixture handle."""
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
            tuning[operation] = kinds
    return tuning


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
    excluded: Dict[str, str] = {}
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
        # A validation error breaks one field of the success request; another typed error is the success
        # request with the tuning's changes.
        broken: Optional[Dict[str, str]] = None
        if code == ERROR_CODE:
            broken_request, broken = error_request(synth, success)
        else:
            broken_request = copy.deepcopy(success)
        apply_tuning(broken_request, tuned.get("error", {}))
        problem = synth.check.params(operation, synth.concrete(wire_params(success)))
        if problem is not None:
            raise GenError(f"{operation}: the success request fails the catalog check: {problem}")
        if code == ERROR_CODE and synth.check.params(operation, synth.concrete(wire_params(broken_request))) is None:
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
        gap = None if "success" in tuned else known_gap(operation)
        files[f"{ok_id}.json"] = case_doc(ok_id, operation, family, "success", success, OK,
                                          tuned.get("success", {}).get("note", "every required field from its catalog type"),
                                          gap)
        files[f"{error_id}.json"] = case_doc(error_id, operation, family, "error", broken_request,
                                             {"outcome": "error", "error": code}, error_note)
        entry: Dict[str, Any] = {
            "family": family,
            "cases": {"success": f"{SUITE}/{ok_id}", "error": f"{SUITE}/{error_id}"},
            "fixture": [s["id"] for s in files[f"{ok_id}.json"]["steps"][:-1]],
            "error": {"code": code, **(broken or {})},
            "placeholders": sorted(set(success.placeholders)),
        }
        if gap:
            entry["gap"] = gap
        if tuned:
            entry["tuned"] = sorted(tuned)
        operations[operation] = entry
        reasons = ([f"placeholders {', '.join(entry['placeholders'])}"] if entry["placeholders"] else []) + ([gap] if gap else [])
        if reasons:
            excluded[operation] = f"{'; '.join(reasons)}: {FAMILY_TASK[family]} tunes the success case"
    total = len(operations)
    files[COVERAGE] = {
        "generator": GENERATOR,
        "catalog": "cmux-tui/spec/resource-operations-v2.json",
        "catalog_sha256": catalog.sha256,
        "suite": SUITE,
        "total": total,
        # Operations whose success case has no placeholder and no known precondition gap. No case has a verdict
        # yet: driver_daemon.py on the VM gives the first one.
        "covered": total - len(excluded),
        "verdicts": "not run",
        "excluded": excluded,
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
        self.assertEqual(coverage["total"], len(mutations))
        self.assertEqual(coverage["covered"], len(mutations) - len(coverage["excluded"]))
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

    def test_selector_check_matches_selector_parse(self) -> None:
        """resource.rs Selector::parse: ids only for PUBLIC_ID_PREFIXES, no bare reserved tokens."""
        check = self.synth.check
        scope = dict(SCOPE)
        for value in ("room_" + "0" * 32, "column_" + "0" * 32, "pane", "update", "pane_" + "0" * 31, "pane_" + "A" * 32):
            with self.subTest(value=value):
                self.assertIsNotNone(check.selector(value, "x"))
        for value in ("pane_" + "0" * 32, "split_" + "a" * 32, "sidebar_view_" + "0" * 32, "name:pane", "current", "oracle"):
            with self.subTest(value=value):
                self.assertIsNone(check.selector(value, "x"))
        self.assertRegex(check.selector("tab_" + "0" * 32, "x", "pane"), "not a pane id")
        self.assertRegex(check.selector("ws_" + "0" * 32, "x", "room"), "not a room id")
        self.assertIsNone(check.selector("ws_" + "0" * 32, "x", "workspace"))
        self.assertRegex(check.params("pane.split", {**scope, "pane": "room_" + "0" * 32, "direction": "right"}), "name: prefix")
        self.assertRegex(check.params("pane.split", {**scope, "pane": resource_id("tab"), "direction": "right"}), "not a pane id")

    def test_operation_constraints_match_validate_operation_constraints(self) -> None:
        check = self.synth.check
        scope = dict(SCOPE)
        browser = {**scope, "browser": resource_id("browser"), "x_px": 1.0, "y_px": 1.0, "pointer_frame_seq": "1"}
        self.assertRegex(check.params("browser.input.mouse", {**browser, "kind": "down"}), "button is required")
        self.assertIsNone(check.params("browser.input.mouse", {**browser, "kind": "down", "button": "left"}))
        self.assertRegex(check.params("browser.input.mouse", {**browser, "kind": "move", "click_count": 1}), "move forbids")
        terminal = {**scope, "terminal": resource_id("terminal"), "row": 0, "column": 0}
        self.assertRegex(check.params("terminal.input.mouse", {**terminal, "kind": "down"}), "do not match")
        self.assertIsNone(check.params("terminal.input.mouse", {**terminal, "kind": "down", "button": "left"}))
        self.assertRegex(check.params("terminal.input.mouse", {**terminal, "kind": "wheel", "delta_rows": 0}), "do not match")
        self.assertIsNone(check.params("terminal.input.mouse", {**terminal, "kind": "wheel", "delta_rows": -1}))
        pane = {**scope, "pane": resource_id("pane"), "direction": "right"}
        self.assertRegex(check.params("pane.split", {**pane, "cols": 80}), "paired size")
        self.assertRegex(check.params("pane.split", {**pane, "ratio": 1.0}), "ratio")
        self.assertRegex(check.params("pane.split", {**pane, "argv": [""]}), "argv\\[0\\]")
        self.assertRegex(check.params("pane.split", {**pane, "argv": ["/bin/sh"], "shell": "/bin/sh"}), "exclusive")
        self.assertRegex(check.params("workspace.create", {**scope, "initial_content": "empty", "cwd": "/tmp"}), "empty workspace")
        self.assertRegex(check.params("session.terminal_defaults.update", scope), "at least one update parameter")
        rename = {**scope, "workspace": resource_id("workspace"), "name": "x"}
        self.assertRegex(check.params("workspace.rename", {**rename, "source": "auto"}), "generation and name revision")
        self.assertRegex(check.params("workspace.rename", {**rename, "release": True}), "release hands a name")

    def test_every_success_request_passes_the_operation_constraints(self) -> None:
        for operation, entry in self.files[COVERAGE]["operations"].items():
            call = self.files[entry["cases"]["success"].split("/", 1)[1] + ".json"]["steps"][-1]
            request = base_request(self.synth, operation)
            self.assertEqual(refs(wire_params(request)), {**call["target"], **call["args"]["params"]}, operation)
            concrete = self.synth.concrete(wire_params(request))
            self.assertIsNone(self.synth.check.params(operation, concrete), operation)
            fields = {k: v for k, v in concrete.items() if k in self.catalog.operations[operation]["params"]["fields"]}
            self.assertIsNone(CatalogCheck.constraints(operation, fields, concrete), operation)
        self.assertEqual(self.files["browser-input-mouse-ok.json"]["steps"][-1]["args"]["params"]["button"], "left")
        self.assertEqual(self.files["terminal-input-mouse-ok.json"]["steps"][-1]["args"]["params"]["button"], "left")

    def test_every_update_and_rename_sets_a_field_that_is_not_an_id(self) -> None:
        for operation in self.catalog.mutations():
            if is_change_operation(operation):
                with self.subTest(operation=operation):
                    self.assertTrue(changed_fields(base_request(self.synth, operation)), operation)
        self.assertEqual(self.files["room-update-ok.json"]["steps"][-1]["args"]["params"],
                         {"room": "$step:fx-room#/value/id", "name": "oracle"})

    def test_handler_rules_the_catalog_cannot_say(self) -> None:
        fx = FIXTURE_BY_ID["fx-message"]
        self.assertEqual(fx.params["recipients"], [Handle("terminal")])
        send = self.files["agent-message-send-ok.json"]
        self.assertEqual(send["steps"][-1]["args"]["params"]["recipients"], ["$step:fx-workspace#/value/terminal_id"])
        self.assertEqual([s["id"] for s in self.files["agent-message-unsend-ok.json"]["steps"]],
                         ["fx-workspace", "fx-message", "call"])
        self.assertEqual(self.files["closed-delete-ok.json"]["steps"][-1]["args"]["params"], {"all": True})
        for name, group, item in (("tab-group-remove-tabs-ok.json", "fx-tab-group", "tab_ids"),
                                  ("screen-group-remove-screens-ok.json", "fx-screen-group", "screen_ids")):
            case = self.files[name]
            self.assertIn(group, [s["id"] for s in case["steps"]], name)
            params = case["steps"][-1]["args"]["params"]
            self.assertEqual(list(params.values()), [[f"$step:{group}#/value/{item}/0"]], name)

    def test_coverage_excludes_what_cannot_pass_yet(self) -> None:
        coverage = self.files[COVERAGE]
        excluded = coverage["excluded"]
        self.assertEqual(coverage["verdicts"], "not run")
        for operation, entry in coverage["operations"].items():
            gap = bool(entry["placeholders"]) or "gap" in entry
            self.assertEqual(operation in excluded, gap, operation)
            if gap:
                self.assertIn(FAMILY_TASK[entry["family"]], excluded[operation], operation)
        for operation in ("git.commit", "closed.reopen", "pane.split_ratio.set", "history.visit.import"):
            self.assertIn(operation, excluded)
        for operation in ("closed.delete", "agent.message.send", "browser.input.mouse", "tab_group.remove_tabs"):
            self.assertNotIn(operation, excluded)
        tuned = generate(self.catalog, {"closed.reopen": {"success": {"note": "after a close"}}})[COVERAGE]
        self.assertNotIn("closed.reopen", tuned["excluded"])
        self.assertEqual(tuned["covered"], coverage["covered"] + 1)

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
