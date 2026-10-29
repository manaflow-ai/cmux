"""The queue janitor's two guards over every pass that cancels a run: one store of owed re-runs, and one read log.

Every cancelling pass of scripts/ci/queue_janitor.py (categories a-f, orphans, superseded delivery runs, the
dead-label re-dispatch in dead_labels.py) checks both before it cancels anything.

One obligation store (OwedStore). A cancel that owes a re-run writes its run into the store before or with the
cancel: category e and f's carried re-runs (LOST_KEY, plan_lost_reruns() settles them) and the dead-label pass's
(DEAD_KEY, dead_labels.resume() settles them). The two lists live in the janitor's pool snapshot under one cap
(CAP): a pass that would add an entry with the store full cancels nothing instead, and nothing is ever evicted or
cut. A run either list names is never cancelled again by any pass. The store is stamped into every snapshot the
sweep publishes (stamp()), as read, before anything is acted on; a list that could not be read is stamped as unread
(`<key>_unread`), never as empty, and read_store() passes over unread and missing copies to the newest one that has
it. While either list is unknown nothing that owes a re-run is cancelled.

One read log (ReadLog, READS). Any listing that fails anywhere in the sweep (a run's jobs, evidence runs, a branch
head, a delivery run's listing, the store itself) is noted; a pass about to cancel asks READS.hold() and, while
anything failed, cancels nothing: an unread run may be the one that would have shown a cancel wrong.
"""

from __future__ import annotations

import dataclasses
import io
import json
import sys
import zipfile
import zlib
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

LOST_KEY = "lost_reruns"
DEAD_KEY = "dead_label_reruns"
UNREAD_SUFFIX = "_unread"
# One cap across every list: category e's own bound (queue_janitor.LOST_PENDING_MAX), now shared.
CAP = 25
SNAPSHOT_UNREADABLE = (ValueError, KeyError, EOFError, NotImplementedError, zipfile.BadZipFile, zlib.error)


class ReadLog:
    """The sweep's failed listings. reset() at the start of a sweep; failed() as each fails; hold() before a cancel."""

    def __init__(self) -> None:
        self.failures: list[str] = []

    def reset(self) -> None:
        self.failures = []

    def failed(self, what: str, error: object = "") -> None:
        self.failures.append(what)
        print(f"queue-janitor: {what}{f': {error}' if error != '' else ''}", file=sys.stderr)

    def hold(self) -> str | None:
        """Why nothing may be cancelled now, or None."""
        if not self.failures:
            return None
        return (f"{len(self.failures)} listing(s) failed this sweep ({'; '.join(self.failures)[:200]}), so nothing "
                "is cancelled")


READS = ReadLog()


def _run_id(entry: Any) -> int | None:
    run_id = entry.get("run_id") if isinstance(entry, Mapping) else None
    return run_id if isinstance(run_id, int) and not isinstance(run_id, bool) else None


@dataclasses.dataclass
class OwedStore:
    """The owed re-runs, by key; a key's list is None while it could not be read."""
    lists: dict[str, list[dict[str, Any]] | None]
    cap: int = CAP

    @property
    def known(self) -> bool:
        return all(entries is not None for entries in self.lists.values())

    def entries(self, key: str) -> list[dict[str, Any]]:
        return list(self.lists.get(key) or [])

    def ids(self) -> set[int]:
        return {run_id for entries in self.lists.values() for entry in entries or () if (run_id := _run_id(entry))}

    def count(self) -> int:
        return sum(len(entries or ()) for entries in self.lists.values())

    def room(self) -> int:
        """How many more entries may be added: none while a list is unknown."""
        return max(0, self.cap - self.count()) if self.known else 0

    def set(self, key: str, entries: Iterable[Mapping[str, Any]]) -> None:
        self.lists[key] = [dict(entry) for entry in entries]

    def stamp(self, snapshot: dict[str, Any]) -> None:
        """Write every list into the snapshot as it stands: a known list whole, an unknown one as unread."""
        for key, entries in self.lists.items():
            if entries is None:
                snapshot.pop(key, None)
                snapshot[key + UNREAD_SUFFIX] = True
            else:
                snapshot.pop(key + UNREAD_SUFFIX, None)
                snapshot[key] = [dict(entry) for entry in entries]


def entries_in(documents: Iterable[Mapping[str, Any] | None], key: str) -> list[dict[str, Any]] | None:
    """KEY's list from the newest document that carries it. A document marked unread for KEY, or without it (a
    sweep that ended before writing it), is passed over. None (unknown) when none carries it and one was marked
    unread; [] when none carries it at all (before any sweep wrote it)."""
    marked = False
    for document in documents:
        if not isinstance(document, Mapping):
            continue
        if document.get(key + UNREAD_SUFFIX):
            marked = True
            continue
        entries = document.get(key)
        if isinstance(entries, list):
            return [dict(entry) for entry in entries if isinstance(entry, Mapping)]
    return None if marked else []


def read_store(artifacts: Sequence[Mapping[str, Any]], download: Callable[[Mapping[str, Any]], bytes],
               snapshot_file: str, keys: Sequence[str] = (LOST_KEY, DEAD_KEY), cap: int = CAP) -> OwedStore:
    """The store from the trusted snapshot artifacts (newest first), downloading each at most once and only as far
    back as a key needs. A download that fails raises (the caller then treats the store as unknown); an unreadable
    archive counts as a document without the keys."""
    cache: list[Mapping[str, Any] | None] = []

    def documents() -> Iterable[Mapping[str, Any] | None]:
        for index, artifact in enumerate(artifacts):
            if index == len(cache):
                blob = download(artifact)
                try:
                    cache.append(json.loads(zipfile.ZipFile(io.BytesIO(blob)).read(snapshot_file)))
                except SNAPSHOT_UNREADABLE:
                    cache.append(None)
            yield cache[index]

    return OwedStore({key: entries_in(documents(), key) for key in keys}, cap)
