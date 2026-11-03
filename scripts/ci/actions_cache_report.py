#!/usr/bin/env python3
"""The Actions cache section of the CI health report: what the store holds, and
whether the cache steps hit.

Two questions nobody could answer without reading logs by hand (cmuxterm-hq#5230):
which cache keys miss, and which ones fill the store.

* **Store.** The repository's GitHub cache store, read from
  `/actions/caches` and `/actions/cache/usage`: its size against the default
  10 GB, the largest key prefixes, and how much of it sits on refs that only
  that ref and its own pull requests can read. Only runners outside Blacksmith
  (the owned minis) write here. On a Blacksmith runner, `actions/cache` goes to
  Blacksmith's own store next to the runner (25 GB per repository; entries
  unused for 7 days are evicted). The GitHub API cannot list that store.
* **Restores.** For a bounded sample of jobs that have a cache step, the
  report reads the job log and classifies each cache invocation from the lines
  the cache actions print: an exact hit, a prefix (restore-keys) hit, a miss,
  or a restore that failed (`Failed to restore`, at lookup or after downloading). It also counts saves refused
  because another job held the key ("Unable to reserve cache"). This works the
  same on either store, because the actions print the same lines.

Everything here is pure over text and JSON already fetched;
tests/test_actions_cache_report.py covers it with recorded log excerpts.
"""

from __future__ import annotations

import dataclasses
import json
import re
from collections import defaultdict
from collections.abc import Collection, Iterable, Mapping, Sequence
from typing import Any

GITHUB_STORE_LIMIT_BYTES = 10 * 1024**3
# Refs whose entries other runs read: the default branch (every branch can
# read it) and the NEXT base branch (its pull requests read it).
SHARED_REFS = ("refs/heads/main", "refs/heads/feat-cmux-next")
DEFAULT_LOG_SAMPLE = 20
MAX_STORE_PAGES = 5

_STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
_RUN_ACTION = re.compile(r"^##\[group\]Run (\S+@\S+|\./\S+)\s*$")
_RUN_ANY = re.compile(r"^##\[group\]Run ")
# The actions whose restore lines are read. Any other step (a build, a test,
# a local composite action whose own cache steps log their own groups) can
# print the same phrases, so its output never counts as a restore.
_CACHE_ACTION = re.compile(
    r"^(?:actions/cache(?:/restore|/save)?|warpbuilds/cache(?:/restore|/save)?|swatinem/rust-cache"
    r"|actions/setup-(?:node|go|python|java|dotnet)|mlugg/setup-zig|oven-sh/setup-bun)@"
)
_INPUT_KEY = re.compile(r"^  (key|primary-key): (\S+)")
_HEX = re.compile(r"^[0-9a-f]{8,}$")

# What the cache actions print. actions/cache and actions/cache/restore,
# Swatinem/rust-cache, actions/setup-go and setup-node all share @actions/cache.
_EXACT = (
    re.compile(r'Restored from cache key "([^"]+)" full match: true'),
    re.compile(r"Cache hit for: (\S+)"),
)
_PARTIAL = (re.compile(r'Restored from cache key "([^"]+)" full match: false'),)
_RESTORED_FROM = re.compile(r"Cache restored from key: (\S+)")
_MISS = (
    re.compile(r"Cache not found for input keys: ([^,\s]+)"),
    re.compile(r"^No cache found\.$"),
    re.compile(r"^Cache is not found$"),
)
_RESTORE_FAILED = re.compile(r"Failed to restore")
_SAVE_COLLISION = re.compile(r"Unable to reserve cache with key (\S+?),? another job")
_SAVED = re.compile(r"Cache saved with (?:the )?key: (\S+)")
# .github/actions/cache-restore prints one receipt per restore
# (scripts/ci/cache_restore_receipt.py). Its GitHub and Warp routes run a cache
# action that usually prints the lines above, so their receipts count only when
# that action printed no result (an unavailable cache service prints a warning
# and nothing else). The R2 route prints nothing else and always counts.
_RECEIPT = re.compile(r"^CMUX_CACHE_RESTORE (\{.*\})\s*$")
_RECEIPT_KINDS = {"exact": "exact", "prefix": "prefix", "miss_or_unavailable": "miss", "error": "failed"}
_RECEIPT_ROUTES = {"r2": "r2", "warp-cache": "warp", "github-cache": ""}
_RECEIPT_STEP = "scripts/ci/cache_restore_receipt.py"
_ACTION_ROUTED = ("actions/cache", "warpbuilds/cache")
# Setup actions that restore a cache when asked to (`cache: npm`, `cache: true`).
_SETUP_STEP = re.compile(r"\bset ?up[- ](?:node|go|python|java|dotnet)\b")
_JOB_CONCLUSIONS = ("success", "failure", "timed_out")


def key_prefix(key: str) -> str:
    """The key up to its first content hash, which names the cache, not the version."""
    parts = key.strip().split("-")
    kept: list[str] = []
    for part in parts:
        if _HEX.match(part.lower()) or (part.isdigit() and len(part) >= 9):
            break
        kept.append(part)
    return "-".join(kept) or key.strip()


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class PrefixRow:
    prefix: str
    entries: int = 0
    size: int = 0
    unshared_size: int = 0
    refs: set[str] = dataclasses.field(default_factory=set)
    last_used: str = ""


@dataclasses.dataclass(frozen=True)
class StoreSummary:
    total_size: int
    entries: int
    listed: int
    unshared_size: int
    prefixes: list[PrefixRow]
    listed_size: int = 0


def summarize_store(entries: Iterable[Mapping[str, Any]], usage: Mapping[str, Any] | None) -> StoreSummary:
    rows: dict[str, PrefixRow] = {}
    listed = 0
    listed_size = 0
    unshared = 0
    for entry in entries:
        listed += 1
        size = int(entry.get("size_in_bytes") or 0)
        ref = str(entry.get("ref") or "")
        prefix = key_prefix(str(entry.get("key") or ""))
        row = rows.setdefault(prefix, PrefixRow(prefix))
        row.entries += 1
        row.size += size
        row.refs.add(ref)
        last = str(entry.get("last_accessed_at") or "")
        row.last_used = max(row.last_used, last)
        listed_size += size
        if ref not in SHARED_REFS:
            row.unshared_size += size
            unshared += size
    usage = usage or {}
    total = int(usage.get("active_caches_size_in_bytes") or listed_size)
    # The usage endpoint has been seen answering a count of 0 next to a real
    # size, so the count falls back to what was listed.
    count = int(usage.get("active_caches_count") or 0) or listed
    ordered = sorted(rows.values(), key=lambda row: (-row.size, row.prefix))
    return StoreSummary(
        total_size=total, entries=count, listed=listed, unshared_size=unshared, prefixes=ordered, listed_size=listed_size
    )


# ---------------------------------------------------------------------------
# Restores, from job logs
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class _Invocation:
    action: str
    key: str = ""
    restored: str = ""
    outcome: str = ""
    failed: bool = False
    awaiting_cache_key: bool = False

    def label(self) -> str:
        if self.key:
            return key_prefix(self.key)
        if self.restored:
            return key_prefix(self.restored)
        return f"{self.action.split('@')[0]} (key not printed)"

    def result(self) -> str | None:
        if self.failed:
            return "failed"
        if self.outcome == "hit" and self.key and self.restored and self.restored != self.key:
            return "prefix"
        return self.outcome or None


@dataclasses.dataclass(frozen=True)
class CacheEvent:
    label: str
    kind: str  # exact | prefix | miss | failed | collision | saved


def _strip(line: str) -> str:
    return _STAMP.sub("", line.rstrip("\r\n"), count=1)


def parse_job_log(text: str) -> list[CacheEvent]:
    """Each cache restore in one job's log, plus its saves refused or done."""
    events: list[CacheEvent] = []
    current: _Invocation | None = None
    # Whether the last routed cache action (see _ACTION_ROUTED) printed a
    # result; None until one runs, and again once a receipt has used it.
    routed_printed: bool | None = None
    # Post-job steps print no group header, only "Post job cleanup.", and that
    # is where the cache actions save.
    in_post = False
    # Receipts count only from the cache-restore action's own receipt step.
    in_receipt_step = False

    def close() -> None:
        nonlocal routed_printed
        if current is not None:
            kind = current.result()
            if kind:
                events.append(CacheEvent(current.label(), "exact" if kind == "hit" else kind))
            if current.action.lower().startswith(_ACTION_ROUTED):
                routed_printed = bool(kind)

    for raw in text.splitlines():
        line = _strip(raw)
        if _RUN_ANY.match(line):
            close()
            in_post = False
            in_receipt_step = _RECEIPT_STEP in line
            match = _RUN_ACTION.match(line)
            action = match.group(1) if match else ""
            current = _Invocation(action) if _CACHE_ACTION.match(action.lower()) else None
            continue
        if line == "Post job cleanup.":
            close()
            current = None
            in_post = True
        receipt = _RECEIPT.match(line) if in_receipt_step else None
        if receipt:
            try:
                record = json.loads(receipt.group(1))
            except ValueError:
                record = {}
            route = _RECEIPT_ROUTES.get(str(record.get("action_route")))
            kind = _RECEIPT_KINDS.get(str(record.get("result")))
            if route != "r2":
                counts, routed_printed = routed_printed is False, None
            else:
                counts = True
            if route is not None and counts and kind and record.get("key"):
                label = key_prefix(str(record["key"]))
                events.append(CacheEvent(f"{label} ({route})" if route else label, kind))
            continue
        saving = current is not None or in_post
        collision = _SAVE_COLLISION.search(line) if saving else None
        if collision:
            events.append(CacheEvent(key_prefix(collision.group(1)), "collision"))
            continue
        saved = _SAVED.search(line) if saving else None
        if saved:
            events.append(CacheEvent(key_prefix(saved.group(1)), "saved"))
            continue
        if current is None:
            continue
        if current.awaiting_cache_key:
            current.awaiting_cache_key = False
            if line.strip():
                current.key = line.strip()
            continue
        if line == "Cache Key:":
            current.awaiting_cache_key = True
            continue
        key_input = _INPUT_KEY.match(line)
        if key_input and not current.key:
            current.key = key_input.group(2)
            continue
        if _RESTORE_FAILED.search(line):
            current.failed = True
            continue
        hit = next((m for m in (p.search(line) for p in _EXACT) if m), None)
        if hit:
            current.outcome, current.restored = "hit", hit.group(1)
            continue
        partial = next((m for m in (p.search(line) for p in _PARTIAL) if m), None)
        if partial:
            current.outcome, current.restored = "prefix", partial.group(1)
            continue
        restored = _RESTORED_FROM.search(line)
        if restored:
            current.outcome, current.restored = "hit", restored.group(1)
            continue
        miss = next((m for m in (p.search(line) for p in _MISS) if m), None)
        if miss and current.outcome != "hit":
            current.outcome = "miss"
            if miss.groups() and not current.key:
                current.key = miss.group(1)
    close()
    return events


@dataclasses.dataclass
class RestoreRow:
    workflow: str
    label: str
    jobs: set[int] = dataclasses.field(default_factory=set)
    exact: int = 0
    prefix: int = 0
    miss: int = 0
    failed: int = 0
    collision: int = 0
    saved: int = 0

    @property
    def restores(self) -> int:
        return self.exact + self.prefix + self.miss + self.failed

    @property
    def hit_rate(self) -> float | None:
        return (self.exact + self.prefix) / self.restores if self.restores else None


def aggregate_restores(sampled: Iterable[tuple[str, int, Sequence[CacheEvent]]]) -> list[RestoreRow]:
    """Rows per (workflow, cache), worst hit rate first."""
    rows: dict[tuple[str, str], RestoreRow] = {}
    for workflow, job_id, events in sampled:
        for event in events:
            row = rows.setdefault((workflow, event.label), RestoreRow(workflow, event.label))
            row.jobs.add(job_id)
            setattr(row, event.kind, getattr(row, event.kind) + 1)

    def order(row: RestoreRow) -> tuple[float, int, str, str]:
        rate = row.hit_rate
        return (rate if rate is not None else 2.0, -row.restores, row.workflow, row.label)

    return sorted(rows.values(), key=order)


NOT_CACHE_JOB, SETUP_ONLY_JOB, CACHE_STEP_JOB = 0, 1, 2


def is_cache_job(job: Mapping[str, Any]) -> int:
    """How a finished job qualifies for the log sample: CACHE_STEP_JOB when a
    step's name says it restores or caches, SETUP_ONLY_JOB when only a setup
    action that may restore a cache ran (most run without one, so these fill
    the sample last), NOT_CACHE_JOB otherwise."""
    if job.get("conclusion") not in _JOB_CONCLUSIONS:
        return NOT_CACHE_JOB
    rank = NOT_CACHE_JOB
    for step in job.get("steps") or ():
        name = str(step.get("name") or "").lower()
        if step.get("conclusion") in ("skipped", None):
            continue
        if "cache" in name or "restore" in name:
            return CACHE_STEP_JOB
        if _SETUP_STEP.search(name):
            rank = SETUP_ONLY_JOB
    return rank


def choose_log_jobs(
    candidates: Sequence[tuple[str, str, int]], cap: int, deferred: Collection[int] = ()
) -> list[tuple[str, str, int]]:
    """Up to `cap` jobs, one per (workflow, job name) per round, newest first.
    Jobs in `deferred` (setup-only jobs) only fill what the others leave."""
    chosen: list[tuple[str, str, int]] = []
    for tier in (
        [c for c in candidates if c[2] not in deferred],
        [c for c in candidates if c[2] in deferred],
    ):
        groups: dict[tuple[str, str], list[tuple[str, str, int]]] = defaultdict(list)
        for candidate in tier:
            groups[(candidate[0], candidate[1])].append(candidate)
        depth = 0
        while len(chosen) < cap and any(len(group) > depth for group in groups.values()):
            for key in sorted(groups):
                if len(groups[key]) > depth and len(chosen) < cap:
                    chosen.append(groups[key][depth])
            depth += 1
    return chosen


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _gb(size: int) -> str:
    return f"{size / 1024**3:.2f}"


def _esc(value: str) -> str:
    """Safe inside a table cell and a code span: log text cannot end the row or the span."""
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value)
    return value.replace("`", "'").replace("|", "\\|")


def _note_esc(value: str) -> str:
    """Notes carry error text from the network: one line, no Markdown of its own."""
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value).replace("`", "'")
    return re.sub(r"([\\*_\[\]<>|#~!])", r"\\\1", value)


def render_section(
    store: StoreSummary | None,
    restores: Sequence[RestoreRow],
    *,
    sampled_logs: int,
    notes: Sequence[str] = (),
    limit: int = 12,
) -> list[str]:
    lines = ["### Actions cache", ""]
    if store is not None:
        used = store.total_size / GITHUB_STORE_LIMIT_BYTES * 100
        lines.append(
            f"**GitHub store:** {_gb(store.total_size)} GB of the default {_gb(GITHUB_STORE_LIMIT_BYTES)} GB "
            f"({used:.0f}%), {store.entries} entries. {_gb(store.unshared_size)} GB of the "
            f"{store.listed} listed sits on refs other than {', '.join(f'`{r}`' for r in SHARED_REFS)}: "
            "only that ref and its own pull requests can read it, and the store evicts by "
            "least-recent use once full. Only runners outside Blacksmith write here; Blacksmith "
            "runners use Blacksmith's own store, which this API does not list."
        )
        if store.listed < store.entries:
            lines.append("")
            lines.append(
                f"_{store.listed} of {store.entries} entries listed (largest first), so the other-ref share is a "
                f"lower bound: {_gb(max(store.total_size - store.listed_size, 0))} GB is unlisted._"
            )
        lines.append("")
        if store.prefixes:
            lines.append("| Key prefix | entries | GB | GB on other refs | refs | last used |")
            lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
            for row in store.prefixes[:limit]:
                lines.append(
                    f"| `{_esc(row.prefix)}` | {row.entries} | {_gb(row.size)} | {_gb(row.unshared_size)} | "
                    f"{len(row.refs)} | {row.last_used[:16].replace('T', ' ')} |"
                )
            lines.append("")
    lines.append(
        f"**Restores (sampled from {sampled_logs} job logs, either store):** exact and prefix are hits; "
        "failed means the cache step printed `Failed to restore`, at lookup or after the entry downloaded; collisions are saves refused because "
        "another job held the key."
    )
    lines.append("")
    if restores:
        lines.append("| Workflow | cache | jobs | restores | exact | prefix | miss | failed | hit rate | collisions |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for row in restores[:limit]:
            rate = "-" if row.hit_rate is None else f"{row.hit_rate * 100:.0f}%"
            lines.append(
                f"| {_esc(row.workflow)} | `{_esc(row.label)}` | {len(row.jobs)} | {row.restores} | {row.exact} | "
                f"{row.prefix} | {row.miss} | {row.failed} | {rate} | {row.collision} |"
            )
    else:
        lines.append("_No cache restores in the sampled logs._")
    lines.append("")
    for note in notes:
        lines.append(f"_{_note_esc(note)}_")
        lines.append("")
    return lines
