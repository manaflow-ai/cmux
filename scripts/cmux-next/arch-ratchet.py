#!/usr/bin/env python3
"""cmux-next arch ratchet: refuse a push that raises an architecture count (pre-push, local only).

guardrails.py runs it (one entry, one report: `prepush-gate.py --pre-push` starts guardrails' ratchet on a
thread next to its scanners, and the guardrails report prints it). The counts are
scripts/cmux-next/arch_counts.py's (method v3; its docstring defines every row), recorded in
plans/cmux-next/arch-ratchet.json. guardrails.py has no line rule for these rows: a count row has exactly one
escape, the dated json exception below.

Two rules refuse a push:
1. Code: counting just the files the push changes, at its base and its head, the TOTAL of a ratcheted row
   rises. A rise in one package that an equal fall elsewhere in the same push cancels is a move, and
   passes. In the rows whose sites have an identity (globals by name or type, broadcasts by literal), a
   new site that no removed site accounts for is refused even when the total holds: a swap (remove one
   singleton, add another) adds debt. A new layer edge or unplaced target is the layer gate's refusal
   (arch_rules/layer_gate.py), so the layer rows hold the total only. Rows: layer_hard, layer_soft,
   layer_upward, layer_unplaced, stateful_singletons, global_mutable_statics,
   assume_isolated_outside_adapters, app_broadcast_names, observer_sites. Report only:
   assume_isolated_total and app_lines (the app-size rule owns that refusal).
2. Record: the push raises a ratcheted total in plans/cmux-next/arch-ratchet.json (or deletes the file)
   beyond what the exceptions it newly applies cover, or changes or drops an applied exception. `--update`
   is the only writer, and it refuses such a
   rise itself, so a rise that landed past the hook (a GitHub merge, --no-verify, a clone with an old hook)
   stays visible: --update names the commits that raised it and asks for a dated exception.

The one escape: a dated entry the push adds to the json's `exceptions`
({"date": "YYYY-MM-DD", "row": "<row>", "allow": <n>, "why": "..."}) lets that push raise the row by n
(counted as sums per row against the base's pending entries: editing a pending entry gives nothing). The
next --update folds every pending entry into the totals and marks it `applied_sha`. An entry for a rule
module's id (`"row": "layer-gate"`) lets that push carry n of the module's refusals. There is no
environment-variable skip.

Rule modules in scripts/cmux-next/arch_rules/*.py add their own refusals (see arch_rules/__init__.py);
none are needed. A missing arch_rules directory (a broken install) prints a warning.

A push rebased onto origin/feat-cmux-next counts from the merge base; one that merges it in counts a
rise only when it is also a rise over that merge base, and keeps a rule module's refusal only when
the module refuses it over both ranges (matched by the refusal's key, not its text), so what others
landed never refuses a push.

When a count drops, it passes, and prints `lower plans/cmux-next/arch-ratchet.json:
scripts/cmux-next/arch-ratchet.py --update` with the rows the pushed json leaves stale, judged over the
range the drop came from (none when the push carries an `--update` measured after the drop; see
stale_rows for the one case it can still name wrongly). An internal error prints a warning and lets the
push through (fail open). Never runs
under GitHub Actions (Lawrence 2026-10-23: no new CI gates, nothing that slows pushes). Its cost is the files
it reads: the changed files, and for a type lookup the declaring and mentioning files, each analyzed once per
content (arch_counts.FactsCache); the report prints the count. Measured 2026-10-23 at load 50-70: an 80-file
cross-package move about 2 s warm, 8 s on the first run after arch_counts.py changes.

  scripts/cmux-next/arch-ratchet.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch-ratchet.py --base A --head B
  scripts/cmux-next/arch-ratchet.py --update [--rev R]
                                                     # rewrite plans/cmux-next/arch-ratchet.json at R (HEAD)
  scripts/cmux-next/arch-ratchet.py --audit [--rev R] [--json]
                                                     # a full count at R against the json at R, and the
                                                     # commits that raised each row over it (a report line
                                                     # for the perf cron, never a gate)
  scripts/cmux-next/arch-ratchet.py --list-rules
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULES_DIR = HERE / "arch_rules"
UPSTREAM = "origin/feat-cmux-next"
UPDATE_HINT = "lower plans/cmux-next/arch-ratchet.json: scripts/cmux-next/arch-ratchet.py --update"
RECORD_ROW = "arch_ratchet_json"  # the refusal id of rule 2 (the record's own totals)

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
                           "name (`app`, `current`, `live`) or a file-scope global is the same singleton",
    "global_mutable_statics": "move the state into an instance its domain model or actor owns and inject it; no "
                              "static or file-scope var, lock or cache",
    "assume_isolated_outside_adapters": "put the callback in a small seam adapter type of its own (a class, struct, "
                                        "enum or actor of at most 150 code lines; an extension of a larger type or "
                                        "a free function is not one) with a `// main-proof: <why>` comment; never in "
                                        "a deinit or a `queue: .main` observer block (use a @MainActor API or the "
                                        "async sequence)",
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
    """([(id, module)], warnings) for every rule module in DIRECTORY; none is fine, a missing DIRECTORY warns.

    The checkout always has arch_rules/ (its __init__.py documents the interface), so a missing one is a
    hook install that did not copy it: its rules would silently never run.
    """
    rules, warnings = [], []
    if not directory.is_dir():
        warnings.append(f"the arch rules directory {directory} is missing, so no rule module ran; rerun "
                        "scripts/install-git-hooks.sh")
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
    allow: dict = dataclasses.field(default_factory=dict)  # {row or rule id: n} from exceptions the push adds
    # {rev: parsed json or None}; check_range shares one across the ranges of a push (same head).
    cache: dict = dataclasses.field(default_factory=dict, repr=False, compare=False)

    def read(self, items):
        return self.counts.Git(self.repo).read(items)

    def record(self, rev: str) -> dict | None:
        """plans/cmux-next/arch-ratchet.json at REV as a dict, or None; read once per push."""
        if rev not in self.cache:
            self._load([rev])
        return self.cache[rev]

    def records(self) -> tuple[dict | None, dict | None]:
        """The json at base and at head, read in one `git cat-file --batch` and kept for the push."""
        missing = [rev for rev in dict.fromkeys((self.base, self.head)) if rev not in self.cache]
        if missing:
            self._load(missing)
        return self.cache[self.base], self.cache[self.head]

    def _load(self, revs: list[str]) -> None:
        rel = self.counts.RATCHET_JSON
        texts = self.read([(rev, rel) for rev in revs])
        for rev in revs:
            self.cache[rev] = parse_record(texts[(rev, rel)])


def parse_record(text: str | None) -> dict | None:
    if text is None:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


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


def exception_key(entry: dict) -> str:
    """An exception's identity: everything but the applied_sha --update adds."""
    return json.dumps({k: v for k, v in entry.items() if k != "applied_sha"}, sort_keys=True)


def verbatim(entry) -> str:
    return json.dumps(entry, sort_keys=True)


def exceptions_of(record: dict | None) -> list:
    entries = (record or {}).get("exceptions", [])
    return entries if isinstance(entries, list) else []


def applied_entries(record: dict | None) -> collections.Counter:
    """The applied entries of RECORD, verbatim (a multiset): the record never changes or drops one."""
    return collections.Counter(verbatim(e) for e in exceptions_of(record) if isinstance(e, dict) and e.get("applied_sha"))


def open_entries(old: dict | None, new: dict | None) -> list:
    """NEW's entries that are not one of OLD's applied entries (multiset): its pending ones and the ones this
    range applies."""
    applied = applied_entries(old)
    out = []
    for entry in exceptions_of(new):
        key = verbatim(entry)
        if applied[key] > 0:
            applied[key] -= 1
            continue
        out.append(entry)
    return out


def allowance(entries, known) -> dict[str, int]:
    out: dict[str, int] = {}
    for entry in entries:
        if valid_exception(entry, known):
            out[entry["row"]] = out.get(entry["row"], 0) + entry["allow"]
    return out


def valid_exception(entry, known) -> bool:
    # YYYY-MM-DD and a real day: the layer gate's `exceptions` and `relayered` use the same check.
    if not isinstance(entry, dict) or not load_counts().valid_date(entry.get("date")):
        return False
    n = entry.get("allow")
    return (entry.get("row") in known and isinstance(n, int) and not isinstance(n, bool) and n > 0
            and bool(str(entry.get("why", "")).strip()))


def exception_form(row: str, n: int) -> str:
    today = datetime.date.today().isoformat()
    return f'{{"date": "{today}", "row": "{row}", "allow": {n}, "why": "<the reviewed reason>"}}'


def added_exceptions(old: dict | None, new: dict | None, known) -> tuple[dict[str, int], list[str]]:
    """{row: allowance} the push adds, and notes.

    Per row: the allowance of NEW's open entries (pending, or applied by this push) minus that of OLD's
    pending entries, never below 0. Counted as sums, not by identity: an edit of an entry's `why` or `date`
    gives nothing, and a second identical entry gives its allowance again.
    """
    old_pending = [e for e in exceptions_of(old) if isinstance(e, dict) and not e.get("applied_sha")]
    opened = open_entries(old, new)
    before, after = allowance(old_pending, known), allowance(opened, known)
    allow = {row: after[row] - before.get(row, 0) for row in after if after[row] > before.get(row, 0)}
    notes = []
    seen = collections.Counter(exception_key(e) for e in exceptions_of(old) if isinstance(e, dict))
    for entry in opened:
        key = exception_key(entry) if isinstance(entry, dict) else verbatim(entry)
        if seen[key] > 0:
            seen[key] -= 1
            continue
        if not valid_exception(entry, known):
            notes.append(f"arch-ratchet: ignored exception {entry!r}: it needs date (YYYY-MM-DD), a row, allow > 0 and why")
            continue
        given = allow.get(entry["row"], 0)
        notes.append(f"arch-ratchet: exception {entry['date']} ({entry['row']} +{entry['allow']}): "
                     f"{str(entry['why']).strip()}; this push may raise {entry['row']} by {given}"
                     + ("" if given else " (an edit of a pending entry adds no allowance)"))
    return allow, notes


def applied_exceptions(old: dict | None, new: dict | None, known) -> dict[str, int]:
    """{row: allowance} of the valid entries NEW has applied that are not OLD's applied entries (multiset):
    what an --update in the range folded into the totals."""
    return allowance([e for e in open_entries(old, new) if isinstance(e, dict) and e.get("applied_sha")], known)


def changed_applied(old: dict | None, new: dict | None) -> list[str]:
    """OLD's applied entries that NEW no longer has verbatim (changed or removed)."""
    missing = applied_entries(old) - applied_entries(new)
    return sorted(missing.elements())


def fmt_packages(by_package: dict[str, int]) -> str:
    return ", ".join(f"{k} {v:+d}" for k, v in sorted(by_package.items(), key=lambda kv: (-kv[1], kv[0])))


# Rows whose sites have an identity (Delta.unpartnered): a new one with no removed partner is refused even
# when the total does not rise (a swap). The assumeIsolated and observer rows have no stable identity per
# site (an edit of the line would read as a new site), so they hold the total only. The layer rows hold the
# total only too: a new edge or unplaced target is arch_rules/layer_gate.py's refusal (one answer per edge).
SWAP_ROWS = frozenset({"stateful_singletons", "global_mutable_statics", "app_broadcast_names"})


def count_rule(per_range: list[Changes]) -> tuple[list[tuple[str, str]], list[str]]:
    """Rule 1: a ratcheted row's total may not rise in the code the push changes (moves pass), and a row with
    site identity may not gain a site no removed one accounts for (a swap adds debt too).

    PER_RANGE holds one Changes per range of ranges_to_count; the first is the pushed range.
    """
    changes = per_range[0]
    counts = changes.counts
    refusals: list[tuple[str, str]] = []
    notes: list[str] = []
    dropped: dict[int, dict[str, int]] = {}  # {index into PER_RANGE: {row: drop}}
    for row in counts.ROWS:
        # A merge of upstream counts only what rises over both ends (see ranges_to_count).
        chosen = min(range(len(per_range)), key=lambda i: per_range[i].delta.total(row.id))
        delta = per_range[chosen].delta
        total = delta.total(row.id)
        new = (min((c.delta.unpartnered(row.id) for c in per_range), key=len)
               if row.ratchet and row.id in SWAP_ROWS else [])
        if total == 0 and not new:
            continue
        where = fmt_packages(delta.by_package(row.id))
        if not row.ratchet:
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where}); report only"
                         + ("; the app-size rule owns that refusal" if row.id == "app_lines" else ""))
            continue
        if total < 0:
            dropped.setdefault(chosen, {})[row.id] = total
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where})")
        rise = max(total, len(new))
        allowed = changes.allow.get(row.id, 0)
        if rise <= allowed:
            continue
        head = f"arch-ratchet: [{row.id}] {row.title}: {total:+d}" + (f" ({where})" if where else "")
        if len(new) > max(total, 0):
            head += (f", {len(new)} new site(s) that replace none the push removes (a swap adds debt even when the "
                     "total holds)")
        lines = [head + (f", {allowed} allowed by the exceptions this push adds" if allowed else "")]
        for site in (new or delta.new_sites(row.id))[:12]:
            place = f"{site.path}:{site.line}" if site.line else site.path
            lines.append(f"  {place}: {site.text}")
        lines.append(f"  Right pattern: {FIX.get(row.id, 'see arch_counts.py')}.")
        lines.append(f"  The only escape (a reviewed reason, never to pass the hook): add "
                     f"{exception_form(row.id, rise - allowed)} to the exceptions of {counts.RATCHET_JSON} "
                     "in this push.")
        refusals.append((row.id, "\n".join(lines)))
    # Each drop is compared with the json over the range the drop came from.
    stale = {row for i, rows in dropped.items() for row in stale_rows(per_range[i], rows)}
    if stale:
        notes.append(f"arch-ratchet: {UPDATE_HINT} ({', '.join(r for r in counts.ROW_IDS if r in stale)})")
    return refusals, notes


def stale_rows(changes: Changes, dropped: dict[str, int]) -> list[str]:
    """The DROPPED rows (row: drop over CHANGES' range) whose recorded total the push leaves stale.

    No full count (the pre-push budget is ~1 s), so this reads the json at both ends:
    - a push that leaves the json alone keeps every drop stale; so does a pushed json that is missing,
      unparsable or of another method_version (`--update` rewrites it);
    - a row is current when the base record has it and the pushed total is at most the base total
      plus the drop.
    Every other row is unproved: the pushed record lacks it, or the base record does (the push brings
    the row's first record, which `--update` measured at some commit, maybe before the drop). Unproved
    rows are cleared together when the pushed record's measured_sha is a commit of this range and no
    counted file (arch_counts.is_counted) changes after it: that record is then a full count of HEAD.
    The comparison assumes the base record was accurate. When a skip left it low (recorded 10, true
    11), a push that drops 1 and runs `--update` writes 10, above 10 - 1, and is unproved too; the
    measured_sha test clears it. Known false positive left: a record measured in the range with
    counted changes after it, or measured outside the range, over an inaccurate base record or with no
    base record. Rerunning `--update` and committing only the json clears it (its measured_sha is then
    the json commit's parent, in the range, with nothing counted after it).
    """
    if not dropped:
        return []
    counts = changes.counts
    if not any(path == counts.RATCHET_JSON for _, path in changes.files):
        return list(dropped)

    def totals(data: dict | None) -> dict | None:
        found = data.get("totals") if data and data.get("method_version") == counts.METHOD_VERSION else None
        return found if isinstance(found, dict) else None

    base_record, head_record = changes.records()
    old, new = totals(base_record), totals(head_record)
    if new is None:
        return list(dropped)
    unproved = []
    for row, total in dropped.items():
        was, now = (old or {}).get(row), new.get(row)
        if not (isinstance(was, int) and isinstance(now, int) and now <= was + total):
            unproved.append(row)
    if unproved and measured_in_range(changes, head_record):
        return []
    return unproved


def measured_in_range(changes: Changes, record: dict) -> bool:
    """True when RECORD's measured_sha is a commit of CHANGES' range and nothing counted changes after it."""
    counts = changes.counts
    sha = record.get("measured_sha")
    if not isinstance(sha, str) or not counts.SHA.fullmatch(sha):
        return False
    git = counts.Git(changes.repo)
    if sha not in git.run("rev-list", f"{changes.base}..{changes.head}", check=False).split():
        return False
    later = git.run("diff", "--name-only", "--no-renames", "-z", sha, changes.head, "--", check=False)
    return not any(counts.is_counted(p) for p in later.split("\0") if p)


def keyed_refusal(item, rule_id: str) -> tuple[str, str, tuple]:
    """(row, text, key) of a rule module's refusal: `(row, text, key)`, `(row, text)` or a bare text.

    KEY identifies the refusal across the ranges of a merge push; without one the row and text do.
    """
    if not isinstance(item, tuple):
        return rule_id, str(item), (rule_id, str(item))
    row, text = str(item[0]), str(item[1])
    key = item[2] if len(item) > 2 else text
    return row, text, (row, key if isinstance(key, (str, tuple)) else repr(key))


def record_rule(per_range: list[Changes]) -> tuple[list[tuple[str, str]], list[str]]:
    """Rule 2: the push may not raise a ratcheted total of arch-ratchet.json beyond the exceptions it newly
    applies, delete the file, or change or drop an applied exception. A merge counts a rise only when every
    range shows it (PER_RANGE as count_rule's)."""
    counts = per_range[0].counts
    rel = counts.RATCHET_JSON
    if not all(any(path == rel for _, path in c.files) for c in per_range):
        return [], []
    known = set(counts.ROW_IDS)
    olds = [c.records()[0] for c in per_range]
    new = per_range[0].records()[1]  # every range ends at the pushed head
    if any(old is None for old in olds):
        return [], []  # the first record: nothing to hold it to
    if new is None:
        return [(RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] this push deletes {rel} (or breaks its JSON), the record "
                             "the ratchet holds the counts to. Keep it; lower it with "
                             "scripts/cmux-next/arch-ratchet.py --update.")], []
    changed = [entry for old in olds[:1] for entry in changed_applied(old, new)]
    if changed and all(changed_applied(old, new) for old in olds):
        return [(RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] this push changes or removes an applied exception of {rel}: "
                             + "; ".join(changed) + ". An applied entry is the record of a reviewed rise: keep it "
                             "verbatim and add a new dated entry instead.")], []
    if any(old.get("method_version") != new.get("method_version") for old in olds):
        return [], [f"arch-ratchet: {rel} changes method v{olds[0].get('method_version')} -> "
                    f"v{new.get('method_version')}: its totals are not compared (review the row definitions)"]
    rises: list[dict[str, tuple[int, int, int]]] = []
    for old in olds:
        allow = applied_exceptions(old, new, known)
        found = {}
        for row in counts.ROWS:
            was, now = (old.get("totals") or {}).get(row.id), (new.get("totals") or {}).get(row.id)
            if row.ratchet and isinstance(was, int) and isinstance(now, int) and now - was > allow.get(row.id, 0):
                found[row.id] = (was, now, allow.get(row.id, 0))
        rises.append(found)
    refusals = []
    for row_id in sorted(set.intersection(*(set(r) for r in rises))):
        was, now, allowed = rises[0][row_id]
        refusals.append((RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] {rel} raises {row_id} from {was} to {now} "
                                     f"(+{now - was}; the exceptions it applies allow {allowed}). Only "
                                     "scripts/cmux-next/arch-ratchet.py --update writes the totals, and it refuses a "
                                     "rise no pending exception covers: add "
                                     f"{exception_form(row_id, now - was - allowed)} to its exceptions and rerun it."))
    return refusals, []


def module_ids(loaded) -> dict[str, str]:
    """{refusal id: rule id} of the loaded rule modules: a module's `ID` (layer_gate.py's "layer-gate"), else
    its file stem. A dated exception for that id lets a push carry that many of the module's refusals."""
    return {str(getattr(module, "ID", rule_id)): rule_id for rule_id, module in loaded}


def check_range(repo: Path, base: str, head: str, rules=None,
                upstream_ref: str = UPSTREAM) -> tuple[list[tuple[str, str]], list[str]]:
    """(refusals, notes) for one pushed BASE..HEAD."""
    counts = load_counts()
    ranges = ranges_to_count(repo, base, head, upstream_ref)
    deltas = [counts.delta_count(repo, b, h) for b, h in ranges]
    loaded, warnings = load_rules() if rules is None else (rules, [])
    ids = module_ids(loaded)
    known = set(counts.ROW_IDS) | set(ids)
    notes = [f"arch-ratchet: WARNING: {w}" for w in warnings]
    analyzed, cached = sum(d.analyzed for d in deltas), sum(d.cached for d in deltas)
    if analyzed + cached:
        notes.append(f"arch-ratchet: read {analyzed + cached} Swift file(s): {analyzed} analyzed, {cached} from the facts "
                     "cache")
    records: dict = {}
    per_range = [Changes(repo, d.base, d.head, d.files, d, counts, cache=records) for d in deltas]
    first = per_range[0]
    if any(path == counts.RATCHET_JSON for _, path in first.files):
        first.allow, extra = added_exceptions(*first.records(), known)
        notes += extra
    for changes in per_range[1:]:
        changes.allow = first.allow  # the exceptions are the pushed head's: one allowance for the push
    refusals, extra = count_rule(per_range)
    notes += extra
    got, extra = record_rule(per_range)
    refusals += got
    notes += extra
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
            kept = [(row, text) for row, text, key in found[0] if all(key in other for other in keys)]
        except Exception as error:  # fail open per rule
            notes.append(f"arch-ratchet: WARNING: arch rule {rule_id} failed ({type(error).__name__}: {error}); "
                         "not applied to this push")
            continue
        refusals += allow_module_refusals(kept, first.allow, ids, notes)
    return refusals, notes


def allow_module_refusals(kept: list[tuple[str, str]], allow: dict[str, int], ids: dict[str, str],
                          notes: list[str]) -> list[tuple[str, str]]:
    """The module refusals KEPT that the push's exceptions do not cover; a covered id gets a note.

    Per module id: when the push adds exceptions that allow at least as many refusals as the module gives,
    every one passes; otherwise every one is refused (the text says how many are allowed).
    """
    out: list[tuple[str, str]] = []
    for row in dict.fromkeys(row for row, _ in kept):
        mine = [text for r, text in kept if r == row]
        allowed = allow.get(row, 0) if row in ids else 0
        if mine and len(mine) <= allowed:
            notes.append(f"arch-ratchet: [{row}] {len(mine)} refusal(s) let through by the exceptions this push adds "
                         f"(allow {allowed})")
            continue
        if allowed:
            mine[-1] += f"\n  The exceptions this push adds allow {allowed} [{row}] refusal(s); it has {len(mine)}."
        out += [(row, text) for text in mine]
    return out


def run_push(repo: Path, ranges: list[tuple[str, str]], upstream_ref: str = UPSTREAM,
             out: list[str] | None = None) -> bool:
    """Report the ratchet for the pushed RANGES; True when it refuses the push. Fails open.

    The report is printed, or appended to OUT (guardrails runs this on a thread next to the gate's scanners
    and prints OUT with its own report).
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
        rules, warnings = load_rules()
        refusals, notes = [], [f"arch-ratchet: WARNING: {w}" for w in warnings]
        for base, head in ranges:
            got, extra = check_range(repo, base, head, rules, upstream_ref)
            refusals += got
            notes += extra
        text = "\n".join(notes + [t for _, t in refusals])
        if text:
            emit(text)
        elapsed = time.monotonic() - started
        if refusals:
            emit(f"arch-ratchet: push refused ({elapsed:.2f}s)")
        else:
            emit(f"arch-ratchet: no architecture count rises ({elapsed:.2f}s)")
        return bool(refusals)
    except (Exception, SystemExit) as error:
        emit(f"arch-ratchet: WARNING: the ratchet failed ({type(error).__name__}: {error}); not applied to this "
             "push. Tell the Performance Lead with this line.", error=True)
        return False


def raised_by(repo: Path, since: str, until: str, rows: set[str]) -> dict[str, list[tuple[str, int, str]]]:
    """{row: [(short sha, rise, "author: subject")]} of the non-merge commits in SINCE..UNTIL that raised a row.

    Each commit is counted against its first parent from git objects only (no worktree), so the answer
    is the same in any checkout.
    """
    counts = load_counts()
    paths = [counts.SOURCES, *counts.COUNT_INPUTS]
    code, out = git(repo, "log", "--no-merges", "--reverse", "--format=%H%x1f%an%x1f%s", f"{since}..{until}", "--", *paths)
    found: dict[str, list[tuple[str, int, str]]] = {row: [] for row in rows}
    if code != 0:
        return found
    for line in out.splitlines():
        sha, author, subject = (line.split("\x1f") + ["", ""])[:3]
        try:
            delta = counts.delta_count(repo, f"{sha}^1", sha, use_worktree=False)
        except RuntimeError:
            continue  # a root commit: nothing to count against
        for row in rows:
            if delta.total(row) > 0:
                found[row].append((sha[:11], delta.total(row), f"{author}: {subject}"))
    return found


def audit(repo: Path, rev: str = "HEAD") -> dict:
    """A full count at REV against arch-ratchet.json at REV: each ratcheted row over its recorded total, and
    the commits since the record's measured_sha that raised it (perf cron report input; never a gate)."""
    counts = load_counts()
    sha, now, _ = counts.full_count(repo, rev)
    record = parse_record(counts.Git(repo).read([(sha, counts.RATCHET_JSON)])[(sha, counts.RATCHET_JSON)])
    result = {"sha": sha, "recorded_sha": None, "over": {}, "note": None}
    if record is None:
        result["note"] = f"no {counts.RATCHET_JSON} at {sha[:11]}"
        return result
    result["recorded_sha"] = record.get("measured_sha")
    if record.get("method_version") != counts.METHOD_VERSION:
        result["note"] = (f"{counts.RATCHET_JSON} is method v{record.get('method_version')}, the count is "
                          f"v{counts.METHOD_VERSION}: not compared")
        return result
    totals = now.totals()
    over = {row.id: (record.get("totals", {}).get(row.id), totals[row.id]) for row in counts.ROWS if row.ratchet
            and isinstance(record.get("totals", {}).get(row.id), int) and totals[row.id] > record["totals"][row.id]}
    since = record.get("measured_sha")
    culprits = raised_by(repo, since, sha, set(over)) if over and since else {}
    for row_id, (was, n) in over.items():
        result["over"][row_id] = {"recorded": was, "now": n,
                                  "raised_by": [{"sha": c, "rise": r, "commit": t} for c, r, t in culprits.get(row_id, [])]}
    return result


def audit_lines(result: dict) -> list[str]:
    if result["note"]:
        return [f"arch-ratchet audit at {result['sha'][:11]}: {result['note']}"]
    if not result["over"]:
        return [f"arch-ratchet audit at {result['sha'][:11]}: every ratcheted row is at or under arch-ratchet.json "
                f"(recorded at {str(result['recorded_sha'])[:11]})"]
    lines = []
    for row_id, entry in sorted(result["over"].items()):
        by = "; ".join(f"{c['sha']} +{c['rise']} ({c['commit'][:60]})" for c in entry["raised_by"]) or "no single commit"
        lines.append(f"arch-ratchet audit at {result['sha'][:11]}: {row_id} {entry['now']} over the recorded "
                     f"{entry['recorded']} (+{entry['now'] - entry['recorded']} since "
                     f"{str(result['recorded_sha'])[:11]}); raised by {by}")
    return lines


def update(repo: Path, rev: str = "HEAD") -> int:
    """Rewrite plans/cmux-next/arch-ratchet.json from a full count at REV, the one writer of its totals.

    REV defaults to HEAD; a branch that changes no Swift may record its base on origin/feat-cmux-next
    (`--rev origin/feat-cmux-next`), so measured_sha survives the rebase that lands it.

    A ratcheted total may only go up by what the pending (not yet applied) dated exceptions allow; a larger
    rise is refused with the commits that raised it. Every pending exception is folded in (applied_sha).
    """
    counts = load_counts()
    path = repo / counts.RATCHET_JSON
    old = {}
    if path.is_file():
        old = parse_record(path.read_text()) or {}
    sha, now, lay = counts.full_count(repo, rev)
    totals = now.totals()
    # A rule module's entry is folded in too: it allowed the refusals of the push that added it.
    known = set(counts.ROW_IDS) | set(module_ids(load_rules()[0]))
    exceptions = [dict(e) if isinstance(e, dict) else e for e in old.get("exceptions", [])]
    pending = [e for e in exceptions if valid_exception(e, known) and not e.get("applied_sha")]
    allow: dict[str, int] = {}
    for e in pending:
        allow[e["row"]] = allow.get(e["row"], 0) + e["allow"]
    comparable = old.get("method_version") == counts.METHOD_VERSION and isinstance(old.get("totals"), dict)
    before = old.get("totals", {}) if comparable else {}
    if old and not comparable:
        print(f"arch-ratchet: the recorded file is method v{old.get('method_version')}, the count is "
              f"v{counts.METHOD_VERSION}: totals not compared (review the row definitions)")
    uncovered = {row.id: (before[row.id], totals[row.id]) for row in counts.ROWS
                 if row.ratchet and isinstance(before.get(row.id), int)
                 and totals[row.id] - before[row.id] > allow.get(row.id, 0)}
    if uncovered:
        since = old.get("measured_sha")
        culprits = raised_by(repo, since, sha, set(uncovered)) if since else {}
        print(f"arch-ratchet: --update refused: {path.name} not written. These ratcheted totals rose past "
              "the pending exceptions:")
        for row_id, (was, n) in sorted(uncovered.items()):
            print(f"  {row_id}: recorded {was} at {str(since)[:11]}, now {n} (+{n - was}; pending exceptions "
                  f"allow {allow.get(row_id, 0)})")
            for c, r, t in culprits.get(row_id, []):
                print(f"    raised by {c} +{r} {t}")
            print(f"    fix the code, or (a reviewed reason only) add "
                  f"{exception_form(row_id, n - was - allow.get(row_id, 0))} to exceptions and rerun --update")
        return 1
    for e in pending:
        e["applied_sha"] = sha
    data = counts.record(sha, now, lay, exceptions)
    counts.write_record(repo, data)
    for row in counts.ROWS:
        was, new = before.get(row.id), data["totals"][row.id]
        print(f"  {row.id:34} {was if was is not None else '-':>8} -> {new}")
    if pending:
        print(f"  applied {len(pending)} pending exception(s) at {sha[:11]}")
    print(f"wrote {path} at {sha[:11]}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--update", action="store_true", help="rewrite plans/cmux-next/arch-ratchet.json at --rev")
    parser.add_argument("--audit", action="store_true", help="full count at --rev against the json at --rev")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--json", action="store_true", help="--audit: print one JSON object")
    parser.add_argument("--list-rules", action="store_true")
    parser.add_argument("--upstream", default=UPSTREAM, help="the shared branch whose landed work never counts")
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve() if args.repo else Path(git(Path.cwd(), "rev-parse", "--show-toplevel")[1])
    if args.list_rules:
        counts = load_counts()
        for row in counts.ROWS:
            print(f"{row.id:34} {'ratchet' if row.ratchet else 'report '} {row.title}")
        print(f"{RECORD_ROW:34} ratchet the json's own ratcheted totals (only --update raises them)")
        rules, warnings = load_rules()
        for refusal_id, rule_id in module_ids(rules).items():
            print(f"{refusal_id:34} module  {RULES_DIR / (rule_id + '.py')}")
        for w in warnings:
            print(f"WARNING: {w}")
        return 0
    if args.update:
        return update(repo, args.rev)
    if args.audit:
        result = audit(repo, args.rev)
        print(json.dumps(result, sort_keys=True) if args.json else "\n".join(audit_lines(result)))
        return 0
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
