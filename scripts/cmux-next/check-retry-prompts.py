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
    # Commands the person runs on purpose (the action catalog's "Reload Extension") and release notes that only
    # describe the app.
    r"|^cmux-tui/crates/cmux-action-catalog/|/action_catalog\.rs$|^webviews/src/pages/changelog/"
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
RUST_TEST_MOD = re.compile(r"^\s*#\[cfg\((?:all\()?test")


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
            if KEY_SHAPE.match(key) and isinstance(english, str) and RETRY_WORDS.search(english):
                keys.add(key)
    return keys


def strip_comments(source: str) -> str:
    source = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)
    return "\n".join(LINE_COMMENT.sub(lambda m: m.group(1), line) for line in source.split("\n"))


def is_prompt(text: str, keys: set[str]) -> bool:
    if KEY_SHAPE.match(text):
        return text in keys
    if NOT_COPY.search(text):
        return False
    return bool(RETRY_WORDS.search(text)) and bool(TEXT_SHAPE.search(text))


def sites_in(path: str, raw: str, keys: set[str]) -> tuple[list[Site], int]:
    """The unmarked prompts in one file, and how many marked ones it has."""
    raw_lines = raw.split("\n")
    if path.endswith(".rs"):
        for i, line in enumerate(raw_lines):
            if RUST_TEST_MOD.match(line):
                raw_lines = raw_lines[:i]
                break
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


def check(root: Path, *, list_all: bool = False, update: bool = False, seed: bool = False, out=sys.stdout) -> int:
    by_file, marked = scan(root)
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
        allowed = baseline.get(path, 0)
        if len(sites) > allowed:
            problems.append(
                f"{path}: {len(sites)} retry prompt(s), {allowed} allowed. Retry automatically (jittered backoff while "
                f"the view is shown, one quiet line after the shared bound) and fix the failure at its root; keep a "
                f"prompt only where retrying has a cost or side effect the person must choose, marked "
                f"`retry-prompt-ok: <reason>`:")
            problems += [f"    line {s.line}: {s.text!r}" for s in sites]
    notes: list[str] = []
    if not update:
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
    print(f"retry prompts: ok ({sum(map(len, by_file.values()))} baseline, {marked} marked with a reason)", file=out)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--list", action="store_true", help="print every unmarked prompt")
    group.add_argument("--update-baseline", action="store_true", help="lower rows to the tree's counts")
    group.add_argument("--seed-baseline", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if os.environ.get("CMUX_RETRY_PROMPTS_SEED") != "1" and args.seed_baseline:
        parser.error("--seed-baseline writes every count anew; set CMUX_RETRY_PROMPTS_SEED=1 to mean it")
    return check(args.root.resolve(), list_all=args.list, update=args.update_baseline, seed=args.seed_baseline)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
