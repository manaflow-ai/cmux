// The mounted transcript row of a given id, found in O(1): through the document's id index, never a
// query over the thread. A query for `.acpmux-row[data-row-id="…"]` matches every element under the
// thread, so each one a streamed update made (the follow chase's anchor row, the reply's height, the
// live line's pin) cost the elements of every mounted row: the history viewport above the view
// included (VirtualTranscript.tsx HISTORY_VIEWPORTS), about twice the rows in view in a chat of short
// turns (CMUX-571; Leo, 2026-11-12: "infinite everything feels like nothing").

/// The DOM id of a transcript row's article (VirtualTranscript.tsx `RowFrame`).
export const rowDomId = (id: string) => `acpmux-row-${encodeURIComponent(id)}`;

/// Threads whose rows carry their DOM id (`rowDomId`): the transcript's own. A thread built some other
/// way (a test's page, a turn fold's copy) is queried.
const indexed = new WeakSet<Element>();

/// Says that the rows of `thread` carry their DOM id, so `mountedRow` looks them up by it.
export function indexRowsById(thread: Element): void {
  indexed.add(thread);
}

/// The mounted row `id` among the rows directly under `thread`, or null. O(1) on the transcript's
/// thread; a row of the same id under another thread (the same chat in another pane) is looked for by
/// query there, as it was before.
export function mountedRow(thread: Element, id: string): HTMLElement | null {
  if (indexed.has(thread)) {
    const found = thread.ownerDocument.getElementById(rowDomId(id));
    if (!found) return null;
    if (found.parentElement === thread && found.dataset.rowId === id) return found;
  }
  const name = typeof CSS === "undefined" ? id.replace(/["\\]/g, "\\$&") : CSS.escape(id);
  return thread.querySelector<HTMLElement>(`:scope > .acpmux-row[data-row-id="${name}"]`);
}
