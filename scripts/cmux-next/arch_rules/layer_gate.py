#!/usr/bin/env python3
"""layer-gate: a push may not add a CmuxNext package edge that breaks the layer map, or an unmapped target.

The layer map is plans/cmux-next/architecture-layers.json (core < service < domain < ui < app;
plans/cmux-next/architecture-refactor-DESIGN.md section 2). The rule reads
Packages/macOS/CmuxNext/Package.swift at the push's base and head statically (no swift, about 90 ms for both)
and refuses only what the push adds:

  hard      a new edge A -> B where B is a ui or app target above A's layer
  soft      a new edge from a service target to a domain target, unless the map lists it under
            `exceptions` with a date and a reason
  unmapped  a new regular, executable or binary target that the map does not place (or a target the
            push removes from the map, or gives a layer that is not in `order`)
  relabel   a target whose layer the push changes, unless the push adds a `relayered` entry for it
            with the old and the new layer, a date and a reason (the refusal names the edges whose
            class the relabel changes); until then a new edge is classified with the stricter of the
            base and head layers of each end (the lower one for the source, the higher for the
            dependency), so a relabel in the same push does not clear it
  app       a target newly placed as `app`: only CmuxNextApp, the composition root, is app
  unread    a construct the static reader cannot account for: a dependency expression it cannot
            resolve, a target constructor whose `name:` is not a string literal, a `Package(targets:)`
            entry that is not a constructor or a top-level `let X: Target`, or code that reads or
            changes `package` or a `.targets`/`.dependencies` list after it is built

An edge that is already in the base is never refused (arch-layers.py reports that debt). Test
targets are ignored. Each refusal names the edge and both layers, then the fix: lift the shared type
to a core target, or define a protocol seam in the consumer and conform in the App (DESIGN sections
2-4). Escape once: ARCH_RATCHET_SKIP_REASON="layer-gate: <why>" (the arch ratchet loader applies it
by ID; `skip_reason()` reads it for callers that do not). Local pre-push only, never CI.

Loader contract (scripts/cmux-next/arch_rules/__init__.py): `check(base, head, changes)` returns
(refusals, notes); a refusal is ("layer-gate", text). It reads only `changes.files` and two files at
both ends through `changes.read` (one `git cat-file --batch`); parsing both ends takes about 90 ms.

  scripts/cmux-next/arch_rules/layer_gate.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch_rules/layer_gate.py --base A --head B
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

ID = "layer-gate"
SKIP_ENV = "ARCH_RATCHET_SKIP_REASON"
UPSTREAM = "origin/feat-cmux-next"
ROOT = Path(__file__).resolve().parents[3]
PACKAGE_SWIFT = "Packages/macOS/CmuxNext/Package.swift"
LAYERS_JSON = "plans/cmux-next/architecture-layers.json"
WATCHED = (PACKAGE_SWIFT, LAYERS_JSON)
# Kinds the map must place. Test targets are ignored; plugins, macros and system libraries hold no app code.
MAPPED_KINDS = ("target", "executableTarget", "binaryTarget")
KINDS = MAPPED_KINDS + ("testTarget", "systemLibrary", "plugin", "macro")
UPPER = ("ui", "app")
# The one target the map may place as `app` (DESIGN section 4).
COMPOSITION_ROOT = "CmuxNextApp"
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CONSTRUCTOR = re.compile(r"(?:\bTarget|(?<![\w)\]\"]))\.(" + "|".join(KINDS) + r")\s*\(")
ELEMENT_CONSTRUCTOR = re.compile(r"^(?:Target)?\.(?:" + "|".join(KINDS) + r")\s*\(")
TOP_LET = re.compile(r"^(let|var)\s+(\w+)\s*(?::\s*([^=\n]+?))?\s*=", re.M)
PACKAGE_CALL = re.compile(r"\bPackage\s*\(")
# A read or a change of the built manifest: `package.` or a `.targets`/`.dependencies` member (the
# labels `targets:`/`dependencies:` have no dot). Matched with strings and comments blanked.
AFTER_BUILD = re.compile(r"\bpackage\s*\.|\.\s*(?:targets|dependencies)\b(?!\s*:)")
STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"$')
IDENT = re.compile(r"^\w+$")
FIX = ("fix: lift the shared type to a core target, or define a protocol seam in the consumer and conform "
       "in the App (plans/cmux-next/architecture-refactor-DESIGN.md sections 2-4)")


@dataclass
class Target:
    kind: str
    line: int = 1  # 1-based line of the target's constructor call
    deps: set[str] = field(default_factory=set)
    # Dependency expressions the static reader cannot resolve (a ternary, an untyped variable).
    unresolved: set[str] = field(default_factory=set)


def strip_comments(text: str) -> str:
    """TEXT with `//` and `/* */` comments blanked (newlines kept); string literals stay as they are."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(text[i:end])
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def skip_string(text: str, i: int) -> int:
    """Index after the string literal that starts at TEXT[i] (a `"`)."""
    if text.startswith('"""', i):
        end = text.find('"""', i + 3)
        return len(text) if end < 0 else end + 3
    j = i + 1
    while j < len(text) and text[j] != '"':
        j += 2 if text[j] == "\\" else 1
    return j + 1


def closing(text: str, start: int) -> int:
    """Index of the bracket that closes the one at TEXT[start] (strings skipped), or len(TEXT)."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def split_top(text: str, sep: str) -> list[str]:
    """TEXT split at SEP outside brackets and strings, each part stripped, empty parts dropped."""
    parts, depth, i, last = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(text[last:i])
            last = i + 1
        i += 1
    parts.append(text[last:])
    return [p.strip() for p in parts if p.strip()]


def labeled(args: str) -> dict[str, str]:
    """The labeled arguments of a call (`name: "X"` -> {"name": '"X"'})."""
    out = {}
    for part in split_top(args, ","):
        m = re.match(r"^(\w+)\s*:(?!:)\s*(.*)$", part, re.S)
        if m and m.group(1) not in out:
            out[m.group(1)] = m.group(2).strip()
    return out


def string_value(expr: str) -> str | None:
    m = STRING.match(expr.strip())
    return m.group(1) if m else None


def statement_end(text: str, start: int) -> int:
    """End of the top-level `let` initializer that starts at START: the first newline outside brackets
    after some content whose next line does not continue the expression."""
    depth, i, seen = 0, start, False
    while i < len(text):
        c = text[i]
        if c == '"':
            i = skip_string(text, i)
            seen = True
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "\n" and depth == 0 and seen:
            rest = text[i + 1:].lstrip()
            if not rest[:1] in ("+", ".", "?", ":", "]", ")"):
                return i
        if not c.isspace():
            seen = True
        i += 1
    return len(text)


def blank_strings(code: str) -> str:
    """CODE with the contents of every string literal blanked (quotes and newlines kept, offsets unchanged)."""
    out, i = [], 0
    while i < len(code):
        if code[i] == '"':
            end = skip_string(code, i)
            quote = 3 if code.startswith('"""', i) else 1
            body = code[i + quote:max(i + quote, end - quote)]
            out.append(code[i:i + quote] + re.sub(r"[^\n]", " ", body) + code[i + quote + len(body):end])
            i = end
        else:
            out.append(code[i])
            i += 1
    return "".join(out)


def normalized(expr: str) -> str:
    return " ".join(expr.split())


def shown(expr: str, limit: int = 120) -> str:
    return expr if len(expr) <= limit else expr[:limit - 3] + "..."


@dataclass
class Manifest:
    targets: dict[str, Target]
    # Constructs outside any dependency list that the static reader cannot account for:
    # {normalized text: (1-based line, why)}. A push may not add one (see `refusals`).
    unreadable: dict[str, tuple[int, str]] = field(default_factory=dict)

    def edges(self) -> set[tuple[str, str]]:
        return {(name, dep) for name, t in self.targets.items() if t.kind != "testTarget" for dep in t.deps}


def parse_manifest(text: str) -> Manifest:
    """The targets of a Package.swift and their in-package dependency names, read without swift.

    Targets come from every `.target(`/`.executableTarget(`/... call that is not inside another one
    (a dependency's `.target(name:)` is), including calls bound to top-level variables
    (`let appFFI: Target = .binaryTarget(...)`). A `dependencies:` value is array literals and
    top-level `let` `[Target.Dependency]` variables joined by `+`; `.product(...)` entries name other
    packages and are skipped. A `var` dependency variable is not read (a later statement can append
    to it), so a dependency list that names one is unresolved.

    Everything else that could add a target or an edge is recorded in `unreadable`: a constructor
    whose `name:` is not a string literal (a helper `func`), a `Package(targets:)` entry that is not a
    constructor or a top-level `let X: Target`, and any line that reads or changes the built manifest
    (`package.`, `.targets`, `.dependencies`).
    """
    code = strip_comments(text)
    bare = blank_strings(code)
    dep_vars: dict[str, str] = {}
    target_vars: set[str] = set()
    skip: list[tuple[int, int]] = []
    for m in TOP_LET.finditer(code):
        annotation = (m.group(3) or "").strip()
        if "Dependency" in annotation:
            end = statement_end(code, m.end())
            if m.group(1) == "let":
                dep_vars[m.group(2)] = code[m.end():end]
            skip.append((m.start(), end))
        elif annotation == "Target" and m.group(1) == "let":
            target_vars.add(m.group(2))

    def line_of(index: int) -> int:
        return code.count("\n", 0, index) + 1

    unreadable: dict[str, tuple[int, str]] = {}
    after_build_lines: set[int] = set()
    for m in AFTER_BUILD.finditer(bare):
        line = line_of(m.start())
        if line in after_build_lines:
            continue
        after_build_lines.add(line)
        text_line = code.splitlines()[line - 1]
        unreadable.setdefault(normalized(text_line), (line, "it reads or changes the manifest after it is built"))

    def dependency_names(expr: str, target: Target, seen: frozenset[str] = frozenset()) -> None:
        for part in split_top(expr, "+"):
            if part.startswith("[") and part.endswith("]"):
                for element in split_top(part[1:-1], ","):
                    name = string_value(element)
                    call = re.match(r"^\.(target|byName)\s*\((.*)\)$", element, re.S)
                    if name is not None:
                        target.deps.add(name)
                    elif call and string_value(labeled(call.group(2)).get("name", "")) is not None:
                        target.deps.add(string_value(labeled(call.group(2))["name"]))
                    elif not re.match(r"^\.product\s*\(", element):
                        target.unresolved.add(normalized(element))
            elif IDENT.match(part) and part in dep_vars and part not in seen:
                dependency_names(dep_vars[part], target, seen | {part})
            else:
                target.unresolved.add(normalized(part))

    targets: dict[str, Target] = {}
    pos = 0
    while True:
        m = CONSTRUCTOR.search(code, pos)
        if not m:
            break
        if any(a <= m.start() < b for a, b in skip):
            pos = m.end()
            continue
        open_index = m.end() - 1
        close = closing(code, open_index)
        line = line_of(m.start())
        if line in after_build_lines:
            pos = close + 1  # already unreadable as a whole line (`....dependencies.append(.target(name: "X"))`)
            continue
        args = labeled(code[open_index + 1:close])
        name = string_value(args.get("name", ""))
        if name is not None and name not in targets:
            target = Target(kind=m.group(1), line=line)
            if "dependencies" in args:
                dependency_names(args["dependencies"], target)
            targets[name] = target
        elif m.group(1) != "testTarget":  # test targets are ignored, whatever their name
            why = (f"a second target named {name}" if name is not None
                   else "its `name:` is not a string literal")
            unreadable.setdefault(normalized(code[m.start():close + 1]), (line, why))
        pos = close + 1

    package = PACKAGE_CALL.search(code)
    if package:
        open_index = package.end() - 1
        close = closing(code, open_index)
        listed = labeled(code[open_index + 1:close]).get("targets")
        for part in split_top(listed or "", "+"):
            elements = split_top(part[1:-1], ",") if part.startswith("[") and part.endswith("]") else [part]
            for element in elements:
                call = ELEMENT_CONSTRUCTOR.match(element)
                if element in target_vars or (call and closing(element, call.end() - 1) == len(element) - 1):
                    continue  # one constructor call, read above (a trailing `.method()` is not)
                at = code.find(element, open_index)
                unreadable.setdefault(normalized(element), (line_of(at if at >= 0 else open_index),
                                                            "a `Package(targets:)` entry that is not a target "
                                                            "constructor or a top-level `let X: Target`"))
    return Manifest(targets, unreadable)


def valid_date(value: Any) -> bool:
    """VALUE is a real calendar date written YYYY-MM-DD (the same check as arch-ratchet.py's exceptions)."""
    text = str(value)
    if not DATE.match(text):
        return False
    try:
        datetime.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def edge_class(order: dict[str, int], a: str | None, b: str | None) -> str | None:
    """'hard', 'soft' or None for an edge from a target of layer A to one of layer B (None when unplaced)."""
    if a is None or b is None or a not in order or b not in order:
        return None
    if order[b] > order[a] and b in UPPER:
        return "hard"
    if a == "service" and b == "domain":
        return "soft"
    return None


@dataclass
class LayerMap:
    order: dict[str, int]
    layers: dict[str, str]
    exceptions: dict[tuple[str, str], dict]
    # `relayered` entries: {"target", "from", "to", "date", "reason"} (a dated reason for a relabel).
    relayered: list[dict] = field(default_factory=list)

    @classmethod
    def parse(cls, text: str | None) -> LayerMap:
        spec = json.loads(text) if text else {}
        exceptions = {}
        for entry in spec.get("exceptions", []):
            if isinstance(entry, dict) and "from" in entry and "to" in entry:
                exceptions[(entry["from"], entry["to"])] = entry
        return cls(order={name: i for i, name in enumerate(spec.get("order", []))},
                   layers={name: entry["layer"] for name, entry in spec.get("targets", {}).items()},
                   exceptions=exceptions,
                   relayered=[e for e in spec.get("relayered", []) if isinstance(e, dict)])

    def placed(self, name: str) -> str | None:
        """NAME's layer, or None when the map does not place it or gives it a layer that is not in `order`."""
        layer = self.layers.get(name)
        return layer if layer in self.order else None

    def unmapped(self, manifest: Manifest) -> set[str]:
        return {name for name, t in manifest.targets.items() if t.kind in MAPPED_KINDS and self.placed(name) is None}

    def classify(self, source: str, dep: str) -> str | None:
        """'hard', 'soft' or None for the edge SOURCE -> DEP with this map's layers."""
        return edge_class(self.order, self.placed(source), self.placed(dep))

    def excepted(self, source: str, dep: str) -> tuple[bool, str]:
        entry = self.exceptions.get((source, dep))
        if entry is None:
            return False, ""
        date, reason = str(entry.get("date", "")), str(entry.get("reason", "")).strip()
        if not valid_date(date) or not reason:
            return False, f" (its exception needs a YYYY-MM-DD `date` and a `reason`; it has date {date!r}, reason {reason!r})"
        return True, ""


@dataclass
class Refusal:
    """One refused addition: PATH and NUMBER (1-based, head side) locate it; TEXT says what and the fix."""
    path: str
    number: int
    text: str
    rule: str = ID
    # The arch_counts row that counts the same debt (the count rule may refuse the push under it too).
    row: str = "layer_hard"

    def __str__(self) -> str:
        return f"[{self.rule}] {self.path}:{self.number}: {self.text}"


def relabels(base_map: LayerMap, head_map: LayerMap) -> tuple[set[str], dict[str, str]]:
    """The targets whose relabel the push justifies with a valid `relayered` entry it adds (matching the
    base and head layers), and {target: why} for the entries it adds that do not count."""
    old = {json.dumps(e, sort_keys=True) for e in base_map.relayered}
    justified, invalid = set(), {}
    for entry in head_map.relayered:
        if json.dumps(entry, sort_keys=True) in old:
            continue
        name = str(entry.get("target", ""))
        reason = str(entry.get("reason", "")).strip()
        was, now = base_map.placed(name), head_map.placed(name)
        matches = was is not None and now is not None and entry.get("from") == was and entry.get("to") == now
        if matches and valid_date(entry.get("date")) and reason:
            justified.add(name)
        else:
            invalid[name] = (f" (its `relayered` entry does not count: it needs `from` {was!r}, `to` {now!r}, "
                             f"a YYYY-MM-DD `date` and a `reason`)")
    return justified, invalid


def refusals(base_manifest: str | None, head_manifest: str | None,
             base_layers: str | None, head_layers: str | None) -> list[Refusal]:
    """One refusal per new hard edge, new unexcepted soft edge, new unmapped target, unjustified relabel,
    new non-root `app` target and new construct the reader cannot account for in HEAD over BASE (the
    texts of Package.swift and architecture-layers.json)."""
    if head_manifest is None or base_manifest is None:
        return []  # nothing to compare against (a deleted or brand-new manifest): fail open
    head, base = parse_manifest(head_manifest), parse_manifest(base_manifest)
    head_map, base_map = LayerMap.parse(head_layers), LayerMap.parse(base_layers)
    order = head_map.order
    justified, invalid = relabels(base_map, head_map)
    out = []

    def refuse(name: str, text: str, row: str) -> None:
        out.append(Refusal(PACKAGE_SWIFT, head.targets[name].line, text, row=row))

    def span(name: str) -> tuple[str, str] | None:
        """(lowest, highest) layer of NAME over the base and head maps; the head layer alone when the target
        is new to the map or its relabel is justified. A new edge takes the source's lowest and the
        dependency's highest, so a relabel in the same push cannot clear it."""
        now, was = head_map.placed(name), base_map.placed(name)
        if now is None:
            return None
        if was is None or was not in order or was == now or name in justified:
            return now, now
        return (was, now) if order[was] < order[now] else (now, was)

    def moved(name: str) -> str:
        was, now = base_map.placed(name), head_map.placed(name)
        if was is None or was == now or name in justified:
            return ""
        return f"; {name} is {was} in the base and {now} here, and the gate takes the stricter of the two"

    for name in sorted(head_map.unmapped(head) - base_map.unmapped(base)):
        layer = head_map.layers.get(name)
        state = (f"has layer {layer!r}, which is not in `order`," if layer is not None else "has no layer")
        refuse(name, f"target {name} ({head.targets[name].kind}) {state} in {LAYERS_JSON}: add it under "
                     f"`targets` with the layer it holds (core, service, domain, ui or app; a target that mixes "
                     f"layers takes its highest one and lists the others in `mixes`)", "layer_unplaced")
    for name, target in sorted(head.targets.items()):
        if target.kind not in MAPPED_KINDS:
            continue
        was, now = base_map.placed(name), head_map.placed(name)
        if now == "app" and name != COMPOSITION_ROOT and was != "app":
            refuse(name, f"target {name} is placed as app in {LAYERS_JSON}: only {COMPOSITION_ROOT}, the "
                         f"composition root, is app (DESIGN section 4); give {name} the layer its code holds "
                         f"(core, service, domain or ui)", "layer_hard")
        if was is None or now is None or was == now or name in justified:
            continue
        changed = []
        for source, dep in sorted(head.edges()):
            if name in (source, dep):
                before, after = base_map.classify(source, dep), head_map.classify(source, dep)
                if before != after:
                    changed.append(f"{source} -> {dep} {before or 'allowed'} -> {after or 'allowed'}")
        effect = ("; it changes " + ", ".join(changed)) if changed else "; it changes no edge's class"
        refuse(name, f"target {name} moves from {was} to {now} in {LAYERS_JSON}{effect}{invalid.get(name, '')}: "
                     f"a relabel needs a dated reason the push adds under `relayered`: {{\"target\": \"{name}\", "
                     f"\"from\": \"{was}\", \"to\": \"{now}\", \"date\": \"YYYY-MM-DD\", \"reason\": what changed "
                     f"in its code}}; a relabel that only clears an edge is the debt renamed: {FIX}", "layer_hard")
    for source, dep in sorted(head.edges() - base.edges()):
        ends, deps = span(source), span(dep)
        if ends is None or deps is None:
            continue
        a, b = ends[0], deps[1]
        kind = edge_class(order, a, b)
        if kind is None:
            continue
        note = moved(source) + moved(dep)
        if kind == "hard":
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): a {a} target may not depend on a {b} "
                           f"target{note}; {FIX}", "layer_hard")
            continue
        ok, why = head_map.excepted(source, dep)
        if not ok:
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): a service may not depend on a domain "
                           f"target{note}{why}; {FIX}; or, if it must stay for now, list it under `exceptions` in "
                           f"{LAYERS_JSON} with a date and a reason", "layer_soft")
    for name, target in sorted(head.targets.items()):
        if target.kind == "testTarget":
            continue
        before = base.targets.get(name)
        for expr in sorted(target.unresolved - (before.unresolved if before else set())):
            refuse(name, f"{name}'s dependencies hold `{shown(expr)}`, which the gate cannot read without swift: use "
                         f"string literals, `.target(name:)`/`.product(...)` entries or a top-level "
                         f"`let` `[Target.Dependency]` variable", "layer_hard")
    for expr, (line, why) in sorted(head.unreadable.items(), key=lambda item: item[1][0]):
        if expr in base.unreadable:
            continue
        out.append(Refusal(PACKAGE_SWIFT, line, f"`{shown(expr)}`: the gate cannot read this without swift ({why}): "
                                                f"declare each target as a `.target(name: \"...\", dependencies: "
                                                f"[...])` call in `Package(targets:)` or a top-level `let X: Target`, "
                                                f"with string-literal names and dependencies, and never change "
                                                f"`package` after it is built", row="layer_hard"))
    return out


def blobs(repo, specs: list[tuple[str, str]]) -> list[str | None]:
    """The text of each (rev, path) in REPO from one `git cat-file --batch`, None where the rev lacks it."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    request = "".join(f"{rev}:{path}\n" for rev, path in specs).encode()
    out = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=request, capture_output=True,
                         env=env, check=True).stdout
    texts, pos = [], 0
    for _ in specs:
        newline = out.index(b"\n", pos)
        header = out[pos:newline].split()
        pos = newline + 1
        if len(header) == 3 and header[1] == b"blob":
            size = int(header[2])
            texts.append(out[pos:pos + size].decode("utf-8", "replace"))
            pos += size + 1
        else:
            texts.append(None)
    return texts


def changed_paths(changes: Any) -> list[str]:
    """The paths of CHANGES: `[(status, path)]` (the loader's `changes.files`), paths, or a mapping keyed by path."""
    if isinstance(changes, dict):
        return [str(path) for path in changes]
    return [str(change[-1] if isinstance(change, tuple) else change) for change in changes]


def check_repo(repo: Path | str, base: str, head: str, changed: Iterable[str], read=None) -> list[Refusal]:
    """The refusals for a push from BASE to HEAD in REPO whose changed paths are CHANGED.

    READ, when given, is the loader's `changes.read` ({(rev, path): text} for [(rev, path)]).
    """
    if not any(path in WATCHED for path in changed):
        return []
    specs = [(base, PACKAGE_SWIFT), (head, PACKAGE_SWIFT), (base, LAYERS_JSON), (head, LAYERS_JSON)]
    texts = [read(specs)[spec] for spec in specs] if read else blobs(repo, specs)
    return refusals(*texts)


def check(base: str, head: str, changes: Any = None, repo: Path | str | None = None) -> tuple[list, list]:
    """arch-ratchet entry point: (refusals, notes) for the pushed range BASE..HEAD.

    A refusal is `(ID, text)`, so ARCH_RATCHET_SKIP_REASON="layer-gate: <why>" names it. CHANGES is the
    loader's object (`repo`, `files` as [(status, path)], `read`); None reads the changed paths from git in
    REPO (default: the repository that holds this file).
    """
    root = Path(getattr(changes, "repo", None) or repo or ROOT)
    if changes is None:
        changed = git(root, "diff", "--name-only", "--no-renames", base, head).splitlines()
    else:
        changed = changed_paths(getattr(changes, "files", changes))
    found = check_repo(root, base, head, changed, getattr(changes, "read", None))
    return [(ID, f"{refusal}\n  Escape for this push only: {SKIP_ENV}=\"{ID}: <why>\" (say it in your report; "
                 f"when the count rule refuses the same change, name its row too: \"{ID},{refusal.row}: <why>\").")
            for refusal in found], []


def git(repo: Path | str, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, check=True,
                          text=True).stdout


def skip_reason(env: dict[str, str] | None = None) -> str | None:
    """The why of an ARCH_RATCHET_SKIP_REASON="<rule>[,<rule>]: <why>" that names this rule, else None."""
    value = (os.environ if env is None else env).get(SKIP_ENV, "").strip()
    named, colon, why = value.partition(":")
    return why.strip() if colon and why.strip() and ID in {r.strip() for r in named.split(",")} else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base", help="default: the merge base of HEAD and origin/feat-cmux-next")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    repo = Path(args.repo) if args.repo else ROOT
    base = args.base or git(repo, "merge-base", args.head, UPSTREAM).strip()
    found = check_repo(repo, base, args.head, git(repo, "diff", "--name-only", "--no-renames", base, args.head).splitlines())
    if not found:
        print(f"{ID}: ok")
        return 0
    for refusal in found:
        print(refusal)
    why = skip_reason()
    if why:
        print(f"{ID}: skipped ({SKIP_ENV}): {why}")
        return 0
    print(f'{ID}: escape once with {SKIP_ENV}="{ID}: <why>" and say it in your report')
    return 1


if __name__ == "__main__":
    sys.exit(main())
