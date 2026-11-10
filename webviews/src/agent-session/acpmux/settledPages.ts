// A chat's settled pages: every finished turn's records, written once when the turn ends and never
// changed after. Leo, 2026-11-10: "it's just text in the end, right? Like, if it is text, then
// therefore why can't it just be a book? Because it's only dynamic up to a certain point and then
// it becomes static, right? So if it's static afterwards, then can't we load that as fast as
// possible?"
//
// The pages are the chat's past as this app last read it, keyed by session and by the seq of each
// page's first record. An open draws them on its first frame, before the socket to acpmux is even
// asked for, so the past never waits on the daemon, on the app host's main thread or on a
// reconnect; only the turn in progress (the live tail) comes from the stream (direct.ts `open`).
//
// Where they live: the page's own memory (`pages`), which a client that lost its socket and the next
// chat of the same pane read synchronously, and the pane's IndexedDB, which every agent pane page
// of the app shares (AgentPaneView's one `sharedDataStore`), so a chat reopened in a NEW TAB reads
// them there without a round trip to the host. That data store is non-persistent: nothing here is
// written to disk, and quitting the app forgets it, as tailCache.ts's host copy is forgotten.
//
// A page is drawn only as a hint the chat's attach checks: the attach answers acpmux's own records
// after the newest drawn seq (`keptThrough`) and a failed attach forgets the chat everywhere
// (`forgetSettled`, from tailCache.ts `forgetTail`). Pages are drawn only as one unbroken run, newest
// first: each older page must end where the newer one says the records before it end (`after`).
import type { EventRecord } from "./direct";
import type { KeptTail } from "./tailCache";

/// One finished turn's records, as the client held them when the turn settled.
export type SettledPage = {
  sessionId: string;
  /// The seq of the page's first record and of its last (the turn's end).
  firstSeq: number;
  lastSeq: number;
  /// The seq of the record the client held right before this page, or 0 when it held none (the
  /// page starts the client's read). Older pages chain through it (`settledRun`).
  after: number;
  events: EventRecord[];
  /// The session generation (`summary.createdAt`) and machine the records are of, which the attach
  /// checks the drawn rows against (direct.ts `drawKeptTail`).
  createdAt?: number;
  peer?: string;
};

/// The ends of a turn as acpmux journals them (direct.ts reads the same three).
const TURN_ENDS = new Set(["turn_end", "turn_result", "turn_error"]);
/// Most records a draw takes from the pages, newest pages first: the same bound as a kept tail, so
/// a chat's first frame costs the same whatever its length (older turns load through the older-
/// history reader, as before).
export const SETTLED_DRAW_EVENTS = 400;
/// Most pages kept per chat in this page's memory. Older ones stay in IndexedDB.
const MEMORY_PAGES = 64;
/// Most chats kept in this page's memory, least recently written first out.
const MEMORY_CHATS = 24;
/// The longest an open waits on IndexedDB. Reads are served by WebKit's storage process, not the
/// app's main thread or the daemon, so they answer in milliseconds even under load; this is only
/// so a store that never answers cannot hold an open up.
const STORE_READ_MS = 120;

const DB_NAME = "cmux-agent-pane-settled";
const STORE = "pages";

/// This page's pages, by chat, oldest first.
const pages = new Map<string, SettledPage[]>();
/// The newest settled seq written per chat (memory and store), so a page is written once.
const writtenThrough = new Map<string, number>();
let opening: Promise<IDBDatabase | undefined> | undefined;

/// Pages a test installs instead of IndexedDB (jsdom has none): shared like the app's data store.
let storeForTests: Map<string, SettledPage[]> | undefined;

function database(): Promise<IDBDatabase | undefined> {
  if (opening) return opening;
  opening = new Promise<IDBDatabase | undefined>((resolve) => {
    try {
      const factory = (globalThis as { indexedDB?: IDBFactory }).indexedDB;
      if (!factory) return resolve(undefined);
      const request = factory.open(DB_NAME, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { keyPath: ["sessionId", "firstSeq"] });
      };
      request.onsuccess = () => resolve(request.result);
      // A page where storage is refused (a private context, a quota): the pages stay in memory.
      request.onerror = () => resolve(undefined);
      request.onblocked = () => resolve(undefined);
    } catch {
      resolve(undefined);
    }
  });
  return opening;
}

/// The settled pages in `events` (the client's records, oldest first) that end after
/// `through`: each run of records up to and including a turn's end, from the record after the
/// previous end. Records after the last end are the live tail and are no page.
export function settledPagesOf(
  sessionId: string,
  events: readonly EventRecord[],
  through: number,
  identity: { createdAt?: number; peer?: string } = {},
): SettledPage[] {
  const out: SettledPage[] = [];
  // Only what follows the newest page written is read: the scan costs the records since the last
  // settle, not the chat's length.
  let start = firstAfter(events, through);
  // The client's records may begin inside a turn (an attach page starts where its bytes allow): that
  // turn's rest is no whole page, so pages start at the first turn opener.
  if (start === 0) {
    while (start < events.length && !startsTurn(events[start]!)) start += 1;
  }
  for (let at = start; at < events.length; at += 1) {
    if (!endsPage(events, at)) continue;
    const page = events.slice(start, at + 1);
    const first = page[0]!;
    out.push({
      sessionId,
      firstSeq: first.seq,
      lastSeq: events[at]!.seq,
      after: start > 0 ? events[start - 1]!.seq : 0,
      events: page,
      ...(identity.createdAt !== undefined ? { createdAt: identity.createdAt } : {}),
      ...(identity.peer !== undefined ? { peer: identity.peer } : {}),
    });
    start = at + 1;
  }
  return out;
}

/// A turn's opener, as direct.ts tells one: a prompt, not a steer into the turn running.
function startsTurn(event: EventRecord): boolean {
  return event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;
}

/// Whether the record at `at` ends a settled page: a turn's result or error, or a legacy daemon's
/// `turn_end` that no result follows. A `turn_end` with nothing after it yet waits: its
/// `turn_result` may still come, and belongs on the same page.
function endsPage(events: readonly EventRecord[], at: number): boolean {
  const event = events[at]!;
  if (event.dir !== "mux" || !TURN_ENDS.has(event.kind)) return false;
  if (event.kind !== "turn_end") return true;
  const next = events[at + 1];
  return next !== undefined && next.kind !== "turn_result";
}

/// The index of the first record of `events` (in seq order) after seq `through`.
function firstAfter(events: readonly EventRecord[], through: number): number {
  let low = 0;
  let high = events.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (events[mid]!.seq <= through) low = mid + 1;
    else high = mid;
  }
  return low;
}

/// Writes the turns of `events` that settled since the last write, once each: in this page's
/// memory now, and in the shared store without waiting. A page already written is never written
/// again (pages are immutable); a chat whose identity changed is forgotten first.
export function settle(
  sessionId: string,
  events: readonly EventRecord[],
  identity: { createdAt?: number; peer?: string } = {},
): void {
  // The page's memory mirrors the app's shared store and is no copy of its own: where there is no
  // store (a page outside WebKit, a test that installs none), nothing is kept, so no later client
  // of the page draws rows that only a closed one read (tailCache.ts `rememberTail`'s rule).
  if (!storeForTests && typeof (globalThis as { indexedDB?: unknown }).indexedDB === "undefined") return;
  const known = pages.get(sessionId);
  const newest = known?.at(-1);
  // Another session generation or machine under the same id: what was kept is not this chat's.
  if (
    newest &&
    ((newest.createdAt !== undefined && identity.createdAt !== undefined && newest.createdAt !== identity.createdAt) ||
      newest.peer !== identity.peer)
  )
    forgetSettled(sessionId);
  const through = writtenThrough.get(sessionId) ?? 0;
  const fresh = settledPagesOf(sessionId, events, through, identity);
  if (fresh.length === 0) return;
  const list = pages.get(sessionId) ?? [];
  // A page that starts a new run (the client read a newer page past a hole) drops the older run
  // from memory: only an unbroken run is ever drawn.
  for (const page of fresh) {
    const last = list.at(-1);
    if (last && page.after !== last.lastSeq) list.length = 0;
    list.push(page);
  }
  while (list.length > MEMORY_PAGES) list.shift();
  pages.delete(sessionId);
  pages.set(sessionId, list);
  while (pages.size > MEMORY_CHATS) pages.delete(pages.keys().next().value!);
  writtenThrough.set(sessionId, fresh.at(-1)!.lastSeq);
  void writeStore(fresh);
}

async function writeStore(fresh: SettledPage[]): Promise<void> {
  if (storeForTests) {
    const sessionId = fresh[0]!.sessionId;
    const list = storeForTests.get(sessionId) ?? [];
    for (const page of fresh) if (!list.some((kept) => kept.firstSeq === page.firstSeq)) list.push(page);
    list.sort((a, b) => a.firstSeq - b.firstSeq);
    storeForTests.set(sessionId, list);
    return;
  }
  const db = await database();
  if (!db) return;
  try {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    // `add`, never `put`: a page that is there already stays as it was written.
    for (const page of fresh) store.add(page).onerror = (event) => event.preventDefault();
  } catch {
    // A store that refuses a write leaves the next tab to open as it did before.
  }
}

/// The newest unbroken run of `list` (oldest first), bounded at ``SETTLED_DRAW_EVENTS`` records.
function settledRun(list: readonly SettledPage[]): SettledPage[] {
  const run: SettledPage[] = [];
  let count = 0;
  for (let at = list.length - 1; at >= 0; at -= 1) {
    const page = list[at]!;
    const newer = run[0];
    if (newer && newer.after !== page.lastSeq) break;
    if (newer && count + page.events.length > SETTLED_DRAW_EVENTS) break;
    run.unshift(page);
    count += page.events.length;
  }
  return run;
}

/// `run` as a tail `drawKeptTail` draws: its records, the chat it is of, and never a claim that
/// the chat's history is read through (older turns still load from acpmux).
function tailOf(run: SettledPage[]): KeptTail | undefined {
  if (run.length === 0) return undefined;
  const newest = run.at(-1)!;
  const events = run.flatMap((page) => page.events);
  const summary: Record<string, unknown> = {};
  if (newest.createdAt !== undefined) summary.createdAt = newest.createdAt;
  if (newest.peer !== undefined) summary.peer = newest.peer;
  return {
    events,
    summary: Object.keys(summary).length > 0 ? summary : undefined,
    turnOpener: undefined,
    historyExhausted: false,
    queue: [],
    configSeq: 0,
    // Usage is whole only from the first drawn record: the tokens of turns before it are unread.
    usageFromSeq: run[0]!.firstSeq,
  };
}

/// The settled pages this page holds of `sessionId`, as a tail, with no wait at all.
export function settledTail(sessionId: string): KeptTail | undefined {
  const list = pages.get(sessionId);
  return list ? tailOf(settledRun(list)) : undefined;
}

/// The settled pages the app's pages share of `sessionId`, as a tail: what this page holds, else
/// the shared store's, raced against ``STORE_READ_MS``. Pages read are kept in this page's memory.
export async function readSettled(sessionId: string): Promise<KeptTail | undefined> {
  const held = settledTail(sessionId);
  if (held) return held;
  const read = readStore(sessionId).then((list) => {
    if (list.length === 0 || pages.has(sessionId)) return settledTail(sessionId);
    pages.set(sessionId, list.slice(-MEMORY_PAGES));
    writtenThrough.set(sessionId, Math.max(writtenThrough.get(sessionId) ?? 0, list.at(-1)!.lastSeq));
    while (pages.size > MEMORY_CHATS) pages.delete(pages.keys().next().value!);
    return settledTail(sessionId);
  });
  return Promise.race([read, new Promise<undefined>((resolve) => setTimeout(() => resolve(undefined), STORE_READ_MS))]);
}

async function readStore(sessionId: string): Promise<SettledPage[]> {
  if (storeForTests) return [...(storeForTests.get(sessionId) ?? [])];
  const db = await database();
  if (!db) return [];
  return new Promise<SettledPage[]>((resolve) => {
    try {
      const range = IDBKeyRange.bound([sessionId, -Infinity], [sessionId, Infinity]);
      const out: SettledPage[] = [];
      // Newest first, and only as many pages as a draw can take: the cost of an open does not grow
      // with the chat.
      const cursor = db.transaction(STORE, "readonly").objectStore(STORE).openCursor(range, "prev");
      let count = 0;
      cursor.onsuccess = () => {
        const at = cursor.result;
        const page = at?.value as SettledPage | undefined;
        if (!at || !page || count >= SETTLED_DRAW_EVENTS) return resolve(out);
        out.unshift(page);
        count += page.events.length;
        at.continue();
      };
      cursor.onerror = () => resolve([]);
    } catch {
      resolve([]);
    }
  });
}

/// A chat this app no longer stands behind (purged, or its attach failed): its pages go, here and
/// in the shared store.
export function forgetSettled(sessionId: string): void {
  pages.delete(sessionId);
  writtenThrough.delete(sessionId);
  if (storeForTests) {
    storeForTests.delete(sessionId);
    return;
  }
  void database().then((db) => {
    if (!db) return;
    try {
      db.transaction(STORE, "readwrite")
        .objectStore(STORE)
        .delete(IDBKeyRange.bound([sessionId, -Infinity], [sessionId, Infinity]));
    } catch {
      // Nothing to forget where nothing could be written.
    }
  });
}

/// Test seam: a fresh page (no pages in memory). `shared` stands for the app's shared store, which
/// outlives a page; pass a new map for a fresh app, or undefined to use IndexedDB.
export function resetSettledForTests(shared?: Map<string, SettledPage[]>): void {
  pages.clear();
  writtenThrough.clear();
  storeForTests = shared;
}
