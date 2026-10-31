// Pure derivations of the channels Home: the rail sections, the timeline rows (day lines, author
// heads, thread summaries) and a thread's replies. Everything here is a view over the owner's
// messages; nothing is stored. Threads come from the owner's thread root, else from the inline
// reply target. A root's count comes from the owner's stats (HomeThreadStats, every reply that is
// not retracted) plus the loaded replies the stats did not count yet; without stats, from the
// loaded window. A retracted reply never counts (it shows as deleted in the thread).
import type { HomeDraft } from "./drafts";
import type {
  HomeAttachment,
  HomeConversation,
  HomeMessage,
  HomePart,
  HomeThreadObject,
  HomeThreadStats,
  HomeThreadStatus,
} from "./types";

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

/** The conversations with each Chief's current name (its record) on its direct messages: the
 * title and the participant's name. A channel keeps its own title; the same map comes back when
 * nothing changes. */
export function withChiefNames(
  conversations: ReadonlyMap<string, HomeConversation>,
  channels: ReadonlySet<string>,
  me: string | undefined,
  chiefs: ReadonlyMap<string, { name: string }>,
): ReadonlyMap<string, HomeConversation> {
  if (chiefs.size === 0) return conversations;
  let changed: Map<string, HomeConversation> | undefined;
  for (const c of conversations.values()) {
    if (channels.has(c.id)) continue;
    const others = c.participants.filter((p) => p.id !== me);
    const record = others.length === 1 && others[0]!.chief ? chiefs.get(others[0]!.id) : undefined;
    if (!record || (c.title === record.name && others[0]!.name === record.name)) continue;
    changed ??= new Map(conversations);
    changed.set(c.id, {
      ...c,
      title: record.name,
      participants: c.participants.map((p) => (p.id === others[0]!.id ? { ...p, name: record.name } : p)),
    });
  }
  return changed ?? conversations;
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
  const names = conversation.participants
    .filter((p) => p.id !== me)
    .map((p) => p.name)
    .filter(Boolean);
  return names.join(", ");
}

/** A thread's status from its root's object and the newest live reply's seq (the owner's rule):
 * resolved only while no reply came after the resolution. */
export function threadStatus(thread: HomeThreadObject | undefined, lastReplySeq: number | undefined): HomeThreadStatus {
  const resolved = thread?.resolved;
  return resolved && (lastReplySeq === undefined || lastReplySeq <= resolved.seq) ? "resolved" : "open";
}

/** The longest derived title (the row truncates by width before this). */
const TITLE_MAX = 120;

/** A thread's title: its own, else the root's first non-empty line without Markdown marks or a
 * trailing colon. */
export function threadTitle(root: HomeMessage): string {
  if (root.thread?.title) return root.thread.title;
  const line =
    messageText(root)
      .split("\n")
      .map((part) => part.trim())
      .find((part) => part.length > 0) ?? "";
  const plain = line
    .replace(/^#+\s+|^[-*>]\s+|^\d+\.\s+/, "")
    // Paired emphasis and code marks only: `fix_sidebar_bug` and `~/path` keep their characters.
    .replace(/(\*\*|__|~~|\*|_|`)(\S(?:.*?\S)?)\1/g, "$2")
    .replace(/[:;,]\s*$/, "");
  return plain.length > TITLE_MAX ? `${plain.slice(0, TITLE_MAX - 1)}…` : plain;
}

/** The thread a message belongs to (its root's id), or undefined for a top-level message. A reply
 * without the owner's root (from before threads, or an inline reply) is in the thread of the message it
 * answers; `withThreadRoots` gives it that message's root when the answered message is a thread reply. */
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
  | {
      kind: "message";
      key: string;
      message: HomeMessage;
      head: boolean;
      thread?: ThreadSummary;
      /** Indent level in the thread panel (0 = none). */
      depth?: number;
      /** The reply this one answers, shown above it when the indent is capped. */
      parent?: HomeMessage;
    }
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

/** Most indent levels the thread panel draws; a deeper reply keeps this indent and names its parent. */
export const MAX_THREAD_INDENT = 4;

/** One reply in the thread tree: its depth (1 = a reply to the root) and its parent when that is
 * another reply. */
export interface ThreadNode {
  message: HomeMessage;
  depth: number;
  parent?: HomeMessage;
}

/** The thread's replies in tree order (each reply after its parent, siblings by seq). The parent is
 * `replyTo` (threads nest without a limit, conversation-tree-v1); a reply whose parent is the root,
 * is not loaded, or is outside the thread is a first-level reply. */
export function threadTree(replies: readonly HomeMessage[], root: string): ThreadNode[] {
  const byId = new Map(replies.map((message) => [message.id, message]));
  const children = new Map<string, HomeMessage[]>();
  for (const message of replies) {
    const parent = message.replyTo?.message;
    const key = parent && parent !== root && parent !== message.id && byId.has(parent) ? parent : root;
    const list = children.get(key);
    if (list) list.push(message);
    else children.set(key, [message]);
  }
  const nodes: ThreadNode[] = [];
  const seen = new Set<string>();
  const walk = (id: string, depth: number) => {
    for (const message of (children.get(id) ?? []).sort((a, b) => a.seq - b.seq)) {
      if (seen.has(message.id)) continue;
      seen.add(message.id);
      const parent = id === root ? undefined : byId.get(id);
      nodes.push(parent ? { message, depth, parent } : { message, depth });
      walk(message.id, depth + 1);
    }
  };
  walk(root, 1);
  return nodes;
}

/** The link of a conversation or one of its messages (cmux-conversation `format_link`): the same
 * text in every UI, opened by the daemon's `conversation-link-resolve`. */
export function messageLink(conversation: string, message?: string, scheme = "cmux"): string {
  return message
    ? `${scheme}://conversation/${conversation}/message/${message}`
    : `${scheme}://conversation/${conversation}`;
}

/** The conversation and message a cmux link names (`cmux[-<tag>]://conversation/<id>[/message/<id>]`;
 * query and fragment ignored), the daemon's link grammar. Ids may also hold `-` (the page only opens
 * a conversation it already lists this way). */
export function parseConversationLink(url: string): { conversation: string; message?: string } | undefined {
  if (url.length > 512) return undefined;
  const match = /^cmux(?:-[a-z0-9]+)*:\/\/conversation\/([\w-]+)(?:\/message\/([\w-]+))?\/?(?:[?#].*)?$/i.exec(url);
  if (!match) return undefined;
  return match[2] ? { conversation: match[1]!, message: match[2] } : { conversation: match[1]! };
}

/** The link a page URL's hash carries (`#/conversation/<id>[/message/<id>]`), as a cmux link. */
export function hashLink(hash: string): string | undefined {
  const match = /^#\/(conversation\/[A-Za-z0-9_]+(?:\/message\/[A-Za-z0-9_]+)?)\/?$/.exec(hash);
  return match ? `cmux://${match[1]}` : undefined;
}

/** Merges a page or event messages into an ascending window by seq; a newer copy replaces the old one.
 * Replies without a root get their thread's root (`withThreadRoots`). */
export function mergeMessages(
  window: readonly HomeMessage[],
  incoming: readonly HomeMessage[],
  limit: number,
): HomeMessage[] {
  if (incoming.length === 0) return window as HomeMessage[];
  const bySeq = new Map<number, HomeMessage>();
  for (const message of window) bySeq.set(message.seq, message);
  for (const message of incoming) bySeq.set(message.seq, message);
  const merged = withThreadRoots([...bySeq.values()].sort((a, b) => a.seq - b.seq));
  return merged.length > limit ? merged.slice(merged.length - limit) : merged;
}

/** The messages with each reply that has no root of its own (`replyTo` only) given the root of the
 * loaded thread reply it answers, through any chain of such replies. A reply to a thread reply then
 * shows in that thread, not under the reply as a thread of its own (a top-level row with the reply
 * drawn again above it); one that answers a top-level message keeps `threadOf`'s rule. */
export function withThreadRoots(messages: HomeMessage[]): HomeMessage[] {
  const byId = new Map(messages.map((message) => [message.id, message]));
  // Each message's resolved thread, once per call (a long chain of replies is walked once).
  const known = new Map<string, string | undefined>();
  // The thread `message` is in: its root, else the thread of the message it answers, else that
  // message (top level); undefined at the top level, in a reply loop, or when the chain leaves the
  // loaded messages.
  const rootOf = (message: HomeMessage, seen: Set<string>): string | undefined => {
    if (message.threadRoot) return message.threadRoot;
    if (known.has(message.id)) return known.get(message.id);
    const target = message.replyTo?.message;
    if (!target || target === message.id || seen.has(target)) return undefined;
    seen.add(message.id);
    // A chain that leaves the loaded messages is unknown: nothing is saved until the older page
    // brings it in, so a derived root never sticks to a reply (it would read as the owner's later).
    const answered = byId.get(target);
    const root = answered ? (rootOf(answered, seen) ?? (answered.replyTo ? undefined : target)) : undefined;
    known.set(message.id, root);
    return root;
  };
  let resolved: HomeMessage[] | undefined;
  messages.forEach((message, index) => {
    if (message.threadRoot || !message.replyTo) return;
    const root = rootOf(message, new Set());
    // The answered message itself is what `threadOf` reads already: the message stays as it is.
    if (!root || root === message.id || root === message.replyTo.message) return;
    resolved ??= [...messages];
    resolved[index] = { ...message, threadRoot: root };
  });
  return resolved ?? messages;
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
export function lastEditable(
  messages: readonly HomeMessage[],
  me: string | undefined,
  /** Thread roots: the timeline shows them as thread rows, so they are edited in the sheet. */
  roots: ReadonlySet<string> = new Set(),
): HomeMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.author !== me || message.retracted || threadOf(message) || roots.has(message.id)) continue;
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

/** The id prefix of a message I sent that the owner has not shown yet. */
export const PENDING_PREFIX = "pending:";

/** My pending sends of one conversation as messages after the window (seq after `afterSeq`), so
 * the timeline and the thread tree place them like owner messages. */
export function pendingMessages(
  pending: readonly {
    key: string;
    conversation: string;
    text: string;
    attachments?: readonly HomeAttachment[];
    threadRoot?: string;
    replyTo?: string;
    createdAt: number;
  }[],
  conversation: string | undefined,
  me: string | undefined,
  afterSeq: number,
): HomeMessage[] {
  if (!conversation || !me) return [];
  return pending
    .filter((entry) => entry.conversation === conversation)
    .map((entry, index) => {
      const message: HomeMessage = {
        id: `${PENDING_PREFIX}${entry.key}`,
        conversation,
        seq: afterSeq + 1 + index,
        author: me,
        createdAt: entry.createdAt,
        retracted: false,
        parts: [
          ...(entry.text ? [{ type: "text" as const, text: entry.text, mentions: [] }] : []),
          ...(entry.attachments ?? []),
        ],
        reactions: [],
        clientMessageId: entry.key,
      };
      if (entry.threadRoot) message.threadRoot = entry.threadRoot;
      if (entry.replyTo) message.replyTo = { message: entry.replyTo, partIndex: 0 };
      return message;
    });
}

/** Every conversation, newest activity first (the one chronological list: rooms and people). */
export function chronological(conversations: Iterable<HomeConversation>): HomeConversation[] {
  return [...conversations].sort((a, b) => activityAt(b) - activityAt(a) || (a.id < b.id ? -1 : 1));
}

/** The list as it shows: my pinned conversations first, in my pin order (lower position first),
 * then every other conversation newest activity first. */
export function listOrder(conversations: Iterable<HomeConversation>): {
  pinned: HomeConversation[];
  rest: HomeConversation[];
} {
  const pinned: HomeConversation[] = [];
  const rest: HomeConversation[] = [];
  for (const conversation of chronological(conversations)) (conversation.pinned ? pinned : rest).push(conversation);
  // Stable: equal positions (an owner without positions) keep the chronological order.
  pinned.sort((a, b) => (a.pinPosition ?? 0) - (b.pinPosition ?? 0));
  return { pinned, rest };
}

/** Unread as the list shows it: messages after my read cursor, or my own unread mark. */
export function isUnread(conversation: HomeConversation): boolean {
  return (conversation.unread > 0 || conversation.markedUnread === true) && !conversation.muted;
}

/** A conversation's last activity: its last message, else its last change (a new, empty room). */
export function activityAt(conversation: HomeConversation): number {
  return conversation.lastAt ?? conversation.updatedAt;
}

/** A Chief's live state as its row and header show it. */
export type ChiefState = "working" | "waiting" | "idle";

/** The state of the Chief a direct message is with (undefined: not a Chief's direct message).
 * Working: it types or writes a reply now, or its last message carries running work. Waiting:
 * its last message carries work that waits for me. Else idle. */
export function chiefState(
  conversation: HomeConversation,
  me: string | undefined,
  active: ReadonlySet<string> | undefined,
): ChiefState | undefined {
  const others = conversation.participants.filter((p) => p.id !== me);
  const chief = others.length === 1 && others[0]!.chief ? others[0]! : undefined;
  if (!chief) return undefined;
  if (active?.has(chief.id)) return "working";
  // The owner's state when it derives one (home-inbox-v1): its typing and runs in every
  // conversation; the page re-reads the rows when a run ends or the Chief stops typing.
  if (conversation.chiefState) return conversation.chiefState;
  if (conversation.lastAuthor === chief.id && conversation.lastWork === "waiting") return "waiting";
  if (conversation.lastAuthor === chief.id && conversation.lastWork === "running") return "working";
  return "idle";
}
