// Pure derivations of the channels Home: the rail sections, the timeline rows (day lines, author
// heads, thread summaries) and a thread's replies. Everything here is a view over the owner's
// messages; nothing is stored. Threads come from the owner's thread root, else from the inline
// reply target (the owner keeps no thread index yet; cx-59n8 tracks the backend request).
import type { HomeConversation, HomeMessage, HomePart } from "./types";

/** Messages closer than this from the same author share one head. */
const GROUP_GAP_MS = 5 * 60 * 1000;

export interface RailSections {
  channels: HomeConversation[];
  direct: HomeConversation[];
}

const byPinThenTime = (a: HomeConversation, b: HomeConversation) =>
  Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt;

export function railSections(conversations: Iterable<HomeConversation>): RailSections {
  const channels: HomeConversation[] = [];
  const direct: HomeConversation[] = [];
  for (const conversation of conversations) (conversation.kind === "group" ? channels : direct).push(conversation);
  channels.sort(byPinThenTime);
  direct.sort((a, b) => Number(b.kind === "chief") - Number(a.kind === "chief") || byPinThenTime(a, b));
  return { channels, direct };
}

/** The rail and header name: the title, else the other participants' names. */
export function conversationName(conversation: HomeConversation, me: string | undefined): string {
  if (conversation.title) return conversation.title;
  const names = conversation.participants.filter((p) => p.id !== me).map((p) => p.name);
  return names.join(", ");
}

/** The thread a message belongs to (its root's id), or undefined for a top-level message. */
export function threadOf(message: HomeMessage): string | undefined {
  const root = message.threadRoot ?? message.replyTo?.message;
  return root && root !== message.id ? root : undefined;
}

export function partText(part: HomePart): string {
  switch (part.type) {
    case "text":
    case "other":
      return part.text;
    case "work":
      return part.preview ?? part.title;
    case "attachment":
      return part.name;
  }
}

export function messageText(message: HomeMessage): string {
  return message.parts.map(partText).join("\n");
}

export function mentionsMe(message: HomeMessage, me: string | undefined): boolean {
  if (!me) return false;
  return message.parts.some((part) => part.type === "text" && part.mentions.some((m) => m.participant === me));
}

export interface ThreadSummary {
  count: number;
  lastAt: number;
  authors: string[];
}

export type TimelineRow =
  | { kind: "day"; key: string; at: number }
  | { kind: "message"; key: string; message: HomeMessage; head: boolean; thread?: ThreadSummary };

const dayKey = (at: number) => {
  const date = new Date(at);
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
};

/** Thread summaries by root id over the loaded window (one pass). */
export function threadSummaries(messages: readonly HomeMessage[]): Map<string, ThreadSummary> {
  const summaries = new Map<string, ThreadSummary>();
  for (const message of messages) {
    const root = threadOf(message);
    if (!root) continue;
    const summary = summaries.get(root) ?? { count: 0, lastAt: 0, authors: [] };
    summary.count += 1;
    summary.lastAt = Math.max(summary.lastAt, message.createdAt);
    if (!summary.authors.includes(message.author)) summary.authors.push(message.author);
    summaries.set(root, summary);
  }
  return summaries;
}

/** Top-level messages with day lines and author heads; thread replies stay in the thread panel. */
export function timelineRows(messages: readonly HomeMessage[]): TimelineRow[] {
  const summaries = threadSummaries(messages);
  const rows: TimelineRow[] = [];
  let previous: HomeMessage | undefined;
  for (const message of messages) {
    if (threadOf(message)) continue;
    const day = dayKey(message.createdAt);
    const newDay = !previous || dayKey(previous.createdAt) !== day;
    if (newDay) rows.push({ kind: "day", key: `day-${day}`, at: message.createdAt });
    const head =
      newDay ||
      previous?.author !== message.author ||
      message.createdAt - (previous?.createdAt ?? 0) > GROUP_GAP_MS ||
      summaries.has(previous?.id ?? "");
    rows.push({ kind: "message", key: message.id, message, head, thread: summaries.get(message.id) });
    previous = message;
  }
  return rows;
}

/** A thread's root (when loaded) and its replies in order. */
export function threadMessages(
  messages: readonly HomeMessage[],
  root: string,
): { root?: HomeMessage; replies: HomeMessage[] } {
  return {
    root: messages.find((message) => message.id === root),
    replies: messages.filter((message) => threadOf(message) === root),
  };
}

/** Merges a page or event messages into an ascending window by seq; a newer copy replaces the old one. */
export function mergeMessages(
  window: readonly HomeMessage[],
  incoming: readonly HomeMessage[],
  limit: number,
): HomeMessage[] {
  if (incoming.length === 0) return window as HomeMessage[];
  const bySeq = new Map<number, HomeMessage>();
  for (const message of window) bySeq.set(message.seq, message);
  for (const message of incoming) bySeq.set(message.seq, message);
  const merged = [...bySeq.values()].sort((a, b) => a.seq - b.seq);
  return merged.length > limit ? merged.slice(merged.length - limit) : merged;
}
