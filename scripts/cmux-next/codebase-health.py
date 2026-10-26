#!/usr/bin/env python3
"""Measure cmux-next codebase health: the debt the guardrails ratchet (plans/cmux-next/codebase-health.md).

Counts code (comments stripped) in Packages/macOS/CmuxNext/Sources and in the Sources of every package of its local
package closure (arch_counts.read_paths at HEAD: the arch ratchet's scope since method v5): stateful singletons and global mutable
statics, MainActor.assumeIsolated, @unchecked Sendable, nonisolated(unsafe), raw locks, sleeps, main-queue hops,
NotificationCenter broadcast names and their observers, NSHostingView, #if DEBUG, plus target sizes, the
Package.swift target graph checked against the 5-layer rule (CLAUDE.md "Refactor architecture"), docs sprawl
with stale references, and script and workflow counts. Reads the working tree's tracked files only.

The singleton, global-static, assumeIsolated, broadcast-name and observer rows and the layer edges are
scripts/cmux-next/arch_counts.py's (count_texts(), layers(), observer_registrations()): the definitions
plans/cmux-next/arch-ratchet.json and the pre-push ratchet hold, so the reports never disagree. An observer is a
registration, counted through wrappers such as `MainActorObservation(` (each use of a wrapper that a caller
configures counts, the wrapper's own body does not), and a call may span lines.

  scripts/cmux-next/codebase-health.py           # print the report
  scripts/cmux-next/codebase-health.py --write   # rewrite plans/cmux-next/codebase-health.md
"""
from __future__ import annotations

import argparse
import collections
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent

PKG = "Packages/macOS/CmuxNext"
SOURCES = PKG + "/Sources/"
APP = "CmuxNextApp"
OUT = "plans/cmux-next/codebase-health.md"
UPSTREAM = "origin/feat-cmux-next"
# What the report reads besides the app sources: every Swift file (section 6), the plans, the scripts, the workflows.
MEASURED = ("*.swift", "plans/cmux-next/", "scripts/cmux-next/", ".github/workflows/", f":(exclude){OUT}")
BENCHES = "scripts/cmux-next/perf-hot-benches.json"

def load_arch_counts():
    """scripts/cmux-next/arch_counts.py: the one definition of the architecture rows and the layer rule."""
    name = "cmux_next_arch_counts"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


ARCH = load_arch_counts()

# (id, title, arch_counts row, the row of the sites outside seam adapters or None, note)
ARCH_CATEGORIES = (
    ("singleton", "stateful singletons and globals (arch_counts `stateful_singletons`)", "stateful_singletons", None,
     "runtime state behind a global, under any name; construct at the composition root and inject "
     "(CLAUDE.md Package design discipline)"),
    ("global_static", "global mutable statics (arch_counts `global_mutable_statics`)", "global_mutable_statics", None,
     "a static or file-scope var, lock or cache: state no owner injects"),
    ("assume_isolated", "`MainActor.assumeIsolated`", "assume_isolated_total", "assume_isolated_outside_adapters",
     "traps off main; allowed only in a small seam adapter with `// main-proof: <why>`"),
    ("observers", "NotificationCenter observers (registrations through wrappers such as `MainActorObservation(`, "
     "KVO included; arch_counts `observer_sites`)", "observer_sites", None, "each one wakes on every post of its name"),
    ("notification_names", "custom `Notification.Name` declarations (arch_counts `app_broadcast_names`)",
     "app_broadcast_names", None, "a broadcast signal: every observer reacts, O(all)"),
)

# (id, title, pattern on comment-stripped code, waiver marker or None, note)
CATEGORIES = (
    ("unchecked_sendable", "`@unchecked Sendable`", r"@unchecked\s+Sendable\b", r"crash-allow:",
     "a data race the compiler cannot see; needs `// crash-allow: <safety argument>`"),
    ("nonisolated_unsafe", "`nonisolated(unsafe)`", r"\bnonisolated\(unsafe\)", r"crash-allow:",
     "as above"),
    ("raw_lock", "raw locks (NSLock, OSAllocatedUnfairLock, os_unfair_lock, pthread mutex)",
     r"\b(NSLock|NSRecursiveLock|NSConditionLock|OSAllocatedUnfairLock|os_unfair_lock|pthread_mutex_t)\b", None,
     "CLAUDE.md: actor, or the CmuxNextCompat Mutex carve-out"),
    ("mutex", "CmuxNextCompat `Mutex` uses (the sanctioned lock)", r"\bMutex\s*[<(]", None, "sanctioned; listed for scale"),
    ("task_sleep", "`Task.sleep`", r"\bTask\.sleep\(", r"wakeup-allow:", "allowed only as a bounded, cancellable delay"),
    ("clock_sleep", "clock sleeps `.sleep(for:/until:)`", r"\.sleep\((for|until):", r"wakeup-allow:", "as above"),
    ("main_async", "`DispatchQueue.main.async`", r"\bDispatchQueue\.main\.async\b", None, "use @MainActor and await"),
    ("async_after", "`asyncAfter`", r"\basyncAfter\(", None, "banned (check-concurrency.sh); an injected Clock"),
    ("hosting_view", "`NSHostingView` / `NSHostingController`", r"\bNSHosting(View|Controller)\b", None,
     "a SwiftUI graph inside AppKit; costly on hot paths"),
    ("if_debug", "`#if DEBUG` blocks", r"^\s*#if\s+DEBUG\b", None, "DEBUG-only instrumentation is not in Release builds"),
    ("combine_state", "`ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject`",
     r"\bObservableObject\b|@(Published|StateObject|ObservedObject|EnvironmentObject)\b", None, "CLAUDE.md: @Observable"),
)
# Every table row in report order: (id, title, waiver label or None, note).
SHOWN = ([(c[0], c[1], ("outside seam adapters" if c[3] else None), c[4]) for c in ARCH_CATEGORIES]
         + [(c[0], c[1], (f"no `{c[3]}`" if c[3] else None), c[4]) for c in CATEGORIES])

TARGET_CALL = re.compile(r"\.(target|executableTarget|testTarget|binaryTarget|systemLibrary)\(\s*name:\s*\"([^\"]+)\"")
STRING_DEP = re.compile(r"\"([A-Za-z0-9_]+)\"")
STALE_PATH = re.compile(r"plans/cmux-next/[\w./-]+?\.md\b")
MD_LINK = re.compile(r"\]\(([\w./-]+?\.md)(#[^)]*)?\)")
# A bare doc name in a script: hyphenated plan-style names only (`perf-speed-of-light.md`), never an f-string part.
BARE_MD = re.compile(r"(?<![\w/.{}-])([A-Za-z0-9]+(?:-[A-Za-z0-9]+)+\.md)\b")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def tracked(repo: Path, *paths: str) -> list[str]:
    return [p for p in git(repo, "ls-files", "-z", "--", *paths).split("\0") if p]


def strip_comment(line: str) -> str:
    """LINE without a trailing `//` comment outside a string literal; a comment-only line is empty."""
    stripped = line.lstrip()
    if stripped.startswith(("//", "*", "/*")):
        return ""
    in_string = False
    i = 0
    while i < len(line) - 1:
        c = line[i]
        if c == "\\" and in_string:
            i += 2
            continue
        if c == '"':
            in_string = not in_string
        elif not in_string and line[i:i + 2] == "//":
            return line[:i]
        i += 1
    return line


def waived(lines: list[str], index: int, marker: re.Pattern) -> bool:
    if marker.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and re.match(r"^\s*(//|\*|/\*|@\w)", lines[j]):
        if marker.search(lines[j]):
            return True
        j -= 1
    return False


def module_of(path: str) -> str:
    """The Swift module of a counted file: arch_counts' package_of (the directory after its package's Sources/)."""
    return ARCH.package_of(path)


def closure(repo: Path):
    """arch_counts.read_paths at HEAD (the counted packages: CmuxNext and its local package closure), or None when
    HEAD is no commit (then CmuxNext alone). The closure is HEAD's; the files are the working tree's."""
    try:
        return ARCH.read_paths(repo, "HEAD")
    except RuntimeError:
        return None


def scan(repo: Path) -> dict:
    scope = closure(repo)
    dirs = [s + "/" for s in scope.sources] if scope is not None else [SOURCES]
    files = [p for p in tracked(repo, *dirs) if p.endswith(".swift")]
    ids = [c[0] for c in ARCH_CATEGORIES] + [c[0] for c in CATEGORIES]
    hits: dict[str, collections.Counter] = {cid: collections.Counter() for cid in ids}
    unwaived: dict[str, collections.Counter] = {cid: collections.Counter() for cid in ids}
    lines_per_module: collections.Counter = collections.Counter()
    texts: dict[str, list[str]] = {}
    raw: dict[str, str] = {}
    compiled = [(c[0], re.compile(c[2]), re.compile(c[3]) if c[3] else None) for c in CATEGORIES]
    blanked: dict[str, str] = {}
    for path in files:
        try:
            text = (repo / path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        raw[path] = text
        lines = text.split("\n")
        texts[path] = lines
        blanked[path] = ARCH.strip(text)
        lines_per_module[module_of(path)] += text.count("\n") + (0 if text.endswith("\n") or not text else 1)
        for index, line in enumerate(lines):
            code = strip_comment(line)
            if not code.strip():
                continue
            for cid, pattern, marker in compiled:
                if pattern.search(code):
                    hits[cid][path] += 1
                    if marker is not None and not waived(lines, index, marker):
                        unwaived[cid][path] += 1

    def read(rel: str) -> str | None:
        try:
            return (repo / rel).read_text(encoding="utf-8")
        except OSError:
            return None
    observers = ARCH.observer_registrations(raw, scope)  # one resolution for section 1's row and section 2's names
    sites = observer_sites(observers, blanked)
    manifests = {p: read(p) for p in scope.manifests} if scope is not None else read(ARCH.MANIFEST)
    arch, edges = ARCH.count_texts(raw, manifests, read(ARCH.LAYERS_JSON), observers, scope)
    for cid, _, row, waiver_row, _ in ARCH_CATEGORIES:
        for site in arch.sites[row]:
            hits[cid][site.path] += 1
        for site in (arch.sites[waiver_row] if waiver_row else []):
            unwaived[cid][site.path] += 1
    app_modules = {module_of(p) for p in files if p.startswith(SOURCES)}
    return {"files": files, "hits": hits, "unwaived": unwaived, "lines": lines_per_module, "texts": texts,
            "edges": edges, "sites": sites, "blanked": blanked, "scope": scope, "app_modules": app_modules}


VIEW_CLASS = re.compile(r"\bclass\s+\w+\s*:\s*[^{]*\bNS\w*(View|Window|Panel)\b")
OBSERVED_NAME = re.compile(r"\b(?:forName|named|name|for):\s*([\w.]+)")
# A wrapper call such as `MainActorObservation(name, ...)`: the name is its first, unlabeled argument.
WRAPPED = re.compile(r"\s*([\w.]+)\s*(?:,|$)")



class ObserverSite(NamedTuple):
    """One counted registration statement (a raw call, or a use of a wrapper): its first and last 0-based line, the
    notification name it observes ("?" when the arguments do not name one), whether that name is a variable (a
    bare identifier such as a loop's `name`, not `.paneMoved` or `Type.member`), whether it observes every sender
    (no `object:` argument, or `object: nil`) and how many registrations it makes (arch_counts' count for it: a
    wrapper's per-call count, times the elements of a literal loop it uses)."""
    first: int
    last: int
    name: str
    variable: bool
    every_sender: bool
    count: int = 1


def observer_sites(observers, blanked: dict[str, str]) -> dict[str, list[ObserverSite]]:
    """The registrations arch_counts counts (OBSERVERS: `ARCH.observer_registrations`), per file. BLANKED is each
    file's `ARCH.strip` text (comments and string contents blanked, same length, so offsets keep their lines)."""
    found: dict[str, list[ObserverSite]] = {}
    for path, hits in observers.hits.items():
        code = blanked[path]
        for reg, count in hits:
            end = reg.end if reg.end > reg.pos else reg.pos
            open_paren = code.find("(", reg.pos, end)
            arguments = code[open_paren + 1:ARCH._closing(code, open_paren)] if open_paren >= 0 else ""
            if reg.kind == "raw":
                named = OBSERVED_NAME.search(arguments)
            else:  # a wrapper: its first, unlabeled argument when it has one
                named = WRAPPED.match(arguments) if reg.kind == "call" and reg.args and not reg.args[0][0] else None
            # NotificationCenter's `object:` defaults to nil (every sender) in every form that may omit it.
            every = "object:" not in arguments or re.search(r"\bobject:\s*nil\b", arguments) is not None
            raw = named.group(1) if named else "?"
            found.setdefault(path, []).append(ObserverSite(
                code.count("\n", 0, reg.pos), code.count("\n", 0, end), raw.split(".")[-1],
                raw != "?" and "." not in raw, every, count))
    return found


def attributed_names(site: ObserverSite, code: list[str], names: set[str], any_name) -> list[str]:
    """The names SITE observes: its own name; for a call that passes a variable (`for name in [.a, .b] {
    addObserver(forName: name, ...) }`), the custom names on the two lines above it, where such a binding sits."""
    if not site.variable or any_name is None:
        return [site.name]
    above = " ".join(code[max(0, site.first - 2):site.first + 1])
    bound = list(dict.fromkeys(m.group(1) for m in any_name.finditer(above)))
    return bound or [site.name]


def notification_report(code_of: dict[str, str], sites_of: dict[str, list[ObserverSite]]) -> tuple[list, list]:
    """Custom names: (name, observer sites, every-sender sites, post sites, per-instance observer files);
    every observed name: (name, sites, per-instance observer files). CODE_OF is each file's blanked text and
    SITES_OF its observer sites (section 1's count)."""
    decl = re.compile(r"static\s+(?:let|var)\s+(\w+)\s*(?::\s*(?:NS)?Notification\.Name)?\s*=\s*(?:NS)?Notification\.Name\(")
    lines_of = {path: text.split("\n") for path, text in code_of.items()}
    names = {m.group(1) for lines in lines_of.values() for line in lines for m in [decl.search(line)] if m}
    is_view = {path: any(VIEW_CLASS.search(l) for l in lines) for path, lines in lines_of.items()}
    stats = {n: [0, 0, 0, []] for n in names}
    observed: dict[str, list] = {}
    any_name = re.compile(r"\.(" + "|".join(re.escape(n) for n in sorted(names)) + r")\b") if names else None
    for path, sites in sites_of.items():
        for site in sites:
            attributed = attributed_names(site, lines_of[path], names, any_name)
            # A statement that names several observed names registers once per name; one name gets them all.
            each = 1 if len(attributed) > 1 else site.count
            for name in attributed:
                entry = observed.setdefault(name, [0, []])
                entry[0] += each
                if is_view[path] and path not in entry[1]:
                    entry[1].append(path)
                if name in stats:
                    row = stats[name]
                    row[0] += each
                    row[1] += each if site.every_sender else 0
                    if is_view[path] and path not in row[3]:
                        row[3].append(path)
    for path, code in lines_of.items():
        if any_name is None:
            break
        inside = {i for site in sites_of.get(path, ()) for i in range(site.first, site.last + 1)}
        for index, line in enumerate(code):
            if index in inside:  # the name an observer call passes: counted above
                continue
            window = " ".join(code[max(0, index - 2):index + 3])
            for m in any_name.finditer(line):
                if "post(" in window:
                    stats[m.group(1)][2] += 1
    rows = [(n, *v) for n, v in stats.items()]
    rows.sort(key=lambda r: (-len(r[4]), -r[1], r[0]))
    top = sorted(((n, c, f) for n, (c, f) in observed.items()), key=lambda r: (-len(r[2]), -r[1], r[0]))
    return rows, top


def targets(repo: Path, scope=None) -> dict[str, dict]:
    """Package.swift targets: {name: {kind, deps}}: CmuxNext's (with its test targets) and, with SCOPE (closure()),
    every non-test target of the other closure packages; deps add the edges arch_counts' closure_manifest reads
    (a `.product` of a local package is its targets)."""
    out = cmux_next_targets(repo)
    if scope is None:
        return out
    texts = {}
    for path in scope.manifests:
        try:
            texts[path] = (repo / path).read_text(encoding="utf-8")
        except OSError:
            texts[path] = None
    try:
        merged = ARCH.closure_manifest(texts)
    except ARCH.AmbiguousModule:
        return out
    for name, target in merged.targets.items():
        entry = out.setdefault(name, {"kind": target.kind, "deps": []})
        entry["deps"] = sorted(set(entry["deps"]) | target.deps)
    return out


def cmux_next_targets(repo: Path) -> dict[str, dict]:
    """CmuxNext's Package.swift targets: {name: {kind, deps}} (in-package string dependencies only)."""
    text = (repo / PKG / "Package.swift").read_text(encoding="utf-8")
    out: dict[str, dict] = {}
    calls = list(TARGET_CALL.finditer(text))
    for i, match in enumerate(calls):
        end = calls[i + 1].start() if i + 1 < len(calls) else len(text)
        body = text[match.end():end]
        deps_match = re.search(r"dependencies:\s*\[", body)
        deps: list[str] = []
        if deps_match:
            depth, j = 1, deps_match.end()
            while j < len(body) and depth:
                depth += {"[": 1, "]": -1}.get(body[j], 0)
                j += 1
            block = "\n".join(strip_comment(l) for l in body[deps_match.end():j].split("\n"))
            block = re.sub(r"\.product\([^)]*\)", "", block)
            block = re.sub(r"condition:\s*\.when\([^)]*\)", "", block)
            deps = [d for d in STRING_DEP.findall(block)]
            deps += re.findall(r"\.target\(\s*name:\s*\"([^\"]+)\"", body[deps_match.end():j])
        out[match.group(2)] = {"kind": match.group(1), "deps": sorted(set(deps))}
    return out


def placed_layers(repo: Path, graph: dict[str, dict]) -> dict[str, str]:
    """Layer per target from plans/cmux-next/architecture-layers.json (the map the ratchet holds the edges to);
    test targets are `test`, a target the map misses is `unplaced`."""
    try:
        text = (repo / ARCH.LAYERS_JSON).read_text(encoding="utf-8")
    except OSError:
        text = None
    layer_map = ARCH.LayerMap.parse(text)  # the map reader the layer rows and the layer gate use
    return {name: "test" if info["kind"] == "testTarget" else layer_map.placed(name) or "unplaced"
            for name, info in graph.items()}


def depth(graph: dict[str, dict], name: str, memo: dict[str, int], stack: frozenset = frozenset()) -> int:
    if name in memo:
        return memo[name]
    if name in stack or name not in graph:
        return 0
    deps = [d for d in graph[name]["deps"] if d in graph]
    memo[name] = 1 + max((depth(graph, d, memo, stack | {name}) for d in deps), default=0)
    return memo[name]


def docs(repo: Path) -> dict:
    plans = tracked(repo, "plans/cmux-next/")
    md = [p for p in plans if p.endswith(".md")]
    top_md = [p for p in md if "/" not in p[len("plans/cmux-next/"):]]
    all_md = set(tracked(repo, "*.md"))
    basenames = {Path(p).name for p in all_md}
    stale: dict[str, set[str]] = collections.defaultdict(set)
    sources = md + [p for p in tracked(repo, "scripts/cmux-next/") if p.endswith((".py", ".sh", ".json"))]
    for path in sources:
        try:
            text = (repo / path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for ref in set(STALE_PATH.findall(text)):
            if ref not in all_md:
                stale[ref].add(path)
        if path.endswith(".md"):
            for ref, _ in set(MD_LINK.findall(text)):
                if ref.startswith(("http", "/")):
                    continue
                resolved = (Path(path).parent / ref).as_posix()
                parts: list[str] = []
                for part in resolved.split("/"):
                    if part == "..":
                        if parts:
                            parts.pop()
                    elif part and part != ".":
                        parts.append(part)
                resolved = "/".join(parts)
                if resolved not in all_md and Path(ref).name not in basenames:
                    stale[ref].add(path)
        else:
            for ref in set(BARE_MD.findall(text)):
                if ref not in basenames and ref.lower() not in {"readme.md", "changelog.md"}:
                    stale[ref].add(path)
    return {"plans": plans, "md": md, "top_md": top_md, "stale": stale}


def file_list(counter: collections.Counter, limit: int | None = None) -> str:
    rows = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    shown = rows if limit is None else rows[:limit]
    text = "\n".join(f"{n:4d}  {p[len(SOURCES):] if p.startswith(SOURCES) else p}" for p, n in shown)
    if limit is not None and len(rows) > limit:
        text += f"\n      ... {len(rows) - limit} more files"
    return text


class Marker(NamedTuple):
    """One `// perf-hot: <budget> <path-id>` marker: the file, its 1-based line, its path id, and the 1-based line
    of the declaration it marks as the pre-push hook resolves it (None: it marks no declaration)."""
    path: str
    line: int
    pid: str
    declaration: int | None


def marked_texts(repo: Path) -> dict[str, str]:
    """{path: working-tree text} of every tracked Swift file in the repository with a `perf-hot:` in it.

    Reads every tracked Swift file (markers live in shared packages too, e.g. Packages/Shared/CmuxMessagesLab),
    not only the app sources the debt counts cover.
    """
    # git grep exits 1 when nothing matches: no marker anywhere is a result, not an error. A fixed output format:
    # color.grep would put escape codes around each name.
    found = subprocess.run(["git", "-C", str(repo), "grep", "-I", "-z", "-l", "--no-color", "-F", "perf-hot:",
                            "--", "*.swift"], capture_output=True, text=True)
    if found.returncode not in (0, 1):
        raise SystemExit(f"codebase-health: git grep failed: {found.stderr.strip()}")
    return {path: (repo / path).read_text(encoding="utf-8", errors="replace")
            for path in found.stdout.split("\0") if path}


def perf_hot_markers(guardrails, texts: dict[str, str]) -> list[Marker]:
    """Every `// perf-hot:` marker with a path id in TEXTS, resolved to its declaration by the hook's own
    resolver (guardrails.perf_hot_markers: the comment block above, the declaration line, or the `{` line of a
    wrapped signature), never a copy of it."""
    return [Marker(path, found.line, found.path_id, found.span[0] if found.span else None)
            for path, text in sorted(texts.items())
            for found in guardrails.perf_hot_markers(text.split("\n")) if found.path_id]


def load_guardrails():
    """The pre-push hook's own module (guardrails.py next to this file): section 6 asks it, never a copy of it."""
    spec = importlib.util.spec_from_file_location("cmux_next_guardrails_for_health",
                                                  Path(__file__).resolve().parent / "guardrails.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses resolve their module by name
    spec.loader.exec_module(module)
    return module


# guardrails.perf_hot_warnings' line for an edited marked declaration: `<path>:<line>: changes perf-hot ... (budget
# <budget>, <path-id>...`.
HOOK_WARNING = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+): changes perf-hot .*\(budget [^,]+, (?P<pid>[\w-]+)")
# Its line for a touched marker that marks no declaration: `<path>:<line>: this `// perf-hot:` marks no declaration`.
HOOK_DANGLING = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+): this `// perf-hot:` marks no declaration")


def git_env(repo: Path, env: dict[str, str], *args: str, stdin: str | None = None) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, input=stdin,
                          env={**os.environ, **env}).stdout


def hook_warnings_for_edits(repo: Path, guardrails, texts: dict[str, str]) -> list[tuple[str, int, str]]:
    """(path, declaration line, path id) per perf-hot warning `guardrails.check` gives a push that edits every line
    of each file in TEXTS (path: its working-tree text).

    Both sides of that push are the working tree: the base tree is HEAD with TEXTS as they are, the edited tree
    the same with a trailing space on every line. The only change the hook sees is that space, so an uncommitted
    edit (a marker removed or retagged) is part of both sides, never a change the hook reports. The hook itself
    decides, with its own diff scope and declaration parser. Both trees go to a throwaway object directory that
    borrows the repository's objects, so the report writes nothing into the repository.
    """
    objects = git(repo, "rev-parse", "--path-format=absolute", "--git-path", "objects").strip()
    paths = sorted(texts)
    with tempfile.TemporaryDirectory(prefix="codebase-health-") as tmp:
        os.mkdir(os.path.join(tmp, "objects"))
        env = {"GIT_OBJECT_DIRECTORY": os.path.join(tmp, "objects"), "GIT_ALTERNATE_OBJECT_DIRECTORIES": objects}
        indexed = {**env, "GIT_INDEX_FILE": os.path.join(tmp, "index")}
        git_env(repo, indexed, "read-tree", "HEAD")
        modes = {}
        for entry in git_env(repo, indexed, "ls-files", "-s", "-z", "--", *paths).split("\0"):
            if entry:
                meta, _, path = entry.partition("\t")
                modes[path] = meta.split()[0]

        def tree_of(suffix: str) -> str:
            """The tree of HEAD with every path in TEXTS replaced by its text, SUFFIX appended to every line."""
            copies = []
            for number, path in enumerate(paths):
                copy = os.path.join(tmp, f"{number}{suffix and '-edited'}.swift")
                Path(copy).write_text("\n".join(line + suffix for line in texts[path].split("\n")), encoding="utf-8")
                copies.append(copy)
            oids = git_env(repo, env, "hash-object", "-w", "--no-filters", "--stdin-paths",
                           stdin="\n".join(copies) + "\n").split()
            git_env(repo, indexed, "update-index", "--add", "--index-info",
                    stdin="".join(f"{modes.get(path, '100644')} {oid}\t{path}\n" for path, oid in zip(paths, oids)))
            return git_env(repo, indexed, "write-tree").strip()

        base = tree_of("")
        tree = tree_of(" ")  # a trailing space on every line: the same code, every line touched
        saved = {key: os.environ.get(key) for key in env}
        os.environ.update(env)  # guardrails' git processes read both trees from the throwaway objects
        try:
            _, warnings = guardrails.check(repo, base, tree)
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    found = []
    for kind, text in warnings:
        if kind == "guardrails" and (text.startswith("perf-hot ") or "could not read this push's diff" in text):
            raise SystemExit(f"codebase-health: guardrails could not judge the perf-hot markers: {text}")
        if kind != "perf-hot":
            continue
        if HOOK_DANGLING.match(text):  # the marker's own line, not an edit of a hot function: it warns for nobody's
            continue                   # function, which the resolver's declaration None already says
        match = HOOK_WARNING.match(text)
        if not match:  # never guess: a reworded warning must not read as "no marker warns"
            raise SystemExit(f"codebase-health: cannot read guardrails' perf-hot warning (reworded?): {text}")
        found.append((match.group("path"), int(match.group("line")), match.group("pid")))
    return found


def hook_view(repo: Path, guardrails, texts: dict[str, str], markers: list[Marker]) -> dict[Marker, str]:
    """Per marker, what the pre-push hook does when a push edits its function: "warns"; "outside" (the hook
    resolves the declaration, but never diffs the file); or "unparsed" (the marker marks no declaration, e.g. a
    trailing marker on a statement line)."""
    if not markers:
        return {}
    warned = set(hook_warnings_for_edits(repo, guardrails, {m.path: texts[m.path] for m in markers}))

    def state(marker: Marker) -> str:
        if marker.declaration is None:
            return "unparsed"
        # The hook names a warned function by its file, its declaration line and its marker's path id.
        return "warns" if (marker.path, marker.declaration, marker.pid) in warned else "outside"

    return {m: state(m) for m in markers}


NO_WARNING = {
    "outside": "outside the pre-push hook's diff scope: no warning",
    "unparsed": "marks no declaration (not above one, on its line, or on a wrapped signature's `{` line): no warning",
}


def marker_text(marker: Marker, state: str) -> str:
    """MARKER as section 6 prints it: path (short under the app sources) and line, flagged when it never warns."""
    shown = marker.path[len(SOURCES):] if marker.path.startswith(SOURCES) else marker.path
    flag = NO_WARNING.get(state)
    return f"{shown}:{marker.line}" + (f" ({flag})" if flag else "")


def measured_at(repo: Path) -> str:
    """Where the numbers come from, by a sha that survives a rebase: the merge base with origin/feat-cmux-next,
    plus the measured files the working tree changes over it (the local commits and edits a rebase rewrites)."""
    head = git(repo, "rev-parse", "--short=11", "HEAD").strip()
    found = subprocess.run(["git", "-C", str(repo), "merge-base", "HEAD", UPSTREAM], capture_output=True, text=True)
    if found.returncode != 0:
        return f"at `{head}` (this repository has no `{UPSTREAM}`)"
    base = found.stdout.strip()
    changed = [p for p in git(repo, "diff", "--name-only", "--no-renames", base, "--", *MEASURED).split("\n") if p]
    short = git(repo, "rev-parse", "--short=11", base).strip()
    if not changed:
        return f"at feat-cmux-next `{short}`"
    listed = ", ".join(f"`{p}`" for p in changed[:4]) + (f" and {len(changed) - 4} more" if len(changed) > 4 else "")
    return f"at feat-cmux-next `{short}` plus this tree's changes to {listed}"


def report(repo: Path) -> str:
    data = scan(repo)
    total_lines = sum(n for m, n in data["lines"].items() if m in data["app_modules"])
    pkg_lines = 0
    for path in tracked(repo, PKG + "/"):
        if path.endswith(".swift"):
            try:
                pkg_lines += (repo / path).read_bytes().count(b"\n")
            except OSError:
                pass
    graph = targets(repo, data["scope"])
    layers = placed_layers(repo, graph)
    edges = data["edges"]
    memo: dict[str, int] = {}
    non_test = {n: i for n, i in graph.items() if layers[n] != "test"}
    app_deps = len([d for d in graph.get(APP, {}).get("deps", []) if d in graph])
    leaves = [n for n, i in non_test.items() if not [d for d in i["deps"] if d in graph]]
    max_depth = max((depth(non_test, n, memo) for n in non_test), default=0)
    notes, observed = notification_report(data["blanked"], data["sites"])
    d = docs(repo)
    scripts_top = [p for p in tracked(repo, "scripts/cmux-next/") if "/" not in p[len("scripts/cmux-next/"):]]
    scripts_all = tracked(repo, "scripts/cmux-next/")
    workflows = tracked(repo, ".github/workflows/")

    out = []
    w = out.append
    w("# cmux-next codebase health (measured)")
    w("")
    w(f"Measured {datetime.date.today().isoformat()} {measured_at(repo)} by "
      "`scripts/cmux-next/codebase-health.py --write` (rerun it to refresh; do not edit numbers by hand).")
    w("Scope: tracked Swift in `Packages/macOS/CmuxNext/Sources` and in the Sources of every local package it links,")
    w("directly or through another one (the arch ratchet's scope, arch_counts.py method v5), comments stripped")
    w("(section 3's App share: CmuxNext's Sources only; section 6's perf-hot markers: every tracked Swift file).")
    w("The pre-push guardrails")
    w("(`scripts/cmux-next/guardrails.py`, run by `prepush-gate.py`) refuse NEW instances of the ratcheted rows;")
    w("the debt below never blocks a push. Owners: [OWNERS.md](OWNERS.md). Guardrail rules: section 6.")
    w("")
    w("## 1. Concurrency, state and instrumentation debt")
    w("")
    w("| Pattern | Lines | Files | Without the waiver comment | Why it matters |")
    w("|---|---:|---:|---:|---|")
    for cid, title, label, note in SHOWN:
        hits = data["hits"][cid]
        waiver = f"{sum(data['unwaived'][cid].values())} ({label})" if label else "-"
        w(f"| {title} | {sum(hits.values())} | {len(hits)} | {waiver} | {note} |")
    w("")
    for cid, title, _, _ in SHOWN:
        hits = data["hits"][cid]
        if not hits:
            continue
        w(f"<details><summary>{title}: {sum(hits.values())} in {len(hits)} files (top 10)</summary>")
        w("")
        w("```")
        w(file_list(hits, 10))
        w("```")
        w("</details>")
        w("")
    w("## 2. NotificationCenter broadcast signals")
    w("")
    w(f"{sum(data['hits']['observers'].values())} observer registrations; {len(notes)} custom names. A name observed by a")
    w("per-instance view or window class wakes every instance on every post: O(all), not O(changed).")
    w("")
    w("| Name | Observer sites | Every sender (no `object:`, or `object: nil`) | Post sites | Per-instance observer files |")
    w("|---|---:|---:|---:|---|")
    for name, obs, broad, posts, per in notes:
        files = ", ".join(f"`{Path(p).name}`" for p in per) or "-"
        w(f"| `{name}` | {obs} | {broad} | {posts} | {files} |")
    w("")
    w("Every observed name (system and custom), by per-instance observer files (a view or window class that")
    w("registers per instance: N instances = N wakes per post):")
    w("")
    w("<details><summary>Observed names</summary>")
    w("")
    w("```")
    for name, sites, per in observed[:15]:
        w(f"{sites:3d} sites  {len(per):2d} per-instance  {name}" + (f"  ({', '.join(Path(p).name for p in per[:5])})" if per else ""))
    w("```")
    w("</details>")
    w("")
    w("Example O(all) cause: `browserChildWindowPagesNeedUpdate` is posted per layout change by")
    w("`WindowRootView+MainPane` and `WindowOverlayLayer`; every `CEFHostView` (one per page, moving or not)")
    w("observes it and posts geometry (perf-lead.md issue 2). Fix shape: notify only the hosts whose rect changed.")
    w("")
    w("## 3. Target sizes")
    w("")
    w(f"`{APP}`: **{data['lines'][APP]:,} lines** of {total_lines:,} in CmuxNext's `Sources` "
      f"({100 * data['lines'][APP] / max(total_lines, 1):.0f} %); {pkg_lines:,} lines with Tests and the package manifest.")
    w("Every edit in the App target re-emits the whole module (check-app-size.sh), so new code goes in a feature target.")
    w("")
    w("<details><summary>Lines per target (15 largest)</summary>")
    w("")
    w("```")
    for name, n in sorted(data["lines"].items(), key=lambda kv: -kv[1])[:15]:
        w(f"{n:8,d}  {name}  [{layers.get(name, '?')}]")
    w("```")
    w("</details>")
    w("")
    w("## 4. Target graph vs the 5-layer rule")
    w("")
    counts = collections.Counter(layers[n] for n in graph)
    w(f"`Package.swift` and its local packages' manifests: {len(graph)} targets ({len(non_test)} non-test: "
      + ", ".join(f"{counts[k]} {k}" for k in ("app", "ui", "domain", "service", "core", "unplaced") if counts[k])
      + f"; {counts['test']} test). The App depends directly on {app_deps} targets; {len(leaves)} targets have no")
    w(f"dependency among them; the longest dependency chain is {max_depth} targets.")
    w("")
    w("Layer per target from `plans/cmux-next/architecture-layers.json`; the rule is arch_counts.py's `layers()`,")
    w("the one plans/cmux-next/arch-ratchet.json and the pre-push ratchet hold: hard, a core/service/domain target")
    w("that depends on a ui or app target; soft, a service target that depends on a domain target; upward, any")
    w("other edge that points up a layer (core -> service/domain).")
    w(f"**{len(edges.hard)} hard, {len(edges.soft)} soft and {len(edges.upward)} upward edges break the rule; "
      f"{len(edges.unplaced)} targets are unplaced:**")
    w("")
    w("<details><summary>Layer violations</summary>")
    w("")
    w("```")
    for src, a, dst, b in edges.hard:
        w(f"hard  {src} ({a}) -> {dst} ({b})")
    for src, a, dst, b in edges.soft:
        w(f"soft  {src} ({a}) -> {dst} ({b})")
    for src, a, dst, b in edges.upward:
        w(f"upward  {src} ({a}) -> {dst} ({b})")
    for name in edges.unplaced:
        w(f"unplaced  {name}")
    w("```")
    w("</details>")
    w("")
    w("## 5. Docs, scripts, workflows")
    w("")
    w(f"- `plans/cmux-next`: {len(d['plans'])} tracked files, {len(d['md'])} Markdown ({len(d['top_md'])} at the top level).")
    w(f"- Stale references (a `.md` named in plans/cmux-next docs or scripts/cmux-next that no tracked file has): "
      f"**{len(d['stale'])}** targets.")
    w(f"- `scripts/cmux-next`: {len(scripts_top)} files at the top level, {len(scripts_all)} tracked in total.")
    w(f"- `.github/workflows`: {len(workflows)} files.")
    w("")
    w("<details><summary>Stale references (missing doc: files that name it)</summary>")
    w("")
    w("```")
    for ref, users in sorted(d["stale"].items()):
        users_text = ", ".join(sorted(users)[:4]) + (f" (+{len(users) - 4})" if len(users) > 4 else "")
        w(f"{ref}: {users_text}")
    w("```")
    w("</details>")
    w("")
    w("## 6. Guardrails (pre-push, local, never CI)")
    w("")
    w("`scripts/cmux-next/guardrails.py`, run by the pre-push hook through `prepush-gate.py --pre-push`, looks only at")
    w("lines the push adds under `Packages/macOS/CmuxNext/Sources` and takes well under a second. Per file and rule it")
    w("is a count ratchet: an edit of a line that already has the debt adds none, and a line moved from another file")
    w("does not count. Removed lines pay only when they were debt in the base (same context and escape rules), and an")
    w("unchanged line counts when the push changes its context (`struct` -> `class` around a static, a view renamed to a row) or deletes its escape comment. Lines a")
    w("push only brings in from origin/feat-cmux-next (a merge or a rebase onto it) never count. Refusals print the rule,")
    w("why, the right pattern and the escape. One rule is not per line: `app-size` is a net count over the push in")
    w("CmuxNextApp source lines (CI's lexer, as `check-app-size.sh --base` counts them), where removed App lines pay")
    w("for added ones and code moved into the App from a package is growth. It refuses the root's wiring over its budget")
    w("(`ROOT_BUDGET` in guardrails.py, `--list` prints it; lines moved into the root count) and a new App file that is")
    w("neither a move nor the push's one `AppServices+<Domain>Host.swift` of one-line forwards; growth of the App total")
    w("and of the App outside the composition root warns (bytes added, the package the code goes to) until the large")
    w("domains are out of CmuxNextApp. `app-type`, a second net rule, refuses a new type in an existing App file")
    w("or in a new App file that passes as a move, when the type is not a move (any depth: top-level, in an")
    w("`extension`, or a nested type over `PRIVATE_TYPE_MAX` source lines with its `extension` blocks in the file).")
    w("They are the only App-size limits in force on a push. Skip one rule for one push with")
    w("`CMUX_GUARDRAILS_SKIP_REASON=\"<rule>[,<rule>]: <why>\"` (the other rules still refuse) and say so in your report.")
    w("`guardrails.py --list` prints every rule. The guardrails also run the arch ratchet (`arch-ratchet.py`): the")
    w("arch_counts rows of section 1 and the layer edges of section 4 may not rise over a push, and their totals in")
    w("`plans/cmux-next/arch-ratchet.json` only go down; their one escape is a dated exception in that file (the skip")
    w("variable does not skip them).")
    w("If the script itself fails, the hook prints a warning and lets the push through.")
    w("It also warns (never refuses) when a push changes a `// perf-hot:` function (names the bench,")
    w("`scripts/cmux-next/perf-hot-benches.json`) or an area in [OWNERS.md](OWNERS.md).")
    w("")
    try:
        known = json.loads((repo / BENCHES).read_text(encoding="utf-8")).get("paths", {})
    except (OSError, ValueError):
        known = {}
    guardrails = load_guardrails()
    texts = marked_texts(repo)
    markers = perf_hot_markers(guardrails, texts)
    states = hook_view(repo, guardrails, texts, markers)
    per_id: dict[str, list[Marker]] = collections.defaultdict(list)
    for marker in markers:
        per_id[marker.pid].append(marker)
    marked = [pid for pid in known if per_id.get(pid)]
    warning = [pid for pid in known if any(states[m] == "warns" for m in per_id.get(pid, ()))]
    silent = [m for m in markers if states[m] != "warns"]
    w("Perf-hot markers per path id, from every tracked Swift file. An id with no marker never warns: its owner")
    w("marks the hot function (a trailing `// perf-hot: <budget> <path-id>` on the line that has `func`, `init` or")
    w("`var`, or on the line with the body's `{` of a wrapped signature, adds no line; or a comment line right above")
    w("the declaration). Which declaration a marker marks is what the hook's own resolver says, and whether it")
    w("warns is what `guardrails.check` itself reports for a push that edits every line of the marked files (its own")
    w("diff scope, not a copy), so a marker outside the hook's diff scope, or one that marks no declaration, is")
    w("flagged: an edit of that function warns nobody.")
    w("")
    w(f"Marked: {len(marked)} of {len(known)} path ids ({len(markers)} markers); {len(warning)} of {len(known)} "
      f"warn at push; {len(silent)} of {len(markers)} markers never warn.")
    w("")
    for pid, entry in known.items():
        listed = ", ".join(marker_text(m, states[m]) for m in per_id.get(pid, ()))
        w(f"- `{pid}`: " + (listed or f"**no marker** (owner {entry.get('owner', '?')})"))
    for pid in sorted(set(per_id) - set(known)):
        listed = ", ".join(marker_text(m, states[m]) for m in per_id[pid])
        w(f"- `{pid}`: {listed} (**unknown id**: not in `{BENCHES}`)")
    w("")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=None)
    parser.add_argument("--write", action="store_true", help=f"rewrite {OUT}")
    args = parser.parse_args(argv)
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    text = report(repo)
    if args.write:
        (repo / OUT).write_text(text, encoding="utf-8")
        print(f"codebase-health: wrote {OUT}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
