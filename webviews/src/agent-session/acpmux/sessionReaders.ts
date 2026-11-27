// The pane's readers of the whole session list, kept as the list changes (RFD 0199 section 7). Leo, 2026-11-27:
// "wonder if we can get some ds&a proper for those situations? like among various parts of the app that could be
// liable to perf situatoins or whatever". The Steer queue (steerQueue/model.ts `steerQueue`) and the Chief dock
// (ChiefDock.tsx) each filtered, folded and sorted every chat on each list change: 1.25 ms and 1.49 ms at 10k chats,
// and a running chat's status tick is a list change. Both rank the listed chats that do not fold under a parent
// (`withoutChildren(sessions.filter(listed))`); here each keeps those chats in buckets sorted by its own order, and a
// list made from the last one by in-place replacements (sessionIndex.ts `noteReplaced`) moves only the replaced
// entries (binary insert). A replacement that could fold or unfold other chats (a parent listed or not, a chat's
// `spawnedBy` changed), or a list made any other way, builds the buckets again from the whole list.
import { replacedSince } from "./sessionIndex";
import { activityTime, folded, listed, sessionMark, type AcpmuxSessionEntry } from "./sessionList";
import type { SteerAct } from "./steerQueue/log";
import {
  STALLED_MS,
  STEER_QUEUE_LIMIT,
  steerBase,
  steerItem,
  type SteerBase,
  type SteerItem,
  type SteerQueueInput,
  type SteerReason,
} from "./steerQueue/model";

/// Entries the readers below read (tests count it: work per change, not per chat listed).
export const readerReads = { count: 0 };

/// More replaced entries than this and the list is read whole.
const PATCHED = 64;

/// The positions at which `sessions` replaced entries of `previous`, when no replacement can fold or unfold another
/// chat: through `noteReplaced` records, else (a list of the same length) by entry identity, no field read. Undefined
/// when the whole list must be read again.
export function replacedLive(
  previous: readonly AcpmuxSessionEntry[] | undefined,
  sessions: readonly AcpmuxSessionEntry[],
): number[] | undefined {
  if (!previous) return undefined;
  let at = replacedSince(previous, sessions);
  if (!at && previous.length === sessions.length) {
    at = [];
    for (let i = 0; i < sessions.length && at.length <= PATCHED; i++) if (sessions[i] !== previous[i]) at.push(i);
  }
  if (!at || at.length > PATCHED || previous.length !== sessions.length) return undefined;
  for (const i of at) {
    const before = previous[i];
    const after = sessions[i];
    readerReads.count += 1;
    if (!before || !after || before.sessionId !== after.sessionId || before.spawnedBy !== after.spawnedBy)
      return undefined;
    // A parent listed or not folds or unfolds its children.
    if (!after.spawnedBy && listed(before) !== listed(after)) return undefined;
  }
  return at;
}

/// The ids chats fold under (`withoutChildren` of the listed chats).
function parentsOf(sessions: readonly AcpmuxSessionEntry[]): Set<string> {
  const parents = new Set<string>();
  for (const entry of sessions) if (listed(entry) && !entry.spawnedBy) parents.add(entry.sessionId);
  return parents;
}

type Row = { entry: AcpmuxSessionEntry; at: number; key: number };

/// Rows in one order: `key` ascending (equal keys, one of them infinite, are equal), then list position.
class Bucket {
  readonly rows: Row[] = [];

  private before(left: Row, right: Row): boolean {
    if (left.key !== right.key) return left.key < right.key;
    return left.at < right.at;
  }

  /// The first place not before `row`.
  private place(row: Row): number {
    let low = 0;
    let high = this.rows.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.before(this.rows[mid]!, row)) low = mid + 1;
      else high = mid;
    }
    return low;
  }

  insert(row: Row): void {
    this.rows.splice(this.place(row), 0, row);
  }

  remove(row: Row): void {
    const at = this.place(row);
    if (this.rows[at] === row) this.rows.splice(at, 1);
  }

  /// Rows built in list order, sorted once.
  sortAll(): void {
    this.rows.sort((left, right) => (left.key === right.key ? left.at - right.at : left.key < right.key ? -1 : 1));
  }

  /// The first place whose key is above `key`.
  after(key: number): number {
    let low = 0;
    let high = this.rows.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (this.rows[mid]!.key <= key) low = mid + 1;
      else high = mid;
    }
    return low;
  }
}

/// Live chats (listed, not folded) kept in buckets as the list changes; `bucketOf` names a chat's bucket and key.
abstract class LiveBuckets<B extends string> {
  private last: readonly AcpmuxSessionEntry[] | undefined;
  private parents = new Set<string>();
  private readonly byPosition = new Map<number, { bucket: B; row: Row }>();
  /// The live rows of each id (one, unless an id is listed twice).
  protected readonly byId = new Map<string, Row[]>();
  protected buckets: Record<B, Bucket>;

  constructor(private readonly names: readonly B[]) {
    this.buckets = this.empty();
  }

  protected abstract bucketOf(entry: AcpmuxSessionEntry): { bucket: B; key: number } | undefined;

  private empty(): Record<B, Bucket> {
    return Object.fromEntries(this.names.map((name) => [name, new Bucket()])) as Record<B, Bucket>;
  }

  protected sync(sessions: readonly AcpmuxSessionEntry[]): void {
    if (sessions === this.last) return;
    const replaced = replacedLive(this.last, sessions);
    this.last = sessions;
    if (!replaced) {
      this.build(sessions);
      return;
    }
    for (const at of replaced) {
      const kept = this.byPosition.get(at);
      if (kept) {
        this.buckets[kept.bucket].remove(kept.row);
        this.byPosition.delete(at);
        const rows = this.byId.get(kept.row.entry.sessionId)!.filter((row) => row !== kept.row);
        if (rows.length) this.byId.set(kept.row.entry.sessionId, rows);
        else this.byId.delete(kept.row.entry.sessionId);
      }
      this.add(sessions[at]!, at, true);
    }
  }

  private add(entry: AcpmuxSessionEntry, at: number, sorted: boolean): void {
    readerReads.count += 1;
    if (!listed(entry) || folded(entry, this.parents)) return;
    const place = this.bucketOf(entry);
    if (!place) return;
    const row = { entry, at, key: place.key };
    if (sorted) this.buckets[place.bucket].insert(row);
    else this.buckets[place.bucket].rows.push(row);
    this.byPosition.set(at, { bucket: place.bucket, row });
    const rows = this.byId.get(entry.sessionId);
    if (rows) rows.push(row);
    else this.byId.set(entry.sessionId, [row]);
  }

  private build(sessions: readonly AcpmuxSessionEntry[]): void {
    this.parents = parentsOf(sessions);
    this.byPosition.clear();
    this.byId.clear();
    this.buckets = this.empty();
    sessions.forEach((entry, at) => this.add(entry, at, false));
    for (const name of this.names) this.buckets[name].sortAll();
  }
}

/// `steerQueue` (steerQueue/model.ts), the same items, read through buckets: a change moves the replaced chats only,
/// and the 30 s tick of its ages reads no chat but the nine it draws: a working chat is stalled once its last
/// activity is `STALLED_MS` old, so the stalled ones are the oldest of the working bucket, found by binary search.
export class SteerQueueReader extends LiveBuckets<SteerBase> {
  constructor() {
    super(["ask", "failed", "working", "review"]);
  }

  protected bucketOf(entry: AcpmuxSessionEntry): { bucket: SteerBase; key: number } | undefined {
    if (entry.unsent) return undefined;
    const base = steerBase(entry);
    if (!base) return undefined;
    // `review` newest first, the others the longest wait first (an unknown time last).
    const at = activityTime(entry);
    return { bucket: base, key: base === "review" ? -(at ?? 0) : (at ?? Infinity) };
  }

  read({ sessions, now, log = [] }: SteerQueueInput): SteerItem[] {
    this.sync(sessions);
    const { ask, failed, working, review } = this.buckets;
    const stalledEnd = working.after(now - STALLED_MS);
    const order: [Row[], number, number, SteerReason][] = [
      [ask.rows, 0, ask.rows.length, "ask"],
      [failed.rows, 0, failed.rows.length, "failed"],
      [working.rows, 0, stalledEnd, "stalled"],
      [review.rows, 0, review.rows.length, "review"],
      [working.rows, stalledEnd, working.rows.length, "running"],
    ];
    const picked: [AcpmuxSessionEntry, SteerReason][] = [];
    for (const [rows, from, to, reason] of order)
      for (let i = from; i < to && picked.length < STEER_QUEUE_LIMIT; i++) picked.push([rows[i]!.entry, reason]);
    if (picked.length === 0) return [];
    const lastAct = new Map<string, SteerAct>();
    for (const act of log) lastAct.set(act.sessionId, act);
    return picked.map(([entry, reason]) => {
      readerReads.count += 1;
      return steerItem(entry, reason, lastAct.get(entry.sessionId));
    });
  }
}

/// A chat's place in the Chief dock: what waits on the person first, then the newest activity.
export function chiefUrgency(session: AcpmuxSessionEntry, selected: boolean): number {
  switch (sessionMark(session, selected)) {
    case "input":
      return 5;
    case "error":
      return 4;
    case "running":
      return 3;
    case "unread":
      return 2;
    default:
      return 1;
  }
}

/// The Chief dock's ranking as it was (ChiefDock.tsx before RFD 0199): every live chat sorted. The oracle of
/// `ChiefRanking`.
export function chiefRankedBySort(
  sessions: readonly AcpmuxSessionEntry[],
  currentId: string | undefined,
  cards: number,
): { cards: AcpmuxSessionEntry[]; attention: number } {
  const live = sessions.filter(listed);
  const parents = new Set(live.filter((entry) => !entry.spawnedBy).map((entry) => entry.sessionId));
  const ranked = live
    .filter((entry) => !folded(entry, parents))
    .sort(
      (left, right) =>
        chiefUrgency(right, right.sessionId === currentId) - chiefUrgency(left, left.sessionId === currentId) ||
        (activityTime(right) ?? 0) - (activityTime(left) ?? 0),
    );
  const attention = ranked.filter((session) => chiefUrgency(session, session.sessionId === currentId) >= 4).length;
  return { cards: ranked.slice(0, cards), attention };
}

type Urgency = "u5" | "u4" | "u3" | "u2" | "u1";
const URGENCIES: readonly Urgency[] = ["u5", "u4", "u3", "u2", "u1"];

/// The Chief dock's first cards and its count of chats that wait, read through urgency buckets sorted by activity:
/// a change moves the replaced chats only, and a read takes the first cards without a sort. Being the open chat only
/// unmarks an unread one (urgency 2 to 1), so the open chat is ranked again on its own among the first cards (found
/// by id, not by a walk).
export class ChiefRanking extends LiveBuckets<Urgency> {
  constructor() {
    super(URGENCIES);
  }

  protected bucketOf(entry: AcpmuxSessionEntry): { bucket: Urgency; key: number } {
    return { bucket: `u${chiefUrgency(entry, false)}` as Urgency, key: -(activityTime(entry) ?? 0) };
  }

  read(
    sessions: readonly AcpmuxSessionEntry[],
    currentId: string | undefined,
    cards: number,
  ): { cards: AcpmuxSessionEntry[]; attention: number } {
    this.sync(sessions);
    // Selection never changes urgency 4 or 5.
    const attention = this.buckets.u5.rows.length + this.buckets.u4.rows.length;
    const candidates: { row: Row; urgency: number }[] = [];
    // The first cards but the open chat, then the open chat at its own urgency, as selected.
    for (const [rank, name] of URGENCIES.entries()) {
      for (const row of this.buckets[name].rows) {
        if (candidates.length >= cards) break;
        if (row.entry.sessionId !== currentId) candidates.push({ row, urgency: 5 - rank });
      }
    }
    if (currentId !== undefined)
      for (const row of this.byId.get(currentId) ?? [])
        candidates.push({ row, urgency: chiefUrgency(row.entry, true) });
    readerReads.count += candidates.length;
    candidates.sort(
      (left, right) => right.urgency - left.urgency || left.row.key - right.row.key || left.row.at - right.row.at,
    );
    return { cards: candidates.slice(0, cards).map((candidate) => candidate.row.entry), attention };
  }
}
