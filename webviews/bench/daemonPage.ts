// One page of a chat's records as acpmux reads it for `_acpmux/attach` and `_acpmux/events`
// (cmux-tui/crates/acpmux/src/hub/paging.rs `events_page`, newest first): the newest `limit`
// records before `beforeSeq`, which also ends before its records' JSON passes `maxBytes`
// (`page_bytes`: 1 MiB when the ask names none, at most 4 MiB), and always holds one record.
// The benches' stand-in daemons page with it, so a chat with MB tool outputs opens on the page the
// pane would get, not on 400 records of any size (a god session's were 1.2 MB against the pane's
// 128 KiB ask).

/// paging.rs DEFAULT_PAGE_BYTES and MAX_PAGE_BYTES.
export const DEFAULT_PAGE_BYTES = 1 << 20;
export const MAX_PAGE_BYTES = 4 << 20;

/// paging.rs `record_bytes`: a record's JSON and room for its envelope.
export const recordBytes = (record: unknown) => JSON.stringify(record).length + 120;

/// The newest page before `beforeSeq`, oldest first, and whether older records remain (pure).
export function newestPage<T extends { seq: number }>(
  events: readonly T[],
  { limit = 400, beforeSeq = Infinity, maxBytes }: { limit?: number; beforeSeq?: number; maxBytes?: number } = {},
): { page: T[]; hasMore: boolean } {
  const max = Math.min(maxBytes ?? DEFAULT_PAGE_BYTES, MAX_PAGE_BYTES);
  const page: T[] = [];
  let bytes = 0;
  let index = events.length - 1;
  while (index >= 0 && events[index]!.seq >= beforeSeq) index -= 1;
  for (; index >= 0; index -= 1) {
    const size = bytes + recordBytes(events[index]);
    // Full by count, or by size once it holds a record.
    if (page.length + 1 > limit || (page.length > 0 && size > max)) break;
    bytes = size;
    page.push(events[index]!);
  }
  return { page: page.reverse(), hasMore: index >= 0 };
}
