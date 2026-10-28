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

Each success case of an operation the catalog marks `idempotency: required` ends with step `retry`: the call
again, same method, target, params and idempotency key, after the `after` steps settle the state the call left.
invariants.py I10 holds it to the first call's reply (replayed true on the retry), the same journal head and the
same facets; a handler that runs again on a replay (a double create) breaks all three. coverage.json names each
retry step. An operation whose success ends the daemon (UNRETRIED, for example session.shutdown) gets no retry:
no daemon is left to answer it. coverage.json `unretried` names each one with its reason.

The standard fixture is FIXTURE: named objects (a terminal workspace, a split, a browser tab, a tab group, ...),
each made by one catalog mutation and read from its result by a JSON pointer that the generator resolves in the
catalog's result type. A case has only the fixture steps its handles need, in FIXTURE order.

Cases are flat in the suite directory, as every suite: `oracle.py` and the expectation targets
(`suite/case[/step]`) name a case by one path segment. The families of tasks 061-070 tune their operations in
`<family>/_tuning.json` (oracle.py skips `_` files), which this generator reads, so regeneration keeps the tuning
and stays byte-stable. A tuning changes params and target, the error code and the error details the error case
asserts, and adds `before` steps (a mutation, a readOnly read whose reply a `$step:` reference uses, or a waitFor
settle between the fixture and the call), `after` steps (the same after the call: a waitFor that asserts the state
it left, for example the split tree or a terminal's screen, a read with its exact reply or with a reply that must
equal an earlier read's, a replay of the call, and a graceful restart of the daemon on the same state root; the
error case does not inherit the success case's), the call's `checkpoint`s and `ends` (a call that stops the daemon
on purpose), `allow_crashes`, `fixture` handles no field names, `requires` capabilities (`chromium` for a
daemon-rendered browser, which needs a cmux-browser provider; `restart`), `switches` (the refactor switches the
case runs on both arms of, as the daemon names them), `untested` reasons and a `gap`: why no product can run the
success case yet, naming the task that closes it, and a `repo`: the generated git repository
(tests/oracle/fixtures/git/<repo>.json, case-v1 fixture.repo) the driver builds under $CASE_ROOT/repos before the
first step; a `remote` is then a plain name of that repository's remotes, and a path under $CASE_ROOT/repos one of
its folders. Such a case requires the `git_repo` capability, which no product has until its driver builds the
repository, so its operation is excluded (REPO_GAP). `expectations` record a known failure of the case on one arm
of its switches ({arm, results, reason}, the reason naming the task that fixes it; the error case inherits the
success case's); the generated block of the suite's expectations file carries them as `[ arm ]` lines.
coverage.json lists every
operation with its family, cases, fixture steps, broken field, placeholders (fields with a fixed id, not a fixture
object: the tuning work), known gap, tuning, switches and the capabilities of cases that need more than
resource_api. An operation counts as covered only when its success case has no placeholder and no known or tuned
gap; the rest are excluded with the task that closes them. Covered is not a verdict: driver_daemon.py on the VM
gives the first one.

Usage:
  gen_daemon_ops.py --out DIR          write the cases and coverage.json into DIR, and the block of Skip lines
                                       (excluded success cases) and known-failure lines into
                                       DIR/../../Expectations.d/daemon-ops.txt
  gen_daemon_ops.py --out DIR --check  exit 1 when DIR or that block differs from a fresh generation
  gen_daemon_ops.py --selftest         offline tests against the checked-in catalog
"""

from __future__ import annotations

import argparse
import copy
import functools
import hashlib
import importlib.util
import itertools
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
WORK = REPO / "plans" / "cmux-next" / "chrome-parity" / "WORK.tsv"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "daemon-ops"
CORPUS_DIR = DEFAULT_OUT.relative_to(REPO).as_posix()
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SUITE = "daemon-ops"
GENERATOR = "scripts/cmux-next/oracle/gen_daemon_ops.py"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
COVERAGE = "coverage.json"
TUNING = "_tuning.json"
# The generated repositories a case names in fixture.repo, and their builder.
REPO_FIXTURES = REPO / "tests" / "oracle" / "fixtures" / "git"

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
# A `$step:` reference in a step's JSON text: the step id it names must be an earlier step of the case.
STEP_REF_IN_TEXT = re.compile(r'"\$step:([a-z0-9][a-z0-9-]{0,63})#')
ERROR_CODE = "validation.invalid"
# git_ops/push.rs: `remote` names a configured remote, never a URL or a path.
REMOTE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# case-v1 capability of a case with fixture.repo: the product's driver builds the repository first.
REPO_CAPABILITY = "git_repo"
# The call step's snapshots unless a tuning says otherwise (a call that stops the daemon has no settled one).
CALL_CHECKPOINTS = ("before", "settled")
# The success case's same-key retry of its call, checked by invariants.py I10.
CALL_STEP = "call"
RETRY_STEP = "retry"
# Operations whose success ends the daemon process, so no daemon is left to answer a same-key retry.
UNRETRIED = {
    "session.shutdown": "its success ends the daemon: the reply is sent, then complete_daemon_shutdown_after_ack "
                        "(cmux-tui-core/src/server/disconnect.rs) disconnects every client and exits, so no daemon "
                        "answers a retry",
}
# case-v1 $defs/stepRef: a value from an earlier step's reply.
STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")


class GenError(Exception):
    """The catalog, the fixture or a tuning file cannot make the suite."""


@functools.lru_cache(maxsize=None)
def make_repo() -> Any:
    """tests/oracle/fixtures/git/make_repo.py: it owns the repository fixture format, the case root token and
    the folder the repositories are built in."""
    spec = importlib.util.spec_from_file_location("oracle_make_repo", REPO_FIXTURES / "make_repo.py")
    if spec is None or spec.loader is None:
        raise GenError(f"{REPO_FIXTURES / 'make_repo.py'}: cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses read the module of each class they make
    spec.loader.exec_module(module)
    return module


# The case's state root, as case values write it (a path under it is local to the case), and the folder of its
# generated repositories: make_repo.py's, the one copy.
ROOT_TOKEN: str = make_repo().ROOT_TOKEN
REPOS_ROOT: str = make_repo().REPOS_ROOT


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
    FixtureStep("fx-notification", "notification.create", (), {"title": "oracle", "body": "oracle"},
                (("notification", "/value/id"),)),
    FixtureStep("fx-checklist", "workspace_checklist.add", (("workspace", "workspace"),), {"text": "oracle"},
                (("checklist_item", "/value/items/0/id"),)),
    FixtureStep("fx-chief", "chief.profile.create", (), {"display_name": "oracle"}, (("chief", "/value/id"),)),
    # agent_message_store.rs recipients_of refuses a send with no recipient and no parent: address the fixture terminal.
    FixtureStep("fx-message", "agent.message.send", (), {"recipients": [Handle("terminal")], "body": "oracle"},
                (("message", "/value/id"),)),
    FixtureStep("fx-sidebar-view", "sidebar_view.ensure", (), {"cols": 80, "rows": 24}, (("sidebar_view", "/value/id"),)),
    # An app-drawn (frontend) browser tab: the daemon keeps its record and needs no cmux-browser provider, so it
    # exists on every daemon. fx-browser is daemon-rendered and needs a provider (`chromium`). The daemon never
    # loads the URL of a frontend tab; it only has to be an http URL with a host (is_web_url).
    FixtureStep("fx-browser-profile", "browser.profile.create", (), {"name": "oracle"},
                (("browser_profile", "/value/browser_profile/id"),)),
    FixtureStep("fx-app-browser", "browser.profile.open", (("workspace", "workspace"), ("screen", "screen"), ("pane", "pane")),
                {"url": "http://127.0.0.1:9/", "profile": Handle("browser_profile")},
                (("app_browser", "/value/browser_id"), ("app_browser_tab", "/value/tab_id"))),
    # state/stash.rs: a tabs stash takes web pages only (a terminal tab refuses the request) and `name` goes
    # with `workspaces` only (stash_router.rs create_workspaces). The app-drawn http page is one on every daemon.
    FixtureStep("fx-stash", "stash.create", (), {"tabs": [Handle("app_browser_tab")]}, (("stash", "/value/stash_id"),)),
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
    ("git.", "no `repo` tuning in git/_tuning.json: the standard fixture has no git repository, so the git "
             "operation needs a generated one (tests/oracle/fixtures/git, p15-oracle-068)"),
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
    # Family tuning: steps between the fixture and the call, steps after it that check its effect, extra
    # capabilities, the refactor switches the case exercises, and what the case cannot test.
    before: List[Dict[str, Any]] = field(default_factory=list)
    after: List[Dict[str, Any]] = field(default_factory=list)
    requires: List[str] = field(default_factory=list)
    switches: List[str] = field(default_factory=list)
    untested: List[str] = field(default_factory=list)
    # The error details the error case asserts (case-v1 expect.errorDetails, a subset of the reply's details).
    details: Optional[Dict[str, Any]] = None
    # case-v1 fixture.agent: "mock" runs the case with the mock agent (mock_chief.py MockAgent).
    agent: Optional[str] = None
    # The generated repository the case needs (case-v1 fixture.repo, tests/oracle/fixtures/git/<repo>.json).
    repo: Optional[str] = None
    # Known failures on one arm of the case's switches ({arm, results, reason}): expectation lines, not case steps.
    expectations: List[Dict[str, Any]] = field(default_factory=list)
    # Fixture handles to make although no field names them, the call's snapshots, the process the call ends on
    # purpose (case-v1 step `ends`), and the case-v1 allow_crashes entries for that exit.
    fixture: List[str] = field(default_factory=list)
    checkpoint: List[str] = field(default_factory=lambda: list(CALL_CHECKPOINTS))
    ends: Optional[str] = None
    allow_crashes: List[Dict[str, Any]] = field(default_factory=list)

    def before_methods(self) -> Dict[str, str]:
        """The before steps that call an operation: step id to method (what a `$step:` reference reads)."""
        return {step["id"]: step["method"] for step in self.before if "method" in step}


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

    def concrete(self, value: Any, steps: Optional[Mapping[str, str]] = None) -> Any:
        """The value with each fixture handle, and each `$step:` reference to a tuned before step (`steps`: step
        id to its method), replaced by a well-formed value of its catalog type."""
        if isinstance(value, Handle):
            step_id, pointer = HANDLES[value.name]
            return self.result_value(step_id, FIXTURE_BY_ID[step_id].operation, pointer)
        reference = STEP_REF.match(value) if isinstance(value, str) else None
        if reference and steps and reference.group(1) in steps:
            return self.result_value(reference.group(1), steps[reference.group(1)], reference.group(2))
        if isinstance(value, dict):
            return {key: self.concrete(item, steps) for key, item in value.items()}
        if isinstance(value, list):
            return [self.concrete(item, steps) for item in value]
        return value

    def result_value(self, step_id: str, operation: str, pointer: str) -> Any:
        """A well-formed value at `pointer` of the result of `operation` (the reply a `$step:` reference reads)."""
        t = self.catalog.type_at(self.catalog.operations[operation]["result"], pointer)
        if t is None:
            raise GenError(f"{step_id}: {pointer} is not in the result type of {operation}")
        resolved, _ = self.catalog.resolve(t, {})
        if resolved["kind"] == "resource_id":
            return resource_id(resolved["resource"])
        if resolved["kind"] == "primitive":
            return self.primitive(resolved)
        return self.structural(Request(operation), resolved, "", pointer, {})


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
# A case that requires `chromium` drives a daemon-rendered browser: only a cmux-browser provider publishes the CDP
# target it attaches to (resource_router/browser_engine.rs), so without one `tab.create_browser` is
# engine_unavailable. The daemon product on the VM has none; the app product brings its browser host.
ENGINE_PRECONDITION = "a cmux-browser provider attached to the case daemon (the daemon launches no browser)"
REPO_PRECONDITION = (f"git on PATH; tests/oracle/fixtures/git/{{repo}}.json built under {REPOS_ROOT} before the first "
                     "step (make_repo.py build_for_case): fixed dates, a local bare origin, no other remote")
# git.worktree.create writes ~/.cmux/worktrees/<repo>/<name> (git_ops/worktree.rs); build_for_case refuses another HOME.
HOME_PRECONDITION = f"HOME is the case's own folder under {ROOT_TOKEN}, as for every case with a generated repository"
# Why no product runs a case with fixture.repo yet: none offers REPO_CAPABILITY (oracle.py PRODUCTS).
REPO_GAP = (f"no product offers {REPO_CAPABILITY} yet: p15-oracle-243 makes the case runner build fixture.repo "
            f"(make_repo.build_for_case, then {ROOT_TOKEN} expanded) in the per-case HOME; the daemon product gets "
            f"{REPO_CAPABILITY} with it, and the git family's first VM run follows")


def known_gap(operation: str) -> Optional[str]:
    """Why the success case cannot succeed on the standard fixture, or None."""
    if operation in KNOWN_GAPS:
        return KNOWN_GAPS[operation]
    return next((reason for prefix, reason in KNOWN_GAP_PREFIXES if operation.startswith(prefix)), None)


def case_doc(case_id: str, operation: str, family: str, kind: str, request: Request, expect: Mapping[str, Any],
             note: str, catalog: Catalog, gap: Optional[str] = None) -> Dict[str, Any]:
    """One case; `gap` is the untested line that says why its success cannot be checked yet."""
    steps = []
    used = [*request.fixture, *handles_in(request.target), *handles_in(request.params), *handles_in(request.before),
            *handles_in(request.details), *handles_in(request.after)]
    if request.details is not None:
        expect = {**expect, "errorDetails": refs(request.details)}
    for step_id in fixture_closure(used):
        fx = FIXTURE_BY_ID[step_id]
        steps.append(call_step(case_id, fx.id, fx.operation, {s: Handle(h) for s, h in fx.target}, fx.params, OK))
    steps.extend(tuned_step(case_id, spec, catalog, request) for spec in request.before)
    call = call_step(case_id, CALL_STEP, operation, request.target, request.params, expect, list(request.checkpoint), note)
    if request.ends:
        call["ends"] = request.ends
    steps.append(call)
    steps.extend(tuned_step(case_id, spec, catalog, request) for spec in request.after)
    if kind == "success" and retried(catalog, operation):
        steps.append(retry_step(call))
    for index, step in enumerate(steps):
        earlier = {s["id"] for s in steps[:index]}
        dangling = sorted(set(STEP_REF_IN_TEXT.findall(json.dumps(step))) - earlier)
        if dangling:
            raise GenError(f"{case_id}: step {step['id']} refers to {dangling}, no earlier step of the case")
    requires = ["resource_api", *(cap for cap in request.requires if cap != "resource_api")]
    preconditions = ["hermetic state root", "no other cmux-tui on the state root"]
    if "chromium" in requires:
        preconditions.append(ENGINE_PRECONDITION)
    fixture: Dict[str, Any] = {"seed": f"{SUITE}.{slug(operation)}", "network": "offline", "clock": "virtual",
                               **({"agent": request.agent} if request.agent else {})}
    if request.repo:
        fixture["repo"] = request.repo
        requires.append(REPO_CAPABILITY)
        preconditions += [REPO_PRECONDITION.format(repo=request.repo), HOME_PRECONDITION]
    doc: Dict[str, Any] = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{operation}: {'success' if kind == 'success' else 'typed error'} on the standard fixture",
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": fixture,
        "preconditions": preconditions,
        "requires": requires,
        **({"switches": list(request.switches)} if request.switches else {}),
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [f"generated by {GENERATOR} from the catalog type of {operation} (family {family})"],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }
    if request.allow_crashes:
        doc["allow_crashes"] = copy.deepcopy(request.allow_crashes)
    equal = [step["id"] for step in steps
             if isinstance(step.get("expect", {}).get("result"), str) and step["expect"]["result"].startswith("$step:")]
    if equal:
        doc["invariants"].append(f"{', '.join(equal)} reply what the step each names replied, but for the "
                                 "pointers its resultExcept lists")
    untested = [f"{path} is a fixed placeholder, not a fixture object; {family}/{TUNING} tunes it"
                for path in request.placeholders] + request.untested
    if gap:
        untested.append(gap)
    if untested:
        doc["untested"] = untested
    return doc


def retried(catalog: Catalog, operation: str) -> bool:
    """The success case of an operation that requires an idempotency key retries its call (I10), unless its success
    ends the daemon (UNRETRIED)."""
    return catalog.operations[operation].get("idempotency") == "required" and operation not in UNRETRIED


def retry_step(call: Mapping[str, Any]) -> Dict[str, Any]:
    """The call again with its own idempotency key, recorded before and settled for I10."""
    step = copy.deepcopy(dict(call))
    step["id"] = RETRY_STEP
    step["checkpoint"] = ["before", "settled"]
    step["note"] = (f"I10: step {call['id']} again with its idempotency key; the daemon replays its reply, adds no "
                    "journal record and changes no facet")
    return step


def tuned_step(case_id: str, spec: Mapping[str, Any], catalog: Catalog, request: Request) -> Dict[str, Any]:
    """A tuning `before` or `after` step (TUNED_STEP_SHAPES): a graceful restart of the daemon, a replay of the
    call, a call (method, target, params) or a settle that waits (waitFor). A read call is a readOnly step that
    expects ok, with no idempotency key (reads forbid one; the runner fails it when the facet moves); its reply must
    equal the tuning's `result` when it gives one, or, with `equals`, an earlier read's reply but for the `except`
    pointers; a later step names its reply with `$step:<id>#<pointer>`. A read of a terminal's screen comes after a
    settle on what the program printed last, so no output moves the facet while it reads."""
    if "restart" in spec:
        step = {"id": spec["id"], "op": "restart", "target": {"process": spec["restart"]},
                "expect": {"outcome": "ok", "receipt": "identify"},
                "checkpoint": list(spec.get("checkpoint") or CALL_CHECKPOINTS)}
        if "waitFor" in spec:
            step["waitFor"] = refs(spec["waitFor"])
        return step
    if "replays" in spec:
        # The call again with its idempotency key: the daemon answers from its durable receipt.
        step = call_step(case_id, "call", request.operation, request.target, request.params,
                         {**OK, **equal_expect("call", spec)})
        return {**step, "id": spec["id"]}
    if "waitFor" in spec:
        return {"id": spec["id"], "op": "settle", "waitFor": refs(spec["waitFor"]), "settleMaxMs": spec["waitFor"]["maxMs"]}
    method = spec["method"]
    if catalog.operations[method].get("class") == "read":
        expect: Dict[str, Any] = {"outcome": "ok"}
        if "result" in spec:
            expect["result"] = copy.deepcopy(spec["result"])
        elif "equals" in spec:
            expect.update(equal_expect(spec["equals"], spec))
        return {"id": spec["id"], "op": "resource.call", "target": {**SCOPE, **refs(dict(spec.get("target") or {}))},
                "args": {"method": method, "params": refs(dict(spec.get("params") or {}))}, "readOnly": True,
                "expect": expect}
    return call_step(case_id, spec["id"], method, spec.get("target") or {}, spec.get("params") or {}, OK)


def equal_expect(step_id: str, spec: Mapping[str, Any]) -> Dict[str, Any]:
    """case-v1 expect.result naming the whole reply of `step_id`, and expect.resultExcept from `except`."""
    out: Dict[str, Any] = {"result": f"$step:{step_id}#"}
    if spec.get("except"):
        out["resultExcept"] = list(spec["except"])
    return out


# ---------------------------------------------------------------------------------------------- tuning


TUNING_KINDS = ("success", "error")
TUNING_KEYS = frozenset({"params", "target", "error", "note", "before", "after", "requires", "switches", "untested",
                         "gap", "details", "agent", "repo", "expectations", "fixture", "checkpoint", "ends",
                         "allow_crashes"})
# case-v1 fixture.agent values a tuning may set: the mock agent (mock_chief.py), or none (the default).
TUNING_AGENTS = frozenset({"mock", "none"})
# Keys that only one kind takes: the error code and details belong to the error case; a gap blocks the success case.
KIND_ONLY_KEYS = {"error": "error", "details": "error", "gap": "success"}
# A gap names the task that closes it (WORK.tsv ids).
TASK_ID = re.compile(r"\bp\d{2}-[a-z]+-\d{3}[a-z]?\b")
WAIT_PREDICATES = frozenset({"exists", "absent", "empty", "nonEmpty", "changed"})
WAIT_OPS = frozenset({"gt", "gte", "lt", "lte", "contains", "lengthEquals"})
WAIT_MAX_MS = 30000
# The capabilities a tuning may add (case-v1 capability); resource_api is every case's.
TUNING_CAPABILITIES = frozenset({"chromium", "restart"})
# A tuned step's shape is named by its first marker key in this order (case-v1 step ops: restart, resource.call,
# settle). A restart may wait (waitFor) until the restarted daemon shows a facet value; a replay sends the call
# again with its idempotency key. A read gives its exact reply (`result`) or equals an earlier read's, not both.
TUNED_STEP_SHAPES: Dict[str, frozenset] = {
    "restart": frozenset({"id", "restart", "waitFor", "checkpoint"}),
    "replays": frozenset({"id", "replays", "except"}),
    "method": frozenset({"id", "method", "target", "params", "result", "equals", "except"}),
    "waitFor": frozenset({"id", "waitFor"}),
}
STEP_CLASSES = frozenset({"mutation", "read"})
ALLOW_CRASH_KEYS = frozenset({"kind", "reason", "steps", "max"})
# The processes a call may end on purpose (case-v1 step `ends`).
ENDS_PROCESSES = frozenset({"daemon"})
# case-v1 $defs/resultExcept item: a JSON pointer whose segments may be `*` (every array item or object member).
EXCEPT_POINTER = re.compile(r"^(/([^~/]|~[01])*)+$")
STEP_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
# The refactor switches a family's cases may list (case-v1 `switches`): the switches the daemon reports in its
# `oracle-state` reply, as checked in by driver_daemon.py live-check (task 021). p15-oracle-232 registers them in
# plans/cmux-next/refactor-switches/.
DAEMON_STATE = REPO / "schemas" / "oracle" / "fixtures" / "daemon-oracle-state.expected.json"
SWITCH_NAME = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
# A tuned known failure: the run arm it fails on (expectations.py TAG_GROUPS["arm"]), the results a run of that arm
# gives (a Skip is a gap, not a known failure), and the reason, which names the task that fixes it.
EXPECTATION_KEYS = frozenset({"arm", "results", "reason"})
EXPECTATION_ARMS = ("old", "new")
EXPECTATION_RESULTS = ("Failure", "Crash", "Timeout")


@dataclass(frozen=True)
class TaskGraph:
    """WORK.tsv's task ids, their depends_on and their files: what a tuning gap may name as the task that closes it."""

    depends_on: Mapping[str, Tuple[str, ...]]
    files: Mapping[str, Tuple[str, ...]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path = WORK) -> "TaskGraph":
        try:
            rows = [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()[1:] if line]
        except OSError as error:
            raise GenError(f"{path}: {error}") from None
        rows = [row for row in rows if len(row) >= 4]
        return cls({row[0]: tuple(dep for dep in row[3].split(";") if dep) for row in rows},
                   {row[0]: tuple(file for file in row[5].split(";") if file) for row in rows if len(row) >= 6})

    def owns(self, task: str, directory: str) -> bool:
        """Whether `task`'s files take in `directory` (repo-relative, ending in /): the directory itself, a file in
        it, or a directory above it."""
        return any(path == directory or path.startswith(directory) or (path.endswith("/") and directory.startswith(path))
                   for path in self.files.get(task, ()))

    def done_before(self, task: str) -> frozenset:
        """`task` and every task it depends on, directly or not: all are done when `task` lands."""
        seen, pending = set(), [task]
        while pending:
            current = pending.pop()
            if current not in seen:
                seen.add(current)
                pending.extend(self.depends_on.get(current, ()))
        return frozenset(seen)

    def gap_problem(self, gap: Any, family: str) -> Optional[str]:
        """Why `gap` names no task that can still close it, or None. A cited id must be a WORK.tsv task, and not
        the family's own task or one it depends on: those are done when the family's cases land."""
        cited = TASK_ID.findall(gap) if isinstance(gap, str) else []
        if not cited:
            return "is a reason that names the task closing it"
        unknown = sorted({task for task in cited if task not in self.depends_on})
        if unknown:
            return f"names {unknown}, not tasks of WORK.tsv"
        done = sorted(set(cited) & self.done_before(FAMILY_TASK[family]))
        if done:
            return f"names {done}, done before {FAMILY_TASK[family]} lands, so they close nothing"
        # Only a task that edits the family's _tuning.json can remove the gap; another closes nothing by itself.
        corpus = f"{CORPUS_DIR}/{family}/"
        if not any(self.owns(task, corpus) for task in cited):
            return f"names {sorted(set(cited))}, none of whose WORK.tsv files take in {corpus}, so none removes it"
        return None


def load_tuning(out: Path, catalog: Catalog, tasks: Optional[TaskGraph] = None) -> Dict[str, Dict[str, Any]]:
    """`<out>/<family>/_tuning.json`: {"operations": {op: {"success"|"error": {params, target, error, details, note,
    before, after, fixture, checkpoint, ends, allow_crashes, requires, switches, untested, gap, agent, repo,
    expectations}}}}. A params or target value null removes the key; {"$fixture": NAME} is a fixture handle. `before`
    (steps between the fixture and the call) and `after` (steps after it, which check its effect) hold
    TUNED_STEP_SHAPES: {id, method, target, params} calls a mutation or a read (an after step only reads), a read's
    `result` is the exact reply it must give, and a read's `equals` names an earlier read whose reply this one must
    equal but for the `except` pointers; {id, waitFor} settles until a facet value holds; in `after` only, {id,
    replays: "call", except} sends the call again with its idempotency key and holds the reply equal to the call's,
    and {id, restart: "daemon", waitFor, checkpoint} stops the daemon gracefully and starts it on the same state
    root. `fixture` names fixture handles to make although no field uses them, `checkpoint` the call's snapshots,
    `ends` the process the call stops on purpose (with an allow_crashes entry that lists the call), `allow_crashes`
    the case-v1 entries, `requires` capabilities beyond resource_api, `switches` the refactor switches whose both
    arms the case runs on; these, `untested` and `agent` (case-v1 fixture.agent: mock runs the mock agent of
    mock_chief.py) replace the request's; the error case starts from the tuned success case, without its after
    steps, which check the success. `details` (error only) is the subset of the error's details the case asserts;
    `gap` (success only) says why no product can check the success yet and names the task that closes it (`tasks`,
    WORK.tsv by default), so coverage excludes the operation. `repo` names the generated repository the case needs
    (tests/oracle/fixtures/git/<repo>.json, case-v1 fixture.repo); null drops it. A value that looks like a real
    credential (CREDENTIAL_PATTERNS) is refused. `expectations` (check_expectations) are the case's known failures
    on one arm; the error case inherits the success case's unless its own tuning sets them."""
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
                misplaced = sorted(key for key in spec if KIND_ONLY_KEYS.get(key, kind) != kind)
                if misplaced:
                    raise GenError(f"{path}: {operation}.{kind} takes no {misplaced}: "
                                   f"{', '.join(f'{k} is {KIND_ONLY_KEYS[k]} only' for k in misplaced)}")
                if "error" in spec and spec["error"] not in catalog.operations[operation]["errors"]:
                    raise GenError(f"{path}: {operation}.{kind} error {spec['error']!r} is not an error of {operation}")
                if "details" in spec and not (isinstance(spec["details"], dict) and spec["details"]):
                    raise GenError(f"{path}: {operation}.{kind} details is a non-empty object")
                if "gap" in spec:
                    tasks = tasks or TaskGraph.load()
                    problem = tasks.gap_problem(spec["gap"], family)
                    if problem:
                        raise GenError(f"{path}: {operation}.{kind} gap {problem}")
                if "expectations" in spec:
                    tasks = tasks or TaskGraph.load()
                    check_expectations(f"{path}: {operation}.{kind}", spec["expectations"], tasks, family)
                secret = next(credential_values(spec, f"{operation}.{kind}"), None)
                if secret:
                    raise GenError(f"{path}: {secret}")
                if spec.get("repo") is not None:
                    repo_fixture(spec["repo"], f"{path}: {operation}.{kind}")
                check_tuned_steps(f"{path}: {operation}.{kind}", spec, catalog)
            tuning[operation] = kinds
    return tuning


# Values that are a real credential (key formats from cmux-tui/crates/acpmux/rules/secrets/gitleaks.toml): a case
# runs offline with a mock agent and holds none, so a tuning that carries one is refused before it reaches a case.
CREDENTIAL_PATTERNS: Tuple[Tuple[str, "re.Pattern[str]"], ...] = (
    ("an Anthropic API key", re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}")),
    ("an OpenAI API key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("a GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})")),
    ("an AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("a Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("a Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("a bearer token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}")),
    ("a private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
)


def credential_values(value: Any, path: str) -> Iterable[str]:
    """Where a tuning value looks like a real credential, as `<path>: <kind>` (never the value itself)."""
    if isinstance(value, str):
        for kind, pattern in CREDENTIAL_PATTERNS:
            if pattern.search(value):
                yield f"{path} holds {kind}; daemon-op cases hold no real credentials"
                return
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from credential_values(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from credential_values(item, f"{path}[{index}]")


def check_tuned_steps(where: str, spec: Mapping[str, Any], catalog: Catalog) -> None:
    """The before, after, fixture, checkpoint, ends, allow_crashes, requires, switches, untested and agent keys of
    one tuning kind. A before step calls a mutation, or a read whose reply a later `$step:` reference uses (an id
    the fixture results do not give), or settles on a waitFor; an after step settles, reads (with the exact reply it
    expects, or equal to an earlier read but for its `except` pointers), replays the call, or restarts the daemon:
    each checks the state the call left."""
    if "agent" in spec and spec["agent"] not in TUNING_AGENTS:
        raise GenError(f"{where}: agent takes only {sorted(TUNING_AGENTS)}")
    requires = spec.get("requires", [])
    if not isinstance(requires, list) or not set(requires) <= TUNING_CAPABILITIES:
        raise GenError(f"{where}: requires takes only {sorted(TUNING_CAPABILITIES)}")
    switches = spec.get("switches", [])
    if not isinstance(switches, list) or len({json.dumps(name) for name in switches}) != len(switches):
        raise GenError(f"{where}: switches is a list of distinct switch names")
    unknown = [name for name in switches if not (isinstance(name, str) and name in daemon_switches())]
    if unknown:
        raise GenError(f"{where}: switches {unknown} are not switches the daemon reports "
                       f"(oracle-state: {sorted(daemon_switches())})")
    untested = spec.get("untested", [])
    if not isinstance(untested, list) or not all(isinstance(item, str) and item for item in untested):
        raise GenError(f"{where}: untested is a list of reasons")
    fixture = spec.get("fixture", [])
    if not isinstance(fixture, list) or not all(isinstance(item, str) and item in HANDLES for item in fixture):
        raise GenError(f"{where}: fixture is a list of fixture handles {sorted(HANDLES)}")
    checkpoint = spec.get("checkpoint", list(CALL_CHECKPOINTS))
    if checkpoint_problem(checkpoint):
        raise GenError(f"{where}: checkpoint {checkpoint_problem(checkpoint)}")
    taken = {step.id for step in FIXTURE} | {CALL_STEP, RETRY_STEP}
    reads: set = set()
    restarts = 0
    for part in ("before", "after"):
        steps = spec.get(part, [])
        if not isinstance(steps, list):
            raise GenError(f"{where}: {part} is a list of steps")
        for item in steps:
            keys = set(item) if isinstance(item, dict) else set()
            marker = next((marker for marker in TUNED_STEP_SHAPES if marker in keys), None)
            if "id" not in keys or marker is None or not keys <= TUNED_STEP_SHAPES[marker]:
                article = "an" if part == "after" else "a"
                raise GenError(f"{where}: {article} {part} step is one of {{id, restart, waitFor, checkpoint}}, "
                               f"{{id, replays, except}}, {{id, method, target, params, result | equals, except}}, "
                               f"{{id, waitFor}}, not {item!r}")
            step_id = item["id"]
            if not isinstance(step_id, str) or not STEP_ID.match(step_id) or step_id in taken:
                raise GenError(f"{where}: {part} step id {step_id!r} is not a new step id")
            taken.add(step_id)
            if "waitFor" in item:
                problem = wait_for_problem(item["waitFor"])
                if problem:
                    raise GenError(f"{where}: {part} step {step_id} waitFor {problem}")
            method = item.get("method")
            classes = STEP_CLASSES if part == "before" else frozenset({"read"})
            kind = catalog.operations.get(method, {}).get("class") if isinstance(method, str) else None
            if marker == "method" and kind not in classes:
                raise GenError(f"{where}: {part} step {step_id} calls {method!r}, not a "
                               f"{' or '.join(sorted(classes))} of the catalog")
            if "result" in item:
                if kind != "read":
                    raise GenError(f"{where}: {part} step {step_id} gives a result, which only a read checks")
                if "equals" in item:
                    raise GenError(f"{where}: {part} step {step_id} gives a result and equals: one reply check")
            if marker in ("restart", "replays") and part != "after":
                raise GenError(f"{where}: {part} step {step_id}: only an after step restarts or replays")
            if marker == "restart":
                if item["restart"] != "daemon":
                    raise GenError(f"{where}: {part} step {step_id} restarts {item['restart']!r}: only the daemon")
                if "checkpoint" in item and checkpoint_problem(item["checkpoint"]):
                    raise GenError(f"{where}: {part} step {step_id} checkpoint {checkpoint_problem(item['checkpoint'])}")
                restarts += 1
            if marker == "replays" and item["replays"] != "call":
                raise GenError(f"{where}: {part} step {step_id} replays {item['replays']!r}: only the call replays")
            if "equals" in item:
                if catalog.operations[method].get("class") != "read" or item["equals"] not in reads:
                    raise GenError(f"{where}: {part} step {step_id} equals {item['equals']!r}: a read equals an "
                                   f"earlier read step")
            if "except" in item:
                if marker == "method" and "equals" not in item:
                    raise GenError(f"{where}: {part} step {step_id}: except needs equals")
                pointers = item["except"]
                if not (isinstance(pointers, list) and pointers and all(isinstance(p, str) and EXCEPT_POINTER.match(p)
                                                                        for p in pointers)):
                    raise GenError(f"{where}: {part} step {step_id} except is a non-empty list of JSON pointers")
            if marker == "method" and catalog.operations[method].get("class") == "read":
                reads.add(step_id)
    if restarts and "restart" not in requires:
        raise GenError(f"{where}: a restart step requires the restart capability")
    crashes = spec.get("allow_crashes", [])
    if not isinstance(crashes, list):
        raise GenError(f"{where}: allow_crashes is a list of case-v1 allow_crashes entries")
    for entry in crashes:
        if (not isinstance(entry, dict) or not {"kind", "reason"} <= set(entry) <= ALLOW_CRASH_KEYS
                or entry["kind"] != "daemon" or not set(entry.get("steps", [])) <= taken):
            raise GenError(f"{where}: an allow_crashes entry is {{kind: daemon, reason, steps, max}} with steps of "
                           f"this case, not {entry!r}")
    ends = spec.get("ends")
    if ends is not None:
        if ends not in ENDS_PROCESSES:
            raise GenError(f"{where}: ends takes only {sorted(ENDS_PROCESSES)}")
        if "settled" in checkpoint:
            raise GenError(f"{where}: a call that ends the {ends} has no settled checkpoint")
        if not any(entry["kind"] == ends and "call" in entry.get("steps", []) for entry in crashes):
            raise GenError(f"{where}: a call that ends the {ends} needs an allow_crashes entry of kind {ends} "
                           f"that lists the call")


def checkpoint_problem(checkpoint: Any) -> Optional[str]:
    """Why `checkpoint` is not a step's list of daemon checkpoints (case-v1 step checkpoint, no turn), or None."""
    if (not isinstance(checkpoint, list) or not checkpoint or len(set(checkpoint)) != len(checkpoint)
            or not set(checkpoint) <= set(CALL_CHECKPOINTS)):
        return f"is a non-empty list of {list(CALL_CHECKPOINTS)}"
    return None


def daemon_switches() -> frozenset:
    """The switch names in the daemon's checked-in `oracle-state` readback."""
    try:
        state = json.loads(DAEMON_STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{DAEMON_STATE}: {error}") from None
    names = frozenset((state.get("oracle") or {}).get("switches") or {})
    bad = sorted(name for name in names if not SWITCH_NAME.match(name))
    if bad:
        raise GenError(f"{DAEMON_STATE}: switch names {bad} do not match case-v1 switches")
    return names


def check_expectations(where: str, expectations: Any, tasks: TaskGraph, family: str) -> None:
    """A kind's known failures: [{arm, results, reason}], one per arm, the reason naming a task that can still fix
    it (the rule of a gap)."""
    if not isinstance(expectations, list):
        raise GenError(f"{where}: expectations is a list of {{arm, results, reason}}")
    arms = []
    for item in expectations:
        if not (isinstance(item, dict) and set(item) == EXPECTATION_KEYS):
            raise GenError(f"{where}: an expectation is {{arm, results, reason}}, not {item!r}")
        if item["arm"] not in EXPECTATION_ARMS:
            raise GenError(f"{where}: expectation arm {item['arm']!r} is not one of {list(EXPECTATION_ARMS)}")
        if item["arm"] in arms:
            raise GenError(f"{where}: expectations give arm {item['arm']!r} more than once")
        arms.append(item["arm"])
        results = item["results"]
        if not (isinstance(results, list) and results and len(set(map(str, results))) == len(results)
                and set(results) <= set(EXPECTATION_RESULTS)):
            raise GenError(f"{where}: expectation results {results!r} are distinct results of "
                           f"{list(EXPECTATION_RESULTS)}")
    for item in expectations:
        problem = tasks.gap_problem(item["reason"], family)
        if problem:
            raise GenError(f"{where}: expectation reason {problem}")


def wait_for_problem(wait: Any) -> Optional[str]:
    """What case-v1 $defs/waitFor refuses in a tuned waitFor (tuned_step reads pointer and maxMs), or None."""
    if not isinstance(wait, dict):
        return "is an object {pointer, maxMs, equals | predicate}"
    extra = sorted(set(wait) - {"pointer", "maxMs", "equals", "predicate"})
    if extra:
        return f"takes no {extra}"
    pointer, max_ms = wait.get("pointer"), wait.get("maxMs")
    if not (isinstance(pointer, str) and pointer.startswith("/") and len(pointer) > 1):
        return f"pointer {pointer!r} is not a facet pointer"
    if not (isinstance(max_ms, int) and not isinstance(max_ms, bool) and 1 <= max_ms <= WAIT_MAX_MS):
        return f"maxMs {max_ms!r} is not an integer in 1..{WAIT_MAX_MS}"
    if ("equals" in wait) == ("predicate" in wait):
        return "takes exactly one of equals and predicate"
    predicate = wait.get("predicate")
    if "predicate" in wait and not (isinstance(predicate, str) and predicate in WAIT_PREDICATES) and not (
            isinstance(predicate, dict) and set(predicate) == {"op", "value"} and predicate["op"] in WAIT_OPS):
        return f"predicate {predicate!r} is not one of {sorted(WAIT_PREDICATES)} or {{op, value}}"
    return None


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


def repo_fixture(name: Any, where: str) -> Any:
    """The RepoFixture `name` names; make_repo.py refuses a fixture whose origin is not a bare repository
    beside the checkout, so every remote a case can reach is under the case root."""
    module = make_repo()
    try:
        return module.RepoFixture.load(name, REPO_FIXTURES)
    except module.FixtureError as error:
        raise GenError(f"{where}: repo: {error}") from None


def strings_in(value: Any, path: str) -> Iterable[Tuple[str, Any, str]]:
    """(path, value, key) of every value under `value`; key is the dict key that holds it, or ''."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield f"{path}.{key}", item, key
            yield from strings_in(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield f"{path}[{index}]", item, ""
            yield from strings_in(item, f"{path}[{index}]")


def repo_problems(request: Request) -> Iterable[str]:
    """What keeps the request off the network and inside its generated repository: a `remote` is a plain
    remote name of the case's repository (git_ops/push.rs resolves names among configured remotes only, and
    the fixture's only remote is its bare origin under the case root), never a URL or a path; a path under
    REPOS_ROOT is one of the case's repository folders."""
    folders = sorted(repo_fixture(request.repo, request.operation).tokens().values()) if request.repo else []
    parts = (("params", request.params), ("target", request.target),
             *((f"before.{step.get('id')}.params", step.get("params") or {}) for step in request.before))
    for part, value in parts:
        for where, item, key in strings_in(value, part):
            if key == "remote":
                if not (isinstance(item, str) and REMOTE_NAME.match(item)):
                    yield f"{where} {item!r} is not a configured remote's name: no URL, no path"
                elif not request.repo:
                    yield f"{where} names a remote, but the case has no generated repository (repo)"
            if isinstance(item, str) and (item == REPOS_ROOT or item.startswith(f"{REPOS_ROOT}/")):
                if ".." in item.split("/"):
                    yield f"{where} {item!r} leaves its folder"
                elif not any(item == folder or item.startswith(f"{folder}/") for folder in folders):
                    yield f"{where} {item!r} is in no folder of the case's repository {request.repo!r}"


def apply_tuning(request: Request, spec: Mapping[str, Any]) -> None:
    if "repo" in spec:
        request.repo = spec["repo"]
    if "before" in spec:
        request.before = [tuned_value(item) for item in spec["before"]]
    if "after" in spec:
        request.after = [tuned_value(item) for item in spec["after"]]
    if "requires" in spec:
        request.requires = list(spec["requires"])
    if "switches" in spec:
        request.switches = list(spec["switches"])
    if "untested" in spec:
        request.untested = list(spec["untested"])
    if "details" in spec:
        request.details = tuned_value(spec["details"])
    if "agent" in spec:
        request.agent = None if spec["agent"] == "none" else spec["agent"]
    if "expectations" in spec:
        request.expectations = copy.deepcopy(spec["expectations"])
    for part in ("fixture", "checkpoint"):
        if part in spec:
            setattr(request, part, list(spec[part]))
    if "ends" in spec:
        request.ends = spec["ends"]
    if "allow_crashes" in spec:
        request.allow_crashes = copy.deepcopy(spec["allow_crashes"])
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
    unretried: Dict[str, str] = {}
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
        # The after steps check what the success left; the error case asserts only what its own tuning says.
        broken_request.after = []
        apply_tuning(broken_request, error_tuning)
        problem = synth.check.params(operation, synth.concrete(wire_params(success), success.before_methods()))
        if problem is not None:
            raise GenError(f"{operation}: the success request fails the catalog check: {problem}")
        for request in (success, broken_request):
            for step in (*request.before, *request.after):
                if catalog.operations.get(step.get("method"), {}).get("class") == "read":
                    wire = synth.concrete({**SCOPE, **(step.get("target") or {}), **(step.get("params") or {})},
                                          request.before_methods())
                    problem = synth.check.params(step["method"], wire)
                    if problem is not None:
                        raise GenError(f"{operation}: read step {step['id']} fails the catalog check: {problem}")
        if broken and synth.check.params(operation, synth.concrete(wire_params(broken_request),
                                                                   broken_request.before_methods())) is None:
            raise GenError(f"{operation}: the error request passes the catalog check")
        for request in (success, broken_request):
            problem = next(iter(repo_problems(request)), None)
            if problem:
                raise GenError(f"{operation}: {problem}")
        ok_id, error_id = f"{name}-ok", f"{name}-error"
        if len(error_id) > 64:
            raise GenError(f"{operation}: case id {error_id} is longer than 64")
        error_note = tuned.get("error", {}).get("note") or (
            f"{broken['field']} breaks its catalog type ({broken['rule']}); the daemon's catalog check refuses it"
            if broken else f"tuned to {code}")
        # A tuned success case takes the operation over from KNOWN_GAPS; its own gap names the task that closes it.
        success_tuning = tuned.get("success", {})
        tuned_gap = "; ".join(filter(None, (success_tuning.get("gap"), success.repo and REPO_GAP))) or None
        gap = tuned_gap if "success" in tuned else known_gap(operation)
        files[f"{ok_id}.json"] = case_doc(ok_id, operation, family, "success", success, OK,
                                          success_tuning.get("note", "every required field from its catalog type"),
                                          catalog, tuned_gap or (gap and f"{gap}; {family}/{TUNING} tunes it"))
        files[f"{error_id}.json"] = case_doc(error_id, operation, family, "error", broken_request,
                                             {"outcome": "error", "error": code}, error_note, catalog)
        entry: Dict[str, Any] = {
            "family": family,
            "cases": {"success": f"{SUITE}/{ok_id}", "error": f"{SUITE}/{error_id}"},
            "fixture": [s["id"] for s in itertools.takewhile(lambda step: step["id"] != CALL_STEP,
                                                             files[f"{ok_id}.json"]["steps"])],
            "error": {"code": code, **(broken or {})},
            "placeholders": sorted(set(success.placeholders)),
        }
        if retried(catalog, operation):
            entry["retry"] = f"{SUITE}/{ok_id}/{RETRY_STEP}"
        elif operation in UNRETRIED:
            unretried[operation] = UNRETRIED[operation]
        if gap:
            entry["gap"] = gap
        if tuned:
            entry["tuned"] = sorted(tuned)
        requires = {kind: files[f"{case_id}.json"]["requires"] for kind, case_id in (("success", ok_id), ("error", error_id))}
        if any(caps != ["resource_api"] for caps in requires.values()):
            entry["requires"] = requires
        switches = {kind: files[f"{case_id}.json"].get("switches", [])
                    for kind, case_id in (("success", ok_id), ("error", error_id))}
        if any(switches.values()):
            entry["switches"] = switches
        expectations = {kind: request.expectations for kind, request in (("success", success), ("error", broken_request))
                        if request.expectations}
        for kind in expectations:
            if not switches[kind]:
                raise GenError(f"{operation}.{kind}: a known failure on an arm needs the switches the case runs on")
        if expectations:
            entry["expectations"] = expectations
        operations[operation] = entry
        if tuned_gap:
            excluded[operation] = tuned_gap
        elif entry["placeholders"] or gap:
            reasons = ([f"placeholders {', '.join(entry['placeholders'])}"] if entry["placeholders"] else []) + ([gap] if gap else [])
            excluded[operation] = f"{'; '.join(reasons)}: {FAMILY_TASK[family]} tunes the success case"
    total = len(operations)
    files[COVERAGE] = {
        "generator": GENERATOR,
        "catalog": "cmux-tui/spec/resource-operations-v2.json",
        "catalog_sha256": catalog.sha256,
        "suite": SUITE,
        "total": total,
        # Operations whose success case has no placeholder and no known or tuned gap. No case has a verdict
        # yet: driver_daemon.py on the VM gives the first one.
        "covered": total - len(excluded),
        "verdicts": "not run",
        # Success cases with a same-key retry step (I10): every operation with `idempotency: required` but those
        # in `unretried`, whose success ends the daemon.
        "retries": sum(1 for entry in operations.values() if "retry" in entry),
        "unretried": unretried,
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


# ------------------------------------------------------------------------------------------ expectations

# The success cases coverage excludes cannot pass until the task their reason names lands. Blink lists such a test
# in TestExpectations with its bug (third_party/blink/web_tests/TestExpectations, `crbug.com/N path [ Skip ]`), so
# a run counts it as expected, not as a failure. The generator owns one block of the suite's expectations file
# (expectations.py: tests/oracle/Expectations.d/<suite>.txt); lines outside the block are kept.
EXPECTATIONS_BEGIN_PREFIX = f"# BEGIN {GENERATOR}:"
EXPECTATIONS_BEGIN = (f"{EXPECTATIONS_BEGIN_PREFIX} the success cases coverage.json excludes, skipped until their task "
                      "lands, and the known failures the family tunings record on one arm")
EXPECTATIONS_END = f"# END {GENERATOR}"
EXPECTATIONS_HEADER = (f"# {SUITE} expectations (format: scripts/cmux-next/oracle/expectations.py).\n"
                       f"# {GENERATOR} writes the block below from coverage.json: edit the family\n"
                       "# tuning, not the block. Lines outside the block are kept.\n")


def expectations_path(out: Path) -> Path:
    """`<oracle root>/Expectations.d/<suite>.txt` for a suite directory `<oracle root>/corpus/<suite>`."""
    return out.parent.parent / "Expectations.d" / f"{SUITE}.txt"


def expectation_lines(coverage: Mapping[str, Any]) -> List[str]:
    """`<task> daemon-ops/<op>-ok [ Skip ]` per excluded operation; the task is the first one its reason names (a
    tuned gap's closing task, or the family task that tunes a placeholder). Then `<task> [ <arm> ] daemon-ops/<case>
    [ <results> ]` per tuned known failure, the task the first its reason names; an excluded success case has only
    its Skip line, which holds on every arm (expectations.py refuses two lines whose tags both match a run)."""
    keyed = []
    for operation, reason in coverage["excluded"].items():
        task = TASK_ID.search(reason)
        if task is None:
            raise GenError(f"{operation}: the exclusion reason names no task: {reason}")
        case = coverage["operations"][operation]["cases"]["success"]
        keyed.append(((case, ""), f"{task.group(0)} {case} [ Skip ]"))
    for operation, entry in coverage["operations"].items():
        for kind, known in sorted((entry.get("expectations") or {}).items()):
            if kind == "success" and operation in coverage["excluded"]:
                continue
            case = entry["cases"][kind]
            for item in known:
                task = TASK_ID.search(item["reason"])
                if task is None:
                    raise GenError(f"{operation}.{kind}: the expectation reason names no task: {item['reason']}")
                keyed.append(((case, item["arm"]),
                              f"{task.group(0)} [ {item['arm']} ] {case} [ {' '.join(item['results'])} ]"))
    return [line for _, line in sorted(keyed)]


def render_expectations(existing: str, lines: Sequence[str]) -> str:
    """`existing` with the generator's block replaced by `lines` (or appended, with a header for a new file)."""
    block = "\n".join([EXPECTATIONS_BEGIN, *lines, EXPECTATIONS_END]) + "\n"
    begin, end = existing.find(EXPECTATIONS_BEGIN_PREFIX), existing.find(EXPECTATIONS_END)
    if begin >= 0 and end > begin:
        tail = existing[end + len(EXPECTATIONS_END):]
        return existing[:begin] + block + (tail[1:] if tail.startswith("\n") else tail)
    if begin >= 0 or end >= 0:
        raise GenError(f"the {SUITE} expectations file has one of the generator's block markers without the other")
    if not existing.strip():
        return EXPECTATIONS_HEADER + block
    return existing + ("" if existing.endswith("\n") else "\n") + block


def expectations_drift(path: Path, coverage: Mapping[str, Any]) -> List[str]:
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    if existing != render_expectations(existing, expectation_lines(coverage)):
        return [f"{path.name}: the generated block differs from coverage.json"]
    return []


def write_expectations(path: Path, coverage: Mapping[str, Any]) -> bool:
    """Writes the block when it changed; True when the file was written."""
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    text = render_expectations(existing, expectation_lines(coverage))
    if text == existing:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return True


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


def _sibling_module(name: str) -> Any:
    """A sibling oracle script, for the self tests that check against it."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return __import__(name)

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
            ok = files["pane-swap-ok.json"]["steps"]
            self.assertEqual(next(step for step in ok if step["id"] == CALL_STEP)["note"], "swap with the split")
            self.assertEqual(generate(self.catalog, load_tuning(out, self.catalog)), files)

    def test_bad_tuning_is_refused(self) -> None:
        bad = [
            ({"operations": {"workspace.list": {}}}, "not a mutation"),
            ({"operations": {"tab.close": {}}}, "belongs to family tab"),
            ({"operations": {"pane.close": {"success": {"error": "selector.not_found"}}}}, "error is error only"),
            ({"operations": {"pane.close": {"success": {"details": {"extra": {}}}}}}, "details is error only"),
            ({"operations": {"pane.close": {"error": {"gap": "p15-oracle-204"}}}}, "gap is success only"),
            ({"operations": {"pane.close": {"success": {"gap": "later"}}}}, "names the task closing it"),
            ({"operations": {"pane.close": {"success": {"gap": "p15-oracle-999"}}}}, "not tasks of WORK.tsv"),
            # The layout family's task (066) depends on 060, which depends on 023: both are done when 066 lands.
            ({"operations": {"pane.close": {"success": {"gap": "follow-up to p15-oracle-023"}}}},
             "names \\['p15-oracle-023'\\], done before p15-oracle-066"),
            ({"operations": {"pane.close": {"success": {"gap": "p15-oracle-066 tunes it"}}}}, "done before p15-oracle-066"),
            # 204's files are the streams suite: it never edits the layout tuning, so it removes no layout gap.
            ({"operations": {"pane.close": {"success": {"gap": "p15-oracle-204 streams it"}}}},
             "none of whose WORK.tsv files take in tests/oracle/corpus/daemon-ops/layout/"),
            ({"operations": {"pane.close": {"error": {"details": {}}}}}, "details is a non-empty object"),
            ({"operations": {"pane.close": {"error": {"error": "home.pinned_first"}}}}, "not an error"),
            ({"operations": {"pane.close": {"retry": {}}}}, "takes only"),
            ({"rules": {}}, "unknown keys"),
            ({"operations": {"pane.close": {"success": {"requires": ["gui"]}}}}, "requires takes only"),
            ({"operations": {"pane.close": {"success": {"untested": [""]}}}}, "untested is a list"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "workspace.nope"}]}}}},
             "not a mutation or read of the catalog"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "conversation.events"}]}}}},
             "not a mutation or read of the catalog"),
            ({"operations": {"pane.close": {"success": {"agent": "real"}}}}, "agent takes only"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "browser.attach"}]}}}},
             "not a mutation or read of the catalog"),
            ({"operations": {"pane.close": {"success": {"after": [{"id": "x", "method": "pane.split"}]}}}},
             "after step x calls 'pane.split', not a read of the catalog"),
            ({"operations": {"pane.close": {"success": {"after": [{"id": "x", "method": "screen.get", "waitFor": {}}]}}}},
             "an after step is one of"),
            ({"operations": {"pane.close": {"success": {"after": {"id": "x"}}}}}, "after is a list of steps"),
            ({"operations": {"pane.close": {"success": {
                "before": [{"id": "x", "method": "screen.get"}],
                "after": [{"id": "x", "waitFor": {"pointer": "/daemon/session", "predicate": "exists", "maxMs": 1}}]}}}},
             "after step id 'x' is not a new step id"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "fx-workspace", "method": "pane.split"}]}}}},
             "not a new step id"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "call", "waitFor": {}}]}}}}, "not a new step id"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "waitFor": {}, "method": "pane.split"}]}}}},
             "a before step is"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x"}]}}}}, "a before step is"),
            ({"operations": {"pane.close": {"success": {"after": [{"id": "x", "read": "terminal.copy"}]}}}},
             "an after step is"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "pane.split", "result": {}}]}}}},
             "before step x gives a result, which only a read checks"),
            ({"operations": {"pane.close": {"success": {"after": [{"id": "x", "method": "terminal.copy", "waits": True}]}}}},
             "an after step is"),
            ({"operations": {"pane.close": {"success": {"before": [{"id": "x", "method": "pane.split"}],
                                                        "after": [{"id": "x", "method": "terminal.copy"}]}}}},
             "after step id 'x' is not a new step id"),
            ({"operations": {"pane.close": {"success": {"after": "x"}}}}, "after is a list of steps"),
            ({"operations": {"pane.close": {"success": {"switches": ["layer-hosting"]}}}},
             "switches \\['layer-hosting'\\] are not switches the daemon reports"),
            ({"operations": {"pane.close": {"success": {"expectations": {}}}}}, "expectations is a list"),
            ({"operations": {"pane.close": {"success": {"expectations": [{"arm": "new", "results": ["Failure"]}]}}}},
             "an expectation is \\{arm, results, reason\\}"),
            ({"operations": {"pane.close": {"success": {"expectations": [
                {"arm": "holder", "results": ["Failure"], "reason": "p15-oracle-245"}]}}}},
             "expectation arm 'holder' is not one of"),
            ({"operations": {"pane.close": {"success": {"expectations": [
                {"arm": "new", "results": ["Skip"], "reason": "p15-oracle-245"}]}}}}, "expectation results"),
            ({"operations": {"pane.close": {"success": {"expectations": [
                {"arm": "new", "results": ["Failure", "Failure"], "reason": "p15-oracle-245"}]}}}},
             "expectation results"),
            ({"operations": {"pane.close": {"success": {"expectations": [
                {"arm": "new", "results": ["Failure"], "reason": "later"}]}}}},
             "expectation reason is a reason that names the task closing it"),
            ({"operations": {"pane.close": {"error": {"expectations": [
                {"arm": "new", "results": ["Failure"], "reason": "p15-oracle-066"}]}}}},
             "expectation reason names \\['p15-oracle-066'\\], done before"),
            ({"operations": {"pane.close": {"success": {"expectations": [
                {"arm": "new", "results": ["Failure"], "reason": "p15-oracle-245"},
                {"arm": "new", "results": ["Crash"], "reason": "p15-oracle-245"}]}}}}, "more than once"),
            ({"operations": {"pane.close": {"success": {"switches": ["terminal-holder", "terminal-holder"]}}}},
             "switches is a list of distinct switch names"),
        ]
        # Credential-shaped values, built here so this file holds no literal key a secret scanner would flag.
        for kind, secret in (("an Anthropic API key", "sk-" + "ant-api03-" + "A" * 24),
                             ("an OpenAI API key", "sk-" + "proj-" + "a1" * 12),
                             ("a GitHub token", "gh" + "p_" + "B" * 36),
                             ("an AWS access key id", "AK" + "IA" + "C" * 16),
                             ("a Slack token", "xo" + "xb-" + "1" * 12),
                             ("a Google API key", "AI" + "za" + "D" * 35),
                             ("a bearer token", "Bear" + "er " + "e" * 20),
                             ("a private key", "-----BEGIN RSA PRIV" + "ATE KEY-----")):
            bad.append(({"operations": {"pane.close": {"success": {"params": {"pane": secret}}}}},
                        f"pane.close.success.params.pane holds {kind}"))
            bad.append(({"operations": {"pane.close": {"success": {"before": [
                {"id": "x", "method": "pane.split", "params": {"argv": ["/bin/sh", "-c", f"echo {secret}"]}}]}}}},
                f"pane.close.success.before\\[0\\].params.argv\\[2\\] holds {kind}"))
        live = {"pointer": "/daemon/session", "equals": "live", "maxMs": 100}
        for wait, message in (
                ({"pointer": "/daemon/session"}, "maxMs None is not an integer"),
                ({**live, "maxMs": 0}, "maxMs 0 is not an integer"),
                ({**live, "maxMs": 30001}, "maxMs 30001 is not an integer"),
                ({**live, "maxMs": True}, "maxMs True is not an integer"),
                ({**live, "pointer": ""}, "pointer '' is not a facet pointer"),
                ({**live, "pointer": "daemon/session"}, "pointer 'daemon/session' is not a facet pointer"),
                ({**live, "predicate": "exists"}, "takes exactly one of equals and predicate"),
                ({"pointer": "/daemon/session", "maxMs": 100}, "takes exactly one of equals and predicate"),
                ({"pointer": "/daemon/session", "maxMs": 100, "predicate": "live"}, "predicate 'live' is not one of"),
                ({"pointer": "/daemon/session", "maxMs": 100, "predicate": {"op": "eq", "value": 1}}, "predicate .* is not one of"),
                ({**live, "timeout": 1}, "takes no \\['timeout'\\]"),
                ("live", "is an object")):
            bad.append(({"operations": {"pane.close": {"success": {"before": [{"id": "w", "waitFor": wait}]}}}},
                        f"before step w waitFor {message}"))
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

    def test_a_gap_names_a_task_that_is_not_done_before_the_family_task(self) -> None:
        tasks = TaskGraph({"p15-oracle-070": ("p15-oracle-060",), "p15-oracle-060": ("p15-oracle-023",),
                           "p15-oracle-023": (), "p15-oracle-237": ("p15-oracle-023", "p15-oracle-070"),
                           "p14-energy-077b": (), "p15-oracle-204": (), "p15-oracle-205": ()},
                          {"p15-oracle-237": ("scripts/cmux-next/oracle/driver_daemon.py",
                                              "tests/oracle/corpus/daemon-ops/misc/"),
                           "p14-energy-077b": ("tests/oracle/corpus/daemon-ops/misc/_tuning.json",),
                           "p15-oracle-205": ("tests/oracle/",),
                           "p15-oracle-204": ("tests/oracle/corpus/streams/",)})
        self.assertEqual(tasks.done_before("p15-oracle-070"), {"p15-oracle-070", "p15-oracle-060", "p15-oracle-023"})
        for gap, problem in (
                ("p15-oracle-237 proves the key", None),
                ("after p14-energy-077b", None),
                ("p15-oracle-205 owns the whole corpus", None),
                ("p15-oracle-204 streams, then p15-oracle-237", None),
                ("p15-oracle-204 streams it", "names ['p15-oracle-204'], none of whose WORK.tsv files take in "
                                              "tests/oracle/corpus/daemon-ops/misc/, so none removes it"),
                ("p15-oracle-237, then p15-oracle-023", "names ['p15-oracle-023'], done before p15-oracle-070 lands, "
                                                        "so they close nothing"),
                ("p15-oracle-070", "names ['p15-oracle-070'], done before p15-oracle-070 lands, so they close nothing"),
                ("p15-oracle-238", "names ['p15-oracle-238'], not tasks of WORK.tsv"),
                ("a later task", "is a reason that names the task closing it"),
                (None, "is a reason that names the task closing it")):
            with self.subTest(gap=gap):
                self.assertEqual(tasks.gap_problem(gap, "misc"), problem)
        # The corpus's own gaps name tasks of the real WORK.tsv.
        work = TaskGraph.load()
        self.assertIn("p15-oracle-237", work.depends_on)
        self.assertTrue(work.owns("p15-oracle-237", "tests/oracle/corpus/daemon-ops/misc/"))
        self.assertIn("p15-oracle-023", work.done_before("p15-oracle-070"))

    def test_before_steps_requires_and_untested_shape_the_case(self) -> None:
        wait = {"pointer": "/daemon/session/browsers/0/status", "equals": "live", "maxMs": 15000}
        tuned = {"browser.back": {
            "success": {"requires": ["chromium"], "untested": ["why"],
                        "before": [{"id": "wait-live", "waitFor": wait},
                                   {"id": "nav", "method": "browser.navigate", "target": {"browser": {"$fixture": "browser"}},
                                    "params": {"url": "data:text/html,o"}}]},
            "error": {"requires": [], "before": [], "untested": [], "target": {"browser": {"$fixture": "app_browser"}},
                      "error": "operation.failed"}}}
        files = generate(self.catalog, tuned)
        ok, bad = files["browser-back-ok.json"], files["browser-back-error.json"]
        self.assertEqual([s["id"] for s in ok["steps"]],
                         ["fx-workspace", "fx-browser", "wait-live", "nav", "call", "retry"])
        self.assertEqual(ok["steps"][2], {"id": "wait-live", "op": "settle", "waitFor": wait, "settleMaxMs": 15000})
        self.assertEqual(ok["steps"][3]["target"]["browser"], "$step:fx-browser#/value/browser_id")
        self.assertEqual(ok["steps"][3]["args"]["idempotencyKey"], "browser-back-ok.nav")
        self.assertEqual(ok["requires"], ["resource_api", "chromium"])
        self.assertIn(ENGINE_PRECONDITION, ok["preconditions"])
        self.assertEqual(ok["untested"], ["why"])
        # The error case resets what it does not share: no engine, no wait, the app-drawn fixture browser only.
        self.assertEqual([s["id"] for s in bad["steps"]], ["fx-workspace", "fx-browser-profile", "fx-app-browser", "call"])
        self.assertEqual((bad["requires"], "untested" in bad), (["resource_api"], False))
        self.assertNotIn(ENGINE_PRECONDITION, bad["preconditions"])
        self.assertEqual(files[COVERAGE]["operations"]["browser.back"]["requires"],
                         {"success": ["resource_api", "chromium"], "error": ["resource_api"]})
        self.assertNotIn("requires", files[COVERAGE]["operations"]["browser.reload"])

    def test_after_steps_check_the_success_and_the_error_case_drops_them(self) -> None:
        settle = {"id": "printed", "waitFor": {"pointer": "/daemon/session/terminals/0/title", "equals": "x", "maxMs": 100}}
        read = {"id": "screen", "method": "terminal.copy", "target": {"pane": "$step:split#/value/pane_id",
                                                                      "terminal": {"$fixture": "terminal"}},
                "params": {"mode": "screen"}, "result": {"mode": "screen", "text": "x"}}
        split = {"id": "split", "method": "pane.split", "target": {"pane": {"$fixture": "pane"}},
                 "params": {"direction": "right"}}
        files = generate(self.catalog, {"terminal.move": {
            "success": {"switches": ["terminal-holder"], "before": [split],
                        "params": {"destination_pane": "$step:split#/value/pane_id"}, "after": [settle, read]},
            "error": {"before": [], "params": {"destination_pane": "pane_" + "0" * 32}, "error": "selector.not_found"}}})
        ok, bad = files["terminal-move-ok.json"], files["terminal-move-error.json"]
        self.assertEqual([s["id"] for s in ok["steps"]], ["fx-workspace", "split", "call", "printed", "screen", "retry"])
        # A read is readOnly, takes no idempotency key and expects its exact reply.
        self.assertEqual(ok["steps"][-2], {
            "id": "screen", "op": "resource.call",
            "target": {**SCOPE, "pane": "$step:split#/value/pane_id", "terminal": "$step:fx-workspace#/value/terminal_id"},
            "readOnly": True, "args": {"method": "terminal.copy", "params": {"mode": "screen"}},
            "expect": {"outcome": "ok", "result": {"mode": "screen", "text": "x"}}})
        self.assertEqual(ok["switches"], ["terminal-holder"])
        # The error case keeps the switches of the success case it starts from, not its after steps.
        self.assertEqual([s["id"] for s in bad["steps"]], ["fx-workspace", "call"])
        self.assertEqual(bad["switches"], ["terminal-holder"])
        entry = files[COVERAGE]["operations"]["terminal.move"]
        self.assertEqual(entry["fixture"], ["fx-workspace", "split"])
        self.assertEqual(entry["switches"], {"success": ["terminal-holder"], "error": ["terminal-holder"]})
        # A `$step:` reference to a tuning step is typed from that step's result for the catalog check.
        self.assertEqual(self.synth.concrete("$step:split#/value/pane_id", {"split": "pane.split"}), resource_id("pane"))
        # An error case that drops the step its inherited params refer to (the request check runs on the success).
        with self.assertRaisesRegex(GenError, "terminal-move-error: step call refers to \\['split'\\], no earlier step"):
            generate(self.catalog, {"terminal.move": {
                "success": {"before": [split], "params": {"destination_pane": "$step:split#/value/pane_id"}},
                "error": {"before": [], "params": {"index": 7}, "error": "selector.not_found"}}})
        with self.assertRaisesRegex(GenError, "read step screen fails the catalog check: .*mode"):
            generate(self.catalog, {"terminal.move": {"success": {"after": [
                {**read, "target": {"terminal": {"$fixture": "terminal"}}, "params": {"mode": "pixels"}}]}}})

    def test_the_terminal_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/terminal/_tuning.json (p15-oracle-065): the 9 terminal mutations, each case on
        both arms of the terminal-holder switch. Each success case checks its effect after the call: the exact screen
        (a readOnly terminal.copy, read only after a settle on the title the program prints last) or the exit record,
        except terminal.viewport.scroll, whose view offset no read returns: a gap (p15-oracle-246) excludes it and its
        screen read checks only that the terminal did not change. Each error case asserts a typed refusal and runs
        none of the success case's checks. Every case records its known holder-arm failure (I6, p15-oracle-245)."""
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        coverage = files[COVERAGE]
        terminal = sorted(op for op in self.catalog.mutations() if family_of(op) == "terminal")
        self.assertEqual(len(terminal), 9)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "terminal"), terminal)
        codes = {}
        unchecked = "terminal.viewport.scroll"
        self.assertEqual(sorted(op for op in coverage["excluded"] if family_of(op) == "terminal"), [unchecked])
        self.assertIn("p15-oracle-246", coverage["excluded"][unchecked])
        holder = [{"arm": "new", "results": ["Failure"], "reason": tuning["terminal.close"]["success"]["expectations"][0]["reason"]}]
        self.assertIn("p15-oracle-245", holder[0]["reason"])
        lines = expectation_lines(coverage)
        for operation in terminal:
            entry = coverage["operations"][operation]
            self.assertEqual(entry["placeholders"], [], operation)
            # The error case inherits the success case's known failure: both run on the holder arm.
            self.assertEqual(entry["expectations"], {"success": holder, "error": holder}, operation)
            for kind in ("success", "error"):
                failure = f"p15-oracle-245 [ new ] {entry['cases'][kind]} [ Failure ]"
                self.assertEqual(failure in lines, not (kind == "success" and operation == unchecked), failure)
            codes[operation] = entry["error"]["code"]
            for kind in ("success", "error"):
                name = entry["cases"][kind].split("/", 1)[1] + ".json"
                case = files[name]
                self.assertEqual(normalize.validate(case, schema), [], name)
                self.assertEqual(checks.check_case(case, rules), [], name)
                self.assertEqual(case["switches"], ["terminal-holder"], name)
                if kind == "success" and operation == unchecked:
                    self.assertEqual(case["untested"], [coverage["excluded"][unchecked]], name)
                else:
                    self.assertNotIn("untested", case, name)
                ids = [step["id"] for step in case["steps"]]
                after = case["steps"][ids.index("call") + 1:]
                self.assertEqual(after != [], kind == "success", name)
                for index, step in enumerate(case["steps"]):
                    if step.get("readOnly"):
                        # A screen read follows a settle (or another read): no output can move the facet.
                        previous = case["steps"][index - 1]
                        self.assertTrue(previous["op"] == "settle" or previous.get("readOnly")
                                        or previous["id"] == "call", f"{name} {step['id']}")
                        self.assertNotIn("idempotencyKey", step["args"], name)
                        self.assertIn("result", step["expect"], name)
                if kind == "success":
                    self.assertTrue(any(s.get("readOnly") or s["op"] == "settle" for s in after), name)
        self.assertEqual(codes, {
            "terminal.close": "revision.conflict", "terminal.history.clear": "selector.wrong_parent",
            "terminal.input.focus": ERROR_CODE, "terminal.input.keys": ERROR_CODE, "terminal.input.mouse": ERROR_CODE,
            "terminal.input.write": "selector.not_found", "terminal.move": "selector.not_found",
            "terminal.project": "selector.not_found", "terminal.viewport.scroll": ERROR_CODE})
        # The exit record of the keys success: exit 7 typed into the shell.
        keys = files["terminal-input-keys-ok.json"]["steps"][-2]
        self.assertEqual(keys["waitFor"]["equals"], {"kind": "exit", "code": 7})
        # The move and project destination is a split of the fixture pane that prints nothing.
        for name in ("terminal-move-ok.json", "terminal-project-ok.json"):
            split = next(s for s in files[name]["steps"] if s["id"] == "split")
            self.assertEqual(split["args"]["params"]["argv"], ["/bin/sleep", "600"], name)
            self.assertNotIn("fx-split", [s["id"] for s in files[name]["steps"]], name)
        self.assertIn(f"p15-oracle-246 {coverage['operations'][unchecked]['cases']['success']} [ Skip ]", lines)
        self.assertEqual(drift(DEFAULT_OUT, files), [])
        self.assertEqual(expectations_drift(expectations_path(DEFAULT_OUT), coverage), [])

    def test_a_known_failure_on_an_arm_is_an_expectation_line(self) -> None:
        known = {"arm": "new", "results": ["Failure", "Timeout"], "reason": "the holder lingers (p15-oracle-245)"}
        files = generate(self.catalog, {"terminal.close": {
            "success": {"switches": ["terminal-holder"], "expectations": [known]},
            "error": {"expectations": []}}})
        coverage = files[COVERAGE]
        self.assertEqual(coverage["operations"]["terminal.close"]["expectations"], {"success": [known]})
        self.assertEqual(coverage["covered"], self.files[COVERAGE]["covered"])
        lines = expectation_lines(coverage)
        self.assertIn("p15-oracle-245 [ new ] daemon-ops/terminal-close-ok [ Failure Timeout ]", lines)
        self.assertFalse([line for line in lines if "terminal-close-error" in line])
        # The lines parse, and the known failure holds on the new arm only.
        expectations_module = _sibling_module("expectations")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Expectations.d"
            root.mkdir()
            (root / f"{SUITE}.txt").write_text(render_expectations("", lines), encoding="utf-8")
            parsed = expectations_module.Expectations.load([root], [])
            self.assertEqual(parsed.diagnostics, [])
            for arm, wanted in (("new", {"Failure", "Timeout"}), ("old", {"Pass"})):
                config = expectations_module.RunConfig(arm=arm)
                self.assertEqual(set(parsed.resolve(SUITE, "terminal-close-ok", config).outcomes), wanted, arm)
        # An excluded success case has only its Skip line: a second line on its target would overlap on that arm.
        gap = {"gap": "no readback yet (p15-oracle-246)"}
        excluded = expectation_lines(generate(self.catalog, {"terminal.close": {
            "success": {"switches": ["terminal-holder"], "expectations": [known], **gap}}})[COVERAGE])
        self.assertEqual([line for line in excluded if "terminal-close-" in line], [
            "p15-oracle-245 [ new ] daemon-ops/terminal-close-error [ Failure Timeout ]",
            "p15-oracle-246 daemon-ops/terminal-close-ok [ Skip ]"])
        # A known failure on an arm needs the switches the case runs on.
        with self.assertRaisesRegex(GenError, "terminal.close.success: a known failure on an arm needs the switches"):
            generate(self.catalog, {"terminal.close": {"success": {"expectations": [known]}}})

    def test_a_well_formed_wait_for_passes(self) -> None:
        for wait in ({"pointer": "/daemon/session", "equals": "live", "maxMs": 1},
                     {"pointer": "/daemon/session", "predicate": "nonEmpty", "maxMs": 30000},
                     {"pointer": "/daemon/session", "predicate": {"op": "gte", "value": 1}, "maxMs": 5}):
            with self.subTest(wait=wait):
                self.assertIsNone(wait_for_problem(wait))
                check_tuned_steps("x", {"before": [{"id": "w", "waitFor": wait}]}, self.catalog)

    def test_a_tuned_gap_excludes_the_operation_and_details_reach_the_error_case(self) -> None:
        gap = "no product attaches a provider yet (p15-oracle-204)"
        details = {"extra": {"code": "browser_rendered_by_app", "tab_id": {"$fixture": "app_browser_tab"}}}
        tuned = {"browser.reload": {"success": {"gap": gap},
                                    "error": {"target": {"browser": {"$fixture": "app_browser"}},
                                              "error": "operation.failed", "details": details}}}
        files = generate(self.catalog, tuned)
        coverage = files[COVERAGE]
        self.assertEqual(coverage["excluded"]["browser.reload"], gap)
        self.assertEqual(coverage["operations"]["browser.reload"]["gap"], gap)
        self.assertEqual(coverage["covered"], self.files[COVERAGE]["covered"] - 1)
        self.assertEqual(files["browser-reload-ok.json"]["untested"], [gap])
        bad = files["browser-reload-error.json"]
        self.assertEqual(bad["steps"][-1]["expect"], {
            "outcome": "error", "error": "operation.failed",
            "errorDetails": {"extra": {"code": "browser_rendered_by_app",
                                       "tab_id": "$step:fx-app-browser#/value/tab_id"}}})
        self.assertIn("fx-app-browser", [s["id"] for s in bad["steps"]])
        self.assertNotIn("errorDetails", files["browser-reload-ok.json"]["steps"][-1]["expect"])

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
        self.assertEqual([s["id"] for s in ok["steps"]], ["fx-workspace", "split", "settled", "group", "call", "retry"])
        self.assertEqual(ok["steps"][1]["target"]["pane"], "$step:fx-workspace#/value/pane_id")
        self.assertEqual(ok["steps"][1]["args"]["idempotencyKey"], "sidebar-group-ungroup-ok.split")
        self.assertEqual(ok["steps"][1]["expect"], OK)
        self.assertEqual(ok["steps"][2], {"id": "settled", "op": "settle", "waitFor": wait, "settleMaxMs": 15000})
        self.assertEqual(ok["steps"][-1]["args"]["params"], {"id": "itm_g"})
        # The error case starts from the tuned success case; an empty before drops the steps (and their fixture).
        self.assertEqual([s["id"] for s in bad["steps"]], ["call"])
        self.assertEqual(bad["steps"][-1]["args"]["params"], {"id": "itm_home"})
        self.assertEqual(bad["steps"][-1]["expect"], {"outcome": "error", "error": ERROR_CODE})

    def test_after_steps_assert_what_the_call_left_and_a_read_gives_ids(self) -> None:
        layout = "/daemon/session/screens/0/layout"
        tuned = {"pane.split_ratio.set": {
            "success": {"before": [{"id": "read-layout", "method": "screen.get", "target": {"screen": {"$fixture": "screen"}}}],
                        "params": {"split_id": "$step:read-layout#/layout/root/split_id", "ratio": 0.25},
                        "after": [{"id": "ratio", "waitFor": {"pointer": f"{layout}/root/ratio", "equals": 0.25, "maxMs": 5}},
                                  {"id": "kept", "waitFor": {"pointer": f"{layout}/root/second/pane_id",
                                                             "equals": {"$fixture": "other_pane"}, "maxMs": 5}}]},
            "error": {"error": "operation.failed", "params": {"split_id": "split_0123456789abcdef0123456789abcdef"},
                      "after": [{"id": "ratio-kept", "waitFor": {"pointer": f"{layout}/root/ratio", "equals": 0.5,
                                                                 "maxMs": 5}}]}}}
        files = generate(self.catalog, tuned)
        ok, bad = files["pane-split-ratio-set-ok.json"], files["pane-split-ratio-set-error.json"]
        # A fixture handle in an after step pulls its fixture step in; after steps follow the call.
        self.assertEqual([s["id"] for s in ok["steps"]],
                         ["fx-workspace", "fx-split", "read-layout", "call", "ratio", "kept", "retry"])
        # A read is a readOnly step with no idempotency key (reads forbid one) and no receipt.
        self.assertEqual(ok["steps"][2], {
            "id": "read-layout", "op": "resource.call",
            "target": {**SCOPE, "screen": "$step:fx-workspace#/value/screen_id"},
            "args": {"method": "screen.get", "params": {}}, "readOnly": True, "expect": {"outcome": "ok"}})
        self.assertEqual(ok["steps"][5], {"id": "kept", "op": "settle", "settleMaxMs": 5, "waitFor": {
            "pointer": f"{layout}/root/second/pane_id", "equals": "$step:fx-split#/value/pane_id", "maxMs": 5}})
        # The error case keeps the before steps but asserts only its own after steps.
        self.assertEqual([s["id"] for s in bad["steps"]], ["fx-workspace", "read-layout", "call", "ratio-kept"])
        self.assertEqual(files[COVERAGE]["operations"]["pane.split_ratio.set"]["fixture"],
                         ["fx-workspace", "fx-split", "read-layout"])
        self.assertNotIn("pane.split_ratio.set", files[COVERAGE]["excluded"])

    def test_a_step_reference_to_a_before_call_is_checked_as_its_result_type(self) -> None:
        steps = {"read-layout": "screen.get", "make": "pane.split"}
        self.assertEqual(self.synth.concrete("$step:read-layout#/layout/root/split_id", steps), resource_id("split"))
        self.assertEqual(self.synth.concrete(["$step:make#/value/screen_id"], steps), [resource_id("screen")])
        # References to steps that are not before calls (the fixture, the call) stay as they are.
        self.assertEqual(self.synth.concrete("$step:call#/value/pane_id", steps), "$step:call#/value/pane_id")
        with self.assertRaisesRegex(GenError, "/layout/nothing is not in the result type of screen.get"):
            self.synth.concrete("$step:read-layout#/layout/nothing", steps)
        tuned = {"pane.split_ratio.set": {"success": {"params": {"split_id": "$step:fx-split#/value/pane_id"}}}}
        with self.assertRaisesRegex(GenError, "fails the catalog check"):
            generate(self.catalog, tuned)

    def test_after_steps_restart_replay_and_step_references_shape_the_case(self) -> None:
        wait = {"pointer": "/daemon/session/terminals/0/lifecycle", "equals": "running", "maxMs": 15000}
        tuned = {"session.journal.segment.seal": {
            "success": {"fixture": ["terminal"], "requires": ["restart"],
                        "before": [{"id": "cp", "method": "session.journal.checkpoint.create"}],
                        "params": {"through_sequence": "$step:cp#/value/source_sequence"},
                        "after": [{"id": "segs", "method": "session.journal.segment.list"},
                                  {"id": "restart", "restart": "daemon", "waitFor": wait},
                                  {"id": "segs-again", "method": "session.journal.segment.list", "equals": "segs",
                                   "except": ["/segments/*/sealed_at_ms"]},
                                  {"id": "again", "replays": "call", "except": ["/generation", "/replayed"]},
                                  {"id": "ws", "method": "workspace.get",
                                   "target": {"workspace": {"$fixture": "workspace"}}}]},
            "error": {"fixture": [], "before": [], "requires": []}},
            "session.shutdown": {"success": {
                "checkpoint": ["before"], "ends": "daemon", "requires": ["restart"],
                "after": [{"id": "restart", "restart": "daemon", "checkpoint": ["settled"]}],
                "allow_crashes": [{"kind": "daemon", "reason": "the call stops the daemon on purpose",
                                   "steps": ["call"]}]},
                "error": {"ends": None, "checkpoint": ["before", "settled"], "allow_crashes": [], "requires": []}}}
        files = generate(self.catalog, tuned)
        ok, bad = files["session-journal-segment-seal-ok.json"], files["session-journal-segment-seal-error.json"]
        steps = {step["id"]: step for step in ok["steps"]}
        self.assertEqual(list(steps), ["fx-workspace", "cp", "call", "segs", "restart", "segs-again", "again", "ws",
                                       "retry"])
        self.assertEqual(steps["call"]["args"]["params"], {"through_sequence": "$step:cp#/value/source_sequence"})
        self.assertEqual(steps["restart"], {"id": "restart", "op": "restart", "target": {"process": "daemon"},
                                            "expect": {"outcome": "ok", "receipt": "identify"},
                                            "checkpoint": ["before", "settled"], "waitFor": wait})
        self.assertEqual(steps["segs"], {"id": "segs", "op": "resource.call", "target": SCOPE,
                                         "args": {"method": "session.journal.segment.list", "params": {}},
                                         "readOnly": True, "expect": {"outcome": "ok"}})
        self.assertEqual(steps["segs-again"]["expect"], {"outcome": "ok", "result": "$step:segs#",
                                                         "resultExcept": ["/segments/*/sealed_at_ms"]})
        self.assertNotIn("idempotencyKey", steps["segs-again"]["args"])
        # The replay is the call again, with the call's idempotency key, held equal to the call's reply.
        self.assertEqual(steps["again"]["args"], steps["call"]["args"])
        self.assertEqual(steps["again"]["expect"], {"outcome": "ok", "receipt": "mutation_result",
                                                    "result": "$step:call#", "resultExcept": ["/generation", "/replayed"]})
        self.assertEqual(steps["ws"]["target"]["workspace"], "$step:fx-workspace#/value/workspace_id")
        self.assertEqual(ok["requires"], ["resource_api", "restart"])
        self.assertIn("segs-again, again reply what the step each names replied, but for the pointers its "
                      "resultExcept lists", ok["invariants"])
        self.assertEqual(files[COVERAGE]["operations"]["session.journal.segment.seal"]["fixture"], ["fx-workspace", "cp"])
        # The error case drops the after steps; its tuning resets the fixture and the before call.
        self.assertEqual([s["id"] for s in bad["steps"]], ["call"])
        shutdown, refused = files["session-shutdown-ok.json"], files["session-shutdown-error.json"]
        call = next(step for step in shutdown["steps"] if step["id"] == "call")
        self.assertEqual((call["ends"], call["checkpoint"]), ("daemon", ["before"]))
        self.assertEqual(shutdown["steps"][-1]["checkpoint"], ["settled"], "no daemon runs at the restart's before")
        self.assertEqual(shutdown["allow_crashes"][0]["steps"], ["call"])
        self.assertNotIn("ends", refused["steps"][-1])
        self.assertNotIn("allow_crashes", refused)
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        for case in (ok, bad, shutdown, refused):
            self.assertEqual(normalize.validate(case, schema), [], case["id"])
            self.assertEqual(checks.check_case(case, rules), [], case["id"])

    def test_bad_after_steps_are_refused(self) -> None:
        wait = {"pointer": "/daemon/session/terminals/0/lifecycle", "equals": "running", "maxMs": 1}
        restart = {"id": "r", "restart": "daemon"}
        stop = {"kind": "daemon", "reason": "the call stops the daemon", "steps": ["call"]}
        bad = [
            ({"before": [restart], "requires": ["restart"]}, "only an after step restarts or replays"),
            ({"before": [{"id": "x", "replays": "call"}]}, "only an after step restarts or replays"),
            ({"after": [{"id": "r", "restart": "app"}], "requires": ["restart"]}, "only the daemon"),
            ({"after": [{"id": "r", "restart": "daemon", "checkpoint": ["turn"]}], "requires": ["restart"]},
             "checkpoint is a non-empty list"),
            ({"after": [restart]}, "requires the restart capability"),
            ({"after": [{"id": "x", "replays": "fx-workspace"}]}, "only the call replays"),
            ({"after": [{"id": "x", "method": "session.get", "equals": "y"}]}, "a read equals an earlier read step"),
            ({"before": [{"id": "y", "method": "session.open"}], "after": [{"id": "x", "method": "session.get", "equals": "y"}]},
             "a read equals an earlier read step"),
            ({"after": [{"id": "y", "method": "session.get"}, {"id": "x", "method": "session.get", "equals": "y",
                                                               "result": {}}]},
             "gives a result and equals"),
            ({"after": [{"id": "x", "method": "session.get", "except": ["/a"]}]}, "except needs equals"),
            ({"after": [{"id": "y", "method": "session.get"},
                        {"id": "x", "method": "session.get", "equals": "y", "except": ["a"]}]},
             "except is a non-empty list of JSON pointers"),
            ({"after": [{"id": "x", "method": "session.get", "waitFor": wait}]}, "an after step is one of"),
            ({"after": [{"id": "call", "method": "session.get"}]}, "not a new step id"),
            ({"fixture": ["nowhere"]}, "fixture is a list of fixture handles"),
            ({"checkpoint": ["turn"]}, "checkpoint is a non-empty list"),
            ({"checkpoint": []}, "checkpoint is a non-empty list"),
            ({"allow_crashes": [{"kind": "renderer", "reason": "not the daemon"}]}, "an allow_crashes entry is"),
            ({"allow_crashes": [{"kind": "daemon", "reason": "a step it lacks", "steps": ["gone"]}]},
             "an allow_crashes entry is"),
            ({"ends": "holder", "checkpoint": ["before"], "allow_crashes": [stop]}, "ends takes only"),
            ({"ends": "daemon", "allow_crashes": [stop]}, "has no settled checkpoint"),
            ({"ends": "daemon", "checkpoint": ["before"]}, "needs an allow_crashes entry"),
        ]
        for spec, message in bad:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                (out / "session").mkdir()
                (out / "session" / TUNING).write_text(json.dumps({"operations": {"session.open": {"success": spec}}}),
                                                      encoding="utf-8")
                with self.assertRaisesRegex(GenError, message):
                    load_tuning(out, self.catalog)

    def test_the_session_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/session/_tuning.json (p15-oracle-063): every session success case restarts
        the daemon gracefully on the same root after the operation (session.shutdown is that stop itself, a call that
        ends the daemon) and then reads the same durable lists and session.snapshot, each equal to its read before
        (the snapshot but for what a new daemon generation changes), and gets the fixture workspace, pane, tab and
        terminal by their ids from before the restart. The error cases stay the catalog-type refusal."""
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        session = sorted(op for op in self.catalog.mutations() if family_of(op) == "session")
        self.assertEqual(len(session), 11)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "session"), session)
        for operation in session:
            entry = files[COVERAGE]["operations"][operation]
            ok = files[entry["cases"]["success"].split("/", 1)[1] + ".json"]
            bad = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]
            ids = [step["id"] for step in ok["steps"]]
            steps = {step["id"]: step for step in ok["steps"]}
            with self.subTest(operation=operation):
                self.assertEqual(steps["call"]["args"]["method"], operation)
                self.assertIn("restart", ok["requires"])
                self.assertLess(ids.index("call"), ids.index("restart"))
                self.assertEqual(steps["restart"]["waitFor"]["pointer"], "/daemon/session/terminals/0/lifecycle")
                compared = [step for step in ok["steps"] if "result" in step["expect"]]
                self.assertGreaterEqual({step["args"]["method"] for step in compared},
                                        {"workspace.list", "pane.list", "tab.list", "session.snapshot"})
                for step in compared:
                    earlier = steps[step["expect"]["result"][len("$step:"):-1]]
                    self.assertEqual(earlier["args"]["method"], step["args"]["method"])
                    self.assertLess(ids.index(earlier["id"]), ids.index("restart"))
                    self.assertGreater(ids.index(step["id"]), ids.index("restart"))
                self.assertEqual(steps["snapshot-after"]["expect"]["resultExcept"],
                                 ["/cursor", "/session/generation", "/session/revision",
                                  "/terminals/*/stream_revision", "/terminals/*/extra"])
                for kind in ("workspace", "pane", "tab", "terminal"):
                    get = steps[f"{kind}-get"]
                    self.assertGreater(ids.index(get["id"]), ids.index("restart"))
                    self.assertTrue(get["target"][kind].startswith("$step:fx-workspace#/value/"))
                self.assertEqual(entry["placeholders"], [])
                self.assertNotIn(operation, files[COVERAGE]["excluded"])
                self.assertEqual(([s["id"] for s in bad["steps"]], bad["requires"]), (["call"], ["resource_api"]))
                self.assertEqual(bad["steps"][-1]["expect"], {"outcome": "error", "error": ERROR_CODE})
                self.assertNotIn("ends", bad["steps"][-1])
        hooks = {step["id"]: step for step in files["session-journal-hook-put-ok.json"]["steps"]}
        self.assertEqual(hooks["hooks-after"]["expect"], {"outcome": "ok", "result": "$step:hooks-before#",
                                                          "resultExcept": ["/hooks/*/cursor"]})
        for name in ("session-terminal-defaults-update-ok", "session-window-title-set-ok",
                     "session-window-title-clear-ok"):
            replay = next(step for step in files[f"{name}.json"]["steps"] if step["id"] == "call-replayed")
            self.assertEqual(replay["expect"]["result"], "$step:call#", name)
        stop = files["session-shutdown-ok.json"]
        steps = {step["id"]: step for step in stop["steps"]}
        self.assertEqual((steps["call"]["ends"], steps["call"]["checkpoint"]), ("daemon", ["before"]),
                         "a stopped daemon has no settled snapshot")
        self.assertEqual(steps["restart"]["checkpoint"], ["settled"], "no daemon runs at the restart's before point")
        self.assertEqual([entry["steps"] for entry in stop["allow_crashes"]], [["call"]])
        self.assertNotIn("allow_crashes", files["session-open-ok.json"])
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        for name, case in files.items():
            if name.startswith("session-"):
                self.assertEqual(normalize.validate(case, schema), [], name)
                self.assertEqual(checks.check_case(case, rules), [], name)

    def test_the_layout_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/layout/_tuning.json (p15-oracle-066): the 25 pane, column, layout, screen
        and screen_group mutations. Every case ends with settle steps whose waitFor asserts the split tree (or the
        screens and groups) the call left: the change on success, the unchanged tree after a refusal. Every error
        is the daemon's own refusal with its details, not the catalog check's broken field, except the confirmation
        an undo that closes a pane needs. All 25 are covered."""
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        coverage = files[COVERAGE]
        layout = sorted(op for op in self.catalog.mutations() if family_of(op) == "layout")
        self.assertEqual(len(layout), 25)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "layout"), layout)
        for operation in layout:
            entry = coverage["operations"][operation]
            self.assertNotIn(operation, coverage["excluded"], operation)
            self.assertEqual((entry["placeholders"], entry["tuned"]), ([], ["error", "success"]), operation)
            for kind in ("success", "error"):
                steps = files[entry["cases"][kind].split("/", 1)[1] + ".json"]["steps"]
                ids = [step["id"] for step in steps]
                after = [step for step in steps[ids.index(CALL_STEP) + 1:] if step["id"] != RETRY_STEP]
                self.assertTrue(after, f"{operation} {kind}: no after step asserts the tree")
                for step in after:
                    self.assertEqual(step["op"], "settle", f"{operation} {kind}")
                    self.assertTrue(step["waitFor"]["pointer"].startswith("/daemon/session/"), f"{operation} {kind}")
            call = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]["steps"]
            expect = next(step for step in call if step["id"] == "call")["expect"]
            self.assertNotIn("field", entry["error"], operation)
            if operation != "screen.layout.undo":
                self.assertIn("errorDetails", expect, operation)
        # Ids the fixture results do not give come from a screen.get read before the call.
        column = files["column-update-ok.json"]["steps"]
        self.assertEqual([s["id"] for s in column], ["fx-workspace", "viewport-split", "read-layout", "call", "docked",
                                                     "first-free", "retry"])
        self.assertEqual(column[3]["args"]["params"]["column"], "$step:read-layout#/layout/root/columns/1/column_id")
        self.assertEqual(files["screen-layout-undo-error.json"]["steps"][-2]["expect"],
                         {"outcome": "error", "error": "confirmation.required"})

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
                self.assertEqual(ids[-1], RETRY_STEP if kind == "success" else CALL_STEP, name)
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
                self.assertEqual(ok["steps"][-3]["args"]["method"], "sidebar_view.ensure")
                bad = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]
                self.assertEqual(bad["steps"][-1]["target"]["sidebar_view"], "sidebar")
        write = files["sidebar-view-ensure-ok.json"]["steps"][0]["args"]["params"]["argv"]
        self.assertEqual(json.loads(write[-1]), {"sidebar": {"plugin": {"command": ["/bin/cat"]}}})
        self.assertEqual(drift(DEFAULT_OUT, files), [])

    def test_the_browser_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/browser/_tuning.json (p15-oracle-061): each browser mutation has a success
        and a typed-error case; only the success cases of the engine ops need a daemon-rendered browser, and they
        wait for it to go live. Every other case runs on a daemon with no cmux-browser provider."""
        engine = {"browser.activate", "browser.back", "browser.forward", "browser.reload", "browser.navigate",
                  "browser.input.key", "browser.input.text", "browser.input.mouse", "browser.input.wheel"}
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        browser = sorted(op for op in self.catalog.mutations() if family_of(op) == "browser")
        self.assertEqual(len(browser), 17)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "browser"), browser)
        for operation in browser:
            entry = files[COVERAGE]["operations"][operation]
            for kind in ("success", "error"):
                case = files[entry["cases"][kind].split("/", 1)[1] + ".json"]
                ids = [step["id"] for step in case["steps"]]
                self.assertEqual(case["steps"][-1]["args"]["method"], operation)
                daemon_rendered = kind == "success" and operation in engine
                self.assertEqual("chromium" in case["requires"], daemon_rendered, f"{operation} {kind}")
                self.assertEqual("fx-browser" in ids, daemon_rendered, f"{operation} {kind}")
                self.assertEqual("wait-live" in ids, daemon_rendered, f"{operation} {kind}")
            self.assertEqual(entry["placeholders"], [], operation)
            code = entry["error"]["code"]
            self.assertEqual(code == "operation.failed", operation in engine, operation)
            # No product runs a chromium success case yet (driver_app.py hands resource.call to driver_daemon.py,
            # whose daemon has no provider): those ops are excluded naming the task that closes them (239).
            excluded = files[COVERAGE]["excluded"]
            self.assertEqual(operation in excluded, operation in engine, operation)
            if operation in engine:
                self.assertIn("p15-oracle-239", excluded[operation], operation)
                bad = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]["steps"][-1]["expect"]
                self.assertEqual(bad["errorDetails"], {"extra": {
                    "code": "browser_rendered_by_app", "browser_id": "$step:fx-app-browser#/value/browser_id",
                    "tab_id": "$step:fx-app-browser#/value/tab_id"}}, operation)
        for operation in ("browser.input.mouse", "browser.input.wheel"):
            self.assertIn("p15-oracle-204", files[COVERAGE]["excluded"][operation], operation)
        move = files["browser-input-mouse-ok.json"]["steps"][-1]["args"]["params"]
        self.assertEqual((move["kind"], "button" in move), ("move", False))
        # The family's own count: the other families' tuning moves the suite total.
        self.assertEqual(sum(op not in files[COVERAGE]["excluded"] for op in browser), len(browser) - len(engine))

    def test_the_misc_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/misc/_tuning.json (p15-oracle-070): the 28 misc mutations. The case
        connection has no client-hello, so it derives origin agent: the operations that need the verified app (and
        pairing accept) assert that refusal, and their success cases (with history.restore, which needs a visit only
        a user-only operation makes) are excluded naming p15-oracle-237, the driver's install-key user connection, and
        pairing_request.resolve naming p15-oracle-238, its loopback pairing step. The rest are covered with no
        placeholder."""
        user_only = {"credential.rotate", "history.backups.purge", "history.trail.record", "history.visit.import",
                     "history.visit.record", "history.visit.title"}
        gapped = user_only | {"history.restore", "pairing_request.resolve"}
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        coverage = files[COVERAGE]
        misc = sorted(op for op in self.catalog.mutations() if family_of(op) == "misc")
        self.assertEqual(len(misc), 28)

        def call(operation: str, kind: str) -> Dict[str, Any]:
            return files[coverage["operations"][operation]["cases"][kind].split("/", 1)[1] + ".json"]["steps"][-1]

        for operation in misc:
            excluded = coverage["excluded"].get(operation)
            self.assertEqual(excluded is not None, operation in gapped, operation)
            if excluded is not None:
                closing = "p15-oracle-238" if operation == "pairing_request.resolve" else "p15-oracle-237"
                self.assertIn(closing, excluded, operation)
            else:
                self.assertEqual(coverage["operations"][operation]["placeholders"], [], operation)
        for operation in user_only | {"pairing_request.resolve"}:
            expect = call(operation, "error")["expect"]
            self.assertEqual((expect["error"], expect["errorDetails"]["derived"], expect["errorDetails"]["required"]),
                             ("origin.forbidden", "agent", "user"), operation)
        # Removing a binding or a record needs one first; the error cases of those ops have no setup step.
        for operation, setup in (("keybindings.remove", "keybindings.set"), ("window_record.delete", "window_record.put")):
            ok = files[coverage["operations"][operation]["cases"]["success"].split("/", 1)[1] + ".json"]["steps"]
            bad = files[coverage["operations"][operation]["cases"]["error"].split("/", 1)[1] + ".json"]["steps"]
            self.assertEqual([step["args"]["method"] for step in ok], [setup, operation, operation], operation)
            self.assertEqual([step["args"]["method"] for step in bad], [operation], operation)
        self.assertEqual(call("settings.reset_all", "success")["args"]["params"]["origin"], "user")
        self.assertEqual(call("settings.reset_all", "error")["expect"]["error"], "settings.agent_refused")
        self.assertEqual(call("pairing_request.resolve", "success")["args"]["params"]["decision"], "reject")
        self.assertEqual(call("pairing_request.resolve", "error")["args"]["params"]["decision"], "accept")
        # Every operation.failed of history.restore has detail operation history.restore; the reason tells the
        # unknown backup from a store failure.
        self.assertEqual(call("history.restore", "error")["expect"]["errorDetails"], {
            "operation": "history.restore",
            "reason": "no history backup history:0000000000000000000000000000000a (it was restored, purged or expired)"})

    def test_the_workspace_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/workspace/_tuning.json (p15-oracle-064): each of the 26 workspace-family
        mutations has a success and a typed-error case with no placeholder, and none needs a capability beyond
        resource_api. Two successes no product runs yet are excluded naming the task that closes them:
        workspace.agent_folder.set (user only, p15-oracle-237) and workspace.ensure_app (an installed first-party
        app, p15-oracle-248). A handler-level refusal with typed keys asserts them; the checklist store's has only
        a prose reason, so those cases assert the code."""
        gapped = {"workspace.agent_folder.set": "p15-oracle-237", "workspace.ensure_app": "p15-oracle-248"}
        missing_group = {"scope": "workspace_group", "id": "oracle-missing-group"}
        typed = {
            "workspace.agent_folder.set": ("origin.forbidden", {"derived": "agent", "required": "user"}),
            "workspace.ensure_app": ("validation.invalid", {
                "field": "app", "reason": "app oracle/not-installed is not installed and enabled"}),
            "workspace.open_url": ("validation.invalid", {
                "field": "url", "reason": "the URL must be an http or https URL with a host, at most 8192 bytes"}),
            "workspace.place": ("resource.not_found", missing_group),
            "workspace_group.delete": ("resource.not_found", missing_group),
            "workspace_group.move": ("resource.not_found", missing_group),
            "workspace_group.update": ("resource.not_found", missing_group),
            "workspace.focus": ("selector.not_found", {
                "scope": "workspace", "selector": "ws_00000000000000000000000000000000"}),
        }
        code_only = {"workspace_checklist.remove", "workspace_checklist.update"}
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        coverage = files[COVERAGE]
        family = sorted(op for op in self.catalog.mutations() if family_of(op) == "workspace")
        self.assertEqual(len(family), 26)
        self.assertLessEqual({op for op in tuning if family_of(op) == "workspace"}, set(family))
        for operation in family:
            entry = coverage["operations"][operation]
            self.assertEqual(entry["placeholders"], [], operation)
            excluded = coverage["excluded"].get(operation)
            self.assertEqual(excluded is not None, operation in gapped, operation)
            if excluded is not None:
                self.assertIn(gapped[operation], excluded, operation)
            calls = {}
            for kind in ("success", "error"):
                case = files[entry["cases"][kind].split("/", 1)[1] + ".json"]
                # workspace.run waits on the new tab after the call, so the call is not the last step.
                calls[kind] = next(step for step in case["steps"] if step["id"] == CALL_STEP)
                self.assertEqual(calls[kind]["args"]["method"], operation)
                self.assertEqual(case["requires"], ["resource_api"], f"{operation} {kind}")
                self.assertNotIn("fx-browser", [step["id"] for step in case["steps"]], f"{operation} {kind}")
            expect = calls["error"]["expect"]
            if operation in typed:
                self.assertEqual((expect["error"], expect["errorDetails"]), typed[operation], operation)
            elif operation in code_only:
                self.assertEqual((expect["error"], "errorDetails" in expect), ("validation.invalid", False), operation)
            else:
                self.assertEqual(expect["error"], ERROR_CODE, operation)
        self.assertEqual(sum(op not in coverage["excluded"] for op in family), len(family) - len(gapped))
        # open_url reuses the app-drawn browser it focused first, so it needs no cmux-browser provider.
        open_ok = files["workspace-open-url-ok.json"]["steps"]
        ids = [step["id"] for step in open_ok]
        call = ids.index(CALL_STEP)
        self.assertEqual(ids[call - 1], "focus-app-browser")
        self.assertEqual(open_ok[call - 1]["target"]["tab"], "$step:fx-app-browser#/value/tab_id")
        # A tuned handler-level error is the tuned success request with one change, never a broken catalog type.
        place_error = next(step for step in files["workspace-place-error.json"]["steps"]
                           if step["id"] == CALL_STEP)["args"]["params"]
        self.assertEqual(place_error, {"group": "oracle-missing-group"})

    def test_the_tab_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/tab/_tuning.json (p15-oracle-067): the 21 tab, tab_group, saved_tab_group
        and closed mutations. Reopen and unpin run as round trips (a close or pin first, in the success case only);
        each error is the handler's own refusal except tab.create_browser's, which keeps the catalog check so it is
        the same with and without a browser engine. Only that success (a daemon-rendered browser) is excluded."""
        sys.path.insert(0, str(HERE))
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        coverage = files[COVERAGE]
        tab = sorted(op for op in self.catalog.mutations() if family_of(op) == "tab")
        self.assertEqual(len(tab), 21)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "tab"), tab)

        def case(operation: str, kind: str) -> Dict[str, Any]:
            return files[coverage["operations"][operation]["cases"][kind].split("/", 1)[1] + ".json"]

        round_trips = {"closed.reopen": "tab.close", "closed.delete": "tab.close",
                       "saved_tab_group.reopen": "tab_group.close", "tab.unpin": "tab.pin", "tab.focus": "tab.focus"}
        for operation in tab:
            entry = coverage["operations"][operation]
            self.assertEqual(entry["placeholders"], [], operation)
            self.assertEqual(operation in coverage["excluded"], operation == "tab.create_browser", operation)
            for kind in ("success", "error"):
                doc = case(operation, kind)
                self.assertEqual(normalize.validate(doc, schema), [], f"{operation} {kind}")
                self.assertEqual(checks.check_case(doc, rules), [], f"{operation} {kind}")
                self.assertEqual(doc["steps"][-1]["args"]["method"], operation)
                # Every refusal but the catalog check's names what it refused.
                expect = doc["steps"][-1]["expect"]
                self.assertEqual("errorDetails" in expect, kind == "error" and operation != "tab.create_browser",
                                 f"{operation} {kind}")
                before = [step["args"]["method"] for step in doc["steps"]
                          if step["id"] not in (CALL_STEP, RETRY_STEP) and not step["id"].startswith("fx-")]
                setup = round_trips.get(operation) if kind == "success" else None
                expected = [setup] if setup else (["tab.pin"] if (operation, kind) == ("tab_group.add_tabs", "error") else [])
                self.assertEqual(before, expected, f"{operation} {kind}")
        self.assertEqual(case("tab.create_browser", "success")["requires"], ["resource_api", "chromium"])
        self.assertEqual(case("tab.create_browser", "error")["requires"], ["resource_api"])
        self.assertEqual(coverage["operations"]["tab.create_browser"]["error"]["code"], ERROR_CODE)
        # The task the gap names owns the tab corpus (load_tuning refuses a gap whose tasks do not), and its plan
        # section takes in this case.
        self.assertIn("p15-oracle-239", coverage["excluded"]["tab.create_browser"])
        self.assertTrue(TaskGraph.load().owns("p15-oracle-239", f"{CORPUS_DIR}/tab/"))
        plan = (WORK.parent / "p15-oracle.md").read_text(encoding="utf-8")
        self.assertIn("tab.create_browser", plan[plan.index("**239 "):].split("\n\n", 1)[0])
        # The closed history is empty until a close: reopen's error is the missing newest group, its success the
        # tab the before step closed.
        self.assertEqual(case("closed.reopen", "error")["steps"][-1]["expect"]["errorDetails"],
                         {"scope": "closed", "id": "newest"})
        self.assertEqual(case("closed.reopen", "success")["steps"][-3]["target"]["tab"],
                         "$step:fx-split#/value/tab_id")

    def test_the_chief_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/chief/_tuning.json (p15-oracle-069): each of the 24 chief, conversation,
        room, participant and agent mutations has a success and a typed-error case. The Chief brain and the
        conversations are the mock agent's (fixture.agent mock, mock_chief.py); no case holds a credential. Every
        error case asserts its refusal by typed keys, except the three whose refusal has none yet (p15-oracle-241).
        The success cases that need a bound agent connection or the verified app name p15-oracle-240."""
        gapped = {"agent.message.release", "agent.message.unsend", "conversation.draft"}
        code_only = {"agent.report", "room.create", "room.delete"}
        mock = {"chief.engine.set", "chief.stop", "chief.profile.adopt", "conversation.send", "conversation.typing",
                "conversation.draft"}
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        chief = sorted(op for op in self.catalog.mutations() if family_of(op) == "chief")
        self.assertEqual(len(chief), 24)
        excluded = files[COVERAGE]["excluded"]
        self.assertEqual(sorted(op for op in excluded if family_of(op) == "chief"), sorted(gapped))
        skips = expectation_lines(files[COVERAGE])
        for operation in chief:
            entry = files[COVERAGE]["operations"][operation]
            success_id = entry["cases"]["success"]
            self.assertEqual(f"p15-oracle-240 {success_id} [ Skip ]" in skips, operation in gapped, operation)
            if operation in gapped:
                self.assertTrue(excluded[operation].startswith("no product runs it yet"), operation)
                self.assertIn("p15-oracle-240", excluded[operation], operation)
            else:
                self.assertEqual(entry["placeholders"], [], operation)
            ok = files[success_id.split("/", 1)[1] + ".json"]
            self.assertEqual(ok["fixture"].get("agent"), "mock" if operation in mock else None, operation)
            for kind in ("success", "error"):
                case = files[entry["cases"][kind].split("/", 1)[1] + ".json"]
                self.assertEqual(case["requires"], ["resource_api"], f"{operation} {kind}")
                self.assertEqual(case["steps"][-1]["args"]["method"], operation)
                self.assertIsNone(next(credential_values(case, operation), None), f"{operation} {kind}")
            error = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]["steps"][-1]["expect"]
            self.assertEqual("errorDetails" in error, operation not in code_only, operation)
            # Typed keys only: a reason is a token (no spaces), never message text.
            reason = error.get("errorDetails", {}).get("reason", "")
            self.assertRegex(reason, r"^[a-z_]*$", f"{operation}: the reason is a token, not prose")
        send = files["conversation-send-ok.json"]["steps"]
        self.assertEqual(send[0], {"id": "conversation", "op": "resource.call", "target": dict(SCOPE),
                                   "args": {"method": "conversation.list", "params": {}}, "readOnly": True,
                                   "expect": {"outcome": "ok"}})
        self.assertEqual(send[-1]["args"]["params"]["conversation"], "$step:conversation#/0/id")
        adopt = files["chief-profile-adopt-ok.json"]["steps"][-1]["args"]["params"]
        self.assertEqual(adopt["participant_id"], _sibling_module("mock_chief").ADOPTABLE)
        undo = [step["id"] for step in files["chief-profile-undo-ok.json"]["steps"]]
        self.assertEqual(undo, ["fx-chief", "rename", "call", "retry"])
        self.assertNotIn("rename", [step["id"] for step in files["chief-profile-undo-error.json"]["steps"]])
        unpin = [step["id"] for step in files["room-unpin-ok.json"]["steps"]]
        self.assertEqual(unpin, ["fx-workspace", "fx-room", "pin", "call", "retry"])

    def test_each_excluded_success_case_is_a_skip_line_naming_its_task(self) -> None:
        files = generate(self.catalog, load_tuning(DEFAULT_OUT, self.catalog))
        coverage = files[COVERAGE]
        lines = expectation_lines(coverage)
        skips = [line for line in lines if line.endswith("[ Skip ]")]
        self.assertEqual(len(skips), len(coverage["excluded"]))
        known = [(operation, kind) for operation, entry in coverage["operations"].items()
                 for kind in entry.get("expectations") or {}
                 if not (kind == "success" and operation in coverage["excluded"])]
        self.assertEqual(len(lines), len(skips) + len(known))
        for operation, reason in coverage["excluded"].items():
            task = TASK_ID.search(reason).group(0)
            self.assertIn(f"{task} {coverage['operations'][operation]['cases']['success']} [ Skip ]", lines)
        with self.assertRaisesRegex(GenError, "names no task"):
            expectation_lines({"excluded": {"pane.close": "no reason"}, "operations": coverage["operations"]})
        # The checked-in file is the expectations.py format, and every line parses with no diagnostic.
        expectations = _sibling_module("expectations")
        text = render_expectations("", lines)
        entries, diagnostics = expectations.parse_text(text, "daemon-ops.txt", "expectations")
        self.assertEqual((len(entries), diagnostics), (len(lines), []))
        self.assertEqual(sum(entry.results == frozenset({"Skip"}) and not entry.tags for entry in entries), len(skips))
        self.assertTrue(all(entry.tags == frozenset({"new"}) for entry in entries if entry.results != {"Skip"}))

    def test_the_skip_block_keeps_hand_lines_and_check_finds_drift(self) -> None:
        coverage = generate(self.catalog, {})[COVERAGE]
        lines = expectation_lines(coverage)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Expectations.d" / f"{SUITE}.txt"
            self.assertEqual(expectations_drift(path, coverage), [f"{SUITE}.txt: the generated block differs "
                                                                   "from coverage.json"])
            self.assertTrue(write_expectations(path, coverage))
            self.assertFalse(write_expectations(path, coverage))
            self.assertEqual(expectations_drift(path, coverage), [])
            hand = "#1234 daemon-ops/pane-close-ok [ Failure Pass ]\n"
            path.write_text(hand + path.read_text(encoding="utf-8"), encoding="utf-8")
            fewer = {**coverage, "excluded": dict(list(coverage["excluded"].items())[1:])}
            self.assertEqual(len(expectations_drift(path, fewer)), 1)
            self.assertTrue(write_expectations(path, fewer))
            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith(hand), "a line outside the block is kept")
            self.assertEqual(text.count(EXPECTATIONS_BEGIN), 1)
            dropped = coverage["operations"][next(iter(coverage["excluded"]))]["cases"]["success"]
            self.assertNotIn(f" {dropped} [ Skip ]", text)
            path.write_text(EXPECTATIONS_BEGIN + "\n", encoding="utf-8")
            with self.assertRaisesRegex(GenError, "one of the generator's block markers"):
                write_expectations(path, coverage)

    def test_a_git_remote_is_a_name_of_the_generated_repository(self) -> None:
        """git_ops/push.rs pushes only to a configured remote, and make_repo.py gives the fixture repository one:
        its bare origin under the case root. So a case's remote is a plain name, never a URL or a path."""
        repo = {"repo": "oracle", "params": {"path": f"{REPOS_ROOT}/oracle"}}
        for remote in ("git@github.com:manaflow-ai/cmux.git", "https://example.invalid/x.git", "/srv/repos/cmux.git",
                       f"{ROOT_TOKEN}/repos/oracle.git", "../x"):
            with self.subTest(remote=remote), self.assertRaisesRegex(GenError, "git.push: params.remote .* no URL"):
                generate(self.catalog, {"git.push": {"success": {**repo, "params": {**repo["params"], "remote": remote}}}})
        with self.assertRaisesRegex(GenError, "git.push: before.push.params.remote"):
            generate(self.catalog, {"git.push": {"success": {**repo, "before": [
                {"id": "push", "method": "git.push", "params": {"remote": "file:///srv/x.git"}}]}}})
        with self.assertRaisesRegex(GenError, "no generated repository"):
            generate(self.catalog, {"git.push": {"success": {"params": {"remote": "origin"}}}})
        files = generate(self.catalog, {"git.push": {"success": {**repo, "params": {**repo["params"], "remote": "origin"}}}})
        self.assertEqual(files["git-push-ok.json"]["steps"][-1]["args"]["params"]["remote"], "origin")
        self.assertEqual(files["git-push-ok.json"]["fixture"]["repo"], "oracle")

    def test_a_repository_path_needs_its_repository(self) -> None:
        for path, problem in ((f"{REPOS_ROOT}/oracle", "no folder of the case's repository None"),
                              (f"{REPOS_ROOT}/other", "no folder of the case's repository 'oracle'"),
                              (f"{REPOS_ROOT}/oracle/../other", "leaves its folder")):
            repo = {"repo": "oracle"} if "None" not in problem else {}
            with self.subTest(path=path), self.assertRaisesRegex(GenError, re.escape(problem)):
                generate(self.catalog, {"git.commit": {"success": {**repo, "params": {"path": path}}}})
        for name, problem in (("Not A Slug", "repo: repository fixture name"), ("no-such-repo", "no-such-repo.json")):
            with self.subTest(repo=name), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / "git").mkdir()
                (Path(tmp) / "git" / TUNING).write_text(json.dumps(
                    {"operations": {"git.commit": {"success": {"repo": name}}}}), encoding="utf-8")
                with self.assertRaisesRegex(GenError, problem):
                    load_tuning(Path(tmp), self.catalog)
        files = generate(self.catalog, {"git.commit": {"success": {"repo": "oracle", "params": {
            "path": f"{REPOS_ROOT}/oracle/src"}}}})
        case = files["git-commit-ok.json"]
        self.assertEqual(case["fixture"]["repo"], "oracle")
        self.assertIn(REPO_PRECONDITION.format(repo="oracle"), case["preconditions"])
        self.assertEqual(files["git-commit-error.json"]["fixture"]["repo"], "oracle", "the error case starts from success")

    def test_a_generated_repository_needs_a_capability_no_product_has_yet(self) -> None:
        """A case with fixture.repo requires git_repo, which no product offers until its driver builds the
        repository (p15-oracle-243): no runner picks the case up, and coverage excludes the
        operation instead of counting expectations no daemon has checked."""
        repo = {"repo": "oracle", "params": {"path": f"{REPOS_ROOT}/oracle"}}
        files = generate(self.catalog, {"git.commit": {"success": repo}})
        coverage = files[COVERAGE]
        for kind in ("ok", "error"):
            case = files[f"git-commit-{kind}.json"]
            self.assertEqual(case["requires"], ["resource_api", REPO_CAPABILITY], kind)
            self.assertIn(HOME_PRECONDITION, case["preconditions"], kind)
        self.assertEqual(coverage["excluded"]["git.commit"], REPO_GAP)
        self.assertEqual(files["git-commit-ok.json"]["untested"], [REPO_GAP])
        # REPO_GAP names a task that still closes it, as a tuned gap must (TaskGraph.gap_problem).
        self.assertIsNone(TaskGraph.load().gap_problem(REPO_GAP, "git"))
        gap = "the store refuses it (p15-oracle-204)"
        files = generate(self.catalog, {"git.commit": {"success": {**repo, "gap": gap}}})
        self.assertEqual(files[COVERAGE]["excluded"]["git.commit"], f"{gap}; {REPO_GAP}")
        # An untuned git operation says what it lacks: a `repo` tuning.
        self.assertIn("no `repo` tuning", generate(self.catalog, {})[COVERAGE]["excluded"]["git.commit"])
        # One owner of the token, the repository folder and the capability: make_repo.py and oracle.py.
        self.assertEqual((ROOT_TOKEN, REPOS_ROOT), (make_repo().ROOT_TOKEN, make_repo().REPOS_ROOT))
        spec = importlib.util.spec_from_file_location("oracle_cli", HERE / "oracle.py")
        assert spec is not None and spec.loader is not None
        oracle = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = oracle
        spec.loader.exec_module(oracle)
        self.assertIn(REPO_CAPABILITY, oracle.CAPABILITIES)
        self.assertEqual([product for product, caps in oracle.PRODUCTS.items() if REPO_CAPABILITY in caps], [])

    def test_the_git_family_tuning(self) -> None:
        """tests/oracle/corpus/daemon-ops/git/_tuning.json (p15-oracle-068): each git, project and stash mutation
        has a success and a typed-error case. A git case runs on the generated repository by path, with no
        workspace selector and requires git_repo, which no product offers until the case runner builds the
        repository (REPO_GAP), so the git operations are excluded; so is project.add (every case root is under /tmp).
        The stash and the other project operations run on the standard fixture."""
        tuning = load_tuning(DEFAULT_OUT, self.catalog)
        files = generate(self.catalog, tuning)
        family = sorted(op for op in self.catalog.mutations() if family_of(op) == "git")
        self.assertEqual(len(family), 18)
        self.assertEqual(sorted(op for op in tuning if family_of(op) == "git"), family)
        coverage = files[COVERAGE]
        handler_errors = {"git.checkpoint.unpin": "managed_pin", "git.commit": "nothing_to_commit",
                          "git.push": "no_remote", "git.worktree.apply": "not_a_worktree",
                          "git.worktree.create": "base_not_found", "git.worktree.remove": "unpushed_commits"}
        for operation in family:
            entry = coverage["operations"][operation]
            self.assertEqual(entry["placeholders"], [], operation)
            git = operation.startswith("git.")
            self.assertEqual(operation in coverage["excluded"], git or operation == "project.add", operation)
            success_repo = files[entry["cases"]["success"].split("/", 1)[1] + ".json"]["fixture"].get("repo")
            self.assertEqual(success_repo == "oracle", git or operation == "project.add", operation)
            if success_repo:
                self.assertIn(REPO_GAP, coverage["excluded"][operation], operation)
            for kind in ("success", "error"):
                case = files[entry["cases"][kind].split("/", 1)[1] + ".json"]
                call = case["steps"][-1]
                text = json.dumps(case["steps"])
                if operation.startswith("git."):
                    self.assertEqual(call["target"], SCOPE, f"{operation} {kind}: a path, no selector")
                    self.assertNotIn("fx-workspace", [step["id"] for step in case["steps"]], operation)
                self.assertEqual(case["fixture"].get("repo") == "oracle", REPOS_ROOT in text, f"{operation} {kind}")
                has_repo = "repo" in case["fixture"]
                self.assertEqual(REPO_CAPABILITY in case["requires"], has_repo, f"{operation} {kind}")
                self.assertEqual(HOME_PRECONDITION in case["preconditions"], has_repo, f"{operation} {kind}")
                self.assertNotRegex(text, r"\$CASE_ROOT/(?!repos/oracle(?:-feature)?\")", f"{operation} {kind}")
            expect = files[entry["cases"]["error"].split("/", 1)[1] + ".json"]["steps"][-1]["expect"]
            if operation in handler_errors:
                self.assertEqual((expect["error"], expect["errorDetails"]["reason"]),
                                 ("operation.failed", handler_errors[operation]), operation)
        self.assertIn("p15-oracle-244", coverage["excluded"]["project.add"])
        remove = files["git-worktree-remove-ok.json"]["steps"]
        self.assertEqual([s["id"] for s in remove], ["worktree", "call", "retry"])
        self.assertEqual(remove[-1]["args"]["params"], {"path": "$step:worktree#/value/root"})
        # fx-stash stashes a web page, as state/stash.rs requires: the app-drawn http page of the fixture.
        stash = files["stash-delete-ok.json"]["steps"]
        self.assertEqual([s["id"] for s in stash], ["fx-workspace", "fx-browser-profile", "fx-app-browser", "fx-stash",
                                                    "call", "retry"])
        self.assertEqual(stash[3]["args"]["params"], {"tabs": ["$step:fx-app-browser#/value/tab_id"]})
        # The repository the cases name: its only remote is its bare origin beside the checkout.
        self.assertEqual(repo_fixture("oracle", "test").tokens()["origin"], f"{REPOS_ROOT}/oracle.git")

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
                         ["fx-workspace", "fx-message", "call", "retry"])
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

    def test_each_success_case_retries_its_call_with_the_same_key(self) -> None:
        """p15-oracle-206: one same-key retry per `idempotency: required` operation, generated, never hand-written,
        and found as a retry by invariants.py I10."""
        invariants = _sibling_module("invariants")
        coverage = self.files[COVERAGE]
        required = [name for name in self.catalog.mutations()
                    if self.catalog.operations[name].get("idempotency") == "required"]
        self.assertEqual(len(required), 201)
        self.assertEqual(coverage["unretried"], UNRETRIED)
        self.assertEqual(coverage["retries"], len(required) - len(UNRETRIED))
        for operation in self.catalog.mutations():
            entry = coverage["operations"][operation]
            if operation in UNRETRIED:
                self.assertIn(operation, required, "an unretried operation requires a key: else it needs no entry")
                self.assertNotIn("retry", entry, operation)
                ok = self.files[entry["cases"]["success"].split("/", 1)[1] + ".json"]
                self.assertEqual(ok["steps"][-1]["id"], CALL_STEP, operation)
                continue
            ok = self.files[entry["cases"]["success"].split("/", 1)[1] + ".json"]
            bad = self.files[entry["cases"]["error"].split("/", 1)[1] + ".json"]
            self.assertNotIn(RETRY_STEP, [step["id"] for step in bad["steps"]], operation)
            self.assertEqual(entry["retry"], f"{entry['cases']['success']}/{RETRY_STEP}", operation)
            call = next(step for step in ok["steps"] if step["id"] == CALL_STEP)
            retry = ok["steps"][-1]
            self.assertEqual(retry["id"], RETRY_STEP, operation)
            self.assertEqual(retry["checkpoint"], ["before", "settled"], operation)
            own = ("id", "checkpoint", "note")
            self.assertEqual({key: value for key, value in retry.items() if key not in own},
                             {key: value for key, value in call.items() if key not in own}, operation)
            trace = invariants.load_trace({"schema": invariants.TRACE_SCHEMA, "case": ok["id"],
                                           "steps": [{"id": step["id"]} for step in ok["steps"]]}, ok)
            checker = invariants.Checker(trace, None)
            self.assertEqual([(a.id, b.id) for a, b in checker.retries()], [(CALL_STEP, RETRY_STEP)], operation)

    def test_a_split_targets_the_fixture_pane_as_the_example_case_does(self) -> None:
        """schemas/oracle/fixtures/case-example-daemon.json splits the pane of a workspace it created."""
        case = self.files["pane-split-ok.json"]
        self.assertEqual([step["id"] for step in case["steps"]], ["fx-workspace", "call", "retry"])
        call = case["steps"][1]
        self.assertEqual(call["args"]["params"], {"direction": "left"}, "the first value of the catalog enum")
        self.assertEqual(call["target"], {**SCOPE, "pane": "$step:fx-workspace#/value/pane_id"})
        self.assertEqual(call["args"]["idempotencyKey"], "pane-split-ok.call")
        self.assertEqual(call["checkpoint"], ["before", "settled"])


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--expectations", type=Path,
                        help="the suite's expectations file (default: <out>/../../Expectations.d/daemon-ops.txt)")
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
        expectations = args.expectations or expectations_path(args.out)
        if args.check:
            problems = drift(args.out, files) + expectations_drift(expectations, coverage)
            for problem in problems:
                print(f"gen_daemon_ops: {problem}", file=sys.stderr)
            print(f"gen_daemon_ops: {coverage['covered']}/{coverage['total']} operations, "
                  f"{'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
        written += write_expectations(expectations, coverage)
    except GenError as error:
        print(f"gen_daemon_ops: {error}", file=sys.stderr)
        return 2
    print(f"gen_daemon_ops: {coverage['covered']}/{coverage['total']} operations, {len(files) - 1} cases, "
          f"{written} files written, {removed} removed, {coverage['placeholder_operations']} with placeholders")
    return 0


if __name__ == "__main__":
    sys.exit(main())
