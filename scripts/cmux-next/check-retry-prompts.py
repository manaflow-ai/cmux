#!/usr/bin/env python3
"""No vacuous retry prompts: the app retries on its own instead of asking the person to "Try again".

Leo, 2026-11-22, on "Couldn't read the held messages. Try again": "im sure there can be more graceful situations to
just have these go on automatically. i dont know what kind of decision a "try again" would be other than "ok i guess
ill click this." vacuous decisions like that should be just done and the underlying problems should be done better
at the root".

A retry prompt is text a person reads that asks them to try again, retry, reload or reconnect: a "Try again" or
"Retry" button, "Couldn't load X. Try again.", a CLI error ending "; try again". When the only sensible answer is
yes, the code retries by itself (jittered backoff while the view is shown, one quiet line after the shared bound in
schemas/notice-timing/notice-timing.json) and fixes the failure at its root. A real prompt stays only where retrying
has a cost or a side effect the person must choose (re-sending a paid request, re-running a command that changes
things, a sign-in code). Such a site says why in a `retry-prompt-ok: <reason>` comment on its line or within the
three lines above it.

What it reads: the cmux NEXT UI and CLI (SURFACES): web pages (webviews/src, .ts/.tsx), the Mac and iOS apps
(.swift) and the Rust crates (cmux-tui/crates, .rs). Tests, galleries, previews, fixtures and Rust `#[cfg(test)]`
modules are not read; nor are comments, log lines, or lowercase identifiers ("retry", "action.retry"). A dotted
string-table key (`t("project.retry")`) counts when its English value in a Localizable.xcstrings says one.

Sites from before the rule have a count per file in retry-prompts-baseline.tsv. A file fails with more unmarked
prompts than its row. One with fewer passes with a note asking to lower the row (`--update-baseline`): a fix that
landed without running this check must not turn the base red. `--update-baseline` never raises a row or adds a file.

    python3 scripts/cmux-next/check-retry-prompts.py                    # the working tree
    python3 scripts/cmux-next/check-retry-prompts.py --list             # every unmarked prompt
    python3 scripts/cmux-next/check-retry-prompts.py --update-baseline  # lower the rows of files that improved
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "scripts/cmux-next/retry-prompts-baseline.tsv"
BASELINE_HEADER = (
    "# check-retry-prompts.py baseline: path<TAB>unmarked retry prompts. Counts only go down: a change that removes a\n"
    "# prompt (an automatic retry, or a `retry-prompt-ok: <reason>` mark) lowers its row with --update-baseline.\n"
)

SURFACES = (
    "webviews/src/",
    "Packages/macOS/CmuxNext/",
    "Packages/Shared/",
    "Packages/iOS/",
    "cmux-next-ios/",
    "ios/",
    "cmux-tui/crates/",
)
SOURCE_SUFFIXES = (".ts", ".tsx", ".swift", ".rs")
STRING_TABLE = "Localizable.xcstrings"

# Not text a person sees: tests, galleries, previews, fixtures, mocks, benches, generated files, build scripts,
# and the executable chat-simulator scenarios in the one verified simulator tree. The simulator drives the real UI
# with synthetic records, so its strings are inputs to a test harness rather than shipped copy.
SKIP = re.compile(
    r"(^|/)(test|tests|\w*Tests|__tests__|testdata|fixtures|Fixtures|Preview Content|gallery|Gallery|prototypes?|"
    r"benches|examples|scripts|verify|stress)/"
    r"|\.(test|spec|gallery|stories|fixtures?|experiment|bench|generated)\.(ts|tsx|swift)$"
    r"|(Tests?|Previews?|Gallery\w*|Fixtures?|Mock\w*)\.swift$"
    r"|(^|/)(Mock|mock)\w*\.(ts|tsx|swift)$|[Ff]ixtures?\w*\.(ts|tsx|swift)$"
    r"|^webviews/src/agent-session/acpmux/sim/"
    # The sidebar gallery loads this module of synthetic session titles.
    r"|^webviews/src/sidebar/SidebarEdgeFadeDesigns\.tsx$"
    # Commands the person runs on purpose (the action catalog's "Reload Extension") and release notes that only
    # describe the app.
    r"|^cmux-tui/crates/cmux-action-catalog/|/action_catalog\.rs$|^webviews/src/pages/changelog/"
    r"|^cmux-tui/crates/acpmux-tui/src/actions/table\.rs$"
    r"|(^|/)(tests?|\w+_tests?|build)\.rs$"
)

# The words of a retry prompt. Not their progress forms ("Retrying…", "Reconnecting…": check-connection-notices.py
# owns states) and not the past ("Reloaded").
RETRY_WORDS = re.compile(
    r"(?i)\btry(?:ing)? (?:it |that |this )?again\b"
    # retry, reload and reconnect as something the person is told to do: a label's first word, or after a stop,
    # "then", "or", "and", "to" or "please" ("Retry", "Reload Page", "then retry the reset"); not a noun in a
    # setting's name ("hook retry max_attempts") or a log's ("reconnect checkpoint").
    r"|(?:^|[.;:!?\u2014(]\s*|\b(?:then|or|and|to|please)\s+)(?:re-?try|reload|reconnect)\b"
)
# Progress notices, diagnostic labels and configuration names use the same words. Remove only
# the descriptive phrase so that another sentence can still ask the person to retry.
RETRY_STATUS = re.compile(
    r"(?i)\b(?:will try (?:it |that |this )?again|backoff and retry limit)\b"
    r"|^retry sent[.!]?$|^reconnect(?:-failed:| \{attempt\}:| backoff$| deadline expired$)"
    r"|\b(?:retry|reconnect) failed(?=:|[.!]?$)|\breload-config(?= takes no arguments)"
    r"|\btrying again(?= \{next\}:)|^retry \{attempt\} of \{of\} waits out\b"
)


def has_prompt_words(text: str) -> bool:
    return bool(RETRY_WORDS.search(RETRY_STATUS.sub("", text)))


# A string literal that is copy: it starts with a capital or has a space.
TEXT_SHAPE = re.compile(r"^[\s“\"'(%\\]*[A-Z]|\s")
# A regular expression, a path or a URL, not copy.
NOT_COPY = re.compile(r"\(\?|\\b|\||^/|://|\{\{|<script")
# A dotted string-table key.
KEY_SHAPE = re.compile(r"^[A-Za-z0-9_]+(?:[.\-][A-Za-z0-9_]+)+$")
# Lines that are not text a person sees: logs, traces, assertions.
NOT_UI_LINE = re.compile(
    r"\b(log(?:ger)?\.\w+|Logger\b|os_log|NSLog|debugPrint|console\.\w+|signpost|breadcrumb|fatalError|"
    r"precondition\w*|assert\w*|tracing::|log::)"
    r"|\b(trace|debug|info|warn|error|event|span|debug_span|info_span)!\s*\("
)
MARK = re.compile(r"retry-prompt-ok:\s*\S")
MARK_REACH = 3  # lines above a site a mark may sit on

STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'|`((?:[^`\\]|\\.)*)`')
RUST_STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
JSX_TEXT = re.compile(r">\s*([^<>{}\n]*[A-Za-z][^<>{}\n]*)\s*<")
LINE_COMMENT = re.compile(r"(^|[^:\"'\\])//.*$")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
RUST_CFG = re.compile(r"^[ \t]*#\[cfg\(([^\]\n]*)\)\][ \t]*(?:\n|$)", re.MULTILINE)
RUST_TEST_CFG = re.compile(
    r"^[ \t]*#\[cfg\((?:test\b|all\(\s*test(?:\s*,|\s*\)))", re.MULTILINE
)


@dataclass(frozen=True)
class Site:
    path: str
    line: int
    text: str


def tracked(root: Path) -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *SURFACES],
                             check=True, capture_output=True).stdout.decode()
        names = [n for n in out.split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        names = []
    if not names:  # not a git tree (an exported copy): walk it
        names = [p.relative_to(root).as_posix() for pre in SURFACES if (root / pre).is_dir()
                 for p in (root / pre).rglob("*") if p.is_file()]
    return sorted(n for n in names if (root / n).is_file())


def retry_keys(root: Path, files: list[str]) -> set[str]:
    """Every string-table key whose English value asks for a retry."""
    keys: set[str] = set()
    for path in files:
        if not path.endswith(STRING_TABLE):
            continue
        try:
            strings = json.loads((root / path).read_text(encoding="utf-8")).get("strings", {})
        except (OSError, ValueError, AttributeError):
            continue
        for key, entry in strings.items():
            try:
                english = entry["localizations"]["en"]["stringUnit"]["value"]
            except (KeyError, TypeError):
                english = key
            if KEY_SHAPE.match(key) and isinstance(english, str) and has_prompt_words(english):
                keys.add(key)
    return keys


def strip_comments(source: str) -> str:
    source = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)
    return "\n".join(LINE_COMMENT.sub(lambda m: m.group(1), line) for line in source.split("\n"))


def rust_code_mask(source: str) -> str:
    """Blank Rust comments and literals while preserving newlines and structural braces."""
    masked = list(source)
    length = len(source)

    def blank(start: int, end: int) -> None:
        for index in range(start, end):
            if source[index] != "\n":
                masked[index] = " "

    def quoted_end(start: int, quote: str) -> int:
        index = start + 1
        while index < length:
            if source[index] == "\\":
                index += 2
            elif source[index] == quote:
                return index + 1
            else:
                index += 1
        return length

    def char_end(start: int) -> int | None:
        if start >= length or source[start] != "'" or start + 2 >= length:
            return None
        index = start + 1
        if source[index] == "\\":
            index += 1
            if index < length and source[index] == "u" and index + 1 < length and source[index + 1] == "{":
                close = source.find("}", index + 2)
                if close < 0:
                    return None
                index = close + 1
            else:
                index += 1
        else:
            index += 1
        return index + 1 if index < length and source[index] == "'" else None

    index = 0
    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end < 0 else end
            blank(index, end)
            index = end
            continue
        if source.startswith("/*", index):
            end, depth = index + 2, 1
            while end < length and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            blank(index, end)
            index = end
            continue
        raw_start = index
        if source.startswith("br", index) or source.startswith("r", index):
            if source.startswith("br", index):
                raw_start, quote = index, index + 2
            else:
                raw_start, quote = index, index + 1
            hashes = 0
            while quote + hashes < length and source[quote + hashes] == "#":
                hashes += 1
            if quote + hashes < length and source[quote + hashes] == '"':
                close = '"' + ("#" * hashes)
                end = source.find(close, quote + hashes + 1)
                end = length if end < 0 else end + len(close)
                blank(raw_start, end)
                index = end
                continue
        if source[index] == "\"" or (source[index] == "b" and index + 1 < length and source[index + 1] == '"'):
            start = index
            if source[index] == "b":
                index += 1
            end = quoted_end(index, '"')
            blank(start, end)
            index = end
            continue
        if source[index] == "'" or (source[index] == "b" and index + 1 < length and source[index + 1] == "'"):
            start = index
            if source[index] == "b":
                index += 1
            end = char_end(index)
            if end is not None:
                blank(start, end)
                index = end
                continue
        index += 1
    return "".join(masked)


def rust_without_test_items(source: str) -> str:
    """Blank each `#[cfg(test)]` item, leaving later production items visible."""
    if not RUST_TEST_CFG.search(source):
        return source
    masked = rust_code_mask(source)
    spans: list[tuple[int, int]] = []
    position = 0
    while True:
        match = RUST_CFG.search(masked, position)
        if match is None:
            break
        condition = match.group(1).strip()
        is_test = condition == "test"
        if condition.startswith("all(") and condition.endswith(")"):
            is_test = condition[4:-1].split(",", 1)[0].strip() == "test"
        if not is_test:
            position = match.end()
            continue
        start = match.start()
        item_start = match.end()
        while item_start < len(masked) and masked[item_start].isspace():
            item_start += 1
        while masked.startswith("#[", item_start):
            depth, cursor = 1, item_start + 2
            while cursor < len(masked) and depth:
                if masked[cursor] == "[":
                    depth += 1
                elif masked[cursor] == "]":
                    depth -= 1
                cursor += 1
            if depth:
                item_start = len(masked)
                break
            item_start = cursor
            while item_start < len(masked) and masked[item_start].isspace():
                item_start += 1
        end_marker = item_start
        while end_marker < len(masked) and masked[end_marker] not in "{;":
            end_marker += 1
        if end_marker >= len(masked):
            end = len(masked)
        elif masked[end_marker] == ";":
            end = end_marker + 1
        else:
            stack = ["}"]
            cursor = end_marker + 1
            while cursor < len(masked) and stack:
                char = masked[cursor]
                if char == "{":
                    stack.append("}")
                elif char == stack[-1]:
                    stack.pop()
                cursor += 1
            end = cursor
        spans.append((start, end))
        position = end
    if not spans:
        return source
    chunks: list[str] = []
    cursor = 0
    for start, end in spans:
        chunks.append(source[cursor:start])
        chunks.append("".join("\n" if char == "\n" else " " for char in source[start:end]))
        cursor = end
    chunks.append(source[cursor:])
    return "".join(chunks)


def is_prompt(text: str, keys: set[str]) -> bool:
    if KEY_SHAPE.match(text):
        return text in keys
    if NOT_COPY.search(text):
        return False
    return has_prompt_words(text) and bool(TEXT_SHAPE.search(text))


def sites_in(path: str, raw: str, keys: set[str]) -> tuple[list[Site], int]:
    """The unmarked prompts in one file, and how many marked ones it has."""
    raw_lines = raw.split("\n")
    if path.endswith(".rs"):
        raw_lines = rust_without_test_items(raw).split("\n")
    lines = strip_comments("\n".join(raw_lines)).split("\n")
    unmarked: list[Site] = []
    marked = 0
    for i, line in enumerate(lines):
        if NOT_UI_LINE.search(line):
            continue
        if path.endswith(".rs"):
            said = [m.group(1) for m in RUST_STRING.finditer(line)]
        else:
            said = [g for m in STRING_LITERAL.finditer(line) for g in m.groups() if g is not None]
            if path.endswith(".tsx"):
                said += [m.group(1).strip() for m in JSX_TEXT.finditer(line)]
        hit = next((s for s in said if is_prompt(s, keys)), None)
        if hit is None:
            continue
        if any(MARK.search(raw_lines[j]) for j in range(max(0, i - MARK_REACH), i + 1)):
            marked += 1
        else:
            unmarked.append(Site(path, i + 1, hit))
    return unmarked, marked


def scan(root: Path) -> tuple[dict[str, list[Site]], int]:
    files = tracked(root)
    keys = retry_keys(root, files)
    by_file: dict[str, list[Site]] = {}
    marked = 0
    for path in files:
        if not path.endswith(SOURCE_SUFFIXES) or SKIP.search(path):
            continue
        found, kept = sites_in(path, (root / path).read_text(encoding="utf-8", errors="replace"), keys)
        marked += kept
        if found:
            by_file[path] = found
    return by_file, marked


def read_baseline(path: Path) -> dict[str, int]:
    rows: dict[str, int] = {}
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        name, _, count = line.partition("\t")
        rows[name] = int(count)
    return rows


def write_baseline(path: Path, rows: dict[str, int]) -> None:
    body = "".join(f"{name}\t{count}\n" for name, count in sorted(rows.items()) if count > 0)
    path.write_text(BASELINE_HEADER + body, encoding="utf-8")


def changed_lines(root: Path, revision: str) -> dict[str, set[int]]:
    """Added lines per file, using NUL-delimited names for unusual Git paths."""
    git = ["git", "-C", str(root), "diff", "--no-ext-diff", "--no-color", "--no-renames"]
    paths = subprocess.check_output([*git, "--name-only", "-z", "--diff-filter=AM",
                                     revision, "--", *SURFACES])
    result: dict[str, set[int]] = {}
    for path in (os.fsdecode(name) for name in paths.split(b"\0") if name):
        if not path.endswith(SOURCE_SUFFIXES) or SKIP.search(path):
            continue
        patch = subprocess.check_output([*git, "--unified=0", revision, "--", path])
        lines = set()
        for match in re.finditer(rb"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", patch, re.M):
            start = int(match[1])
            lines.update(range(start, start + int(match[2] or 1)))
        result[path] = lines
    return result


def check(root: Path, *, list_all: bool = False, update: bool = False, seed: bool = False,
          changed_from: str | None = None, out=sys.stdout) -> int:
    by_file, marked = scan(root)
    added = changed_lines(root, changed_from) if changed_from else None
    baseline_path = root / BASELINE
    baseline = read_baseline(baseline_path)
    if list_all:
        for sites in by_file.values():
            for s in sites:
                print(f"{s.path}:{s.line}: {s.text!r}", file=out)
        print(f"retry prompts: {sum(map(len, by_file.values()))} unmarked in {len(by_file)} files, {marked} marked",
              file=out)
        return 0
    if seed:
        write_baseline(baseline_path, {p: len(s) for p, s in by_file.items()})
        print(f"retry prompts: wrote {BASELINE} ({len(by_file)} files)", file=out)
        return 0
    if update:
        rows = {p: min(c, len(by_file.get(p, []))) for p, c in baseline.items()}
        write_baseline(baseline_path, rows)
        print(f"retry prompts: lowered {BASELINE} to the tree's counts", file=out)
    problems: list[str] = []
    for path, sites in sorted(by_file.items()):
        if added is not None:
            sites = [site for site in sites if site.line in added.get(path, set())]
        allowed = baseline.get(path, 0) if added is None else 0
        if len(sites) > allowed:
            problems.append(
                f"{path}: {len(sites)} retry prompt(s), {allowed} allowed. Retry automatically (jittered backoff while "
                f"the view is shown, one quiet line after the shared bound) and fix the failure at its root; keep a "
                f"prompt only where retrying has a cost or side effect the person must choose, marked "
                f"`retry-prompt-ok: <reason>`:")
            problems += [f"    line {s.line}: {s.text!r}" for s in sites]
    notes: list[str] = []
    if not update and added is None:
        for path, allowed in sorted(baseline.items()):
            now = len(by_file.get(path, []))
            if now < allowed:
                notes.append(f"{path}: {now} retry prompt(s), its row says {allowed}; lower it: "
                                f"python3 {BASELINE.replace('retry-prompts-baseline.tsv', 'check-retry-prompts.py')} "
                                f"--update-baseline")
    for note in notes:
        print(f"note: {note}", file=out)
    if problems:
        print("retry prompts (Leo 2026-11-22: \"vacuous decisions like that should be just done\"):", file=out)
        for p in problems:
            print(p, file=out)
        return 1
    count = sum(len(sites) for sites in by_file.values()) if added is None else sum(
        1 for path, sites in by_file.items() for site in sites if site.line in added.get(path, set()))
    print(f"retry prompts: ok ({count} baseline, {marked} marked with a reason)", file=out)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--list", action="store_true", help="print every unmarked prompt")
    group.add_argument("--update-baseline", action="store_true", help="lower rows to the tree's counts")
    group.add_argument("--changed-from", metavar="REVISION",
                       help="check only newly added prompt lines against REVISION")
    group.add_argument("--seed-baseline", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if os.environ.get("CMUX_RETRY_PROMPTS_SEED") != "1" and args.seed_baseline:
        parser.error("--seed-baseline writes every count anew; set CMUX_RETRY_PROMPTS_SEED=1 to mean it")
    return check(args.root.resolve(), list_all=args.list, update=args.update_baseline,
                 seed=args.seed_baseline, changed_from=args.changed_from)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
