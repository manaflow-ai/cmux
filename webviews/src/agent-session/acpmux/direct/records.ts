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
  const line = msg.line === "busy" || msg.line === "unavailable" ? msg.line : undefined;
  const showAfterMs =
    typeof msg.showAfterMs === "number" && Number.isFinite(msg.showAfterMs) && msg.showAfterMs >= 0
      ? msg.showAfterMs
      : undefined;
  return {
    ...(attempt !== undefined && { attempt }),
    ...(maxRetries !== undefined && (attempt === undefined || attempt <= maxRetries) && { maxRetries }),
    ...(errorStatus !== undefined && { errorStatus }),
    ...(error !== undefined && { error }),
    ...(cause !== undefined && { cause }),
    ...(host !== undefined && { host }),
    ...(retryAt !== undefined && { retryAt }),
    ...(line !== undefined && { line }),
    ...(showAfterMs !== undefined && { showAfterMs }),
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
