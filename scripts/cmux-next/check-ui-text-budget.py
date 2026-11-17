#!/usr/bin/env python3
"""UI text says only what the person can act on (Leo, 2026-11-16: "this needs to shut up / most of our s***
probably needs to shut up / and stop writing so much s***").

Every visible string has a word budget by the kind of place it is drawn. The check reads every string table
(`*.xcstrings`, English value, else the key) under the roots below and the settings schema
(`schemas/settings/source/*.json`: a row's `summary` is drawn on every row, its `help` only feeds Settings search),
names each string's kind from its key, and fails a string over its kind's budget.

Strings over budget when the check landed are rows of `scripts/cmux-next/ui-text-budget-allowlist.tsv`
(path, key, words, budget). The list only shrinks:
  - a string over budget with no row fails: cut it (delete it, or shorten it); never add a row;
  - a row whose string grew past its row's count fails;
  - a stale row (the string is gone, within budget or shorter than its row) fails; the fix is
    `--write-allowlist`, which only drops rows or lowers their counts;
  - a row whose table git tracks but the checkout lacks (a sparse checkout) exits 2 before judging or writing:
    read as gone, `--write-allowlist` would drop rows CI still needs;
  - with `--base REF` (CI passes the pull request's base) a row the base lacks, or a row whose count is higher
    than the base's, fails. A `--base` git cannot resolve exits 2.

  python3 scripts/cmux-next/check-ui-text-budget.py [--base REF] [--write-allowlist] [--report] [ROOT]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

# The budgets, in words, by kind. Tune here, with evidence (the counts `--report` prints).
#   kind        budget  key words that name it (the key's last segment, read from its end)
BUDGETS: dict[str, int] = {
    "label": 6,  # title label name button placeholder action cta heading
    "status": 12,  # status toast banner badge line state, and state words: running done offline busy ...
    "error": 20,  # error failed refused unavailable timedOut invalid conflict: the cause and the one next step
    "cli": 30,  # a CLI or socket refusal (a `cli` segment, or a `handlers.` / `control.` key): cause, then next step
    "empty": 10,  # empty none nothing
    "summary": 10,  # a settings row's `summary` (drawn on every row)
    "hint": 25,  # hint subtitle detail body message description lead intro help tooltip caption footer note
    "dialog": 40,  # a hint-kind string under a dialog, alert, confirm or sheet key
    "search-help": 60,  # a settings row's `help` (Settings search and the schema export only)
    "text": 25,  # a key that names no kind (an English sentence used as its own key)
}

KIND_WORDS: dict[str, str] = {}
for _kind, _words in {
    "label": "title label name button placeholder action cta heading",
    "status": "status toast banner badge line state running done offline online busy connecting reconnecting "
              "connected disconnected waiting loading pending ready idle stopped paused queued success succeeded",
    "error": "error errors failed failure refused refusal unavailable timedout invalid conflict conflicts",
    "empty": "empty none nothing",
    "hint": "hint subtitle detail details body message description lead intro help tooltip caption footer note "
            "summary explanation info",
}.items():
    for _word in _words.split():
        KIND_WORDS[_word] = _kind
DIALOG_WORDS = {"dialog", "alert", "confirm", "confirmation", "sheet"}
# A label word after one of these names a state, not a label ("copyName.noName", "laneNeedsName").
NOT_LABEL_WORDS = {"no", "needs", "missing", "removed", "gone", "required", "unknown", "not"}
CLI_FIRST_SEGMENTS = {"handlers", "control", "cli"}

TABLE_ROOTS = ("webviews/src", "Packages/macOS/CmuxNext", "Packages/iOS", "Packages/Shared", "cmux-next-ios")
SKIP_DIRS = {"node_modules", ".build", "build", "DerivedData", ".git"}
SCHEMA_GLOB = "schemas/settings/source/*.json"
SCHEMA_FIELDS = {"summary": "summary", "help": "search-help"}
ALLOWLIST = "scripts/cmux-next/ui-text-budget-allowlist.tsv"
HEADER = ("# Strings over their word budget (scripts/cmux-next/check-ui-text-budget.py). The list only shrinks:\n"
          "# cut a string and run the check with --write-allowlist; never add a row.\n"
          "# path\tkey\twords\tbudget\n")
LEO = "(Leo: say only what the person can act on)"

WORD = re.compile(r"[A-Za-z0-9'\u2019]+")
# printf specifiers (%@, %lld, %1$@) and {named} placeholders: one word each.
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaAi]|\{[^{}]*\}")
CAMEL = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+")


@dataclass(frozen=True)
class Text:
    path: str
    key: str
    value: str
    kind: str

    @property
    def words(self) -> int:
        return count_words(self.value)

    @property
    def budget(self) -> int:
        return BUDGETS[self.kind]


def count_words(value: str) -> int:
    return len(WORD.findall(PLACEHOLDER.sub(" X ", value)))


def key_tokens(segment: str) -> list[str]:
    return [token.lower() for token in CAMEL.findall(segment)]


def kind_of(key: str) -> str:
    """The kind a key names: its last segment's words read from the end, then earlier segments'."""
    if not key or re.search(r"\s", key) or not re.fullmatch(r"[A-Za-z0-9_.\-]+", key):
        return "text"
    segments = [s for s in re.split(r"[._\-]", key) if s]
    tokens_by_segment = [key_tokens(s) for s in segments]
    if segments[0].lower() in CLI_FIRST_SEGMENTS or any(s.lower() == "cli" for s in segments):
        return "cli"
    found = None
    for tokens in reversed(tokens_by_segment):
        joined = [a + b for a, b in zip(tokens, tokens[1:])]
        for token in reversed(joined + tokens):
            if token in KIND_WORDS:
                found = KIND_WORDS[token]
                break
        if found:
            break
    if found is None:
        return "text"
    if found == "label" and NOT_LABEL_WORDS & set(tokens_by_segment[-1]):
        return "status"
    if found in ("hint", "text") and any(t in DIALOG_WORDS for tokens in tokens_by_segment for t in tokens):
        return "dialog"
    return found


def english(entry: object, key: str) -> str:
    """A table entry's English: its stringUnit, else its plural `other` variation, else the key."""
    loc = ((entry or {}).get("localizations") or {}).get("en") if isinstance(entry, dict) else None
    if isinstance(loc, dict):
        unit = loc.get("stringUnit")
        if isinstance(unit, dict) and isinstance(unit.get("value"), str):
            return unit["value"]
        plural = ((loc.get("variations") or {}).get("plural") or {})
        for form in ("other", "one"):
            unit = (plural.get(form) or {}).get("stringUnit") or {}
            if isinstance(unit.get("value"), str):
                return unit["value"]
    return key


def tables(root: str) -> list[str]:
    found = []
    for top in TABLE_ROOTS:
        base = os.path.join(root, top)
        for directory, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            found += [os.path.join(directory, f) for f in files if f.endswith(".xcstrings")]
    return sorted(found)


def schema_texts(root: str) -> tuple[list[Text], set[str]]:
    """Settings rows' `summary` and `help`, and every string key the schema owns (its tables copy them)."""
    texts: list[Text] = []
    owned: set[str] = set()
    for path in sorted(glob.glob(os.path.join(root, SCHEMA_GLOB))):
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)

        def walk(node: object) -> None:
            if isinstance(node, dict):
                for field, value in node.items():
                    if isinstance(value, dict) and isinstance(value.get("key"), str) and isinstance(value.get("text"), str):
                        owned.add(value["key"])
                        if field in SCHEMA_FIELDS:
                            texts.append(Text(rel, value["key"], value["text"], SCHEMA_FIELDS[field]))
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(data)
    return texts, owned


def collect(root: str) -> list[Text]:
    texts, owned = schema_texts(root)
    for path in tables(root):
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for key, entry in (data.get("strings") or {}).items():
            if key in owned:
                continue
            texts.append(Text(rel, key, english(entry, key), kind_of(key)))
    return texts


def escape(field: str) -> str:
    return field.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def unescape(field: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"t": "\t", "n": "\n", "r": "\r"}.get(m.group(1), m.group(1)), field)


Row = tuple[str, str]


def parse_rows(text: str, source: str) -> tuple[dict[Row, tuple[int, int]], list[str]]:
    rows: dict[Row, tuple[int, int]] = {}
    problems: list[str] = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 4 or not parts[2].isdigit() or not parts[3].isdigit():
            problems.append(f"{source}:{number}: a row is path, key, words, budget (tab-separated)")
            continue
        row = (unescape(parts[0]), unescape(parts[1]))
        if row in rows:
            problems.append(f"{source}:{number}: duplicate row for {row[0]}: {row[1]}")
        rows[row] = (int(parts[2]), int(parts[3]))
    return rows, problems


def render_rows(rows: dict[Row, tuple[int, int]]) -> str:
    body = "".join(f"{escape(p)}\t{escape(k)}\t{w}\t{b}\n" for (p, k), (w, b) in sorted(rows.items()))
    return HEADER + body


def git(root: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)


def not_checked_out(root: str, rows: dict[Row, tuple[int, int]]) -> list[str]:
    """Row paths git tracks that are missing on disk (a sparse checkout). Their strings would read as gone, and
    `--write-allowlist` would drop rows CI still needs, so the check refuses to judge them."""
    paths = sorted({path for path, _ in rows if not os.path.exists(os.path.join(root, path))})
    if not paths:
        return []
    listed = git(root, "ls-files", "--", *paths)
    return [path for path in listed.stdout.splitlines() if path] if listed.returncode == 0 else []


def base_rows(root: str, base: str) -> dict[Row, tuple[int, int]] | None:
    """The list at `base`; None when the base has no list (the change that adds it). Raises on a bad ref."""
    if git(root, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}").returncode != 0:
        raise LookupError(base)
    shown = git(root, "show", f"{base}:{ALLOWLIST}")
    if shown.returncode != 0:
        return None
    return parse_rows(shown.stdout, f"{base}:{ALLOWLIST}")[0]


def judge(texts: list[Text], rows: dict[Row, tuple[int, int]],
          base: dict[Row, tuple[int, int]] | None) -> list[str]:
    failures: list[str] = []
    current: dict[Row, Text] = {}
    for text in texts:
        current.setdefault((text.path, text.key), text)
    for row, text in sorted(current.items()):
        words = text.words
        if words <= text.budget:
            continue
        listed = rows.get(row)
        message = f"{text.path}: {text.key}: {words} words, budget {text.budget} for {text.kind} {LEO}"
        if listed is None:
            failures.append(message)
        elif words > listed[0]:
            failures.append(f"{message}; it grew past its allowlist row ({listed[0]}): cut it back")
    for row, (words, budget) in sorted(rows.items()):
        text = current.get(row)
        now = text.words if text else None
        if text is None:
            why = "the string is gone"
        elif now <= text.budget:
            why = f"it is {now} words, within budget {text.budget}"
        elif now < words or budget != text.budget:
            why = f"it is {now} words, budget {text.budget} (row says {words}, {budget})"
        else:
            why = None
        if why:
            failures.append(f"{ALLOWLIST}: stale row {row[0]}: {row[1]}: {why}; "
                            f"fix: python3 scripts/cmux-next/check-ui-text-budget.py --write-allowlist")
    if base is not None:
        for row, (words, _) in sorted(rows.items()):
            before = base.get(row)
            if before is None:
                failures.append(f"{ALLOWLIST}: new row {row[0]}: {row[1]}: the list only shrinks; cut the string "
                                f"instead {LEO}")
            elif words > before[0]:
                failures.append(f"{ALLOWLIST}: row {row[0]}: {row[1]} grew from {before[0]} to {words} words: the "
                                f"list only shrinks; cut the string instead {LEO}")
    return failures


def shrunk(texts: list[Text], rows: dict[Row, tuple[int, int]]) -> dict[Row, tuple[int, int]]:
    """Rows still over budget, each at most its current count; never a new row, never a higher count."""
    current = {(t.path, t.key): t for t in texts}
    kept: dict[Row, tuple[int, int]] = {}
    for row, (words, budget) in rows.items():
        text = current.get(row)
        if text is None or text.words <= text.budget:
            continue
        kept[row] = (min(words, text.words), text.budget)
    return kept


def seeded(texts: list[Text]) -> dict[Row, tuple[int, int]]:
    return {(t.path, t.key): (t.words, t.budget) for t in texts if t.words > t.budget}


def report(texts: list[Text]) -> None:
    by_kind: dict[str, list[int]] = {}
    for text in texts:
        by_kind.setdefault(text.kind, []).append(text.words)
    print(f"{len({t.path for t in texts})} files, {len(texts)} strings, {sum(t.words for t in texts)} words")
    for kind, counts in sorted(by_kind.items()):
        counts.sort()
        over = sum(1 for c in counts if c > BUDGETS[kind])
        p90 = counts[int(len(counts) * 0.9)] if counts else 0
        print(f"  {kind:12} budget {BUDGETS[kind]:3}  strings {len(counts):6}  p90 {p90:3}  max {counts[-1]:4}  "
              f"over {over}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--base", help="the revision this change is judged against (CI: the pull request's base)")
    parser.add_argument("--write-allowlist", action="store_true",
                        help="drop stale rows and lower counts to the strings' current words; adds no row")
    parser.add_argument("--seed-allowlist", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--report", action="store_true", help="print strings and over-budget counts per kind")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    texts = collect(root)
    if args.report:
        report(texts)
        return 0
    list_path = os.path.join(root, ALLOWLIST)
    text = open(list_path, encoding="utf-8").read() if os.path.exists(list_path) else ""
    rows, problems = parse_rows(text, ALLOWLIST)
    missing = not_checked_out(root, rows)
    if missing:
        for path in missing:
            print(f"check-ui-text-budget: {path} is tracked but not checked out (a sparse checkout); its rows "
                  f"cannot be judged. next: git sparse-checkout add /{path}", file=sys.stderr)
        return 2
    if args.seed_allowlist or args.write_allowlist:
        new = seeded(texts) if args.seed_allowlist else shrunk(texts, rows)
        with open(list_path, "w", encoding="utf-8") as handle:
            handle.write(render_rows(new))
        print(f"{ALLOWLIST}: {len(rows)} -> {len(new)} rows")
        return 0
    base = None
    if args.base:
        try:
            base = base_rows(root, args.base)
        except LookupError:
            print(f"check-ui-text-budget: --base {args.base} does not resolve to a commit; fetch it or pass a "
                  f"reachable revision", file=sys.stderr)
            return 2
    failures = problems + judge(texts, rows, base)
    for failure in failures:
        print(failure)
    if failures:
        print(f"{len(failures)} UI text budget failure(s). Cut the text (delete the string and its use, or "
              f"shorten it); budgets are the table at the top of scripts/cmux-next/check-ui-text-budget.py.")
        return 1
    over = sum(1 for t in texts if t.words > t.budget)
    print(f"UI text budget: {len(texts)} strings, {over} over budget, all listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
