"""The settings store's write-ahead log: JSON-lines segments, and their compaction.

Every write appends one JSON object per line to the newest segment:

    {"seq": 41, "key": "theme", "value": "dark"}
    {"seq": 42, "key": "theme", "deleted": true}        # a tombstone

`seq` is a global, increasing write number handed out by `next_seq`. A segment
is a list of lines (str); a log is a list of segments. Segments are rotated by
size, uploaded, and later fetched back from the object store, which does not
promise to list them in the order they were written.

A record is a tombstone only when "deleted" is the JSON value true; a record
with any other "deleted" value (false, 1, "yes") is an ordinary write of its
"value". Records may carry other fields (a "ts", a writer id); compaction keeps
each surviving record whole.

Lines that are blank, are not valid JSON (a torn write at the end of a
segment after a crash), or lack an integer "seq" or a string "key", are
ignored by every reader here.
"""

import json


def _records(segments):
    """Every valid record, in segment order then line order."""
    for segment in segments:
        for line in segment:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            if not isinstance(rec.get("seq"), int) or isinstance(rec.get("seq"), bool):
                continue
            if not isinstance(rec.get("key"), str):
                continue
            yield rec


def is_tombstone(rec):
    return rec.get("deleted") is True


def _deciding(segments):
    """{key: deciding record}: highest seq; on a seq tie, the later one in log order."""
    winners = {}
    for rec in _records(segments):
        prev = winners.get(rec["key"])
        if prev is None or rec["seq"] >= prev["seq"]:
            winners[rec["key"]] = rec
    return winners


def compact(segments, keep_tombstones=False):
    """One segment holding only the record that decides each key, in seq order.

    With keep_tombstones=False, deleted keys disappear entirely. With
    keep_tombstones=True (compacting only the older part of a log, whose
    deletes must still shadow even older segments elsewhere), a key whose
    deciding record is a tombstone keeps that tombstone.
    """
    winners = _deciding(segments)
    out = [r for r in winners.values() if keep_tombstones or not is_tombstone(r)]
    out.sort(key=lambda r: r["seq"])
    return [json.dumps(r, sort_keys=True) for r in out]


def replay(segments):
    """The current {key: value} state the log describes."""
    return {k: r.get("value") for k, r in _deciding(segments).items() if not is_tombstone(r)}


def get(segments, key, default=None):
    """The current value of one key, or `default` when it is unset or deleted."""
    found = None
    for rec in _records(segments):
        if rec["key"] == key and (found is None or rec["seq"] >= found["seq"]):
            found = rec
    if found is None or is_tombstone(found):
        return default
    return found.get("value")


def next_seq(segments):
    """The seq for the next write: one past every seq in the log (1 for an empty log)."""
    top = None
    for rec in _records(segments):
        if top is None or rec["seq"] > top:
            top = rec["seq"]
    return 1 if top is None else top + 1


def append(segment, seq, key, value=None, deleted=False):
    """Append one record line to `segment` (a list) and return the line."""
    rec = {"seq": seq, "key": key}
    if deleted:
        rec["deleted"] = True
    else:
        rec["value"] = value
    line = json.dumps(rec, sort_keys=True)
    segment.append(line)
    return line


def obsolete(segments):
    """Indexes into `segments` of the segments a compaction made unnecessary, ascending.

    A segment is obsolete when none of its valid records decides its key (so a
    segment of only ignored lines is obsolete too).
    """
    best = {}
    for i, segment in enumerate(segments):
        for rec in _records([segment]):
            prev = best.get(rec["key"])
            if prev is None or rec["seq"] >= prev[0]:
                best[rec["key"]] = (rec["seq"], i)
    needed = {i for _, i in best.values()}
    return [i for i in range(len(segments)) if i not in needed]
