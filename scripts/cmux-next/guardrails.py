#!/usr/bin/env python3
"""cmux-next guardrails: refuse new architecture debt in what a push adds; warn on hot paths and owned areas.

Run by the pre-push hook through `prepush-gate.py --pre-push` (and by a plain local `prepush-gate.py`),
never by CI (Lawrence 2026-10-23: no new CI gates). Only lines the push ADDS under
Packages/macOS/CmuxNext/Sources count, and an added line whose text the same push removes elsewhere is a
move, not new. Base debt never blocks a push (plans/cmux-next/codebase-health.md has the counts).

Refusals (rules below, `--list` prints them): each names the rule, why, the right pattern and its escape.
Skip once: CMUX_GUARDRAILS_SKIP_REASON="<rule>: <why>"; say it in your report.
Warnings (never refuse):
  perf-hot  the push changes a function marked `// perf-hot: <budget> <path-id>` (a trailing comment on its
            declaration line, or in the comment block above it); names the bench from scripts/cmux-next/perf-hot-benches.json to run before
            and after on the fleet.
  owner     the push touches an area in plans/cmux-next/OWNERS.md; names the owner and the doc to read.
  app-grow  the push grows the CmuxNextApp target or adds a file to it (new features get their own target).

  scripts/cmux-next/guardrails.py                    # what HEAD adds over origin/feat-cmux-next
  scripts/cmux-next/guardrails.py --base A --head B
  scripts/cmux-next/guardrails.py --list
"""
from __future__ import annotations

import argparse
import collections
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

SOURCES = "Packages/macOS/CmuxNext/Sources/"
APP = SOURCES + "CmuxNextApp/"
OWNERS = "plans/cmux-next/OWNERS.md"
BENCHES = "scripts/cmux-next/perf-hot-benches.json"
SKIP_ENV = "CMUX_GUARDRAILS_SKIP_REASON"
NEW_APP_FILE_MAX = 400  # check-no-godfiles.sh's per-file budget, refused here for new App files at push time
COMMENT_LINE = re.compile(r"^\s*(//|\*|/\*)")
ATTRIBUTE_LINE = re.compile(r"^\s*@\w+(\([^)]*\))?\s*$")
PERF_HOT = re.compile(r"//\s*perf-hot:\s*(?P<budget>\S+)(?:\s+(?P<path>[\w-]+))?")
DECL = re.compile(r"\b(func|init|deinit|subscript|var)\b")


def git(repo: Path, *args: str, check: bool = True) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env)
    if check and result.returncode != 0:
        raise SystemExit(f"guardrails: git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode("utf-8", "replace")


def code_of(line: str) -> str:
    """LINE without a trailing `//` comment (outside string literals) and with string contents blanked."""
    if '"' not in line and "/" not in line:
        return line
    if COMMENT_LINE.match(line):
        return ""
    out, in_string, i = [], False, 0
    while i < len(line):
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append(c)
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
        elif line.startswith("//", i):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def escaped(lines: list[str], index: int, marker: re.Pattern) -> bool:
    """MARKER on the line, on the previous code line's trailing comment, or in the comment block above."""
    if marker.search(lines[index]):
        return True
    j = index - 1
    while j >= 0 and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j])):
        if marker.search(lines[j]):
            return True
        j -= 1
    return j >= 0 and j == index - 1 and bool(marker.search(lines[j]))


@dataclass
class Added:
    path: str
    number: int  # 1-based line in head
    text: str


@dataclass
class FileChange:
    path: str
    head_lines: list[str]
    added: list[Added] = field(default_factory=list)
    touched: set[int] = field(default_factory=set)  # head line numbers the push changed (deletions mark their spot)
    removed: list[str] = field(default_factory=list)
    is_new: bool = False
    has_perf_hot: bool = False
    has_row_struct: bool = False


@dataclass
class Rule:
    id: str
    title: str
    why: str
    fix: str
    escape: str | None
    find: Callable[[FileChange, "Context"], list[Added]]


@dataclass
class Context:
    moved: collections.Counter


def new_hits(change: FileChange, ctx: Context, pattern: re.Pattern, escape: re.Pattern | None) -> list[Added]:
    hits = []
    for added in change.added:
        code = code_of(added.text)
        if not pattern.search(code):
            continue
        if escape is not None and escaped(change.head_lines, added.number - 1, escape):
            continue
        key = added.text.strip()
        if ctx.moved[key] > 0:
            ctx.moved[key] -= 1
            continue
        hits.append(added)
    return hits


def line_rule(pattern: str, escape: str | None) -> Callable[[FileChange, Context], list[Added]]:
    compiled = re.compile(pattern)
    marker = re.compile(r"//\s*" + re.escape(escape) + r"\s*\S") if escape else None
    return lambda change, ctx: new_hits(change, ctx, compiled, marker)


def enclosing_openers(lines: list[str], index: int, stop: re.Pattern) -> list[str]:
    """The lines that open the blocks around LINES[INDEX], innermost first, up to a line matching STOP."""
    openers, depth = [], 0
    for j in range(index - 1, -1, -1):
        code = code_of(lines[j])
        for c in reversed(code):
            if c == "}":
                depth += 1
            elif c == "{":
                if depth == 0:
                    openers.append(code)
                    if stop.search(code):
                        return openers
                else:
                    depth -= 1
    return openers


SLEEP = re.compile(r"\bTask\.sleep\(|\.sleep\((for|until):|\bclock\.sleep\b")
LOOP = re.compile(r"^\s*(\}\s*)?(while\b|repeat\b|for\b)|\b(while|repeat)\s*[{(!]")
FUNC_STOP = re.compile(r"\b(func|init|deinit)\b[^{]*\{|\b(Task|Task\.detached)\s*(\([^)]*\))?\s*\{")
POLL_ALLOW = re.compile(r"//\s*poll-allow:\s*\S")


def sleep_in_loop(change: FileChange, ctx: Context) -> list[Added]:
    hits = []
    for added in new_hits(change, ctx, SLEEP, POLL_ALLOW):
        openers = enclosing_openers(change.head_lines, added.number - 1, FUNC_STOP)
        if any(LOOP.search(o) for o in openers):
            hits.append(added)
    return hits


ROW_STRUCT = re.compile(r"\bstruct\s+(\w*(Row|Cell|Tile|Gap|Item)(View)?)\b[^{]*:\s*[^{]*\bView\b")
ROW_STORE = re.compile(
    r"@(ObservedObject|EnvironmentObject|StateObject|Bindable)\b|@Environment\(\s*\w+\.self\s*\)"
    r"|^\s*(?:(?:private|fileprivate|internal|public|package)\s+)?(?:let|var)\s+\w+\s*:\s*(?:any\s+)?"
    r"\w*(Store|ViewModel|Coordinator|Controller|Manager|Service|Runtime)\b")
ROW_ALLOW = re.compile(r"//\s*row-snapshot-allow:\s*\S")


def row_store(change: FileChange, ctx: Context) -> list[Added]:
    """Added store references declared in the body of a SwiftUI row type (`...Row`, `...Cell`, `...Gap`)."""
    if not change.has_row_struct:
        return []
    lines = change.head_lines
    spans: list[tuple[int, int]] = []
    for index, line in enumerate(lines):
        if not ROW_STRUCT.search(code_of(line)):
            continue
        depth, started = 0, False
        for j in range(index, len(lines)):
            for c in code_of(lines[j]):
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
            if started and depth <= 0:
                spans.append((index + 1, j + 1))
                break
    if not spans:
        return []
    inside = [a for a in change.added if any(s < a.number <= e for s, e in spans)]
    sub = FileChange(change.path, lines, inside)
    return new_hits(sub, ctx, ROW_STORE, ROW_ALLOW)


def big_new_app_file(change: FileChange, ctx: Context) -> list[Added]:
    if change.is_new and change.path.startswith(APP) and len(change.head_lines) > NEW_APP_FILE_MAX:
        return [Added(change.path, 1, f"new file, {len(change.head_lines)} lines (limit {NEW_APP_FILE_MAX})")]
    return []


RULES = (
    Rule("singleton", "New `static let shared` singleton",
         "a global hides runtime state: no injection, no test seam, every caller couples to one instance "
         f"({149} already, codebase-health.md)",
         "construct it once at the composition root (the App's startup) and pass it through `init`; "
         "`static let` is fine for constants and identifiers",
         "// singleton-allow: <why a process-wide instance is the only correct shape>",
         line_rule(r"\bstatic\s+(let|var)\s+(shared|sharedInstance|instance)\b", "singleton-allow:")),
    Rule("assume-isolated", "`MainActor.assumeIsolated` without a main-thread proof",
         "it traps in Release when the caller is not on main, and nothing proves it is",
         "make the caller `@MainActor` (and await it), or prove the thread on the line or above: "
         "`// main-proof: <why this always runs on main>` (e.g. an observer registered with queue: .main)",
         "// main-proof: <why>",
         line_rule(r"\bMainActor\.assumeIsolated\b", "main-proof:")),
    Rule("unchecked-sendable", "`@unchecked Sendable` / `nonisolated(unsafe)` without a safety argument",
         "it switches off the data-race checker; without a written argument nobody can review it",
         "an actor, a Sendable value type, or CmuxNextCompat `Mutex` around the state; when it is truly safe, "
         "say why on the declaration: `// crash-allow: <the safety argument>` (crash_ratchet.py honors it too)",
         "// crash-allow: <the safety argument>",
         line_rule(r"@unchecked\s+Sendable\b|\bnonisolated\(unsafe\)", "crash-allow:")),
    Rule("sleep-poll", "A sleep inside a loop (polling)",
         "a sleep that waits for a condition wakes forever, adds up to one period of latency and hides the real signal",
         "await the event (AsyncStream, a continuation, observation); one deadline: DemandTimer; a retry after a "
         "failure: Backoff.wait",
         "// poll-allow: <why no event exists>",
         sleep_in_loop),
    Rule("main-async", "`DispatchQueue.main.async`",
         "an untyped hop that reorders work and hides isolation (CLAUDE.md forbids it in new code)",
         "annotate the destination `@MainActor` and `await` it, or hop once with `Task { @MainActor in ... }` "
         "owned by the caller",
         "// main-async-allow: <the API that forces a GCD hop>",
         line_rule(r"\bDispatchQueue\.main\.async\b|\bOperationQueue\.main\.addOperation\b", "main-async-allow:")),
    Rule("broadcast-name", "New `Notification.Name` (a broadcast signal)",
         "every observer wakes on every post: O(all) work per change (browserChildWindowPagesNeedUpdate makes "
         "every Chromium host re-post geometry on any layout change; perf-lead.md issue 2)",
         "tell the one object that changed (a method on its owner, a closure the owner holds, or an "
         "AsyncStream keyed by id)",
         "// broadcast-allow: <why every observer must hear every post>",
         line_rule(r"\b(NS)?Notification\.Name\(|:\s*(NS)?Notification\.Name\s*=", "broadcast-allow:")),
    Rule("combine-state", "`ObservableObject` / `@Published` / Combine state",
         "one change invalidates every observer view; CLAUDE.md requires Observation",
         "`@MainActor @Observable` models; views take `@State`, `@Bindable`, a plain `let` or "
         "`@Environment(Model.self)`",
         None,
         line_rule(r"\bObservableObject\b|@(Published|StateObject|ObservedObject|EnvironmentObject)\b"
                   r"|\.environmentObject\(|\b(PassthroughSubject|CurrentValueSubject)\b", None)),
    Rule("row-store", "A store reference stored in a list row view",
         "a row that holds a store re-renders on every change to it: N rows x every change (the 100 % CPU "
         "LazyLayoutViewCache loop, classic #2586)",
         "give the row an immutable value snapshot plus a closure action bundle; read the store above the "
         "ForEach",
         "// row-snapshot-allow: <why>",
         row_store),
    Rule("app-big-file", f"New CmuxNextApp file over {NEW_APP_FILE_MAX} lines",
         "the App target re-emits its whole module on every edit (check-app-size.sh) and CI refuses god files",
         "put the feature in its own target under Packages/macOS/CmuxNext/Sources, one type per file",
         None,
         big_new_app_file),
)


# ---------------------------------------------------------------- diff

def parse_diff(diff: str) -> dict[str, FileChange]:
    changes: dict[str, FileChange] = {}
    current: FileChange | None = None
    number, pending_new, old_path = 0, False, ""
    for line in diff.split("\n"):
        if line.startswith("diff --git"):
            current = None
        elif line.startswith("--- "):
            pending_new = line == "--- /dev/null"
            old_path = line[6:] if line.startswith("--- a/") else ""
        elif line.startswith("+++ "):
            # A deleted file keeps its old path: its removed lines still make a move elsewhere not new.
            path = line[6:] if line.startswith("+++ b/") else old_path
            current = changes.setdefault(path, FileChange(path, [])) if path else None
            if current is not None:
                current.is_new = pending_new
        elif line.startswith("@@") and current is not None:
            match = re.search(r"\+(\d+)(?:,(\d+))?", line)
            number = int(match.group(1)) if match else 0
            count = int(match.group(2)) if match and match.group(2) is not None else 1
            if count == 0:
                current.touched.add(max(number, 1))  # a pure deletion after line `number`
                current.touched.add(number + 1)
        elif current is not None and line.startswith("+"):
            current.added.append(Added(current.path, number, line[1:]))
            current.touched.add(number)
            number += 1
        elif current is not None and line.startswith("-"):
            current.removed.append(line[1:])
    return changes


def blobs(repo: Path, rev: str, paths: list[str]) -> dict[str, str]:
    """{path: text} at REV in one `git cat-file --batch` (a path missing at REV is left out)."""
    if not paths:
        return {}
    request = "".join(f"{rev}:{p}\n" for p in paths).encode()
    result = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=request, capture_output=True)
    out, cursor, found = result.stdout, 0, {}
    for path in paths:
        end = out.index(b"\n", cursor)
        header = out[cursor:end].split()
        cursor = end + 1
        if len(header) < 3 or header[1] != b"blob":
            continue
        size = int(header[2])
        found[path] = out[cursor:cursor + size].decode("utf-8", "replace")
        cursor += size + 1
    return found


def run_both(repo: Path, *commands: list[str]) -> list[str]:
    """Run git COMMANDS at once (each costs a process start on a busy Mac) and return their outputs."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    procs = [subprocess.Popen(["git", "-C", str(repo), *c], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
             for c in commands]
    return [p.communicate()[0].decode("utf-8", "replace") for p in procs]


# ---------------------------------------------------------------- warnings

def function_spans(lines: list[str]) -> list[tuple[int, int, str, str, str]]:
    """(first, last, declaration, budget, path-id) per `// perf-hot:` marked declaration (1-based, inclusive)."""
    spans = []
    for index, line in enumerate(lines):
        match = PERF_HOT.search(line)
        if not match:
            continue
        if COMMENT_LINE.match(line):  # the marker in the comment block above the declaration
            j = index + 1
            while j < len(lines) and (COMMENT_LINE.match(lines[j]) or ATTRIBUTE_LINE.match(lines[j]) or not lines[j].strip()):
                j += 1
        else:  # a trailing marker on the declaration line itself (adds no line to a capped file)
            j = index
        if j >= len(lines) or not DECL.search(code_of(lines[j])):
            continue
        depth, started, k = 0, False, j
        while k < len(lines):
            for c in code_of(lines[k]):
                if c == "{":
                    depth += 1
                    started = True
                elif c == "}":
                    depth -= 1
            if started and depth <= 0:
                break
            k += 1
        spans.append((j + 1, k + 1, code_of(lines[j]).strip(), match.group("budget"), match.group("path") or ""))
    return spans


def perf_hot_warnings(changes: dict[str, FileChange], benches: dict) -> list[str]:
    out = []
    paths = benches.get("paths", {})
    for path, change in sorted(changes.items()):
        if not path.endswith(".swift"):
            continue
        if not change.has_perf_hot:
            continue
        for first, last, decl, budget, hot in function_spans(change.head_lines):
            if not any(first <= n <= last for n in change.touched):
                continue
            entry = paths.get(hot, {})
            bench = entry.get("bench", "no bench mapped: add the path id to " + BENCHES)
            owner = f"; owner {entry['owner']}" if entry.get("owner") else ""
            out.append(f"{path}:{first}: changes perf-hot `{decl[:80]}` (budget {budget}, {hot or 'no path id'}"
                       f"{owner}). Run before and after on the fleet, light and STRESS: {bench}")
    for path, change in sorted(changes.items()):
        for removed in change.removed:
            if "perf-hot" in removed and PERF_HOT.search(removed):
                out.append(f"{path}: removes a perf-hot marker (`{removed.strip()[:80]}`): keep it unless the path "
                           "is no longer hot, and say why in the commit")
    return out


def parse_owners(text: str) -> list[tuple[str, list[str], str, str]]:
    """(area, path globs, owner, doc) from OWNERS.md's table (columns: Area | Paths | Owner | Read first)."""
    rows, header = [], None
    for line in text.splitlines():
        if not line.startswith("|"):
            header = None if not line.strip() else header
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = [c.lower() for c in cells]
            continue
        if set(line) <= set("|-: "):
            continue
        if "paths" not in header or len(cells) < len(header):
            continue
        row = dict(zip(header, cells))
        globs = re.findall(r"`([^`]+)`", row.get("paths", ""))
        cell = row.get("read first", "")
        link = re.search(r"\]\(([^)]+)\)", cell)
        if link:  # a Markdown link is relative to OWNERS.md
            target = link.group(1)
            doc_text = target if target.startswith(("http", "/")) else str(Path(OWNERS).parent / target)
        else:
            quoted = re.search(r"`([^`]+)`", cell)
            doc_text = cell.replace("`", "") if quoted else cell
        rows.append((row.get("area", "?"), globs, row.get("owner", "?"), doc_text))
    return rows


def glob_match(path: str, pattern: str) -> bool:
    if pattern.endswith("/"):
        return path.startswith(pattern)
    regex = re.escape(pattern).replace(r"\*\*", "\0").replace(r"\*", "[^/]*").replace("\0", ".*")
    return re.fullmatch(regex, path) is not None or fnmatch.fnmatch(path, pattern)


def owner_warnings(files: list[str], owners: list[tuple[str, list[str], str, str]]) -> list[str]:
    out = []
    for area, globs, owner, doc in owners:
        hit = [f for f in files if any(glob_match(f, g) for g in globs)]
        if hit:
            more = f" and {len(hit) - 1} more" if len(hit) > 1 else ""
            out.append(f"touches {area} ({hit[0]}{more}): owner {owner}. Read {doc} first; tell the owner what changed.")
    return out


def app_warnings(changes: dict[str, FileChange]) -> list[str]:
    added = sum(len(c.added) for p, c in changes.items() if p.startswith(APP))
    removed = sum(len(c.removed) for p, c in changes.items() if p.startswith(APP))
    new_files = sorted(p for p, c in changes.items() if p.startswith(APP) and c.is_new)
    out = []
    if new_files:
        out.append(f"adds {len(new_files)} file(s) to CmuxNextApp ({new_files[0]}...): new features get their own target "
                   "(plans/cmux-next/code-quality.md SW14); the App only shrinks")
    if added - removed > 0:
        out.append(f"grows CmuxNextApp by {added - removed} lines (CI's check-app-size.sh cap may refuse it)")
    return out


# ---------------------------------------------------------------- run

def check(repo: Path, base: str, head: str) -> tuple[list[tuple[Rule, list[Added]]], list[tuple[str, str]]]:
    """(refusals [(rule, hits)], warnings [(kind, text)]) for what HEAD adds over BASE."""
    diff, names = run_both(repo, ["diff", "-U0", "--no-color", "--no-renames", "--no-ext-diff", base, head, "--", SOURCES],
                           ["diff", "--name-only", "--no-renames", base, head])
    changes = parse_diff(diff)
    swift = {p: c for p, c in changes.items() if p.endswith(".swift")}
    texts = blobs(repo, head, sorted(swift) + [BENCHES, OWNERS])
    for path, change in swift.items():
        text = texts.get(path, "")
        change.head_lines = text.split("\n")
        change.has_perf_hot = "perf-hot:" in text
        change.has_row_struct = ROW_STRUCT.search(text) is not None
    moved = collections.Counter(r.strip() for c in changes.values() for r in c.removed if r.strip())
    refusals = []
    for rule in RULES:
        ctx = Context(moved.copy())  # each rule consumes its own moved lines
        hits = [h for change in swift.values() for h in rule.find(change, ctx)]
        if hits:
            refusals.append((rule, hits))
    warnings: list[tuple[str, str]] = []
    try:
        benches = json.loads(texts[BENCHES]) if BENCHES in texts else {}
    except json.JSONDecodeError:
        benches = {}
    warnings += [("perf-hot", w) for w in perf_hot_warnings(swift, benches)]
    if OWNERS in texts:
        files = [f for f in names.split("\n") if f]
        warnings += [("owner", w) for w in owner_warnings(files, parse_owners(texts[OWNERS]))]
    warnings += [("app-grow", w) for w in app_warnings(changes)]
    return refusals, warnings


def format_report(refusals, warnings) -> tuple[str, bool]:
    """The text to print and whether the push is refused."""
    lines = []
    if warnings:
        lines.append("guardrails: warnings (never refuse):")
        lines += [f"  [{kind}] {text}" for kind, text in warnings]
    if not refusals:
        return "\n".join(lines), False
    lines.append("guardrails: this push adds architecture debt (scripts/cmux-next/guardrails.py):")
    for rule, hits in refusals:
        lines.append(f"  [{rule.id}] {rule.title}")
        for hit in hits[:20]:
            lines.append(f"    {hit.path}:{hit.number}: {hit.text.strip()[:140]}")
        if len(hits) > 20:
            lines.append(f"    ... {len(hits) - 20} more")
        lines.append(f"    why: {rule.why}")
        lines.append(f"    do:  {rule.fix}")
        if rule.escape:
            lines.append(f"    reviewed escape: `{rule.escape}` (only when it is true)")
    skip = os.environ.get(SKIP_ENV, "").strip()
    if skip:
        lines.append(f"guardrails: SKIPPED by {SKIP_ENV}={skip!r}. Say so in your report.")
        return "\n".join(lines), False
    lines.append(f"Skip once (only with a real reason): {SKIP_ENV}=\"<rule>: <why>\" git push ...; "
                 "say it in your report. Debt counts: plans/cmux-next/codebase-health.md.")
    return "\n".join(lines), True


def default_base(repo: Path, head: str) -> str:
    base = git(repo, "merge-base", head, "origin/feat-cmux-next", check=False).strip()
    return base or f"{head}~1"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--list", action="store_true", help="print the rules")
    args = parser.parse_args(argv)
    if args.list:
        for rule in RULES:
            print(f"{rule.id}: {rule.title}\n  why: {rule.why}\n  do:  {rule.fix}\n  escape: {rule.escape or '-'}")
        return 0
    repo = Path(args.repo or git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    started = time.monotonic()
    refusals, warnings = check(repo, args.base or default_base(repo, args.head), args.head)
    text, refused = format_report(refusals, warnings)
    if text:
        print(text)
    print(f"guardrails: {'refused' if refused else 'ok'} ({time.monotonic() - started:.2f}s)")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
