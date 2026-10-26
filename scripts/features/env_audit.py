#!/usr/bin/env python3
"""Audit the environment switches the app and the daemon read (MQ7, task p12-perf-process-106).

Chromium keeps every command-line switch in one reviewed list per component
(content/public/common/content_switches.cc, chrome/common/chrome_switches.cc), and a switch that
changes a shipping code path becomes a base::Feature (base/feature_list.h). cmux has two sets of
env names instead of switches:

  app     every "CMUX_*" string literal in Packages/macOS/CmuxNext/Sources/**/*.swift
  daemon  every "CMUX_TUI_*" string literal in cmux-tui/crates/**/*.rs

schemas/features/env-audit.json lists every name both queries return, with the file:line of
each site, the build the site compiles into (release; nightly for #if CMUX_BLOCKING_CHECKS; bench
for #if DEBUG || CMUX_BENCH_HOOKS; debug for #if DEBUG and cfg(debug_assertions); test for
cfg(test), #[test] and test files; comment), whether the site reads, writes or declares it (a
declared constant takes the build of its uses), what the name changes, and its class. A shipped
read that changes a perf path is class releasePerf and carries a follow-up: make it a feature in
schemas/features/features.d/ or move the read under #if DEBUG / cfg(debug_assertions).

    python3 scripts/features/env_audit.py --check         # exit 1 on a new, stale, unclassified or
                                                          #   misclassified name
    python3 scripts/features/env_audit.py --write         # refresh the sites; classes are kept,
                                                          #   new names are added unclassified
    python3 scripts/features/env_audit.py --unclassified  # MQ7: one line per open task
    add --count to --unclassified to print only the number.
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from dataclasses import dataclass

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
AUDIT = "schemas/features/env-audit.json"
APP_ROOT = "Packages/macOS/CmuxNext/Sources"
DAEMON_ROOT = "cmux-tui/crates"
APP_QUERY = re.compile(r'"(CMUX_[A-Z0-9_]+)"')
DAEMON_QUERY = re.compile(r'"(CMUX_TUI_[A-Z0-9_]+)"')

# The builds a site can compile into, most shipped first. Nightly is the Release configuration with
# -DCMUX_BLOCKING_CHECKS; bench is scripts/reload.sh --config bench (Release optimization with
# -DCMUX_BENCH_HOOKS), which never ships (scripts/cmux-next/check-no-bench-hooks.sh).
RELEASE, NIGHTLY, BENCH, DEBUG, TEST, COMMENT = "release", "nightly", "bench", "debug", "test", "comment"
BUILDS = (RELEASE, NIGHTLY, BENCH, DEBUG, TEST, COMMENT)
SWIFT_FLAG_BUILDS = {"DEBUG": DEBUG, "CMUX_UI_LAYER_PREVIEW": DEBUG, "CMUX_BENCH_HOOKS": BENCH,
                     "CMUX_BLOCKING_CHECKS": NIGHTLY}
NOT_SHIPPED = {BENCH, DEBUG, TEST, COMMENT}
SHIPPED = {RELEASE, NIGHTLY}

# class -> (meaning, the builds a name of that class may be read in, needs a follow-up)
CLASSES = {
    "releasePerf": ("Read in a shipped build (Release or Nightly) and changes a perf path (latency, frames, "
                    "memory, threads, process model). Open until it is a feature in schemas/features/features.d/ "
                    "or its read moves under #if DEBUG / cfg(debug_assertions).", None, True),
    "releaseProbe": ("Read in a shipped build only to add measurement for a bench, a trace or a report; unset "
                     "in normal use, and it changes no product behavior (Chromium's --enable-benchmarking and "
                     "--trace-startup).", None, False),
    "releaseConfig": ("Read in a shipped build; selects identity, paths, sockets, channel, auth, a test "
                      "harness's placement or another non-perf behavior.", None, False),
    "releaseTestHook": ("Read in a shipped build as a test seam (fault injection or a shorter bound) that does "
                        "nothing unless set and touches no perf path. Prefer cfg(debug_assertions) when the tests "
                        "allow it.", None, False),
    "childEnv": ("Set, passed on or stripped for a child process or a shell; this process does not branch "
                 "on it.", None, False),
    "debugOnly": ("Every site compiles only into Debug or bench builds (#if DEBUG, #if DEBUG || "
                  "CMUX_BENCH_HOOKS, cfg(debug_assertions)) or tests.", NOT_SHIPPED, False),
    "testOnly": ("Every site is test code (cfg(test), #[test], tests/, benches/).", {TEST, COMMENT}, False),
    "notEnv": ("The literal is not an env name the process reads: a prefix, a key in a document, a list "
               "of names to strip, docs.", None, False),
}


def least_shipped(builds, default=RELEASE):
    builds = list(builds)
    return max(builds, key=BUILDS.index) if builds else default


def most_shipped(builds, default=RELEASE):
    builds = list(builds)
    return min(builds, key=BUILDS.index) if builds else default


@dataclass(frozen=True)
class Site:
    name: str
    path: str
    line: int
    build: str
    kind: str
    condition: str

    def ref(self):
        text = "%s:%d %s %s" % (self.path, self.line, self.build, self.kind)
        return text + (" [%s]" % self.condition if self.condition else "")


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def _walk(root, sub, suffix):
    base = os.path.join(root, sub)
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in ("target", ".build", "node_modules"))
        for name in sorted(files):
            if name.endswith(suffix):
                full = os.path.join(directory, name)
                yield os.path.relpath(full, root).replace(os.sep, "/"), full


class SourceFile:
    """One file's text, its comment spans and the build and condition at each offset. `parse(text)`
    returns (sorted comment spans, build_at(offset, line) -> (build, condition)); it runs on first use,
    since most files are only searched for a constant's name."""

    def __init__(self, path, text, parse):
        self.path, self.text, self._parse, self._parsed = path, text, parse, None
        self._lines = self._starts = None

    @property
    def lines(self):
        if self._lines is None:
            self._lines = self.text.split("\n")
        return self._lines

    def line_of(self, offset):
        if self._starts is None:
            self._starts = [0] + [match.end() for match in re.finditer("\n", self.text)]
        return bisect.bisect_right(self._starts, offset)

    def _ensure(self):
        if self._parsed is None:
            self._parsed = self._parse(self.text)
        return self._parsed

    def in_comment(self, offset):
        comments = self._ensure()[0]
        index = bisect.bisect_right(comments, (offset, float("inf"))) - 1
        return index >= 0 and comments[index][0] <= offset < comments[index][1]

    def build_at(self, offset):
        if self.in_comment(offset):
            return COMMENT, ""
        return self._ensure()[1](offset, self.line_of(offset))


# --- Swift -----------------------------------------------------------------------------------------

_SWIFT_IF = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def swift_branch_build(expr):
    """The build a `#if expr` branch compiles into: an OR is as shipped as its most shipped term, an AND
    as its least shipped atom. A negated or unknown flag is in every build."""
    expr = re.sub(r"//.*$", "", expr).strip()
    while expr.startswith("(") and expr.endswith(")") and expr.count("(") == 1:
        expr = expr[1:-1].strip()
    if "(" in expr.replace("compiler(", "").replace("arch(", "").replace("os(", "").replace("canImport(", ""):
        return RELEASE
    terms = []
    for term in expr.split("||"):
        atoms = [atom.strip() for atom in term.split("&&")]
        terms.append(least_shipped(SWIFT_FLAG_BUILDS.get(atom, RELEASE) for atom in atoms))
    return most_shipped(terms)


def swift_else_build(previous):
    """The `#else` of `#if !FLAG` is FLAG's build; any other `#else` is in every build."""
    if len(previous) == 1:
        flat = re.sub(r"[\s()]", "", previous[0])
        if flat.startswith("!") and flat[1:] in SWIFT_FLAG_BUILDS:
            return SWIFT_FLAG_BUILDS[flat[1:]]
    return RELEASE


def swift_line_builds(text):
    """[(build, condition)] per line, index 0 unused: the enclosing #if branches."""
    result = [(RELEASE, "")]
    stack = []  # [conditions so far in this #if, branch build, label]
    for raw in text.split("\n"):
        match = _SWIFT_IF.match(raw)
        if match:
            word, rest = match.group(1), re.sub(r"//.*$", "", match.group(2)).strip()
            if word == "if":
                stack.append([[rest], swift_branch_build(rest), "#if " + rest])
            elif word == "elseif" and stack:
                stack[-1][0].append(rest)
                stack[-1][1], stack[-1][2] = swift_branch_build(rest), "#elseif " + rest
            elif word == "else" and stack:
                stack[-1][1] = swift_else_build(stack[-1][0])
                stack[-1][2] = "#else of " + " / ".join(stack[-1][0])
            elif word == "endif" and stack:
                stack.pop()
        result.append((least_shipped(frame[1] for frame in stack),
                       " ; ".join(frame[2] for frame in stack)))
    return result


def swift_comment_spans(text):
    """Sorted [(start, end)] of // and /* */ comments; string literals ("..." and \"\"\"...\"\"\") skipped."""
    spans, index, size = [], 0, len(text)
    while index < size:
        if text.startswith('"""', index):
            end = text.find('"""', index + 3)
            index = size if end < 0 else end + 3
        elif text[index] == '"':
            index += 1
            while index < size and text[index] not in '"\n':
                index += 2 if text[index] == "\\" else 1
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            end = size if end < 0 else end
            spans.append((index, end))
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = size if end < 0 else end + 2
            spans.append((index, end))
            index = end
        else:
            index += 1
    return spans


def _swift_parse(text):
    builds = swift_line_builds(text)
    return swift_comment_spans(text), lambda offset, line: builds[line] if line < len(builds) else (RELEASE, "")


def swift_file(path, text):
    return SourceFile(path, text, _swift_parse)


# --- Rust ------------------------------------------------------------------------------------------

_RUST_ATTR = re.compile(r"#!?\[\s*(cfg\s*\((.*)\)|test|\w+::test\b.*)\s*\]$", re.S)


def rust_cfg_build(predicate):
    """The build an item under #[cfg(predicate)] compiles into; None when it is in every build."""
    flat = re.sub(r"\s", "", predicate)
    if flat in ("test", "debug_assertions"):
        return TEST if flat == "test" else DEBUG
    if flat.startswith("all("):
        parts = _split_args(flat[4:-1])
        if "test" in parts:
            return TEST
        if "debug_assertions" in parts:
            return DEBUG
    if flat.startswith("any("):
        parts = _split_args(flat[4:-1])
        if parts and all(part in ("test", "debug_assertions") for part in parts):
            return DEBUG if "debug_assertions" in parts else TEST
    return None


def _split_args(text):
    parts, depth, current = [], 0, ""
    for char in text:
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
            continue
        depth += char == "("
        depth -= char == ")"
        current += char
    if current:
        parts.append(current)
    return parts


def _matching(text, index, opener, closer):
    depth = 0
    for cursor in range(index, len(text)):
        if text[cursor] == opener:
            depth += 1
        elif text[cursor] == closer:
            depth -= 1
            if depth == 0:
                return cursor
    return len(text) - 1


def rust_regions(text):
    """([(start, end, build, label)], sorted [(start, end)] comments). A region is the item after a
    #[cfg(test)], #[test] or #[cfg(debug_assertions)] attribute (to its `;`, its `,` as a field or arm,
    or its closing brace), a file under #![cfg(...)], or the block after `if cfg!(debug_assertions)`."""
    regions, comments = [], []
    index, size, depth, parens = 0, len(text), 0, 0
    pending = []  # [(build, label, start, depth, parens)]: attributes waiting for their item
    open_items = []  # [(depth at open, start, build, label)]

    def close_pending(end):
        for build, label, start, _, _ in pending:
            regions.append((start, end, build, label))
        pending.clear()

    while index < size:
        char = text[index]
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = size if end < 0 else end
            comments.append((index, end))
            index = end
            continue
        if text.startswith("/*", index):
            level, cursor = 1, index + 2
            while cursor < size and level:
                if text.startswith("/*", cursor):
                    level, cursor = level + 1, cursor + 2
                elif text.startswith("*/", cursor):
                    level, cursor = level - 1, cursor + 2
                else:
                    cursor += 1
            comments.append((index, cursor))
            index = cursor
            continue
        if char in "rb" and (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_")):
            raw = re.match(r'b?r(#*)"', text[index:index + 12])
            if raw:
                closer = '"' + raw.group(1)
                end = text.find(closer, index + raw.end())
                index = size if end < 0 else end + len(closer)
                continue
        if char == '"':
            index += 1
            while index < size and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
            index += 1
            continue
        if char == "'":
            if text.startswith("\\", index + 1):
                end = text.find("'", index + 3)
                index = size if end < 0 else end + 1
            elif index + 2 < size and text[index + 2] == "'":
                index += 3
            else:
                index += 1  # a lifetime
            continue
        if text.startswith("#[", index) or text.startswith("#![", index):
            end = _matching(text, text.index("[", index), "[", "]")
            attribute = text[index:end + 1]
            match = _RUST_ATTR.match(attribute)
            if match:
                build = rust_cfg_build(match.group(2)) if match.group(2) is not None else TEST
                label = re.sub(r"\s+", " ", attribute)
                if build and attribute.startswith("#!") and depth == 0:
                    regions.append((0, size, build, label))
                elif build:
                    start = pending[0][2] if pending else index
                    pending.append((build, label, start, depth, parens))
            index = end + 1
            continue
        if text.startswith("cfg!(", index):
            end = _matching(text, index + 4, "(", ")")
            build = rust_cfg_build(text[index + 5:end])
            if build and re.match(r"\s*\{", text[end + 1:end + 40]):
                pending.append((build, "cfg!(%s)" % text[index + 5:end], index, depth, parens))
            index = end + 1
            continue
        if char == "{":
            for build, label, start, _, _ in pending:
                open_items.append((depth, start, build, label))
            pending.clear()
            depth += 1
        elif char == "}":
            close_pending(index)
            depth -= 1
            while open_items and open_items[-1][0] == depth:
                _, start, build, label = open_items.pop()
                regions.append((start, index + 1, build, label))
        elif char in "([":
            parens += 1
        elif char in ")]":
            parens -= 1
        elif char == ";" and pending:
            close_pending(index + 1)
        elif char == "," and pending and pending[-1][3] == depth and pending[-1][4] == parens:
            close_pending(index + 1)
        index += 1
    for _, start, build, label in open_items:
        regions.append((start, size, build, label))
    return regions, sorted(comments)


def rust_test_files(root):
    """Files whose module is declared under #[cfg(test)] (`#[cfg(test)] mod tests;`)."""
    found = set()
    declaration = re.compile(r"#\[cfg\(\s*test\s*\)\]\s*(?:#\[path\s*=\s*\"([^\"]+)\"\]\s*)?"
                             r"(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;")
    for rel, full in _walk(root, DAEMON_ROOT, ".rs"):
        text = _read(full)
        if "cfg(test)" not in text:
            continue
        directory, stem = os.path.dirname(rel), os.path.splitext(os.path.basename(rel))[0]
        base = directory if stem in ("mod", "lib", "main") else os.path.join(directory, stem)
        for match in declaration.finditer(text):
            if match.group(1):
                found.add(os.path.normpath(os.path.join(base, match.group(1))).replace(os.sep, "/"))
                continue
            found.add(os.path.join(base, match.group(2) + ".rs").replace(os.sep, "/"))
            found.add(os.path.join(base, match.group(2), "mod.rs").replace(os.sep, "/"))
    return found


def rust_test_path(rel):
    parts = rel.split("/")
    return (any(part in ("tests", "benches", "examples", "testdata", "fixtures") for part in parts[:-1])
            or parts[-1] in ("tests.rs", "test.rs") or parts[-1].endswith(("_tests.rs", "_test.rs")))


def rust_file(path, text, test_file):
    def parse(text):
        regions, comments = rust_regions(text)

        def build_at(offset, line):
            enclosing = [region for region in regions if region[0] <= offset < region[1]]
            builds = [region[2] for region in enclosing] + ([TEST] if test_file else [])
            labels = [region[3] for region in enclosing] + (["test file"] if test_file else [])
            return least_shipped(builds), " ; ".join(dict.fromkeys(labels))

        return comments, build_at

    return SourceFile(path, text, parse)


# --- sites -----------------------------------------------------------------------------------------

# Patterns over one source line; %s is the escaped literal.
KINDS = {
    "swift": (
        ("write", r'"%s"\s*(\]\s*=[^=]|:)|setenv\(\s*"%s"|unsetenv\(\s*"%s"|(updateValue|removeValue)\([^)]*"%s"'),
        ("decl", r'\b(let|var|case)\s+\w+[^=]*=\s*"%s"'),
        ("read", r'getenv\(\s*"%s"|[eE]nv\w*\s*\[\s*"%s"|[eE]nv\w*\(\s*"%s"|\(\s*"%s"\s*[,)]'),
    ),
    "rust": (
        ("write", r'\.env\(\s*"%s"|set_var\(\s*"%s"|remove_var\(\s*"%s"|env_remove\(\s*"%s"|\(\s*"%s"\s*,\s*[^)]|'
                  r'insert\(\s*"%s"'),
        ("decl", r'\b(const|static)\s+\w+\s*:[^=]*=\s*"%s"|\blet\s+\w+[^=]*=\s*"%s"'),
        ("read", r'var(_os)?\(\s*"%s"|env\w*\(\s*"%s"|\.get\(\s*"%s"|\(\s*"%s"\s*\)'),
    ),
}
_DECL_IDENT = {"swift": re.compile(r"\b(?:let|var|case)\s+(\w+)"),
               "rust": re.compile(r"\b(?:const|static|let)\s+(?:mut\s+)?(\w+)")}
_IMPORT_LINE = re.compile(r"^\s*(pub(\([^)]*\))?\s+)?use\b|^\s*(public\s+)?import\b")


def site_kind(language, line, name):
    escaped = re.escape(name)
    for kind, pattern in KINDS[language]:
        if re.search(pattern.replace("%s", escaped), line):
            return kind
    return "other"


_SWIFT_TYPE = re.compile(r"\b(?:struct|class|enum|extension|actor|protocol)\s+(\w+)")
_RUST_PUBLIC = re.compile(r"^\s*pub\b")


def _uses(files, home, offset, ident, language):
    """[(file, offset)] where code names the constant declared at `offset`: any word use in its own file,
    and in another file of the scope `Type.ident` (Swift, the type the declaration sits in) or, for a
    `pub` Rust constant, `path::IDENT` or a bare use in a file that imports it and declares no constant
    of that name."""
    found = [(home, match.start()) for match in re.finditer(r"\b%s\b" % re.escape(ident), home.text)]
    line = home.lines[home.line_of(offset) - 1]
    if language == "swift":
        owners = _SWIFT_TYPE.findall(home.text[:offset])
        other = re.compile(r"\b%s\.%s\b" % (re.escape(owners[-1]), re.escape(ident))) if owners else None
    else:
        other = re.compile(r"::%s\b" % re.escape(ident)) if _RUST_PUBLIC.match(line) else None
    own = re.compile(r"\b(?:const|static)\s+%s\b" % re.escape(ident))
    imported = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?use\b[^;]*\b%s\b" % re.escape(ident), re.M)
    for source in files:
        if other is None or source is home or ident not in source.text:
            continue
        found += [(source, match.start()) for match in other.finditer(source.text)]
        if language == "rust" and imported.search(source.text) and not own.search(source.text):
            found += [(source, match.start()) for match in re.finditer(r"\b%s\b" % re.escape(ident), source.text)]
    return [(source, use) for source, use in dict.fromkeys(found)
            if not source.in_comment(use)
            and not _IMPORT_LINE.match(source.lines[source.line_of(use) - 1])
            and not (source is home and source.line_of(use) == home.line_of(offset))]


def collect(files, query, prefix, language):
    sites = []
    for source in files:
        if prefix not in source.text:
            continue
        for match in query.finditer(source.text):
            name, offset = match.group(1), match.start()
            line = source.line_of(offset)
            build, condition = source.build_at(offset)
            kind = site_kind(language, source.lines[line - 1], name) if build != COMMENT else "doc"
            ident = _DECL_IDENT[language].search(source.lines[line - 1]) if kind == "decl" else None
            if ident:
                uses = _uses(files, source, offset, ident.group(1), language)
                if uses:
                    used = [(other.build_at(use), other, use) for other, use in uses]
                    (build, _), other, use = min(used, key=lambda item: BUILDS.index(item[0][0]))
                    condition = "via %s at %s:%d" % (ident.group(1), other.path, other.line_of(use))
            sites.append(Site(name, source.path, line, build, kind, condition))
    return sites


def scan_swift(root):
    return collect([swift_file(rel, _read(full)) for rel, full in _walk(root, APP_ROOT, ".swift")],
                   APP_QUERY, "CMUX_", "swift")


def scan_rust(root):
    tests = rust_test_files(root)
    return collect([rust_file(rel, _read(full), rel in tests or rust_test_path(rel))
                    for rel, full in _walk(root, DAEMON_ROOT, ".rs")], DAEMON_QUERY, "CMUX_TUI_", "rust")


# --- audit -----------------------------------------------------------------------------------------

def observe(root):
    """{(scope, name): [Site]} for both queries."""
    observed = {}
    for scope, sites in (("app", scan_swift(root)), ("daemon", scan_rust(root))):
        for site in sites:
            observed.setdefault((scope, site.name), []).append(site)
    return observed


def builds_of(sites):
    """The builds a name is named in, most shipped first; comments left out unless that is all there is."""
    builds = sorted({site.build for site in sites} - {COMMENT}, key=BUILDS.index)
    return builds or [COMMENT]


class AuditFileError(Exception):
    """The audit file exists but is not a JSON object with a `names` object."""


def load_audit(root):
    path = os.path.join(root, AUDIT)
    if not os.path.exists(path):
        return {"names": {}}
    with open(path, encoding="utf-8") as handle:
        try:
            audit = json.load(handle)
        except json.JSONDecodeError as error:
            raise AuditFileError("%s: %s" % (AUDIT, error)) from error
    if not isinstance(audit, dict) or not isinstance(audit.get("names"), dict):
        raise AuditFileError("%s: expected an object with a \"names\" object" % AUDIT)
    return audit


def entry_key(scope, name):
    return "%s %s" % (scope, name)


def problems(audit, observed):
    """[(key, message)]: what --check fails on."""
    found = []
    entries = audit.get("names", {})
    keys = {entry_key(scope, name): sites for (scope, name), sites in observed.items()}
    for key in sorted(set(keys) - set(entries)):
        found.append((key, "new name: classify it in %s (run --write to add it)" % AUDIT))
    for key in sorted(set(entries) - set(keys)):
        found.append((key, "stale: no source names it any more; remove it (run --write)"))
    for key in sorted(set(entries) & set(keys)):
        entry, sites = entries[key], keys[key]
        klass = entry.get("class")
        if klass not in CLASSES:
            found.append((key, "unclassified: class %r is not one of %s" % (klass, ", ".join(CLASSES))))
            continue
        if not entry.get("effect"):
            found.append((key, "no effect: say what the name changes"))
        builds = builds_of(sites)
        if entry.get("builds") != builds:
            found.append((key, "builds changed from %s to %s: review the class, then run --write"
                          % (entry.get("builds"), builds)))
        allowed = CLASSES[klass][1]
        if allowed is not None and not set(builds) <= allowed:
            found.append((key, "class %s but read in %s: %s" % (klass, ", ".join(builds), "; ".join(
                site.ref() for site in sites if site.build not in allowed))))
        if klass.startswith("release") and not set(builds) & SHIPPED:
            found.append((key, "class %s but no shipped build reads it any more (%s): reclassify it"
                          % (klass, ", ".join(builds))))
        if CLASSES[klass][2] and not entry.get("followup"):
            found.append((key, "class %s needs a followup (the feature to add or the #if DEBUG to move)"
                          % klass))
        if not CLASSES[klass][2] and entry.get("followup"):
            found.append((key, "class %s takes no followup" % klass))
    return found


def refreshed(audit, observed):
    """The audit with every observed name, its current sites and builds; classes kept."""
    entries = audit.get("names", {})
    names = {}
    for (scope, name), sites in sorted(observed.items()):
        key = entry_key(scope, name)
        entry = dict(entries.get(key, {"class": None, "effect": ""}))
        entry["scope"], entry["name"] = scope, name
        entry["builds"] = builds_of(sites)
        entry["sites"] = [site.ref() for site in sorted(sites, key=lambda s: (s.path, s.line))]
        names[key] = {field: entry[field] for field in
                      ("scope", "name", "class", "effect", "followup", "builds", "sites") if field in entry}
    return {
        "$comment": ("GENERATED sites and builds by scripts/features/env_audit.py --write; class, effect and "
                     "followup are reviewed by hand. Queries: app = \"CMUX_*\" literals in %s/**/*.swift, "
                     "daemon = \"CMUX_TUI_*\" literals in %s/**/*.rs." % (APP_ROOT, DAEMON_ROOT)),
        "classes": {name: meaning[0] for name, meaning in CLASSES.items()},
        "names": names,
    }


def dump(audit):
    return json.dumps(audit, indent=1, ensure_ascii=False) + "\n"


def queue(audit, observed):
    """MQ7: an unclassified name, or a releasePerf name with its follow-up, one per line."""
    rows, entries = [], audit.get("names", {})
    for (scope, name), sites in sorted(observed.items()):
        entry = entries.get(entry_key(scope, name), {})
        first = sorted(sites, key=lambda s: (s.build != RELEASE, s.path, s.line))[0]
        if entry.get("class") not in CLASSES:
            rows.append("unclassified %s %s %s" % (scope, name, first.ref()))
        elif CLASSES[entry["class"]][2]:
            rows.append("followup %s %s %s: %s" % (scope, name, first.ref(), entry.get("followup", "")))
    return rows


def main(argv=None, root=ROOT):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="exit 1 on a new, stale, unclassified or misclassified name")
    mode.add_argument("--write", action="store_true", help="refresh sites and builds, keep the classes")
    mode.add_argument("--unclassified", action="store_true", help="MQ7: unclassified names and releasePerf follow-ups")
    parser.add_argument("--count", action="store_true", help="with --unclassified: print only the number")
    args = parser.parse_args(argv)

    try:
        audit = load_audit(root)
    except AuditFileError as error:
        print("env audit: %s" % error, file=sys.stderr)
        return 1
    observed = observe(root)
    if args.write:
        os.makedirs(os.path.dirname(os.path.join(root, AUDIT)), exist_ok=True)
        with open(os.path.join(root, AUDIT), "w", encoding="utf-8") as handle:
            handle.write(dump(refreshed(audit, observed)))
        print("wrote %s: %d names" % (AUDIT, len(observed)))
        return 0
    if args.unclassified:
        rows = queue(audit, observed)
        print(len(rows) if args.count else "\n".join(rows))
        return 0
    found = problems(audit, observed)
    for key, message in found:
        print("%s: %s" % (key, message), file=sys.stderr)
    if found:
        print("env audit: %d problem(s) in %s" % (len(found), AUDIT), file=sys.stderr)
        return 1
    stale_sites = sum(1 for (scope, name), sites in observed.items()
                      if audit["names"][entry_key(scope, name)].get("sites") !=
                      [site.ref() for site in sorted(sites, key=lambda s: (s.path, s.line))])
    print("env audit: %d names classified (%d app, %d daemon)%s" % (
        len(observed), sum(1 for scope, _ in observed if scope == "app"),
        sum(1 for scope, _ in observed if scope == "daemon"),
        "; %d site lists moved, refresh with --write" % stale_sites if stale_sites else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
