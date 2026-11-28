// What a thread's line read from acpmux (`chat.inbox.thread`, InboxNoticeCard.tsx), by chat, line
// (inboxNotice.ts `inboxThreadKey`: the row and its thread) and the messages it was read for, kept
// while the page lasts. A line scrolled out of the virtualized transcript and back draws what it
// read at once, with no second read and no first line growing into the whole message again, and
// the row estimator (model.ts) measures the same text the line draws. Bounded: the oldest reads go
// first past `KEEP`.
import { plainLine } from "./agentMessageRowModel";
import type { InboxMessage } from "./inboxNotice";

/// An opened thread draws its newest messages this many at a time, and "Show earlier messages" the
/// ones before them: a thread of hundreds costs what a short one does until the person asks.
export const THREAD_PAGE = 20;

/// The key under which a shut line's newest message shows whole, past its eight lines
/// (incomingOpened.ts, which the row estimator reads too).
export const newestWholeKey = (lineKey: string) => `${lineKey}\u0000whole`;

const KEEP = 128;
const reads = new Map<string, InboxMessage[] | null>();

const key = (sessionId: string | undefined, line: string, readFor: string) =>
  `${sessionId ?? ""}\u0000${line}\u0000${readFor}`;

/// The prompt ids a read is for, as one key part: a later notice for the thread (new ids) reads again.
export const readForIds = (promptIds: readonly string[]) => promptIds.join("\u0001");

/// What was read for these messages: their messages, `null` when the read found none, else undefined.
export function threadRead(
  sessionId: string | undefined,
  line: string,
  readFor: string,
): InboxMessage[] | null | undefined {
  return reads.get(key(sessionId, line, readFor));
}

/// Records a read (`null`: it found nothing, and is not asked again until new messages come).
export function setThreadRead(
  sessionId: string | undefined,
  line: string,
  readFor: string,
  messages: InboxMessage[] | null,
): void {
  const id = key(sessionId, line, readFor);
  reads.delete(id);
  reads.set(id, messages);
  if (reads.size > KEEP) reads.delete(reads.keys().next().value!);
}

/// Forgets every read (tests).
export function resetThreadReads(): void {
  reads.clear();
}

/// The longest newest message a shut line holds on itself.
const ON_LINE_CHARS = 60;

/// Whether a shut line's newest message, known whole, reads on the line itself, as another
/// agent's short received line does: one plain line of at most `ON_LINE_CHARS`. The line then keeps
/// the one-line rows' pitch (Leo, 2026-11-01: "doesn't make sense for these to be spaced
/// differently"); anything longer reads in the card under it. The row estimator (model.ts) asks
/// the same, so the row is measured as it draws.
export function fitsLine(whole: string | undefined): whole is string {
  const text = whole?.trim();
  return Boolean(text) && !text!.includes("\n") && text!.length <= ON_LINE_CHARS && plainLine(text!) === text;
}
