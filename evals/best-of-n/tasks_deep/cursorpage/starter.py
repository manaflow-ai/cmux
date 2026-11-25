"""Cursor pagination for the activity feed API.

Records are dicts with a unique "id" and a sort field (default "ts"). The feed is
ordered ascending by the sort field. Clients get opaque cursor strings and pass
them back as `after=` (the next page) or `before=` (the previous page). The list
of records can change between requests: events arrive and get deleted, so a
cursor names a position in the order, not an offset.
"""

import base64
import json


class BadCursor(ValueError):
    pass


class Page:
    def __init__(self, items, next_cursor, prev_cursor):
        self.items = items
        self.next_cursor = next_cursor
        self.prev_cursor = prev_cursor

    def ids(self):
        return [r["id"] for r in self.items]

    def __repr__(self):
        return "Page(%r, next=%r, prev=%r)" % (self.ids(), self.next_cursor, self.prev_cursor)


def encode_cursor(record, field):
    raw = json.dumps({"k": record[field]}, separators=(",", ":"))
    return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def decode_cursor(token):
    try:
        pad = "=" * (-len(token) % 4)
        data = json.loads(base64.urlsafe_b64decode(token + pad).decode())
        return data["k"]
    except (ValueError, KeyError, TypeError, UnicodeDecodeError) as exc:
        raise BadCursor("invalid cursor") from exc


def _ordered(records, field):
    return sorted(records, key=lambda r: r[field])


def _page_after(ordered, field, cursor, limit):
    if cursor is None:
        rest = ordered
    else:
        key = decode_cursor(cursor)
        rest = [r for r in ordered if r[field] > key]
    return rest[:limit], len(rest) > limit


def _page_before(ordered, field, cursor, limit):
    key = decode_cursor(cursor)
    rest = [r for r in ordered if r[field] < key]
    return rest[-limit:] if limit else [], len(rest) > limit


def paginate(records, limit, after=None, before=None, field="ts"):
    """One page of `records` in ascending order.

    With neither cursor: the first `limit` records. With `after`: the first
    `limit` records after that position. With `before`: the last `limit`
    records before that position (still in ascending order).
    """
    if limit < 1:
        raise ValueError("limit must be at least 1")
    if after is not None and before is not None:
        raise ValueError("pass after or before, not both")
    ordered = _ordered(records, field)
    if before is not None:
        items, more_before = _page_before(ordered, field, before, limit)
        prev_cursor = encode_cursor(items[0], field) if more_before else None
        next_cursor = encode_cursor(items[-1], field) if items else None
        return Page(items, next_cursor, prev_cursor)
    items, more_after = _page_after(ordered, field, after, limit)
    next_cursor = encode_cursor(items[-1], field) if len(items) == limit else None
    prev_cursor = encode_cursor(items[0], field) if after is not None and items else None
    return Page(items, next_cursor, prev_cursor)


def iterate(fetch, limit, field="ts"):
    """Yield every record by following next cursors; `fetch(after)` returns the current records."""
    cursor = None
    while True:
        page = paginate(fetch(cursor), limit, after=cursor, field=field)
        yield from page.items
        if page.next_cursor is None:
            return
        cursor = page.next_cursor
