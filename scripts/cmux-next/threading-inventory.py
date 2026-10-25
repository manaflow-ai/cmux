#!/usr/bin/env python3
"""Whole-tree threading inventory: every line of a revision judged by the pre-push threading rules.

guardrails.py judges only what a push adds. This tool imports it (its rules unchanged) and judges every Swift line
under Packages/macOS/CmuxNext/Sources at REV as a push from the empty tree (4b825dc6) would add it, so the
p02-threads machine queues (plans/cmux-next/chrome-parity/p02-threads.md section 6) come from the same definitions
the hook refuses. The rules model Chromium's blocking discipline: base/threading/scoped_blocking_call.h (a blocking
call is marked and may not run on the UI thread) and base/threading/thread_restrictions.h (the reviewed allow list).

Rules: main-blocking, raw-blocking, maybe-main-blocking, task-priority, thread-doc. The hook gives a raw primitive
that surely runs on main to main-blocking only (one refusal per line); the inventory lists each line under every
rule it breaks, so raw-blocking here also holds the raw primitives main-blocking took (each still needs its seam).

Each hit carries its call-graph context, read lexically from the source:
  enclosing_func  `Type.name` of the function, initializer, subscript or computed property around the line
  is_async        whether that declaration is `async` (effects after its parameter list)
  isolation       main | pool | nonisolated | actor: the innermost main-thread opener (`MainActor.run {`), pool
                  opener (`Task.detached {`, `queue.async {`, a global queue), or declaration that states isolation
                  (`@MainActor`, `@concurrent`, `nonisolated`, an `actor`), else the target's default
  caller_count    call sites `name(` of the function where Swift lets them be: its file (`private`), its module
                  (internal, the default) or all Sources (`public`, `package`, `open`); `Type(` for an initializer;
                  null for a deinit, subscript or accessor. A name-based fan-in: an upper bound when other types of
                  that scope share the name. Lexical: an extension in another file does not tell its type's isolation.

  threading-inventory.py --count                                   # hits per rule at HEAD
  threading-inventory.py --rev 772cdfc45ac --count
  threading-inventory.py --rule raw-blocking --group root --max-hits 25
  threading-inventory.py --rule main-blocking --jsonl
  threading-inventory.py --rule raw-blocking --paths Packages/macOS/CmuxNext/Sources/CmuxNextFiles/

Reads git objects only (ls-tree, cat-file): no network, no file writes, not even bytecode caches. Not a CI gate
(Lawrence 2026-10-23); run it yourself.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # importing guardrails and its siblings must not write __pycache__

import argparse
import collections
import fnmatch
import importlib.util
import json
import re
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent


def load_guardrails():
    """guardrails.py beside this file, as a module: the rules are read from it, never copied."""
    spec = importlib.util.spec_from_file_location("cmux_next_guardrails_inventory", HERE / "guardrails.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


g = load_guardrails()
RULE_BY_ID = {rule.id: rule for rule in g.RULES}


def raw_blocking(changes: list, moved: collections.Counter) -> list:
    """guardrails' raw-blocking hits plus the raw primitives its main-blocking rule took (they still need a seam)."""
    hits = g.raw_blocking(changes, moved)
    for hit in g.blocking_on_main(changes, moved):
        code = g.code_of(hit.text)
        if g.blocking_match(g.RAW_SCAN, code) and not g.ALWAYS_SCAN.search(code):
            hits.append(hit)
    return hits


def guardrails_rule(rule_id: str) -> Callable[[list, collections.Counter], list]:
    return RULE_BY_ID[rule_id].find


# The inventory's rules, in report order. Later p02-threads tasks add theirs here.
RULES: dict[str, Callable[[list, collections.Counter], list]] = {
    "main-blocking": guardrails_rule("main-blocking"),
    "raw-blocking": raw_blocking,
    "maybe-main-blocking": guardrails_rule("maybe-main-blocking"),
    "task-priority": guardrails_rule("task-priority"),
    "thread-doc": guardrails_rule("thread-doc"),
}

# Where on the hit line the judged call starts: braces before it enclose the call, braces after it are its own.
LOCATORS = {
    "task-priority": g.TASK_CALL,
    "thread-doc": g.THREAD_SCAN.pattern,
}
DEFAULT_LOCATOR = g.MAIN_SCAN.pattern
ALWAYS = g.ALWAYS_BLOCKING

NEVER = re.compile(r"(?!)")
POOL_OPENER = re.compile(r"\bTask\.detached\b|\bDispatchQueue\.global\(|\.concurrentPerform\b|\bdetachNewThread\b"
                         r"|(?:^|[=(,]\s*|\breturn\s+)Thread\s*(\{|\(block:)|\baddOperation\s*\{"
                         r"|(?<!\bmain)\.async(After)?\s*(\([^{]*\))?\s*\{")
FUNC_KINDS = {"func", "init", "deinit", "subscript"}
ACCESSORS = {"get", "set", "willSet", "didSet", "_read", "_modify"}
TYPE_KINDS = {"class", "struct", "enum", "actor", "extension", "protocol"}
FUNC_NAME = re.compile(r"\bfunc\s+`?([^\s(<`]+)")
VAR_NAME = re.compile(r"\bvar\s+`?(\w+)")
VAR_KEYWORD = re.compile(r"\bvar\b")
TYPE_NAME = re.compile(r"\b(?:class|struct|enum|actor|protocol)\s+(\w+)|\bextension\s+([\w.]+)")
EFFECTS = re.compile(r"\s*((?:async|reasync|throws(?:\s*\([^)]*\))?|rethrows)\b\s*)*")
NONISOLATED = re.compile(r"\bnonisolated\b(?!\s*\(unsafe\))")
PRIVATE = re.compile(r"\b(private|fileprivate)\b(?!\s*\(set\))")
PUBLIC = re.compile(r"\b(public|open|package)\b(?!\s*\(set\))")
CALL = re.compile(r"(?<![\w$])`?(\w+)`?\s*\(")
NOT_A_CALL_BEFORE = re.compile(r"(\bfunc|\bcase\s*\.?|\bcase\s+let\s+\.?)\s*$")


@dataclass
class Hit:
    rule: str
    path: str
    line: int
    module: str
    ui_target: bool
    text: str
    enclosing_func: str | None
    is_async: bool | None
    isolation: str
    caller_count: int | None
    enclosing_type: str | None = None
    group: str | None = None
    # Not reported: what caller_count and --group root need.
    func_name: str | None = field(default=None, repr=False)
    func_line: int | None = field(default=None, repr=False)
    func_scope: tuple[str, str] | None = field(default=None, repr=False)

    def record(self) -> dict:
        out = asdict(self)
        for key in ("func_name", "func_line", "func_scope"):
            out.pop(key)
        if out["group"] is None:
            out.pop("group")
        return out


@dataclass
class Context:
    enclosing_func: str | None = None
    func_name: str | None = None  # the name a call site uses (`Type` for an initializer)
    func_kind: str | None = None
    func_line: int | None = None  # 1-based line of the declaration's `{`
    func_access: str | None = None  # file | tree | None (unstated) from the declaration's own modifiers
    type_access: str | None = None  # file | tree | module of the innermost type or extension around it
    type_is_extension: bool = False
    is_async: bool | None = None
    isolation: str | None = None
    types: list[str] = field(default_factory=list)  # innermost first


HEADER_END = re.compile(r"[{};]\s*$|^\s*$|^\s*(//|\*|/\*)")


def declaration_header(lines: list[str], number: int, opener: str) -> tuple[str, str]:
    """(header, attribute lines above it) of the block that opens on 1-based line NUMBER. A one-line header is the
    opener; a wrapped one is joined back to the previous statement's end, like guardrails' block_header, except
    that a line starting with an attribute (`@concurrent static func f(`) belongs to it: block_header stops there."""
    k = number - 2
    parts = [opener]
    if not g.DECLARATION_OPENER.search(opener):
        while k >= 0 and number - 1 - k <= g.HEADER_LINES:
            text = g.code_of(lines[k])
            if HEADER_END.search(text) or g.ATTRIBUTE_LINE.match(text):
                break
            parts.insert(0, text)
            k -= 1
    above = []
    while k >= 0 and (g.ATTRIBUTE_LINE.match(lines[k]) or g.COMMENT_LINE.match(lines[k])
                      or g.code_of(lines[k]).strip() == "nonisolated"):
        if not g.COMMENT_LINE.match(lines[k]):
            above.insert(0, g.code_of(lines[k]).strip())
        k -= 1
    return " ".join(part.strip() for part in parts), " ".join(above)


def access_of(prefix: str) -> str | None:
    """Where a declaration with these modifiers can be called from: its file, the whole tree, or unstated."""
    if PRIVATE.search(prefix):
        return "file"
    if PUBLIC.search(prefix):
        return "tree"
    return None


def call_scope(ctx: Context) -> str:
    """Where the enclosing function's callers can be (Swift access control): file, module or tree. A member is
    internal unless it says otherwise, a `public extension` makes its members public, and a private type keeps
    its members in its file."""
    if "file" in (ctx.func_access, ctx.type_access):
        return "file"
    if ctx.func_access == "tree":
        return "tree" if ctx.type_access in (None, "tree") else "module"
    return "tree" if ctx.type_is_extension and ctx.type_access == "tree" else "module"


def declared_isolation(prefix: str, kind: str) -> str | None:
    if "@MainActor" in prefix:
        return "main"
    if "@concurrent" in prefix:
        return "pool"
    if NONISOLATED.search(prefix):
        return "nonisolated"
    if kind == "actor":
        return "actor"
    return None


def is_async(header: str, keyword_end: int, kind: str) -> bool:
    """Whether the declaration's effects (after its parameter list, or after an accessor keyword) say `async`."""
    rest = header[keyword_end:]
    if kind in FUNC_KINDS:
        if kind == "deinit":
            return False
        start = rest.find("(")
        if start < 0:
            return False
        depth = 0
        for i in range(start, len(rest)):
            depth += rest[i] == "("
            depth -= rest[i] == ")"
            if depth == 0:
                rest = rest[i + 1:]
                break
        else:
            return False
    elif kind == "var":
        return False
    return "async" in EFFECTS.match(rest).group(0).split()


def context_of(lines: list[str], index: int, prefix: str, default_main: bool) -> Context:
    """The declaration, isolation and enclosing types of LINES[INDEX] (0-based), walking its openers outward."""
    ctx = Context()
    accessor: tuple[str, int, str, int] | None = None  # (keyword, opener line, header, keyword end)
    for opener, number in g.enclosing_openers(lines, index, NEVER, prefix):
        line_code = g.code_of(lines[number - 1])
        header, attributes = declaration_header(lines, number, opener) if number - 1 != index else (opener, "")
        match = g.DECLARATION_OPENER.search(header)
        if match is None:
            if ctx.isolation is None and ctx.func_kind is None:
                if g.MAIN_OPENER.search(opener) or g.MAIN_OPENER.search(line_code):
                    ctx.isolation = "main"
                elif POOL_OPENER.search(opener):
                    ctx.isolation = "pool"
            continue  # control flow, or a closure that inherits its context's isolation
        kind = match.group(4) or "var"
        kind = "init" if kind.startswith("init") else kind
        keyword_start = match.start(4) if match.group(4) else VAR_KEYWORD.search(header).start()
        keyword_end = match.end(4) if match.group(4) else keyword_start + 3
        decl_prefix = f"{attributes} {header[:keyword_start]}"
        if ctx.isolation is None:
            ctx.isolation = declared_isolation(decl_prefix, kind)
        if kind in ACCESSORS:
            accessor = accessor or (kind, number, header, keyword_end)
            continue
        if kind in TYPE_KINDS:
            if ctx.type_access is None:
                ctx.type_access = access_of(decl_prefix) or "module"
                ctx.type_is_extension = kind == "extension"
            name = TYPE_NAME.search(header[keyword_start:])
            if name:
                ctx.types.append((name.group(1) or name.group(2)).split(".")[-1])
            if accessor is not None and ctx.func_kind is None:
                ctx.func_kind, ctx.func_name, ctx.func_line = accessor[0], None, accessor[1]
                ctx.is_async = is_async(accessor[2], accessor[3], accessor[0])
            continue
        if ctx.func_kind is not None:
            continue  # a local function's outer function: the hit belongs to the innermost one
        ctx.func_kind, ctx.func_line = kind, number
        ctx.func_access = access_of(decl_prefix)
        if kind == "func":
            found = FUNC_NAME.search(header)
            ctx.func_name = found.group(1) if found else None
            ctx.is_async = is_async(header, keyword_end, kind)
        elif kind == "var":
            found = VAR_NAME.search(header)
            ctx.func_name = found.group(1) if found else None
            ctx.is_async = is_async(accessor[2], accessor[3], accessor[0]) if accessor else False
        else:
            ctx.func_name = kind
            ctx.is_async = is_async(header, keyword_end, kind)
    if ctx.isolation is None:
        ctx.isolation = "main" if default_main else "nonisolated"
    if ctx.func_kind is not None:
        outer = ctx.types[0] if ctx.types else None
        own = ctx.func_name or ctx.func_kind
        ctx.enclosing_func = f"{outer}.{own}" if outer else own
        if ctx.func_kind == "init":
            ctx.func_name = outer  # an initializer is called by its type's name
        elif ctx.func_kind not in ("func",):
            ctx.func_name = None  # deinit, subscript, accessors: no name-based call site
    return ctx


# ---------------------------------------------------------------- the tree


@dataclass
class Tree:
    """The Swift sources of one revision ({path: text}) and the files the rules read beside them."""
    sources: dict[str, str]
    threading_doc: str | None = None
    manifest: str | None = None


def read_tree(repo: Path, rev: str) -> Tree:
    listing = g.git(repo, "ls-tree", "-r", "--name-only", rev, "--", g.SOURCES)
    paths = [p for p in listing.split("\n") if p.endswith(".swift")]
    texts = g.blobs(repo, [(rev, p) for p in paths] + [(rev, g.THREADING_DOC), (rev, g.PACKAGE_MANIFEST)])
    return Tree({p: texts[(rev, p)] for p in paths if (rev, p) in texts},
                texts.get((rev, g.THREADING_DOC)), texts.get((rev, g.PACKAGE_MANIFEST)))


def path_matcher(patterns: list[str] | None) -> Callable[[str], bool]:
    """A path filter: each pattern is a repo-relative file, folder (prefix) or fnmatch glob (`*` crosses folders)."""
    if not patterns:
        return lambda path: True
    cleaned = [p[2:] if p.startswith("./") else p for p in patterns]

    def match(path: str) -> bool:
        for pattern in cleaned:
            if any(c in pattern for c in "*?["):
                if fnmatch.fnmatchcase(path, pattern):
                    return True
            elif path == pattern or path.startswith(pattern.rstrip("/") + "/"):
                return True
        return False
    return match


def file_change(path: str, text: str):
    """PATH as a new file: every line added over the empty tree."""
    lines = text.split("\n")
    return g.FileChange(path, lines, added=[g.Added(path, i + 1, line) for i, line in enumerate(lines)],
                        base_lines=[], is_new=True)


def judge(tree: Tree, rules: Iterable[str], paths: Callable[[str], bool]) -> list[tuple[str, object]]:
    """[(rule, guardrails hit)] over the matching files, each rule judging every line against the empty tree."""
    texts: dict[tuple[str, str], str] = {}
    rev = "inventory"
    if tree.threading_doc is not None:
        texts[(rev, g.THREADING_DOC)] = tree.threading_doc
    if tree.manifest is not None:
        texts[(rev, g.PACKAGE_MANIFEST)] = tree.manifest
    g.load_blocking_context(texts, rev)
    targets = g.swift_scope.package_targets(tree.manifest or "")
    changes = []
    for path in sorted(tree.sources):
        if not paths(path):
            continue
        change = file_change(path, tree.sources[path])
        change.head_main = change.base_main = g.main_by_default(path, targets)
        changes.append(change)
    found = []
    for rule_id in rules:
        rule = RULE_BY_ID.get(rule_id)
        scope = rule.scope if rule is not None else (g.SOURCES,)
        scoped = [c for c in changes if c.path.startswith(scope)]
        found += [(rule_id, hit) for hit in RULES[rule_id](scoped, collections.Counter())]
    return found


Scope = tuple[str, str]  # ("file", path) | ("module", module) | ("tree", "")


def scope_key(scope: str, path: str) -> Scope:
    return (scope, path if scope == "file" else g.module_of(path) if scope == "module" else "")


def caller_counts(tree: Tree, wanted: dict[str, set[Scope]]) -> dict[tuple[str, Scope], int]:
    """{(name, scope): call sites of NAME inside SCOPE} for each scope WANTED asks of a name. A call site is `name(`
    in code (comments and string contents dropped), not `func name(` or an enum case pattern."""
    counts: dict[tuple[str, Scope], int] = collections.Counter()
    if not wanted:
        return counts
    for path, text in tree.sources.items():
        here = {("file", path), ("module", g.module_of(path)), ("tree", "")}
        for line in text.split("\n"):
            if "(" not in line:
                continue
            code = g.code_of(line)
            for match in CALL.finditer(code):
                scopes = wanted.get(match.group(1))
                if scopes is None or NOT_A_CALL_BEFORE.search(code[:match.start()]):
                    continue
                for scope in scopes & here:
                    counts[(match.group(1), scope)] += 1
    return counts


def inventory(tree: Tree, rules: Iterable[str] = tuple(RULES), paths: Callable[[str], bool] = lambda p: True
              ) -> list[Hit]:
    """Every hit of RULES in TREE's files that PATHS matches, with its call-graph context, in rule then path order."""
    rules = list(rules)
    found = judge(tree, rules, paths)
    targets = g.ui_targets()  # judge() loaded TREE's manifest
    lines_of: dict[str, list[str]] = {}
    hits = []
    for rule_id, hit in found:
        lines = lines_of.setdefault(hit.path, tree.sources[hit.path].split("\n"))
        index = hit.number - 1
        code = g.code_of(lines[index])
        locator = LOCATORS.get(rule_id, DEFAULT_LOCATOR)
        match = locator.search(code) or ALWAYS.search(code)
        prefix = code[:match.start()] if match else code
        module = g.module_of(hit.path)
        ctx = context_of(lines, index, prefix, module in targets)
        hits.append(Hit(rule_id, hit.path, hit.number, module, module in targets, lines[index].strip(),
                        ctx.enclosing_func, ctx.is_async, ctx.isolation, None,
                        ctx.types[0] if ctx.types else None, func_name=ctx.func_name, func_line=ctx.func_line,
                        func_scope=scope_key(call_scope(ctx), hit.path) if ctx.func_name else None))
    wanted: dict[str, set[Scope]] = collections.defaultdict(set)
    for hit in hits:
        if hit.func_name:
            wanted[hit.func_name].add(hit.func_scope)
    counts = caller_counts(tree, wanted)
    for hit in hits:
        if hit.func_name:
            hit.caller_count = counts.get((hit.func_name, hit.func_scope), 0)
    order = {rule: i for i, rule in enumerate(rules)}
    hits.sort(key=lambda h: (order[h.rule], h.path, h.line))
    return hits


# ---------------------------------------------------------------- grouping


def chunked(label: str, items: list, size: int) -> list[tuple[str, list]]:
    parts = [items[i:i + size] for i in range(0, len(items), size)] or [[]]
    if len(parts) == 1:
        return [(label, parts[0])]
    return [(f"{label}#{n}", part) for n, part in enumerate(parts, 1)]


def group_by_module(hits: list[Hit], max_hits: int) -> list[tuple[str, list[Hit]]]:
    by_module: dict[str, list[Hit]] = collections.defaultdict(list)
    for hit in hits:
        by_module[hit.module].append(hit)
    out = []
    for module in sorted(by_module):
        out += chunked(f"module:{module}", sorted(by_module[module], key=lambda h: (h.path, h.line)), max_hits)
    return out


RECEIVER = re.compile(r"(?:\b(\w+)\s*)?\.\s*$")


def callees(candidates: list, before: str, caller: Hit, units: dict) -> list:
    """The units of CANDIDATES (same module and name) a call resolves to by its receiver: a bare, `self.` or
    `Self.` call is the caller's own type's (a bare call else a free function's), `Type.name(` that type's. A call
    on a value (`data.write(`, `raw.append(`) names no type lexically, so it joins nothing."""
    receiver = RECEIVER.search(before)
    if receiver is None or receiver.group(1) in ("self", "Self"):
        own = [k for k in candidates if units[k][0].enclosing_type == caller.enclosing_type]
        return own or ([k for k in candidates if units[k][0].enclosing_type is None] if receiver is None else [])
    name = receiver.group(1)
    if not name or not name[0].isupper():
        return []
    return [k for k in candidates if units[k][0].enclosing_type == name]


def group_by_root(tree: Tree, hits: list[Hit], max_hits: int) -> list[tuple[str, list[Hit]]]:
    """Hits in chunks of at most MAX_HITS that follow the call graph: the functions holding hits are joined when
    one calls another in the same module (a call `name(` in its body), so a caller and its callee land in one
    chunk; components of one module are packed together up to MAX_HITS, a larger one is split. A chunk is named
    by its first component's root: the function no other function of the component calls."""
    units: dict[tuple[str, int | None], list[Hit]] = collections.defaultdict(list)
    for hit in hits:
        units[(hit.path, hit.func_line)].append(hit)
    keys = sorted(units, key=lambda k: (k[0], k[1] or 0))
    parent = {k: k for k in keys}

    def find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    by_name: dict[tuple[str, str], list] = collections.defaultdict(list)
    for key in keys:
        hit = units[key][0]
        if hit.func_name and key[1] is not None:
            by_name[(hit.module, hit.func_name)].append(key)
    called: set = set()
    for key in keys:
        path, opener = key
        if opener is None:
            continue
        lines = tree.sources[path].split("\n")
        caller = units[key][0]
        end = g.block_end(lines, opener - 1)
        for k in range(opener - 1, end + 1):
            code = g.code_of(lines[k])
            for match in CALL.finditer(code) if "(" in code else ():
                candidates = by_name.get((caller.module, match.group(1)))
                for callee in callees(candidates, code[:match.start()], caller, units) if candidates else ():
                    if callee != key:
                        called.add(callee)
                        parent[find(callee)] = find(key)
    components: dict = collections.defaultdict(list)
    for key in keys:
        components[find(key)].append(key)

    def root_label(members: list) -> str:
        roots = [k for k in members if k not in called] or members
        hit = units[roots[0]][0]
        return f"{hit.module}/{hit.enclosing_func or Path(hit.path).name}"

    ordered = sorted(components.values(), key=lambda m: (units[m[0]][0].module, m[0][0], m[0][1] or 0))
    out: list[tuple[str, list[Hit]]] = []
    pending: list[Hit] = []
    pending_label, pending_module = "", ""
    for members in ordered:
        member_hits = sorted((h for k in members for h in units[k]), key=lambda h: (h.path, h.line))
        module = member_hits[0].module
        if pending and (module != pending_module or len(pending) + len(member_hits) > max_hits):
            out.append((pending_label, pending))
            pending = []
        if len(member_hits) > max_hits:
            out += chunked(f"root:{root_label(members)}", member_hits, max_hits)
            continue
        if not pending:
            pending_label, pending_module = f"root:{root_label(members)}", module
        pending += member_hits
    if pending:
        out.append((pending_label, pending))
    seen: collections.Counter = collections.Counter(label for label, _ in out)
    numbered: collections.Counter = collections.Counter()
    unique = []
    for label, chunk in out:
        if seen[label] > 1 and "#" not in label:
            numbered[label] += 1
            label = f"{label}~{numbered[label]}"
        unique.append((label, chunk))
    return unique


# ---------------------------------------------------------------- output


def describe(hit: Hit) -> str:
    where = [hit.enclosing_func or "type level", hit.isolation]
    if hit.is_async is not None:
        where.append("async" if hit.is_async else "sync")
    if hit.caller_count is not None:
        where.append(f"callers {hit.caller_count}")
    return f"{hit.path}:{hit.line}: [{hit.rule}] {hit.text}  ({', '.join(where)})"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rule", action="append", default=None,
                        help=f"a rule to report (repeat or comma-separate; default all): {', '.join(RULES)}")
    parser.add_argument("--paths", nargs="+", action="extend", default=None,
                        help="repo-relative files, folders or globs to judge (default: all of Sources)")
    parser.add_argument("--count", action="store_true", help="print the hits per rule (and per group with --group)")
    parser.add_argument("--group", choices=("module", "root"), help="chunk the hits by module or call-graph root")
    parser.add_argument("--max-hits", type=int, default=None, help="hits per chunk with --group (default 25)")
    parser.add_argument("--jsonl", action="store_true", help="one JSON object per hit (or the counts as JSON)")
    parser.add_argument("--rev", default="HEAD", help="the revision to judge (default HEAD)")
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    args = parser.parse_args(argv)
    rules = [r.strip() for value in (args.rule or []) for r in value.split(",") if r.strip()]
    unknown = [r for r in rules if r not in RULES]
    if unknown:
        parser.error(f"unknown rule {', '.join(unknown)}; known: {', '.join(RULES)}")
    args.rules = rules or list(RULES)
    if args.max_hits is not None and args.group is None:
        parser.error("--max-hits needs --group")
    if args.max_hits is not None and args.max_hits < 1:
        parser.error("--max-hits must be at least 1")
    args.max_hits = args.max_hits or 25
    return args


def repo_root(repo: Path | None) -> Path:
    if repo is not None:
        return repo.resolve()
    result = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(result.stdout.strip()) if result.returncode == 0 else HERE.parents[1]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    tree = read_tree(repo_root(args.repo), args.rev)
    try:
        hits = inventory(tree, args.rules, path_matcher(args.paths))
    except RuntimeError as error:  # thread-doc without the threading doc at REV
        print(f"threading-inventory: {error}", file=sys.stderr)
        return 2
    groups: list[tuple[str, list[Hit]]] = []
    if args.group == "module":
        groups = group_by_module(hits, args.max_hits)
    elif args.group == "root":
        groups = group_by_root(tree, hits, args.max_hits)
    for label, chunk in groups:
        for hit in chunk:
            hit.group = label
    if args.count:
        totals = collections.Counter(h.rule for h in hits)
        counts = {rule: totals[rule] for rule in args.rules}
        if args.jsonl:
            print(json.dumps({"rules": counts, **({"groups": {label: len(c) for label, c in groups}} if groups else {})}))
        else:
            for rule, n in counts.items():
                print(f"{rule} {n}")
            for label, chunk in groups:
                print(f"{label} {len(chunk)}")
        return 0
    if args.jsonl:
        ordered = [h for _, chunk in groups for h in chunk] if groups else hits
        for hit in ordered:
            print(json.dumps(hit.record()))
        return 0
    if groups:
        for label, chunk in groups:
            print(f"== {label} ({len(chunk)} hits)")
            for hit in chunk:
                print(describe(hit))
        return 0
    for hit in hits:
        print(describe(hit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
