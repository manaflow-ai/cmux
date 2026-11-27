// A chat's rows on the page with `chat` on: a window of the rows the daemon rendered, kept as a
// map by rowId and the ids in order, per sid. No history, no rebuild, no clear: a window swaps the
// rows in one step, an op replaces one row, a page adds a stretch at an edge, and past the cap the
// stretch farthest from where the person reads is let go (a page brings it back). The wire's
// rules stay in Rust: this keeps no cursor and no credit, compares no edition and asks for nothing.
// The field table (FIELDS.md) says what of a chat's view comes from here.
import type {
  ChatBlobHead,
  ChatChange,
  ChatOp,
  ChatOpenRow,
  ChatPageResult,
  ChatQueueHead,
  ChatRow,
  ChatWindow,
} from "./wire";
import { changeSid } from "./wire";

/// The most rows and row bytes one sid holds: four of the core's bounds on a window or a page
/// (acpmux-client chat.rs MAX_CHAT_ROWS, 400 rows; wire.rs MAX_PAGE_BYTES, 256 KiB). That is the
/// window a chat opens with, a page each side of it, and the page in flight, so a page merged at
/// one edge never lets go of what the person was reading at the other. Open rows (at most 64)
/// are not counted: the store holds every one (decision 243).
export const STORE_MAX_ROWS = 1_600;
export const STORE_MAX_BYTES = 4 * 256 * 1024;
/// The most bytes of whole blob bodies (a 5 MB tool output read for the view) one sid keeps, the
/// least recently read let go first: a body is read again on demand, so the cap costs one read.
export const STORE_MAX_BLOB_BYTES = 4 * 1024 * 1024;

/// One row as held. `row` is null for a hole: a row whose record a read refused, kept in its place
/// with its size (`est`, the lines of the row it stood for, 1 when none was held).
export type ChatRowEntry = {
  readonly id: number;
  readonly rev: number;
  readonly row: ChatRow | null;
  /// The body's length when the daemon left an open row's body out (read by `blob`).
  readonly bodyLen?: number;
  readonly est: number;
  /// Held outside the last window's range and not covered by a page since.
  readonly unconfirmed?: true;
  readonly refused?: true;
  /// Rows are missing between the entry before this one and this one: the store holds two
  /// stretches (a window in place of a resume, or a page that did not reach the other). A page
  /// before from this row's id fills it.
  readonly gapBefore?: true;
};

export type ChatAnchor = "end" | { rowId: number; side: "before" | "after" | "around" };

/// What a subscriber draws. A new object only when something in it changed; a row that did not
/// change keeps its entry's identity, so the list renders one row for one op.
export type ChatRowsSnapshot = {
  readonly sid: string;
  /// In rowId order, which is the order the page draws.
  readonly rows: readonly ChatRowEntry[];
  /// Open rows past the rows held (decision 243): the stretch does not reach them, so they are
  /// drawn apart from `rows`, in rowId order. They join `rows` when a page reaches them.
  readonly apart: readonly ChatRowEntry[];
  readonly hasBefore: boolean;
  readonly hasAfter: boolean;
  readonly queue: ChatQueueHead;
  readonly seen: number | undefined;
  readonly folds: readonly number[];
  /// Whole blob bodies by target (`row:<rowId>` or `prompt:<id>`): a row's parsed body JSON, a
  /// prompt's text.
  readonly bodies: ReadonlyMap<string, unknown>;
  /// False until the first window: nothing to draw yet, and nothing was cleared.
  readonly ready: boolean;
};

/// Why a chat falls to v1 (decision 225): an `open` the host refused, or a `sub` error other
/// than `not_ready`.
export type ChatFall = { sid: string; code: string };

export type BlobTarget = { rowId: number } | { prompt: string };
export const blobKey = (target: BlobTarget): string =>
  "rowId" in target ? `row:${target.rowId}` : `prompt:${target.prompt}`;

type PageAsk = { side: "before" | "after"; rowId: number; fold?: number };
type Assembly = { parts: string[]; nextStart: number; gen?: string };
type BlobAsk = { key: string; rowId?: number };
type Mutable<T> = { -readonly [K in keyof T]: T[K] };

const EMPTY_QUEUE: ChatQueueHead = Object.freeze({ entries: [], count: 0 }) as ChatQueueHead;
const NO_FOLDS: readonly number[] = Object.freeze([]);
const NO_ENTRIES: readonly ChatRowEntry[] = Object.freeze([]);
const NO_BODIES: ReadonlyMap<string, unknown> = new Map();
// The core keeps at most 64 queue entries in a head (wire.rs QueueHead).
const QUEUE_HEAD_MAX = 64;

const entryBytes = (entry: ChatRowEntry): number => (entry.row ? JSON.stringify(entry.row).length : 16);
const isOpen = (entry: ChatRowEntry | undefined): boolean => entry?.row?.open === true;

function entryOf(row: ChatRow, bodyLen?: number): ChatRowEntry {
  const entry: Mutable<ChatRowEntry> = { id: row.id, rev: row.rev, row, est: row.est };
  if (bodyLen !== undefined) entry.bodyLen = bodyLen;
  return entry;
}

function hole(id: number, held: ChatRowEntry | undefined): ChatRowEntry {
  return { id, rev: held?.rev ?? 0, row: null, est: held?.est ?? 1, refused: true };
}

function marked(entry: ChatRowEntry, gap: boolean): ChatRowEntry {
  const next: Mutable<ChatRowEntry> = { ...entry };
  if (gap) next.gapBefore = true;
  else delete next.gapBefore;
  return next;
}

/// The index of the first id in `ids` at or above `id`.
function lowerBound(ids: readonly number[], id: number): number {
  let lo = 0;
  let hi = ids.length;
  // ends: binary search: each pass halves hi - lo
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (ids[mid]! < id) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/// One sid's rows.
class SidRows {
  readonly sid: string;
  anchor: ChatAnchor;
  private entries = new Map<number, ChatRowEntry>();
  private ids: number[] = [];
  /// Each entry's bytes, kept so a text op adds its delta instead of measuring the row again.
  private sizes = new Map<number, number>();
  private bytes = 0;
  /// Open rows past the stretch (decision 243), by id.
  private apart = new Map<number, ChatRowEntry>();
  private hasBefore = false;
  private hasAfter = false;
  private queue: ChatQueueHead = EMPTY_QUEUE;
  private seen: number | undefined;
  private folds: readonly number[] = NO_FOLDS;
  private ready = false;
  /// A resume's ops, applied in one step at its end.
  private replayed: ChatOp[] = [];
  private page: PageAsk | null = null;
  private assemblies = new Map<string, Assembly>();
  private bodies = new Map<string, { value: unknown; bytes: number }>();
  private bodyBytes = 0;
  private blobAsks = new Map<string, BlobAsk>();
  private snapshot: ChatRowsSnapshot;
  private rowsChanged = false;
  private apartChanged = false;
  private bodiesChanged = false;
  private changed = false;

  constructor(sid: string, anchor: ChatAnchor) {
    this.sid = sid;
    this.anchor = anchor;
    this.snapshot = this.build(true, true, true);
  }

  get current(): ChatRowsSnapshot {
    return this.snapshot;
  }

  /// The row a page before or after asks from: the edge of the stretch that holds the anchor.
  /// Null with nothing held.
  edge(side: "before" | "after"): number | null {
    const count = this.ids.length;
    if (!count) return null;
    const anchor = this.anchor;
    let at = anchor === "end" ? count - 1 : Math.min(lowerBound(this.ids, anchor.rowId), count - 1);
    if (side === "before") {
      // ends: `at` falls by one each pass, to 0 at most
      while (at > 0 && !this.entries.get(this.ids[at]!)!.gapBefore) at -= 1;
    } else {
      // ends: `at` rises by one each pass, to count - 1 at most
      while (at + 1 < count && !this.entries.get(this.ids[at + 1]!)!.gapBefore) at += 1;
    }
    return this.ids[at]!;
  }

  pageAsked(ask: PageAsk): void {
    this.page = ask;
  }

  pageOut(): boolean {
    return this.page !== null;
  }

  blobAsked(id: string, target: BlobTarget): void {
    this.blobAsks.set(id, { key: blobKey(target), rowId: "rowId" in target ? target.rowId : undefined });
  }

  blobFailed(id: string): void {
    this.blobAsks.delete(id);
  }

  apply(change: ChatChange): void {
    switch (change.kind) {
      case "chatWindow":
        return this.window(change.replaces, change.window);
      case "chatOp":
        if (change.replay) this.replayed.push(change.op);
        else this.op(change.op);
        return;
      case "chatResumeEnd": {
        const replayed = this.replayed;
        this.replayed = [];
        for (const op of replayed) this.op(op);
        return;
      }
      case "chatPage":
        return this.merge(change.page);
      case "chatBlob":
        return this.blob(change);
      case "chatDropped":
        // The core subscribed again under the same sid; what follows is a resume or a window.
        return;
      case "chatError":
        if (change.method === "page") this.page = null;
        else if (change.method === "blob" && change.id) this.blobFailed(change.id);
        return;
    }
  }

  /// Ends a batch: lets go past the cap, then makes the new snapshot if anything changed.
  settle(): ChatRowsSnapshot | null {
    if (!this.changed) return null;
    this.trim();
    this.snapshot = this.build(this.rowsChanged, this.apartChanged, this.bodiesChanged);
    this.changed = this.rowsChanged = this.apartChanged = this.bodiesChanged = false;
    return this.snapshot;
  }

  /// What the store holds, for the held gate: rows and row bytes (open rows apart included), and
  /// the blob bodies' bytes.
  held(): { rows: number; bytes: number; blobBytes: number } {
    let bytes = this.bytes;
    for (const entry of this.apart.values()) bytes += entryBytes(entry);
    return { rows: this.ids.length + this.apart.size, bytes, blobBytes: this.bodyBytes };
  }

  private touchRows(): void {
    this.changed = this.rowsChanged = true;
  }

  private touchApart(): void {
    this.changed = this.apartChanged = true;
  }

  /// Holds `entry` in the stretch. A gap before the row it replaces stays; `size` is its bytes
  /// when the caller knows them.
  private put(entry: ChatRowEntry, size = entryBytes(entry)): void {
    const was = this.entries.get(entry.id);
    if (was) {
      this.bytes -= this.sizes.get(entry.id)!;
      if (was.gapBefore && !entry.gapBefore) entry = marked(entry, true);
    } else this.ids.splice(lowerBound(this.ids, entry.id), 0, entry.id);
    if (this.apart.delete(entry.id)) this.touchApart();
    this.entries.set(entry.id, entry);
    this.sizes.set(entry.id, size);
    this.bytes += size;
    this.touchRows();
  }

  private remove(id: number): void {
    const at = lowerBound(this.ids, id);
    if (this.ids[at] !== id) return;
    this.ids.splice(at, 1);
    this.bytes -= this.sizes.get(id)!;
    this.sizes.delete(id);
    this.entries.delete(id);
    this.assemblies.delete(`row:${id}`);
    this.touchRows();
  }

  private setGap(id: number, gap: boolean): void {
    const entry = this.entries.get(id);
    if (!entry || Boolean(entry.gapBefore) === gap) return;
    this.entries.set(id, marked(entry, gap));
    this.touchRows();
  }

  private holdApart(entry: ChatRowEntry): void {
    this.apart.set(entry.id, entry.gapBefore ? marked(entry, false) : entry);
    this.touchApart();
  }

  private inside(id: number): boolean {
    const count = this.ids.length;
    return count > 0 && this.ids[0]! <= id && id <= this.ids[count - 1]!;
  }

  /// Open rows held apart join the stretch once it reaches them: inside it, or past an end that
  /// has nothing more (a page after that answered `hasAfter: false`).
  private joinApart(): void {
    if (!this.apart.size) return;
    const first = this.ids[0];
    const last = this.ids[this.ids.length - 1];
    // `put` deletes the entry it joins: a Map's iteration skips nothing it has not reached yet.
    for (const entry of this.apart.values()) {
      const id = entry.id;
      const joins =
        first === undefined || last === undefined
          ? !this.hasBefore && !this.hasAfter
          : (first <= id && id <= last) || (id > last && !this.hasAfter) || (id < first && !this.hasBefore);
      if (joins) this.put(entry);
    }
  }

  private window(replaces: boolean, window: ChatWindow): void {
    // A window in place of a resume: the ops held for it are behind what it holds.
    this.replayed = [];
    const incoming: ChatRowEntry[] = window.rows.map((row) => entryOf(row));
    for (const open of window.open ?? []) incoming.push(openEntry(open));
    for (const id of window.refused ?? []) incoming.push(hole(id, this.entries.get(id)));
    if (replaces || !this.ready) {
      // In one step: the old rows are there until the new ones are.
      this.entries = new Map(incoming.map((entry) => [entry.id, entry]));
      this.ids = [...this.entries.keys()].sort((a, b) => a - b);
      this.sizes = new Map();
      this.bytes = 0;
      for (const entry of this.entries.values()) {
        const size = entryBytes(entry);
        this.sizes.set(entry.id, size);
        this.bytes += size;
      }
      if (this.apart.size) this.touchApart();
      this.apart.clear();
      this.hasBefore = window.hasBefore;
      this.hasAfter = window.hasAfter;
      this.page = null;
    } else {
      const ids = incoming.map((entry) => entry.id);
      const lo = ids.length ? Math.min(...ids) : Infinity;
      const hi = ids.length ? Math.max(...ids) : -Infinity;
      const fresh = new Set(ids);
      // A window that holds none of the rows held does not reach them: what lies between is
      // missing, unless the window says nothing does.
      const reaches = ids.some((id) => this.entries.has(id));
      const below = this.ids.length > 0 && this.ids[0]! < lo;
      const aboveAt = lowerBound(this.ids, hi + 1);
      const above = aboveAt < this.ids.length ? this.ids[aboveAt]! : undefined;
      // Rows held that this window does not hold stay, unconfirmed until a page covers them.
      for (const [id, entry] of this.entries)
        if (!fresh.has(id) && !entry.unconfirmed) this.entries.set(id, { ...entry, unconfirmed: true });
      for (const entry of incoming) this.put(entry);
      if (ids.length && !reaches) {
        if (below && window.hasBefore) this.setGap(lo, true);
        if (above !== undefined && window.hasAfter) this.setGap(above, true);
      }
      const first = this.ids[0];
      const last = this.ids[this.ids.length - 1];
      if (first === undefined || first >= lo) this.hasBefore = window.hasBefore;
      if (last === undefined || last <= hi) this.hasAfter = window.hasAfter;
    }
    this.queue = window.queue ?? EMPTY_QUEUE;
    this.seen = window.seen;
    this.folds = window.folds?.length ? window.folds : NO_FOLDS;
    this.ready = true;
    this.joinApart();
    this.touchRows();
  }

  private op(op: ChatOp): void {
    switch (op.op) {
      case "row": {
        const id = op.row.id;
        const held = this.entries.get(id);
        if (held) {
          if (held.row && held.rev > op.row.rev) return;
          this.put(entryOf(op.row, op.bodyLen));
          return;
        }
        const apart = this.apart.get(id);
        if (apart) {
          if (apart.row && apart.rev > op.row.rev) return;
          if (op.row.open) this.holdApart(entryOf(op.row, op.bodyLen));
          else {
            // Settled past the stretch: a page brings it. Inside the stretch it is the stretch's.
            this.apart.delete(id);
            this.touchApart();
            if (this.inside(id)) this.put(entryOf(op.row, op.bodyLen));
          }
          return;
        }
        // Not held: only an append at the tail the store shows. Anything else is a stretch the
        // store does not hold, and a page brings it; a row that opens past the stretch is held
        // apart (decision 243).
        const last = this.ids[this.ids.length - 1];
        if (!this.ready || (last !== undefined && id < last)) return;
        if (!this.hasAfter) this.put(entryOf(op.row, op.bodyLen));
        else if (op.row.open) this.holdApart(entryOf(op.row, op.bodyLen));
        return;
      }
      case "patch": {
        const held = this.entries.get(op.row.id);
        if (held) {
          if (!held.row || held.rev < op.row.rev) this.put(entryOf(op.row));
          return;
        }
        const apart = this.apart.get(op.row.id);
        if (apart && (!apart.row || apart.rev < op.row.rev)) this.holdApart(entryOf(op.row));
        return;
      }
      case "text": {
        const inStretch = this.entries.get(op.rowId);
        const held = inStretch ?? this.apart.get(op.rowId);
        const row = held?.row;
        if (!held || !row?.open) return;
        const body = row.body as { text?: unknown } | null;
        // A body left out (`bodyLen`) is not held here: a blob read gives it, text included.
        if (held.bodyLen !== undefined || !body || typeof body !== "object" || typeof body.text !== "string") return;
        const next = { ...held, row: { ...row, body: { ...body, text: body.text + op.text } } };
        if (!inStretch) return this.holdApart(next);
        // JSON escapes each character alone, so the row grows by the piece's escaped length.
        this.put(next, this.sizes.get(op.rowId)! + JSON.stringify(op.text).length - 2);
        return;
      }
      case "queue": {
        let entries = this.queue.entries;
        if (op.head) entries = op.head.entries;
        if (op.removed !== undefined) entries = entries.filter((item) => item.id !== op.removed);
        if (op.entry) {
          const entry = op.entry;
          const at = entries.findIndex((item) => item.id === entry.id);
          if (at >= 0) entries = entries.map((item, index) => (index === at ? entry : item));
          else if (entries.length < QUEUE_HEAD_MAX) entries = [...entries, entry];
        }
        this.queue = { entries, count: op.count };
        this.changed = true;
        return;
      }
    }
  }

  private merge(page: ChatPageResult): void {
    const ask = this.page;
    this.page = null;
    if (!ask || !this.ready) return;
    const given = [...page.rows.map((row) => row.id), ...(page.refused ?? [])];
    const reaches = given.some((id) => this.entries.has(id));
    const low = given.length ? Math.min(...given) : undefined;
    const high = given.length ? Math.max(...given) : undefined;
    // What the page speaks for: a fold's page its own rows; a page before, from its first row up
    // to the row asked from; a page after, from that row to its last.
    let lo: number;
    let hi: number;
    if (ask.fold !== undefined) {
      lo = low ?? Infinity;
      hi = high ?? -Infinity;
    } else if (ask.side === "before") {
      lo = low ?? (page.hasBefore ? ask.rowId : -Infinity);
      hi = ask.rowId - 1;
    } else {
      lo = ask.rowId + 1;
      hi = high ?? (page.hasAfter ? ask.rowId : Infinity);
    }
    // A row held there that the page neither gives nor refuses is gone, unless a window or page
    // since has held it.
    const kept = new Set(given);
    const stale: number[] = [];
    for (let at = lowerBound(this.ids, lo); at < this.ids.length && this.ids[at]! <= hi; at += 1) {
      const id = this.ids[at]!;
      if (!kept.has(id) && this.entries.get(id)!.unconfirmed) stale.push(id);
    }
    for (const id of stale) this.remove(id);
    for (const row of page.rows) {
      const held = this.entries.get(row.id);
      if (held && held.row && held.rev === row.rev && !held.unconfirmed && !held.refused) continue;
      this.put(entryOf(row));
    }
    for (const id of page.refused ?? []) this.put(hole(id, this.entries.get(id)));
    // The page covers its range: what it held there is confirmed.
    for (let at = lowerBound(this.ids, lo); at < this.ids.length && this.ids[at]! <= hi; at += 1) {
      const entry = this.entries.get(this.ids[at]!)!;
      if (entry.unconfirmed) {
        const confirmed: Mutable<ChatRowEntry> = { ...entry };
        delete confirmed.unconfirmed;
        this.entries.set(entry.id, confirmed);
      }
    }
    if (ask.fold === undefined) {
      // A page runs on from the row asked from: nothing is missing inside it.
      for (const id of given) this.setGap(id, false);
      if (ask.side === "before") {
        if (low !== undefined || !page.hasBefore) this.setGap(ask.rowId, false);
        const edge = low ?? ask.rowId;
        if (!this.ids.length || this.ids[0]! >= edge) this.hasBefore = page.hasBefore;
        else if (!reaches && page.hasBefore) this.setGap(edge, true);
      } else {
        const next = this.ids[lowerBound(this.ids, (high ?? ask.rowId) + 1)];
        if (next === undefined) this.hasAfter = page.hasAfter;
        else if (reaches || !page.hasAfter) this.setGap(next, false);
      }
      // The person reads where they paged to: the cap lets go of the other end.
      this.anchor = { rowId: ask.rowId, side: ask.side };
      this.joinApart();
    }
    this.touchRows();
  }

  private blob(change: Extract<ChatChange, { kind: "chatBlob" }>): void {
    const ask = this.blobAsks.get(change.head.id);
    // An id the store does not hold is dropped, as a change for a sid it does not hold is.
    if (!ask) return;
    this.blobAsks.delete(change.head.id);
    this.range(ask, change.head, change.nextStart, change.text);
  }

  /// Applies one range of a blob read the page asked for.
  private range(ask: BlobAsk, head: ChatBlobHead, nextStart: number, text: string): void {
    let assembly = this.assemblies.get(ask.key);
    // An open row's body changed between two ranges: what was joined is of another body.
    if (assembly && head.open && assembly.gen !== head.gen) assembly = undefined;
    if (!assembly || head.start === 0) assembly = { parts: [], nextStart: 0, gen: head.gen };
    // Ranges join in order: one that does not start where the last ended is dropped.
    if (head.start !== assembly.nextStart) {
      this.assemblies.set(ask.key, assembly);
      return;
    }
    assembly.parts.push(text);
    assembly.nextStart = nextStart;
    if (nextStart < head.total) {
      this.assemblies.set(ask.key, assembly);
      return;
    }
    this.assemblies.delete(ask.key);
    const whole = assembly.parts.join("");
    let value: unknown = whole;
    if (ask.rowId !== undefined) {
      try {
        value = JSON.parse(whole);
      } catch {
        return;
      }
    }
    const was = this.bodies.get(ask.key);
    if (was) this.bodyBytes -= was.bytes;
    this.bodies.delete(ask.key);
    this.bodies.set(ask.key, { value, bytes: whole.length });
    this.bodyBytes += whole.length;
    // Map order is insertion order: the first key is the least recently read.
    for (const [key, body] of this.bodies) {
      if (this.bodyBytes <= STORE_MAX_BLOB_BYTES || key === ask.key) break;
      this.bodies.delete(key);
      this.bodyBytes -= body.bytes;
    }
    this.changed = this.bodiesChanged = true;
  }

  /// Past the cap on settled rows, lets go of the end farthest from the anchor and marks that side
  /// to page. An open row is never let go of (decision 243): one past the end is held apart.
  private trim(): void {
    if (this.ids.length <= STORE_MAX_ROWS && this.bytes <= STORE_MAX_BYTES) return;
    let rows = 0;
    let bytes = 0;
    for (const id of this.ids) {
      if (isOpen(this.entries.get(id))) continue;
      rows += 1;
      bytes += this.sizes.get(id)!;
    }
    if (rows <= STORE_MAX_ROWS && bytes <= STORE_MAX_BYTES) return;
    const anchor = this.anchor;
    const at =
      anchor === "end" ? this.ids.length - 1 : Math.min(lowerBound(this.ids, anchor.rowId), this.ids.length - 1);
    let lo = 0;
    let hi = this.ids.length - 1;
    // ends: each pass takes `lo` up or `hi` down by one, until they meet
    while ((rows > STORE_MAX_ROWS || bytes > STORE_MAX_BYTES) && lo < hi) {
      let front = at - lo >= hi - at;
      // Never the anchor's row.
      if (front && lo >= at) front = false;
      else if (!front && hi <= at) front = true;
      const id = front ? this.ids[lo++]! : this.ids[hi--]!;
      if (front) this.hasBefore = true;
      else this.hasAfter = true;
      const entry = this.entries.get(id)!;
      const size = this.sizes.get(id)!;
      this.entries.delete(id);
      this.sizes.delete(id);
      this.bytes -= size;
      if (isOpen(entry)) {
        this.holdApart(entry);
        continue;
      }
      rows -= 1;
      bytes -= size;
      this.assemblies.delete(`row:${id}`);
    }
    this.ids = this.ids.slice(lo, hi + 1);
    // Nothing is held before the first row now: what is missing there is `hasBefore`'s.
    if (this.ids.length) this.setGap(this.ids[0]!, false);
    this.rowsChanged = true;
  }

  private build(rows: boolean, apart: boolean, bodies: boolean): ChatRowsSnapshot {
    const was = this.snapshot as ChatRowsSnapshot | undefined;
    let list = was?.rows ?? NO_ENTRIES;
    if (rows) list = this.ids.map((id) => this.entries.get(id)!);
    let apartList = was?.apart ?? NO_ENTRIES;
    if (apart) apartList = this.apart.size ? [...this.apart.values()].sort((a, b) => a.id - b.id) : NO_ENTRIES;
    let bodyMap = was?.bodies ?? NO_BODIES;
    if (bodies)
      bodyMap = this.bodies.size ? new Map([...this.bodies].map(([key, body]) => [key, body.value])) : NO_BODIES;
    return Object.freeze({
      sid: this.sid,
      rows: list,
      apart: apartList,
      hasBefore: this.hasBefore,
      hasAfter: this.hasAfter,
      queue: this.queue,
      seen: this.seen,
      folds: this.folds,
      bodies: bodyMap,
      ready: this.ready,
    });
  }
}

function openEntry(open: ChatOpenRow): ChatRowEntry {
  return entryOf(open.row, open.bodyLen);
}

type Listener = (snapshot: ChatRowsSnapshot) => void;

/// The sids a batch applied in parts has changed, until its `commit`.
export class StorePart {
  readonly touched = new Set<SidRows>();
}

/// Every chat sub of a page, by sid. The host client hands it each batch's changes; it applies
/// them and tells each sid's subscribers once, after the batch, with the new snapshot.
export class ChatRowStore {
  private sids = new Map<string, SidRows>();
  private listeners = new Map<string, Set<Listener>>();
  private onFall: (fall: ChatFall) => void;

  constructor(options: { onFall?: (fall: ChatFall) => void } = {}) {
    this.onFall = options.onFall ?? (() => {});
  }

  open(sid: string, anchor: ChatAnchor = "end"): void {
    if (!this.sids.has(sid)) this.sids.set(sid, new SidRows(sid, anchor));
  }

  close(sid: string): void {
    this.sids.delete(sid);
  }

  has(sid: string): boolean {
    return this.sids.has(sid);
  }

  snapshot(sid: string): ChatRowsSnapshot | undefined {
    return this.sids.get(sid)?.current;
  }

  /// Where the person reads, as the view knows it: the cap lets go of the end farthest from it.
  setAnchor(sid: string, anchor: ChatAnchor): void {
    const rows = this.sids.get(sid);
    if (rows) rows.anchor = anchor;
  }

  edge(sid: string, side: "before" | "after"): number | null {
    return this.sids.get(sid)?.edge(side) ?? null;
  }

  pageOut(sid: string): boolean {
    return this.sids.get(sid)?.pageOut() ?? false;
  }

  pageAsked(sid: string, side: "before" | "after", rowId: number, fold?: number): void {
    this.sids.get(sid)?.pageAsked({ side, rowId, fold });
  }

  /// A blob read the page named, recorded before it is posted: its reply may come before the
  /// operation's answer (decision 228).
  blobAsked(sid: string, id: string, target: BlobTarget): void {
    this.sids.get(sid)?.blobAsked(id, target);
  }

  /// A blob read the host refused: its id is not held.
  blobFailed(sid: string, id: string): void {
    this.sids.get(sid)?.blobFailed(id);
  }

  held(sid: string): { rows: number; bytes: number; blobBytes: number } | undefined {
    return this.sids.get(sid)?.held();
  }

  subscribe(sid: string, listener: Listener): () => void {
    let set = this.listeners.get(sid);
    if (!set) this.listeners.set(sid, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (!set.size) this.listeners.delete(sid);
    };
  }

  /// Falls `sid` to v1 for a reason the page found itself (an `open` the host refused).
  fall(sid: string, code: string): void {
    this.sids.delete(sid);
    this.onFall({ sid, code });
  }

  /// Applies one batch: every change, then one snapshot per sid that changed.
  applyBatch(changes: readonly ChatChange[]): void {
    const part = new StorePart();
    this.applyPart(part, changes);
    this.commit(part);
  }

  /// Applies changes into `part` and tells no one yet. A batch applied in slices (rows/receiver.ts)
  /// calls this per change and `commit(part)` once at its end, so subscribers are told once, as with
  /// `applyBatch`. Another batch committed meanwhile tells only the sids it changed itself (with
  /// their state as it is then).
  applyPart(part: StorePart, changes: readonly ChatChange[]): void {
    const touched = part.touched;
    for (const change of changes) {
      const sid = changeSid(change);
      if (sid === null) continue;
      const rows = this.sids.get(sid);
      // A change for a sid the page does not hold is dropped unread.
      if (!rows) continue;
      if (change.kind === "chatError" && change.method === "sub" && change.code !== "not_ready") {
        this.sids.delete(sid);
        touched.delete(rows);
        this.onFall({ sid, code: change.code });
        continue;
      }
      rows.apply(change);
      touched.add(rows);
    }
  }

  /// Tells each sid `part` changed, once, with its new snapshot.
  commit(part: StorePart): void {
    if (!part.touched.size) return;
    const touched = [...part.touched];
    part.touched.clear();
    // A sid closed between a part and the commit (a batch spans slices) tells no one.
    for (const rows of touched) if (this.sids.get(rows.sid) === rows) this.notify(rows);
  }

  private notify(rows: SidRows): void {
    const snapshot = rows.settle();
    if (!snapshot) return;
    for (const listener of this.listeners.get(rows.sid) ?? []) listener(snapshot);
  }
}
