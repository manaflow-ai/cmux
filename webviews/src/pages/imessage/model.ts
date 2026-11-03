// Pure shaping for the Messages mirror page: wire normalization, the merge of a fresh page of
// messages into the loaded window, the conversation's rows (day lines, sender names in groups,
// bubble runs) and the list's relative times. No React, no I/O; tests call these directly.
import type { Attachment, Message, Thread, ThreadPreview } from "./types";

const DAY_MS = 86_400_000;
/** Messages farther apart than this start a new run (a new bubble group). */
const RUN_GAP_MS = 5 * 60_000;
/** A day line also appears inside one day after this much quiet, as Messages does. */
const QUIET_GAP_MS = 60 * 60_000;

/** cmux.protocol/2 can send an integer as a decimal string; the page keeps numbers. */
function num(value: unknown): number | undefined {
  if (value === null || value === undefined || value === "") return undefined;
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function normalizeMessage(raw: Message): Message {
  return {
    rowid: num(raw.rowid) ?? 0,
    guid: String(raw.guid ?? raw.rowid),
    chat_id: num(raw.chat_id) ?? 0,
    sender: str(raw.sender) ?? null,
    is_from_me: raw.is_from_me === true,
    date_ms: num(raw.date_ms) ?? null,
    text: str(raw.text) ?? null,
    attachments: Array.isArray(raw.attachments)
      ? raw.attachments.map((a: Attachment) => ({ name: str(a?.name) ?? null, mime_type: str(a?.mime_type) ?? null }))
      : [],
  };
}

function normalizePreview(raw: ThreadPreview | null | undefined): ThreadPreview | null {
  if (!raw) return null;
  return {
    rowid: num(raw.rowid) ?? 0,
    text: str(raw.text) ?? null,
    is_from_me: raw.is_from_me === true,
    sender: str(raw.sender) ?? null,
    date_ms: num(raw.date_ms) ?? null,
    has_attachments: raw.has_attachments === true,
  };
}

export function normalizeThread(raw: Thread): Thread {
  return {
    chat_id: num(raw.chat_id) ?? 0,
    guid: String(raw.guid ?? raw.chat_id),
    title: str(raw.title) ?? "",
    display_name: str(raw.display_name) ?? null,
    is_group: raw.is_group === true,
    service: str(raw.service) ?? null,
    participants: Array.isArray(raw.participants) ? raw.participants.filter((p) => typeof p === "string") : [],
    last_message: normalizePreview(raw.last_message),
  };
}

/** Oldest first, by rowid; one entry per rowid (a later copy wins: it is the fresher read). */
export function mergeMessages(loaded: readonly Message[], fresh: readonly Message[]): Message[] {
  const byRow = new Map<number, Message>();
  for (const message of loaded) byRow.set(message.rowid, message);
  for (const message of fresh) byRow.set(message.rowid, message);
  return [...byRow.values()].sort((a, b) => a.rowid - b.rowid);
}

export type ConversationRow =
  | { kind: "day"; key: string; at: number }
  | {
      kind: "message";
      key: string;
      message: Message;
      /** In a group, the sender's handle above the first bubble of their run. */
      sender?: string;
      /** The first and last bubble of a run (same sender, close in time). */
      first: boolean;
      last: boolean;
    };

function sameDay(a: number, b: number, offsetMinutes: number): boolean {
  const shift = offsetMinutes * 60_000;
  return Math.floor((a + shift) / DAY_MS) === Math.floor((b + shift) / DAY_MS);
}

function author(message: Message): string {
  return message.is_from_me ? "\u0000me" : (message.sender ?? "");
}

/**
 * The conversation's rows: a day line before the first message of each day (and after an hour of
 * quiet), then each message with its place in its run. `offsetMinutes` is the person's UTC offset
 * (east positive), so days break at their midnight.
 */
export function conversationRows(
  messages: readonly Message[],
  isGroup: boolean,
  offsetMinutes: number,
): ConversationRow[] {
  const rows: ConversationRow[] = [];
  let previous: Message | undefined;
  messages.forEach((message, index) => {
    const at = message.date_ms ?? undefined;
    const before = previous?.date_ms ?? undefined;
    const newDay =
      at !== undefined && (before === undefined || !sameDay(at, before, offsetMinutes) || at - before > QUIET_GAP_MS);
    if (newDay) rows.push({ kind: "day", key: `day-${message.rowid}`, at });
    const next = messages[index + 1];
    const continues = (a: Message | undefined, b: Message | undefined, dayBreak: boolean) =>
      !!a &&
      !!b &&
      !dayBreak &&
      author(a) === author(b) &&
      (a.date_ms == null || b.date_ms == null || Math.abs(b.date_ms - a.date_ms) <= RUN_GAP_MS);
    const nextAt = next?.date_ms ?? undefined;
    const nextDayBreak =
      nextAt !== undefined && at !== undefined && (!sameDay(nextAt, at, offsetMinutes) || nextAt - at > QUIET_GAP_MS);
    const first = !continues(previous, message, newDay);
    const last = !continues(message, next, nextDayBreak);
    rows.push({
      kind: "message",
      key: `m-${message.rowid}`,
      message,
      sender: isGroup && first && !message.is_from_me ? (message.sender ?? undefined) : undefined,
      first,
      last,
    });
    previous = message;
  });
  return rows;
}

export type RelativeKind =
  | { kind: "time"; at: number }
  | { kind: "yesterday" }
  | { kind: "weekday"; at: number }
  | { kind: "date"; at: number };

/** Which form a list row's time takes, as Messages: a time today, Yesterday, a weekday this week, else a date. */
export function relativeKind(at: number, now: number, offsetMinutes: number): RelativeKind {
  const shift = offsetMinutes * 60_000;
  const day = Math.floor((at + shift) / DAY_MS);
  const today = Math.floor((now + shift) / DAY_MS);
  if (day >= today) return { kind: "time", at };
  if (day === today - 1) return { kind: "yesterday" };
  if (day > today - 7) return { kind: "weekday", at };
  return { kind: "date", at };
}

/** A time zone name for Intl that matches `offsetMinutes` (Etc/GMT signs are inverted). */
export function offsetZone(offsetMinutes: number): string | undefined {
  if (offsetMinutes % 60 !== 0) return undefined;
  const hours = offsetMinutes / 60;
  return hours === 0 ? "UTC" : `Etc/GMT${hours > 0 ? "-" : "+"}${Math.abs(hours)}`;
}

/** The thread's initials for its avatar: letters of a name, nothing for a phone number or email. */
export function initials(title: string): string {
  const words = title
    .split(/[\s,]+/)
    .filter((word) => /^\p{L}/u.test(word) && !word.includes("@"));
  return words
    .slice(0, 2)
    .map((word) => [...word][0]!.toUpperCase())
    .join("");
}

/** The attachment's kind for its chip icon, from its MIME type. */
export function attachmentKind(attachment: Attachment): "image" | "video" | "audio" | "file" {
  const major = attachment.mime_type?.split("/")[0];
  return major === "image" || major === "video" || major === "audio" ? major : "file";
}

/** The attachment's file name, without the folder Messages keeps it in. */
export function attachmentName(attachment: Attachment): string | undefined {
  const name = attachment.name ?? undefined;
  if (!name) return undefined;
  const parts = name.split("/");
  return parts[parts.length - 1] || undefined;
}
