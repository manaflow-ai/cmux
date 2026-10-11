// Pure derivations of the channels Home: the rail sections, the timeline rows (day lines, author
// heads, thread summaries) and a thread's replies. Everything here is a view over the owner's
// messages; nothing is stored. Threads come from the owner's thread root, else from the inline
// reply target. A root's count comes from the owner's stats (HomeThreadStats, every reply that is
// not retracted) plus the loaded replies the stats did not count yet; without stats, from the
// loaded window. A retracted reply never counts (it shows as deleted in the thread).
import type { HomeDraft } from "./drafts";
import type { HomeConversation, HomeMessage, HomePart, HomeThreadStats } from "./types";

/** Messages closer than this from the same author share one head. */
const GROUP_GAP_MS = 5 * 60 * 1000;

export interface RailSections {
  channels: HomeConversation[];
  direct: HomeConversation[];
}

const byPinThenTime = (a: HomeConversation, b: HomeConversation) =>
  Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt;

/** The channels: every group, and every titled room that repeats a member's direct message. With
 * one other member, the oldest conversation (created, then id; the rule HomeChiefName.select uses
 * for the Chief) is the direct message, whatever its title (the Chief's DM is titled "Chief" in
 * the user's language, and a user may rename it); a later titled one is a room made with
 * "Add channel". */
export function channelIds(conversations: Iterable<HomeConversation>, me?: string): Set<string> {
  const channels = new Set<string>();
  const byMember = new Map<string, HomeConversation[]>();
  for (const c of conversations) {
    const others = c.participants.filter((p) => p.id !== me);
    if (c.kind === "group" || others.length !== 1) channels.add(c.id);
    else byMember.set(others[0]!.id, [...(byMember.get(others[0]!.id) ?? []), c]);
  }
  const created = (c: HomeConversation) => c.createdAt ?? c.updatedAt;
  for (const list of byMember.values()) {
    list.sort((a, b) => created(a) - created(b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    for (const c of list.slice(1)) if (c.title) channels.add(c.id);
  }
  return channels;
}

export function railSections(conversations: Iterable<HomeConversation>, me?: string): RailSections {
  const list = [...conversations];
  const ids = channelIds(list, me);
  const channels: HomeConversation[] = [];
  const direct: HomeConversation[] = [];
  for (const conversation of list) (ids.has(conversation.id) ? channels : direct).push(conversation);
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
  /** Replies after my read cursor when the conversation opened. */
  unread: number;
}

export type TimelineRow =
  | { kind: "day"; key: string; at: number }
  | { kind: "new"; key: string }
  | { kind: "message"; key: string; message: HomeMessage; head: boolean; thread?: ThreadSummary }
  | { kind: "draft"; key: string; draft: HomeDraft; head: boolean }
  | { kind: "replies"; key: string; count: number };

const dayKey = (at: number) => {
  const date = new Date(at);
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
};

/** What showed as new when the conversation opened (HomeSnapshot.unseen). */
export interface Unseen {
  after: number;
  through: number;
}

const isUnseen = (message: HomeMessage, unseen: Unseen | undefined, me: string | undefined) =>
  unseen !== undefined && message.seq > unseen.after && message.seq <= unseen.through && message.author !== me;

/** Thread summaries by root id (one pass over the loaded window). With the owner's stats of a
 * root, the count is the owner's plus the loaded replies after its last counted seq, so a reply
 * is never counted twice and replies outside the window still count. */
export function threadSummaries(
  messages: readonly HomeMessage[],
  unseen?: Unseen,
  me?: string,
  seen: ReadonlySet<string> = new Set(),
  owner: ReadonlyMap<string, HomeThreadStats> = new Map(),
): Map<string, ThreadSummary> {
  const summaries = new Map<string, ThreadSummary>();
  for (const [root, stats] of owner) {
    if (stats.replyCount > 0)
      summaries.set(root, {
        count: stats.replyCount,
        lastAt: stats.lastReplyAt ?? 0,
        authors: [...stats.authors],
        unread: 0,
      });
  }
  for (const message of messages) {
    const root = threadOf(message);
    if (!root || message.retracted) continue;
    const stats = owner.get(root);
    const counted = stats !== undefined && message.seq <= (stats.lastReplySeq ?? 0);
    const summary = summaries.get(root) ?? { count: 0, lastAt: 0, authors: [], unread: 0 };
    if (!counted) summary.count += 1;
    if (!seen.has(root) && isUnseen(message, unseen, me)) summary.unread += 1;
    summary.lastAt = Math.max(summary.lastAt, message.createdAt);
    if (!summary.authors.includes(message.author)) summary.authors.push(message.author);
    summaries.set(root, summary);
  }
  return summaries;
}

/** A thread's reply count: the owner's stats plus the loaded replies after them, else the loaded
 * replies; retracted replies never count. */
export function replyCount(replies: readonly HomeMessage[], stats: HomeThreadStats | undefined): number {
  const live = replies.filter((reply) => !reply.retracted);
  if (!stats) return live.length;
  return stats.replyCount + live.filter((reply) => reply.seq > (stats.lastReplySeq ?? 0)).length;
}

/** Top-level messages with day lines, author heads and a "New" line before the first message that
 * was unread when the conversation opened (not my own); thread replies stay in the thread panel. */
export function timelineRows(
  messages: readonly HomeMessage[],
  unseen?: Unseen,
  me?: string,
  seenThreads?: ReadonlySet<string>,
  owner?: ReadonlyMap<string, HomeThreadStats>,
): TimelineRow[] {
  const summaries = threadSummaries(messages, unseen, me, seenThreads, owner);
  const rows: TimelineRow[] = [];
  let previous: HomeMessage | undefined;
  let marked = false;
  for (const message of messages) {
    if (threadOf(message)) continue;
    const day = dayKey(message.createdAt);
    const newDay = !previous || dayKey(previous.createdAt) !== day;
    if (newDay) rows.push({ kind: "day", key: `day-${day}`, at: message.createdAt });
    const fresh = !marked && isUnseen(message, unseen, me);
    if (fresh) {
      marked = true;
      rows.push({ kind: "new", key: "new-line" });
    }
    const head =
      fresh ||
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

/** The timeline with the running reply as its last row (grouped under the author's own last
 * message). The row's key is the turn, so the row keeps its place while it grows. */
export function withDraft(rows: TimelineRow[], draft: HomeDraft | undefined): TimelineRow[] {
  if (!draft) return rows;
  const last = rows.at(-1);
  const head = !(last?.kind === "message" && last.message.author === draft.participant && !last.thread);
  return [...rows, { kind: "draft", key: `draft-${draft.turn}`, draft, head }];
}

/** My newest top-level text message in the window that I can still edit (Up in the composer). */
export function lastEditable(messages: readonly HomeMessage[], me: string | undefined): HomeMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.author !== me || message.retracted || threadOf(message)) continue;
    if (message.parts.length > 0 && message.parts.every((part) => part.type === "text")) return message;
  }
  return undefined;
}

/** The other participants (an @ mention's choices). */
export function others(conversation: HomeConversation | undefined, me: string | undefined) {
  return conversation ? conversation.participants.filter((p) => p.id !== me) : [];
}

/** What the other member of a direct message is (Chief, Agent); nothing for a person or a channel.
 * The rail shows it only when the name does not already say it. */
export function memberTag(
  conversation: HomeConversation,
  me: string | undefined,
  channel: boolean,
): "chief" | "agent" | undefined {
  if (channel) return undefined;
  const other = conversation.participants.find((p) => p.id !== me);
  if (!other || other.kind !== "agent") return undefined;
  return other.chief ? "chief" : "agent";
}

/** A muted disambiguator for conversations that share a name: the last activity, and the id's
 * end when even that is the same. Conversations with a unique name get none. */
export function disambiguators(
  conversations: Iterable<HomeConversation>,
  me: string | undefined,
  stamp: (at: number) => string,
): Map<string, string> {
  const byName = new Map<string, HomeConversation[]>();
  for (const c of conversations) {
    const key = conversationName(c, me).trim().toLowerCase();
    byName.set(key, [...(byName.get(key) ?? []), c]);
  }
  const out = new Map<string, string>();
  for (const group of byName.values()) {
    if (group.length < 2) continue;
    const stamps = group.map((c) => stamp(c.updatedAt));
    group.forEach((c, index) => {
      const same = stamps.filter((s) => s === stamps[index]).length > 1;
      out.set(c.id, same ? `${stamps[index]} · ${c.id.slice(-4)}` : stamps[index]!);
    });
  }
  return out;
}
