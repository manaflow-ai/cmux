// A message surge the chat's inbox holds (cmuxterm-hq RFD 0018, per-host-dedup handbook page): when
// other agents write faster than the chat should take turns, acpmux stores their messages in the
// chat's inbox and wakes the agent only for the ones that need it. Session Info draws that as one row
// of Background tasks (session-info/agentSide.ts), never a row per held message (Leo, 2026-11-20: "when it gets
// to states like this all of you need to be able to temporarily let the messages go to some inbox
// that you later categorize/read maybe with a cheaper model to filter things").
//
// The wire (acpmux's receiver, forum-surge-inbox): a persisted mux `inbox` event with
// `msg.surgeHeld === true` and `msg.surge = {held, needYou}`, a cumulative snapshot, and later
// `inbox_triaged` events with a new `msg.surge`. The newest snapshot by seq is the row; a page of
// older events read later never moves it back. `_acpmux/inbox_threads` lists the threads, and may
// carry the same `surge` snapshot.
import type { InboxNotice, InboxThread, SenderRef } from "./inboxNotice";
import { foldFind } from "./chatFind";

/// The chat's held surge, as its newest snapshot said.
export type SurgeHold = {
  /// Messages held in the inbox without a turn.
  held: number;
  /// Of them, the ones that need the person or the agent (blocks and questions).
  needYou: number;
  /// The event's seq (0 for a listing's snapshot, which any event replaces).
  seq: number;
  /// When the snapshot was taken (Unix ms), when known.
  at?: number;
};

const count = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : undefined;

/// A `surge` object's counts, or undefined when it names none.
export function surgeCounts(value: unknown): { held: number; needYou: number } | undefined {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const held = count(record.held);
  const needYou = count(record.needYou);
  if (held === undefined && needYou === undefined) return undefined;
  return { held: held ?? 0, needYou: needYou ?? 0 };
}

/// The snapshot a mux event carries: a held `inbox` event's or an `inbox_triaged` event's.
export function surgeOfEvent(kind: string, msg: unknown, seq: number, at?: number): SurgeHold | undefined {
  if (kind !== "inbox" && kind !== "inbox_triaged") return undefined;
  const record = (msg ?? {}) as Record<string, unknown>;
  if (kind === "inbox" && record.surgeHeld !== true) return undefined;
  const counts = surgeCounts(record.surge);
  return counts && { ...counts, seq, ...(at !== undefined && { at }) };
}

/// The newer of two snapshots: by seq, a tie to the later one heard.
export function newerSurge(current: SurgeHold | undefined, next: SurgeHold | undefined): SurgeHold | undefined {
  if (!next) return current;
  if (!current || next.seq >= current.seq) return next;
  return current;
}

/// Whether the row draws: something is held or needs the person.
export const surgeShows = (surge: SurgeHold | undefined): surge is SurgeHold =>
  Boolean(surge && (surge.held > 0 || surge.needYou > 0));

/// One thread of `_acpmux/inbox_threads` (hub/inbox.rs `inbox_threads`).
type ListedThread = {
  threadId?: unknown;
  label?: unknown;
  from?: unknown;
  count?: unknown;
  unread?: unknown;
  newestAt?: unknown;
  newestPreview?: unknown;
  class?: unknown;
  sender?: unknown;
  surgeHeld?: unknown;
  held?: unknown;
  /// The daemon's rule for "need you" (surge_triage.rs `needs_person`): a permission, or a
  /// question to the person.
  needYou?: unknown;
};

/// A listed thread as the received-messages card (InboxNoticeCard.tsx) draws one, with when its
/// newest message came for the order.
export type HeldThread = InboxThread & { newestAt: number };

const text = (value: unknown): string => (typeof value === "string" ? value : "");

const senderOf = (value: unknown): SenderRef | undefined => {
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const session = text(record.session);
  const label = text(record.label);
  return session || label ? { ...(session && { session }), ...(label && { label }) } : undefined;
};

/// The listing's reply as the threads the panel lists: a listing that marks held threads
/// (`surgeHeld` or `held` on a thread) lists only those; one that marks none lists every thread.
/// The ones that need the person first, then the newest.
export function heldThreads(reply: unknown): HeldThread[] {
  const listed = (reply as { threads?: unknown } | null)?.threads;
  if (!Array.isArray(listed)) return [];
  const rows = listed.filter((row): row is ListedThread => Boolean(row) && typeof row === "object");
  const marks = rows.some((row) => row.surgeHeld === true || row.held === true);
  const threads: HeldThread[] = [];
  for (const row of marks ? rows.filter((r) => r.surgeHeld === true || r.held === true) : rows) {
    const threadId = text(row.threadId);
    if (!threadId) continue;
    const from = Array.isArray(row.from) ? row.from.filter((f): f is string => typeof f === "string" && f !== "") : [];
    const sender = senderOf(row.sender);
    threads.push({
      threadId,
      label: text(row.label),
      from,
      ...(sender && { sender }),
      ...(sender?.session && { fromSession: sender.session }),
      count: count(row.count) || 1,
      preview: text(row.newestPreview),
      // The bar's "need you" count and its filter are one rule, the daemon's; an older daemon
      // sends no `needYou`, so its urgent class stands in.
      blocker: typeof row.needYou === "boolean" ? row.needYou : row.class === "blocker",
      promptIds: [],
      newestAt: count(row.newestAt) ?? 0,
    });
  }
  return threads.sort((a, b) => Number(b.blocker) - Number(a.blocker) || b.newestAt - a.newestAt);
}

/// The threads a search keeps: every word of it in the thread's label, senders or newest preview
/// (case and accents folded as Find folds them). An empty search keeps them all.
export function searchThreads(threads: readonly HeldThread[], query: string): HeldThread[] {
  const words = foldFind(query).split(/\s+/).filter(Boolean);
  if (words.length === 0) return [...threads];
  return threads.filter((thread) => {
    const hay = foldFind([thread.label, ...thread.from, thread.sender?.label ?? "", thread.preview].join("\n"));
    return words.every((word) => hay.includes(word));
  });
}

/// The threads drawn, as one notice for the received-messages card.
export function heldNotice(threads: readonly HeldThread[], shown: number): InboxNotice {
  return { threads: threads.slice(0, Math.max(0, shown)) };
}
