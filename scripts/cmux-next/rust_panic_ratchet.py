#!/usr/bin/env python3
"""Compiler-accurate panic ratchet for the cmux-tui Rust workspace.

Plan: plans/cmux-next/rust-panic-free.md. The production code of every
cmux-tui crate (the `--lib` and `--bins` targets; never `#[cfg(test)]`
code, `tests/`, `benches/`, `examples/` or build scripts) is checked with
the clippy lints in LINTS. A crate may never gain a hit of a lint; fixing
hits is free (lower the baseline with --update-baseline in the same commit).
A crate that is not in the baseline must have zero hits: new crates start
panic-free. A crate whose DENY_LINTS counts are all zero is "deny": any new
hit fails, the same as `#![deny(...)]`. TRACKED_LINTS (arithmetic, casts)
use the same baseline but only warn when they grow.

Why not `[workspace.lints.clippy] unwrap_used = "deny"`: Cargo applies the
workspace table to every target of every member with no per-crate or
per-target override, so a workspace deny would fail 56 crates at once, and
also fail test helpers in `tests/` and build scripts unless hundreds of
test roots carried an allow. Checking only the production targets keeps
tests free by construction and needs no Cargo.toml change.

A reviewed exception is `#[allow(clippy::<lint>, reason = "...")]` on the
smallest item (clippy honours it, so the hit is not counted). Every such
allow in production sources must carry `reason =`; one without fails.

Usage:
  # 1. lint (on rbx, a Testbox or CI; never the laptop):
  cargo clippy --workspace --lib --bins --locked --message-format=json -- $(rust_panic_ratchet.py --flags) > clippy.jsonl
  # 2. compare (laptop OK, read-only):
  rust_panic_ratchet.py --clippy-json clippy.jsonl [--update-baseline] [--report md|json]
  # 3. merge the Linux run with the macOS fleet run (scripts/cmux-next/rust-panic-macos.sh):
  rust_panic_ratchet.py --clippy-json linux=linux.jsonl --clippy-json macos=macos.jsonl --report md
  # 4. the Q10 fix queue (tasks of <= 50 deny-lint hits; see "Q10 fix queue" below):
  rust_panic_ratchet.py --clippy-json linux=linux.jsonl --clippy-json macos=macos.jsonl --queue [json|md]
Exit 1 when a crate gained a DENY_LINTS hit (a new crate: any), or an allow lacks a reason.
TRACKED_LINTS increases print a warning annotation and pass.

Several --clippy-json runs (each [LABEL=]PATH; the label defaults to the file
name without its extension) are merged into one set of hits: a hit is one
lint at one workspace-relative file:line:column, so a line both runs see
counts once, and a `#[cfg(target_os = ...)]` line only one run compiles is
added. The report then lists the hits only one run saw (the macOS-only
hits). The CI-read baseline stays the Linux run's, the one CI repeats, so a
merged run never writes it (--update-baseline and --init-baseline take one
run).
"""
import argparse
import collections
import fnmatch
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BASELINE = os.path.join(HERE, "rust-panic-baseline.json")

# Lints whose zero makes a crate "deny" (a panic in production code).
DENY_LINTS = [
    "unwrap_used",
    "expect_used",
    "panic",
    "unreachable",
    "todo",
    "unimplemented",
    "indexing_slicing",
    "string_slice",
    "panic_in_result_fn",
]
# Tracked by the same ratchet (never grow), but not required for "deny":
# integer overflow panics only in debug builds (release wraps), and a
# truncating cast never panics; both matter on parsers, which the fuzz
# targets cover (plans/cmux-next/rust-panic-free.md, "Arithmetic and casts").
TRACKED_LINTS = [
    "arithmetic_side_effects",
    "cast_possible_truncation",
]
LINTS = DENY_LINTS + TRACKED_LINTS
# Frozen test fixtures (a binary as it once shipped, never edited): the
# ratchet neither counts their hits nor scans their allows, so no lint or
# toolchain change can ask for an edit.
FROZEN_FIXTURES = {"cmux-holder-v3"}

ALLOW_ATTR = re.compile(r"#!?\[(?:cfg_attr\([^\]]*?,\s*)?(allow|expect)\(([^\]]*)\)\]", re.S)
REASON = re.compile(r"\breason\s*=")
LINT_NAME = re.compile(r"clippy::(\w+)")


def lint_flags():
    return " ".join(f"-W clippy::{lint}" for lint in LINTS)


def crate_of(path):
    """crates/<name>/... -> <name>; bindings/<x>/... -> bindings-<x>; else None."""
    parts = path.replace("\\", "/").split("/")
    # clippy prints paths relative to the workspace root (cmux-tui/).
    if "cmux-tui" in parts:
        parts = parts[parts.index("cmux-tui") + 1:]
    if len(parts) >= 3 and parts[0] == "crates":
        return parts[1]
    if len(parts) >= 3 and parts[0] == "bindings":
        return "bindings-" + parts[1]
    return None


def package_name(package_id):
    # "path+file:///w/src/cmux-tui/crates/acpmux#0.1.0" or "acpmux 0.1.0 (path+file://...)"
    match = re.search(r"/crates/([^/#)\s]+)", package_id)
    if match:
        return match.group(1)
    match = re.search(r"/bindings/([^/#)\s]+)", package_id)
    if match:
        return "bindings-" + match.group(1)
    return None


def workspace_path(file_name):
    """A span's file as a cmux-tui workspace-relative path, so runs on two hosts name a file alike.

    clippy prints workspace members relative to the workspace root; an absolute
    path (a checkout at another place) keeps its part from crates/ or bindings/.
    """
    path = file_name.replace("\\", "/")
    if path.startswith("/"):
        for top in ("/cmux-tui/crates/", "/cmux-tui/bindings/"):
            at = path.find(top)
            if at >= 0:
                return path[at + len("/cmux-tui/"):]
    return path


class ClippyRun:
    """One clippy --message-format=json run: the crates it checked, whether it finished, its hits."""

    def __init__(self, label):
        self.label = label
        self.checked = set()
        self.finished = None
        # (workspace file, line, column, lint) -> crate, in first-seen order.
        self.hits = {}


def read_run(path, label=None):
    run = ClippyRun(label or os.path.splitext(os.path.basename(path))[0])
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            reason = item.get("reason")
            if reason == "build-finished":
                run.finished = bool(item.get("success"))
                continue
            if reason == "compiler-artifact":
                name = package_name(item.get("package_id", ""))
                if name and name not in FROZEN_FIXTURES and any(k in ("lib", "rlib", "bin", "cdylib", "staticlib", "proc-macro", "dylib")
                                for k in item.get("target", {}).get("kind", [])):
                    run.checked.add(name)
                continue
            if reason != "compiler-message":
                continue
            if "custom-build" in (item.get("target") or {}).get("kind", []):
                continue  # build scripts run at build time, never in a daemon
            message = item.get("message") or {}
            code = (message.get("code") or {}).get("code") or ""
            if not code.startswith("clippy::"):
                continue
            lint = code[len("clippy::"):]
            if lint not in LINTS:
                continue
            span = next((s for s in message.get("spans", []) if s.get("is_primary")), None)
            if span is None:
                continue
            file_name = span.get("file_name", "")
            crate = crate_of(file_name) or package_name(item.get("package_id", ""))
            if crate is None:
                continue  # vendor/ or registry code: third-party
            if crate in FROZEN_FIXTURES:
                continue
            # The same source line seen through a lib and a bin target counts once.
            run.hits.setdefault((workspace_path(file_name), span.get("line_start"), span.get("column_start"), lint), crate)
    return run


def merged_hits(runs):
    """{(workspace file, line, column, lint): (crate, {labels of the runs that saw it})}, first-seen order."""
    merged = {}
    for run in runs:
        for key, crate in run.hits.items():
            merged.setdefault(key, (crate, set()))[1].add(run.label)
    return merged


def merge_runs(runs):
    """Return (checked, {crate: {lint: count}}, {crate: {file: count}}, finished, {(crate, lint): [loc]}, only).

    `only` maps a run's label to {crate: [(loc, lint)]}: the hits no other run saw.
    With one run it is empty.
    """
    checked = set()
    for run in runs:
        checked |= run.checked
    both = merged_hits(runs)
    merged = {key: crate for key, (crate, _) in both.items()}
    seen_by = {key: labels for key, (_, labels) in both.items()}
    counts = collections.defaultdict(collections.Counter)
    files = collections.defaultdict(collections.Counter)
    hits = collections.defaultdict(list)
    only = {run.label: collections.defaultdict(list) for run in runs} if len(runs) > 1 else {}
    for key, crate in merged.items():
        file_name, line, column, lint = key
        loc = f"{file_name}:{line}:{column}"
        counts[crate][lint] += 1
        hits[(crate, lint)].append(loc)
        files[crate][file_name] += 1
        if only and len(seen_by[key]) == 1:
            only[next(iter(seen_by[key]))][crate].append((loc, lint))
    finished = all(run.finished is True for run in runs) if runs else None
    return checked, counts, files, finished, hits, only


def read_clippy(path):
    """One run: (checked crate set, {crate: {lint: count}}, {crate: {file: count}}, finished, hits)."""
    return merge_runs([read_run(path)])[:5]


def parse_run_arg(value):
    """`LABEL=PATH` or `PATH` (the label is then the file name without its extension)."""
    label, sep, path = value.partition("=")
    if sep and re.fullmatch(r"[A-Za-z0-9_.-]+", label) and not os.path.exists(value):
        return label, path
    return None, value


def allow_without_reason(root):
    """Production-source allow/expect attributes on our lints that carry no reason."""
    bad = []
    for top in ("crates", "bindings"):
        bad.extend(_allow_scan(root, os.path.join(root, "cmux-tui", top)))
    return bad


def _allow_scan(root, crates_dir):
    bad = []
    for dirpath, dirnames, filenames in os.walk(crates_dir):
        rel = os.path.relpath(dirpath, crates_dir).replace("\\", "/")
        parts = rel.split("/")
        if parts[0] in FROZEN_FIXTURES:
            dirnames[:] = []
            continue
        if len(parts) >= 2 and parts[1] in ("tests", "benches", "examples", "fuzz", "target"):
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in ("target", "tests", "benches", "examples", "fuzz")]
        for name in filenames:
            if not name.endswith(".rs") or name in ("build.rs",) or name.endswith("_tests.rs") or name == "tests.rs":
                continue
            path = os.path.join(dirpath, name)
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for match in ALLOW_ATTR.finditer(text):
                kind, body = match.group(1), match.group(2)
                lints = [l for l in LINT_NAME.findall(body) if l in LINTS]
                if lints and kind == "expect":
                    line = text.count("\n", 0, match.start()) + 1
                    bad.append(f"{os.path.relpath(path, root)}:{line}: use allow, not expect, for {', '.join(lints)} "
                               "(the plain clippy run does not enable these lints, so expect is unfulfilled)")
                elif lints and not REASON.search(body):
                    line = text.count("\n", 0, match.start()) + 1
                    bad.append(f"{os.path.relpath(path, root)}:{line}: allow({', '.join(lints)}) needs reason = \"...\"")
    return bad


def _changed_first(root, locations):
    """Hit locations in files changed against origin/feat-cmux-next first (where a new hit is)."""
    try:
        import subprocess
        out = subprocess.run(["git", "-C", root, "diff", "--name-only", "origin/feat-cmux-next...HEAD"],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    changed = {line.split("cmux-tui/", 1)[-1] for line in out.splitlines()}
    return sorted(locations, key=lambda loc: (loc.split(":", 1)[0] not in changed, loc))


def load_baseline():
    if not os.path.exists(BASELINE):
        return {}
    with open(BASELINE, encoding="utf-8") as handle:
        return json.load(handle).get("crates", {})


def write_baseline(crates):
    data = {
        "_doc": "Per-crate clippy hit counts of production code (scripts/cmux-next/rust_panic_ratchet.py). "
                "Counts only go down. A crate with every deny lint at 0 is at deny.",
        "lints": LINTS,
        "deny_lints": DENY_LINTS,
        "crates": {crate: {lint: crates[crate].get(lint, 0) for lint in LINTS} for crate in sorted(crates)},
    }
    with open(BASELINE, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")


def is_deny(lints):
    return all(lints.get(lint, 0) == 0 for lint in DENY_LINTS)


SHORT = {"unwrap_used": "unwrap", "expect_used": "expect", "panic": "panic", "unreachable": "unreach",
         "todo": "todo", "unimplemented": "unimpl", "indexing_slicing": "index", "string_slice": "strslice",
         "panic_in_result_fn": "panic_in_result", "arithmetic_side_effects": "arith",
         "cast_possible_truncation": "cast_trunc"}


def report(checked, counts, files, fmt, only=None):
    only = only or {}
    rows = []
    for crate in sorted(checked | set(counts)):
        c = counts.get(crate, {})
        top = ", ".join(f"{f} {n}" for f, n in files.get(crate, collections.Counter()).most_common(3))
        rows.append((crate, c, is_deny(c), top))
    if fmt == "json":
        out = {}
        for crate, c, deny, top in rows:
            out[crate] = {"counts": dict(c), "deny": deny, "top": top}
            if only:
                out[crate]["only_in"] = {label: [{"loc": loc, "lint": lint} for loc, lint in sorted(by_crate.get(crate, []))]
                                         for label, by_crate in only.items()}
        print(json.dumps(out, indent=1))
        return
    print("| crate | " + " | ".join(SHORT[l] for l in LINTS) + " | deny | top files |")
    print("|" + " --- |" * (len(LINTS) + 3))
    rows.sort(key=lambda r: -sum(r[1].get(l, 0) for l in DENY_LINTS))
    for crate, c, deny, top in rows:
        print(f"| {crate} | " + " | ".join(str(c.get(l, 0)) for l in LINTS) + f" | {'yes' if deny else 'no'} | {top} |")
    for label, by_crate in only.items():
        total = sum(len(v) for v in by_crate.values())
        print(f"\n### Hits only the {label} run saw ({total})\n")
        if not total:
            print("none")
            continue
        print("| crate | lint | location |")
        print("| --- | --- | --- |")
        for crate in sorted(by_crate):
            for loc, lint in sorted(by_crate[crate]):
                print(f"| {crate} | {SHORT[lint]} | {loc} |")


# --- Q10 fix queue (--queue) ------------------------------------------------
#
# The deny-lint hits of a (merged) run become fix tasks of at most
# QUEUE_MAX_HITS hits each, so one agent takes one task: a file with more hits
# is split into balanced line ranges, and the smaller files of one module
# directory and owner are packed in path order into one task up to the limit.
# Every hit is in exactly one task. Each task names its crate, Rust module,
# owner (plans/cmux-next/OWNERS.md, the most specific row; PL-stability, the
# panic lane, when no row covers the file), class and boundary error type.
#
# Class (the Q14 reachability proxy of chrome-parity/p10-stability.md section
# D, per file): "input" when the file defines a Q14 decode entry point or reads
# outside bytes (INPUT_SIGNALS), so its hits get validation that returns a
# typed error; otherwise "invariant", whose hits get a real fix or an
# allow(..., reason = "INVARIANT: ...") item. A file the generator cannot read
# is "input", so no hit reaches the INVARIANT path unread. A task is "input"
# when any of its files is.
#
# Boundary error type (per file): the error type the file's functions already
# return most often (`-> Result<T, E>`, `io::Result`, `anyhow::Result`, the
# crate's `type Result<T> = ...` alias); else an `...Error` type the file
# defines; else one its directory or the crate's src/ defines (error.rs,
# errors.rs, mod.rs, lib.rs, main.rs); else none, and the task adds one.

QUEUE_MAX_HITS = 50
QUEUE_DEFAULT_OWNER = "PL-stability"
OWNERS_DOC = os.path.join("plans", "cmux-next", "OWNERS.md")
INPUT_SIGNALS = re.compile(
    r"\bpub(?:\(crate\))?\s+fn\s+(?:decode|parse|from_bytes|read_frame|from_slice)"  # Q14 entry points
    r"|\bserde_json::from_(?:str|slice|reader|value)\b|\bbincode::deserialize|\btoml::from_str\b"
    r"|\bfrom_utf8\b|\.read_exact\(|\.read_to_end\(|\.read_to_string\(|\.read_line\(|\bfs::read(?:_to_string)?\(")
ERROR_TYPE_DEF = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:enum|struct)\s+(\w*Error)\b", re.M)
RESULT_ALIAS = re.compile(r"\btype\s+Result\s*<\s*\w+\s*>\s*=\s*(?:\w+::)*Result\s*<")
RETURN_RESULT = re.compile(r"->\s*((?:\w+::)*)Result\s*<")
ERROR_FILES = ("error.rs", "errors.rs", "mod.rs", "lib.rs", "main.rs")


def _generic_args(text, start):
    """The generic arguments that open at text[start] ('<'), split at their top-level commas; None if unclosed."""
    depth, args, current = 0, [], []
    for at in range(start, min(len(text), start + 400)):
        char = text[at]
        if char == "<":
            depth += 1
            if depth == 1:
                continue
        elif char == ">" and text[at - 1] != "-":
            depth -= 1
            if depth == 0:
                args.append("".join(current).strip())
                return args
        elif char == "," and depth == 1:
            args.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    return None


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


class QueueSource:
    """The checkout a queue describes: its source files, crate Result aliases and OWNERS.md rows."""

    def __init__(self, repo):
        self.repo = repo
        self._aliases = {}
        self._dir_errors = {}
        self.owner_rows = self._owner_rows()

    def text(self, path):
        return _read(os.path.join(self.repo, path))

    def _owner_rows(self):
        rows = []
        for line in (self.text(OWNERS_DOC) or "").splitlines():
            if not line.startswith("|"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) < 3:
                continue
            match = re.search(r"\bPL-[\w-]+", cells[2])
            owner = match.group(0) if match else cells[2].split("(")[0].strip()
            for owned in re.findall(r"`([^`]+)`", cells[1]):
                rows.append((owned, owner))
        return rows

    def owner(self, path):
        """(owner, the OWNERS.md path that names it, or None) for a repo-relative file."""
        best = None
        for owned, owner in self.owner_rows:
            if any(c in owned for c in "*?["):
                hit = fnmatch.fnmatch(path, owned) or fnmatch.fnmatch(path, owned.rstrip("/") + "/*")
            else:
                hit = path == owned or path.startswith(owned.rstrip("/") + "/")
            if hit and (best is None or len(owned) > len(best[0])):
                best = (owned, owner)
        return (best[1], best[0]) if best else (QUEUE_DEFAULT_OWNER, None)

    @staticmethod
    def crate_src(path):
        parts = path.split("/")
        return "/".join(parts[:parts.index("src") + 1]) if "src" in parts else os.path.dirname(path)

    def _crate_alias(self, path):
        """The E of the crate's `type Result<T> = Result<T, E>` alias, or None."""
        src = self.crate_src(path)
        if src not in self._aliases:
            self._aliases[src] = None
            for dirpath, dirnames, filenames in os.walk(os.path.join(self.repo, src)):
                dirnames.sort()
                for name in sorted(n for n in filenames if n.endswith(".rs")):
                    text = _read(os.path.join(dirpath, name)) or ""
                    match = RESULT_ALIAS.search(text)
                    args = _generic_args(text, match.end() - 1) if match else None
                    if args and len(args) == 2:
                        self._aliases[src] = " ".join(args[1].split())
                        break
                if self._aliases[src]:
                    break
        return self._aliases[src]

    def boundary_error(self, path, text):
        """(error type or None, where it was found) for one repo-relative file and its text."""
        if text:
            seen = collections.Counter()
            for match in RETURN_RESULT.finditer(text):
                prefix = match.group(1)
                args = _generic_args(text, match.end() - 1)
                if not args:
                    continue
                if prefix.endswith("io::"):
                    seen["std::io::Error"] += 1
                elif prefix.endswith("anyhow::"):
                    seen["anyhow::Error"] += 1
                elif len(args) == 2:
                    error = " ".join(args[1].split())
                    if not re.fullmatch(r"[A-Z]", error):  # a generic parameter names no type
                        seen[error] += 1
                elif len(args) == 1 and not prefix and self._crate_alias(path):
                    seen[self._crate_alias(path)] += 1
            if seen:
                return min(seen.items(), key=lambda kv: (-kv[1], kv[0]))[0], "returned here"
            match = ERROR_TYPE_DEF.search(text)
            if match:
                return match.group(1), "defined here"
        for directory in (os.path.dirname(path), self.crate_src(path)):
            found = self._dir_error(directory)
            if found:
                return found
        return None, "none: add a typed error"

    def _dir_error(self, directory):
        if directory not in self._dir_errors:
            self._dir_errors[directory] = None
            for name in ERROR_FILES:
                match = ERROR_TYPE_DEF.search(self.text(f"{directory}/{name}") or "")
                if match:
                    self._dir_errors[directory] = (match.group(1), f"defined in {directory}/{name}")
                    break
        return self._dir_errors[directory]


def rust_module(path):
    """crates/<c>/src/a/b.rs -> c::a::b; src/lib.rs -> c; src/main.rs -> c (bin); src/bin/x.rs -> c (bin x)."""
    parts = path.split("/")
    root = (crate_of(path) or os.path.splitext(parts[-1])[0]).replace("-", "_")
    if "src" not in parts:
        return root
    rest = parts[parts.index("src") + 1:]
    if rest in (["lib.rs"], ["mod.rs"], []):
        return root
    if rest == ["main.rs"]:
        return f"{root} (bin)"
    if rest[0] == "bin":
        return f"{root} (bin {os.path.splitext(rest[1])[0]})" if len(rest) > 1 and rest[1] != "mod.rs" else f"{root} (bins)"
    rest[-1] = os.path.splitext(rest[-1])[0]
    if rest[-1] == "mod":
        rest.pop()
    return "::".join([root] + rest)


def _balanced_chunks(items, limit):
    count = -(-len(items) // limit)
    size, extra = divmod(len(items), count)
    chunks, at = [], 0
    for index in range(count):
        step = size + (1 if index < extra else 0)
        chunks.append(items[at:at + step])
        at += step
    return chunks


def _heaviest(counter):
    return min(counter.items(), key=lambda kv: (-kv[1], kv[0]))[0] if counter else None


def build_queue(runs, source, limit=QUEUE_MAX_HITS):
    """The deny-lint hits of the merged runs as fix tasks of at most `limit` hits (see the block comment)."""
    merged = len(runs) > 1
    by_file = collections.defaultdict(list)
    crates = {}
    for (file_name, line, column, lint), (crate, labels) in merged_hits(runs).items():
        if lint not in DENY_LINTS:
            continue
        path = file_name if file_name.startswith(("cmux-tui/", "/")) else "cmux-tui/" + file_name
        hit = {"loc": f"{path}:{line}:{column}", "line": line or 0, "column": column or 0, "lint": lint}
        if merged and len(labels) == 1:
            hit["only_in"] = next(iter(labels))
        by_file[path].append(hit)
        crates[path] = crate
    files = {}
    for path, hits in by_file.items():
        hits.sort(key=lambda h: (h["line"], h["column"], h["lint"]))
        text = source.text(path)
        error, error_source = source.boundary_error(path, text)
        owner, owner_row = source.owner(path)
        files[path] = {
            "path": path,
            "crate": crates[path],
            "module": rust_module(path),
            "class": "input" if text is None or INPUT_SIGNALS.search(text) else "invariant",
            "owner": owner,
            "owner_row": owner_row,
            "boundary_error": error,
            "boundary_error_source": error_source,
        }
    pieces = []  # ([(path, hits)], part label or None)
    groups = collections.defaultdict(list)
    for path in sorted(files):
        hits = by_file[path]
        if len(hits) > limit:
            chunks = _balanced_chunks(hits, limit)
            for index, chunk in enumerate(chunks, 1):
                pieces.append(([(path, chunk)], f"part {index}/{len(chunks)}"))
        else:
            info = files[path]
            groups[(info["crate"], os.path.dirname(path), info["owner"])].append((path, hits))
    for key in sorted(groups):
        bucket, size = [], 0
        for path, hits in groups[key]:
            if bucket and size + len(hits) > limit:
                pieces.append((bucket, None))
                bucket, size = [], 0
            bucket.append((path, hits))
            size += len(hits)
        pieces.append((bucket, None))
    pieces.sort(key=lambda piece: (crates[piece[0][0][0]], piece[0][0][0], piece[0][0][1][0]["line"]))
    tasks = []
    for number, (bucket, part) in enumerate(pieces, 1):
        infos = [files[path] for path, _ in bucket]
        hits = [hit for _, chunk in bucket for hit in chunk]
        first = infos[0]
        if len(bucket) == 1:
            module = first["module"]
            where = first["path"] + (f" ({part}, lines {hits[0]['line']}-{hits[-1]['line']})" if part else "")
        else:
            directory = os.path.dirname(first["path"])
            module = rust_module(directory + "/mod.rs")
            where = f"{directory}/ {os.path.basename(first['path'])} .. {os.path.basename(infos[-1]['path'])}"
        errors = collections.Counter()
        for path, chunk in bucket:
            if files[path]["boundary_error"]:
                errors[files[path]["boundary_error"]] += len(chunk)
        tasks.append({
            "id": f"q10-{number:04d}",
            "title": f"Panic deny: {first['crate']} {where} ({len(hits)} hits)",
            "crate": first["crate"],
            "module": module,
            "owner": first["owner"],
            "class": "input" if any(info["class"] == "input" for info in infos) else "invariant",
            "boundary_error": _heaviest(errors),
            "hit_count": len(hits),
            "counts": dict(collections.Counter(hit["lint"] for hit in hits)),
            "files": [dict(files[path], hits=len(chunk), lines=f"{chunk[0]['line']}-{chunk[-1]['line']}")
                      for path, chunk in bucket],
            "hits": [{k: v for k, v in hit.items() if k not in ("line", "column")} for hit in hits],
        })
    return {
        "_doc": "Q10 rust-panic-deny fix queue (scripts/cmux-next/rust_panic_ratchet.py --queue): every deny-lint "
                f"hit in exactly one task, at most {limit} hits per task.",
        "runs": [run.label for run in runs],
        "lints": DENY_LINTS,
        "max_hits": limit,
        "total_hits": sum(len(hits) for hits in by_file.values()),
        "tasks": tasks,
    }


def queue_markdown(queue):
    lines = [f"Q10 rust-panic-deny queue: {queue['total_hits']} hits in {len(queue['tasks'])} tasks"
             f" (at most {queue['max_hits']} each; runs: {', '.join(queue['runs'])})", "",
             "| task | crate | module | files | hits | class | owner | boundary error |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for task in queue["tasks"]:
        files = "<br>".join(f"{f['path']}:{f['lines']} ({f['hits']})" for f in task["files"])
        lines.append(f"| {task['id']} | {task['crate']} | {task['module']} | {files} | {task['hit_count']} |"
                     f" {task['class']} | {task['owner']} | {task['boundary_error'] or 'none: add one'} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flags", action="store_true", help="print the clippy lint flags and exit")
    parser.add_argument("--clippy-json", action="append", metavar="[LABEL=]PATH",
                        help="cargo clippy --message-format=json output; repeat to merge runs (Linux and macOS)")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--update-baseline", action="store_true", help="lower the baseline to the counts seen")
    parser.add_argument("--init-baseline", action="store_true", help="write the baseline from scratch (first run only)")
    parser.add_argument("--report", choices=["md", "json"])
    parser.add_argument("--queue", nargs="?", const="json", choices=["md", "json"],
                        help=f"print the Q10 fix queue (deny-lint hits in tasks of <= {QUEUE_MAX_HITS}) and exit;"
                             " the baseline is neither compared nor written")
    args = parser.parse_args()
    if args.flags:
        print(lint_flags())
        return 0
    if not args.clippy_json:
        parser.error("--clippy-json is required")
    runs = []
    for value in args.clippy_json:
        label, path = parse_run_arg(value)
        run = read_run(path, label)
        if any(other.label == run.label for other in runs):
            parser.error(f"two --clippy-json runs are labelled {run.label!r}; name them LABEL=PATH")
        runs.append(run)
    if len(runs) > 1 and (args.update_baseline or args.init_baseline):
        parser.error("--update-baseline and --init-baseline take one --clippy-json run: the CI-read baseline is the"
                     " Linux run CI repeats, and a merged run would add hits CI never sees")
    if args.queue and (args.update_baseline or args.init_baseline or args.report):
        parser.error("--queue prints only the queue: run --report and the baseline flags separately")
    for run in runs:
        if not run.checked or run.finished is not True:
            print(f"rust-panic-ratchet: the {run.label} clippy run did not finish successfully (no build-finished"
                  " success line); counts from a partial build prove nothing", file=sys.stderr)
            return 2
    if args.queue:
        queue = build_queue(runs, QueueSource(args.repo))
        print(queue_markdown(queue) if args.queue == "md" else json.dumps(queue, indent=1))
        return 0
    checked, counts, files, _, hits, only = merge_runs(runs)
    if only:
        sizes = ", ".join(f"{run.label} {len(run.hits)}" for run in runs)
        alone = ", ".join(f"{label}-only {sum(len(v) for v in by.values())}" for label, by in only.items())
        print(f"rust-panic-ratchet: merged {len(runs)} runs by file:line:column (hits: {sizes});"
              f" {sum(sum(c.values()) for c in counts.values())} distinct, {alone}", file=sys.stderr)
    if args.report:
        report(checked, counts, files, args.report, only)
    baseline = load_baseline()
    if args.init_baseline:
        write_baseline({crate: counts.get(crate, collections.Counter()) for crate in checked})
        print(f"rust-panic-ratchet: wrote {os.path.relpath(BASELINE, args.repo)} for {len(checked)} crates")
        return 0

    failures = []
    warnings = []
    lowered = {}
    for crate in sorted(checked):
        now = counts.get(crate, collections.Counter())
        base = baseline.get(crate)
        for lint in LINTS:
            got = now.get(lint, 0)
            allowed = 0 if base is None else base.get(lint, 0)
            if got > allowed:
                where = "new crate (must be 0)" if base is None else f"baseline {allowed}"
                # Tracked lints warn only: an added `x + 1` must not block a landing.
                (failures if lint in DENY_LINTS else warnings).append(f"{crate}: clippy::{lint} {got} > {where}")
                if lint in DENY_LINTS:
                    for loc in _changed_first(args.repo, hits.get((crate, lint), []))[:20]:
                        failures.append(f"    {loc}")
        if base is not None and any(now.get(l, 0) < base.get(l, 0) for l in LINTS):
            lowered[crate] = {l: min(now.get(l, 0), base.get(l, 0)) for l in LINTS}

    missing = sorted(set(baseline) - checked)
    if missing and not args.init_baseline:
        print("::warning title=rust panic ratchet::baseline crates not checked by this run (a -p run, a removed "
              "member, or a bin with required-features): " + ", ".join(missing), file=sys.stderr)
    for line in allow_without_reason(args.repo):
        failures.append(line)

    if args.update_baseline:
        if failures:
            print("rust-panic-ratchet: refusing to update the baseline while it is red", file=sys.stderr)
        else:
            merged = dict(baseline)
            merged.update(lowered)
            for crate in checked:
                now = counts.get(crate, collections.Counter())
                merged.setdefault(crate, {l: (0 if l in DENY_LINTS else now.get(l, 0)) for l in LINTS})
            write_baseline(merged)
            print(f"rust-panic-ratchet: lowered {len(lowered)} crate(s)", file=sys.stderr)

    deny = sorted(c for c in checked if is_deny(counts.get(c, {})))
    print(f"rust-panic-ratchet: {len(checked)} crates checked, {len(deny)} at deny", file=sys.stderr)
    if lowered and not args.update_baseline:
        print("::warning title=rust panic ratchet::counts went down in " + ", ".join(sorted(lowered))
              + "; lower scripts/cmux-next/rust-panic-baseline.json with --update-baseline"
              + (" on the Linux run alone" if len(runs) > 1 else "") + " in this commit,"
              " or a later change can add hits up to the old count", file=sys.stderr)
    for line in warnings:
        print(f"::warning title=rust panic ratchet (tracked lint)::{line}", file=sys.stderr)
    if failures:
        print("rust-panic-ratchet: RED", file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        print("Fix the hit (a typed error handled at a boundary), or put a reviewed\n"
              "#[allow(clippy::<lint>, reason = \"...\")] on the smallest item. Never raise the baseline.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
