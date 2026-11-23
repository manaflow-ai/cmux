import type { AcpmuxTurnRetry } from "../model";
import type { SessionEvent } from "../protocol/generated/types";

/** What an `adopt.live` refusal's details offer: a fork (Claude Code), and the holding process. */
/// What a `turn_retrying` record says the live line shows (acpmux hub/turn_retry.rs).
export function readTurnRetry(msg: Record<string, unknown>): AcpmuxTurnRetry {
  const count = (value: unknown) =>
    typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
  const attempt = count(msg.attempt);
  const maxRetries = count(msg.maxRetries);
  const errorStatus = count(msg.errorStatus);
  const error = typeof msg.error === "string" && msg.error.trim() ? msg.error.trim() : undefined;
  return {
    ...(attempt !== undefined && { attempt }),
    ...(maxRetries !== undefined && (attempt === undefined || attempt <= maxRetries) && { maxRetries }),
    ...(errorStatus !== undefined && { errorStatus }),
    ...(error !== undefined && { error }),
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

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
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
