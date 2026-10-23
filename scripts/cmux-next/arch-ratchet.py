#!/usr/bin/env python3
"""cmux-next arch ratchet: refuse a push that raises an architecture count (pre-push, local only).

The counts are scripts/cmux-next/arch_counts.py's (method v1; its docstring defines every row), recorded
in plans/cmux-next/arch-ratchet.json. The hook (prepush-gate.py, local path only) counts just the files
the push changes, at its base and its head, and refuses when the TOTAL of a ratcheted row rises. A rise
in one package that an equal fall elsewhere in the same push cancels is a move, and passes. Rows:
layer_hard, layer_soft, layer_upward, layer_unplaced, stateful_singletons, global_mutable_statics,
assume_isolated_outside_adapters, app_broadcast_names, observer_sites. Report only: assume_isolated_total
and app_lines (the app-size rule owns that refusal).

Rule modules in scripts/cmux-next/arch_rules/*.py add their own refusals (see arch_rules/__init__.py);
none are needed.

A push rebased onto origin/feat-cmux-next counts from the merge base; one that merges it in counts a
rise only when it is also a rise over that merge base, and keeps a rule module's refusal only when
the module refuses it over both ranges (matched by the refusal's key, not its text), so what others
landed never refuses a push.

When a count drops, it prints `lower plans/cmux-next/arch-ratchet.json: scripts/cmux-next/arch-ratchet.py
--update` and passes. Escape for one push (say it in your report):
ARCH_RATCHET_SKIP_REASON="<row>[,<row>]: <why>". A dated entry the push adds to the json's `exceptions`
({"date": "YYYY-MM-DD", "row": "<row>", "allow": <n>, "why": "..."}) lets that push raise the row by n.
An internal error prints a warning and lets the push through (fail open). Never runs under GitHub
Actions (Lawrence 2026-10-23: no new CI gates, nothing that slows pushes; well under 1 s).

  scripts/cmux-next/arch-ratchet.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch-ratchet.py --base A --head B
  scripts/cmux-next/arch-ratchet.py --update         # rewrite plans/cmux-next/arch-ratchet.json at HEAD
  scripts/cmux-next/arch-ratchet.py --list-rules
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULES_DIR = HERE / "arch_rules"
SKIP_ENV = "ARCH_RATCHET_SKIP_REASON"
UPSTREAM = "origin/feat-cmux-next"
UPDATE_HINT = "lower plans/cmux-next/arch-ratchet.json: scripts/cmux-next/arch-ratchet.py --update"

# The right pattern per row, printed with each refusal (repo CLAUDE.md "Refactor architecture",
# "Modern Swift concurrency"; plans/cmux-next/perf-lead.md "Architecture targets").
FIX = {
    "layer_hard": "depend downward only: lift the shared type to a core target or define a protocol seam in the "
                  "consumer, never an edge from core/service/domain to ui/app",
    "layer_soft": "a service depends on core protocols, not on a domain target: lift the type or add a seam",
    "layer_upward": "edges only point down: a core target depends on nothing above core; lift the type it needs "
                    "to core or define a protocol seam in core that the higher layer conforms to",
    "layer_unplaced": "add the target to plans/cmux-next/architecture-layers.json with its layer",
    "stateful_singletons": "construct the object once at the composition root (AppDelegate / AppServices) and "
                           "inject it through init; wrap an OS singleton once at a seam and inject that. A new "
                           "name (`app`, `current`, `live`) is the same singleton",
    "global_mutable_statics": "move the state into an instance its domain model or actor owns and inject it; no "
                              "static var, static lock or static cache",
    "assume_isolated_outside_adapters": "put the callback in a small seam adapter type (at most 150 code lines and "
                                        "2 types) with a `// main-proof: <why>` comment; never in a deinit or a "
                                        "`queue: .main` observer block (use a @MainActor API or the async sequence)",
    "app_broadcast_names": "tell the subscriber directly (an injected protocol, a closure or an AsyncStream), not "
                           "through a NotificationCenter name",
    "observer_sites": "observe a system notification once per app or window in an adapter that calls only the "
                      "affected subscribers; tell app subscribers directly",
}


def load_counts():
    """arch_counts.py next to this file (the installed hook copy runs its own)."""
    name = "cmux_next_arch_counts"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def load_rules(directory: Path = RULES_DIR) -> tuple[list[tuple[str, object]], list[str]]:
    """([(id, module)], warnings) for every rule module in DIRECTORY; none is fine."""
    rules, warnings = [], []
    if not directory.is_dir():
        return rules, warnings
    for path in sorted(directory.glob("*.py")):
        if path.name.startswith("_"):
            continue
        try:
            spec = importlib.util.spec_from_file_location(f"cmux_next_arch_rule_{path.stem}", path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            if not callable(getattr(module, "check", None)):
                warnings.append(f"arch rule {path.name} has no check(); skipped")
                continue
            rules.append((path.stem, module))
        except Exception as error:  # fail open: a broken rule never blocks a push
            warnings.append(f"arch rule {path.name} did not load ({type(error).__name__}: {error}); skipped")
    return rules, warnings


@dataclasses.dataclass
class Changes:
    """What a rule module's check() gets (arch_rules/__init__.py documents it)."""

    repo: Path
    base: str
    head: str
    files: list
    delta: object
    counts: object

    def read(self, items):
        return self.counts.Git(self.repo).read(items)

    def record(self, rev: str) -> dict | None:
        text = self.read([(rev, self.counts.RATCHET_JSON)])[(rev, self.counts.RATCHET_JSON)]
        if text is None:
            return None
        try:
            return json.loads(text)
        except ValueError:
            return None


def git(repo: Path, *args: str) -> tuple[int, str]:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def ranges_to_count(repo: Path, base: str, head: str, upstream_ref: str = UPSTREAM) -> list[tuple[str, str]]:
    """The ranges whose deltas count for a pushed BASE..HEAD (full shas): the push's own changes.

    One `git merge-base` in the common case (BASE is already where HEAD meets origin/feat-cmux-next).
    """
    code, upstream = git(repo, "merge-base", head, upstream_ref)
    if code != 0 or not upstream or upstream == base:
        return [(base, head)]
    if upstream == head:
        return [(head, head)]  # every pushed commit is already on origin/feat-cmux-next: none is the push's own
    _, common = git(repo, "merge-base", base, upstream)
    if common == upstream:
        return [(base, head)]  # origin/feat-cmux-next is behind the base
    if common == base:
        return [(upstream, head)]  # rebased or fast-forwarded onto it: count from where HEAD meets it
    return [(base, head), (upstream, head)]  # merged it in: a rise must show over both


def parse_skip(value: str, known: set[str]) -> tuple[set[str], str | None]:
    named, colon, why = value.partition(":")
    ids = {r.strip() for r in named.split(",") if r.strip()}
    if not colon or not why.strip() or not ids:
        return set(), f'{SKIP_ENV} must be "<row>[,<row>]: <why>" (rows: {", ".join(sorted(known))})'
    unknown = sorted(ids - known)
    if unknown:
        return set(), f"{SKIP_ENV} names no row {', '.join(unknown)} (rows: {', '.join(sorted(known))})"
    return ids, None


def added_exceptions(changes: Changes) -> tuple[dict[str, int], list[str]]:
    """{row: allowance} from valid entries the push adds to the json's `exceptions`, and notes."""
    rel = changes.counts.RATCHET_JSON
    if not any(path == rel for _, path in changes.files):
        return {}, []
    old = changes.record(changes.base) or {}
    new = changes.record(changes.head) or {}
    seen = {json.dumps(e, sort_keys=True) for e in old.get("exceptions", []) if isinstance(e, dict)}
    allow: dict[str, int] = {}
    notes = []
    for entry in new.get("exceptions", []):
        if not isinstance(entry, dict) or json.dumps(entry, sort_keys=True) in seen:
            continue
        row, n, why, date = entry.get("row"), entry.get("allow"), str(entry.get("why", "")).strip(), entry.get("date")
        # YYYY-MM-DD and a real day: the layer gate's `exceptions` and `relayered` use the same check.
        dated = changes.counts.valid_date(date)
        if row not in changes.counts.ROW_IDS or not isinstance(n, int) or n <= 0 or not why or not dated:
            notes.append(f"arch-ratchet: ignored exception {entry!r}: it needs date (YYYY-MM-DD), a row, allow > 0 and why")
            continue
        allow[row] = allow.get(row, 0) + n
        notes.append(f"arch-ratchet: exception {date} lets this push raise {row} by {n}: {why}")
    return allow, notes


def fmt_packages(by_package: dict[str, int]) -> str:
    return ", ".join(f"{k} {v:+d}" for k, v in sorted(by_package.items(), key=lambda kv: (-kv[1], kv[0])))


def count_rule(changes: Changes, deltas: list) -> tuple[list[tuple[str, str]], list[str]]:
    """The built-in rule: a ratcheted row's total may not rise (moves pass)."""
    counts = changes.counts
    allow, notes = added_exceptions(changes)
    refusals: list[tuple[str, str]] = []
    dropped = False
    for row in counts.ROWS:
        # A merge of upstream counts only what rises over both ends (see ranges_to_count).
        delta = min(deltas, key=lambda d: d.total(row.id))
        total = delta.total(row.id)
        if total == 0:
            continue
        where = fmt_packages(delta.by_package(row.id))
        if not row.ratchet:
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where}); report only"
                         + ("; the app-size rule owns that refusal" if row.id == "app_lines" else ""))
            continue
        if total < 0:
            dropped = True
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where})")
            continue
        if total <= allow.get(row.id, 0):
            continue
        lines = [f"arch-ratchet: [{row.id}] {row.title}: {total:+d} ({where})"]
        for site in delta.new_sites(row.id)[:12]:
            place = f"{site.path}:{site.line}" if site.line else site.path
            lines.append(f"  {place}: {site.text}")
        lines.append(f"  Right pattern: {FIX.get(row.id, 'see arch_counts.py')}.")
        lines.append(f'  Escape for this push only: {SKIP_ENV}="{row.id}: <why>" (say it in your report).')
        refusals.append((row.id, "\n".join(lines)))
    if dropped:
        notes.append(f"arch-ratchet: {UPDATE_HINT}")
    return refusals, notes


def keyed_refusal(item, rule_id: str) -> tuple[str, str, tuple]:
    """(row, text, key) of a rule module's refusal: `(row, text, key)`, `(row, text)` or a bare text.

    KEY identifies the refusal across the ranges of a merge push; without one the row and text do.
    """
    if not isinstance(item, tuple):
        return rule_id, str(item), (rule_id, str(item))
    row, text = str(item[0]), str(item[1])
    key = item[2] if len(item) > 2 else text
    return row, text, (row, key if isinstance(key, (str, tuple)) else repr(key))


def check_range(repo: Path, base: str, head: str, rules=None,
                upstream_ref: str = UPSTREAM) -> tuple[list[tuple[str, str]], list[str]]:
    """(refusals, notes) for one pushed BASE..HEAD."""
    counts = load_counts()
    ranges = ranges_to_count(repo, base, head, upstream_ref)
    deltas = [counts.delta_count(repo, b, h) for b, h in ranges]
    per_range = [Changes(repo, d.base, d.head, d.files, d, counts) for d in deltas]
    refusals, notes = count_rule(per_range[0], deltas)
    loaded, warnings = load_rules() if rules is None else (rules, [])
    notes += [f"arch-ratchet: WARNING: {w}" for w in warnings]
    for rule_id, module in loaded:
        try:
            found = []
            for changes in per_range:
                got, extra = module.check(changes.base, changes.head, changes)
                found.append([keyed_refusal(item, rule_id) for item in got])
                notes += [str(n) for n in extra if str(n) not in notes]
            # A merge of upstream refuses only what every range refuses, as the count rule takes the
            # minimum (see ranges_to_count): a change that came in through the merge is not the push's own.
            # Ranges are matched by key: the text can name a layer or a note that differs between the two
            # bases (an upstream relabel), and the first range's (the pushed range's) text is kept.
            keys = [{key for _, _, key in other} for other in found[1:]]
            refusals += [(row, text) for row, text, key in found[0] if all(key in other for other in keys)]
        except Exception as error:  # fail open per rule
            notes.append(f"arch-ratchet: WARNING: arch rule {rule_id} failed ({type(error).__name__}: {error}); "
                         "not applied to this push")
    return refusals, notes


def report(refusals: list[tuple[str, str]], notes: list[str], known: set[str]) -> tuple[str, bool]:
    """The text to print and whether the push is refused (after ARCH_RATCHET_SKIP_REASON)."""
    lines = list(notes)
    skip = os.environ.get(SKIP_ENV, "").strip()
    skip_ids, error = parse_skip(skip, known | {r for r, _ in refusals}) if skip else (set(), None)
    if error:
        lines.append(f"arch-ratchet: {error}; nothing skipped")
    kept = []
    for row, text in refusals:
        if row in skip_ids:
            lines.append(f"arch-ratchet: SKIPPED by {SKIP_ENV}={skip!r}: [{row}]. Say so in your report.")
        else:
            kept.append(text)
    lines += kept
    return "\n".join(lines), bool(kept)


def run_push(repo: Path, ranges: list[tuple[str, str]], upstream_ref: str = UPSTREAM,
             out: list[str] | None = None) -> bool:
    """Report the ratchet for the pushed RANGES; True when it refuses the push. Fails open.

    The report is printed, or appended to OUT (prepush-gate runs this next to its scanners and prints
    OUT when it reaches the guardrails).
    """
    def emit(text: str, error: bool = False) -> None:
        if out is not None:
            out.append(text)
        else:
            print(text, file=sys.stderr if error else sys.stdout)

    if os.environ.get("GITHUB_ACTIONS"):
        return False
    started = time.monotonic()
    try:
        counts = load_counts()
        rules, warnings = load_rules()
        refusals, notes = [], [f"arch-ratchet: WARNING: {w}" for w in warnings]
        for base, head in ranges:
            got, extra = check_range(repo, base, head, rules, upstream_ref)
            refusals += got
            notes += extra
        text, refused = report(refusals, notes, set(counts.ROW_IDS))
        if text:
            emit(text)
        elapsed = time.monotonic() - started
        if refused:
            emit(f"arch-ratchet: push refused ({elapsed:.2f}s)")
        else:
            emit(f"arch-ratchet: no architecture count rises ({elapsed:.2f}s)")
        return refused
    except (Exception, SystemExit) as error:
        emit(f"arch-ratchet: WARNING: the ratchet failed ({type(error).__name__}: {error}); not applied to this "
             "push. Tell the Performance Lead with this line.", error=True)
        return False


def update(repo: Path) -> int:
    """Rewrite plans/cmux-next/arch-ratchet.json from a full count at HEAD (keeps the exceptions)."""
    counts = load_counts()
    path = repo / counts.RATCHET_JSON
    old = {}
    if path.is_file():
        try:
            old = json.loads(path.read_text())
        except ValueError:
            old = {}
    sha, now, lay = counts.full_count(repo, "HEAD")
    data = counts.record(sha, now, lay, old.get("exceptions", []))
    counts.write_record(repo, data)
    before = old.get("totals", {}) if old.get("method_version") == counts.METHOD_VERSION else {}
    for row in counts.ROWS:
        was, new = before.get(row.id), data["totals"][row.id]
        mark = ""
        if was is not None and new > was and row.ratchet:
            mark = "  (higher than recorded: a push skipped the ratchet or a merge brought it in)"
        print(f"  {row.id:34} {was if was is not None else '-':>8} -> {new}{mark}")
    print(f"wrote {path} at {sha[:11]}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--update", action="store_true", help="rewrite plans/cmux-next/arch-ratchet.json at HEAD")
    parser.add_argument("--list-rules", action="store_true")
    parser.add_argument("--upstream", default=UPSTREAM, help="the shared branch whose landed work never counts")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(git(Path.cwd(), "rev-parse", "--show-toplevel")[1])
    if args.list_rules:
        counts = load_counts()
        for row in counts.ROWS:
            print(f"{row.id:34} {'ratchet' if row.ratchet else 'report '} {row.title}")
        rules, warnings = load_rules()
        for rule_id, _ in rules:
            print(f"{rule_id:34} module  {RULES_DIR / (rule_id + '.py')}")
        for w in warnings:
            print(f"WARNING: {w}")
        return 0
    if args.update:
        return update(repo)
    if os.environ.get("GITHUB_ACTIONS"):
        print("arch-ratchet: not run under GitHub Actions (local pre-push only)")
        return 0
    code, head = git(repo, "rev-parse", "--verify", f"{args.head}^{{commit}}")
    if code != 0:
        print(f"arch-ratchet: no commit {args.head}", file=sys.stderr)
        return 2
    if args.base:
        code, base = git(repo, "rev-parse", "--verify", f"{args.base}^{{commit}}")
    else:
        code, base = git(repo, "merge-base", head, args.upstream)
        if code != 0 or not base:
            code, base = git(repo, "rev-parse", "--verify", f"{head}~1")
    if code != 0 or not base:
        print(f"arch-ratchet: no base commit for {args.head}", file=sys.stderr)
        return 2
    return 1 if run_push(repo, [(base, head)], args.upstream) else 0


if __name__ == "__main__":
    sys.exit(main())
