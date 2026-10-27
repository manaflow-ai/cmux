#!/usr/bin/env python3
"""JSON pointers, the waitFor condition and expect.resultExcept of case-v1, one implementation for every oracle driver.

Spec: schemas/oracle/case-v1.schema.json `$defs/waitFor` and plans/cmux-next/chrome-parity/p15-oracle.md 3G. Stdlib
only, safe under `python3 -I`. driver_daemon.py (p15-oracle-023) and driver_app_v0.py (p15-oracle-006) both call
`predicate_holds`, so one case means the same thing on every product, which the product-differential comparison
needs. A pointer that does not resolve gives MISSING, not None: `absent` holds only for a missing value, and a
present null is a value (`exists` holds for it).
"""

from __future__ import annotations

import copy
from typing import Any, List, Mapping, Sequence


class _Missing:
    """The value at a pointer that does not resolve (RFC 6901 has no value there)."""

    def __repr__(self) -> str:
        return "MISSING"


MISSING: Any = _Missing()


def decode_pointer(pointer: str) -> List[str]:
    if pointer == "":
        return []
    if not pointer.startswith("/"):
        raise ValueError(f"JSON pointer {pointer!r} does not start with /")
    return [part.replace("~1", "/").replace("~0", "~") for part in pointer[1:].split("/")]


def resolve_pointer(value: Any, pointer: str) -> Any:
    """The value at `pointer` (RFC 6901), or MISSING."""
    for part in decode_pointer(pointer):
        if isinstance(value, dict) and part in value:
            value = value[part]
        elif isinstance(value, list) and part.isdigit() and (part == "0" or not part.startswith("0")) \
                and int(part) < len(value):
            value = value[int(part)]
        else:
            return MISSING
    return value


def predicate_holds(wait: Mapping[str, Any], value: Any, baseline: Any) -> bool:
    """The waitFor condition of case-v1 (`equals` or `predicate`) on the value at its pointer. `baseline` is the
    value read before the step acted (MISSING when the pointer did not resolve then); only `changed` reads it."""
    if "equals" in wait:
        return value is not MISSING and value == wait["equals"]
    predicate = wait["predicate"]
    if isinstance(predicate, str):
        sized = isinstance(value, (list, dict, str))
        return {
            "exists": value is not MISSING,
            "absent": value is MISSING,
            "empty": sized and len(value) == 0,
            "nonEmpty": sized and len(value) > 0,
            "changed": value != baseline,
        }[predicate]
    op, target = predicate["op"], predicate["value"]
    if value is MISSING:
        return False
    if op == "lengthEquals":
        return isinstance(value, (list, dict, str)) and len(value) == target
    if op == "contains":
        if isinstance(value, (str, dict)) and isinstance(target, str):
            return target in value
        return isinstance(value, list) and target in value
    numbers = (int, float)
    if not (isinstance(value, numbers) and isinstance(target, numbers)) or isinstance(value, bool):
        return False
    return {"gt": value > target, "gte": value >= target, "lt": value < target, "lte": value <= target}[op]


def without_pointers(value: Any, pointers: Sequence[str]) -> Any:
    """A copy of `value` without what each pointer names (case-v1 expect.resultExcept): a `*` segment stands for
    every array item or object member there, and a pointer that names nothing removes nothing."""
    out = copy.deepcopy(value)
    for pointer in pointers:
        _remove(out, decode_pointer(pointer))
    return out


def _remove(node: Any, parts: List[str]) -> None:
    head, rest = parts[0], parts[1:]
    if isinstance(node, dict):
        keys = list(node) if head == "*" else [head] if head in node else []
        for key in keys:
            if rest:
                _remove(node[key], rest)
            else:
                del node[key]
    elif isinstance(node, list):
        if head == "*":
            indexes = range(len(node))
        elif head.isdigit() and (head == "0" or not head.startswith("0")) and int(head) < len(node):
            indexes = range(int(head), int(head) + 1)
        else:
            return
        if rest:
            for index in indexes:
                _remove(node[index], rest)
        else:
            for index in reversed(indexes):
                del node[index]
