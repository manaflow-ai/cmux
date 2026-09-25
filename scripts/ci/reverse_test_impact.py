#!/usr/bin/env python3
"""Which cmuxTests/ suites can observe a diff to app code. Report only.

test_impact.py walks a cmuxTests/ diff forward to the suites it edits. A pull
request that changes only Sources/ selects nothing there, so today it runs no
app-host behavior test at all. This walks the other way: each changed app
declaration is named, the name is searched for in cmuxTests/, a referencing
line inside a helper continues the trail through the helper's own name (as in
test_impact.py), and a referencing line inside a suite selects that suite.

Tests that drive the CLI binary or the socket never name the Swift code they
exercise; they assert on its text. So a string literal the diff adds or
removes, in app code or in CLI/, is searched for too, and a suite that spells
it out is selected the same way.

A name that says nothing specific is dropped rather than followed: Swift and
Foundation vocabulary (`init`, `name`, `update`), a name more than HOT_TEST_FILES
test files mention, or a name several app files declare that the test does not
qualify by its owner type. The report records each one and why.

The selection is costed from the measured timings choose_ci_suite.py already
uses, compared with CHANGED_SUITES_BUDGET_MS, and when it does not fit, the
most specific names are kept greedily until the budget is spent.

Nothing reads this report to route a run. ci.yml records it in the step
summary and as an artifact, so its recall can be measured against the suites
that later fail on main before anything depends on it.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from choose_ci_suite import CHANGED_SUITES_BUDGET_MS  # noqa: E402
from cmux_unit_test_shard import (  # noqa: E402
    DEFAULT_TIMINGS_PATH,
    FALLBACK_TEST_MS,
    discover_selectors,
    load_timings,
    reweight_selectors,
)
from test_impact import IDENTIFIER_RE, TOP_LEVEL_RE, changed_lines, enclosing, outline  # noqa: E402

SCHEMA = 1
APP_PREFIX = "Sources/"
PACKAGE_SOURCES_RE = re.compile(r"^Packages/(?:macOS|Shared)/[^/]+/Sources/")
# The trees a selection reads: the app, the packages it links, and the tests.
TREE_PREFIXES = ("Sources", "Packages/macOS", "Packages/Shared", "cmuxTests")

# A changed name more test files mention than this is "hot": searching it
# selects much of the suite without telling which part the change reaches.
HOT_TEST_FILES = 40
# The same cap for a helper's name further along the trail.
HOT_HELPER_TEST_FILES = 25
# A name declared in this many app files (delay, tokens, isLocal) says little
# on its own, so a test that names it must also name the owner type.
AMBIGUOUS_APP_DECLARATIONS = 3
# Swift and Foundation vocabulary that appears across hundreds of test files
# whichever type declares it.
GENERIC_NAMES = frozenset({
    "init", "body", "id", "name", "title", "value", "description", "path", "url",
    "state", "count", "isEmpty", "update", "start", "stop", "run", "reset", "close",
    "open", "make", "load", "save", "apply", "handle", "text", "data", "string",
    "type", "kind", "key", "index", "items", "view", "window", "error", "result",
    "shared", "default", "none", "some", "configuration", "config", "status",
    "identifier", "label", "message", "request", "response", "command", "options",
    "cancel", "send", "remove", "add", "insert", "contains", "isEnabled", "enabled",
    "hash", "encode", "decode", "CodingKeys", "rawValue", "Element", "Key", "Value",
})
APP_DECLARATION_RE = re.compile(
    r"\b(?:func|var|let|case|class|struct|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


# Changed string literals shorter than this ("ok", "--json") match too much.
MIN_LITERAL_CHARS = 8
STRING_LITERAL_RE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# `\(value)` inside a literal; the text on either side is what a test sees.
INTERPOLATION_RE = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def is_literal_source(path: str) -> bool:
    """Swift whose string literals a cmuxTests/ suite can observe: app code, and CLI/."""
    return path.endswith(".swift") and (is_app_path(path) or path.startswith("CLI/"))


def literal_pieces(text: str) -> set[str]:
    """The distinctive text of the string literals on one line of Swift."""
    if text.lstrip().startswith("//"):
        return set()
    pieces: set[str] = set()
    for match in STRING_LITERAL_RE.finditer(text):
        for piece in INTERPOLATION_RE.split(match.group(1)):
            # Kept as written: a Swift test spells it with the same escapes.
            piece = piece.strip()
            if len(piece) >= MIN_LITERAL_CHARS and re.search(r"[A-Za-z]{3}", piece):
                pieces.add(piece)
    return pieces


def changed_literals(diff: str) -> dict[str, set[str]]:
    """Per file, the literals only one side of the diff has.

    A literal on both a removed and an added line only moved or was
    reformatted; one on a single side is text a test may still expect.
    """
    removed: dict[str, set[str]] = {}
    added: dict[str, set[str]] = {}
    old: str | None = None
    new: str | None = None
    for line in diff.splitlines():
        if line.startswith("--- "):
            old = line[6:] if line.startswith("--- a/") else None
            continue
        if line.startswith("+++ "):
            new = line[6:] if line.startswith("+++ b/") else None
            continue
        if line.startswith("-") and old is not None:
            removed.setdefault(old, set()).update(literal_pieces(line[1:]))
        elif line.startswith("+") and new is not None:
            added.setdefault(new, set()).update(literal_pieces(line[1:]))
    changed: dict[str, set[str]] = {}
    for path in set(removed) | set(added):
        literals = removed.get(path, set()) ^ added.get(path, set())
        if literals and is_literal_source(path):
            changed[path] = literals
    return changed


def is_app_path(path: str) -> bool:
    """App code a cmuxTests/ suite can observe: Sources/ and the macOS/Shared packages."""
    return path.startswith(APP_PREFIX) or PACKAGE_SOURCES_RE.match(path) is not None


@dataclass(frozen=True)
class Seed:
    """A changed app declaration, as a test would have to spell it."""

    name: str
    owner: str | None
    how: str


@dataclass
class Selection:
    # Set when the diff could not be judged; the caller treats that as
    # "no opinion", never as "nothing to run".
    fallback: str | None = None
    app_files: list[str] = field(default_factory=list)
    nonswift_app_files: list[str] = field(default_factory=list)
    untraceable: list[str] = field(default_factory=list)
    # Seed -> (suites, test files) it reaches.
    reached: dict[Seed, tuple[set[str], set[str]]] = field(default_factory=dict)
    # (seed, reason) for each name dropped before or during the search.
    dropped: list[tuple[Seed, str]] = field(default_factory=list)

    @property
    def suites(self) -> set[str]:
        return set().union(*(suites for suites, _ in self.reached.values()))


def changed_seeds(path: str, lines: list[str], changed: set[int]) -> tuple[list[Seed], list[str]]:
    """The names a test would use to reach the declarations `changed` sits in.

    A private member is reachable only through the visible members of the same
    file that call it, so the trail continues from those callers instead
    (two passes, for a private helper of a private helper).
    """
    seeds: list[Seed] = []
    untraceable: list[str] = []
    file_outline = outline(lines)
    private: set[str] = set()

    def header(top) -> tuple[str, str]:
        match = TOP_LEVEL_RE.match(lines[top.start - 1])
        return (match.group(2), match.group(3)) if match else ("", "")

    for number in sorted(changed):
        if not 1 <= number <= len(lines):
            continue
        top, member = enclosing(file_outline, number)
        if top is None:
            continue  # imports, file header
        kind, type_name = header(top)
        if member is not None and member.start > top.start:
            if member.name is None:
                # init, subscript or operator: reachable only through the type.
                seeds.append(Seed(type_name, None, "init-or-subscript"))
            elif member.visible:
                seeds.append(Seed(member.name, type_name, "member"))
            else:
                private.add(member.name)
            continue
        if kind == "extension" and ":" in lines[top.start - 1].split("{")[0]:
            untraceable.append(f"{path}:{number} conformance extension {type_name}")
            seeds.append(Seed(type_name, None, "conformance"))
            continue
        if not top.visible and kind != "extension":
            private.add(type_name)
            continue
        seeds.append(Seed(type_name, None, "top"))

    for _ in range(2):
        if not private:
            break
        pattern = re.compile(r"\b(" + "|".join(map(re.escape, sorted(private))) + r")\b")
        found: set[str] = set()
        for number, text in enumerate(lines, start=1):
            if not pattern.search(text):
                continue
            top, member = enclosing(file_outline, number)
            if top is None:
                continue
            _, type_name = header(top)
            if member is not None and member.start > top.start:
                if member.name is None:
                    seeds.append(Seed(type_name, None, "via-private-init"))
                elif member.name in private:
                    continue
                elif member.visible:
                    seeds.append(Seed(member.name, type_name, "via-private"))
                else:
                    found.add(member.name)
        private = found - private
    return seeds, untraceable


class TestIndex:
    """cmuxTests/ text, which files mention each identifier, and outlines."""

    def __init__(self, files: dict[str, str]):
        self.text = {path: text for path, text in files.items() if path.startswith("cmuxTests/")}
        self.lines = {path: text.splitlines() for path, text in self.text.items()}
        self.mentions: dict[str, set[str]] = {}
        for path, lines in self.lines.items():
            for word in set(IDENTIFIER_RE.findall("\n".join(lines))):
                self.mentions.setdefault(word, set()).add(path)
        self._outlines: dict = {}

    def outline(self, path: str):
        if path not in self._outlines:
            self._outlines[path] = outline(self.lines[path])
        return self._outlines[path]


def reach(
    seed: Seed, tests: TestIndex, declared: dict[str, int], skipped: list[str] | None = None
) -> tuple[set[str], set[str]] | str:
    """Suites and test files one changed name reaches, or why it was dropped.

    A helper name further along the trail that is too common to follow is
    recorded in `skipped`, so the report shows where recall was given up.
    A seed whose `how` is "string" is a literal: the first search is for the
    text itself, and the trail continues from there through helper names.
    """
    literal = seed.how == "string"
    if seed.name in GENERIC_NAMES and not literal:
        return "generic name"
    suites: set[str] = set()
    test_files: set[str] = set()
    queue: list[tuple[str, str | None]] = [(seed.name, seed.owner)]
    searched: set[tuple[str, str | None]] = set()
    first = True
    while queue:
        name, owner = queue.pop()
        if (name, owner) in searched:
            continue
        searched.add((name, owner))
        text_search = literal and first
        if text_search:
            scope = {path for path, text in tests.text.items() if name in text}
        else:
            scope = set(tests.mentions.get(name, ()))
        if not scope:
            continue
        cap = HOT_TEST_FILES if first else HOT_HELPER_TEST_FILES
        ambiguous = declared.get(name, 0) >= AMBIGUOUS_APP_DECLARATIONS
        if (ambiguous or len(scope) > cap) and owner and owner in tests.mentions:
            scope &= tests.mentions[owner]
        if len(scope) > cap or (ambiguous and not owner):
            if first:
                if len(scope) > cap:
                    return f"hot: {len(scope)} test files"
                return f"ambiguous: declared in {declared[name]} app files, no owner type"
            if skipped is not None:
                skipped.append(f"hot helper {name} (from {seed.name}): {len(scope)} test files")
            continue
        first = False
        pattern = re.compile(re.escape(name) if text_search else rf"\b{re.escape(name)}\b")
        for path in sorted(scope):
            file_outline = tests.outline(path)
            for number, text in enumerate(tests.lines[path], start=1):
                if not pattern.search(text):
                    continue
                top, member = enclosing(file_outline, number)
                if top is None:
                    continue
                if top.suite is not None:
                    suites.add(top.suite)
                    test_files.add(path)
                elif top.holds_tests:
                    match = TOP_LEVEL_RE.match(tests.lines[path][top.start - 1])
                    if match:
                        suites.add(match.group(3))
                        test_files.add(path)
                elif member is not None and member.start > top.start and member.name:
                    if member.visible:
                        queue.append((member.name, member.owner))
                    elif top.name:
                        queue.append((top.name, None))
                elif top.name:
                    queue.append((top.name, None))
    return suites, test_files


def select(files: dict[str, str], diff: str | None) -> Selection:
    """Suites a `git diff -U0` of app code reaches, over the trees in `files`.

    `files` maps repository paths under TREE_PREFIXES to their text at the
    diff's new side.
    """
    selection = Selection()
    if diff is None:
        selection.fallback = "diff unavailable"
        return selection
    hunks = changed_lines(diff)
    if diff.strip() and not hunks:
        selection.fallback = "diff not parseable"
        return selection
    if not any(path.startswith("cmuxTests/") for path in files):
        selection.fallback = "cmuxTests/ not found"
        return selection
    seeds: list[Seed] = []
    literals = changed_literals(diff)
    for path in sorted(set(hunks) | set(literals)):
        for literal in sorted(literals.get(path, ())):
            seeds.append(Seed(literal, None, "string"))
        if path.startswith("CLI/"):
            # The CLI is its own module; cmuxTests/ reaches it only through
            # the binary, so its literals are all there is to follow.
            selection.app_files.append(path)
            continue
        if not is_app_path(path) or path not in hunks:
            continue
        selection.app_files.append(path)
        if not path.endswith(".swift"):
            selection.nonswift_app_files.append(path)
            continue
        if path not in files:
            # Deleted: its callers changed too, or stop compiling. Recorded so a
            # missed failure can be traced to it.
            selection.untraceable.append(f"{path} deleted")
            continue
        found, untraceable = changed_seeds(path, files[path].splitlines(), hunks[path])
        seeds.extend(found)
        selection.untraceable.extend(untraceable)
    if not seeds:
        return selection
    tests = TestIndex(files)
    declared: dict[str, int] = {}
    for path, text in files.items():
        if not path.startswith("cmuxTests/"):
            for word in set(APP_DECLARATION_RE.findall(text)):
                declared[word] = declared.get(word, 0) + 1
    seen: set[tuple[str, str | None]] = set()
    for seed in seeds:
        if not seed.name or (seed.name, seed.owner) in seen:
            continue
        seen.add((seed.name, seed.owner))
        result = reach(seed, tests, declared, selection.untraceable)
        if isinstance(result, str):
            selection.dropped.append((seed, result))
        elif seed.how == "string" and not result[0]:
            continue  # most changed text is not asserted on anywhere
        else:
            selection.reached[seed] = result
    return selection


def suite_costs(root: Path, timings: dict | None) -> dict[str, int]:
    """Measured milliseconds per cmuxTests suite, as choose_ci_suite.py weighs them.

    Suites discover_selectors() leaves to their own strict steps fall back to
    the timings table, then to one default test.
    """
    costs: dict[str, int] = {}
    try:
        selectors, _ = reweight_selectors(discover_selectors(root), timings)
    except SystemExit as error:  # discover_selectors reports problems this way
        print(f"Could not enumerate cmuxTests selectors: {error}", file=sys.stderr)
        selectors = []
    for selector in selectors:
        suite = selector.identifier.split("/")[1]
        costs[suite] = costs.get(suite, 0) + selector.weight
    for suite, ms in ((timings or {}).get("suites") or {}).items():
        costs.setdefault(suite, int(ms))
    return costs


def budgeted(
    reached: dict[Seed, tuple[set[str], set[str]]], cost_of, budget_ms: int
) -> tuple[set[str], list[Seed], list[Seed]]:
    """Greedy: the names reaching the cheapest suite sets first, until the budget is spent."""
    chosen: set[str] = set()
    kept: list[Seed] = []
    left_out: list[Seed] = []
    for seed, (suites, _) in sorted(
        reached.items(), key=lambda item: (cost_of(item[1][0]), item[0].name, item[0].owner or "")
    ):
        trial = chosen | suites
        if cost_of(trial) <= budget_ms:
            chosen = trial
            kept.append(seed)
        else:
            left_out.append(seed)
    return chosen, kept, left_out


def seed_label(seed: Seed) -> str:
    if seed.how == "string":
        return json.dumps(seed.name)
    return f"{seed.owner}.{seed.name}" if seed.owner else seed.name


def report(
    selection: Selection,
    costs: dict[str, int],
    default_ms: int = FALLBACK_TEST_MS,
    budget_ms: int = CHANGED_SUITES_BUDGET_MS,
) -> dict:
    """The JSON artifact: what was considered, dropped, selected and what fits."""
    def cost_of(suites) -> int:
        return sum(costs.get(suite, default_ms) for suite in suites)

    suites = selection.suites
    total = cost_of(suites)
    chosen, kept, left_out = budgeted(selection.reached, cost_of, budget_ms)
    return {
        "schema": SCHEMA,
        "report_only": True,
        "fallback": selection.fallback,
        "app_files": selection.app_files,
        "nonswift_app_files": selection.nonswift_app_files,
        "untraceable": selection.untraceable,
        "names": [
            {
                "name": seed.name,
                "owner": seed.owner,
                "how": seed.how,
                "suites": sorted(reached),
                "test_files": len(test_files),
                "cost_ms": cost_of(reached),
            }
            for seed, (reached, test_files) in selection.reached.items()
        ],
        "dropped": [
            {"name": seed.name, "owner": seed.owner, "how": seed.how, "reason": reason}
            for seed, reason in selection.dropped
        ],
        "suites": sorted(suites),
        "cost_ms": total,
        "unmeasured_suites": sorted(suite for suite in suites if suite not in costs),
        "budget_ms": budget_ms,
        "over_budget": total > budget_ms,
        "budgeted": {
            "suites": sorted(chosen),
            "cost_ms": cost_of(chosen),
            "kept_names": [seed_label(seed) for seed in kept],
            "left_out_names": [seed_label(seed) for seed in left_out],
        },
        "would_run": sorted(chosen),
    }


def summary_markdown(data: dict, listed: int = 25) -> str:
    """A short step-summary section for one report."""
    heading = "### Reverse test impact (report only)"
    if data.get("fallback"):
        return f"{heading}\n\nNo selection: {data['fallback']}. Routing is unchanged.\n"
    would_run = data["would_run"]
    minutes = data["budgeted"]["cost_ms"] / 60000
    lines = [
        heading,
        "",
        f"{len(would_run)} suite{'' if len(would_run) == 1 else 's'}, {minutes:.1f} min; would run: "
        + (", ".join(would_run[:listed]) + (f", and {len(would_run) - listed} more" if len(would_run) > listed else "")
           if would_run else "nothing"),
        "",
        f"{len(data['app_files'])} app files changed; {len(data['names'])} names traced to "
        f"{len(data['suites'])} suites ({data['cost_ms'] / 60000:.1f} min measured).",
    ]
    if data["over_budget"]:
        lines.append(
            f"Over the {data['budget_ms'] / 60000:.0f} min budget: the most specific names were kept; "
            f"left out: {', '.join(data['budgeted']['left_out_names'][:10]) or 'none'}."
        )
    if data["dropped"]:
        dropped = ", ".join(
            f"`{seed_label(Seed(item['name'], item['owner'], item['how']))}` ({item['reason']})"
            for item in data["dropped"][:10]
        )
        lines.append(f"Dropped names: {dropped}" + (" ..." if len(data["dropped"]) > 10 else ""))
    if data["nonswift_app_files"]:
        lines.append(f"Not traced (not Swift): {', '.join(data['nonswift_app_files'][:10])}")
    lines.append("")
    lines.append("Nothing here changes which jobs run.")
    return "\n".join(lines) + "\n"


def read_root(root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for prefix in TREE_PREFIXES:
        for source in sorted((root / prefix).glob("**/*.swift")):
            files[source.relative_to(root).as_posix()] = source.read_text(encoding="utf-8", errors="replace")
    return files


def git(repo: Path, *args: str) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True).stdout


def extract_revision(repo: Path, revision: str, destination: Path) -> None:
    """Write the TREE_PREFIXES trees at `revision` under `destination`."""
    present = git(repo, "ls-tree", "--name-only", revision, "--", *TREE_PREFIXES).decode().split()
    archive = git(repo, "archive", "--format=tar", revision, "--", *present)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(destination, filter="data")
        else:
            tar.extractall(destination)


def run(args: argparse.Namespace) -> dict:
    timings = load_timings(args.timings)
    default_ms = (timings or {}).get("default_test_ms", FALLBACK_TEST_MS)
    with tempfile.TemporaryDirectory(prefix="reverse-test-impact-") as scratch:
        root = args.root
        diff: str | None = None
        if args.head:
            root = Path(scratch)
            extract_revision(args.repo, args.head, root)
            diff = git(
                args.repo, "diff", "--no-renames", "-U0", args.base or f"{args.head}^1", args.head,
                "--", "Sources", "Packages/macOS", "Packages/Shared", "CLI",
            ).decode("utf-8", "replace")
        elif args.diff_from:
            try:
                diff = Path(args.diff_from).read_text(encoding="utf-8", errors="replace")
            except OSError:
                diff = None
        selection = select(read_root(root), diff)
        costs = suite_costs(root, timings) if selection.reached else {}
    return report(selection, costs, default_ms)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="checkout holding the diff's new side")
    parser.add_argument("--diff-from", help="`git diff -U0` of Sources/, Packages/ and CLI/; omit when unreadable")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="with --head: the repository to read")
    parser.add_argument("--head", help="read the new side from this revision instead of --root")
    parser.add_argument("--base", help="with --head: the old side (default: its first parent)")
    parser.add_argument("--timings", type=Path, default=DEFAULT_TIMINGS_PATH)
    parser.add_argument("--output", help="write the JSON report here")
    parser.add_argument("--summary", help="append the markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)
    try:
        data = run(args)
    except Exception as error:  # report only: any failure is a warning, never a failed job
        print(f"::warning::Reverse test impact report failed: {error!r}", file=sys.stderr)
        data = {"schema": SCHEMA, "report_only": True, "fallback": f"selector error: {error!r}"}
    text = json.dumps(data, indent=1) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    summary = summary_markdown(data)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(summary)
    else:
        print(summary, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
