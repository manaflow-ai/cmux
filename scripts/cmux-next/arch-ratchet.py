#!/usr/bin/env python3
"""cmux-next arch ratchet: refuse a push that raises an architecture count (pre-push, local only).

guardrails.py runs it (one entry, one report: `prepush-gate.py --pre-push` starts guardrails' ratchet on a
thread next to its scanners, and the guardrails report prints it). The counts are
scripts/cmux-next/arch_counts.py's (method v6; its docstring defines every row), recorded in
plans/cmux-next/arch-ratchet.json. guardrails.py has no line rule for these rows: a count row has exactly one
escape, the dated json exception below.

Two rules refuse a push:
1. Code: counting just the files the push changes, at its base and its head, the TOTAL of a ratcheted row
   rises. A rise in one package that an equal fall elsewhere in the same push cancels is a move, and
   passes. In the rows whose sites have an identity (globals by owner and name or by type, broadcasts by
   literal, an assumeIsolated outside an adapter by the type and function around it), a new site that no
   removed site accounts for is refused even when the total holds: a swap (remove one singleton or unproved
   call, add another) adds debt. The owner type is part of that identity on purpose: a typeless static or an
   unproved call moved to another type (a renamed owner, a static extracted into a new Coordinator) counts as
   new debt there, so the move fixes it or carries a dated exception (arch_counts "Site identity"). A new
   layer edge or unplaced target is the layer gate's refusal
   (arch_rules/layer_gate.py): the layer rows hold the total only, and the unit of a layer row's rise that
   a gate refusal answers is not refused again (one refusal, one dated entry per edge). Rows: layer_hard, layer_soft,
   layer_upward, layer_unplaced, stateful_singletons, global_mutable_statics,
   assume_isolated_outside_adapters, app_broadcast_names, observer_sites, blocking_allow_escapes. Report only:
   assume_isolated_total and app_lines (the app-size rule owns that refusal).
2. Record: the push raises a ratcheted total in plans/cmux-next/arch-ratchet.json (or deletes the file)
   beyond what the exceptions it newly applies cover, changes or drops an applied exception, or changes
   method_version without changing arch_counts.py to that METHOD_VERSION. `--update` is the only writer,
   and it refuses a rise no pending exception covers, unless commits already on origin/feat-cmux-next made
   it (a GitHub merge, --no-verify, a clone with an old hook): that debt is not the runner's, so --update
   warns, names the commits and records the rise with a generated applied entry (`raised_by`: the commits),
   which allows no rise in any push's code. This rule re-derives such an entry as --update does
   (generated_allowance): each commit is on origin/feat-cmux-next, after the old record's measured_sha and
   in the new one's, named by no earlier applied entry and by no second open entry, and the allowance is at
   most both the commits' rises and the net rise where the new measured_sha meets origin/feat-cmux-next. A
   hand-written or copied generated entry therefore lets the totals take no rise the record missed.

The one escape: a dated entry the push adds to the json's `exceptions`
({"date": "YYYY-MM-DD", "row": "<row>", "allow": <n>, "why": "..."}) lets that push raise the row by n
(counted as sums per row against the base's pending entries: editing a pending entry gives nothing; the
base of a push that merges origin/feat-cmux-next in is where HEAD meets it, so an exception upstream landed
is in the base and allows the push nothing). The next --update folds every pending entry into the
totals and marks it `applied_sha`. An entry for a rule
module's id (`"row": "layer-gate"`) lets that push carry n of the module's refusals. There is no
environment-variable skip.

Rule modules in scripts/cmux-next/arch_rules/*.py add their own refusals (see arch_rules/__init__.py);
none are needed. A missing arch_rules directory (a broken install) prints a warning.

A push counts over one range: the push's own base..head (push_range.py; prepush-gate passes the ranges its
scanners judged, through guardrails; own_pair). A push rebased onto origin/feat-cmux-next or merging it in
counts from where HEAD meets it, a second push from its old remote head. Everything others landed is in that
base, so it never refuses a push, never cancels the push's own rise (an upstream drop that came in through a
merge is not the push's) and never lends the push an exception. The count rule, the record rule, the
exceptions the push adds and every rule module read that one range.

When a count drops, it passes, and prints `lower plans/cmux-next/arch-ratchet.json:
scripts/cmux-next/arch-ratchet.py --update` with the rows the pushed json leaves stale, judged over the
range (none when the push carries an `--update` measured after the drop; see
stale_rows for the one case it can still name wrongly). An internal error prints a warning and lets the
push through (fail open). Never runs
under GitHub Actions (Lawrence 2026-10-23: no new CI gates, nothing that slows pushes). Its cost is the files
it reads: the changed files, and for a type lookup the declaring and mentioning files, each analyzed once per
content (arch_counts.FactsCache); the report prints the count. Measured 2026-10-23 at load 50-70 (method v3,
before the v4 observer count): an 80-file cross-package move about 2 s warm, 8 s on the first run after
arch_counts.py changes. v4 adds the observer count at both ends of every Swift push: two worktree greps and the
observer facts of about 150 files from the cache when warm (one parse of each when cold); not measured yet.
v5 (2026-10-24, load 65-77) counts the local package closure: a 10-file CmuxNext range takes 0.75 s best and 0.85 s
median warm, against 0.62 s and 0.80 s for v4 in the same run (the closure comes from the facts cache by commit; a
range that changes no Package.swift reuses its base's).

  scripts/cmux-next/arch-ratchet.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch-ratchet.py --base A --head B   # exactly what B adds over A
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
import re
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
                      "affected subscribers; tell app subscribers directly. A wrapper (MainActorObservation, a "
                      "helper) is still an observer at each use that configures it",
    "blocking_allow_escapes": "move the blocking call off the main thread (an actor, a detached task) instead of "
                              "allowing it; an allowance is for a call that must block, with its reason",
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
    # {rev: parsed json or None}, read once per push.
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


def load_push_range():
    """push_range.py next to this file: which commits a push owns (prepush-gate and guardrails use it too)."""
    name = "cmux_next_push_range"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "push_range.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


def own_pair(own) -> tuple[str, str]:
    """The one range the ratchet counts for OWN (a push_range.OwnRange): HEAD over its base, the merged upstream
    commit for a merge of origin/feat-cmux-next in (where HEAD meets it).

    OWN.before (what the branch's old remote head already had, which the gate and guardrails take off a merge)
    is not taken off here: commits of the pushed branch that an earlier push sent count again in a merge push,
    as they do after a rebase (3f25c6b0fc2: the branch lands as one change, and a rule module's refusal has no
    key to match across ranges)."""
    return own.base, own.head


def range_to_count(repo: Path, base: str, head: str, upstream_ref: str = UPSTREAM) -> tuple[str, str]:
    """The one range whose delta counts for a push of HEAD whose remote head is BASE: the push's own changes.

    The ratchet rule (perf-lead brief, agreed with cmux-b6) refuses only what the push adds, counted against
    the push's own merge base with origin/feat-cmux-next (push_range.own_range). A push rebased onto it and a
    push that merges it in both count from where HEAD meets it: everything others landed is in it, so an
    upstream drop never cancels the push's own rise and an upstream `exceptions` entry is never the push's own.
    """
    return own_pair(load_push_range().own_range(repo, head, [base], upstream_ref))


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


def generated(entry) -> bool:
    """Whether ENTRY is --update's record of a rise already on origin/feat-cmux-next (it names the commits in
    `raised_by`): it lets the record's totals take that rise (once the record rule re-checks it) and allows no
    rise in a push's code."""
    return isinstance(entry, dict) and "raised_by" in entry


def added_exceptions(old: dict | None, new: dict | None, known) -> tuple[dict[str, int], list[str]]:
    """{row: allowance} the push adds, and notes.

    Per row: the allowance of NEW's open entries (pending, or applied by this push) minus that of OLD's
    pending entries, never below 0. Counted as sums, not by identity: an edit of an entry's `why` or `date`
    gives nothing, and a second identical entry gives its allowance again. A generated entry gives nothing.
    """
    old_pending = [e for e in exceptions_of(old) if isinstance(e, dict) and not e.get("applied_sha") and not generated(e)]
    opened = [e for e in open_entries(old, new) if not generated(e)]
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


def applied_exceptions(old: dict | None, new: dict | None, known, derive=None) -> dict[str, int]:
    """{row: allowance} of the valid entries NEW has applied that are not OLD's applied entries (multiset):
    what an --update in the range folded into the totals. The generated entries among them give what
    DERIVE(generated entries) re-derives ({row: n}; none: they give nothing)."""
    opened = [e for e in open_entries(old, new) if isinstance(e, dict) and e.get("applied_sha")]
    out = allowance([e for e in opened if not generated(e)], known)
    if derive is not None:
        for row, n in derive([e for e in opened if generated(e)]).items():
            out[row] = out.get(row, 0) + n
    return out


def changed_applied(old: dict | None, new: dict | None) -> list[str]:
    """OLD's applied entries that NEW no longer has verbatim (changed or removed)."""
    missing = applied_entries(old) - applied_entries(new)
    return sorted(missing.elements())


def fmt_packages(by_package: dict[str, int]) -> str:
    return ", ".join(f"{k} {v:+d}" for k, v in sorted(by_package.items(), key=lambda kv: (-kv[1], kv[0])))


# Rows whose sites have an identity (Delta.unpartnered): a new one with no removed partner is refused even
# when the total does not rise (a swap). A global is identified by its owner and name or its type, a broadcast
# by its literal, an assumeIsolated outside an adapter by the type and function around it (so an unproved
# call removed in one type and added in another is refused). The observer row has no stable identity per site
# (an edit of the line would read as a new site), so it holds the total only. The layer rows hold the total
# only too: a new edge or unplaced target is arch_rules/layer_gate.py's refusal (one answer per edge).
SWAP_ROWS = frozenset({"stateful_singletons", "global_mutable_statics", "app_broadcast_names",
                       "assume_isolated_outside_adapters"})


def count_rule(changes: Changes, answered: dict[str, int] | None = None) -> tuple[list[tuple[str, str]], list[str]]:
    """Rule 1: a ratcheted row's total may not rise in the code the push changes (moves pass), and a row with
    site identity may not gain a site no removed one accounts for (a swap adds debt too).

    CHANGES is the push's one range (range_to_count). ANSWERED is {row: n}: n rule-module refusals of this push
    (refused or let through by the module's own exception) that each answer one unit of ROW's rise (a new hard
    edge is the layer gate's refusal; one escape for it, not a second one for layer_hard).
    """
    answered = answered or {}
    counts = changes.counts
    delta = changes.delta
    refusals: list[tuple[str, str]] = []
    notes: list[str] = []
    dropped: dict[str, int] = {}
    unknown = delta.unknown()
    for why in dict.fromkeys(unknown.values()):
        rows = ", ".join(r for r in counts.ROW_IDS if unknown.get(r) == why)
        notes.append(f"arch-ratchet: {rows} not judged for this push: {why} at one end and no earlier map parses, "
                     "so its edges are unknown")
    for row in counts.ROWS:
        total = delta.total(row.id)
        new = delta.unpartnered(row.id) if row.ratchet and row.id in SWAP_ROWS else []
        if total == 0 and not new:
            continue
        where = fmt_packages(delta.by_package(row.id))
        if not row.ratchet:
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where}); report only"
                         + ("; the app-size rule owns that refusal" if row.id == "app_lines" else ""))
            continue
        if total < 0:
            dropped[row.id] = total
            notes.append(f"arch-ratchet: {row.id} {total:+d} ({where})")
        rise = max(total, len(new))
        by_module = min(answered.get(row.id, 0), max(rise, 0))
        allowed = changes.allow.get(row.id, 0)
        if rise - by_module <= allowed:
            continue
        head = f"arch-ratchet: [{row.id}] {row.title}: {total:+d}" + (f" ({where})" if where else "")
        if by_module:
            head += f", {by_module} answered by a rule module's refusal"
        if len(new) > max(total, 0):
            head += (f", {len(new)} new site(s) that replace none the push removes (a swap adds debt even when the "
                     "total holds; a static or unproved call moved to another type counts as new debt)")
        lines = [head + (f", {allowed} allowed by the exceptions this push adds" if allowed else "")]
        for site in (new or delta.new_sites(row.id))[:12]:
            place = f"{site.path}:{site.line}" if site.line else site.path
            lines.append(f"  {place}: {site.text}")
        lines.append(f"  Right pattern: {FIX.get(row.id, 'see arch_counts.py')}.")
        lines.append(f"  The only escape (a reviewed reason, never to pass the hook): add "
                     f"{exception_form(row.id, rise - by_module - allowed)} to the exceptions of {counts.RATCHET_JSON} "
                     "in this push.")
        refusals.append((row.id, "\n".join(lines)))
    stale = set(stale_rows(changes, dropped))
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
    """True when RECORD's measured_sha is a commit of CHANGES' range and nothing counted changes after it: no file
    that the closure at measured_sha or at the head counts (arch_counts.read_paths: their Swift and manifests)."""
    counts = changes.counts
    sha = record.get("measured_sha")
    if not isinstance(sha, str) or not counts.SHA.fullmatch(sha):
        return False
    git = counts.Git(changes.repo)
    if sha not in git.run("rev-list", f"{changes.base}..{changes.head}", check=False).split():
        return False
    later = [p for p in git.run("diff", "--name-only", "--no-renames", "-z", sha, changes.head, "--",
                                check=False).split("\0") if p]
    if not later:
        return True
    scopes = [counts.read_paths(changes.repo, rev) for rev in (sha, changes.head)]
    return not any(scope.is_counted(p) for scope in scopes for p in later)


def rule_refusal(item, rule_id: str) -> tuple[str, str, str | None]:
    """(row, text, counted) of a rule module's refusal: `(row, text, counted)`, `(row, text)` or a bare text
    (named by RULE_ID). COUNTED names the arch_counts row whose rise this refusal answers (count_rule does not
    refuse that unit again)."""
    if not isinstance(item, tuple):
        return rule_id, str(item), None
    row, text = str(item[0]), str(item[1])
    counted = str(item[2]) if len(item) > 2 and item[2] else None
    return row, text, counted


class Derivation:
    """What generated_allowance reads from git for one push, each once: full counts, per-commit rises, ancestry."""

    def __init__(self, repo: Path, upstream_ref: str):
        self.repo, self.upstream_ref = repo, upstream_ref
        self._totals: dict[str, dict[str, int] | None] = {}
        self._rises: dict[str, object] = {}
        self._ancestor: dict[tuple[str, str], bool] = {}
        self._parents: dict[str, int] = {}

    def ancestor(self, sha: str, of: str) -> bool:
        """Whether commit SHA is OF or an ancestor of it (OF a sha or a ref)."""
        if (sha, of) not in self._ancestor:
            self._ancestor[(sha, of)] = git(self.repo, "merge-base", "--is-ancestor", sha, of)[0] == 0
        return self._ancestor[(sha, of)]

    def parents(self, sha: str) -> int:
        """The number of parents of SHA (-1: no such commit)."""
        if sha not in self._parents:
            code, out = git(self.repo, "rev-list", "--parents", "-n", "1", sha)
            self._parents[sha] = len(out.split()) - 1 if code == 0 and out else -1
        return self._parents[sha]

    def rise(self, sha: str, row: str) -> int:
        """ROW's rise in commit SHA over its first parent, from git objects only (as raised_by counts it)."""
        if sha not in self._rises:
            try:
                self._rises[sha] = load_counts().delta_count(self.repo, f"{sha}^1", sha, use_worktree=False)
            except RuntimeError:
                self._rises[sha] = None
        delta = self._rises[sha]
        return max(0, delta.total(row)) if delta is not None else 0

    def totals_where_met(self, sha: str) -> dict[str, int] | None:
        """The full-count totals where SHA meets UPSTREAM_REF (what --update's upstream_rises counts), or None."""
        if sha not in self._totals:
            code, meet = git(self.repo, "merge-base", sha, self.upstream_ref)
            self._totals[sha] = load_counts().full_count(self.repo, meet)[1].totals() if code == 0 and meet else None
        return self._totals[sha]


def generated_allowance(old: dict, new: dict, entries: list, derivation: Derivation) -> dict[str, int]:
    """{row: n} the generated ENTRIES (the ones NEW applies over OLD) allow, re-derived as --update derives
    them, so a hand-written or copied `raised_by` entry gives no more than the upstream rise it names.

    An entry counts only when it is well formed (a valid exception of a count row, `raised_by` a non-empty
    list of full shas) and every commit it names is a non-merge commit on UPSTREAM_REF that NEW's
    measured_sha contains and OLD's measured_sha does not (a commit before the old record was counted
    there already), that no applied entry of OLD names, and that no other entry of ENTRIES names for the
    same row (a verbatim copy of an entry names the same commits as the original, so neither counts). Per
    row the allowance is the smallest of: the counted entries' `allow` sum, the sum of their commits' rises
    of the row over each first parent, and the net rise over OLD's total where NEW's measured_sha meets
    UPSTREAM_REF (a rise a later upstream commit undid is none). Only a push whose json brings a generated
    entry pays the full count and the per-commit counts (from FactsCache when warm).
    """
    counts = load_counts()
    since, until = old.get("measured_sha"), new.get("measured_sha")
    before = old.get("totals") if isinstance(old.get("totals"), dict) else {}
    if (not entries or not all(isinstance(x, str) and counts.SHA.fullmatch(x) for x in (since, until))
            or derivation.parents(since) < 0):
        return {}  # no old record to bound the commits by (a missing commit is no ancestor of anything)
    named_before = {x for e in exceptions_of(old) if isinstance(e, dict) and e.get("applied_sha")
                    and isinstance(e.get("raised_by"), list) for x in e["raised_by"] if isinstance(x, str)}
    named = collections.Counter((e["row"], x) for e in entries if isinstance(e.get("row"), str)
                                and isinstance(e.get("raised_by"), list) for x in e["raised_by"] if isinstance(x, str))

    def holds(entry: dict) -> bool:
        shas, row = entry.get("raised_by"), entry.get("row")
        if (row not in counts.ROW_IDS or not valid_exception(entry, counts.ROW_IDS) or not isinstance(shas, list)
                or not shas or not all(isinstance(x, str) and counts.SHA.fullmatch(x) for x in shas)):
            return False
        return all(named[(row, x)] == 1 and x not in named_before and derivation.parents(x) == 1
                   and derivation.ancestor(x, derivation.upstream_ref) and derivation.ancestor(x, until)
                   and not derivation.ancestor(x, since) for x in shas)

    claimed: dict[str, int] = {}
    commits: dict[str, set[str]] = collections.defaultdict(set)
    for entry in entries:
        if holds(entry):
            claimed[entry["row"]] = claimed.get(entry["row"], 0) + entry["allow"]
            commits[entry["row"]].update(entry["raised_by"])
    out = {}
    for row, n in claimed.items():
        met = derivation.totals_where_met(until)
        if met is None or not isinstance(before.get(row), int):
            continue
        n = min(n, sum(derivation.rise(x, row) for x in sorted(commits[row])), met[row] - before[row])
        if n > 0:
            out[row] = n
    return out


def record_rule(changes: Changes, upstream_ref: str = UPSTREAM) -> tuple[list[tuple[str, str]], list[str]]:
    """Rule 2: the push may not raise a ratcheted total of arch-ratchet.json beyond the exceptions it newly
    applies, delete the file, change or drop an applied exception, or change method_version without the
    arch_counts.py change that makes it. CHANGES is the push's one range (range_to_count), so a merge push
    compares the json where HEAD meets UPSTREAM_REF with its own. A generated entry (--update's record of a rise
    already on UPSTREAM_REF) covers only what generated_allowance re-derives for it."""
    counts = changes.counts
    rel = counts.RATCHET_JSON
    if not any(path == rel for _, path in changes.files):
        return [], []
    known = set(counts.ROW_IDS)
    old, new = changes.records()
    if old is None:
        return [], []  # the first record: nothing to hold it to
    if new is None:
        return [(RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] this push deletes {rel} (or breaks its JSON), the record "
                             "the ratchet holds the counts to. Keep it; lower it with "
                             "scripts/cmux-next/arch-ratchet.py --update.")], []
    changed = changed_applied(old, new)
    if changed:
        return [(RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] this push changes or removes an applied exception of {rel}: "
                             + "; ".join(changed) + ". An applied entry is the record of a reviewed rise: keep it "
                             "verbatim and add a new dated entry instead.")], []
    if old.get("method_version") != new.get("method_version"):
        if not method_change_made(changes, new):
            return [(RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] {rel} changes method_version "
                                 f"{old.get('method_version')!r} -> {new.get('method_version')!r}, but this push "
                                 f"does not change {counts.METHOD_FILE} to that METHOD_VERSION. Only a change of the "
                                 "row definitions changes the method (it bumps METHOD_VERSION there), and only "
                                 "scripts/cmux-next/arch-ratchet.py --update writes the json.")], []
        return [], [f"arch-ratchet: {rel} changes method v{old.get('method_version')} -> "
                    f"v{new.get('method_version')} with {counts.METHOD_FILE}: its totals are not compared (review "
                    "the row definitions)"]
    derivation = Derivation(changes.repo, upstream_ref)
    allow = applied_exceptions(old, new, known, lambda entries: generated_allowance(old, new, entries, derivation))
    refusals = []
    for row in counts.ROWS:
        was, now = (old.get("totals") or {}).get(row.id), (new.get("totals") or {}).get(row.id)
        allowed = allow.get(row.id, 0)
        if row.ratchet and isinstance(was, int) and isinstance(now, int) and now - was > allowed:
            refusals.append((RECORD_ROW, f"arch-ratchet: [{RECORD_ROW}] {rel} raises {row.id} from {was} to {now} "
                                         f"(+{now - was}; the exceptions it applies allow {allowed}). Only "
                                         "scripts/cmux-next/arch-ratchet.py --update writes the totals, and it refuses "
                                         "a rise no pending exception covers (a generated `raised_by` entry covers only "
                                         "the rise its commits made on origin/feat-cmux-next after the old record): add "
                                         f"{exception_form(row.id, now - was - allowed)} to its exceptions and rerun it."))
    return refusals, []


def method_change_made(changes: Changes, record: dict) -> bool:
    """Whether CHANGES' range makes RECORD's method_version: it changes arch_counts.py, and the head's
    arch_counts.py declares METHOD_VERSION = RECORD's method_version (the head's file, not the installed copy
    the hook runs). A json-only edit of method_version is not a method change."""
    counts = changes.counts
    if not any(path == counts.METHOD_FILE for _, path in changes.files):
        return False
    text = changes.read([(changes.head, counts.METHOD_FILE)])[(changes.head, counts.METHOD_FILE)] or ""
    found = re.search(r"^METHOD_VERSION\s*=\s*(\d+)\s*$", text, re.M)
    version = record.get("method_version")
    return bool(found) and isinstance(version, int) and not isinstance(version, bool) and int(found.group(1)) == version


def module_ids(loaded) -> dict[str, str]:
    """{refusal id: rule id} of the loaded rule modules: a module's `ID` (layer_gate.py's "layer-gate"), else
    its file stem. A dated exception for that id lets a push carry that many of the module's refusals."""
    return {str(getattr(module, "ID", rule_id)): rule_id for rule_id, module in loaded}


def push_allowance(changes: Changes, known, notes: list[str]) -> dict[str, int]:
    """{row or rule id: n} the exceptions the push adds allow, for every rule (count, module), over the push's
    one range: the json where HEAD meets origin/feat-cmux-next holds every exception upstream landed, so a merge
    push gets nothing from one. A range that leaves the json alone adds none. NOTES gets one line per entry."""
    if not any(path == changes.counts.RATCHET_JSON for _, path in changes.files):
        return {}
    allow, extra = added_exceptions(*changes.records(), known)
    notes += extra
    return {row: n for row, n in allow.items() if n > 0}


def check_range(repo: Path, base: str, head: str, rules=None,
                upstream_ref: str = UPSTREAM) -> tuple[list[tuple[str, str]], list[str]]:
    """(refusals, notes) for a push of HEAD whose remote head is BASE, counted over range_to_count's one range."""
    return check_own(repo, *range_to_count(repo, base, head, upstream_ref), rules, upstream_ref)


def check_own(repo: Path, base: str, head: str, rules=None,
              upstream_ref: str = UPSTREAM) -> tuple[list[tuple[str, str]], list[str]]:
    """(refusals, notes) for exactly what HEAD adds over BASE: the push's own range (own_pair)."""
    counts = load_counts()
    delta = counts.delta_count(repo, base, head)
    loaded, warnings = load_rules() if rules is None else (rules, [])
    ids = module_ids(loaded)
    known = set(counts.ROW_IDS) | set(ids)
    notes = [f"arch-ratchet: WARNING: {w}" for w in warnings]
    if delta.analyzed + delta.cached:
        notes.append(f"arch-ratchet: read {delta.analyzed + delta.cached} Swift file(s): {delta.analyzed} analyzed, "
                     f"{delta.cached} from the facts cache")
    changes = Changes(repo, delta.base, delta.head, delta.files, delta, counts)
    changes.allow = push_allowance(changes, known, notes)
    # The rule modules run first: a module refusal that answers a count row's rise (the layer gate's new edge)
    # is the one answer for it, so count_rule does not refuse the same unit again.
    module_refusals: list[tuple[str, str]] = []
    answered: collections.Counter = collections.Counter()
    for rule_id, module in loaded:
        try:
            got, extra = module.check(changes.base, changes.head, changes)
            kept = [rule_refusal(item, rule_id) for item in got]
            notes += [str(n) for n in extra if str(n) not in notes]
        except Exception as error:  # fail open per rule
            notes.append(f"arch-ratchet: WARNING: arch rule {rule_id} failed ({type(error).__name__}: {error}); "
                         "not applied to this push")
            continue
        answered.update(counted for _, _, counted in kept if counted)
        module_refusals += allow_module_refusals([(row, text) for row, text, _ in kept], changes.allow, ids, notes)
    refusals, extra = count_rule(changes, dict(answered))
    notes += extra
    got, extra = record_rule(changes, upstream_ref)
    refusals += got
    notes += extra
    refusals += module_refusals
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


def run_push(repo: Path, ranges: list, upstream_ref: str = UPSTREAM,
             out: list[str] | None = None) -> bool:
    """Report the ratchet for the pushed RANGES; True when it refuses the push. Fails open.

    RANGES are push_range.OwnRange values (guardrails passes the gate's, so the ratchet judges the commits the
    scanners judged); a (base, head) pair is a push whose remote head is base. The report is printed, or
    appended to OUT (guardrails runs this on a thread next to the gate's scanners and prints OUT with its own
    report).
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
        for own in load_push_range().as_own_ranges(repo, ranges, upstream_ref):
            got, extra = check_own(repo, *own_pair(own), rules, upstream_ref)
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
    """{row: [(sha, rise, "author: subject")]} of the non-merge commits in SINCE..UNTIL that raised a row.

    Each commit is counted against its first parent from git objects only (no worktree), so the answer
    is the same in any checkout.
    """
    counts = load_counts()
    # The closures at both ends (their Sources and manifests), every Package.swift (a commit between them can link a
    # package and the next unlink it) and the layer map.
    found: dict[str, list[tuple[str, int, str]]] = {row: [] for row in rows}
    try:
        scopes = [counts.read_paths(repo, rev) for rev in (since, until)]
    except RuntimeError:
        return found  # an end is not a commit here (a measured_sha rebased away)
    paths = sorted({p for scope in scopes for p in scope.sources + scope.count_inputs}) + [":(glob)**/Package.swift"]
    code, out = git(repo, "log", "--no-merges", "--reverse", "--format=%H%x1f%an%x1f%s", f"{since}..{until}", "--", *paths)
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
                found[row].append((sha, delta.total(row), f"{author}: {subject}"))
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
                                  "raised_by": [{"sha": c[:11], "rise": r, "commit": t} for c, r, t in culprits.get(row_id, [])]}
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


def on_upstream(repo: Path, sha: str, upstream_ref: str) -> bool:
    """Whether commit SHA is already on UPSTREAM_REF (origin/feat-cmux-next)."""
    return git(repo, "merge-base", "--is-ancestor", sha, upstream_ref)[0] == 0


def upstream_rises(repo: Path, since: str | None, sha: str, rows: set[str], before: dict,
                   upstream_ref: str) -> tuple[dict[str, int], dict[str, list[tuple[str, int, str]]]]:
    """({row: rise}, {row: [(sha, rise, commit)]}): how far each of ROWS rose over BEFORE (the record) in
    commits already on UPSTREAM_REF, and those commits.

    The rise is the smaller of two measures, so a local commit's debt is never attributed to upstream: a full
    count where SHA meets UPSTREAM_REF over the record (net, so an upstream rise a later upstream commit undid
    is none), and the sum of the per-commit rises of the upstream commits since the record (what the
    generated entry names and the record rule re-checks). No upstream ref, no record sha: nothing.
    """
    if not since or not rows:
        return {}, {}
    code, meet = git(repo, "merge-base", sha, upstream_ref)
    if code != 0 or not meet:
        return {}, {}
    _, at_meet, _ = load_counts().full_count(repo, meet)
    met = at_meet.totals()
    culprits = raised_by(repo, since, meet, rows)
    rise, named = {}, {}
    for row in rows:
        mine = [c for c in culprits.get(row, []) if on_upstream(repo, c[0], upstream_ref)]
        n = min(met[row] - before[row], sum(r for _, r, _ in mine))
        if n > 0:
            rise[row], named[row] = n, mine
    return rise, named


def update(repo: Path, rev: str = "HEAD", upstream_ref: str = UPSTREAM) -> int:
    """Rewrite plans/cmux-next/arch-ratchet.json from a full count at REV, the one writer of its totals.

    REV defaults to HEAD; a branch that changes no Swift may record its base on origin/feat-cmux-next
    (`--rev origin/feat-cmux-next`), so measured_sha survives the rebase that lands it.

    A ratcheted total may only go up by what the pending (not yet applied) dated exceptions allow. A larger
    rise that commits already on UPSTREAM_REF made (a GitHub merge, --no-verify: debt the person running this
    did not add) is a warning: it is recorded with a generated, applied entry that names those commits
    (`raised_by`; the record rule re-checks it, and it allows no rise in any push's code). Any other rise is
    refused with the commits that raised it. Every pending exception is folded in (applied_sha).
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
    pending = [e for e in exceptions if valid_exception(e, known) and not e.get("applied_sha") and not generated(e)]
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
    since = old.get("measured_sha")
    landed, named = upstream_rises(repo, since, sha, set(uncovered), before, upstream_ref) if uncovered else ({}, {})
    excess = {row_id: n - was - allow.get(row_id, 0) for row_id, (was, n) in uncovered.items()}
    local = {row_id: e - landed.get(row_id, 0) for row_id, e in excess.items() if e > landed.get(row_id, 0)}
    if local:
        culprits = raised_by(repo, since, sha, set(local)) if since else {}
        print(f"arch-ratchet: --update refused: {path.name} not written. These ratcheted totals rose past "
              f"the pending exceptions in commits that are not on {upstream_ref}:")
        for row_id, n in sorted(local.items()):
            was, total = uncovered[row_id]
            print(f"  {row_id}: recorded {was} at {str(since)[:11]}, now {total} (+{total - was}; pending exceptions "
                  f"allow {allow.get(row_id, 0)}" + (f", {landed[row_id]} already on {upstream_ref}" if landed.get(row_id) else "")
                  + ")")
            for c, r, t in culprits.get(row_id, []):
                print(f"    raised by {c[:11]} +{r} {t}")
            print(f"    fix the code, or (a reviewed reason only) add {exception_form(row_id, n)} to exceptions and "
                  "rerun --update")
        return 1
    for e in pending:
        e["applied_sha"] = sha
    today = datetime.date.today().isoformat()
    for row_id, n in sorted(excess.items()):
        shas = [c for c, _, _ in named[row_id]]
        print(f"arch-ratchet: WARNING: {row_id} rose {n} past the record in commits already on {upstream_ref} "
              f"(not this push's debt; recorded with a generated entry): "
              + "; ".join(f"{c[:11]} +{r} {t[:60]}" for c, r, t in named[row_id]))
        exceptions.append({"date": today, "row": row_id, "allow": n,
                           "why": f"generated by --update: the rise landed on {upstream_ref} past the hook",
                           "raised_by": shas, "applied_sha": sha})
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
        return update(repo, args.rev, args.upstream)
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
    try:
        push_range = load_push_range()
        own = (push_range.given_range(repo, args.base, head) if args.base
               else push_range.own_range(repo, head, [], args.upstream))
    except ValueError as error:
        print(f"arch-ratchet: {error}", file=sys.stderr)
        return 2
    print(f"arch-ratchet: judging {own.describe()}")
    return 1 if run_push(repo, [own], args.upstream) else 0


if __name__ == "__main__":
    sys.exit(main())
