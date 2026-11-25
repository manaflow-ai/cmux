Fix the pagination in `cursorpage.py`, the cursor paging behind our activity feed API.

Bug report: a bulk import wrote 40 events with the same `ts`. Paging through the feed 10 at a time, the second page
jumped straight to the first event with a later `ts`: 30 of the imported events never showed up in the client.

Contract:
- The feed order is ascending by the sort field, and records with equal sort values are ordered by `id` (ids are
  unique and comparable). Every record therefore has one position, and a cursor names the gap right after
  (`next_cursor`, passed back as `after=`) or right before (`prev_cursor`, passed back as `before=`) a record's
  position. A cursor stays valid when records are inserted or deleted, including the record it was made from.
- `after=c` returns the first `limit` records after that gap; `before=c` returns the last `limit` records before
  it, still in ascending order.
- In the records given to the call, `next_cursor` is `None` exactly when no record comes after the page's last
  item, and `prev_cursor` is `None` exactly when no record comes before its first item. An empty page has both `None`.
- Cursors stay opaque strings; keep the public API as it is.
