#!/usr/bin/env python3
"""The nightly's static capability check skips every capability a daemon adds at runtime.

check-daemon-capabilities.sh --static-only compares the app's capability list
(plans/cmux-next/daemon-capabilities.json) with the bundled manifest that
`cmux-tui __daemon-capabilities` writes. That manifest holds only the static
set; `identify_capabilities` in cmux-tui-core's server/capabilities.rs adds
the rest at startup (agent sessions, cloud transport, ...). The script keeps
those in a hand list, `runtime_only`. A capability the app lists that only
`identify_capabilities` adds and that the list misses fails every nightly
build-nightly-app ("the bundled static capability manifest is missing X");
agent-session-folders-v1 did so on 2026-10-31 and no tip reached the feed.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "check-daemon-capabilities.sh"
APP_LIST = ROOT / "plans" / "cmux-next" / "daemon-capabilities.json"
CRATES = ROOT / "cmux-tui" / "crates"
CAPABILITIES_RS = CRATES / "cmux-tui-core" / "src" / "server" / "capabilities.rs"

CONST = re.compile(r'\bconst\s+([A-Z][A-Z0-9_]*)\s*:\s*&(?:\'static\s+)?str\s*=\s*"([^"]+)"')
ALIAS = re.compile(r"\buse\s+([\w:]+)::([A-Z][A-Z0-9_]*)\s+as\s+([A-Z][A-Z0-9_]*)\s*;")
PUSH = re.compile(r"capabilities\s*\.push\(\s*([^()]+?)\s*\)", re.S)


def runtime_only() -> set[str]:
    text = SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"runtime_only\s*=\s*\{(.*?)\}", text, re.S)
    if not match:
        raise AssertionError(f"{SCRIPT}: no runtime_only set")
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def function_body(text: str, name: str) -> str:
    start = re.search(rf"\bfn\s+{name}\b[^{{]*\{{", text)
    if not start:
        raise AssertionError(f"{CAPABILITIES_RS}: no fn {name}")
    depth, index = 1, start.end()
    while depth:
        char = text[index]
        depth += {"{": 1, "}": -1}.get(char, 0)
        index += 1
    return text[start.end():index - 1]


def constants() -> dict[str, list[tuple[Path, str]]]:
    """Each `const NAME: &str = "..."` (value) and `use path::ORIG as NAME;` (alias "use:path::ORIG")."""
    found: dict[str, list[tuple[Path, str]]] = {}
    for path in CRATES.rglob("*.rs"):
        if "target" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for name, value in CONST.findall(text):
            found.setdefault(name, []).append((path, value))
        for module_path, original, alias in ALIAS.findall(text):
            found.setdefault(alias, []).append((path, f"use:{module_path}::{original}"))
    return found


def narrow(candidates: list[tuple[Path, str]], modules: list[str]) -> list[tuple[Path, str]]:
    """The candidates in the module the path names, most specific first: `a::b` is b.rs
    or b/, then a_b.rs (a `#[path]` module file), then a.rs or a/. A path naming a
    re-exported crate (crate::cloud_conversations) matches no file and keeps them all."""
    tests = []
    if modules:
        last = modules[-1]
        tests.append(lambda p: p.stem == last or last in p.relative_to(CRATES).parts[:-1])
    if len(modules) > 1:
        tests.append(lambda p: p.stem == "_".join(modules[-2:]))
        tests.append(lambda p: p.stem == modules[-2] or modules[-2] in p.relative_to(CRATES).parts[:-1])
    for test in tests:
        found = [(p, v) for p, v in candidates if test(p)]
        if found:
            return found
    return candidates


def resolve(expr: str, consts: dict[str, list[tuple[Path, str]]], depth: int = 0) -> str:
    expr = re.sub(r"\s+", "", expr)
    if expr.startswith('"'):
        return expr.strip('"')
    *modules, name = expr.split("::")
    candidates = consts.get(name, [])
    modules = [m for m in modules if m not in ("crate", "super", "self")]
    if modules:
        candidates = narrow(candidates, modules)
    if depth < 4:
        candidates = [(p, resolve(v[4:], consts, depth + 1) if v.startswith("use:") else v)
                      for p, v in candidates]
    values = {v for _, v in candidates}
    if len(values) != 1:
        raise AssertionError(f"cannot resolve {expr} in capabilities.rs to one string: {sorted(values)}")
    return values.pop()


class StaticCapabilityRuntimeOnlyTests(unittest.TestCase):
    def test_runtime_added_app_capabilities_are_runtime_only(self) -> None:
        consts = constants()
        rust = CAPABILITIES_RS.read_text(encoding="utf-8")
        runtime_added = {resolve(e, consts) for e in PUSH.findall(function_body(rust, "identify_capabilities"))}
        app = json.loads(APP_LIST.read_text(encoding="utf-8"))
        needed = set(app.get("required", [])) | set(app.get("optional", []))
        missing = sorted((runtime_added & needed) - runtime_only())
        self.assertEqual(missing, [], f"add these to runtime_only in {SCRIPT.relative_to(ROOT)}: identify_capabilities "
                         "adds them at runtime, so the static manifest never lists them and every nightly fails")

    def test_resolver_finds_the_capability_that_broke_nightly(self) -> None:
        rust = CAPABILITIES_RS.read_text(encoding="utf-8")
        consts = constants()
        resolved = {resolve(e, consts) for e in PUSH.findall(function_body(rust, "identify_capabilities"))}
        self.assertIn("agent-session-folders-v1", resolved)
        self.assertIn("agent-session-start-v1", resolved)


if __name__ == "__main__":
    unittest.main()
