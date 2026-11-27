import type { AcpmuxTurnRetry } from "../model";
import type { SessionEvent } from "../protocol/generated/types";

/// The connection failures acpmux classifies (hub/outage.rs).
const OUTAGE_CAUSES = ["dns", "refused", "timeout", "unreachable"] as const;

/// What a `turn_retrying` record says the live line shows (acpmux hub/turn_retry.rs).
export function readTurnRetry(msg: Record<string, unknown>): AcpmuxTurnRetry {
  const count = (value: unknown) =>
    typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
  const attempt = count(msg.attempt);
  const maxRetries = count(msg.maxRetries);
  const errorStatus = count(msg.errorStatus);
  const error = typeof msg.error === "string" && msg.error.trim() ? msg.error.trim() : undefined;
  const cause = OUTAGE_CAUSES.find((c) => c === msg.cause);
  const host = typeof msg.host === "string" && /^[a-z0-9.-]{1,253}$/i.test(msg.host) ? msg.host : undefined;
  const retryAt =
    typeof msg.retryAt === "number" && Number.isFinite(msg.retryAt) && msg.retryAt > 0 ? msg.retryAt : undefined;
  return {
    ...(attempt !== undefined && { attempt }),
    ...(maxRetries !== undefined && (attempt === undefined || attempt <= maxRetries) && { maxRetries }),
    ...(errorStatus !== undefined && { errorStatus }),
    ...(error !== undefined && { error }),
    ...(cause !== undefined && { cause }),
    ...(host !== undefined && { host }),
    ...(retryAt !== undefined && { retryAt }),
  };
}

/// A session log record (acpmux's `SessionEvent`); the pane reads `msg`, a raw JSON-RPC message
/// or acpmux's payload, loosely.
export type EventRecord = Pick<SessionEvent, "seq" | "at" | "dir" | "kind"> & {
  sessionId?: string;
  msg: Record<string, any>;
};
/// The one place the pane takes acpmux's records as `EventRecord`s.
export const records = (events: SessionEvent[] | undefined): EventRecord[] => (events ?? []) as EventRecord[];

export const startsTurn = (event: EventRecord) =>
  event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;

/// Where the chat's journal ends now, from a read refused because its cursor is past it
/// (`cursor_future: afterSeq N is beyond the last event M`, acpmux `server/requests/events.rs`):
/// its machine is back on a shorter log, so the records this pane holds past `M` are not its
/// chat's any more. Undefined for any other failure.
export function journalEndOf(error: unknown): number | undefined {
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : "";
  const end = /cursor_future: afterSeq \d+ is beyond the last event (\d+)/.exec(message)?.[1];
  return end === undefined ? undefined : Number(end);
}

/// The records a pane held, by seq, as they were before a journal that went back was read again:
/// what `readRewoundTail` compares the machine's records to, never the ones it merged in since.
export function heldBySeq(events: readonly EventRecord[]): ReadonlyMap<number, EventRecord> {
  return new Map(events.map((event) => [event.seq, event]));
}

/// The reply segment acpmux stamped on an `agent_message_chunk` record (`_meta.acpmux.segment`,
/// hub/stream.rs): one id for every chunk of one run of reply text, whatever page holds them.
export function replySegment(event: EventRecord): string | undefined {
  const segment = (event.msg as any)?.params?._meta?.acpmux?.segment;
  return typeof segment === "string" && segment.length > 0 && segment.length <= 200 ? segment : undefined;
}

/// The batches' records by `seq`, oldest first, one per `seq`: a later batch's record (and a later one within a
/// batch) wins a tie. A new array always. Every caller passes batches already in `seq` order (the held log, a page),
/// so this walks them once, O(total), instead of a Map and a sort of the whole held log per page (11.5 ms at 100k
/// held records for a 500-record page, 233 ms at 1M: test/merge-event-records.test.ts). A batch out of order falls
/// back to `mergeEventRecordsBySort`, the old way, which is also the test's oracle.
export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  let merged: EventRecord[] | undefined;
  for (const batch of batches) {
    if (batch.length === 0) continue;
    const ordered = inSeqOrder(batch);
    if (ordered === undefined) return mergeEventRecordsBySort(...batches);
    merged = merged === undefined ? ordered : mergeTwo(merged, ordered);
  }
  if (merged === undefined) return [];
  // Never hand back a caller's own array: callers assign the result over the log they passed in.
  return batches.includes(merged) ? merged.slice() : merged;
}

/// The old merge: every record into a Map by `seq` (last wins), then a sort. Kept for out-of-order input and as the
/// oracle of the linear merge.
export function mergeEventRecordsBySort(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
}

/// The batch itself when its `seq`s strictly rise; a copy without the earlier of equal neighbours when they only never
/// fall; undefined when one falls (or is not a number to order by).
function inSeqOrder(batch: EventRecord[]): EventRecord[] | undefined {
  let ties = false;
  for (let i = 1; i < batch.length; i++) {
    const step = batch[i]!.seq - batch[i - 1]!.seq;
    if (step > 0) continue;
    if (step === 0) ties = true;
    else return undefined;
  }
  if (Number.isNaN(batch[0]!.seq)) return undefined;
  if (!ties) return batch;
  const out: EventRecord[] = [];
  for (const event of batch)
    if (out.length > 0 && out[out.length - 1]!.seq === event.seq) out[out.length - 1] = event;
    else out.push(event);
  return out;
}

/// Two `seq`-ordered, tie-free lists merged; `b` wins a tie. Disjoint ranges (an older page above the log, a live
/// record below it) are one concatenation.
function mergeTwo(a: EventRecord[], b: EventRecord[]): EventRecord[] {
  if (a[a.length - 1]!.seq < b[0]!.seq) return a.concat(b);
  if (b[b.length - 1]!.seq < a[0]!.seq) return b.concat(a);
  const out: EventRecord[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    const left = a[i]!;
    const right = b[j]!;
    if (left.seq < right.seq) {
      out.push(left);
      i++;
    } else {
      if (left.seq === right.seq) i++;
      out.push(right);
      j++;
    }
  }
  while (i < a.length) out.push(a[i++]!);
  while (j < b.length) out.push(b[j++]!);
  return out;
}

/// Older paging asks for records strictly before `events[0]`. Prepending that page avoids sorting
/// and copying the entire retained log through a Map on every page; the filter also makes retries
/// idempotent when a reconnect replays the boundary record.
export function prependOlderEventRecords(older: EventRecord[], events: EventRecord[]): EventRecord[] {
  if (older.length === 0) return events;
  const first = events[0]?.seq;
  const fresh = first === undefined ? older : older.filter((event) => event.seq < first);
  return fresh.length === 0 ? events : [...fresh, ...events];
}

export function sessionUpdate(event: EventRecord): any | undefined {
  return event.dir === "in" && event.msg.method === "session/update" ? event.msg.params?.update : undefined;
}

/// The records in `seq` order as a new array, only those with `seq <= through` when it is given: what a copy (or a
/// filter) and a sort by `seq` give, a stable sort, so equal `seq`s keep their order. A held log is already in order
/// (every merge and page keeps it so), and a full rebuild sorted it twice anyway; this checks the order in one pass and
/// copies, and sorts only a log that is out of order (test/held-by-seq.test.ts: `heldBySeqBySort` is its oracle).
export function heldBySeq(events: readonly EventRecord[], through?: number): EventRecord[] {
  let end = events.length;
  for (let i = 0; i < events.length; i++) {
    const seq = events[i]!.seq;
    // A NaN fails every comparison, so a log holding one takes the sort, which places it as it always did.
    if (seq !== seq || (i > 0 && !(events[i - 1]!.seq <= seq))) return heldBySeqBySort(events, through);
    // In order, every record after the first past `through` is past it too.
    if (end === events.length && through !== undefined && !(seq <= through)) end = i;
  }
  return events.slice(0, end);
}

/// The old way: a copy or a filter, then a sort. The oracle of `heldBySeq`, and its path for a log out of order.
export function heldBySeqBySort(events: readonly EventRecord[], through?: number): EventRecord[] {
  const kept = through === undefined ? [...events] : events.filter((event) => event.seq <= through);
  return kept.sort((a, b) => a.seq - b.seq);
}
