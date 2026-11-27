// The transcript's one open-state store (docs/design/transcript-motion-model.md, "The owner, and what
// a row may no longer do": "`useDisclosure(key)`: the one open-state store. It gives `open` and
// `toggle`. The list reads the same store for its state signature and its estimate.").
//
// Before, five stores held what the reader opened, each with its own listeners or none: the line
// choices (transcriptDisclosureModel.ts, persisted), the messages opened (incomingOpened.ts), the
// thoughts opened (thoughtChoices.ts), the edited-files cards opened (turnChanges/openStore.ts) and
// the rows' own `runOpen` default. Now every one of them keeps its values here: one listener set, one
// revision, and one record of which rows a change touched (`rowRevision`), which is what the list's
// state signature for a row reads. The line choices keep their persisted map and their links
// (transcriptDisclosureModel.ts); the page-lifetime spaces live in `PageSpace` below. What any row
// shows is unchanged: each space reads and writes exactly what its old store did.
//
// No React here (the hook is useDisclosure.ts), so the estimators (model.ts) import it freely.

const listeners = new Set<() => void>();
let revision = 0;

/// Hears every change to any open state in the transcript.
export function subscribeDisclosure(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Grows by one on every change to any open state: a memo keyed by it re-reads the store.
export const disclosureRevision = (): number => revision;

/// The rows whose open state last changed, by `rowKey`, each with the revision it changed at. Bounded
/// (ROW_LIMIT): the oldest change is forgotten first.
const rowChanges = new Map<string, number>();
const ROW_LIMIT = 4000;

const rowKey = (sessionId: string | undefined, rowId: string) => `${sessionId ?? ""}\u0000${rowId}`;

/// The chat a disclosure session belongs to: a view's own toggles (`chat#thinking`) and the default
/// session are the chat's.
const chatOf = (sessionId: string | undefined): string => {
  if (!sessionId || sessionId === "__transcript__") return "";
  const view = sessionId.indexOf("#");
  return view < 0 ? sessionId : sessionId.slice(0, view);
};

/// The revision row `rowId` of chat `sessionId` last changed its open state at, or 0 when it never did
/// (as far as the bound reaches). A height drawn or estimated at another revision was taken in another
/// open state. O(1).
export function rowRevision(sessionId: string | undefined, rowId: string): number {
  // A change kept in no chat (a thought's, thoughtChoices.ts) counts for the row in every chat.
  return Math.max(rowChanges.get(rowKey(chatOf(sessionId), rowId)) ?? 0, rowChanges.get(rowKey("", rowId)) ?? 0);
}

/// Tells every listener the open state changed; `rows` (of chat `sessionId`) are the rows it changed.
export function notifyDisclosure(sessionId?: string, rows?: Iterable<string>): void {
  revision += 1;
  if (rows) {
    const chat = chatOf(sessionId);
    for (const id of rows) {
      const key = rowKey(chat, id);
      rowChanges.delete(key);
      rowChanges.set(key, revision);
    }
    while (rowChanges.size > ROW_LIMIT) rowChanges.delete(rowChanges.keys().next().value!);
  }
  // A snapshot: a listener that subscribes while this runs waits for the next change.
  for (const listener of Array.from(listeners)) listener();
}

/// The row a disclosure is drawn in, set by the transcript's row frame (useDisclosure.ts reads it
/// through React context; this is for code outside React, the row a change is credited to).
export type DisclosureRowRef = { sessionId?: string; rowId: string };

/// A page-lifetime space of the store: open choices by key, kept while the page lives (a row scrolled
/// out of the virtualized transcript and back keeps them). Map-like, so the old stores' callers keep
/// their calls; every write notifies the store's listeners once.
export class PageSpace {
  private readonly values = new Map<string, boolean>();
  /// `rowOf`: the row a key shows in, credited when a write names none.
  constructor(
    readonly name: string,
    private readonly rowOf?: (key: string) => string | undefined,
  ) {}
  private rowsFor(key: string, rows: Iterable<string> | undefined): Iterable<string> | undefined {
    if (rows) return rows;
    const row = this.rowOf?.(key);
    return row === undefined ? undefined : [row];
  }
  get size(): number {
    return this.values.size;
  }
  get(key: string): boolean | undefined {
    return this.values.get(key);
  }
  has(key: string): boolean {
    return this.values.has(key);
  }
  /// Sets `key`; `rows` are the rows of chat `sessionId` the change shows in.
  set(key: string, open: boolean, sessionId?: string, rows?: Iterable<string>): this {
    if (this.values.get(key) === open) return this;
    this.values.set(key, open);
    notifyDisclosure(sessionId, this.rowsFor(key, rows));
    return this;
  }
  delete(key: string, sessionId?: string, rows?: Iterable<string>): boolean {
    if (!this.values.delete(key)) return false;
    notifyDisclosure(sessionId, this.rowsFor(key, rows));
    return true;
  }
  /// Deletes every key `match` names, with one notification.
  deleteWhere(match: (key: string, open: boolean) => boolean): void {
    let changed = false;
    const touched: string[] = [];
    for (const [key, open] of this.values)
      if (match(key, open)) {
        this.values.delete(key);
        const row = this.rowOf?.(key);
        if (row !== undefined) touched.push(row);
        changed = true;
      }
    if (changed) notifyDisclosure(undefined, touched);
  }
  clear(): void {
    if (this.values.size === 0) return;
    this.values.clear();
    notifyDisclosure();
  }
  entries(): IterableIterator<[string, boolean]> {
    return this.values.entries();
  }
  keys(): IterableIterator<string> {
    return this.values.keys();
  }
  [Symbol.iterator](): IterableIterator<[string, boolean]> {
    return this.values.entries();
  }
}

/// The page-lifetime spaces, by name.
const spaces = new Map<string, PageSpace>();

/// The page space `name` (created on first use).
export function pageSpace(name: string, rowOf?: (key: string) => string | undefined): PageSpace {
  let space = spaces.get(name);
  if (!space) spaces.set(name, (space = new PageSpace(name, rowOf)));
  return space;
}

/** Test/gallery reset of every page space and the row record. */
export function resetPageSpaces(): void {
  for (const space of spaces.values()) space.clear();
  rowChanges.clear();
  notifyDisclosure();
}
