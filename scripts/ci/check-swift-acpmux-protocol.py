#!/usr/bin/env python3
"""Fails when the Swift app names an acpmux method or param the protocol does not define.

acpmux's wire contract is cmux-tui/crates/acpmux/spec/acpmux-protocol.json, emitted from
its Rust method registry (protocol_ir_is_current keeps it current; the webviews generate
their client from it). The app's Swift side names methods and params by hand:

  * every string literal in the app's Swift sources that has an acpmux method's shape
    (`_acpmux/...`, `session/...`, `acp.*`, `trigger/...`) must be a protocol method;
  * every method and param key in the agent pane's frame policy
    (CmuxNextAgentPane/AcpmuxPaneMethods*.swift: `requests`, `notifications`, `knownParams`)
    must be a protocol method and, where the method's params are typed, a property of them;
  * every `_meta.acpmux` key the app writes into a request (knownParams' second set, and the
    `acpmux["key"] = ...` / `setAcpmuxMeta(...)` / `setDecision(..., field:)` writes) must be a
    property of the protocol's `AcpmuxRequestMeta`.

A name that is not one (a host-side op that shares the shape, a method acpmux has not
registered yet) is listed in scripts/ci/swift-acpmux-protocol-allowlist.txt with its reason.
A listed name the Swift side no longer uses, or that the protocol now defines, fails too, so
the list only shrinks.

Usage: scripts/ci/check-swift-acpmux-protocol.py [--root DIR]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PROTOCOL = "cmux-tui/crates/acpmux/spec/acpmux-protocol.json"
SOURCES = "Packages/macOS/CmuxNext/Sources"
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane"
ALLOWLIST = "scripts/ci/swift-acpmux-protocol-allowlist.txt"

# A literal with an acpmux method's shape.
METHOD_SHAPE = re.compile(r'"((?:_acpmux/|session/|acp\.|trigger/)[A-Za-z0-9_./-]+)"')
STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def strip_comments(text: str) -> str:
    """Swift source without // and /* */ comments (string contents kept)."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if text.startswith('"""', i) or text.startswith('#"""', i):
            # A multiline string: kept whole, so a `//` inside it is not a comment.
            start = i + (1 if c == "#" else 0)
            end = text.find('"""', start + 3)
            end = n if end < 0 else end + 3
            out.append(text[i:end])
            i = end
        elif c == "#" and text.startswith('#"', i):
            # A raw string `#"..."#`: no escapes, so a backslash never ends it early.
            end = text.find('"#', i + 2)
            end = n if end < 0 else end + 2
            out.append(text[i:end])
            i = end
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            chunk = text[i : (end + 2 if end >= 0 else n)]
            out.append("\n" * chunk.count("\n"))
            i = end + 2 if end >= 0 else n
        else:
            out.append(c)
            i += 1
    return "".join(out)


class Protocol:
    def __init__(self, path: Path):
        spec = json.loads(path.read_text())
        self.types = spec["types"]
        self.methods = {m["name"]: m for m in spec["methods"]}

    def _resolve(self, schema):
        if isinstance(schema, dict) and "$ref" in schema:
            return self._resolve(self.types[schema["$ref"].rsplit("/", 1)[-1]])
        return schema

    def properties(self, method: str) -> set[str] | None:
        """The method's param names, or None when its params are untyped or open. A closed object
        with no properties (`{"additionalProperties": false}`) takes no key: an empty set."""
        params = self.methods[method].get("params")
        if not isinstance(params, dict):
            return None
        return self.schema_properties(params)

    def type_properties(self, name: str) -> set[str] | None:
        """A named type's property names (as ``schema_properties``), or None when it is missing."""
        if name not in self.types:
            return None
        return self.schema_properties(self.types[name])

    def schema_properties(self, root) -> set[str] | None:
        names: set[str] = set()
        closed = False
        stack = [root]
        while stack:
            schema = self._resolve(stack.pop())
            if not isinstance(schema, dict):
                return None
            branches = [b for key in ("allOf", "anyOf", "oneOf") for b in schema.get(key, [])]
            # `null` beside an object (an optional param) adds no key.
            if schema.get("type") == "null":
                continue
            is_object = "properties" in schema or schema.get("type") == "object" or "additionalProperties" in schema
            # A JSON Schema object takes keys beyond its properties unless additionalProperties is false.
            if is_object and schema.get("additionalProperties") is not False:
                return None
            if is_object:
                closed = True
            names.update(schema.get("properties", {}))
            stack.extend(branches)
        return names if closed else (names or None)


def swift_string_at(text: str, i: int) -> tuple[int, str] | None:
    """The Swift string literal starting at `i` (`"..."`, `#"..."#`, `\"\"\"...\"\"\"`, `#\"\"\"...\"\"\"#`, any
    number of `#`): (index just past it, its value), or None when no literal starts there. A raw string
    keeps its backslashes; a multiline one is its lines without their common indentation, joined."""
    j = i
    while j < len(text) and text[j] == "#":
        j += 1
    hashes = j - i
    if not text.startswith('"', j):
        return None
    if text.startswith('"""', j):
        close = '"""' + "#" * hashes
        end = text.find(close, j + 3)
        end = len(text) if end < 0 else end
        lines = text[j + 3 : end].split("\n")[1:]
        if lines and not lines[-1].strip():
            lines = lines[:-1]
        value = "\n".join(line.strip() for line in lines)
        return end + len(close), value
    close = '"' + "#" * hashes
    k = j + 1
    value = []
    while k < len(text) and text[k] != "\n":
        if text.startswith(close, k):
            return k + len(close), "".join(value)
        if text[k] == "\\" and hashes == 0:
            value.append(text[k + 1 : k + 2])
            k += 2
            continue
        value.append(text[k])
        k += 1
    return k, "".join(value)


def swift_tokens(text: str) -> list[tuple[str, str]]:
    """Swift source as ("str", value) for each string literal and ("p", char) for each bracket,
    paren, comma or colon; everything else dropped."""
    out: list[tuple[str, str]] = []
    i = 0
    while i < len(text):
        literal = swift_string_at(text, i) if text[i] in '"#' else None
        if literal:
            i, value = literal
            out.append(("str", value))
        elif text[i] in "[](),:":
            out.append(("p", text[i]))
            i += 1
        else:
            i += 1
    return out


def declaration_tokens(text: str, name: str) -> list[tuple[str, str]]:
    """The tokens of `static let NAME: T = [ ... ]`'s array, outer brackets excluded."""
    m = re.search(rf"static let {name}\s*:[^=]*=\s*\[", text)
    if not m:
        return []
    tokens = swift_tokens(text[m.end() :])
    depth = 1
    for index, (kind, value) in enumerate(tokens):
        if kind == "p" and value in "[(":
            depth += 1
        elif kind == "p" and value in "])":
            depth -= 1
            if depth == 0:
                return tokens[:index]
    return tokens


def set_literal(text: str, name: str) -> list[str]:
    """The strings of `static let NAME: Set<String> = [ ... ]` (or `[String]`), raw and multiline included."""
    return [value for kind, value in declaration_tokens(text, name) if kind == "str"]


def known_params_with_meta(text: str) -> dict[str, tuple[list[str], list[str]]]:
    """`knownParams`: method -> (its top-level param names, its `_meta.acpmux` keys)."""
    tokens = declaration_tokens(text, "knownParams")
    out: dict[str, tuple[list[str], list[str]]] = {}
    i = 0
    while i < len(tokens):
        # "method" : ( [ ... ] , [ ... ] )
        if tokens[i][0] == "str" and tokens[i + 1 : i + 3] == [("p", ":"), ("p", "(")]:
            method = tokens[i][1]
            lists: list[list[str]] = []
            j = i + 3
            depth = 1
            current: list[str] | None = None
            while j < len(tokens) and depth:
                kind, value = tokens[j]
                if kind == "p" and value == "[":
                    current = []
                elif kind == "p" and value == "]":
                    lists.append(current or [])
                    current = None
                elif kind == "p" and value == "(":
                    depth += 1
                elif kind == "p" and value == ")":
                    depth -= 1
                elif kind == "str" and current is not None:
                    current.append(value)
                j += 1
            params, meta = out.setdefault(method, ([], []))
            params.extend(lists[0] if lists else [])
            meta.extend(lists[1] if len(lists) > 1 else [])
            i = j
        else:
            i += 1
    return out


def known_params(text: str) -> dict[str, list[str]]:
    """`knownParams`: method -> its top-level param names (the tuple's first set)."""
    return {method: params for method, (params, _) in known_params_with_meta(text).items()}


# The `_meta.acpmux` keys the app writes into a request frame outside knownParams.
META_WRITES = (
    re.compile(r'\bacpmux\["([A-Za-z0-9_]+)"\]\s*=(?!=)'),
    re.compile(r'\bsetAcpmuxMeta\(\s*"([A-Za-z0-9_]+)"'),
    re.compile(r'\bsetAcpmuxMeta\(\s*\[\s*"([A-Za-z0-9_]+)"\s*:'),
    re.compile(r'\bsetDecision\([^)]*\bfield:\s*(?:String\s*=\s*)?"([A-Za-z0-9_]+)"'),
)


def load_allowlist(path: Path) -> dict[str, str]:
    allowed: dict[str, str] = {}
    if not path.exists():
        return allowed
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition(" ")
        if not reason.strip():
            raise SystemExit(f"{path}: '{name}' has no reason")
        allowed[name] = reason.strip()
    return allowed


def check(root: Path) -> list[str]:
    protocol = Protocol(root / PROTOCOL)
    allowed = load_allowlist(root / ALLOWLIST)
    used: set[str] = set()
    problems: list[str] = []

    def unknown(name: str, where: str) -> None:
        used.add(name)
        if name not in allowed:
            problems.append(f"{where}: '{name}' is not in {PROTOCOL}")

    # 1. Method-shaped literals anywhere in the app's sources.
    for path in sorted((root / SOURCES).rglob("*.swift")):
        text = strip_comments(path.read_text(errors="ignore"))
        rel = path.relative_to(root)
        for lineno, line in enumerate(text.splitlines(), 1):
            for name in METHOD_SHAPE.findall(line):
                # A prefix the code joins a name to (`"_acpmux/" + op`) is not a method.
                if name.endswith(("/", ".")):
                    continue
                if name not in protocol.methods:
                    unknown(name, f"{rel}:{lineno}")

    # 2. The agent pane's frame policy: every method it lets through, and their param keys.
    pane = "".join(strip_comments(p.read_text()) for p in sorted((root / PANE).glob("AcpmuxPaneMethods*.swift")))
    methods = set(set_literal(pane, "requests")) | set(set_literal(pane, "notifications"))
    # The first frame of every connection (`static let initialize = "initialize"`).
    methods |= set(re.findall(r'static let initialize\s*=\s*"([^"]+)"', pane))
    params = known_params(pane)
    for method in sorted(methods | set(params)):
        if method not in protocol.methods:
            if method not in used:
                unknown(method, "AcpmuxPaneMethods")
            continue
        names = protocol.properties(method)
        if names is None:
            continue
        for key in params.get(method, []):
            if key not in names:
                unknown(f"{method}#{key}", f"AcpmuxPaneMethods.knownParams[{method}]")

    # 3. The `_meta.acpmux` keys the app writes into requests.
    meta_keys = protocol.type_properties("AcpmuxRequestMeta")
    if meta_keys is None:
        problems.append(f"{PROTOCOL}: no closed AcpmuxRequestMeta type, so the app's _meta.acpmux keys go unchecked")
    else:
        for method, (_, keys) in sorted(known_params_with_meta(pane).items()):
            for key in keys:
                if key not in meta_keys:
                    unknown(f"_meta.acpmux#{key}", f"AcpmuxPaneMethods.knownParams[{method}]")
        for path in sorted((root / PANE).rglob("*.swift")):
            text = strip_comments(path.read_text(errors="ignore"))
            rel = path.relative_to(root)
            for lineno, line in enumerate(text.splitlines(), 1):
                for pattern in META_WRITES:
                    for key in pattern.findall(line):
                        if key not in meta_keys:
                            unknown(f"_meta.acpmux#{key}", f"{rel}:{lineno}")

    for name in sorted(set(allowed) - used):
        if "#" not in name and name in protocol.methods:
            problems.append(f"{ALLOWLIST}: '{name}' is in the protocol now; remove it from the list")
        else:
            problems.append(f"{ALLOWLIST}: '{name}' is no longer named by the Swift side; remove it from the list")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    problems = check(args.root)
    if problems:
        print("The Swift app names acpmux methods or params the protocol does not define:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(
            "Fix the name, register the method in acpmux (its spec regenerates), or list it in "
            f"{ALLOWLIST} with the reason.",
            file=sys.stderr,
        )
        return 1
    print("swift-acpmux-protocol: every Swift method and param is in the protocol (or listed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
