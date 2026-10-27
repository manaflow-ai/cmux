#!/usr/bin/env python3
"""The x-oracle checks of schemas/oracle/case-v1.schema.json, with the standard library only.

JSON Schema cannot compare one array item with another, so case-v1 states these checks as
x-oracle-* keywords and this module runs them with the error text the schema carries:

- x-oracle-unique on /steps: step ids are unique.
- x-oracle-step-ref on $defs/stepRef: a $step:<id>#<pointer> value names an earlier step.
- x-oracle-step-ref on $defs/allowCrash steps: allow_crashes names steps of this case.
- x-oracle-crash-scope on /allow_crashes: each step that ends a child process (a kill, or a
  Chromium debug URL in its args) is inside an allow_crashes entry of its kind, and no kind has
  more such steps than its entries' max.

normalize.py --validate (task 013) and oracle.py check (task 017) call check_case after their
JSON Schema pass. --selftest runs schemas/oracle/fixtures/case-v1-mutations.json: each mutation
of an example case must be refused by the layer it names, with the message or pointer it names.

    python3 -I scripts/cmux-next/oracle/case_checks.py CASE.json...
    python3 -I scripts/cmux-next/oracle/case_checks.py --selftest
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

REPO = Path(__file__).resolve().parents[3]
SCHEMA = REPO / "schemas/oracle/case-v1.schema.json"
MUTATIONS = REPO / "schemas/oracle/fixtures/case-v1-mutations.json"

# Fields of a step whose values may hold $step: references (case-v1 $defs/step, last allOf entry,
# and target through $defs/handle).
STEP_REF_FIELDS = ("target", "args", "expect", "waitFor")


@dataclass(frozen=True)
class Finding:
    pointer: str
    message: str


def pointer_token(token: str | int) -> str:
    return str(token).replace("~", "~0").replace("/", "~1")


def join(pointer: str, *tokens: str | int) -> str:
    return pointer + "".join("/" + pointer_token(t) for t in tokens)


def resolve(document: Any, pointer: str) -> Any:
    """RFC 6901 lookup; KeyError when the pointer names nothing."""
    node = document
    if pointer == "":
        return node
    for raw in pointer.split("/")[1:]:
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, list):
            node = node[int(token)]
        elif isinstance(node, dict):
            node = node[token]
        else:
            raise KeyError(pointer)
    return node


class Rules:
    """The x-oracle keywords and patterns read from the schema, so the messages live in one place."""

    def __init__(self, schema: dict[str, Any]) -> None:
        self.unique = resolve(schema, "/properties/steps/x-oracle-unique")
        self.step_ref = resolve(schema, "/$defs/stepRef/x-oracle-step-ref")
        self.allow_ref = resolve(schema, "/$defs/allowCrash/properties/steps/items/x-oracle-step-ref")
        self.crash_scope = resolve(schema, "/properties/allow_crashes/x-oracle-crash-scope")
        self.crash_urls = {
            "renderer": re.compile(resolve(schema, "/$defs/rendererCrashUrl/pattern")),
            "gpu": re.compile(resolve(schema, "/$defs/gpuCrashUrl/pattern")),
        }
        kinds = resolve(schema, "/$defs/crashKind/enum")
        if self.unique.get("key") != "/id" or self.step_ref.get("order") != "earlier" or self.allow_ref.get("order") != "any":
            raise ValueError("case-v1 x-oracle keywords changed; update case_checks.py with them")
        if not set(self.crash_urls) <= set(kinds):
            raise ValueError("case-v1 crash URL kinds are not crash kinds")


def strings(value: Any, pointer: str) -> Iterator[tuple[str, str]]:
    """Every string value (not key) at any depth, with its pointer, in document order."""
    if isinstance(value, str):
        yield pointer, value
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from strings(item, join(pointer, index))
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(item, join(pointer, key))


def step_ref_id(value: str) -> str:
    return value[len("$step:"):].split("#", 1)[0]


def crash_kinds(step: dict[str, Any], rules: Rules) -> list[str]:
    """The child kinds a step ends on purpose: a kill's process, the process a call `ends`, and the debug URLs in
    its args."""
    kinds: list[str] = []
    target = step.get("target")
    if step.get("op") == "kill" and isinstance(target, dict) and isinstance(target.get("process"), str):
        kinds.append(target["process"])
    if isinstance(step.get("ends"), str):
        kinds.append(step["ends"])
    for _, text in strings(step.get("args"), ""):
        for kind, pattern in rules.crash_urls.items():
            if pattern.search(text) and kind not in kinds:
                kinds.append(kind)
    return kinds


def check_case(case: Any, rules: Rules) -> list[Finding]:
    """Runs the x-oracle checks on a case that may or may not pass JSON Schema; never raises."""
    if not isinstance(case, dict) or not isinstance(case.get("steps"), list):
        return []
    findings: list[Finding] = []
    steps = [s if isinstance(s, dict) else {} for s in case["steps"]]
    ids = [s.get("id") if isinstance(s.get("id"), str) else None for s in steps]

    first: dict[str, int] = {}
    for index, step_id in enumerate(ids):
        if step_id is None:
            continue
        if step_id in first:
            findings.append(Finding(join("/steps", index, "id"), rules.unique["error"].format(
                value=step_id, pointer=join("/steps", index, "id"), first=join("/steps", first[step_id], "id"))))
        else:
            first[step_id] = index

    for index, step in enumerate(steps):
        earlier = {i for i in ids[:index] if i is not None}
        for field in STEP_REF_FIELDS:
            for pointer, text in strings(step.get(field), join("/steps", index, field)):
                if text.startswith("$step:") and step_ref_id(text) not in earlier:
                    findings.append(Finding(pointer, rules.step_ref["error"].format(
                        pointer=pointer, value=text, step=step_ref_id(text))))

    allow = case.get("allow_crashes")
    entries = [e if isinstance(e, dict) else {} for e in allow] if isinstance(allow, list) else []
    known = {i for i in ids if i is not None}
    for e_index, entry in enumerate(entries):
        names = entry.get("steps")
        if not isinstance(names, list):
            continue
        for n_index, name in enumerate(names):
            if isinstance(name, str) and name not in known:
                pointer = join("/allow_crashes", e_index, "steps", n_index)
                findings.append(Finding(pointer, rules.allow_ref["error"].format(pointer=pointer, value=name, step=name)))

    counts: dict[str, int] = {}
    for index, step in enumerate(steps):
        for kind in crash_kinds(step, rules):
            counts[kind] = counts.get(kind, 0) + 1
            covered = any(
                e.get("kind") == kind and (not isinstance(e.get("steps"), list) or ids[index] in e["steps"])
                for e in entries
            )
            if not covered:
                pointer = join("/steps", index)
                findings.append(Finding(pointer, rules.crash_scope["error"].format(
                    pointer=pointer, step=ids[index], kind=kind)))
    for kind, count in counts.items():
        allowed = sum(e.get("max", 1) for e in entries if e.get("kind") == kind and isinstance(e.get("max", 1), int))
        if allowed and count > allowed:
            findings.append(Finding("/allow_crashes", rules.crash_scope["countError"].format(
                pointer="/allow_crashes", count=count, kind=kind, max=allowed)))
    return findings


def error_details_mismatch(expected: Any, actual: Any, pointer: str = "") -> str | None:
    """case-v1 expect.errorDetails against a typed error's details (its $step: references already resolved):
    every expected key is present with an equal value, objects compared key by key, other values exactly. The
    first difference as `<pointer>: ...`, or None. The drivers that read a reply's details call this."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return f"{pointer or '/'}: expected an object, got {json.dumps(actual)[:120]}"
        for key, value in expected.items():
            where = join(pointer, key)
            if key not in actual:
                return f"{where}: missing"
            problem = error_details_mismatch(value, actual[key], where)
            if problem:
                return problem
        return None
    if not json_equal(expected, actual):
        return f"{pointer or '/'}: expected {json.dumps(expected)[:120]}, got {json.dumps(actual)[:120]}"
    return None


def json_equal(a: Any, b: Any) -> bool:
    """Equal as JSON values: Python's == says True == 1 == 1.0, but a boolean, an integer and a number with a
    fraction are three different wire values, so the types must match too (containers element by element)."""
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(json_equal(value, b[key]) for key, value in a.items())
    if isinstance(a, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    return a == b


ERROR_DETAILS_VECTORS: tuple[tuple[Any, Any, str | None], ...] = (
    ({"extra": {"code": "a"}}, {"operation": "o", "extra": {"code": "a", "tab_id": "t"}}, None),
    ({"extra": {"code": "a"}}, {"extra": {"code": "b"}}, '/extra/code: expected "a", got "b"'),
    ({"extra": {"code": "a"}}, {"operation": "o"}, "/extra: missing"),
    ({"extra": {"code": "a"}}, None, "/: expected an object, got null"),
    ({"ids": ["a"]}, {"ids": ["a", "b"]}, '/ids: expected ["a"], got ["a", "b"]'),
    ({"n": 1}, {"n": True}, "/n: expected 1, got true"),
    ({"n": True}, {"n": 1}, "/n: expected true, got 1"),
    ({"n": 1}, {"n": 1.0}, "/n: expected 1, got 1.0"),
    ({"ids": [0]}, {"ids": [False]}, "/ids: expected [0], got [false]"),
    ({"ids": [{"n": 1}]}, {"ids": [{"n": 1.0}]}, '/ids: expected [{"n": 1}], got [{"n": 1.0}]'),
    ({"n": 1, "ok": False}, {"n": 1, "ok": False}, None),
)


def apply_patch(document: Any, patch: list[dict[str, Any]]) -> Any:
    """RFC 6902 add, remove and replace: enough to write the mutation table."""
    result = copy.deepcopy(document)
    for operation in patch:
        parent_pointer, _, raw = operation["path"].rpartition("/")
        parent = resolve(result, parent_pointer)
        token = raw.replace("~1", "/").replace("~0", "~")
        kind = operation["op"]
        if isinstance(parent, list):
            index = len(parent) if token == "-" else int(token)
            if kind == "add":
                parent.insert(index, copy.deepcopy(operation["value"]))
            elif kind == "remove":
                del parent[index]
            elif kind == "replace":
                parent[index] = copy.deepcopy(operation["value"])
            else:
                raise ValueError(f"unsupported patch op {kind}")
        elif kind in ("add", "replace"):
            if kind == "replace" and token not in parent:
                raise KeyError(operation["path"])
            parent[token] = copy.deepcopy(operation["value"])
        elif kind == "remove":
            del parent[token]
        else:
            raise ValueError(f"unsupported patch op {kind}")
    return result


def schema_error_pointers(validator: Any, case: Any) -> set[str]:
    pointers: set[str] = set()
    pending = list(validator.iter_errors(case))
    while pending:
        error = pending.pop()
        pointers.add(join("", *error.absolute_path))
        pending.extend(error.context or [])
    return pointers


def selftest(schema: dict[str, Any], rules: Rules) -> int:
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        print("selftest: jsonschema is not installed; the JSON Schema layer cannot run (python3 -m pip install jsonschema)")
        return 1
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    table = json.loads(MUTATIONS.read_text())
    bases: dict[str, Any] = {}
    failures = 0
    for name in sorted({m["base"] for m in table["mutations"]}):
        bases[name] = json.loads((MUTATIONS.parent / name).read_text())
        problems = [f"{p}: JSON Schema refuses it" for p in sorted(schema_error_pointers(validator, bases[name]))]
        problems += [f.message for f in check_case(bases[name], rules)]
        for problem in problems:
            print(f"FAIL base {name}: {problem}")
        failures += bool(problems)
    for mutation in table["mutations"]:
        case = apply_patch(bases[mutation["base"]], mutation["patch"])
        schema_pointers = schema_error_pointers(validator, case)
        messages = [f.message for f in check_case(case, rules)]
        layer = mutation["layer"]
        if layer == "valid":
            ok = not schema_pointers and not messages
            got = f"schema {sorted(schema_pointers)}, x-oracle {messages}"
        elif layer == "schema":
            ok = mutation["pointer"] in schema_pointers
            got = f"schema errors at {sorted(schema_pointers)}"
        elif layer == "x-oracle":
            ok = not schema_pointers and messages == [mutation["error"]]
            got = f"schema {sorted(schema_pointers)}, x-oracle {messages}"
        else:
            raise ValueError(f"{mutation['name']}: unknown layer {layer}")
        if not ok:
            failures += 1
            print(f"FAIL {mutation['name']} ({layer}): {got}")
    for expected, actual, want in ERROR_DETAILS_VECTORS:
        got = error_details_mismatch(expected, actual)
        if got != want:
            failures += 1
            print(f"FAIL errorDetails {json.dumps(expected)} against {json.dumps(actual)}: {got!r}, not {want!r}")
    total = len(table["mutations"]) + len(bases) + len(ERROR_DETAILS_VECTORS)
    print(f"selftest: {total - failures}/{total} pass ({len(bases)} example cases, {len(table['mutations'])} mutations, "
          f"{len(ERROR_DETAILS_VECTORS)} errorDetails vectors)")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("cases", nargs="*", type=Path)
    parser.add_argument("--schema", type=Path, default=SCHEMA)
    parser.add_argument("--selftest", action="store_true", help="run the case-v1 mutation table on both layers")
    args = parser.parse_args(argv)
    schema = json.loads(args.schema.read_text())
    rules = Rules(schema)
    if args.selftest:
        return selftest(schema, rules)
    if not args.cases:
        parser.error("name a case file or --selftest")
    failed = False
    for path in args.cases:
        for finding in check_case(json.loads(path.read_text()), rules):
            failed = True
            print(f"{path}: {finding.message}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
