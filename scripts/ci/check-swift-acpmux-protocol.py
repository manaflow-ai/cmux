#!/usr/bin/env python3
"""Fails when the Swift app names an acpmux method or param the protocol does not define.

acpmux's wire contract is cmux-tui/crates/acpmux/spec/acpmux-protocol.json, emitted from
its Rust method registry (protocol_ir_is_current keeps it current; the webviews generate
their client from it). The app's Swift side names methods and params by hand:

  * every string literal in the app's Swift sources that has an acpmux method's shape
    (`_acpmux/...`, `session/...`, `acp.*`, `trigger/...`) must be a protocol method;
  * every method and param key in the agent pane's frame policy
    (CmuxNextAgentPane/AcpmuxPaneMethods*.swift: `requests`, `notifications`, `knownParams`)
    must be a protocol method and, where the method's params are typed, a property of them.

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
        if c == '"':
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
        """The method's param names, or None when its params are untyped or open."""
        params = self.methods[method].get("params")
        if not isinstance(params, dict):
            return None
        names: set[str] = set()
        stack = [params]
        while stack:
            schema = self._resolve(stack.pop())
            if not isinstance(schema, dict):
                return None
            if schema.get("additionalProperties") not in (None, False):
                return None
            names.update(schema.get("properties", {}))
            for key in ("allOf", "anyOf", "oneOf"):
                stack.extend(schema.get(key, []))
        return names or None


def set_literal(text: str, name: str) -> list[str]:
    """The strings of `static let NAME: Set<String> = [ ... ]` (or `[String]`)."""
    m = re.search(rf"static let {name}\s*:[^=]*=\s*\[", text)
    if not m:
        return []
    depth, i = 1, m.end()
    while i < len(text) and depth:
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
        elif text[i] == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j
        i += 1
    return STRING.findall(text[m.end() : i - 1])


def known_params(text: str) -> dict[str, list[str]]:
    """`knownParams`: method -> its top-level param names (the tuple's first set)."""
    m = re.search(r"static let knownParams\s*:[^=]*=\s*\[", text)
    if not m:
        return {}
    depth, i = 1, m.end()
    while i < len(text) and depth:
        if text[i] in "[(":
            depth += 1
        elif text[i] in "])":
            depth -= 1
        elif text[i] == '"':
            j = i + 1
            while text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j
        i += 1
    body = text[m.end() : i - 1]
    out: dict[str, list[str]] = {}
    for entry in re.finditer(r'"([^"]+)"\s*:\s*\(\s*\[([^\]]*)\]', body):
        out.setdefault(entry.group(1), []).extend(STRING.findall(entry.group(2)))
    return out


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
